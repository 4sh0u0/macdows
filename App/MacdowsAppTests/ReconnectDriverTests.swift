import Foundation
import MacdowsCore
import Testing

// adr/0019 §2 lane B, the behaviour half. `ReconnectSemanticsPinTests` (this directory) holds the
// shapes that only source text can hold; everything here is ordinary offline Swift.
//
// Two fixtures carry the whole suite:
//
//  - `FakeSession`, a `CRSession` subclass built with an empty host and never started, so no
//    method below can reach a socket. The precedent is `GfxFrameCountersTests`'
//    `SurfaceVendingSession`. It overrides the three entry points the driver uses and the two
//    read-only properties the driver reads, records every call in order, and returns whatever the
//    test asked it to.
//  - `ManualClock`, a `ReconnectClock` that records the `Duration` it was handed and fires only
//    when a test says so. The back-off curve is 1 s / 2 s / 4 s / 8 s; a suite that waited for it
//    would take fifteen seconds to make four assertions and would be deleted within a month.
//
// The registry is the REAL `RemoteWindowRegistry`, not a fake, and that is deliberate: the one
// thing lane B must get right about it is that `prepareForReconnect()` is called in the window
// between the shutdown and the start, and the real one counts those calls itself
// (`sessionTopologyFreezeCount`). A fake registry would let the test agree with itself about a
// call the product code might not actually be making.

@MainActor
private final class ManualClock: ReconnectClock {
    /// Every delay this clock has been asked for, in order -- including ones later cancelled, so a
    /// test can distinguish "scheduled then cancelled" from "never scheduled".
    private(set) var requested: [Duration] = []
    /// How many scheduled runs are still live (not fired, not cancelled).
    var pendingCount: Int { pending.count }

    private var pending: [Ticket] = []
    /// The most recent body, kept even after its ticket is cancelled -- see
    /// `fireLastScheduledIgnoringCancellation()`.
    private var lastScheduledBody: (@MainActor () -> Void)?

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        requested.append(delay)
        lastScheduledBody = body
        let ticket = Ticket(body: body) { [weak self] ticket in
            self?.pending.removeAll { $0 === ticket }
        }
        pending.append(ticket)
        return ticket
    }

    /// Runs every live scheduled body, oldest first, and answers how many ran. Unlike `fireNext()`
    /// this tolerates an empty queue: "advance time and show that nothing happens" is a claim a
    /// test has to be able to make without the clock itself recording an issue.
    @discardableResult
    func fireAllPending() -> Int {
        var fired = 0
        while let ticket = pending.first {
            pending.removeFirst()
            ticket.run()
            fired += 1
        }
        return fired
    }

    /// Runs the most recently scheduled body even if its ticket has been cancelled.
    ///
    /// This is not a contract violation dressed up as a test: `DispatchSourceTimer.cancel()`
    /// prevents FURTHER invocations of the event handler, but it does not recall a handler block
    /// that the source has already submitted to its queue. So the production clock really can run
    /// a body one last time after a cancel, and `ReconnectDriver.performReconnect`'s `isAttached`
    /// guard is what has to survive that. Nothing else in this file uses it.
    func fireLastScheduledIgnoringCancellation() {
        lastScheduledBody?()
    }

    /// Runs the oldest live scheduled body, exactly as the real clock would when its deadline
    /// arrives. Fails the test if nothing is scheduled -- "fire a timer that was never set" must
    /// never read as a silent no-op.
    func fireNext(sourceLocation: SourceLocation = #_sourceLocation) {
        guard let ticket = pending.first else {
            Issue.record("fireNext() with nothing scheduled", sourceLocation: sourceLocation)
            return
        }
        pending.removeFirst()
        ticket.run()
    }

    fileprivate final class Ticket: ReconnectClockTicket {
        private var body: (@MainActor () -> Void)?
        private let onCancel: (Ticket) -> Void

        init(body: @escaping @MainActor () -> Void, onCancel: @escaping (Ticket) -> Void) {
            self.body = body
            self.onCancel = onCancel
        }

        func run() {
            let body = self.body
            self.body = nil
            body?()
        }

        func cancel() {
            body = nil
            onCancel(self)
        }
    }
}

private final class FakeSession: CRSession {
    /// What `-teardownInitiated` answers. The real one is YES from the start of
    /// `-shutdownAndWait` until the next `-start`.
    var stubTeardownInitiated = false
    /// What `-lastConnectError` answers. The real one is cleared at the top of every `-start`.
    var stubConnectError: (any Error)?
    /// What `-restartForReconnectPreparing:` returns. The real one is
    /// `cleanShutdown && state == Connected`.
    var restartResult = true

    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var restartCount = 0
    /// Every call this fake received, in order, including the `prepare` callback -- the only way to
    /// assert that the caller's re-take happened BETWEEN the two halves and not beside them.
    private(set) var calls: [String] = []

    override var teardownInitiated: Bool { stubTeardownInitiated }

    override var lastConnectError: (any Error)? { stubConnectError }

    override func start() {
        startCount += 1
        calls.append("start")
    }

    override func shutdownAndWait() -> Bool {
        shutdownCount += 1
        calls.append("shutdown")
        return true
    }

    override func restartForReconnect(preparing prepare: (() -> Void)?) -> Bool {
        restartCount += 1
        // Reproduces the real method's own three steps, so a `prepare` block that depends on
        // running between them is being tested against that arrangement rather than against a
        // stub that happens to call it somewhere.
        calls.append("shutdown")
        shutdownCount += 1
        calls.append("prepare")
        prepare?()
        calls.append("start")
        startCount += 1
        return restartResult
    }
}

private final class DisconnectEvent: CRDPEvent {
    override var kind: CRDPEventKind { .disconnected }
}

private final class HandshakeEvent: CRDPEvent {
    override var kind: CRDPEventKind { .handshakeFlags }
}

/// An event kind the driver must ignore entirely, so "ignored" is a checked claim rather than an
/// absence of code.
private final class FrameReadyEvent: CRDPEvent {
    override var kind: CRDPEventKind { .frameReady }
}

@MainActor
private struct Fixture {
    let session: FakeSession
    let registry: RemoteWindowRegistry
    let clock: ManualClock
    let driver: ReconnectDriver

    /// A fixture layout, not this machine's: one 1920x1080 1x primary, injected through the
    /// registry's provider seam so nothing here reads a real `NSScreen`.
    static func make(attached: Bool = true) throws -> Fixture {
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
        )
        let topology = try #require(DisplayTopology(displays: [display]))
        let session = FakeSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(
            session: session, topologyProvider: StaticDisplayTopologyProvider(topology)
        )
        let clock = ManualClock()
        let driver = ReconnectDriver(session: session, registry: registry, clock: clock)
        if attached { driver.attach() }
        return Fixture(session: session, registry: registry, clock: clock, driver: driver)
    }

    func disconnect() { driver.handle(DisconnectEvent()) }
    func handshake() { driver.handle(HandshakeEvent()) }
}

@MainActor
@Suite("ReconnectDriver: what it reacts to (adr/0019 §2 lane B)")
struct ReconnectDriverReactionTests {

    /// Test ④. The one case that must produce NOTHING. `-shutdownAndWait` posts the same
    /// `DISCONNECTED` sentinel a server-side drop does, so a driver that reacted to the sentinel
    /// alone would race its own owner: `applicationWillTerminate` would tear the session down and
    /// the driver would immediately start bringing it back up. `teardownInitiated` is the only
    /// thing in the system that distinguishes the two, and this is the test that it is read.
    @Test("a disconnect during our own teardown schedules nothing and changes nothing")
    func ownTeardownIsNotAReconnect() throws {
        let fixture = try Fixture.make()
        fixture.session.stubTeardownInitiated = true

        fixture.disconnect()

        #expect(fixture.clock.requested.isEmpty)
        #expect(fixture.clock.pendingCount == 0)
        #expect(fixture.session.restartCount == 0)
        #expect(fixture.driver.state == .idle)
        #expect(fixture.driver.lastGiveUpCause == nil)
    }

    /// Test ⑤. The first unexpected drop waits exactly what the policy says for failed-attempt
    /// index 0 -- asserted by CALLING the policy, not by writing `1` here. A test that hard-coded
    /// the number would keep passing if the driver stopped consulting the policy at all, which is
    /// the failure this is for (the constants are provisional until the R-1 follow-ups, and a
    /// driver with its own copy of them would silently diverge the day they change).
    @Test("the first unexpected disconnect waits exactly ReconnectPolicy.delay(forFailedAttempt: 0)")
    func firstDropUsesThePolicysFirstDelay() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()

        let expected = try ReconnectPolicy.delay(forFailedAttempt: 0)
        #expect(fixture.clock.requested == [expected])
        #expect(fixture.driver.state == .waiting(attempt: 0, delay: expected))
        // Scheduled, not performed: the whole point of a back-off is that nothing happens yet.
        #expect(fixture.session.restartCount == 0)
    }

    /// The back-off actually backs off. Four drops, four delays, each read back from the policy --
    /// this is what a driver that always waited `baseDelay` (or that reset its index every time)
    /// fails.
    @Test("successive failures walk the policy's curve, one index per failed attempt")
    func successiveFailuresWalkTheCurve() throws {
        let fixture = try Fixture.make()

        for _ in 0..<4 {
            fixture.disconnect()
            fixture.clock.fireNext()
        }

        let expected = try (0..<4).map { try ReconnectPolicy.delay(forFailedAttempt: $0) }
        #expect(fixture.clock.requested == expected)
        #expect(fixture.session.restartCount == 4)
    }

    /// Test ⑥. Terminal means terminal. Two claims, and the second is the one worth having: after
    /// the give-up, further disconnects (a server that keeps dropping a client that keeps not
    /// connecting) must not restart the curve, must not schedule, and must not touch the session.
    @Test("failures up to the policy's limit give up, and nothing after that reschedules")
    func attemptsExhaustedIsTerminal() throws {
        let fixture = try Fixture.make()

        for _ in 0..<(ReconnectPolicy.maxAttempts - 1) {
            fixture.disconnect()
            fixture.clock.fireNext()
        }
        // One more failure than the policy allows attempts for.
        fixture.disconnect()

        #expect(fixture.driver.state == .gaveUp(.policy(.attemptsExhausted)))
        #expect(fixture.driver.lastGiveUpCause == .policy(.attemptsExhausted))

        let scheduledAtGiveUp = fixture.clock.requested.count
        let restartsAtGiveUp = fixture.session.restartCount
        #expect(fixture.clock.pendingCount == 0)

        fixture.disconnect()
        fixture.disconnect()
        // Gate r1 M8: advance the clock as well as injecting the events. "Nothing was scheduled"
        // and "something was scheduled but we never looked" are different claims, and only the
        // first one is the one this test is making.
        #expect(fixture.clock.fireAllPending() == 0)

        #expect(fixture.clock.requested.count == scheduledAtGiveUp)
        #expect(fixture.session.restartCount == restartsAtGiveUp)
        #expect(fixture.driver.state == .gaveUp(.policy(.attemptsExhausted)))
    }

    /// Gate r1 M8/m-1: the `.gaveUp` terminal guard, in the one shape that actually needs it.
    ///
    /// After an exhausted back-off the guard is redundant -- `giveUp()`'s own idempotent early
    /// return absorbs a repeat, which is why the mutation that deleted the guard survived the test
    /// above. The shape that does NOT absorb it is a give-up caused by a bridge refusal followed by
    /// a disconnect with the error gone: `lastConnectError` is cleared at the top of every
    /// `-start`, so any route that restarts the session (lane D's Connect button, a manual retry)
    /// leaves exactly that arrangement behind. Without the guard the driver would quietly restart
    /// the whole back-off curve from index 0 for a session it has already publicly given up on.
    @Test("a give-up survives a later disconnect whose connect error has since been cleared")
    func giveUpSurvivesAClearedConnectError() throws {
        let fixture = try Fixture.make()
        fixture.session.stubConnectError = NSError(domain: "Macdows.CRSession", code: -2)
        fixture.disconnect()
        #expect(fixture.driver.state == .gaveUp(.refusedByBridge(code: -2)))

        // The error is gone (a `-start` from somewhere else cleared it), and we are not tearing
        // down -- so every guard except the terminal one lets this through.
        fixture.session.stubConnectError = nil
        #expect(fixture.session.teardownInitiated == false)
        fixture.disconnect()
        #expect(fixture.clock.fireAllPending() == 0)

        #expect(fixture.clock.requested.isEmpty)
        #expect(fixture.session.restartCount == 0)
        #expect(fixture.driver.state == .gaveUp(.refusedByBridge(code: -2)))
    }

    /// Test ⑦. A successful handshake resets the attempt index, so an unstable link that drops
    /// once an hour never accumulates its way to a give-up. The assertion that matters is the LAST
    /// one: the delay after the reset is the policy's index-0 answer again, not its index-2 one.
    @Test("a handshake makes the session live and puts the next failure back at index 0")
    func handshakeResetsTheAttemptCount() throws {
        let fixture = try Fixture.make()

        for _ in 0..<2 {
            fixture.disconnect()
            fixture.clock.fireNext()
        }
        #expect(fixture.driver.failedAttempts == 2)

        fixture.handshake()
        #expect(fixture.driver.state == .live)
        #expect(fixture.driver.failedAttempts == 0)

        fixture.disconnect()
        let first = try ReconnectPolicy.delay(forFailedAttempt: 0)
        #expect(fixture.clock.requested.last == first)
        #expect(fixture.driver.state == .waiting(attempt: 0, delay: first))
    }

    /// Test ⑩. A refused connection is not a dropped one. `-lastConnectError` non-nil means the
    /// bridge itself said no -- DNS/TCP/TLS/NLA, or the ADR-0017 §4 A2 decode-path refusal -- and
    /// the same attempt will be refused the same way however long the driver waits. Checked BEFORE
    /// everything else because a refusal also posts the disconnect sentinel, so any later branch
    /// would swallow it and start a five-attempt back-off against a wall.
    @Test("a disconnect with a connect error gives up immediately, with the bridge's own code")
    func bridgeRefusalSkipsTheBackoff() throws {
        let fixture = try Fixture.make()
        fixture.session.stubConnectError = NSError(domain: "Macdows.CRSession", code: -5)

        fixture.disconnect()

        #expect(fixture.driver.state == .gaveUp(.refusedByBridge(code: -5)))
        #expect(fixture.driver.lastGiveUpCause == .refusedByBridge(code: -5))
        #expect(fixture.clock.requested.isEmpty)
        #expect(fixture.clock.pendingCount == 0)
        #expect(fixture.session.restartCount == 0)
    }

    /// A give-up while a retry is already in flight has to cancel it. Without this, the driver
    /// gives up, reports it, and then performs one more reconnect anyway when the timer fires.
    @Test("giving up cancels a retry that was already scheduled")
    func giveUpCancelsAPendingRetry() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        #expect(fixture.clock.pendingCount == 1)

        fixture.session.stubConnectError = NSError(domain: "Macdows.CRSession", code: -2)
        fixture.disconnect()

        #expect(fixture.clock.pendingCount == 0)
        #expect(fixture.session.restartCount == 0)
    }

    /// Two disconnects before the first retry fires -- a duplicate drain, or a server dropping the
    /// same connection twice -- must leave ONE retry outstanding, not two reconnects racing.
    @Test("a second disconnect while a retry is pending does not stack a second reconnect")
    func retriesDoNotStack() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        fixture.disconnect()

        #expect(fixture.clock.pendingCount == 1)
        fixture.clock.fireNext()
        #expect(fixture.session.restartCount == 1)

        // Gate r1 m-7, registered as a checked fact rather than left to a reader: the second
        // disconnect cancels and RE-SCHEDULES at the same index, so the wait restarts from the top
        // instead of continuing. Unreachable today -- one connection posts one sentinel -- but if a
        // later lane makes it reachable, this is the behaviour it will be changing.
        let first = try ReconnectPolicy.delay(forFailedAttempt: 0)
        #expect(fixture.clock.requested == [first, first])
    }

    /// Gate r1 I-1, the timer edge. `teardownInitiated` is read when a disconnect ARRIVES; a
    /// teardown that starts after the retry is scheduled and before its timer fires is invisible to
    /// that check. Without a second guard the driver walks through that window and brings a session
    /// its owner has just closed back up -- shutdown, `prepareForReconnect()`, start -- which for
    /// an app that is terminating means resurrecting the thing it is quitting.
    @Test("a teardown started while a retry is pending stops the retry at the timer edge")
    func teardownBetweenScheduleAndFireStopsTheReconnect() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        #expect(fixture.clock.pendingCount == 1)

        // The owner tears the session down; nothing tells the driver.
        fixture.session.stubTeardownInitiated = true
        fixture.clock.fireNext()

        #expect(fixture.session.restartCount == 0)
        #expect(fixture.session.startCount == 0)
        #expect(fixture.registry.sessionTopologyFreezeCount == 1, "prepareForReconnect() must not have run")
        #expect(fixture.driver.state == .idle)
        #expect(fixture.clock.pendingCount == 0)
    }

    /// Gate r1 m-6. `detach()` is the only external way to cancel an in-flight retry, and it is the
    /// natural place for lane D to hook a deliberate disconnect. Two claims: the ticket really is
    /// cancelled, and the driver is inert afterwards.
    @Test("detach cancels a pending retry, and time passing afterwards does nothing")
    func detachCancelsAPendingRetry() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        #expect(fixture.clock.pendingCount == 1)

        fixture.driver.detach()

        #expect(fixture.clock.pendingCount == 0)
        #expect(fixture.clock.fireAllPending() == 0)
        #expect(fixture.session.restartCount == 0)
        #expect(fixture.driver.isAttached == false)
    }

    /// Gate r1 I-1, second half: the guard's `isAttached` term, tested through the one race a real
    /// `DispatchSourceTimer` can lose -- `cancel()` does not recall a handler block already
    /// submitted to the queue, so a body can run once after `detach()`. The guard, not the clock,
    /// is what has to refuse it.
    @Test("a detached driver refuses a timer body that fires anyway")
    func detachedDriverRefusesALateTimerBody() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        fixture.driver.detach()
        fixture.clock.fireLastScheduledIgnoringCancellation()

        #expect(fixture.session.restartCount == 0)
        #expect(fixture.registry.sessionTopologyFreezeCount == 1)
        #expect(fixture.driver.state == .idle)
    }

    /// Ignored kinds are ignored. `FrameReady` arrives thousands of times per session; a driver
    /// that fell through to any state change on it would be unusable.
    @Test("event kinds other than handshake and disconnect do nothing")
    func unrelatedEventsAreIgnored() throws {
        let fixture = try Fixture.make()

        fixture.driver.handle(FrameReadyEvent())

        #expect(fixture.driver.state == .idle)
        #expect(fixture.clock.requested.isEmpty)
        #expect(fixture.session.restartCount == 0)
    }

    /// Not wired means not armed, at runtime as well as at link time. Construction alone must not
    /// make a driver that reacts to anything -- that is what lets lane B merge the class into the
    /// app target without changing a single thing the app does.
    @Test("an unattached driver ignores everything")
    func unattachedDriverIsInert() throws {
        let fixture = try Fixture.make(attached: false)

        fixture.disconnect()
        fixture.handshake()

        #expect(fixture.driver.isAttached == false)
        #expect(fixture.driver.state == .idle)
        #expect(fixture.clock.requested.isEmpty)
        #expect(fixture.session.restartCount == 0)
    }
}

@MainActor
@Suite("ReconnectDriver: how it performs a reconnect (adr/0019 §2 lane B)")
struct ReconnectDriverStepTests {

    /// The composed step, in order. `shutdown` -> `prepare` -> `start` is enforced inside
    /// `-restartForReconnectPreparing:`; what this asserts is that the driver goes through that
    /// method at all rather than calling `shutdownAndWait()` and `start()` itself, which is the
    /// shape that lost the ordering guarantee in the first place.
    @Test("the driver reconnects through the one composed step, never through shutdown + start")
    func reconnectGoesThroughTheComposedStep() throws {
        let fixture = try Fixture.make()

        fixture.disconnect()
        fixture.clock.fireNext()

        #expect(fixture.session.restartCount == 1)
        #expect(fixture.session.calls == ["shutdown", "prepare", "start"])
        #expect(fixture.driver.state == .reconnecting(attempt: 0))
    }

    /// The `prepare` block's own internal order: the topology re-take (lane C's hook) runs BEFORE
    /// the registry re-freeze, because the registry freezes against whatever the topology is at
    /// that instant. Reversed, the registry freezes against the old layout and the server is then
    /// told about the new one -- the divergence adr/0015 §5.A.4 forbids, and one the fixture's own
    /// comment records as invisible to every offline test when the two steps are written by hand.
    ///
    /// Read through the registry's own freeze counter rather than a recorder the test controls:
    /// the hook records the count it SEES, so "before" and "after" are measured against the thing
    /// being ordered.
    @Test("topologyRefresh runs before the registry re-freeze, inside the prepare window")
    func topologyRefreshRunsBeforeTheRegistryRefreeze() throws {
        let fixture = try Fixture.make()
        // One freeze already happened: the registry takes its snapshot at construction.
        let freezesAtStart = fixture.registry.sessionTopologyFreezeCount
        #expect(freezesAtStart == 1)

        var freezesSeenByHook: Int?
        fixture.driver.topologyRefresh = { [registry = fixture.registry] in
            freezesSeenByHook = registry.sessionTopologyFreezeCount
        }

        fixture.disconnect()
        fixture.clock.fireNext()

        #expect(freezesSeenByHook == freezesAtStart, "the hook ran after prepareForReconnect()")
        #expect(fixture.registry.sessionTopologyFreezeCount == freezesAtStart + 1)
    }

    /// The registry is re-prepared exactly once per reconnect. Twice would double-count the
    /// freeze, which `Tools/window-smoke`'s N+1 assertion reads directly; zero times would leave
    /// the previous connection's windows on screen under a new generation.
    @Test("each reconnect re-prepares the registry exactly once")
    func registryIsPreparedOncePerReconnect() throws {
        let fixture = try Fixture.make()

        for _ in 0..<3 {
            fixture.disconnect()
            fixture.clock.fireNext()
        }

        #expect(fixture.registry.sessionTopologyFreezeCount == 1 + 3)
    }

    /// A nil `topologyRefresh` is the lane-B default and must be a clean no-op, not a crash and not
    /// a skipped registry re-freeze. This is the state lane B merges in, so it is the state that
    /// needs the test.
    @Test("a nil topologyRefresh still performs the reconnect and re-freezes the registry")
    func nilTopologyHookIsANoOp() throws {
        let fixture = try Fixture.make()
        #expect(fixture.driver.topologyRefresh == nil)

        fixture.disconnect()
        fixture.clock.fireNext()

        #expect(fixture.session.restartCount == 1)
        #expect(fixture.registry.sessionTopologyFreezeCount == 2)
    }

    /// Test ⑨, behaviour half. What the composed step's `BOOL` means to the driver, in all three
    /// combinations that can occur.
    ///
    /// YES is "both halves succeeded" -- the shutdown was clean AND a thread was spawned. It is
    /// NOT "connected": the connect happens on that thread afterwards, so the driver waits for a
    /// handshake rather than treating YES as success.
    ///
    /// NO is two different things wearing one bit, and `-lastConnectError` is what separates them.
    /// NO with no error means the shutdown was not clean but the attempt IS airborne (this is
    /// exactly the case the sentinel-memory fix makes rare rather than universal -- see
    /// `ReconnectSemanticsPinTests`) -- tearing that down to retry would be the driver fighting
    /// its own attempt. NO with an error means `-start` fell straight back to idle and no event
    /// will ever arrive, so waiting would hang the driver in `.reconnecting` forever.
    @Test("the composed step's return value is read as airborne-or-not, not as connected-or-not")
    func restartResultIsReadCorrectly() throws {
        // YES: airborne, wait for events, no give-up.
        let clean = try Fixture.make()
        clean.session.restartResult = true
        clean.disconnect()
        clean.clock.fireNext()
        #expect(clean.driver.state == .reconnecting(attempt: 0))
        #expect(clean.driver.lastGiveUpCause == nil)

        // NO, no error: unclean shutdown, thread still spawned -- also airborne.
        let unclean = try Fixture.make()
        unclean.session.restartResult = false
        unclean.disconnect()
        unclean.clock.fireNext()
        #expect(unclean.driver.state == .reconnecting(attempt: 0))
        #expect(unclean.driver.lastGiveUpCause == nil)

        // NO, with an error: the start itself failed, nothing will ever arrive.
        let refused = try Fixture.make()
        refused.session.restartResult = false
        refused.disconnect()
        refused.session.stubConnectError = NSError(domain: "Macdows.CRSession", code: -4)
        refused.clock.fireNext()
        #expect(refused.driver.state == .gaveUp(.refusedByBridge(code: -4)))
    }

    /// The seam lane D consumes: every state change, in order, with `state` already updated when
    /// the handler runs.
    @Test("onStateChange reports every transition in order")
    func stateChangesAreReportedInOrder() throws {
        let fixture = try Fixture.make()
        var seen: [ReconnectDriver.State] = []
        fixture.driver.onStateChange = { seen.append($0) }

        fixture.disconnect()
        fixture.clock.fireNext()
        fixture.handshake()

        let firstDelay = try ReconnectPolicy.delay(forFailedAttempt: 0)
        #expect(seen == [.waiting(attempt: 0, delay: firstDelay), .reconnecting(attempt: 0), .live])
    }
}

@MainActor
@Suite("ReconnectDriver: the [reconnect] judgement line (adr/0019 §2 lane B)")
struct ReconnectDriverLogLineTests {

    /// The frozen shape, field by field. This line is the judgement unit a future live-host
    /// acceptance run will read, and a judgement unit that changes after the fact makes every
    /// earlier run unreadable -- so the exact strings are asserted here rather than described in a
    /// comment. Four fields, always all four, always in this order; `delay-ms` carries a value only
    /// while waiting and `cause` only after a give-up.
    @Test("every state prints all four fields in the frozen order")
    func logLineShapeIsFrozen() {
        #expect(ReconnectDriver.logLine(for: .waiting(attempt: 0, delay: .seconds(1)), failedAttempts: 0)
            == "[reconnect] attempt=0 delay-ms=1000 state=waiting cause=")
        #expect(ReconnectDriver.logLine(for: .waiting(attempt: 3, delay: .seconds(8)), failedAttempts: 3)
            == "[reconnect] attempt=3 delay-ms=8000 state=waiting cause=")
        #expect(ReconnectDriver.logLine(for: .reconnecting(attempt: 2), failedAttempts: 3)
            == "[reconnect] attempt=2 delay-ms= state=reconnecting cause=")
        #expect(ReconnectDriver.logLine(for: .live, failedAttempts: 0)
            == "[reconnect] attempt= delay-ms= state=live cause=")
        #expect(ReconnectDriver.logLine(for: .gaveUp(.policy(.attemptsExhausted)), failedAttempts: 4)
            == "[reconnect] attempt=4 delay-ms= state=gaveup cause=attempts-exhausted")
        #expect(ReconnectDriver.logLine(for: .gaveUp(.refusedByBridge(code: -5)), failedAttempts: 0)
            == "[reconnect] attempt=0 delay-ms= state=gaveup cause=refused-by-bridge:-5")
        #expect(ReconnectDriver.logLine(for: .gaveUp(.policyRefused(attemptIndex: -1)), failedAttempts: 0)
            == "[reconnect] attempt=0 delay-ms= state=gaveup cause=policy-refused-index:-1")
    }

    /// `.idle` has no line: it is a starting value, not a transition, and the frozen shape
    /// enumerates four state names that do not include it. A line for it would be a fifth name
    /// that no parser was told about.
    @Test("the idle starting value prints nothing")
    func idleHasNoLine() {
        #expect(ReconnectDriver.logLine(for: .idle, failedAttempts: 0) == nil)
    }

    /// The `delay-ms` field is derived from the policy's `Duration`, so the printed numbers are
    /// the policy's curve and not a second copy of it.
    @Test("delay-ms carries the policy's own curve")
    func delayMillisecondsComeFromThePolicy() throws {
        let printed = try (0..<4).map { index -> Int64 in
            ReconnectDriver.milliseconds(try ReconnectPolicy.delay(forFailedAttempt: index))
        }
        #expect(printed == [1_000, 2_000, 4_000, 8_000])
        #expect(ReconnectDriver.milliseconds(ReconnectPolicy.maxDelay) == 16_000)
    }
}
