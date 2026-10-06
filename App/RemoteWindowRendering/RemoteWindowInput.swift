import AppKit
import Carbon

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
/// `RemoteWindowRegistry.macContentRect(for:)` is already "the one and only place" a *rect*
/// does that conversion (W4b task spec's own instruction: no second, ad hoc coordinate-math
/// implementation anywhere else in this layer).
enum RemoteWindowInputEvent {
    case mouseMoved(screenPoint: NSPoint)
    case mouseButton(RemoteWindowMouseButton, down: Bool, screenPoint: NSPoint)
    case scrollWheel(deltaX: Double, deltaY: Double, screenPoint: NSPoint)
    /// `macKeyCode`: raw `NSEvent.keyCode`, untranslated — `CRSession.sendKeyDown(_:)`/
    /// `sendKeyUp(_:)` do the WinPR translation (see their doc comments in CRSession.h).
    /// `characters`/`charactersIgnoringModifiers` (adr/0011 §2): the matching `NSEvent`
    /// fields, verbatim, empty for dead keys and pure function/modifier keys (never `nil`
    /// -- `RemoteWindowContentView` substitutes `""` for AppKit's own optional `nil` case).
    /// Not consumed by `RemoteWindowRegistry`'s ISO-keycode correction (adr/0011 §0a: that
    /// depends only on keyboard type, never on characters) -- this pipeline's real
    /// consumer is adr/0011 §3's `CommandKeyMapper` (keyed on
    /// `charactersIgnoringModifiers.lowercased()`, never on `macKeyCode` -- AZERTY
    /// evidence, see that type's own doc comment).
    case keyDown(macKeyCode: UInt16, characters: String, charactersIgnoringModifiers: String)
    case keyUp(macKeyCode: UInt16, characters: String, charactersIgnoringModifiers: String)
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
    /// adr/0011 §1/§2: an already-composed IME commit string, from
    /// `RemoteWindowContentView`'s `NSTextInputClient -insertText:` conformance --
    /// dispatched only when the current input source is non-ASCII-capable (see
    /// `RemoteWindowContentView.keyDown(with:)`'s own routing).
    case unicodeText(String)
    /// adr/0022 D-3: one of the local-reserved key equivalents (`LocalKeyEquivalent.reserved`)
    /// was handed to the Mac's menu instead of the wire. Carries nothing: the registry only tells
    /// `CommandKeyMapper` that the current Cmd gesture had a key (`localKeyEquivalent()`), so
    /// Cmd's release does not send a bare LWIN tap. Never puts anything on the wire.
    case localKeyEquivalent
}

/// adr/0022 D-3: a key equivalent the Mac keeps for itself even while a remote window is key --
/// matched on (`charactersIgnoringModifiers.lowercased()`, the event's modifier flags restricted
/// to ⌘ ⌥ ⌃ ⇧ and compared for EXACT equality). Caps Lock, Fn and the other bits take no part.
/// ⇧⌘H, ⌃⌘H, ⌃⌘, and every other near miss are not reserved and go to Windows as before.
///
/// `reserved` is the one copy of the set: the content view's claim decision reads it, and the
/// main menu takes the key equivalents of its four local items from it (adr/0022 D-8 T-1).
struct LocalKeyEquivalent: Hashable {
    let character: String
    let modifiers: NSEvent.ModifierFlags

    /// The only modifier bits the match looks at.
    static let comparedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static let quit = LocalKeyEquivalent(character: "q", modifiers: [.command])
    static let hide = LocalKeyEquivalent(character: "h", modifiers: [.command])
    static let hideOthers = LocalKeyEquivalent(character: "h", modifiers: [.command, .option])
    static let settings = LocalKeyEquivalent(character: ",", modifiers: [.command])

    /// adr/0022 D-3's R4, owner-ruled (STATUS ㋍): ⌘Q, ⌘H, ⌥⌘H, ⌘,.
    static let reserved: [LocalKeyEquivalent] = [quit, hide, hideOthers, settings]

    static func == (lhs: LocalKeyEquivalent, rhs: LocalKeyEquivalent) -> Bool {
        lhs.character == rhs.character && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(character)
        hasher.combine(modifiers.rawValue)
    }

    /// Whether `event` is one of `reserved`, by exact pair.
    static func isReserved(_ event: NSEvent) -> Bool {
        let candidate = LocalKeyEquivalent(
            character: (event.charactersIgnoringModifiers ?? "").lowercased(),
            modifiers: event.modifierFlags.intersection(comparedModifiers)
        )
        return reserved.contains(candidate)
    }
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
    /// adr/0011 §2: the current IME composition's marked (not-yet-committed) text, tracked
    /// only to keep `NSTextInputClient`'s own state machine (backspace-during-composition,
    /// `hasMarkedText()`/`markedRange()`) internally consistent -- deliberately never drawn
    /// (the inline marked-text overlay is Phase 2's documented v1 gap, adr/0011 §2/§6).
    private var markedText = ""

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

    /// adr/0022 D-2 B: once a main menu exists, AppKit offers every modifier key event to the
    /// KEY window's view hierarchy through this method BEFORE the menu bar sees it, and only then
    /// delivers it as `keyDown` (Cocoa Event Handling Guide, "Handling Key Equivalents"). Claiming
    /// a Command key here is what keeps ⌘W, ⌘C, ⌘M and the rest going to Windows exactly as they
    /// did when the App had no menu, whatever the menu contains.
    ///
    /// In order:
    ///  1. adr/0022 I-4: claim nothing unless this view's window is key AND this view is its first
    ///     responder -- a Mac panel that is key while a remote window is main keeps its ⌘C.
    ///  2. No Command (a bare Control key equivalent included): not ours, `super` (returns NO). The
    ///     main menu then decides: a matching item, enabled or disabled, consumes the key (gate r1
    ///     I-1 -- AppKit's injected fn / Globe items included); only when no item matches does
    ///     AppKit re-deliver it as `keyDown`.
    ///  3. Command, not reserved: the same body `keyDown` runs (modifier alignment first, then the
    ///     input-source fork), and YES, so the menu never sees it.
    ///  4. Command, reserved (`LocalKeyEquivalent.reserved`): align modifiers exactly as `keyDown`
    ///     does -- so a Cmd press this view never observed puts `CommandKeyMapper` into its
    ///     withheld state first and the bare letter cannot leak through the ordinary lane -- then
    ///     report `.localKeyEquivalent` (no input-source fork), and NO, so the menu performs it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let window, window.isKeyWindow, window.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if LocalKeyEquivalent.isReserved(event) {
            reportModifierAlignment(for: event)
            onEvent?(.localKeyEquivalent)
            return false
        }
        handleKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // adr/0022 D-2 B: a reserved pair arriving here was already reported by
        // `performKeyEquivalent`. AppKit re-delivers a key equivalent as keyDown only when there is
        // no menu or no matching item; a matching disabled item consumes it (gate r1 m-2).
        // Report it again -- `CommandKeyMapper.localKeyEquivalent()` is idempotent -- and never
        // hand it to the mapper's character table, where a disabled ⌘, would become LWIN+,.
        if LocalKeyEquivalent.isReserved(event) {
            onEvent?(.localKeyEquivalent)
            return
        }
        handleKeyDown(event)
    }

    /// W4c review H1's reconciliation `.flagsChanged`, shared by `keyDown` and the claim path.
    private func reportModifierAlignment(for event: NSEvent) {
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    /// The one keyDown body: `keyDown(with:)` and `performKeyEquivalent(with:)`'s claim branch
    /// both run exactly this, so a claimed Command key reaches the registry in the same shape a
    /// menu-less `keyDown` delivered it in (adr/0022 I-1).
    private func handleKeyDown(_ event: NSEvent) {
        // W4c review H1: MRDPView.m:513's own keyDown: calls [self flagsChanged:event] as
        // its literal first line, before handling the key itself -- a defensive
        // reconciliation against modifier state that might have drifted out of sync with
        // the last real flagsChanged: this view saw (event coalescing, or this window only
        // just regaining focus). Reporting .flagsChanged here is a no-op downstream if
        // nothing actually changed (RemoteWindowRegistry's diff against session-level state
        // produces zero transitions), so this is always safe to send.
        reportModifierAlignment(for: event)

        // adr/0011 §1's mixing rule: modifier/function/arrow/Enter/Tab/Esc keys always go
        // scancode regardless of input source; everything else defers to whether the
        // *current* input source is ASCII-capable -- a non-ASCII-capable (CJK/合成型)
        // source hands its work back via NSTextInputClient (insertText:/setMarkedText:
        // below), not scancodes.
        if !Self.isAlwaysScancodeKey(macKeyCode: event.keyCode), !Self.isCurrentInputSourceASCIICapable() {
            interpretKeyEvents([event])
            return
        }
        onEvent?(.keyDown(
            macKeyCode: event.keyCode,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? ""
        ))
    }

    override func keyUp(with event: NSEvent) {
        // Same reconciliation as keyDown above -- MRDPView.m's own keyUp: does this too.
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))

        // Mirrors keyDown's own routing: while composing under a non-ASCII-capable source,
        // the physical key that produced this keyUp was already fully consumed locally by
        // interpretKeyEvents on the matching keyDown (adr/0011 §1/§2: only the final
        // committed string ever crosses the wire for that path) -- no scancode keyUp for
        // it either, except for the same always-scancode carve-out.
        if !Self.isAlwaysScancodeKey(macKeyCode: event.keyCode), !Self.isCurrentInputSourceASCIICapable() {
            return
        }
        onEvent?(.keyUp(
            macKeyCode: event.keyCode,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? ""
        ))
    }

    override func flagsChanged(with event: NSEvent) {
        onEvent?(.flagsChanged(modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    /// adr/0011 §1's table: "修饰键、功能键、方向键、Enter/Tab/Esc——无论输入源" always take the
    /// scancode path. Modifier keys never reach this method at all (AppKit delivers them as
    /// `flagsChanged:`, not `keyDown:`/`keyUp:`), so this only needs to name the rest:
    /// function keys, arrows, Return/Enter, Tab, Escape. Standard, stable AppKit virtual
    /// keycodes (physical position, not layout-dependent -- same numbering space
    /// `CommandKeyMapper`'s fixed-VK table uses). Deliberately does NOT include Delete/
    /// ForwardDelete: adr/0011 §2 says marked text is tracked "以维持输入法状态与退格"
    /// (backspace included) -- backspace needs to reach `interpretKeyEvents` while
    /// composing so it can edit the marked (not-yet-committed) text, exactly like every
    /// other Cocoa text-input client.
    private static func isAlwaysScancodeKey(macKeyCode: UInt16) -> Bool {
        switch macKeyCode {
        case 36, 76: return true // Return, numpad Enter
        case 48: return true // Tab
        case 53: return true // Escape
        case 123, 124, 125, 126: return true // Left, Right, Down, Up
        case 115, 116, 117, 119, 121: return true // Home, PageUp, ForwardDelete, End, PageDown
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106: return true // F1-F16
        case 114: return true // Help
        default: return false
        }
    }

    /// adr/0011 §1/§2: whether the *currently active* keyboard input source is ASCII-
    /// capable (`TISCopyCurrentKeyboardInputSource`'s `kTISPropertyInputSourceIsASCIICapable`
    /// property) -- the mixing rule's own decision point, re-evaluated on every keystroke
    /// (a user can switch input sources mid-session). Defaults to `true` (today's exact
    /// scancode-only behavior) whenever the source or property can't be read -- mirrors
    /// adr/0011 §4's own "探测失败/符号缺席时不猜测，退回今天的行为" discipline: never silently
    /// route an unrecognized source into the (per-keystroke-fidelity-losing) IME lane it
    /// never asked for.
    private static func isCurrentInputSourceASCIICapable() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return true }
        guard let rawProperty = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return true
        }
        let cfBoolean = Unmanaged<CFBoolean>.fromOpaque(rawProperty).takeUnretainedValue()
        return CFBooleanGetValue(cfBoolean)
    }
}

// MARK: - NSTextInputClient (adr/0011 §2)

/// v1 only consumes the fully-composed commit (`insertText(_:replacementRange:)`) --
/// marked (in-progress composition) text is tracked internally, purely to keep this
/// protocol's own state machine consistent (backspace-during-composition,
/// `hasMarkedText()`), but is deliberately never drawn (the inline marked-text overlay is
/// Phase 2's documented v1 gap: CJK users composing inside an app-inline-IME-style remote
/// application see nothing locally until the whole string commits at once, adr/0011 §2/§6).
// `@preconcurrency`: `NSTextInputClient`'s requirements are all `nonisolated` as imported
// from its unannotated ObjC header, while every implementation below is (implicitly, this
// target's default actor isolation) main-actor-isolated like the rest of this
// `NSView` subclass -- exactly the documented case for `@preconcurrency` on a protocol
// conformance (Swift 6 #ConformanceIsolation), not a real cross-actor hazard: AppKit only
// ever calls these from the main thread in the first place.
extension RemoteWindowContentView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: text = ""
        }
        guard !text.isEmpty else { return }
        onEvent?(.unicodeText(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString: markedText = attributed.string
        case let plain as String: markedText = plain
        default: markedText = ""
        }
    }

    func unmarkText() {
        markedText = ""
    }

    func selectedRange() -> NSRange {
        // No local text storage to report a real selection against -- NSNotFound is the
        // conventional "unknown" answer Cocoa text-input clients give here.
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard !markedText.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil // no local text storage (v1: only the committed-string path is consumed)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Best-effort candidate-window anchor: this view's own frame in screen space --
        // not glyph-accurate (no local text storage to measure against), but a reasonable,
        // never-crashing default. Real candidate-window anchoring is the remote-IME path
        // adr/0011 §6 explicitly defers.
        guard let window else { return .zero }
        return window.convertToScreen(NSRect(origin: .zero, size: bounds.size))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
