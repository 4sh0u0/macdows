import Foundation
import MacdowsCore
import Testing

// adr/0019 supplementary ruling RB-1 (a′): who reads a connect error -- the App's connect-error
// branch or the reconnect driver.
//
// `AppDelegate` is not compiled into this bundle (see `AppDelegateReconnectWiringPinTests`' header),
// so its drain tick cannot be driven here. What CAN be driven is everything the tick's decision is
// made of: the predicate it asks (`ReconnectDriver.connectErrorBelongsToDriver(in:)`, production
// code), the real driver, and a session double that sets the error first and then delivers the
// sentinel, in the bridge's order. `AppTick` below is the tick's routing re-stated in three lines
// over that predicate; `AppDelegateReconnectWiringPinTests.theConnectErrorBranchEndsTheSession` pins
// that the App's branch is written with exactly this condition, before the drain. Together the two
// say what neither says alone: the condition is the one in the App, and the condition routes the
// events the way the ruling requires.

@MainActor
private final class StepClock: ReconnectClock {
    private var pending: [Ticket] = []
    private(set) var requested: [Duration] = []
    var pendingCount: Int { pending.count }

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        requested.append(delay)
        let ticket = Ticket(body: body) { [weak self] ticket in self?.pending.removeAll { $0 === ticket } }
        pending.append(ticket)
        return ticket
    }

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

/// A `CRSession` that never starts: the error and the restart are what the test says. Like the real
/// one, a restart clears the connect error (the real `-start` clears it on entry).
private final class RoutingSession: CRSession {
    var connectError: NSError?
    private(set) var restartCount = 0

    override var lastConnectError: (any Error)? { connectError }
    override var teardownInitiated: Bool { false }
    override var lastCertificateRejection: CRCertificateRejection? { nil }
    override func start() {}
    override func shutdownAndWait() -> Bool { true }
    override func restartForReconnect(preparing prepare: (() -> Void)?) -> Bool {
        restartCount += 1
        prepare?()
        connectError = nil
        return true
    }
}

private final class Sentinel: CRDPEvent {
    override var kind: CRDPEventKind { .disconnected }
}

private final class Handshake: CRDPEvent {
    override var kind: CRDPEventKind { .handshakeFlags }
}

/// The App's drain tick, routing only: the connect-error branch takes the error when the predicate
/// says the leg is not the driver's (and ends the session, which detaches the driver); otherwise
/// the drained events reach the driver.
@MainActor
private final class AppTick {
    let session: RoutingSession
    let driver: ReconnectDriver
    let clock: StepClock
    private let registry: RemoteWindowRegistry
    /// Whether the connect-error branch has ended the session (the teardown's `detach()` included).
    private(set) var appTookTheError = false

    init() throws {
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
        )
        let topology = try #require(DisplayTopology(displays: [display]))
        session = RoutingSession(host: "", user: "", passwordBytes: Data(), program: "")
        registry = RemoteWindowRegistry(session: session, topologyProvider: StaticDisplayTopologyProvider(topology))
        clock = StepClock()
        driver = ReconnectDriver(session: session, registry: registry, clock: clock)
        driver.attach()
    }

    /// One tick delivering `events` (none for a backstop-timer tick that finds the queue empty).
    func tick(_ events: [CRDPEvent]) {
        guard !appTookTheError else { return }
        if session.lastConnectError != nil, !ReconnectDriver.connectErrorBelongsToDriver(in: driver.state) {
            driver.detach()
            appTookTheError = true
            return
        }
        for event in events { driver.handle(event) }
    }

    /// The bridge's order on T_rdp: the error first, the sentinel last.
    func failConnect(code: Int) {
        session.connectError = NSError(domain: "Macdows.CRSession", code: code)
        tick([Sentinel()])
    }
}

@MainActor
@Suite("adr/0019 RB-1 (a′): the App leaves a driver leg's connect error to the driver")
struct ConnectErrorRoutingTests {

    @Test("the predicate: the driver's legs are .reconnecting and .waiting, nothing else")
    func predicateIsExact() {
        #expect(ReconnectDriver.connectErrorBelongsToDriver(in: .reconnecting(attempt: 0)))
        #expect(ReconnectDriver.connectErrorBelongsToDriver(in: .reconnecting(attempt: 3)))
        #expect(ReconnectDriver.connectErrorBelongsToDriver(in: .waiting(attempt: 1, delay: .seconds(2))))
        #expect(!ReconnectDriver.connectErrorBelongsToDriver(in: nil), "no driver")
        #expect(!ReconnectDriver.connectErrorBelongsToDriver(in: .idle), "a first connect")
        #expect(!ReconnectDriver.connectErrorBelongsToDriver(in: .live), "a live leg")
        for cause: ReconnectDriver.GiveUpCause in [.policy(.attemptsExhausted), .refusedByBridge(code: -5),
                                                   .policyRefused(attemptIndex: 0),
                                                   .certificateRejected(unsupportedRoute: false)] {
            #expect(!ReconnectDriver.connectErrorBelongsToDriver(in: .gaveUp(cause)), "\(cause)")
        }
    }

    @Test("a first connect's error is the App's: the session ends and the driver never sees the sentinel")
    func firstConnectIsTheApps() throws {
        let app = try AppTick()
        app.failConnect(code: 131_078)
        #expect(app.appTookTheError)
        #expect(app.driver.state == .idle)
        #expect(app.driver.isAttached == false)
        #expect(app.clock.requested.isEmpty)
    }

    @Test("a live leg's error is the App's, the decode-path refusal included")
    func liveLegIsTheApps() throws {
        let app = try AppTick()
        app.tick([Handshake()])
        #expect(app.driver.state == .live)
        app.failConnect(code: -5)
        #expect(app.appTookTheError)
        #expect(app.driver.state == .live)
        #expect(app.driver.lastGiveUpCause == nil)
    }

    @Test("a transient failure on a driver leg reaches the driver, which backs off, and later ticks leave the stale error alone")
    func transientDriverLegBacksOff() throws {
        let app = try AppTick()
        app.tick([Handshake()])
        app.tick([Sentinel()])
        app.clock.fireNext()
        #expect(app.driver.state == .reconnecting(attempt: 0))

        app.failConnect(code: 131_080)
        #expect(!app.appTookTheError)
        let expected = try ReconnectPolicy.delay(forFailedAttempt: 1)
        #expect(app.driver.state == .waiting(attempt: 1, delay: expected))

        // The backstop timer ticks through the back-off with the error still on the session.
        app.tick([])
        app.tick([])
        #expect(!app.appTookTheError)
        #expect(app.driver.state == .waiting(attempt: 1, delay: expected))

        // The retry's restart clears the error, and that leg comes up.
        app.clock.fireNext()
        #expect(app.session.lastConnectError == nil)
        app.tick([Handshake()])
        #expect(app.driver.state == .live)
        #expect(app.session.restartCount == 2)
    }

    /// adr/0019 RB-1 D-B(iv) reconsidered (owner 2026-10-07): ERRINFO_RPC_INITIATED_DISCONNECT
    /// (65537, seen on a host restart) is one failed attempt, not a refusal. The driver's step 1
    /// only asks `ConnectFailureClass`, so the leg backs off exactly as a CONNECT-class transient
    /// one does, and the leg-failed line keeps its shape with the new code and class.
    @Test("an ERRINFO RPC_INITIATED_DISCONNECT (65537) on a driver leg backs off instead of giving up")
    func errinfoRpcInitiatedDisconnectOnDriverLegBacksOff() throws {
        let app = try AppTick()
        app.tick([Handshake()])
        app.tick([Sentinel()])
        app.clock.fireNext()
        #expect(app.driver.state == .reconnecting(attempt: 0))

        app.failConnect(code: 65_537)
        #expect(!app.appTookTheError)
        let expected = try ReconnectPolicy.delay(forFailedAttempt: 1)
        #expect(app.driver.state == .waiting(attempt: 1, delay: expected))
        #expect(app.driver.lastGiveUpCause == nil)

        app.clock.fireNext()
        app.tick([Handshake()])
        #expect(app.driver.state == .live)
        #expect(app.session.restartCount == 2)

        let buffer = DiagnosticLogBuffer(capacity: 10)
        let logger = DiagnosticLogger(subsystem: "dev.haru.macdows.tests", category: "Connect", buffer: buffer)
        let error = NSError(domain: "Macdows.CRSession", code: 65_537)
        ConnectChain.logLegFailure(error, as: ConnectFailureClass.classify(domain: error.domain, code: error.code),
                                   to: logger)
        #expect(buffer.snapshot().map(\.line.message) == [
            "[connect] leg-failed: domain=Macdows.CRSession code=65537 class=transient",
        ])
    }

    @Test("a final failure on a driver leg reaches the driver, which gives up with the code")
    func finalDriverLegGivesUp() throws {
        let app = try AppTick()
        app.tick([Handshake()])
        app.tick([Sentinel()])
        app.clock.fireNext()

        app.failConnect(code: 131_081)
        #expect(!app.appTookTheError)
        #expect(app.driver.state == .gaveUp(.refusedByBridge(code: 131_081)))

        // From here the App's branch would take a stale error again (the give-up branch has
        // already ended the session in the App; the predicate agrees).
        #expect(!ReconnectDriver.connectErrorBelongsToDriver(in: app.driver.state))
    }

    @Test("transient failures on every driver leg end in attempts-exhausted, never in the App's branch")
    func transientDriverLegsExhaust() throws {
        let app = try AppTick()
        app.tick([Handshake()])
        app.tick([Sentinel()])
        for _ in 0..<(ReconnectPolicy.maxAttempts - 1) {
            app.clock.fireNext()
            app.failConnect(code: 131_078)
            #expect(!app.appTookTheError)
            // A backstop tick inside the back-off; after the give-up the App's give-up branch has
            // already ended the session, so there is no further tick to take.
            if case .waiting = app.driver.state {
                app.tick([])
                #expect(!app.appTookTheError)
            }
        }
        #expect(app.driver.state == .gaveUp(.policy(.attemptsExhausted)))
        #expect(app.session.restartCount == ReconnectPolicy.maxAttempts - 1)
    }
}

@MainActor
@Suite("adr/0019 RB-1: the [connect] leg-failed line")
struct ConnectLegFailedLineTests {

    @Test("domain, code and class, nothing else, and the export passes it unchanged")
    func lineShape() {
        let buffer = DiagnosticLogBuffer(capacity: 10)
        let logger = DiagnosticLogger(subsystem: "dev.haru.macdows.tests", category: "Connect", buffer: buffer)
        let error = NSError(domain: "Macdows.CRSession", code: 131_080,
                            userInfo: [NSLocalizedDescriptionKey: "freerdp_connect failed: fixture description"])
        ConnectChain.logLegFailure(error, as: .transient, to: logger)
        ConnectChain.logLegFailure(NSError(domain: "Macdows.CRSession", code: 131_081), as: .final, to: logger)
        let lines = buffer.snapshot().map(\.line)
        #expect(lines.map(\.message) == [
            "[connect] leg-failed: domain=Macdows.CRSession code=131080 class=transient",
            "[connect] leg-failed: domain=Macdows.CRSession code=131081 class=final",
        ])
        let exported = DiagnosticExportFilter.export(lines, includeAccountAndKeyWitness: false, homeDirectory: nil).exported
        #expect(exported.count == 2)
        #expect(exported.allSatisfy { $0.hasSuffix("class=transient") || $0.hasSuffix("class=final") })
        #expect(exported.allSatisfy { !$0.contains("fixture description") })
    }
}

// MARK: - The certificate rejection on a driver leg has one writer per surface

private func routingRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func routingCodeOnly(_ relative: String) throws -> String {
    let raw = try String(contentsOf: routingRepoRoot().appendingPathComponent(relative), encoding: .utf8)
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func routingBody(of start: String, endingAt end: String, in code: String) throws -> Substring {
    let lower = try #require(code.range(of: start), "not found: \(start)").lowerBound
    let upper = try #require(code[lower...].range(of: end), "not found after \(start): \(end)").lowerBound
    return code[lower..<upper]
}

/// RB-1 implementation item (I-3): once (a′) lets a driver leg's certificate rejection reach the
/// driver, the same event has two consumers -- the driver's `.gaveUp(.certificateRejected)` state
/// (shell and banners) and `reviewSessionEnd`'s certificate question. They do not stack: the
/// presenter gives a certificate give-up NO connection banner and no Remote windows note
/// (`SessionBannerTests` holds those values), so the session banners only remove the reconnecting
/// banner, and the certificate banner / sheet is written by `presentCertificateQuestion` alone,
/// called from `reviewSessionEnd` alone.
@Suite("adr/0019 RB-1: a certificate rejection on a driver leg has one writer for its banner and sheet")
struct CertificateRejectionSingleWriterTests {

    private static let appDelegate = "App/Macdows/AppDelegate.swift"

    @Test("the driver's give-up shows no connection banner; the certificate question is asked from the session-end review only")
    @MainActor
    func oneWriter() throws {
        #expect(ShellReconnectPresenter.connectionBanner(for: .gaveUp(.certificateRejected(unsupportedRoute: false)), hostTitle: "h") == nil)
        #expect(ShellReconnectPresenter.connectionBanner(for: .gaveUp(.certificateRejected(unsupportedRoute: true)), hostTitle: "h") == nil)

        let code = try routingCodeOnly(Self.appDelegate)
        #expect(code.components(separatedBy: "presentCertificateQuestion(").count - 1 == 2, "one declaration, one call")
        let review = try routingBody(of: "private func reviewSessionEnd(", endingAt: "private func sessionPresenceChanged(", in: code)
        #expect(review.contains("presentCertificateQuestion(record, verdict: verdict, session: ended, rejection: rejection)"))
        let banners = try routingBody(of: "private func applySessionBanners(", endingAt: "private func sessionBannerModel(", in: code)
        for writer in ["presentCertificateQuestion(", "presentCertificateSheet(", "\"certificate\""] {
            #expect(!banners.contains(writer), "the session banners write \(writer)")
        }
    }
}

// MARK: - RB-2 gate r1 fold-in: the source pins no behaviour test in this bundle can carry

/// Three claims that live in source text only (`AppDelegate` is not compiled into this bundle, and
/// the driver writes its `[connect] leg-failed:` line to the default logger, which no test reads):
///
///  - F-1 (gate r1 I-3 / U-2): a driver leg that gives up before the chain went live -- a final
///    code at once, or transient codes until attempts-exhausted -- already has its give-up banner,
///    so `reviewSessionEnd` still records `.connectFailed` but shows no connect-failure banner on
///    top. The condition sits INSIDE the branch: folded into the outer condition it would send the
///    give-up end to neither branch and lose the record.
///  - F-3 (gate r1 I-2): the driver writes the leg-failed line from step 1 only, once, after step 0
///    has returned for a certificate rejection and before the final class gives up.
///  - F-4 (gate r1 m-3): `AppTick`, the re-stated drain-tick gate the routing tests above drive,
///    asks the same predicate on the driver's own state; the real gate is pinned by
///    `AppDelegateReconnectWiringPinTests.theConnectErrorBranchEndsTheSession`, this pins the copy.
@Suite("RB-2 gate r1 fold-in: the give-up banner's one writer, the leg-failed call site, the routing copy")
struct ConnectErrorRoutingSourcePinTests {

    private static let appDelegate = "App/Macdows/AppDelegate.swift"
    private static let reconnectDriver = "App/SessionControl/ReconnectDriver.swift"
    private static let routingTests = "App/MacdowsAppTests/ConnectErrorRoutingTests.swift"

    private static func occurrences(of needle: String, in haystack: some StringProtocol) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("F-1: a give-up end before live records connect-failed and leaves the banner to the give-up")
    func reviewSessionEndLeavesTheGiveUpBannerAlone() throws {
        let code = try routingCodeOnly(Self.appDelegate)
        let review = try routingBody(of: "private func reviewSessionEnd(", endingAt: "private func sessionPresenceChanged(", in: code)
        #expect(Self.occurrences(
            of: "if !chainReachedLive, let error = ended.lastConnectError { hostStore.note(.connectFailed, for: host) "
                + "if !endingByGiveUp { showConnectFailure(",
            in: review) == 1)
        #expect(Self.occurrences(of: "showConnectFailure(", in: code) == 2, "one declaration, one call")
    }

    @Test("F-3: the driver writes the leg-failed line once, between step 0's return and the final give-up")
    func legFailedLineIsWrittenFromStepOneOnly() throws {
        let code = try routingCodeOnly(Self.reconnectDriver)
        let call = "ConnectChain.logLegFailure(error, as: failureClass)"
        #expect(Self.occurrences(of: call, in: code) == 1)
        #expect(Self.occurrences(of: "logLegFailure(", in: code) == 1, "no other call shape")
        let body = try routingBody(of: "private func noteDisconnect() {", endingAt: "private func scheduleRetry(", in: code)
        let stepZero = try #require(body.range(of: "giveUp(.certificateRejected("), "step 0's give-up")
        let stepZeroReturn = try #require(body[stepZero.upperBound...].range(of: "return }"), "step 0's return")
        let logged = try #require(body.range(of: call), "the call inside noteDisconnect")
        let finalBranch = try #require(body.range(of: "if failureClass == .final {"), "step 1's final branch")
        #expect(stepZeroReturn.upperBound <= logged.lowerBound, "after step 0 has returned")
        #expect(logged.upperBound <= finalBranch.lowerBound, "before the final class gives up")
    }

    @Test("F-4: AppTick asks the production predicate on the driver's own state, once")
    func routingCopyAsksTheRealPredicate() throws {
        let code = try routingCodeOnly(Self.routingTests)
        let tick = try routingBody(of: "func tick(_ events: [CRDPEvent]) {", endingAt: "func failConnect(code: Int) {", in: code)
        #expect(Self.occurrences(of: "!ReconnectDriver.connectErrorBelongsToDriver(in: driver.state)", in: tick) == 1)
        #expect(Self.occurrences(of: "connectErrorBelongsToDriver(", in: tick) == 1)
    }
}
