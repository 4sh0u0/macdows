import AppKit
import MacdowsCore
import Testing

// F-ja-2′ B-1 gate r1 m-2: the content view's two key-lane ledgers (gate r1 I-1's scancode ledger,
// B-1's input-method ledger) are session-level -- one `KeyLaneLedgers` instance held by
// `RemoteWindowRegistry` and handed, through `RemoteWindow`, to every content view the registry
// creates. The behaviour across two views sharing one instance is `RemoteWindowInputTests`' m-2
// section; this file pins the wiring that makes the App's views share it: the view's injectable
// property, the window's hand-over, and the registry's one instance at its one creation point --
// by source (the call shapes) and by behaviour (identity of the instance the views end up with).
// Since lane-session-reset it also pins that the registry empties the instance at its session
// reset (`closeAllWindows()`, after `wireHeldModifiers = []`) and nowhere else: not when the window
// table empties mid-session, not on a `.focusLost` reaching the registry.
// Since lane-focuslost-flush the instance has a third member, the wire ledger `wireDown`: kept by the
// registry at its one wire exit (`sendKeyboardLaneEvent`), never by a view, and flushed -- a release
// per key, straight to the session -- by a `.focusLost` reaching the registry, keys before modifiers,
// lane ledgers left alone. The behaviour half drives the registry's keyboard lane to a spy session
// (`KeyLaneSpySession`), the first registry-level test of what keys reach the wire.

private func keyLaneLedgersRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Line comments removed, whitespace folded -- `RemoteWindowKeyEquivalentTests`' strip, so a count is
/// about statements and not about the prose explaining them. `//` only (none of the three files has
/// a block comment on a line pinned here); a `//` inside a string literal would cut that line, which
/// can only lose a pinned line (a red), never add one. `theStripDropsTheProse` keeps it honest.
private func keyLaneLedgersCode(_ relative: String) throws -> String {
    let text = try String(contentsOf: keyLaneLedgersRepoRoot().appendingPathComponent(relative), encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func keyLaneLedgersOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("F-ja-2′ B-1 gate r1 m-2: the key-lane ledgers are the session's (source pins)")
struct KeyLaneLedgersPinTests {
    private static let input = "App/RemoteWindowRendering/RemoteWindowInput.swift"
    private static let window = "App/RemoteWindowRendering/RemoteWindow.swift"
    private static let registry = "App/RemoteWindowRendering/RemoteWindowRegistry.swift"

    @Test("the strip drops the m-2 prose and keeps the statements in all three files")
    func theStripDropsTheProse() throws {
        for file in [Self.input, Self.window, Self.registry] {
            let code = try keyLaneLedgersCode(file)
            #expect(!code.contains("B-1 gate r1 m-2"), "a line comment survived the strip in \(file)")
            #expect(code.contains("keyLedgers"), "the strip ate the statements in \(file)")
        }
    }

    /// The view keeps no ledger of its own: the two per-view sets are gone, the only `Set<UInt16>`
    /// stored in the file are `KeyLaneLedgers`' members, every insert / remove goes through the
    /// injectable `keyLedgers`, and that property is declared once with a default of the view's own.
    /// The `Set<UInt16>` count is a tripwire (B-1 m-2 gate r1 (f-2)): it was 2, the two lane ledgers,
    /// and was refrozen to 3 by lane-focuslost-flush for the third member, `wireDown` -- the wire
    /// ledger of the non-modifier keys. It lives in `KeyLaneLedgers` because it is the same
    /// session-level instance the registry already holds and resets (one physical keyboard, one set
    /// of ledgers, emptied together at the session reset), but it is the registry's alone: no view
    /// reads or writes it (`theWireLedgerIsNeverTouchedByTheView`). A fourth set, or a per-view set
    /// coming back, trips this again.
    @Test("RemoteWindowInput.swift: the view's ledgers are the injectable KeyLaneLedgers, and the per-view sets are gone")
    func theViewUsesTheInjectableLedgers() throws {
        let code = try keyLaneLedgersCode(Self.input)
        #expect(keyLaneLedgersOccurrences(of: "private var scancodeDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "private var inputMethodDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "scancodeDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "inputMethodDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "Set<UInt16>", in: code) == 3, "only KeyLaneLedgers' three members")
        #expect(keyLaneLedgersOccurrences(of: "@MainActor final class KeyLaneLedgers {", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.scancodeDown", in: code) >= 1)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.inputMethodDown", in: code) >= 1)
        #expect(keyLaneLedgersOccurrences(of: "var keyLedgers: KeyLaneLedgers = KeyLaneLedgers()", in: code) == 1)
    }

    /// The window takes the ledgers as an initializer parameter that defaults to its own, and hands
    /// them to its content view in one assignment.
    @Test("RemoteWindow.swift: the initializer takes keyLedgers and hands them to the content view once")
    func theWindowHandsTheLedgersToItsContentView() throws {
        let code = try keyLaneLedgersCode(Self.window)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers: KeyLaneLedgers = KeyLaneLedgers()", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "contentView.keyLedgers = keyLedgers", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: ".keyLedgers =", in: code) == 1)
    }

    /// The registry creates one instance, as a constant member, and passes that member -- not a fresh
    /// instance -- at its one `RemoteWindow` creation point (gate mutant M2: a `KeyLaneLedgers()`
    /// argument there).
    @Test("RemoteWindowRegistry.swift: one instance, passed at the one RemoteWindow creation point")
    func theRegistryPassesItsOneInstance() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "private let keyLedgers = KeyLaneLedgers()", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "KeyLaneLedgers()", in: code) == 1, "no second instance anywhere in the registry")
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers: keyLedgers)", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "RemoteWindow(", in: code) == 1, "the registry has one creation point")
        #expect(keyLaneLedgersOccurrences(
            of: "RemoteWindow( key: key, contentRect: contentRect, title: state.title, firstFrameTimeout: firstFrameTimeout, keyLedgers: keyLedgers)",
            in: code
        ) == 1)
    }

    /// The text between `signature`'s opening brace and its matching closing brace in `code`, braces
    /// counted on the stripped text (the shape of `RemoteWindowLocalGeometrySyncTests.body(of:in:)`).
    private static func body(of signature: String, in code: String) -> Substring? {
        guard let open = code.range(of: signature) else { return nil }
        var depth = 1
        var index = open.upperBound
        while index < code.endIndex {
            if code[index] == "{" {
                depth += 1
            } else if code[index] == "}" {
                depth -= 1
                if depth == 0 { return code[open.upperBound..<index] }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The session reset empties the ledgers, at the one point `wireHeldModifiers` is emptied
    /// without a flush: `keyLedgers.reset()` appears once in the registry, inside `closeAllWindows()`,
    /// after that function's `wireHeldModifiers = []`, in the same body as its
    /// `commandKeyMapper.reset()`. Kills lane-session-reset M1 (the call deleted), M2 (moved before
    /// `wireHeldModifiers = []`) and M3 (moved out into `closeWindowsForSessionEnd()` -- the behaviour
    /// test below stays green for that one, since the entry routes through `closeAllWindows()`).
    /// The four session-reset callers all route through `closeAllWindows()`
    /// (`RemoteWindowRegistrySessionEndPinTests`).
    @Test("RemoteWindowRegistry.swift: closeAllWindows() resets the ledgers once, after wireHeldModifiers = []")
    func theSessionResetResetsTheLedgers() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.reset()", in: code) == 1)
        let body = try #require(Self.body(of: "private func closeAllWindows() {", in: code))
        let reset = try #require(body.range(of: "keyLedgers.reset()"), "not inside closeAllWindows()")
        let wire = try #require(body.range(of: "wireHeldModifiers = []"))
        #expect(wire.upperBound <= reset.lowerBound, "after wireHeldModifiers = []")
        #expect(body.contains("commandKeyMapper.reset()"), "the same body as commandKeyMapper.reset()")
    }

    // MARK: lane-focuslost-flush: the wire ledger

    /// `wireDown` is declared once in `KeyLaneLedgers`, emptied by `reset()` with the two lane
    /// ledgers, and named nowhere else in the file: `wireDown` appears exactly twice in its code (the
    /// declaration and the reset), so no view code reads or writes it under any spelling --
    /// `keyLedgers.wireDown` in particular appears zero times. `reset()`'s body is frozen whole (lane
    /// mutant M6: the `wireDown = []` line dropped).
    @Test("RemoteWindowInput.swift: wireDown is declared and reset in KeyLaneLedgers, and the view never touches it")
    func theWireLedgerIsNeverTouchedByTheView() throws {
        let code = try keyLaneLedgersCode(Self.input)
        #expect(keyLaneLedgersOccurrences(of: "var wireDown: Set<UInt16> = []", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown", in: code) == 0, "the view never touches the wire ledger")
        #expect(keyLaneLedgersOccurrences(of: "wireDown", in: code) == 2, "the declaration and reset() only")
        #expect(keyLaneLedgersOccurrences(of: "func reset() { scancodeDown = [] inputMethodDown = [] wireDown = [] }", in: code) == 1)
    }

    /// The wire ledger is kept at the one wire exit: `sendKeyboardLaneEvent`'s `.keyDown` case inserts
    /// the code right after `session.sendKeyDown`, its `.keyUp` case removes it right after
    /// `session.sendKeyUp` -- the two cases frozen as one stripped needle inside the function's body
    /// (lane mutant M3: the insert dropped). Each write appears once in the registry.
    @Test("RemoteWindowRegistry.swift: sendKeyboardLaneEvent keeps the wire ledger, and nothing else adds to it")
    func theWireExitKeepsTheWireLedger() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown.insert(", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown.remove(", in: code) == 1)
        let body = try #require(Self.body(of: "private func sendKeyboardLaneEvent(_ event: KeyboardLaneEvent) {", in: code))
        #expect(body.contains("keyLedgers.wireDown.insert("), "the insert is not inside sendKeyboardLaneEvent")
        #expect(body.contains("keyLedgers.wireDown.remove("), "the remove is not inside sendKeyboardLaneEvent")
        #expect(keyLaneLedgersOccurrences(
            of: "case .keyDown(let macKeyCode): session.sendKeyDown(macKeyCode) keyLedgers.wireDown.insert(macKeyCode)"
                + " case .keyUp(let macKeyCode): session.sendKeyUp(macKeyCode) keyLedgers.wireDown.remove(macKeyCode)"
                + " case .modifierKey(",
            in: String(body)
        ) == 1)
    }

    /// The `.focusLost` arm is frozen as a statement sequence -- R-4's shape, scaled down: the text from
    /// `case .focusLost:` to the next `case ` is exactly the key flush, then the modifier flush, then
    /// the mapper reset (lane mutants M1: the key flush dropped; M2: it moved after the modifiers).
    /// `releaseAllHeldKeys()` is declared once and called once (the declaration and that call are its
    /// two mentions), so `.dropBufferedInput` and every other path stay out of it. Its body empties
    /// the wire ledger -- the ledger's one assignment in the registry (M4: the flush that sends without
    /// emptying) -- reads `wireDown`, not a lane ledger (M7), and sends with `session.sendKeyUp`
    /// directly, neither through the wire exit nor through the gate.
    @Test("RemoteWindowRegistry.swift: .focusLost flushes the wire ledger, then the modifiers, then resets the mapper")
    func theFocusLossFlushesKeysThenModifiers() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "case .focusLost: releaseAllHeldKeys() releaseAllHeldModifiers() commandKeyMapper.reset()", in: code) == 1)
        let label = "case .focusLost:"
        #expect(keyLaneLedgersOccurrences(of: label, in: code) == 1, "the arm is not unique")
        let start = try #require(code.range(of: label))
        let next = try #require(code.range(of: "case ", range: start.upperBound..<code.endIndex))
        let arm = code[start.upperBound..<next.lowerBound].trimmingCharacters(in: .whitespaces)
        #expect(arm == "releaseAllHeldKeys() releaseAllHeldModifiers() commandKeyMapper.reset()", "\(arm)")

        #expect(keyLaneLedgersOccurrences(of: "private func releaseAllHeldKeys()", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "releaseAllHeldKeys()", in: code) == 2, "the declaration and the one call")
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown = []", in: code) == 1)
        let flush = try #require(Self.body(of: "private func releaseAllHeldKeys() {", in: code))
        #expect(flush.contains("keyLedgers.wireDown = []"), "the wire ledger is not emptied inside releaseAllHeldKeys()")
        #expect(flush.contains("keyLedgers.wireDown.sorted()"), "the flush does not read the wire ledger")
        #expect(flush.contains("session.sendKeyUp(macKeyCode)"), "the flush does not send straight to the session")
        #expect(!flush.contains("scancodeDown") && !flush.contains("inputMethodDown"), "the flush touches a lane ledger: \(flush)")
        #expect(!flush.contains("sendKeyboardLaneEvent") && !flush.contains("focusAuthority"), "the flush goes through the exit or the gate")
    }

    /// Every mention of the wire ledger in the registry's code, accounted for: the two writes at the
    /// wire exit, the flush's read and its one assignment, and the two emptiness predicates
    /// (`keyLedgersAreEmpty()`, `wireHeldKeysAreEmpty()`). Six, so a seventh -- another writer, a
    /// second flush -- shows up here (the session reset reaches it through `keyLedgers.reset()`, which
    /// does not name it). Spelling-level: an alias gets past it -- gate r1 G3, a one-release-clears-
    /// all alias at the capture of any keyUp, passed every pin -- which F8 below is for: releasing
    /// one of two held keys must leave the other for the flush.
    @Test("RemoteWindowRegistry.swift: the wire ledger is named in exactly the six places that keep, flush and read it")
    func theWireLedgerHasNoOtherUser() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown", in: code) == 6)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown.isEmpty", in: code) == 2)
        #expect(keyLaneLedgersOccurrences(of: "keyLedgers.wireDown.sorted()", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(
            of: "keyLedgers.scancodeDown.isEmpty && keyLedgers.inputMethodDown.isEmpty && keyLedgers.wireDown.isEmpty",
            in: code
        ) == 1, "keyLedgersAreEmpty() reads all three ledgers")
    }

    // MARK: lane-delete-key-window: the server deleting the key window flushes the wire

    /// The seam is declared once with the live AppKit read as its default (lane mutant M5: a default of
    /// `{ _ in true }`), and read once -- in the delete path's test.
    @Test("RemoteWindowRegistry.swift: the isKeyWindow seam defaults to the live read and is read once")
    func theKeyWindowSeamDefaultsToTheLiveRead() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        #expect(keyLaneLedgersOccurrences(of: "var isKeyWindow: (NSWindow) -> Bool = { $0.isKeyWindow }", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "var isKeyWindow:", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "isKeyWindow(closing.window)", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "isKeyWindow(", in: code) == 1, "the seam's one read")
    }

    /// `handleWindowDelete` synthesizes the one `.focusLost` -- through `handleInput`, the same branch
    /// (lane mutant M6: the three statements inlined; M7: the key flush alone) -- only for the key
    /// window (M2: the test dropped; M9: inverted), before the window's close (M4: moved after it),
    /// and inside that function (M1: deleted; M3: moved into `windows.didSet`). `windows`' didSet keeps
    /// its one statement (gate r1 G4: a flush there is a session-reset flush).
    @Test("RemoteWindowRegistry.swift: handleWindowDelete synthesizes .focusLost for the key window, before its close")
    func theKeyWindowDeleteSynthesizesTheFocusLoss() throws {
        let code = try keyLaneLedgersCode(Self.registry)
        let needle = "if let closing = windows[windowId], isKeyWindow(closing.window) { handleInput(windowId: windowId, event: .focusLost) }"
        #expect(keyLaneLedgersOccurrences(of: needle, in: code) == 1)
        let body = try #require(Self.body(of: "private func handleWindowDelete(windowId: UInt32) {", in: code))
        let flush = try #require(body.range(of: needle), "the synthesized focus loss is not inside handleWindowDelete")
        let close = try #require(body.range(of: "window.close(via: session)"))
        #expect(flush.upperBound <= close.lowerBound, "the flush runs before the window's close")
        #expect(!body.contains("#if"), "a conditional-compilation block inside handleWindowDelete (gate r1 Gii's decoy)")
        #expect(keyLaneLedgersOccurrences(of: "handleInput(windowId: windowId, event: .focusLost)", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "event: .focusLost", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(
            of: "private var windows: [UInt32: RemoteWindow] = [:] { didSet { dropLocalMoveStateOfRemovedWindows() } }",
            in: code
        ) == 1)
    }

    /// lane-smoke-wirekeys: Tools/window-smoke's two live batteries (cmdmap-live, ime) assert the wire
    /// key ledger at finish, each right after its modifier-ledger assertion. The behaviour runs only in
    /// the live battery (a real host); this pin guards "both places have it, each after the modifier
    /// check" (lane mutants M1 / M2: an assertion deleted; M3: the order swapped; M4: the predicate
    /// swapped for the modifier one with the message kept). The needles hold no `//`, so the strip
    /// keeps them. Gate r1 I-1: a bare predicate-name needle is spelling-level -- `|| true` (V2) and
    /// `true,` with the name left in a string (V3) kept it -- so the needle is the CALL SHAPE, the
    /// predicate as `check`'s condition followed by the battery's message; a dead-branch decoy (V1,
    /// the check wrapped in `if false { }`) keeps every needle by construction and is pinned as
    /// "neither battery body contains `if false` or `#if`" -- the pin's known ceiling.
    @Test("window-smoke: cmdmap-live and ime each assert wireHeldKeysAreEmpty() after the modifier ledger")
    func theLiveBatteriesAssertTheWireKeyLedger() throws {
        let code = try keyLaneLedgersCode("Tools/window-smoke/main.swift")
        #expect(keyLaneLedgersOccurrences(of: "registry.wireHeldKeysAreEmpty()", in: code) == 2)
        #expect(keyLaneLedgersOccurrences(of: "registry.wireHeldModifiersIsEmpty()", in: code) == 2)
        #expect(keyLaneLedgersOccurrences(
            of: "check( registry.wireHeldKeysAreEmpty(), \"cmdmap-live: the wire-side key ledger is empty at finish", in: code
        ) == 1, "cmdmap-live: the predicate is not check's condition (gate r1 V2 / V3)")
        #expect(keyLaneLedgersOccurrences(
            of: "check( registry.wireHeldKeysAreEmpty(), \"ime: the wire-side key ledger is empty at finish", in: code
        ) == 1, "ime: the predicate is not check's condition (gate r1 V2 / V3)")
        // `if cmdMapLiveActive {` also opens an earlier block (the input-test driver), so each battery
        // is located from its own message: the last occurrence of the signature before the message.
        let batteries = [
            ("if cmdMapLiveActive {", "\"cmdmap-live: the wire-side key ledger is empty at finish"),
            ("if inputTestMode == .ime {", "\"ime: the wire-side key ledger is empty at finish"),
        ]
        for (signature, message) in batteries {
            let messageRange = try #require(code.range(of: message), "\(message) not found")
            let open = try #require(
                code.range(of: signature, options: .backwards, range: code.startIndex..<messageRange.lowerBound),
                "\(signature) not found before its message"
            )
            let body = try #require(Self.body(of: signature, in: String(code[open.lowerBound...])), "\(signature) body")
            #expect(keyLaneLedgersOccurrences(of: "registry.wireHeldKeysAreEmpty()", in: String(body)) == 1, "\(signature)")
            #expect(keyLaneLedgersOccurrences(of: "registry.wireHeldModifiersIsEmpty()", in: String(body)) == 1, "\(signature)")
            let keys = try #require(body.range(of: "registry.wireHeldKeysAreEmpty()"))
            let modifiers = try #require(body.range(of: "registry.wireHeldModifiersIsEmpty()"))
            #expect(modifiers.upperBound <= keys.lowerBound, "\(signature): keys assertion before the modifier one")
            #expect(!body.contains("if false") && !body.contains("#if"), "\(signature): a dead-branch decoy (gate r1 V1)")
        }
        #expect(keyLaneLedgersOccurrences(of: "\"cmdmap-live: the wire-side key ledger is empty at finish", in: code) == 1)
        #expect(keyLaneLedgersOccurrences(of: "\"ime: the wire-side key ledger is empty at finish", in: code) == 1)
    }
}

/// lane-delete-key-window: makes window `windowId` the one `registry.isKeyWindow` answers true for
/// (an xctest host never has a real key window), by identity of its `NSWindow` -- and only while the
/// window is still in the registry's table: on a real host `isKeyWindow` is false once the window is
/// closed, and the table is the offline stand-in for that (gate r1 I-2: a flush moved after the
/// close, or a `#if false` decoy carrying the pinned needle, must fail D1-D9, not only the pins).
@MainActor
private func keyLaneMakeKey(_ windowId: UInt32, in registry: RemoteWindowRegistry) throws {
    let window = try #require(registry.window(forWindowId: windowId), "setup: window \(windowId) is in the table")
    registry.isKeyWindow = { [weak window, weak registry] in
        $0 === window && registry?.window(forWindowId: windowId) != nil
    }
}

// MARK: - Behaviour: which instance the views end up with

/// A `WindowCreate` order with fields this file chooses -- the test-local construct
/// `RemoteWindowRegistrySessionEndTests` / `ReconnectTopologyOrderTests` each keep their own copy of
/// (`CRDPEvent` vends no initializer that takes its fields; "复制一份" is the precedent).
private final class KeyLaneWindowCreateStub: CRDPEvent {
    private let id: UInt32

    init(windowId: UInt32) {
        id = windowId
        super.init()
    }

    override var kind: CRDPEventKind { .windowCreate }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { id }
    // WINDOW_ORDER_FIELD_OFFSET | _SIZE | _SHOW | _TITLE | _STYLE
    override var fieldFlags: UInt32 { 0x0000_0800 | 0x0000_0400 | 0x0000_0010 | 0x0000_0004 | 0x0000_0008 }
    override var style: UInt32 { 0x000F_0000 }
    override var styleEx: UInt32 { 0 }
    override var ownerWindowId: UInt32 { 0 }
    override var title: String { "key-lane-ledgers-probe" }
    override var offsetX: Int32 { 300 }
    override var offsetY: Int32 { 200 }
    override var windowWidth: UInt32 { 522 }
    override var windowHeight: UInt32 { 514 }
    override var show: UInt32 { 5 } // WINDOW_SHOW
}

/// An UNSTARTED `CRSession` (nothing here calls `-start`, nothing contacts any host, the strings are
/// empty) with a registry over a fixture 1920x1080 1x primary, injected through the provider
/// parameter so nothing reads `NSScreen`.
@MainActor
private func makeKeyLaneRegistry() throws -> RemoteWindowRegistry {
    try makeKeyLaneRegistry(session: CRSession(host: "", user: "", passwordBytes: Data(), program: ""))
}

/// `makeKeyLaneRegistry()` over a session the caller made -- a `KeyLaneSpySession`, to see what the
/// registry's keyboard lane sends.
@MainActor
private func makeKeyLaneRegistry(session: CRSession) throws -> RemoteWindowRegistry {
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    let topology = try #require(DisplayTopology(displays: [display]))
    return RemoteWindowRegistry(session: session, topologyProvider: StaticDisplayTopologyProvider(topology))
}

/// One keyboard call the registry made on its session, as `KeyLaneSpySession` records it.
private enum KeyLaneWireCall: Equatable {
    case keyDown(UInt16)
    case keyUp(UInt16)
    case modifier(CRModifierKey, down: Bool)
}

/// lane-focuslost-flush: an UNSTARTED `CRSession` (as above: no `-start`, no host, empty strings) that
/// records, in order, the three keyboard sends the registry's keyboard lane makes -- `-sendKeyDown:`,
/// `-sendKeyUp:` and `-sendModifierKey:down:` -- and forwards none of them (the real ones are no-ops on
/// an unstarted session anyway: no outbound queue). The `ReconnectDriverTests.FakeSession` shape.
private final class KeyLaneSpySession: CRSession {
    private(set) var calls: [KeyLaneWireCall] = []

    override func sendKeyDown(_ macKeyCode: UInt16) {
        calls.append(.keyDown(macKeyCode))
    }

    override func sendKeyUp(_ macKeyCode: UInt16) {
        calls.append(.keyUp(macKeyCode))
    }

    override func send(_ key: CRModifierKey, down: Bool) {
        calls.append(.modifier(key, down: down))
    }

    func clear() {
        calls.removeAll()
    }
}

/// A MonitoredDesktop order naming `activeWindowId` as the server's active window, carrying no Z-order
/// array (no `WINDOW_ORDER_FIELD_DESKTOP_ZORDER`, 0x10, so `applyZOrder` stays out of it; the
/// ACTIVEWND bit, 0x20, is what the server sets with an active window id, and the registry reads
/// neither for focus). `RemoteWindowRegistryLeftBorderTests.MonitoredDesktopStub`'s shape, copied.
private final class KeyLaneMonitoredDesktopStub: CRDPEvent {
    private let active: UInt32

    init(activeWindowId: UInt32) {
        active = activeWindowId
        super.init()
    }

    override var kind: CRDPEventKind { .monitoredDesktop }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { active }
    override var fieldFlags: UInt32 { 0x0000_0020 }
    override var windowIds: [NSNumber] { [] }
    override var numWindowIds: UInt32 { 0 }
    override var windowIdsTruncated: Bool { false }
}

/// A key event for the content view: `type` `.keyDown` / `.keyUp` / `.flagsChanged`.
private func keyLaneKey(
    _ type: NSEvent.EventType, keyCode: UInt16, _ charactersIgnoringModifiers: String,
    characters: String? = nil, _ flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters ?? charactersIgnoringModifiers,
        charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCode
    ))
}

/// Delivers `event` to `view` the way AppKit does (`keyDown(with:)` / `keyUp(with:)` /
/// `flagsChanged(with:)`, by its type) with F-a1-5's input-source seam fixed to ASCII-capable, so a
/// plain key takes the scancode lane whatever source the test runner has active
/// (`RemoteWindowInputTests.withInputSource`'s shape; the live read goes back in a `defer`).
@MainActor
private func keyLaneDeliver(_ event: NSEvent, to view: RemoteWindowContentView) {
    let live = RemoteWindowContentView.inputSourceIsASCIICapable
    RemoteWindowContentView.inputSourceIsASCIICapable = { true }
    defer { RemoteWindowContentView.inputSourceIsASCIICapable = live }
    switch event.type {
    case .keyUp: view.keyUp(with: event)
    case .flagsChanged: view.flagsChanged(with: event)
    default: view.keyDown(with: event)
    }
}

/// Window `windowId`, created through `registry` from a `WindowCreate` order, and its content view.
@MainActor
private func makeKeyLaneWindow(_ windowId: UInt32, in registry: RemoteWindowRegistry) throws -> RemoteWindowContentView {
    autoreleasepool {
        registry.handle(KeyLaneWindowCreateStub(windowId: windowId))
    }
    let view = try #require(registry.window(forWindowId: windowId)?.contentView as? RemoteWindowContentView)
    try #require(view.onEvent != nil, "setup: the registry is wired to the view")
    return view
}

/// Opens the keyboard-lane gate for window `windowId` the way the server does: a MonitoredDesktop
/// naming it active. The registry's FocusAuthority starts `.unmonitored` (`FocusAuthority.state`),
/// where `enqueueKeyboardEvent` drops every keyboard event; with no local activation in flight,
/// `serverDesktopUpdate` follows a `.window(id)` truth at once -- `.converged(windowId:)`, plus a
/// `.makeKey` that only marks the window's pending activation, since its first frame never arrives
/// here -- and `.converged` is the one state whose `enqueueKeyboardEvent` passes an event straight
/// through to the wire exit. Ends by proving it, or every assertion after it would be a false green:
/// a probe key (F, key code 3) pressed and released through the view must reach the spy as
/// `.keyDown(3)` then `.keyUp(3)`. The spy's record is then cleared, so a test starts from an empty
/// wire record (the probe leaves every ledger as it found it).
@MainActor
private func openKeyLaneGate(
    _ windowId: UInt32, of view: RemoteWindowContentView, in registry: RemoteWindowRegistry, spy: KeyLaneSpySession
) throws {
    autoreleasepool {
        registry.handle(KeyLaneMonitoredDesktopStub(activeWindowId: windowId))
    }
    keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 3, "f"), to: view)
    try #require(spy.calls == [.keyDown(3)], "setup: the gate did not pass the probe keyDown to the wire: \(spy.calls)")
    keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 3, "f"), to: view)
    try #require(spy.calls == [.keyDown(3), .keyUp(3)], "setup: the probe keyUp did not reach the wire: \(spy.calls)")
    spy.clear()
}

/// A fresh spy, a registry over it, window `windowId` and its content view.
@MainActor
private func makeKeyLaneSpyRegistry(
    window windowId: UInt32
) throws -> (spy: KeyLaneSpySession, registry: RemoteWindowRegistry, view: RemoteWindowContentView) {
    let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
    let registry = try makeKeyLaneRegistry(session: spy)
    let view = try makeKeyLaneWindow(windowId, in: registry)
    return (spy, registry, view)
}

@MainActor
@Suite("F-ja-2′ B-1 gate r1 m-2: the key-lane ledgers are the session's (behaviour)")
struct KeyLaneLedgersInjectionTests {
    private static func probeWindow(_ id: UInt32, keyLedgers: KeyLaneLedgers? = nil) -> RemoteWindow {
        let key = RemoteWindowKey(windowId: id, generation: 0)
        let rect = NSRect(x: 0, y: 0, width: 120, height: 80)
        guard let keyLedgers else {
            return RemoteWindow(key: key, contentRect: rect, title: "ledger-probe", firstFrameTimeout: 3600)
        }
        return RemoteWindow(key: key, contentRect: rect, title: "ledger-probe", firstFrameTimeout: 3600, keyLedgers: keyLedgers)
    }

    /// `RemoteWindow` gives its content view the instance it is handed, and a window built without
    /// one gets a ledger of its own (the single-view semantics every other caller keeps).
    @Test("RemoteWindow hands the ledgers it is given to its content view, and makes its own by default")
    func aWindowHandsItsLedgersToItsContentView() throws {
        let shared = KeyLaneLedgers()
        let first = try #require(Self.probeWindow(21, keyLedgers: shared).window.contentView as? RemoteWindowContentView)
        let second = try #require(Self.probeWindow(22, keyLedgers: shared).window.contentView as? RemoteWindowContentView)
        let own = try #require(Self.probeWindow(23).window.contentView as? RemoteWindowContentView)
        let otherOwn = try #require(Self.probeWindow(24).window.contentView as? RemoteWindowContentView)
        #expect(first.keyLedgers === shared)
        #expect(second.keyLedgers === shared)
        #expect(own.keyLedgers !== shared)
        #expect(own.keyLedgers !== otherOwn.keyLedgers)
    }

    /// The registry's windows share ONE instance, and it is the registry's own: a key code recorded
    /// through one window's view makes the registry's emptiness predicate false (gate mutant M2: a
    /// fresh `KeyLaneLedgers()` at the creation point leaves the registry's own instance untouched
    /// and gives each window a different one).
    @Test("the registry hands its one instance to every window it creates")
    func theRegistryHandsItsInstanceToEveryWindow() throws {
        let registry = try makeKeyLaneRegistry()
        autoreleasepool {
            registry.handle(KeyLaneWindowCreateStub(windowId: 601))
            registry.handle(KeyLaneWindowCreateStub(windowId: 602))
        }
        let first = try #require(registry.window(forWindowId: 601)?.contentView as? RemoteWindowContentView)
        let second = try #require(registry.window(forWindowId: 602)?.contentView as? RemoteWindowContentView)
        #expect(first.keyLedgers === second.keyLedgers, "two windows of one registry share one instance")
        #expect(registry.keyLedgersAreEmpty())

        first.keyLedgers.scancodeDown.insert(15)
        #expect(!registry.keyLedgersAreEmpty(), "a scancode entry recorded through window 601 is in the registry's instance")
        first.keyLedgers.scancodeDown.remove(15)
        #expect(registry.keyLedgersAreEmpty())
        second.keyLedgers.inputMethodDown.insert(36)
        #expect(!registry.keyLedgersAreEmpty(), "an input-method entry recorded through window 602 is in the registry's instance")
        second.keyLedgers.inputMethodDown.remove(36)
        #expect(registry.keyLedgersAreEmpty())

        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// The session reset empties the registry's instance: entries recorded through a window it
    /// created are gone once `closeWindowsForSessionEnd()` -- one of the four routes into
    /// `closeAllWindows()` -- has run (lane-session-reset M1: the reset call deleted; also the only
    /// test that catches the gate's G3 -- a `#if false` decoy carrying the call while the real
    /// function dropped it -- which every source pin above passes).
    @Test("the session reset empties the registry's ledgers")
    func theSessionResetEmptiesTheRegistrysLedgers() throws {
        let registry = try makeKeyLaneRegistry()
        autoreleasepool {
            registry.handle(KeyLaneWindowCreateStub(windowId: 611))
        }
        let view = try #require(registry.window(forWindowId: 611)?.contentView as? RemoteWindowContentView)
        view.keyLedgers.scancodeDown.insert(15)
        view.keyLedgers.inputMethodDown.insert(36)
        try #require(!registry.keyLedgersAreEmpty(), "setup: the entries are in the registry's instance")

        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
        #expect(registry.keyLedgersAreEmpty())
        #expect(view.keyLedgers.scancodeDown.isEmpty && view.keyLedgers.inputMethodDown.isEmpty)
    }

    /// Only the session reset empties the ledgers (gate r1 I-1). The window table emptying
    /// mid-session is not a session reset: the last window is deleted while a key is still down, and
    /// a new window may appear before the release -- a clear here (the F-a1-6 `windows.didSet`
    /// precedent, the shape B-1 gate r1 (f-1) named; gate variant G4) would drop that release under a
    /// CJK source and leave the key held on the server. Entries recorded through the deleted window
    /// survive its delete. The wire ledgers are another matter: when the deleted window is the key
    /// window, `handleWindowDelete` synthesizes a `.focusLost` that flushes them (lane-delete-key-window,
    /// D1-D9), and the lane ledgers are left alone on that path too (D1).
    @Test("deleting the last window mid-session leaves the ledgers alone")
    func theLastWindowDeleteKeepsTheLedgers() throws {
        let registry = try makeKeyLaneRegistry()
        autoreleasepool {
            registry.handle(KeyLaneWindowCreateStub(windowId: 631))
        }
        let view = try #require(registry.window(forWindowId: 631)?.contentView as? RemoteWindowContentView)
        view.keyLedgers.scancodeDown.insert(15)
        view.keyLedgers.inputMethodDown.insert(36)
        autoreleasepool {
            registry.handle(KeyLaneWindowDeleteStub(windowId: 631))
        }
        try #require(registry.window(forWindowId: 631) == nil, "setup: the window table emptied mid-session")
        #expect(view.keyLedgers.scancodeDown == [15] && view.keyLedgers.inputMethodDown == [36])
        #expect(!registry.keyLedgersAreEmpty())
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// Only the session reset empties the lane ledgers (gate r1 I-1): a `.focusLost` reaching the
    /// registry leaves them as they are -- a clear there (gate variant G6; lane-focuslost-flush mutant
    /// M5, the flush clearing `scancodeDown` too) would bring I-1 back for a key released after a
    /// focus round trip. What it does flush, since lane-focuslost-flush, is the wire ledger: the key
    /// put in `wireDown` here gets its release on the spy, and the ledger is empty afterwards.
    /// `theLedgerSurvivesLosingFirstResponder` covers the view on its own; this one goes through the
    /// registry's `.focusLost` branch. No gate is opened: the flush does not go through it.
    @Test("a focus loss reaching the registry keeps the lane ledgers and flushes the wire ledger")
    func aFocusLossReachingTheRegistryKeepsTheLaneLedgersAndFlushesTheWireLedger() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 641)
        view.keyLedgers.scancodeDown.insert(15)
        view.keyLedgers.inputMethodDown.insert(36)
        view.keyLedgers.wireDown.insert(49)
        try #require(!registry.wireHeldKeysAreEmpty(), "setup: the wire entry is in the registry's instance")
        view.onEvent?(.focusLost)
        #expect(view.keyLedgers.scancodeDown == [15] && view.keyLedgers.inputMethodDown == [36])
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(spy.calls == [.keyUp(49)], "\(spy.calls)")
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    // MARK: lane-focuslost-flush: the wire ledger, through the registry's keyboard lane

    /// F1. The wire ledger follows the wire exit: with the gate open, R pressed through the view
    /// reaches the spy as `.keyDown(15)` and puts 15 on the wire ledger; its release reaches the spy
    /// as `.keyUp(15)` and takes it off (lane mutant M3: the exit's insert dropped).
    @Test("F1: the wire ledger follows what the keyboard lane sends")
    func theWireLedgerFollowsTheWireExit() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 651)
        try openKeyLaneGate(651, of: view, in: registry, spy: spy)
        try #require(registry.wireHeldKeysAreEmpty())

        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        #expect(spy.calls == [.keyDown(15)], "\(spy.calls)")
        #expect(!registry.wireHeldKeysAreEmpty(), "R is held on the wire")

        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: view)
        #expect(spy.calls == [.keyDown(15), .keyUp(15)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(registry.keyLedgersAreEmpty())
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F2. A keyDown the gate dropped is captured but not on the wire: before any MonitoredDesktop the
    /// registry's FocusAuthority is `.unmonitored`, which drops every keyboard event. R pressed
    /// through the view is in the lane ledger (`scancodeDown`, recorded at capture) and not on the
    /// spy, and the wire ledger stays empty -- the two kinds of ledger, apart. A focus loss then sends
    /// nothing: no release for a press the server never saw (lane mutant M7: the flush reading
    /// `scancodeDown` instead of `wireDown` sends `.keyUp(15)` here).
    @Test("F2: a keyDown the gate dropped is in the lane ledger, not on the wire ledger, and a focus loss does not release it")
    func aKeyDownTheGateDroppedIsNotOnTheWireLedger() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 661)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        #expect(spy.calls.isEmpty, "the gate is closed: \(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(view.keyLedgers.scancodeDown == [15], "captured: \(view.keyLedgers.scancodeDown)")

        view.onEvent?(.focusLost)
        #expect(spy.calls.isEmpty, "a focus loss released a key that never reached the wire: \(spy.calls)")
        #expect(view.keyLedgers.scancodeDown == [15])
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F3. A focus loss releases the keys on the wire, and only those: A pressed before the gate opens
    /// (captured, dropped, never on the wire), then R and Space pressed with the gate open and held.
    /// `.focusLost` adds exactly `.keyUp(15)`, `.keyUp(49)` -- in key-code order, and nothing for A
    /// (lane mutant M7) -- and empties the wire ledger; the lane ledger keeps all three entries, so a
    /// release that still arrives takes the lane its press took (M5: the flush clearing it). A second
    /// `.focusLost` sends nothing (M4: the flush that sends without emptying the ledger). R's physical
    /// release arriving afterwards is forwarded once more by its lane record -- a second release of a
    /// key the server already let go, a no-op there -- and leaves the wire ledger empty.
    @Test("F3: a focus loss releases every key held on the wire, once, and leaves the lane ledgers alone")
    func aFocusLossReleasesTheKeysOnTheWire() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 671)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 0, "a"), to: view)
        try #require(spy.calls.isEmpty && view.keyLedgers.scancodeDown == [0], "setup: A captured, not sent")
        try openKeyLaneGate(671, of: view, in: registry, spy: spy)

        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 49, " "), to: view)
        try #require(spy.calls == [.keyDown(15), .keyDown(49)], "setup: \(spy.calls)")

        view.onEvent?(.focusLost)
        #expect(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15), .keyUp(49)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(view.keyLedgers.scancodeDown == [0, 15, 49], "the lane ledger is not the flush's: \(view.keyLedgers.scancodeDown)")

        view.onEvent?(.focusLost)
        #expect(spy.calls.count == 4, "a second focus loss sent again: \(spy.calls)")

        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: view)
        #expect(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15), .keyUp(49), .keyUp(15)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F4. Keys before modifiers: Shift held on the wire (a `.flagsChanged` through the gate) and R
    /// pressed with it; `.focusLost` releases R, then Shift -- the order a chord is let go in (lane
    /// mutant M2: the key flush moved after the modifier flush).
    @Test("F4: a focus loss releases the key before its modifier")
    func aFocusLossReleasesTheKeyBeforeItsModifier() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 681)
        try openKeyLaneGate(681, of: view, in: registry, spy: spy)

        keyLaneDeliver(try keyLaneKey(.flagsChanged, keyCode: 56, "", .shift), to: view)
        try #require(spy.calls == [.modifier(.shift, down: true)], "setup: \(spy.calls)")
        try #require(!registry.wireHeldModifiersIsEmpty())
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r", characters: "R", .shift), to: view)
        try #require(spy.calls == [.modifier(.shift, down: true), .keyDown(15)], "setup: \(spy.calls)")

        view.onEvent?(.focusLost)
        #expect(Array(spy.calls.dropFirst(2)) == [.keyUp(15), .modifier(.shift, down: false)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(registry.wireHeldModifiersIsEmpty())
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F5. The session reset empties the wire ledger and sends nothing: R held on the wire, then
    /// `closeWindowsForSessionEnd()` -- the wire ledger is empty and the spy has no release (the
    /// connection is gone; adr/0011 §3's "no flush" for `wireHeldModifiers`). Lane mutant M6:
    /// `reset()` leaving `wireDown` alone.
    @Test("F5: the session reset empties the wire ledger without a flush")
    func theSessionResetEmptiesTheWireLedgerWithoutAFlush() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 691)
        try openKeyLaneGate(691, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        try #require(spy.calls == [.keyDown(15)] && !registry.wireHeldKeysAreEmpty(), "setup: \(spy.calls)")

        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(registry.keyLedgersAreEmpty())
        #expect(spy.calls == [.keyDown(15)], "the session reset sent a release: \(spy.calls)")
    }

    /// F6. Nothing held, nothing sent: a focus loss on a window whose session holds no key and no
    /// modifier puts nothing on the spy.
    @Test("F6: a focus loss with nothing held sends nothing")
    func aFocusLossWithNothingHeldSendsNothing() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 701)
        try openKeyLaneGate(701, of: view, in: registry, spy: spy)
        view.onEvent?(.focusLost)
        #expect(spy.calls.isEmpty, "\(spy.calls)")
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F7. The emptiness predicate reads the wire ledger too: a keyDown handed to the registry directly
    /// (`onEvent`, past the view's capture, so no lane ledger records it) leaves only the wire ledger
    /// non-empty, and `keyLedgersAreEmpty()` says so (lane mutant M8: the predicate skipping `wireDown`).
    @Test("F7: keyLedgersAreEmpty() sees a key that only the wire ledger holds")
    func theEmptinessPredicateSeesTheWireLedger() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 711)
        try openKeyLaneGate(711, of: view, in: registry, spy: spy)
        view.onEvent?(.keyDown(macKeyCode: 15, characters: "r", charactersIgnoringModifiers: "r"))
        try #require(spy.calls == [.keyDown(15)], "setup: \(spy.calls)")
        try #require(view.keyLedgers.scancodeDown.isEmpty && view.keyLedgers.inputMethodDown.isEmpty, "setup: no lane record")
        #expect(!registry.wireHeldKeysAreEmpty())
        #expect(!registry.keyLedgersAreEmpty(), "only the wire ledger holds R")

        view.onEvent?(.keyUp(macKeyCode: 15, characters: "r", charactersIgnoringModifiers: "r"))
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(registry.keyLedgersAreEmpty())
        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }
    }

    /// F8 (gate r1 I-1). Releasing one of two held keys leaves the other on the wire ledger, and a
    /// focus loss releases it -- a release takes its own code off, not every code. The gate's G2
    /// (`removeAll()` at the wire exit) and G3 (the same clear-all through an alias at the capture
    /// of any keyUp, outside every pinned text) both passed F1-F7: R and Space held, R released,
    /// Space forgotten, a focus loss then left Space held on the server.
    @Test("F8: releasing one of two held keys leaves the other on the wire ledger for the flush")
    func releasingOneKeyKeepsTheOther() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 721)
        try openKeyLaneGate(721, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 49, " "), to: view)
        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: view)
        try #require(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15)], "setup: \(spy.calls)")
        #expect(!registry.wireHeldKeysAreEmpty(), "Space is still held on the wire")
        view.onEvent?(.focusLost)
        #expect(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15), .keyUp(49)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// F9 (gate r1 m-1, the gate's probe PS). The epoch-supersede half of writer U-1, sleep-free: R
    /// goes out while the server's focus is on a window this registry does not render; a click on A
    /// starts an epoch toward A (no AppKit key change, no `.focusLost`); R's release is buffered; a
    /// click on B supersedes the epoch -- the drop releases the modifiers, then `.resignKey(A)`
    /// posts didResignKey on A synchronously and re-enters `.focusLost`, which releases R. So the
    /// rollback / supersede site needs no flush of its own; what it leaves is the deleted-target
    /// shape (gate r1 PU1b), registered.
    @Test("F9: an epoch supersede releases a key held on the wire through .resignKey of the old target")
    func anEpochSupersedeReleasesThroughResignKey() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let a = try makeKeyLaneWindow(731, in: registry)
        let b = try makeKeyLaneWindow(732, in: registry)
        try openKeyLaneGate(731, of: a, in: registry, spy: spy)
        autoreleasepool { registry.handle(KeyLaneMonitoredDesktopStub(activeWindowId: 9999)) }
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: a)
        try #require(spy.calls == [.keyDown(15)], "R out: \(spy.calls)")
        a.onEvent?(.mouseButton(.left, down: true, screenPoint: NSPoint(x: 400, y: 400)))
        a.onEvent?(.mouseButton(.left, down: false, screenPoint: NSPoint(x: 400, y: 400)))
        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: a)
        try #require(spy.calls == [.keyDown(15)], "release buffered: \(spy.calls)")
        b.onEvent?(.mouseButton(.left, down: true, screenPoint: NSPoint(x: 410, y: 410)))
        #expect(spy.calls == [.keyDown(15), .keyUp(15)], "after the supersede: \(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    // MARK: lane-delete-key-window: the server deletes the key window

    /// D1. The server deleting the key window flushes the wire as a focus loss does: Shift and R held
    /// on the wire, the window made key, a WindowDelete for it -- the spy gets R's release, then
    /// Shift's, both wire ledgers are empty, the lane ledger keeps R (lane mutants M1, M7, M8, M9).
    @Test("D1: deleting the key window flushes the keys, then the modifiers, and keeps the lane ledgers")
    func deletingTheKeyWindowFlushesTheWire() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 801)
        try openKeyLaneGate(801, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.flagsChanged, keyCode: 56, "", .shift), to: view)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r", characters: "R", .shift), to: view)
        try #require(spy.calls == [.modifier(.shift, down: true), .keyDown(15)], "setup: \(spy.calls)")
        try keyLaneMakeKey(801, in: registry)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 801)) }
        #expect(Array(spy.calls.dropFirst(2)) == [.keyUp(15), .modifier(.shift, down: false)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        #expect(registry.wireHeldModifiersIsEmpty())
        #expect(view.keyLedgers.scancodeDown == [15], "the lane ledger is not the flush's: \(view.keyLedgers.scancodeDown)")
        #expect(registry.window(forWindowId: 801) == nil)
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D2. Deleting a window that is not key flushes nothing: R held through A, A key, B deleted -- the
    /// spy is unchanged and R is still on the wire; then A itself is deleted and R is released. The
    /// test is "is the deleted window the key one", not "is there a key window" (lane mutant M2).
    @Test("D2: deleting a window that is not key leaves the wire alone")
    func deletingANonKeyWindowFlushesNothing() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let a = try makeKeyLaneWindow(811, in: registry)
        _ = try makeKeyLaneWindow(812, in: registry)
        try openKeyLaneGate(811, of: a, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: a)
        try #require(spy.calls == [.keyDown(15)], "setup: \(spy.calls)")
        try keyLaneMakeKey(811, in: registry)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 812)) }
        #expect(spy.calls == [.keyDown(15)], "a non-key window's delete flushed: \(spy.calls)")
        #expect(!registry.wireHeldKeysAreEmpty())
        #expect(registry.window(forWindowId: 811) != nil)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 811)) }
        #expect(spy.calls == [.keyDown(15), .keyUp(15)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D3. Two keys held, one released, then the key window deleted: only the other one is released.
    @Test("D3: deleting the key window after releasing one of two held keys releases the other only")
    func deletingTheKeyWindowReleasesTheStillHeldKey() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 821)
        try openKeyLaneGate(821, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 49, " "), to: view)
        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: view)
        try #require(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15)], "setup: \(spy.calls)")
        try keyLaneMakeKey(821, in: registry)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 821)) }
        #expect(spy.calls == [.keyDown(15), .keyDown(49), .keyUp(15), .keyUp(49)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D4. Nothing held, nothing sent; and a flush already done is not repeated: C's delete flushes R
    /// once, a second key window D deleted afterwards sends nothing more.
    @Test("D4: deleting the key window with nothing held sends nothing, and a second delete does not flush again")
    func deletingTheKeyWindowWithNothingHeldSendsNothing() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let a = try makeKeyLaneWindow(831, in: registry)
        try openKeyLaneGate(831, of: a, in: registry, spy: spy)
        try keyLaneMakeKey(831, in: registry)
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 831)) }
        #expect(spy.calls.isEmpty, "\(spy.calls)")

        let c = try makeKeyLaneWindow(832, in: registry)
        try openKeyLaneGate(832, of: c, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: c)
        try keyLaneMakeKey(832, in: registry)
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 832)) }
        try #require(spy.calls == [.keyDown(15), .keyUp(15)], "setup: \(spy.calls)")

        _ = try makeKeyLaneWindow(833, in: registry)
        try keyLaneMakeKey(833, in: registry)
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 833)) }
        #expect(spy.calls == [.keyDown(15), .keyUp(15)], "a second delete flushed again: \(spy.calls)")
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D5. A key captured but never sent (the gate is closed) gets no release when the key window is
    /// deleted: it is in the lane ledger, not on the wire ledger.
    @Test("D5: deleting the key window does not release a key that never reached the wire")
    func deletingTheKeyWindowSkipsAKeyNeverSent() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 841)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        try #require(view.keyLedgers.scancodeDown.contains(15) && registry.wireHeldKeysAreEmpty(), "setup")
        try keyLaneMakeKey(841, in: registry)
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 841)) }
        #expect(!spy.calls.contains(.keyUp(15)), "\(spy.calls)")
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D6. The session reset after a key-window delete still sends nothing (F5 on this path).
    @Test("D6: the session reset after a key-window delete sends nothing")
    func theSessionResetAfterAKeyWindowDeleteSendsNothing() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let a = try makeKeyLaneWindow(851, in: registry)
        let b = try makeKeyLaneWindow(852, in: registry)
        try openKeyLaneGate(851, of: a, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: a)
        try keyLaneMakeKey(851, in: registry)
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 851)) }
        try #require(spy.calls == [.keyDown(15), .keyUp(15)], "setup: \(spy.calls)")
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 49, " "), to: b)
        let before = spy.calls
        try keyLaneMakeKey(852, in: registry)
        autoreleasepool { registry.closeWindowsForSessionEnd() }
        #expect(spy.calls == before, "the session reset sent something: \(spy.calls)")
        #expect(registry.keyLedgersAreEmpty())
    }

    /// D7. Without an injected seam the live read answers false in an xctest host, so a delete flushes
    /// nothing -- the runtime twin of the seam's default (lane mutant M5: a default of `{ _ in true }`).
    @Test("D7: with the seam left alone, deleting a window flushes nothing")
    func theDefaultSeamFlushesNothing() throws {
        let (spy, registry, view) = try makeKeyLaneSpyRegistry(window: 861)
        try openKeyLaneGate(861, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: view)
        try #require(spy.calls == [.keyDown(15)], "setup: \(spy.calls)")
        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 861)) }
        #expect(spy.calls == [.keyDown(15)], "\(spy.calls)")
        #expect(!registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D8 (gate r1 PU1b, F9's sequence). R goes out while the server's focus is elsewhere, a click on
    /// A starts an epoch toward A (on a real host its `.makeKey(A)` is what keeps the target the local
    /// key window; here the first frame never came, so A is key through the seam), R's release is
    /// buffered -- and the server deletes A, still the local key window. The synthesized focus loss
    /// releases R.
    @Test("D8: the server deleting the epoch's target, still the key window, releases a key held on the wire")
    func deletingTheEpochTargetReleasesTheHeldKey() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let a = try makeKeyLaneWindow(871, in: registry)
        try openKeyLaneGate(871, of: a, in: registry, spy: spy)
        autoreleasepool { registry.handle(KeyLaneMonitoredDesktopStub(activeWindowId: 9999)) }
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 15, "r"), to: a)
        try #require(spy.calls == [.keyDown(15)], "R out: \(spy.calls)")
        a.onEvent?(.mouseButton(.left, down: true, screenPoint: NSPoint(x: 400, y: 400)))
        a.onEvent?(.mouseButton(.left, down: false, screenPoint: NSPoint(x: 400, y: 400)))
        keyLaneDeliver(try keyLaneKey(.keyUp, keyCode: 15, "r"), to: a)
        try #require(spy.calls == [.keyDown(15)], "release buffered: \(spy.calls)")
        try keyLaneMakeKey(871, in: registry)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 871)) }
        #expect(spy.calls == [.keyDown(15), .keyUp(15)], "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty())
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }

    /// D9. The Cmd mapper is reset with the flush: Cmd held (withheld) and C pressed through A go out
    /// as the mapped chord; deleting A, the key window, releases them; Cmd's physical release, arriving
    /// at B (the window still in the table), finds an idle mapper and sends nothing (lane mutant M7':
    /// the flush without `commandKeyMapper.reset()`).
    @Test("D9: deleting the key window resets the Cmd mapper too")
    func deletingTheKeyWindowResetsTheMapper() throws {
        let spy = KeyLaneSpySession(host: "", user: "", passwordBytes: Data(), program: "")
        let registry = try makeKeyLaneRegistry(session: spy)
        let view = try makeKeyLaneWindow(881, in: registry)
        let other = try makeKeyLaneWindow(882, in: registry)
        try openKeyLaneGate(881, of: view, in: registry, spy: spy)
        keyLaneDeliver(try keyLaneKey(.flagsChanged, keyCode: 55, "", .command), to: view)
        keyLaneDeliver(try keyLaneKey(.keyDown, keyCode: 8, "c", .command), to: view)
        try #require(spy.calls.contains(.keyDown(8)) && !registry.wireHeldModifiersIsEmpty(), "setup: \(spy.calls)")
        let pressed = spy.calls.count
        try keyLaneMakeKey(881, in: registry)

        autoreleasepool { registry.handle(KeyLaneWindowDeleteStub(windowId: 881)) }
        let flushed = Array(spy.calls.dropFirst(pressed))
        let heldModifiers = spy.calls.prefix(pressed).compactMap { call -> CRModifierKey? in
            if case .modifier(let key, down: true) = call { return key } else { return nil }
        }
        #expect(flushed == [.keyUp(8)] + heldModifiers.map { .modifier($0, down: false) }, "\(spy.calls)")
        #expect(registry.wireHeldKeysAreEmpty() && registry.wireHeldModifiersIsEmpty())

        let afterFlush = spy.calls
        keyLaneDeliver(try keyLaneKey(.flagsChanged, keyCode: 55, ""), to: other)
        #expect(spy.calls == afterFlush, "Cmd's release after the flush sent: \(spy.calls)")
        autoreleasepool { registry.closeWindowsForSessionEnd() }
    }
}

/// A `.windowDelete` order for one window id, generation 0 -- the registry's delete path with no
/// server (the same "复制一份" shape as `KeyLaneWindowCreateStub` above).
private final class KeyLaneWindowDeleteStub: CRDPEvent {
    private let id: UInt32

    init(windowId: UInt32) {
        id = windowId
        super.init()
    }

    override var kind: CRDPEventKind { .windowDelete }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { id }
}
