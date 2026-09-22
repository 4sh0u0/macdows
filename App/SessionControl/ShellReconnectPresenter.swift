import Foundation
import MacdowsCore

// adr/0019 §2 lane D. The shell's two AppKit properties -- the Connect button's `isEnabled` and the
// status label's string -- as ONE pure function of `ReconnectDriver.State`.
//
// ## Why a type of its own rather than two `if`s inside `AppDelegate`
//
// `App/project.yml` gives `MacdowsAppTests` the sources `MacdowsAppTests` + `RemoteWindowRendering`
// + `SessionControl`, and deliberately NOT `Macdows`: nothing declared in `AppDelegate.swift`
// exists in the test bundle at all, so a branch written there can only ever be checked by matching
// source text. Everything that decides WHAT the shell says therefore lives here, where it is
// ordinary offline Swift with no AppKit object in sight, and `AppDelegate` keeps only the two
// assignments -- which is all a source pin has to hold.
//
// ## What this type is not
//
// It makes the DECISION testable, not the BINDING. That the button's `isEnabled` really receives
// `connectEnabled`, and that the label really receives `statusLine`, stays a source pin
// (`AppDelegateReconnectWiringPinTests`). Registered, not papered over: closing it means splitting
// `AppDelegate` into a target the test bundle can compile, which is a different lane.
//
// It also holds no state and reads nothing. The session's event count, generation and live-window
// count arrive as a `ConnectedSummary` the caller gathered, so this file cannot disagree with the
// caller about which session it is describing.

/// The Connect button and the status label, decided together, from the reconnect state.
@MainActor
enum ShellReconnectPresenter {

    /// What a live connection's status line reports, gathered by the caller.
    ///
    /// One struct rather than three parameters because the three are only ever meaningful
    /// together: they are one reading of one session, and a call site that could pass this
    /// session's event count beside the previous session's generation is a call site worth not
    /// having.
    struct ConnectedSummary: Equatable {
        /// Events drained since `beginSession` reset the counter.
        let events: Int
        /// `CRSession.currentGeneration` -- the control queue's connection generation.
        let generation: UInt32
        /// `RemoteWindowRegistry.windowSnapshots().count`.
        let windows: Int

        init(events: Int, generation: UInt32, windows: Int) {
            self.events = events
            self.generation = generation
            self.windows = windows
        }
    }

    /// The whole shell as one value, so a caller cannot update one half and forget the other.
    struct Shell: Equatable {
        /// Whether the Connect button accepts a press.
        let connectEnabled: Bool
        /// The complete status label text, display-change note included.
        let statusLine: String
    }

    /// The shell for `state`.
    ///
    /// - Parameter connected: read only by the states that describe a working connection; the
    ///   reconnect states say nothing about event counts, and a caller that has no session may pass
    ///   any summary it likes.
    /// - Parameter displayNote: the most recent screen-parameter note (adr/0015 §5.A.3), or `nil`.
    ///   APPENDED to every state's text rather than replacing it -- see `noteSuffix`.
    static func shell(
        for state: ReconnectDriver.State,
        connected: ConnectedSummary,
        displayNote: String?
    ) -> Shell {
        Shell(
            connectEnabled: connectEnabled(for: state),
            statusLine: body(for: state, connected: connected) + noteSuffix(displayNote)
        )
    }

    /// Whether the Connect button accepts a press in `state`.
    ///
    /// TRUE FOR `.gaveUp` ONLY, and the reason is structural rather than cautious. An automatic
    /// reconnect reuses the SAME `CRSession` (`-restartForReconnectPreparing:` restarts the
    /// instance it is called on), and `AppDelegate.connectTapped`'s first guard is
    /// `session == nil`. So a button enabled while a retry is pending or in flight would answer
    /// "Already connecting/connected." to every press -- a button that lies is worse than one that
    /// is visibly unavailable. Giving up is the one state in which the App drops the session, which
    /// is what lets the next press start a real connection.
    ///
    /// `.idle` is FALSE, and that is the one place this differs from the lane blueprint's sketch.
    /// `.idle` is not only the stand-down state (`ReconnectDriver.performReconnect`'s abandoned
    /// retry); it is also the driver's INITIAL value, which the App reads on every drain tick
    /// between `-start` and the RAIL handshake. Enabling there would re-open the button on a
    /// connection that is merely still coming up -- the same lie, on the ordinary connect path.
    ///
    /// ## `.idle` IS A PRECONDITION, NOT JUST A CASE (gate r1 I-2)
    ///
    /// This arm serves the pre-handshake tick. A STAND-DOWN `.idle` arriving at the App through
    /// `onStateChange` would be a different animal, and this presenter is not written for it: it
    /// would re-DISABLE the button and overwrite whatever the App last said (a `Connect failed:`
    /// line, say) with a `Connected — …` one built from a session that is on its way out -- and
    /// because every path that produces a stand-down has already invalidated `drainTimer`, nothing
    /// would ever refresh the label again. A permanently wrong shell, with no next tick.
    ///
    /// So the claim this arm rests on is a REQUIREMENT on the App, registered here rather than
    /// asserted as a happy fact: **a stand-down `.idle` must not reach `AppDelegate`**. It holds
    /// today at all three `detach()` sites, for three different reasons, and each reason is what a
    /// future edit has to preserve:
    ///
    ///  1. the give-up teardown drops the driver (`reconnectDriver = nil`) right after detaching
    ///     it, and the pending-retry block holds the driver weakly, so no callback can follow;
    ///  2. `applicationWillTerminate` is the process leaving;
    ///  3. the connect-error branch detaches but keeps the driver on the property, so it is the
    ///     only site where a scheduled retry block could still find a live driver. Reaching the
    ///     stand-down needs that driver to be in `.waiting`, which needs the `.disconnected` that
    ///     scheduled it to have arrived with `lastConnectError` still nil -- and nothing can set
    ///     that error afterwards, because both bridge paths set it BEFORE they post the sentinel
    ///     and then return. Unreachable, but by an argument about another file.
    ///
    /// Registered, not repaired: the structural repair (nil the driver in the connect-error branch
    /// too) would edit a branch this lane is only allowed to append to. Left for the owner.
    ///
    /// The stand-down reading is not lost by any of this: a stand-down only happens when the owner
    /// is already tearing the session down or has detached the driver, and in both of those the
    /// button's state is decided by the code doing the tearing down.
    static func connectEnabled(for state: ReconnectDriver.State) -> Bool {
        if case .gaveUp = state { return true }
        return false
    }

    /// The status text for `state`, without the display-change note.
    private static func body(
        for state: ReconnectDriver.State,
        connected: ConnectedSummary
    ) -> String {
        switch state {
        case .idle, .live:
            // BYTE-IDENTICAL to what `AppDelegate.drainTick` wrote before this lane existed (the
            // two-line "Connected" block), because lane D is a reconnect lane and must not also
            // restyle the ordinary connected shell. `ShellReconnectPresenterTests` carries the
            // frozen text as a literal.
            //
            // `.idle` shares it with `.live` deliberately: `.idle` means "the driver is not
            // claiming anything about this connection", which before the first handshake is simply
            // the truth, and which is exactly the shell this app showed for the whole connection
            // before there was a driver at all.
            return """
                Connected — \(connected.events) event(s) so far (generation \(connected.generation))
                \(connected.windows) remote window(s) live
                """
        case .waiting(let attempt, let delay):
            return "Reconnecting — attempt \(humanAttemptNumber(forZeroBasedIndex: attempt)) "
                + "of \(ReconnectPolicy.maxAttempts), retrying in \(delayText(delay))"
        case .reconnecting(let attempt):
            return "Reconnecting — attempt \(humanAttemptNumber(forZeroBasedIndex: attempt)) "
                + "of \(ReconnectPolicy.maxAttempts)..."
        case .gaveUp(let cause):
            // `ReconnectDriver.token(for:)`, not a second vocabulary. The `[reconnect]` line's
            // `cause=` field and this label are then the same word by construction, so a screenshot
            // and a log can be lined up without a glossary.
            return "Disconnected — gave up (\(ReconnectDriver.token(for: cause))). "
                + "Press Connect to try again."
        }
    }

    /// The display-change note as a suffix, or the empty string.
    ///
    /// Computed OUTSIDE the state switch on purpose: adr/0015 §5.A.3 lets that event reach exactly
    /// one place in this app -- a label -- and `AppDelegate.drainTick` already had to carry it
    /// through its own overwrite for the note to be legible for more than a second. A reconnect
    /// does not make the note less true, and a switch with one arm that forgot to append it is
    /// precisely the defect this shape makes unwritable.
    private static func noteSuffix(_ displayNote: String?) -> String {
        displayNote.map { "\n\($0)" } ?? ""
    }

    /// The human-facing attempt number for a policy attempt index.
    ///
    /// `ReconnectDriver.State`'s `attempt` is the ZERO-BASED failed-attempt index -- the same `n`
    /// that `ReconnectPolicy.delay(forFailedAttempt:)` takes, so that the state, the log line and
    /// the policy call can never disagree about which attempt is which. A human counts from one, so
    /// every index that reaches a label goes through this function.
    ///
    /// THE CONSEQUENCE, STATED SO IT IS NOT READ AS A BUG: the `[reconnect]` line prints the index
    /// verbatim (`attempt=0` for the first retry) and the status line prints `attempt 1 of 5` for
    /// the same moment. They differ by one, always, and in that direction. Changing either side to
    /// "match" the other would break whichever of the two it was matched to.
    static func humanAttemptNumber(forZeroBasedIndex index: Int) -> Int {
        index + 1
    }

    /// A back-off delay as whole tenths of a second, e.g. `1.0 s`.
    ///
    /// Derived from `ReconnectDriver.milliseconds(_:)` rather than from `Duration`'s components
    /// again, so the number on the label and the `delay-ms=` field of the `[reconnect]` line are
    /// two renderings of one reading. `String(format:)` without a locale is deliberate: this is a
    /// developer harness's diagnostic text, it must have a decimal point in every region, and a
    /// test comparing it to a literal must not depend on where it runs.
    static func delayText(_ delay: Duration) -> String {
        String(format: "%.1f s", Double(ReconnectDriver.milliseconds(delay)) / 1000)
    }
}
