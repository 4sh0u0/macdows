import Foundation
import Testing

// The session-end lane (a follow-up to adr/0019 §2 lane D). Lane D's implementation report
// registered four defects in how `AppDelegate` ends a session, and all four had one root: THREE
// hand-written teardowns, each missing a different step.
//
//  #1  the connect-error branch re-enabled the Connect button without dropping `session`, so the
//      button answered "Already connecting/connected." to every press;
//  #3  `drainTimer` was stopped in only two of the ways a session can end, so any third way would
//      have left it rewriting the status line once a second for the life of the process;
//  #5  the bridge's push hook, `onEventsAvailable`, was never cleared, so "this session is over"
//      was invisible from the bridge side;
//  #7  termination ended the session in a shape of its own, dropping nothing.
//
// The lane replaces the three with ONE function, `tearDownSession()`, and these pins hold that
// shape. Same instrument as `AppDelegateReconnectWiringPinTests`, for the same reason:
// `App/project.yml` keeps `Macdows` out of this bundle, so `AppDelegate` is reachable only as
// source text.
//
// What these pins are FOR:
//
//  S0. The comment stripper did not eat the code. Every other pin here reads the stripped text.
//  S1. `tearDownSession()`'s body is exactly its six steps, in the one order that is safe.
//  S2. Every step is spelled ONCE in the whole file, so no path can end a session by hand any
//      more. That is what closes #3 structurally rather than by detection: with a single
//      `invalidate()` and a single `shutdownAndWait(`, a session cannot be shut down without its
//      timer being stopped in the same breath.
//  S3. The function is declared once and called from exactly three places. WHICH three is held
//      next door (`AppDelegateReconnectWiringPinTests`: the connect-error branch, the give-up
//      branch, termination), beside the other claims about those three paths.
//  S4. The bridge reads the push hook when its main-queue block RUNS, not when the block is
//      scheduled -- the premise without which clearing the hook on the main actor would not stop
//      a push that is already queued.
//
// REGISTERED GAP, stated rather than papered over: these pins check that the teardown is WRITTEN,
// not that it RUNS. Whether the re-enabled button really starts a new connection cannot be observed
// from this bundle, and whether termination really completes cannot be observed from inside the
// terminating process at all. Closing the first half means splitting `AppDelegate` into a target
// this bundle can compile, which is a different lane.

private func sessionEndRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func sessionEndRawSource(_ relative: String) throws -> String {
    try String(contentsOf: sessionEndRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Every run of whitespace collapsed to a single space, so a pin is about the tokens and not about
/// how the file happens to be wrapped or indented. Comments included.
private func sessionEndFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The same fold with line comments removed first, so a pin on a RUN OF STATEMENTS is not also a
/// pin on the prose between them, and a count of a call is not also a count of the sentences that
/// explain it.
///
/// LIMITATION, checked rather than assumed: `//` inside a string literal would be stripped as well.
/// `AppDelegate.swift` contains none, and `theCommentStripperDidNotEatTheTeardown` below is what
/// keeps that true.
private func sessionEndCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return sessionEndFolded(lines.joined(separator: " "))
}

private func sessionEndOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The index of `needle` inside `haystack`. Fails the test rather than returning a sentinel, so
/// "the statement vanished" can never read as "the statement is in the right place".
private func sessionEndIndex(of needle: String, in haystack: String) throws -> String.Index {
    let found = try #require(haystack.range(of: needle), "not found: \(needle)")
    return found.lowerBound
}

@Suite("session-end lane — AppDelegate ends every session through one teardown, pinned as source")
struct AppDelegateSessionEndPinTests {

    private static let appDelegate = "App/Macdows/AppDelegate.swift"
    private static let bridge = "App/CRBridge/CRSession.mm"

    private static func code() throws -> String {
        try sessionEndCodeOnly(sessionEndRawSource(appDelegate))
    }

    // MARK: - S0: the stripper

    /// S0. The comment stripper's own guard (the shape `AppDelegateReconnectWiringPinTests`
    /// established). If it ever ate code, every count below would start passing vacuously against a
    /// shorter file, so what is checked is that the declarations these pins are about, and the one
    /// line in the file that carries a string interpolation, survive the strip.
    @Test("the comment stripper leaves the teardown it is asked about intact")
    func theCommentStripperDidNotEatTheTeardown() throws {
        let code = try Self.code()
        #expect(code.contains("private func tearDownSession() {"))
        #expect(code.contains("func applicationWillTerminate(_ notification: Notification) {"))
        #expect(code.contains("statusLabel.stringValue = \"Connect failed: \\(error.localizedDescription)\""))
        #expect(!code.contains("adr/0019"), "a line comment survived the strip")
        #expect(!code.contains("// "), "a comment marker survived the strip")
    }

    // MARK: - S1: the body, in order

    /// S1. The whole body as one contiguous run, so the ORDER is the claim and nothing can be
    /// inserted between the steps. Why each step sits where it does:
    ///
    ///  1. The timer first. It is the only thing that can call `drainTick` again on its own, and
    ///     this is now its only stopping point (#3).
    ///  2. The driver disarmed and dropped BEFORE the shutdown. `teardownInitiated` closes the
    ///     EVENT edge only; a retry already on the clock is a second edge, and disarming is what
    ///     cancels it. Dropping it as well means the retry block, which holds the driver weakly,
    ///     finds nothing if it fires anyway.
    ///  3. The push hook cleared BEFORE the shutdown, so a push the shutdown itself triggers is a
    ///     no-op from the moment it is produced (#5). The mutant this ordering exists to kill:
    ///     moving the clear after `session = nil` turns `session?.` into a nil-chain and the clear
    ///     into a silent no-op -- still compiling, still spelled once, and wrong.
    ///  4. The shutdown after both disconnections and before any reference is dropped: it needs
    ///     the session it shuts down.
    ///  5. The references dropped after the shutdown. `session = nil` is the statement that lets
    ///     `connectTapped`'s first guard pass again (#1).
    ///  6. The topology's `endSession()` last: it has no output and nothing after it depends on it.
    ///
    /// MUST-RED for: any reordering, any inserted statement, any dropped step, and the clear moved
    /// behind the nil-ing.
    @Test("tearDownSession's body is its six steps, in the one safe order")
    func theTeardownBodyIsTheSixStepsInOrder() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(
            of: "private func tearDownSession() { "
                + "drainTimer?.invalidate() "
                + "drainTimer = nil "
                + "reconnectDriver?.detach() "
                + "reconnectDriver = nil "
                + "session?.onEventsAvailable = nil "
                + "session?.shutdownAndWait() "
                + "session = nil "
                + "registry = nil "
                + "displayTopology.endSession() }",
            in: code) == 1)

        // The hook's two neighbours, stated separately so a failure names the edge that broke.
        let driverDropped = try sessionEndIndex(of: "reconnectDriver = nil", in: code)
        let hookCleared = try sessionEndIndex(of: "session?.onEventsAvailable = nil", in: code)
        let shutdown = try sessionEndIndex(of: "session?.shutdownAndWait()", in: code)
        let sessionDropped = try sessionEndIndex(of: "session = nil", in: code)
        #expect(driverDropped < hookCleared)
        #expect(hookCleared < shutdown, "cleared before the shutdown it would otherwise be pushed by")
        #expect(shutdown < sessionDropped, "a cleared session reference cannot be shut down")
    }

    // MARK: - S2: every step spelled once

    /// S2. Nine single-point counts over the comment-stripped file. Each of these used to appear at
    /// two or three hand-written exits (or, for the hook, at none); one spelling each is what makes
    /// "a session ended without X" unwritable rather than merely absent today.
    ///
    /// MUST-RED for: a second `invalidate()` anywhere (the shape of #3), a second shutdown call
    /// site, an exit that keeps a private copy of any step, and a lost hook clear.
    @Test("each teardown step is spelled exactly once in the whole file")
    func eachTeardownStepHasOneSpelling() throws {
        let code = try Self.code()
        let steps: [(needle: String, why: String)] = [
            ("drainTimer?.invalidate()", "#3: the timer's only stopping point"),
            ("drainTimer = nil", "the timer reference, dropped once"),
            (".detach()", "the only disarming"),
            ("shutdownAndWait(", "the only shutdown call site"),
            ("displayTopology.endSession()", "the topology's only session end"),
            ("reconnectDriver = nil", "the driver, dropped once"),
            ("session = nil", "#1: the one place this app stops having a session"),
            ("registry = nil", "the registry, dropped once"),
            ("onEventsAvailable = nil", "#5: the push hook, cleared once"),
        ]
        for step in steps {
            #expect(sessionEndOccurrences(of: step.needle, in: code) == 1, "\(step.needle) -- \(step.why)")
        }
    }

    // MARK: - S3: declared once, called three times

    /// S3. One declaration plus the three callers the wiring pins name: the connect-error branch
    /// (`theConnectErrorBranchEndsTheSession`), the give-up branch
    /// (`theGiveUpTeardownDropsTheSession`) and termination (`terminationDisarmsTheDriverFirst`).
    /// Counted with and without the closing parenthesis so an overload that takes an argument
    /// cannot slip in beside the parameterless one.
    ///
    /// MUST-RED for: a fourth caller nobody pinned, a caller dropped, and a second declaration.
    @Test("tearDownSession is declared once and called from exactly three places")
    func theTeardownHasOneDeclarationAndThreeCallers() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(of: "func tearDownSession(", in: code) == 1)
        #expect(sessionEndOccurrences(of: "tearDownSession()", in: code) == 4,
                "one declaration + connect-error branch + give-up branch + applicationWillTerminate")
        #expect(sessionEndOccurrences(of: "tearDownSession(", in: code) == 4)
    }

    // MARK: - S4: the premise on the bridge side

    /// S4. The premise the hook clear stands on, pinned where it lives. `crb_schedule_drain` hops to
    /// the main queue and reads `onEventsAvailable` INSIDE the block, when it runs. So a push that
    /// is already queued when `tearDownSession()` clears the hook on the main actor reads nil when
    /// its turn comes, and does nothing.
    ///
    /// A bridge that captured the hook BEFORE dispatching would invalidate that silently: the
    /// queued block would call the closure it captured whatever the property says by then, and the
    /// App-side clear would stop only pushes posted after it. The App side cannot see that change,
    /// so the pin is here. It is green before and after the session-end lane -- it records the
    /// bridge as it is, which is not a file that lane may edit.
    ///
    /// Also why the clear lives in the App and not in `-shutdownAndWait`: the reconnect path runs the
    /// same `-shutdownAndWait` and keeps using the hook afterwards.
    ///
    /// MUST-RED for: capturing the hook into a local before `dispatch_async`, reading it outside the
    /// block, and a second place in the bridge that invokes it.
    @Test("the bridge reads the push hook when the main-queue block runs, not when it is scheduled")
    func theBridgeReadsTheHookAtRunTime() throws {
        let bridge = sessionEndFolded(try sessionEndRawSource(Self.bridge))
        #expect(sessionEndOccurrences(
            of: "static void crb_schedule_drain(void *ctx) { "
                + "CRSession *session = (__bridge CRSession *)ctx; "
                + "dispatch_async(dispatch_get_main_queue(), ^{ "
                + "if (session.onEventsAvailable) { session.onEventsAvailable(); } "
                + "}); }",
            in: bridge) == 1)
        #expect(sessionEndOccurrences(of: "onEventsAvailable()", in: bridge) == 1,
                "the hook is invoked from one place in the bridge")
    }
}
