import AppKit
import Carbon
import Testing

// Lane D7: `RemoteWindowContentView`'s pure event-translation surface, driven with
// synthesized `NSEvent`s on a windowless view (constructible with no NSApplication and no
// NSWindow). See DisplayTopologyProviderTests.swift's file header for the lane's shared
// coverage-boundary register; boundaries specific to THIS file:
//
//  * The IME routing fork in `keyDown(with:)`/`keyUp(with:)` reads the input source through
//    `RemoteWindowContentView.inputSourceIsASCIICapable` (F-a1-5's seam), so which lane a key
//    takes IS assertable: the F-a1-5 tests below fix the answer and put the live read back in a
//    `defer`. That the seam's default is the live read is pinned twice (gate r1 m-3):
//    `seamDefaultIsTheLiveInputSourceRead` compares the default's answer with a
//    `TISCopyCurrentKeyboardInputSource` read of its own, and
//    `RemoteWindowKeyEquivalentTests.theSeamDeclarationCallsTheLiveRead` pins the declaration's
//    source. What stays unpinned is the live read's answer for any source other than the one the
//    test runner's user session has active (a test cannot select an input source). Tests that
//    leave the seam alone run with the live read; their keys (Return, Escape, on a view composing
//    nothing) take the scancode lane whatever it says.
//  * The hand-off to the input method goes through `RemoteWindowContentView.handOffToInputMethod`
//    (F-ja-2′ B-6's seam), so what an input method does with a key IS drivable: the B-1 / B-6
//    tests below set a stand-in that consumes the key, confirms the composition, or gives the key
//    back through `doCommand(by:)` as AppKit's key bindings do, and put AppKit's hand-off back in a
//    `defer`. That the default is AppKit's hand-off is pinned by source
//    (`RemoteWindowKeyEquivalentTests.theHandOffSeamIsTheOnlyInterpretKeyEventsCall`). Tests that
//    leave this seam alone get the live input context, which works on a windowless view: measured
//    2026-10-22 on the test runner's com.apple.keylayout.ABC source, "a" came back as
//    `insertText("a")`, ⌃A as `doCommand(moveToBeginningOfParagraph:)`, Delete as
//    `doCommand(deleteBackward:)`, ⌃O as two commands. What a real CJK input method makes of a key
//    is not drivable here (a test cannot select an input source).
//  * A keyUp follows its keyDown's lane through the ledgers (gate r1 I-1, F-ja-2′ B-1), so the ledger
//    tests drive a down and its up on ONE view (`makeSteppedView`), each step with its own
//    input-source answer. The ledgers are the session's (`KeyLaneLedgers`, B-1 gate r1 m-2): a view
//    built here keeps its own default instance, which is the single-view case; the m-2 tests drive
//    the down and the up on TWO views sharing one instance, as `RemoteWindowRegistry` builds them
//    (`makeSteppedView(sharing:)`), each next to its per-view control.
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

    /// F-a1-5's seam, fixed to `asciiCapable` for the length of `body`; the live read goes back in
    /// a `defer`, whatever `body` does.
    private static func withInputSource<T>(asciiCapable: Bool, _ body: () throws -> T) rethrows -> T {
        let live = RemoteWindowContentView.inputSourceIsASCIICapable
        RemoteWindowContentView.inputSourceIsASCIICapable = { asciiCapable }
        defer { RemoteWindowContentView.inputSourceIsASCIICapable = live }
        return try body()
    }

    /// An input method stand-in for F-ja-2′ B-6's seam: called with the view and the key it is handed.
    private typealias InputMethod = (RemoteWindowContentView, NSEvent) -> Void

    /// F-ja-2′ B-6's seam, set to `inputMethod` for the length of `body`; AppKit's hand-off goes back
    /// in a `defer`, whatever `body` does.
    private static func withInputMethod<T>(_ inputMethod: @escaping InputMethod, _ body: () throws -> T) rethrows -> T {
        let live = RemoteWindowContentView.handOffToInputMethod
        RemoteWindowContentView.handOffToInputMethod = inputMethod
        defer { RemoteWindowContentView.handOffToInputMethod = live }
        return try body()
    }

    /// An input method that takes every key it is handed (composes, edits, confirms, cancels) and
    /// gives none back -- the IME-lane outcome without the live input context's say.
    private static func consumes() -> InputMethod {
        { _, _ in }
    }

    /// An input method that gives every key back: AppKit's key bindings turn it into `commands`, one
    /// `doCommand(by:)` each, in order (⌃O is two).
    private static func givesBack(_ commands: Selector...) -> InputMethod {
        { view, _ in commands.forEach { view.doCommand(by: $0) } }
    }

    /// An input method that confirms the composition with `text`, as one does on Return.
    private static func confirms(_ text: String) -> InputMethod {
        { view, _ in view.insertText(text, replacementRange: noRange) }
    }

    /// A hand-off that must not happen.
    private static func neverHandedOff() -> InputMethod {
        { _, event in Issue.record("keyCode \(event.keyCode) was handed to the input method") }
    }

    private static let noRange = NSRange(location: NSNotFound, length: 0)

    /// Puts `view` mid-composition, as an input method's `setMarkedText` call does.
    private static func compose(_ view: RemoteWindowContentView, _ marked: String = "わた") {
        view.setMarkedText(marked, selectedRange: noRange, replacementRange: noRange)
    }

    private static func key(
        _ charactersIgnoringModifiers: String, characters: String? = nil, keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters ?? charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCode
        ))
    }

    /// Delivers `event` to `view` (as `keyDown` or `keyUp`, by its type) with the input source fixed
    /// to `asciiCapable`.
    private static func deliver(_ event: NSEvent, to view: RemoteWindowContentView, asciiCapable: Bool) {
        withInputSource(asciiCapable: asciiCapable) {
            if event.type == .keyUp {
                view.keyUp(with: event)
            } else {
                view.keyDown(with: event)
            }
        }
    }

    /// `deliver(_:to:asciiCapable:)` with F-ja-2′ B-6's seam set to `inputMethod` as well.
    private static func deliver(
        _ event: NSEvent, to view: RemoteWindowContentView, asciiCapable: Bool, inputMethod: @escaping InputMethod
    ) {
        withInputMethod(inputMethod) { deliver(event, to: view, asciiCapable: asciiCapable) }
    }

    /// What a fresh windowless view reports for `event` (delivered as `keyDown` or `keyUp` by its
    /// type) with the input source fixed to `asciiCapable`.
    private static func reported(_ event: NSEvent, asciiCapable: Bool) -> [RemoteWindowInputEvent] {
        let (view, events) = makeView()
        deliver(event, to: view, asciiCapable: asciiCapable)
        return events()
    }

    /// A windowless view whose reader returns what the view reported since the previous read, so
    /// one test can drive a keyDown and its keyUp on the same view and look at each step alone.
    private static func makeSteppedView() -> (RemoteWindowContentView, () -> [RemoteWindowInputEvent]) {
        let view = RemoteWindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let box = EventBox()
        view.onEvent = { box.events.append($0) }
        return (view, {
            defer { box.events.removeAll() }
            return box.events
        })
    }

    /// `makeSteppedView()` with its key-lane ledgers replaced by `ledgers` -- what `RemoteWindow` does
    /// with the instance `RemoteWindowRegistry` hands it (B-1 gate r1 m-2).
    private static func makeSteppedView(sharing ledgers: KeyLaneLedgers) -> (RemoteWindowContentView, () -> [RemoteWindowInputEvent]) {
        let (view, drain) = makeSteppedView()
        view.keyLedgers = ledgers
        return (view, drain)
    }

    /// Whether `events` holds `.keyDown` for `keyCode`.
    private static func hasKeyDown(_ keyCode: UInt16, in events: [RemoteWindowInputEvent]) -> Bool {
        events.contains { if case .keyDown(keyCode, _, _) = $0 { true } else { false } }
    }

    /// Whether `events` holds `.keyUp` for `keyCode`.
    private static func hasKeyUp(_ keyCode: UInt16, in events: [RemoteWindowInputEvent]) -> Bool {
        events.contains { if case .keyUp(keyCode, _, _) = $0 { true } else { false } }
    }

    private static func rendered(_ events: [RemoteWindowInputEvent]) -> [String] {
        events.map { "\($0)" }
    }

    /// Whether `events` holds a scancode key event (`.keyDown` or `.keyUp`).
    private static func hasScancodeKey(_ events: [RemoteWindowInputEvent]) -> Bool {
        events.contains {
            switch $0 {
            case .keyDown, .keyUp: true
            default: false
            }
        }
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
    /// characters carried verbatim -- regardless of the live input source, when nothing is being
    /// composed (a fresh view composes nothing; F-ja-2′ B-1 hands Return to the input method while
    /// it composes, `composingHandsEveryKeyToTheInputMethod`).
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

    // MARK: - F-a1-5: the input-source fork, through the seam

    /// F-a1-5 (a): under a non-ASCII-capable source (a CJK input method, the owner's usual state) a
    /// Command chord used to go to `interpretKeyEvents`, which swallowed it, so `CommandKeyMapper`
    /// never saw the key. It now takes the scancode lane: the alignment `.flagsChanged` carrying
    /// Command, then `.keyDown` -- exactly what an ASCII-capable source reports for the same event
    /// -- and never `.unicodeText`.
    /// ⌘⇧Z (gate r1 m-2) is `CommandKeyMapper`'s only Shift row: the rule is "contains Command",
    /// not "Command alone".
    @Test(
        "F-a1-5: a Command chord takes the scancode lane under a CJK source, exactly as under an ASCII one",
        arguments: [
            ("w", UInt16(13), NSEvent.ModifierFlags.command),
            ("c", UInt16(8), NSEvent.ModifierFlags.command),
            ("v", UInt16(9), NSEvent.ModifierFlags.command),
            ("z", UInt16(6), NSEvent.ModifierFlags.command),
            ("z", UInt16(6), NSEvent.ModifierFlags([.command, .shift])),
        ]
    )
    func commandChordTakesTheScancodeLaneUnderACJKSource(
        character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags
    ) throws {
        let event = try Self.key(character, keyCode: keyCode, flags)
        let cjk = Self.reported(event, asciiCapable: false)
        #expect(Self.rendered(cjk) == Self.rendered(Self.reported(event, asciiCapable: true)))
        try #require(cjk.count == 2, "\(cjk)")
        guard case .flagsChanged(let flags) = cjk[0] else {
            Issue.record("first event was \(cjk[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(flags.contains(.command))
        guard case .keyDown(let code, let chars, let charsIM) = cjk[1] else {
            Issue.record("second event was \(cjk[1]), expected .keyDown")
            return
        }
        #expect(code == keyCode)
        #expect(chars == character && charsIM == character)
        #expect(!cjk.contains { if case .unicodeText = $0 { true } else { false } })
    }

    /// F-a1-5 (a), the up half: the keyUp of a Command chord takes the same lane as its keyDown, so
    /// the remote key is released.
    @Test("F-a1-5: the keyUp of ⌘W takes the scancode lane under a CJK source too")
    func commandChordKeyUpTakesTheScancodeLaneUnderACJKSource() throws {
        let event = try Self.key("w", keyCode: 13, .command, type: .keyUp)
        let cjk = Self.reported(event, asciiCapable: false)
        #expect(Self.rendered(cjk) == Self.rendered(Self.reported(event, asciiCapable: true)))
        try #require(cjk.count == 2, "\(cjk)")
        guard case .flagsChanged(let flags) = cjk[0] else {
            Issue.record("first event was \(cjk[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(flags.contains(.command))
        guard case .keyUp(let code, _, let charsIM) = cjk[1] else {
            Issue.record("second event was \(cjk[1]), expected .keyUp")
            return
        }
        #expect(code == 13)
        #expect(charsIM == "w")
    }

    /// F-a1-5 changes nothing for a plain key: under a CJK source a bare letter still goes to the
    /// input method (whatever `interpretKeyEvents` does with it on a windowless view is not asserted
    /// beyond "no scancode key event"), and under an ASCII-capable source it is a scancode key.
    @Test("F-a1-5 leaves plain keys alone: a bare letter takes the IME lane under a CJK source, the scancode lane under an ASCII one")
    func plainKeysStillTakeTheIMELaneUnderACJKSource() throws {
        let down = try Self.key("a", keyCode: 0, [])
        let up = try Self.key("a", keyCode: 0, [], type: .keyUp)
        let cjkDown = Self.reported(down, asciiCapable: false)
        #expect(!Self.hasScancodeKey(cjkDown), "\(cjkDown)")
        let cjkUp = Self.reported(up, asciiCapable: false)
        #expect(!Self.hasScancodeKey(cjkUp), "\(cjkUp)")
        let asciiDown = Self.reported(down, asciiCapable: true)
        #expect(asciiDown.contains { if case .keyDown(0, "a", "a") = $0 { true } else { false } }, "\(asciiDown)")
        let asciiUp = Self.reported(up, asciiCapable: true)
        #expect(asciiUp.contains { if case .keyUp(0, "a", "a") = $0 { true } else { false } }, "\(asciiUp)")
    }

    /// The F-a1-5 row is Command only: a Control chord keeps today's fork (an input method does use
    /// some Control chords) -- the IME lane under a CJK source, the scancode lane under an ASCII one.
    /// The CJK half fixes F-ja-2′ B-6's seam to an input method that consumes the key: this test pins
    /// the fork, not what the input method then does. Left at AppKit's hand-off, the windowless
    /// view's input context gives ⌃A back as `doCommand(moveToBeginningOfParagraph:)` (measured
    /// 2026-10-22), and B-6 rightly sends a key given back down the scancode lane
    /// (`aKeyTheInputMethodGivesBackTakesTheScancodeLane`).
    @Test("F-a1-5 is Command only: ⌃A keeps today's fork")
    func controlChordKeepsTodaysFork() throws {
        let event = try Self.key("a", characters: "\u{1}", keyCode: 0, .control)
        let cjk = Self.withInputMethod(Self.consumes()) { Self.reported(event, asciiCapable: false) }
        #expect(!Self.hasScancodeKey(cjk), "\(cjk)")
        let ascii = Self.reported(event, asciiCapable: true)
        #expect(ascii.contains { if case .keyDown(0, _, "a") = $0 { true } else { false } }, "\(ascii)")
    }

    /// adr/0011 §1's always-scancode carve-out does not depend on the source when nothing is being
    /// composed: the Return keyDown and Escape keyUp pinned above report the same two events with the
    /// seam fixed to a CJK source, on fresh views that compose nothing (F-ja-2′ B-1 suspends the
    /// carve-out only while the input method composes, `composingHandsEveryKeyToTheInputMethod`).
    @Test("the always-scancode carve-out holds under a CJK source: Return down, Escape up")
    func alwaysScancodeKeysTakeTheScancodeLaneUnderACJKSource() throws {
        let enter = try Self.key("\r", keyCode: 36, [])
        let escape = try Self.key("\u{1b}", keyCode: 53, [], type: .keyUp)
        let down = Self.reported(enter, asciiCapable: false)
        try #require(down.count == 2, "\(down)")
        guard case .flagsChanged = down[0], case .keyDown(36, "\r", "\r") = down[1] else {
            Issue.record("Return under a CJK source reported \(down)")
            return
        }
        let up = Self.reported(escape, asciiCapable: false)
        try #require(up.count == 2, "\(up)")
        guard case .flagsChanged = up[0], case .keyUp(53, "\u{1b}", "\u{1b}") = up[1] else {
            Issue.record("Escape under a CJK source reported \(up)")
            return
        }
    }

    // MARK: - gate r1 I-1: a keyUp follows its keyDown's lane

    /// gate r1 I-1, the reviewer's P-1: under a CJK source ⌘R's keyDown takes the scancode lane
    /// (Command), so R is held on the server (⌘R is a passthrough chord: Win+R). Command released
    /// first, the R keyUp carries no modifier flags -- by its own flags it would take the IME lane
    /// and be dropped, leaving R held. It follows its keyDown instead: the alignment, then `.keyUp`.
    @Test("gate r1 I-1: R released after Command still takes the scancode lane ⌘R's keyDown took (CJK source)")
    func aLetterReleasedAfterCommandStillTakesTheScancodeLane() throws {
        let (view, drain) = Self.makeSteppedView()
        Self.deliver(try Self.key("r", keyCode: 15, .command), to: view, asciiCapable: false)
        let down = drain()
        #expect(Self.hasKeyDown(15, in: down), "\(down)")

        Self.deliver(try Self.key("r", keyCode: 15, [], type: .keyUp), to: view, asciiCapable: false)
        let up = drain()
        try #require(up.count == 2, "\(up)")
        guard case .flagsChanged(let flags) = up[0], flags.isEmpty, case .keyUp(15, "r", "r") = up[1] else {
            Issue.record("R's keyUp after Command's reported \(up), expected the empty alignment then .keyUp(15)")
            return
        }
    }

    /// The ledger only adds a reason to forward: a plain keyUp under a CJK source whose keyDown this
    /// view never sent down the scancode lane is dropped, as before -- with no keyDown at all, and
    /// after a keyDown that took the IME lane. Since F-ja-2′ B-1 the two drops have different
    /// reasons: the bare release by the input-source fork (neither ledger holds 0), the second by the
    /// input-method ledger (the keyDown was handed to the input method and, left at AppKit's
    /// hand-off, came back as `insertText("a")`, not as a command) -- which the fork would drop too.
    @Test("gate r1 I-1: a plain keyUp with no scancode keyDown recorded is still dropped under a CJK source")
    func aPlainKeyUpWithoutARecordedDownIsStillDropped() throws {
        let (view, drain) = Self.makeSteppedView()
        let down = try Self.key("a", keyCode: 0, [])
        let up = try Self.key("a", keyCode: 0, [], type: .keyUp)
        Self.deliver(up, to: view, asciiCapable: false)
        let bare = drain()
        #expect(!Self.hasScancodeKey(bare), "\(bare)")
        #expect(bare.count == 1, "only the alignment: \(bare)")

        Self.deliver(down, to: view, asciiCapable: false)
        let imeDown = drain()
        #expect(!Self.hasScancodeKey(imeDown), "\(imeDown)")
        Self.deliver(up, to: view, asciiCapable: false)
        let imeUp = drain()
        #expect(!Self.hasScancodeKey(imeUp), "an IME-lane keyDown records nothing: \(imeUp)")
    }

    /// The input source switching between a key's down and its up: "a" pressed under an
    /// ASCII-capable source went down the scancode lane, so its release under a CJK source does
    /// too, once -- the entry is consumed, and a second release is dropped. An up that forwards for
    /// another reason (the source is ASCII-capable again) consumes the entry as well, so a later
    /// release under a CJK source is not forwarded on its strength.
    @Test("gate r1 I-1: the ledger follows an input-source switch between down and up, and each entry is used once")
    func theLedgerFollowsAnInputSourceSwitch() throws {
        let (view, drain) = Self.makeSteppedView()
        let down = try Self.key("a", keyCode: 0, [])
        let up = try Self.key("a", keyCode: 0, [], type: .keyUp)

        Self.deliver(down, to: view, asciiCapable: true)
        let pressed = drain()
        #expect(Self.hasKeyDown(0, in: pressed), "\(pressed)")
        Self.deliver(up, to: view, asciiCapable: false)
        let released = drain()
        #expect(Self.hasKeyUp(0, in: released), "\(released)")
        Self.deliver(up, to: view, asciiCapable: false)
        let again = drain()
        #expect(!Self.hasScancodeKey(again), "the entry was consumed: \(again)")

        Self.deliver(down, to: view, asciiCapable: true)
        Self.deliver(up, to: view, asciiCapable: true)
        let asciiRound = drain()
        #expect(Self.hasKeyUp(0, in: asciiRound), "\(asciiRound)")
        Self.deliver(up, to: view, asciiCapable: false)
        let afterASCIIRound = drain()
        #expect(!Self.hasScancodeKey(afterASCIIRound), "an up forwarded for the source consumed the entry: \(afterASCIIRound)")
    }

    /// The ledger is never cleared: losing first responder between ⌘R's keyDown and R's keyUp
    /// (the `.focusLost` the registry answers by releasing modifiers only) leaves R recorded, so its
    /// release still reaches the wire. Clearing on resign would bring I-1 back for a key whose
    /// release arrives after a focus round trip.
    @Test("gate r1 I-1: the ledger survives the view resigning first responder between down and up")
    func theLedgerSurvivesLosingFirstResponder() throws {
        let (view, drain) = Self.makeSteppedView()
        Self.deliver(try Self.key("r", keyCode: 15, .command), to: view, asciiCapable: false)
        let down = drain()
        #expect(Self.hasKeyDown(15, in: down), "\(down)")
        #expect(view.resignFirstResponder())
        let resigned = drain()
        #expect(resigned.contains { if case .focusLost = $0 { true } else { false } }, "\(resigned)")

        Self.deliver(try Self.key("r", keyCode: 15, [], type: .keyUp), to: view, asciiCapable: false)
        let up = drain()
        #expect(Self.hasKeyUp(15, in: up), "\(up)")
    }

    // MARK: - F-ja-2′ B-1: while composing, every key goes to the input method

    /// Records the key codes an input-method stand-in is handed.
    private final class HandOffLog {
        var keyCodes: [UInt16] = []
    }

    /// Whether `events` holds `.unicodeText`.
    private static func hasUnicodeText(_ events: [RemoteWindowInputEvent]) -> Bool {
        events.contains { if case .unicodeText = $0 { true } else { false } }
    }

    /// F-ja-2′ B-1 (owner in person 2026-10-22: Japanese source, regedit's address bar, nothing ever
    /// appeared): while composing under a CJK source, Return / Escape / Tab / the arrows / Delete /
    /// the F keys are the input method's keys -- confirm, cancel, move through candidates, edit,
    /// convert. Each is handed to it and nothing but the alignment reaches the registry: no
    /// `.keyDown`, no `.keyUp`, no `.unicodeText` (the stand-in consumes the key). Before B-1 the
    /// always-scancode keys among them went out as scancodes and the composition was never confirmed.
    @Test(
        "F-ja-2′ B-1: composing under a CJK source, Return / Escape / Tab / Left / Delete / F1 go to the input method and only the alignment is reported",
        arguments: [
            (UInt16(36), "\r"), (UInt16(53), "\u{1b}"), (UInt16(48), "\t"),
            (UInt16(123), "\u{F702}"), (UInt16(51), "\u{7f}"), (UInt16(122), "\u{F704}"),
        ]
    )
    func composingHandsEveryKeyToTheInputMethod(keyCode: UInt16, character: String) throws {
        let event = try Self.key(character, keyCode: keyCode, [])
        let (view, events) = Self.makeView()
        Self.compose(view)
        let log = HandOffLog()
        Self.deliver(event, to: view, asciiCapable: false, inputMethod: { _, handed in log.keyCodes.append(handed.keyCode) })
        let seen = events()
        #expect(log.keyCodes == [keyCode], "handed: \(log.keyCodes)")
        try #require(seen.count == 1, "\(seen)")
        guard case .flagsChanged = seen[0] else {
            Issue.record("the one event was \(seen[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(!Self.hasScancodeKey(seen) && !Self.hasUnicodeText(seen), "\(seen)")
    }

    /// F-ja-2′ B-1's other half: with nothing composed the always-scancode keys keep adr/0011 §1's
    /// carve-out under a CJK source -- alignment, then `.keyDown` with the characters verbatim, and
    /// the input method is never handed them. (Delete, the sixth key above, is not an always-scancode
    /// key: with nothing composed it goes to the input method too, and comes back through
    /// `doCommand(by:)`, `aKeyTheInputMethodGivesBackTakesTheScancodeLane`.)
    @Test(
        "F-ja-2′ B-1: nothing composed, Return / Escape / Tab / Left / F1 still take the scancode lane under a CJK source",
        arguments: [
            (UInt16(36), "\r"), (UInt16(53), "\u{1b}"), (UInt16(48), "\t"),
            (UInt16(123), "\u{F702}"), (UInt16(122), "\u{F704}"),
        ]
    )
    func nothingComposedKeepsTheAlwaysScancodeCarveOut(keyCode: UInt16, character: String) throws {
        let event = try Self.key(character, keyCode: keyCode, [])
        let (view, events) = Self.makeView()
        Self.deliver(event, to: view, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let seen = events()
        try #require(seen.count == 2, "\(seen)")
        guard case .flagsChanged = seen[0], case .keyDown(keyCode, character, character) = seen[1] else {
            Issue.record("keyCode \(keyCode) with nothing composed reported \(seen)")
            return
        }
    }

    /// F-ja-2′ B-1, the up half: a Return the input method took keeps its release off the wire too,
    /// through the input-method ledger -- by its own flags Return's keyUp takes the scancode lane, so
    /// without the ledger the server would get an Enter-up with no Enter-down. Both ways the input
    /// method can take it: consumed with the composition still open, and confirmed (the stand-in
    /// commits, as one does on Return, so the release arrives with nothing composed).
    @Test("F-ja-2′ B-1: the keyUp of a Return the input method took is dropped, the composition confirmed or not", arguments: [false, true])
    func aReturnTheInputMethodTookKeepsItsReleaseOffTheWire(confirmed: Bool) throws {
        let (view, drain) = Self.makeSteppedView()
        Self.compose(view)
        let inputMethod = confirmed ? Self.confirms("私") : Self.consumes()
        Self.deliver(try Self.key("\r", keyCode: 36, []), to: view, asciiCapable: false, inputMethod: inputMethod)
        let down = drain()
        #expect(!Self.hasScancodeKey(down), "\(down)")
        #expect(Self.hasUnicodeText(down) == confirmed, "\(down)")
        #expect(view.hasMarkedText() == !confirmed)

        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: view, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let up = drain()
        try #require(up.count == 1, "only the alignment: \(up)")
        guard case .flagsChanged = up[0] else {
            Issue.record("the one event was \(up[0]), expected the alignment .flagsChanged")
            return
        }
    }

    /// F-ja-2′ B-1, a scancode record wins over an input-method one: Return confirms the composition
    /// (handed to the input method), then, held, auto-repeats with nothing composed -- that repeat
    /// takes the scancode lane and puts Return on the wire, so the one release must reach it too,
    /// although the first press is in the input-method ledger.
    @Test("F-ja-2′ B-1: a Return held past its confirmation repeats down the scancode lane, and its keyUp follows the repeat")
    func aReturnHeldPastItsConfirmationReleasesOnTheWire() throws {
        let (view, drain) = Self.makeSteppedView()
        Self.compose(view)
        let press = try Self.key("\r", keyCode: 36, [])
        Self.deliver(press, to: view, asciiCapable: false, inputMethod: Self.confirms("私"))
        let confirmed = drain()
        #expect(!Self.hasScancodeKey(confirmed) && !view.hasMarkedText(), "\(confirmed)")
        Self.deliver(press, to: view, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let repeated = drain()
        #expect(Self.hasKeyDown(36, in: repeated), "\(repeated)")
        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: view, asciiCapable: false)
        let released = drain()
        #expect(Self.hasKeyUp(36, in: released), "\(released)")
        // gate r1 m-1 (mutant G1): that release consumed BOTH ledgers' entries for 36, so a later bare
        // Return keyUp with no press recorded anywhere is judged by today's guard (always-scancode)
        // and reaches the wire -- a leftover input-method entry would have swallowed it.
        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: view, asciiCapable: false)
        let bare = drain()
        #expect(Self.hasKeyUp(36, in: bare), "\(bare)")
    }

    /// F-ja-2′ B-1 keeps F-a1-5: a Command chord takes the scancode lane mid-composition too -- the
    /// alignment carrying Command, then `.keyDown(13)`, the shape
    /// `commandChordTakesTheScancodeLaneUnderACJKSource` pins with nothing composed -- and the input
    /// method is never handed it.
    @Test("F-ja-2′ B-1: ⌘W mid-composition under a CJK source still takes the scancode lane")
    func aCommandChordMidCompositionStillTakesTheScancodeLane() throws {
        let (view, events) = Self.makeView()
        Self.compose(view)
        Self.deliver(try Self.key("w", keyCode: 13, .command), to: view, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let seen = events()
        try #require(seen.count == 2, "\(seen)")
        guard case .flagsChanged(let flags) = seen[0], case .keyDown(13, "w", "w") = seen[1] else {
            Issue.record("⌘W mid-composition reported \(seen)")
            return
        }
        #expect(flags.contains(.command))
    }

    /// F-ja-2′ B-1's composition test lives inside the IME fork: under an ASCII-capable source,
    /// marked text left behind (an input method that never called `unmarkText`) does not pull Return
    /// into the input method -- it takes the scancode lane, and the input method is never handed it.
    @Test("F-ja-2′ B-1: under an ASCII-capable source, marked text left behind does not hand Return to the input method")
    func leftoverMarkedTextUnderAnASCIISourceDoesNotTakeTheInputMethodLane() throws {
        let (view, events) = Self.makeView()
        Self.compose(view, "x")
        Self.deliver(try Self.key("\r", keyCode: 36, []), to: view, asciiCapable: true, inputMethod: Self.neverHandedOff())
        let seen = events()
        try #require(seen.count == 2, "\(seen)")
        guard case .flagsChanged = seen[0], case .keyDown(36, "\r", "\r") = seen[1] else {
            Issue.record("Return under an ASCII source with leftover marked text reported \(seen)")
            return
        }
    }

    // MARK: - F-ja-2′ B-6: a key the input method gives back takes the scancode lane

    /// F-ja-2′ B-6 (owner in person 2026-10-22: Japanese source, nothing composed, Delete only
    /// beeped): the input method does not want the Delete, AppKit's key bindings turn it into
    /// `deleteBackward:` and call `doCommand(by:)` -- which now sends the key down the scancode lane:
    /// exactly the alignment and `.keyDown(51, "\u{7f}", "\u{7f}")`. Its keyUp is forwarded: the
    /// fallback recorded 51 in the scancode ledger (under a CJK source a plain Delete-up with no
    /// record is dropped).
    @Test("F-ja-2′ B-6: a Delete the input method gives back under a CJK source goes down the scancode lane, its keyUp after it")
    func aKeyTheInputMethodGivesBackTakesTheScancodeLane() throws {
        let (view, drain) = Self.makeSteppedView()
        let inputMethod = Self.givesBack(#selector(NSResponder.deleteBackward(_:)))
        Self.deliver(try Self.key("\u{7f}", keyCode: 51, []), to: view, asciiCapable: false, inputMethod: inputMethod)
        let down = drain()
        try #require(down.count == 2, "\(down)")
        guard case .flagsChanged = down[0], case .keyDown(51, "\u{7f}", "\u{7f}") = down[1] else {
            Issue.record("a Delete given back reported \(down)")
            return
        }

        Self.deliver(try Self.key("\u{7f}", keyCode: 51, [], type: .keyUp), to: view, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let up = drain()
        try #require(up.count == 2, "\(up)")
        guard case .flagsChanged = up[0], case .keyUp(51, "\u{7f}", "\u{7f}") = up[1] else {
            Issue.record("the keyUp of a Delete given back reported \(up)")
            return
        }
    }

    /// F-ja-2′ B-6: the fallback sends the event being interpreted -- its key code and both character
    /// fields, verbatim -- not one made up from the command (the stand-in gives back
    /// `insertNewline:`, which belongs to neither key) and not `NSApp.currentEvent`. ⌃A's three
    /// fields all differ from each other's and from Return's.
    @Test(
        "F-ja-2′ B-6: the key given back is the original event, field by field",
        arguments: [
            (UInt16(51), "\u{7f}", "\u{7f}", NSEvent.ModifierFlags()),
            (UInt16(0), "\u{1}", "a", NSEvent.ModifierFlags.control),
        ]
    )
    func theKeyGivenBackIsTheOriginalEvent(
        keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, flags: NSEvent.ModifierFlags
    ) throws {
        let event = try Self.key(charactersIgnoringModifiers, characters: characters, keyCode: keyCode, flags)
        let (view, events) = Self.makeView()
        Self.deliver(event, to: view, asciiCapable: false, inputMethod: Self.givesBack(#selector(NSResponder.insertNewline(_:))))
        let keyDowns: [(UInt16, String, String)] = events().compactMap {
            if case .keyDown(let code, let chars, let charsIM) = $0 { (code, chars, charsIM) } else { nil }
        }
        try #require(keyDowns.count == 1, "\(events())")
        #expect(keyDowns[0].0 == event.keyCode)
        #expect(keyDowns[0].1 == event.characters)
        #expect(keyDowns[0].2 == event.charactersIgnoringModifiers)
    }

    /// F-ja-2′ B-6, once per key: AppKit's standard bindings give ⌃O back as TWO commands
    /// (`insertNewlineIgnoringFieldEditor:` then `moveBackward:`, measured 2026-10-22). One physical
    /// press puts one `.keyDown` on the wire, not a press and a repeat; its keyUp follows, once.
    @Test("F-ja-2′ B-6: a key given back as two commands (⌃O) goes down the scancode lane once")
    func aKeyGivenBackAsTwoCommandsIsSentOnce() throws {
        let (view, drain) = Self.makeSteppedView()
        let inputMethod = Self.givesBack(
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.moveBackward(_:))
        )
        Self.deliver(try Self.key("o", characters: "\u{f}", keyCode: 31, .control), to: view, asciiCapable: false, inputMethod: inputMethod)
        let down = drain()
        try #require(down.count == 2, "\(down)")
        guard case .flagsChanged = down[0], case .keyDown(31, "\u{f}", "o") = down[1] else {
            Issue.record("⌃O given back as two commands reported \(down)")
            return
        }
        Self.deliver(try Self.key("o", characters: "\u{f}", keyCode: 31, [], type: .keyUp), to: view, asciiCapable: false)
        let up = drain()
        #expect(up.filter { if case .keyUp(31, _, _) = $0 { true } else { false } }.count == 1, "\(up)")
    }

    /// F-ja-2′ B-6 only answers a command for the key being handed over: `doCommand(by:)` called on
    /// its own -- on a fresh view, and on a view that has just handed a key to an input method that
    /// consumed it -- sends nothing (it goes to `NSResponder`, as before) and does not crash.
    @Test("F-ja-2′ B-6: doCommand(by:) outside a hand-off sends nothing")
    func doCommandOutsideAHandOffSendsNothing() throws {
        let (view, drain) = Self.makeSteppedView()
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        let fresh = drain()
        #expect(fresh.isEmpty, "\(fresh)")

        Self.deliver(try Self.key("a", keyCode: 0, []), to: view, asciiCapable: false, inputMethod: Self.consumes())
        _ = drain()
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        let after = drain()
        #expect(after.isEmpty, "after a consumed hand-off: \(after)")
    }

    /// F-ja-2′ B-6 does not depend on the composition: a Return handed to the input method
    /// mid-composition that the input method lets through (`insertNewline:`) goes down the scancode
    /// lane like any key given back, and so does its keyUp.
    @Test("F-ja-2′ B-6: a Return the input method lets through mid-composition reaches the wire")
    func aReturnLetThroughMidCompositionReachesTheWire() throws {
        let (view, drain) = Self.makeSteppedView()
        Self.compose(view)
        Self.deliver(
            try Self.key("\r", keyCode: 36, []), to: view, asciiCapable: false,
            inputMethod: Self.givesBack(#selector(NSResponder.insertNewline(_:)))
        )
        let down = drain()
        try #require(down.count == 2, "\(down)")
        guard case .flagsChanged = down[0], case .keyDown(36, "\r", "\r") = down[1] else {
            Issue.record("a Return let through reported \(down)")
            return
        }
        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: view, asciiCapable: false)
        let up = drain()
        #expect(Self.hasKeyUp(36, in: up), "\(up)")
    }

    /// F-ja-2′ B-6 through AppKit's own hand-off (the seam left at its default): the windowless
    /// view's live input context gives a Delete with nothing composed back as `deleteBackward:`
    /// (measured 2026-10-22 on the runner's ABC source), and it reaches the registry as
    /// `.keyDown(51)`. The one runtime test of the default hand-off (the source pin is
    /// `RemoteWindowKeyEquivalentTests.theHandOffSeamIsTheOnlyInterpretKeyEventsCall`). It rests on
    /// AppKit's standard key binding for Delete and on the runner's live source not keeping the key;
    /// an input method composing nothing has nothing to delete and is expected to give it back too.
    @Test("F-ja-2′ B-6: through AppKit's own hand-off, an empty Delete under a CJK source reaches the wire")
    func anEmptyDeleteThroughAppKitsHandOffReachesTheWire() throws {
        let seen = Self.reported(try Self.key("\u{7f}", keyCode: 51, []), asciiCapable: false)
        // gate r1 m-3: this is the one test that depends on the runner's live input source, so a red
        // names that source; under a CJK source read the lane's U-1 (an input method that hands the
        // key back asynchronously) before anything else.
        #expect(
            Self.hasKeyDown(51, in: seen),
            "\(seen); active input source \(Self.liveInputSourceID()); if this runner's source is a CJK input method, read F-ja-2′ U-1 first"
        )
    }

    // MARK: - F-ja-2′ B-1 gate r1 m-2: the key-lane ledgers are the session's

    /// Whether all three of `ledgers` are empty (the two lane ledgers and, since
    /// lane-focuslost-flush, the wire ledger `wireDown`, which no view writes -- so it stays empty in
    /// every test here that does not put a code in it by hand).
    private static func isEmpty(_ ledgers: KeyLaneLedgers) -> Bool {
        ledgers.scancodeDown.isEmpty && ledgers.inputMethodDown.isEmpty && ledgers.wireDown.isEmpty
    }

    /// S1 + S5. Gate r1 I-1's ⌘R across two windows: under a CJK source ⌘R's keyDown in window A
    /// takes the scancode lane (R held on the server), focus moves to window B, and Command released
    /// first, R's bare keyUp arrives at B. B finds the press in the ledgers it shares with A and
    /// forwards the release: the empty alignment, then `.keyUp(15)`. The entry is used once: a second
    /// R keyUp, back at A, is dropped by today's guard.
    @Test("B-1 gate r1 m-2: ⌘R pressed in window A, R released in window B, reaches the wire once (shared ledgers, CJK source)")
    func aReleaseInAnotherWindowFollowsThePressThroughTheSharedLedgers() throws {
        let ledgers = KeyLaneLedgers()
        let (a, drainA) = Self.makeSteppedView(sharing: ledgers)
        let (b, drainB) = Self.makeSteppedView(sharing: ledgers)
        Self.deliver(try Self.key("r", keyCode: 15, .command), to: a, asciiCapable: false)
        let down = drainA()
        #expect(Self.hasKeyDown(15, in: down), "\(down)")
        #expect(ledgers.scancodeDown == [15], "the press is recorded in the shared instance: \(ledgers.scancodeDown)")

        let release = try Self.key("r", keyCode: 15, [], type: .keyUp)
        Self.deliver(release, to: b, asciiCapable: false)
        let up = drainB()
        try #require(up.count == 2, "\(up)")
        guard case .flagsChanged(let flags) = up[0], flags.isEmpty, case .keyUp(15, "r", "r") = up[1] else {
            Issue.record("R's keyUp in window B reported \(up), expected the empty alignment then .keyUp(15)")
            return
        }
        #expect(Self.isEmpty(ledgers), "B's release consumed the entry: \(ledgers.scancodeDown) \(ledgers.inputMethodDown)")

        Self.deliver(release, to: a, asciiCapable: false)
        let again = drainA()
        #expect(!Self.hasScancodeKey(again) && again.count == 1, "the entry is used once: \(again)")
    }

    /// S1's control, the defect B-1 gate r1 m-2 names: with a ledger per view (two views built on their
    /// own, each with its default instance) the same ⌘R sequence leaves B with no record, and R's
    /// bare keyUp is dropped by the input-source fork -- R stays held on the server.
    @Test("B-1 gate r1 m-2, the defect: with a ledger per view, R released in window B is dropped (CJK source)")
    func perViewLedgersDropAReleaseWhoseFocusMoved() throws {
        let (a, drainA) = Self.makeSteppedView()
        let (b, drainB) = Self.makeSteppedView()
        #expect(a.keyLedgers !== b.keyLedgers, "views built on their own each keep their own ledgers")
        Self.deliver(try Self.key("r", keyCode: 15, .command), to: a, asciiCapable: false)
        let down = drainA()
        #expect(Self.hasKeyDown(15, in: down), "\(down)")

        Self.deliver(try Self.key("r", keyCode: 15, [], type: .keyUp), to: b, asciiCapable: false)
        let up = drainB()
        #expect(!Self.hasScancodeKey(up) && up.count == 1, "only the alignment: \(up)")
    }

    /// S2. F-ja-2′ B-1 across two windows: window A composes, its Return goes to the input method
    /// (consumed) -- no keyDown on the wire -- and the Return keyUp arrives at window B, composing
    /// nothing. B finds the input-method entry in the shared ledgers and drops the release: no
    /// keyUp without its keyDown.
    @Test("B-1 gate r1 m-2: a Return the input method took in window A has its keyUp dropped in window B (shared ledgers)")
    func aReleaseInAnotherWindowFollowsAnInputMethodPress() throws {
        let ledgers = KeyLaneLedgers()
        let (a, drainA) = Self.makeSteppedView(sharing: ledgers)
        let (b, drainB) = Self.makeSteppedView(sharing: ledgers)
        Self.compose(a)
        Self.deliver(try Self.key("\r", keyCode: 36, []), to: a, asciiCapable: false, inputMethod: Self.consumes())
        let down = drainA()
        #expect(!Self.hasScancodeKey(down), "\(down)")
        #expect(ledgers.inputMethodDown == [36], "the hand-off is recorded in the shared instance: \(ledgers.inputMethodDown)")

        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: b, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let up = drainB()
        try #require(up.count == 1, "only the alignment: \(up)")
        guard case .flagsChanged = up[0] else {
            Issue.record("the one event was \(up[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(Self.isEmpty(ledgers), "\(ledgers.scancodeDown) \(ledgers.inputMethodDown)")
    }

    /// S2's control, the defect: with a ledger per view, B has no input-method entry, and by its own
    /// flags Return's keyUp takes the scancode lane -- an Enter-up with no Enter-down reaches the wire.
    @Test("B-1 gate r1 m-2, the defect: with a ledger per view, the keyUp of a Return the input method took reaches the wire from window B")
    func perViewLedgersForwardAReleaseWhosePressTheInputMethodTook() throws {
        let (a, drainA) = Self.makeSteppedView()
        let (b, drainB) = Self.makeSteppedView()
        Self.compose(a)
        Self.deliver(try Self.key("\r", keyCode: 36, []), to: a, asciiCapable: false, inputMethod: Self.consumes())
        let down = drainA()
        #expect(!Self.hasScancodeKey(down), "\(down)")

        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: b, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let up = drainB()
        #expect(Self.hasKeyUp(36, in: up), "\(up)")
    }

    /// S3. F-ja-2′ B-6 across two windows: window A hands an empty-state Delete to the input method,
    /// which gives it back (`deleteBackward:`); `doCommand(by:)` sends it down the scancode lane and
    /// moves 51 from the shared input-method ledger to the shared scancode ledger -- one entry, in
    /// one ledger, of the one instance. Its keyUp at window B is forwarded and consumes it.
    @Test("B-1 gate r1 m-2: a Delete given back in window A moves to the shared scancode ledger and its keyUp in window B reaches the wire")
    func aKeyGivenBackMovesWithinTheSharedLedgers() throws {
        let ledgers = KeyLaneLedgers()
        let (a, drainA) = Self.makeSteppedView(sharing: ledgers)
        let (b, drainB) = Self.makeSteppedView(sharing: ledgers)
        let inputMethod = Self.givesBack(#selector(NSResponder.deleteBackward(_:)))
        Self.deliver(try Self.key("\u{7f}", keyCode: 51, []), to: a, asciiCapable: false, inputMethod: inputMethod)
        let down = drainA()
        try #require(down.count == 2, "\(down)")
        guard case .flagsChanged = down[0], case .keyDown(51, "\u{7f}", "\u{7f}") = down[1] else {
            Issue.record("a Delete given back in window A reported \(down)")
            return
        }
        #expect(a.keyLedgers === ledgers)
        #expect(ledgers.inputMethodDown.isEmpty, "no input-method entry left behind: \(ledgers.inputMethodDown)")
        #expect(ledgers.scancodeDown == [51], "\(ledgers.scancodeDown)")

        Self.deliver(try Self.key("\u{7f}", keyCode: 51, [], type: .keyUp), to: b, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let up = drainB()
        try #require(up.count == 2, "\(up)")
        guard case .flagsChanged = up[0], case .keyUp(51, "\u{7f}", "\u{7f}") = up[1] else {
            Issue.record("the Delete keyUp in window B reported \(up)")
            return
        }
        #expect(Self.isEmpty(ledgers), "\(ledgers.scancodeDown) \(ledgers.inputMethodDown)")
    }

    /// S4. `reset()` empties all three ledgers: after ⌘R (scancode entry 15) and a composing Return
    /// taken by the input method (input-method entry 36) in window A -- and R on the wire ledger, put
    /// there by hand as the registry's wire exit would when ⌘R's keyDown went out (no view writes it;
    /// lane-focuslost-flush) -- a reset leaves nothing, and window B judges both releases by today's
    /// guard -- R's dropped (a letter under a CJK source), Return's forwarded (an always-scancode key
    /// with no record either way). Lane-focuslost-flush mutant M6: `reset()` leaving `wireDown` alone.
    @Test("B-1 gate r1 m-2: reset() empties all three shared ledgers, and the releases fall back to today's guard")
    func resetEmptiesEverySharedLedger() throws {
        let ledgers = KeyLaneLedgers()
        let (a, drainA) = Self.makeSteppedView(sharing: ledgers)
        let (b, drainB) = Self.makeSteppedView(sharing: ledgers)
        Self.deliver(try Self.key("r", keyCode: 15, .command), to: a, asciiCapable: false)
        Self.compose(a)
        Self.deliver(try Self.key("\r", keyCode: 36, []), to: a, asciiCapable: false, inputMethod: Self.consumes())
        _ = drainA()
        ledgers.wireDown.insert(15)
        try #require(ledgers.scancodeDown == [15] && ledgers.inputMethodDown == [36] && ledgers.wireDown == [15],
                     "setup: \(ledgers.scancodeDown) \(ledgers.inputMethodDown) \(ledgers.wireDown)")

        ledgers.reset()
        #expect(Self.isEmpty(ledgers), "\(ledgers.scancodeDown) \(ledgers.inputMethodDown) \(ledgers.wireDown)")
        #expect(ledgers.wireDown.isEmpty, "\(ledgers.wireDown)")

        Self.deliver(try Self.key("r", keyCode: 15, [], type: .keyUp), to: b, asciiCapable: false)
        let letter = drainB()
        #expect(!Self.hasScancodeKey(letter) && letter.count == 1, "R's release is judged by today's guard: \(letter)")
        Self.deliver(try Self.key("\r", keyCode: 36, [], type: .keyUp), to: b, asciiCapable: false, inputMethod: Self.neverHandedOff())
        let enter = drainB()
        #expect(Self.hasKeyUp(36, in: enter), "Return's release is judged by today's guard: \(enter)")
    }

    // MARK: - gate r1 m-3: the seam's default is the live read

    /// gate r1 m-3 (F-ja-2′): the active input source's `kTISPropertyInputSourceID`, for the failure
    /// message of the one test that depends on it; "<unreadable>" when it cannot be read.
    private static func liveInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return "<unreadable>"
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// What `TISCopyCurrentKeyboardInputSource` says right now, read here independently of the
    /// product's own read; an unreadable source or property counts as ASCII-capable, as the
    /// product's read treats it.
    private static func liveInputSourceIsASCIICapable() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return true
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// gate r1 m-3: a constant default (`{ true }`) would silently close the IME lane for every CJK
    /// user while every seam-fixed test stayed green. With the seam left at its default, its answer
    /// is the live input source's. This half catches a constant only while the runner's active source
    /// disagrees with it; `RemoteWindowKeyEquivalentTests.theSeamDeclarationCallsTheLiveRead` pins
    /// the declaration itself.
    @Test("gate r1 m-3: the input-source seam, left at its default, answers what the live input source says")
    func seamDefaultIsTheLiveInputSourceRead() {
        #expect(RemoteWindowContentView.inputSourceIsASCIICapable() == Self.liveInputSourceIsASCIICapable())
    }
}
