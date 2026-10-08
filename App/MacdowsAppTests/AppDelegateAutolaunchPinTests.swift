import CryptoKit
import Foundation
import Testing

// adr/0019 §2 R-6 tool lane T1-b, the wiring half. `App/project.yml` gives this bundle the sources
// `MacdowsAppTests` + `RemoteWindowRendering` + `SessionControl` and deliberately not `Macdows`, so
// `AppDelegate` does not exist here as a type at all: source text is the only instrument available,
// the same instrument `AppDelegateReconnectWiringPinTests`, `ReconnectSemanticsPinTests` and
// `ProductScaleDefaultPinTests` already use on this same file and for this same reason.
//
// What these pins are FOR. `ShellAutolaunch` decides what the four knobs mean and is covered by
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
// adr/0020 lane S added a fifth claim here, because it changed what the real button press does
// before it dials (D-8, #6): the host.env read now runs off the main actor, and every way that
// read or the gate can fail hands the button back. Autoconnect presses that same button, so this
// file is where its interlock is held.
//
// adr/0020 lane K added a fifth and sixth: the Disconnect delay knob presses the real
// `endSessionTapped()`, exactly once, from a Timer nested inside the launch method (Pin 5); and
// the reconnect delay knob presses the real `connectTapped()` a second time, from a Timer nested
// inside THAT one (Pin 6, reusing Pin 2's invocation-count shape). Both are real button presses
// for the same reason Pin 2 already is one: `endSessionTapped`'s own guard, its status line, its
// literal `connectButton.isEnabled = true` and its one `tearDownSession()` all have to run for an
// unattended Disconnect exactly as they do for a human one, and copying any step out of it would
// skip one of those.
//
// adr/0020 lane K's gate r1 fold-in added a seventh: an anchor line, printed by
// `ShellAutolaunch.notePress(_:)`, immediately before each of Pin 5's and Pin 6's presses (Pin 7,
// gate r1 I-1) -- neither press otherwise writes anything that says it happened.
//
// adr/0021 lane LC-2 added an eighth: the extra-exec knob schedules ONE one-shot Timer, appended
// after the quit-ceiling block as the new tail of the launch method, whose callback prints the A-X
// anchor line and then makes the file's only `session.executeProgram(` call (Pin 8). Its bridge-side
// witness lines (X-S, X-R, X-C) are held by `BridgeExecWitnessPinTests`.
//
// REGISTERED GAP, stated rather than papered over: these pins check that the wiring is WRITTEN, not
// that it RUNS. No offline test in this repository can launch this app, set an environment variable
// for it, or watch its Timer fire. Closing the gap means splitting `AppDelegate` into a target this
// bundle can compile, which is a different lane; the run-time evidence for this lane is the
// orchestrator's own `app-stdout-<sub>.log` (a launch with the knobs off produces no `[reconnect]`
// line, no `[autolaunch]` line and no self-termination; a launch with T1's own knob on produces the
// first and the last). adr/0020 lane K's own two knobs are evidenced the same way, by the
// `[autolaunch] press=disconnect` / `[autolaunch] press=connect` anchor lines `notePress(_:)`
// writes immediately before each real press -- the one place in this lane's run-time evidence that
// says a press actually happened, not merely that the code to make it compiled (gate r1 I-1).

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
    /// RE-FROZEN by adr/0020 lane K: the needle now spans the two new nested Timers as well, so
    /// the same mutant gate-r1 I1 rules out for T1 (moving a knob's statements into an unrelated
    /// helper declared in the same gap) rules out for the Disconnect/reconnect pair too.
    ///
    /// RE-FROZEN AGAIN by lane K's gate r1 fold-in (I-1): each real press now has
    /// `ShellAutolaunch.notePress(_:)` immediately in front of it, inside the same
    /// `MainActor.assumeIsolated` block -- this is also what Pin 7's adjacency tests below rely on,
    /// stated here as one contiguous needle instead of two.
    ///
    /// RE-FROZEN by adr/0021 lane CA-2: the key-witness switch (`if autolaunch.keyWitness {
    /// CRSession.keyWitnessEnabled = true }`) sits between the one `plan` read and the autoconnect
    /// press, so it is set before any connection this launch starts (Pin 9).
    @Test("the four statements are the tail of applicationDidFinishLaunching, not a stray helper")
    func theKnobsAreTheTailOfTheLaunchMethod() throws {
        let code = try Self.code()
        // Built as a `let`, not inline inside `#expect`: a single expression this long, chained
        // entirely with `+`, made the type checker time out (gate r1's original, T1-sized needle
        // was already close to that ceiling; this lane's longer one crossed it).
        let needle: String =
            "self.lastDisplayChangeNote = note self.statusLabel.stringValue = note } "
            + "let autolaunch = ShellAutolaunch.plan(environment: ProcessInfo.processInfo.environment) "
            + "if autolaunch.keyWitness { CRSession.keyWitnessEnabled = true } "
            + "if autolaunch.autoconnect { connectTapped() } "
            + "if let disconnectAfter = autolaunch.disconnectAfterInterval { "
            + "_ = Timer.scheduledTimer(withTimeInterval: disconnectAfter, repeats: false) { _ in "
            + "MainActor.assumeIsolated { ShellAutolaunch.notePress(.disconnect) self.endSessionTapped() "
            + "if let reconnectAfter = autolaunch.reconnectAfterInterval { "
            + "_ = Timer.scheduledTimer(withTimeInterval: reconnectAfter, repeats: false) { _ in "
            + "MainActor.assumeIsolated { ShellAutolaunch.notePress(.connect) self.connectTapped() } } } } } } "
            + "if let quitAfter = autolaunch.quitAfterInterval {"
        #expect(code.contains(needle))
    }

    // MARK: - Pin 2: autoconnect presses the real button

    /// THREE occurrences of `connectTapped()` in the whole file since adr/0020 lane K: the
    /// declaration, the autoconnect branch's bare invocation, and the reconnect knob's
    /// `self.connectTapped()` (the substring match does not care about the `self.` prefix).
    /// `#selector(connectTapped)` carries no parentheses of its own and so is not counted by this
    /// needle -- the target-action binding is a separate claim, pinned by its own line below.
    @Test("there are exactly two no-argument connectTapped() invocations (autoconnect, reconnect)")
    func exactlyTwoConnectTappedInvocations() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "func connectTapped()", in: code) == 1)
        #expect(autolaunchOccurrences(of: "connectTapped()", in: code) == 3)
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

    // MARK: - Pin 5 (adr/0020 lane K): the Disconnect knob presses the real endSessionTapped()

    /// Same shape as Pin 2, for `endSessionTapped()`: two occurrences in the whole file -- the
    /// declaration, and exactly one no-argument invocation, added by this lane. Before this lane
    /// the only other mention is `#selector(endSessionTapped)`, which (like
    /// `#selector(connectTapped)` above) carries no parentheses and so is not counted here.
    @Test("there is exactly one no-argument endSessionTapped() invocation, from the disconnect knob")
    func exactlyOneEndSessionTappedInvocation() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "func endSessionTapped()", in: code) == 1)
        #expect(autolaunchOccurrences(of: "endSessionTapped()", in: code) == 2)
        #expect(autolaunchOccurrences(of: "#selector(endSessionTapped)", in: code) == 1)
    }

    /// MUST-RED for the "presses the wrong thing" mutant: a knob that calls `self.tearDownSession()`
    /// directly instead would still fail THIS test, but not through a count -- `code.contains(
    /// "self.endSessionTapped()")` below would simply be false. The count assertion that catches
    /// the same mutant a different way (`endSessionTapped()`'s bare-invocation count stopping at 1,
    /// declaration only) lives next door, in `exactlyOneEndSessionTappedInvocation`.
    @Test("the invocation is self.endSessionTapped(), inside applicationDidFinishLaunching")
    func theInvocationIsTheDisconnectAfterBranch() throws {
        let code = try Self.code()
        #expect(code.contains("self.endSessionTapped()"))
        let invocation = try autolaunchIndex(of: "self.endSessionTapped()", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(invocation < nextDeclaration)
    }

    // MARK: - Pin 6 (adr/0020 lane K): the reconnect knob presses the real connectTapped(), after Disconnect

    /// The second `connectTapped()` invocation Pin 2 above now counts, isolated by its `self.`
    /// prefix (the autoconnect branch's own invocation is bare, with no receiver).
    @Test("the second invocation is self.connectTapped(), inside applicationDidFinishLaunching")
    func theSecondInvocationIsTheReconnectAfterBranch() throws {
        let code = try Self.code()
        #expect(code.contains("self.connectTapped()"))
        let invocation = try autolaunchIndex(of: "self.connectTapped()", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(invocation < nextDeclaration)
    }

    /// ORDER, not just presence: the brief for this lane is "press Disconnect, THEN press Connect
    /// again" -- the two presses swapped would leave every count and containment check above
    /// green while reversing the one thing this knob pair is for. `self.connectTapped()`'s only
    /// occurrence is inside the `if let reconnectAfter` block nested inside the `if let
    /// disconnectAfter` block, so its index in the source can only be later than
    /// `self.endSessionTapped()`'s while the nesting is the right way round.
    @Test("the Disconnect press comes before the reconnect press in source order")
    func theDisconnectPressComesBeforeTheReconnectPress() throws {
        let code = try Self.code()
        let disconnect = try autolaunchIndex(of: "self.endSessionTapped()", in: code)
        let reconnect = try autolaunchIndex(of: "self.connectTapped()", in: code)
        #expect(disconnect < reconnect)
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
    /// file, fingerprinted. Frozen first at main `beaaee0` -- the merge base this lane branched from,
    /// before any edit here -- where that region folded to 22638 characters, and this lane changed
    /// none of it.
    ///
    /// RE-FROZEN by the session-end lane (branched from main `00d9994`, where the region was still
    /// those 22638 characters): its three session ends now share `tearDownSession()`, which moved
    /// the connect-error branch, the give-up teardown, `applicationWillTerminate` and the comments
    /// that describe them. The region now folds to 26761 characters hashing to the constant below;
    /// the +4123 is exactly that lane's net folded edit (5983 characters added, 1860 removed), and
    /// everything before `connectTapped` is byte-identical to `00d9994`.
    ///
    /// RE-FROZEN by adr/0020 lane S (branched from main `8a51cf6`, where the region was still those
    /// 26761 characters): the End-session action and the teardown's seventh step, the `.reconnecting`
    /// branch's event-count reset, and the comments that describe them. That commit left the region
    /// folding to 31244 characters, a net folded edit of +4483. Lane S's other hunks -- the
    /// button's stored property, `session`'s `didSet` and the button's construction -- sit before
    /// `connectTapped` and are held by `AppDelegateSessionEndPinTests` instead.
    ///
    /// RE-FROZEN again by lane S's separable D-8 commit (#6): the host.env read moved into the
    /// detached task with its comment, the verdict gained two failure arms, and the result type
    /// `ConnectPreflight` was declared after `connectTapped`. The region folded to 33035
    /// characters, a net folded edit of +1791. Reverting that commit alone restores 31244.
    ///
    /// RE-FROZEN again by lane S's gate r1 fold-in (m-3): `tearDownSession`'s exit-ordering comment
    /// was reworded to match gate r1's G6 exit-probe arm (the "last window" ask fires once, as
    /// termination's own trigger, not a second time from this function's own close) -- after
    /// `connectTapped`, so it is inside this region. (The fold-in's other comment fix, m-2, sits
    /// inside `applicationDidFinishLaunching`'s quit-ceiling block, before `connectTapped`, so it
    /// does not touch this region at all.) The region now folds to 33563 characters hashing to the
    /// constant below, a net folded edit of +528.
    ///
    /// RE-FROZEN again by adr/0022 UI slice ② (with adr/0023): the status item's hand-offs that
    /// sit after `connectTapped` -- `beginSession` records the session's address for it, the
    /// driver's every state change refreshes it, the read-only `statusItemReading()`,
    /// and the `NSMenuItemValidation` extension that validates the Disconnect menu items by the
    /// End-session button's predicate (adr/0022 D-11). The actions themselves are untouched. The
    /// region now folds to 34853 characters, a net folded edit of +1290.
    ///
    /// RE-FROZEN by ADR-0024 UI slice ① commit 1 (the bridge takes the password as bytes, D-2):
    /// `beginSession`'s `CRSession(...)` call passes `passwordBytes: Data(pass.utf8)` instead of the
    /// string. Nothing else in the region moved. It now folds to 34869 characters, +16.
    ///
    /// RE-FROZEN by ADR-0024 UI slice ① commit 3 (host.env retired, D-9; the chain wiring, D-2 /
    /// D-2′ / D-5): `connectTapped` now preflights the selected host record off the main actor
    /// (`ConnectFlow.preflight`) instead of reading host.env, `ConnectPreflight` is gone,
    /// `beginSession` takes the chain's session and its trust context, the drain hooks call
    /// `drainThenReview`, `applyReconnectState` also updates the Hosts window, and the chain helpers
    /// (password sheet, certificate question, failure banners) sit before
    /// `applicationShouldTerminateAfterLastWindowClosed`. `tearDownSession`, `applyShell`,
    /// `endSessionTapped`, `drainTick` and `applicationWillTerminate` are unchanged. It folded to
    /// 43835 characters, +8966.
    ///
    /// RE-FROZEN by the UI-6 gate r1 fold (same commit 3): the preflight runs in
    /// `KeychainQueue.run` instead of a detached task (m-5), the Password sheet's Remember is
    /// recorded only when the save succeeded (m-11), the certificate question clears the give-up
    /// flag (m-13), `applicationShouldTerminateAfterLastWindowClosed` answers false and
    /// `applicationShouldHandleReopen` shows the Hosts window (I-2), and three stale comments
    /// (`applyShell`'s five literal trues, `tearDownSession`'s exit-ordering note, the preflight's
    /// queue) were corrected (m-1). `tearDownSession`'s code, `applyShell`'s code,
    /// `endSessionTapped`, `drainTick` and `applicationWillTerminate` are unchanged. It now folds to
    /// 45012 characters, +1177.
    ///
    /// RE-FROZEN by UI slice ④ commit 1 (UI-1 spec §4.1, the shell in three languages): every English
    /// status-line literal after `connectTapped` became its catalog accessor (`UIStrings.*`); the
    /// connect-error branch logs the error as a `[connect]` line instead of showing its description;
    /// the driver's state handler records the handshake moment (`liveSince`); `applyShell` reads one
    /// summary builder, `connectedSummary()`, and also writes the status bar; the status item's
    /// reading carries `liveSince`; `chainEnded` keeps a give-up's row; the Hosts window's
    /// presentation gets the summary. `tearDownSession` and `applicationWillTerminate` are
    /// unchanged. It folded to 46458 characters, +1446.
    ///
    /// RE-FROZEN by UI slice ④ commit 2 (UI-1 spec §4.2 / §4.3, the session banners): the driver's
    /// state handler reads the leg's input capability once (`inputNotice`) and calls the one banner
    /// writer, `applySessionBanners`, after the Hosts window; the summary builder carries the
    /// capability (`dg_bar`); `chainEnded` clears the connection's banners; the Hosts window's state
    /// write sets the Remote windows note; `sessionBannerModel` wires the banner buttons to existing
    /// paths (gate r1 fold: Learn More to Settings > Keyboard). `tearDownSession`, `endSessionTapped`
    /// and `applicationWillTerminate` are unchanged. It now folds to 49205 characters, +2747.
    ///
    /// RE-FROZEN by RB-2 (adr/0019 supplementary ruling RB-1 (a′)): `drainTick`'s connect-error
    /// branch gained one condition -- it leaves a leg the reconnect driver started to the driver
    /// (`ReconnectDriver.connectErrorBelongsToDriver(in:)`) -- and its comment, and
    /// `tearDownSession`'s connect-error precondition, were rewritten to match. The branch's
    /// statements, `tearDownSession`'s code, `endSessionTapped` and `applicationWillTerminate` are
    /// unchanged. It folded to 50380 characters, +1175.
    ///
    /// RE-FROZEN again by RB-2's gate r1 fold-in (F-1, gate r1 I-3): in `reviewSessionEnd`, the
    /// connect-failure banner of a chain that never went live is now shown only when the end is not
    /// the reconnect driver's give-up (`if !endingByGiveUp { ... }` inside the branch, plus a
    /// two-line comment); the `.connectFailed` record and every other statement stay as they were.
    /// `tearDownSession`, `endSessionTapped`, `drainTick` and `applicationWillTerminate` are
    /// unchanged. It folded to 50570 characters, +190.
    ///
    /// RE-FROZEN by F-1 (owner in-person batch 2026-10-07): `showConnectFailure` builds its banner
    /// through `BannerView.Model.connectFailure` (UI, where the offline tests drive it) and hands it
    /// one more handler, Reconnect, which presses Connect for the host -- the unreachable banner's
    /// new second button; the status bar per kind and every other statement are as they were.
    /// `connectTapped`, `drainTick`, `tearDownSession`, `endSessionTapped` and
    /// `applicationWillTerminate` are unchanged. It now folds to 50608 characters, +38.
    ///
    /// RE-FROZEN by ADR-0025 a-1 commit 2 (the Dock start panel): `beginSession` hands the new
    /// registry's ExecResult forward (`onExecResult`, S-4) to the start panel's launcher;
    /// `applyReconnectState` re-reads the panel after the status item; `sessionPresenceChanged`
    /// re-reads it first thing, so every session end closes it (the teardown keeps its seven steps);
    /// `startPanelReading()` is new beside `statusItemReading()`; the reopen gained its has-session
    /// clause (R-7; the no-session clause is word for word as before, see
    /// `AppDelegateChainPinTests.hostsWindowLifecycle`) and `applicationDockMenu(_:)` its one-line
    /// forward. `connectTapped`, `drainTick`, `tearDownSession`, `endSessionTapped` and
    /// `applicationWillTerminate` are unchanged; no `@objc` was added. It folded to 52179
    /// characters, +1571.
    ///
    /// RE-FROZEN by ADR-0025 a-1b (R-7: a late launch failure also reaches the Hosts window's status
    /// line): `applyShell` hands the presenter one more argument, the start panel's waiting failure
    /// for the chain's host (`lastLaunchFailure: startPanel.lastLaunchFailureReason(for: chainHost)`),
    /// and its doc comment says so in three lines. The panel's change callback that also calls
    /// `applyShell` is wired in `applicationDidFinishLaunching`, before `connectTapped`, so outside
    /// this region. `connectTapped`, `drainTick`, `tearDownSession`, `endSessionTapped`,
    /// `sessionPresenceChanged` and `applicationWillTerminate` are unchanged; no `@objc` was added.
    /// It now folds to 52545 characters, +366.
    ///
    /// The "net folded edit" above is the folded-length delta for each re-freeze, which is what the
    /// length chain below already checks; it is not a token-by-token added/removed count -- those
    /// depend on the diff algorithm and separator convention used to produce them, so this pin does
    /// not restate them.
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
    private static let foldedTailLength = 52545
    private static let foldedTailSHA256 =
        "40ac0323d87858f9f623971fdcc7aa51988653b088ea401a0610ccf892d3cdff"

    @Test("connectTapped to end-of-file is byte-identical to its last deliberate freeze")
    func theRestOfTheFileIsUnchanged() throws {
        let raw = try autolaunchRawSource(Self.appDelegate)
        #expect(autolaunchOccurrences(of: Self.firstDeclarationAfterLaunch, in: raw) == 1)
        let start = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: raw)
        let folded = autolaunchFolded(String(raw[start...]))
        #expect(folded.count == Self.foldedTailLength)
        #expect(autolaunchSHA256(folded) == Self.foldedTailSHA256)
    }

    // MARK: - adr/0020 S-8, rewritten by ADR-0024 D-9: Connect reads no plaintext file, off-main preflight, never locks itself

    /// adr/0020 S-8 as REWRITTEN by ADR-0024 D-9 (M-a; UI slice ①, which retired the App's host.env
    /// read in the same merge, together with its two failure lines). The old clause -- "the host.env
    /// read and its three-key check live INSIDE the `Task.detached` closure" -- has no subject any
    /// more; what it protected carries over in three parts:
    ///
    ///  (a) the App reads no plaintext credential file: no `EnvFile`, no `hostEnvPath`, no
    ///      `host.env` and none of the three WIN_* key names anywhere in the App's product sources
    ///      (comment-stripped; the harnesses under `Tools/` keep theirs, D-9 M-a). The host comes
    ///      from the selected host record, the password from the keychain or the Password sheet;
    ///  (b) the press's blocking work -- the live-host gate (getaddrinfo) AND the keychain reads
    ///      (the file-based keychain blocks on its authorisation prompt, ADR-0024 probe K) -- runs
    ///      inside the ONE `KeychainQueue.run` body (UI-6 gate r1 m-5: the serial keychain queue,
    ///      never a detached task on the cooperative pool), as `ConnectFlow.preflight(` with the
    ///      gate passed in;
    ///  (c) the interlock: `isCheckingBoundary` is reset once, before the result is read, and every
    ///      arm that starts no session (boundary refusal, pin unavailable) hands Connect back with a
    ///      literal `true` -- the Password sheet's Cancel is the fifth literal, pinned by the wiring
    ///      pins' count. Only `.ready` starts a chain.
    ///
    /// MUST-RED for: any plaintext-file read reintroduced into the App, the preflight moved onto the
    /// main actor, a no-session arm that forgets to re-enable Connect, and an arm that starts a
    /// session on a refusal.
    ///
    /// A LIMIT of (a), registered by UI-6 gate r1 m-7: it counts literal names, and a name built by
    /// concatenation (`"host" + ".env"`) does not contain them -- r1's mutant M13c read the file that
    /// way from `ConnectFlow.swift` and survived. (a′) closes that with CALL shapes instead of
    /// names: outside `HostRecordStore` (`App/UI/Hosts/HostRecord.swift`, the App's one file it
    /// reads, its own JSON) no product source may call a file-reading API at all, whatever path it
    /// builds.
    @Test("ADR-0024 D-9: the App reads no plaintext credential file, and the Connect preflight is off-main and hands the button back")
    func theConnectPressReadsNoFileAndEveryFailureReEnablesConnect() throws {
        // (a)
        var scanned = 0
        for directory in ["App/Macdows", "App/UI", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
            let root = repoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                scanned += 1
                let code = autolaunchCodeOnly(try autolaunchRawSource("\(directory)/\(entry)"))
                for needle in ["EnvFile", "hostEnvPath", "host.env", "WIN_" + "HOST", "WIN_" + "USER", "WIN_" + "PASS"] {
                    #expect(autolaunchOccurrences(of: needle, in: code) == 0, "\(directory)/\(entry): \(needle)")
                }
            }
        }
        #expect(scanned > 20, "the walk found the App's sources (\(scanned))")

        // (a′) gate r1 m-7: file-reading CALL shapes, not names.
        var fileReaders = 0
        var readsInStore = 0
        var readsInLaunchItems = 0
        for directory in ["App/Macdows", "App/UI", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
            let root = repoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                let path = "\(directory)/\(entry)"
                let code = autolaunchCodeOnly(try autolaunchRawSource(path))
                let count = ["contentsOfFile:", "contentsOf:", "contentsAtPath", "FileHandle(forReadingAtPath",
                             "FileHandle(forReadingFrom", "fopen("].reduce(0) { $0 + autolaunchOccurrences(of: $1, in: code) }
                if path == "App/UI/Hosts/HostRecord.swift" {
                    readsInStore = count
                    let store = try autolaunchIndex(of: "final class HostRecordStore", in: code)
                    let read = try autolaunchIndex(of: "Data(contentsOf: fileURL)", in: code)
                    #expect(store < read, "the one read is HostRecordStore's")
                } else if path == "App/UI/StartPanel/LaunchItemStore.swift" {
                    // ADR-0025 R-6 (a-1 commit 2): the App's second and last file read -- the start
                    // panel's own `launch-items.json`, beside `hosts.json`, holding display names,
                    // programs, arguments and times and nothing that signs in. Admitted by exact path
                    // and the same shape as the host store's: one read, inside its own store class.
                    readsInLaunchItems = count
                    let store = try autolaunchIndex(of: "final class LaunchItemStore", in: code)
                    let read = try autolaunchIndex(of: "Data(contentsOf: fileURL)", in: code)
                    #expect(store < read, "the one read is LaunchItemStore's")
                } else {
                    fileReaders += count
                    #expect(count == 0, "\(path) calls a file-reading API")
                }
            }
        }
        #expect(fileReaders == 0)
        #expect(readsInStore == 1, "HostRecordStore reads its own JSON once")
        #expect(readsInLaunchItems == 1, "LaunchItemStore reads its own JSON once")

        // (b)
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "Task.detached(", in: code) == 0)
        #expect(autolaunchOccurrences(of: "KeychainQueue.run {", in: code) == 1)
        #expect(autolaunchOccurrences(of: "ConnectFlow.preflight(", in: code) == 1)
        let queued = try autolaunchIndex(of: "KeychainQueue.run {", in: code)
        let preflight = try autolaunchIndex(of: "ConnectFlow.preflight(", in: code)
        let reset = try autolaunchIndex(of: "self.isCheckingBoundary = false", in: code)
        #expect(queued < preflight && preflight < reset, "the preflight is inside the queued body")
        #expect(autolaunchOccurrences(
            of: "let preflight = await KeychainQueue.run { () -> ConnectFlow.Preflight in "
                + "ConnectFlow.preflight( host: host, address: address, recordSaysPinned: recordSaysPinned, "
                + "remembersPassword: readsKeychain, credentials: credentials, pins: pins, "
                + "boundary: { LabBoundary.check(host: $0) } ) }",
            in: code) == 1)

        // (c)
        #expect(autolaunchOccurrences(
            of: "boundary: { LabBoundary.check(host: $0) } ) } guard let self else { return } self.isCheckingBoundary = false switch preflight { "
                + "case .refusedByBoundary(let refusal): "
                + "self.statusLabel.stringValue = LabBoundary.refusalLine(host: address, refusal: refusal) "
                + "self.connectButton.isEnabled = true "
                + "self.chainEnded() "
                + "case .pinUnavailable(let status): "
                + "self.showPinUnavailable(record, status: status) "
                + "self.connectButton.isEnabled = true "
                + "self.chainEnded() "
                + "case .ready(let context, let secret?, _): "
                + "self.beginChain(record, context: context, secret: secret) "
                + "case .ready(let context, nil, let keychainStatus): ",
            in: code) == 1)
        #expect(autolaunchOccurrences(of: "isCheckingBoundary = false", in: code) == 2,
                "the stored property's initial value, and the one reset in front of the result")
    }

    // MARK: - Pin 7 (adr/0020 lane K, gate r1 I-1): the press anchor, before each real press

    /// `ShellAutolaunch.notePress(` appears exactly twice in the whole file, once per real press
    /// this lane adds, and nowhere else -- there is no third occasion in this file for an anchor
    /// line.
    ///
    /// RE-COUNTED by adr/0021 lane LC-2: three, the third being the extra-exec press (Pin 8).
    @Test("ShellAutolaunch.notePress is called exactly three times, once per scheduled press")
    func exactlyThreeNotePressInvocations() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "ShellAutolaunch.notePress(", in: code) == 3)
        #expect(autolaunchOccurrences(of: "ShellAutolaunch.notePress(.disconnect)", in: code) == 1)
        #expect(autolaunchOccurrences(of: "ShellAutolaunch.notePress(.connect)", in: code) == 1)
        #expect(autolaunchOccurrences(of: "ShellAutolaunch.notePress(.extraExec", in: code) == 1)
    }

    /// MUST-RED for "the anchor is printed after the press, not before": the anchor line's only
    /// reason to exist is to let an orchestrator locate the instant of a press it cannot otherwise
    /// see (gate r1 I-1) -- a line written after the fact locates only the instant AppDelegate got
    /// back around to writing it, not the press.
    @Test("the disconnect anchor comes immediately before self.endSessionTapped()")
    func disconnectAnchorPrecedesTheDisconnectPress() throws {
        let code = try Self.code()
        #expect(code.contains("ShellAutolaunch.notePress(.disconnect) self.endSessionTapped()"))
    }

    /// Same must-red, for the reconnect press.
    @Test("the reconnect anchor comes immediately before self.connectTapped()")
    func reconnectAnchorPrecedesTheReconnectPress() throws {
        let code = try Self.code()
        #expect(code.contains("ShellAutolaunch.notePress(.connect) self.connectTapped()"))
    }

    // MARK: - Pin 8 (adr/0021 lane LC-2): the extra exec, once, from a one-shot Timer

    /// The whole extra-exec block, folded, as the new tail of `applicationDidFinishLaunching`: it
    /// opens right after the quit-ceiling block closes and ends at the method's own closing brace,
    /// immediately before `connectTapped`'s declaration. Same purpose as
    /// `theKnobsAreTheTailOfTheLaunchMethod`: a block moved into a helper nobody calls, a Timer that
    /// repeats, an anchor printed after the send, or a send without the session check all break
    /// this one needle.
    @Test("the extra-exec block is the tail of applicationDidFinishLaunching, in its exact shape")
    func theExtraExecBlockIsTheTailOfTheLaunchMethod() throws {
        let code = try Self.code()
        let needle: String =
            "_ = Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in "
            + "MainActor.assumeIsolated { NSApp.terminate(nil) } } } "
            + "if let extraExecAfter = autolaunch.extraExecAfterInterval, let extraExecProgram = autolaunch.extraExecProgram { "
            + "_ = Timer.scheduledTimer(withTimeInterval: extraExecAfter, repeats: false) { _ in "
            + "MainActor.assumeIsolated { let session = self.session "
            + "ShellAutolaunch.notePress(.extraExec, programBytes: extraExecProgram.utf8.count, sessionPresent: session != nil) "
            + "if let session { session.executeProgram(extraExecProgram) } } } } } "
            + Self.firstDeclarationAfterLaunch
        #expect(autolaunchOccurrences(of: needle, in: code) == 1)
    }

    /// One send site in the whole file, and it is the one inside the Timer. `executeProgram(` is
    /// counted bare as well, so a second call through another receiver cannot hide.
    @Test("session.executeProgram is called exactly once, inside the one-shot extra-exec Timer, after the anchor")
    func exactlyOneExecuteProgramInsideTheTimer() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "session.executeProgram(", in: code) == 1)
        #expect(autolaunchOccurrences(of: "executeProgram(", in: code) == 1)
        #expect(
            autolaunchOccurrences(
                of: "_ = Timer.scheduledTimer(withTimeInterval: extraExecAfter, repeats: false) { _ in", in: code) == 1)

        let timer = try autolaunchIndex(
            of: "_ = Timer.scheduledTimer(withTimeInterval: extraExecAfter, repeats: false) { _ in", in: code)
        let anchor = try autolaunchIndex(of: "ShellAutolaunch.notePress(.extraExec", in: code)
        let send = try autolaunchIndex(of: "session.executeProgram(", in: code)
        let nextDeclaration = try autolaunchIndex(of: Self.firstDeclarationAfterLaunch, in: code)
        #expect(timer < anchor, "the anchor is inside the Timer's callback")
        #expect(anchor < send, "the anchor is printed BEFORE the send")
        #expect(send < nextDeclaration, "the send is inside applicationDidFinishLaunching")
        // No other Timer opens between this one and the send: the send is in THIS Timer's block.
        let between = code[timer..<send]
        #expect(autolaunchOccurrences(of: "Timer.scheduledTimer(", in: String(between)) == 1)
    }

    /// The file's Timer budget: `drainTimer`'s repeating poll plus four one-shot knob Timers
    /// (Disconnect, reconnect, quit, extra exec). Before lane LC-2 the count was 4; exactly one
    /// was added. `repeats: true` stays `drainTimer`'s alone.
    @Test("exactly one Timer was added, and only drainTimer repeats")
    func timerBudget() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "Timer.scheduledTimer(", in: code) == 5)
        #expect(autolaunchOccurrences(of: "repeats: true", in: code) == 1)
        #expect(autolaunchOccurrences(of: "drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)", in: code) == 1)
    }

    /// The program string reaches the anchor helper only as its byte count (gate r1 I-1), and
    /// nothing in this file prints or logs it on its own.
    @Test("the program string is only ever measured for notePress and handed to executeProgram")
    func theProgramStringGoesNowhereElse() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "extraExecProgram", in: code) == 4,
                "the binding, the autolaunch read, the byte count notePress receives, and the send")
        #expect(autolaunchOccurrences(of: "print(", in: code) == 0)
    }

    /// Gate r1 I-1 (folded in, ruling (a)): the extra-exec anchor call hands `notePress` the
    /// program's `.utf8.count` and never the program string itself, so the anchor helper cannot
    /// log what it is never given. The argument list is cut out by balanced parentheses, and every
    /// mention of `extraExecProgram` inside it must be the `.utf8.count` measurement.
    @Test("notePress(.extraExec receives the program's .utf8.count, never the program string")
    func theExtraExecAnchorReceivesOnlyTheByteCount() throws {
        let code = try Self.code()
        let head = "ShellAutolaunch.notePress"
        let start = try autolaunchIndex(of: head + "(.extraExec", in: code)
        let open = code.index(start, offsetBy: head.count)
        var depth = 0
        var end: String.Index?
        var cursor = open
        while cursor < code.endIndex {
            if code[cursor] == "(" { depth += 1 }
            if code[cursor] == ")" {
                depth -= 1
                if depth == 0 { end = code.index(after: cursor); break }
            }
            cursor = code.index(after: cursor)
        }
        let arguments = String(code[open..<(try #require(end, "unbalanced notePress(.extraExec call"))])
        #expect(arguments.contains(".utf8.count"))
        #expect(!arguments.contains("extraExecProgram)"), "the program string passed as the last argument")
        #expect(!arguments.contains("extraExecProgram,"), "the program string passed as an argument")
        let mentions = autolaunchOccurrences(of: "extraExecProgram", in: arguments)
        #expect(mentions == 1)
        #expect(mentions == autolaunchOccurrences(of: "extraExecProgram.utf8.count", in: arguments),
                "every mention of the program string in the call is its byte count")
    }

    // MARK: - adr/0020 lane K, gate r1 I-4 (folded in): ShellAutolaunch.swift's own zero-output guard

    private static func shellAutolaunchCode() throws -> String {
        try autolaunchCodeOnly(autolaunchRawSource(shellAutolaunch))
    }

    /// I-4 (gate r1 mutant M2a): `plan(environment:)` runs on EVERY launch, knobs off included, so
    /// a stray `print` inside it (or inside either `*Interval` conversion, both declared even
    /// earlier, inside `Plan`) would put a line on stdout on every launch with nothing in
    /// `App/Macdows/` -- where `noOtherExitRoute`'s S-6 guard lives -- able to catch it. This
    /// file's only sanctioned output is `notePress(_:)`'s own `print(line)`, declared BEFORE
    /// `plan(environment:)` in source, so ONE occurrence of `print(` in the whole file, strictly
    /// between `notePress`'s declaration and `plan`'s, both proves it is there and rules out a
    /// second one anywhere else in the file.
    @Test("ShellAutolaunch.swift prints exactly once, from notePress(_:), and nowhere else")
    func shellAutolaunchPrintsOnlyFromNotePress() throws {
        let code = try Self.shellAutolaunchCode()
        #expect(autolaunchOccurrences(of: "print(", in: code) == 1)
        let notePress = try autolaunchIndex(of: "static func notePress(", in: code)
        let printSite = try autolaunchIndex(of: "print(", in: code)
        let plan = try autolaunchIndex(of: "static func plan(environment:", in: code)
        #expect(notePress < printSite, "the one print( must be inside notePress(_:)")
        #expect(printSite < plan, "the one print( must be before plan(environment:), not inside it")
    }

    /// Gate r1 I-1 (folded in, ruling (a)): neither anchor helper accepts a `String` parameter at
    /// all, so the program string cannot reach `print` or the unified log through them. Both
    /// signatures are pinned whole (one declaration each, no overload), and no parameter named
    /// `program` of type `String` is declared anywhere in the file. Gate r1's mutant R12 (the
    /// logger carrying the program out) needs exactly such a parameter and is killed here.
    @Test("notePress and pressLine take a byte count, and no String program parameter exists")
    func theAnchorHelpersTakeNoProgramString() throws {
        let code = try Self.shellAutolaunchCode()
        #expect(autolaunchOccurrences(of: "static func notePress(", in: code) == 1)
        #expect(autolaunchOccurrences(of: "static func pressLine(", in: code) == 1)
        #expect(autolaunchOccurrences(
            of: "static func notePress(_ which: Press, programBytes: Int? = nil, sessionPresent: Bool? = nil) {",
            in: code) == 1)
        #expect(autolaunchOccurrences(
            of: "static func pressLine(_ which: Press, programBytes: Int? = nil, sessionPresent: Bool? = nil) -> String {",
            in: code) == 1)
        #expect(autolaunchOccurrences(of: "program: String", in: code) == 0)
    }

    /// Gate r1 m-1 (folded in): every knob, the program string included, is read from the
    /// environment dictionary `plan(environment:)` is handed, under one of the seven key constants,
    /// and from nowhere else. Exactly seven subscripts, each one a key constant; no defaults
    /// database, no file read, no command line. Gate r1's mutant R13 (a fallback to a second,
    /// unlisted environment key) is killed here.
    @Test("the knobs are read only through the seven key constants, from the environment alone")
    func theKnobsAreReadOnlyThroughTheSixKeys() throws {
        let code = try Self.shellAutolaunchCode()
        // adr/0021 lane CA-2 adds the seventh constant, `keyWitnessKey`, and the seventh subscript.
        let keys: Set<String> = [
            "autoconnectKey", "quitAfterKey", "disconnectAfterKey",
            "reconnectAfterKey", "extraExecAfterKey", "extraExecProgramKey",
            "keyWitnessKey",
        ]
        let subscripts = code.components(separatedBy: "environment[").dropFirst()
        #expect(subscripts.count == 7)
        for rest in subscripts {
            let key = String(rest.prefix { $0 != "]" })
            #expect(keys.contains(key), "environment[\(key)] is not one of the seven key constants")
        }
        #expect(autolaunchOccurrences(of: "UserDefaults", in: code) == 0)
        #expect(autolaunchOccurrences(of: "contentsOf", in: code) == 0)
        #expect(autolaunchOccurrences(of: "CommandLine", in: code) == 0)
    }

    // MARK: - The knob names the orchestrator greps for

    /// `form1-batch.sh`'s third pre-check refuses to start a batch unless `ShellAutolaunch.swift`
    /// mentions `MACDOWS_AUTOCONNECT` -- the same "does this checkout support the knob at all"
    /// shape `soak-batch.sh` uses for `WINDOW_SMOKE_CYCLES`. That check reads a literal out of this
    /// file, so the literal has to stay spelled out here rather than being assembled at run time.
    ///
    /// EXTENDED by gate r1 I-3 (folded in): the same orchestrator that greps for
    /// `MACDOWS_AUTOCONNECT` before starting a batch has to grep for lane K's own two knob names
    /// the same way, since a silently renamed key makes the D-A sub-run degrade to shape 1 (connect,
    /// then exit at the ceiling) with nothing in-process to say so (no anchor line is ever printed
    /// for a knob whose name does not match). Gate r1's mutant M3c proved the old, two-name version
    /// of this test let exactly that renaming through.
    @Test("all seven knob names appear literally in ShellAutolaunch.swift")
    func knobNamesAreGreppable() throws {
        let raw = try autolaunchRawSource(Self.shellAutolaunch)
        #expect(raw.contains("\"MACDOWS_AUTOCONNECT\""))
        #expect(raw.contains("\"MACDOWS_QUIT_AFTER_SECONDS\""))
        #expect(raw.contains("\"MACDOWS_DISCONNECT_AFTER_SECONDS\""))
        #expect(raw.contains("\"MACDOWS_RECONNECT_AFTER_SECONDS\""))
        // adr/0021 lane LC-2: the extra-exec pair, for the same "silently renamed key" reason.
        #expect(raw.contains("\"MACDOWS_EXTRA_EXEC_AFTER_SECONDS\""))
        #expect(raw.contains("\"MACDOWS_EXTRA_EXEC_PROGRAM\""))
        // adr/0021 lane CA-2: the key-witness switch, for the same "silently renamed key" reason.
        #expect(raw.contains("\"MACDOWS_KEY_WITNESS\""))
    }

    // MARK: - Pin 9 (adr/0021 lane CA-2): the key-witness switch, set once, only when asked

    /// The class switch is assigned exactly once in this file, to the literal `true`, only inside
    /// `if autolaunch.keyWitness {`, between the one `plan` read and the autoconnect press. With the
    /// knob off nothing assigns it, so it keeps `CRSession.mm`'s initial `NO` and the bridge prints
    /// nothing (`KeyWitnessBridgePinTests` holds that half). MUST-RED for: an unconditional
    /// assignment, an assignment of `autolaunch.keyWitness` itself outside the `if` (still
    /// behaviour-equal, but a second shape the zero-output claim would have to re-argue), a second
    /// writer, and the switch set after the autoconnect press.
    @Test("CRSession.keyWitnessEnabled is set once, to true, only under autolaunch.keyWitness, before autoconnect")
    func theKeyWitnessSwitchIsSetOnceBeforeAutoconnect() throws {
        let code = try Self.code()
        #expect(autolaunchOccurrences(of: "keyWitnessEnabled", in: code) == 1)
        #expect(autolaunchOccurrences(of: "if autolaunch.keyWitness { CRSession.keyWitnessEnabled = true }", in: code) == 1)
        #expect(autolaunchOccurrences(of: "autolaunch.keyWitness", in: code) == 1)
        let plan = try autolaunchIndex(of: "ShellAutolaunch.plan(", in: code)
        let set = try autolaunchIndex(of: "CRSession.keyWitnessEnabled = true", in: code)
        let press = try autolaunchIndex(of: "if autolaunch.autoconnect { connectTapped() }", in: code)
        #expect(plan < set)
        #expect(set < press)
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
