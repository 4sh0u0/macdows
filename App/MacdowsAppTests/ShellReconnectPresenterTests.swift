import Foundation
import MacdowsCore
import Testing

// adr/0019 §2 lane D, the behaviour half. `ShellReconnectPresenter` is the only part of the shell's
// reconnect story that offline Swift can reach at all: `App/project.yml` keeps `Macdows` out of this
// bundle's sources, so `AppDelegate` itself is only ever checked by
// `AppDelegateReconnectWiringPinTests`' source pins. Everything that DECIDES what the button and the
// label say is therefore here, and the pins next door only have to hold "the two assignments exist,
// once each, and read from this type".
//
// D-3 carries the frozen "Connected" text as a literal. That is a transcription of what
// `AppDelegate.drainTick` printed before this lane moved it, and the pin file asserts the App no
// longer spells it itself -- one writer, one wording, and a diff on either side lands here.

@MainActor
@Suite("adr/0019 §2 lane D — the shell the reconnect driver's state implies")
struct ShellReconnectPresenterTests {

    private static let summary = ShellReconnectPresenter.ConnectedSummary(
        events: 7, generation: 3, windows: 2)

    /// Every `State` this type must answer for. Written out rather than derived, so a new case
    /// added to `ReconnectDriver.State` makes the presenter's `switch` fail to compile and this
    /// list fail to be exhaustive -- two reminders instead of a silent default.
    ///
    /// A function rather than a stored property, and looped over inside a test body rather than
    /// handed to `arguments:`, because `ReconnectDriver` is `@MainActor` and a `@Test` attribute's
    /// argument expression is not evaluated in this suite's isolation.
    private static func everyState() -> [ReconnectDriver.State] {
        [
            .idle,
            .live,
            .waiting(attempt: 0, delay: .seconds(1)),
            .reconnecting(attempt: 1),
            .gaveUp(.policy(.attemptsExhausted)),
        ]
    }

    /// Every `GiveUpCause` shape `ReconnectDriver.token(for:)` can be handed, for the same reason.
    private static func everyGiveUpCause() -> [ReconnectDriver.GiveUpCause] {
        [
            .policy(.attemptsExhausted),
            .refusedByBridge(code: -3),
            .policyRefused(attemptIndex: 2),
        ]
    }

    private static func shell(
        _ state: ReconnectDriver.State,
        note: String? = nil
    ) -> ShellReconnectPresenter.Shell {
        ShellReconnectPresenter.shell(for: state, connected: summary, displayNote: note)
    }

    /// The text between the first `(` and the last `)`, i.e. the give-up line's cause word, read
    /// out of the rendered line instead of re-stated as a literal. D-2's whole point is that this
    /// file never writes the vocabulary down.
    private static func parenthesised(_ line: String) throws -> String {
        let open = try #require(line.firstIndex(of: "("), "no '(' in: \(line)")
        let close = try #require(line.lastIndex(of: ")"), "no ')' in: \(line)")
        #expect(open < close, "empty or reversed parentheses in: \(line)")
        return String(line[line.index(after: open)..<close])
    }

    // MARK: - D-1

    /// D-1. A scheduled retry: the button must not accept a press, and the line must report the
    /// attempt the way a human counts and the delay the policy actually asked for.
    ///
    /// `attempt: 0` is the FIRST retry (the policy's zero-based failed-attempt index), so
    /// `attempt 1 of 5` is the correct rendering of it and `attempt 0 of 5` would be the bug this
    /// asserts against. `1.0 s` is `.seconds(1)` rendered; a presenter that re-derived the delay
    /// from the attempt index instead of carrying the policy's own value would still print `1.0 s`
    /// here, which is why D-1b below uses an attempt/delay pair the curve does not produce.
    @Test("waiting: button disabled, attempt printed one-based, delay from the policy's value")
    func waitingDisablesTheButtonAndReportsTheAttempt() throws {
        let shell = Self.shell(.waiting(attempt: 0, delay: .seconds(1)))
        #expect(shell.connectEnabled == false)
        #expect(shell.statusLine.contains("attempt 1 of 5"))
        #expect(shell.statusLine.contains("1.0 s"))
        #expect(!shell.statusLine.contains("attempt 0"))
    }

    /// D-1b. The delay is CARRIED, not re-derived. `attempt: 3` with a 16 s delay is not a point on
    /// the 1/2/4/8 curve; a presenter computing `baseDelay * 2^n` would print `8.0 s` here.
    @Test("waiting: the printed delay is the state's own Duration, not one re-derived from the index")
    func waitingPrintsTheCarriedDelay() throws {
        let shell = Self.shell(.waiting(attempt: 3, delay: .seconds(16)))
        #expect(shell.statusLine.contains("attempt 4 of 5"))
        #expect(shell.statusLine.contains("16.0 s"))
    }

    /// D-1c. The cap in the line is the policy's, not a literal that can drift away from it.
    @Test("the attempt ceiling in the line is ReconnectPolicy.maxAttempts")
    func theCeilingComesFromThePolicy() throws {
        let shell = Self.shell(.reconnecting(attempt: 0))
        #expect(shell.statusLine.contains("of \(ReconnectPolicy.maxAttempts)"))
        #expect(ReconnectPolicy.maxAttempts == 5, "the provisional cap this lane's wording assumes")
    }

    // MARK: - D-2

    /// D-2. Giving up is the one state that re-opens the button, and the word it shows is the
    /// driver's own `cause=` token rather than a second vocabulary invented for the UI.
    ///
    /// The comparison is made against `ReconnectDriver.token(for:)`'s return value, so this test
    /// contains no cause spelling at all: changing the token changes both sides together, and
    /// changing only the label's wording is red.
    @Test("gaveUp: button enabled, and the cause word IS the [reconnect] line's cause token")
    func gaveUpEnablesTheButtonAndSpeaksTheDriversVocabulary() throws {
        #expect(Self.everyGiveUpCause().count == 3, "one row per GiveUpCause case")
        for cause in Self.everyGiveUpCause() {
            let shell = Self.shell(.gaveUp(cause))
            #expect(shell.connectEnabled == true, "cause: \(cause)")
            let token = ReconnectDriver.token(for: cause)
            #expect(try Self.parenthesised(shell.statusLine) == token)
            #expect(shell.statusLine.contains(token))
        }
    }

    /// D-2b. The give-up line tells the human what to do next, and the thing it tells them to do is
    /// the thing the button now allows. A line that said "gave up" over a disabled button would be
    /// the failure mode lane D exists to remove.
    @Test("gaveUp: the line names the recovery the enabled button provides")
    func gaveUpNamesTheRecovery() throws {
        let shell = Self.shell(.gaveUp(.policy(.attemptsExhausted)))
        #expect(shell.statusLine.contains("Press Connect"))
        #expect(shell.connectEnabled == true)
    }

    // MARK: - D-3

    /// D-3. The ordinary connected shell is BYTE-IDENTICAL to what `AppDelegate.drainTick` wrote
    /// before lane D moved it into this type, and the button stays disabled while a session is up.
    ///
    /// The literal below is that transcription. `AppDelegateReconnectWiringPinTests` asserts the
    /// App no longer carries the wording itself, so the two cannot drift apart into two spellings
    /// of "connected" without one of the two tests going red.
    @Test("live: the connected text is the pre-lane-D wording, verbatim, and the button is disabled")
    func liveKeepsTheConnectedWordingVerbatim() throws {
        let shell = Self.shell(.live)
        #expect(shell.connectEnabled == false)
        #expect(shell.statusLine == """
            Connected — 7 event(s) so far (generation 3)
            2 remote window(s) live
            """)
    }

    /// D-3b. `.idle` renders the same connected shell as `.live`.
    ///
    /// Not an oversight and not a convenience: `.idle` is the driver's value between `-start` and
    /// the RAIL handshake, which the App reads on every drain tick in that window. Rendering
    /// anything else there would change the ordinary connect path -- a path this lane must leave
    /// exactly as it found it.
    @Test("idle: the same connected shell as live, because idle is also the pre-handshake value")
    func idleRendersTheConnectedShell() throws {
        #expect(Self.shell(.idle) == Self.shell(.live))
        #expect(Self.shell(.idle).connectEnabled == false)
    }

    /// D-3c. The summary's three numbers all reach the line, and each reaches its own place. A
    /// presenter that printed the window count where the event count belongs passes every
    /// `contains` check written with equal numbers.
    @Test("live: the three summary numbers land in three distinct places")
    func liveReportsEachSummaryNumberOnce() throws {
        let shell = ShellReconnectPresenter.shell(
            for: .live,
            connected: .init(events: 11, generation: 22, windows: 33),
            displayNote: nil)
        #expect(shell.statusLine == """
            Connected — 11 event(s) so far (generation 22)
            33 remote window(s) live
            """)
    }

    // MARK: - D-4

    /// D-4. adr/0015 §5.A.3's screen-parameter note is APPENDED in every state, never substituted.
    ///
    /// The claim is made as "the noted line is the unnoted line plus the suffix", which is stronger
    /// than `contains`: it also catches a state that drops the connection text and shows only the
    /// note, and a state that puts the note somewhere other than the end.
    @Test("every state appends the display note rather than replacing its own text")
    func theDisplayNoteIsAppendedInEveryState() throws {
        let note = "Display change: this session's desktop size is unaffected."
        for state in Self.everyState() {
            let plain = Self.shell(state)
            let noted = Self.shell(state, note: note)
            #expect(noted.statusLine == plain.statusLine + "\n" + note, "state: \(state)")
            #expect(noted.connectEnabled == plain.connectEnabled,
                    "a display change is not evidence about the connection (§5.A.3): \(state)")
        }
    }

    /// D-4b. The list above really did cover every case. `ReconnectDriver.State` has five, and a
    /// sixth arriving without a row here would leave a state whose note handling nobody checked.
    @Test("the state list covers all five states, each exactly once")
    func everyStateIsCoveredOnce() throws {
        let states = Self.everyState()
        #expect(states.count == 5)
        for state in states {
            #expect(states.filter { $0 == state }.count == 1, "duplicated: \(state)")
        }
    }

    /// D-4c. No note means no suffix at all -- not an empty line, which would leave the label
    /// taller than its text for the whole of an ordinary session.
    @Test("no display note adds no trailing newline")
    func noNoteAddsNothing() throws {
        #expect(!Self.shell(.live).statusLine.hasSuffix("\n"))
    }

    // MARK: - the two mappings, named

    /// The zero-based-to-one-based mapping, as its own checked claim. The status line and the
    /// `[reconnect]` line differ by one BY DESIGN, and this is where that is written down in a form
    /// that fails if someone "fixes" it.
    @Test("the attempt mapping is the policy index plus one")
    func theAttemptMappingIsOffByOneOnPurpose() throws {
        #expect(ShellReconnectPresenter.humanAttemptNumber(forZeroBasedIndex: 0) == 1)
        #expect(ShellReconnectPresenter.humanAttemptNumber(forZeroBasedIndex: 4) == 5)
        let index = 2
        let line = Self.shell(.waiting(attempt: index, delay: .seconds(4))).statusLine
        let logLine = try #require(ReconnectDriver.logLine(
            for: .waiting(attempt: index, delay: .seconds(4)), failedAttempts: index))
        #expect(logLine.contains("attempt=\(index)"))
        #expect(line.contains("attempt \(index + 1) of"))
    }

    /// The delay rendering, against the same `Duration` the log line measures in milliseconds.
    @Test("the delay text and the log line's delay-ms are two renderings of one Duration")
    func theDelayTextAgreesWithTheLogLine() throws {
        for seconds in [1, 2, 4, 8, 16] {
            let delay = Duration.seconds(seconds)
            #expect(ShellReconnectPresenter.delayText(delay) == "\(seconds).0 s")
            #expect(ReconnectDriver.milliseconds(delay) == Int64(seconds) * 1_000)
        }
    }
}
