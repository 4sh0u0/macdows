import AppKit
import Testing

// adr/0022 (UI slice ⓪), commit 1: the content view claims Command key equivalents before the
// main menu can (D-2 B), keeps the four Mac-reserved pairs local (D-3), and remote windows stay
// out of the Window menu (D-5 W2). D-8 T-2′ and T-5 live here; T-3 is MacdowsCore's
// `CommandKeyMapperTests`.
//
// Coverage boundary, stated: these tests call `performKeyEquivalent(with:)` / `keyDown(with:)`
// directly. Whether AppKit really asks the key window's views BEFORE the menu bar is the
// documented order (Cocoa Event Handling Guide) and is the gate r1 probe's job (adr/0022 §6 R-1);
// the xctest host cannot make a window key (`makeKeyAndOrderFront` leaves `isKeyWindow` false
// here), so "key" is supplied by `KeyStateWindow`, a window whose `isKeyWindow` the test sets. A
// standalone .app launched through LaunchServices (`open`) does get a real key window: gate r1's
// probe `probe-dispatch-order.swift` ran that way and observed the view answering before the menu.
// Claimed events are compared with what `keyDown` produces for the same event on a twin view --
// the claim must be "the same body", whatever that body does here. Since F-a1-5 that body sends a
// Command chord down the scancode lane whatever the input source; the lane itself is pinned with
// the input-source seam fixed to a CJK source (`aClaimedChordIsNotHandedToTheIMEUnderACJKSource`).

private func keyEquivalentRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Line comments removed, whitespace folded -- the stripping `AppDelegateSessionEndPinTests` uses,
/// so a count is about statements and not about the prose explaining them. It handles `//` only
/// (`RemoteWindowRegistry.swift` has no block comments) and would also cut a `//` inside a string
/// literal; `theRegistryStripKeepsTheSeam` below is what keeps the strip honest for this file.
private func keyEquivalentCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func keyEquivalentOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// A window whose key state the test decides (see the file header).
private final class KeyStateWindow: NSWindow {
    var keyState = true
    override var isKeyWindow: Bool { keyState }
}

@MainActor
@Suite("RemoteWindowContentView key equivalents (adr/0022)")
struct RemoteWindowKeyEquivalentTests {
    private final class EventBox {
        var events: [RemoteWindowInputEvent] = []
        var rendered: [String] { events.map { "\($0)" } }
    }

    /// A content view inside a `KeyStateWindow`, made first responder -- the I-4 premise holds.
    private static func makeHosted(key: Bool = true) -> (KeyStateWindow, RemoteWindowContentView, EventBox) {
        let window = KeyStateWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.keyState = key
        let view = RemoteWindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = view
        let box = EventBox()
        view.onEvent = { box.events.append($0) }
        _ = window.makeFirstResponder(view)
        return (window, view, box)
    }

    /// What `keyDown` alone reports for `event`, on a windowless twin view.
    private static func keyDownEvents(_ event: NSEvent) -> [String] {
        let view = RemoteWindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let box = EventBox()
        view.onEvent = { box.events.append($0) }
        view.keyDown(with: event)
        return box.rendered
    }

    private static func key(
        _ character: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode
        ))
    }

    // MARK: - The reserved set itself

    @Test("the reserved set is exactly ⌘Q, ⌘H, ⌥⌘H, ⌘, (adr/0022 D-3 R4)")
    func reservedSetIsR4() {
        let pairs = LocalKeyEquivalent.reserved.map { "\($0.character)/\($0.modifiers.rawValue)" }
        let command = NSEvent.ModifierFlags.command.rawValue
        let optionCommand = NSEvent.ModifierFlags([.command, .option]).rawValue
        #expect(pairs == ["q/\(command)", "h/\(command)", "h/\(optionCommand)", ",/\(command)"])
        #expect(LocalKeyEquivalent.comparedModifiers == [.command, .option, .control, .shift])
    }

    // MARK: - T-2′: claimed Command keys go the keyDown way and the menu never sees them

    @Test(
        "a non-reserved Command key is claimed (YES) and reports exactly what keyDown reports",
        arguments: [
            ("w", UInt16(13), NSEvent.ModifierFlags.command),
            ("c", UInt16(8), NSEvent.ModifierFlags.command),
            ("m", UInt16(46), NSEvent.ModifierFlags.command),
            ("h", UInt16(4), NSEvent.ModifierFlags([.command, .shift])),
            ("h", UInt16(4), NSEvent.ModifierFlags([.command, .control])),
            (",", UInt16(43), NSEvent.ModifierFlags([.command, .control])),
            ("q", UInt16(12), NSEvent.ModifierFlags([.command, .option])),
        ]
    )
    func nonReservedCommandKeyIsClaimed(character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        let event = try Self.key(character, keyCode: keyCode, flags)
        #expect(view.performKeyEquivalent(with: event) == true)
        let expected = Self.keyDownEvents(event)
        #expect(box.rendered == expected)
        try #require(!box.events.isEmpty)
        guard case .flagsChanged(let aligned) = box.events[0] else {
            Issue.record("first event was \(box.events[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(aligned.contains(.command))
        #expect(!box.rendered.contains("\(RemoteWindowInputEvent.localKeyEquivalent)"))
    }

    @Test(
        "a reserved pair is NOT claimed (NO): alignment, then .localKeyEquivalent, and no key event",
        arguments: [
            ("q", UInt16(12), NSEvent.ModifierFlags.command),
            ("h", UInt16(4), NSEvent.ModifierFlags.command),
            ("h", UInt16(4), NSEvent.ModifierFlags([.command, .option])),
            (",", UInt16(43), NSEvent.ModifierFlags.command),
        ]
    )
    func reservedPairGoesToTheMenu(character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        let event = try Self.key(character, keyCode: keyCode, flags)
        #expect(view.performKeyEquivalent(with: event) == false)
        try #require(box.events.count == 2)
        guard case .flagsChanged(let aligned) = box.events[0] else {
            Issue.record("first event was \(box.events[0]), expected the alignment .flagsChanged")
            return
        }
        // The alignment carries Cmd, so a Cmd press this view never saw still puts the mapper
        // into its withheld state before the bare letter could reach the ordinary lane.
        #expect(aligned == flags.intersection(.deviceIndependentFlagsMask))
        guard case .localKeyEquivalent = box.events[1] else {
            Issue.record("second event was \(box.events[1]), expected .localKeyEquivalent")
            return
        }
    }

    @Test("Caps Lock and Fn take no part in the match: ⌘H with them is still reserved")
    func capsLockAndFunctionBitsAreIgnored() throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        let event = try Self.key("h", keyCode: 4, [.command, .capsLock, .function])
        #expect(view.performKeyEquivalent(with: event) == false)
        #expect(box.events.count == 2)
        #expect(box.rendered.last == "\(RemoteWindowInputEvent.localKeyEquivalent)")
    }

    @Test("an upper-case H from charactersIgnoringModifiers still matches ⌘H (lower-cased compare)")
    func characterIsLowerCased() throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: try Self.key("H", keyCode: 4, .command)) == false)
        #expect(box.rendered.last == "\(RemoteWindowInputEvent.localKeyEquivalent)")
    }

    @Test(
        "no Command bit (a Control key equivalent, or none): not claimed, nothing reported",
        arguments: [NSEvent.ModifierFlags.control, NSEvent.ModifierFlags([.control, .option]), NSEvent.ModifierFlags()]
    )
    func nonCommandIsNotClaimed(flags: NSEvent.ModifierFlags) throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: try Self.key("c", keyCode: 8, flags)) == false)
        #expect(box.events.isEmpty)
    }

    /// F-a1-5 (a): the claim path shares `handleKeyDown`, so the fork fix holds there too -- under a
    /// non-ASCII-capable source a claimed ⌘W reports the alignment and then the key itself, instead
    /// of being handed to `interpretKeyEvents` and swallowed (YES was returned all the same, so the
    /// menu never saw it either: ⌘W did nothing at all).
    @Test("F-a1-5: a claimed ⌘W under a CJK source is not handed to the IME: alignment, then the key")
    func aClaimedChordIsNotHandedToTheIMEUnderACJKSource() throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        let event = try Self.key("w", keyCode: 13, .command)
        let live = RemoteWindowContentView.inputSourceIsASCIICapable
        RemoteWindowContentView.inputSourceIsASCIICapable = { false }
        defer { RemoteWindowContentView.inputSourceIsASCIICapable = live }
        #expect(view.performKeyEquivalent(with: event) == true)
        try #require(box.events.count == 2, "\(box.rendered)")
        guard case .flagsChanged(let aligned) = box.events[0] else {
            Issue.record("first event was \(box.events[0]), expected the alignment .flagsChanged")
            return
        }
        #expect(aligned.contains(.command))
        guard case .keyDown(let code, _, let charsIM) = box.events[1] else {
            Issue.record("second event was \(box.events[1]), expected .keyDown")
            return
        }
        #expect(code == 13)
        #expect(charsIM == "w")
    }

    @Test("adr/0022 I-4: a window that is not key claims nothing, reserved or not")
    func notKeyWindowClaimsNothing() throws {
        let (window, view, box) = Self.makeHosted(key: false)
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: try Self.key("c", keyCode: 8, .command)) == false)
        #expect(view.performKeyEquivalent(with: try Self.key("h", keyCode: 4, .command)) == false)
        #expect(box.events.isEmpty)
    }

    @Test("adr/0022 I-4: a view that is not first responder claims nothing, reserved or not")
    func notFirstResponderClaimsNothing() throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        let sibling = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        view.addSubview(sibling)
        try #require(window.makeFirstResponder(sibling))
        try #require(window.firstResponder !== view)
        box.events.removeAll() // the resign itself reports .focusLost; that is not under test here
        #expect(view.performKeyEquivalent(with: try Self.key("c", keyCode: 8, .command)) == false)
        #expect(view.performKeyEquivalent(with: try Self.key("q", keyCode: 12, .command)) == false)
        #expect(box.events.isEmpty)
    }

    @Test("a key-up event is never claimed")
    func keyUpIsNotClaimed() throws {
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: try Self.key("c", keyCode: 8, .command, type: .keyUp)) == false)
        #expect(box.events.isEmpty)
    }

    // MARK: - The re-delivered keyDown of a reserved pair

    @Test(
        "keyDown of a reserved pair reports only .localKeyEquivalent: no alignment, no key, never the table",
        arguments: [
            ("q", UInt16(12), NSEvent.ModifierFlags.command),
            ("h", UInt16(4), NSEvent.ModifierFlags.command),
            ("h", UInt16(4), NSEvent.ModifierFlags([.command, .option])),
            (",", UInt16(43), NSEvent.ModifierFlags.command),
        ]
    )
    func reservedKeyDownIsLocalOnly(character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        #expect(Self.keyDownEvents(try Self.key(character, keyCode: keyCode, flags))
            == ["\(RemoteWindowInputEvent.localKeyEquivalent)"])
    }

    @Test("keyDown of a near miss (⇧⌘H) still takes the ordinary keyDown body")
    func nearMissKeyDownIsOrdinary() throws {
        let events = Self.keyDownEvents(try Self.key("h", keyCode: 4, [.command, .shift]))
        #expect(!events.contains("\(RemoteWindowInputEvent.localKeyEquivalent)"))
        #expect(events.first?.hasPrefix("flagsChanged") == true)
    }

    /// gate r1 I-1's keyUp ledger records only keyDowns that took the scancode lane; a reserved
    /// pair's keyDown never reaches it -- `performKeyEquivalent` hands the pair to the menu and the
    /// re-delivered `keyDown` returns before `handleKeyDown` -- so the pair's release is what it was
    /// before the ledger: Q released while ⌘ is still held reports the alignment and `.keyUp` (a
    /// Command chord's lane), and Q released after ⌘ under a CJK source reports only the alignment.
    /// No earlier pin covered a reserved pair's `keyUp(with:)` (`keyUpIsNotClaimed` is about
    /// `performKeyEquivalent`), so this is a new test rather than an extended one.
    @Test("gate r1 I-1: a reserved pair's release is unchanged by the keyUp ledger (⌘Q)")
    func aReservedPairsReleaseIsUnchanged() throws {
        let live = RemoteWindowContentView.inputSourceIsASCIICapable
        defer { RemoteWindowContentView.inputSourceIsASCIICapable = live }
        let down = try Self.key("q", keyCode: 12, .command)

        RemoteWindowContentView.inputSourceIsASCIICapable = { true }
        let (window, view, box) = Self.makeHosted()
        defer { window.close() }
        #expect(view.performKeyEquivalent(with: down) == false)
        box.events.removeAll()
        view.keyUp(with: try Self.key("q", keyCode: 12, .command, type: .keyUp))
        #expect(box.rendered == [
            "\(RemoteWindowInputEvent.flagsChanged(modifierFlags: .command))",
            "\(RemoteWindowInputEvent.keyUp(macKeyCode: 12, characters: "q", charactersIgnoringModifiers: "q"))",
        ])

        RemoteWindowContentView.inputSourceIsASCIICapable = { false }
        let (cjkWindow, cjkView, cjkBox) = Self.makeHosted()
        defer { cjkWindow.close() }
        #expect(cjkView.performKeyEquivalent(with: down) == false)
        cjkView.keyDown(with: down)
        cjkBox.events.removeAll()
        cjkView.keyUp(with: try Self.key("q", keyCode: 12, [], type: .keyUp))
        #expect(cjkBox.rendered == ["\(RemoteWindowInputEvent.flagsChanged(modifierFlags: []))"])
    }

    // MARK: - T-5: remote windows stay out of the Window menu (adr/0022 D-5 W2)

    @Test("a RemoteWindow's NSWindow is excluded from the Window menu")
    func remoteWindowIsExcludedFromWindowsMenu() {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 3, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "excluded-probe"
        )
        #expect(remote.window.isExcludedFromWindowsMenu)
    }

    // MARK: - Registry seam (gate r1 I-2, fold F-4)

    private static let registry = "App/RemoteWindowRendering/RemoteWindowRegistry.swift"

    private static func registryCode() throws -> String {
        let url = keyEquivalentRepoRoot().appendingPathComponent(registry)
        return keyEquivalentCodeOnly(try String(contentsOf: url, encoding: .utf8))
    }

    /// The text of the registry's `case .localKeyEquivalent:` arm, up to the next `case `.
    private static func localKeyEquivalentArm(in code: String) throws -> Substring {
        let label = "case .localKeyEquivalent:"
        #expect(keyEquivalentOccurrences(of: label, in: code) == 1, "the arm is not unique")
        let start = try #require(code.range(of: label))
        let next = try #require(code.range(of: "case ", range: start.upperBound..<code.endIndex))
        return code[start.upperBound..<next.lowerBound]
    }

    @Test("the registry strip keeps the seam and drops the prose around it")
    func theRegistryStripKeepsTheSeam() throws {
        let code = try Self.registryCode()
        #expect(code.contains("case .localKeyEquivalent:"))
        #expect(code.contains("commandKeyMapper.reset()"))
        #expect(!code.contains("adr/0022 D-3"), "a line comment survived the strip")
        #expect(!code.contains("// "), "a comment marker survived the strip")
    }

    /// adr/0022 I-2 end to end rests on this one line: the view's `.localKeyEquivalent` must reach
    /// `CommandKeyMapper.localKeyEquivalent()`, or ⌘H / ⌥⌘H / ⌘, / ⌘Q followed by Cmd-up sends a
    /// bare LWIN tap. The view tests stop at `onEvent` and the mapper tests start at the mapper, so
    /// this pins the hop between them by call shape (gate r1 mutant M12: the arm's body as `break`).
    @Test("the registry's .localKeyEquivalent arm calls commandKeyMapper.localKeyEquivalent() exactly once")
    func registryArmCallsTheMapper() throws {
        let arm = try Self.localKeyEquivalentArm(in: try Self.registryCode())
        #expect(keyEquivalentOccurrences(of: "commandKeyMapper.localKeyEquivalent()", in: String(arm)) == 1, "\(arm)")
    }

    // MARK: - F-a1-5's input-source seam (gate r1 m-3)

    private static let input = "App/RemoteWindowRendering/RemoteWindowInput.swift"

    /// gate r1 m-3: the seam's declaration line calls the live read, so the App -- which never sets
    /// the seam -- forks on the real input source. The runtime twin,
    /// `RemoteWindowInputTests.seamDefaultIsTheLiveInputSourceRead`, catches a constant default only
    /// while the runner's active source disagrees with it; this one always does. Each line goes
    /// through the strip on its own, so the declaration stays one line and its doc comment drops out.
    @Test("gate r1 m-3: the input-source seam's declaration defaults to isCurrentInputSourceASCIICapable()")
    func theSeamDeclarationCallsTheLiveRead() throws {
        let url = keyEquivalentRepoRoot().appendingPathComponent(Self.input)
        let text = try String(contentsOf: url, encoding: .utf8)
        let label = "static var inputSourceIsASCIICapable"
        #expect(keyEquivalentOccurrences(of: label, in: keyEquivalentCodeOnly(text)) == 1, "the seam is not declared once")
        let lines = text.split(separator: "\n").map { keyEquivalentCodeOnly(String($0)) }
        #expect(!lines.contains { $0.contains("F-a1-5's test seam") }, "a line comment survived the strip")
        let declaration = try #require(lines.first { $0.contains(label) })
        #expect(declaration.contains("isCurrentInputSourceASCIICapable()"), "\(declaration)")
    }
}
