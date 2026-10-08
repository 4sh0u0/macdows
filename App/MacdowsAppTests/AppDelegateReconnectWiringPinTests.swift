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
//  4. The connect-error branch keeps its failure line and its literal `true`, and then ends the
//     session through that same function. Lane D froze the branch's five statements byte-for-byte
//     and appended one call; the session-end lane lifted that freeze to repair the button it left
//     refusing every press (lane D impl-report §8 #1), keeping the two statements a human actually
//     sees. UI slice ④ re-worded the line to the catalog's `st_err` and moved the error itself to
//     a `[connect]` log line in front of it. RB-2 (adr/0019 supplementary ruling RB-1 (a′)) gave
//     the branch one condition: it leaves a leg the reconnect driver started to the driver.
//  5. The button is enabled by a literal `true` only where no reconnect state is involved: the two
//     places that predate this lane, and the three adr/0020 lane S added (the End-session action,
//     and the two host.env failures D-8 moved behind the button's disable -- since UI slice ①,
//     ADR-0024 D-9, the pin-unavailable refusal and the Password sheet's Cancel in their place).
//     Everything a reconnect decides reaches it through the presenter's `connectEnabled`.
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
        // UI slice ④ re-froze the literal this probe looked for ("Connecting...") to its
        // catalog accessor; the probe still needs a statement that sits on a line of its own.
        #expect(stripped.contains("statusLabel.stringValue = UIStrings.connecting"))
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
    /// statement, so the branch cannot drift below the drain (it must return BEFORE the drain: when
    /// this branch takes an error, the driver never sees the `.disconnected` that comes with it),
    /// and it runs to the branch's `return }`, so nothing can be inserted between the call and the
    /// return.
    ///
    /// RE-FROZEN by UI slice ④ (UI-1 spec §4.1; old needle's line was
    /// `statusLabel.stringValue = "Connect failed: \(error.localizedDescription)"`): the status line
    /// is the catalog's `st_err` (`UIStrings.connectionFailed`), and the error leaves the screen --
    /// it is logged as one `[connect]` line by domain and code (never its description, which can
    /// carry the address), the first statement of the branch. The order is otherwise lane S's.
    ///
    /// RE-FROZEN by RB-2 (adr/0019 supplementary ruling RB-1 (a′); old needle's condition was
    /// `if let error = session.lastConnectError {`): the branch takes the error only when the leg
    /// is not the reconnect driver's, `!ReconnectDriver.connectErrorBelongsToDriver(in:
    /// reconnectDriver?.state)`. A leg the driver started (`.reconnecting`, or `.waiting` after a
    /// transient failure of that leg) is left to the drain, which hands its `.disconnected` to the
    /// driver's step 1; a first connect and a live leg are taken here exactly as before. The
    /// branch's statements are unchanged. `ConnectErrorRoutingTests` drives the predicate and the
    /// driver through both routes.
    ///
    /// MUST-RED for: reverting to the hand-written statements, dropping or moving the literal
    /// `true`, re-wording the failure line, putting the error's description back on screen,
    /// returning without the teardown, and dropping or inverting the driver-leg condition.
    @Test("the connect-error branch logs the error, writes st_err, enables the button, and ends the session")
    func theConnectErrorBranchEndsTheSession() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "private func drainTick() { guard let session else { return } "
                + "if let error = session.lastConnectError, "
                + "!ReconnectDriver.connectErrorBelongsToDriver(in: reconnectDriver?.state) { "
                + "ConnectChain.log.notice(\"[connect] failed: domain=\\((error as NSError).domain, privacy: .public) "
                + "code=\\((error as NSError).code, privacy: .public)\") "
                + "statusLabel.stringValue = UIStrings.connectionFailed "
                + "connectButton.isEnabled = true "
                + "tearDownSession() "
                + "return }",
            in: stripped) == 1)
        #expect(occurrences(of: "localizedDescription", in: stripped) == 0, "the error's text is not shown or logged")
        #expect(occurrences(of: "connectErrorBelongsToDriver(", in: stripped) == 1,
                "the gate asks the driver's predicate in one place")
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
    /// Re-read, not re-counted, by UI slice ① (ADR-0024 D-9): the two host.env failures are gone
    /// with the host.env read; their two literals are now the pin-unavailable refusal (D-3′) and the
    /// Password sheet's Cancel -- both arms that end a press without a session, after the button
    /// was disabled. Still five literal trues and eight writes.
    ///
    /// Re-counted, not changed, by UI slice ④: its banner buttons press the Hosts window's own
    /// buttons (`MainWindowController.connect(to:)` / `disconnectSession()`), so this file gains no
    /// `isEnabled` write. Still five literal trues and eight writes.
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
    /// presenter's answer, and the button receives it in the same breath (and, since UI slice ④,
    /// the status bar right after them).
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
            of: "statusLabel.stringValue = shell.statusLine connectButton.isEnabled = shell.connectEnabled "
                + "mainWindow.setStatusBarText(shell.statusBar)",
            in: stripped) == 1,
            "all three parts of the shell, from the same value, adjacent")
        #expect(occurrences(of: "setStatusBarText(", in: stripped) == 1, "the per-tick bar write, in one place")
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
    /// order pins in this file.
    ///
    /// RE-FROZEN by UI slice ④: the presenter no longer shows the event count or the generation
    /// (UI-1 spec §4.1 replaced lane D's "N event(s) so far (generation G)" line), so the summary is
    /// the live-window count and the handshake moment of the current leg (`liveSince`), built by
    /// ONE helper, `connectedSummary()`, which the Hosts window's state write calls too. The old
    /// needle's `events: eventCount` and `generation: session?.currentGeneration ?? 0` are gone
    /// (`session?.currentGeneration` 1 -> 0 here); `eventCount`'s bookkeeping and its two resets are
    /// kept (the drain tick's gate reads it; `theDisplayNoteIsClearedByTheReconnect` holds them).
    ///
    /// RE-FROZEN by ADR-0025 a-1b (R-7): the presenter also gets the start panel's waiting late
    /// launch failure for the chain's host -- the same host the panel's launches are recorded under
    /// (`startPanelReading()` hands it `chainHost`) -- and shows it on the line while live. Passing
    /// `nil` there would leave every presenter test green and the line without the failure, so the
    /// argument is part of the needle and spelled once in the file.
    ///
    /// MUST-RED for: replacing any argument with a literal, reading the window count or the moment
    /// from somewhere other than the current registry / the App's one record, dropping an
    /// assignment, and a second summary builder.
    @Test("the presenter is fed the live session's values, not constants")
    func theShellIsBuiltFromTheLiveSessionsValues() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "private func applyShell(for state: ReconnectDriver.State) { "
                + "let shell = ShellReconnectPresenter.shell( "
                + "for: state, "
                + "connected: connectedSummary(), "
                + "displayNote: lastDisplayChangeNote, "
                + "lastLaunchFailure: startPanel.lastLaunchFailureReason(for: chainHost) "
                + ") "
                + "statusLabel.stringValue = shell.statusLine "
                + "connectButton.isEnabled = shell.connectEnabled "
                + "mainWindow.setStatusBarText(shell.statusBar) }",
            in: stripped) == 1)
        // UI slice ④ commit 2 adds the input capability (`dg_bar`) to the same builder.
        #expect(occurrences(
            of: "private func connectedSummary() -> ShellReconnectPresenter.ConnectedSummary { "
                + ".init(windows: registry?.windowSnapshots().count ?? 0, liveSince: liveSince, inputDegraded: inputNotice.degraded) }",
            in: stripped) == 1)
        #expect(occurrences(of: "connectedSummary()", in: stripped) == 3,
                "the declaration, applyShell, and the Hosts window's presentation")
        // The read that cannot be spelled anywhere else in this file: a second call site would mean
        // a second, possibly disagreeing, description of the same session.
        #expect(occurrences(of: "registry?.windowSnapshots().count", in: stripped) == 1)
        #expect(occurrences(of: "session?.currentGeneration", in: stripped) == 0)
        #expect(occurrences(of: "lastLaunchFailure:", in: stripped) == 1, "the failure reaches the presenter in one place")
    }

    /// UI slice ④ (UI-1 spec §4.1 "since 12:03"): the handshake moment has ONE record in the App,
    /// `liveSince`, set on a leg's first `.live` in the driver's state handler before the shell is
    /// written, cleared by every other state and at the chain's end, and read by the two places
    /// that show it -- the summary (status bar) and the status item's reading.
    ///
    /// MUST-RED for: a second writer of the moment, the record taken after the shell is written,
    /// and a reader that takes its own clock.
    @Test("the handshake moment has one record, set before the shell is written, read by the bar and the status item")
    func theHandshakeMomentHasOneRecord() throws {
        let stripped = try sourceWithoutComments(Self.appDelegate)
        #expect(occurrences(
            of: "if case .live = state { if liveSince == nil { liveSince = Date() } } else { liveSince = nil } applyShell(for: state)",
            in: stripped) == 1)
        #expect(occurrences(of: "liveSince = ", in: stripped) == 3, "set, cleared on other states, cleared at the chain's end")
        #expect(occurrences(of: "liveSince = nil", in: stripped) == 2)
        #expect(occurrences(of: "liveSince: liveSince", in: stripped) == 2, "the summary and the status item's reading")
        #expect(occurrences(of: "Date()", in: stripped) == 1, "the App takes the clock in one place")
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
