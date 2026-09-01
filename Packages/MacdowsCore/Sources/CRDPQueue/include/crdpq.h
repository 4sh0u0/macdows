#ifndef CRDPQ_H
#define CRDPQ_H

/*
 * crdpq: the C event-queue layer specified by adr/0005 §1/§3/§4 — three independent
 * primitives, each crossing exactly one thread boundary FreeRDP's callback threads and
 * AppKit's main thread must never cross directly:
 *
 *   1. crdpq_control  — T_rdp/T_dvc (any number of producer threads) -> T_main.
 *                        FIFO, POD-deep-copy double buffer (adr/0005 §1's "rdpq").
 *   2. crdpq_frames    — T_dvc -> T_main. Not a queue: GFX frames are *state*, not
 *                        events, so this is a last-writer-wins per-surfaceId slot table
 *                        (adr/0005 §1's frame lane).
 *   3. crdpq_outbound  — T_main -> T_rdp. The reverse direction (adr/0005 §3's "outbound
 *                        commands go through a queue too"): ClientExecute/ClientActivate/ClientWindowMove/input
 *                        never call into FreeRDP directly from T_main.
 *
 * Zero FreeRDP, zero AppKit, zero Objective-C dependencies in this target — pure C11.
 * The callback side (waking the consumer) is a function pointer supplied at creation:
 * production code hangs dispatch_async(main, ...)/a WinPR event's SetEvent off it; tests
 * hang a manual pump or a counter off it. See adr/0005 §5: this C layer is exactly
 * where Swift 6 strict concurrency draws its "I don't manage this" boundary — the shared
 * mutable state lives here, in C, with an explicit lock, on purpose.
 *
 * THREADING CONTRACT (read this before calling anything below):
 *   - crdpq_post / crdpq_frame_publish / crdpq_outbound_post: safe from any number of
 *     threads, concurrently with each other and with a drain/consume call.
 *   - crdpq_drain / crdpq_frame_consume / crdpq_outbound_drain: each queue has exactly
 *     ONE designated consumer thread (T_main for control+frames, T_rdp for outbound).
 *     Calling a given queue's drain/consume function concurrently with *itself* (i.e.
 *     from two threads at once, or reentrantly) is undefined behavior. This is not a
 *     missing feature: adr/0005 §1/§3 designs each lane around a single consumer, and
 *     relying on that (rather than adding a second lock to also guard against concurrent
 *     drains) is what keeps the post-side critical section a single short lock/unlock.
 *   - The visitor callback passed to a drain/consume function runs OUTSIDE the internal
 *     lock, on the consumer thread, in FIFO order for crdpq_drain (adr/0005 §1: "FIFO
 *     naturally guarantees full per-window ordering"). It must not call back into crdpq_post/crdpq_drain for
 *     the *same* queue (reentrancy is undefined for the reason above) or block.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ==================================================================================== *
 * Shared types
 * ==================================================================================== */

/** Bridge-layer session generation (adr/0005 §3's `atomic uint32 sessionGeneration`).
 *  Owned by the caller/consumer, not by this library: `crdpq_generation_bump` just
 *  atomically increments a counter this library stores on behalf of `crdpq_control_t`;
 *  the actual "does this event still belong to the live session" comparison happens at
 *  the consumer's drain entry point (adr/0005 §3: "the one comparison point is at the
 *  drain() entry point"), never
 *  inside this library — crdpq_drain delivers every event, unfiltered, generation and
 *  all, and lets the caller decide. */
typedef uint32_t crdpq_generation_t;

/** Fixed-size UTF-8 text buffer used for every variable-length string field (window
 *  titles, exeOrFile paths, RemoteApplicationProgram). adr/0005 requires events to be POD
 *  (no pointers survive the producing callback) — a fixed buffer is the direct cost of
 *  that requirement, not an oversight. 256 bytes comfortably covers every title observed
 *  in samples/phase05-rail-events-2026-08-19 (longest real title there is under 20 UTF-8
 *  bytes) with headroom for pathological server input; anything longer is truncated at a
 *  UTF-8 codepoint boundary (never mid-sequence) and `truncated` is set so a consumer can
 *  tell the difference between "short title" and "we cut this off". */
#define CRDPQ_TEXT_BUF_SIZE 256

typedef struct {
    char bytes[CRDPQ_TEXT_BUF_SIZE]; /* always NUL-terminated */
    uint16_t length;                 /* strlen(bytes), i.e. excluding the NUL */
    bool truncated;
} crdpq_text_t;

/** Copies `src[0..src_len)` into `dst`, truncating at `CRDPQ_TEXT_BUF_SIZE - 1` bytes if
 *  necessary and backing up to the start of a UTF-8 codepoint (never splitting a
 *  multi-byte sequence) before doing so. Always leaves `dst->bytes` NUL-terminated. */
static inline void crdpq_text_set(crdpq_text_t* dst, const char* src, size_t src_len) {
    if (src_len < CRDPQ_TEXT_BUF_SIZE) {
        for (size_t i = 0; i < src_len; i++) {
            dst->bytes[i] = src[i];
        }
        dst->bytes[src_len] = '\0';
        dst->length = (uint16_t)src_len;
        dst->truncated = false;
        return;
    }
    size_t cut = CRDPQ_TEXT_BUF_SIZE - 1;
    /* Back up while looking at a UTF-8 continuation byte (10xxxxxx). */
    while (cut > 0 && ((unsigned char)src[cut] & 0xC0) == 0x80) {
        cut--;
    }
    for (size_t i = 0; i < cut; i++) {
        dst->bytes[i] = src[i];
    }
    dst->bytes[cut] = '\0';
    dst->length = (uint16_t)cut;
    dst->truncated = true;
}

/* ==================================================================================== *
 * Control lane (crdpq_control) — RAIL window orders + a handful of connection-lifecycle
 * events. Field shapes/sizes are drawn from Tools/rail-probe/rail-probe.c's observed
 * event set and Packages/MacdowsCore/Sources/MacdowsCore/RailEvent.swift's field
 * typing decisions (offsets = int32_t, genuinely signed on the wire in a multi-monitor
 * layout; size/identifiers/bitmasks = uint32_t, matching FreeRDP's own Stream_Read_UINT32
 * parse of windowWidth/windowHeight and RDPGFX's mappedWidth/mappedHeight — real captures
 * also include style values with bit 31 set, which would silently misdecode as a signed
 * type). This is a *curated* subset of rail-probe's full diagnostic event catalog: only
 * what adr/0005's window-management/GFX-binding consumers actually need, not every
 * probe-only diagnostic event (ServerZOrderSync, ChannelConnected, VerifyCertificateEx,
 * etc. have no production consumer and are not represented here).
 * ==================================================================================== */

typedef enum {
    CRDPQ_EVENT_WINDOW_CREATE = 0,
    CRDPQ_EVENT_WINDOW_UPDATE,
    CRDPQ_EVENT_WINDOW_DELETE,
    CRDPQ_EVENT_WINDOW_ICON,
    CRDPQ_EVENT_NOTIFY_ICON_CREATE,
    CRDPQ_EVENT_NOTIFY_ICON_UPDATE,
    CRDPQ_EVENT_NOTIFY_ICON_DELETE,
    CRDPQ_EVENT_MONITORED_DESKTOP,
    CRDPQ_EVENT_EXEC_RESULT,
    CRDPQ_EVENT_HANDSHAKE_FLAGS,
    CRDPQ_EVENT_SURFACE_MAPPED,
    CRDPQ_EVENT_FRAME_READY,
    CRDPQ_EVENT_DISCONNECTED,
    /* adr/0008 §1: the three RAIL callbacks CRSession.mm previously left unwired
     * ("no curated crdpq event type exists for any of them yet"). */
    CRDPQ_EVENT_LOCAL_MOVE_SIZE,
    CRDPQ_EVENT_MIN_MAX_INFO,
    CRDPQ_EVENT_ZORDER_SYNC,
} crdpq_event_type_t;

/** adr/0008 §2b: a wire-faithful `RECTANGLE_16` (window.c:462/478 parses this as four
 *  `Stream_Read_UINT16`s, unsigned, window-relative) — deliberately NOT widened to
 *  int32_t the way offsets/positions elsewhere in this header are: window_order is the
 *  highest-frequency event type, and widening every visibility rect would push
 *  crdpq_window_order_t (already the largest union member) up by another 768 bytes for
 *  no observed need (adr/0008 §2b). */
typedef struct {
    uint16_t left;
    uint16_t top;
    uint16_t right;
    uint16_t bottom;
} crdpq_rect_t;

/** adr/0008 §2b: upper bound on `crdpq_window_order_t.visibilityRects`. The protocol's own
 *  hard ceiling is 65535 (window.c:462, a `Stream_Read_UINT16` — 2 bytes, not the 1-byte
 *  ceiling `numWindowIds` below has); 32 is a shape-based estimate (not observation-based —
 *  see adr/0008 §2b's "the observed×4 input is missing, not small" discussion) covering the
 *  scan-band decomposition of a typical rounded/irregular window region with a full extra
 *  multiple of headroom, at a cost of 256 bytes/slot. */
#define CRDPQ_MAX_VISIBILITY_RECTS 32

/** WindowCreate/WindowUpdate. Matches MS-RDPERP's TS_WINDOW_STATE_ORDER field set (see
 *  Packages/MacdowsCore/.../WindowModel.swift's WindowOrderField for the fieldFlags bit
 *  values, if this ever needs delta-merge semantics at this layer too — as of Phase 1
 *  W3, this layer is a transport, not a state machine: merge policy lives in WindowModel,
 *  this struct just carries whatever fieldFlags + values rail-probe/CRBridge observed for
 *  a single order).
 *
 *  `ownerWindowId` (adr/0008 §3): TS_WINDOW_STATE_ORDER.ownerWindowId, gated on the wire
 *  by WINDOW_ORDER_FIELD_OWNER (0x00000002) — this layer is still a transport, not a
 *  state machine, so it carries whatever the caller copied in for a given order (0 is a
 *  legitimate "no owner" value, not just "field absent"); bit-gated delta-merge across
 *  orders is WindowModel's job, same as every other sub-field here. */
typedef struct {
    uint32_t windowId;
    uint32_t fieldFlags;
    int32_t offsetX;
    int32_t offsetY;
    uint32_t width;
    uint32_t height;
    uint32_t style;
    uint32_t styleEx;
    uint32_t show;
    uint32_t ownerWindowId;
    crdpq_text_t title;
    /* adr/0008 §2b: `numVisibilityRects` holds the WIRE value (not the stored count),
     * exactly like `crdpq_monitored_desktop_t.numWindowIds` below — deliberate asymmetry
     * from `crdpq_text_t`'s own truncation convention (crdpq.h's own doc comment on
     * CRDPQ_TEXT_BUF_SIZE explains why a string's original length isn't useful to a
     * consumer, but "how many rects did the server actually send" is a real signal here).
     * Existence of the array itself is gated by the caller on WINDOW_ORDER_FIELD_VISIBILITY
     * (0x0200) -- see CRSession.mm's crb_window_common, which is the only writer. */
    uint32_t numVisibilityRects;
    bool visibilityRectsTruncated;
    crdpq_rect_t visibilityRects[CRDPQ_MAX_VISIBILITY_RECTS];
    /** adr/0010 §1: `TS_WINDOW_STATE_ORDER.visibleOffsetX/Y` (window.h:215-216, wire INT32,
     *  not widened further) -- the screen-space top-left corner of the window's VISIBLE
     *  region bounding box, gated on `WINDOW_ORDER_FIELD_VIS_OFFSET` (0x00001000). This is
     *  NOT the same anchor as `offsetX/offsetY` above (`windowOffsetX/Y`, the window's own
     *  origin) -- adr/0010 §0(b): the two agree only when the window is unoccluded, and
     *  adr/0010 §2's shape transform requires this one specifically to correctly place
     *  `visibilityRects` for an occluded window. Bit-gated exactly like `ownerWindowId`
     *  above (adr/0008 §3's same discipline, restated by adr/0010 §1): an order that
     *  doesn't carry this bit leaves these two fields at their `ev.payload`-memset zero,
     *  which is NOT "visibleOffset == 0" at the WindowModel/PendingWindowState delta-merge
     *  layer -- that layer is what actually implements "absent bit -> keep prior value /
     *  anchor still unknown" (adr/0010 §3 rule 2); this transport layer only ever carries
     *  what a single order's own bit said, same as every other conditional sub-field here.
     *  Appended at the end of the struct, per adr/0008 §5's "new fields append" rule. */
    int32_t visibleOffsetX;
    int32_t visibleOffsetY;
} crdpq_window_order_t;

/* adr/0008 §5's ABI/version discipline: no version number, no reserved padding — a struct
 * layout change must be caught by the compiler at build time, not papered over by
 * convention. 572 was measured (not estimated) with `clang`/arm64 immediately after adding
 * `visibleOffsetX/Y` above (adr/0010 §1; up from 564 before this ADR -- see adr/0008 §5's
 * own assert comment for the 300B/296B lineage before that). If this ever fires, some
 * other field in this struct (or its `crdpq_text_t`/`crdpq_rect_t` member) changed shape and
 * every consumer needs re-auditing, not just this assert updating. */
_Static_assert(sizeof(crdpq_window_order_t) == 572, "crdpq_window_order_t layout changed -- re-measure and audit consumers (adr/0008 §5 / adr/0010 §1)");

/** WindowDelete, WindowIcon. */
typedef struct {
    uint32_t windowId;
} crdpq_window_id_t;

/** adr/0013 §1: the notify-icon pixel side-store's two bounds. `CRDPQ_ICON_MAX_DIM` is the
 *  largest square a tray icon may be for this client to carry it at all (Windows' shell asks
 *  its tray for 16/32/48-square icons at the DPI scales this client targets — 48 is the top of
 *  that range, and anything larger is rejected outright rather than downscaled here, see
 *  `crdpq_icon_convert`); `CRDPQ_ICON_SLOTS` is how many distinct `(windowId, notifyIconId)`
 *  icons may be live at once. Together they fix the store's footprint at
 *  16 * 9216B = ~144KB, allocated once — which is exactly the point (adr/0013 §1): the
 *  control lane's own slots grow to a 65536-event ceiling (adr/0005 §7), so inlining even a
 *  32x32 RGBA icon into `crdpq_event_payload_t` would multiply that ceiling's memory
 *  footprint by ~10x for the lowest-frequency event type in the whole union. Pixels do not
 *  ride in control slots — the same split the frames lane + `CRSurfaceSlotTable` already
 *  establish for GFX frames. */
#define CRDPQ_ICON_MAX_DIM 48
#define CRDPQ_ICON_SLOTS 16
/** Bytes one store slot's premultiplied-RGBA8888 buffer occupies (48*48*4 = 9216). */
#define CRDPQ_ICON_RGBA_BUF_SIZE (CRDPQ_ICON_MAX_DIM * CRDPQ_ICON_MAX_DIM * 4)

/** NotifyIconCreate/Update/Delete.
 *
 *  adr/0013 §1: everything past `notifyIconId` was appended (adr/0008 §5's "new fields only
 *  append" rule) to carry a real tray icon instead of a placeholder. The PIXELS are NOT here —
 *  `iconSlot` is an index into the session's `crdpq_icon_store_t` (below), written on T_rdp
 *  BEFORE this event is posted, read on the consumer thread after the drain hands this event
 *  over. No extra synchronization is needed for that hand-off beyond the control queue's own
 *  post/drain ordering (adr/0005 §1: the lane is FIFO and its post-side critical section
 *  publishes everything the producer wrote before it) — see `crdpq_icon_store_t`'s own doc
 *  comment for the full argument.
 *
 *  - `hasIconSlot`: 1 iff `iconSlot` names a live store slot for this key. 0 does NOT imply
 *    the order carried no icon — an order whose `WINDOW_ORDER_ICON` bit was absent simply
 *    reuses whatever slot this key already had (NotifyIcon orders are delta-shaped exactly
 *    like window orders, same discipline as `crdpq_window_order_t.ownerWindowId`'s bit gate),
 *    so a 0 here means "no pixels are available for this key at all".
 *  - `iconSkipped`: 1 when an icon WAS present on the wire but this layer refused it —
 *    oversize/unsupported bpp/self-inconsistent `cb*` fields (`crdpq_icon_convert` returned
 *    a failure), store slot exhaustion, or the deferred CACHED_ICON variant (adr/0013 §2).
 *    Fail-open (adr/0008 §4): the consumer falls back to its placeholder and counts this;
 *    it is evidence, not an error to swallow.
 *  - `toolTipPresent` / `toolTip`: `NOTIFY_ICON_STATE_ORDER.toolTip`, a `RAIL_UNICODE_STRING`
 *    transcoded to UTF-8 and truncated through `crdpq_text_set`, exactly like
 *    `crdpq_window_order_t.title`. `toolTipPresent` is 0 when the order's
 *    `WINDOW_ORDER_FIELD_NOTIFY_TIP` bit was absent — a distinct state from "present but
 *    empty", which a delta-merging consumer needs in order to keep a prior tooltip.
 *  - `iconCached`: 1 iff this order's skip cause was specifically the deferred CACHED_ICON
 *    variant (a cacheId/cacheEntry reference, adr/0013 §2) — always accompanied by
 *    `iconSkipped == 1`. Split out (R1 review finding 3, confirmed live 2026-08-31: real
 *    Win11 sessions re-send their own tray icons as cache references as a matter of
 *    course) so a consumer can count deferred-protocol evidence separately from genuine
 *    converter/store failures — the two demand opposite reactions from an acceptance
 *    gate. Appended per adr/0008 §5's append-only rule.
 *  - `versionPresent` / `version`: `NOTIFY_ICON_STATE_ORDER.version` (freerdp/window.h:242),
 *    gated on `WINDOW_ORDER_FIELD_NOTIFY_VERSION` (0x8) exactly like `toolTipPresent` gates
 *    the tooltip — upstream only writes the field inside that bit's `if`
 *    (libfreerdp/core/window.c:948-954), so a 0 with `versionPresent == 0` means "the order
 *    said nothing about the version", never "version 0". OBSERVATION ONLY (adr/0014 §7):
 *    nothing in this project reads it for behavior, it is counted/logged so the precondition
 *    MS-RDPERP attaches to the NIN_ and WM_CONTEXTMENU notify messages stops being invisible
 *    to us. Appended per adr/0008 §5, with the 1-byte flag before the 4-byte value so it
 *    lands in `iconCached`'s existing tail padding instead of adding a second padded word. */
typedef struct {
    uint32_t windowId;
    uint32_t notifyIconId;
    uint8_t hasIconSlot;
    uint8_t iconSlot;
    uint8_t iconSkipped;
    uint8_t toolTipPresent;
    crdpq_text_t toolTip;
    uint8_t iconCached;
    uint8_t versionPresent;
    uint32_t version;
} crdpq_notify_icon_t;

/* adr/0008 §5 / adr/0013 §1: measured (not estimated) with clang/arm64 — same discipline as
 * crdpq_window_order_t's own assert comment above. 12 bytes of scalars + crdpq_text_t's 260
 * (256 + uint16_t length + bool truncated, padded to the text struct's own 2-byte alignment)
 * + iconCached's 1 byte, rounded up to the struct's 4-byte alignment = 276 (was 272 before
 * the R1-finding-3 iconCached append, 8 before this ADR). adr/0014 §7's version observation
 * appends versionPresent (1 byte, taken out of iconCached's existing tail padding at offset
 * 273, costing nothing) + version (4 bytes, aligned to offset 276) = 280 — re-MEASURED, not
 * predicted (adr/0013 §6.2's discipline): the assert below was compiled at the old value
 * first and clang reported "expression evaluates to '280 == 276'", then confirmed by a
 * runtime sizeof/offsetof probe (iconCached@272, versionPresent@273, version@276).
 * Deliberately still well under crdpq_window_order_t's 572, which remains the union's
 * largest member — adr/0013 §1's whole "pixels go to a side store, the event carries a
 * reference" decision exists to keep this event type from becoming that. */
_Static_assert(sizeof(crdpq_notify_icon_t) == 280, "crdpq_notify_icon_t layout changed -- re-measure and audit consumers (adr/0008 §5 / adr/0013 §1 / adr/0014 §7)");

/** adr/0008 §2a: upper bound on `crdpq_monitored_desktop_t.windowIds`. The protocol's own
 *  hard ceiling is 255 (window.c:1068, a `Stream_Read_UINT8` -- genuinely 1 byte, unlike
 *  `CRDPQ_MAX_VISIBILITY_RECTS` above); 96 is 4x the observed max of 24
 *  (samples/phase05-rail-events-2026-08-19). Deliberately NOT 255: adr/0008 §4 shows taking
 *  the full protocol ceiling would make this struct (not crdpq_window_order_t, the
 *  overwhelmingly higher-frequency event) the union's largest member, inflating every
 *  control-lane slot -- including every window order -- for a bound this event type has
 *  never come close to needing. */
#define CRDPQ_MAX_WINDOW_IDS 96

/** MonitoredDesktop. `activeWindowId` is `0xFFFFFFFF` (observed 134/150 times in
 *  samples/phase05-rail-events-2026-08-19) when no window on this desktop currently has
 *  focus -- this layer passes that sentinel through unchanged (it is still a transport,
 *  not a policy layer); a consumer MUST treat it as "no active window", never as a literal
 *  windowId (adr/0008 §0).
 *
 *  `numWindowIds` holds the WIRE value, not `min(numWindowIds, CRDPQ_MAX_WINDOW_IDS)` --
 *  see `crdpq_window_order_t.numVisibilityRects`'s doc comment above for why (the same
 *  asymmetry from `crdpq_text_t`'s truncation convention, deliberate both places). The
 *  `windowIds` array's very existence (not just its populated length) is gated by the
 *  caller on `WINDOW_ORDER_FIELD_DESKTOP_ZORDER` (0x10) -- confirmed against every sample
 *  (adr/0008 §0: every `numWindowIds>0` record carries that bit, every `numWindowIds==0`
 *  record doesn't) and against FreeRDP's own parser (window.c's
 *  update_read_desktop_actively_monitored_order only touches numWindowIds/windowIds inside
 *  that bit's `if`) -- see CRSession.mm's crb_monitored_desktop, the only writer. */
typedef struct {
    uint32_t fieldFlags;
    uint32_t activeWindowId;
    uint32_t numWindowIds;
    bool windowIdsTruncated;
    uint32_t windowIds[CRDPQ_MAX_WINDOW_IDS];
} crdpq_monitored_desktop_t;

/* adr/0008 §5: measured (not estimated) with clang/arm64 -- see crdpq_window_order_t's own
 * assert comment for the same discipline. Up from 12 bytes before this ADR. */
_Static_assert(sizeof(crdpq_monitored_desktop_t) == 400, "crdpq_monitored_desktop_t layout changed -- re-measure and audit consumers (adr/0008 §5)");

/** ServerExecuteResult. */
typedef struct {
    uint32_t flags;
    uint32_t execResult;
    uint32_t rawResult;
    crdpq_text_t exeOrFile;
} crdpq_exec_result_t;

/** ServerHandshakeEx's negotiated posture (adr/0004's HiDef-vs-legacy flags: 126 vs 127
 *  observed in samples/phase05-rail-events-2026-08-19's README). */
typedef struct {
    uint32_t buildNumber;
    uint32_t railHandshakeFlags;
} crdpq_handshake_flags_t;

/** GfxMapSurfaceToWindow AND GfxMapSurfaceToScaledWindow — ONE event type covers both PDUs.
 *  `windowId` is `uint64_t`, faithful to RDPGFX_MAP_SURFACE_TO_WINDOW_PDU's actual wire type
 *  (RailEvent.swift makes the same choice, for the same reason: real window IDs always fit in
 *  32 bits, but the type stays honest about what FreeRDP actually hands us).
 *
 *  WHY ONE KIND, not a second `CRDPQ_EVENT_SURFACE_MAPPED_SCALED` (phase3 M1 U4 ruling):
 *  `RDPGFX_MAP_SURFACE_TO_SCALED_WINDOW_PDU` (rdpgfx.h:396-403) is a strict superset of the
 *  plain PDU (rdpgfx.h:388-394) — identical surfaceId/windowId/mappedWidth/mappedHeight, plus
 *  targetWidth/targetHeight — and the SCALED variant is the one the server was actually
 *  observed to send (live 2026-08-21, real Win11 25H2 host). WHY it picks that variant is an
 *  open question, not the AVC/H264-caps story an earlier version of this comment asserted:
 *  our caps always carry AVC_DISABLED and the observation predates the FFmpeg flip it was
 *  blamed on — falsified in L4's audit (docs/matrix/sample-audit-2026-09.md §7), with the
 *  evidence spelled out at `crb_gfx_map_surface_to_scaled_window` in CRSession.mm and the
 *  question routed to the W2 drill re-record. Only the observation is load-bearing here, and
 *  it is enough: a second event type would have turned every live surface map
 *  into an unhandled event kind for every existing consumer, in exchange for expressing one
 *  optional pair of fields. Appending the fields instead is exactly adr/0008 §5's append-only
 *  rule; the two-case model in `RailEvent.swift:156-160` describes rail-probe's own JSONL
 *  encoder (a separate, file-based format), not this queue, so nothing is inconsistent.
 *
 *  `targetWidth`/`targetHeight` — SENTINEL: **(0, 0) means "no target hint accompanied this
 *  map"**, i.e. the plain PDU, whose wire form has no such fields at all. The argument for it
 *  is the usable-hint one below, and that argument stands alone. (ANALOGY ONLY, not a governing
 *  rule for this site: adr/0008 §5's replay-compat rule ① reads an absent appended field as
 *  0/false, so absent-as-zero is a shape this project already thinks in. That rule is scoped to
 *  the JSONL *decoder*'s obligation toward samples recorded before a field existed — the ADR
 *  says in the same breath that replay compatibility is the decoder's job, not the memory
 *  layout's — and this struct has no decoder path at all today. Protocol-variant absence is not
 *  stale-recording absence; the resemblance is real but it licenses nothing here.)
 *
 *  Zero can never be a *usable* hint: upstream's own plain-variant handler models "no separate
 *  target" as `outputTarget* = mapped*` (gdi/gfx.c:1937-1938), never as 0, and a genuine 0
 *  would make gdi/gfx.c:204-205's `sx = outputTargetWidth / mappedWidth` a zero scale factor —
 *  a zero-area, invisible surface. Note the precise claim: nothing in the protocol FORBIDS a
 *  server sending a literal 0x0 target, and FreeRDP's receive path validates neither field
 *  (channels/rdpgfx/client/rdpgfx_main.c:2031-2039 is a length check and six `Stream_Read_*`
 *  calls), so a nonconforming server's 0x0 scaled map does alias to the plain form here. That
 *  aliasing is harmless rather than lossy — a consumer would have to discard a zero-area hint
 *  anyway — but it is an aliasing, not an impossibility.
 *
 *  A consumer must therefore check BOTH members against 0 before using either, and a consumer
 *  that wants upstream's *effective* target must apply upstream's own `target := mapped`
 *  fallback itself. This layer deliberately does NOT pre-apply it: it is a transport, and
 *  collapsing "the wire carried no hint" into "the hint equalled mapped" would destroy the
 *  single distinction F2 exists to measure.
 *
 *  MEASUREMENT ONLY in M1 (phase3 F2): nothing may branch rendering, window sizing, or
 *  coordinate conversion on these two fields yet — they are promoted so the difference becomes
 *  *observable*, not actionable. To date `target` has only ever been observed equal to the
 *  64-aligned surface allocation size while the NSWindow's own frame already defines the
 *  on-screen size, so no consumer has anything to gain from it. REVISIT AT W3, the wave that
 *  owns the DPI / `DesktopScaleFactor` posture: the first observed `target != window-rect` case
 *  is that wave's input, and this paragraph is its marker. */
typedef struct {
    uint32_t surfaceId;
    uint64_t windowId;
    uint32_t mappedWidth;
    uint32_t mappedHeight;
    /* Appended per adr/0008 §5 (new fields append; absent == 0/false). */
    uint32_t targetWidth;
    uint32_t targetHeight;
} crdpq_surface_mapped_t;

/* adr/0008 §5's measure-don't-estimate discipline, applied to this struct for the first time
 * (it had no assert before phase3 M1 — it had also never grown before). Needed on its own
 * because `crdpq_event_payload_t`'s union-level assert structurally CANNOT see this member: at
 * 32 bytes it is nowhere near `crdpq_window_order_t`'s 572, so a reshaping here that changes
 * this struct's SIZE would still leave the union's size untouched.
 *
 * WHAT THIS ASSERT DOES AND DOES NOT CATCH — measured by mutating this struct and re-running
 * the suite, not reasoned about (r1 review finding I-1: the previous wording here named three
 * mutations as though this assert caught them; it catches none of the three, because all three
 * leave sizeof at exactly 32). It catches whole-struct SIZE drift, and nothing else. The other
 * two failure modes are covered in `CRDPQueueTests.swift`'s layout suite, which pins every
 * member's width AND every member's offset for this struct:
 *   - narrowing `target*` to uint16_t   -> sizeof still 32 (bytes absorbed by tail padding);
 *                                          caught by the width pins.
 *   - widening `surfaceId` to uint64_t  -> sizeof still 32, every offset unchanged (it fits the
 *                                          padding that already followed it); caught ONLY by
 *                                          that member's width pin. Not hypothetical: the wire
 *                                          field is UINT16 (rdpgfx.h:390), so a future
 *                                          "make the type honest" edit is a live possibility.
 *   - reordering `target*` ahead of `mapped*` -> sizeof, alignment and every member's width all
 *                                          unchanged; caught ONLY by the offset pins.
 * Keep all three kinds in step when this struct changes; any one of them alone is blind to what
 * the other two see.
 *
 * 32 was MEASURED with clang/arm64, not predicted: this assert was first compiled at the
 * pre-growth value and clang reported "expression evaluates to '32 == 24'", then a runtime
 * sizeof/offsetof probe confirmed the layout field by field (surfaceId@0, 4B of alignment
 * padding before windowId@8, mappedWidth@16, mappedHeight@20, targetWidth@24,
 * targetHeight@28 — the two new fields land in what was already the struct's 8-byte-alignment
 * footprint, which is why the union above does not move). That probe is no longer one-shot: the
 * offset pins hold exactly those numbers permanently. */
_Static_assert(sizeof(crdpq_surface_mapped_t) == 32, "crdpq_surface_mapped_t layout changed -- re-measure and audit consumers (adr/0008 §5 / phase3 M1 F2)");

/** A lightweight "a frame became ready" notification carried on the *control* lane, so a
 *  consumer draining window orders in FIFO order can also observe frame-readiness
 *  interleaved with them without separately polling crdpq_frames every drain cycle. The
 *  actual frame pixels / generation-of-record live in crdpq_frames (last-writer-wins,
 *  below) — this is just a doorbell, not a copy of the frame state. */
typedef struct {
    uint32_t surfaceId;
} crdpq_frame_ready_t;

/** ServerLocalMoveSize <- RAIL_LOCALMOVESIZE_ORDER (client/rail.h:453-460). adr/0008 §0's
 *  caveat: this shape was NEVER observed in any of the six
 *  samples/phase05-rail-events-2026-08-19 captures (the probe never dragged/resized a
 *  window) -- verified only against the header and MS-RDPERP, not real wire bytes. W3's
 *  first live LocalMoveSize must be treated as a verification event for this struct, not
 *  an already-proven assumption.
 *
 *  `posX`/`posY` are `INT16` on the wire; widened to `int32_t` here purely for uniformity
 *  with every other offset/position field this header exposes as `int32_t` (adr/0008 §1) --
 *  this is NOT a claim that the upstream INT16 narrowing was wrong or needs fixing; FreeRDP
 *  has already parsed the value by the time it reaches this struct. Observed values (where
 *  analogous position fields exist elsewhere) top out around 2580, nowhere near either
 *  type's range limit. */
typedef struct {
    uint32_t windowId;
    /* Upstream is `BOOL` (a typedef for `int`) -- the writer MUST normalize with `!= 0`,
     * never memcpy/assign the raw int bit pattern into this `bool` (adr/0008 §1). */
    bool isMoveSizeStart;
    uint16_t moveSizeType;
    int32_t posX;
    int32_t posY;
} crdpq_local_move_size_t;
_Static_assert(sizeof(crdpq_local_move_size_t) == 16, "crdpq_local_move_size_t layout changed -- re-measure and audit consumers (adr/0008 §5)");

/** ServerMinMaxInfo <- RAIL_MINMAXINFO_ORDER (client/rail.h:440-451). Same INT16->int32_t
 *  widening rationale as `crdpq_local_move_size_t.posX/posY` above applies to all eight
 *  fields here. */
typedef struct {
    uint32_t windowId;
    int32_t maxWidth;
    int32_t maxHeight;
    int32_t maxPosX;
    int32_t maxPosY;
    int32_t minTrackWidth;
    int32_t minTrackHeight;
    int32_t maxTrackWidth;
    int32_t maxTrackHeight;
} crdpq_min_max_info_t;
_Static_assert(sizeof(crdpq_min_max_info_t) == 36, "crdpq_min_max_info_t layout changed -- re-measure and audit consumers (adr/0008 §5)");

/** ServerZOrderSync <- RAIL_ZORDER_SYNC (rail.h:495-498). adr/0008 §1: despite the name,
 *  this carries NO Z-order array -- it's a boundary marker ("a sync just happened"), not a
 *  data payload. `windowIdMarker` is opaque; do not treat it as a real windowId. The actual
 *  ordered array is `crdpq_monitored_desktop_t.windowIds` (§2a) -- a consumer of this event
 *  should re-read the most recently observed MonitoredDesktop event's array, not wait for
 *  this one to carry data it never will. */
typedef struct {
    uint32_t windowIdMarker;
} crdpq_zorder_sync_t;
_Static_assert(sizeof(crdpq_zorder_sync_t) == 4, "crdpq_zorder_sync_t layout changed -- re-measure and audit consumers (adr/0008 §5)");

typedef union {
    crdpq_window_order_t windowOrder;   /* WINDOW_CREATE, WINDOW_UPDATE */
    crdpq_window_id_t windowId;         /* WINDOW_DELETE, WINDOW_ICON */
    crdpq_notify_icon_t notifyIcon;     /* NOTIFY_ICON_CREATE/UPDATE/DELETE */
    crdpq_monitored_desktop_t monitoredDesktop;
    crdpq_exec_result_t execResult;
    crdpq_handshake_flags_t handshakeFlags;
    crdpq_surface_mapped_t surfaceMapped; /* SURFACE_MAPPED — both the plain and the scaled PDU */
    crdpq_frame_ready_t frameReady;
    crdpq_local_move_size_t localMoveSize;   /* CRDPQ_EVENT_LOCAL_MOVE_SIZE */
    crdpq_min_max_info_t minMaxInfo;         /* CRDPQ_EVENT_MIN_MAX_INFO */
    crdpq_zorder_sync_t zorderSync;          /* CRDPQ_EVENT_ZORDER_SYNC */
    /* CRDPQ_EVENT_DISCONNECTED carries no payload — the envelope's `generation` field
     * (the generation *as of the disconnect*, per adr/0005 §4 step 3: "post
     * DISCONNECTED(gen)") is everything a consumer needs. */
} crdpq_event_payload_t;

/* adr/0008 §5: measured (not estimated) with clang/arm64. `crdpq_window_order_t` (572,
 * adr/0010 §1) is still this union's largest member post-ADR (adr/0008 §4's deliberate
 * "take 96, not 255" bound choice for CRDPQ_MAX_WINDOW_IDS exists specifically to keep it
 * that way, and adr/0013 §1's side-store decision keeps the freshly-grown
 * `crdpq_notify_icon_t` at 280 — still under half of it — for the same reason); the union's
 * own alignment is 8 (from `crdpq_surface_mapped_t`'s `uint64_t windowId`, not from
 * `crdpq_window_order_t`), so 572 pads up to the next multiple of 8 = 576. Unchanged by
 * adr/0013 (which grew the notify-icon member to 276) or by adr/0014 §7 (280, re-measured
 * at both steps — see that struct's own assert comment); up from 568 before adr/0010.
 *
 * ALSO UNCHANGED by phase3 M1 F2's `target*` growth of `crdpq_surface_mapped_t` (24 -> 32) —
 * and that "unchanged" is a MEASUREMENT, not the prediction it looks like (adr/0008 §5 /
 * adr/0013 §6.2: the sizeof discipline is a real gate, and "the union's largest member didn't
 * move, so nothing moved" is exactly the reasoning that discipline exists to refuse). Both
 * halves were re-run after the growth: clang's own diagnostic on the member's assert reported
 * '32 == 24', and a runtime sizeof probe then read this union back at 576 and `CrdpEvent` at
 * 584. 32 is still an order of magnitude under `crdpq_window_order_t`'s 572, so the union's
 * size is still set by that member and its 8-byte alignment, neither of which this growth
 * touched. Consumer audit at the same commit: the ONLY readers of this union member are
 * `CRDPEventFromCrdpEvent` (CRSession.mm) and the two GFX callbacks that write it — every
 * other consumer (RemoteWindowRegistry, RemoteWindow, window-smoke, bridge-smoke) reaches it
 * through `CRDPEvent`'s ObjC properties and cannot see this struct at all; `RailEvent.swift`
 * decodes rail-probe JSONL and never touches this type. No consumer indexes, memcpy's a fixed
 * width out of, or serializes this struct, so none needed changing beyond the promotion
 * itself. */
_Static_assert(sizeof(crdpq_event_payload_t) == 576, "crdpq_event_payload_t layout changed -- re-measure and audit consumers (adr/0008 §5 / adr/0010 §1)");

/** One control-lane event. POD, no pointers, safe to memcpy — this is the whole point
 *  (adr/0005 §1/§3). `generation` is stamped by crdpq_post itself at enqueue time from
 *  the queue's current generation counter (adr/0005 §3: "the producer copies it in at post
 *  time") —
 *  whatever the caller puts in this field before calling crdpq_post is ignored and
 *  overwritten; callers only need to set `type` and the relevant `payload` member. */
typedef struct {
    crdpq_event_type_t type;
    crdpq_generation_t generation;
    crdpq_event_payload_t payload;
} CrdpEvent;

/* adr/0008 §5: measured (not estimated) with clang/arm64. type(4)+generation(4)+payload(576)
 * = 584, already an exact multiple of the struct's own 8-byte alignment, so no further
 * padding. Up from 576 before this ADR. */
_Static_assert(sizeof(CrdpEvent) == 584, "CrdpEvent layout changed -- re-measure and audit consumers (adr/0008 §5 / adr/0010 §1)");

typedef struct crdpq_control crdpq_control_t;

/** Called (at most once per drain cycle — see crdpq_post) to ask the consumer to run
 *  crdpq_drain soon. Production: wraps `dispatch_async(dispatch_get_main_queue(), ...)`.
 *  Tests: a manual pump, or a counter. Called OUTSIDE crdpq_control's internal lock. */
typedef void (*crdpq_schedule_drain_fn)(void* ctx);

/** `schedule_drain` may be NULL (useful for tests that only care about post/drain
 *  ordering and poll manually without ever needing a wakeup). Equivalent to
 *  crdpq_control_create_with_max_capacity with a 65536-event ceiling. */
crdpq_control_t* crdpq_control_create(crdpq_schedule_drain_fn schedule_drain, void* schedule_drain_ctx);
/** Same as crdpq_control_create, but with an explicit ceiling (M4 in the W3 review) on
 *  the back buffer's capacity instead of the default 65536 events — adr/0005 §7's
 *  "dropped-frame count alert" mitigation, extended from the frame lane to this one: once a
 *  back buffer's capacity reaches `max_capacity` and is also full, further posts are
 *  rejected (counted in crdpq_dropped_count) rather than growing unbounded.
 *  `max_capacity` below the initial 256-event capacity is clamped up to 256 (a ceiling
 *  that can never bind below the buffer's own floor is meaningless). */
crdpq_control_t* crdpq_control_create_with_max_capacity(crdpq_schedule_drain_fn schedule_drain, void* schedule_drain_ctx, size_t max_capacity);
void crdpq_control_destroy(crdpq_control_t* q);

/** Atomically increments and returns the queue's generation counter (adr/0005 §4 step 5:
 *  "generation +1"). */
crdpq_generation_t crdpq_generation_bump(crdpq_control_t* q);
/** Atomically reads the current generation, for a consumer's own drain-entry comparison
 *  (adr/0005 §3: "provide crdpq_current_generation(q) for comparison"). */
crdpq_generation_t crdpq_current_generation(const crdpq_control_t* q);

/** Deep-copies `*ev` into the queue's back buffer under lock, stamping `generation`.
 *  Returns false (without copying) if the queue has been sealed (crdpq_seal, counted in
 *  crdpq_seal_rejected_count), if the back buffer is already at its configured capacity
 *  ceiling and full (M4 — see crdpq_control_create_with_max_capacity, counted in
 *  crdpq_dropped_count), or if the buffer failed to grow under memory pressure (also
 *  counted in crdpq_dropped_count) —
 *  either way, the event is dropped, never partially enqueued. The seal check happens
 *  inside the same critical section as the enqueue itself, checked as late as possible
 *  (M1 in the W3 review): once crdpq_seal() has returned on any thread, every crdpq_post
 *  call whose actual buffer mutation is still pending at that point is guaranteed to see
 *  it and reject, closing the check-then-lock race an earlier version of this function
 *  had. Safe from any thread, any number of threads concurrently. */
bool crdpq_post(crdpq_control_t* q, const CrdpEvent* ev);

typedef void (*crdpq_visitor_fn)(const CrdpEvent* ev, void* vctx);

/** Swaps the front/back buffers under lock, clears the "drain scheduled" flag, then
 *  (outside the lock) calls `visitor` once per event in strict FIFO post order. Returns
 *  the number of events delivered. Single-consumer only — see the threading contract at
 *  the top of this header. */
size_t crdpq_drain(crdpq_control_t* q, crdpq_visitor_fn visitor, void* vctx);

/** After this call, crdpq_post always returns false without enqueueing (adr/0005 §3's
 *  "reject sends after shutdown" via the queue itself, mirrored on the outbound side too). Idempotent. */
void crdpq_seal(crdpq_control_t* q);
bool crdpq_is_sealed(const crdpq_control_t* q);

/** Largest `count` either buffer has reached, across the queue's lifetime. */
size_t crdpq_high_water_mark(const crdpq_control_t* q);

/** Number of crdpq_post calls rejected because the back buffer had reached its configured
 *  capacity ceiling and couldn't grow further (M4), or because growth failed under memory
 *  pressure. Does NOT count posts rejected for having already been sealed (crdpq_seal) —
 *  that's expected post-shutdown behavior, not an overflow condition worth alerting on.
 *  Monotonically increasing; adr/0005 §7's "dropped-frame count alert" mitigation pattern. */
size_t crdpq_dropped_count(const crdpq_control_t* q);

/** Number of crdpq_post calls rejected because the queue was already sealed (crdpq_seal) —
 *  exactly the cause crdpq_dropped_count above excludes, and nothing else: a post rejected
 *  for being at-cap-and-full or for a failed growth is counted THERE, never here. The two
 *  counters therefore partition the rejections completely — every crdpq_post returning
 *  false bumps exactly one of them — which is what makes "sealed, so this is expected
 *  shutdown behavior" distinguishable from "overflowing, so alert" without either counter
 *  having to be interpreted against the other. Monotonically increasing, cumulative for
 *  this queue instance's lifetime.
 *
 *  The lane's counterpart to crdpq_outbound_seal_rejected_count. Unlike that one it has no
 *  bridge-layer pass-through and, today, no production writer either: CRSession calls
 *  crdpq_outbound_seal during teardown but never crdpq_seal — the control lane is simply
 *  destroyed. This exists for lane symmetry (every other counter on one lane has a twin on
 *  the other) and so that the seal contract is testable from both directions, not for an
 *  existing reader; the day the control lane does get sealed, the counter is already here. */
uint64_t crdpq_seal_rejected_count(const crdpq_control_t* q);

/* ==================================================================================== *
 * Notify-icon pixel side-store + DIB->RGBA conversion (adr/0013) — the fourth primitive,
 * and the only one that is not itself a lane: it is the bounded side storage the control
 * lane's `crdpq_notify_icon_t.iconSlot` refers into (adr/0013 §1). Pixels never ride in a
 * control slot; the event carries a reference, exactly like the frames lane keeps GFX
 * pixels out of the control lane.
 * ==================================================================================== */

/** A fixed table of `CRDPQ_ICON_SLOTS` premultiplied-RGBA8888 icon buffers, keyed by
 *  `(windowId, notifyIconId)` — one allocation, ~144KB, no growth path (adr/0013 §1).
 *
 *  DELIBERATELY A PLAIN pthread_mutex, NOT the frames lane's lock-free/seqlock-shaped
 *  design: NotifyIcon orders arrive at a frequency indistinguishable from zero (a handful
 *  per session, when a tray icon is created or its bitmap changes), so there is no lock
 *  contention to design around, and the extra complexity of a lock-free publication
 *  protocol would be pure liability here. The frames lane earns its complexity from a
 *  per-frame, per-surface write rate this store will never see.
 *
 *  THREADING: written on T_rdp from inside the NotifyIcon callback, BEFORE the
 *  corresponding control event is enqueued; read on the control lane's consumer thread
 *  (T_main) AFTER that event has been drained. Nothing extra is needed to make the write
 *  visible to the reader: the control queue's own post-side critical section and the
 *  drain-side swap are the happens-before edge (adr/0005 §1 — the lane is FIFO and
 *  single-consumer by contract), so "written before post" plus "read after drain" is
 *  already a totally ordered pair. The mutex here exists only to make the store's own
 *  slot table internally consistent when a put/remove races an unrelated copy-out, not to
 *  order the write against the read. */
typedef struct crdpq_icon_store crdpq_icon_store_t;

/** Returns NULL only on allocation failure or if the mutex can't be initialized. */
crdpq_icon_store_t* crdpq_icon_store_create(void);
void crdpq_icon_store_destroy(crdpq_icon_store_t* s);

/** Releases every slot, leaving an empty table ready for the next session (the
 *  session-teardown / generation-rollover path — CRSession's `-shutdownAndWait` calls this
 *  exactly where it already calls `crsurface_table_clear`). Does NOT reset
 *  `crdpq_icon_store_overflow_count`: that counter is cumulative for the store's whole
 *  lifetime, matching the "counters survive reconnects" precedent every other diagnostic
 *  counter in this header already sets (crdpq_dropped_count et al). */
void crdpq_icon_store_clear(crdpq_icon_store_t* s);

/** Upsert by key: an existing slot for `(windowId, notifyIconId)` is overwritten in place
 *  (a tray icon whose bitmap changes must not consume a second slot), otherwise the first
 *  free slot is claimed. `rgba` must hold `width * height * 4` bytes of premultiplied
 *  RGBA8888, top-down — i.e. exactly what `crdpq_icon_convert` writes.
 *
 *  Returns false (writing nothing, leaving `*out_slot` untouched) when `width`/`height` are
 *  0 or exceed `CRDPQ_ICON_MAX_DIM`, or when every slot is already taken by another key. The
 *  slot-exhaustion case additionally increments `crdpq_icon_store_overflow_count` — adr/0013
 *  §1's fail-open contract (adr/0008 §4): the caller sets `iconSkipped`, the consumer shows
 *  its placeholder, and the counter is the evidence that the bound was reached. */
bool crdpq_icon_store_put(crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId,
                          const uint8_t* rgba, uint32_t width, uint32_t height, uint8_t* out_slot);

/** Finds the live slot for `(windowId, notifyIconId)` without touching it. The bridge uses
 *  this for a NotifyIconUpdate whose `WINDOW_ORDER_ICON` bit is absent: MS-RDPERP notify-icon
 *  orders are delta-shaped, so "no icon field this time" means "keep the icon you have", not
 *  "this icon has no pixels" (same bit-gating discipline as adr/0008 §3's ownerWindowId). */
bool crdpq_icon_store_lookup(const crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId,
                             uint8_t* out_slot);

/** Frees the slot held by `(windowId, notifyIconId)`, if any (NotifyIconDelete). Returns
 *  whether a slot was actually released — an unknown-delete is tolerated, matching
 *  `TrayModel.delete`'s own tolerance on the Swift side. */
bool crdpq_icon_store_remove(crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId);

/** Copies slot `slot`'s pixels out into caller-owned memory under the store's lock, so the
 *  consumer's copy has zero lifetime coupling to the slot (adr/0013 §3: the Swift layer owns
 *  its `NSData` outright and never observes a later overwrite of the same slot). Returns
 *  false if `slot` is out of range, not currently in use, or `dst_capacity` is smaller than
 *  the slot's `width * height * 4`.
 *
 *  `windowId`/`notifyIconId` are the key the CALLER's event claims this slot belongs to, and
 *  the copy is refused if the slot no longer holds it. That check is not redundant: an event
 *  is a reference, and the store is state, so the reference is resolved at DRAIN time, not at
 *  post time. Between the two, a NotifyIconDelete could have freed this slot and a different
 *  icon's create could have claimed it — draining the older event would then hand the
 *  consumer another icon's pixels. Refusing instead degrades that (very narrow) race to the
 *  ordinary placeholder path, fail-open (adr/0008 §4).
 *
 *  Not covered, and deliberately so: two orders for the SAME key posted before either is
 *  drained resolve to the newer pixels for both. That is last-writer-wins on a per-key state
 *  slot — the identical semantics the frames lane already documents for GFX frames ("a
 *  surface published twice before being consumed once is not two frames, it's one frame") —
 *  and the consumer's own second drain immediately reasserts the same end state. */
bool crdpq_icon_store_copy_slot(const crdpq_icon_store_t* s, uint8_t slot, uint32_t windowId,
                                uint32_t notifyIconId, uint8_t* dst, size_t dst_capacity,
                                uint32_t* out_width, uint32_t* out_height, size_t* out_bytes);

/** Number of `crdpq_icon_store_put` calls rejected because every slot was already held by a
 *  different key — the same dropped-count-for-alerting shape as `crdpq_dropped_count` /
 *  `crdpq_frames_dropped_count` on the lanes (adr/0005 §7). Monotonically increasing, never
 *  reset by `crdpq_icon_store_clear`. */
size_t crdpq_icon_store_overflow_count(const crdpq_icon_store_t* s);

/** Slots currently in use. Diagnostics/tests only. */
size_t crdpq_icon_store_live_count(const crdpq_icon_store_t* s);

/** Why `crdpq_icon_convert` refused an icon. Every non-OK value maps to
 *  `crdpq_notify_icon_t.iconSkipped = 1` at the caller; the distinction exists for logging
 *  and for the offline test matrix, not for any behavioral branch downstream. */
typedef enum {
    CRDPQ_ICON_OK = 0,
    /** `width`/`height` is 0, or exceeds `CRDPQ_ICON_MAX_DIM`. */
    CRDPQ_ICON_ERR_DIMENSIONS,
    /** `bpp` is not one of {1, 4, 8, 16, 24, 32}. */
    CRDPQ_ICON_ERR_BPP,
    /** Indexed bpp (1/4/8) with a missing or self-inconsistent palette: `cbColorTable` zero,
     *  not a multiple of 4 (DIB palettes are `RGBQUAD` arrays), or describing more than 256
     *  entries. Same three checks FreeRDP's own `fill_gdi_palette_for_icon` applies. */
    CRDPQ_ICON_ERR_COLOR_TABLE,
    /** `bitsColor` is NULL, or `cbBitsColor` is too small to hold `height` scanlines at this
     *  `bpp`/`width` under EITHER scanline-stride convention (see `crdpq_icon_convert`). */
    CRDPQ_ICON_ERR_BITS_COLOR,
    /** `cbBitsMask` is non-zero but `bitsMask` is NULL, or `cbBitsMask` is too small to hold
     *  `height` 1-bit AND-mask scanlines. */
    CRDPQ_ICON_ERR_BITS_MASK,
    /** `dst` is NULL or `dst_capacity` is under `width * height * 4`. A caller bug, not
     *  server input — kept distinct from the wire-data rejections above for that reason. */
    CRDPQ_ICON_ERR_DEST,
} crdpq_icon_convert_result_t;

/** Converts one wire `ICON_INFO` (freerdp/window.h:165-178 — this parameter list is that
 *  struct's field set verbatim, minus the two cache identifiers) into premultiplied
 *  RGBA8888, written top-down and tightly packed at `width * 4` bytes per row into `dst`.
 *  Pure function: no allocation, no globals, no FreeRDP types — which is exactly why it
 *  lives in this target and can be fed synthetic DIBs straight from the Swift test suite
 *  (adr/0013 §2).
 *
 *  MUST NOT read out of bounds for ANY combination of field values, including deliberately
 *  malicious ones: FreeRDP's own parser (libfreerdp/core/window.c's `update_read_icon_info`)
 *  validates only `1 <= bpp <= 32` and that the stream actually held `cbBitsMask` /
 *  `cbColorTable` / `cbBitsColor` bytes — it never cross-checks any of those three against
 *  `bpp`/`width`/`height`, so every such check is this function's job. All of them run
 *  before the first pixel is touched.
 *
 *  Layout facts, each verified against the vendored source rather than assumed:
 *  - Rows are BOTTOM-UP for both the color bitmap and the AND mask
 *    (libfreerdp/codec/color.c's `freerdp_image_copy_from_icon_data` passes
 *    `FREERDP_FLIP_VERTICAL` for the color plane and indexes the mask at
 *    `stride * (height - 1 - y)`).
 *  - The AND mask's scanline stride is 4-byte aligned (same function:
 *    `round_up(div_ceil(width, 8), 4)`).
 *  - The color plane's stride is NOT stated consistently upstream: that same function feeds
 *    `freerdp_image_copy_no_overlap` a `nSrcStep` of 0, which defaults to an UNPADDED
 *    `width * bytesPerPixel` (color.c:1040), while the DIB format the data actually is
 *    pads every scanline to 4 bytes. For the icon sizes that exist in practice
 *    (16/32/48-square at 8/16/24/32bpp) the two agree exactly, so neither reading has ever
 *    been exercised against the other. Rather than pick one and mis-decode the other, this
 *    function infers: it uses the 4-byte-padded stride when `cbBitsColor` is large enough
 *    for it, and falls back to the unpadded stride when it is not. Both paths are bounded by
 *    the `cbBitsColor` check, so neither can overread.
 *  - 16bpp is RGB555, not RGB565 (color.c maps icon bpp 16 to `PIXEL_FORMAT_RGB15`), with
 *    5->8 channel expansion `(c << 3) | (c >> 2)` — bit-identical to FreeRDP's own
 *    `(c << 3) + c / 4`.
 *  - 32bpp source bytes are B,G,R,A and palette entries are `RGBQUAD` B,G,R,X in memory
 *    (FreeRDP's `PIXEL_FORMAT_BGRA32`/`PIXEL_FORMAT_BGRX32` under its documented
 *    "format names give byte position in memory" convention).
 *  - 24bpp source bytes are taken as B,G,R here — the Windows DIB `RGBTRIPLE` order, which
 *    is also what FreeRDP's own pointer-data path uses for the same 24bpp shape
 *    (`PIXEL_FORMAT_BGR24`, color.c:717). Its icon path uses `PIXEL_FORMAT_RGB24` instead,
 *    which contradicts both its sibling and every other channel order in the same switch;
 *    that is treated here as an upstream inconsistency, not as evidence about the wire.
 *  - 1bpp and 4bpp are supported here; FreeRDP's own icon converter refuses them outright
 *    ("1bpp and 4bpp icons are not supported", color.c:438).
 *
 *  Alpha (adr/0013 §2):
 *  - 32bpp uses its own alpha plane, UNLESS that plane is entirely zero — a very common
 *    shape in real icons, and one that would otherwise render a fully invisible tray item —
 *    in which case it falls back to the AND mask, or to fully opaque if no mask was sent.
 *  - <=24bpp derives 1-bit alpha from the AND mask (set bit = transparent, matching
 *    `freerdp_image_copy_from_icon_data`), or is fully opaque when no mask was sent.
 *  - An indexed pixel whose palette index is past `cbColorTable / 4` is written fully
 *    transparent rather than rejecting the whole icon: per-pixel fail-open (adr/0008 §4),
 *    since a short palette costs a few pixels, not the icon. */
crdpq_icon_convert_result_t crdpq_icon_convert(uint32_t bpp, uint32_t width, uint32_t height,
                                               uint32_t cbColorTable, uint32_t cbBitsMask,
                                               uint32_t cbBitsColor, const uint8_t* bitsColor,
                                               const uint8_t* colorTable, const uint8_t* bitsMask,
                                               uint8_t* dst, size_t dst_capacity);

/* ==================================================================================== *
 * Frame lane (crdpq_frames) — GFX frames are state, not events: last-writer-wins per
 * surfaceId, never queued (adr/0005 §1). A sparse open-addressed table keyed by
 * surfaceId, since observed surfaceId values are small and dense in practice but the
 * table must not assume that.
 * ==================================================================================== */

typedef struct crdpq_frames crdpq_frames_t;

/** Same semantics/contract as crdpq_schedule_drain_fn — a separate function pointer
 *  because crdpq_frames is a wholly separate structure/instance from crdpq_control (the
 *  two lanes' "wake the consumer" bookkeeping is independent, even though a real CRBridge
 *  will likely wire both to the same dispatch_async(main, ...) underneath). */
typedef void (*crdpq_frames_schedule_drain_fn)(void* ctx);

crdpq_frames_t* crdpq_frames_create(crdpq_frames_schedule_drain_fn schedule_drain, void* schedule_drain_ctx);
void crdpq_frames_destroy(crdpq_frames_t* f);

/** Last-writer-wins: marks `surfaceId`'s slot dirty with `generation`, overwriting
 *  whatever generation was there before if it was already dirty (a surface that gets
 *  mapped/remapped twice before being consumed once is not two frames, it's one frame —
 *  adr/0005 §1: "a GFX frame is state, not an event"). Grows the table (rehashing) if needed. If no
 *  drain was already pending for this table, schedules one exactly once, mirroring
 *  crdpq_post's coalescing. Safe from any thread.
 *
 *  Returns false (without writing anything) if the table is completely full of *other*
 *  surfaceIds and growth also fails — this can only happen under sustained memory
 *  pressure (H1 in the W3 review; ASan-confirmed heap-out-of-bounds before this fix).
 *  Updates to an already-present surfaceId always succeed regardless of table fullness or
 *  growth outcome, per adr/0005 §7's "surfaceId merges are naturally bounded" mitigation: a rejected
 *  *new* surfaceId is counted in crdpq_frames_dropped_count for alerting, the same
 *  dropped-count-alert pattern that row already calls for. */
bool crdpq_frame_publish(crdpq_frames_t* f, uint32_t surfaceId, crdpq_generation_t generation);

typedef void (*crdpq_frame_visitor_fn)(uint32_t surfaceId, crdpq_generation_t generation, void* vctx);

/** Snapshots every currently-dirty slot (surfaceId, generation) under lock, clears their
 *  dirty flags (last-writer-wins state itself — the surfaceId->generation mapping —
 *  is *not* cleared, only the "there's unconsumed news" flag), then calls `visitor` once
 *  per dirty slot outside the lock. Iteration order is unspecified (this is not a FIFO —
 *  there is no "order" for state, only current values). Returns the number of slots
 *  visited. Single-consumer only. */
size_t crdpq_frame_consume(crdpq_frames_t* f, crdpq_frame_visitor_fn visitor, void* vctx);

/** Reads a surface's current generation without consuming/clearing anything — a
 *  side-effect-free peek, mainly for tests asserting last-writer-wins end state. Returns
 *  false via `out_found` if `surfaceId` has never been published (this includes the H1
 *  edge case where the table is completely full and doesn't contain `surfaceId` at all —
 *  treated as not-found, same as an ordinary miss). */
crdpq_generation_t crdpq_frame_peek(const crdpq_frames_t* f, uint32_t surfaceId, bool* out_found);

/** Number of crdpq_frame_publish calls rejected because the table was completely full of
 *  other surfaceIds and growth also failed (H1). Monotonically increasing, same
 *  dropped-count-for-alerting shape as crdpq_dropped_count/crdpq_outbound_dropped_count on
 *  the other two lanes — see adr/0005 §7's "dropped-frame count alert" mitigation. */
size_t crdpq_frames_dropped_count(const crdpq_frames_t* f);

/* ==================================================================================== *
 * Outbound command lane (crdpq_outbound) — the reverse direction: T_main -> T_rdp.
 * adr/0005 §3: "ClientExecute/ClientWindowMove/ClientActivate/input are never called
 * directly from T_main" —
 * everything here is POD-copied across, same discipline as the control lane, just
 * flowing the other way and waking a different consumer (T_rdp's own event-handle wait,
 * not dispatch_async(main, ...)).
 * ==================================================================================== */

typedef enum {
    CRDPQ_CMD_EXECUTE = 0,
    CRDPQ_CMD_ACTIVATE,
    CRDPQ_CMD_WINDOW_MOVE,
    CRDPQ_CMD_SYS_COMMAND,
    CRDPQ_CMD_INPUT,
    /** adr/0014 §2: ClientNotifyEvent, the outbound tray-click lane. Appended at the END
     *  (adr/0008 §5's append-only rule, applied to this enum exactly as it is to the
     *  inbound one) so no existing command type's numeric value moves. */
    CRDPQ_CMD_NOTIFY_EVENT,
} crdpq_command_type_t;

/** ClientExecute (launching/re-launching the RemoteApp program). */
typedef struct {
    crdpq_text_t program;
} crdpq_cmd_execute_t;

/** ClientActivate. */
typedef struct {
    uint32_t windowId;
    bool enabled;
} crdpq_cmd_activate_t;

/** ClientWindowMove. */
typedef struct {
    uint32_t windowId;
    int32_t left;
    int32_t top;
    int32_t right;
    int32_t bottom;
} crdpq_cmd_window_move_t;

/** ClientSystemCommand (SC_MINIMIZE/SC_MAXIMIZE/SC_CLOSE/... on a remote window). */
typedef struct {
    uint32_t windowId;
    uint16_t command;
} crdpq_cmd_sys_command_t;

/** ClientNotifyEvent (adr/0014 §2): one notify-message PDU addressed at a tray icon, i.e.
 *  `RAIL_NOTIFY_EVENT_ORDER` (freerdp/rail.h:433-438) field for field. `message` is a
 *  `uint32_t`, NOT the `uint16_t` its `crdpq_cmd_sys_command_t` sibling above uses — the
 *  wire field really is UINT32 here (rail.h:437) and UINT16 there (rail.h:430); the two
 *  commands look alike enough that narrowing this by reflex is the obvious way to corrupt
 *  a `NIN_*` (>= 0x400) value later, so the width difference is deliberate and load-bearing.
 *  v1 sends only WM_LBUTTONDOWN (0x201) then WM_LBUTTONUP (0x202) as two independent posts
 *  (the lane is FIFO, so their order is the queue's guarantee, not a per-command field). */
typedef struct {
    uint32_t windowId;
    uint32_t notifyIconId;
    uint32_t message;
} crdpq_cmd_notify_event_t;

typedef enum {
    CRDPQ_INPUT_KEYBOARD = 0,
    CRDPQ_INPUT_MOUSE,
    /** adr/0011 §1/§0c: one UTF-16 code unit's down/release pair, bound for
     *  freerdp_input_send_unicode_keyboard_event(input, flags, code) -- same two-argument
     *  shape as CRDPQ_INPUT_KEYBOARD (`x`/`y` unused here too), `flags` is 0 for down or
     *  KBD_FLAGS_RELEASE for release (verified against
     *  ThirdParty/FreeRDP/client/X11/xf_client.c's xf_inject_keypress, the only in-tree
     *  reference for this pairing), `code` is the raw UTF-16 code unit -- a surrogate pair
     *  (e.g. an emoji) is two separate CRDPQ_INPUT_UNICODE down/release pairs, never one.
     *  Added with zero struct/ABI impact (§0c: crdpq_cmd_input_t.code is already
     *  uint16_t) -- see this file's own _Static_assert block, none of which cover the
     *  outbound lane (crdpq_cmd_input_t/crdpq_command_payload_t/CrdpCommand have never had
     *  one), confirming this really is enum-only. */
    CRDPQ_INPUT_UNICODE,
} crdpq_input_kind_t;

/** Keyboard, unicode, or mouse input bound for FreeRDP's
 *  ClientSendKeyboardEvent/ClientSendMouseEvent/freerdp_input_send_unicode_keyboard_event-
 *  shaped APIs. `x`/`y` are unused for CRDPQ_INPUT_KEYBOARD and CRDPQ_INPUT_UNICODE. */
typedef struct {
    crdpq_input_kind_t kind;
    uint16_t flags;
    uint16_t code;
    int32_t x;
    int32_t y;
} crdpq_cmd_input_t;

typedef union {
    crdpq_cmd_execute_t execute;
    crdpq_cmd_activate_t activate;
    crdpq_cmd_window_move_t windowMove;
    crdpq_cmd_sys_command_t sysCommand;
    crdpq_cmd_input_t input;
    crdpq_cmd_notify_event_t notifyEvent;
} crdpq_command_payload_t;

/** No generation field, deliberately: outbound commands don't carry the same
 *  "stale after reconnect" concern the inbound lanes do (there is no consumer-side
 *  generation-mismatch check for outbound commands in adr/0005) — the only shutdown
 *  concern here is reject-after-seal, via crdpq_outbound_seal.
 *
 *  This is safe only under a lifecycle contract this header does not enforce, so it's
 *  stated here instead: a crdpq_outbound_t instance's lifetime is exactly one session.
 *  It is NOT reused across a reconnect/generation bump — CRBridge must
 *  crdpq_outbound_destroy the old instance and crdpq_outbound_create a fresh one for the
 *  new session, never keep draining/posting to the same queue across generations. Adding
 *  a generation field later would only be meaningful once/if that contract changes. */
typedef struct {
    crdpq_command_type_t type;
    crdpq_command_payload_t payload;
} CrdpCommand;

typedef struct crdpq_outbound crdpq_outbound_t;

/** Called (at most once per drain cycle, mirroring crdpq_post's coalescing) to interrupt
 *  T_rdp's blocking wait so a freshly-posted command doesn't sit until the next poll
 *  timeout. Production: SetEvent on a WinPR event handle folded into T_rdp's
 *  WaitForMultipleObjects set (injected by CRBridge — see
 *  "crdpq_outbound_wakeup_handle" in the W3 report for why that's a concept realized via
 *  this function pointer rather than a named handle type in this FreeRDP-free target).
 *  Tests: a counter. May be NULL. */
typedef void (*crdpq_wakeup_fn)(void* ctx);

/** Equivalent to crdpq_outbound_create_with_max_capacity with a 65536-command ceiling. */
crdpq_outbound_t* crdpq_outbound_create(crdpq_wakeup_fn wakeup, void* wakeup_ctx);
/** Same as crdpq_outbound_create, but with an explicit capacity ceiling (M4) instead of
 *  the default 65536 commands — see crdpq_control_create_with_max_capacity's doc comment
 *  for the full rationale, mirrored here for the outbound direction. `max_capacity` below
 *  the initial 64-command capacity is clamped up to 64. */
crdpq_outbound_t* crdpq_outbound_create_with_max_capacity(crdpq_wakeup_fn wakeup, void* wakeup_ctx, size_t max_capacity);
void crdpq_outbound_destroy(crdpq_outbound_t* q);

/** Same POD-deep-copy-under-lock discipline as crdpq_post, including the same M1 fix:
 *  the seal check happens inside the same critical section as the enqueue, checked as
 *  late as possible, immediately before the mutation it gates. Returns false (without
 *  enqueueing) once crdpq_outbound_seal has been called (counted in
 *  crdpq_outbound_seal_rejected_count), if the back buffer is already at its configured
 *  capacity ceiling and full (M4, counted in crdpq_outbound_dropped_count), or on
 *  allocation failure (also counted). */
bool crdpq_outbound_post(crdpq_outbound_t* q, const CrdpCommand* cmd);

typedef void (*crdpq_command_visitor_fn)(const CrdpCommand* cmd, void* vctx);

/** T_rdp calls this at the top of every event-loop iteration (adr/0005 §3: "the reverse
 *  command queue is drained by T_rdp at the top of every freerdp_check_event_handles
 *  round"). Same swap-under-lock/visit-
 *  outside-lock structure as crdpq_drain. Single-consumer only. */
size_t crdpq_outbound_drain(crdpq_outbound_t* q, crdpq_command_visitor_fn visitor, void* vctx);

/** After this call, crdpq_outbound_post always returns false (adr/0005 §3: "gets the
 *  'reject sends after shutdown' landing point as a side effect"). Idempotent. */
void crdpq_outbound_seal(crdpq_outbound_t* q);
bool crdpq_outbound_is_sealed(const crdpq_outbound_t* q);

size_t crdpq_outbound_high_water_mark(const crdpq_outbound_t* q);

/** Outbound-lane counterpart to crdpq_dropped_count — same semantics, same exclusion of
 *  seal-rejected posts, mirrored for this direction (M4). */
size_t crdpq_outbound_dropped_count(const crdpq_outbound_t* q);

/** Number of crdpq_outbound_post calls rejected because the queue was already sealed
 *  (crdpq_outbound_seal, i.e. after CRSession's `-shutdownAndWait` has begun) — the
 *  outbound-lane counterpart to crdpq_seal_rejected_count, and the exact cause
 *  crdpq_outbound_dropped_count above excludes. Nothing else lands here: an at-cap-and-full
 *  rejection and a failed growth are counted THERE. Between them the two counters partition
 *  every false return from crdpq_outbound_post, so a send that vanished can always be
 *  attributed to one of "the session was shutting down" or "the lane overflowed" rather than
 *  to neither, which was the state of affairs before this counter existed.
 *
 *  Monotonically increasing, cumulative for this queue instance's lifetime — which, per
 *  CrdpCommand's own lifecycle note above, is exactly one session: this counter is NOT a
 *  cross-reconnect total, because the queue it lives in is destroyed and recreated at a
 *  generation rollover.
 *
 *  PASS-THROUGH CAVEAT, and it has bitten this codebase before: a bridge-level reader of
 *  this counter (CRSession's `-outboundSealRejectedCount`) is a pass-through to the queue
 *  itself, so once the queue has been destroyed the reader necessarily reports 0 rather
 *  than the session's real total — reading it after `-shutdownAndWait` yields a
 *  backwards-moving zero, not a total.
 *
 *  Sharper than that, for this counter specifically: CRSession seals inside
 *  `-shutdownAndWait` (step 1) and destroys the queue before that method returns, so a
 *  reader OUTSIDE the bridge has no instant at which a nonzero value is observable — it
 *  reads 0 before the seal and 0 after the destroy. Anything that wants a real total has
 *  to sample it from inside the shutdown sequence, between those two points. That is why
 *  Tools/window-smoke does not print it: from there it is a constant, not evidence. */
uint64_t crdpq_outbound_seal_rejected_count(const crdpq_outbound_t* q);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CRDPQ_H */
