import Foundation

/// UI slice ①'s user-visible strings, all from `Localizable.xcstrings` (en / zh-Hans / ja; keys
/// from the UI-1 v0.2 string table, `strings-v0.2.tsv`, plus the few this slice needed that the
/// table does not have, marked "slice ①" in their catalog comment). Plain strings use
/// `String(localized:defaultValue:)`; format strings come from the catalog unformatted and are
/// filled with `String(format:)` (the rule slices ⓪ / ② use). Host names, addresses and
/// fingerprints are data and are never translated.
enum UIStrings {
    // MARK: Chrome
    static var hosts: String { String(localized: "sb_hosts", defaultValue: "Hosts", comment: "Sidebar: section title") }
    static var newHost: String { String(localized: "sb_new", defaultValue: "New Host", comment: "Sidebar / toolbar: add a host; Host Editor title in new mode") }
    static var removeHost: String { String(localized: "sb_remove", defaultValue: "Remove Host", comment: "Sidebar: remove the selected host (accessibility)") }
    static var settings: String { String(localized: "tb_settings", defaultValue: "Settings", comment: "Toolbar: Settings button") }
    /// `hosts3` has plural variations in English ("1 host", "2 hosts"; gate r1 m-10), which only
    /// a localized format resolves -- with the resolved localization's locale, not the region's
    /// (`ShellText.formattingLocale`, UI slice ④ gate r1 m-1).
    static func hostCount(_ count: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "hosts3", value: "%d hosts", table: nil),
               locale: ShellText.formattingLocale(preferredLocalizations: Bundle.main.preferredLocalizations), Int32(clamping: count))
    }
    static var hostDetails: String { String(localized: "details", defaultValue: "Host details", comment: "Main window: the detail pane (accessibility)") }

    // MARK: State
    static var connected: String { String(localized: "st_conn", defaultValue: "Connected", comment: "State: connected") }
    static var notConnected: String { String(localized: "st_off", defaultValue: "Not connected", comment: "Status menu: no session") }
    static var connectionFailed: String { String(localized: "st_err", defaultValue: "Connection failed", comment: "State: the last connect failed") }
    static var reconnecting: String { String(localized: "st_warn", defaultValue: "Reconnecting", comment: "State: reconnecting") }
    static var connecting: String { String(localized: "st_connecting", defaultValue: "Connecting…", comment: "Status menu: a session that has not reached live yet") }
    /// UI slice ④ (UI-1 spec §4.1): the status line after the user pressed Disconnect.
    static var sessionEnded: String { String(localized: "st_ended", defaultValue: "Session ended.", comment: "Status line: the user pressed Disconnect (UI slice 4)") }
    /// UI slice ④: a Connect press while a session or its preflight already exists (the button is
    /// disabled then, so only an unattended press reaches it) -- the status menu's own wording.
    static var oneSessionAtATime: String { String(localized: "si_one", defaultValue: "One session at a time. Disconnect first.", comment: "Status menu: why Connect to is unavailable during a session") }
    static func connectingTo(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "tb_connecting", value: "Connecting to %@…", table: nil), host)
    }
    static func connectedTo(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "tb_live", value: "Connected to %@", table: nil), host)
    }
    static func connectionLostTo(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "tb_lost", value: "Connection lost to %@", table: nil), host)
    }

    // MARK: Actions
    static var edit: String { String(localized: "edit", defaultValue: "Edit…", comment: "Main window: edit the selected host") }
    static var remove: String { String(localized: "remove", defaultValue: "Remove…", comment: "Main window: remove the selected host") }
    static var show: String { String(localized: "show", defaultValue: "Show…", comment: "Main window: show the pinned certificate") }
    static var done: String { String(localized: "done", defaultValue: "Done", comment: "Sheet: close") }
    static var cancel: String { String(localized: "cancel", defaultValue: "Cancel", comment: "Sheet: cancel") }
    static var save: String { String(localized: "save", defaultValue: "Save", comment: "Host Editor: save") }
    static var trust: String { String(localized: "trust", defaultValue: "Trust and Pin", comment: "Certificate sheet, first use: confirm") }
    static var replace: String { String(localized: "replace", defaultValue: "Replace Pin and Connect", comment: "Certificate sheet, changed: confirm") }
    static var addHost: String { String(localized: "add_host", defaultValue: "Add Host…", comment: "Empty first screen: add a host") }
    static var reviewCertificate: String { String(localized: "review_cert", defaultValue: "Review Certificate…", comment: "Certificate banner: open the changed-certificate sheet") }
    static var enterPassword: String { String(localized: "enter_pw", defaultValue: "Enter Password…", comment: "Sign-in failure banner: open the Password sheet") }
    static var editHostAction: String { String(localized: "edit_host", defaultValue: "Edit Host…", comment: "File menu: Edit Host item (UI slice 1)") }
    static var dismiss: String { String(localized: "dismiss", defaultValue: "Dismiss", comment: "Banner: close") }
    static var connect: String { String(localized: "connect", defaultValue: "Connect", comment: "File menu: Connect item (UI slice 1)") }
    static var disconnect: String { String(localized: "disconnect", defaultValue: "Disconnect", comment: "File menu and status menu: end the current session") }
    /// UI slice ④: the connection banner's button after a give-up.
    static var reconnect: String { String(localized: "reconnect", defaultValue: "Reconnect", comment: "Connection-lost banner, after giving up: start a new connection (UI slice 4)") }
    /// UI slice ④: the input-method banner's button to Settings > Keyboard.
    static var learnMore: String { String(localized: "learn_more", defaultValue: "Learn More", comment: "Input-method banner: opens Settings > Keyboard (UI slice 4)") }

    // MARK: Display-change note (adr/0015 §5.A.3; UI-11)
    /// The one thing a screen-parameter change does in this app: `AppDelegate` picks one of these
    /// four and writes it to the status line. Text only -- no reconnect, no resize.
    static var displayNoteNoDisplay: String { String(localized: "dn_none", defaultValue: "Display change: no usable display right now.", comment: "adr/0015 §5.A.3 display-change note: the screen list is empty (§5.A.6)") }
    static var displayNoteNoSession: String { String(localized: "dn_nosess", defaultValue: "Display change: no session yet -- the desktop size is taken at connect.", comment: "adr/0015 §5.A.3 display-change note: no session, the desktop size is taken at connect") }
    static var displayNoteStale: String { String(localized: "dn_stale", defaultValue: "Display change: this session's desktop size is now out of date -- reconnect to re-negotiate.", comment: "adr/0015 §5.A.3 display-change note: the session desktop size is out of date") }
    static var displayNoteUnaffected: String { String(localized: "dn_ok", defaultValue: "Display change: this session's desktop size is unaffected.", comment: "adr/0015 §5.A.3 display-change note: the session desktop size is unaffected") }

    // MARK: Main window detail
    static var connectionHeader: String { String(localized: "conn_h", defaultValue: "Connection", comment: "Main window: card title") }
    static var fieldAddress: String { String(localized: "f_addr", defaultValue: "Address", comment: "Main window: field label") }
    static var fieldPort: String { String(localized: "f_port", defaultValue: "Port", comment: "Main window: field label") }
    static var fieldUser: String { String(localized: "f_user", defaultValue: "User name", comment: "Main window: field label") }
    static var fieldPassword: String { String(localized: "f_pw", defaultValue: "Password", comment: "Main window: field label") }
    static var fieldCertificate: String { String(localized: "f_cert", defaultValue: "Certificate", comment: "Main window: field label") }
    static var fieldSecurity: String { String(localized: "f_sec", defaultValue: "Security", comment: "Main window: field label") }
    static var savedInKeychain: String { String(localized: "kc_saved", defaultValue: "Saved in Keychain", comment: "Main window: password saved") }
    static var askedEachTime: String { String(localized: "pw_asked", defaultValue: "Asked for on each connection", comment: "Main window: password not saved (slice 1)") }
    static var pinnedSHA256: String { String(localized: "pinned_sha", defaultValue: "Pinned · SHA-256", comment: "Main window: the host is pinned") }
    static var notPinned: String { String(localized: "not_pinned", defaultValue: "Not pinned yet. You confirm the fingerprint on first connect.", comment: "Main window: not pinned") }
    static var nlaRequired: String { String(localized: "nla_req", defaultValue: "Network Level Authentication required", comment: "Main window: security row") }
    /// UI slice ④: the Remote windows card, shown with the `wn_*` note while the connection is down.
    static var remoteWindowsHeader: String { String(localized: "rw_h", defaultValue: "Remote windows", comment: "Main window: card title (UI slice 4)") }
    static var recentHeader: String { String(localized: "recent_h", defaultValue: "Recent connections", comment: "Main window: card title") }
    static var recentNone: String { String(localized: "recent_none", defaultValue: "No connections yet", comment: "Main window: empty recent list (slice 1)") }

    static func recentEvent(_ event: RecentConnection.Event) -> String {
        switch event {
        case .connected: return String(localized: "rc_connected", defaultValue: "Connected", comment: "Recent connections: a connection reached live (slice 1)")
        case .disconnectedByUser: return String(localized: "r1_end", defaultValue: "Disconnected by you", comment: "Recent connections: ended with Disconnect")
        case .connectionLost: return String(localized: "rc_lost", defaultValue: "Connection lost", comment: "Recent connections: dropped and not reconnected (slice 1)")
        case .connectFailed: return String(localized: "st_err", defaultValue: "Connection failed", comment: "State: the last connect failed")
        case .certificateTrusted: return String(localized: "r3_end", defaultValue: "Certificate confirmed and pinned", comment: "Recent connections: Trust and Pin")
        case .certificatePinnedFromPreset: return String(localized: "rc_preset", defaultValue: "Certificate matched the expected fingerprint and was pinned", comment: "Recent connections: preset match pinned (slice 1)")
        case .certificatePinReplaced: return String(localized: "rc_replaced", defaultValue: "Certificate pin replaced", comment: "Recent connections: Replace Pin and Connect (slice 1)")
        case .allPinsReset: return String(localized: "rc_reset", defaultValue: "All pins reset", comment: "Recent connections: Reset All Pins (slice 1)")
        }
    }

    // MARK: Empty first screen (§4.3)
    static var emptyTitle: String { String(localized: "em_t", defaultValue: "No hosts yet", comment: "Empty first screen: title") }
    static var emptyBody: String { String(localized: "em_b", defaultValue: "Add the Windows PC you want to use. You need its host name or address, and a Windows account that can sign in with Remote Desktop.", comment: "Empty first screen: body") }
    static var emptyNote: String { String(localized: "em_n", defaultValue: "Macdows keeps passwords in your Keychain and asks you to confirm each host’s certificate fingerprint before it connects.", comment: "Empty first screen: note") }

    // MARK: Password sheet (§4.3)
    static func passwordTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "pw_t", value: "Connect to %@", table: nil), host)
    }
    static var passwordBody: String { String(localized: "pw_b", defaultValue: "Enter the password for this connection.", comment: "Password sheet: body") }
    static var passwordRemember: String { String(localized: "pw_remember", defaultValue: "Remember in Keychain", comment: "Password sheet: remember checkbox") }
    static var passwordSaved: String { String(localized: "pw_saved", defaultValue: "Saved in your Keychain for this host. It is never shown again.", comment: "Password sheet: note with Remember on") }
    static var passwordNotSaved: String { String(localized: "pw_notsaved", defaultValue: "Not saved. It is used for this connection, including automatic reconnects, and then forgotten.", comment: "Password sheet: note with Remember off") }

    // MARK: First-connect failure banners (§4.3)
    static func unreachableTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_u_t", value: "Can’t reach %@", table: nil), host)
    }
    static func unreachableBody(address: String, port: Int) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_u_b", value: "Macdows couldn’t open a connection to %1$@ on port %2$d. Check that the PC is turned on, is on a network this Mac can reach, and allows Remote Desktop connections.", table: nil), address, Int32(clamping: port))
    }
    static func signInTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_n_t", value: "Sign-in to %@ failed", table: nil), host)
    }
    static var signInBody: String { String(localized: "cf_n_b", defaultValue: "The host didn’t accept the user name or password (Network Level Authentication). Your saved password was not changed. Enter the password again to try once more.", comment: "First-connect failure banner: sign-in") }
    /// F-7: the `.other` kind -- the remote PC ended the connection, or the connection failed in a
    /// way the classifier does not name, before the desktop appeared.
    static func otherFailureTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_o_t", value: "Couldn’t connect to %@", table: nil), host)
    }
    static var otherFailureBody: String { String(localized: "cf_o_b", defaultValue: "The remote PC ended the connection, or the connection failed before the desktop appeared. Try again, or check this host’s settings.", comment: "First-connect failure banner: other (F-7)") }
    static func certificateRejectedTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_c_t", value: "Certificate rejected for %@", table: nil), host)
    }
    static var certificateRejectedBody: String { String(localized: "cf_c_b", defaultValue: "The host presented a certificate that doesn’t match the pinned fingerprint, so Macdows did not connect. Review the new fingerprint before you decide anything.", comment: "Certificate banner: body") }
    static var barUnreachable: String { String(localized: "cf_bar_u", defaultValue: "Not connected · can’t reach the host", comment: "Status bar: unreachable") }
    static var barSignIn: String { String(localized: "cf_bar_n", defaultValue: "Not connected · sign-in failed", comment: "Status bar: sign-in failed") }
    static var barCertificate: String { String(localized: "cf_bar_c", defaultValue: "Not connected · certificate rejected", comment: "Status bar: certificate rejected") }
    static func pinUnavailableTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "pu_t", value: "Can’t read the pinned fingerprint of %@", table: nil), host)
    }
    static var pinUnavailableBody: String { String(localized: "pu_b", defaultValue: "Macdows could not read this host’s pinned certificate fingerprint from your Keychain, so it did not connect. Allow Macdows to use the Keychain item, then connect again.", comment: "Pin unavailable banner: body (slice 1)") }
    static var unsupportedRouteBody: String { String(localized: "cf_route_b", defaultValue: "The connection was redirected or went through a gateway, which Macdows does not support, so it did not connect.", comment: "Certificate banner: redirect / gateway route refused (slice 1)") }

    // MARK: Certificate sheet (§4.4)
    static func pinnedTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cd_title", value: "Pinned certificate of %@", table: nil), host)
    }
    static func pinnedBody(_ date: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cd_body", value: "Macdows connects to this host only while it presents this fingerprint. Pinned on %@.", table: nil), date)
    }
    static var pinnedNote: String { String(localized: "cd_note", defaultValue: "A pin changes only when you replace it after a certificate change, or reset all pins in Settings. A changed certificate is never accepted silently.", comment: "Certificate sheet, details: note") }
    static func firstTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cf_title", value: "Verify the identity of %@", table: nil), host)
    }
    static var firstBody: String { String(localized: "cf_body", defaultValue: "This is the first connection to this host. Compare the fingerprint below with the one the host shows for its Remote Desktop certificate before you trust it.", comment: "Certificate sheet, first use: body") }
    static var firstCheck: String { String(localized: "cf_check", defaultValue: "I compared this fingerprint on the host and it matches", comment: "Certificate sheet, first use: checkbox") }
    static func changedTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "cc_title", value: "The certificate of %@ has changed", table: nil), host)
    }
    static var changedWarning: String { String(localized: "cc_warn", defaultValue: "The fingerprint changed since last pin. Macdows did not connect.", comment: "Certificate sheet, changed: warning") }
    static var changedBody: String { String(localized: "cc_body", defaultValue: "The host may have a new certificate, or someone may be intercepting the connection. Replace the pin only if you checked the new fingerprint on the host itself.", comment: "Certificate sheet, changed: body") }
    static var changedCheck: String { String(localized: "cc_check", defaultValue: "I compared the new fingerprint on the host and it matches", comment: "Certificate sheet, changed: checkbox") }
    static var pinLost: String { String(localized: "cc_lost", defaultValue: "The pinned fingerprint is missing from your Keychain.", comment: "Certificate sheet, changed: the old pin item is gone (slice 1)") }
    static var expectedFingerprint: String { String(localized: "fp_expected", defaultValue: "Expected fingerprint (SHA-256)", comment: "Certificate sheet, changed: the preset the host did not match (slice 1)") }
    static var fingerprint: String { String(localized: "fp", defaultValue: "Fingerprint (SHA-256)", comment: "Certificate sheet: field label") }
    static var fingerprintPinned: String { String(localized: "fp_pinned", defaultValue: "Pinned fingerprint (SHA-256)", comment: "Certificate sheet: field label") }
    static var fingerprintNew: String { String(localized: "fp_new", defaultValue: "New fingerprint (SHA-256)", comment: "Certificate sheet: field label") }
    static var certHost: String { String(localized: "c_host", defaultValue: "Host:", comment: "Certificate sheet: field label") }
    static var certIssuedTo: String { String(localized: "c_to", defaultValue: "Issued to:", comment: "Certificate sheet: field label") }
    static var certUser: String { String(localized: "he_user", defaultValue: "User name:", comment: "Host Editor: label") }
    static var certIssuer: String { String(localized: "c_by", defaultValue: "Issuer:", comment: "Certificate sheet: field label") }

    // MARK: Host Editor
    static var editHostTitle: String { String(localized: "he_edit", defaultValue: "Edit Host", comment: "Host Editor title in edit mode") }
    static var editorName: String { String(localized: "he_name", defaultValue: "Name:", comment: "Host Editor: label") }
    static var editorNamePlaceholder: String { String(localized: "he_name_ph", defaultValue: "For example: Office PC", comment: "Host Editor: placeholder") }
    static var editorAddress: String { String(localized: "he_addr", defaultValue: "Address:", comment: "Host Editor: label") }
    static var editorAddressPlaceholder: String { String(localized: "he_addr_ph", defaultValue: "Host name or IP address", comment: "Host Editor: placeholder") }
    static var editorPort: String { String(localized: "he_port", defaultValue: "Port:", comment: "Host Editor: label") }
    static var editorUser: String { String(localized: "he_user", defaultValue: "User name:", comment: "Host Editor: label") }
    static var editorUserPlaceholder: String { String(localized: "he_user_ph", defaultValue: "Windows account name", comment: "Host Editor: placeholder") }
    static var editorPassword: String { String(localized: "he_pw", defaultValue: "Password:", comment: "Host Editor: label") }
    static var editorPasswordPlaceholderEdit: String { String(localized: "he_pw_ph_edit", defaultValue: "Saved in Keychain. Type to replace.", comment: "Host Editor: password placeholder in edit mode") }
    static var showPassword: String { String(localized: "show_pw", defaultValue: "Show password", comment: "Host Editor: reveal button (accessibility)") }
    static var hidePassword: String { String(localized: "hide_pw", defaultValue: "Hide password", comment: "Host Editor: hide button (accessibility)") }
    static var editorRemember: String { String(localized: "he_remember", defaultValue: "Remember password in Keychain", comment: "Host Editor: checkbox") }
    static var editorAsk: String { String(localized: "he_ask", defaultValue: "Ask for Touch ID or your Mac password before using it", comment: "Host Editor: Touch ID checkbox (disabled in slice 1)") }
    static var comingLater: String { String(localized: "soon", defaultValue: "Coming later", comment: "A disabled item that a later version enables") }
    static var editorPasswordNote: String { String(localized: "he_pw_note", defaultValue: "The show button reveals only what you type here. A saved password is never shown again.", comment: "Host Editor: password note") }
    static var editorSignIn: String { String(localized: "he_signin", defaultValue: "Sign-in security:", comment: "Host Editor: label") }
    static var editorNLA: String { String(localized: "he_nla", defaultValue: "Network Level Authentication", comment: "Host Editor: read-only value") }
    static var editorRequired: String { String(localized: "required", defaultValue: "(required)", comment: "Host Editor: suffix of the NLA row") }
    static var editorCertificate: String { String(localized: "he_cert", defaultValue: "Certificate:", comment: "Host Editor: label") }
    static var editorFingerprint: String { String(localized: "he_fp", defaultValue: "Expected certificate fingerprint (optional)", comment: "Host Editor: preset field title") }
    static var editorFingerprintPlaceholder: String { String(localized: "he_fp_ph", defaultValue: "SHA-256, for example AB:CD:EF:01:…", comment: "Host Editor: preset placeholder") }
    static var editorFingerprintNote: String { String(localized: "he_fp_note", defaultValue: "Recommended. The first connection is checked against it and a mismatch is handled like a changed certificate. If you leave it empty, you compare the fingerprint yourself on first connect.", comment: "Host Editor: preset note") }
    static var editorFingerprintSHA1: String { String(localized: "he_fp_sha1", defaultValue: "This is a SHA-1 thumbprint (20 bytes). Enter the SHA-256 fingerprint (32 bytes).", comment: "Host Editor: preset error (slice 1)") }
    static var editorFingerprintInvalid: String { String(localized: "he_fp_err", defaultValue: "Enter 32 bytes in hexadecimal, for example AB:CD:EF:01:…", comment: "Host Editor: preset error (slice 1)") }
    static var editorAddressRequired: String { String(localized: "he_addr_err", defaultValue: "Enter a host name or address.", comment: "Host Editor: address error (slice 1)") }
    static var editorPortInvalid: String { String(localized: "he_port_err", defaultValue: "Enter a port from 1 to 65535.", comment: "Host Editor: port error (slice 1)") }
    static var editorKeychainFailed: String { String(localized: "he_kc_err", defaultValue: "The host was saved, but Macdows could not update its Keychain items.", comment: "Host Editor: keychain write failed (slice 1)") }

    // MARK: Remove alert
    static func removeTitle(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "rm_t", value: "Remove “%@”?", table: nil), host)
    }
    static var removeBody: String { String(localized: "rm_b", defaultValue: "Macdows removes this host, its password saved in your Keychain and its pinned certificate fingerprint.", comment: "Remove alert: body (slice 1)") }
    static var removeConfirm: String { String(localized: "rm_ok", defaultValue: "Remove", comment: "Remove alert: destructive button (slice 1)") }
    static var removeFailed: String { String(localized: "rm_err", defaultValue: "Macdows could not remove this host’s Keychain items, so the host was kept.", comment: "Remove alert: failure (slice 1)") }

    // MARK: Start panel (ADR-0025 §5.1 as amended by owner ruling ㋯; design note 2026-10-07 §4)
    // Twenty-five `sp_*` keys. `sp_gaveup` is not one of them: a give-up tears the session down, so
    // the panel has no give-up state (§10 item 1 (b)). Reused, never re-keyed: `si_open`,
    // `st_conn`, `st_connecting`, `st_off`, `si_retry`.
    static var startPanelTitle: String { String(localized: "sp_title", defaultValue: "Start panel", comment: "Start panel: its name (VoiceOver) and the Settings row label") }
    static var startPanelPinned: String { String(localized: "sp_pinned", defaultValue: "Pinned", comment: "Start panel: section header") }
    static var startPanelRecent: String { String(localized: "sp_recent", defaultValue: "Recent", comment: "Start panel: section header") }
    static var startPanelRun: String { String(localized: "sp_run", defaultValue: "Run…", comment: "Start panel, Dock menu and status menu: run a program (the Run field's VoiceOver name)") }
    static var startPanelRunPlaceholder: String { String(localized: "sp_run_ph", defaultValue: "Program path or name", comment: "Start panel: Run field placeholder") }
    static var startPanelPin: String { String(localized: "sp_pin", defaultValue: "Pin", comment: "Start panel: row menu, pin a recent program") }
    static var startPanelUnpin: String { String(localized: "sp_unpin", defaultValue: "Unpin", comment: "Start panel: row menu, unpin a pinned program") }
    static var startPanelForget: String { String(localized: "sp_forget", defaultValue: "Remove from Recent", comment: "Start panel: row menu, drop a recent program") }
    static var startPanelEmpty: String { String(localized: "sp_empty", defaultValue: "Programs you run appear here.", comment: "Start panel: no pinned or recent programs yet") }
    static var startPanelWaiting: String { String(localized: "sp_wait", defaultValue: "Reconnecting. You can launch programs once connected.", comment: "Start panel: header status while reconnecting") }
    static func startPanelLastFailure(_ reason: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "sp_last_fail", value: "The last launch did not succeed: %@", table: nil), reason)
    }
    static var startPanelHookNotLoaded: String { String(localized: "sp_r_hook", defaultValue: "Windows is not ready to start programs yet. Try again in a moment.", comment: "Start panel: launch result 1") }
    static var startPanelDecodeFailed: String { String(localized: "sp_r_decode", defaultValue: "Windows could not read the program name.", comment: "Start panel: launch result 2") }
    static var startPanelNotAllowed: String { String(localized: "sp_r_allow", defaultValue: "This program is not allowed on the remote PC.", comment: "Start panel: launch result 3") }
    static var startPanelNotFound: String { String(localized: "sp_r_nf", defaultValue: "The program was not found on the remote PC. Check the path.", comment: "Start panel: launch result 5") }
    static var startPanelFailed: String { String(localized: "sp_r_fail", defaultValue: "Windows could not start the program.", comment: "Start panel: launch result 6") }
    static var startPanelLocked: String { String(localized: "sp_r_locked", defaultValue: "The remote session is locked.", comment: "Start panel: launch result 7") }
    static var startPanelUnknownResult: String { String(localized: "sp_r_unknown", defaultValue: "Windows returned an unknown result.", comment: "Start panel: any other launch result") }
    static var startPanelTimedOut: String { String(localized: "sp_r_timeout", defaultValue: "Windows did not reply. If the program doesn’t open, try again.", comment: "Start panel: no launch result within the timeout") }
    static var startPanelPathTooLong: String { String(localized: "sp_r_long", defaultValue: "The path is too long.", comment: "Start panel: refused before sending") }
    static var startPanelPathAndArgumentsTooLong: String { String(localized: "sp_r_args_long", defaultValue: "The path and arguments are too long together.", comment: "Start panel: refused before sending") }
    static var startPanelPrecise: String { String(localized: "sp_ax", defaultValue: "Precise Dock positioning", comment: "Settings, General: the start panel checkbox") }
    static var startPanelPreciseNote: String { String(localized: "sp_ax_d", defaultValue: "Uses Accessibility to find the Macdows icon in the Dock. Without access, the panel opens where you clicked. You can allow access in System Settings > Privacy & Security > Accessibility.", comment: "Settings, General: the start panel checkbox, explained") }
    static var startPanelNotAuthorized: String { String(localized: "sp_ax_off", defaultValue: "Accessibility access isn’t allowed yet. Allow Macdows in Privacy & Security to open the panel at its Dock icon.", comment: "Settings, General: the checkbox is on but access is not granted") }
    static var startPanelOpenPrivacy: String { String(localized: "sp_ax_open", defaultValue: "Open Privacy & Security…", comment: "Settings, General: open the Accessibility list in System Settings") }

    /// The `sp_r_*` key -> its sentence, for the keys `ExecResultCode.reasonKey`,
    /// `AppLauncher.reasonKey(for:)` and the timeout produce. A key outside the table reads as the
    /// unknown result.
    static func startPanelReason(forKey key: String) -> String {
        switch key {
        case "sp_r_hook": startPanelHookNotLoaded
        case "sp_r_decode": startPanelDecodeFailed
        case "sp_r_allow": startPanelNotAllowed
        case "sp_r_nf": startPanelNotFound
        case "sp_r_fail": startPanelFailed
        case "sp_r_locked": startPanelLocked
        case "sp_r_timeout": startPanelTimedOut
        case "sp_r_long": startPanelPathTooLong
        case "sp_r_args_long": startPanelPathAndArgumentsTooLong
        default: startPanelUnknownResult
        }
    }

    /// Reused keys, same default values as their first users (`StatusItemController`).
    static var openMacdows: String { String(localized: "si_open", defaultValue: "Open Macdows", comment: "Status menu: bring Macdows to the front") }
    static func reconnectingTo(_ host: String) -> String {
        String(format: Bundle.main.localizedString(forKey: "si_retry", value: "Reconnecting to %@", table: nil), host)
    }
}
