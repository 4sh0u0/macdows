import Foundation
import MacdowsCore
import Testing

// adr/0019 §2 lane D, the behaviour half -- RE-FROZEN by UI slice ④ (UI-1 spec §4.1 / §4.2 / §4.3).
// `ShellReconnectPresenter` is the only part of the shell's reconnect story that offline Swift can
// reach at all: `App/project.yml` keeps `Macdows` out of this bundle's sources, so `AppDelegate`
// itself is only ever checked by `AppDelegateReconnectWiringPinTests`' source pins. Everything that
// DECIDES what the button, the status line and the status bar say is therefore here.
//
// What slice ④ re-froze, and why. Lane D froze English developer text ("Connected — 7 event(s) so
// far (generation 3)", "Reconnecting — attempt 1 of 5, retrying in 1.0 s", "Disconnected — gave up
// (<token>). Press Connect to try again."). The UI-1 table REPLACES those strings (spec §4.1:
// "替换而非对齐"), so the literals below are now the table's three languages, copied from the spec;
// the attempt denominator is the number of reconnects (`maxAttempts - 1`), and the cause token is
// no longer shown (it stays in the `[reconnect]` line and the diagnostics export). The checks that
// were about structure, not wording -- the note is appended in every state, the attempt is
// one-based, the delay is the state's own `Duration`, only `.gaveUp` enables Connect -- are kept.

@MainActor
@Suite("adr/0019 §2 lane D / UI slice ④ — the shell the reconnect driver's state implies")
struct ShellReconnectPresenterTests {

    private static let summary = ShellReconnectPresenter.ConnectedSummary(
        windows: 2, liveSince: Date(timeIntervalSince1970: 0))

    /// Every `State` this type must answer for. Written out rather than derived, so a new case
    /// added to `ReconnectDriver.State` makes the presenter's `switch` fail to compile and this
    /// list fail to be exhaustive -- two reminders instead of a silent default.
    private static func everyState() -> [ReconnectDriver.State] {
        [
            .idle,
            .live,
            .waiting(attempt: 0, delay: .seconds(1)),
            .reconnecting(attempt: 1),
            .gaveUp(.policy(.attemptsExhausted)),
        ]
    }

    /// Every `GiveUpCause` shape `ReconnectDriver.token(for:)` can be handed.
    private static func everyGiveUpCause() -> [ReconnectDriver.GiveUpCause] {
        [
            .policy(.attemptsExhausted),
            .refusedByBridge(code: -3),
            .policyRefused(attemptIndex: 2),
            .certificateRejected(unsupportedRoute: false),
        ]
    }

    private static func shell(
        _ state: ReconnectDriver.State,
        note: String? = nil,
        failure: String? = nil,
        language: String = "en",
        connected: ShellReconnectPresenter.ConnectedSummary = summary
    ) throws -> ShellReconnectPresenter.Shell {
        ShellReconnectPresenter.shell(for: state, connected: connected, displayNote: note, lastLaunchFailure: failure,
                                      text: try .catalog(language))
    }

    // MARK: - D-1: the reconnect states

    /// D-1. A scheduled retry: the button must not accept a press, and the line must report the
    /// attempt the way a human counts, out of the number of reconnects, with the delay the policy
    /// actually asked for. `attempt: 0` is the FIRST retry, so "attempt 1 of 4" is correct and
    /// "attempt 0" would be the bug.
    @Test("waiting: button disabled, attempt one-based out of maxAttempts - 1, delay from the policy's value")
    func waitingDisablesTheButtonAndReportsTheAttempt() throws {
        let shell = try Self.shell(.waiting(attempt: 0, delay: .seconds(1)))
        #expect(shell.connectEnabled == false)
        #expect(shell.statusLine == "Connection lost · Reconnecting (attempt 1 of 4) in 1.0 s")
        #expect(shell.statusBar == shell.statusLine, "UI-1 §4.1: one text for the line and the bar")
        #expect(!shell.statusLine.contains("attempt 0"))
    }

    /// D-1b. The delay is CARRIED, not re-derived. `attempt: 3` with a 16 s delay is not a point on
    /// the 1/2/4/8 curve; a presenter computing `baseDelay * 2^n` would print `8.0` here.
    @Test("waiting: the printed delay is the state's own Duration, not one re-derived from the index")
    func waitingPrintsTheCarriedDelay() throws {
        let shell = try Self.shell(.waiting(attempt: 3, delay: .seconds(16)))
        #expect(shell.statusLine == "Connection lost · Reconnecting (attempt 4 of 4) in 16.0 s")
    }

    /// D-1c. The denominator is derived from the policy: `maxAttempts - 1` reconnects (the first of
    /// the policy's attempts is the connection that dropped), never a literal and never
    /// `maxAttempts` itself, which is what lane D's wording printed.
    @Test("the attempt denominator is ReconnectPolicy.maxAttempts - 1")
    func theDenominatorComesFromThePolicy() throws {
        #expect(ReconnectPolicy.maxAttempts == 5, "the provisional cap the UI-1 table's \"of 4\" assumes")
        #expect(ShellReconnectPresenter.reconnectCount == ReconnectPolicy.maxAttempts - 1)
        let shell = try Self.shell(.reconnecting(attempt: 0))
        #expect(shell.statusLine.contains("of \(ReconnectPolicy.maxAttempts - 1))"))
        #expect(!shell.statusLine.contains("of \(ReconnectPolicy.maxAttempts)"))
        #expect(try Self.shell(.gaveUp(.policy(.attemptsExhausted))).statusLine.contains("after \(ReconnectPolicy.maxAttempts - 1) attempts"))
    }

    // MARK: - D-2: giving up

    /// D-2, re-frozen. Giving up is the one state that re-opens the button. The cause token is NOT
    /// on screen any more (UI-1 §4.1: "cause token 不进主文案，只进诊断包"): no cause's token appears in
    /// any language's line or bar, and none of lane D's English wording survives.
    @Test("gaveUp: button enabled for every cause, and no cause token or lane-D wording on screen")
    func gaveUpEnablesTheButtonAndShowsNoToken() throws {
        #expect(Self.everyGiveUpCause().count == 4, "one row per GiveUpCause case (ADR-0024 D-5 added certificateRejected)")
        let tokens = Self.everyGiveUpCause().map(ReconnectDriver.token(for:))
        for language in ["en", "zh-Hans", "ja"] {
            for cause in Self.everyGiveUpCause() {
                let shell = try Self.shell(.gaveUp(cause), language: language)
                #expect(shell.connectEnabled == true, "cause: \(cause)")
                for token in tokens {
                    #expect(!shell.statusLine.contains(token) && !shell.statusBar.contains(token), "\(language) \(cause): \(token)")
                }
                for old in ["Press Connect", "gave up", "Disconnected —", "Reconnecting —", "<missing:"] {
                    #expect(!shell.statusLine.contains(old), "\(language) \(cause): \(old)")
                }
            }
        }
    }

    /// D-2b. The two give-up causes the UI-1 table names, and the certificate cause, which the
    /// certificate path owns (ADR-0024 D-5): the shell says what that path's status bar says.
    @Test("gaveUp: exhausted -> s_gx, refused / policy refused -> s_gr, certificate -> cf_bar_c")
    func gaveUpCausesMapToTheTable() throws {
        #expect(try Self.shell(.gaveUp(.policy(.attemptsExhausted))).statusLine == "Not connected · couldn’t reconnect after 4 attempts")
        #expect(try Self.shell(.gaveUp(.refusedByBridge(code: -3))).statusLine == "Not connected · the host refused the connection")
        #expect(try Self.shell(.gaveUp(.policyRefused(attemptIndex: 2))).statusLine == "Not connected · the host refused the connection")
        #expect(try Self.shell(.gaveUp(.certificateRejected(unsupportedRoute: true))).statusLine == "Not connected · certificate rejected")
        for cause in Self.everyGiveUpCause() {
            let shell = try Self.shell(.gaveUp(cause))
            #expect(shell.statusBar == shell.statusLine, "\(cause)")
        }
    }

    // MARK: - D-3: the connected shell

    /// D-3, re-frozen. `.live`: the line is `st_conn`, the bar the long form `s_live_bar` with the
    /// window count and the handshake moment; the button stays disabled.
    @Test("live: st_conn on the line, s_live_bar on the bar, the button disabled")
    func liveShowsTheTableWording() throws {
        let shell = try Self.shell(.live)
        #expect(shell.connectEnabled == false)
        #expect(shell.statusLine == "Connected")
        #expect(shell.statusBar == "Connected · 2 windows · since 12:03")
    }

    /// D-3b, re-frozen. `.idle` is the driver's value between `-start` and the RAIL handshake (and
    /// the boundary check's "Connecting…" carries on through it): `st_connecting` on both.
    @Test("idle: Connecting… on the line and the bar, the button disabled")
    func idleRendersConnecting() throws {
        let shell = try Self.shell(.idle)
        #expect(shell.statusLine == "Connecting…")
        #expect(shell.statusBar == "Connecting…")
        #expect(shell.connectEnabled == false)
    }

    /// D-3c. The summary's values each reach their own place: the window count (with the en plural
    /// variant), the handshake moment, and the input capability (`dg_bar`, UI-1 §4.3). A live shell
    /// with no recorded moment keeps the short form rather than printing "since " with nothing.
    @Test("live: window count with plural, since-time, degraded form, and the no-moment short form")
    func liveReportsEachSummaryValue() throws {
        let one = ShellReconnectPresenter.ConnectedSummary(windows: 1, liveSince: Date())
        #expect(try Self.shell(.live, connected: one).statusBar == "Connected · 1 window · since 12:03")
        let degraded = ShellReconnectPresenter.ConnectedSummary(windows: 33, liveSince: Date(), inputDegraded: true)
        #expect(try Self.shell(.live, connected: degraded).statusBar == "Connected · 33 windows · since 12:03 · some features unavailable")
        #expect(try Self.shell(.live, connected: degraded).statusLine == "Connected", "the line does not carry the degradation")
        let noMoment = ShellReconnectPresenter.ConnectedSummary(windows: 3, liveSince: nil)
        #expect(try Self.shell(.live, connected: noMoment).statusBar == "Connected")
        let timed = ShellReconnectPresenter.shell(
            for: .live, connected: Self.summary, displayNote: nil,
            text: ShellText(resolve: { key, fallback, arguments in
                "\(key)|\(arguments.map { "\($0)" }.joined(separator: ","))"
            }, time: { $0 == Date(timeIntervalSince1970: 0) ? "T0" : "other" }))
        #expect(timed.statusBar == "s_live_bar|2,T0", "the moment handed in is the moment printed")
    }

    // MARK: - three languages, against the UI-1 table

    /// The UI-1 table's literals (spec §4.1 / §4.2 / §4.3), each language, each state. The table's
    /// example values -- attempt 2 of 4, 2.0 s, 2 windows, 12:03 -- are what the arguments below
    /// produce, so each row must reproduce the spec's cell exactly: positional arguments put the
    /// numbers where each language's word order wants them.
    @Test("the three languages reproduce the UI-1 table's cells exactly")
    func threeLanguagesMatchTheTable() throws {
        let rows: [(String, ReconnectDriver.State, KeyPath<ShellReconnectPresenter.Shell, String>, [String])] = [
            ("s_wait", .waiting(attempt: 1, delay: .seconds(2)), \.statusLine,
             ["Connection lost · Reconnecting (attempt 2 of 4) in 2.0 s", "连接中断 · 2.0 秒后第 2 次重连（共 4 次）", "接続が切れました · 2.0 秒後に再接続（4 回中 2 回目）"]),
            ("s_re", .reconnecting(attempt: 1), \.statusLine,
             ["Connection lost · Reconnecting (attempt 2 of 4)…", "连接中断 · 正在第 2 次重连（共 4 次）…", "接続が切れました · 再接続中（4 回中 2 回目）…"]),
            ("s_gx", .gaveUp(.policy(.attemptsExhausted)), \.statusBar,
             ["Not connected · couldn’t reconnect after 4 attempts", "未连接 · 4 次重连均未成功", "未接続 · 4 回再接続できませんでした"]),
            ("s_gr", .gaveUp(.refusedByBridge(code: -3)), \.statusBar,
             ["Not connected · the host refused the connection", "未连接 · 主机拒绝了连接", "未接続 · ホストが接続を拒否しました"]),
            ("s_live_bar", .live, \.statusBar,
             ["Connected · 2 windows · since 12:03", "已连接 · 2 个窗口 · 自 12:03 起", "接続済み · ウインドウ 2 個 · 12:03 から"]),
            ("st_conn", .live, \.statusLine, ["Connected", "已连接", "接続済み"]),
            ("st_connecting", .idle, \.statusLine, ["Connecting…", "正在连接…", "接続中…"]),
        ]
        for (key, state, path, cells) in rows {
            for (language, cell) in zip(["en", "zh-Hans", "ja"], cells) {
                #expect(try Self.shell(state, language: language)[keyPath: path] == cell, "\(key) \(language)")
            }
        }
        let degraded = ShellReconnectPresenter.ConnectedSummary(windows: 2, liveSince: Date(), inputDegraded: true)
        for (language, cell) in zip(["en", "zh-Hans", "ja"], [
            "Connected · 2 windows · since 12:03 · some features unavailable",
            "已连接 · 2 个窗口 · 自 12:03 起 · 部分功能不可用",
            "接続済み · ウインドウ 2 個 · 12:03 から · 一部の機能は利用できません",
        ]) {
            #expect(try Self.shell(.live, language: language, connected: degraded).statusBar == cell, "dg_bar \(language)")
        }
    }

    /// The presenter's English fallbacks ARE the catalog's en values, key by key (for a plural key,
    /// its `other` variant), and every key it names has all three languages with the same format
    /// specifiers as en. A fallback is what a missing catalog shows; it must not be a fourth wording.
    @Test("every key the presenter names is in the catalog in three languages; fallbacks equal the en value")
    func thePresenterKeysAreInTheCatalog() throws {
        let strings = try shellCatalogStrings()
        let code = try String(contentsOf: shellCatalogRepoRoot().appendingPathComponent("App/SessionControl/ShellReconnectPresenter.swift"), encoding: .utf8)
        let call = try Regex(#"text\.(?:string|format)\(\s*"([a-z0-9_]+)",\s*"((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        for match in code.matches(of: call) {
            guard let key = match.output[1].substring, let fallback = match.output[2].substring else { continue }
            keys.insert(String(key))
            #expect(shellCatalogValue(strings, String(key), "en") == String(fallback), "\(key)")
        }
        #expect(keys == ["st_connecting", "st_conn", "st_off", "dg_bar", "s_live_bar", "s_wait", "s_re", "s_gx", "s_gr", "cf_bar_c",
                         // UI slice ④ commit 2: the banners and the Remote windows note.
                         "d_retry_b", "d_gx_t", "d_gx_b", "d_gr_t", "d_gr_b", "wn_retry", "wn_gx", "wn_gr", "dg_u_t", "dg_u_b",
                         "dg_u_x",
                         // ADR-0025 a-1b: the late launch failure on the live line (a key the start panel added).
                         "sp_last_fail"])
        let specifier = try Regex(#"%(?:\d\$)?(?:lld|d|@)"#)
        for key in keys {
            let en = shellCatalogValue(strings, key, "en") ?? ""
            let enSpecs = Set(en.matches(of: specifier).map { String(en[$0.range]) })
            for language in ["zh-Hans", "ja"] {
                let value = try #require(shellCatalogValue(strings, key, language), "\(key) \(language)")
                #expect(Set(value.matches(of: specifier).map { String(value[$0.range]) }) == enSpecs, "\(key) \(language)")
            }
        }
        for key in ["s_live_bar", "dg_bar"] {
            #expect(shellCatalogValue(strings, key, "en", count: 1)?.contains("1$lld window ·") == true, "\(key): en plural one")
            #expect(shellCatalogValue(strings, key, "en", count: 2)?.contains("1$lld windows ·") == true, "\(key): en plural other")
        }
    }

    // MARK: - D-4: the display note

    /// D-4. adr/0015 §5.A.3's screen-parameter note is APPENDED to the status line in every state,
    /// never substituted, and never put on the status bar.
    @Test("every state appends the display note to the line rather than replacing its own text")
    func theDisplayNoteIsAppendedInEveryState() throws {
        let note = "Display change: this session's desktop size is unaffected."
        for state in Self.everyState() {
            let plain = try Self.shell(state)
            let noted = try Self.shell(state, note: note)
            #expect(noted.statusLine == plain.statusLine + "\n" + note, "state: \(state)")
            #expect(noted.statusBar == plain.statusBar, "state: \(state)")
            #expect(noted.connectEnabled == plain.connectEnabled,
                    "a display change is not evidence about the connection (§5.A.3): \(state)")
        }
    }

    /// D-4b. The list above really did cover every case.
    @Test("the state list covers all five states, each exactly once")
    func everyStateIsCoveredOnce() throws {
        let states = Self.everyState()
        #expect(states.count == 5)
        for state in states {
            #expect(states.filter { $0 == state }.count == 1, "duplicated: \(state)")
        }
    }

    /// D-4c. No note means no suffix at all.
    @Test("no display note adds no trailing newline")
    func noNoteAddsNothing() throws {
        #expect(!(try Self.shell(.live)).statusLine.hasSuffix("\n"))
    }

    // MARK: - ADR-0025 R-7 (a-1b): the last launch failure

    /// P1. While live, a late launch failure follows the state's line on its own line, as
    /// `sp_last_fail` around the reason the caller resolved -- in each language, the catalog's value.
    @Test("a-1b P1: live + a failure: st_conn, a newline, sp_last_fail around the reason, in three languages")
    func liveCarriesTheLastLaunchFailure() throws {
        for (language, cell) in zip(["en", "zh-Hans", "ja"], [
            "Connected\nThe last launch did not succeed: R",
            "已连接\n上次启动未成功：R",
            "接続済み\n前回の起動は成功しませんでした：R",
        ]) {
            #expect(try Self.shell(.live, failure: "R", language: language).statusLine == cell, "\(language)")
        }
        let reason = "Windows did not reply. If the program doesn’t open, try again."
        #expect(try Self.shell(.live, failure: reason).statusLine == "Connected\nThe last launch did not succeed: " + reason)
    }

    /// P2. Every other state ignores it: the connection is the news there, and the panel keeps the
    /// value for the next live line. The whole shell is identical to the one without a failure.
    @Test("a-1b P2: every non-live state (every give-up cause too) is unchanged by a failure, with or without a note")
    func nonLiveStatesIgnoreTheFailure() throws {
        let states = Self.everyState().filter { $0 != .live } + Self.everyGiveUpCause().map { ReconnectDriver.State.gaveUp($0) }
        #expect(states.count == 8)
        for state in states {
            for language in ["en", "zh-Hans", "ja"] {
                #expect(try Self.shell(state, failure: "R", language: language) == Self.shell(state, language: language), "\(state) \(language)")
                #expect(try Self.shell(state, note: "N", failure: "R", language: language) == Self.shell(state, note: "N", language: language),
                        "\(state) \(language) with a note")
            }
        }
    }

    /// P3. With a display note too, the order is the state, the failure, the note.
    @Test("a-1b P3: live + a failure + a note: state line, failure, note, in that order")
    func theFailureSitsBetweenTheStateAndTheNote() throws {
        let note = "Display change: this session's desktop size is unaffected."
        #expect(try Self.shell(.live, note: note, failure: "R").statusLine
                == "Connected\nThe last launch did not succeed: R\n" + note)
        #expect(try Self.shell(.live, note: note, failure: "R", language: "ja").statusLine
                == "接続済み\n前回の起動は成功しませんでした：R\n" + note)
    }

    /// P5. The status bar and the Connect button never read the failure, in any state: a launch
    /// failure says nothing about the connection.
    @Test("a-1b P5: the status bar and Connect are the same with and without a failure, in every state")
    func theBarAndTheButtonIgnoreTheFailure() throws {
        for state in Self.everyState() {
            let plain = try Self.shell(state)
            let failed = try Self.shell(state, failure: "R")
            #expect(failed.statusBar == plain.statusBar, "\(state)")
            #expect(failed.connectEnabled == plain.connectEnabled, "\(state)")
        }
        let degraded = ShellReconnectPresenter.ConnectedSummary(windows: 2, liveSince: Date(), inputDegraded: true)
        #expect(try Self.shell(.live, failure: "R", connected: degraded).statusBar == "Connected · 2 windows · since 12:03 · some features unavailable")
        #expect(!(try Self.shell(.live)).statusLine.contains("\n"), "no failure, no note: one line")
    }

    // MARK: - the two mappings, named

    /// The zero-based-to-one-based mapping, as its own checked claim. The status line and the
    /// `[reconnect]` line differ by one BY DESIGN.
    @Test("the attempt mapping is the policy index plus one")
    func theAttemptMappingIsOffByOneOnPurpose() throws {
        #expect(ShellReconnectPresenter.humanAttemptNumber(forZeroBasedIndex: 0) == 1)
        #expect(ShellReconnectPresenter.humanAttemptNumber(forZeroBasedIndex: 4) == 5)
        let index = 2
        let line = try Self.shell(.waiting(attempt: index, delay: .seconds(4))).statusLine
        let logLine = try #require(ReconnectDriver.logLine(
            for: .waiting(attempt: index, delay: .seconds(4)), failedAttempts: index))
        #expect(logLine.contains("attempt=\(index)"))
        #expect(line.contains("attempt \(index + 1) of"))
    }

    /// The delay rendering, against the same `Duration` the log line measures in milliseconds. The
    /// unit is the format string's, so the number carries none.
    @Test("the delay text and the log line's delay-ms are two renderings of one Duration")
    func theDelayTextAgreesWithTheLogLine() throws {
        for seconds in [1, 2, 4, 8, 16] {
            let delay = Duration.seconds(seconds)
            #expect(ShellReconnectPresenter.delayText(delay) == "\(seconds).0")
            #expect(ReconnectDriver.milliseconds(delay) == Int64(seconds) * 1_000)
        }
    }
}

// MARK: - ConnectChain.presentation (UI-1 spec §4.1, the Hosts window's columns)

@MainActor
@Suite("UI slice ④ — the Hosts window's marker, subtitle and status bar per state (UI-1 §4.1)")
struct ConnectChainPresentationTests {
    private static let connected = ShellReconnectPresenter.ConnectedSummary(windows: 2, liveSince: Date())

    @Test("no session, the boundary check, and every driver state map to the §4.1 row")
    func everyRow() throws {
        let text = try ShellText.catalog("en")
        func row(_ hasSession: Bool, _ state: ReconnectDriver.State?) -> ConnectChain.Presentation {
            ConnectChain.presentation(hasSession: hasSession, state: state, hostTitle: "workstation.example", connected: Self.connected, text: text)
        }
        #expect(row(false, .live) == .init(marker: .idle, subtitle: nil, statusBar: UIStrings.notConnected), "no session: st_off and hosts3")
        #expect(row(true, nil) == .init(marker: .connecting, subtitle: UIStrings.connectingTo("workstation.example"), statusBar: UIStrings.connecting))
        #expect(row(true, .idle) == .init(marker: .connecting, subtitle: UIStrings.connectingTo("workstation.example"), statusBar: "Connecting…"))
        #expect(row(true, .live) == .init(marker: .live, subtitle: UIStrings.connectedTo("workstation.example"), statusBar: "Connected · 2 windows · since 12:03"))
        #expect(row(true, .waiting(attempt: 1, delay: .seconds(2))) == .init(
            marker: .reconnecting, subtitle: UIStrings.connectionLostTo("workstation.example"),
            statusBar: "Connection lost · Reconnecting (attempt 2 of 4) in 2.0 s"))
        #expect(row(true, .reconnecting(attempt: 1)).statusBar == "Connection lost · Reconnecting (attempt 2 of 4)…")
        #expect(row(true, .gaveUp(.policy(.attemptsExhausted))) == .init(
            marker: .failed, subtitle: UIStrings.notConnected, statusBar: "Not connected · couldn’t reconnect after 4 attempts"))
        #expect(row(true, .gaveUp(.refusedByBridge(code: -3))) == .init(
            marker: .failed, subtitle: UIStrings.notConnected, statusBar: "Not connected · the host refused the connection"))
    }

    @Test("the bar of a session state is the presenter's bar, the one the App's per-tick write uses")
    func oneBarFunction() throws {
        let text = try ShellText.catalog("ja")
        for state: ReconnectDriver.State in [.idle, .live, .waiting(attempt: 0, delay: .seconds(1)), .reconnecting(attempt: 2),
                                             .gaveUp(.policy(.attemptsExhausted)), .gaveUp(.policyRefused(attemptIndex: 1))] {
            let bar = ConnectChain.presentation(hasSession: true, state: state, hostTitle: "h", connected: Self.connected, text: text).statusBar
            let shell = ShellReconnectPresenter.shell(for: state, connected: Self.connected, displayNote: "note", text: text)
            #expect(bar == shell.statusBar, "\(state)")
        }
    }
}
