import AppKit
import MacdowsCore

/// adr/0022 D-6 (T1, UI slice ②): the Macdows status item -- the App's one `NSStatusItem` -- and
/// its menu (UI-1 spec §6.3), top to bottom:
///
///     <marker> <connection state>       disabled; live / reconnecting / not connected
///     <detail>                          disabled, second line; hidden when there is none
///     [Remote tray section]             adr/0023, `StatusItemTraySection` (hidden or shown)
///     ---------------------------      shown only while the section is hidden
///     Connect to                        disabled until slice ① brings the host list
///     One session at a time. ...        disabled, shown while a session exists
///     Disconnect                        the File menu's Disconnect item (adr/0022 D-11)
///     ---------------------------
///     Open Macdows                      activates the App
///     Settings…                         no action yet, so AppKit keeps it disabled
///     ---------------------------
///     Quit Macdows                      `terminate:`
///
/// Rules this type keeps:
///  - It is the ONE writer of this menu's structure (adr/0023 D-6 P-a). The Remote tray section
///    edits only its own run of items, on its behalf.
///  - `install()` is the only place in the App's non-test sources that asks the system status bar
///    for an item (adr/0023 D-8 ⑥). The item lives from launch to exit, not per session: it is
///    created once and removed when the App terminates.
///  - Disconnect is the item `MainMenu.disconnectItem()` builds, so both Disconnect entries are the
///    same nil-target action -- the scaffold button's `endSessionTapped` -- validated by the same
///    `session != nil` predicate in `AppDelegate` (adr/0022 D-11 K3-R). Nothing here ends a session
///    itself, and no item sends a key to Windows (adr/0022 I-3).
///  - The Remote tray section (adr/0023) mirrors the bound registry's tray entries and follows the
///    session's state, also while the menu is open: entries through the tray's own change stream
///    (D-3 M-a), presentation through `refresh()` on every driver state change.
///  - The session is READ, never driven: `reading` is a closure over the App's own state, called
///    whenever this menu is about to open and whenever the App says the session changed
///    (`bind(_:)`, `refresh()`).
///  - Open Macdows activates the App, so a key remote window resigns key and releases its
///    modifiers through its own `.focusLost` path (adr/0022 D-6) -- the expected outcome.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// What the status rows and the Remote tray section are computed from.
    struct SessionReading: Equatable {
        var hasSession: Bool
        /// The reconnect driver's state; nil while there is no driver (no session, or a session
        /// whose driver is not armed yet).
        var state: ReconnectDriver.State?
        /// The address the session was opened to (adr/0023 D-4: the host's display name arrives
        /// with slice ①'s host list; until then the connection address is the name).
        var host: String?

        static let noSession = SessionReading(hasSession: false, state: nil, host: nil)
    }

    /// The first status row's colour mark.
    enum Marker: Equatable {
        case live
        case reconnecting
        case notConnected
    }

    /// The status rows for one reading: the mark, the first line, the optional second line.
    struct StatusRows: Equatable {
        var marker: Marker
        var title: String
        var detail: String?
    }

    let menu = NSMenu(title: "Macdows")
    let statusRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let detailRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Separates the status rows from Connect to while the Remote tray section is hidden (the
    /// section brings its own separators when shown).
    let sectionGapSeparator = NSMenuItem.separator()
    let connectToItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let oneSessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let disconnectItem = MainMenu.disconnectItem()
    let openItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    /// adr/0023 D-6 P-a: the Remote tray section's hook in this menu, directly after the status
    /// rows.
    private(set) var traySection: StatusItemTraySection!

    /// The App's state, read on demand. Returns `.noSession` until the App sets it.
    var reading: () -> SessionReading = { .noSession }

    private(set) var statusItem: NSStatusItem?
    /// The registry of the current session, nil without one. Weak: the App owns it.
    private(set) weak var registry: RemoteWindowRegistry?
    /// When the current connection was first seen live, for "since 12:03"; cleared when it stops
    /// being live.
    private(set) var liveSince: Date?
    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        statusRow.isEnabled = false
        detailRow.isEnabled = false
        detailRow.isHidden = true
        connectToItem.title = String(localized: "si_connect_to", defaultValue: "Connect to", comment: "Status menu: Connect to (the host list arrives with UI slice 1)")
        oneSessionItem.title = String(localized: "si_one", defaultValue: "One session at a time. Disconnect first.", comment: "Status menu: why Connect to is unavailable during a session")
        oneSessionItem.isHidden = true
        openItem.title = String(localized: "si_open", defaultValue: "Open Macdows", comment: "Status menu: bring Macdows to the front")
        openItem.action = #selector(openMacdows(_:))
        openItem.target = self
        settingsItem.title = String(localized: "m_settings", defaultValue: "Settings…", comment: "Application menu: Settings item")
        quitItem.title = String(localized: "m_quit", defaultValue: "Quit Macdows", comment: "Application menu: Quit item")

        menu.addItem(statusRow)
        menu.addItem(detailRow)
        menu.addItem(sectionGapSeparator)
        menu.addItem(connectToItem)
        menu.addItem(oneSessionItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.delegate = self
        traySection = StatusItemTraySection(menu: menu, after: detailRow)
        apply(reading())
    }

    // MARK: - Lifetime (launch to exit)

    /// Puts the status item in the menu bar with this menu. Called once, at launch; a second call
    /// does nothing.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let label = String(localized: "si_label", defaultValue: "Macdows status menu", comment: "Status item: accessibility label")
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel(label)
        item.menu = menu
        statusItem = item
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.uninstall() }
        }
    }

    /// Takes the status item out of the menu bar (on App termination).
    func uninstall() {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        if let statusItem {
            statusItem.statusBar?.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Session hand-off

    /// The App hands over the current session's registry, or nil when there is none (adr/0023
    /// D-6: an empty source, so the Remote tray section hides). The section mirrors that
    /// registry's tray entries from now on.
    func bind(_ registry: RemoteWindowRegistry?) {
        self.registry = registry
        traySection.bind(registry?.trayMenuSource)
        refresh()
    }

    /// Re-reads the App's state and rewrites the status rows (and, from adr/0023, the section's
    /// presentation). Safe while the menu is open.
    func refresh() {
        apply(reading())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private func apply(_ reading: SessionReading) {
        if case .live = reading.state, reading.hasSession {
            if liveSince == nil { liveSince = Date() }
        } else {
            liveSince = nil
        }
        let rows = Self.statusRows(for: reading, windows: registry?.windowSnapshots().count ?? 0, liveSince: liveSince)
        statusRow.title = rows.title
        statusRow.image = Self.markerImage(rows.marker)
        detailRow.title = rows.detail ?? ""
        detailRow.isHidden = rows.detail == nil
        oneSessionItem.isHidden = !reading.hasSession
        traySection.setPresentation(registry == nil ? .hidden : Self.trayPresentation(for: reading))
        sectionGapSeparator.isHidden = traySection.isShown
    }

    /// adr/0023 D-4: live -> entries (or "no tray icons"); waiting / reconnecting -> "come back
    /// after reconnecting" (the entries were torn down with the connection); first connect not yet
    /// live, given up, no session -> no section at all. The header names the session's address.
    static func trayPresentation(for reading: SessionReading) -> StatusItemTraySection.Presentation {
        guard reading.hasSession else { return .hidden }
        let host = reading.host ?? ""
        switch reading.state {
        case .live:
            return .live(host: host)
        case .waiting, .reconnecting:
            return .reconnecting(host: host)
        case .idle, .gaveUp, nil:
            return .hidden
        }
    }

    // MARK: - Pure presentation (offline-testable)

    /// UI-1 spec §6.3's status rows. v1 has three states -- live, reconnecting, not connected --
    /// plus "Connecting…" for a session that has not reached live yet (first connect). Format
    /// strings come from the catalog unformatted and are filled in with `String(format:)`.
    static func statusRows(for reading: SessionReading, windows: Int, liveSince: Date?) -> StatusRows {
        let host = reading.host ?? ""
        guard reading.hasSession else {
            return StatusRows(marker: .notConnected, title: notConnectedTitle, detail: nil)
        }
        switch reading.state {
        case .live:
            let since = liveSince.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
            return StatusRows(
                marker: .live,
                title: String(format: Bundle.main.localizedString(forKey: "tb_live", value: "Connected to %@", table: nil), host),
                detail: String(format: Bundle.main.localizedString(forKey: "si_live_d", value: "%d windows · since %@", table: nil), Int32(clamping: windows), since)
            )
        case .waiting(let attempt, _), .reconnecting(let attempt):
            return StatusRows(
                marker: .reconnecting,
                title: String(format: Bundle.main.localizedString(forKey: "si_retry", value: "Reconnecting to %@", table: nil), host),
                detail: String(
                    format: Bundle.main.localizedString(forKey: "si_retry_d", value: "Reconnect attempt %1$d of %2$d", table: nil),
                    Int32(clamping: ShellReconnectPresenter.humanAttemptNumber(forZeroBasedIndex: attempt)),
                    Int32(clamping: ReconnectPolicy.maxAttempts)
                )
            )
        case .gaveUp:
            return StatusRows(marker: .notConnected, title: notConnectedTitle, detail: nil)
        case .idle, nil:
            return StatusRows(
                marker: .reconnecting,
                title: String(localized: "st_connecting", defaultValue: "Connecting…", comment: "Status menu: a session that has not reached live yet"),
                detail: nil
            )
        }
    }

    private static var notConnectedTitle: String {
        String(localized: "st_off", defaultValue: "Not connected", comment: "Status menu: no session")
    }

    private static func markerImage(_ marker: Marker) -> NSImage? {
        let color: NSColor
        switch marker {
        case .live: color = .systemGreen
        case .reconnecting: color = .systemOrange
        case .notConnected: color = .tertiaryLabelColor
        }
        let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        return base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color]))
        )
    }

    // MARK: - Actions

    /// UI-1 spec §6.3 Open Macdows: activate the App (adr/0022 D-6: a key remote window resigns
    /// key, which releases its modifiers -- the correct outcome).
    @objc private func openMacdows(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
