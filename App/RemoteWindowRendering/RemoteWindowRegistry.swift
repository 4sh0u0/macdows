import AppKit
import MacdowsCore
import os

/// Local re-derivation of TS_WINDOW_STATE_ORDER's field-presence bits actually needed for
/// rendering (offset/size/show/title). MacdowsCore's WindowModel.swift is the canonical
/// reference for these values (verified there against
/// ThirdParty/FreeRDP/include/freerdp/window.h and libfreerdp/core/window.c's own order
/// parser) — duplicated here, narrowly, rather than exported from MacdowsCore, because
/// this module sits on the AppKit side of adr/0006 §2's no-AppKit boundary and
/// WindowModel's merge policy is deliberately scoped to MacdowsCore's own pure-logic
/// replay/test surface, not a second live-rendering consumer. Mirrors crdpq.h's own
/// precedent of not sharing these constants with its C transport layer either.
private enum WindowOrderField {
    static let title: UInt32 = 0x0000_0004
    static let show: UInt32 = 0x0000_0010
    static let size: UInt32 = 0x0000_0400
    static let offset: UInt32 = 0x0000_0800
}

/// Accumulated per-windowId state this registry needs to paint something — narrower than
/// MacdowsCore.WindowState (no style/styleEx/visibility-rects; this rendering layer
/// consumes none of them, W4b's LocalMoveResize/Z-order work being Phase 2).
private struct PendingWindowState {
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var show: UInt32 = 0
    var title: String = ""

    /// Applies only the sub-fields `event.fieldFlags` actually flags present — a delta
    /// order's unset bit means "unchanged", not "reset to zero/empty" (same invariant
    /// MacdowsCore.WindowState.merge documents and enforces for the JSONL-replay path).
    mutating func merge(_ event: CRDPEvent) {
        let flags = event.fieldFlags
        if flags & WindowOrderField.offset != 0 {
            offsetX = event.offsetX
            offsetY = event.offsetY
        }
        if flags & WindowOrderField.size != 0 {
            width = event.windowWidth
            height = event.windowHeight
        }
        if flags & WindowOrderField.show != 0 {
            show = event.show
        }
        if flags & WindowOrderField.title != 0 {
            title = event.title
        }
    }

    var hasKnownSize: Bool { width > 0 && height > 0 }
    /// WINDOW_HIDE == 0 (freerdp/window.h); any other show value means shown in some form.
    var isVisible: Bool { show != 0 }
}

/// Owns every `RemoteWindow` for one `CRSession`, driven entirely by that session's
/// drained control-lane events (adr/0005 §2/§3). `@MainActor` — this *is* T_main's window-
/// management state, matching `CRSession`'s own threading contract (every method on
/// `CRSession` is safe to call from whatever thread owns it; this registry is that
/// thread's own bookkeeping on top of it).
@MainActor
final class RemoteWindowRegistry {
    private let session: CRSession
    private var windows: [UInt32: RemoteWindow] = [:]
    private var geometry: [UInt32: PendingWindowState] = [:]
    /// surfaceId -> the windowId it's currently mapped to (from SurfaceMapped events), so
    /// a later FrameReady(surfaceId) can be routed to the right RemoteWindow. Unlike
    /// MacdowsCore.WindowModel's surfaceBindings/pendingBindings pair, this registry
    /// doesn't separately track "settled vs. pending" — a FrameReady for a surfaceId whose
    /// window doesn't exist yet (or is filtered out, see isLikelyContentWindow) is simply
    /// skipped; adr/0005 §1's "a GFX frame is state, not an event" means nothing is lost by doing so —
    /// the next FrameReady for the same surfaceId will retry once/if the window exists.
    private var surfaceToWindow: [UInt32: UInt32] = [:]
    /// Per-surface mapped sub-rect size (GFX mappedWidth/Height) -- the real content
    /// region inside the 64-aligned surface allocation; RemoteWindow.present crops the
    /// layer to it. Populated by .surfaceMapped, dropped alongside surfaceToWindow.
    private var surfaceMappedSize: [UInt32: CGSize] = [:]
    private var currentGeneration: UInt32?

    /// W4c review H1: *session-level* modifier state — one physical keyboard, one tracked
    /// set, not per-window. The original per-window `[UInt32: NSEvent.ModifierFlags]`
    /// dictionary had a real bug: a modifier pressed while window A was focused, then
    /// released while window B was focused instead (B's own dictionary entry never
    /// recorded the press), left that bit permanently stuck "held" in RDP's own remote-side
    /// state — no transition was ever observed to clear it, since diffing happened
    /// per-window rather than against one shared truth. `MacdowsCore.ModifierKeyTracker`
    /// does the actual diff/release-sequence computation (unit-tested there, offline, no
    /// AppKit/CRSession needed); this var is the one piece of mutable state it's diffed
    /// against. Cleared (not "flushed" — the connection this state described is already
    /// gone) on `closeAllWindows`, and force-flushed via `ModifierKeyTracker.releaseAll`
    /// on a `.focusLost` event (see `handleInput`'s own case).
    private var heldModifierKeys: ModifierKeySet = []
    /// W4c: last time a `.mouseMoved` event was actually forwarded for each window, for the
    /// move-event throttle in `handleInput` (task spec: "move events may be throttled at 8ms" — AppKit's
    /// native mouseMoved/mouseDragged rate is far higher than the outbound lane needs).
    private var lastMoveSentAt: [UInt32: CFAbsoluteTime] = [:]
    private static let moveThrottleInterval: CFAbsoluteTime = 0.008
    /// Trailing-edge state for the move throttle: the throttle used to plain DROP moves
    /// inside the 8ms window, so a burst's FINAL cursor position often never reached the
    /// server -- hover states stuck one step behind the cursor, and a warp-then-click sent
    /// its button event with no preceding motion at the final spot (both observed live
    /// during the 2026-08-21 input investigation, where the dropped tail invalidated a
    /// whole class of hover probes). A throttled move now parks here and a flush fires
    /// once the throttle window elapses, superseded by any newer send for the same window.
    private var pendingTrailingMove: [UInt32: NSPoint] = [:]

    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "RemoteWindowRendering")
    /// L1 (W4b review): logged once, not on every event, so a genuinely no-display
    /// environment doesn't spam this on every drained window order — the actual skip
    /// behavior in handleWindowOrder still applies every time regardless of this flag.
    private static var warnedZeroPrimaryMonitorHeight = false

    init(session: CRSession) {
        self.session = session
    }

    /// adr/0005 §2 / W4b task spec: "primaryMonitorHeight takes NSScreen.screens' primary screen" —
    /// `NSScreen.screens.first`, not `NSScreen.main` (which tracks keyboard focus, a
    /// different concept). `NSScreen.screens` is documented to list the primary display
    /// (the one containing the menu bar, i.e. Windows-space origin (0,0)'s counterpart)
    /// first.
    private static var primaryMonitorHeight: Double {
        // NSRect.height is CGFloat, not Double -- an explicit conversion (harmless on this
        // 64-bit-only project, adr/0005's own target) rather than a type mismatch.
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// W4b temporary size-based filter (spec's own words: a "temporary policy", not a permanent
    /// windowing design). A RemoteApp session's whole-desktop container surface (observed
    /// ~2560x1410 against the real lab host, matching a full virtual-desktop "Program
    /// Manager"-class window) and assorted 1x1 helper windows RAIL creates for its own
    /// bookkeeping aren't real user-visible content — mapping either to a visible NSWindow
    /// just adds noise (a huge black/blank window, or a scattering of 1-pixel windows)
    /// with no acceptance-criteria value. A real allow/deny-list belongs to a later phase
    /// once more window classes have actually been observed against a real host; this is
    /// a narrow, explicitly temporary guard, not general windowing policy.
    private static func isLikelyContentWindow(width: UInt32, height: UInt32) -> Bool {
        if width <= 1 || height <= 1 { return false }
        // Garbage-value guard: in the Int32 era any wire value with bit 31 set came out
        // negative and failed the <=1 check; the UInt32 migration silently removed that
        // accidental protection (a 0x80000000-wide order would have built a 2-billion-
        // point NSWindow). No sane single window exceeds 16384 in either dimension.
        if width > 16384 || height > 16384 { return false }
        if width >= 2000 && height >= 1000 { return false }
        return true
    }

    /// Call once per drained event, in delivery order (`session.drainEvents { registry.handle($0) }`)
    /// — there is no separate flush step; every event, including FrameReady, is applied as
    /// it arrives.
    func handle(_ event: CRDPEvent) {
        // adr/0005 §4's generation protocol: `-drainEventsWithHandler:` already filters
        // out stale-generation events before this method ever sees them, so any
        // generation change observed *here* is a genuine, first-time-seen reconnect
        // boundary — every window this registry currently tracks is from a connection
        // that's now gone (a clean reconnect always tears down and rebuilds RAIL/RDPGFX
        // state from scratch), so it's closed unconditionally, not merged forward.
        if currentGeneration != event.generation {
            closeAllWindows()
            currentGeneration = event.generation
        }

        switch event.kind {
        case .windowCreate, .windowUpdate:
            handleWindowOrder(event)
        case .windowDelete:
            handleWindowDelete(windowId: event.windowId)
        case .surfaceMapped:
            surfaceToWindow[event.surfaceId] = UInt32(truncatingIfNeeded: event.mappedWindowId)
            // The mapped sub-rect of the (64-aligned, padded) surface this window shows --
            // consumed by RemoteWindow.present's contentsRect crop; see its comment for
            // why skipping this crop was the white-edges/dead-clicks root cause.
            if event.mappedWidth > 0, event.mappedHeight > 0 {
                surfaceMappedSize[event.surfaceId] = CGSize(
                    width: CGFloat(event.mappedWidth), height: CGFloat(event.mappedHeight))
            }
        case .frameReady:
            handleFrameReady(surfaceId: event.surfaceId)
        case .disconnected:
            closeAllWindows()
        case .windowIcon, .notifyIconCreate, .notifyIconUpdate, .notifyIconDelete,
             .monitoredDesktop, .execResult, .handshakeFlags:
            break
        @unknown default:
            break
        }
    }

    private func handleWindowOrder(_ event: CRDPEvent) {
        let windowId = event.windowId
        var state = geometry[windowId] ?? PendingWindowState()
        state.merge(event)
        geometry[windowId] = state

        guard state.hasKnownSize, Self.isLikelyContentWindow(width: state.width, height: state.height) else {
            // Not enough geometry yet, or filtered out (see isLikelyContentWindow) — if a
            // RemoteWindow was already created for this windowId before it grew into a
            // filtered size (not expected in practice, but not assumed impossible either),
            // it's deliberately left alone here rather than torn down mid-session; only
            // WindowDelete/a generation rollover removes an existing RemoteWindow.
            return
        }
        guard let generation = currentGeneration else { return }

        // L1: primaryMonitorHeight==0 means NSScreen.screens was empty (no display
        // attached/available — plausible headless or display-asleep). WindowGeometry.
        // macRect would still compute *something* from a zero height (a bogus, likely
        // negative Y), silently placing/moving a window at a coordinate that was never
        // actually meaningful. Skip positioning entirely instead — this event's geometry
        // is still recorded above (state merge already ran), so once a real screen becomes
        // available a later update (or this same accumulated state, re-evaluated) positions
        // correctly rather than needing the server to resend anything.
        guard Self.primaryMonitorHeight > 0 else {
            if !Self.warnedZeroPrimaryMonitorHeight {
                Self.warnedZeroPrimaryMonitorHeight = true
                Self.logger.warning(
                    "primaryMonitorHeight is 0 (NSScreen.screens is empty) -- skipping window positioning rather than producing a bogus coordinate"
                )
            }
            return
        }

        let frame = macFrame(for: state)
        if let existing = windows[windowId] {
            existing.updateFrame(frame)
            existing.updateTitle(state.title)
            // Only reorder this window's front/back position when *this specific delta*
            // actually carries a show-state change — calling setVisible (hence
            // orderFront) on every unrelated geometry/title-only update was needlessly
            // pulling a window to the front of AppKit's window stack just because it
            // happened to receive some other kind of update, fighting for Z-order against
            // other windows that hadn't changed visibility at all (observed against a real
            // host with several leftover RemoteApp windows already open in the session:
            // an idle window could still end up on top of a freshly launched one). Full
            // Z-order fidelity is still Phase 2 (adr/0005 §7) — this only stops a kind of
            // update this registry doesn't model at all from having an unintended Z-order
            // side effect.
            if event.fieldFlags & WindowOrderField.show != 0 {
                existing.setVisible(state.isVisible)
            }
        } else {
            let key = RemoteWindowKey(windowId: windowId, generation: generation)
            let window = RemoteWindow(key: key, frame: frame, title: state.title)
            window.onInput = { [weak self] event in
                self?.handleInput(windowId: windowId, event: event)
            }
            windows[windowId] = window
            window.setVisible(state.isVisible)
        }
    }

    /// The one and only place Windows-space geometry becomes an `NSRect` — always through
    /// `MacdowsCore.WindowGeometry`, per the W4b task spec's explicit instruction never
    /// to reimplement this math anywhere else in this layer.
    private func macFrame(for state: PendingWindowState) -> NSRect {
        let windowsRect = WindowsRect(
            x: Double(state.offsetX),
            y: Double(state.offsetY),
            width: Double(state.width),
            height: Double(state.height)
        )
        let macRect = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryMonitorHeight)
        return NSRect(x: macRect.x, y: macRect.y, width: macRect.width, height: macRect.height)
    }

    private func handleWindowDelete(windowId: UInt32) {
        geometry.removeValue(forKey: windowId)
        let droppedSurfaces = surfaceToWindow.filter { $0.value == windowId }.map(\.key)
        for sid in droppedSurfaces {
            surfaceMappedSize.removeValue(forKey: sid)
        }
        surfaceToWindow = surfaceToWindow.filter { $0.value != windowId }
        // heldModifierKeys is deliberately NOT touched here (W4c review H1) -- it is
        // session-level, not per-window; a modifier held while this specific window closes
        // is still physically held on the keyboard and may still need its RELEASE observed
        // via whatever window next receives it, or via a .focusLost flush.
        lastMoveSentAt.removeValue(forKey: windowId)
        pendingTrailingMove.removeValue(forKey: windowId)
        if let window = windows.removeValue(forKey: windowId) {
            window.close(via: session)
        }
    }

    /// W4c: routes one `RemoteWindowInputEvent` from `windowId`'s `RemoteWindow` to
    /// `CRSession` (adr/0005's Phase 1 "clickable/interactive" milestone). This is the
    /// one and only place a mac-screen point becomes a Windows-space absolute desktop
    /// coordinate for *input* — mirrors `macFrame(for:)` being the one and only place the
    /// reverse direction happens for window geometry; `RemoteWindowContentView` never does
    /// this conversion itself.
    private func handleInput(windowId: UInt32, event: RemoteWindowInputEvent) {
        switch event {
        case .mouseMoved(let screenPoint):
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastMoveSentAt[windowId], now - last < Self.moveThrottleInterval {
                // Inside the throttle window: park this position and arrange for it to be
                // sent when the window elapses, instead of dropping it (see
                // pendingTrailingMove's comment for why dropping the tail was a real bug).
                let alreadyPending = pendingTrailingMove[windowId] != nil
                pendingTrailingMove[windowId] = screenPoint
                if !alreadyPending {
                    let delay = Self.moveThrottleInterval - (now - last)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.flushTrailingMove(windowId: windowId)
                        }
                    }
                }
                return
            }
            pendingTrailingMove.removeValue(forKey: windowId)
            lastMoveSentAt[windowId] = now
            let point = remotePoint(from: screenPoint)
            session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))

        case .mouseButton(let button, let down, let screenPoint):
            // A button event carries its own position -- any parked trailing move is now
            // stale (and letting it fire after the click would jiggle the remote pointer).
            pendingTrailingMove.removeValue(forKey: windowId)
            if down {
                // Click-to-activate (W4c task spec: "this is also where the real fix for the
                // white-block bug lands") — both the
                // remote ClientActivate and the local makeKeyAndOrderFront happen together,
                // unconditionally, on every button-down, not gated on "was this window
                // already focused" — a redundant Activate/makeKey on an already-focused
                // window is a fire-and-forget no-op cost, not a correctness risk.
                session.activateWindow(windowId)
                windows[windowId]?.activateLocally()
            }
            let point = remotePoint(from: screenPoint)
            session.send(crMouseButton(for: button), down: down, atX: Int32(point.x), y: Int32(point.y))

        case .scrollWheel(let deltaX, let deltaY, let screenPoint):
            // Same reasoning as .mouseButton above: this event carries its own position,
            // so a parked trailing move is stale and would drag the pointer backwards.
            pendingTrailingMove.removeValue(forKey: windowId)
            // Matches ThirdParty/FreeRDP/client/Mac/MRDPView.m's own -scrollWheel:: vertical
            // takes priority over horizontal for a single physical scroll event, not both
            // sent together. W4c review L1: the priority check itself must use an epsilon
            // (fabsf(dy) > FLT_EPSILON in the reference implementation), not a bare "!= 0"
            // -- a primarily-horizontal gesture can carry a negligible but technically
            // nonzero deltaY (trackpad noise), and a bare "!= 0" check let that tiny value
            // always win the vertical branch, silently swallowing every horizontal scroll
            // that happened to arrive with any deltaY noise at all.
            let point = remotePoint(from: screenPoint)
            if Float(abs(deltaY)) > Float.ulpOfOne {
                session.sendMouseVerticalWheelDelta(deltaY, atX: Int32(point.x), y: Int32(point.y))
            } else if Float(abs(deltaX)) > Float.ulpOfOne {
                session.sendMouseHorizontalWheelDelta(deltaX, atX: Int32(point.x), y: Int32(point.y))
            }

        case .keyDown(let macKeyCode):
            session.sendKeyDown(macKeyCode)

        case .keyUp(let macKeyCode):
            session.sendKeyUp(macKeyCode)

        case .flagsChanged(let modifierFlags):
            let current = Self.modifierKeySet(from: modifierFlags)
            let transitions = ModifierKeyTracker.transitions(from: heldModifierKeys, to: current)
            heldModifierKeys = current
            for transition in transitions {
                session.send(Self.crModifierKey(for: transition.key), down: transition.down)
            }

        case .focusLost:
            // W4c review H1: this window (or its content view) can no longer be trusted to
            // observe the physical keyboard -- unconditionally release every bit this
            // session-level tracker currently has marked as held, rather than leaving RDP's
            // own modifier state stuck on a release that might never arrive.
            let releases = ModifierKeyTracker.releaseAll(heldModifierKeys)
            heldModifierKeys = []
            for release in releases {
                session.send(Self.crModifierKey(for: release.key), down: release.down)
            }
        }
    }

    /// Trailing-edge flush for the move throttle (see `pendingTrailingMove`): sends the
    /// last position a throttled burst parked, unless a newer send for this window already
    /// superseded it (an unthrottled move clears the pending entry; a closed window drops
    /// out of `windows`).
    private func flushTrailingMove(windowId: UInt32) {
        guard let screenPoint = pendingTrailingMove.removeValue(forKey: windowId),
              windows[windowId] != nil
        else { return }
        lastMoveSentAt[windowId] = CFAbsoluteTimeGetCurrent()
        let point = remotePoint(from: screenPoint)
        session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))
    }

    /// The one and only place a mac-screen point becomes a `WindowsPoint`, exactly
    /// mirroring `macFrame(for:)` above for the reverse (Windows-rect -> mac-rect)
    /// direction. Always through `MacdowsCore.WindowGeometry` — never a second, ad hoc
    /// coordinate-math implementation in this file or `RemoteWindowContentView`.
    private func remotePoint(from screenPoint: NSPoint) -> WindowsPoint {
        WindowGeometry.windowsPoint(
            from: MacPoint(x: screenPoint.x, y: screenPoint.y),
            primaryMonitorHeight: Self.primaryMonitorHeight
        )
    }

    private func crMouseButton(for button: RemoteWindowMouseButton) -> CRMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }

    /// The AppKit -> `MacdowsCore` boundary conversion for modifier state (W4c review
    /// H1): `RemoteWindowContentView` reports raw `NSEvent.ModifierFlags`; the actual
    /// diff/release-sequence logic lives entirely in the no-AppKit
    /// `MacdowsCore.ModifierKeyTracker` (adr/0006 §2), so this is the one place that
    /// bridges one representation to the other. Same eight keys, same order, as
    /// MRDPView.m's own updateFlagStates (Help/Function added per W4c review M4).
    private static func modifierKeySet(from flags: NSEvent.ModifierFlags) -> ModifierKeySet {
        var result: ModifierKeySet = []
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.numericPad) { result.insert(.numericPad) }
        if flags.contains(.help) { result.insert(.help) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    /// `MacdowsCore.ModifierKeySet`'s single-key constants -> the `CRModifierKey`
    /// `CRSession.send(_:down:)` expects for it. `ModifierKeyTracker` only ever hands back
    /// single-bit `Transition.key` values (see its own `allKeys`-driven implementation), so
    /// this never needs to handle a multi-bit set.
    private static func crModifierKey(for key: ModifierKeySet) -> CRModifierKey {
        switch key {
        case .capsLock: return .capsLock
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .numericPad: return .numericPad
        case .help: return .help
        case .function: return .function
        default:
            // Unreachable in practice (see this function's own doc comment), but
            // ModifierKeySet is an OptionSet, not a closed enum, so the switch must be
            // exhaustive -- .command is as reasonable a default as any single-key fallback,
            // and this path is never actually exercised.
            return .command
        }
    }

    private func handleFrameReady(surfaceId: UInt32) {
        guard let windowId = surfaceToWindow[surfaceId], let window = windows[windowId] else {
            // Either not yet bound to a window, or bound to a window this registry isn't
            // rendering (isLikelyContentWindow filter) — either way, nothing to present;
            // see surfaceToWindow's own doc comment for why this is safe to just skip.
            return
        }
        guard let surface = session.copyPublishedSurface(surfaceId) else {
            // Already consumed by an earlier FrameReady for the same publish, or rejected
            // as stale-generation by CRSession itself — nothing new to display.
            return
        }
        window.present(surface: surface, mappedSize: surfaceMappedSize[surfaceId], via: session)
    }

    /// Diagnostics only (Tools/window-smoke's assertion battery) — not used by the real
    /// app's own rendering path, which never needs to enumerate live windows externally.
    struct WindowSnapshot {
        let windowId: UInt32
        let frame: NSRect
        let isVisible: Bool
        let hasDisplayedContent: Bool
        let title: String
        /// Phase 2 W0③ first-frame gating diagnostic -- see `RemoteWindow.firstFrameTimedOut`'s
        /// own doc comment.
        let firstFrameTimedOut: Bool
    }

    /// Diagnostics only (Tools/window-smoke's W4c input end-to-end assertions) — exposes
    /// the live `NSWindow` so a test harness can synthesize and dispatch a real `NSEvent`
    /// at it, exercising the actual AppKit hit-testing/first-responder dispatch path
    /// rather than calling `RemoteWindowContentView`'s event-handling methods directly (a
    /// test that bypassed real dispatch would only prove the method bodies work, not that
    /// a genuine click/keystroke actually reaches them). Not used by the real rendering
    /// path, which never needs to reach back into an individual window externally.
    func window(forWindowId windowId: UInt32) -> NSWindow? {
        windows[windowId]?.window
    }

    func windowSnapshots() -> [WindowSnapshot] {
        windows.map { windowId, window in
            WindowSnapshot(
                windowId: windowId, frame: window.frame, isVisible: window.isVisible,
                hasDisplayedContent: window.hasDisplayedContent, title: window.title,
                firstFrameTimedOut: window.firstFrameTimedOut
            )
        }
    }

    /// Diagnostics only (window-smoke's pixel-level assertion, W4b review round 2). See
    /// `RemoteWindow.nonWhitePixelRatio(inBottomFraction:sampleCount:)`'s own doc comment.
    func nonWhitePixelRatio(windowId: UInt32, inBottomFraction bottomFraction: Double, sampleCount: Int) -> Double? {
        windows[windowId]?.nonWhitePixelRatio(inBottomFraction: bottomFraction, sampleCount: sampleCount)
    }

    /// Explicit between-connections reset, for callers that drive reconnects themselves
    /// (window-smoke's WINDOW_SMOKE_CYCLES soak). Necessary because a `shutdownAndWait`
    /// leaves NOTHING for a drain to deliver -- its own step-4 loop consumes the
    /// `.disconnected` event and its final step bumps the generation, after which
    /// `drainEventsWithHandler` discards every remaining (now stale-generation) event --
    /// so neither of `handle()`'s two cleanup triggers (generation change, `.disconnected`)
    /// can ever fire from a post-shutdown drain (2026-08-22 review BLOCKER: the soak's
    /// "forced drain" delivered zero events and the previous cycle's windows survived
    /// into the next). The real app never needs this: it only shuts down at
    /// `applicationWillTerminate`.
    func prepareForReconnect() {
        closeAllWindows()
        currentGeneration = nil
    }

    private func closeAllWindows() {
        for (_, window) in windows {
            window.close(via: session)
        }
        windows.removeAll()
        geometry.removeAll()
        surfaceToWindow.removeAll()
        surfaceMappedSize.removeAll()
        // No RELEASE flush here (unlike the .focusLost case) -- the connection this
        // tracked state described is already gone, so there is nothing left to send it to.
        heldModifierKeys = []
        lastMoveSentAt.removeAll()
        pendingTrailingMove.removeAll()
    }
}
