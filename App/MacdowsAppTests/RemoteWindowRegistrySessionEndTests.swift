import AppKit
import MacdowsCore
import Testing

// adr/0020 §2 lane R — the registry's own session-end window-close entry (D-1 = A).
//
// THE SHAPE. `RemoteWindowRegistry` already has exactly one place that closes every RAIL window
// and resets this registry's own per-connection state: the private `closeAllWindows()`. Today it
// has three callers, all reconnect-shaped (a generation rollover, `.disconnected`, and the
// explicit `prepareForReconnect()` driver). This lane adds a FOURTH caller for a session that is
// simply ENDING, with no next connection to prepare for: `closeWindowsForSessionEnd()`, an
// `internal` method whose body is exactly the one call `closeAllWindows()` -- the shape R-2
// below pins, not a new one this lane invents. Lane S (adr/0020 §2 lane S) wires the actual
// call site inside `AppDelegate.tearDownSession()`'s seventh step; this file only proves the
// entry itself and pins its source shape, since `AppDelegate.swift` does not compile into this
// test bundle at all (adr/0020 §0(f)).
//
// WHAT R-1 / R-1c DISCRIMINATE, and why both are needed. The registry has always had exactly one
// way to make a RAIL window disappear from the screen and from `windowSnapshots()` together:
// route it through `closeAllWindows()`. R-1c is the control arm gate-r1's own AppKit exit probe
// found (adr/0020 §0(b)): an ordered-in, `isReleasedWhenClosed = false` NSWindow that loses its
// only owner WITHOUT going through `close(via:)` stays alive and on screen -- and, once that
// drop happens inside a drained `autoreleasepool` (see ② below), its own `weak` observer stays
// non-nil too. R-1's own `#require(isVisible == true)` already guards against a probe window
// that was never really visible in the first place; what R-1c adds is proof that the SAME
// setup, minus the entry call, comes out the OTHER way on both of R-1's post-entry signals --
// establishing that those signals actually discriminate "the entry ran" rather than passing
// vacuously. R-1's own probe window is ordered front directly (bypassing the first-frame gate
// deliberately — see the two probe points below) so the two arms differ in exactly one thing:
// whether the entry was called.
//
// TWO PROBE POINTS THIS FILE HAD TO SETTLE BEFORE FREEZING THE ASSERTION FORM (adr/0020 §2 lane
// R "两个待探针点"), recorded here rather than left as a comment nobody re-checks:
//
//  ① Can a headless `xcodebuild test` host actually put a window on screen? Yes -- confirmed
//     both locally and on Tier 2 (run 36248942164, the macOS runner, Xcode 16.4):
//     `NSWindow.orderFront(nil)` set `isVisible == true` on both a bare `NSWindow` and a real
//     registry-built `RemoteWindow`'s window, immediately and reliably (no run-loop spin
//     needed).
//
//  ② Does a CLOSED window leave `NSApp.windows`, and does dropping the last reference after
//     `close(via:)` set a `weak` observer to `nil`? Gate r1's re-probe found this file's first
//     answer here was an artifact, not a fact about layer-backed windows: the earlier probe left
//     the test function's own enclosing autorelease pool undrained for its entire body, so every
//     autoreleased temporary AppKit hands back from `orderFront`/`close` (window-server proxies
//     among them) kept a strong reference alive until the test returned -- long after
//     `close(via:)` itself had run, and regardless of whether it had run at all. Once setup and
//     the entry call are each wrapped in their OWN `autoreleasepool { }` that drains before the
//     following assertions run, BOTH signals discriminate cleanly, even for THIS registry's
//     real, layer-backed window: dropping the entry-owned window's last strong reference inside
//     a drained pool nils a `weak` observer to it (R-1's `weakWindow == nil`, below), and
//     dropping the registry itself inside a drained pool nils a `weak` observer to the registry
//     (R-1c's `weakRegistry == nil`, below), while the window it still owns stays alive and
//     visible. `isVisible` remains the primary NSWindow-level signal both arms assert; the
//     pool-scoped `weak` checks are the ADR's required additional ("外加") signal, not a
//     replacement for it.

/// A `WindowCreate` order with fields this file chooses. `CRDPEvent` exposes every field
/// `readonly` and vends no initializer that takes them (`App/CRBridge/CRSession.h`), so a
/// subclass overriding the getters is the only way to build one -- the same test-local construct
/// `ReconnectTopologyOrderTests`/`RemoteWindowRegistryLeftBorderTests` each keep their own copy
/// of (adr/0020 §0(f): "复制一份" is the established precedent, not a shortcut this file invented).
private final class WindowCreateStub: CRDPEvent {
    static let fieldTitle: UInt32 = 0x0000_0004
    static let fieldStyle: UInt32 = 0x0000_0008
    static let fieldShow: UInt32 = 0x0000_0010
    static let fieldSize: UInt32 = 0x0000_0400
    static let fieldOffset: UInt32 = 0x0000_0800
    /// `WINDOW_SHOW` (freerdp/window.h) -- any nonzero value means shown.
    static let showNormal: UInt32 = 5

    private let id: UInt32

    init(windowId: UInt32) {
        id = windowId
        super.init()
    }

    override var kind: CRDPEventKind { .windowCreate }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { id }
    override var fieldFlags: UInt32 {
        Self.fieldOffset | Self.fieldSize | Self.fieldShow | Self.fieldTitle | Self.fieldStyle
    }
    override var style: UInt32 { 0x000F_0000 }
    override var styleEx: UInt32 { 0 }
    override var ownerWindowId: UInt32 { 0 }
    override var title: String { "session-end-probe" }
    override var offsetX: Int32 { 300 }
    override var offsetY: Int32 { 200 }
    override var windowWidth: UInt32 { 522 }
    override var windowHeight: UInt32 { 514 }
    override var show: UInt32 { Self.showNormal }
}

/// A fixture layout, not this machine's: one 1920x1080 1x primary, injected through the
/// registry's existing provider parameter so nothing here reads `NSScreen`.
@MainActor
private func fixtureTopology() throws -> DisplayTopology {
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    return try #require(DisplayTopology(displays: [display]))
}

/// An UNSTARTED `CRSession` (`-initWithHost:...` only allocates queues and sets
/// `CRSessionStateIdle`; nothing here calls `-start`) with a registry over a static snapshot of
/// `fixtureTopology()`. NOTHING IN THIS FILE CONTACTS ANY HOST, and the strings are empty.
@MainActor
private func makeRegistry() throws -> (CRSession, RemoteWindowRegistry) {
    let session = CRSession(host: "", user: "", password: "", program: "")
    let registry = RemoteWindowRegistry(
        session: session, topologyProvider: StaticDisplayTopologyProvider(try fixtureTopology()))
    return (session, registry)
}

/// Orders the probe window straight onto screen, bypassing the first-frame gate deliberately
/// (probe ①) — returned rather than bound to a local in the caller, so a caller that wants a
/// `weak` observer never has a strong local of its own standing in the way of what that
/// observation is trying to show (probe ②'s "不得强持有" constraint, adr/0020 §2 lane R R-1c).
@MainActor
private func orderFrontStubWindow(registry: RemoteWindowRegistry, windowId: UInt32) -> NSWindow? {
    guard let win = registry.window(forWindowId: windowId) else { return nil }
    win.orderFront(nil)
    return win
}

@MainActor
@Suite("adr/0020 §2 lane R — closeWindowsForSessionEnd() (D-1 = A), behaviour")
struct RemoteWindowRegistrySessionEndBehaviorTests {

    /// R-1. Calling the entry on a registry with one on-screen probe window empties
    /// `windowSnapshots()`, hides the NSWindow it closed, and leaves
    /// `sessionTopologyFreezeCount` at 1 -- the freeze count is what tells D-1's A apart from C
    /// (`prepareForReconnect()` would bump it to 2). Called twice, to prove it is safe against a
    /// caller that runs it more than once.
    @Test func closingAllWindowsAtSessionEndHidesTheWindowAndResetsNothingElse() throws {
        let (_, registry) = try makeRegistry()

        // Setup runs inside its own drained autoreleasepool (gate r1 I-1): without this, AppKit's
        // own autoreleased temporaries from handle()/orderFront keep a strong reference to the
        // window alive for the rest of the test function regardless of what
        // closeWindowsForSessionEnd() does later -- exactly the artifact this file's header ②
        // diagnoses.
        weak var weakWindow: NSWindow?
        autoreleasepool {
            registry.handle(WindowCreateStub(windowId: 501))
            weakWindow = orderFrontStubWindow(registry: registry, windowId: 501)
        }
        try #require(registry.windowSnapshots().count == 1, "setup: the probe window must be tracked before the entry runs")
        try #require(weakWindow != nil, "setup: the probe window must exist")
        try #require(weakWindow?.isVisible == true, "setup (probe ①): the probe window must be on screen before the entry runs")
        try #require(registry.sessionTopologyFreezeCount == 1, "setup: only init's own freeze so far")

        autoreleasepool {
            registry.closeWindowsForSessionEnd()
        }

        #expect(registry.windowSnapshots().isEmpty)
        #expect((weakWindow?.isVisible ?? false) == false, "the entry must hide the window closeAllWindows() closed")
        #expect(weakWindow == nil,
                "adr/0020 §2 lane R's other discriminator (gate r1 I-1): dropping the window's last strong reference inside a drained pool nils this observer")
        #expect(registry.sessionTopologyFreezeCount == 1,
                "the entry must not re-freeze the topology -- this is what tells D-1's A apart from C")

        // Safe to call twice: closeAllWindows() iterates an already-empty table the second time.
        registry.closeWindowsForSessionEnd()
        #expect(registry.windowSnapshots().isEmpty)
        #expect(registry.sessionTopologyFreezeCount == 1)
    }

    /// R-1c. The control arm gate-r1's exit probe found (adr/0020 §0(b)): an ordered-in,
    /// `isReleasedWhenClosed = false` window that loses its only owner WITHOUT going through
    /// `close(via:)` stays alive and on screen. This is R-1's judge -- if this arm didn't hold,
    /// R-1's own assertion could be trivially true for a window nothing ever really showed.
    ///
    /// The window reference held across the drop is `weak`, not strong (probe ②'s constraint,
    /// stated in this file's header): a strong local here would keep the window alive by the
    /// TEST's own doing, which is not what this arm is trying to show.
    @Test func droppingTheRegistryWithoutTheEntryLeavesAVisibleZombieWindow() throws {
        weak var weakWindow: NSWindow?
        weak var weakRegistry: RemoteWindowRegistry?
        var registry: RemoteWindowRegistry? = try makeRegistry().1

        // Same drained-pool setup as R-1 (gate r1 I-1), plus a weak observer on the registry
        // itself (gate r1 m-6): this arm's whole point is that the registry really is gone.
        autoreleasepool {
            weakRegistry = registry
            registry?.handle(WindowCreateStub(windowId: 502))
            weakWindow = registry.flatMap { orderFrontStubWindow(registry: $0, windowId: 502) }
        }
        try #require(weakWindow?.isVisible == true, "setup: the probe window must be on screen before the registry is dropped")

        autoreleasepool {
            registry = nil // "直接丢掉注册表" -- the session-end entry is never called on this arm.
        }

        #expect(weakRegistry == nil, "the owner really is gone -- this arm dropped the registry, not merely a second reference to it")
        #expect(weakWindow != nil, "gate-r1 探针 3's zombie: the window must survive losing its only owner without close()")
        #expect(weakWindow?.isVisible == true, "and stay visible -- this is the reproducible zombie form, not a cleaned-up window")

        // Cleanup so this zombie window cannot leak into a later test in the same process.
        autoreleasepool {
            weakWindow?.orderOut(nil)
            weakWindow?.close()
        }
    }
}

// MARK: - Source pins (R-2, R-3)

private func sessionEndCloseRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func sessionEndCloseRawSource(_ relative: String) throws -> String {
    try String(contentsOf: sessionEndCloseRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func sessionEndCloseFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Same technique as `AppDelegateSessionEndPinTests`/`ReconnectLogChannelPinTests`: strip a `//`
/// line comment before folding, so a pin on a run of STATEMENTS is not also a pin on the prose
/// that explains them.
///
/// LIMITATION, checked rather than assumed: `//` inside a string literal would be stripped too.
/// `theCommentStripperDidNotEatTheEntry` below is what keeps that true for this file's needles.
private func sessionEndCloseCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return sessionEndCloseFolded(lines.joined(separator: " "))
}

private func sessionEndCloseOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Every `.swift` file under `relative`, recursively, as repo-relative paths -- the same walk
/// `ReconnectDriverLinkagePinTests.swiftFiles(under:)` uses, kept as this file's own copy rather
/// than a shared import (adr/0020 §0(f): "复制一份" is the established precedent, not a shortcut).
private func sessionEndCloseSwiftFiles(under relative: String) throws -> [String] {
    let root = sessionEndCloseRepoRoot().appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var out: [String] = []
    for case let entry as String in walker where entry.hasSuffix(".swift") {
        let directories = entry.split(separator: "/").dropLast()
        guard !directories.contains(where: { $0.hasPrefix("build") || $0 == ".build" }) else { continue }
        out.append("\(relative)/\(entry)")
    }
    return out.sorted()
}

@Suite("adr/0020 §2 lane R — closeWindowsForSessionEnd(), source pins (R-2, R-3)")
struct RemoteWindowRegistrySessionEndPinTests {

    private static let registryPath = "App/RemoteWindowRendering/RemoteWindowRegistry.swift"

    /// The entry's name, spelled exactly once, as the one place every needle below quotes it
    /// from -- so a future rename cannot drift the naming-constraint check below out of sync
    /// with the source needles that actually read the file.
    private static let entryName = "closeWindowsForSessionEnd"

    private static func code() throws -> String {
        try sessionEndCloseCodeOnly(sessionEndCloseRawSource(registryPath))
    }

    @Test("the comment stripper leaves the entry and closeAllWindows() intact")
    func theCommentStripperDidNotEatTheEntry() throws {
        let code = try Self.code()
        #expect(code.contains("func \(Self.entryName)() { closeAllWindows() }"))
        #expect(code.contains("private func closeAllWindows() {"))

        // Gate r1 m-3: the two checks this replaced (`!code.contains("adr/0020")`,
        // `!code.contains("// ")`) were tautologies against THIS file's own stripped output --
        // stripping removes every `//` by construction, so the second could never fail, and the
        // first only ever fires on a literal containing that exact string. A fixed two-line
        // sample with a real trailing comment is what actually exercises the stripper.
        let sample = "let a = 1 // adr/0020 keep\nlet b = 2"
        #expect(sessionEndCloseCodeOnly(sample) == "let a = 1 let b = 2",
                "the stripper must remove the comment text, not just fold whitespace around it")
    }

    // MARK: - R-2: the entry's own shape

    /// R-2, naming half. adr/0020 §2 lane R's naming constraint, checked against the constant
    /// every other needle in this suite is built from, so it cannot silently stop meaning what
    /// it says.
    @Test("the entry's name avoids the three substrings that would inflate an existing count")
    func theEntryNameAvoidsTheReservedSubstrings() throws {
        #expect(!Self.entryName.lowercased().contains("reconnect"),
                "would inflate every reconnect-branded count this file and adr/0019's pins already take")
        #expect(!Self.entryName.contains("closeAllWindows"),
                "would be indistinguishable from a call to the method it wraps")
        #expect(!Self.entryName.contains("prepareForReconnect"),
                "would be indistinguishable from a call to the rebuild seam D-1 explicitly rejected (option C)")
    }

    /// R-2, shape half. The entry is declared exactly once, its body is the single statement
    /// `closeAllWindows()` and nothing else -- which by construction also proves the body does
    /// not spell `performClose(`, `sendSysCommand(`, `prepareForReconnect`, `currentGeneration`,
    /// or `refreshSessionTopology`: any of those appearing in the body would change this exact
    /// needle and the assertion below would no longer find it.
    ///
    /// MUST-RED for: m1 (body calls `prepareForReconnect()` instead), m2 (body emptied), m4 (body
    /// calls `closeAllWindows()` a second time) -- each changes this exact string, so
    /// `occurrences == 1` drops to 0. m5 (entry renamed to something containing `Reconnect`)
    /// never reaches this assertion: the behaviour suite above calls the entry by its fixed
    /// name, so a rename fails the whole test target's COMPILE step first -- gate r1 m-4's
    /// correction, a stronger red than any runtime assertion here could produce.
    @Test("the entry is declared once, and its body is exactly closeAllWindows()")
    func theEntryBodyIsExactlyOneCall() throws {
        let code = try Self.code()
        #expect(sessionEndCloseOccurrences(of: "func \(Self.entryName)() { closeAllWindows() }", in: code) == 1)
        #expect(sessionEndCloseOccurrences(of: "func \(Self.entryName)(", in: code) == 1,
                "declared exactly once -- no overload sharing the name")
    }

    /// R-2, `private` half. `closeAllWindows()` itself keeps its access level and its code
    /// byte-for-byte (adr/0019 §4 risk 2, adr/0020 D-1 = A): only its SURROUNDING comments moved
    /// in this lane.
    ///
    /// MUST-RED for: m3 (the `private` keyword dropped from `closeAllWindows()`).
    @Test("closeAllWindows() itself stays private")
    func closeAllWindowsStaysPrivate() throws {
        let code = try Self.code()
        #expect(sessionEndCloseOccurrences(of: "private func closeAllWindows() {", in: code) == 1)
    }

    /// R-2, call-count half. `closeAllWindows()` is a declaration plus its call sites; counting
    /// the bare `closeAllWindows()` text and subtracting the one occurrence that is actually the
    /// declaration (`private func closeAllWindows() {`) is a subtract-the-declaration technique
    /// -- not the with-and-without-parenthesis trick `AppDelegateSessionEndPinTests` uses for
    /// `tearDownSession(` (gate r1 m-4's correction): that trick counts the SAME base string
    /// twice, with and without a trailing paren; here the declaration and its calls share one
    /// substring and are told apart by which longer string contains them. Three calls today (the
    /// generation-rollover branch, `.disconnected`, and `prepareForReconnect()`'s own body)
    /// become four with this lane's entry.
    @Test("closeAllWindows() now has four call sites, not three")
    func closeAllWindowsHasFourCallSites() throws {
        let code = try Self.code()
        let total = sessionEndCloseOccurrences(of: "closeAllWindows()", in: code)
        let declarations = sessionEndCloseOccurrences(of: "private func closeAllWindows() {", in: code)
        #expect(declarations == 1)
        #expect(total - declarations == 4,
                "three existing callers (handle(_:)'s generation branch, .disconnected, prepareForReconnect()) plus the new entry")
    }

    /// R-2 (gate r1 m-7). `Tools/window-smoke` links `RemoteWindowRendering`
    /// (adr/0019 §2 lane B's own `project.yml` pin), so the entry is present in that binary
    /// whether or not the fixture ever calls it. This pin is what keeps it from being called
    /// there: window-smoke drives its own reconnects on its own schedule
    /// (`prepareForReconnect()`, not this lane's session-end entry), and `finishCycle`'s
    /// `clean`/`leftoverWindows`/`freezeCount` assertions are written against that sequence -- a
    /// stray call to `closeWindowsForSessionEnd()` there would change what those numbers mean
    /// without any other pin in this file or `ReconnectSemanticsPinTests` noticing.
    @Test("Tools/window-smoke never calls closeWindowsForSessionEnd()")
    func windowSmokeNeverCallsTheSessionEndEntry() throws {
        let files = try sessionEndCloseSwiftFiles(under: "Tools/window-smoke")
        #expect(files.contains("Tools/window-smoke/main.swift"), "the walk found nothing -- this pin would pass vacuously")
        for file in files {
            let code = try sessionEndCloseCodeOnly(sessionEndCloseRawSource(file))
            #expect(sessionEndCloseOccurrences(of: Self.entryName, in: code) == 0, "wired in \(file)")
        }
    }

    // MARK: - R-3: the guard pins C's own steps did not sneak into the entry

    /// R-3. `currentGeneration = nil` and `refreshSessionTopology(reason:` are D-1's C, not A:
    /// they belong to `prepareForReconnect(refreezingTopologyWith:)`'s steps ③④, which this
    /// lane's entry deliberately does not call. Counting them GLOBALLY (not just inside the
    /// entry's body) is enough to catch a mutant that adds either call anywhere the entry could
    /// reach, because both are pinned everywhere else in this file at their current counts.
    ///
    /// MUST-RED for: a mutant that inlines steps ③④ of `prepareForReconnect()`'s own body --
    /// `currentGeneration = nil` and/or a further `refreshSessionTopology(reason:` call --
    /// directly into the entry, anywhere this file's decommented source can see it. NOT for m1
    /// (the entry calling the EXISTING `prepareForReconnect()` instead): calling an
    /// already-declared method adds no new spelling of either pinned string, so this pin alone
    /// stays green for m1 (gate r1 I-2) -- R-1's frozen `sessionTopologyFreezeCount` and R-2's
    /// exact-body/call-count needles are what catch that one.
    @Test("currentGeneration = nil and refreshSessionTopology(reason: keep their pre-lane counts")
    func theEntryDoesNotSneakInPrepareForReconnectsOwnSteps() throws {
        let code = try Self.code()
        #expect(sessionEndCloseOccurrences(of: "currentGeneration = nil", in: code) == 1)

        let refreshTotal = sessionEndCloseOccurrences(of: "refreshSessionTopology(reason:", in: code)
        let refreshDeclarations = sessionEndCloseOccurrences(
            of: "private func refreshSessionTopology(reason: String) {", in: code)
        #expect(refreshDeclarations == 1)
        #expect(refreshTotal - refreshDeclarations == 2, "the connect-time call and prepareForReconnect()'s own call, and no other")
    }

    // MARK: - R-4: closeAllWindows()'s own body, frozen verbatim (added at gate r1, m-5)

    /// The exact decommented-and-folded text of `closeAllWindows()`'s function body, produced by
    /// running this file's own `sessionEndCloseCodeOnly` over the `7a24b2e` baseline and matched
    /// byte-for-byte against the current file at gate r1 (516 characters both times) -- this
    /// constant IS that verified string, not a fresh transcription of it.
    private static let closeAllWindowsBodyNeedle =
        "private func closeAllWindows() { for (_, window) in windows { window.close(via: session) }" +
        " windows.removeAll() geometry.removeAll() surfaceToWindow.removeAll()" +
        " surfaceMappedSize.removeAll() attachedChildOwner.removeAll() warnedUnresolvedOwner.removeAll()" +
        " trayStatusController.removeAll() desktopState = ServerDesktopState()" +
        " _ = focusAuthority.generationReset() heldModifierKeys = [] wireHeldModifiers = []" +
        " commandKeyMapper.reset() unicodeInputGate.reset() lastMoveSentAt.removeAll()" +
        " pendingTrailingMove.removeAll() }"

    /// R-4. None of R-2's other pins names every statement inside `closeAllWindows()`'s body, so
    /// a mutant that drops one line from deep inside it survives all of them and the full
    /// 227/227 -- gate r1's G5 (deleting `trayStatusController.removeAll()`) is exactly that
    /// mutant, and it is what this pin exists to catch. adr/0019 §4 risk 2 ("清表集合改动单独
    /// 成车道") already required this method's code to move byte-for-byte for D-1 = A; this pin
    /// makes that guarantee run on every future commit instead of only at gate time.
    @Test("closeAllWindows()'s decommented body matches the frozen needle exactly")
    func closeAllWindowsBodyMatchesFrozenNeedle() throws {
        let code = try Self.code()
        #expect(sessionEndCloseOccurrences(of: Self.closeAllWindowsBodyNeedle, in: code) == 1)
    }
}
