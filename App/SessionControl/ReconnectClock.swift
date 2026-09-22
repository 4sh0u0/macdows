import Foundation

/// The "wait this long, then do this on T_main" seam `ReconnectDriver` backs its back-off with.
///
/// adr/0019 §2 lane B. It exists for one reason: the driver's whole contract is *when* it does
/// things, and a test that has to spend real seconds to observe a 1 s / 2 s / 4 s / 8 s back-off
/// curve is a test nobody will keep. The production implementation below wraps a
/// `DispatchSourceTimer` on the main queue; the test implementation records the `Duration` it was
/// handed and fires on demand, which turns "the second retry waits twice as long as the first"
/// into an equality assertion instead of a stopwatch.
///
/// Why not `Task.sleep`: the body has to run on T_main, and it has to be *cancellable from
/// T_main, synchronously*. `-[CRSession shutdownAndWait]` drains the control lane on its calling
/// thread and the window registry is T_main-only state (adr/0005 §3), so the reconnect step is
/// main-thread work by construction; a `Task` would add an actor hop whose ordering relative to
/// the next drained event is exactly the thing this driver must not leave to chance. A pending
/// retry also has to be cancellable the instant a give-up or a successful handshake happens, with
/// no possibility of the body running "one more time" afterwards -- `cancel()` on a suspended
/// dispatch source gives that; cancelling a `Task` gives it only at the next suspension point.
///
/// `AnyObject` and `@MainActor`: a clock is a thing with identity that outlives one call, and
/// everything on both sides of this protocol lives on T_main.
@MainActor
protocol ReconnectClock: AnyObject {
    /// Runs `body` after `delay`. The returned handle cancels that pending run and nothing else;
    /// dropping it without cancelling leaves the run scheduled (a caller that wants "cancel when
    /// I go away" must say so).
    ///
    /// A `delay` of zero or less runs `body` on the next turn of the main queue, never
    /// synchronously inside this call: a driver that re-entered itself from inside its own state
    /// transition would be a much harder thing to reason about than one that always yields first.
    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket
}

/// A pending `ReconnectClock.schedule(after:_:)`, cancellable exactly once.
///
/// Deliberately this project's own protocol rather than `Combine.Cancellable`: nothing else in
/// this directory imports Combine, and the one thing this type has to guarantee -- that after
/// `cancel()` returns, the body will not run -- is a stronger statement than `Cancellable`'s
/// documentation makes.
@MainActor
protocol ReconnectClockTicket: AnyObject {
    /// Cancels the pending run. Idempotent. After this returns, `body` will not run.
    func cancel()
}

/// The production clock: a one-shot `DispatchSourceTimer` per scheduled run, on the main queue.
///
/// One source per run rather than one reused source, because the driver never has more than one
/// retry outstanding and a fresh source makes "cancelled" unambiguous -- a cancelled source is
/// dead, so there is no state in which a stale rescheduling could resurrect it.
@MainActor
final class DispatchReconnectClock: ReconnectClock {

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.seconds(delay), leeway: .milliseconds(50))
        timer.setEventHandler {
            // The source is one-shot: cancel before running the body, so a body that schedules
            // the next retry can never be racing this source's own teardown. Already on the main
            // queue (the source's queue), hence the assumeIsolated rather than a hop.
            timer.cancel()
            MainActor.assumeIsolated { body() }
        }
        timer.resume()
        return Ticket(timer: timer)
    }

    /// `Duration` -> seconds as a `Double`, via its exact `(seconds, attoseconds)` components
    /// rather than any lossy convenience: the values this clock is handed come from
    /// `MacdowsCore.ReconnectPolicy`, which is defined in `Duration` and is the source of truth
    /// for the curve.
    ///
    /// Negative durations collapse to zero -- see the protocol's own note on a zero delay.
    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(0, value)
    }

    private final class Ticket: ReconnectClockTicket {
        private var timer: (any DispatchSourceTimer)?

        init(timer: any DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            // Dropping the reference as well as cancelling: `cancel()` on an already-cancelled
            // source is harmless, but a nil here makes double-cancel free rather than merely safe,
            // and makes "this ticket is spent" readable in a debugger.
            timer?.cancel()
            timer = nil
        }
    }
}
