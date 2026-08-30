import Testing
@testable import MacdowsCore

/// adr/0011 §5 item 7's acceptance ("服务端 caps 缺 INPUT_FLAG_UNICODE 时，降级告警恰好一次且无
/// 静默丢字"), asserted offline: the live-host half of that item needs a Windows host with
/// `INPUT_FLAG_UNICODE` removed from its Input Capability Set (constructible via
/// `CRSession.forceUnicodeInputUnsupported`), but the "exactly once" and "nothing silently
/// lost" properties are pure state-machine facts and belong here.
@Suite("UnicodeInputDegradationGate")
struct UnicodeInputDegradationGateTests {
    @Test("supported: every commit forwards, nothing dropped, nothing warned")
    func supportedIsPureNoOp() {
        let gate = UnicodeInputDegradationGate()
        for _ in 0..<10 {
            #expect(gate.evaluateCommit(readCapability: { true }) == .forward)
        }
        #expect(gate.unicodeInputSupported == true)
        #expect(gate.droppedCommits == 0)
        #expect(gate.warningsEmitted == 0)
    }

    @Test("unsupported: warns on the first drop only, across many consecutive drops")
    func unsupportedWarnsExactlyOnce() {
        let gate = UnicodeInputDegradationGate()
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: true))
        for _ in 0..<19 {
            #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: false))
        }
        #expect(gate.warningsEmitted == 1)
    }

    @Test("unsupported: every dropped commit is counted, one per commit regardless of length")
    func dropCountIsExact() {
        let gate = UnicodeInputDegradationGate()
        for _ in 0..<7 {
            _ = gate.evaluateCommit(readCapability: { false })
        }
        #expect(gate.droppedCommits == 7)
        #expect(gate.unicodeInputSupported == false)
    }

    @Test("the capability is read exactly once per connection, no matter how many commits")
    func capabilityIsReadOncePerConnection() {
        let gate = UnicodeInputDegradationGate()
        var reads = 0
        for _ in 0..<5 {
            _ = gate.evaluateCommit(readCapability: {
                reads += 1
                return false
            })
        }
        #expect(reads == 1)

        // ... and once more for the next connection, never again within it.
        gate.reset()
        for _ in 0..<5 {
            _ = gate.evaluateCommit(readCapability: {
                reads += 1
                return false
            })
        }
        #expect(reads == 2)
    }

    @Test("the capability is not read at all until a commit actually arrives")
    func capabilityIsNotReadWithoutACommit() {
        let gate = UnicodeInputDegradationGate()
        #expect(gate.unicodeInputSupported == nil)
        #expect(gate.warningsEmitted == 0)
        #expect(gate.droppedCommits == 0)
    }

    @Test("reset re-arms the one-warning budget for the new connection")
    func resetReArmsTheWarning() {
        let gate = UnicodeInputDegradationGate()
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: true))
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: false))

        gate.reset()
        #expect(gate.unicodeInputSupported == nil)
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: true))
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: false))
        #expect(gate.warningsEmitted == 2)
    }

    @Test("counters are cumulative across resets, so a post-shutdown read sees real totals")
    func countersSurviveReset() {
        let gate = UnicodeInputDegradationGate()
        for _ in 0..<3 { _ = gate.evaluateCommit(readCapability: { false }) }
        gate.reset()
        for _ in 0..<4 { _ = gate.evaluateCommit(readCapability: { false }) }
        gate.reset() // the teardown a post-shutdown diagnostics read happens after

        #expect(gate.droppedCommits == 7)
        #expect(gate.warningsEmitted == 2)
        #expect(gate.unicodeInputSupported == nil)
    }

    @Test("a reconnect onto a supported server forwards again, with the old totals intact")
    func resetCanFlipToSupported() {
        let gate = UnicodeInputDegradationGate()
        for _ in 0..<2 { _ = gate.evaluateCommit(readCapability: { false }) }
        gate.reset()

        #expect(gate.evaluateCommit(readCapability: { true }) == .forward)
        #expect(gate.evaluateCommit(readCapability: { true }) == .forward)
        #expect(gate.droppedCommits == 2)
        #expect(gate.warningsEmitted == 1)
    }

    @Test("a mid-connection capability flip is ignored -- the first answer is the connection's")
    func cachedAnswerWinsWithinAConnection() {
        // adr/0011 §2 reads the capability once per connection on purpose; a source that
        // later changes its mind (CRSession's own property is reset to NO at -start, and a
        // stale read of it must never re-enable a lane this gate already disabled) must not
        // be able to reopen the IME lane mid-connection.
        let gate = UnicodeInputDegradationGate()
        #expect(gate.evaluateCommit(readCapability: { false }) == .drop(warn: true))
        #expect(gate.evaluateCommit(readCapability: { true }) == .drop(warn: false))
        #expect(gate.droppedCommits == 2)
    }
}
