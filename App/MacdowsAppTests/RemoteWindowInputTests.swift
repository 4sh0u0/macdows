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
//    test runner's user session has active (a test cannot select an input source), and what
//    `interpretKeyEvents` then does with a key (it needs a live input context), so the IME-lane
//    tests assert only "no scancode key event". Tests that leave the seam alone run with the live
//    read; their keys (Return, Escape) take the scancode lane whatever it says.
//  * A keyUp follows its keyDown's lane through the view's ledger (gate r1 I-1), so the ledger
//    tests drive a down and its up on ONE view (`makeSteppedView`), each step with its own
//    input-source answer.
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
    @Test("F-a1-5 is Command only: ⌃A keeps today's fork")
    func controlChordKeepsTodaysFork() throws {
        let event = try Self.key("a", characters: "\u{1}", keyCode: 0, .control)
        let cjk = Self.reported(event, asciiCapable: false)
        #expect(!Self.hasScancodeKey(cjk), "\(cjk)")
        let ascii = Self.reported(event, asciiCapable: true)
        #expect(ascii.contains { if case .keyDown(0, _, "a") = $0 { true } else { false } }, "\(ascii)")
    }

    /// adr/0011 §1's always-scancode carve-out does not depend on the source: the Return keyDown and
    /// Escape keyUp pinned above report the same two events with the seam fixed to a CJK source.
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
    /// after a keyDown that took the IME lane.
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

    // MARK: - gate r1 m-3: the seam's default is the live read

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
