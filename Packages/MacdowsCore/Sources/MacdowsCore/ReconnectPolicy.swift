import Foundation

/// adr/0019 §1 R-1 (reconnect policy ownership is not yet ruled — the owner is choosing between
/// "A" application-layer reconnect, "F" FreeRDP's own `AutoReconnectionEnabled` loop and "AF",
/// A first with F as a later optimisation) and §2
/// lane A ("reconnect policy pure function": attempt index in, backoff duration or give-up out;
/// no wiring). This type is deliberately just the math: a namespace of pure functions with no
/// instance, no stored state, no I/O, and no randomness. Wiring it into `CRSession` (or any other
/// driver) is lane B and is explicitly out of scope here.
///
/// No jitter: determinism is this type's contract, so the same failed-attempt index always
/// produces the same answer. If a driver wants jitter (e.g. to avoid a reconnect thundering
/// herd), that is a driver concern for lane B to decide and add on top — it does not belong in
/// this pure policy.
public enum ReconnectPolicy {
    /// Upper bound on reconnect attempts. Provisional until the R-1 ruling (adr/0019 §1); wiring
    /// is lane B.
    public static let maxAttempts: Int = 5

    /// Backoff for the first failed attempt (`n == 0`).
    public static let baseDelay: Duration = .seconds(1)

    /// Backoff ceiling; no failed-attempt index produces a longer delay than this.
    public static let maxDelay: Duration = .seconds(16)

    /// Why `decision(afterFailedAttempt:)` returned `.giveUp`.
    public enum GiveUpReason: Equatable, Sendable {
        case attemptsExhausted
    }

    /// What a driver should do after a failed connection attempt.
    public enum Decision: Equatable, Sendable {
        case retry(after: Duration)
        case giveUp(reason: GiveUpReason)
    }

    /// Thrown when a failed-attempt index is not a valid attempt count.
    public enum PolicyError: Error, Equatable, Sendable {
        case invalidAttemptIndex(Int)
    }

    /// The backoff to wait before retrying after the `n`-th failed attempt, `n` zero-based (the
    /// first failure is `n == 0`). Negative `n` is refused, not clamped: `n < 0` throws
    /// `PolicyError.invalidAttemptIndex(n)` rather than being treated as attempt 0.
    ///
    /// The result is `min(baseDelay * 2^n, maxDelay)`. The exponent is capped before the shift
    /// (`1 << min(n, 30)`) so that any legal `n`, however large, never traps — the result simply
    /// saturates at `maxDelay`.
    public static func delay(forFailedAttempt n: Int) throws -> Duration {
        guard n >= 0 else { throw PolicyError.invalidAttemptIndex(n) }
        let cappedExponent = min(n, 30)
        let multiplier = 1 << cappedExponent
        let scaled = baseDelay * multiplier
        return min(scaled, maxDelay)
    }

    /// What to do after the `n`-th failed attempt, `n` zero-based. Same validation as
    /// `delay(forFailedAttempt:)`, throwing the same error for the same invalid input.
    ///
    /// Retries while there is at least one attempt left (`n + 1 < maxAttempts`); once attempts
    /// are exhausted, gives up with `.attemptsExhausted`. With `maxAttempts == 5`, `n` in
    /// `0..<4` retries (1s, 2s, 4s, 8s) and `n >= 4` gives up.
    public static func decision(afterFailedAttempt n: Int) throws -> Decision {
        guard n >= 0 else { throw PolicyError.invalidAttemptIndex(n) }
        guard n + 1 < maxAttempts else {
            return .giveUp(reason: .attemptsExhausted)
        }
        return .retry(after: try delay(forFailedAttempt: n))
    }
}
