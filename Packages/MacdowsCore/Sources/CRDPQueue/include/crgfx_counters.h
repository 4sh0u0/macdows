#ifndef CRGFX_COUNTERS_H
#define CRGFX_COUNTERS_H

/*
 * crgfx_counters: per-surfaceId GFX frame counters for ONE session. MEASUREMENT ONLY --
 * nothing in the render path reads these, no code branches on them, and removing this
 * whole unit would change no pixel.
 *
 * THE QUESTION IT EXISTS TO ANSWER (ADR-0018 §5.2 ②). A RAIL window can be re-mapped onto a
 * NEW GFX surface mid-session (a resize allocates a bigger one). The 2026-09-15 About case
 * showed a window whose later surfaces were mapped but never presented, and the two possible
 * causes are indistinguishable from the client's own render state alone:
 *   4a -- the server DID draw into the new surface and something between the wire and the
 *         NSWindow dropped the frame, or
 *   4b -- the server only mapped the surface and never drew into it.
 * The discriminator is upstream of every client decision: how often the gdi pipeline handed
 * that surface to the bridge at all (`updates`), how often it arrived carrying a non-empty
 * invalid region (`dirty`), how often the bridge published it onward (`publishes`), and how
 * many of those publishes the drain's generation filter then discarded (`stale`).
 * 4b looks like `updates > 0, dirty = 0`; 4a looks like `dirty > 0` with the registry-side
 * counters showing where the frame was lost afterwards.
 *
 * TWO MORE COUNTERS, ADDED BY THE 2026-09-15 GUARD TRACE (ADR-0018 §5.2 ②b). The trace showed that
 * neither half of the chain above can be read without them: `publishes` is counted whether or not
 * the write into the surface slot was accepted (`writes` is that bool), and the slot itself can be
 * TORN DOWN behind the consumer's back by an unmap of its window (`erased`), which is what leaves a
 * frame with nowhere to land while every other counter looks healthy. `writes < publishes` and
 * `erased > 0` are the two shapes that were previously reachable only by elimination.
 *
 * WHY A SEPARATE TABLE AND NOT crdpq_frames. crdpq_frames is last-writer-wins STATE (adr/0005
 * §1): a publish overwrites the previous one, so it cannot say how many times anything
 * happened. These are monotonic event counts with no consumer and nothing to consume -- a
 * different data structure answering a different question, kept out of crdpq.h's own
 * three-primitive contract for that reason.
 *
 * LIFETIME: one table per CRSession instance, created with the session and never reset --
 * not by a reconnect, not by a disconnect. Same "cumulative for this instance's whole
 * lifetime" semantics as the session's other diagnostic counters, and for the same reason: a
 * counter that resets cannot be read after the run that produced it.
 *
 * FIXED CAPACITY, ON PURPOSE (`CRGFX_COUNTERS_SLOTS`). The write side runs on T_dvc inside
 * FreeRDP's mux critical section, on the per-frame path, where adr/0005 §2 forbids allocation;
 * a growing table would allocate there. A session that exceeds the capacity simply stops
 * tracking NEW surface ids -- the ones already holding a slot keep counting correctly, and a
 * read for an untracked id answers "not tracked" rather than 0, so an overflow can never be
 * misread as "the server drew nothing". Observed sessions use a handful of surfaces (the
 * 2026-09-15 About window's whole life: three), so the ceiling is roughly an order of
 * magnitude above anything measured.
 *
 * WHAT CONSUMES A SLOT (gate r1 I-1). Not only ids that DREW: `crgfx_counters_note_erase` claims
 * one too, so a surface that was mapped and torn down without a single update holds a slot for the
 * session's whole life. That is deliberate -- an erase is a measured event about that id, and the
 * lane exists partly to find surfaces that were never drawn into -- but it means the ceiling is
 * shared with erase-only ids, and a session that crosses it loses the measurement for NEW drawn
 * ids (they read "not tracked"), never a wrong number for an old one. The sizing argument above
 * was written about drawn ids; erase-only ids are additional.
 *
 * THREADING: every function below takes the table's own `os_unfair_lock`, so the write side
 * (T_dvc) and the read side (T_main, the diagnostics harness) need no external
 * synchronization. The lock is uncontended in practice -- the same thread that already holds
 * FreeRDP's mux is the only writer -- and taking one more uncontended lock on that path is
 * exactly what `crsurface_table_write` already does one call earlier in the same hook.
 * Allocation-free after `crgfx_counters_create`.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** How many distinct surface ids one table can track (see the file comment's capacity
 *  rationale). Exposed so a test can pin the overflow behaviour against the real bound
 *  rather than a guessed one. */
#define CRGFX_COUNTERS_SLOTS 64

typedef struct crgfx_counters crgfx_counters_t;

/** Creates an empty table, or NULL if the allocation fails (a caller that gets NULL loses
 *  the diagnostic and nothing else -- every function below tolerates a NULL table). */
crgfx_counters_t* crgfx_counters_create(void);

void crgfx_counters_destroy(crgfx_counters_t* counters);

/** Records one entry into the frame hook for `surfaceId`, with `dirty` saying whether the
 *  surface arrived carrying a non-empty invalid region.
 *
 *  The two counters are bumped together, under one lock, so `dirty <= updates` holds by
 *  construction: "the server drew into this surface at least once" is then a property of the
 *  pair, never an artefact of two counters observed a moment apart. Claims a free slot for a
 *  surface id seen for the first time; a call that finds the table full is dropped, leaving
 *  that id untracked (`crgfx_counters_read` returns false for it) rather than being
 *  attributed to somebody else's slot. */
void crgfx_counters_note_update(crgfx_counters_t* counters, uint32_t surfaceId, bool dirty);

/** Records that `crsurface_table_write` ACCEPTED a frame for `surfaceId` (returned true, i.e. the
 *  pixels were copied into one of that slot's buffers).
 *
 *  THE GAP THIS CLOSES (2026-09-15 guard trace, ADR-0018 §5.2 ②b). The frame hook ignores that
 *  return value and counts a `publish` regardless, so `publishes` means only "the hook reached its
 *  exit": a write declined because the slot was gone, because all three buffers were leased, or
 *  because an allocation failed is indistinguishable from one that landed. `writes < publishes` is
 *  that difference made visible, and it is the ONLY client-side counter that can say the frame
 *  never reached a buffer at all -- everything downstream sees the same empty slot either way.
 *  Same no-slot-claiming rule as `crgfx_counters_note_publish`: a write is always preceded by the
 *  update that claimed the slot. */
void crgfx_counters_note_write(crgfx_counters_t* counters, uint32_t surfaceId);

/** Records that the surface-slot table TORE DOWN this surface's slot -- the unmap sweep that
 *  erases every slot of a windowId, the disconnect/shutdown clear, a remap to a different window,
 *  or a size change that discarded a published frame (`CRSurfaceSlots.h`'s erase-observer comment
 *  lists the four call sites and the one deliberate exclusion).
 *
 *  WHY IT IS HERE AND NOT IN THE SLOT TABLE. The teardown is the one event in the whole chain that
 *  nothing recorded: `UnmapWindowForSurface` erases slots the registry still believes in, and the
 *  registry is never told, so every subsequent frame for that surface dies as "no slot" with no
 *  trace of what removed it -- the 2026-09-15 trace could only reach that conclusion by
 *  elimination. Counting it beside the surface's other counters is what turns that elimination
 *  into a reading.
 *
 *  UNLIKE the two functions above, this one DOES claim a free slot for an id it has not seen: a
 *  surface can be mapped and torn down without anything ever drawing into it, and that case --
 *  no updates at all, `erased >= 1` -- is precisely one of the shapes the lane is looking for. */
void crgfx_counters_note_erase(crgfx_counters_t* counters, uint32_t surfaceId);

/** Records that the bridge published a frame for `surfaceId` onward to the consumer (the
 *  frame lane write plus the readiness doorbell -- see CRSession.mm's GFX hook).
 *
 *  Counted separately from `updates` rather than assumed equal to it: the two are the entry
 *  and the exit of the same hook, and a session where they diverge is a frame the bridge
 *  accepted and never forwarded -- the one client-side loss that would otherwise be invisible
 *  to both the server's own logs and the registry's counters. Does NOT claim a slot for an
 *  unseen surface id: a publish without a preceding update is impossible on the real path, so
 *  a slot claimed here would be a measurement of a bug in this file rather than of the
 *  session. */
void crgfx_counters_note_publish(crgfx_counters_t* counters, uint32_t surfaceId);

/** Records that a published frame-readiness event for `surfaceId` was thrown away by the
 *  drain's generation filter (adr/0005 §4) before any consumer could act on it.
 *
 *  THE GAP THIS CLOSES (gate r1 I-1). Between `publishes` and anything the registry can count
 *  there is one more exit: a reconnect bumps the session generation, and every event still in
 *  the queue from the older connection is discarded at the drain entry point. Without this
 *  counter a run reads `publishes=N` with every later counter at 0 and no way to tell a
 *  discarded frame from one that was never delivered -- so the row's arithmetic
 *  (`publishes = stale + ready + still-in-flight`) would have an unnamed term in it. Same
 *  no-slot-claiming rule as `crgfx_counters_note_publish`: the event this counts was posted by
 *  the same hook that already counted an update for that surface. */
void crgfx_counters_note_stale(crgfx_counters_t* counters, uint32_t surfaceId);

/** Reads the six counters for `surfaceId`, in the order a frame meets them (`updates` ->
 *  `dirty` -> `writes` -> `publishes` -> `stale`) plus `erased`.
 *
 *  WHAT `true` MEANS, EXACTLY (gate r1 I-1 -- read this before interpreting a zero). `true` says
 *  SOME bridge event was recorded for this id: an update, a write, a publish, a stale discard or an
 *  ERASE. It does NOT say anything was ever drawn. `crgfx_counters_note_erase` claims a slot on its
 *  own (see its own comment for why), so `true` with `updates == 0` is reachable and means "the
 *  bridge tore this surface's slot down and nothing ever drew into it" -- itself one of the lane's
 *  verdicts, not a bookkeeping accident.
 *
 *  Returns false -- leaving the out-parameters untouched -- when this table has recorded NOTHING for
 *  that surface id, whether because no event of any of those five kinds ever reached it or because
 *  the table was already full when the first one did. The caller is expected to report that "not
 *  tracked" verdict verbatim; collapsing it into zeros would turn "no measurement" into the
 *  measurement 4b consists of. Every out-parameter is optional, and all six are read under ONE lock
 *  so a caller can never see two of them from different instants. Safe from any thread. */
bool crgfx_counters_read(crgfx_counters_t* counters, uint32_t surfaceId, uint64_t* out_updates,
                         uint64_t* out_dirty, uint64_t* out_writes, uint64_t* out_publishes,
                         uint64_t* out_stale, uint64_t* out_erased);

#ifdef __cplusplus
}
#endif

#endif /* CRGFX_COUNTERS_H */
