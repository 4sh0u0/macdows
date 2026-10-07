import Foundation
import os

// adr/0019 §2 R-6 tool lane T1, extended by adr/0020 lane K and by adr/0021 lane LC-2. Six
// unattended-launch knobs, as ONE pure function of the process environment.
//
// ## What this is for
//
// "Shape 1" acceptance (a passive drop, then the driver's automatic reconnect) has to be judged
// from a file, and the only channel that carries the frozen `[reconnect]` line family is the App's
// own stdout (`ReconnectDriver.logLine`'s doc records why the status label cannot be read at all).
// An orchestrator therefore has to be able to start `Macdows.app`, have it connect, and have it
// exit again, with nobody at the keyboard. Before T1, nothing in this app could do either: the
// only path to a connection was a button press, and the only path to `applicationWillTerminate`
// was a human quitting the app.
//
// ## Why this is NOT the precedent `AppDelegate.connectTapped` refuses
//
// `connectTapped` carries a deliberate, documented refusal to read `WIN_HOST`/`WIN_USER`/
// `WIN_PASS` from the environment: this is a GUI app, it is launched by Finder, by Xcode's Run
// button or by `open`, and honouring those variables would add a way to change WHICH HOST A BUTTON
// PRESS DIALS that is invisible in the window the human is looking at. That reasoning is about the
// TARGET of a connection, and it is untouched here -- none of the six knobs below introduces
// any host, account or credential source. Since UI slice ① (ADR-0024 D-9, M-a) the App reads no
// `host.env` at all: the host is the record selected in the Hosts window, the account is that
// record's user name and the password comes from the keychain or the Password sheet. Until the
// lab target-knob lane lands (ADR-0024 D-9 F-4), a host is pre-selected at launch ONLY when exactly
// one host record exists (M-a-1), so `MACDOWS_AUTOCONNECT`'s press dials that one record and, with
// zero or several records, finds no selection and refuses with one `[connect]` line that names no
// address. The knob still only presses the button that is already there.
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
//
// ## adr/0021 lane LC-2: a fifth and sixth knob, and why they are still not that precedent
//
// Shape L-C (adr/0021 §3) needs the stimulus that locks the remote session to arrive INSIDE the
// App's own live connection, and the only delivery left under S2' is a second RAIL ClientExecute
// on that connection. `MACDOWS_EXTRA_EXEC_AFTER_SECONDS` (a whole number of seconds, counted from
// launch, same grammar and same parse function as `MACDOWS_DISCONNECT_AFTER_SECONDS`) and
// `MACDOWS_EXTRA_EXEC_PROGRAM` (a program string, trimmed of surrounding whitespace and otherwise
// passed verbatim) make the app call `CRSession.executeProgram(_:)` once, that long after launch,
// on the session it is holding at that moment.
//
// This pair is different in kind from the first four, and the difference is stated rather than
// hidden: it adds WHAT is executed on the remote side, not merely whether somebody has to be
// present to press a button. It still does not touch what `connectTapped`'s refusal is about.
// It names no host and no account, carries no credential, and cannot change WHICH HOST is dialled
// or WITH WHAT IDENTITY -- the connection it rides on is the one the autoconnect press made, through
// the selected host record (ADR-0024 D-9) and the live-host boundary gate. It is OFF by default (both
// variables have to be set, and `plan(environment:)` drops the pair unless `MACDOWS_AUTOCONNECT=1`
// and a `MACDOWS_QUIT_AFTER_SECONDS` ceiling are set too, i.e. only in the unattended shape an
// orchestrator exports deliberately). The program string comes from the environment only and never
// reaches a log line: the anchor line carries its UTF-8 byte count, nothing else. The owner ruled
// this knob in on 2026-10-05 (O-1, recorded in the docs STATUS entry 43 and in the 2026-10-05
// addendum to adr/0021 D-3, which revises S2 from "should not exist either" to "an experimental
// entry point that is off by default").
//
// Gate r1 m-3, registered rather than changed: the anchor line (A-X) does not tell the first
// connection apart from one `ReconnectDriver` re-established after a drop. Both run on the same
// `CRSession`, so `session=present` still holds after an automatic reconnect, and the bridge's
// X-C count restarts at 0 on every `-start`. A reader identifies the first connection from the
// captured output instead: exactly one X-C line before A-X, and no non-live `[reconnect]` line.
//
// ## adr/0021 lane CA-2: a seventh knob that is not a launch knob at all
//
// `MACDOWS_KEY_WITNESS` (exactly `1`, nothing else) turns on the bridge's `[key-witness]` lines:
// one INFO line per keyboard event the outbound lane hands to FreeRDP, printed by `CRSession.mm`
// on T_rdp (owner ruling 2026-10-06 on P-CA1-1, "add the observation-only key witness first, then
// check in the field"). It is parsed here only so the process environment is still read in one
// place, once; it presses nothing, schedules nothing and changes nothing that is sent. It is
// independent of the six launch knobs (a human pressing Connect gets the lines too), names no
// host, account or credential, and its lines never carry a typed character (the Unicode path
// logs the kind, the flags and the return code, never the code unit).

/// The six unattended-launch knobs, plus lane CA-2's key-witness switch, parsed together, from the process environment.
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

    /// adr/0021 lane LC-2. Set to a whole number of seconds to have the app send one extra RAIL
    /// ClientExecute, inside its own connection, that long after launch. Has no effect unless
    /// `extraExecProgramKey` is set as well and `plan(environment:)`'s gate admits the pair -- see
    /// the file header.
    static let extraExecAfterKey = "MACDOWS_EXTRA_EXEC_AFTER_SECONDS"

    /// adr/0021 lane LC-2. The program string that extra ClientExecute sends. Trimmed of leading and
    /// trailing whitespace, otherwise passed to `CRSession.executeProgram(_:)` verbatim; its
    /// 255-byte limit is enforced by that method's own refusal, not repeated here. NEVER logged.
    static let extraExecProgramKey = "MACDOWS_EXTRA_EXEC_PROGRAM"

    /// adr/0021 lane CA-2. Set to exactly `1` to have every connection print one `[key-witness]`
    /// line per keyboard event it sends -- see the file header. Any other value, including the
    /// empty string, ` 1`, `1 `, `01`, `true` and `yes`, is off: the same exact-literal grammar as
    /// `autoconnectKey`, with no trimming.
    static let keyWitnessKey = "MACDOWS_KEY_WITNESS"

    /// What a launch should do about the six launch knobs and the key-witness switch. `Plan(autoconnect: false, quitAfter: nil,
    /// disconnectAfter: nil, reconnectAfter: nil)` is both the default and the answer for every
    /// environment that does not set any of them (the two lane LC-2 fields default to `nil`).
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
        /// adr/0021 lane LC-2. Send the extra ClientExecute that long after launch, or `nil` for
        /// "never". Always `nil` exactly when `extraExecProgram` is `nil` -- `init` enforces it.
        let extraExecAfter: Duration?
        /// adr/0021 lane LC-2. The program the extra ClientExecute sends, or `nil` for "never".
        /// Always `nil` exactly when `extraExecAfter` is `nil` -- `init` enforces it.
        let extraExecProgram: String?
        /// adr/0021 lane CA-2. Turn the bridge's `[key-witness]` lines on for every connection
        /// this process starts. Independent of every other field.
        let keyWitness: Bool

        /// The memberwise shape every earlier lane already spells, plus the two lane LC-2 fields,
        /// defaulted so a plan written without them still means "no extra exec". The pair lives or
        /// dies together: a half-set pair is stored as neither, so no reader can ever see a delay
        /// without a program or a program without a delay.
        init(
            autoconnect: Bool,
            quitAfter: Duration?,
            disconnectAfter: Duration?,
            reconnectAfter: Duration?,
            extraExecAfter: Duration? = nil,
            extraExecProgram: String? = nil,
            keyWitness: Bool = false
        ) {
            self.autoconnect = autoconnect
            self.quitAfter = quitAfter
            self.disconnectAfter = disconnectAfter
            self.reconnectAfter = reconnectAfter
            if let extraExecAfter, let extraExecProgram {
                self.extraExecAfter = extraExecAfter
                self.extraExecProgram = extraExecProgram
            } else {
                self.extraExecAfter = nil
                self.extraExecProgram = nil
            }
            self.keyWitness = keyWitness
        }

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

        /// adr/0021 lane LC-2. The extra-exec delay as a `TimeInterval`, for the same reason as
        /// `quitAfterInterval` above.
        var extraExecAfterInterval: TimeInterval? {
            guard let extraExecAfter else { return nil }
            return ShellAutolaunch.seconds(extraExecAfter)
        }
    }

    /// The default: all six launch knobs off and the key-witness switch off.
    static let off = Plan(autoconnect: false, quitAfter: nil, disconnectAfter: nil, reconnectAfter: nil)

    /// adr/0020 lane K (gate r1 I-1): which real button a launch is about to press. The two cases
    /// line up with the two Timers `AppDelegate` nests at the tail of
    /// `applicationDidFinishLaunching`, in the order they can fire -- Disconnect, then Connect.
    ///
    /// adr/0021 lane LC-2 adds `extraExec`: not a button, but the same kind of instant an
    /// orchestrator has to locate (witness A-X), so it gets the same anchor line.
    enum Press: String {
        case disconnect
        case connect
        case extraExec = "extra-exec"
    }

    /// adr/0019 §2 lane D's own logger, extended here rather than duplicated: this file's anchor
    /// line needs the same two channels `ReconnectDriver.transition(to:)` already uses for the
    /// `[reconnect]` line family -- stdout, captured by the same orchestrator, and the unified
    /// log, timestamped, for a cross-check the stdout line cannot carry on its own. UI slice ③: a
    /// `DiagnosticLogger` (same `os.Logger` underneath; the buffer copy has no registered export
    /// shape, so an export only counts these lines).
    private static let logger = DiagnosticLogger(subsystem: "dev.haru.macdows", category: "Autolaunch")

    /// The fixed-shape anchor line for `which`, e.g. `[autolaunch] press=disconnect`. Split out
    /// from `notePress(_:)` below so its exact shape can be value-tested, the same reason
    /// `seconds(_:)` is split out from the Timer-interval conversions that use it.
    ///
    /// `[autolaunch]`, never `[reconnect]`: this line is not a member of that frozen line family
    /// (`ReconnectLogChannelPinTests` pins `[reconnect]`'s own vocabulary and knows nothing of
    /// this one).
    ///
    /// adr/0021 lane LC-2: the extra-exec press may append two fields, ` program-bytes=<n>` (the
    /// UTF-8 byte count of the program string, computed by the caller) and
    /// ` session=present|absent`. Gate r1 I-1 (folded in): this function and `notePress(_:)` take
    /// the byte count, never the program string itself, so neither the printed line nor the
    /// unified-log copy can carry any of its characters by construction rather than by
    /// convention (`AppDelegateAutolaunchPinTests` pins both signatures and the caller's
    /// `.utf8.count`). Both fields are omitted when their argument is `nil`, so the two earlier
    /// presses keep their exact shape.
    static func pressLine(_ which: Press, programBytes: Int? = nil, sessionPresent: Bool? = nil) -> String {
        var line = "[autolaunch] press=\(which.rawValue)"
        if let programBytes {
            line += " program-bytes=\(programBytes)"
        }
        if let sessionPresent {
            line += sessionPresent ? " session=present" : " session=absent"
        }
        return line
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
    ///
    /// adr/0021 lane LC-2: `programBytes` and `sessionPresent` are forwarded to `pressLine`
    /// unchanged; see there for why only the byte count, never the program string, is accepted.
    static func notePress(_ which: Press, programBytes: Int? = nil, sessionPresent: Bool? = nil) {
        let line = pressLine(which, programBytes: programBytes, sessionPresent: sessionPresent)
        print(line)
        logger.notice("\(line, privacy: .public)")
    }

    /// Reads all six launch knobs and the key-witness switch (seven keys) out of `environment`. `autoconnect` and `quitAfter` are fully
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
    /// Digits only: a sign, whitespace, a decimal point or any non-ASCII digit is refused --
    /// `Tools/rail-probe`'s `parse_decimal_field` is the same grammar, for the same knob shape.
    /// Anything else -- an empty value, a word, a float, a negative number, `0`, or a number too
    /// large for `Int` -- yields `nil`, which is the "do nothing" answer, and never a trap or a
    /// crash. `0` is refused with the rest deliberately: a zero-second delay fires before the
    /// launch that scheduled it has finished doing anything else, which reads in the evidence
    /// exactly like a launch that died, and these knobs exist to be a safety net (or a fixed,
    /// legible rehearsal) rather than a way to produce that.
    ///
    /// adr/0021 lane LC-2: `MACDOWS_EXTRA_EXEC_AFTER_SECONDS` uses the same parse (counted from
    /// launch, like the Disconnect delay) and `MACDOWS_EXTRA_EXEC_PROGRAM` must be non-empty once
    /// trimmed of surrounding whitespace. The pair is scheduled only when ALL of these hold, and is
    /// otherwise silently `nil` -- both fields, never one (the gate r1 m-2 shape): autoconnect is
    /// on (there is no session of this knob's own making to execute in otherwise); a ceiling is
    /// set and the delay N is strictly before it (the unattended shape, with room left); and, if a
    /// Disconnect press is scheduled, N is strictly before that too (owner ruling O-2: the extra
    /// exec may share a run with Disconnect, but only inside the first connection).
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

        let disconnect = ceilingLeavesNoRoom ? nil : disconnectIfAutoconnected

        // adr/0021 lane LC-2: the extra-exec pair, gated as this function's doc comment says.
        var extraExecAfter: Duration?
        var extraExecProgram: String?
        if autoconnect, let quit, let delay = quitAfter(environment[extraExecAfterKey]),
            let program = environment[extraExecProgramKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !program.isEmpty, delay < quit
        {
            // O-2: strictly before a scheduled Disconnect, never on the reconnected session.
            if disconnect.map({ delay < $0 }) ?? true {
                extraExecAfter = delay
                extraExecProgram = program
            }
        }

        return Plan(
            autoconnect: autoconnect,
            quitAfter: quit,
            disconnectAfter: disconnect,
            reconnectAfter: ceilingLeavesNoRoom ? nil : reconnectIfDisconnecting,
            extraExecAfter: extraExecAfter,
            extraExecProgram: extraExecProgram,
            // adr/0021 lane CA-2: exactly "1", independent of every other knob.
            keyWitness: environment[keyWitnessKey] == "1"
        )
    }

    /// The "whole positive number of seconds, else nothing" parse shared by
    /// `MACDOWS_QUIT_AFTER_SECONDS`, `MACDOWS_DISCONNECT_AFTER_SECONDS`,
    /// `MACDOWS_RECONNECT_AFTER_SECONDS` and `MACDOWS_EXTRA_EXEC_AFTER_SECONDS`, split out so its
    /// refusals can be tested by value once rather than four times. Digits only: a sign, whitespace, a decimal point or any
    /// non-ASCII digit is refused, even one `Int(_:)` alone would otherwise have accepted (a
    /// leading `+`) -- the same grammar `Tools/rail-probe`'s `parse_decimal_field` uses for its
    /// own seconds knobs. Leading zeros normalise the way `Int(_:)` already normalises them
    /// ("010" is 10).
    static func quitAfter(_ raw: String?) -> Duration? {
        guard let raw, !raw.isEmpty, raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        guard let seconds = Int(raw), seconds > 0 else { return nil }
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
