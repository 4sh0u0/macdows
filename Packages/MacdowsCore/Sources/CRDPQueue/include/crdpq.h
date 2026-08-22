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
} crdpq_event_type_t;

/** WindowCreate/WindowUpdate. Matches MS-RDPERP's TS_WINDOW_STATE_ORDER field set (see
 *  Packages/MacdowsCore/.../WindowModel.swift's WindowOrderField for the fieldFlags bit
 *  values, if this ever needs delta-merge semantics at this layer too — as of Phase 1
 *  W3, this layer is a transport, not a state machine: merge policy lives in WindowModel,
 *  this struct just carries whatever fieldFlags + values rail-probe/CRBridge observed for
 *  a single order). */
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
    crdpq_text_t title;
} crdpq_window_order_t;

/** WindowDelete, WindowIcon. */
typedef struct {
    uint32_t windowId;
} crdpq_window_id_t;

/** NotifyIconCreate/Update/Delete. */
typedef struct {
    uint32_t windowId;
    uint32_t notifyIconId;
} crdpq_notify_icon_t;

/** MonitoredDesktop. */
typedef struct {
    uint32_t fieldFlags;
    uint32_t activeWindowId;
    uint32_t numWindowIds;
} crdpq_monitored_desktop_t;

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

/** GfxMapSurfaceToWindow. `windowId` is `uint64_t`, faithful to
 *  RDPGFX_MAP_SURFACE_TO_WINDOW_PDU's actual wire type (RailEvent.swift makes the same
 *  choice, for the same reason: real window IDs always fit in 32 bits, but the type stays
 *  honest about what FreeRDP actually hands us). */
typedef struct {
    uint32_t surfaceId;
    uint64_t windowId;
    uint32_t mappedWidth;
    uint32_t mappedHeight;
} crdpq_surface_mapped_t;

/** A lightweight "a frame became ready" notification carried on the *control* lane, so a
 *  consumer draining window orders in FIFO order can also observe frame-readiness
 *  interleaved with them without separately polling crdpq_frames every drain cycle. The
 *  actual frame pixels / generation-of-record live in crdpq_frames (last-writer-wins,
 *  below) — this is just a doorbell, not a copy of the frame state. */
typedef struct {
    uint32_t surfaceId;
} crdpq_frame_ready_t;

typedef union {
    crdpq_window_order_t windowOrder;   /* WINDOW_CREATE, WINDOW_UPDATE */
    crdpq_window_id_t windowId;         /* WINDOW_DELETE, WINDOW_ICON */
    crdpq_notify_icon_t notifyIcon;     /* NOTIFY_ICON_CREATE/UPDATE/DELETE */
    crdpq_monitored_desktop_t monitoredDesktop;
    crdpq_exec_result_t execResult;
    crdpq_handshake_flags_t handshakeFlags;
    crdpq_surface_mapped_t surfaceMapped;
    crdpq_frame_ready_t frameReady;
    /* CRDPQ_EVENT_DISCONNECTED carries no payload — the envelope's `generation` field
     * (the generation *as of the disconnect*, per adr/0005 §4 step 3: "post
     * DISCONNECTED(gen)") is everything a consumer needs. */
} crdpq_event_payload_t;

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
 *  Returns false (without copying) if the queue has been sealed (crdpq_seal), if the back
 *  buffer is already at its configured capacity ceiling and full (M4 — see
 *  crdpq_control_create_with_max_capacity, counted in crdpq_dropped_count), or if the
 *  buffer failed to grow under memory pressure (also counted in crdpq_dropped_count) —
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

typedef enum {
    CRDPQ_INPUT_KEYBOARD = 0,
    CRDPQ_INPUT_MOUSE,
} crdpq_input_kind_t;

/** Keyboard or mouse input bound for FreeRDP's ClientSendKeyboardEvent/ClientSendMouseEvent-
 *  shaped APIs. `x`/`y` are unused for CRDPQ_INPUT_KEYBOARD. */
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
 *  enqueueing) once crdpq_outbound_seal has been called, if the back buffer is already at
 *  its configured capacity ceiling and full (M4, counted in
 *  crdpq_outbound_dropped_count), or on allocation failure (also counted). */
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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CRDPQ_H */
