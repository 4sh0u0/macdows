import Foundation

// adr/0019 §2 R-6 tool lane T1. The two unattended-launch knobs, as ONE pure function of the
// process environment.
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
// TARGET of a connection, and it is untouched here -- neither knob below introduces any host,
// account or credential source, and `host.env` remains the app's single source for all three.
//
// These knobs decide only whether somebody has to be present to press a button that is already
// there, and whether the process puts a ceiling on its own lifetime. Both answers are visible in
// the window either way (a connect started by `MACDOWS_AUTOCONNECT` walks the very same
// `connectTapped` path, status label included), and both default to OFF, so an app launched by
// Finder, by Xcode's Run button or by `open` -- which is to say, every launch that is not an
// orchestrator deliberately exporting a variable -- behaves byte-for-byte as it did before this
// file existed.
//
// ## Why a type of its own rather than two `if`s inside `AppDelegate`
//
// The same reason `ShellReconnectPresenter` gives: `App/project.yml` hands `MacdowsAppTests` the
// sources `MacdowsAppTests` + `RemoteWindowRendering` + `SessionControl` and deliberately NOT
// `Macdows`, so nothing declared in `AppDelegate.swift` exists in the test bundle at all. Anything
// that DECIDES lives here, where it is ordinary offline Swift; `AppDelegate` keeps only the
// binding, and a source pin (`AppDelegateAutolaunchPinTests`) is what holds that.

/// The two unattended-launch knobs, parsed together, from the process environment.
///
/// Pure and non-isolated on purpose: it reads nothing (the caller passes the environment in), it
/// touches no AppKit object, and it has no opinion about when either knob is acted on.
enum ShellAutolaunch {

    /// Set to exactly `1` to have the app press its own Connect button once, at launch.
    static let autoconnectKey = "MACDOWS_AUTOCONNECT"

    /// Set to a whole number of seconds to have the app terminate itself that long after launch.
    static let quitAfterKey = "MACDOWS_QUIT_AFTER_SECONDS"

    /// What a launch should do about the two knobs. `Plan(autoconnect: false, quitAfter: nil)` is
    /// both the default and the answer for every environment that does not set them.
    struct Plan: Equatable, Sendable {
        /// Press Connect once, at the end of `applicationDidFinishLaunching`.
        let autoconnect: Bool
        /// Terminate this process that long after launch, or `nil` for "no ceiling".
        let quitAfter: Duration?

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
    }

    /// The default: both knobs off.
    static let off = Plan(autoconnect: false, quitAfter: nil)

    /// Reads both knobs out of `environment`. They are independent: neither one's presence,
    /// absence or malformedness changes the other's answer.
    ///
    /// `MACDOWS_AUTOCONNECT` recognises the single character `1` and nothing else. Not `true`, not
    /// `yes`, not `01`, not ` 1`, not a non-empty-means-on rule. A knob that turns a real network
    /// connection on is the wrong place to be generous: the cost of refusing a spelling somebody
    /// meant is one puzzled re-read of this line, and the cost of accepting a spelling nobody meant
    /// is an unattended process dialling a live host.
    ///
    /// `MACDOWS_QUIT_AFTER_SECONDS` takes a whole number of seconds, strictly positive. Anything
    /// else -- an empty value, a word, a float, a negative number, `0`, or a number too large for
    /// `Int` -- yields `nil`, which is the "no ceiling" answer, and never a trap or a crash. `0` is
    /// refused with the rest deliberately: a zero-second ceiling terminates the app before it has
    /// done anything, which reads in the evidence exactly like a launch that died, and this knob
    /// exists to be a safety net rather than a way to produce that.
    static func plan(environment: [String: String]) -> Plan {
        Plan(
            autoconnect: environment[autoconnectKey] == "1",
            quitAfter: quitAfter(environment[quitAfterKey])
        )
    }

    /// The `MACDOWS_QUIT_AFTER_SECONDS` half, split out so its refusals can be tested by value.
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
