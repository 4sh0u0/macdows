import AppKit
import MacdowsCore

/// adr/0022 D-6 (T1, UI slice ②): the Macdows status item -- the App's one `NSStatusItem` -- and
/// its menu (UI-1 spec §6.3), top to bottom:
///
///     <marker> <connection state>       disabled; live / reconnecting / not connected
///     <detail>                          disabled, second line; hidden when there is none
///     [Remote tray section]             adr/0023, `StatusItemTraySection` (hidden or shown)
///     ---------------------------      shown only while the section is hidden
///     Connect to ▸ <hosts>              slice ①: the host records (ADR-0024 §3 adr/0023 row)
///     One session at a time. ...        disabled, shown while a session exists
///     Disconnect                        the File menu's Disconnect item (adr/0022 D-11)
///     ---------------------------
///     Run…                              ADR-0025 R-8: the start panel under this item; enabled
///                                       while a session exists (Disconnect's predicate)
///     Open Macdows                      activates the App
///     Settings…                         the main menu's Settings… (UI slice ③)
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
///  - Connect to (UI slice ①) lists the host records the App supplies through `hostEntries` and is
///    enabled only while there is no session and at least one host; choosing a host hands its id to
///    `onConnectTo`, which presses the App's own Connect button for it. The submenu's items are
///    written here too, by replacing its `items` in `apply`, so this type stays the one writer.
///  - The session is READ, never driven: `reading` is a closure over the App's own state, called
///    whenever this menu is about to open and whenever the App says the session changed
///    (`bind(_:)`, `refresh()`).
///  - Open Macdows activates the App, so a key remote window resigns key and releases its
///    modifiers through its own `.focusLost` path (adr/0022 D-6) -- the expected outcome.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// What the status rows and the Remote tray section are computed from.
    struct SessionReading: Equatable {
        var hasSession: Bool
        /// The reconnect driver's state; nil while there is no driver (no session, or a session
        /// whose driver is not armed yet).
        var state: ReconnectDriver.State?
        /// The address the session was opened to (adr/0023 D-4: the host's display name arrives
        /// with slice ①'s host list; until then the connection address is the name).
        var host: String?
        /// UI slice ④: when the connection leg went live, as the App recorded it -- the one record
        /// the Hosts window's status bar reads too. `nil` lets this controller latch its own (a
        /// reading built without the App, as in a test).
        var liveSince: Date? = nil

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
    /// Connect to's submenu: one item per host record (UI slice ①).
    let connectToMenu = NSMenu(title: "")
    let oneSessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let disconnectItem = MainMenu.disconnectItem()
    /// ADR-0025 R-8: opens the start panel under the status item, its Run field focused.
    let runItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let openItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    /// adr/0023 D-6 P-a: the Remote tray section's hook in this menu, directly after the status
    /// rows.
    private(set) var traySection: StatusItemTraySection!

    /// The App's state, read on demand. Returns `.noSession` until the App sets it.
    var reading: () -> SessionReading = { .noSession }

    /// One Connect to entry (UI slice ①).
    struct HostEntry: Equatable {
        let id: HostID
        let title: String
    }

    /// The host records, read on demand; empty until the App sets it.
    var hostEntries: () -> [HostEntry] = { [] }
    /// Called with the chosen host; the App presses its Connect button for it.
    var onConnectTo: ((HostID) -> Void)?
    /// Gate r1 I-2: Open Macdows also brings the Hosts window back (the App points this at the
    /// Hosts window controller's `showHosts`), so a closed Hosts window is always one click away.
    var onOpenMacdows: (() -> Void)?
    /// ADR-0025 R-8: Run… -- the App opens the start panel anchored under the status item button,
    /// whose screen frame this passes (nil before `install()`).
    var onRun: ((CGRect?) -> Void)?

    private(set) var statusItem: NSStatusItem?
    /// The registry of the current session, nil without one. Weak: the App owns it.
    private(set) weak var registry: RemoteWindowRegistry?
    /// When the current connection was first seen live, for "since 12:03"; cleared when it stops
    /// being live. The App's own record (`SessionReading.liveSince`) wins when it supplies one.
    private(set) var liveSince: Date?
    private var terminationObserver: NSObjectProtocol?
    /// Design note §6: true while the start panel this item's Run… opened is showing -- what the
    /// button's highlight follows (`setPanelHighlight(_:)`).
    private(set) var panelHighlightWanted = false
    /// F-a1-8: this item's menu finishing its tracking, observed from `install()`.
    private var menuEndObserver: NSObjectProtocol?

    override init() {
        super.init()
        statusRow.isEnabled = false
        detailRow.isEnabled = false
        detailRow.isHidden = true
        connectToItem.title = String(localized: "si_connect_to", defaultValue: "Connect to", comment: "Status menu: Connect to (the host list arrives with UI slice 1)")
        connectToItem.submenu = connectToMenu
        connectToMenu.autoenablesItems = false
        oneSessionItem.title = String(localized: "si_one", defaultValue: "One session at a time. Disconnect first.", comment: "Status menu: why Connect to is unavailable during a session")
        oneSessionItem.isHidden = true
        runItem.title = UIStrings.startPanelRun
        runItem.action = #selector(runProgram(_:))
        runItem.target = self
        openItem.title = String(localized: "si_open", defaultValue: "Open Macdows", comment: "Status menu: bring Macdows to the front")
        openItem.action = #selector(openMacdows(_:))
        openItem.target = self
        settingsItem.title = String(localized: "m_settings", defaultValue: "Settings…", comment: "Application menu: Settings item")
        settingsItem.action = #selector(openSettings(_:))
        settingsItem.target = self
        quitItem.title = String(localized: "m_quit", defaultValue: "Quit Macdows", comment: "Application menu: Quit item")

        menu.addItem(statusRow)
        menu.addItem(detailRow)
        menu.addItem(sectionGapSeparator)
        menu.addItem(connectToItem)
        menu.addItem(oneSessionItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(runItem)
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
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyPanelHighlightAfterMenu() }
        }
    }

    /// Takes the status item out of the menu bar (on App termination).
    func uninstall() {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
        }
        menuEndObserver = nil
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
            liveSince = reading.liveSince ?? liveSince ?? Date()
        } else {
            liveSince = nil
        }
        let rows = Self.statusRows(for: reading, windows: registry?.windowSnapshots().count ?? 0, liveSince: liveSince)
        statusRow.title = rows.title
        statusRow.image = Self.markerImage(rows.marker)
        detailRow.title = rows.detail ?? ""
        detailRow.isHidden = rows.detail == nil
        oneSessionItem.isHidden = !reading.hasSession
        runItem.isEnabled = reading.hasSession
        let entries = hostEntries()
        connectToMenu.items = entries.map { entry in
            let item = NSMenuItem(title: entry.title, action: #selector(connectToHost(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.keychainAccount
            item.isEnabled = !reading.hasSession
            return item
        }
        connectToItem.isEnabled = !reading.hasSession && !entries.isEmpty
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
                    Int32(clamping: ShellReconnectPresenter.reconnectCount)
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
        onOpenMacdows?()
    }

    /// ADR-0025 R-8: Run… opens the start panel under this status item (its Run field focused).
    /// Only with a session: the same predicate as Disconnect, checked again here.
    @objc private func runProgram(_ sender: Any?) {
        guard reading().hasSession else { return }
        onRun?(buttonScreenFrame)
    }

    /// Design note §6: the button stays highlighted while the start panel it opened is open. The App
    /// forwards the panel's `onStatusItemAnchorChange` here. Applied on the next turn, after the menu
    /// that sent Run… has finished tracking (which resets the button's highlight itself); both
    /// directions go through the same queue, so their order is kept.
    ///
    /// F-a1-8 (in person, macOS 27.2: no highlight at all): the next turn alone did not hold, so the
    /// wanted state is also applied again 50 ms after this item's menu ends tracking
    /// (`reapplyPanelHighlightAfterMenu`), and each application sets both the button's highlight and
    /// its cell's highlighted flag. Not verifiable offline (no status item in tests): the next
    /// in-person batch checks it.
    func setPanelHighlight(_ on: Bool) {
        panelHighlightWanted = on
        DispatchQueue.main.async { [weak self] in
            self?.applyPanelHighlight(on)
        }
    }

    /// F-a1-8: after the menu's own teardown has reset the button, set the wanted state again (read
    /// when the block runs, so a panel closed in between is not highlighted back).
    private func reapplyPanelHighlightAfterMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.applyPanelHighlight(self.panelHighlightWanted)
        }
    }

    /// The one place the button's highlight is written: the button's own call and its cell's flag,
    /// on and off alike.
    private func applyPanelHighlight(_ on: Bool) {
        guard let button = statusItem?.button else { return }
        button.highlight(on)
        (button.cell as? NSButtonCell)?.isHighlighted = on
    }

    /// The status item button's frame on screen, the start panel's anchor.
    var buttonScreenFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Run… is enabled exactly while a session exists (the menu auto-enables items with a target);
    /// every other item keeps AppKit's answer.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === runItem else { return true }
        return reading().hasSession
    }

    /// UI slice ③: Settings… activates the App (as Open Macdows does) and performs the main menu's
    /// Settings… item, so both entries are one action with one target.
    @objc private func openSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        MainMenu.performSettings(in: NSApp.mainMenu, from: sender)
    }

    /// UI slice ①: Connect to ▸ <host>. Only while there is no session (one session at a time).
    @objc func connectToHost(_ sender: NSMenuItem) {
        guard !reading().hasSession, let account = sender.representedObject as? String,
              let host = HostID(keychainAccount: account) else { return }
        onConnectTo?(host)
    }
}
