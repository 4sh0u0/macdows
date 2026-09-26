import Foundation
import os

// adr/0019 §2 R-6 tool lane T1, extended by adr/0020 lane K. Four unattended-launch knobs, as ONE
// pure function of the process environment.
//
// ## What this is for
//
// "Shape 1" acceptance (a passive drop, then the driver's automatic reconnect) has to be judged
// from a file, and the only channel that carries the frozen `[reconnect]` line family is the App's
// own stdout (`ReconnectDriver.logLine`'s doc records why the status label cannot be read at all).
// An orchestrator therefore has to be able to start `Macdows.app`, have it connect, and have it
// exit again, with nobody at the keyboard. Today nothing in this app can do either: the only path
// to a connection is a button press, and the only path to `applicationWillTerminate` is a human
// quitting the app.
//
// ## Why this is NOT the precedent `AppDelegate.connectTapped` refuses
//
// `connectTapped` carries a deliberate, documented refusal to read `WIN_HOST`/`WIN_USER`/
// `WIN_PASS` from the environment: this is a GUI app, it is launched by Finder, by Xcode's Run
// button or by `open`, and honouring those variables would add a way to change WHICH HOST A BUTTON
// PRESS DIALS that is invisible in the window the human is looking at. That reasoning is about the
// TARGET of a connection, and it is untouched here -- none of the four knobs below introduces
// any host, account or credential source, and `host.env` remains the app's single source for all
// three.
//
// These knobs decide only whether somebody has to be present to press a button that is already
// there -- Connect (twice over: once via `MACDOWS_AUTOCONNECT`, a second time via
// `MACDOWS_RECONNECT_AFTER_SECONDS`) and Disconnect (via `MACDOWS_DISCONNECT_AFTER_SECONDS`) --
// and whether the process puts a ceiling on its own lifetime (`MACDOWS_QUIT_AFTER_SECONDS`).
// Every answer is visible in the window either way (each of the three presses walks the very same
// button method a human's mouse would call, status label included), and all four default to OFF,
// so an app launched by Finder, by Xcode's Run button or by `open` -- which is to say, every
// launch that is not an orchestrator deliberately exporting a variable -- behaves byte-for-byte as
// it did before any of these knobs existed.
//
// ## Why a type of its own rather than two `if`s inside `AppDelegate`
//
// The same reason `ShellReconnectPresenter` gives: `App/project.yml` hands `MacdowsAppTests` the
// sources `MacdowsAppTests` + `RemoteWindowRendering` + `SessionControl` and deliberately NOT
// `Macdows`, so nothing declared in `AppDelegate.swift` exists in the test bundle at all. Anything
// that DECIDES lives here, where it is ordinary offline Swift; `AppDelegate` keeps only the
// binding, and a source pin (`AppDelegateAutolaunchPinTests`) is what holds that.
//
// ## adr/0020 lane K: two more knobs, same shape, for the same reason
//
// Shape 1's acceptance answers "did a passive drop reconnect on its own"; it says nothing about a
// human pressing Disconnect and then Connect again, because nothing in this app could press either
// without a human at the keyboard. `MACDOWS_DISCONNECT_AFTER_SECONDS` and
// `MACDOWS_RECONNECT_AFTER_SECONDS` close that gap the same way T1 closed the first one: each is a
// whole number of seconds, each defaults to doing nothing, and each -- when it fires -- calls the
// very button method a human's mouse would call, never a step copied out of it.
//
// `MACDOWS_RECONNECT_AFTER_SECONDS` is deliberately read relative to the Disconnect press, not to
// launch ("press Connect again, t2 seconds after Disconnect fired") -- even though the relative
// reading is exactly the one that means NOTHING when `MACDOWS_DISCONNECT_AFTER_SECONDS` is absent
// or invalid, since there is then no Disconnect press for it to be "after" (an absolute,
// launch-relative reading would still mean something: dial again at t2 regardless).
// `plan(environment:)` is what enforces that precondition (gate r1 I-2, folded in): it reads
// `reconnectAfter` as `nil` whenever `disconnectAfter` did not itself parse to a value, so
// `AppDelegate`'s nesting of the second Timer inside the first one's callback is wiring a press
// this type has already confirmed makes sense, not a second place that decides whether it does.
//
// ## adr/0020 lane K, gate r1 I-1: an anchor line for the presses themselves
//
// Neither press writes anything else that says it happened: `endSessionTapped()` writes nothing
// by design (adr/0020 D-10), and `connectTapped()`'s own status line is not a judgement unit. An
// unattended run's only other captured evidence is `app-stdout-<sub>.log`'s `[reconnect]` line
// family, which carries no timestamp and says nothing about either button. `notePress(_:)` below
// is the fix: one fixed-shape line per press, printed immediately before `AppDelegate` makes it,
// on the same stdout channel plus a timestamped unified-log copy -- never `[reconnect]` itself, so
// it cannot be mistaken for a member of that frozen family.

/// The four unattended-launch knobs, parsed together, from the process environment.
///
/// Pure and non-isolated on purpose: it reads nothing (the caller passes the environment in), it
/// touches no AppKit object, and it has no opinion about when any knob is acted on.
enum ShellAutolaunch {

    /// Set to exactly `1` to have the app press its own Connect button once, at launch.
    static let autoconnectKey = "MACDOWS_AUTOCONNECT"

    /// Set to a whole number of seconds to have the app terminate itself that long after launch.
    static let quitAfterKey = "MACDOWS_QUIT_AFTER_SECONDS"

    /// adr/0020 lane K. Set to a whole number of seconds to have the app press its own Disconnect
    /// button that long after launch. Has no effect without `autoconnectKey` also being set to
    /// `"1"` -- see the file header and `plan(environment:)` (gate r1 I-2).
    static let disconnectAfterKey = "MACDOWS_DISCONNECT_AFTER_SECONDS"

    /// adr/0020 lane K. Set to a whole number of seconds to have the app press its own Connect
    /// button that long after the Disconnect press `disconnectAfterKey` scheduled. Has no effect
    /// without `disconnectAfterKey` also parsing to a valid value -- see the file header and
    /// `plan(environment:)` (gate r1 I-2).
    static let reconnectAfterKey = "MACDOWS_RECONNECT_AFTER_SECONDS"

    /// What a launch should do about the four knobs. `Plan(autoconnect: false, quitAfter: nil,
    /// disconnectAfter: nil, reconnectAfter: nil)` is both the default and the answer for every
    /// environment that does not set any of them.
    struct Plan: Equatable, Sendable {
        /// Press Connect once, at the end of `applicationDidFinishLaunching`.
        let autoconnect: Bool
        /// Terminate this process that long after launch, or `nil` for "no ceiling".
        let quitAfter: Duration?
        /// adr/0020 lane K. Press Disconnect that long after launch, or `nil` for "never" -- which
        /// is also the answer whenever `autoconnect` is off, whatever the raw environment value
        /// said (gate r1 I-2), or whenever `quitAfter` would leave no room for the press (gate r1
        /// m-2).
        let disconnectAfter: Duration?
        /// adr/0020 lane K. Press Connect that long after the Disconnect press above, or `nil` for
        /// "never" -- which is also the answer whenever `disconnectAfter` above is `nil`, for
        /// whatever reason (gate r1 I-2), or whenever `quitAfter` would leave no room for this
        /// press either (gate r1 m-2).
        let reconnectAfter: Duration?

        /// The same ceiling as a `TimeInterval`, which is what `Timer` takes.
        ///
        /// Here rather than at the call site because `AppDelegate` is not in the test bundle:
        /// arithmetic written there could only ever be checked by matching source text, and this
        /// conversion is arithmetic. The plan's own unit stays `Duration`, matching
        /// `ReconnectPolicy`'s vocabulary for every other interval in this lane's neighbourhood.
        var quitAfterInterval: TimeInterval? {
            guard let quitAfter else { return nil }
            return ShellAutolaunch.seconds(quitAfter)
        }

        /// adr/0020 lane K. The Disconnect delay as a `TimeInterval`, for the same reason as
        /// `quitAfterInterval` above.
        var disconnectAfterInterval: TimeInterval? {
            guard let disconnectAfter else { return nil }
            return ShellAutolaunch.seconds(disconnectAfter)
        }

        /// adr/0020 lane K. The Connect-again delay as a `TimeInterval`, for the same reason as
        /// `quitAfterInterval` above.
        var reconnectAfterInterval: TimeInterval? {
            guard let reconnectAfter else { return nil }
            return ShellAutolaunch.seconds(reconnectAfter)
        }
    }

    /// The default: all four knobs off.
    static let off = Plan(autoconnect: false, quitAfter: nil, disconnectAfter: nil, reconnectAfter: nil)

    /// adr/0020 lane K (gate r1 I-1): which real button a launch is about to press. The two cases
    /// line up with the two Timers `AppDelegate` nests at the tail of
    /// `applicationDidFinishLaunching`, in the order they can fire -- Disconnect, then Connect.
    enum Press: String {
        case disconnect
        case connect
    }

    /// adr/0019 §2 lane D's own logger, extended here rather than duplicated: this file's anchor
    /// line needs the same two channels `ReconnectDriver.transition(to:)` already uses for the
    /// `[reconnect]` line family -- stdout, captured by the same orchestrator, and the unified
    /// log, timestamped, for a cross-check the stdout line cannot carry on its own.
    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "Autolaunch")

    /// The fixed-shape anchor line for `which`, e.g. `[autolaunch] press=disconnect`. Split out
    /// from `notePress(_:)` below so its exact shape can be value-tested, the same reason
    /// `seconds(_:)` is split out from the Timer-interval conversions that use it.
    ///
    /// `[autolaunch]`, never `[reconnect]`: this line is not a member of that frozen line family
    /// (`ReconnectLogChannelPinTests` pins `[reconnect]`'s own vocabulary and knows nothing of
    /// this one).
    static func pressLine(_ which: Press) -> String {
        "[autolaunch] press=\(which.rawValue)"
    }

    /// adr/0020 lane K (gate r1 I-1): prints, and logs to the unified log, the anchor line for
    /// `which`. `AppDelegate` calls this once per Timer, immediately BEFORE the real button press
    /// it is about to make -- `endSessionTapped()` writes nothing on purpose (adr/0020 D-10) and
    /// `connectTapped()`'s own status line is not a judgement unit, so without this line an
    /// unattended run's captured output has no way to locate the instant of either press.
    ///
    /// Two channels, never one without the other, mirroring `ReconnectDriver.transition(to:)`
    /// exactly: `print` for the same captured-stdout channel the `[reconnect]` line family already
    /// uses, and `logger.notice(_:privacy:)` for a timestamped cross-check in the unified log.
    /// `.notice`, not `.info`, for the reason `ReconnectDriver`'s own logger doc comment gives:
    /// `.info` does not persist to disk by default, and a `log show` export run minutes later can
    /// come back empty.
    static func notePress(_ which: Press) {
        let line = pressLine(which)
        print(line)
        logger.notice("\(line, privacy: .public)")
    }

    /// Reads all four knobs out of `environment`. `autoconnect` and `quitAfter` are fully
    /// independent of everything else, exactly as they always have been. `disconnectAfter` and
    /// `reconnectAfter` are NOT independent of the other three (gate r1 I-2, folded in):
    /// `disconnectAfter` only ever holds a value when `autoconnect` is on (a Disconnect press with
    /// no autoconnected session to end would be a second, laxer unattended-dial path -- exactly
    /// what `autoconnectKey`'s own doc below argues against paying for), and `reconnectAfter` only
    /// ever holds a value when `disconnectAfter` itself parsed to one (there is otherwise no
    /// Disconnect press for "the reconnect delay" to be relative to). A ceiling that would leave
    /// no room for either press -- `quitAfter` at or before `disconnectAfter`, or at or before
    /// `disconnectAfter + reconnectAfter` -- forces both back to `nil` as well (gate r1 m-2): this
    /// is a NECESSARY condition, not a sufficient one (the ORCHESTRATOR still owns the margin
    /// `endSessionTapped()`'s own blocking teardown and the second connect's handshake need, since
    /// this function cannot see either duration). `AppDelegate`'s nesting of the Connect-again
    /// Timer inside the Disconnect Timer's callback (not visible here) is what gives a scheduled
    /// `reconnectAfter` its "relative to the Disconnect press" TIMING; this function is what
    /// decides whether either press should be scheduled at all.
    ///
    /// `MACDOWS_AUTOCONNECT` recognises the single character `1` and nothing else. Not `true`, not
    /// `yes`, not `01`, not ` 1`, not a non-empty-means-on rule. A knob that turns a real network
    /// connection on is the wrong place to be generous: the cost of refusing a spelling somebody
    /// meant is one puzzled re-read of this line, and the cost of accepting a spelling nobody meant
    /// is an unattended process dialling a live host.
    ///
    /// `MACDOWS_QUIT_AFTER_SECONDS`, `MACDOWS_DISCONNECT_AFTER_SECONDS` and
    /// `MACDOWS_RECONNECT_AFTER_SECONDS` each take a whole number of seconds, strictly positive.
    /// Anything else -- an empty value, a word, a float, a negative number, `0`, or a number too
    /// large for `Int` -- yields `nil`, which is the "do nothing" answer, and never a trap or a
    /// crash. `0` is refused with the rest deliberately: a zero-second delay fires before the
    /// launch that scheduled it has finished doing anything else, which reads in the evidence
    /// exactly like a launch that died, and these knobs exist to be a safety net (or a fixed,
    /// legible rehearsal) rather than a way to produce that.
    static func plan(environment: [String: String]) -> Plan {
        let autoconnect = environment[autoconnectKey] == "1"
        let quit = quitAfter(environment[quitAfterKey])
        // gate r1 I-2: the two cuts described in this function's own doc comment above, made HERE
        // as values so `AppDelegate` only ever reads an answer that has already accounted for
        // them.
        let disconnectIfAutoconnected = autoconnect ? quitAfter(environment[disconnectAfterKey]) : nil
        let reconnectIfDisconnecting = disconnectIfAutoconnected != nil ? quitAfter(environment[reconnectAfterKey]) : nil

        // gate r1 m-2: NECESSARY, not sufficient -- see this function's doc comment. `reconnectSpan`
        // is `disconnect` alone when there is no reconnect delay to add, so ONE comparison covers
        // both matrix rows ("t1 >= ceiling" and "t1 + t2 >= ceiling") at once.
        var ceilingLeavesNoRoom = false
        if let quit, let disconnect = disconnectIfAutoconnected {
            let reconnectSpan = reconnectIfDisconnecting.map { disconnect + $0 } ?? disconnect
            ceilingLeavesNoRoom = reconnectSpan >= quit
        }

        return Plan(
            autoconnect: autoconnect,
            quitAfter: quit,
            disconnectAfter: ceilingLeavesNoRoom ? nil : disconnectIfAutoconnected,
            reconnectAfter: ceilingLeavesNoRoom ? nil : reconnectIfDisconnecting
        )
    }

    /// The "whole positive number of seconds, else nothing" parse shared by
    /// `MACDOWS_QUIT_AFTER_SECONDS`, `MACDOWS_DISCONNECT_AFTER_SECONDS` and
    /// `MACDOWS_RECONNECT_AFTER_SECONDS`, split out so its refusals can be tested by value once
    /// rather than three times.
    static func quitAfter(_ raw: String?) -> Duration? {
        guard let raw, let seconds = Int(raw), seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    /// Whole and fractional seconds of `duration` as a `TimeInterval`.
    ///
    /// Written out rather than taken from `Duration`'s own `TimeInterval` bridge so that this file
    /// does not depend on which SDK offers that bridge, and so the truncation behaviour is this
    /// project's own statement -- the same reason `DispatchReconnectClock.seconds` exists next
    /// door, and this is the same arithmetic.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
