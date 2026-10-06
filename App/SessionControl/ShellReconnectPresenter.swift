import Foundation
import MacdowsCore

// adr/0019 §2 lane D, re-worded by UI slice ④ (UI-1 spec §4.1 / §4.2). The shell's AppKit
// properties -- the Connect button's `isEnabled`, the status line and the status bar's text -- as
// ONE pure function of `ReconnectDriver.State`.
//
// ## Why a type of its own rather than `if`s inside `AppDelegate`
//
// `App/project.yml` gives `MacdowsAppTests` the sources `MacdowsAppTests` + `RemoteWindowRendering`
// + `SessionControl` (+ `UI`), and deliberately NOT `Macdows`: nothing declared in
// `AppDelegate.swift` exists in the test bundle at all, so a branch written there can only ever be
// checked by matching source text. Everything that decides WHAT the shell says therefore lives
// here, where it is ordinary offline Swift with no AppKit object in sight, and `AppDelegate` keeps
// only the assignments -- which is all a source pin has to hold.
//
// ## What this type is not
//
// It makes the DECISION testable, not the BINDING. That the button's `isEnabled` really receives
// `connectEnabled`, and that the label really receives `statusLine`, stays a source pin
// (`AppDelegateReconnectWiringPinTests`).
//
// It also holds no state and reads nothing but the String Catalog, through `ShellText` (which a
// test replaces with one language of the catalog file). The session's live-window count, the
// moment it went live and its input capability arrive as a `ConnectedSummary` the caller gathered,
// so this file cannot disagree with the caller about which session it is describing.
//
// ## UI slice ④: replaced, not aligned (UI-1 spec §4.1)
//
// Until slice ④ this type produced English developer text ("Connected — N event(s) so far
// (generation G)", "Reconnecting — attempt k of 5, retrying in d", "Disconnected — gave up
// (<cause token>). Press Connect to try again."). Slice ④ replaced every one of those with the
// three-language catalog strings of the UI-1 table. Two things changed in meaning, on purpose:
// the attempt denominator is the number of RECONNECTS (`maxAttempts - 1` = 4: the first of the
// policy's five attempts is the connection that dropped), and the give-up cause token stays in the
// `[reconnect]` line and the diagnostics export only -- it is no longer on screen.

/// The Connect button, the status line and the status bar, decided together, from the reconnect
/// state.
@MainActor
enum ShellReconnectPresenter {

    /// What a working connection's shell reports, gathered by the caller.
    ///
    /// One struct rather than separate parameters because the values are only ever meaningful
    /// together: they are one reading of one session.
    struct ConnectedSummary: Equatable {
        /// `RemoteWindowRegistry.windowSnapshots().count`.
        let windows: Int
        /// When the current connection leg reached `.live` (the RAIL handshake completed): the
        /// App's one record of it, which the status item reads too. `nil` before that.
        let liveSince: Date?
        /// UI-1 spec §4.3: the connection did not accept Unicode input, so the status bar says
        /// "some features unavailable" (`dg_bar`).
        let inputDegraded: Bool

        init(windows: Int, liveSince: Date?, inputDegraded: Bool = false) {
            self.windows = windows
            self.liveSince = liveSince
            self.inputDegraded = inputDegraded
        }
    }

    /// The whole shell as one value, so a caller cannot update one part and forget another.
    struct Shell: Equatable {
        /// Whether the Connect button accepts a press.
        let connectEnabled: Bool
        /// The complete status line text, display-change note included.
        let statusLine: String
        /// The status bar's text (UI-1 spec §4.1, long form).
        let statusBar: String
    }

    /// The shell for `state`.
    ///
    /// - Parameter connected: read only by `.live`; the other states say nothing about windows.
    /// - Parameter displayNote: the most recent screen-parameter note (adr/0015 §5.A.3), or `nil`.
    ///   APPENDED to every state's status line rather than replacing it -- see `noteSuffix`.
    static func shell(
        for state: ReconnectDriver.State,
        connected: ConnectedSummary,
        displayNote: String?,
        text: ShellText = .main
    ) -> Shell {
        Shell(
            connectEnabled: connectEnabled(for: state),
            statusLine: line(for: state, text: text) + noteSuffix(displayNote),
            statusBar: statusBar(for: state, connected: connected, text: text)
        )
    }

    /// Whether the Connect button accepts a press in `state`.
    ///
    /// TRUE FOR `.gaveUp` ONLY, and the reason is structural rather than cautious. An automatic
    /// reconnect reuses the SAME `CRSession` (`-restartForReconnectPreparing:` restarts the
    /// instance it is called on), and `AppDelegate.connectTapped`'s first guard is
    /// `session == nil`. So a button enabled while a retry is pending or in flight would refuse
    /// every press -- a button that lies is worse than one that is visibly unavailable. Giving up
    /// is the one reconnect state in which the App drops the session, which is what lets the next
    /// press start a real connection. The user's End-session press drops it too (adr/0020 D-5),
    /// but that is not a reconnect state and never reaches this function: that action enables
    /// Connect with a literal of its own.
    ///
    /// `.idle` is FALSE: it is also the driver's INITIAL value, which the App reads on every drain
    /// tick between `-start` and the RAIL handshake. Enabling there would re-open the button on a
    /// connection that is merely still coming up.
    ///
    /// ## `.idle` IS A PRECONDITION, NOT JUST A CASE (gate r1 I-2)
    ///
    /// This arm serves the pre-handshake tick. A STAND-DOWN `.idle` arriving at the App through
    /// `onStateChange` would be a different animal: it would re-DISABLE the button and overwrite
    /// whatever the App last said with "Connecting…" -- and because every path that produces a
    /// stand-down has already invalidated `drainTimer`, nothing would ever refresh the label again.
    ///
    /// So the claim this arm rests on is a REQUIREMENT on the App: **a stand-down `.idle` must not
    /// reach `AppDelegate`**. It holds because the App disarms the driver in exactly ONE place,
    /// `AppDelegate.tearDownSession()`, and that place drops the driver (`reconnectDriver = nil`)
    /// right after detaching it; the pending-retry block holds the driver weakly, so no callback
    /// can follow. All four of the App's session ends go through it.
    static func connectEnabled(for state: ReconnectDriver.State) -> Bool {
        if case .gaveUp = state { return true }
        return false
    }

    /// The status line for `state`, without the display-change note (UI-1 spec §4.1 "状态行").
    private static func line(for state: ReconnectDriver.State, text: ShellText) -> String {
        switch state {
        case .idle:
            // Before the first handshake: the connection is still coming up.
            return text.string("st_connecting", "Connecting…")
        case .live:
            return text.string("st_conn", "Connected")
        case .waiting, .reconnecting, .gaveUp:
            // The table gives these states one text for the line and the bar.
            return lostOrEndedText(for: state, text: text)
        }
    }

    /// The status bar for `state` (UI-1 spec §4.1 / §4.2 long forms; §4.3 `dg_bar`).
    static func statusBar(
        for state: ReconnectDriver.State,
        connected: ConnectedSummary,
        text: ShellText = .main
    ) -> String {
        switch state {
        case .idle:
            return text.string("st_connecting", "Connecting…")
        case .live:
            guard let since = connected.liveSince else {
                // No handshake moment recorded (the drain's no-driver reading): the short form.
                return text.string("st_conn", "Connected")
            }
            let windows = Int64(connected.windows)
            let time = text.time(since)
            if connected.inputDegraded {
                return text.format("dg_bar", "Connected · %1$lld windows · since %2$@ · some features unavailable", [windows, time])
            }
            return text.format("s_live_bar", "Connected · %1$lld windows · since %2$@", [windows, time])
        case .waiting, .reconnecting, .gaveUp:
            return lostOrEndedText(for: state, text: text)
        }
    }

    /// The text the line and the bar share once a connection has dropped.
    private static func lostOrEndedText(for state: ReconnectDriver.State, text: ShellText) -> String {
        switch state {
        case .waiting(let attempt, let delay):
            return text.format(
                "s_wait", "Connection lost · Reconnecting (attempt %1$lld of %2$lld) in %3$@ s",
                [Int64(humanAttemptNumber(forZeroBasedIndex: attempt)), Int64(reconnectCount), delayText(delay)]
            )
        case .reconnecting(let attempt):
            return text.format(
                "s_re", "Connection lost · Reconnecting (attempt %1$lld of %2$lld)…",
                [Int64(humanAttemptNumber(forZeroBasedIndex: attempt)), Int64(reconnectCount)]
            )
        case .gaveUp(.policy(.attemptsExhausted)):
            return text.format("s_gx", "Not connected · couldn’t reconnect after %lld attempts", [Int64(reconnectCount)])
        case .gaveUp(.refusedByBridge), .gaveUp(.policyRefused):
            return text.string("s_gr", "Not connected · the host refused the connection")
        case .gaveUp(.certificateRejected):
            // ADR-0024 D-5: the certificate path owns this end (the `cf_c_*` banner and sheets);
            // the shell only says what the certificate banner's status bar says.
            return text.string("cf_bar_c", "Not connected · certificate rejected")
        case .idle, .live:
            return text.string("st_off", "Not connected")
        }
    }

    /// The display-change note as a suffix, or the empty string.
    ///
    /// Computed OUTSIDE the state switch on purpose: adr/0015 §5.A.3 lets that event reach exactly
    /// one place in this app -- a label -- and the drain tick's overwrite has to carry it for the
    /// note to be legible for more than a second. A reconnect does not make the note less true,
    /// and a switch with one arm that forgot to append it is precisely the defect this shape makes
    /// unwritable.
    private static func noteSuffix(_ displayNote: String?) -> String {
        displayNote.map { "\n\($0)" } ?? ""
    }

    /// UI-1 spec §4.1: "attempt k of 4". The denominator counts RECONNECTS -- the policy's
    /// `maxAttempts` counts the dropped connection as its first attempt -- so it is
    /// `maxAttempts - 1`, derived rather than written down (the Settings page's "up to 4
    /// reconnects" derives it the same way).
    static var reconnectCount: Int { ReconnectPolicy.maxAttempts - 1 }

    /// The human-facing attempt number for a policy attempt index.
    ///
    /// `ReconnectDriver.State`'s `attempt` is the ZERO-BASED failed-attempt index -- the same `n`
    /// that `ReconnectPolicy.delay(forFailedAttempt:)` takes, so that the state, the log line and
    /// the policy call can never disagree about which attempt is which. A human counts from one, so
    /// every index that reaches a label goes through this function.
    ///
    /// THE CONSEQUENCE, STATED SO IT IS NOT READ AS A BUG: the `[reconnect]` line prints the index
    /// verbatim (`attempt=0` for the first retry) and the status line prints `attempt 1 of 4` for
    /// the same moment. They differ by one, always, and in that direction. Changing either side to
    /// "match" the other would break whichever of the two it was matched to.
    static func humanAttemptNumber(forZeroBasedIndex index: Int) -> Int {
        index + 1
    }

    /// A back-off delay as whole tenths of a second, without the unit, e.g. `1.0` -- the unit is
    /// part of each language's format string ("in 2.0 s", "2.0 秒后", "2.0 秒後").
    ///
    /// Derived from `ReconnectDriver.milliseconds(_:)` rather than from `Duration`'s components
    /// again, so the number on the label and the `delay-ms=` field of the `[reconnect]` line are
    /// two renderings of one reading. `String(format:)` without a locale is deliberate: the UI-1
    /// table writes "2.0" in all three languages, and a test comparing it to a literal must not
    /// depend on the region it runs in.
    static func delayText(_ delay: Duration) -> String {
        String(format: "%.1f", Double(ReconnectDriver.milliseconds(delay)) / 1000)
    }
}

/// Where the shell's words come from: the App's String Catalog, or -- in a test -- one language of
/// the catalog file. Plain values with closures, so the presenter stays a pure function of its
/// arguments.
struct ShellText {
    /// The catalog value for `key` (`fallback` when the catalog has none), formatted with
    /// `arguments` (positional `%1$lld` / `%2$@` specifiers; plural variants resolved).
    let resolve: (_ key: String, _ fallback: String, _ arguments: [any CVarArg]) -> String
    /// A clock time for "since 12:03".
    let time: (Date) -> String

    func string(_ key: String, _ fallback: String) -> String {
        resolve(key, fallback, [])
    }

    func format(_ key: String, _ fallback: String, _ arguments: [any CVarArg]) -> String {
        resolve(key, fallback, arguments)
    }

    /// The App's catalog in the user's language. Formatted WITH a locale because the en
    /// `s_live_bar` / `dg_bar` carry plural variants, which only a localized format resolves (the
    /// rule `UIStrings.hostCount` follows); the locale is `formattingLocale`'s, not the region's.
    static var main: ShellText {
        ShellText(
            resolve: { key, fallback, arguments in
                let format = Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
                return arguments.isEmpty ? format : String(format: format, locale: formattingLocale(preferredLocalizations: Bundle.main.preferredLocalizations), arguments: arguments)
            },
            time: { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }
        )
    }

    /// The locale a catalog format is filled in with: the language of the localization the bundle
    /// actually resolved (`preferredLocalizations.first`), so the plural variant is chosen by that
    /// language's rules. `Locale.current` follows the region instead: an en App in a zh_CN or
    /// ja_JP region would pick "1 windows" (gate r1 m-1).
    static func formattingLocale(preferredLocalizations: [String]) -> Locale {
        Locale(identifier: preferredLocalizations.first ?? "en")
    }
}

// MARK: - UI slice ④: the session banners and the remote-windows note (UI-1 spec §4.2 / §4.3)

extension ShellReconnectPresenter {
    /// One session banner as data: what the App builds a `BannerView.Model` from, minus the
    /// handlers -- the App wires each `Action` to a path that already exists.
    struct SessionBanner: Equatable {
        enum Tone: Equatable {
            /// Untinted (UI-1 spec §3: information is not tinted), the input-method banner.
            case information
            case warning
            case error
        }

        /// The banner's buttons. Disconnect only while the session still exists (waiting /
        /// reconnecting); after a give-up the session is gone, so Dismiss / Reconnect (UI-1 §4.2).
        /// Learn More opens Settings > Keyboard (the input-method banner, UI-1 §4.3).
        enum Action: Equatable {
            case disconnect
            case dismiss
            case reconnect
            case learnMore
        }

        let id: String
        let title: String
        let body: String
        let tone: Tone
        let actions: [Action]
        /// The Dismiss button's accessibility name when it needs its own (`dg_u_x`); `nil` keeps
        /// the button's title.
        var dismissAccessibilityLabel: String? = nil
    }

    /// The connection banner's id: ONE banner, replaced as the state moves on (waiting ->
    /// reconnecting -> gave up), never stacked, and removed when the connection is live again.
    static let connectionBannerID = "session-connection"
    /// The input-method banner's id (UI-1 spec §4.3).
    static let inputBannerID = "session-input"

    /// The connection banner for `state`, or `nil` when there is none (`.idle`, `.live`, and a
    /// certificate give-up, whose banner and sheets belong to the certificate path, ADR-0024 D-5).
    ///
    /// Titles and bodies follow the Session-Disconnected artboard: while retrying, the title is
    /// the state's own status text (`s_wait` / `s_re`) over `d_retry_b`; after giving up, `d_gx_*`
    /// or `d_gr_*`. Warning tint while retrying, error tint after giving up.
    static func connectionBanner(
        for state: ReconnectDriver.State,
        hostTitle: String,
        text: ShellText = .main
    ) -> SessionBanner? {
        switch state {
        case .idle, .live, .gaveUp(.certificateRejected):
            return nil
        case .waiting, .reconnecting:
            return SessionBanner(
                id: connectionBannerID, title: lostOrEndedText(for: state, text: text),
                body: text.string("d_retry_b", "Remote windows come back when the connection does. Your Windows session should still be running on the host."),
                tone: .warning, actions: [.disconnect]
            )
        case .gaveUp(.policy(.attemptsExhausted)):
            return SessionBanner(
                id: connectionBannerID,
                title: text.format("d_gx_t", "Couldn’t reconnect after %lld attempts", [Int64(reconnectCount)]),
                body: text.format(
                    "d_gx_b", "%1$@ didn’t answer %2$lld reconnect attempts. The Windows session should still be running on the host; Reconnect starts a new connection to it.",
                    [hostTitle, Int64(reconnectCount)]
                ),
                tone: .error, actions: [.dismiss, .reconnect]
            )
        case .gaveUp(.refusedByBridge), .gaveUp(.policyRefused):
            return SessionBanner(
                id: connectionBannerID,
                title: text.string("d_gr_t", "The host refused the connection"),
                body: text.format(
                    "d_gr_b", "%@ refused the reconnect, so Macdows stopped without trying again. The Windows session should still be running on the host; Reconnect tries once more.",
                    [hostTitle]
                ),
                tone: .error, actions: [.dismiss, .reconnect]
            )
        }
    }

    /// The Remote windows card's note while there are no remote windows because the connection
    /// dropped (UI-1 spec §4.2 `wn_*`, Main-Connected artboard: the detail area, not the banner).
    /// `nil` hides the card: no state, a connection coming up, a live one, a certificate give-up.
    static func remoteWindowsNote(for state: ReconnectDriver.State?, text: ShellText = .main) -> String? {
        switch state {
        case .waiting?, .reconnecting?:
            return text.string("wn_retry", "Remote windows close while the connection is down and reappear when the host sends them again after reconnecting.")
        case .gaveUp(.policy(.attemptsExhausted))?:
            return text.string("wn_gx", "No remote windows. The Windows session should still be running on the host; Connect starts a new connection to it.")
        case .gaveUp(.refusedByBridge)?, .gaveUp(.policyRefused)?:
            return text.string("wn_gr", "No remote windows. The host refused the connection, so Macdows did not retry. Connect tries again once.")
        case nil, .idle?, .live?, .gaveUp(.certificateRejected)?:
            return nil
        }
    }

    /// adr/0011 §2's "visible to the user" half (UI-1 spec §4.3): the connection did not accept
    /// Unicode input, so input-method text is not sent. Information tone (the artboard's `info-b`),
    /// Learn More and Dismiss, the latter named `dg_u_x` for accessibility.
    static func inputBanner(hostTitle: String, text: ShellText = .main) -> SessionBanner {
        SessionBanner(
            id: inputBannerID,
            title: text.string("dg_u_t", "Input method text can’t be sent to this host"),
            body: text.format(
                "dg_u_b", "%@ didn’t accept Unicode input, so text from input methods (for example Chinese or Japanese) and the Character Viewer is not sent. Typing with your keyboard layout still works.",
                [hostTitle]
            ),
            tone: .information, actions: [.learnMore, .dismiss],
            dismissAccessibilityLabel: text.string("dg_u_x", "Dismiss input method notice")
        )
    }
}
