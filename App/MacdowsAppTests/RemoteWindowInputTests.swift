import AppKit
import Testing

// Lane D7: `RemoteWindowContentView`'s pure event-translation surface, driven with
// synthesized `NSEvent`s on a windowless view (constructible with no NSApplication and no
// NSWindow). See DisplayTopologyProviderTests.swift's file header for the lane's shared
// coverage-boundary register; boundaries specific to THIS file:
//
//  * The IME routing fork in `keyDown(with:)`/`keyUp(with:)` (`isCurrentInputSourceASCIICapable`)
//    reads the LIVE `TISCopyCurrentKeyboardInputSource`, so which lane a non-carve-out key
//    takes depends on whatever input source the test runner's user session happens to have
//    active -- environment-dependent, not assertable. Only the always-scancode carve-out
//    (Return below), which bypasses that check by construction, is pinned. The
//    `interpretKeyEvents` lane additionally needs a live input context.
//  * Mouse coverage is left-button only: `NSEvent.mouseEvent(...)` offers no way to set
//    `buttonNumber`, so `otherMouseDown`'s `buttonNumber == 2` middle-vs-side-button gate is
//    not synthesizable headless. `scrollWheel`'s `deltaX/deltaY` are likewise not settable on
//    a synthesized event.
//  * `screenPoint(for:)`'s window-to-screen conversion branch needs a real `NSWindow`; the
//    windowless fallback (location passed through verbatim) is what is pinned here.
//  * `updateTrackingAreas`' option set (`.activeInActiveApp`, the 2026-08-20 hover finding)
//    is only observable through live tracking-area delivery -- not assertable headless.

@MainActor
@Suite("RemoteWindowContentView")
struct RemoteWindowInputTests {
    private static func makeView() -> (RemoteWindowContentView, () -> [RemoteWindowInputEvent]) {
        let view = RemoteWindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let box = EventBox()
        view.onEvent = { box.events.append($0) }
        return (view, { box.events })
    }

    private final class EventBox {
        var events: [RemoteWindowInputEvent] = []
    }

    /// The W4c first-click contract this file's own doc comment names: a borderless RAIL
    /// window's very first click must both focus and land, so both acceptance flags are true.
    @Test func viewAcceptsFirstResponderAndFirstMouse() {
        let (view, _) = Self.makeView()
        #expect(view.acceptsFirstResponder)
        #expect(view.acceptsFirstMouse(for: nil))
    }

    /// adr/0011 §1: Return (keyCode 36) is an always-scancode key, so `keyDown` emits the
    /// MRDPView-style reconciliation `.flagsChanged` FIRST (masked to
    /// `.deviceIndependentFlagsMask`) and then the `.keyDown` itself, with the event's
    /// characters carried verbatim -- regardless of the live input source.
    @Test func keyDownOnAlwaysScancodeKeyEmitsFlagsThenKeyDown() throws {
        let (view, events) = Self.makeView()
        // .shift plus a junk low bit that is NOT device-independent -- the mask must strip it.
        let dirtyFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: dirtyFlags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: event)
        let seen = events()
        try #require(seen.count == 2)
        guard case .flagsChanged(let flags) = seen[0] else {
            Issue.record("first event was \(seen[0]), expected .flagsChanged")
            return
        }
        #expect(flags == event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        #expect(!flags.contains(NSEvent.ModifierFlags(rawValue: 0x4)))
        guard case .keyDown(let code, let chars, let charsIM) = seen[1] else {
            Issue.record("second event was \(seen[1]), expected .keyDown")
            return
        }
        #expect(code == 36)
        #expect(chars == "\r")
        #expect(charsIM == "\r")
    }

    /// Mirror of the keyDown routing for keyUp: same carve-out, same reconciliation-first
    /// ordering.
    @Test func keyUpOnAlwaysScancodeKeyEmitsFlagsThenKeyUp() throws {
        let (view, events) = Self.makeView()
        let event = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53 // Escape
        ))
        view.keyUp(with: event)
        let seen = events()
        try #require(seen.count == 2)
        guard case .flagsChanged = seen[0] else {
            Issue.record("first event was \(seen[0]), expected .flagsChanged")
            return
        }
        guard case .keyUp(let code, let chars, let charsIM) = seen[1] else {
            Issue.record("second event was \(seen[1]), expected .keyUp")
            return
        }
        // Review d7-r1 minor: the keyDown twin asserts the character payloads verbatim;
        // discarding them here would let a keyUp-only payload regression through.
        #expect(chars == "\u{1b}")
        #expect(charsIM == "\u{1b}")
        #expect(code == 53)
    }

    /// `flagsChanged(with:)` masks to `.deviceIndependentFlagsMask` before reporting.
    @Test func flagsChangedIsMasked() throws {
        let (view, events) = Self.makeView()
        let dirtyFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: dirtyFlags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55 // left Command
        ))
        view.flagsChanged(with: event)
        let seen = events()
        try #require(seen.count == 1)
        guard case .flagsChanged(let flags) = seen[0] else {
            Issue.record("event was \(seen[0]), expected .flagsChanged")
            return
        }
        #expect(flags == event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    /// Windowless left click: down/up forwarded as `.mouseButton(.left, ...)` with the
    /// event's location passed through verbatim (`screenPoint(for:)`'s no-window fallback).
    @Test func leftMouseDownUpForwardedWithLocation() throws {
        let (view, events) = Self.makeView()
        let location = NSPoint(x: 12.5, y: 34.25)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        let seen = events()
        try #require(seen.count == 2)
        guard case .mouseButton(.left, true, let downPoint) = seen[0] else {
            Issue.record("first event was \(seen[0]), expected left-down")
            return
        }
        #expect(downPoint == location)
        guard case .mouseButton(.left, false, let upPoint) = seen[1] else {
            Issue.record("second event was \(seen[1]), expected left-up")
            return
        }
        // Review d7-r1 minor: the down half asserts its point; the up half must too, or a
        // regression that zeroes the release coordinate stays green.
        #expect(upPoint == location)
    }

    /// W4c review H1: a successful first-responder resignation reports `.focusLost` so the
    /// registry can release every held modifier.
    @Test func resignFirstResponderEmitsFocusLost() throws {
        let (view, events) = Self.makeView()
        #expect(view.resignFirstResponder())
        let seen = events()
        try #require(seen.count == 1)
        guard case .focusLost = seen[0] else {
            Issue.record("event was \(seen[0]), expected .focusLost")
            return
        }
    }

    /// adr/0011 §2: `insertText` forwards the committed string (plain or attributed) as
    /// `.unicodeText`, drops the empty commit, and ends any in-progress composition.
    @Test func insertTextCommitsAndClearsComposition() throws {
        let (view, events) = Self.makeView()
        let noRange = NSRange(location: NSNotFound, length: 0)

        view.setMarkedText("わた", selectedRange: noRange, replacementRange: noRange)
        #expect(view.hasMarkedText())
        view.insertText("わたし", replacementRange: noRange)
        #expect(!view.hasMarkedText()) // the commit ends the composition

        view.insertText(NSAttributedString(string: "です"), replacementRange: noRange)
        view.insertText("", replacementRange: noRange) // empty commit: no event
        view.insertText(42, replacementRange: noRange) // non-string payload: no event

        let seen = events()
        try #require(seen.count == 2)
        guard case .unicodeText("わたし") = seen[0] else {
            Issue.record("first event was \(seen[0]), expected .unicodeText(わたし)")
            return
        }
        guard case .unicodeText("です") = seen[1] else {
            Issue.record("second event was \(seen[1]), expected .unicodeText(です)")
            return
        }
    }

    /// The `NSTextInputClient` bookkeeping contract: `markedRange` reports UTF-16 length
    /// (`NSString` semantics -- pinned with a surrogate-pair character), `unmarkText` clears,
    /// and `selectedRange`/`characterIndex` report the conventional "unknown" answers.
    @Test func markedTextStateMachineUsesUTF16Lengths() {
        let (view, _) = Self.makeView()
        let noRange = NSRange(location: NSNotFound, length: 0)

        #expect(!view.hasMarkedText())
        #expect(view.markedRange().location == NSNotFound)

        view.setMarkedText("a𝄞", selectedRange: noRange, replacementRange: noRange) // 𝄞 = 2 UTF-16 units
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 3))

        view.setMarkedText(NSAttributedString(string: "ab"), selectedRange: noRange, replacementRange: noRange)
        #expect(view.markedRange() == NSRange(location: 0, length: 2))

        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(view.markedRange().location == NSNotFound)

        #expect(view.selectedRange().location == NSNotFound)
        #expect(view.characterIndex(for: .zero) == NSNotFound)
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: nil) == nil)
    }
}
