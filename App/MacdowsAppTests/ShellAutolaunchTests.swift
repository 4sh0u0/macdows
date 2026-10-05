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
        arguments: [
            "", "abc", "10s", "1e3", "1e1", "10.5", "10.0", ".5", "-1", "-0", "+10", "0", "00", " 10", "10 ", "1_0",
            "0x10", "٩", "１０", "9999999999999999999999",
        ]
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

    /// Leading zeros normalise exactly as `Int(_:)` already normalises them -- "010" is ten
    /// seconds, never an octal literal and never refused for the leading zero itself. The same
    /// normalisation rail-probe's `parse_decimal_field` documents for its own knobs.
    @Test("a leading zero normalises like Int(_:), not a refusal")
    func quitAfterNormalisesLeadingZeros() {
        #expect(ShellAutolaunch.quitAfter("010") == .seconds(10))
    }

    /// gate r1 m-5: the boundary a hand-rolled replacement for `Int(_:)` could get wrong silently
    /// -- there is no ceiling below `Int.max` (unlike rail-probe's 3600), so `Int.max` itself must
    /// still be accepted, and a value one digit past it must be refused rather than wrapping
    /// around to a small, plausible-looking number.
    @Test("Int.max is accepted; one digit past it is refused, not wrapped")
    func quitAfterIntMaxBoundary() {
        #expect(ShellAutolaunch.quitAfter(String(Int.max)) == .seconds(Int.max))
        #expect(ShellAutolaunch.quitAfter(String(Int.max) + "0") == nil)
        #expect(ShellAutolaunch.quitAfter(String(repeating: "9", count: 20)) == nil)
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
        arguments: [
            "", "abc", "10s", "1e3", "1e1", "10.5", "10.0", ".5", "-1", "-0", "+10", "0", "00", " 10", "10 ", "1_0",
            "0x10", "٩", "１０", "9999999999999999999999",
        ]
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
        arguments: [
            "", "abc", "10s", "1e3", "1e1", "10.5", "10.0", ".5", "-1", "-0", "+10", "0", "00", " 10", "10 ", "1_0",
            "0x10", "٩", "１０", "9999999999999999999999",
        ]
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

    // MARK: - adr/0021 lane LC-2: MACDOWS_EXTRA_EXEC_AFTER_SECONDS / MACDOWS_EXTRA_EXEC_PROGRAM

    /// A neutral stand-in for a program string. Never a real path: the tests only need something
    /// non-empty that `CRSession.executeProgram(_:)` would accept.
    private static let fakeProgram = "D:\\fixture\\program.exe"

    /// The unattended shape lane LC-2 is gated on, with the pair on top: autoconnect, a ceiling
    /// `quit`, the extra-exec delay `after` and the program. `extra` overrides or adds keys.
    private static func extraExecEnvironment(
        after: String? = "20", program: String? = fakeProgram, quit: String? = "60",
        autoconnect: String? = "1", extra: [String: String] = [:]
    ) -> [String: String] {
        var environment: [String: String] = [:]
        if let autoconnect { environment[ShellAutolaunch.autoconnectKey] = autoconnect }
        if let quit { environment[ShellAutolaunch.quitAfterKey] = quit }
        if let after { environment[ShellAutolaunch.extraExecAfterKey] = after }
        if let program { environment[ShellAutolaunch.extraExecProgramKey] = program }
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Asserts the pair is absent -- both halves, never one (R2: they live and die together).
    private static func expectNoExtraExec(_ plan: ShellAutolaunch.Plan, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(plan.extraExecAfter == nil, sourceLocation: sourceLocation)
        #expect(plan.extraExecProgram == nil, sourceLocation: sourceLocation)
        #expect(plan.extraExecAfterInterval == nil, sourceLocation: sourceLocation)
    }

    @Test("the key names are the two the orchestrator exports")
    func extraExecKeyNames() {
        #expect(ShellAutolaunch.extraExecAfterKey == "MACDOWS_EXTRA_EXEC_AFTER_SECONDS")
        #expect(ShellAutolaunch.extraExecProgramKey == "MACDOWS_EXTRA_EXEC_PROGRAM")
    }

    @Test("off carries no extra exec")
    func offHasNoExtraExec() {
        Self.expectNoExtraExec(ShellAutolaunch.off)
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: [:]))
    }

    @Test("a whole number of seconds below the ceiling schedules the extra exec, counted from launch",
          arguments: [1, 2, 19, 59])
    func extraExecWholeSecondsAccepted(seconds: Int) {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(after: String(seconds)))
        #expect(plan.extraExecAfter == .seconds(seconds))
        #expect(plan.extraExecAfterInterval == TimeInterval(seconds))
        #expect(plan.extraExecProgram == Self.fakeProgram)
        // The other knobs read exactly as they would without the pair.
        #expect(plan.autoconnect)
        #expect(plan.quitAfter == .seconds(60))
        #expect(plan.disconnectAfter == nil)
        #expect(plan.reconnectAfter == nil)
    }

    /// Same grammar as the other `_AFTER_SECONDS` knobs: digits only, strictly positive.
    @Test("anything but a positive whole number of seconds is refused, and takes the program with it",
          arguments: ["", "abc", "1.5", "-5", "0", "00", " 5", "5 ", "+5", "5s", "\u{0665}"])
    func extraExecDelayRefusals(raw: String) {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(after: raw)))
    }

    @Test("a program without a delay schedules nothing")
    func extraExecProgramWithoutDelay() {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(after: nil)))
    }

    @Test("a delay without a program schedules nothing")
    func extraExecDelayWithoutProgram() {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(program: nil)))
    }

    @Test("an empty or all-whitespace program schedules nothing", arguments: ["", " ", "   ", "\t", "\n", " \t\r\n "])
    func extraExecBlankProgram(program: String) {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(program: program)))
    }

    /// Trimmed at both ends, otherwise verbatim: inner spaces, case and backslashes survive.
    @Test("the program is trimmed at both ends and otherwise passed verbatim")
    func extraExecProgramIsTrimmedOnly() {
        let padded = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(program: " \t" + Self.fakeProgram + "\n "))
        #expect(padded.extraExecProgram == Self.fakeProgram)
        let inner = "D:\\Fixture Dir\\Some Program.EXE"
        let verbatim = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(program: inner))
        #expect(verbatim.extraExecProgram == inner)
    }

    @Test("without autoconnect the pair is dropped", arguments: [nil, "0", "true", "yes", " 1"] as [String?])
    func extraExecNeedsAutoconnect(autoconnect: String?) {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(autoconnect: autoconnect)))
    }

    @Test("without a valid ceiling the pair is dropped", arguments: [nil, "", "later", "0"] as [String?])
    func extraExecNeedsCeiling(quit: String?) {
        Self.expectNoExtraExec(ShellAutolaunch.plan(environment: Self.extraExecEnvironment(quit: quit)))
    }

    /// N must be STRICTLY before the ceiling: at it, or past it, there is no live connection left
    /// to deliver into.
    @Test("a delay at or past the ceiling drops the pair", arguments: ["60", "61", "600"])
    func extraExecAtOrPastCeiling(after: String) {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(after: after, quit: "60"))
        Self.expectNoExtraExec(plan)
        #expect(plan.quitAfter == .seconds(60), "the ceiling itself is untouched by the cut")
    }

    /// O-2: with a Disconnect press scheduled, N must be strictly before it as well, so the
    /// extra exec can only land inside the first connection.
    @Test("a delay at or past a scheduled Disconnect drops the pair", arguments: ["30", "31", "45"])
    func extraExecAtOrPastDisconnect(after: String) {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(
            after: after, quit: "60",
            extra: [ShellAutolaunch.disconnectAfterKey: "30", ShellAutolaunch.reconnectAfterKey: "10"]))
        Self.expectNoExtraExec(plan)
        #expect(plan.disconnectAfter == .seconds(30), "the Disconnect press itself is untouched by the cut")
        #expect(plan.reconnectAfter == .seconds(10))
    }

    @Test("N < Disconnect < ceiling schedules the pair alongside the Disconnect press")
    func extraExecBeforeDisconnect() {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(
            after: "29", quit: "60",
            extra: [ShellAutolaunch.disconnectAfterKey: "30", ShellAutolaunch.reconnectAfterKey: "10"]))
        #expect(plan.extraExecAfter == .seconds(29))
        #expect(plan.extraExecProgram == Self.fakeProgram)
        #expect(plan.disconnectAfter == .seconds(30))
        #expect(plan.reconnectAfter == .seconds(10))
    }

    /// A Disconnect value at the ceiling is cancelled by gate r1 m-2, and the extra exec is then
    /// judged against the ceiling alone. With D >= Q, N < Q already implies N < D, so this case
    /// cannot tell "the scheduled Disconnect" from "the raw Disconnect value" apart (gate r1 I-3);
    /// `extraExecWithDisconnectCancelledByTheReconnectSpan` below is the case that does.
    @Test("a Disconnect value the ceiling already cancelled does not gate the pair")
    func extraExecWithCancelledDisconnect() {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(
            after: "40", quit: "50", extra: [ShellAutolaunch.disconnectAfterKey: "50"]))
        #expect(plan.disconnectAfter == nil)
        #expect(plan.extraExecAfter == .seconds(40))
        #expect(plan.extraExecProgram == Self.fakeProgram)
    }

    /// Gate r1 I-3 (folded in): the O-2 comparison is against the Disconnect press the plan
    /// actually SCHEDULES, after gate r1 m-2's cut. Here D = 30 is below the ceiling but D + R = 70
    /// is not, so m-2 cancels both presses; there is then no Disconnect at all and N = 45 is
    /// judged against the ceiling alone (N < Q), even though N is past the raw Disconnect value.
    @Test("a Disconnect cancelled by the reconnect span does not gate the pair (Q=60, D=30, R=40, N=45)")
    func extraExecWithDisconnectCancelledByTheReconnectSpan() {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(
            after: "45", quit: "60",
            extra: [ShellAutolaunch.disconnectAfterKey: "30", ShellAutolaunch.reconnectAfterKey: "40"]))
        #expect(plan.disconnectAfter == nil)
        #expect(plan.reconnectAfter == nil)
        #expect(plan.extraExecAfter == .seconds(45))
        #expect(plan.extraExecProgram == Self.fakeProgram)
    }

    /// The control for the case above: the same Q, D and N with a reconnect span that fits
    /// (D + R = 40 < 60), so the Disconnect press at 30 is scheduled and N = 45 >= D drops the pair.
    @Test("the same N past a scheduled Disconnect drops the pair (Q=60, D=30, R=10, N=45)")
    func extraExecPastAScheduledDisconnectControl() {
        let plan = ShellAutolaunch.plan(environment: Self.extraExecEnvironment(
            after: "45", quit: "60",
            extra: [ShellAutolaunch.disconnectAfterKey: "30", ShellAutolaunch.reconnectAfterKey: "10"]))
        #expect(plan.disconnectAfter == .seconds(30))
        Self.expectNoExtraExec(plan)
    }

    @Test("near-miss key names are not read")
    func extraExecNearMissKeys() {
        let plan = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "60",
            "MACDOWS_EXTRA_EXEC_AFTER_SECOND": "20",
            "MACDOWS_EXTRA_EXEC_PROGRAMS": Self.fakeProgram,
            "XMACDOWS_EXTRA_EXEC_AFTER_SECONDS": "20",
            "MACDOWS_EXTRA_EXEC_PROGRAM_": Self.fakeProgram,
        ])
        Self.expectNoExtraExec(plan)
    }

    /// `Plan.init` stores a half-set pair as neither, so no reader can see one without the other.
    @Test("Plan stores a half-set pair as neither half")
    func planInitKeepsThePairTogether() {
        let delayOnly = ShellAutolaunch.Plan(
            autoconnect: true, quitAfter: .seconds(60), disconnectAfter: nil, reconnectAfter: nil,
            extraExecAfter: .seconds(5), extraExecProgram: nil)
        Self.expectNoExtraExec(delayOnly)
        let programOnly = ShellAutolaunch.Plan(
            autoconnect: true, quitAfter: .seconds(60), disconnectAfter: nil, reconnectAfter: nil,
            extraExecAfter: nil, extraExecProgram: Self.fakeProgram)
        Self.expectNoExtraExec(programOnly)
        #expect(delayOnly == ShellAutolaunch.Plan(autoconnect: true, quitAfter: .seconds(60), disconnectAfter: nil, reconnectAfter: nil))
    }

    // MARK: - adr/0021 lane LC-2: the A-X anchor line

    @Test("pressLine(.extraExec) is the fixed A-X literal, and the earlier presses keep their shape")
    func extraExecPressLineLiteral() {
        #expect(ShellAutolaunch.pressLine(.extraExec) == "[autolaunch] press=extra-exec")
        #expect(ShellAutolaunch.Press.extraExec.rawValue == "extra-exec")
        #expect(ShellAutolaunch.pressLine(.disconnect) == "[autolaunch] press=disconnect")
        #expect(ShellAutolaunch.pressLine(.connect) == "[autolaunch] press=connect")
    }

    @Test("the A-X line carries the program's UTF-8 byte count and the session flag")
    func extraExecPressLineFields() {
        #expect(
            ShellAutolaunch.pressLine(.extraExec, programBytes: Self.fakeProgram.utf8.count, sessionPresent: true)
                == "[autolaunch] press=extra-exec program-bytes=22 session=present")
        #expect(
            ShellAutolaunch.pressLine(.extraExec, programBytes: Self.fakeProgram.utf8.count, sessionPresent: false)
                == "[autolaunch] press=extra-exec program-bytes=22 session=absent")
        // Bytes, not characters: "é" is two UTF-8 bytes, so 1 + 1 + 2 = 4 (the same `.utf8.count`
        // measurement AppDelegate's call site makes, gate r1 I-1).
        #expect(
            ShellAutolaunch.pressLine(.extraExec, programBytes: "a\u{00E9}b".utf8.count, sessionPresent: true)
                == "[autolaunch] press=extra-exec program-bytes=4 session=present")
    }

    /// The red line: whatever the program string is, none of it reaches the line notePress emits.
    /// A unique sentinel makes "none of it" checkable, and every fragment of the fake program is
    /// checked too, not only the sentinel. Since gate r1 I-1 the helper only ever receives the
    /// byte count (its signature is pinned in `AppDelegateAutolaunchPinTests`); this value test
    /// keeps the line itself honest at the pressLine layer.
    @Test("the A-X line never contains the program string or any fragment of it")
    func extraExecPressLineNeverCarriesTheProgram() {
        let sentinel = "zz-sentinel-6c41d0-zz"
        let program = "D:\\fixture\\" + sentinel + "\\program.exe"
        for present in [true, false] {
            let line = ShellAutolaunch.pressLine(.extraExec, programBytes: program.utf8.count, sessionPresent: present)
            #expect(!line.contains(sentinel))
            #expect(!line.contains("fixture"))
            #expect(!line.contains("program.exe"))
            #expect(!line.contains("\\"))
            #expect(!line.contains("D:"))
            #expect(line.hasPrefix("[autolaunch] press=extra-exec program-bytes=\(program.utf8.count) session="))
        }
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
