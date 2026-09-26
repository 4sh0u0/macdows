import Foundation
import Testing

// adr/0019 §2 lane D, the wiring half. `App/project.yml` gives this bundle the sources
// `MacdowsAppTests` + `RemoteWindowRendering` + `SessionControl` and deliberately not `Macdows`, so
// `AppDelegate` does not exist here as a type: the drain handler, the button and the label cannot
// be driven offline at all. Source text is therefore the only instrument available, the same
// instrument `ProductScaleDefaultPinTests` and `ReconnectSemanticsPinTests` already use on this
// same file and for this same reason.
//
// What these pins are FOR. `ShellReconnectPresenter` decides what the shell says and is covered by
// ordinary tests; the claims here are the ones no value can carry:
//
//  1. There is exactly ONE driver, armed once, before the connection it watches starts.
//  2. The driver sees the event stream, always AFTER the registry (a driver that ran first would
//     announce "Reconnecting" over a window table nobody had emptied yet).
//  3. The driver is disarmed at every exit -- the connect-error branch, the give-up branch, app
//     termination and (since adr/0020 lane S) the End-session button -- because a detached driver
//     is the only kind that cannot bring a session its owner has closed back up from a retry timer
//     that was already scheduled. Since the session-end lane every exit reaches it through ONE
//     function, `tearDownSession()`, whose body and single-spelling counts
//     `AppDelegateSessionEndPinTests` holds; three of the call sites are held here, beside the
//     other claims about those three paths, and the End-session action's next door, beside that
//     button's own pins.
//  4. The connect-error branch keeps its "Connect failed: ..." line and its literal `true`, and
//     then ends the session through that same function. Lane D froze the branch's five statements
//     byte-for-byte and appended one call; the session-end lane lifted that freeze to repair the
//     button it left refusing every press (lane D impl-report §8 #1), keeping the two statements
//     a human actually sees.
//  5. The button is enabled by a literal `true` only where no reconnect state is involved: the two
//     places that predate this lane, and the three adr/0020 lane S added (the End-session action,
//     and the two host.env failures D-8 moved behind the button's disable). Everything a reconnect
//     decides reaches it through the presenter's `connectEnabled`.
//
// REGISTERED GAP, stated rather than papered over: these pins check that the wiring is WRITTEN, not
// that it RUNS. No offline test in this repository can press that button. Closing the gap means
// splitting `AppDelegate` into a target this bundle can compile, which is a different lane.

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func rawSource(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// One source file with every run of whitespace collapsed to a single space, so a pin is about the
/// tokens and not about how the file happens to be wrapped or indented. Comments included.
private func source(_ relative: String) throws -> String {
    try rawSource(relative).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The same, with line comments removed first, so that a pin on a RUN OF STATEMENTS is not also a
/// pin on the prose between them.
///
/// Why this exists: the statements lane D was forbidden to touch have an explanatory comment
/// sitting in the middle of them, so the only contiguous needle that could hold "these five, in
/// this order, with nothing inserted" over the collapsed text would have had to quote that comment
/// too -- and would then have gone red every time somebody re-wrapped a sentence. Stripping the
/// prose makes the pin say exactly what it means.
///
/// LIMITATION, checked rather than assumed: `//` inside a string literal would be stripped as well.
/// `AppDelegate.swift` contains none, and `theCommentStripperDidNotEatTheCode` below is what keeps
/// that true.
private func sourceWithoutComments(_ relative: String) throws -> String {
    let lines = try rawSource(relative).split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The index of `needle` inside `haystack`. Fails the test rather than returning a sentinel, so
/// "the call vanished" can never read as "the call is in the right place".
private func index(of needle: String, in haystack: String) throws -> String.Index {
    let found = try #require(haystack.range(of: needle), "not found: \(needle)")
    return found.lowerBound
}

@Suite("adr/0019 §2 lane D — the reconnect driver's wiring in AppDelegate, pinned as source")
struct AppDelegateReconnectWiringPinTests {

    private static let appDelegate = "App/Macdows/AppDelegate.swift"

    /// The comment stripper's own guard. If it ever ate code, every pin below would start passing
    /// vacuously against a shorter file, so the thing to check is that the statements the other
    /// tests look for are still there after stripping.
    @Test("the comment stripper removes prose and nothing else")
    func theCommentStripperDidNotEatTheCode() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(stripped.contains("newSession.start()"))
        #expect(stripped.contains("statusLabel.stringValue = \"Connecting...\""))
        #expect(!stripped.contains("adr/0019 §2 lane D"), "a line comment survived the strip")
        // The `//` in this file's own paths and URLs lives in comments only; a `//` appearing
        // inside a string literal would silently truncate that line and this is the alarm.
        #expect(!stripped.contains("// "), "a comment marker survived the strip")
    }

    // MARK: - D-5: one driver, armed once, disarmed at every exit

    /// D-5a. The counts. One construction, one arming, ONE disarming -- inside
    /// `tearDownSession()`, which every exit calls. Lane D had three hand-written disarmings here
    /// (connect-error branch, give-up teardown, termination); the session-end lane folded them into
    /// the shared teardown, and the three exits are now held as call sites (D-7, the give-up pin and
    /// the termination pin below).
    ///
    /// Counted over the UNSTRIPPED fold, as before: prose in `AppDelegate.swift` does not spell the
    /// dotted call either, and keeping it that way is part of what this pin holds.
    ///
    /// MUST-RED for: a second `ReconnectDriver(...)` anywhere in the app entry point, an
    /// `attach()` that is never paired, a dropped `detach()`, and an exit that disarms the driver by
    /// hand beside the shared teardown.
    @Test("one construction, one attach, one detach -- inside the shared teardown")
    func theDriverIsBuiltOnceAndDisarmedAtEveryExit() throws {
        let src = try source(Self.appDelegate)
        #expect(occurrences(of: "ReconnectDriver(", in: src) == 1,
                "the app entry point constructs exactly one driver")
        #expect(occurrences(of: "ReconnectDriver(session: newSession, registry: newRegistry)", in: src) == 1,
                "and it is built from the session and registry this connection just created")
        #expect(occurrences(of: ".attach()", in: src) == 1)
        #expect(occurrences(of: ".detach()", in: src) == 1,
                "tearDownSession(), called by the connect-error branch, the give-up branch, endSessionTapped and applicationWillTerminate")
    }

    /// D-5b. The ARMING ORDER. A driver attached after `-start` can miss the events of the
    /// connection it is supposed to be watching; the registry it is built from has to exist first.
    ///
    /// MUST-RED for: moving the driver block below `newSession.start()`, and for attaching before
    /// either seam is installed (an event arriving between the two would be handled by a driver
    /// with no topology hook and no consumer for its state).
    @Test("the driver is built after the registry, armed after both seams, and armed before start()")
    func theDriverIsArmedBeforeTheConnectionStarts() throws {
        // Comment-stripped, because the prose around this block names the very calls being
        // ordered ("armed before `newSession.start()` below"), and a mention is not a call site.
        let src = try sourceWithoutComments(Self.appDelegate)
        let registry = try index(of: "let newRegistry = RemoteWindowRegistry(", in: src)
        let build = try index(of: "let driver = ReconnectDriver(", in: src)
        let topology = try index(of: "driver.topologyRefresh = {", in: src)
        let onState = try index(of: "driver.onStateChange = {", in: src)
        let attach = try index(of: "driver.attach()", in: src)
        let start = try index(of: "newSession.start()", in: src)
        #expect(registry < build)
        #expect(build < topology)
        #expect(topology < onState)
        #expect(onState < attach)
        #expect(attach < start, "an event can only be posted after start(); the driver is armed first")
        #expect(occurrences(of: "driver.attach() reconnectDriver = driver", in: src) == 1,
                "the armed driver is the one this delegate keeps")
    }

    /// D-5c. THE SEAMS. `topologyRefresh` must be built out of this delegate's resident provider
    /// (adr/0015 §5.A.5 allows exactly one `NSScreen` reader in the project), must return the
    /// provider rather than discard it (adr/0019 §2 lane C), and `onStateChange` must not capture
    /// `self` strongly -- this delegate owns the driver, so a strong capture is a cycle.
    ///
    /// MUST-RED for: giving the driver a provider of its own, dropping `refreeze`'s result,
    /// and a strong `self` in either closure.
    @Test("the topology hook is the App's own provider, and neither closure retains the delegate")
    func theSeamsAreInstalledTheWayTheirOwnersRequire() throws {
        let src = try source(Self.appDelegate)
        #expect(occurrences(
            of: "driver.topologyRefresh = { [weak self, unowned newSession] in guard let self else { return nil } "
                + "return ReconnectTopologyRefresh.refreeze(session: newSession, topology: self.displayTopology) }",
            in: src) == 1,
            "the hook returns the refreeze's provider, and reads the App's single NSScreen reader")
        #expect(occurrences(
            of: "driver.onStateChange = { [weak self] state in self?.applyReconnectState(state) }",
            in: src) == 1)
        #expect(occurrences(of: "ReconnectTopologyRefresh.refreeze(", in: src) == 1,
                "one re-take call site; a second would freeze twice for one reconnect")
    }

    // MARK: - D-6: the event stream reaches the driver, after the registry

    /// D-6. The forwarding, and its order.
    ///
    /// The needle is the whole tail of the drain closure plus the two statements after it, as one
    /// contiguous run, which is what makes this a pin on ORDER rather than on presence. Swapping
    /// the two `handle` calls, dropping either, or moving the status write above the re-read guard
    /// all change this string.
    ///
    /// The re-read guard is part of the same claim: a driver that gives up does so from inside this
    /// very closure and tears the session down there, so the status write that follows must not
    /// describe a session that stopped existing halfway through the drain.
    @Test("every drained event reaches the registry first and the driver second")
    func theDriverIsForwardedEveryEventAfterTheRegistry() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "self?.registry?.handle(event) self?.reconnectDriver?.handle(event) } "
                + "guard self.session != nil else { return } "
                + "if delivered > 0 || eventCount > 0 { applyShell(for: reconnectDriver?.state ?? .live) }",
            in: stripped) == 1)

        let src = try source(Self.appDelegate)
        #expect(occurrences(of: "reconnectDriver?.handle(", in: src) == 1,
                "the driver is fed from exactly one place")
        #expect(occurrences(of: "registry?.handle(event)", in: src) == 1)
        let registry = try index(of: "self?.registry?.handle(event)", in: src)
        let driver = try index(of: "self?.reconnectDriver?.handle(event)", in: src)
        #expect(registry < driver, "registry first: see the comment at that line for why")
    }

    // MARK: - D-7: the connect-error branch ends the session, and `true` stays in two places

    /// D-7, re-frozen by the session-end lane. The `lastConnectError` branch ENDS the session.
    ///
    /// Lane D froze this branch's five statements byte-for-byte and appended one `detach()`, and in
    /// doing so froze a registered defect along with them (lane D impl-report §8 #1): the branch
    /// re-enabled the button without dropping `session`, and `connectTapped`'s first guard is
    /// `session == nil`, so the enabled button answered "Already connecting/connected." to every
    /// press. The session-end lane lifted that freeze and kept exactly two statements from it, the
    /// "Connect failed: ..." wording and the literal `true`. The rest -- stopping the timer, the
    /// topology's `endSession()`, the appended disarming -- is now the shared teardown, which also
    /// drops the session, the registry and the driver.
    ///
    /// UI first, teardown second: the same order the give-up path has, where the presenter writes
    /// the give-up line before the teardown runs. The needle starts at the method's own first
    /// statement, so the branch cannot drift below the drain (it must return BEFORE the drain: the
    /// driver never sees the `.disconnected` a bridge refusal produces on this path), and it runs to
    /// the branch's `return }`, so nothing can be inserted between the call and the return.
    ///
    /// MUST-RED for: reverting to the hand-written statements, dropping or moving the literal
    /// `true`, re-wording the failure line, and returning without the teardown.
    @Test("the connect-error branch writes the failure, enables the button, and ends the session")
    func theConnectErrorBranchEndsTheSession() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "private func drainTick() { guard let session else { return } "
                + "if let error = session.lastConnectError { "
                + "statusLabel.stringValue = \"Connect failed: \\(error.localizedDescription)\" "
                + "connectButton.isEnabled = true "
                + "tearDownSession() "
                + "return }",
            in: stripped) == 1)
    }

    /// D-7b. The literal `true` stays in the two places that predate this lane -- the boundary
    /// refusal and the connect-error branch -- plus the three adr/0020 lane S added, none of which is
    /// a reconnect state either: the End-session action (D-5 = Q1), and the two host.env failures
    /// (unreadable, keys missing) that D-8 moved off the main actor and therefore behind the
    /// button's disable, where each has to hand the button back. Every enable a reconnect decides
    /// goes through the presenter, so any further literal would be a second opinion about when the
    /// button is usable. Re-frozen by lane S: 2 -> 3 literal trues and 5 -> 6 writes in its main
    /// commit, 3 -> 5 and 6 -> 8 in its separable D-8 commit.
    ///
    /// Read from the comment-stripped text so that a `true` written in prose cannot be counted.
    @Test("connectButton.isEnabled = true survives in exactly five places, none of them a reconnect state")
    func theButtonIsEnabledByALiteralInFivePlacesOnly() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(of: "connectButton.isEnabled = true", in: stripped) == 5)
        #expect(occurrences(of: "connectButton.isEnabled = shell.connectEnabled", in: stripped) == 1,
                "the reconnect-aware enable, in one place")
        #expect(occurrences(of: "connectButton.isEnabled =", in: stripped) == 8,
                "five literal trues, two literal falses (the Connect press, the session start), one presenter")
    }

    // MARK: - the status line has one writer, and the give-up teardown is complete

    /// D-3, App side. The "Connected" wording left this file; the label now receives the
    /// presenter's answer, and the button receives it in the same breath.
    ///
    /// MUST-RED for: re-introducing a hard-coded connected status here (which is what made a
    /// dropped session go on being announced as connected once a second), and for writing one half
    /// of the shell without the other.
    @Test("the shell is written from the presenter, in one place, and the old wording is gone")
    func theStatusLineHasOneReconnectAwareWriter() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(of: "Connected —", in: stripped) == 0,
                "the connected wording lives in ShellReconnectPresenter now")
        #expect(occurrences(of: "remote window(s) live", in: stripped) == 0)
        #expect(occurrences(of: "ShellReconnectPresenter.shell(", in: stripped) == 1)
        #expect(occurrences(
            of: "statusLabel.stringValue = shell.statusLine connectButton.isEnabled = shell.connectEnabled",
            in: stripped) == 1,
            "both halves of the shell, from the same value, adjacent")
    }

    /// GATE r1 I-1. THE ARGUMENT LIST, and not just the call.
    ///
    /// The test above pins that the presenter is called and that both halves of its answer are
    /// assigned. It says nothing about WHAT is passed, and three surviving mutants measured the
    /// size of that hole: `generation:` pinned to `0`, `events:` pinned to `0`, and
    /// `displayNote:` pinned to `nil` all left the whole bundle green. The third is the worst of
    /// them -- it silently reinstates the defect the comment a few lines above this call records
    /// M1/W1 as having fixed, because adr/0015 §5.A.3's screen-parameter note would then be wiped
    /// by every drain tick instead of carried through it.
    ///
    /// The reason the hole existed is the reason this lane is shaped the way it is:
    /// `ShellReconnectPresenter`'s own tests prove that three distinct numbers land in three
    /// distinct places and that every state appends the note -- and every one of those proofs is
    /// vacuous if the App feeds the presenter constants. Binding the four expressions to their
    /// sources is the ONLY job lane D left inside `AppDelegate`, so it is the one thing that has
    /// to be pinned here.
    ///
    /// One needle over the whole function body, comment-stripped, same technique as the other
    /// order pins in this file. MUST-RED for: replacing any of the four arguments with a literal,
    /// swapping `events:` and `windows:` (both are `Int`, so the compiler would not object),
    /// reading the generation from somewhere other than the current session, and dropping either
    /// assignment.
    @Test("the presenter is fed the live session's numbers, not constants")
    func theShellIsBuiltFromTheLiveSessionsValues() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "private func applyShell(for state: ReconnectDriver.State) { "
                + "let shell = ShellReconnectPresenter.shell( "
                + "for: state, "
                + "connected: .init( "
                + "events: eventCount, "
                + "generation: session?.currentGeneration ?? 0, "
                + "windows: registry?.windowSnapshots().count ?? 0 "
                + "), "
                + "displayNote: lastDisplayChangeNote "
                + ") "
                + "statusLabel.stringValue = shell.statusLine "
                + "connectButton.isEnabled = shell.connectEnabled }",
            in: stripped) == 1)
        // The two reads that cannot be spelled anywhere else in this file: a second call site for
        // either would mean a second, possibly disagreeing, description of the same session.
        #expect(occurrences(of: "session?.currentGeneration", in: stripped) == 1)
        #expect(occurrences(of: "registry?.windowSnapshots().count", in: stripped) == 1)
    }

    /// The give-up branch ends the session through the shared teardown.
    ///
    /// `session = nil` is the statement that matters and it is still the only one in the file --
    /// now inside `tearDownSession()`, whose body `AppDelegateSessionEndPinTests` holds and which
    /// this branch, the connect-error branch and termination all call. `connectTapped`'s first guard
    /// is `session == nil` and an automatic reconnect reuses the same `CRSession`, so a give-up that
    /// re-enabled the button without dropping the session would produce a button that answers
    /// "Already connecting/connected." to every press. Lane D registered the same defect on the
    /// connect-error path; the session-end lane repaired it there by routing that branch through
    /// this same function, which is why the give-up teardown stopped being a function of its own.
    ///
    /// MUST-RED for: the give-up branch no longer ending the session, a second `session = nil` (an
    /// exit that ends a session by hand), and dropping it altogether.
    @Test("giving up really ends the session, so the button it enables can start a new one")
    func theGiveUpTeardownDropsTheSession() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(of: "if case .gaveUp = state { tearDownSession() }", in: stripped) == 1,
                "reached from the driver's state change")
        #expect(occurrences(of: "session = nil", in: stripped) == 1,
                "the one place this app stops having a session")
    }

    /// Termination is the shared teardown, which disarms the driver BEFORE the shutdown it is about
    /// to cause.
    ///
    /// `teardownInitiated` (which `-shutdownAndWait` sets) closes the event edge on its own, but a
    /// retry already sitting on the clock is a second edge, and only disarming cancels that. Until
    /// the session-end lane this method carried a teardown of its own that dropped nothing (lane D
    /// impl-report §8 #7); it is now one call, so this app has one shape for "a session ends".
    ///
    /// The order is read by index over the whole stripped file, which is sound because
    /// `AppDelegateSessionEndPinTests` holds each of the two calls to a single spelling.
    ///
    /// MUST-RED for: termination keeping any hand-written step beside or instead of the call, and
    /// the shared teardown shutting down before it disarms.
    @Test("applicationWillTerminate is the shared teardown, which detaches before it shuts down")
    func terminationDisarmsTheDriverFirst() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "func applicationWillTerminate(_ notification: Notification) { tearDownSession() }",
            in: stripped) == 1)
        let detach = try index(of: "reconnectDriver?.detach()", in: stripped)
        let shutdown = try index(of: "session?.shutdownAndWait()", in: stripped)
        #expect(detach < shutdown, "disarm first: a scheduled retry is an edge teardownInitiated does not close")
    }

    /// The display-change note is cleared by the reconnect that makes it stale, in the one place
    /// that knows a re-freeze just happened -- the same rule the connect path states for itself.
    ///
    /// adr/0020 S-7 (D-7, #4), re-frozen by lane S: the same branch restarts the event count, so
    /// the status line's event count and its `generation` -- which steps inside the same
    /// synchronous turn, when the driver's restart shuts the old connection down -- describe one
    /// connection. `beginSession`'s reset is the other `eventCount = 0`.
    ///
    /// MUST-RED for: the reset dropped from the branch, moved out of it, or spelled a third time.
    @Test("a reconnect clears the display-change note and restarts the event count, on .reconnecting")
    func theDisplayNoteIsClearedByTheReconnect() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "if case .reconnecting = state { lastDisplayChangeNote = nil eventCount = 0 }", in: stripped) == 1)
        #expect(occurrences(of: "lastDisplayChangeNote = nil", in: stripped) == 2,
                "the connect path's own clear, and the reconnect's")
        #expect(occurrences(of: "eventCount = 0", in: stripped) == 2,
                "beginSession's reset, and the reconnect's (adr/0020 D-7)")
    }
}
