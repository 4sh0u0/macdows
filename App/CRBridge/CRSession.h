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
};

@interface CRDPEvent : NSObject

@property (nonatomic, readonly) CRDPEventKind kind;
/// The session generation this event was stamped with at post time. Always equal to
/// `-[CRSession currentGeneration]` as observed by the drain call that delivered this
/// event — events from a stale generation are filtered out before ever reaching a
/// drain handler (adr/0005 §3), so this field is mostly useful for logging/diagnostics.
@property (nonatomic, readonly) uint32_t generation;

/// WindowCreate/Update/Delete/Icon, NotifyIconCreate/Update/Delete (window owner),
/// MonitoredDesktop.activeWindowId.
@property (nonatomic, readonly) uint32_t windowId;
/// NotifyIconCreate/Update/Delete only.
@property (nonatomic, readonly) uint32_t notifyIconId;
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
/// Does not implement `fixKeyCode()`'s ISO-keyboard Section/Grave swap (a MRDPView.m
/// detail gated on `mac_detect_keyboard_type() == APPLE_KEYBOARD_TYPE_ISO`). W4c review
/// M5: this is a bigger gap than "port one more translation function" -- `fixKeyCode()`'s
/// own signature is `fixKeyCode(DWORD keyCode, unichar keyChar, enum APPLE_KEYBOARD_TYPE
/// type)`, and that `keyChar` (from `[event charactersIgnoringModifiers] characterAtIndex:0]`,
/// MRDPView.m's own `-keyDown:`) is exactly what tells it whether a given key code needs
/// correcting. This method's own signature only carries `macKeyCode` -- no character data
/// at all -- so supporting `fixKeyCode()` would need `RemoteWindowInputEvent.keyDown`/
/// `.keyUp` (App/RemoteWindowRendering/RemoteWindowInput.swift) to carry the event's
/// characters too, and this method's own signature to grow a parameter for them: a real
/// pipeline change, not a drop-in call at the bottom of an existing function. Documented
/// here as a deliberate, narrow W4c gap rather than either half-implemented or ported
/// speculatively.
- (void)sendKeyDown:(uint16_t)macKeyCode;
- (void)sendKeyUp:(uint16_t)macKeyCode;

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
