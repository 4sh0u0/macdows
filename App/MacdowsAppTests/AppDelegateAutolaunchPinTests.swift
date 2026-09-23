import CryptoKit
import Foundation
import Testing

// adr/0019 §2 R-6 tool lane T1-b, the wiring half. `App/project.yml` gives this bundle the sources
// `MacdowsAppTests` + `RemoteWindowRendering` + `SessionControl` and deliberately not `Macdows`, so
// `AppDelegate` does not exist here as a type at all: source text is the only instrument available,
// the same instrument `AppDelegateReconnectWiringPinTests`, `ReconnectSemanticsPinTests` and
// `ProductScaleDefaultPinTests` already use on this same file and for this same reason.
//
// What these four pins are FOR. `ShellAutolaunch` decides what the two knobs mean and is covered by
// ordinary tests next door; the claims here are the ones no value can carry:
//
//  1. The knobs are read ONCE, and inside `applicationDidFinishLaunching`. One reading per launch,
//     at the end of the launch, is the whole of the contract -- a second call site could answer
//     differently for the same process, and a reading moved elsewhere would fire at a moment no
//     orchestrator is waiting for.
//  2. Autoconnect presses the REAL button: exactly one no-argument `connectTapped()` invocation
//     exists in the file, and it is that one. Copying any step out of `connectTapped` would bypass
//     the host.env read, the live-host boundary gate or the `isCheckingBoundary` interlock -- the
//     three things that make an unattended connect as safe as a human one.
//  3. The quit ceiling goes through `NSApp.terminate`, once. That is the only route that runs
//     `applicationWillTerminate`, whose detach -> shutdownAndWait -> endSession sequence is part of
//     what an unattended run exists to exercise; `exit()` or an outside SIGTERM would skip it.
//  4. EVERYTHING FROM `connectTapped` TO THE END OF THE FILE IS UNCHANGED. This lane was allowed to
//     append statements to the end of `applicationDidFinishLaunching` and nothing else, and the
//     fingerprint below is what says so without quoting 22 KB of source.
//
// REGISTERED GAP, stated rather than papered over: these pins check that the wiring is WRITTEN, not
// that it RUNS. No offline test in this repository can launch this app, set an environment variable
// for it, or watch its Timer fire. Closing the gap means splitting `AppDelegate` into a target this
// bundle can compile, which is a different lane; the run-time evidence for this lane is the
// orchestrator's own `app-stdout-<sub>.log` (a launch with the knobs off produces no `[reconnect]`
// line and no self-termination; a launch with them on produces both).

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func autolaunchRawSource(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Every run of whitespace collapsed to a single space -- the "fold" a pin is about, so that
/// re-wrapping a comment or re-indenting a block is invisible to it while any change to the tokens
/// is not. Comments included: this is the form pin 4 fingerprints.
private func autolaunchFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The same fold with line comments removed first, so a pin ON A CALL is not also a pin on the
/// prose that explains it. Needed here because this lane's own comments deliberately quote the very
/// needles pins 1-3 count (`ShellAutolaunch.plan(`, `connectTapped()`, `NSApp.terminate`): counting
/// over the raw text would count the explanation as a second call site, which is the exact failure
/// mode recorded for this repository's earlier name-count pins.
///
/// LIMITATION, checked rather than assumed: `//` inside a string literal would be stripped too.
/// `AppDelegate.swift` contains none, and `theCommentStripperDidNotEatTheCode` below is what keeps
/// that true.
private func autolaunchCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return autolaunchFolded(lines.joined(separator: " "))
}

private func autolaunchOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The index of `needle` inside `haystack`. Fails the test rather than returning a sentinel, so
/// "the call vanished" can never read as "the call is in the right place".
private func autolaunchIndex(of needle: String, in haystack: String) throws -> String.Index {
    let found = try #require(haystack.range(of: needle), "not found: \(needle)")
    return found.lowerBound
}

private func autolaunchSHA256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite("adr/0019 §2 R-6 T1-b — the unattended-launch knobs' wiring in AppDelegate, pinned as source")
struct AppDelegateAutolaunchPinTests {

    private static let appDelegate = "App/Macdows/AppDelegate.swift"
    private static let shellAutolaunch = "App/SessionControl/ShellAutolaunch.swift"

    /// Where `applicationDidFinishLaunching`'s body ends, for every "inside the launch method" claim
    /// below: the next declaration in the file. Using the NEXT declaration rather than a closing
    /// brace means the bound moves with the file instead of with a line number.
    private static let firstDeclarationAfterLaunch = "@objc private func connectTapped() {"

    private static func code() throws -> String {
        try autolaunchCodeOnly(autolaunchRawSource(appDelegate))
    }

    /// The comment stripper's own guard (the shape `AppDelegateReconnectWiringPinTests` established).
    /// If it ever ate code, every count below would start passing vacuously against a shorter file.
    @Test("the comment stripper leaves the code it is asked about intact")
    func theCommentStripperDidNotEatTheCode() throws {
        let code = try Self.code()
        #expect(code.contains("let autolaunch = ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment)"))
        #expect(code.contains("func applicationDidFinishLaunching(_ notification: Notification) {"))
        #expect(code.contains(Self.firstDeclarationAfterLaunch))
        #expect(code.contains("func applicationWillTerminate(_ notification: Notification) {"))
    }

    // MARK: - Pin 1: read once, inside applicationDidFinishLaunching

    @Test("ShellAutolaunch.plan is called exactly once, with the process environment")
    func planIsCalledExactlyOnce() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "ShellAutolaunch.plan(", in: code) == 1)
        // The call SHAPE, not just the name: a call handed a hand-built dictionary, or a second
        // argument, would be a different reading of the launch than the one this lane ships.
        #expect(
            autolaunchOccurrences(
                of: "ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment)",
                in: code) == 1)
    }

    @Test("that one call is inside applicationDidFinishLaunching")
    func planIsCalledInsideLaunch() throws {
        let code = try Self.code()
        let launch = try autolaunchIndex(
            of: "func applicationDidFinishLaunching(_ notification: Notification) {", in: code)
        let plan = try autolaunchIndex(of: "ShellAutolaunch.plan(", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(launch < plan)
        #expect(plan < nextDeclaration)
    }

    /// ADJACENCY, not just containment -- gate r1 I1.
    ///
    /// The ordering pin above bounds the call by "the next declaration in the file", and ANY method
    /// inserted between `applicationDidFinishLaunching` and `connectTapped` sits inside that bound.
    /// Gate r1's mutant A12 moved all three statements verbatim into a private helper declared in
    /// exactly that gap and called by nobody: the knobs became dead code -- the app neither
    /// autoconnects nor self-terminates -- and every other pin here stayed green, because the
    /// counts, the call shape and the frozen tail were all still exactly what they had been.
    ///
    /// What closes it is naming the statement the three follow. `self.statusLabel.stringValue =
    /// note }` is the last line of the display-change closure, i.e. the end of the launch method's
    /// previous body; a needle that spans it and the three new statements can only match while they
    /// really are the tail of THAT method.
    ///
    /// COST, stated rather than hidden: the closure's last two statements are now part of this
    /// lane's frozen face. They were already the line above this lane's only hunk. A later lane that
    /// legitimately edits the end of `applicationDidFinishLaunching` re-freezes this needle in the
    /// same commit, exactly as it would the tail fingerprint below.
    @Test("the three statements are the tail of applicationDidFinishLaunching, not a stray helper")
    func theKnobsAreTheTailOfTheLaunchMethod() throws {
        let code = try Self.code()
        #expect(
            code.contains(
                "self.lastDisplayChangeNote = note self.statusLabel.stringValue = note } "
                    + "let autolaunch = ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment) "
                    + "if autolaunch.autoconnect { connectTapped() } "
                    + "if let quitAfter = autolaunch.quitAfterInterval {"))
    }

    // MARK: - Pin 2: autoconnect presses the real button

    /// Two occurrences of `connectTapped()` in the whole file: the declaration, and exactly one
    /// no-argument invocation. `#selector(connectTapped)` carries no parentheses of its own and so
    /// is not counted by this needle -- the target-action binding is a separate claim, pinned by its
    /// own line below.
    @Test("there is exactly one no-argument connectTapped() invocation")
    func exactlyOneConnectTappedInvocation() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "func connectTapped()", in: code) == 1)
        #expect(autolaunchOccurrences(of: "connectTapped()", in: code) == 2)
        #expect(autolaunchOccurrences(of: "#selector(connectTapped)", in: code) == 1)
    }

    @Test("the invocation is the autoconnect branch, inside applicationDidFinishLaunching")
    func theInvocationIsTheAutoconnectBranch() throws {
        let code = try Self.code()
        #expect(code.contains("if autolaunch.autoconnect { connectTapped() }"))
        let invocation = try autolaunchIndex(of: "if autolaunch.autoconnect { connectTapped() }", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(invocation < nextDeclaration)
    }

    // MARK: - Pin 3: the quit ceiling goes through NSApp.terminate, once

    @Test("NSApp.terminate is called exactly once, from a one-shot timer inside the launch method")
    func terminateIsCalledExactlyOnce() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "NSApp.terminate(", in: code) == 1)
        #expect(autolaunchOccurrences(of: "NSApp.terminate(nil)", in: code) == 1)
        // The call shape of the timer that reaches it: `repeats: false` is load-bearing (a
        // repeating ceiling would re-send terminate to an app already tearing down), and the
        // interval comes from the plan rather than from a literal.
        #expect(
            autolaunchOccurrences(
                of: "_ = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in",
                in: code) == 1)
        #expect(code.contains("if let quitAfter = autolaunch.quitAfterInterval {"))

        let terminate = try autolaunchIndex(of: "NSApp.terminate(", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(terminate < nextDeclaration)
    }

    /// Nothing else was given a way to end the process. `exit(` and a `SIGTERM` handler are the two
    /// alternatives that would skip `applicationWillTerminate` entirely.
    @Test("no other route out of the process was added")
    func noOtherExitRoute() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "exit(", in: code) == 0)
        #expect(autolaunchOccurrences(of: "signal(", in: code) == 0)
    }

    // MARK: - Pin 4: everything from connectTapped to the end of the file is untouched

    /// The fold of `AppDelegate.swift` from `@objc private func connectTapped() {` to the end of the
    /// file, fingerprinted. At main `beaaee0` -- the merge base this lane branched from, before any
    /// edit here -- that region folded to 22638 characters hashing to the constant below, and this
    /// lane changed none of it.
    ///
    /// Why a hash and not a quoted literal: the region is ~22 KB, which is not a thing to paste into
    /// a test, and an excerpt would pin only the excerpt. Why the fold WITH comments: the claim is
    /// "byte-identical", and a fold is stable under re-wrapping and re-indentation (the two edits
    /// that are genuinely nothing) while still red on a single reworded word.
    ///
    /// WHAT A FAILURE MEANS: not necessarily a defect. A later lane that legitimately edits
    /// `connectTapped`, `beginSession`, `drainTick`, `applyShell` or `applicationWillTerminate` is
    /// expected to re-freeze this constant in the same commit that makes the edit, and the length
    /// below is here so that such a re-freeze can be sanity-checked (a length that MOVED by the size
    /// of the edit is a re-freeze; a length that moved by 22638 is a needle that stopped matching).
    private static let foldedTailLength = 22638
    private static let foldedTailSHA256 =
        "6315858537ce205f9181c7f8187294a06220235c98290dee6d4b53f671740f64"

    @Test("connectTapped to end-of-file is byte-identical to the merge base")
    func theRestOfTheFileIsUnchanged() throws {
        let raw = try autolaunchRawSource(Self.appDelegate)
        #expect(autolaunchOccurrences(of: Self.firstDeclarationAfterLaunch, in: raw) == 1)
        let start = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: raw)
        let folded = autolaunchFolded(String(raw[start...]))
        #expect(folded.count == Self.foldedTailLength)
        #expect(autolaunchSHA256(folded) == Self.foldedTailSHA256)
    }

    // MARK: - The knob names the orchestrator greps for

    /// `form1-batch.sh`'s third pre-check refuses to start a batch unless `ShellAutolaunch.swift`
    /// mentions `MACDOWS_AUTOCONNECT` -- the same "does this checkout support the knob at all"
    /// shape `soak-batch.sh` uses for `WINDOW_SMOKE_CYCLES`. That check reads a literal out of this
    /// file, so the literal has to stay spelled out here rather than being assembled at run time.
    @Test("both knob names appear literally in ShellAutolaunch.swift")
    func knobNamesAreGreppable() throws {
        let raw = try autolaunchRawSource(Self.shellAutolaunch)
        #expect(raw.contains("\"MACDOWS_AUTOCONNECT\""))
        #expect(raw.contains("\"MACDOWS_QUIT_AFTER_SECONDS\""))
    }

    /// The app's ONE permission, declared. `App/project.yml`'s own comment about the test bundle's
    /// generated plist says the app target's plist "carries real usage-description keys"; until this
    /// lane it carried none, so the first local-network dialog -- the single human step the whole
    /// unattended story still needs -- would have shown no reason at all. Local Network is the only
    /// entry that belongs here: a grep of `App/` and `Packages/` finds no Accessibility, Screen
    /// Recording or Input Monitoring API anywhere in this project.
    @Test("the app plist declares the local-network usage description")
    func plistDeclaresLocalNetworkUsage() throws {
        let raw = try autolaunchRawSource("App/Macdows/Info.plist")
        #expect(raw.contains("<key>NSLocalNetworkUsageDescription</key>"))
        // Tracked file: the reason string must not name a host, an address or an account.
        let reason = try #require(
            raw.range(of: "<key>NSLocalNetworkUsageDescription</key>").map { range -> String in
                String(raw[range.upperBound...].prefix(200))
            })
        #expect(!reason.contains("WIN_HOST"))
        #expect(reason.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) == nil)
    }
}
