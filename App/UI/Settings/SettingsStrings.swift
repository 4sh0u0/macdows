import Foundation

/// UI slice ③: the Settings window's user-visible strings, all from `Localizable.xcstrings`
/// (en / zh-Hans / ja). Keys `g_*` / `k_*` / `d_*` / `a_*` and the tab / window labels come from the
/// UI-1 v0.2 string table (`strings-v0.2.tsv`, §4.6); the few the table does not have (the Reset
/// alert, the two results and the export failure) are marked "slice 3" in their comment. Same rules
/// as `UIStrings`: plain strings through `String(localized:defaultValue:)`, format strings from the
/// catalog unformatted and filled with `String(format:)`. `100%` / `200%` and the key symbols in the
/// Keyboard table are literals (UI-1 spec §4.6), never catalog entries.
enum SettingsStrings {
    // MARK: Window and tabs
    static var windowLabel: String { String(localized: "set_label", defaultValue: "Macdows Settings", comment: "Settings window: accessibility label") }
    static var tabsLabel: String { String(localized: "tabs_label", defaultValue: "Settings sections", comment: "Settings window: the tab group (accessibility)") }
    static var tabGeneral: String { String(localized: "tab_general", defaultValue: "General", comment: "Settings tab") }
    static var tabKeyboard: String { String(localized: "tab_keyboard", defaultValue: "Keyboard", comment: "Settings tab") }
    static var tabDisplay: String { String(localized: "tab_display", defaultValue: "Display", comment: "Settings tab") }
    static var tabAdvanced: String { String(localized: "tab_advanced", defaultValue: "Advanced", comment: "Settings tab") }

    // MARK: General
    static var launch: String { String(localized: "g_launch", defaultValue: "At launch", comment: "General: row label") }
    static var launchOpensHosts: String { String(localized: "g_launch_v", defaultValue: "Open the Hosts window", comment: "General: at launch (fixed today)") }
    static var connectionDrops: String { String(localized: "g_drop", defaultValue: "If the connection drops", comment: "General: row label") }
    static var reconnectPolicy: String { String(localized: "g_drop_v", defaultValue: "Reconnect up to 4 times", comment: "General: the fixed reconnect policy (read-only)") }
    static var reconnectPolicyNote: String { String(localized: "g_drop_n", defaultValue: "Waits 1, 2, 4 and 8 seconds before the attempts. Stops at once if the host refuses the connection. Disconnect stops it at any time.", comment: "General: the fixed reconnect policy, explained") }
    static var notifications: String { String(localized: "g_notif", defaultValue: "Notifications", comment: "General: row label") }
    static var notifyLost: String { String(localized: "g_n1", defaultValue: "When the connection is lost", comment: "General: notification (coming later)") }
    static var notifyReconnectFailed: String { String(localized: "g_n2", defaultValue: "When reconnecting fails", comment: "General: notification (coming later)") }
    static var notifyHidden: String { String(localized: "g_n3", defaultValue: "When the remote session hides its windows", comment: "General: notification (coming later)") }

    // MARK: Keyboard
    static var commandKey: String { String(localized: "k_cmd", defaultValue: "Command (⌘) key", comment: "Keyboard: row label") }
    static var commandKeyGroup: String { String(localized: "k_cmd_l", defaultValue: "Command key", comment: "Keyboard: the Command key choices (accessibility)") }
    static var commandMac: String { String(localized: "k_cmd_mac", defaultValue: "Mac shortcuts: ⌘ with common letters sends Ctrl", comment: "Keyboard: Command key choice (today's behaviour)") }
    static var commandWindows: String { String(localized: "k_cmd_win", defaultValue: "Always send the Windows key", comment: "Keyboard: Command key choice (coming later)") }
    static var commandControl: String { String(localized: "k_cmd_ctrl", defaultValue: "Always send Ctrl", comment: "Keyboard: Command key choice (coming later)") }
    static var optionKey: String { String(localized: "k_opt", defaultValue: "Option (⌥) key", comment: "Keyboard: row label") }
    static var optionValue: String { String(localized: "k_opt_v", defaultValue: "Sends Alt", comment: "Keyboard: what Option sends (read-only)") }
    static var fnKey: String { String(localized: "k_fn", defaultValue: "fn and Help keys", comment: "Keyboard: row label") }
    static var fnValue: String { String(localized: "k_fn_v", defaultValue: "Send the Windows Help key", comment: "Keyboard: what fn / Help send (read-only)") }
    static var tableLabel: String { String(localized: "k_tbl_l", defaultValue: "What ⌘ sends", comment: "Keyboard: the read-only table of what Command sends") }
    static var tableMac: String { String(localized: "k_th_mac", defaultValue: "On this Mac", comment: "Keyboard table: column header") }
    static var tableWindows: String { String(localized: "k_th_win", defaultValue: "Sent to Windows", comment: "Keyboard table: column header") }
    static var rowLetters: String { String(localized: "k_r_letters", defaultValue: "Ctrl + the same letter", comment: "Keyboard table: Command + listed letters") }
    static var rowRedo: String { String(localized: "k_r_redo", defaultValue: "Ctrl + Y (Redo)", comment: "Keyboard table: Shift-Command-Z") }
    static var rowClose: String { String(localized: "k_r_close", defaultValue: "Closes the window, same as its close button", comment: "Keyboard table: Command-W") }
    static var rowKept: String { String(localized: "k_r_kept", defaultValue: "Not sent; Macdows keeps them", comment: "Keyboard table: the four keys Macdows keeps") }
    static var rowMacOS: String { String(localized: "k_r_macos", defaultValue: "Not sent; macOS handles them", comment: "Keyboard table: keys macOS handles") }
    static var rowOtherKeys: String { String(localized: "k_r_other_l", defaultValue: "⌘ alone, or ⌘ + any other key", comment: "Keyboard table: every other Command combination") }
    static var rowOther: String { String(localized: "k_r_other", defaultValue: "Windows key (alone opens Start)", comment: "Keyboard table: what every other combination sends") }
    static var menuShortcutsNote: String { String(localized: "k_link", defaultValue: "Which Macdows menu shortcuts reach Windows…", comment: "Keyboard: note on menu shortcuts (static text in this version)") }

    // MARK: Display
    static var scale: String { String(localized: "d_scale", defaultValue: "Scale remote windows", comment: "Display: row label") }
    static var scaleMatch: String { String(localized: "d_match", defaultValue: "Match this Mac", comment: "Display: scale choice (today's behaviour)") }
    static var scaleNote: String { String(localized: "d_scale_n", defaultValue: "Applies at the next connection. The remote desktop size follows your displays when you connect.", comment: "Display: scale note") }
    static var displays: String { String(localized: "d_multi", defaultValue: "Multiple displays", comment: "Display: row label") }
    static var followDisplays: String { String(localized: "d_follow", defaultValue: "Follow display changes during a session", comment: "Display: option (coming later)") }
    static var followNote: String { String(localized: "d_follow_n", defaultValue: "Today a display change takes effect after you disconnect and connect again.", comment: "Display: what happens today") }
    static var afterReconnect: String { String(localized: "d_after", defaultValue: "After reconnecting", comment: "Display: row label") }
    static var restoreWindows: String { String(localized: "d_restore", defaultValue: "Put remote windows back where they were", comment: "Display: option (coming later)") }
    static var restoreNote: String { String(localized: "d_restore_n", defaultValue: "Today windows reappear where the host places them.", comment: "Display: what happens today") }

    // MARK: Advanced
    static var logDetail: String { String(localized: "a_log", defaultValue: "Log detail", comment: "Advanced: row label") }
    static var logStandard: String { String(localized: "a_log_std", defaultValue: "Standard", comment: "Advanced: log detail choice") }
    static var logDetailed: String { String(localized: "a_log_det", defaultValue: "Detailed (Coming later)", comment: "Advanced: log detail choice (disabled)") }
    static var logNote: String { String(localized: "a_log_n", defaultValue: "Logs never contain passwords.", comment: "Advanced: log note") }
    static var diagnostics: String { String(localized: "a_diag", defaultValue: "Diagnostics", comment: "Advanced: row label") }
    static var export: String { String(localized: "a_export", defaultValue: "Export Diagnostics…", comment: "Advanced: export button") }
    static var exportNote: String { String(localized: "a_export_n", defaultValue: "Saves recent logs to a file you choose. It names your hosts. Account names and key-witness lines are left out unless you include them below. Review the file before you share it.", comment: "Advanced: what the export contains (safety note)") }
    static var includeAccounts: String { String(localized: "a_include", defaultValue: "Include account names and key-witness lines", comment: "Advanced: export option, this export only") }
    static var pins: String { String(localized: "a_pins", defaultValue: "Certificate pins", comment: "Advanced: row label") }
    static var reset: String { String(localized: "a_reset", defaultValue: "Reset All Pins…", comment: "Advanced: reset button") }
    static var resetNote: String { String(localized: "a_reset_n", defaultValue: "Forgets every pinned fingerprint. You confirm each host again on its next connection.", comment: "Advanced: what reset does") }
    static var overrides: String { String(localized: "a_ov", defaultValue: "Launch overrides", comment: "Advanced: row label") }
    static var overridesNone: String { String(localized: "a_ov_none", defaultValue: "None active.", comment: "Advanced: no launch override active") }
    static var overridesNote: String { String(localized: "a_ov_n", defaultValue: "Test overrides set in the launch environment are not settings. This row only says whether any is active; it never shows names or values.", comment: "Advanced: launch overrides note (safety)") }
    static var resetTitle: String { String(localized: "a_reset_t", defaultValue: "Reset all certificate pins?", comment: "Reset All Pins alert: title (slice 3)") }
    static var resetBody: String { String(localized: "a_reset_b", defaultValue: "Macdows forgets every pinned fingerprint. On its next connection, a host with an expected certificate fingerprint is checked against it again; any other host asks you to confirm its certificate again.", comment: "Reset All Pins alert: body (slice 3)") }
    static var resetConfirm: String { String(localized: "a_reset_go", defaultValue: "Reset All Pins", comment: "Reset All Pins alert: destructive button (slice 3)") }
    static var resetFailed: String { String(localized: "a_reset_err", defaultValue: "Macdows could not reset every pin. Try again.", comment: "Reset All Pins: failure (slice 3)") }
    static var exportFailed: String { String(localized: "a_export_err", defaultValue: "Macdows could not save the diagnostics file.", comment: "Export Diagnostics: failure (slice 3)") }

    // MARK: Formats

    /// `a_ov_active`: "N active. Names and values are not shown." -- only the count is ever filled in.
    static func overridesActive(_ count: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "a_ov_active", value: "%lld active. Names and values are not shown.", table: nil), Int64(count))
    }

    /// `a_reset_part` (slice 3): Reset All Pins stopped part-way.
    static func resetPartial(_ count: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "a_reset_part", value: "Pins cleared: %lld. Macdows could not reset the rest. Try again.", table: nil), Int64(count))
    }

    /// `a_reset_done` (slice 3): how many pins Reset All Pins cleared.
    static func resetDone(_ count: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "a_reset_done", value: "Pins cleared: %lld", table: nil), Int64(count))
    }

    /// `a_export_done` (slice 3): the saved file's name (never its folder) and the withheld-line count.
    static func exportDone(fileName: String, linesLeftOut: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "a_export_done", value: "Saved “%1$@”. Lines left out: %2$lld.", table: nil), fileName, Int64(linesLeftOut))
    }
}
