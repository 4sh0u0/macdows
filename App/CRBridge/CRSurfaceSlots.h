#ifndef CRSURFACESLOTS_H
#define CRSURFACESLOTS_H

/*
 * CRSurfaceSlots: adr/0005 §2's frame data pathway -- one SurfaceSlot per GFX surfaceId,
 * each owning an IOSurface triple-buffer ring (write / published-not-yet-leased / leased-
 * to-CoreAnimation). Pure C interface (mirrors Packages/MacdowsCore/.../CRDPQueue's
 * crdpq.h opaque-pointer idiom) so CRSession.mm and any Swift-facing ObjC method built on
 * top of it never need to see the C++ class this wraps.
 *
 * Threading contract, matching adr/0005 §2/§3 exactly:
 *   - crsurface_table_map / crsurface_table_unmap_window / crsurface_table_write: called
 *     from T_dvc only (the RDPGFX callbacks this is wired into all run there). Must be
 *     fast -- the ADR's own words, "must be fast" -- since this runs inside FreeRDP's mux
 *     critical section; the actual pixel copy this performs *is* the "must be fast" work,
 *     not something deferrable outside a lock the way crdpq_control's post() is.
 *   - crsurface_table_lease_published / crsurface_table_release_lease: called from
 *     T_main only.
 *   - crsurface_table_clear: called from T_main during -[CRSession shutdownAndWait],
 *     after T_rdp (and therefore T_dvc, which freerdp_disconnect joins) has already
 *     exited -- so by the time this runs there is no concurrent writer left; the lock is
 *     still taken for symmetry/defensiveness, not because it's load-bearing there.
 *   - All other functions (create/destroy) follow ordinary single-owner construction/
 *     destruction discipline -- no concurrent calls expected.
 *
 * Never exposes `surface->data` (GDI-owned, freed on T_dvc) past crsurface_table_write's
 * own call frame -- the whole point of copying into an IOSurface synchronously, before
 * FreeRDP's EndFrame handling sends FRAME_ACKNOWLEDGE (adr/0005 §2's "FrameAck semantics =
 * decoded and already copied out").
 */

#include <IOSurface/IOSurface.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

typedef struct CRSurfaceSlotTable CRSurfaceSlotTable;

CRSurfaceSlotTable *crsurface_table_create(void);
void crsurface_table_destroy(CRSurfaceSlotTable *table);

/* T_dvc, from MapSurfaceToWindow: registers surfaceId -> windowId. A slot's IOSurface
 * buffers aren't allocated until the first crsurface_table_write call for it (dimensions
 * aren't known yet at map time). */
void crsurface_table_map(CRSurfaceSlotTable *table, uint32_t surfaceId, uint64_t windowId);

/* T_dvc, from UnmapWindowForSurface: releases every slot currently mapped to windowId
 * (there is normally exactly one) and frees its IOSurface buffers -- but only buffers not
 * currently leased to T_main; a still-leased buffer is freed when its lease is released
 * (crsurface_table_release_lease already handles a release against an unmapped slot
 * safely -- see that function's own comment). */
void crsurface_table_unmap_window(CRSurfaceSlotTable *table, uint64_t windowId);

/* T_dvc, from UpdateWindowFromSurface. `data`/`scanline` describe the GDI-decoded BGRA32
 * surface buffer (never retained past this call); `rects`/`rectCount` is the surface's
 * current invalidRegion (may be empty -- see crsurface_table_write's .cpp-side comment
 * for when a full-frame copy happens regardless of what's passed here). `generation` is
 * the value this write publishes under -- the caller stamps it (typically from the same
 * counter driving crdpq_frame_publish, so a consumer cross-referencing the two agrees).
 * Returns false (frame dropped, not copied) only if surfaceId isn't mapped or every
 * buffer in its triple-buffer ring is currently leased (all three legitimately in use at
 * once -- rare, but must not block/crash rather than silently corrupt a leased buffer);
 * the caller should count this (adr/0005 §7's dropped-frame-alert pattern). */
typedef struct
{
    uint16_t left;
    uint16_t top;
    uint16_t right;
    uint16_t bottom;
} CRSurfaceRect;

bool crsurface_table_write(CRSurfaceSlotTable *table, uint32_t surfaceId, const uint8_t *data, uint32_t width,
                            uint32_t height, uint32_t scanline, uint32_t generation, const CRSurfaceRect *rects,
                            uint32_t rectCount);

/* T_main. Returns a +1-retained IOSurfaceRef (caller must CFRelease, typically after
 * handing it to a CALayer, which itself retains it) for surfaceId's most recently
 * published buffer not already leased, and marks that buffer Leased so
 * crsurface_table_write won't pick it as a write target. NULL if surfaceId isn't tracked,
 * nothing has ever been published for it, or the most recent publish is already leased
 * (caller already holds the current frame -- nothing new to hand out). `*outGeneration`
 * (if non-NULL) receives the published generation. */
IOSurfaceRef crsurface_table_lease_published(CRSurfaceSlotTable *table, uint32_t surfaceId, uint32_t *outGeneration);

/* T_main, once a CATransaction completion block fires for a surface previously returned
 * by crsurface_table_lease_published (adr/0005 §2: "the recycle point is CATransaction
 * completion, not the moment contents is swapped"). Marks the matching buffer Free again. Safe to call even if the
 * slot has since been unmapped/resized out from under it (the buffer itself is looked up
 * by IOSurfaceRef identity across all live slots, not by surfaceId+index, specifically so
 * a lease outstanding across an unmap/resize still resolves correctly and doesn't leak);
 * a surface this table no longer recognizes at all is CFRelease'd directly and otherwise
 * ignored. */
void crsurface_table_release_lease(CRSurfaceSlotTable *table, IOSurfaceRef surface);

/* T_main, on disconnect (adr/0005 §2: "after disconnect the pool stops leasing; destroy
 * once every lease has been returned"). Unmaps
 * every slot; any buffer not currently leased is freed immediately, exactly like
 * crsurface_table_unmap_window would for it. Does NOT wait for outstanding leases --
 * those still get released (and freed) normally via crsurface_table_release_lease
 * whenever their CATransaction completion eventually fires, even after this call. */
void crsurface_table_clear(CRSurfaceSlotTable *table);

/* Cumulative count of crsurface_table_write calls that returned false. Not `const
 * CRSurfaceSlotTable*` -- reading it still takes the table's lock, matching every other
 * accessor in this file, which would otherwise require a const_cast internally. */
uint64_t crsurface_table_dropped_frame_count(CRSurfaceSlotTable *table);

/* Diagnostics only (Scripts/test-slots.sh and ad hoc perf verification) -- cumulative
 * counts, across every crsurface_table_write call that actually copied pixels (dropped
 * writes count in neither), of how many took the full-frame path (only ever a buffer's
 * very first write, per H1's own fix) versus the rect-union path (every rotation onto an
 * already-written buffer, copying just that buffer's accumulated pending dirty union
 * rather than a full frame). Either output pointer may be NULL if that count isn't
 * wanted. */
void crsurface_table_copy_path_counts(CRSurfaceSlotTable *table, uint64_t *outFullFrameCopies,
                                       uint64_t *outRectCopies);

#ifdef __cplusplus
}
#endif

#endif /* CRSURFACESLOTS_H */
