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
    /// stored in the file are `KeyLaneLedgers`' two members, every insert / remove goes through the
    /// injectable `keyLedgers`, and that property is declared once with a default of the view's own.
    @Test("RemoteWindowInput.swift: the view's ledgers are the injectable KeyLaneLedgers, and the per-view sets are gone")
    func theViewUsesTheInjectableLedgers() throws {
        let code = try keyLaneLedgersCode(Self.input)
        #expect(keyLaneLedgersOccurrences(of: "private var scancodeDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "private var inputMethodDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "scancodeDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "inputMethodDownKeyCodes", in: code) == 0)
        #expect(keyLaneLedgersOccurrences(of: "Set<UInt16>", in: code) == 2, "only KeyLaneLedgers' two members")
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
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    let topology = try #require(DisplayTopology(displays: [display]))
    let session = CRSession(host: "", user: "", passwordBytes: Data(), program: "")
    return RemoteWindowRegistry(session: session, topologyProvider: StaticDisplayTopologyProvider(topology))
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
}
