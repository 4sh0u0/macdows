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
    private static let firstFrameTimeout: TimeInterval = 2.0

    /// W4c review H1: token for the `NSWindow.didResignKeyNotification` observer below,
    /// removed in `close(via:)`/`deinit` — a block-based `NotificationCenter` observer
    /// keeps firing (and keeps this instance alive, via the closure's captures) until
    /// explicitly removed; it does not get torn down automatically just because the
    /// underlying `NSWindow` closes.
    private var didResignKeyObserver: NSObjectProtocol?

    /// `frame` is already in macOS screen space (post `WindowGeometry.macRect`) — this
    /// type does no coordinate conversion of its own; that's `RemoteWindowRegistry`'s job,
    /// using `MacdowsCore.WindowGeometry` exclusively (per the W4b task spec: no second,
    /// ad hoc coordinate-math implementation anywhere else in this layer).
    init(key: RemoteWindowKey, frame: NSRect, title: String) {
        self.key = key

        let win = RemoteWindowBackingWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
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

        let contentView = RemoteWindowContentView(frame: NSRect(origin: .zero, size: frame.size))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout, execute: timeoutWorkItem)
    }

    /// Diagnostics only (Tools/window-smoke's assertion battery) — not read anywhere on
    /// the real rendering path, which only ever needs `window`/`present`/`close` above.
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }
    var hasDisplayedContent: Bool { contentLayer.contents != nil }
    var title: String { window.title }

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

    func updateFrame(_ frame: NSRect) {
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true)
    }

    func updateTitle(_ title: String) {
        guard window.title != title else { return }
        window.title = title
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
    /// Frame preservation (task item 3's own instruction): `NSWindow.styleMask` and `.frame`
    /// interact in AppKit -- a titled window's frame includes the titlebar strip, a
    /// borderless one doesn't, so toggling `.titled` can shift how `.frame` relates to the
    /// window's own content region. Capturing `window.frame` before the styleMask
    /// assignment and unconditionally restoring it afterward keeps whatever
    /// `RemoteWindowRegistry.macFrame(for:)` most recently computed from the RAIL order as
    /// this window's actual on-screen frame, regardless of that internal reinterpretation --
    /// the RAIL-provided frame meaning stays authoritative, AppKit's own chrome-driven frame
    /// adjustment is simply overridden right back. (Open question, deliberately not guessed
    /// at here: whether RAIL's own windowWidth/Height already accounts for a native
    /// titlebar's height for a titled window is unconfirmed without live-host measurement --
    /// flagged for follow-up, not silently assumed either way.)
    private func applyChromeNow(_ chrome: WindowChrome) {
        guard chrome != appliedChrome else { return }
        let previousFrame = window.frame

        var mask: NSWindow.StyleMask = chrome.titled ? [.titled] : [.borderless]
        if chrome.titled {
            if chrome.closable { mask.insert(.closable) }
            if chrome.miniaturizable { mask.insert(.miniaturizable) }
            // See WindowChrome.zoomable's own doc comment: AppKit couples the zoom
            // button's enabled state to `.resizable` itself, there is no independent
            // "zoomable" styleMask bit -- `resizable` (WS_THICKFRAME) is what this project
            // maps onto that one AppKit bit, not `zoomable` (WS_MAXIMIZEBOX) directly.
            if chrome.resizable { mask.insert(.resizable) }
        }
        window.styleMask = mask
        window.setFrame(previousFrame, display: window.isVisible)

        window.hasShadow = chrome.hasShadow
        window.level = chrome.level == .floating ? .floating : .normal

        appliedChrome = chrome
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
        applyVisibility(pendingVisible)
        applyPendingActivateIfNeeded()
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
            applyVisibility(pendingVisible)
            applyPendingActivateIfNeeded()
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
