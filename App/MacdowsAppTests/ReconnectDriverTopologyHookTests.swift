import AppKit
import MacdowsCore
import Testing

// adr/0019 §2 lane C, the driver half (C-7). `ReconnectDriverTests` covers lane B's state machine;
// this file covers exactly one thing lane C changed about it — `topologyRefresh` is no longer a
// statement the driver runs beside `prepareForReconnect()`, it is the ARGUMENT to
// `prepareForReconnect(refreezingTopologyWith:)`, so the order the old comment asked a reader to
// preserve is now the only order the call can have.
//
// THE REGISTRY IS THE REAL ONE, deliberately (lane B's suite makes the same choice for the same
// reason): a fake registry would let this file agree with itself about a call the driver might not
// be making. What is faked is the session — a `CRSession` subclass built with an empty host and
// never started, so nothing here can reach a socket — and the clock, because the back-off curve
// starts at one second and a suite that waited for it would be deleted within a month.
//
// The source-text twin of this claim (the hook is evaluated in exactly one place, and that place
// is the argument) is `ReconnectTopologyOrderPinTests.theDriverPassesTheHookAsTheArgument`.

/// A clock that fires only when this file says so. Minimal on purpose — the one scheduled body,
/// run on demand.
@MainActor
private final class HookTestClock: ReconnectClock {
    private(set) var scheduled: [Duration] = []
    private var body: (@MainActor () -> Void)?

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        scheduled.append(delay)
        self.body = body
        return Ticket { [weak self] in self?.body = nil }
    }

    /// Runs the pending body, or records an issue: "fire a timer that was never set" must never
    /// read as a silent no-op.
    func fire(sourceLocation: SourceLocation = #_sourceLocation) {
        guard let body else {
            Issue.record("fire() with nothing scheduled", sourceLocation: sourceLocation)
            return
        }
        self.body = nil
        body()
    }

    fileprivate final class Ticket: ReconnectClockTicket {
        private let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }
}

/// A `CRSession` that records the three steps of `-restartForReconnectPreparing:` in order,
/// including the caller's `prepare` block — the only way to assert the re-take happened BETWEEN
/// the two halves rather than beside them. Never started; see the file header.
private final class HookTestSession: CRSession {
    private(set) var calls: [String] = []

    override var teardownInitiated: Bool { false }
    override var lastConnectError: (any Error)? { nil }

    override func restartForReconnect(preparing prepare: (() -> Void)?) -> Bool {
        calls.append("shutdown")
        calls.append("prepare")
        prepare?()
        calls.append("start")
        return true
    }
}

private final class DisconnectStub: CRDPEvent {
    override var kind: CRDPEventKind { .disconnected }
}

/// A `DisplayTopologyProviding` that counts reads. Same shape and same job as the one in
/// `ReconnectTopologyOrderTests`; duplicated rather than shared because both are `private` to
/// their file, which is what keeps a fixture from drifting into an API.
@MainActor
private final class CountingProvider: DisplayTopologyProviding {
    private let topology: DisplayTopology?
    private(set) var reads = 0

    init(_ topology: DisplayTopology?) { self.topology = topology }

    var currentTopology: DisplayTopology? {
        reads += 1
        return topology
    }
}

@MainActor
private func hookFixtureTopology(width: Double) throws -> DisplayTopology {
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: width, height: 1080),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    return try #require(DisplayTopology(displays: [display]))
}

@MainActor
@Suite("ReconnectDriver hands the topology re-take in as an argument (adr/0019 §2 lane C)")
struct ReconnectDriverTopologyHookTests {

    /// C-7. An unexpected disconnect, the back-off timer fires, and the reconnect runs: the hook's
    /// provider must be installed on the registry, and it must be installed BEFORE the registry
    /// tears its window table down.
    ///
    /// MUST-RED for: reinstating `topologyRefresh?()` as a statement beside
    /// `prepareForReconnect()` (the returned provider would go nowhere — `fresh.reads` stays 0 and
    /// the old seam is read a second time), and for evaluating the hook after the teardown (the
    /// window count seen inside it would be 0).
    @Test func theHookIsEvaluatedInsidePrepareAndBeforeTheTeardown() throws {
        let old = CountingProvider(try hookFixtureTopology(width: 1920))
        let fresh = CountingProvider(try hookFixtureTopology(width: 2560))
        let session = HookTestSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(session: session, topologyProvider: old)
        let clock = HookTestClock()
        let driver = ReconnectDriver(session: session, registry: registry, clock: clock)
        driver.attach()
        registry.handle(HookWindowStub(windowId: 301))
        try #require(registry.windowSnapshots().count == 1)

        var windowsSeenByTheHook: Int?
        driver.topologyRefresh = {
            windowsSeenByTheHook = registry.windowSnapshots().count
            return fresh
        }

        driver.handle(DisconnectStub())
        try #require(clock.scheduled.count == 1, "one retry scheduled by the policy")
        clock.fire()

        // The step order the bridge method exists to enforce, and the hook inside it.
        #expect(session.calls == ["shutdown", "prepare", "start"])
        #expect(windowsSeenByTheHook == 1, "the hook must run before closeAllWindows()")
        // The installation claim: the post-teardown re-take read the hook's provider, once.
        #expect(fresh.reads == 1)
        #expect(old.reads == 1, "the connect-time seam must not be read again")
        #expect(registry.sessionTopologyFreezeCount == 2)
        #expect(registry.windowSnapshots().isEmpty)
    }

    /// The no-hook default is lane B's registered behaviour and lane C must not change it: with
    /// no `topologyRefresh`, the reconnect still prepares the registry and the registry still
    /// re-freezes against the seam it already had (adr/0015 §5.A.4's no-refresh branch).
    ///
    /// MUST-RED for: an absent hook skipping `prepareForReconnect` altogether, and for the driver
    /// inventing a provider of its own when the hook is nil.
    @Test func withNoHookTheRegistryKeepsItsSeamAndStillPrepares() throws {
        let seam = CountingProvider(try hookFixtureTopology(width: 1920))
        let session = HookTestSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(session: session, topologyProvider: seam)
        let clock = HookTestClock()
        let driver = ReconnectDriver(session: session, registry: registry, clock: clock)
        driver.attach()

        driver.handle(DisconnectStub())
        clock.fire()

        #expect(session.calls == ["shutdown", "prepare", "start"])
        #expect(seam.reads == 2, "init's freeze plus the reconnect re-take, both against the same seam")
        #expect(registry.sessionTopologyFreezeCount == 2)
    }

    /// A hook that returns `nil` — "I re-derived what I needed, there is nothing to swap in", the
    /// shape `Tools/window-smoke` uses — must behave exactly like no hook at all on the registry
    /// side, while still having been called.
    @Test func aHookThatReturnsNilStillRunsAndKeepsTheSeam() throws {
        let seam = CountingProvider(try hookFixtureTopology(width: 1920))
        let session = HookTestSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(session: session, topologyProvider: seam)
        let clock = HookTestClock()
        let driver = ReconnectDriver(session: session, registry: registry, clock: clock)
        driver.attach()
        var hookCalls = 0
        driver.topologyRefresh = {
            hookCalls += 1
            return nil
        }

        driver.handle(DisconnectStub())
        clock.fire()

        #expect(hookCalls == 1, "the hook is called exactly once per reconnect")
        #expect(seam.reads == 2)
        #expect(registry.sessionTopologyFreezeCount == 2)
    }
}

/// A `WindowCreate` order, so the registry has a table to tear down. See
/// `ReconnectTopologyOrderTests` for why a `CRDPEvent` subclass is the only way to build one.
private final class HookWindowStub: CRDPEvent {
    private let id: UInt32
    init(windowId: UInt32) {
        id = windowId
        super.init()
    }
    override var kind: CRDPEventKind { .windowCreate }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { id }
    /// `FIELD_OFFSET | FIELD_SIZE | FIELD_SHOW | FIELD_TITLE | FIELD_STYLE`.
    override var fieldFlags: UInt32 { 0x0000_0800 | 0x0000_0400 | 0x0000_0010 | 0x0000_0004 | 0x0000_0008 }
    override var style: UInt32 { 0x000F_0000 }
    override var styleEx: UInt32 { 0 }
    override var ownerWindowId: UInt32 { 0 }
    override var title: String { "reconnect-driver-probe" }
    override var offsetX: Int32 { 300 }
    override var offsetY: Int32 { 200 }
    override var windowWidth: UInt32 { 522 }
    override var windowHeight: UInt32 { 514 }
    /// `WINDOW_SHOW` — any nonzero value means shown.
    override var show: UInt32 { 5 }
}
