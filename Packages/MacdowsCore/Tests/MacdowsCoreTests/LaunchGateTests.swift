import Testing

@testable import MacdowsCore

/// ADR-0025 §3.1 item 3: the launch gate opens only when there is a session and it is live.
@Suite("LaunchGate: a launch needs a session and a live connection")
struct LaunchGateTests {

    @Test("all four combinations: only (session, live) opens the gate")
    func truthTable() {
        #expect(LaunchGate.canLaunch(hasSession: true, isLive: true))
        #expect(!LaunchGate.canLaunch(hasSession: true, isLive: false))
        #expect(!LaunchGate.canLaunch(hasSession: false, isLive: true))
        #expect(!LaunchGate.canLaunch(hasSession: false, isLive: false))
    }
}
