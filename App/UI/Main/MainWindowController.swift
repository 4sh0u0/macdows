import AppKit
import MacdowsCore

/// UI slice ① (UI-1 spec §1 / §3 / §8 ①): the main "Hosts" window -- sidebar host list, a
/// transparent standard toolbar (New Host, Settings), the banner area, the host detail and the
/// status bar -- and the sheets it presents (Host Editor, Password, Certificate).
///
/// Session control stays with the App: the Connect and Disconnect buttons are the App's own
/// (handed in with `installSessionControls`), and File ▸ Connect / the status item's Connect to
/// reach the App by pressing that same Connect button (`connectSelectedHost(_:)`), so there is one
/// connect path. This controller owns the host records' editing (Host Editor, Remove…) and asks the
/// keychain only off the main thread, through `HostActions`.
///
/// File ▸ New Host… / Edit Host… / Connect are nil-target menu items whose selectors
/// (`MainMenu.newHostAction`, …) this controller implements; it is the window's controller, so the
/// responder chain reaches it while the Hosts window is key or main. View ▸ Show Hosts is the
/// exception (gate r1 I-2): the App binds it to this controller explicitly
/// (`MainMenu.bindShowHosts`), because it has to work while the Hosts window is closed, and so do
/// the status item's Open Macdows and a Dock-icon reopen. Closing the window only orders it out
/// (`isReleasedWhenClosed = false`). File ▸ Close Window (⌘W, `MainMenu.closeWindowAction`) is
/// one of those nil-target items too: it closes this window while it is key (UI-9).
///
/// Keychain work runs on `KeychainQueue`, never in a detached task (gate r1 m-5).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    static let minimumSize = NSSize(width: 760, height: 520)

    let store: HostRecordStore
    let actions: HostActions
    let list: HostListViewController
    let detail: HostDetailViewController
    /// The host the current session (or connect attempt) belongs to; Remove… is disabled for it.
    var activeHostID: HostID? {
        didSet { refreshDetail() }
    }
    /// Called whenever the host records change (the status item's Connect to list re-reads).
    var onHostsChanged: (() -> Void)?
    /// Called when the App's Disconnect button turns on or off. That button's enablement has one
    /// writer, the App's `session` property (adr/0020 S-4: enabled exactly while a session exists),
    /// so this is "a session began / ended", whichever path ended it.
    var onSessionPresenceChange: ((Bool) -> Void)?
    private var presenceObservation: NSKeyValueObservation?
    private(set) var selectedHostID: HostID?
    private weak var connectButton: NSButton?
    /// The App's Disconnect button (UI slice ④: the connection banner's Disconnect presses it).
    private weak var disconnectButton: NSButton?
    private var titleLabel: NSTextField?
    private var banners: [BannerView.Model] = []
    /// Sheets kept alive until they finish.
    private var openSheets: [ObjectIdentifier: AnyObject] = [:]

    init(store: HostRecordStore, actions: HostActions) {
        self.store = store
        self.actions = actions
        list = HostListViewController(addAction: MainMenu.newHostAction, removeAction: Self.removeAction)
        detail = HostDetailViewController(editAction: MainMenu.editHostAction, removeAction: Self.removeAction,
                                          showAction: Self.showCertificateAction, addAction: MainMenu.newHostAction)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Macdows"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("MacdowsHostsWindow")
        super.init(window: window)

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: list)
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 320
        sidebar.canCollapse = true
        split.addSplitViewItem(sidebar)
        let content = NSSplitViewItem(viewController: detail)
        content.minimumThickness = 480
        split.addSplitViewItem(content)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 700))

        let toolbar = NSToolbar(identifier: "MacdowsHostsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.delegate = self
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName("MacdowsHostsWindow") {
            window.center()
        }

        list.onSelectionChange = { [weak self] host in
            self?.selectedHostID = host
            self?.refreshDetail()
        }
        list.addButton.target = self
        list.removeButton.target = self
        detail.editButton.target = self
        detail.removeButton.target = self
        detail.showButton.target = self
        detail.addHostButton.target = self
        store.onChange = { [weak self] in
            self?.reloadHosts()
            self?.onHostsChanged?()
        }
        // ADR-0024 D-9 (M-a-1): a host is pre-selected only when there is exactly one, so an
        // unattended Connect press can only ever dial that one.
        selectedHostID = store.records.count == 1 ? store.records[0].id : nil
        reloadHosts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static let removeAction = NSSelectorFromString("removeHost:")
    static let showCertificateAction = NSSelectorFromString("showPinnedCertificate:")

    // MARK: - Wiring from the App

    func installSessionControls(_ stack: NSStackView, title: NSTextField, status: NSTextField,
                                connect: NSButton, disconnect: NSButton) {
        connectButton = connect
        disconnectButton = disconnect
        titleLabel = title
        detail.installSessionControls(stack, title: title, status: status, connect: connect, disconnect: disconnect)
        presenceObservation = disconnect.observe(\.isEnabled, options: [.new]) { [weak self] button, _ in
            MainActor.assumeIsolated {
                self?.onSessionPresenceChange?(button.isEnabled)
            }
        }
        refreshDetail()
    }

    var selectedRecord: HostRecord? { selectedHostID.flatMap(store.record) }

    func select(_ host: HostID?) {
        selectedHostID = host
        list.select(host)
        refreshDetail()
    }

    /// The window subtitle, the status bar and the active host's sidebar marker, together.
    func setShell(subtitle: String?, statusBar: String, marker: HostListViewController.Marker, for host: HostID?) {
        window?.subtitle = subtitle ?? UIStrings.hostCount(store.records.count)
        detail.setStatusBar(statusBar, marker: marker)
        if let host { list.setMarker(marker, for: host) }
    }

    /// UI slice ④: the Remote windows card's note (`nil` hides the card).
    func setRemoteWindowsNote(_ text: String?) {
        detail.setRemoteWindowsNote(text)
    }

    /// UI slice ④: the connection banner's Disconnect -- presses the App's Disconnect button, so it
    /// is the End-session action itself (adr/0020 D-5), by the route a mouse takes. Ignored while
    /// that button is disabled (no session to end).
    func disconnectSession() {
        guard let disconnectButton, disconnectButton.isEnabled else { return }
        disconnectButton.performClick(nil)
    }

    /// UI slice ④: the status bar's text alone -- the App's per-tick shell write (the live text
    /// carries the window count). The marker follows state changes through `setShell`.
    func setStatusBarText(_ text: String) {
        detail.setStatusBarText(text)
    }

    // MARK: - Banners

    func showBanner(_ model: BannerView.Model) {
        banners.removeAll { $0.id == model.id }
        banners.append(model)
        detail.setBanners(banners.map(BannerView.init))
    }

    func removeBanner(id: String) {
        banners.removeAll { $0.id == id }
        detail.setBanners(banners.map(BannerView.init))
    }

    func clearBanners() {
        banners.removeAll()
        detail.setBanners([])
    }

    var bannerIDs: [String] { banners.map(\.id) }

    // MARK: - Sheets the App asks for

    func presentPasswordSheet(for record: HostRecord, completion: @escaping (PasswordSheet.Result?) -> Void) {
        guard let window else { completion(nil); return }
        let sheet = PasswordSheet(hostTitle: record.title, userName: record.userName)
        keep(sheet)
        showWindow(nil)
        sheet.begin(on: window) { [weak self, weak sheet] result in
            if let sheet { self?.release(sheet) }
            completion(result)
        }
    }

    func presentCertificateSheet(_ variant: CertificateSheet.Variant, for record: HostRecord,
                                 completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        let sheet = CertificateSheet(variant: variant, hostTitle: record.title, address: record.address)
        keep(sheet)
        showWindow(nil)
        sheet.begin(on: window) { [weak self, weak sheet] confirmed in
            if let sheet { self?.release(sheet) }
            completion(confirmed)
        }
    }

    private func keep(_ sheet: AnyObject) { openSheets[ObjectIdentifier(sheet)] = sheet }
    private func release(_ sheet: AnyObject) { openSheets[ObjectIdentifier(sheet)] = nil }

    /// The status item's Connect to (and the sign-in banner's Enter Password…): select the host and
    /// press the App's Connect button. Ignored while that button is disabled -- a preflight is
    /// running or a session exists -- so the sidebar never shows a host other than the one being
    /// dialled (gate r1 m-13).
    func connect(to host: HostID) {
        guard let connectButton, connectButton.isEnabled else { return }
        select(host)
        showWindow(nil)
        connectSelectedHost(nil)
    }

    // MARK: - Menu and button actions

    @objc func newHost(_ sender: Any?) {
        presentEditor(mode: .new, presetState: .loaded(nil))
    }

    @objc func editHost(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        let actions = self.actions
        let host = record.id
        Task { [weak self] in
            let read = await KeychainQueue.run { actions.storedPreset(for: host) }
            let state: HostEditorSheet.PresetState
            switch read {
            case .found(let pin): state = .loaded(pin.expected)
            case .missing: state = .loaded(nil)
            case .unavailable: state = .unavailable
            }
            self?.presentEditor(mode: .edit(record), presetState: state)
        }
    }

    @objc func connectSelectedHost(_ sender: Any?) {
        guard selectedRecord != nil, let connectButton, connectButton.isEnabled else { return }
        connectButton.performClick(nil)
    }

    @objc func showHosts(_ sender: Any?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// File ▸ Close Window (⌘W; UI-9): the standard close of this window -- `performClose`, so
    /// the close button's path (`windowShouldClose`, the close animation) is the same as a click
    /// on the red button. The window only orders out; View ▸ Show Hosts brings it back. Enabled
    /// only while this window is key (`validateMenuItem`), so a key remote window or an open
    /// sheet never lets it close the Hosts window behind them.
    @objc func closeKeyWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: - Settings (UI slice ③)

    /// The Settings window, built on first use. It shares this controller's host records and
    /// keychain actions, so Reset All Pins updates the same records the sidebar shows.
    private(set) lazy var settings = SettingsWindowController(actions: actions, store: store)

    /// Macdows ▸ Settings… (⌘,), the status item's Settings… and the toolbar's Settings button.
    @objc func showSettings(_ sender: Any?) {
        settings.show()
    }

    /// UI slice ④: the input-method banner's Learn More -- the Settings window on its Keyboard page.
    /// Named without "Settings" so AppDelegate's source still never names it (slice ③'s S-5 pin).
    func showKeyboardPage() {
        settings.show()
        settings.select(.keyboard)
    }

    @objc func removeHost(_ sender: Any?) {
        guard let record = selectedRecord, record.id != activeHostID, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UIStrings.removeTitle(record.title)
        alert.informativeText = UIStrings.removeBody
        let remove = alert.addButton(withTitle: UIStrings.removeConfirm)
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: UIStrings.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let actions = self.actions
            let store = self.store
            Task { [weak self] in
                if await HostOperations.remove(record.id, actions: actions, store: store) != nil {
                    self?.showError(UIStrings.removeFailed)
                } else {
                    self?.select(nil)
                }
            }
        }
    }

    @objc func showPinnedCertificate(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        let actions = self.actions
        Task { [weak self] in
            let read = await KeychainQueue.run { actions.storedPreset(for: record.id) }
            guard case .found(let pin) = read, let pinned = pin.sha256 else { return }
            self?.presentCertificateSheet(.details(pinned: pinned, pinnedAt: pin.pinnedAt, subject: pin.subject, issuer: pin.issuer),
                                          for: record) { _ in }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case MainMenu.editHostAction?:
            return selectedRecord != nil
        case MainMenu.connectAction?:
            return selectedRecord != nil && (connectButton?.isEnabled ?? false)
        case Self.removeAction?:
            return selectedRecord != nil && selectedHostID != activeHostID
        case MainMenu.closeWindowAction?:
            return window?.isKeyWindow == true
        default:
            return true
        }
    }

    // MARK: - Editor

    private func presentEditor(mode: HostEditorSheet.Mode, presetState: HostEditorSheet.PresetState) {
        guard let window else { return }
        let sheet = HostEditorSheet(mode: mode, presetState: presetState)
        keep(sheet)
        showWindow(nil)
        sheet.begin(on: window) { [weak self, weak sheet] result in
            if let sheet { self?.release(sheet) }
            guard let self, let result else { return }
            let actions = self.actions
            let changes = result.changes
            // Gate r1 m-11: read before the keychain half wipes the typed password.
            let typedPassword = !(changes.newPassword?.isEmpty ?? true)
            let wasRemembering = self.store.record(result.record.id)?.remembersPassword ?? false
            Task { [weak self] in
                let failures = await KeychainQueue.run { actions.applyEditorChanges(changes) }
                guard let self else { return }
                var record = result.record
                record.remembersPassword = HostActions.remembersPassword(
                    remember: changes.remember, typedPassword: typedPassword, wasRemembering: wasRemembering,
                    credentialFailed: failures.credentialStatus != nil
                )
                self.store.upsert(record)
                self.select(record.id)
                if !failures.isEmpty { self.showError(UIStrings.editorKeychainFailed) }
            }
        }
    }

    private func showError(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    // MARK: - Refresh

    private func reloadHosts() {
        if let selected = selectedHostID, store.record(selected) == nil { selectedHostID = nil }
        list.reload(records: store.records, selected: selectedHostID)
        if window?.subtitle.isEmpty ?? true || activeHostID == nil {
            window?.subtitle = UIStrings.hostCount(store.records.count)
        }
        refreshDetail()
    }

    private func refreshDetail() {
        detail.showEmpty(store.records.isEmpty)
        if let record = selectedRecord {
            detail.show(record)
            titleLabel?.stringValue = record.title
        } else {
            titleLabel?.stringValue = store.records.isEmpty ? "" : UIStrings.hosts
        }
        detail.removeButton.isEnabled = selectedRecord != nil && selectedHostID != activeHostID
        detail.editButton.isEnabled = selectedRecord != nil
        list.removeButton.isEnabled = detail.removeButton.isEnabled
    }

    // MARK: - Toolbar

    private static let newHostItem = NSToolbarItem.Identifier("newHost")
    private static let settingsItem = NSToolbarItem.Identifier("settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newHostItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.newHostItem:
            item.label = UIStrings.newHost
            item.toolTip = UIStrings.newHost
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: UIStrings.newHost)
            item.target = self
            item.action = MainMenu.newHostAction
        case Self.settingsItem:
            // UI slice ③: the same action as Settings… in the menus.
            item.label = UIStrings.settings
            item.toolTip = UIStrings.settings
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: UIStrings.settings)
            item.target = self
            item.action = MainMenu.settingsAction
        default:
            return nil
        }
        item.isBordered = true
        return item
    }
}
