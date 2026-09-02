import AppKit
import IOSurface
import MacdowsCore

/// Identifies one `RemoteWindow`. Deliberately keyed by `windowId` **and** `generation`,
/// not `windowId` alone — after a reconnect the RDP server is free to reuse the same
/// numeric windowId for a logically unrelated window, and nothing in this rendering layer
/// should ever confuse the two. `RemoteWindowRegistry` is what actually enforces "only one
/// generation's windows are ever live at once" (closing every prior-generation window the
/// moment it observes a new generation) — this key type just makes that invariant visible
/// in the type itself rather than relying on callers to get the bookkeeping right by hand.
struct RemoteWindowKey: Hashable {
    let windowId: UInt32
    let generation: UInt32
}

/// User-reported "clicks don't work" / dead keyboard, root-caused this review round: a
/// `.borderless`-styleMask `NSWindow` defaults to `canBecomeKey == false` /
/// `canBecomeMain == false` in stock AppKit, and this project's own `RemoteWindow` never
/// overrode either — confirmed absent by grep before this fix. Without this override,
/// `-makeKeyAndOrderFront:`/`-makeKey` silently no-op (the window orders front but never
/// actually becomes key), so a genuine user click — which goes through the window server's
/// own key-window assignment — never reaches `RemoteWindowContentView`'s keyDown/keyUp
/// overrides at all. This project's own W4c end-to-end tests never caught it because they
/// dispatch synthetic events via `NSWindow.sendEvent(_:)` directly, which delivers straight
/// into the view hierarchy regardless of the window's actual key/main status — a real gap
/// in what those tests could observe, not evidence the bug didn't exist. Only a subclass
/// can override these (they're not instance-settable on a plain `NSWindow`), hence this
/// otherwise-trivial subclass existing at all.
private final class RemoteWindowBackingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Phase 2 W2 traffic lights (docs/plans/phase2.md §2 W2 task item 3): the server is
    /// authoritative over close/minimize/maximize -- this backing window never performs any
    /// of the three locally, `super` is deliberately never called. Overriding these three
    /// AppKit action methods (rather than wiring the traffic-light buttons' target/action
    /// individually) intercepts EVERY trigger that would normally invoke them: the
    /// traffic-light buttons themselves (whose default actions ARE exactly these three
    /// selectors -- `-standardWindowButton:` for `.closeButton`/`.miniaturizeButton`/
    /// `.zoomButton` targets these by construction), the standard ⌘W/⌘M keyboard shortcuts
    /// wherever they're bound, and a double-click on the title bar (which calls `-zoom:`) --
    /// in one place, rather than only covering the buttons and leaving every other trigger
    /// to fall through to AppKit's real close/miniaturize/zoom behavior. The real effect
    /// only happens once `RemoteWindowRegistry` later observes the server's own
    /// `WindowDelete`/`WindowUpdate` in response to the `SC_*` command these closures send
    /// (see `RemoteWindow.onChromeAction`'s own doc comment for the full loop). All three
    /// default to nil (a plain closure property, not `@objc`/target-action) -- safe to leave
    /// unset for a window whose chrome never enables the corresponding style bit, since
    /// AppKit then never surfaces the button/shortcut to trigger the override in the first
    /// place.
    ///
    /// DORMANT under `RemoteWindow.nativeChromePolicy == .never` (owner decision,
    /// 2026-08-23, adr/0010 §6): `applyChromeNow` never applies `.titled` (hence never
    /// `.closable`/`.miniaturizable` either) any more, so AppKit never renders a
    /// traffic-light button and never registers the title-bar double-click that would call
    /// `-zoom:` -- none of these three overrides has a live AppKit-side trigger left. Kept,
    /// not deleted: still correct if the policy ever flips back to native chrome, and
    /// costs nothing while dormant. Cmd+W does NOT depend on this path either way -- this
    /// app builds no `NSApp.mainMenu` at all (see `App/Macdows/main.swift`/`AppDelegate`),
    /// so there is no menu key-equivalent to intercept Cmd+W before it reaches
    /// `RemoteWindowContentView.keyDown`; it flows to `CommandKeyMapper`, which reports
    /// `.closeRequest` and routes to `RemoteWindowRegistry.handleChromeAction(.close)` ->
    /// `SC_CLOSE`, entirely independent of `performClose` above (verified by reading both
    /// paths, not assumed).
    var onPerformClose: (() -> Void)?
    var onPerformMiniaturize: (() -> Void)?
    var onZoom: (() -> Void)?

    override func performClose(_ sender: Any?) {
        onPerformClose?()
    }

    override func performMiniaturize(_ sender: Any?) {
        onPerformMiniaturize?()
    }

    override func zoom(_ sender: Any?) {
        onZoom?()
    }
}

/// One remote RAIL window mirrored onto this Mac as an undecorated `NSWindow`, per
/// adr/0005 §2's frame pathway. Owns exactly one `NSWindow` and one image-backed
/// `CALayer`. `@MainActor` — window management is a T_main concern (adr/0005 §5); nothing
/// here is safe to touch from T_dvc/T_rdp.
@MainActor
final class RemoteWindow {
    let key: RemoteWindowKey
    let window: NSWindow
    private let contentLayer: CALayer

    /// The surface currently assigned to `contentLayer.contents`, if any — held onto so
    /// that a *later* `present(surface:via:)` call can recycle it once CoreAnimation has
    /// actually finished with it (adr/0005 §2: "the recycle point is CATransaction
    /// completion, not the moment contents is swapped"). This is always the *outgoing* surface being replaced, never the
    /// incoming one.
    private var displayedSurface: IOSurface?
    /// The GFX mapped sub-rect size for `displayedSurface` (nil when unknown) -- the real
    /// content region inside the 64-aligned allocation. Kept alongside the surface so
    /// diagnostics (`nonWhitePixelRatio`) sample actual content instead of padding rows,
    /// which used to skew every pixel-honesty metric (padding bytes read as "non-white").
    private var displayedMappedSize: CGSize?

    /// W4c: fed straight from `RemoteWindowContentView.onEvent` — this class does no
    /// translation of its own, just plumbs the closure through to the view constructed in
    /// `init` below (adr/0005 §5: "outbound traffic goes through the registry calling back
    /// into CRSession", so the actual
    /// CRSession-calling logic lives one level up, in `RemoteWindowRegistry`).
    var onInput: ((RemoteWindowInputEvent) -> Void)? {
        get { contentView.onEvent }
        set { contentView.onEvent = newValue }
    }
    private let contentView: RemoteWindowContentView

    /// Phase 2 W2 (docs/plans/phase2.md §2 W2 task item 3): one traffic-light action,
    /// reported upward exactly like `onInput` above -- `RemoteWindowRegistry` decides which
    /// `SC_*` command to send (it alone knows this window's current show-state, needed to
    /// pick `SC_MAXIMIZE` vs `SC_RESTORE` for `.zoom`) and owns the actual `CRSession` call,
    /// the same "dumb pipe up, policy in the registry" split `onInput`/`handleInput`
    /// already establishes. Server authority (task item 3's own instruction): `RemoteWindow`
    /// never mutates its own `NSWindow` state in response to a traffic-light action --
    /// `RemoteWindowBackingWindow`'s three overrides above never call `super`, so the ONLY
    /// effect of a click/⌘W/⌘M/double-click-titlebar is this closure firing. The real
    /// close/minimize/maximize happens later, when `RemoteWindowRegistry` observes the
    /// server's own `WindowDelete` (close) or a `WindowUpdate` carrying a new show-state/
    /// size (minimize/maximize) -- the exact same `handleWindowOrder`/`handleWindowDelete`
    /// path an ordinary RAIL-driven show-state change already goes through, so a
    /// traffic-light click and a server-initiated state change look identical downstream.
    var onChromeAction: ((ChromeAction) -> Void)?

    enum ChromeAction {
        case close
        case minimize
        case zoom
    }

    /// Phase 2 W3 (docs/plans/phase2.md §2 W3): fired once a local drag/resize gesture (or
    /// a server-announced ServerLocalMoveSize modality, see
    /// `beginServerAnnouncedMoveResize`/`endServerAnnouncedMoveResize` below) has settled,
    /// reporting this window's final CONTENT rect (`window.contentRect(forFrameRect:
    /// window.frame)`, NOT the raw `NSWindow.frame` -- real-host regression, 2026-08-23:
    /// RAIL geometry describes the remote window's outer rect, which this class's content
    /// view displays verbatim, so the content rect is what round-trips through RAIL space;
    /// `init`'s own doc comment has the full reasoning) -- `RemoteWindowRegistry` converts
    /// it back to RAIL space via `MacdowsCore.WindowGeometry` and calls
    /// `CRSession.sendWindowMove(_:left:top:right:bottom:)`. This class does no Windows/Mac
    /// coordinate math of its own, the same "dumb pipe up, policy in the registry" split
    /// `onInput`/`onChromeAction` already establish -- reading the content rect out of its
    /// own `window` is an AppKit-chrome fact this class already owns, not RAIL coordinate
    /// math.
    var onLocalGeometrySettled: ((NSRect) -> Void)?

    /// Real-host regression fix (2026-08-23, popup-scenario live battery under the
    /// borderless-chrome flip): fired exactly once per gate-clear, from `present`'s and
    /// `firstFrameTimeoutFired`'s own gate-clearing branches, AFTER every other pending
    /// state (`pendingChrome`/`pendingMask`/`pendingVisible`/`pendingActivate`) has already
    /// been applied. Exists so `RemoteWindowRegistry.updateParentChild` can defer its
    /// `NSWindow.addChildWindow(_:ordered:)` call the same way `applyChrome`/`applyMask`/
    /// `setVisible`/`activateLocally` already defer THEIR AppKit calls until this window's
    /// first-frame gate has cleared -- see `updateParentChild`'s own doc comment for the
    /// real-host finding that made this necessary: `addChildWindow` was observed to
    /// materialize a gate-held (zero-content, never-ordered) child window on screen
    /// immediately, independent of `setVisible`, joining the four other AppKit-call sites
    /// (construction-time registration, Z-order's `order(_:relativeTo:)`, chrome's
    /// styleMask/frame mutation, `activateLocally`'s `makeKeyAndOrderFront`) already known
    /// to bypass the gate this way. This class has no reference to any OTHER `RemoteWindow`
    /// or to the registry's `attachedChildOwner` bookkeeping, so -- unlike
    /// `pendingChrome`/`pendingMask`/`pendingVisible`/`pendingActivate`, which this class
    /// applies to itself -- the actual deferred action has to live in the registry; this
    /// closure is the "dumb pipe up, policy in the registry" notification that lets it do
    /// so, the same split `onInput`/`onChromeAction`/`onLocalGeometrySettled` already
    /// establish.
    var onFirstFrameGateCleared: (() -> Void)?

    /// The chrome most recently applied to the real `NSWindow` via `applyChromeNow(_:)`, so
    /// a redundant call (e.g. a WindowUpdate that re-merges the same style bits this window
    /// already has) is a cheap no-op rather than unconditionally reassigning
    /// `styleMask`/`level`/`hasShadow` and re-preserving the frame on every single order.
    /// `nil` until the first real application -- distinct from `pendingChrome` below, which
    /// tracks "most recently requested" even while gated (see that property's own doc
    /// comment for why the two can differ).
    private var appliedChrome: WindowChrome?
    /// Real-host regression (2026-08-23, post-W2 first-frame-gate investigation): mutating
    /// `NSWindow.styleMask` (and, separately, calling `-setFrame:display:`) on a window that
    /// has NEVER been ordered onto screen was observed live to force the window server to
    /// register/insert the window into `NSApp.orderedWindows` as a side effect -- entirely
    /// independent of any explicit `orderFront`/`orderOut` call. This reproduced exactly the
    /// same "hidden window silently becomes on-screen" failure class the Z-order
    /// investigation traced to unconditional `order(_:relativeTo:)` calls (see
    /// `RemoteWindowRegistry.applyZOrder`'s own doc comment on the still-unexplained
    /// `isVisible`/`orderedWindows` disagreement) -- six real windows (dxdiag/charmap) were
    /// observed present in `NSApp.orderedWindows` with `window.isVisible == false` moments
    /// after their first `applyChrome` call, then later flagged as first-frame gate
    /// VIOLATIONs (visible with no content, no timeout) once something downstream started
    /// reading them as shown.
    ///
    /// The fix: `applyChrome(_:)` NEVER touches AppKit while `hasClearedFirstFrameGate` is
    /// false -- it only records the request here, exactly mirroring `setVisible`/
    /// `pendingVisible`'s existing precedent for the identical class of "don't touch AppKit
    /// until the gate clears" problem. `present`/`firstFrameTimeoutFired` apply whatever is
    /// pending at the exact moment they clear the gate (right before the `orderFront`/
    /// `orderOut` call that immediately follows makes the window's on-screen state
    /// authoritative again either way).
    private var pendingChrome: WindowChrome?

    /// Phase 2 W0③ first-frame gating: true once this window's real order/visibility gate
    /// has cleared -- either because its first GFX surface actually presented (see
    /// `present(surface:mappedSize:via:)`) or because `firstFrameTimeout` fired first (see
    /// `firstFrameTimeoutFired()`). While this is false, `setVisible` records the
    /// requested show-state in `pendingVisible` but never calls `orderFront`/`orderOut` on
    /// the real `NSWindow` -- this is the actual fix for the black-box gap that
    /// `win.backgroundColor = .black` below used to just document as an accepted cosmetic
    /// artifact (W4b review L3).
    ///
    /// `private(set)` (Phase 2 W2 real-host regression round 2): `RemoteWindowRegistry.
    /// currentTopDownWindowIds()` reads this to exclude gate-held windows from Z-order
    /// application -- see that method's own doc comment for why `NSApp.orderedWindows`
    /// alone was confirmed live to be insufficient ground truth for "on screen."
    private(set) var hasClearedFirstFrameGate = false
    /// The RAIL server's last-requested show-state for this window (see `setVisible`),
    /// captured even while gated so the correct state can be applied the instant the gate
    /// clears. Irrelevant once `hasClearedFirstFrameGate` is true -- `setVisible` applies
    /// immediately at that point, same as before this feature existed.
    private var pendingVisible = false
    /// Real-host regression, round 3 (2026-08-23, W2 first-frame-gate investigation): the
    /// FOURTH bypass route of the same failure class -- `activateLocally()`'s
    /// `-makeKeyAndOrderFront:` call orders a gate-held window front exactly like the three
    /// routes already fixed this round (Z-order's `order(_:relativeTo:)`, the chrome
    /// styleMask/frame mutation, and construction-time window-server registration). Observed
    /// live in the maximize scenario: the server converges focus onto a freshly-(re)created
    /// About window via `FocusAuthority`'s server-truth-only `.makeKey` effect (no user click
    /// involved at all -- `serverDesktopUpdate`'s own "no local activation in flight, follow
    /// the server immediately" branch), landing on `activateLocally()` before that window's
    /// first frame had ever presented. Mirrors `pendingVisible`/`pendingChrome`'s exact
    /// precedent: while gated, only record the request; `present`/`firstFrameTimeoutFired`
    /// apply it once they clear the gate. Verified against `FocusAuthority`'s own source
    /// (Packages/MacdowsCore/Sources/MacdowsCore/FocusAuthority.swift) before relying on the
    /// team's "it trusts effects, doesn't read key state back" claim: `FocusAuthority`'s
    /// entire public surface (`serverDesktopUpdate`/`localActivate`/`enqueueKeyboardEvent`/
    /// `tick`/`generationReset`) takes no AppKit/NSWindow input of any kind, and every
    /// decision about "what's currently keyed" is derived purely from its own `state`
    /// (`currentlyKeyedWindow`, a read of `FocusState` it set itself) plus server truth and
    /// time -- it never reads `NSWindow.isKeyWindow` or any other real AppKit state back, so
    /// deferring the actual `makeKeyAndOrderFront:` call in time (never in whether it
    /// happens) cannot desync it from `FocusAuthority`'s own model. Confirmed true, not
    /// assumed.
    private var pendingActivate = false
    /// adr/0010 §2: the fourth member of the `pendingChrome`/`pendingVisible`/
    /// `pendingActivate` trio above -- same precedent, same reason: mutating
    /// `contentLayer.mask`/`window.isOpaque`/`window.backgroundColor` while
    /// `hasClearedFirstFrameGate` is false risks the exact same premature window-server
    /// registration those three routes were fixed against (`applyChromeNow`'s own doc
    /// comment has the full real-host finding). `nil` means "no mask request recorded yet"
    /// (distinct from `WindowShape.MaskResult.none`, "explicitly no mask") -- `applyMask`
    /// always records into this before checking the gate, so `present`/
    /// `firstFrameTimeoutFired` apply whatever was most recently requested, never a stale
    /// default.
    private var pendingMask: WindowShape.MaskResult?
    /// Real-host regression fix (2026-08-23, maximize-scenario investigation, team-lead
    /// review): the FIFTH member of the `pendingChrome`/`pendingVisible`/`pendingActivate`/
    /// `pendingMask` family -- `updateFrame(contentRect:)` below used to call
    /// `window.setFrame` unconditionally regardless of `hasClearedFirstFrameGate`, unlike
    /// every other AppKit-mutating method on this class. This was latent (not yet the
    /// mechanism behind any PRIOR real-host finding) until `RemoteWindowRegistry`'s new
    /// `.surfaceMapped`-triggered reapply (see that handler's own doc comment for the actual
    /// regression this closes: a window stuck at its pre-remap size forever after a
    /// server-side resize) started calling `updateFrame` from a SECOND call site --
    /// `.surfaceMapped` (GFX `MapSurfaceToWindow`) naturally arrives BEFORE a window's first
    /// `.frameReady`/`present()` in the ordinary case (the server must map a surface before
    /// it can send frame data for it), meaning nearly every window's FIRST surface map would
    /// otherwise call `window.setFrame` on a still-gate-held window -- reproducing the exact
    /// "hidden window silently becomes on-screen" failure class `pendingChrome`'s own doc
    /// comment documents, on nearly every window, not as a rare race. Gating `updateFrame`
    /// itself (rather than only the new call site) also closes what was already a
    /// structurally-identical, just less-frequently-triggered gap in the ORIGINAL
    /// `handleWindowOrder`-driven path.
    private var pendingContentRect: NSRect?
    /// The `CAShapeLayer` built once and reused across mask updates (rebuilding a new layer
    /// per order would churn `contentLayer.mask` unnecessarily) -- `nil` until the first
    /// `.rects` mask is actually applied.
    private var maskLayer: CAShapeLayer?
    /// Tracks whether the CURRENTLY applied mask is "material" (adr/0010 §2's own term) --
    /// i.e. whether `window.isOpaque`/`.backgroundColor` are presently in their transparent-
    /// mask state, so a later mask update that reverts to trivial/none can restore the
    /// original opaque fast path rather than leaving them stuck transparent forever. See
    /// `applyMaskNow`'s own doc comment for the full materiality definition.
    private var appliedMaskIsMaterial = false
    /// Diagnostics only (Tools/window-smoke's `[shape]` log line) -- the rect count of the
    /// most recently APPLIED mask (0 for `.none`), independent of the wire's own truncated/
    /// count bookkeeping (which `RemoteWindowRegistry.geometry` already tracks separately).
    private(set) var appliedMaskRectCount = 0
    /// Diagnostics only (Tools/window-smoke's first-frame gating assertion) -- true if this
    /// window's gate cleared via `firstFrameTimeout` rather than a real presented frame,
    /// i.e. it was shown with no content yet. Not read anywhere on the real rendering path.
    private(set) var firstFrameTimedOut = false
    /// Cancellable handle for the 2s no-paint fallback armed in `init` -- cancelled by
    /// `present` (a real frame arrived first) and by `close(via:)` (nothing left to time
    /// out). `DispatchWorkItem` rather than a plain `asyncAfter` closure specifically so it
    /// can be cancelled outright rather than merely superseded (contrast
    /// `RemoteWindowRegistry`'s move-throttle trailing-flush, which only ever needs the
    /// latter).
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    /// adr/0010 §5: the ordinary tier, unchanged from Phase 2 W0③ — 2s, still the default
    /// for every titled (non-popup) window.
    static let defaultFirstFrameTimeout: TimeInterval = 2.0
    /// adr/0010 §5: the popup tier — a menu/tooltip-class window (`WindowChrome.titled ==
    /// false`, the ADR's own discriminator, NOT `WS_POPUP`) is something a user just clicked
    /// and expects to appear immediately; 2s of blank silence reads as "broken," not
    /// "loading," for something this transient. 250ms is plan §4 W4's own
    /// WindowCreate→first-content p95 gate (≤100ms, LAN) times 2.5 — comfortable headroom
    /// that the normal path never approaches, tripping only when something is genuinely
    /// wrong (see this constant's own ADR section for the full cost/benefit argument).
    static let popupFirstFrameTimeout: TimeInterval = 0.25
    /// Set once at `init` (the ADR's own "构造期一次性选定，不中途 re-arm" instruction — shortening
    /// an in-flight timeout has no well-defined semantics) from whichever of the two
    /// constants above `RemoteWindowRegistry` picked, based on this window's own
    /// `WindowChrome.titled` at creation time.
    private let firstFrameTimeout: TimeInterval

    /// W4c review H1: token for the `NSWindow.didResignKeyNotification` observer below,
    /// removed in `close(via:)`/`deinit` — a block-based `NotificationCenter` observer
    /// keeps firing (and keeps this instance alive, via the closure's captures) until
    /// explicitly removed; it does not get torn down automatically just because the
    /// underlying `NSWindow` closes.
    private var didResignKeyObserver: NSObjectProtocol?

    /// Phase 2 W3 (docs/plans/phase2.md §2 W3, adr/0012's optimistic-prediction principle
    /// applied to geometry): incremented by each of the two independent local-geometry-
    /// authority holders this window can have in flight at once -- a native titlebar
    /// drag/live-resize (tracked via the notification observers below) and the server's own
    /// announced ServerLocalMoveSize modality (`beginServerAnnouncedMoveResize`/
    /// `endServerAnnouncedMoveResize`, called by `RemoteWindowRegistry`). A counter, not a
    /// bool, specifically so the two triggers can never prematurely un-suppress each other
    /// if they ever overlap in the same window at once. `updateFrame` below refuses to apply
    /// inbound server geometry to this window's real `NSWindow` while this is nonzero --
    /// the bookkeeping in `RemoteWindowRegistry.geometry[windowId]` (this window's
    /// server-side state cache) still updates regardless; only the AppKit-visible
    /// application is suppressed, so the server's authoritative value is never lost, just
    /// not fought against mid-gesture.
    private var geometryAuthoritySuppressionCount = 0
    private var isLocalGeometrySuppressed: Bool { geometryAuthoritySuppressionCount > 0 }

    /// True between `NSWindow.willStartLiveResizeNotification` and
    /// `didEndLiveResizeNotification` -- AppKit's own clean begin/end pair for an
    /// *interactive* resize (never posted for a programmatic `-setFrame:display:`, which is
    /// why the move-settle debounce below exists at all: move has no equivalent pair).
    /// Guards `handleLocalGeometryChanged` from double-counting a resize's own incidental origin
    /// changes (dragging a top-left resize handle moves the origin too) against the
    /// suppression counter a second time -- and, since F-R2, the per-step `didResize`
    /// notifications the same gesture posts, which would otherwise start a competing debounce.
    private var isInLiveResize = false
    /// Debounce work item for settling a native titlebar drag (see `handleLocalGeometryChanged`'s
    /// own doc comment for why a trailing-edge debounce, not a clean "did end move"
    /// callback, is the only way to detect drag-end for a *move* -- AppKit has no
    /// `windowDidEndLiveMove` counterpart to `didEndLiveResizeNotification`). Mirrors
    /// `RemoteWindowRegistry.pendingTrailingMove`'s own trailing-flush idiom (asyncAfter,
    /// cancelled/reissued on every new event inside the window, not a repeating `Timer`).
    private var moveSettleWorkItem: DispatchWorkItem?
    private static let moveSettleDebounce: TimeInterval = 0.2

    private var didMoveObserver: NSObjectProtocol?
    private var didResizeObserver: NSObjectProtocol?
    private var willStartLiveResizeObserver: NSObjectProtocol?
    private var didEndLiveResizeObserver: NSObjectProtocol?

    /// Phase 2 W3: set around every INTERNAL `window.setFrame`/`.styleMask` mutation this
    /// class makes on the server's behalf (`updateFrame`'s own server-driven frame apply,
    /// and `applyChromeNow`'s styleMask-change + frame-restore pair) -- AppKit posts
    /// `NSWindow.didMoveNotification` for ANY origin change, programmatic or interactive,
    /// with no way to distinguish "the server just told us to move" from "the user is
    /// dragging" at the notification level itself. Without this flag, `updateFrame`
    /// applying an ordinary server-driven `WindowUpdate` would trigger
    /// `handleLocalGeometryChanged` exactly like a real drag, and -- after the 200ms debounce --
    /// echo that same geometry straight back to the server as a spurious
    /// `ClientWindowMove`, on every single server-initiated move. The same applies to
    /// `NSWindow.didResizeNotification` (F-R2, 2026-09-02): a server-driven `WindowUpdate`
    /// that changes the SIZE posts `didResize` exactly like a local programmatic resize, so
    /// the shared handler checks this flag before either notification can claim a gesture.
    /// `willStartLiveResizeNotification`/`didEndLiveResizeNotification` need no equivalent
    /// guard: AppKit only ever posts that pair for a genuine interactive (mouse-tracked)
    /// resize loop, never as a side effect of a programmatic `-setFrame:`/`.styleMask` change.
    /// The set/clear bracket around `setFrame` only works because the block observers above are
    /// delivered INLINE on the posting (main) thread -- measured (review fr2-r1 probe Q1);
    /// `RemoteWindowLocalGeometrySyncTests.serverDrivenFrameApplyIsNotEchoedBackAsALocalSettle`
    /// is the guard against that premise ever changing (a different queue, or an async apply).
    private var isApplyingProgrammaticFrame = false

    /// `contentRect` is already in macOS screen space (post `WindowGeometry.macRect`) — this
    /// type does no Windows/Mac coordinate conversion of its own; that's
    /// `RemoteWindowRegistry`'s job, using `MacdowsCore.WindowGeometry` exclusively (per the
    /// W4b task spec: no second, ad hoc coordinate-math implementation anywhere else in this
    /// layer). Real-host regression (2026-08-23, W3 first live verification): RAIL's
    /// geometry describes the remote window's own OUTER rect as the remote desktop sees it
    /// (the content view displays those pixels verbatim, remote titlebar included, per
    /// adr/0005 §2's "GFX surfaces ... carry PIXEL_FORMAT_BGRX32" finding) -- so this value
    /// is this window's CONTENT rect, never its `NSWindow.frame` directly. Constructed here
    /// with `styleMask: [.borderless]` unconditionally (chrome, if any, is applied later via
    /// `applyChrome`), so `contentRect == frame` at construction time regardless (zero
    /// chrome insets). Owner decision (2026-08-23, adr/0010 §6, `nativeChromePolicy`'s own
    /// doc comment has the full resolution): under today's `.never` policy `applyChromeNow`
    /// below never applies `.titled` either, so this equality holds for this window's
    /// entire lifetime, not just at construction -- the borderless<->titled divergence this
    /// comment used to warn about only existed under W2's now-reverted native-chrome path.
    /// - Parameter firstFrameTimeout: adr/0010 §5 — `RemoteWindowRegistry` passes
    ///   `Self.popupFirstFrameTimeout` for a window whose `StyleTranslator`-derived chrome
    ///   has `titled == false`, `Self.defaultFirstFrameTimeout` otherwise. Defaults to
    ///   `Self.defaultFirstFrameTimeout` so every pre-existing caller (tests, any future
    ///   caller that doesn't yet know about the popup tier) keeps Phase 2 W0③'s original
    ///   behavior unchanged.
    init(key: RemoteWindowKey, contentRect: NSRect, title: String, firstFrameTimeout: TimeInterval = RemoteWindow.defaultFirstFrameTimeout) {
        self.key = key
        self.firstFrameTimeout = firstFrameTimeout

        let win = RemoteWindowBackingWindow(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false // this class, not AppKit, owns the window's lifetime
        win.title = title
        win.hasShadow = true
        win.isOpaque = true
        // L3 (W4b review) resolved by Phase 2 W0③: this window is never ordered front
        // until either its first real surface presents or firstFrameTimeout fires (see
        // hasClearedFirstFrameGate below), so this solid-black background is no longer
        // something a user can actually see appear -- kept anyway as the layer's own
        // backing color for whatever sliver of a frame CoreAnimation might composite
        // before contentLayer.contents is first assigned.
        win.backgroundColor = .black

        let layer = CALayer()
        // M1/L8 (ADR-0015 §7 (c)/§9, U5 record-only): both VALUES below are deliberately
        // untouched this wave -- `contentsGravity`, `contentsScale` and `masksToBounds` are
        // W3's (ADR-0015 §8, and M1's own global MUST-NOT list). What M1 adds is the unit
        // statement `.resize` never had: it stretches a **remote px** source raster onto a
        // **mac pt** destination, so the ratio it silently applies is exactly this window's
        // remote-pixels-per-point. See `present(surface:mappedSize:via:)`'s doc comment for
        // the full derivation, why that ratio is 1:1 on today's hardware, and what W3 has to
        // measure before touching any of it.
        layer.contentsGravity = .resize
        layer.masksToBounds = true
        // GFX surfaces observed against a real host carry PIXEL_FORMAT_BGRX32 -- 32bpp
        // with an *ignored* 4th byte, not a real alpha channel (see CRSession.mm's
        // crb_gfx_update_window_from_surface comment for the empirical finding). Setting
        // this explicitly means CoreAnimation always treats this layer's content as fully
        // opaque regardless of whatever value that ignored byte actually happens to hold in
        // memory, rather than risking it being misread as a real (possibly
        // fully-transparent) alpha value.
        layer.isOpaque = true

        let contentView = RemoteWindowContentView(frame: NSRect(origin: .zero, size: contentRect.size))
        contentView.wantsLayer = true
        contentView.layer = layer
        win.contentView = contentView
        // W4c: without this, the very first click after a reconnect/relaunch would land on
        // a view AppKit hasn't yet made first responder, and mouseDown/keyDown wouldn't
        // reach RemoteWindowContentView's overrides at all until *something else* first
        // made it first responder (e.g. a second click) — makeFirstResponder here plus
        // acceptsFirstMouse==true together are what let a single click on a background
        // remote window both raise it and register as real forwarded input.
        win.makeFirstResponder(contentView)

        self.window = win
        self.contentLayer = layer
        self.contentView = contentView

        // Phase 2 W2 (task item 3): wires RemoteWindowBackingWindow's three action
        // overrides straight to `onChromeAction` -- see both types' own doc comments for
        // why these exist and what happens (or, deliberately, doesn't happen locally) when
        // they fire. [weak self]: these closures must not be what keeps a closed
        // RemoteWindow alive, same reasoning as every other closure in this initializer.
        win.onPerformClose = { [weak self] in self?.onChromeAction?(.close) }
        win.onPerformMiniaturize = { [weak self] in self?.onChromeAction?(.minimize) }
        win.onZoom = { [weak self] in self?.onChromeAction?(.zoom) }

        // W4c review H1: this window losing key status is the primary signal that this
        // client can no longer reliably observe the physical keyboard's modifier state
        // (e.g. the user Cmd-Tabbed to a different Mac app while holding Shift) --
        // RemoteWindowRegistry responds to the resulting .focusLost event by releasing
        // every modifier bit it currently has tracked as held (see
        // MacdowsCore.ModifierKeyTracker.releaseAll(_:)), rather than leaving RDP's own
        // modifier state stuck if the matching physical release never reaches this window
        // again. [weak contentView] rather than capturing self strongly: this closure must
        // not be what keeps a closed RemoteWindow's NSWindow alive.
        didResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: win, queue: .main
        ) { [weak contentView] _ in
            // `queue: .main` guarantees this always actually runs on the main thread/actor
            // already; assumeIsolated documents and asserts that (crashing loudly if it's
            // ever somehow wrong) rather than leaving a Swift 6 strict-concurrency error at
            // this call site -- same pattern Tools/window-smoke/main.swift's own Timer
            // closure uses for the identical "block-based API, statically Sendable,
            // dynamically always main-actor" situation.
            MainActor.assumeIsolated {
                contentView?.onEvent?(.focusLost)
            }
        }

        // Phase 2 W3: native titlebar drag/resize -> server sync (see `isInLiveResize`'s and
        // `moveSettleWorkItem`'s own doc comments for why this needs four separate observers, not
        // one: a move has no end signal and is debounced, an interactive resize has AppKit's
        // begin/end pair, and a programmatic resize posts only `didResize`). Uses
        // `NSNotification.Name` constants rather than `NSWindowDelegate` for the exact same reason
        // `didResignKeyObserver` above does -- this class isn't an `NSObject` subclass, and AppKit
        // exposes these four specific transitions as public notifications, sidestepping the need
        // for delegate conformance entirely. [weak self]: none of these must be what keeps a
        // closed RemoteWindow alive.
        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLocalGeometryChanged() }
        }
        // F-R2 (docs/upgrade-gate/2026-09-resize-leg-live.md §3.2, real-host run 2026-09-02;
        // measured on this machine: six scenarios in the controller's .titled/.resizable probe,
        // corroborated by an independent five-scenario probe and two borderless re-runs in review
        // -- fr2-r1's own probe was borderless too -- and `RemoteWindowLocalGeometrySyncTests`
        // re-pins it on the borderless styleMask this class actually uses): a programmatic
        // `-setFrame:display:` that changes the SIZE posts ONLY `didResizeNotification` -- not
        // `didMoveNotification`, even when the origin changes in the same call, and never the
        // live-resize pair (interactive-only). Without this observer a non-interactive local size
        // change (window-smoke's resize leg, a display reconfiguration (unmeasured, plausible), or
        // any other non-interactive frame change AppKit applies on the window's behalf -- min/max
        // constraints were measured NOT to be one: setting them neither moves an existing frame
        // nor posts anything, review fr2-r1) had no sync exit at all and never became a
        // `ClientWindowMove`. It feeds the SAME trailing-edge debounce as `didMove` -- one gesture,
        // one settle, whichever notifications AppKit chooses to post for it -- and is skipped
        // during an interactive resize (`isInLiveResize`), whose own clean end signal settles it.
        // `RemoteWindowLocalGeometrySyncTests` pins this. UNMEASURED (registered, review fr2-r1
        // I-2): whether AppKit can post a trailing `didResize` AFTER `didEndLiveResizeNotification`;
        // if it does, the same rect settles a second time 200ms later as a duplicate,
        // geometry-identical `ClientWindowMove` (the registry does not dedupe) and holds
        // `geometryAuthoritySuppressionCount` for that extra 200ms, during which inbound server
        // `WindowUpdate`s are refused. One hand-driven resize on a live host decides it.
        didResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLocalGeometryChanged() }
        }
        willStartLiveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLocalWillStartLiveResize() }
        }
        didEndLiveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLocalDidEndLiveResize() }
        }

        // Phase 2 W0③: arms the 2s no-paint fallback (see firstFrameTimeoutWorkItem's own
        // doc comment). [weak self]: this timer must not be what keeps a closed
        // RemoteWindow alive. assumeIsolated: same "block-based API, statically Sendable,
        // dynamically always main-actor" situation as the didResignKeyObserver closure
        // above.
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.firstFrameTimeoutFired()
            }
        }
        firstFrameTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + firstFrameTimeout, execute: timeoutWorkItem)
    }

    /// Diagnostics only (Tools/window-smoke's assertion battery) — not read anywhere on
    /// the real rendering path, which only ever needs `window`/`present`/`close` above.
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }
    var hasDisplayedContent: Bool { contentLayer.contents != nil }
    var title: String { window.title }
    /// Diagnostics only (maximize-scenario real-host regression investigation, 2026-08-23):
    /// the live value of `geometryAuthoritySuppressionCount` -- `updateFrame(contentRect:)`
    /// silently no-ops while this is nonzero (see that method's own doc comment). Exposed so
    /// a test harness can directly OBSERVE whether a dropped server-driven geometry update
    /// (e.g. a maximize's own `WindowUpdate`) coincided with suppression being active,
    /// rather than inferring it indirectly from `ServerLocalMoveSize` log lines alone --
    /// `isMoveSizeStart`/`stop` pairing for a server-initiated operation (as opposed to a
    /// local drag) is genuinely untested wire behavior (adr/0008 §0's own caveat: never
    /// observed in any phase05 sample), so this makes the hypothesis directly checkable
    /// against real wire evidence instead of staying inferential.
    var debugGeometrySuppressionCount: Int { geometryAuthoritySuppressionCount }

    /// Diagnostics only (Tools/window-smoke's pixel-level assertion battery, W4b review
    /// round 2 -- the round-1 "screenshot looked fine" call was wrong, since nothing
    /// actually checked pixel content; this reads the real backing store directly instead).
    /// Samples `sampleCount` points on a deterministic grid spread across the bottom
    /// `bottomFraction` of the *currently displayed* IOSurface's own pixel data (not a
    /// screenshot -- sidesteps Screen Recording TCC entirely, and can't be fooled by a
    /// stale/wrong-window capture the way a full-screen screenshot can). Returns the
    /// fraction of sampled pixels that are NOT close to solid white, or `nil` if nothing is
    /// currently displayed. BGRA/BGRX byte order (adr/0005 §2's own empirical finding) --
    /// "close to white" means B/G/R are all above a high threshold, matching what a human
    /// eye would call white rather than requiring an exact 0xFFFFFF match (anti-aliased
    /// text edges, slight color variation, etc.).
    func nonWhitePixelRatio(inBottomFraction bottomFraction: Double, sampleCount: Int) -> Double? {
        guard let surface = displayedSurface else { return nil }
        // Sample within the mapped content sub-rect only: the IOSurface's 64-aligned
        // padding rows/columns hold whatever bytes the allocator left there and used to be
        // counted as "non-white content", quietly inflating (and de-meaning) every ratio
        // this diagnostic ever reported. Falls back to the full allocation when no mapped
        // size is known (pre-map frame, or a plain-path server that never told us).
        var width = IOSurfaceGetWidth(surface)
        var height = IOSurfaceGetHeight(surface)
        if let mapped = displayedMappedSize, mapped.width > 0, mapped.height > 0 {
            width = min(width, Int(mapped.width))
            height = min(height, Int(mapped.height))
        }
        guard width > 0, height > 0, sampleCount > 0 else { return nil }

        IOSurfaceLock(surface, IOSurfaceLockOptions(rawValue: 1 /* kIOSurfaceLockReadOnly */), nil)
        defer { IOSurfaceUnlock(surface, IOSurfaceLockOptions(rawValue: 1), nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)

        let bottomStartY = Int(Double(height) * (1.0 - bottomFraction))
        guard bottomStartY < height else { return nil }
        let bottomRowCount = height - bottomStartY

        var nonWhiteCount = 0
        let columns = max(1, Int(Double(sampleCount).squareRoot().rounded(.up)))
        let rows = max(1, (sampleCount + columns - 1) / columns)
        var sampled = 0
        for row in 0..<rows {
            for col in 0..<columns {
                guard sampled < sampleCount else { break }
                let x = min(width - 1, (col * width) / max(1, columns))
                let y = bottomStartY + min(bottomRowCount - 1, (row * bottomRowCount) / max(1, rows))
                let offset = y * bytesPerRow + x * 4
                let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let b = ptr[0]
                let g = ptr[1]
                let r = ptr[2]
                sampled += 1
                if !(b > 240 && g > 240 && r > 240) {
                    nonWhiteCount += 1
                }
            }
        }
        guard sampled > 0 else { return nil }
        return Double(nonWhiteCount) / Double(sampled)
    }

    /// Phase 2 W3: refuses to touch the real `NSWindow` while
    /// `isLocalGeometrySuppressed` is true (see that property's own doc comment) -- the
    /// server's own geometry echo for this window is simply not applied for the moment,
    /// never queued/merged against the in-flight local gesture. Once suppression lifts
    /// (drag/resize settles, or the server's ServerLocalMoveSize modality ends), the NEXT
    /// call to this method with the server's current authoritative content rect applies
    /// normally -- "server wins" from then on, exactly as before this feature existed.
    ///
    /// Real-host regression (2026-08-23, W3 first live verification): `contentRect` is this
    /// window's CONTENT rect (see `init`'s own doc comment for why), NOT a frame -- converted
    /// to the real outer frame via `NSWindow.frameRect(forContentRect:)`, which accounts for
    /// this window's CURRENT `styleMask`'s chrome insets -- zero under today's
    /// `nativeChromePolicy == .never` (owner decision, 2026-08-23, adr/0010 §6: that
    /// policy's own doc comment has the full resolution), matching Phase 1's exact
    /// behavior for this window's entire lifetime, not just while un-styled. Before the W2
    /// fix this comment originally documented, this method set `window.frame` directly from
    /// RAIL-derived geometry, which was silently correct only because Phase 1 windows were
    /// always borderless (frame == content rect there) -- W2's since-reverted titled chrome
    /// made that assumption wrong by exactly the chrome inset amount (~14pt observed live);
    /// the `frameRect(forContentRect:)` conversion below is kept regardless, since it stays
    /// the correct identity transform under the current borderless-only policy and remains
    /// correct if a future policy change ever reintroduces real insets.
    /// Real-host regression fix (2026-08-23, maximize-scenario investigation): now gated on
    /// `hasClearedFirstFrameGate` -- see `pendingContentRect`'s own doc comment for why.
    /// While gated, only records the request; `present`/`firstFrameTimeoutFired` apply
    /// whatever is pending at the exact moment they clear the gate, mirroring
    /// `pendingChrome`/`pendingMask`'s own precedent exactly.
    func updateFrame(contentRect: NSRect) {
        pendingContentRect = contentRect
        guard hasClearedFirstFrameGate else { return }
        applyContentRectNow(contentRect)
    }

    /// The actual `window.setFrame` mutation -- only ever called once
    /// `hasClearedFirstFrameGate` is true (from `updateFrame` once already cleared, or from
    /// `present`/`firstFrameTimeoutFired` at the exact moment they clear it), mirroring
    /// `applyChromeNow`/`applyMaskNow`'s own "only called once already gate-cleared"
    /// contract exactly. `isLocalGeometrySuppressed`'s own doc comment covers why THAT guard
    /// stays here rather than moving to `updateFrame` -- suppression is a live, in-flight
    /// concern independent of the first-frame gate (in practice a gate-held window is never
    /// suppressed at all, since suppression only ever starts from a local drag/resize or a
    /// `ServerLocalMoveSize` modality, neither plausible against a window the gate has never
    /// let on screen -- but this keeps the check exactly where it always was rather than
    /// assuming that invariant elsewhere).
    private func applyContentRectNow(_ contentRect: NSRect) {
        guard !isLocalGeometrySuppressed else { return }
        let targetFrame = window.frameRect(forContentRect: contentRect)
        guard window.frame != targetFrame else { return }
        isApplyingProgrammaticFrame = true
        window.setFrame(targetFrame, display: true)
        isApplyingProgrammaticFrame = false
    }

    func updateTitle(_ title: String) {
        guard window.title != title else { return }
        window.title = title
    }

    // MARK: - Phase 2 W3: local move/resize -> server sync

    /// Native titlebar drag (`didMove`) or a non-interactive frame change (`didResize`, F-R2):
    /// `didMove` fires on every intermediate position during a drag, not just once at the end
    /// (AppKit has no `windowDidEndLiveMove` counterpart to `didEndLiveResizeNotification` --
    /// this is the "standard workaround" the task spec itself calls for: debounce on the
    /// trailing edge of repeated notifications), and `didResize` rides the same debounce so a
    /// burst of programmatic frame changes settles once, reporting the last frame. Ignored
    /// during a live *resize* (`isInLiveResize`) -- both a resize's own incidental origin
    /// changes (e.g. dragging a top-left handle) and its per-step `didResize` notifications are
    /// settled by `handleLocalDidEndLiveResize` instead, which has AppKit's own clean end
    /// signal and doesn't need a debounce at all.
    private func handleLocalGeometryChanged() {
        guard !isApplyingProgrammaticFrame else { return }
        guard !isInLiveResize else { return }
        if moveSettleWorkItem == nil {
            // First didMove of a fresh gesture (no debounce already in flight) -- claim
            // suppression exactly once per gesture, not once per didMove callback.
            geometryAuthoritySuppressionCount += 1
        }
        moveSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleLocalMove() }
        }
        moveSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveSettleDebounce, execute: workItem)
    }

    /// Fires `Self.moveSettleDebounce` after the last observed `didMove`/`didResize` -- the
    /// gesture is presumed over (no clean end signal exists for a move or a programmatic
    /// resize, see `handleLocalGeometryChanged`'s own doc comment), so this releases
    /// suppression and reports the final frame upward for `RemoteWindowRegistry` to sync to
    /// the server.
    private func settleLocalMove() {
        moveSettleWorkItem = nil
        geometryAuthoritySuppressionCount = max(0, geometryAuthoritySuppressionCount - 1)
        // Real-host regression: report the CONTENT rect, not the raw frame -- see
        // `onLocalGeometrySettled`'s own doc comment.
        onLocalGeometrySettled?(window.contentRect(forFrameRect: window.frame))
    }

    /// AppKit's own clean begin signal for an interactive resize -- claims suppression
    /// immediately (unlike move, which only learns a gesture started from its first
    /// `didMove`). Also cancels/absorbs any move-debounce already in flight: a resize that
    /// starts mid-way through what looked like a move gesture (e.g. the user was dragging,
    /// then grabbed a resize handle) hands settling over to
    /// `handleLocalDidEndLiveResize`'s own clean end signal instead of the move debounce.
    private func handleLocalWillStartLiveResize() {
        isInLiveResize = true
        if moveSettleWorkItem != nil {
            moveSettleWorkItem?.cancel()
            moveSettleWorkItem = nil
            geometryAuthoritySuppressionCount = max(0, geometryAuthoritySuppressionCount - 1)
        }
        geometryAuthoritySuppressionCount += 1
    }

    /// AppKit's own clean end signal for an interactive resize -- settles immediately (no
    /// debounce needed, unlike move: this notification only fires once, exactly when the
    /// gesture is actually over).
    private func handleLocalDidEndLiveResize() {
        isInLiveResize = false
        geometryAuthoritySuppressionCount = max(0, geometryAuthoritySuppressionCount - 1)
        // Real-host regression: report the CONTENT rect, not the raw frame -- see
        // `onLocalGeometrySettled`'s own doc comment.
        onLocalGeometrySettled?(window.contentRect(forFrameRect: window.frame))
    }

    /// Phase 2 W3 task item 4 (docs/plans/phase2.md §2 W3): the server announcing a
    /// modality-level local move/size operation for this window via ServerLocalMoveSize's
    /// `isMoveSizeStart == true` (adr/0008 §1 -- this wire shape is unverified against any
    /// real sample; only the two simplest semantics, start/stop, are handled this slice).
    /// Independent trigger from the native-drag notification observers above -- both share
    /// the same suppression counter so neither can prematurely release the other.
    func beginServerAnnouncedMoveResize() {
        geometryAuthoritySuppressionCount += 1
    }

    /// The matching `isMoveSizeStart == false` transition: "release + treat like settle"
    /// (task item 4's own instruction) -- reports the current frame exactly like a native
    /// drag settling, in case whatever the server's own gesture left this window at
    /// diverged from this class's last-known frame.
    func endServerAnnouncedMoveResize() {
        geometryAuthoritySuppressionCount = max(0, geometryAuthoritySuppressionCount - 1)
        // Real-host regression: report the CONTENT rect, not the raw frame -- see
        // `onLocalGeometrySettled`'s own doc comment.
        onLocalGeometrySettled?(window.contentRect(forFrameRect: window.frame))
    }

    /// Phase 2 W3 task item 3: applies `ServerMinMaxInfo`'s track-size fields
    /// (`MacdowsCore.MinMaxInfoTranslator`'s already sentinel-filtered output) as this
    /// window's `NSWindow.minSize`/`.maxSize`. `nil` on either side of a pair substitutes
    /// AppKit's own "unconstrained" sentinel here -- `.zero` for min, `.greatestFiniteMagnitude`
    /// for max -- rather than in the pure `MacdowsCore` translator, which stays free of the
    /// AppKit boundary (adr/0006 §2).
    ///
    /// Deliberately outside the `isApplyingProgrammaticFrame` guard: assigning `minSize`/`maxSize`
    /// neither moves an existing frame nor posts `didResize`/`didMove` (measured, review fr2-r1:
    /// AppKit does not retroactively clamp, and a later programmatic `setFrame` is not clamped by
    /// them either), so there is no frame change here for the guard to hide.
    func applyTrackSizeConstraints(_ constraints: WindowTrackSizeConstraints) {
        window.minSize = NSSize(width: constraints.minWidth ?? 0, height: constraints.minHeight ?? 0)
        window.maxSize = NSSize(
            width: constraints.maxWidth ?? .greatestFiniteMagnitude,
            height: constraints.maxHeight ?? .greatestFiniteMagnitude
        )
    }

    /// Phase 2 W2 (docs/plans/phase2.md §2 W2 task item 3): requests one
    /// `MacdowsCore.WindowChrome` value (from `StyleTranslator.chrome`) be applied to this
    /// window. Real-host regression fix (see `pendingChrome`'s own doc comment): while
    /// `hasClearedFirstFrameGate` is false, this ONLY records the request -- it must not
    /// touch `NSWindow` at all, since mutating `styleMask`/`frame` on a window that's never
    /// been ordered onto screen was observed live to force premature window-server
    /// registration. Once the gate has already cleared (the common case for any style
    /// change arriving after this window's first real frame), applies immediately.
    func applyChrome(_ chrome: WindowChrome) {
        pendingChrome = chrome
        guard hasClearedFirstFrameGate else { return }
        applyChromeNow(chrome)
    }

    /// The actual `NSWindow.styleMask`/`.level`/`.hasShadow` mutation -- only ever called
    /// once `hasClearedFirstFrameGate` is true (from `applyChrome` once already cleared, or
    /// from `present`/`firstFrameTimeoutFired` at the exact moment they clear it). Idempotent
    /// against a redundant call with the same chrome (`appliedChrome` short-circuit) -- a
    /// WindowUpdate that re-merges unrelated fields (offset/size/show) but leaves style
    /// unchanged must not churn styleMask on every single order.
    ///
    /// CONTENT RECT preservation (real-host regression, 2026-08-23, corrects this method's
    /// original "frame preservation" design): `NSWindow.styleMask` and `.frame` interact in
    /// AppKit -- a titled window's frame includes the titlebar strip, a borderless one
    /// doesn't, so toggling `.titled` shifts how `.frame` relates to the window's own content
    /// region. What must survive a chrome change is the CONTENT rect (the remote pixels'
    /// on-screen position/size, which `RemoteWindowRegistry.macContentRect(for:)` most
    /// recently computed from the RAIL order and `updateFrame` applied) -- NOT the raw
    /// frame. Capturing `window.contentRect(forFrameRect: window.frame)` before the
    /// styleMask assignment, then deriving the new frame from THAT via
    /// `window.frameRect(forContentRect:)` under the NEW styleMask, keeps the remote pixels
    /// exactly where RAIL says they belong regardless of how much chrome this window's
    /// outer frame gained or lost -- this method's original version instead restored the
    /// raw frame unchanged, which was silently correct only for borderless<->borderless
    /// (zero insets either way); going borderless->titled left the content rect shrunk by
    /// the new titlebar's height inside the old, unchanged frame, exactly the ~14pt
    /// real-host divergence that first exposed this whole class of bug (see
    /// `RemoteWindow.init`'s and `updateFrame`'s own doc comments for the full finding).
    ///
    /// DOUBLE TITLEBAR QUESTION -- RESOLVED (owner decision, 2026-08-23): adr/0010 §6 left
    /// this an explicitly open question ("留成加法") between native macOS chrome stacked
    /// above the remote window's own Windows titlebar pixels, or the Windows titlebar
    /// alone. The owner ratified "只有 Windows 标题栏" -- remote windows keep ONLY the
    /// remote-drawn titlebar (it's already baked into the RAIL pixels this window displays
    /// verbatim, per `init`'s own doc comment), and the native `.titled` chrome W2
    /// introduced here is removed. See `nativeChromePolicy` immediately below for the
    /// actual rendering switch this resolution installs. Per adr/0010 §6's own text, this
    /// keeps `topInset` permanently 0 (no crop of the remote titlebar out of the displayed
    /// content is needed, since there is no second, native titlebar to make redundant) --
    /// the crop machinery that resolving the OTHER way would have required
    /// (`present(surface:mappedSize:via:)`'s own contentsRect crop gaining a second,
    /// source-side titlebar crop) stays exactly the "left undone, flagged for the owner"
    /// state this comment used to describe, just now because the owner chose the branch
    /// that never needs it, not because the work remains outstanding.
    ///
    /// adr/0010 §6/W2 owner decision (2026-08-23): pick the rendered styleMask from THIS
    /// policy, not from `chrome.titled` directly. `WindowChrome`'s semantic fields stay
    /// computed exactly as `StyleTranslator.chrome` derives them from Win32 style bits --
    /// `titled` in particular keeps driving `RemoteWindowRegistry`'s popup-tier
    /// first-frame-timeout choice (adr/0010 §5), Cmd+W's SC_CLOSE routing, and any future
    /// semantic consumer unchanged. Only the AppKit-visible RENDERING of that semantic
    /// value is redirected here -- a single switch point so a future owner reversal (back
    /// to native chrome, or some third option) is a one-line change, not a re-design,
    /// mirroring the "留成加法" discipline adr/0010 §6 itself asked for, just resolved in
    /// the other direction than that ADR left open.
    enum NativeChromePolicy {
        /// Never apply native `.titled` AppKit chrome, regardless of what
        /// `WindowChrome.titled` says -- every remote window renders fully borderless,
        /// keeping only whatever traffic-light/level/shadow affordances don't require
        /// `.titled` itself (see `applyChromeNow`'s mask construction below for exactly
        /// which bits survive).
        case never
    }
    /// The current owner decision (2026-08-23, this doc comment's own date). Changing this
    /// to a hypothetical future case is the entire scope of reversing today's decision --
    /// no other line in this file encodes "should this window get a native titlebar."
    static let nativeChromePolicy: NativeChromePolicy = .never

    private func applyChromeNow(_ chrome: WindowChrome) {
        guard chrome != appliedChrome else { return }
        let previousContentRect = window.contentRect(forFrameRect: window.frame)

        // `nativeChromePolicy` decides `.titled` (today: never) -- NOT `chrome.titled`
        // directly, per this method's own doc comment above. `.resizable` is kept
        // independent of `.titled`: AppKit enables native edge/corner drag-resize from
        // the `.resizable` styleMask bit alone, with no `.titled` requirement, so a
        // borderless-but-resizable window still gets that affordance. It also adds no
        // frame/content-rect inset either way (only `.titled`'s titlebar strip does),
        // so keeping it here cannot reintroduce the borderless<->titled content-rect
        // divergence this method's own "CONTENT RECT preservation" paragraph above
        // documents -- frame == content rect stays true with or without `.resizable`
        // under a `.never` policy, the exact "degenerate case" W3's content-rect math
        // (`macContentRect`/`updateFrame`/`handleLocalGeometrySettled`) already handles
        // with no changes needed on that side.
        var mask: NSWindow.StyleMask
        switch Self.nativeChromePolicy {
        case .never:
            mask = [.borderless]
        }
        if chrome.resizable {
            mask.insert(.resizable)
        }
        isApplyingProgrammaticFrame = true
        window.styleMask = mask
        let targetFrame = window.frameRect(forContentRect: previousContentRect)
        window.setFrame(targetFrame, display: window.isVisible)
        isApplyingProgrammaticFrame = false

        window.hasShadow = chrome.hasShadow
        window.level = chrome.level == .floating ? .floating : .normal

        appliedChrome = chrome
    }

    /// adr/0010 §2: requests `result` be applied as this window's `contentLayer.mask`.
    /// Mirrors `applyChrome(_:)`'s own gating exactly (`pendingMask` is the fourth member
    /// of that trio, see its own doc comment): while `hasClearedFirstFrameGate` is false,
    /// this ONLY records the request -- it must never touch `contentLayer.mask`/
    /// `window.isOpaque`/`.backgroundColor` before the gate clears, for the identical
    /// premature-window-server-registration reason `applyChrome`/`setVisible`/
    /// `activateLocally` were each fixed against. Once the gate has already cleared (the
    /// common case for any mask change arriving after this window's first real frame),
    /// applies immediately.
    func applyMask(_ result: WindowShape.MaskResult) {
        pendingMask = result
        guard hasClearedFirstFrameGate else { return }
        applyMaskNow(result)
    }

    /// The actual `contentLayer.mask`/`window.isOpaque`/`.backgroundColor`/
    /// `invalidateShadow()` mutation -- only ever called once `hasClearedFirstFrameGate` is
    /// true, mirroring `applyChromeNow`'s own "only called once already gate-cleared"
    /// contract exactly.
    ///
    /// MATERIALITY (adr/0010 §2's "仅当窗口真带非平凡 mask 时" clause): a mask is "material"
    /// when it would actually clip something visible -- `.none` never is; a single `.rects`
    /// entry that (within a half-point epsilon, for floating-point slop) exactly covers the
    /// current content bounds is ALSO not material (an ordinary rectangular window whose
    /// server-reported visibility rect happens to be its own full client area, ordinary and
    /// common per adr/0008 §0's own sample survey -- masking it would pay the transparency
    /// cost below for zero visual effect). Everything else (0 rects -- a real full clip --
    /// or 2+ rects, or a single rect that doesn't cover the full bounds) is material.
    ///
    /// Only material masks pay adr/0010 §2's "阴影与不透明" cost (`window.isOpaque = false`,
    /// `.backgroundColor = .clear`, `invalidateShadow()`) -- a non-masked/trivially-masked
    /// window keeps the existing all-opaque fast path (adr/0005 §2) untouched. This also
    /// REVERTS correctly: a window that goes from material back to trivial/none (e.g.
    /// un-maximizing restores rule 4's cleared mask, or a resize happens to land the visible
    /// rect back on the full bounds) restores `isOpaque = true`/`.backgroundColor = .black`
    /// (matching `init`'s own original values) rather than staying transparent forever --
    /// the ADR's own text only describes the forward (non-masked -> masked) direction
    /// explicitly, but leaving a window permanently paying the transparency cost after its
    /// mask genuinely stopped mattering would itself violate the same "keep the fast path
    /// for non-masked windows" principle the ADR states for the forward case.
    private func applyMaskNow(_ result: WindowShape.MaskResult) {
        // UNIT (ADR-0015 §1 vocabulary, M1/L8 tagging pass): `contentView.bounds.size` is
        // **mac pt** -- an AppKit view's own bounds -- and so is every `LayerRect` in
        // `result` (`WindowShape.LayerRect`'s unit note: layer-local points, same unit,
        // bottom-left origin of this layer rather than of the screen). The two are therefore
        // directly comparable below with no conversion, which is the whole reason this method
        // is a *consumer* of the unit contract and not the place that establishes it: the one
        // remote-px/mac-pt boundary in the mask pipeline is the registry call that produced
        // `result` (`RemoteWindowRegistry.computeMaskResult`, ADR-0015 §7's "(c) 的位置更正";
        // §9's L8 row states plainly that the boundary is not in this file).
        let contentSize = contentView.bounds.size
        let material = Self.isMaterialMask(result, contentSize: contentSize)

        switch result {
        case .none:
            contentLayer.mask = nil
            appliedMaskRectCount = 0
        case .rects(let rects):
            let shape = maskLayer ?? {
                let layer = CAShapeLayer()
                layer.fillRule = .nonZero
                maskLayer = layer
                return layer
            }()
            // Both lines below are in mac pt: the mask layer covers the content view exactly,
            // and each path rect is a `LayerRect` in that same space. `CGRect(layerPoints:)`
            // (bottom of this file) is the one named conversion the four `Double`s go through
            // -- identity by construction, so the emitted path is bit-for-bit what the
            // previous bare `CGRect(x:y:width:height:)` splat produced.
            shape.frame = CGRect(origin: .zero, size: contentSize)
            let path = CGMutablePath()
            for rect in rects {
                path.addRect(CGRect(layerPoints: rect))
            }
            shape.path = path
            contentLayer.mask = shape
            appliedMaskRectCount = rects.count
        }

        if material || appliedMaskIsMaterial {
            window.isOpaque = !material
            window.backgroundColor = material ? .clear : .black
            window.invalidateShadow()
        }
        appliedMaskIsMaterial = material
    }

    /// See `applyMaskNow`'s own doc comment for the full materiality definition this
    /// implements.
    ///
    /// UNIT (ADR-0015 §1, M1/L8): both sides of the comparison below are **mac pt** -- a
    /// `LayerRect`'s layer-local points against an AppKit `NSSize` -- so `epsilon` is half a
    /// **point**, not half a remote pixel and not half a backing pixel. It is a
    /// floating-point-slop tolerance for a "do these two rects coincide" test, NOT a geometry
    /// tolerance in ADR-0015 §6's sense (that one is L9's, priced by the owner at U6, and
    /// expressed in remote px); nothing here should ever be re-derived from that constant.
    /// At `remotePixelsPerPoint != 1` this comparison stays correct without change precisely
    /// because both sides are points -- W3 would have to move a scale into the pipeline
    /// UPSTREAM of here (ADR-0015 §7 (c)), never into this predicate.
    private static func isMaterialMask(_ result: WindowShape.MaskResult, contentSize: NSSize) -> Bool {
        switch result {
        case .none:
            return false
        case .rects(let rects):
            guard rects.count == 1 else { return true } // 0 rects (a real full clip) or 2+
            let r = rects[0]
            let epsilon = 0.5
            return !(abs(r.x) <= epsilon && abs(r.y) <= epsilon
                && abs(r.width - Double(contentSize.width)) <= epsilon
                && abs(r.height - Double(contentSize.height)) <= epsilon)
        }
    }

    /// `show`: RAIL's WINDOW_ORDER show-state for this window collapsed to a simple
    /// visible/hidden bool (adr/0005 §7: full minimize/maximize/Z-order fidelity is Phase
    /// 2). `true` orders the window front; `false` orders it out without closing/
    /// destroying it, so a later visibility flip doesn't need to reconstruct the NSWindow.
    /// Phase 2 W0③: while `hasClearedFirstFrameGate` is false, this only records the
    /// request in `pendingVisible` -- the real `orderFront`/`orderOut` call is deferred
    /// until `present` or `firstFrameTimeoutFired` actually clears the gate, so a window
    /// with nothing painted yet never shows as a solid black box.
    func setVisible(_ visible: Bool) {
        pendingVisible = visible
        guard hasClearedFirstFrameGate else { return }
        applyVisibility(visible)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    /// Fires 2s after `init` if no frame has presented by then (see
    /// `firstFrameTimeoutWorkItem`'s own doc comment) -- clears the gate and applies
    /// whatever show-state is currently pending, so a pathological window that never
    /// paints is still visible/debuggable rather than gated forever. Deliberately does
    /// NOT flip `hasDisplayedContent`/`displayedSurface` -- there is still no real content;
    /// a genuine frame arriving later just assigns it via `present` as normal (that method's
    /// own gate-clearing branch is simply skipped by then, since there is nothing left to
    /// clear or re-apply).
    private func firstFrameTimeoutFired() {
        firstFrameTimeoutWorkItem = nil
        guard !hasClearedFirstFrameGate else { return } // present() already cleared it; stale fire
        firstFrameTimedOut = true
        hasClearedFirstFrameGate = true
        // Real-host regression fix: apply whatever chrome was requested while gated BEFORE
        // ordering the window, not after -- see `pendingChrome`'s own doc comment.
        if let pendingChrome {
            applyChromeNow(pendingChrome)
        }
        if let pendingMask {
            applyMaskNow(pendingMask)
        }
        // Real-host regression fix (2026-08-23): applied here, after chrome/mask but before
        // visibility -- see `pendingContentRect`'s own doc comment. Geometry should be
        // correct before the window is judged on-screen, matching the exact ordering
        // reasoning `applyChromeNow`'s own "CONTENT RECT preservation" doc comment already
        // establishes for chrome.
        if let pendingContentRect {
            applyContentRectNow(pendingContentRect)
        }
        applyVisibility(pendingVisible)
        applyPendingActivateIfNeeded()
        // See `onFirstFrameGateCleared`'s own doc comment -- fired last, after this
        // window's own visibility/activation state is already settled, so a deferred
        // `addChildWindow` (the registry's own response) reflects real, already-decided
        // on-screen state rather than racing it.
        onFirstFrameGateCleared?()
    }

    /// W4c click-to-activate's local half (the remote half is `CRSession.activateWindow(_:)`
    /// — see `RemoteWindowRegistry.handleInput`, which calls both together on `mouseDown`).
    /// `makeKeyAndOrderFront` rather than plain `orderFront`: a borderless window still
    /// needs to become *key* to receive the keyDown/keyUp/flagsChanged events this same
    /// work package just wired `RemoteWindowContentView` to forward — `setVisible(true)`
    /// alone (used for RAIL show-state updates, not user clicks) deliberately does not make
    /// a window key, since pulling keyboard focus away from whatever the user is actually
    /// typing into just because a background window's RAIL show bit flipped would be its
    /// own kind of bug.
    ///
    /// Real-host regression fix (see `pendingActivate`'s own doc comment): while
    /// `hasClearedFirstFrameGate` is false, this ONLY records the request -- calling
    /// `-makeKeyAndOrderFront:` on a window that's never been ordered onto screen was
    /// observed live to bypass the first-frame gate exactly like the other three routes
    /// already fixed this round. `FocusAuthority` (this method's only caller, via
    /// `RemoteWindowRegistry.execute(_:)`'s `.makeKey` case) never reads real AppKit state
    /// back to check whether this actually ran -- deferring it in time changes nothing it
    /// can observe.
    func activateLocally() {
        guard hasClearedFirstFrameGate else {
            pendingActivate = true
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Assigns a newly leased surface to the layer and arranges for the *previously*
    /// displayed one (if any) to be recycled back to `session`'s pool once CoreAnimation
    /// has actually finished referencing it, never immediately (adr/0005 §2).
    ///
    /// Real-host regression investigation note (2026-08-23, W3 round 3, team-lead review):
    /// `contentsRect` immediately below crops the SOURCE image to `mappedSize` within the
    /// surface's own 64-aligned allocation -- it has no opinion on the DESTINATION
    /// `contentLayer`'s own on-screen size at all. With `contentsGravity == .resize` (set in
    /// `init`), CoreAnimation STRETCHES that cropped image to fill whatever size the layer
    /// (hence `contentView`, hence this window's content size) currently has, regardless of
    /// the cropped image's own native pixel dimensions -- confirmed by inspection, not
    /// merely suspected: before `RemoteWindowRegistry.macContentRect(for:windowId:)`'s W3
    /// round 3 fix made the content view's size GFX-mapped-canonical, a window whose content
    /// size still tracked RAIL's `windowWidth`/`windowHeight` (which round 3's own real-host
    /// evidence showed differs from `mappedSize` by a real, if small, per-window amount) was
    /// silently stretching every frame by that same ratio, with nothing in this method (or
    /// anywhere else) ever detecting or reporting it. Now that the content view's size is
    /// kept equal to `mappedSize` whenever one is known, this stretch's ratio degrades to
    /// 1:1 as a side effect -- not a change to this method itself.
    ///
    /// STRETCH SEMANTICS IN ADR-0015 §1'S VOCABULARY (M1/L8; documentation only -- the U5
    /// ruling is record-only and no value in this method or in `init` changes). The paragraph
    /// above says "stretches the cropped image to fill whatever size the layer has"; the three
    /// quantities involved are in three different units, which is precisely the confusion
    /// F1/F6 are made of, so they are now named:
    ///
    /// * SOURCE: the `mappedSize` sub-rect of the GFX surface -- **remote px** (GFX
    ///   `mappedWidth`/`mappedHeight` are wire values). `contentsRect` below selects it in the
    ///   contents' own *normalized* [0,1] space, which is unitless by construction and
    ///   therefore neutral in this accounting.
    /// * DESTINATION: `contentLayer.bounds` -- **mac pt**, tracking `contentView`'s size,
    ///   which `RemoteWindowRegistry.macContentRect(for:windowId:)` keeps mapped-canonical.
    /// * THE RATIO `.resize` APPLIES is therefore source remote px : destination mac pt --
    ///   i.e. this window's own remote-pixels-per-point (`DisplayScale.remotePixelsPerPoint`,
    ///   ADR-0015 §2). It is **1** on every configuration that exists today, for the two
    ///   independent reasons ADR-0015 §0a/§0c record: we advertise no `DesktopScaleFactor`, so
    ///   the server's raster is numerically our point grid, and the sole physical display is
    ///   1x (`docs/plans/phase3.md:219`). That is why this comment can be added without
    ///   changing a pixel: naming a ratio of 1 does not move anything.
    /// * The third unit, **backing px**, enters only through `contentsScale`, which this
    ///   project sets nowhere (repo-wide grep empty, ADR-0015 §0a) and which M1's MUST-NOT
    ///   list forbids touching -- AppKit's own handling of a view-backing layer is what
    ///   decides it today. Whether we should manage it, and whether the ratio above should
    ///   stop being 1, are the same W3 question (ADR-0015 §8), gated on a real 2x session
    ///   (§8.5: no such measurement exists yet).
    ///
    /// W3 TRIGGER, stated so the next reader does not have to re-derive it. There are TWO, and
    /// the EARLIER one is what `docs/plans/phase3.md:130` is actually about:
    /// * `backingPixelsPerPoint != 1` -- i.e. simply moving this window onto a Retina display.
    ///   `.resize`'s true destination is the layer's backing store, and AppKit gives a
    ///   view-backing layer `contentsScale == backingScaleFactor`, so a remote-px raster is
    ///   already upsampled 2x there while `remotePixelsPerPoint` is still 1. That is
    ///   `DisplayScale.retinaBackingOnly` (`DisplayTopology.swift:104-107`) and it is the
    ///   `backingScaleFactor` factor phase3.md §1 F1 names; the "red today, green on delivery"
    ///   assertion (`docs/plans/phase3.md:130`: an `NSWindow`'s backing-pixel size == its GFX
    ///   `mappedSize`) is the measurement for THIS trigger, not the one below.
    /// * `remotePixelsPerPoint != 1` -- the ratio named above stops being 1, i.e. the
    ///   point-level mapping itself is no longer 1:1 and `.resize` upsamples/downsamples even
    ///   before the backing store is considered.
    /// Both are W3's (ADR-0015 §8); M1 changes neither, and today's sole display is 1x on both
    /// counts (`docs/plans/phase3.md:219`).
    func present(surface: IOSurface, mappedSize: CGSize?, via session: CRSession) {
        let outgoing = displayedSurface
        CATransaction.begin()
        CATransaction.setDisableActions(true) // a raw frame swap, not an animated cross-fade
        CATransaction.setCompletionBlock {
            if let outgoing {
                // Swift's ObjC importer renames `-recycleSurface:` to `recycle(_:)` here
                // (the selector's "Surface" suffix reads as redundant with the IOSurface-
                // typed argument) -- same method, same CF_RELEASES_ARGUMENT contract.
                session.recycle(outgoing)
            }
        }
        contentLayer.contents = surface
        // The IOSurface's allocation is 64-aligned padding around the real content
        // (e.g. a 536x521 window's surface allocates 576x576) -- GFX MapSurfaceToWindow's
        // mappedWidth/Height name the sub-rect the window actually corresponds to.
        // contentsRect crops to that sub-rect BEFORE .resize stretches to the window;
        // without it the padding gets stretched in too, shrinking the real content by
        // alignedSize/mappedSize and leaving white bands at the right/bottom -- the
        // root cause behind both the long-standing "white edges" symptom and every
        // "clicks land on nothing" report (visual positions no longer matched remote
        // reality). Established live against the real host, 2026-08-21; the earlier
        // "server doesn't repaint stale windows" reading of the whiteness (cb97a25 era)
        // was a misdiagnosis of this same stretch.
        let allocW = CGFloat(surface.width)
        let allocH = CGFloat(surface.height)
        if let mapped = mappedSize, mapped.width > 0, mapped.height > 0, allocW > 0, allocH > 0 {
            let w = min(1, mapped.width / allocW)
            let h = min(1, mapped.height / allocH)
            // contentsRect is in the contents' *unit* coordinate space, whose origin is the
            // image's bottom-left on macOS (non-flipped layer geometry) -- the mapped
            // content occupies the surface's TOP-left, so the crop's y origin is 1-h, not
            // 0 (established live: a (0,0,w,h) crop kept the bottom rows and cut the
            // remote title bar off instead of the padding).
            contentLayer.contentsRect = CGRect(x: 0, y: 1 - h, width: w, height: h)
        } else {
            contentLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        displayedSurface = surface
        displayedMappedSize = mappedSize
        CATransaction.commit()

        if !hasClearedFirstFrameGate {
            // Phase 2 W0③: this window's first real content -- clear the gate and apply
            // whatever show-state RAIL has asked for since creation (see `setVisible`), now
            // that there's something other than solid black to actually show. Cancelling
            // the timeout work item here (rather than just letting it check
            // `hasClearedFirstFrameGate` and no-op) avoids ever firing it needlessly.
            hasClearedFirstFrameGate = true
            firstFrameTimeoutWorkItem?.cancel()
            firstFrameTimeoutWorkItem = nil
            // Real-host regression fix: apply whatever chrome was requested while gated
            // BEFORE ordering the window, not after -- see `pendingChrome`'s own doc
            // comment.
            if let pendingChrome {
                applyChromeNow(pendingChrome)
            }
            if let pendingMask {
                applyMaskNow(pendingMask)
            }
            // Real-host regression fix (2026-08-23): see `pendingContentRect`'s own doc
            // comment, and `firstFrameTimeoutFired`'s identical placement (after chrome/
            // mask, before visibility) for the ordering reasoning. In practice this call is
            // very often a no-op here specifically -- `contentLayer.contents = surface`
            // above already reflects this frame's mapped size, and if the LAST WindowUpdate
            // (or `.surfaceMapped` reapply) before this first frame already set
            // `pendingContentRect` to match, `applyContentRectNow`'s own "frame unchanged"
            // check short-circuits -- but a genuinely still-pending mismatch (e.g. a
            // WindowUpdate that arrived between the surface mapping and this first-paint
            // callback) is now correctly caught here instead of silently staying gated
            // forever.
            if let pendingContentRect {
                applyContentRectNow(pendingContentRect)
            }
            applyVisibility(pendingVisible)
            applyPendingActivateIfNeeded()
            // See `onFirstFrameGateCleared`'s own doc comment -- fired last, same
            // reasoning as `firstFrameTimeoutFired`'s own identical call.
            onFirstFrameGateCleared?()
        }
    }

    /// Real-host regression fix (see `pendingActivate`'s own doc comment): applies a
    /// deferred `activateLocally()` request, if one is pending, once the first-frame gate
    /// has just cleared. Called AFTER `applyVisibility` (not before, unlike
    /// `applyChromeNow`) so the window comes up front and key exactly as
    /// `activateLocally()`'s own pre-existing unconditional `-makeKeyAndOrderFront:`
    /// semantics always intended -- ordering after `applyVisibility` here is purely about
    /// matching that existing call's own effect, not a correctness requirement the way
    /// chrome-before-visibility was (styleMask must land before the window is judged
    /// on-screen; `-makeKeyAndOrderFront:` orders AND keys in one call regardless of what
    /// ran immediately before it).
    private func applyPendingActivateIfNeeded() {
        guard pendingActivate else { return }
        pendingActivate = false
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window and recycles whatever surface it was last displaying (if any).
    /// Call exactly once, from `RemoteWindowRegistry` only, on `WindowDelete` or a
    /// generation rollover — not idempotent against a second call.
    func close(via session: CRSession) {
        // Phase 2 W0③: nothing left to time out once this window is closing -- covers
        // WindowDelete, closeAllWindows, and prepareForReconnect alike, since all three
        // route through this one method (see this method's own doc comment above).
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        if let didResignKeyObserver {
            NotificationCenter.default.removeObserver(didResignKeyObserver)
            self.didResignKeyObserver = nil
        }
        // Phase 2 W3: same "block observers keep firing until explicitly removed" reasoning
        // as didResignKeyObserver above, times four. moveSettleWorkItem is cancelled too --
        // nothing left to settle once this window is closing.
        if let didMoveObserver {
            NotificationCenter.default.removeObserver(didMoveObserver)
            self.didMoveObserver = nil
        }
        if let didResizeObserver {
            NotificationCenter.default.removeObserver(didResizeObserver)
            self.didResizeObserver = nil
        }
        if let willStartLiveResizeObserver {
            NotificationCenter.default.removeObserver(willStartLiveResizeObserver)
            self.willStartLiveResizeObserver = nil
        }
        if let didEndLiveResizeObserver {
            NotificationCenter.default.removeObserver(didEndLiveResizeObserver)
            self.didEndLiveResizeObserver = nil
        }
        moveSettleWorkItem?.cancel()
        moveSettleWorkItem = nil
        // A still-gated close (this window never presented/timed out before its own
        // WindowDelete arrived) leaves `pendingActivate` moot the instant `window.close()`
        // below runs -- cleared explicitly anyway, matching `pendingActivate`'s own
        // lifecycle note ("cleared in close(via:)") rather than relying on the instance
        // simply going out of use afterward.
        pendingActivate = false
        window.orderOut(nil)
        window.close()
        if let displayedSurface {
            session.recycle(displayedSurface)
            self.displayedSurface = nil
            self.displayedMappedSize = nil
        }
    }
    // No deinit backstop for didResignKeyObserver: `deinit` is always nonisolated even on
    // a @MainActor class (deallocation can happen from any thread), so it cannot safely
    // read a MainActor-isolated, non-Sendable stored property like an NSObjectProtocol
    // observer token. close(via:) above is this class's own documented single point of
    // teardown ("call exactly once, from RemoteWindowRegistry only") and already removes
    // the observer; nothing in this codebase deallocates a RemoteWindow without going
    // through it first.
}

// MARK: - The mask pipeline's one crossing into CoreGraphics (M1/L8, ADR-0015 §9's L8 row)

private extension CGRect {
    /// The named conversion `applyMaskNow` builds its mask path through, replacing a bare
    /// `CGRect(x:y:width:height:)` splat of a `LayerRect`'s four `Double`s.
    ///
    /// WHAT IT CONVERTS, in ADR-0015 §1's vocabulary: **mac pt → mac pt**. `LayerRect` is
    /// already layer-local points (`MacdowsCore.WindowShape.LayerRect`'s own unit note); the
    /// only thing crossed here is the module boundary — `MacdowsCore` is AppKit- and
    /// CoreGraphics-free by charter (`Packages/MacdowsCore/Package.swift:21-24`, adr/0006 §2),
    /// so it models this rect with four plain `Double`s and the App target is where they
    /// become a `CGRect`. Hence the body is, and must remain, the **identity**: no scale, no
    /// flip, no rounding. ADR-0015 §9's L8 row states the acceptance criterion in exactly
    /// those terms — the mask conversion is the identity at `remotePixelsPerPoint == 1`
    /// (today's only hardware, `docs/plans/phase3.md:219`), and whether any scale factor ever
    /// enters this pipeline is W3's decision on the strength of a real 2x measurement
    /// (ADR-0015 §7 (c), §8). This wave introduces none.
    ///
    /// WHAT IT IS NOT, because ADR-0015 §7 predicts this specific wrong turn: this is **not**
    /// `WindowGeometry.macRect`. That function flips into mac SCREEN space around the primary
    /// display's height; a mask path lives in the layer's own bottom-left-origin space and
    /// adr/0010 §2 bans the substitution outright (`WindowShape.swift`'s `LayerRect` note,
    /// pinned by `WindowShapeTests.maskFlipAnchorsOnContentHeightNotThePrimaryScreenHeight`).
    /// The flip this pipeline does need already happened, once, inside
    /// `WindowShape.computeMask`'s step 2 — anything further here would be a second one.
    init(layerPoints rect: WindowShape.LayerRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
