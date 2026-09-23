import Foundation
import Testing

// adr/0019 §2 R-6 tool lane T1-a, the behaviour half. `ShellAutolaunch` is the whole of what the
// two unattended-launch knobs DECIDE; `AppDelegate`'s three statements only act on the answer, and
// they are held by `AppDelegateAutolaunchPinTests`' source pins next door because `App/project.yml`
// keeps `Macdows` out of this bundle's sources.
//
// The claims worth having here are the refusals. "Default off" is the one an accidental export
// could break silently -- a launch by Finder, by Xcode's Run button or by `open` must be
// byte-for-byte what it was before this lane -- and "only `1`" is the one a well-meaning
// generalisation (non-empty means on, `true` means on) would break.

@Suite("adr/0019 §2 R-6 T1-a — the unattended-launch knobs, parsed")
struct ShellAutolaunchTests {

    // MARK: - The default

    /// The launch every human gets. Not "autoconnect is false" alone: the whole plan, compared as
    /// one value against the constant the type publishes as its own default, so a knob added later
    /// that defaults to ON cannot slip past this file.
    @Test("an empty environment plans nothing")
    func emptyEnvironmentPlansNothing() {
        #expect(ShellAutolaunch.plan(environment: [:]) == ShellAutolaunch.off)
        #expect(ShellAutolaunch.off == ShellAutolaunch.Plan(autoconnect: false, quitAfter: nil))
    }

    /// An environment that is busy but says nothing about either knob. Guards against a reader
    /// that keys on a prefix or on "some variable is set" rather than on these two exact names.
    @Test("an environment full of other variables plans nothing")
    func unrelatedEnvironmentPlansNothing() {
        let environment = [
            "HOME": "/Users/nobody",
            "MACDOWS_REPO": "/somewhere",
            "MACDOWS_AUTOCONNECT_": "1",
            "XMACDOWS_AUTOCONNECT": "1",
            "MACDOWS_QUIT_AFTER_SECOND": "10",
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

    // MARK: - Independence

    /// Both knobs at once, and each knob with the OTHER one malformed. The failure this rules out
    /// is a parser that bails on the first unusable value and reports the default for both.
    @Test("the two knobs are independent")
    func knobsAreIndependent() {
        let both = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "45",
        ])
        #expect(both == ShellAutolaunch.Plan(autoconnect: true, quitAfter: .seconds(45)))

        let connectOnlyBecauseTheCeilingIsJunk = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "1",
            ShellAutolaunch.quitAfterKey: "later",
        ])
        #expect(connectOnlyBecauseTheCeilingIsJunk == ShellAutolaunch.Plan(autoconnect: true, quitAfter: nil))

        let ceilingOnlyBecauseTheConnectKnobIsJunk = ShellAutolaunch.plan(environment: [
            ShellAutolaunch.autoconnectKey: "true",
            ShellAutolaunch.quitAfterKey: "45",
        ])
        #expect(ceilingOnlyBecauseTheConnectKnobIsJunk == ShellAutolaunch.Plan(autoconnect: false, quitAfter: .seconds(45)))
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
