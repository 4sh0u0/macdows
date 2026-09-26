import Foundation
import Testing

// adr/0019 §2 R-6 tool lane T1-a, the behaviour half, extended by adr/0020 lane K. `ShellAutolaunch`
// is the whole of what the four unattended-launch knobs DECIDE; `AppDelegate`'s statements only act
// on the answer, and they are held by `AppDelegateAutolaunchPinTests`' source pins next door because
// `App/project.yml` keeps `Macdows` out of this bundle's sources.
//
// The claims worth having here are the refusals. "Default off" is the one an accidental export
// could break silently -- a launch by Finder, by Xcode's Run button or by `open` must be
// byte-for-byte what it was before either lane -- and "only `1`" (for `MACDOWS_AUTOCONNECT`) and
// "only a positive whole number of seconds" (for the three `_AFTER_SECONDS` knobs) are the ones a
// well-meaning generalisation would break.

@Suite("adr/0019 §2 R-6 T1-a / adr/0020 lane K — the unattended-launch knobs, parsed")
struct ShellAutolaunchTests {

    // MARK: - The default

    /// The launch every human gets. Not "autoconnect is false" alone: the whole plan, compared as
    /// one value against the constant the type publishes as its own default, so a knob added later
    /// that defaults to ON cannot slip past this file.
    @Test("an empty environment plans nothing")
    func emptyEnvironmentPlansNothing() {
        #expect(ShellAutolaunch.plan(environment: [:]) == ShellAutolaunch.off)
        #expect(
            ShellAutolaunch.off
                == ShellAutolaunch.Plan(autoconnect: false, quitAfter: nil, disconnectAfter: nil, reconnectAfter: nil))
    }

    /// An environment that is busy but says nothing about any knob. Guards against a reader
    /// that keys on a prefix or on "some variable is set" rather than on these four exact names.
    @Test("an environment full of other variables plans nothing")
    func unrelatedEnvironmentPlansNothing() {
        let environment = [
            "HOME": "/Users/nobody",
            "MACDOWS_REPO": "/somewhere",
            "MACDOWS_AUTOCONNECT_": "1",
            "XMACDOWS_AUTOCONNECT": "1",
            "MACDOWS_QUIT_AFTER_SECOND": "10",
            "MACDOWS_DISCONNECT_AFTER_SECOND": "10",
            "MACDOWS_RECONNECT_AFTER_SECOND": "10",
            "WINDOW_SMOKE_CYCLES": "20",
        ]
        #expect(ShellAutolaunch.plan(environment: environment) == ShellAutolaunch.off)
    }

    // MARK: - MACDOWS_AUTOCONNECT

    @Test("MACDOWS_AUTOCONNECT=1 is the one spelling that turns autoconnect on")
    func autoconnectOn() {
        let plan = ShellAutolaunch.plan(environment: [ShellAutolaunch.autoconnectKey: "1"])
        #expect(plan.autoconnect)
        // On, and still no self-imposed lifetime ceiling: the knobs are independent.
        #expect(plan.quitAfter == nil)
    }

    /// Every spelling that must NOT connect. `0` and the empty string are the ones an orchestrator
    /// would actually write to mean "off"; `true`/`yes`/`on`/`Y` are the ones a reader generalised
    /// to a boolean parser would accept; `01`, `1 `, ` 1`, `1.0`, `11` are the ones a prefix,
    /// suffix or numeric-value comparison would let through.
    @Test(
        "every other value leaves autoconnect off",
        arguments: ["", "0", "2", "11", "01", "1 ", " 1", "\t1", "1\n", "1.0", "true", "TRUE", "yes", "on", "Y", "-1", "+1"]
    )
    func autoconnectOffForEverythingElse(value: String) {
        let plan = ShellAutolaunch.plan(environment: [ShellAutolaunch.autoconnectKey: value])
        #expect(!plan.autoconnect, "value \(String(reflecting: value)) must not turn autoconnect on")
    }

    // MARK: - MACDOWS_QUIT_AFTER_SECONDS

    @Test("a whole number of seconds becomes the ceiling", arguments: [1, 2, 10, 60, 600, 3600])
    func quitAfterAcceptsWholeSeconds(value: Int) {
        let plan = ShellAutolaunch.plan(environment: [ShellAutolaunch.quitAfterKey: String(value)])
        #expect(plan.quitAfter == .seconds(value))
        #expect(plan.quitAfterInterval == TimeInterval(value))
        // A ceiling is not a connect order.
        #expect(!plan.autoconnect)
    }

    /// The refusals, and the claim the brief singles out: a non-numeric value yields `nil` rather
    /// than trapping. Each of these is run through the parser, so a crash here is a test failure
    /// and not a silently different answer.
    @Test(
        "anything that is not a positive whole number yields no ceiling",
        arguments: ["", "abc", "10s", "1e3", "10.5", ".5", "-1", "-0", "0", "00", " 10", "10 ", "1_0", "0x10", "٩", "9999999999999999999999"]
    )
    func quitAfterRefusesEverythingElse(value: String) {
        let plan = ShellAutolaunch.plan(environment: [ShellAutolaunch.quitAfterKey: value])
        #expect(plan.quitAfter == nil, "value \(String(reflecting: value)) must not become a ceiling")
        #expect(plan.quitAfterInterval == nil)
    }

    /// `quitAfter(_:)` answers the same for a missing key as for an unparsable one, which is what
    /// lets `plan(environment:)` treat "absent" and "nonsense" as one branch.
    @Test("a missing value and an unparsable one are the same answer")
    func quitAfterMissingEqualsUnparsable() {
        #expect(ShellAutolaunch.quitAfter(nil) == nil)
        #expect(ShellAutolaunch.quitAfter("nonsense") == nil)
        #expect(ShellAutolaunch.quitAfter("7") == .seconds(7))
    }

    // MARK: - adr/0020 lane K: MACDOWS_DISCONNECT_AFTER_SECONDS

    /// Same acceptance shape as `MACDOWS_QUIT_AFTER_SECONDS`, read into its own field by its own
    /// key -- the claim worth having here is that `plan(environment:)` wires the key to
    /// `disconnectAfter` and nothing else (not `quitAfter`, not `reconnectAfter`). Autoconnect is
    /// held ON throughout: gate r1 I-2 makes that a precondition (see the gate-r1-I-2 section
    /// below), so a test of the parse's OWN acceptance shape has to satisfy it to observe anything
    /// other than `nil`.
    @Test("a whole number of seconds becomes the Disconnect delay, given autoconnect", arguments: [1, 2, 10, 60, 600, 3600])
    func disconnectAfterAcceptsWholeSeconds(value: Int) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: String(value),
        ])
        #expect(plan.disconnectAfter == .seconds(value))
        #expect(plan.disconnectAfterInterval == TimeInterval(value))
        #expect(plan.quitAfter == nil)
        #expect(plan.reconnectAfter == nil)
        #expect(plan.autoconnect)
    }

    /// The rejection matrix, same shape as `quitAfterRefusesEverythingElse`: a knob that presses a
    /// real Disconnect button is exactly as unforgiving of a spelling nobody meant. Autoconnect is
    /// held ON so a malformed value is refused by the SHARED PARSE (`quitAfter(_:)`), not merely
    /// because I-2's own gate would already have refused it.
    @Test(
        "anything that is not a positive whole number never schedules a Disconnect press, even with autoconnect on",
        arguments: ["", "abc", "10s", "1e3", "10.5", ".5", "-1", "-0", "0", "00", " 10", "10 ", "1_0", "0x10", "٩", "9999999999999999999999"]
    )
    func disconnectAfterRefusesEverythingElse(value: String) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: value,
        ])
        #expect(plan.disconnectAfter == nil, "value \(String(reflecting: value)) must not schedule a Disconnect press")
        #expect(plan.disconnectAfterInterval == nil)
    }

    // MARK: - adr/0020 lane K: MACDOWS_RECONNECT_AFTER_SECONDS

    /// Same acceptance shape again, for the Connect-again delay -- with autoconnect ON and a valid
    /// `disconnectAfter` held in place throughout, since gate r1 I-2 makes both a precondition for
    /// `reconnectAfter` ever holding a value at all (see the gate-r1-I-2 section below).
    @Test(
        "a whole number of seconds becomes the reconnect delay, given autoconnect and a valid Disconnect delay",
        arguments: [1, 2, 10, 60, 600, 3600]
    )
    func reconnectAfterAcceptsWholeSeconds(value: Int) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: String(value),
        ])
        #expect(plan.reconnectAfter == .seconds(value))
        #expect(plan.reconnectAfterInterval == TimeInterval(value))
        #expect(plan.quitAfter == nil)
        #expect(plan.disconnectAfter == .seconds(30))
        #expect(plan.autoconnect)
    }

    /// The rejection matrix for the reconnect delay's OWN parse, isolated from I-2's gate by
    /// holding autoconnect on and `disconnectAfter` valid throughout.
    @Test(
        "anything that is not a positive whole number never schedules a reconnect press, even with autoconnect and a valid Disconnect delay",
        arguments: ["", "abc", "10s", "1e3", "10.5", ".5", "-1", "-0", "0", "00", " 10", "10 ", "1_0", "0x10", "٩", "9999999999999999999999"]
    )
    func reconnectAfterRefusesEverythingElse(value: String) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: value,
        ])
        #expect(plan.reconnectAfter == nil, "value \(String(reflecting: value)) must not schedule a reconnect press")
        #expect(plan.reconnectAfterInterval == nil)
        #expect(plan.disconnectAfter == .seconds(30), "the reconnect knob's own junk must not take the Disconnect delay down with it")
    }

    // MARK: - adr/0020 lane K, gate r1 I-2 (folded in): the knobs' own wiring-level preconditions

    /// I-2: `MACDOWS_DISCONNECT_AFTER_SECONDS` is meaningless without an autoconnected session for
    /// it to end, and letting it schedule anyway would be a second, laxer unattended-dial path that
    /// does not require `MACDOWS_AUTOCONNECT=1` at all -- exactly what that key's own doc comment
    /// argues against paying for. So the value is read but the answer is forced to `nil` whenever
    /// autoconnect did not turn on, whatever the raw string said (the arguments are values that
    /// would otherwise parse cleanly) -- and `reconnectAfter` follows it to `nil`, since it has no
    /// valid Disconnect delay to be relative to either.
    @Test(
        "MACDOWS_DISCONNECT_AFTER_SECONDS never schedules without MACDOWS_AUTOCONNECT=1, and neither does the reconnect delay behind it",
        arguments: [1, 30, 3600]
    )
    func disconnectAfterIsNilWithoutAutoconnect(value: Int) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.disconnectAfterKey: String(value),
            ShellAutolaunch.reconnectAfterKey: String(value),
        ])
        #expect(plan.disconnectAfter == nil)
        #expect(plan.reconnectAfter == nil)
        #expect(!plan.autoconnect)
    }

    /// I-2's second half: `MACDOWS_RECONNECT_AFTER_SECONDS` has no Disconnect press to be "after"
    /// unless `disconnectAfter` itself parsed to a value -- autoconnect alone is not enough if the
    /// Disconnect delay's own value was junk.
    @Test(
        "MACDOWS_RECONNECT_AFTER_SECONDS never schedules without a valid Disconnect delay, even with autoconnect on",
        arguments: ["", "abc", "0", "-1", "later"]
    )
    func reconnectAfterIsNilWithoutValidDisconnectAfter(disconnectValue: String) {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: disconnectValue,
            ShellAutolaunch.reconnectAfterKey: "15",
        ])
        #expect(plan.disconnectAfter == nil)
        #expect(plan.reconnectAfter == nil)
        #expect(plan.autoconnect)
    }

    // MARK: - adr/0020 lane K, gate r1 m-2 (folded in): the ceiling leaving no room

    /// m-2: a `MACDOWS_QUIT_AFTER_SECONDS` ceiling due AT OR BEFORE the Disconnect press (t1 >= Q)
    /// makes that press, and any reconnect chained off it, pointless -- both are forced to `nil`,
    /// not merely left to race `NSApp.terminate`.
    @Test("a ceiling at or before the Disconnect delay cancels both new knobs")
    func ceilingAtOrBeforeDisconnectCancelsBoth() {
        let atCeiling = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "30",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: "5",
        ])
        #expect(atCeiling.disconnectAfter == nil)
        #expect(atCeiling.reconnectAfter == nil)
        #expect(atCeiling.quitAfter == .seconds(30))

        let pastCeiling = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "30",
            ShellAutolaunch.disconnectAfterKey: "45",
        ])
        #expect(pastCeiling.disconnectAfter == nil)
        #expect(pastCeiling.reconnectAfter == nil)
    }

    /// m-2: the same cancellation when only t1 + t2 TOGETHER reach the ceiling -- t1 alone still
    /// has room, but the reconnect chained after it would not.
    @Test("a ceiling at or before the Disconnect delay plus the reconnect delay cancels both")
    func ceilingAtOrBeforeDisconnectPlusReconnectCancelsBoth() {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "40",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: "10",
        ])
        #expect(plan.disconnectAfter == nil)
        #expect(plan.reconnectAfter == nil)
        #expect(plan.quitAfter == .seconds(40))
    }

    /// m-2: comfortably under the ceiling still schedules both -- the cut above is a NECESSARY
    /// condition, not a blanket refusal of the pair whenever any ceiling exists.
    @Test("a ceiling well past the Disconnect delay and the reconnect delay leaves both scheduled")
    func ceilingWithRoomLeavesBothScheduled() {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "600",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: "15",
        ])
        #expect(plan.disconnectAfter == .seconds(30))
        #expect(plan.reconnectAfter == .seconds(15))
    }

    // MARK: - adr/0020 lane K, gate r1 I-1 (folded in): the press anchor line's shape

    /// I-1: the fixed-shape line an orchestrator greps stdout (or the unified log) for to locate
    /// the instant of either press. Value-tested here because `notePress(_:)` itself only prints
    /// and logs -- this is the shape `pressLine(_:)` hands it, and never `[reconnect]`, so it
    /// cannot be mistaken for a member of that frozen line family.
    @Test("pressLine spells the fixed anchor shape for each press, never [reconnect]")
    func pressLineIsTheFixedAnchorShape() {
        #expect(ShellAutolaunch.pressLine(.disconnect) == "[autolaunch] press=disconnect")
        #expect(ShellAutolaunch.pressLine(.connect) == "[autolaunch] press=connect")
        #expect(!ShellAutolaunch.pressLine(.disconnect).hasPrefix("[reconnect]"))
        #expect(!ShellAutolaunch.pressLine(.connect).hasPrefix("[reconnect]"))
    }

    // MARK: - Independence

    /// Both T1 knobs at once, and each with the OTHER one malformed. The failure this rules out
    /// is a parser that bails on the first unusable value and reports the default for both.
    @Test("the two T1 knobs are independent")
    func knobsAreIndependent() {
        let both = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "45",
        ])
        #expect(
            both == ShellAutolaunch.Plan(autoconnect: true, quitAfter: .seconds(45), disconnectAfter: nil, reconnectAfter: nil))

        let connectOnlyBecauseTheCeilingIsJunk = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "later",
        ])
        #expect(
            connectOnlyBecauseTheCeilingIsJunk
                == ShellAutolaunch.Plan(autoconnect: true, quitAfter: nil, disconnectAfter: nil, reconnectAfter: nil))

        let ceilingOnlyBecauseTheConnectKnobIsJunk = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "true",
            ShellAutolaunch.quitAfterKey: "45",
        ])
        #expect(
            ceilingOnlyBecauseTheConnectKnobIsJunk
                == ShellAutolaunch.Plan(autoconnect: false, quitAfter: .seconds(45), disconnectAfter: nil, reconnectAfter: nil))
    }

    /// adr/0020 lane K: all four knobs at once, and the two new ones with each other and with the
    /// two T1 knobs malformed in turn, WHEN THEIR OWN PRECONDITIONS (gate r1 I-2) ARE MET. Same
    /// failure mode ruled out as above (a parser that bails on the first unusable value and
    /// reports the default for both), extended to the pair this lane adds -- with autoconnect held
    /// on and a valid `disconnectAfter` held in place throughout, since I-2's own gate cases are
    /// pinned separately by `disconnectAfterIsNilWithoutAutoconnect` and
    /// `reconnectAfterIsNilWithoutValidDisconnectAfter` above.
    @Test("the lane K knobs are independent of each other and of the T1 knobs, once I-2's own preconditions are met")
    func laneKKnobsAreIndependent() {
        let all4 = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "600",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: "15",
        ])
        #expect(
            all4
                == ShellAutolaunch.Plan(
                    autoconnect: true, quitAfter: .seconds(600), disconnectAfter: .seconds(30), reconnectAfter: .seconds(15)))

        let disconnectSurvivesAJunkCeiling = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "later",
            ShellAutolaunch.disconnectAfterKey: "30",
        ])
        #expect(
            disconnectSurvivesAJunkCeiling
                == ShellAutolaunch.Plan(autoconnect: true, quitAfter: nil, disconnectAfter: .seconds(30), reconnectAfter: nil))

        let disconnectOnlyBecauseReconnectIsJunk = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.disconnectAfterKey: "30",
            ShellAutolaunch.reconnectAfterKey: "never",
        ])
        #expect(
            disconnectOnlyBecauseReconnectIsJunk
                == ShellAutolaunch.Plan(autoconnect: true, quitAfter: nil, disconnectAfter: .seconds(30), reconnectAfter: nil))
    }

    // MARK: - The Duration → TimeInterval conversion AppDelegate hands to Timer

    /// The arithmetic `AppDelegate` cannot carry itself (it is not in this bundle). Sub-second
    /// components are included even though no environment value can produce one today, because the
    /// function is what a later knob with a finer unit would go through.
    @Test("seconds(_:) converts whole and fractional components")
    func secondsConversion() {
        #expect(ShellAutolaunch.seconds(.seconds(0)) == 0)
        #expect(ShellAutolaunch.seconds(.seconds(10)) == 10)
        #expect(ShellAutolaunch.seconds(.milliseconds(1500)) == 1.5)
        #expect(abs(ShellAutolaunch.seconds(.milliseconds(250)) - 0.25) < 1e-9)
    }
}
