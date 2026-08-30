#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// One control-lane event delivered by `-[CRSession drainEventsWithHandler:]`.
///
/// Pure Objective-C, matching adr/0005 §5's "the bridge exposes only an ObjC header
/// externally, never C++" — this class is a lightweight, immutable snapshot of one `CrdpEvent` (the C POD event struct
/// defined by the CRDPQueue package), translated at the ObjC boundary so nothing C/C++
/// ever crosses `CRSession.h`. Only the fields relevant to `kind` are meaningful; the rest
/// hold their zero/nil default.
typedef NS_ENUM(NSInteger, CRDPEventKind) {
    CRDPEventKindWindowCreate,
    CRDPEventKindWindowUpdate,
    CRDPEventKindWindowDelete,
    CRDPEventKindWindowIcon,
    CRDPEventKindNotifyIconCreate,
    CRDPEventKindNotifyIconUpdate,
    CRDPEventKindNotifyIconDelete,
    CRDPEventKindMonitoredDesktop,
    CRDPEventKindExecResult,
    CRDPEventKindHandshakeFlags,
    CRDPEventKindSurfaceMapped,
    CRDPEventKindDisconnected,
    /// W4b: a frame became ready for `surfaceId` — the doorbell for
    /// `-copyPublishedSurface:`. Carries no pixels itself (adr/0005 §2: this is a
    /// notification, not a copy of the frame state).
    CRDPEventKindFrameReady,
    /// adr/0008 §1: ServerLocalMoveSize. NOT verified against any real capture (adr/0008
    /// §0's caveat — the six phase05 samples never dragged/resized a window); W3's first
    /// live occurrence is a verification event for this shape, not an already-proven one.
    CRDPEventKindLocalMoveSize,
    /// adr/0008 §1: ServerMinMaxInfo.
    CRDPEventKindMinMaxInfo,
    /// adr/0008 §1: ServerZOrderSync — a boundary marker only, carries no Z-order array
    /// (see `windowId`'s own doc comment below).
    CRDPEventKindZOrderSync,
};

@interface CRDPEvent : NSObject

@property (nonatomic, readonly) CRDPEventKind kind;
/// The session generation this event was stamped with at post time. Always equal to
/// `-[CRSession currentGeneration]` as observed by the drain call that delivered this
/// event — events from a stale generation are filtered out before ever reaching a
/// drain handler (adr/0005 §3), so this field is mostly useful for logging/diagnostics.
@property (nonatomic, readonly) uint32_t generation;

/// WindowCreate/Update/Delete/Icon, NotifyIconCreate/Update/Delete (window owner),
/// MonitoredDesktop.activeWindowId (adr/0008 §0: `0xFFFFFFFF` when no window on that
/// desktop currently has focus — callers MUST treat that sentinel as "no active window",
/// never as a literal windowId), LocalMoveSize/MinMaxInfo.windowId. Also reused
/// (adr/0008 §1) for ZOrderSync.windowIdMarker — despite the field name, that is NOT a
/// real window id, just an opaque Z-order sync boundary marker; never perform a
/// windowId-keyed lookup against it.
@property (nonatomic, readonly) uint32_t windowId;
/// NotifyIconCreate/Update/Delete only.
@property (nonatomic, readonly) uint32_t notifyIconId;

/// NotifyIconCreate/Update only. `NOTIFY_ICON_STATE_ORDER.toolTip` (adr/0013 §1), the tray
/// icon's own hover text — transcoded UTF-16→UTF-8 and truncated through the same
/// `crdpq_text_t` path `title` above uses. `nil` (NOT an empty string) when the order didn't
/// carry `WINDOW_ORDER_FIELD_NOTIFY_TIP`: notify-icon orders are delta-shaped like window
/// orders, so "the order said nothing" and "the order set it to empty" are different facts
/// and a consumer must be able to keep a previously-known tooltip across the first. This is
/// deliberately unlike `title`, which uses `@""` for its absent case — that property predates
/// the distinction being expressible and is left alone rather than churned.
@property (nonatomic, readonly, nullable) NSString *toolTip;
/// NotifyIconCreate/Update only. The tray icon's pixels, premultiplied RGBA8888, top-down,
/// `iconWidth * 4` bytes per row and `iconWidth * iconHeight * 4` bytes total (adr/0013 §2 —
/// `crdpq_icon_convert` does the DIB decode on T_rdp; this is already-converted output, not
/// wire bytes). `nil` when the order carried no icon, when the icon was refused
/// (see `iconSkipped`), or when the referenced side-store slot was recycled before this
/// event was drained — all three are the same thing to a consumer: show a placeholder.
/// Copied out of the store under its own lock at drain time, so this object's lifetime is
/// wholly independent of the session's (adr/0013 §3).
@property (nonatomic, readonly, nullable) NSData *iconRGBA;
/// NotifyIconCreate/Update only. Dimensions of `iconRGBA`, both 0 when it is `nil`. Bounded
/// by `CRDPQ_ICON_MAX_DIM` (48) — an icon larger than that is refused rather than downscaled
/// (`iconSkipped`), since scaling policy belongs to the AppKit layer that knows the menu
/// bar's own metrics, not to this transport.
@property (nonatomic, readonly) uint32_t iconWidth;
@property (nonatomic, readonly) uint32_t iconHeight;
/// NotifyIconCreate/Update only. `YES` iff the order DID carry an icon that this client
/// refused: oversize/unsupported-bpp/self-inconsistent bitmap fields, side-store slot
/// exhaustion, or the deferred CACHED_ICON variant (adr/0013 §2). adr/0008 §4's fail-open
/// contract applies — the consumer shows its placeholder and counts this; it is evidence
/// that a real icon existed and was dropped, which a plain `iconRGBA == nil` can't express.
@property (nonatomic, readonly) BOOL iconSkipped;
/// WindowCreate/Update.fieldFlags; MonitoredDesktop.fieldFlags. Gates which of
/// offsetX/offsetY (together), width/height (together), and show below are actually
/// meaningful for a given WindowUpdate — an unset bit means "unchanged from this window's
/// prior state", not "reset to zero" (TS_WINDOW_STATE_ORDER is a delta structure; see
/// MacdowsCore's WindowModel.swift, the canonical reference for these bit values, even
/// though this class doesn't share its constants directly — adr/0005 §5 keeps this
/// transport-level type free of that merge policy, exactly like crdpq.h's own C layer).
@property (nonatomic, readonly) uint32_t fieldFlags;
/// WindowCreate/Update only. Empty string (not nil) when the underlying order didn't set
/// WINDOW_ORDER_FIELD_TITLE for this delta.
@property (nonatomic, readonly) NSString *title;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the offset bit
/// (0x0800). Windows-space desktop offset, top-left origin, Y down — feed straight into
/// `MacdowsCore.WindowGeometry.macRect(from:primaryMonitorHeight:)`, never used directly
/// as an NSWindow frame origin.
@property (nonatomic, readonly) int32_t offsetX;
@property (nonatomic, readonly) int32_t offsetY;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the size bit (0x0400).
@property (nonatomic, readonly) uint32_t windowWidth;
@property (nonatomic, readonly) uint32_t windowHeight;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the show bit (0x0010).
/// `WINDOW_HIDE` (0) means hidden; any other value (`WINDOW_SHOW_MINIMIZED`=2,
/// `WINDOW_SHOW_MAXIMIZED`=3, `WINDOW_SHOW`=5, per freerdp/window.h) means shown in some
/// form — W4b's rendering layer only distinguishes hidden-vs-shown, not which shown state
/// (Z-order/minimize/restore fidelity is Phase 2, adr/0005 §7).
@property (nonatomic, readonly) uint32_t show;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the style bit (0x0008,
/// which gates BOTH `style` and `styleEx` together, per MacdowsCore's WindowModel.swift).
/// `TS_WINDOW_STATE_ORDER.style` (a `WS_*` bitmask, freerdp/window.h) — Phase 2 W0①'s
/// style/owner-based window filter (adr/0008 §3) is this field's first real consumer.
@property (nonatomic, readonly) uint32_t style;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the style bit (0x0008;
/// see `style` above). `TS_WINDOW_STATE_ORDER.extendedStyle` (a `WS_EX_*` bitmask).
@property (nonatomic, readonly) uint32_t styleEx;
/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the owner bit (0x0002,
/// `WINDOW_ORDER_FIELD_OWNER`). `TS_WINDOW_STATE_ORDER.ownerWindowId` (adr/0008 §3) — 0 is
/// a legitimate "no owner" value on the wire, not just "field absent"; callers must gate on
/// `fieldFlags` exactly like every other conditional sub-field on this class, never treat a
/// bare 0 here as authoritative without checking the bit first.
@property (nonatomic, readonly) uint32_t ownerWindowId;

/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the VIS_OFFSET bit
/// (0x1000, `WINDOW_ORDER_FIELD_VIS_OFFSET`). `TS_WINDOW_STATE_ORDER.visibleOffsetX/Y`
/// (adr/0010 §1) -- the screen-space top-left corner of the window's VISIBLE region
/// bounding box, NOT the same anchor as `offsetX`/`offsetY` above (those are
/// `windowOffsetX/Y`, the window's own origin; adr/0010 §0(b): the two agree only when the
/// window is unoccluded). Required to correctly place `visibilityRects` for an occluded
/// window (adr/0010 §2's shape transform) -- never assume `visibleOffset == windowOffset`
/// when this bit is unset; adr/0010 §3 rule 2 requires treating an unseen VIS_OFFSET as
/// "anchor unknown", not as an implicit zero or windowOffset fallback. 0 is itself a
/// legitimate value once the bit has actually been seen -- same fieldFlags-gating caveat as
/// `ownerWindowId` above.
@property (nonatomic, readonly) int32_t visibleOffsetX;
@property (nonatomic, readonly) int32_t visibleOffsetY;

/// WindowCreate/Update only, meaningful only when `fieldFlags` sets the visibility bit
/// (0x0200, `WINDOW_ORDER_FIELD_VISIBILITY`). `TS_WINDOW_STATE_ORDER.visibilityRects`
/// (adr/0008 §2b), flattened as `[left, top, right, bottom, left, top, right, bottom, ...]`
/// — `visibilityRects.count / 4` is the number of rects actually carried (bounded by
/// `CRDPQ_MAX_VISIBILITY_RECTS`, 32); `numVisibilityRects` below is the wire's own
/// (possibly larger) count, and `visibilityRectsTruncated` says whether they differ. Not
/// yet consumed by any live rendering path (adr/0008 §6: the rects->mask algorithm is
/// adr/0010's job) — this class only carries them to the main thread unmodified.
@property (nonatomic, readonly) NSArray<NSNumber *> *visibilityRects;
/// WindowCreate/Update only. The wire's own `numVisibilityRects` — may exceed
/// `visibilityRects.count / 4` when truncated; see `crdpq_window_order_t`'s own doc
/// comment (crdpq.h) for why the wire count itself is preserved rather than just the
/// stored count.
@property (nonatomic, readonly) uint32_t numVisibilityRects;
/// WindowCreate/Update only. YES iff the server sent more rects than
/// `CRDPQ_MAX_VISIBILITY_RECTS` (32) could hold — adr/0008 §4's fail-open contract applies
/// (degrade to the full window rect, never fabricate a smaller one from a truncated set).
@property (nonatomic, readonly) BOOL visibilityRectsTruncated;

/// ExecResult.execResult; ExecResult.rawResult; ExecResult's program/file path.
@property (nonatomic, readonly) uint32_t execResult;
@property (nonatomic, readonly) uint32_t rawResult;
@property (nonatomic, readonly) NSString *program;

/// HandshakeFlags.buildNumber (also set, buildNumber-only, by the non-Ex ServerHandshake).
@property (nonatomic, readonly) uint32_t buildNumber;
/// HandshakeFlags.railHandshakeFlags (0 for the non-Ex ServerHandshake, which doesn't
/// carry this field on the wire).
@property (nonatomic, readonly) uint32_t railHandshakeFlags;

/// SurfaceMapped only. `mappedWindowId` is 64-bit, faithful to
/// RDPGFX_MAP_SURFACE_TO_WINDOW_PDU's actual wire type (real window IDs always fit in 32
/// bits, but the type stays honest about what FreeRDP hands us).
/// Also set (mappedWindowId/mappedWidth/mappedHeight left at their zero default) by
/// FrameReady, where this is simply "the surfaceId a new frame is ready for".
@property (nonatomic, readonly) uint32_t surfaceId;
@property (nonatomic, readonly) uint64_t mappedWindowId;
@property (nonatomic, readonly) uint32_t mappedWidth;
@property (nonatomic, readonly) uint32_t mappedHeight;

/// MonitoredDesktop only, meaningful only when `fieldFlags` sets the Z-order bit (0x10,
/// `WINDOW_ORDER_FIELD_DESKTOP_ZORDER`). Ordered top-to-bottom Z order (adr/0008 §2a) as
/// `NSNumber`-boxed `uint32_t` window ids — empty when that bit wasn't set for this order.
/// May hold fewer entries than `numWindowIds` if the server's own array was larger than
/// `CRDPQ_MAX_WINDOW_IDS` (96); see `windowIdsTruncated`. adr/0008 §4's fail-open contract:
/// a consumer must leave the relative order of any windowId NOT in this array untouched —
/// never infer it belongs at the bottom just because it was cut off.
@property (nonatomic, readonly) NSArray<NSNumber *> *windowIds;
/// MonitoredDesktop only. The wire's own `numWindowIds` — may exceed `windowIds.count`
/// when truncated; see `crdpq_monitored_desktop_t`'s own doc comment (crdpq.h).
@property (nonatomic, readonly) uint32_t numWindowIds;
/// MonitoredDesktop only. YES iff the server sent more window ids than
/// `CRDPQ_MAX_WINDOW_IDS` (96) could hold.
@property (nonatomic, readonly) BOOL windowIdsTruncated;

/// LocalMoveSize only (adr/0008 §1) — `windowId` above names the moving/sizing window.
/// `TS_RAIL_ORDER_LOCALMOVESIZE`'s own boolean: YES at the start of a local move/size
/// operation, NO when it ends (normalized from the wire's raw `BOOL`/`int` — never a
/// bit-pattern reinterpretation).
@property (nonatomic, readonly) BOOL isMoveSizeStart;
/// LocalMoveSize only. Opaque handshake value (`LMS_*` constants) — this class does not
/// interpret it; that semantic belongs to whichever future layer implements W3's
/// move/resize handshake (adr/0008 §1).
@property (nonatomic, readonly) uint16_t moveSizeType;
/// LocalMoveSize only. Position at the moment of this notification, widened from the
/// wire's `INT16` to `int32_t` purely for uniformity with `offsetX`/`offsetY` above
/// (adr/0008 §1 — not a claim that the upstream INT16 narrowing needs fixing).
@property (nonatomic, readonly) int32_t moveSizePosX;
@property (nonatomic, readonly) int32_t moveSizePosY;

/// MinMaxInfo only (adr/0008 §1) — `windowId` above names the window this applies to.
/// `TS_RAIL_ORDER_MINMAXINFO`'s eight fields verbatim, each widened from the wire's
/// `INT16` to `int32_t` for the same uniformity reason as `moveSizePosX`/`moveSizePosY`.
@property (nonatomic, readonly) int32_t maxWidth;
@property (nonatomic, readonly) int32_t maxHeight;
@property (nonatomic, readonly) int32_t maxPosX;
@property (nonatomic, readonly) int32_t maxPosY;
@property (nonatomic, readonly) int32_t minTrackWidth;
@property (nonatomic, readonly) int32_t minTrackHeight;
@property (nonatomic, readonly) int32_t maxTrackWidth;
@property (nonatomic, readonly) int32_t maxTrackHeight;

/// ZOrderSync carries no properties of its own beyond `windowId` (reused above for
/// `windowIdMarker` — see that property's doc comment for why it is NOT a real window id).

@end

/// One RDP/RAIL/RDPGFX session bridging a remote Windows host into this process, per
/// adr/0005. `CRSession.mm`'s implementation links FreeRDP and CRDPQueue's C API
/// directly; none of that leaks across this header — it stays pure Objective-C so Swift
/// callers never pay a C++ interop tax (adr/0005 §5).
///
/// Threading contract (adr/0005 §1/§3/§5): every method here is safe to call from
/// whatever thread owns this CRSession instance ("T_main" in adr/0005's terms — an
/// AppKit main thread in the real app, or a CLI harness's own single thread, e.g.
/// Tools/bridge-smoke). Internally, the actual FreeRDP connection runs on its own
/// dedicated pthread ("T_rdp") that this class owns and never exposes; callers never see
/// or touch it directly.
@interface CRSession : NSObject

/// Calls `freerdp_get_version_string()` from libfreerdp3 and NSLogs the result. Kept from
/// the Phase 1 link-and-load smoke test; harmless to call at any time, independent of any
/// session instance.
+ (void)logFreeRDPVersion;

/// `host`/`user`/`password` are supplied by the caller — this class never reads
/// environment variables or credential files itself (red line: no credential-handling
/// logic embedded in library code). `program` is the RemoteApp executable path on the
/// Windows host, e.g. `C:\Windows\System32\winver.exe`.
- (instancetype)initWithHost:(NSString *)host
                         user:(NSString *)user
                     password:(NSString *)password
                      program:(NSString *)program NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Remote session desktop size, in remote pixels. Set BOTH before `-start` (read once by
/// the connect path on T_rdp; unsynchronized afterwards) or leave at 0/0 for FreeRDP's
/// default (1024x768). The caller passes its screen size here -- this class deliberately
/// knows nothing about AppKit/NSScreen. The RAIL server clamps remote window positions to
/// this desktop, so an undersized value shows up as an "invisible wall" mid-screen that
/// windows cannot be dragged past (established live 2026-08-21: default 1024 wide vs a
/// 2560pt display put that wall exactly at the screen's midpoint, and the server-side
/// clamp desynced local window frames from remote reality, breaking visually-aimed
/// clicks after a drag).
@property (nonatomic) uint32_t desktopWidth;
@property (nonatomic) uint32_t desktopHeight;

/// Command-line arguments for the initial `program` launch — MS-RDPERP's Exec order
/// `RemoteApplicationArguments`, carried via FreeRDP's `RemoteApplicationCmdLine` setting
/// (the vendored RAIL channel reads that setting itself when it sends the connect-time
/// Exec order — channels/rail/client/client_rails.c:68-82). Same contract as
/// `desktopWidth`: set before `-start` (read once by the connect path on T_rdp;
/// unsynchronized afterwards), or leave nil for no arguments. Windows-side quoting is the
/// caller's responsibility — this string is passed through verbatim.
@property (nonatomic, copy, nullable) NSString *programArguments;

/// Starts a fresh connection attempt: spawns T_rdp, which connects and (on success) runs
/// the RAIL/RDPGFX event loop until told to stop. Returns immediately — connection
/// progress and results surface as drained events (HandshakeFlags/ExecResult/...) or via
/// `-lastConnectError` after a failure. Safe to call again after a prior
/// `-shutdownAndWait` has completed (that pairing *is* adr/0005 §4's "reconnect = walk
/// steps 1-5 fully, then build a new context" — the same CRSession instance and its control-lane generation counter
/// persist across a reconnect; only the FreeRDP context/thread and the outbound queue are
/// torn down and recreated).
- (void)start;

/// adr/0005 §4's 5-step shutdown protocol, run synchronously on the calling thread:
/// seals the outbound queue and signals T_rdp to disconnect (step 1); waits for T_rdp to
/// run `freerdp_disconnect` and post `DISCONNECTED` (steps 2–3); drains the control queue
/// looking for that sentinel (step 4); joins T_rdp, frees the FreeRDP context, and bumps
/// the generation counter (step 5). Idempotent — calling this when already idle is a
/// harmless no-op. Returns YES iff the DISCONNECTED sentinel was actually observed before
/// the join (a clean shutdown, not a timeout-forced one).
- (BOOL)shutdownAndWait;

/// Drains the control lane once. adr/0005 §3: "the one comparison point is at the drain()
/// entry point" — this method
/// reads the current generation exactly once at entry and silently discards (counting
/// them into `-staleEventsDiscardedCount`, never handing them to `handler`) any drained
/// event whose stamped generation doesn't match. Calls `handler` once per surviving
/// event, in FIFO order, synchronously on the calling thread. Returns the number of
/// events delivered to `handler` (not counting discards).
- (NSUInteger)drainEventsWithHandler:(void (^)(CRDPEvent *event))handler;

/// W4c review: push-style event-availability notification, replacing 0.2s/0.05s-interval
/// Timer polling as this class's callers' way of knowing when to call
/// `-drainEventsWithHandler:` -- a real user-reported bug this round (observed ~5 FPS
/// end-to-end; the fixed poll interval, not anything in the render pipeline itself, was
/// the bottleneck: with a 0.2s Timer, the *average* wait before a ready frame's next drain
/// is ~half the interval, ~100ms, and 1000ms / 200ms is exactly the observed ~5 FPS
/// ceiling). Set this once, any time; invoked on the main queue (always, regardless of
/// which thread's `crdpq_post` actually triggered the underlying `schedule_drain` --
/// T_rdp, for every real production caller) whenever new control-lane events (including
/// FRAME_READY) become available. Coalesced: `crdpq_control_t`'s own `schedule_drain`
/// contract fires "at most once per drain cycle", so several events posted back-to-back
/// before a caller has had a chance to drain collapse into a single call here, not one per
/// event -- "one burst, one dispatch". Call `-drainEventsWithHandler:` from inside the
/// handler. `nil` (the default) is a safe no-op: nothing here requires this ever being
/// set, matching every pre-existing caller's behavior (e.g. a headless test that only
/// polls manually).
@property (nonatomic, copy, nullable) void (^onEventsAvailable)(void);

/// The control lane's current generation (adr/0005 §3's `sessionGeneration`). Bumped by
/// exactly one, atomically, as the last step of `-shutdownAndWait`.
@property (nonatomic, readonly) uint32_t currentGeneration;

/// Cumulative count of drained events discarded by the generation gate described on
/// `-drainEventsWithHandler:`, across this instance's whole lifetime (survives
/// reconnects — it is exactly the "reject count" adr/0005's reconnect protocol exists to
/// produce).
@property (nonatomic, readonly) uint64_t staleEventsDiscardedCount;

/// Cumulative count of drained `CrdpEvent`s whose `type` this class doesn't recognize (any
/// future crdpq_event_type_t addition this file hasn't been taught about yet) — silently
/// skipped rather than delivered to a drain handler as a fabricated event.
@property (nonatomic, readonly) uint64_t unknownEventCount;

/// Passthrough of the control lane's own `crdpq_dropped_count` (adr/0005 §7's
/// dropped-frame-style alerting, extended to this lane by W3's M4 fix batch) — posts
/// rejected because the lane was at its capacity ceiling and full, or OOM. Does not
/// count anything related to sealing/shutdown.
@property (nonatomic, readonly) uint64_t droppedEventsCount;

/// adr/0013 §1: passthrough of the notify-icon pixel side-store's own overflow counter —
/// tray icons refused because all `CRDPQ_ICON_SLOTS` (16) slots were already held by other
/// `(windowId, notifyIconId)` keys. Same dropped-count-for-alerting shape as
/// `droppedEventsCount` above, and cumulative for this instance's whole lifetime in the same
/// way (a reconnect clears the slots but never this counter). Consumed by
/// `TrayStatusController.Diagnostics.storeOverflowCount`.
@property (nonatomic, readonly) uint64_t iconStoreOverflowCount;

/// Set (non-nil) if the most recent `-start` call's connection attempt failed before any
/// protocol traffic occurred (DNS/TCP/TLS/NLA/activation failure) — read this after
/// observing no HandshakeFlags event within a reasonable timeout. Cleared at the start of
/// each `-start` call. Deliberately not `nonatomic`: written from T_rdp
/// (`crb_rdp_thread_main`'s connect-failure path), read from T_main — see the class
/// extension's redeclaration in CRSession.mm for the cross-thread publish rationale.
@property (readonly, nullable) NSError *lastConnectError;

/// W4b frame pathway (adr/0005 §2). Call after observing a `CRDPEventKindFrameReady` event
/// for `surfaceId`: returns a +1-retained `IOSurfaceRef` (caller must `CFRelease`,
/// typically after handing it to a `CALayer`, which retains its own stake) holding that
/// surface's most recently published frame, or `nil` if nothing is available — either
/// because `surfaceId` isn't currently tracked, or because the frame that was published is
/// stale (from a connection generation prior to `-currentGeneration`, e.g. after a
/// reconnect — adr/0005 §4's generation protocol applies to frames exactly as it does to
/// control-lane events). Safe to call even if nothing new has been published since the
/// last call for the same `surfaceId` (returns `nil` — the caller already holds the
/// current frame, there's nothing newer to hand out).
- (nullable IOSurfaceRef)copyPublishedSurface:(uint32_t)surfaceId CF_RETURNS_RETAINED;

/// Returns a surface previously obtained from `-copyPublishedSurface:` back to its
/// triple-buffer pool once it's no longer needed — call this from a `CATransaction`
/// completion block, once the surface has actually stopped being read by CoreAnimation
/// (adr/0005 §2: "the recycle point is CATransaction completion, not the moment contents
/// is swapped"), never
/// immediately after assigning `layer.contents`. `CF_RELEASES_ARGUMENT`: this call consumes
/// the caller's retain (mirrors `CFRelease`'s own contract, and — critically — tells
/// Swift's importer this method releases `surface` rather than borrowing it, so a Swift
/// caller's own bridged `IOSurface` doesn't *also* get independently released, which would
/// double-release the same object) — do not also `CFRelease`/drop `surface` separately
/// after calling this. Safe to call with a surface whose originating slot has since been
/// unmapped, resized, or torn down by a disconnect; in that case this simply releases the
/// reference without touching any pool state.
- (void)recycleSurface:(IOSurfaceRef CF_RELEASES_ARGUMENT)surface;

/// W4b review round 2's Activate-repaint experiment: posts a RAIL ClientActivate command
/// for `windowId` onto the outbound lane (already-existing plumbing -- `crb_outbound_visitor`
/// has handled `CRDPQ_CMD_ACTIVATE` since W4a; this method is simply the first public,
/// Swift-facing way to actually post one). Drained by T_rdp at the top of its next loop
/// iteration (adr/0005 §3), fire-and-forget -- there is no synchronous confirmation the
/// server actually did anything in response. Intended for diagnostics (does bringing a
/// window to the foreground make the server resend content it never painted for us as a
/// background window?), not as a real focus-management feature yet; a real one belongs to
/// whatever phase does full RAIL window-management/focus sync. Safe to call at any time
/// after `-start`; silently does nothing if the session isn't connected.
- (void)activateWindow:(uint32_t)windowId;

/// Launches an additional RemoteApp program in the already-connected session (RAIL
/// ClientExecute over the outbound lane -- Phase 1 acceptance's multi-window scenarios
/// exercise several apps in one session; Phase 0.5's S3 established the server honors
/// repeat ClientExecute on a live connection). Fire-and-forget like `-activateWindow:`:
/// silently dropped if the RAIL channel isn't connected yet; the launch's outcome
/// arrives as an ExecResult event (execResult != 0 = server-side failure, e.g.
/// RAIL_EXEC_E_FILE_NOT_FOUND). `program` is a full Windows path, same convention as
/// the initializer's `program`.
- (void)executeProgram:(NSString *)program;

/// W2 (docs/plans/phase2.md §2 W2 task item 4): posts a RAIL ClientSystemCommand for
/// `windowId` onto the outbound lane -- already-existing plumbing (`crb_outbound_visitor`
/// has handled `CRDPQ_CMD_SYS_COMMAND` since it was implemented, this method is simply the
/// first public, Swift-facing way to actually post one, exactly mirroring `-activateWindow:`'s
/// own doc comment above for `CRDPQ_CMD_ACTIVATE`). `command` is an MS-RDPERP `TS_RAIL_ORDER_
/// SYSCOMMAND` `SC_*` value (freerdp/rail.h) -- this header intentionally stays agnostic
/// about which `SC_*` constant means what (a raw, undecorated `uint16_t` pipe, like every
/// other outbound method on this interface); the caller (`RemoteWindowRegistry`) owns that
/// mapping, matching how it already owns e.g. `WindowOrderField`'s bit-flag semantics rather
/// than this AppKit-free header knowing about them. Fire-and-forget like `-activateWindow:`
/// -- silently does nothing if the session isn't connected. Server authority: this call
/// alone never changes anything locally: the actual close/minimize/maximize only happens
/// once `RemoteWindowRegistry` later observes the server's own `WindowDelete`/`WindowUpdate`
/// in response (see `RemoteWindow`'s traffic-light doc comments for the full loop).
- (void)sendSysCommand:(uint32_t)windowId command:(uint16_t)command;

/// W3 (docs/plans/phase2.md §2 W3): posts a RAIL ClientWindowMove for `windowId` onto the
/// outbound lane -- already-existing plumbing (`crb_outbound_visitor` has handled
/// `CRDPQ_CMD_WINDOW_MOVE` since the outbound lane was implemented, this method is simply
/// the first public, Swift-facing way to actually post one, exactly mirroring
/// `-sendSysCommand:command:`'s own doc comment above). RECT semantics, NOT x/y/width/
/// height: `left`/`top`/`right`/`bottom` mirror `RAIL_WINDOW_MOVE_ORDER` (freerdp/rail.h)
/// exactly -- verified directly against that header, not assumed -- and
/// `crdpq_cmd_window_move_t`'s own field names already match 1:1, so this method does no
/// coordinate math of its own, the same "dumb pipe" contract every other outbound method on
/// this header already has. The caller (`RemoteWindowRegistry`) computes these four values
/// from the local `NSWindow` frame via `MacdowsCore.WindowGeometry.windowsRect(from:
/// primaryMonitorHeight:)` (the exact inverse of the conversion `handleWindowOrder` already
/// applies inbound), then `right = left + width` / `bottom = top + height` -- never handed
/// a width/height pair directly, so a caller can't accidentally reintroduce the classic
/// RECT-vs-x/y/w/h off-by-frame bug this method's own signature is shaped to avoid.
/// Fire-and-forget like `-sendSysCommand:command:` -- silently does nothing if the session
/// isn't connected.
- (void)sendWindowMove:(uint32_t)windowId left:(int32_t)left top:(int32_t)top right:(int32_t)right bottom:(int32_t)bottom;

/// W4c: one physical mouse button, in RDP's own PTR_FLAGS_BUTTON1/2/3 numbering (left/
/// right/middle) -- deliberately not NSEvent.buttonNumber's own scheme (0/1/2), so this
/// header never has to explain an off-by-one to a Swift caller. Extended/side buttons
/// (NSEvent.buttonNumber >= 3, RDP's separate PTR_XFLAGS_BUTTON1/2 wire message) are a
/// documented, deliberate W4c gap -- rare for a RemoteApp session, and out of scope for
/// this input-plumbing pass; a caller that only ever constructs one of the three cases
/// below simply never triggers it.
typedef NS_ENUM(NSInteger, CRMouseButton) {
    CRMouseButtonLeft = 1,
    CRMouseButtonRight = 2,
    CRMouseButtonMiddle = 3,
};

/// W4c: the eight modifier keys FreeRDP's own Mac reference client
/// (ThirdParty/FreeRDP/client/Mac/MRDPView.m's updateFlagState) distinguishes for
/// `-flagsChanged:` handling. Named after the *physical Mac key*, not any RDP-side
/// semantic -- `-sendModifierKey:down:` sends that key's own literal scancode
/// uninterpreted. A Cmd<->Ctrl remap for Mac users reaching for Windows-standard
/// shortcuts is explicitly deferred to Phase 2; this round is a straight passthrough
/// (matching the W4c task spec's own wording).
///
/// W4c review M4: `CRModifierKeyHelp`/`CRModifierKeyFunction` mirror MRDPView.m:624-631's
/// own two separate switch cases for `NSEventModifierFlagHelp`/`NSEventModifierFlagFunction`
/// -- two distinct AppKit bits that both resolve to `RDP_SCANCODE_HELP` on the wire. Kept
/// as two separate enum cases (not collapsed into one) so this type stays a 1:1 mirror of
/// `MacdowsCore.ModifierKeySet`, which a caller diffs `NSEvent.modifierFlags` against
/// before ever constructing one of these.
typedef NS_ENUM(NSInteger, CRModifierKey) {
    CRModifierKeyCapsLock,
    CRModifierKeyShift,
    CRModifierKeyControl,
    CRModifierKeyOption,
    CRModifierKeyCommand,
    CRModifierKeyNumericPad,
    CRModifierKeyHelp,
    CRModifierKeyFunction,
};

/// W4c: mouse/keyboard input forwarding -- Phase 1's "clickable/interactive" acceptance
/// milestone (adr/0005). Every method below is a "dumb pipe" exactly like
/// `-activateWindow:` above: this class does no coordinate math and no keycode
/// translation *policy* of its own (the WinPR calls inside `-sendKeyDown:`/`-sendKeyUp:`
/// are a direct, undecorated port of what FreeRDP's own Mac client already does for the
/// same input, not a design choice made here). The caller (`RemoteWindowRegistry`) is
/// responsible for converting a mac-screen point to Windows-space absolute desktop
/// coordinates via `MacdowsCore.WindowGeometry.windowsPoint(from:primaryMonitorHeight:)`
/// before calling any of the coordinate-taking methods here -- RAIL mouse input always
/// targets the *whole remote desktop's* absolute coordinate space, not a window-local one,
/// even though each RAIL window is rendered here as its own separate NSWindow. All six
/// methods are fire-and-forget, like `-activateWindow:` -- silently do nothing if the
/// session isn't connected.

/// PTR_FLAGS_MOVE. Also correct for a drag in progress: RDP tracks button state
/// independently of pointer motion on the wire, so a plain move event while a button is
/// already down is the right encoding (matches FreeRDP's own Mac client, which sends this
/// exact same event for both `-mouseMoved:` and `-mouseDragged:`).
- (void)sendMouseMoveToX:(int32_t)x y:(int32_t)y;

/// PTR_FLAGS_BUTTON1/2/3, ORed with PTR_FLAGS_DOWN when `down` is YES.
- (void)sendMouseButton:(CRMouseButton)button down:(BOOL)down atX:(int32_t)x y:(int32_t)y;

/// PTR_FLAGS_WHEEL / PTR_FLAGS_HWHEEL. `delta`: a raw NSEvent scroll delta (`deltaY`/
/// `deltaX`) -- the 120-units-per-notch scaling and the wire's 9-bit signed step encoding
/// are this method's own job (matches ThirdParty/FreeRDP/client/Mac/MRDPView.m's
/// `-scrollWheel:`); the caller passes the event's delta through unscaled. A delta of
/// exactly 0 is a no-op.
- (void)sendMouseVerticalWheelDelta:(double)deltaY atX:(int32_t)x y:(int32_t)y;
- (void)sendMouseHorizontalWheelDelta:(double)deltaX atX:(int32_t)x y:(int32_t)y;

/// `macKeyCode`: a raw, untranslated `[NSEvent keyCode]` value. Internally calls WinPR's
/// public `GetVirtualKeyCodeFromKeycode(_, WINPR_KEYCODE_TYPE_APPLE)` +
/// `GetVirtualScanCodeFromVirtualKeyCode` -- the same exported functions
/// ThirdParty/FreeRDP/client/Mac/MRDPView.m's own `-keyDown:`/`-keyUp:` call, already
/// linked into this target via winpr3 -- so no keycode table needed porting here.
///
/// Does not implement `fixKeyCode()`'s ISO-keyboard Section/Grave swap here -- that
/// correction now lives in `MacdowsCore.IsoKeyCodeCorrection` (adr/0011 §4), applied by
/// `RemoteWindowRegistry` to `macKeyCode` BEFORE it ever reaches this method, not inside
/// this "dumb pipe" translation layer. adr/0011 §0a corrects this comment's own prior
/// claim (W4c review M5), which was wrong: `fixKeyCode(DWORD keyCode, unichar keyChar,
/// enum APPLE_KEYBOARD_TYPE type)`'s `keyChar` parameter does NOT drive the correction --
/// the only branch of `fixKeyCode()` that's actually live in the vendored source is the
/// pure `type == APPLE_KEYBOARD_TYPE_ISO` Grave<->Section swap (MRDPView.m:468-476); the
/// Hungarian branch that reads `keyChar` is `#if 0`'d out entirely (MRDPView.m:448-466),
/// so `keyChar` there only ever gates "is this call worth making at all" (non-empty
/// `characters`), never which correction to apply. The ISO gap is closed by keyboard
/// *type* alone, never by character data -- adr/0011 §2 still adds `characters`/
/// `charactersIgnoringModifiers` to `RemoteWindowInputEvent.keyDown`/`.keyUp`
/// (App/RemoteWindowRendering/RemoteWindowInput.swift), but that pipeline change's real
/// third consumer is adr/0011 §3's Cmd-chord recognition, not this ISO correction.
- (void)sendKeyDown:(uint16_t)macKeyCode;
- (void)sendKeyUp:(uint16_t)macKeyCode;

/// adr/0011 §2: sends `text` as a sequence of Unicode keyboard events -- one down/release
/// pair per UTF-16 code unit (adr/0011 §0b/§1: FreeRDP's own unicode wire message carries
/// exactly one UTF-16 code unit per event, so a surrogate pair, e.g. an emoji, becomes two
/// pairs, never one), posted through the same outbound lane every other input method here
/// uses. Fire-and-forget, silently does nothing if the session isn't connected or `text`
/// is empty -- same contract as every other method on this interface. This is the v1
/// "local IME composition, Unicode-only commit" path (adr/0011 §2): callers only ever pass
/// an already-fully-composed string here (an `NSTextInputClient -insertText:` commit), not
/// per-keystroke romanization input. Does nothing to check `-unicodeInputSupported` itself
/// -- degradation policy (adr/0011 §2: "为假时IME通路整体停用、告警一次") belongs to the
/// caller (`RemoteWindowRegistry`), which is also where every other input-forwarding
/// *policy* decision on this interface already lives; this method stays the same kind of
/// undecorated pipe `-sendKeyDown:`/`-sendModifierKey:down:` already are.
- (void)sendUnicodeText:(NSString *)text;

/// adr/0011 §2's degradation gate: `FreeRDP_UnicodeInput`, read from the server's
/// negotiated Input Capability Set exactly once, immediately after a successful
/// `-start` connection attempt (adr/0011 §2: "连接建立后读一次"). `NO` before the first
/// successful connect and reset to `NO` at the top of every `-start` call, so a caller
/// never sees a stale answer from a prior connection generation. When this is `NO`,
/// `-sendUnicodeText:` would otherwise silently fail per-event (FreeRDP's own
/// `freerdp_input_send_unicode_keyboard_event` just `WLog_WARN`s and returns `FALSE`,
/// adr/0011 §0b) -- this property exists so `RemoteWindowRegistry` can check it ONCE and
/// disable the whole IME lane with a single visible warning instead (adr/0011 §2: "不静默
/// 丢字, §0b的默认行为不可接受").
@property (nonatomic, readonly) BOOL unicodeInputSupported;

/// Test-harness override for the property above: when `YES`, the connect path forces
/// `-unicodeInputSupported` to `NO` no matter what the server actually negotiated (and
/// logs one line saying it did). Same contract as `desktopWidth`: set before `-start`
/// (read once by the connect path on T_rdp; unsynchronized afterwards), default `NO`.
///
/// Exists because adr/0011 §5 item 7's acceptance ("服务端 caps 缺 INPUT_FLAG_UNICODE 时，
/// 降级告警恰好一次且无静默丢字") otherwise requires a Windows host reconfigured to drop
/// `INPUT_FLAG_UNICODE` from its Input Capability Set -- a host-side change neither an
/// offline test nor an ordinary live run can make, which would leave adr/0011 §2's entire
/// degradation path ("IME通路整体停用、告警一次") permanently unexercised on the very
/// pipeline it exists to protect. With this, the whole path is constructible against any
/// host: set it, connect, type through an IME, observe exactly one warning and a nonzero
/// drop count.
///
/// Can only ever *narrow* what reaches the wire -- forcing this on disables the Unicode
/// lane; it can never enable one the server didn't advertise, so a harness that leaves it
/// set cannot manufacture a protocol violation. This class still reads no environment
/// variables of its own (the same red line `-initWithHost:user:password:program:` states
/// for credentials): a harness that wants this behavior sets the property itself.
@property (nonatomic) BOOL forceUnicodeInputUnsupported;

/// One `CRModifierKey`'s pressed state changed (from diffing
/// `NSEvent.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask` against its
/// previous value -- mirrors MRDPView.m's own updateFlagState/updateFlagStates, one call
/// per bit that actually flipped). `CRModifierKeyCapsLock` and `CRModifierKeyNumericPad`
/// are toggle keys on RDP's wire, not hold keys: every call for either of those two always
/// sends both a DOWN and a RELEASE back to back (matching updateFlagState's
/// `release = press = TRUE` special case), so `down` is meaningless for them beyond "the
/// toggle just fired"; for the other six (including Help/Function), `down` selects DOWN
/// vs. RELEASE normally.
- (void)sendModifierKey:(CRModifierKey)key down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
