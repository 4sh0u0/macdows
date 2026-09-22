import Testing

@testable import MacdowsCore

/// adr/0019 §2 lane A: `ReconnectPolicy` is a pure function of the failed-attempt index, so
/// every test here is offline and deterministic — no session, no driver, no real host.
@Suite("ReconnectPolicy: attempt index to backoff / give-up")
struct ReconnectPolicyTests {

    // MARK: Zero-based starting point

    @Test("the first failed attempt (n == 0) retries after baseDelay")
    func firstFailureRetriesAfterBaseDelay() throws {
        #expect(try ReconnectPolicy.decision(afterFailedAttempt: 0) == .retry(after: ReconnectPolicy.baseDelay))
    }

    // MARK: Give-up boundary

    @Test("the give-up boundary is exact: retry through n == maxAttempts - 2, give up from n == maxAttempts - 1")
    func giveUpBoundaryIsExact() throws {
        let lastRetryIndex = ReconnectPolicy.maxAttempts - 2
        let firstGiveUpIndex = ReconnectPolicy.maxAttempts - 1

        let lastRetry = try ReconnectPolicy.decision(afterFailedAttempt: lastRetryIndex)
        guard case .retry = lastRetry else {
            Issue.record("expected .retry at n == maxAttempts - 2, got \(lastRetry)")
            return
        }

        #expect(
            try ReconnectPolicy.decision(afterFailedAttempt: firstGiveUpIndex)
                == .giveUp(reason: .attemptsExhausted)
        )
        #expect(
            try ReconnectPolicy.decision(afterFailedAttempt: ReconnectPolicy.maxAttempts)
                == .giveUp(reason: .attemptsExhausted)
        )
    }

    // MARK: Invalid input is refused, not clamped

    @Test("a negative failed-attempt index is refused, not clamped, by delay(forFailedAttempt:)")
    func delayRefusesNegativeIndex() {
        #expect(throws: ReconnectPolicy.PolicyError.invalidAttemptIndex(-1)) {
            try ReconnectPolicy.delay(forFailedAttempt: -1)
        }
        #expect(throws: ReconnectPolicy.PolicyError.invalidAttemptIndex(Int.min)) {
            try ReconnectPolicy.delay(forFailedAttempt: Int.min)
        }
    }

    @Test("a negative failed-attempt index is refused, not clamped, by decision(afterFailedAttempt:)")
    func decisionRefusesNegativeIndex() {
        #expect(throws: ReconnectPolicy.PolicyError.invalidAttemptIndex(-1)) {
            try ReconnectPolicy.decision(afterFailedAttempt: -1)
        }
        #expect(throws: ReconnectPolicy.PolicyError.invalidAttemptIndex(Int.min)) {
            try ReconnectPolicy.decision(afterFailedAttempt: Int.min)
        }
    }

    // MARK: Backoff is monotonic

    @Test("backoff is monotonically non-decreasing across consecutive failed attempts")
    func backoffIsMonotonic() throws {
        for n in 0..<(ReconnectPolicy.maxAttempts - 1) {
            let here = try ReconnectPolicy.delay(forFailedAttempt: n)
            let next = try ReconnectPolicy.delay(forFailedAttempt: n + 1)
            #expect(here <= next, "delay(\(n)) = \(here) should be <= delay(\(n + 1)) = \(next)")
        }
    }

    // MARK: The doubling curve itself is pinned (gate r1 m-1: a `* 2` exponent mutant survived
    // the monotonic + cap tests, so the 1 s / 2 s / 4 s / 8 s values need their own pin)

    @Test("delays for failed attempts 1, 2 and 3 are exactly 2 s, 4 s and 8 s")
    func doublingCurveIsPinned() throws {
        #expect(try ReconnectPolicy.delay(forFailedAttempt: 1) == .seconds(2))
        #expect(try ReconnectPolicy.delay(forFailedAttempt: 2) == .seconds(4))
        #expect(try ReconnectPolicy.delay(forFailedAttempt: 3) == .seconds(8))
    }

    // MARK: Cap never traps

    @Test("the exponent cap keeps delay(forFailedAttempt:) from trapping, saturating at maxDelay")
    func capNeverTraps() throws {
        #expect(try ReconnectPolicy.delay(forFailedAttempt: 1_000) == ReconnectPolicy.maxDelay)
        #expect(try ReconnectPolicy.delay(forFailedAttempt: Int.max) == ReconnectPolicy.maxDelay)
    }

    // MARK: Constants are pinned

    @Test("the provisional constants are pinned; changing them requires an adr/0019 ruling")
    func constantsArePinned() {
        #expect(ReconnectPolicy.maxAttempts == 5)
        #expect(ReconnectPolicy.baseDelay == .seconds(1))
        #expect(ReconnectPolicy.maxDelay == .seconds(16))
    }

    // MARK: Determinism

    @Test("the same failed-attempt index always answers the same way, and decision's retry delay matches delay(forFailedAttempt:)")
    func sameIndexIsDeterministic() throws {
        for n in 0..<ReconnectPolicy.maxAttempts {
            let delayFirst = try ReconnectPolicy.delay(forFailedAttempt: n)
            let delaySecond = try ReconnectPolicy.delay(forFailedAttempt: n)
            #expect(delayFirst == delaySecond)

            let decision = try ReconnectPolicy.decision(afterFailedAttempt: n)
            if case .retry(let after) = decision {
                #expect(after == delayFirst)
            }
        }
    }
}
