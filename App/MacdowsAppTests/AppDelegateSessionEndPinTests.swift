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
// adr/0020 lane S (the shell's Disconnect control) re-froze S1-S3 in the same commit that changed
// what they hold -- a seventh step, the registry's session-end window close, and a fourth caller,
// the End-session button -- and added the button's own pins (adr/0020 S-3', S-4, S-5, S-6) here.
//
// What these pins are FOR:
//
//  S0. The comment stripper did not eat the code. Every other pin here reads the stripped text.
//  S1. `tearDownSession()`'s body is exactly its seven steps, in the one order that is safe.
//  S2. Every step is spelled ONCE in the whole file, so no path can end a session by hand any
//      more. That is what closes #3 structurally rather than by detection: with a single
//      `invalidate()` and a single `shutdownAndWait(`, a session cannot be shut down without its
//      timer being stopped in the same breath.
//  S3. The function is declared once and called from exactly four places. WHICH four is held
//      next door (`AppDelegateReconnectWiringPinTests`: the connect-error branch, the give-up
//      branch, termination) and below (the End-session action), beside the other claims about
//      those paths.
//  S4. The bridge reads the push hook when its main-queue block RUNS, not when the block is
//      scheduled -- the premise without which clearing the hook on the main actor would not stop
//      a push that is already queued.
//  adr/0020 S-3', S-4, S-5, S-6. The End-session button: its action is UI first and teardown
//      second; it is enabled by one statement, in `session`'s `didSet`; there is one action and one
//      binding, named clear of the substrings the other pins count; and nothing about it adds a
//      menu, a stdout line or a reconnect route.
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

/// Every `.swift` file under `relative`, recursively, as repo-relative paths. This file's own copy
/// of the walk `ReconnectSemanticsPinTests` and `RemoteWindowRegistrySessionEndTests` each keep
/// (copying it is the established precedent here, not a shortcut).
private func sessionEndSwiftFiles(under relative: String) throws -> [String] {
    let root = sessionEndRepoRoot().appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var out: [String] = []
    for case let entry as String in walker where entry.hasSuffix(".swift") {
        out.append("\(relative)/\(entry)")
    }
    return out.sorted()
}

/// The first capture group of every match of `pattern` in `haystack`, in order.
private func sessionEndCaptures(of pattern: String, in haystack: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let whole = NSRange(haystack.startIndex..., in: haystack)
    return regex.matches(in: haystack, range: whole).compactMap { match in
        Range(match.range(at: 1), in: haystack).map { String(haystack[$0]) }
    }
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

    /// S1 (re-frozen by adr/0020 lane S, D-2 = P1: six steps -> seven). The whole body as one
    /// contiguous run, so the ORDER is the claim and nothing can be inserted between the steps. Why
    /// each step sits where it does:
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
    ///  5. The RAIL windows closed through the registry's session-end entry, AFTER the shutdown --
    ///     adr/0005 §4 closes an NSWindow only once both FreeRDP threads are gone, which is what
    ///     `-shutdownAndWait` returning means -- and BEFORE the references are dropped: each window
    ///     hands its surface back through the session the registry still holds, and a registry
    ///     dropped with its windows ordered in leaves them on screen with no owner.
    ///  6. The references dropped after the shutdown. `session = nil` is the statement that lets
    ///     `connectTapped`'s first guard pass again (#1).
    ///  7. The topology's `endSession()` last: it has no output and nothing after it depends on it.
    ///
    /// MUST-RED for: any reordering, any inserted statement, any dropped step, the clear moved
    /// behind the nil-ing, and the window close moved in front of the shutdown (adr/0005 §4) or
    /// behind the session's nil-ing.
    @Test("tearDownSession's body is its seven steps, in the one safe order")
    func theTeardownBodyIsTheSevenStepsInOrder() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(
            of: "private func tearDownSession() { "
                + "drainTimer?.invalidate() "
                + "drainTimer = nil "
                + "reconnectDriver?.detach() "
                + "reconnectDriver = nil "
                + "session?.onEventsAvailable = nil "
                + "session?.shutdownAndWait() "
                + "registry?.closeWindowsForSessionEnd() "
                + "session = nil "
                + "registry = nil "
                + "displayTopology.endSession() }",
            in: code) == 1)

        // The hook's two neighbours and the window close's, stated separately so a failure names
        // the edge that broke: shutdown < window close < `session = nil` < `registry = nil`.
        let driverDropped = try sessionEndIndex(of: "reconnectDriver = nil", in: code)
        let hookCleared = try sessionEndIndex(of: "session?.onEventsAvailable = nil", in: code)
        let shutdown = try sessionEndIndex(of: "session?.shutdownAndWait()", in: code)
        let windowsClosed = try sessionEndIndex(of: "registry?.closeWindowsForSessionEnd()", in: code)
        let sessionDropped = try sessionEndIndex(of: "session = nil", in: code)
        let registryDropped = try sessionEndIndex(of: "registry = nil", in: code)
        #expect(driverDropped < hookCleared)
        #expect(hookCleared < shutdown, "cleared before the shutdown it would otherwise be pushed by")
        #expect(shutdown < windowsClosed, "adr/0005 §4: windows close only once both FreeRDP threads are gone")
        #expect(windowsClosed < sessionDropped, "each window hands its surface back through the session")
        #expect(sessionDropped < registryDropped, "the registry, which still holds the session, goes last")
    }

    // MARK: - S2: every step spelled once

    /// S2. Ten single-point counts over the comment-stripped file. The first nine each used to
    /// appear at two or three hand-written exits (or, for the hook, at none); one spelling each is
    /// what makes "a session ended without X" unwritable rather than merely absent today. The tenth
    /// is adr/0020 S-2': the registry's session-end entry, called once, inside the teardown -- zero
    /// before lane S.
    ///
    /// MUST-RED for: a second `invalidate()` anywhere (the shape of #3), a second shutdown call
    /// site, an exit that keeps a private copy of any step, a lost hook clear, and a window close
    /// that is dropped or called a second time outside the teardown.
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
            ("closeWindowsForSessionEnd(", "adr/0020 S-2': the session-end window close, called once"),
        ]
        for step in steps {
            #expect(sessionEndOccurrences(of: step.needle, in: code) == 1, "\(step.needle) -- \(step.why)")
        }
    }

    // MARK: - S3: declared once, called four times

    /// S3 (re-frozen by adr/0020 lane S: three callers -> four). One declaration plus the four
    /// callers the needles name: the connect-error branch (`theConnectErrorBranchEndsTheSession`),
    /// the give-up branch (`theGiveUpTeardownDropsTheSession`), termination
    /// (`terminationDisarmsTheDriverFirst`) and the End-session action
    /// (`theEndSessionActionIsUIFirstThenTeardown`, below). Counted with and without the closing
    /// parenthesis so an overload that takes an argument cannot slip in beside the parameterless
    /// one.
    ///
    /// MUST-RED for: a fifth caller nobody pinned, a caller dropped, and a second declaration.
    @Test("tearDownSession is declared once and called from exactly four places")
    func theTeardownHasOneDeclarationAndFourCallers() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(of: "func tearDownSession(", in: code) == 1)
        #expect(sessionEndOccurrences(of: "tearDownSession()", in: code) == 5,
                "one declaration + connect-error branch + give-up branch + endSessionTapped + applicationWillTerminate")
        #expect(sessionEndOccurrences(of: "tearDownSession(", in: code) == 5)
    }

    /// adr/0020 S-3'. The End-session action, as one contiguous run over its whole body (D-5 = Q1):
    /// a `session != nil` guard, the action's own status line, Connect enabled by a literal `true`,
    /// and only then the teardown -- the connect-error branch's order, UI first. The status line is
    /// part of the needle so that a re-worded line is a deliberate re-freeze; it carries no `//`
    /// (the stripper would cut it), no `adr/0019` (S0) and no `Connected —` (the wiring pins keep
    /// that wording in the presenter).
    ///
    /// The needle already admits nothing else into the body; the three route checks after it say
    /// the part of adr/0020 S-6 that is about THIS body in words a failure can name: no
    /// `connectTapped(` (a one-press reconnect), no `performClose` (an SC_CLOSE), no
    /// `prepareForReconnect` (the registry's reconnect seam).
    ///
    /// MUST-RED for: dropping the guard, tearing down before the UI is written, a second statement
    /// of any kind inside the action (a reconnect route, a stdout line, a note clear), and the
    /// action no longer ending the session.
    @Test("the End-session action writes its line, enables Connect, and only then ends the session")
    func theEndSessionActionIsUIFirstThenTeardown() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(
            of: "@objc private func endSessionTapped() { "
                + "guard session != nil else { return } "
                + "statusLabel.stringValue = \"Session ended. Press Connect to start a new one.\" "
                + "connectButton.isEnabled = true "
                + "tearDownSession() }",
            in: code) == 1)

        let start = try sessionEndIndex(of: "@objc private func endSessionTapped() {", in: code)
        let end = try #require(code[start...].range(of: "tearDownSession() }"), "the action's end").upperBound
        let body = code[start..<end]
        for route in ["connectTapped(", "performClose", "prepareForReconnect"] {
            #expect(!body.contains(route), "the End-session action calls \(route)")
        }
    }

    // MARK: - adr/0020 S-4: one enablement write, in session's didSet

    /// adr/0020 S-4 (D-4 = K1). The End-session button is usable exactly while `session` is
    /// non-nil, and ONE statement decides that: `session`'s own `didSet`, which covers both of the
    /// property's assignments (`beginSession`'s and the teardown's). The bare predicate
    /// `session != nil` is deliberately not counted -- the drain tick's re-read guard and the
    /// action's own guard spell it too -- the WRITE is.
    ///
    /// `applyShell` is not a legal home for it: three of the four session ends never call it after
    /// their teardown, and the give-up one calls it BEFORE its teardown, while `session` is still
    /// set. Moving the write there also breaks the wiring pins' whole-body needle on `applyShell`.
    ///
    /// NSButton starts out enabled, so the construction writes the initial value, once, as a
    /// literal `false`; spelled as the same predicate it would make the write count two. The last
    /// count is exhaustive: every `.isEnabled =` in the file is either Connect's or one of these
    /// two, so a third writer anywhere -- whatever its name -- is red.
    ///
    /// The construction needle is widened to the whole run from the button's `NSButton(...)` call
    /// through the `NSStackView(views:)` line that lays out the shell, ending on the literal array
    /// `[label, status, button, endButton]`. A button that is built, wired and disabled but never
    /// added to the stack still satisfies every other pin here -- it is a dead control the pins
    /// could not otherwise see (gate r1 I-1, mutant G9: dropping `endButton` from the array still
    /// built and passed all 234 tests). Folding the whole run into one needle means any statement
    /// inserted between construction and the stack line, and any change to the array's own
    /// membership, is red. The separate whole-file count on `endSessionButton` (declaration,
    /// `didSet`, construction assignment -- exactly 3) closes the gap the substring check in S-5
    /// leaves open: a fourth use anywhere else, such as an `isHidden` or `removeFromSuperview`
    /// write, is red too.
    ///
    /// MUST-RED for: the write moved into `applyShell` (or anywhere out of the `didSet`), a second
    /// enablement write, a missing or non-literal initial value, the button dropped from the
    /// stack's view array (G9), or any additional use of `endSessionButton` elsewhere in the file.
    @Test("the End-session button is enabled by one statement, in session's didSet, starts disabled, and is in the stack")
    func theEndSessionButtonHasOneEnablementWrite() throws {
        let code = try Self.code()
        #expect(sessionEndOccurrences(of: "isEnabled = session != nil", in: code) == 1)
        #expect(sessionEndOccurrences(
            of: "private var session: CRSession? { didSet { endSessionButton.isEnabled = session != nil } }",
            in: code) == 1)
        #expect(sessionEndOccurrences(
            of: """
                let endButton = NSButton(title: "Disconnect", target: self, action: #selector(endSessionTapped)) \
                endButton.translatesAutoresizingMaskIntoConstraints = false \
                endButton.isEnabled = false \
                endSessionButton = endButton \
                let stack = NSStackView(views: [label, status, button, endButton])
                """,
            in: code) == 1,
                "the construction run through the stack line, with endButton inside the views array")
        #expect(sessionEndOccurrences(of: "endSessionButton", in: code) == 3,
                "declaration, didSet, and the construction assignment -- nothing else touches the button")
        let everyWrite = sessionEndOccurrences(of: ".isEnabled =", in: code)
        let connectWrites = sessionEndOccurrences(of: "connectButton.isEnabled =", in: code)
        #expect(everyWrite - connectWrites == 2, "the construction's literal and the didSet, and nothing else")
    }

    // MARK: - adr/0020 S-5: one action, one binding, names clear of the counted substrings

    /// adr/0020 S-5. Exactly one End-session action method and exactly one `#selector(...)` binding
    /// it, and names that stay clear of the substrings other pins count: `connectTapped` (the
    /// autolaunch pins count `connectTapped()`), `connectButton` (the wiring pins count
    /// `connectButton.isEnabled =`) and `tearDownSession` (S3). The names are read out of the
    /// source rather than restated, so a rename that re-freezes the expected list still has to pass
    /// the substring check.
    ///
    /// MUST-RED for: a second action or binding, a renamed action or button (the name lists), and
    /// a name that would inflate another pin's count (the substring check).
    @Test("one End-session action, bound by one selector, named clear of the pinned substrings")
    func theEndSessionActionIsOneMethodWithOneBinding() throws {
        let code = try Self.code()
        let selectors = try sessionEndCaptures(of: "#selector\\((\\w+)\\)", in: code)
        let actions = try sessionEndCaptures(of: "@objc private func (\\w+)\\(\\)", in: code)
        let buttons = try sessionEndCaptures(of: "private var (\\w+): NSButton!", in: code)
        #expect(selectors.sorted() == ["connectTapped", "endSessionTapped"])
        #expect(actions.sorted() == ["connectTapped", "endSessionTapped"])
        #expect(buttons.sorted() == ["connectButton", "endSessionButton"])
        #expect(sessionEndOccurrences(of: "@objc", in: code) == 2, "the file's only two action methods")
        for name in (selectors + actions + buttons) where name != "connectTapped" && name != "connectButton" {
            for counted in ["connectTapped", "connectButton", "tearDownSession"] {
                #expect(!name.contains(counted), "\(name) contains \(counted)")
            }
        }
    }

    // MARK: - adr/0020 S-6: no menu, no stdout, no reconnect route

    /// adr/0020 S-6, a guard: green before lane S and after it, red on three mutant classes. No
    /// `mainMenu` anywhere in `App/Macdows` (a menu item for Disconnect would bring key equivalents
    /// that take Cmd+W and friends before a RAIL window's `keyDown` sees them); no `print(` there
    /// (the product's Disconnect path adds no stdout line, D-10, and the App's only reachable
    /// stdout writer stays the reconnect driver's); and no `performClose` or `prepareForReconnect`
    /// anywhere in `AppDelegate` (an SC_CLOSE, the registry's reconnect seam). The same three
    /// routes, plus `connectTapped(`, are checked inside the action's own body by S-3' above,
    /// which can only be green once the action exists.
    ///
    /// A knob lane that prints an anchor line from `App/Macdows` collides with this pin and has to
    /// change it in the same commit.
    @Test("no mainMenu and no print( in App/Macdows, and no SC_CLOSE or reconnect seam in AppDelegate")
    func theEndSessionPathAddsNoMenuNoStdoutAndNoReconnect() throws {
        let files = try sessionEndSwiftFiles(under: "App/Macdows")
        #expect(files.contains(Self.appDelegate) && files.contains("App/Macdows/main.swift"),
                "the walk found \(files) -- this pin would pass vacuously")
        for file in files {
            let code = sessionEndCodeOnly(try sessionEndRawSource(file))
            #expect(sessionEndOccurrences(of: "mainMenu", in: code) == 0, "\(file)")
            #expect(sessionEndOccurrences(of: "print(", in: code) == 0, "\(file)")
        }

        let code = try Self.code()
        #expect(sessionEndOccurrences(of: "performClose", in: code) == 0)
        #expect(sessionEndOccurrences(of: "prepareForReconnect", in: code) == 0)
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
