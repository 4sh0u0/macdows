import AppKit
import MacdowsCore

/// UI slice ③ (UI-1 spec §1 / §4.6 / §6.4 / §8 ③ / §10): what the Settings window shows and which
/// of its controls can be changed. The rule of this slice is "only capabilities that already
/// exist; everything else is shown, disabled and labelled Coming later" -- and today NOTHING on
/// these four pages is configurable: every behaviour they describe is fixed in code. So every
/// choice below is either the one behaviour the App has (selected, and the only option that is
/// not disabled) or a later option (disabled, Coming later). The window keeps no settings of its
/// own: nothing here is persisted, and nothing reads or writes a launch knob (§10 ②; the overrides
/// row only counts which of the seven known knob names are present).
///
/// The two things the window can DO are actions on existing capabilities, not settings: Export
/// Diagnostics… (ADR-0024 D-8, `DiagnosticExport`) and Reset All Pins… (ADR-0024 D-6,
/// `HostOperations.resetAllPins`).
enum SettingsModel {
    /// One option of a choice group, or one checkbox.
    struct Choice: Equatable, Identifiable {
        /// The string-table key of its title (`100%` / `200%` are literals and use their text).
        let id: String
        let isSelected: Bool
        let isEnabled: Bool
        /// Shown with the secondary "Coming later" label (UI-1 spec §7.1: never by dimming alone).
        var showsComingLater: Bool { !isEnabled }

        static func current(_ id: String) -> Choice { Choice(id: id, isSelected: true, isEnabled: true) }
        static func later(_ id: String, selected: Bool = false) -> Choice { Choice(id: id, isSelected: selected, isEnabled: false) }
    }

    // MARK: General (artboard Settings-General; §10 ⑥ ⑦ ⑧)

    /// "At launch: Open the Hosts window" -- the App always opens the Hosts window at launch and
    /// has no way not to, so the box is shown ticked and disabled.
    static let launchOpensHosts = Choice.later("g_launch_v", selected: true)
    /// The three notification switches (§1: system notifications are not in v1).
    static let notifications: [Choice] = [.later("g_n1"), .later("g_n2"), .later("g_n3")]

    /// §10 ⑥: the fixed reconnect policy, read-only. The text `g_drop_v` says "up to 4 times" and
    /// `g_drop_n` names the waits 1, 2, 4 and 8 seconds; these are what `ReconnectPolicy` does
    /// (`SettingsWindowTests` holds the strings to the policy's constants).
    static var reconnectsAfterTheFirstAttempt: Int { ReconnectPolicy.maxAttempts - 1 }

    // MARK: Keyboard (§4.6 k_*, §6.4)

    /// `CommandKeyMapper` has one behaviour and no mode: the Mac-shortcuts mapping.
    static let commandKey: [Choice] = [.current("k_cmd_mac"), .later("k_cmd_win"), .later("k_cmd_ctrl")]

    /// The letters ⌘ maps to Ctrl + the same letter (`CommandKeyMapper`'s table; held to it by
    /// `SettingsWindowTests`).
    static let mappedLetters = ["A", "C", "F", "N", "O", "P", "S", "V", "X", "Z"]

    /// One row of the read-only "What ⌘ sends" table.
    struct KeyRow: Equatable, Identifiable {
        /// What is pressed on the Mac: key symbols (a literal) or, for the last row, a catalog string.
        let mac: String
        /// What Windows gets (a catalog string).
        let windows: String
        var id: String { mac }
    }

    /// The table's six rows (§6.4): letters -> Ctrl, ⇧⌘Z -> Ctrl+Y, ⌘W -> close, the four keys
    /// Macdows keeps (from `LocalKeyEquivalent.reserved`, adr/0022 D-3), the two macOS keeps, and
    /// everything else -> the Windows key.
    static func keyRows() -> [KeyRow] {
        [
            KeyRow(mac: "⌘ + " + mappedLetters.joined(separator: " "), windows: SettingsStrings.rowLetters),
            KeyRow(mac: "⇧⌘Z", windows: SettingsStrings.rowRedo),
            KeyRow(mac: "⌘W", windows: SettingsStrings.rowClose),
            KeyRow(mac: LocalKeyEquivalent.reserved.map(symbols).joined(separator: ", "), windows: SettingsStrings.rowKept),
            KeyRow(mac: "⌘Space, ⌘Tab", windows: SettingsStrings.rowMacOS),
            KeyRow(mac: SettingsStrings.rowOtherKeys, windows: SettingsStrings.rowOther),
        ]
    }

    /// `⌥⌘H` style: modifiers in the macOS order ⌃ ⌥ ⇧ ⌘, then the key in upper case.
    static func symbols(_ key: LocalKeyEquivalent) -> String {
        var text = ""
        if key.modifiers.contains(.control) { text += "⌃" }
        if key.modifiers.contains(.option) { text += "⌥" }
        if key.modifiers.contains(.shift) { text += "⇧" }
        if key.modifiers.contains(.command) { text += "⌘" }
        return text + key.character.uppercased()
    }

    // MARK: Display (§4.6 d_*)

    /// "Match this Mac" is today's behaviour; 100% / 200% are later (their titles are literals).
    static let scale: [Choice] = [.current("d_match"), .later("100%"), .later("200%")]
    static let followDisplays = Choice.later("d_follow")
    static let restoreWindows = Choice.later("d_restore")

    // MARK: Advanced (§4.6 a_*, §5.5, ADR-0024 D-8)

    /// Standard only; Detailed stays disabled until its whitelist ceiling is ruled (§10 ⑩). Its
    /// title already carries "(Coming later)".
    static let logDetail: [Choice] = [.current("a_log_std"), .later("a_log_det")]

    /// §10 ②: how many of the seven launch knobs `ShellAutolaunch` knows are PRESENT in
    /// `environment`. Only presence is looked at: a value is never read, and neither is any name
    /// outside these seven.
    static func activeOverrideCount(in environment: [String: String]) -> Int {
        knownOverrideNames.filter { environment[$0] != nil }.count
    }

    /// The seven names (`ShellAutolaunch`'s constants; this file never spells one).
    static let knownOverrideNames: [String] = [
        ShellAutolaunch.autoconnectKey, ShellAutolaunch.quitAfterKey, ShellAutolaunch.disconnectAfterKey,
        ShellAutolaunch.reconnectAfterKey, ShellAutolaunch.extraExecAfterKey, ShellAutolaunch.extraExecProgramKey,
        ShellAutolaunch.keyWitnessKey,
    ]

    /// The overrides row's text: `a_ov_none` or `a_ov_active` with the count, nothing else.
    static func overridesText(count: Int) -> String {
        count == 0 ? SettingsStrings.overridesNone : SettingsStrings.overridesActive(count)
    }

    // MARK: Titles

    /// The title of a choice: its catalog string, or the literal for `100%` / `200%`.
    static func title(of choice: Choice) -> String {
        switch choice.id {
        case "g_launch_v": return SettingsStrings.launchOpensHosts
        case "g_n1": return SettingsStrings.notifyLost
        case "g_n2": return SettingsStrings.notifyReconnectFailed
        case "g_n3": return SettingsStrings.notifyHidden
        case "k_cmd_mac": return SettingsStrings.commandMac
        case "k_cmd_win": return SettingsStrings.commandWindows
        case "k_cmd_ctrl": return SettingsStrings.commandControl
        case "d_match": return SettingsStrings.scaleMatch
        case "d_follow": return SettingsStrings.followDisplays
        case "d_restore": return SettingsStrings.restoreWindows
        case "a_log_std": return SettingsStrings.logStandard
        case "a_log_det": return SettingsStrings.logDetailed
        default: return choice.id
        }
    }

    /// Every disabled control of each page, for the window's own pins.
    static func disabledChoices() -> [String: [Choice]] {
        [
            "general": ([launchOpensHosts] + notifications).filter { !$0.isEnabled },
            "keyboard": commandKey.filter { !$0.isEnabled },
            "display": (scale + [followDisplays, restoreWindows]).filter { !$0.isEnabled },
            "advanced": logDetail.filter { !$0.isEnabled },
        ]
    }
}
