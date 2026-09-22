import Foundation
import MacdowsCore

/// Decides whether and when a dropped session reconnects, and performs the reconnect.
///
/// adr/0019 §2 lane B. Three pieces, deliberately kept apart:
///
///  - the MATH is `MacdowsCore.ReconnectPolicy` (lane A) — a pure function, attempt index in,
///    back-off `Duration` or give-up out, no state and no clock;
///  - the STEP is `-[CRSession restartForReconnectPreparing:]` — shutdown, then the caller's
///    per-connection re-take, then start, in an order the type enforces;
///  - the DECISION — this class. It owns exactly one thing neither of the other two can: the
///    state machine that turns drained events into calls on the other two.
///
/// ## What it reacts to, and why those are the right signals
///
/// There is no "connected" event to react to. `crdpq`'s event enum has no such member, and
/// `CRDPQ_EVENT_DISCONNECTED` carries no payload and no reason at all — the same sentinel is
/// posted for a server-side drop, for a connect that never completed, and for a shutdown this
/// side asked for. So the driver reads three signals and never guesses:
///
///  1. `CRSession.lastConnectError` — non-nil means the bridge itself refused this connection
///     (DNS/TCP/TLS/NLA, or the RDPGFX decode-path refusal of ADR-0017 §4 A2). Retrying a refusal
///     on a back-off is how a client spends five minutes failing at something that failed for a
///     reason; the driver gives up immediately and hands the cause out for the UI to show.
///  2. `CRSession.teardownInitiated` — this side asked for the shutdown. The driver must not
///     "reconnect" a session its owner is deliberately closing, including the one `-dealloc`
///     closes and the one `applicationWillTerminate` closes.
///  3. `CRDPEventKindHandshakeFlags` — the earliest evidence a connection is actually working
///     (the RAIL channel completed its handshake). This is what resets the attempt count, and it
///     is deliberately NOT "`-restartForReconnectPreparing:` returned YES": that only means the
///     RDP thread was spawned, which is true of every attempt that will go on to fail.
///
/// ## Not wired
///
/// Nothing constructs this class. Lane B ships it as "exists, nobody attaches it", the same shape
/// lane A's `ReconnectPolicy` shipped in, and `ReconnectSemanticsPinTests` holds that as a checked
/// fact. Wiring is lane D's, for a reason worth stating: a session that silently reconnects under
/// a UI that was never told is worse than one that stays down — the App's Connect button is
/// disabled the moment it is pressed and re-enabled only on a connect error, so the driver alone
/// would leave a working session behind a dead button and a status line that lies. `onStateChange`
/// is the seam D consumes; `topologyRefresh` is the seam lane C fills.
@MainActor
final class ReconnectDriver {

    /// Where the driver is, as one value. `Equatable` so a consumer can diff rather than latch.
    ///
    /// `attempt` throughout is the ZERO-BASED failed-attempt index — the same `n` that
    /// `ReconnectPolicy.delay(forFailedAttempt:)` takes, not a human-facing "attempt 1 of 5". The
    /// first retry is `attempt: 0`. Using the policy's own index here means the log line, the
    /// state and the policy call can never disagree about which attempt is which.
    enum State: Equatable {
        /// Nothing is scheduled and nothing is in progress: the starting value, and (gate r1 I-1)
        /// where the driver stands down to when a scheduled retry is abandoned because the owner
        /// tore the session down or detached the driver in the meantime. It has no `[reconnect]`
        /// line -- the frozen line shape names four states and this is not one of them -- so a
        /// stand-down reaches a consumer through `onStateChange` and not through the log.
        case idle
        /// A connection completed its RAIL handshake. Attempt count is zero.
        case live
        /// A retry is scheduled. `delay` is what the policy asked for, kept in the state so a
        /// consumer (and the log line) reports the policy's number rather than a re-derived one.
        case waiting(attempt: Int, delay: Duration)
        /// `-restartForReconnectPreparing:` has run for `attempt`; waiting for a handshake or the
        /// next disconnect to say which way it went.
        case reconnecting(attempt: Int)
        /// Terminal until a handshake proves otherwise. The driver schedules nothing more.
        case gaveUp(GiveUpCause)
    }

    /// Why the driver stopped. A driver-local type: `CRSession` knows nothing about a reconnect
    /// policy and `ReconnectPolicy` knows nothing about a bridge, so the union of their two
    /// reasons belongs to the only layer that sees both.
    enum GiveUpCause: Equatable {
        /// The back-off policy said stop — today, only "attempts exhausted".
        case policy(ReconnectPolicy.GiveUpReason)
        /// The bridge refused the connection; `code` is `CRSession.lastConnectError`'s code (the
        /// `Macdows.CRSession` domain's own small negative codes).
        case refusedByBridge(code: Int)
        /// The policy rejected the attempt index itself. Unreachable by construction — the index
        /// starts at zero and only ever increments, and `ReconnectPolicy` refuses only negatives —
        /// but it is a thrown error, and a driver that cannot get a decision must not invent one.
        /// Reported honestly rather than folded into `.policy(.attemptsExhausted)`, which would be
        /// a diagnostic that lies about what happened.
        case policyRefused(attemptIndex: Int)
    }

    // MARK: - Dependencies

    private let session: CRSession
    private let registry: RemoteWindowRegistry
    private let clock: any ReconnectClock

    // MARK: - Seams

    /// Lane C's hook: re-take the display topology and tell the server about it, in the window
    /// between the shutdown and the next connect (adr/0015 §5.A.4).
    ///
    /// `nil` — the lane-B default — means the next connection reuses the desktop size and anchor
    /// the last one froze. That is not a new failure mode: it is the existing "a display change
    /// since connect shows up as a whole-desktop offset" one, with its repair moved from "the next
    /// reconnect" to "the next reconnect after lane C lands". Registered as such, and the driver
    /// does not paper over it with a guess.
    var topologyRefresh: (() -> Void)?

    /// Lane D's hook: every state change, in order, on T_main. Called after `state` is updated, so
    /// a handler reading `state` sees the new value.
    var onStateChange: ((State) -> Void)?

    // MARK: - State

    private(set) var state: State = .idle

    /// The cause of the most recent give-up, kept after a later handshake moves `state` off
    /// `.gaveUp` — a status line wants "we gave up, then you reconnected manually" to stay
    /// legible. Never cleared.
    private(set) var lastGiveUpCause: GiveUpCause?

    /// How many connection attempts have failed since the last successful handshake. This is the
    /// `n` handed to `ReconnectPolicy`, so zero means "the next failure is the first one".
    private(set) var failedAttempts = 0

    /// Whether `attach()` has been called. Events are ignored until it has.
    ///
    /// Construction alone does nothing on purpose (there is no singleton, no auto-start and no
    /// `CRSession` back-reference that could build one): a driver has to be armed by whoever owns
    /// the session, and the fixture in `Tools/window-smoke` — which drives its own reconnects —
    /// does not even link this file.
    private(set) var isAttached = false

    private var pendingRetry: (any ReconnectClockTicket)?

    // MARK: - Lifecycle

    /// - Parameter clock: the back-off timer seam. The default is the real one; tests pass a
    ///   manually advanced clock.
    init(session: CRSession,
         registry: RemoteWindowRegistry,
         clock: any ReconnectClock = DispatchReconnectClock()) {
        self.session = session
        self.registry = registry
        self.clock = clock
    }

    /// Arms the driver. Until this is called, `handle(_:)` does nothing at all — not "does nothing
    /// visible", nothing: no policy call, no timer, no state change.
    func attach() {
        isAttached = true
    }

    /// Disarms the driver and drops any pending retry. Idempotent. The state is left where it is:
    /// detaching is not evidence about the connection, and a status line should keep showing
    /// whatever was last true.
    func detach() {
        isAttached = false
        cancelPendingRetry()
    }

    // MARK: - Event entry point

    /// Call once per drained event, in delivery order — the same shape as
    /// `RemoteWindowRegistry.handle(_:)`, and intended to be called beside it from the owner's
    /// drain handler. Every event kind other than the two below is ignored.
    func handle(_ event: CRDPEvent) {
        guard isAttached else { return }
        switch event.kind {
        case .handshakeFlags:
            noteConnectionIsLive()
        case .disconnected:
            noteDisconnect()
        default:
            break
        }
    }

    // MARK: - The two reactions

    private func noteConnectionIsLive() {
        cancelPendingRetry()
        failedAttempts = 0
        // Unconditional, including out of `.gaveUp`: a completed handshake is proof this
        // connection works, and a driver reporting "gave up" over a live session is the one lie a
        // status line cannot recover from. Nothing in this class produces that transition by
        // itself (it never retries after giving up) — it happens only when the owner reconnects by
        // some other route, which is exactly when staying in `.gaveUp` would be wrong.
        // `lastGiveUpCause` keeps the history.
        guard state != .live else { return }
        transition(to: .live)
    }

    private func noteDisconnect() {
        // ORDER IS THE CONTRACT here; each branch is a different question and they are not
        // interchangeable.

        // 1. Did the bridge refuse this connection? Then there is nothing to back off from: the
        //    same attempt will be refused the same way. Checked FIRST because a refusal also
        //    produces a disconnect sentinel (`crb_rdp_thread_main`'s epilogue publishes the error
        //    just before posting it), so any later branch would swallow it.
        if let error = session.lastConnectError {
            giveUp(.refusedByBridge(code: (error as NSError).code))
            return
        }

        // 2. Did WE ask for this? `-shutdownAndWait` sets `teardownInitiated` before it does
        //    anything, and the next `-start` clears it. Without this branch the driver would
        //    fight its owner's own shutdown — including `-dealloc`'s.
        if session.teardownInitiated {
            return
        }

        // 3. Terminal is terminal. Consulting the policy again after a give-up would restart the
        //    curve from the index it already rejected, once per further disconnect.
        if case .gaveUp = state {
            return
        }

        // 4. An unexpected disconnect. Ask the policy.
        let decision: ReconnectPolicy.Decision
        do {
            decision = try ReconnectPolicy.decision(afterFailedAttempt: failedAttempts)
        } catch {
            giveUp(.policyRefused(attemptIndex: failedAttempts))
            return
        }

        switch decision {
        case .giveUp(let reason):
            giveUp(.policy(reason))
        case .retry(let delay):
            scheduleRetry(after: delay, attempt: failedAttempts)
        }
    }

    // MARK: - Retrying

    private func scheduleRetry(after delay: Duration, attempt: Int) {
        // At most one retry outstanding. A second disconnect arriving while one is already
        // scheduled (the server dropping the same connection twice, or a duplicate drain) must not
        // become two reconnects.
        cancelPendingRetry()
        pendingRetry = clock.schedule(after: delay) { [weak self] in
            self?.performReconnect(attempt: attempt)
        }
        transition(to: .waiting(attempt: attempt, delay: delay))
    }

    private func performReconnect(attempt: Int) {
        // GATE r1 I-1 -- the timer edge, which is a second edge and not the event edge above.
        // `teardownInitiated` is checked in `noteDisconnect` only, and everything that tears a
        // session down (an app terminating, a Disconnect button, `-dealloc`) can happen AFTER a
        // retry was scheduled and BEFORE its timer fires. Without this guard the driver would walk
        // straight through that window and bring a session its owner had just closed back up --
        // `-shutdownAndWait` on an idle session, `prepareForReconnect()`, `-start`. Being detached
        // is checked here for the same reason and for one more: cancelling a `DispatchSourceTimer`
        // does not recall a handler block that has already been submitted to its queue, so the
        // production clock can lose that race even though `detach()` cancels correctly.
        //
        // Standing down to `.idle`: `.waiting` would be a claim that a retry is still coming, and
        // it is not. `.idle` emits no `[reconnect]` line (the frozen line shape names four states
        // and `idle` is not one of them), so this transition is visible to `onStateChange` but not
        // in the log -- registered rather than papered over by inventing a fifth state name.
        guard isAttached, !session.teardownInitiated else {
            cancelPendingRetry()
            if state != .idle {
                transition(to: .idle)
            }
            return
        }
        pendingRetry = nil
        // Counted BEFORE the attempt, not after: everything below this line is asynchronous past
        // `-start`, so if the count were bumped on the way out, a disconnect arriving during the
        // attempt would be judged against the index of the attempt that had just failed.
        failedAttempts = attempt + 1
        transition(to: .reconnecting(attempt: attempt))

        let restarted = session.restartForReconnect {
            // The order inside this block is `-restartForReconnectPreparing:`'s whole reason for
            // existing, and it matches the fixture's hand-written one: re-take the display
            // topology FIRST (lane C fills this in; nil today), then re-freeze the registry
            // against it. Reversed, the registry freezes against the old layout and the server is
            // then told about the new one — the divergence adr/0015 §5.A.4 forbids.
            self.topologyRefresh?()
            // adr/0012 §2: closes every window, drops the generation, re-freezes the topology, and
            // resets the focus gate to `.unmonitored` — which can only reopen on a real
            // MonitoredDesktop order from the new connection. No timeout fallback, and no replay
            // of buffered input into the new connection: both are deliberate, and both are
            // decisions this driver must not quietly reverse.
            self.registry.prepareForReconnect()
        }

        // `restarted == false` means either the shutdown was not clean or the `-start` fell
        // straight back to idle, and the two need different answers. Only the second is terminal,
        // and `lastConnectError` (which that `-start` cleared on entry and only a synchronous
        // failure could have set again by now) is what distinguishes them. An unclean shutdown
        // with a started thread is NOT a failure to react to: the connection is in progress, and
        // tearing it down again to retry would be the driver fighting itself.
        if !restarted, let error = session.lastConnectError {
            giveUp(.refusedByBridge(code: (error as NSError).code))
            return
        }
        // Otherwise stay in `.reconnecting` and let the events decide: a handshake means live, a
        // disconnect means this attempt failed and the policy gets the next index.
    }

    private func cancelPendingRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
    }

    private func giveUp(_ cause: GiveUpCause) {
        // The first cause is the one that stands: a give-up already cancelled everything, so a
        // later disconnect cannot add information, only overwrite it with something less specific.
        if case .gaveUp = state { return }
        cancelPendingRetry()
        lastGiveUpCause = cause
        transition(to: .gaveUp(cause))
    }

    // MARK: - State changes and the log line

    private func transition(to next: State) {
        state = next
        if let line = Self.logLine(for: next, failedAttempts: failedAttempts) {
            print(line)
        }
        onStateChange?(next)
    }

    /// The one diagnostic line this driver emits, as a pure function so its exact shape can be
    /// pinned by a test instead of by capturing stdout.
    ///
    /// FROZEN SHAPE — `[reconnect] attempt=<n> delay-ms=<d> state=<waiting|reconnecting|live|gaveup> cause=<...>`.
    /// Four fields, always all four, always in that order; `delay-ms` carries a value only while
    /// waiting and `cause` only after a give-up, and both are present-but-empty otherwise so that a
    /// field-position parser never has to deal with a short line. This is the judgement unit a
    /// future live-host acceptance run will read, and the reason it is frozen now is that a
    /// judgement unit changed after the fact makes every earlier run unreadable.
    ///
    /// `print`, not `os_log`: the harness that captures a run's output tees stdout to a file, and
    /// unified-log entries do not land in it.
    ///
    /// Returns `nil` for `.idle`, which is a starting value rather than a transition and therefore
    /// has no line — the frozen shape enumerates four state names and `idle` is deliberately not
    /// one of them.
    static func logLine(for state: State, failedAttempts: Int) -> String? {
        let name: String
        var attempt = ""
        var delayMS = ""
        var cause = ""
        switch state {
        case .idle:
            return nil
        case .live:
            name = "live"
        case .waiting(let n, let delay):
            name = "waiting"
            attempt = String(n)
            delayMS = String(milliseconds(delay))
        case .reconnecting(let n):
            name = "reconnecting"
            attempt = String(n)
        case .gaveUp(let reason):
            name = "gaveup"
            attempt = String(failedAttempts)
            cause = token(for: reason)
        }
        return "[reconnect] attempt=\(attempt) delay-ms=\(delayMS) state=\(name) cause=\(cause)"
    }

    /// Whole milliseconds, truncated. The policy's curve is whole seconds, so truncation is exact
    /// for every value this can actually be handed; it is defined here anyway so a future
    /// sub-millisecond delay prints a number rather than a surprise.
    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }

    /// Hyphenated, lower-case, no spaces — one `cause=` field, greppable, never ambiguous about
    /// where the field ends.
    static func token(for cause: GiveUpCause) -> String {
        switch cause {
        case .policy(.attemptsExhausted):
            return "attempts-exhausted"
        case .refusedByBridge(let code):
            return "refused-by-bridge:\(code)"
        case .policyRefused(let index):
            return "policy-refused-index:\(index)"
        }
    }
}
