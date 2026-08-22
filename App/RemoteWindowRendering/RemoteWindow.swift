import AppKit
import IOSurface

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
        // L3 (W4b review): a solid black window is visible for however long elapses
        // between this window being ordered front and its first real surface actually
        // being assigned (window creation and first paint are two separate control-lane
        // events, never atomic) — a known, accepted, purely cosmetic gap for this phase,
        // not a bug to chase down here. A real fix (e.g. deferring orderFront until the
        // first frame is in hand, or an interim placeholder less jarring than solid black)
        // is W4c/Phase 2 scope; this comment documents the artifact rather than changing
        // behavior to work around it now.
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

    /// `show`: RAIL's WINDOW_ORDER show-state for this window collapsed to a simple
    /// visible/hidden bool (adr/0005 §7: full minimize/maximize/Z-order fidelity is Phase
    /// 2). `true` orders the window front; `false` orders it out without closing/
    /// destroying it, so a later visibility flip doesn't need to reconstruct the NSWindow.
    func setVisible(_ visible: Bool) {
        if visible {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
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
    func activateLocally() {
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
    }

    /// Closes the window and recycles whatever surface it was last displaying (if any).
    /// Call exactly once, from `RemoteWindowRegistry` only, on `WindowDelete` or a
    /// generation rollover — not idempotent against a second call.
    func close(via session: CRSession) {
        if let didResignKeyObserver {
            NotificationCenter.default.removeObserver(didResignKeyObserver)
            self.didResignKeyObserver = nil
        }
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
