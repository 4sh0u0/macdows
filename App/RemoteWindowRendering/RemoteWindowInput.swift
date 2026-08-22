import AppKit

/// W4c: the three mouse buttons this rendering layer forwards to the remote session (mirrors
/// `CRMouseButton` in CRBridge's `CRSession.h`, kept as an independent Swift-side enum rather
/// than importing that ObjC type here — `RemoteWindowContentView` has no reason to know
/// `CRSession` exists at all; only `RemoteWindowRegistry`, which already talks to `CRSession`
/// directly, translates one into the other).
enum RemoteWindowMouseButton {
    case left
    case right
    case middle
}

/// One raw input event captured by `RemoteWindowContentView`, reported upward through
/// `RemoteWindow`'s `onInput` closure for `RemoteWindowRegistry` to translate and forward to
/// `CRSession` (adr/0005 §5: the view itself never touches `CRSession` directly — "outbound
/// traffic goes through the registry calling back into CRSession"). Points are always in this Mac's *global screen space*
/// (bottom-left origin, Y up) — the one and only place Windows-space geometry gets computed
/// from a mac point is `RemoteWindowRegistry`, exactly mirroring how
/// `RemoteWindowRegistry.macFrame(for:)` is already "the one and only place" a *rect* does
/// that conversion (W4b task spec's own instruction: no second, ad hoc coordinate-math
/// implementation anywhere else in this layer).
enum RemoteWindowInputEvent {
    case mouseMoved(screenPoint: NSPoint)
    case mouseButton(RemoteWindowMouseButton, down: Bool, screenPoint: NSPoint)
    case scrollWheel(deltaX: Double, deltaY: Double, screenPoint: NSPoint)
    /// `macKeyCode`: raw `NSEvent.keyCode`, untranslated — `CRSession.sendKeyDown(_:)`/
    /// `sendKeyUp(_:)` do the WinPR translation (see their doc comments in CRSession.h).
    case keyDown(macKeyCode: UInt16)
    case keyUp(macKeyCode: UInt16)
    /// Already masked to `.deviceIndependentFlagsMask` — `RemoteWindowRegistry` diffs this
    /// against the *session-level* (W4c review H1, not per-window) modifier state it
    /// tracks and calls `CRSession.send(_:down:)` once per bit that actually flipped,
    /// mirroring MRDPView.m's own updateFlagStates.
    case flagsChanged(modifierFlags: NSEvent.ModifierFlags)
    /// W4c review H1: this window (or its content view specifically) can no longer be
    /// trusted to observe the physical keyboard's modifier state — either the whole
    /// `NSWindow` resigned key status (`RemoteWindow`'s own `NSWindow.didResignKeyNotification`
    /// observer), or this view itself resigned first responder within a still-key window
    /// (`resignFirstResponder()` below). `RemoteWindowRegistry` responds by unconditionally
    /// releasing every modifier bit its session-level state currently has tracked as held,
    /// rather than waiting for a release event that might never arrive on this window
    /// again — see `MacdowsCore.ModifierKeyTracker.releaseAll(_:)`.
    case focusLost
}

/// W4c: `RemoteWindow`'s content view. Captures the full range of mouse/keyboard/scroll
/// input AppKit can deliver to a plain view and reports each as a `RemoteWindowInputEvent`
/// via `onEvent`, set once by `RemoteWindow` at construction time — this class holds no
/// reference to `CRSession` or `RemoteWindowRegistry` itself.
///
/// `acceptsFirstResponder`/`acceptsFirstMouse` both `true`: a borderless RAIL window (no
/// titlebar to click through first) needs the very first click to both raise/focus the
/// window *and* be forwarded as real input — the default AppKit behavior (first click only
/// activates a background window, a second click actually reaches the view) would silently
/// eat every user's first click on any not-yet-focused remote window, which is exactly the
/// "click doesn't do anything" symptom this whole work package exists to fix.
final class RemoteWindowContentView: NSView {
    var onEvent: ((RemoteWindowInputEvent) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// W4c review H1: defense-in-depth alongside `RemoteWindow`'s own
    /// `NSWindow.didResignKeyNotification` observer — that one catches the whole window
    /// losing key status (e.g. Cmd-Tabbing to a different Mac app); this one catches *this
    /// view specifically* losing first-responder status within a window that might still
    /// be key (not expected to happen in this single-content-view-per-window design today,
    /// but cheap to guard against and exactly what the task spec asked for).
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onEvent?(.focusLost)
        }
        return resigned
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // .activeInActiveApp, not .activeInKeyWindow: with the key-window-only option, a
        // remote window that is visible but not key never reports mouseMoved at all, so no
        // hover state (button highlights, link underlines, close-button reddening) can ever
        // reach the server for it -- and a cursor warp followed immediately by a click
        // forwards the button event with no preceding motion. Local Mac windows show hover
        // effects whenever their app is active, key or not; matching that is exactly what a
        // Parallels Coherence-style window should do. (Established live against the real host during
        // the 2026-08-20 white-edge/click investigation: hover probes silently forwarded
        // nothing until the window happened to be key, invalidating a whole class of
        // input-path experiments.)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Converts an event's `locationInWindow` into a global mac-screen point. This view
    /// always fills its window's whole content rect (`RemoteWindow` never adds a titlebar or
    /// any other chrome around it), so window-space and view-space coincide — the only
    /// AppKit-specific geometry step this view does itself is the window-to-screen step,
    /// since `window` is only reachable from inside the view, not from
    /// `RemoteWindowRegistry`; everything past this (the mac-screen -> Windows-desktop flip)
    /// stays centralized in `RemoteWindowRegistry`, per this file's own doc comment above.
    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        onEvent?(.mouseMoved(screenPoint: screenPoint(for: event)))
    }

    override func mouseDragged(with event: NSEvent) {
        onEvent?(.mouseMoved(screenPoint: screenPoint(for: event)))
    }

    override func rightMouseDragged(with event: NSEvent) {
        onEvent?(.mouseMoved(screenPoint: screenPoint(for: event)))
    }

    override func otherMouseDragged(with event: NSEvent) {
        onEvent?(.mouseMoved(screenPoint: screenPoint(for: event)))
    }

    override func mouseDown(with event: NSEvent) {
        onEvent?(.mouseButton(.left, down: true, screenPoint: screenPoint(for: event)))
    }

    override func mouseUp(with event: NSEvent) {
        onEvent?(.mouseButton(.left, down: false, screenPoint: screenPoint(for: event)))
    }

    override func rightMouseDown(with event: NSEvent) {
        onEvent?(.mouseButton(.right, down: true, screenPoint: screenPoint(for: event)))
    }

    override func rightMouseUp(with event: NSEvent) {
        onEvent?(.mouseButton(.right, down: false, screenPoint: screenPoint(for: event)))
    }

    override func otherMouseDown(with event: NSEvent) {
        // Only the middle button (NSEvent.buttonNumber == 2) maps to RDP's PTR_FLAGS_
        // BUTTON3 — side buttons (3+) map to a *separate* wire message (PTR_XFLAGS_
        // BUTTON1/2), deliberately deferred to a later phase rather than wired here (W4c
        // review L3; see CRSession.h's CRMouseButton doc comment). The event is still
        // consumed here (no `super` call) so AppKit doesn't do something unexpected with
        // an unhandled side-button click landing on a borderless window.
        guard event.buttonNumber == 2 else { return }
        onEvent?(.mouseButton(.middle, down: true, screenPoint: screenPoint(for: event)))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onEvent?(.mouseButton(.middle, down: false, screenPoint: screenPoint(for: event)))
    }

    override func scrollWheel(with event: NSEvent) {
        onEvent?(.scrollWheel(deltaX: event.deltaX, deltaY: event.deltaY, screenPoint: screenPoint(for: event)))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // W4c review H1: MRDPView.m:513's own keyDown: calls [self flagsChanged:event] as
        // its literal first line, before handling the key itself -- a defensive
        // reconciliation against modifier state that might have drifted out of sync with
        // the last real flagsChanged: this view saw (event coalescing, or this window only
        // just regaining focus). Reporting .flagsChanged here is a no-op downstream if
        // nothing actually changed (RemoteWindowRegistry's diff against session-level state
        // produces zero transitions), so this is always safe to send.
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
        onEvent?(.keyDown(macKeyCode: event.keyCode))
    }

    override func keyUp(with event: NSEvent) {
        // Same reconciliation as keyDown above -- MRDPView.m's own keyUp: does this too.
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
        onEvent?(.keyUp(macKeyCode: event.keyCode))
    }

    override func flagsChanged(with event: NSEvent) {
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }
}
