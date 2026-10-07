import AppKit
import MacdowsCore
import Testing

// UI slice ① (UI-1 spec §5.1 / §5.2): the three-state certificate sheet's gating, the Password
// sheet's defaults and the Host Editor's defaults and validation, built offline (no sheet is begun).

@MainActor
@Suite("UI slice ① — Certificate sheet (UI-1 §5.2)")
struct CertificateSheetTests {
    @Test("first use: Trust and Pin is the default button and stays disabled until cf_check is ticked; Esc is Cancel")
    func firstUse() throws {
        let sheet = CertificateSheet(variant: .firstUse(presented: TestFingerprints.a, subject: "CN=pc", issuer: "CN=pc"),
                                     hostTitle: "Office PC", address: "workstation.example")
        let box = try #require(sheet.checkBox)
        #expect(sheet.confirmButton.title == UIStrings.trust)
        #expect(sheet.confirmButton.keyEquivalent == "\r")
        #expect(!sheet.confirmButton.isEnabled)
        #expect(sheet.cancelButton?.keyEquivalent == "\u{1b}")
        box.performClick(nil)
        #expect(sheet.confirmButton.isEnabled)
        box.performClick(nil)
        #expect(!sheet.confirmButton.isEnabled)
        #expect(sheet.window.onCancel != nil)
    }

    @Test("changed: Cancel is the default button (Return cancels); Replace has no key equivalent and needs cc_check")
    func changed() throws {
        for (old, source) in [(TestFingerprints.a, CertificateDecision.OldSource.pin), (TestFingerprints.a, .preset)] as [(CertificateFingerprint?, CertificateDecision.OldSource)] + [(nil, .lost)] {
            let sheet = CertificateSheet(variant: .changed(old: old, oldSource: source, presented: TestFingerprints.b, subject: "CN=pc", issuer: "CN=pc"),
                                         hostTitle: "Office PC", address: "workstation.example")
            let cancel = try #require(sheet.cancelButton)
            #expect(cancel.keyEquivalent == "\r")
            #expect(sheet.window.defaultButtonCell === cancel.cell)
            #expect(sheet.confirmButton.title == UIStrings.replace)
            #expect(sheet.confirmButton.keyEquivalent == "")
            #expect(!sheet.confirmButton.isEnabled)
            try #require(sheet.checkBox).performClick(nil)
            #expect(sheet.confirmButton.isEnabled)
            #expect(sheet.window.onCancel != nil, "Esc cancels too")
        }
    }

    @Test("details: read-only, Done only")
    func details() {
        let sheet = CertificateSheet(variant: .details(pinned: TestFingerprints.a, pinnedAt: Date(), subject: nil, issuer: nil),
                                     hostTitle: "Office PC", address: "workstation.example")
        #expect(sheet.checkBox == nil)
        #expect(sheet.cancelButton == nil)
        #expect(sheet.confirmButton.title == UIStrings.done)
        #expect(sheet.confirmButton.isEnabled)
    }
}

@MainActor
@Suite("UI slice ① — Password sheet and Host Editor (UI-1 §5.1)")
struct PasswordAndEditorTests {
    @Test("Password sheet: Remember is off by default and the note says the password is not saved; Connect needs text")
    func passwordDefaults() {
        let sheet = PasswordSheet(hostTitle: "Office PC", userName: "user")
        #expect(sheet.rememberBox.state == .off)
        #expect(sheet.noteLabel.stringValue == UIStrings.passwordNotSaved)
        #expect(!sheet.connectButton.isEnabled)
        sheet.rememberBox.performClick(nil)
        #expect(sheet.noteLabel.stringValue == UIStrings.passwordSaved)
    }

    @Test("Host Editor: Remember is on by default, Touch ID is disabled and off (ADR-0024 D-1′ T-1)")
    func editorDefaults() {
        let sheet = HostEditorSheet(mode: .new, presetState: .loaded(nil))
        #expect(sheet.rememberBox.state == .on)
        #expect(!sheet.touchIDBox.isEnabled)
        #expect(sheet.touchIDBox.state == .off)
        #expect(sheet.passwordField.stringValue.isEmpty)
    }

    @Test("Host Editor, edit mode: the saved password is never filled in; the placeholder says it is saved")
    func editorEditMode() {
        let record = HostRecord(displayName: "Office PC", address: "workstation.example", userName: "user", remembersPassword: true)
        let sheet = HostEditorSheet(mode: .edit(record), presetState: .loaded(TestFingerprints.a))
        #expect(sheet.passwordField.stringValue.isEmpty)
        #expect(sheet.passwordField.placeholderString == UIStrings.editorPasswordPlaceholderEdit)
        #expect(CertificateFingerprint.parse(sheet.presetField.stringValue) == .success(TestFingerprints.a))
        let unreadable = HostEditorSheet(mode: .edit(record), presetState: .unavailable)
        #expect(!unreadable.presetField.isEnabled)
    }

    @Test("Host Editor validation: address required, port range, preset 32 bytes, SHA-1 refused with its own message")
    func validation() {
        typealias E = HostEditorSheet
        #expect(E.validate(address: "  ", port: "", preset: "") == .failure(.addressRequired))
        #expect(E.validate(address: "workstation.example", port: "0", preset: "") == .failure(.portInvalid))
        #expect(E.validate(address: "workstation.example", port: "70000", preset: "") == .failure(.portInvalid))
        #expect(E.validate(address: "workstation.example", port: "", preset: String(repeating: "ab", count: 20)) == .failure(.presetSHA1))
        #expect(E.validate(address: "workstation.example", port: "", preset: "zz") == .failure(.presetInvalid))
        #expect(E.validate(address: " 192.0.2.10 ", port: "", preset: TestFingerprints.a.displayString)
                == .success(.init(address: "192.0.2.10", port: 3389, preset: TestFingerprints.a)))
        #expect(E.message(for: .presetSHA1) == UIStrings.editorFingerprintSHA1)
    }
}

@MainActor
@Suite("UI slice ① — the Hosts window, offline")
struct MainWindowControllerTests {
    static func controller(records: [HostRecord]) -> MainWindowController {
        let store = HostRecordStore(fileURL: nil)
        for record in records { store.upsert(record) }
        return MainWindowController(store: store, actions: HostActions(credentials: InMemoryCredentialStore(), pins: InMemoryPinStore()))
    }

    @Test("the File / View menu selectors are this controller's")
    func respondsToMenuActions() {
        for selector in [MainMenu.newHostAction, MainMenu.editHostAction, MainMenu.connectAction, MainMenu.showHostsAction] {
            #expect(MainWindowController.instancesRespond(to: selector), "\(selector)")
        }
    }

    @Test("ADR-0024 D-9 M-a-1: exactly one record is pre-selected; zero or several leave nothing selected")
    func preselection() {
        let one = HostRecord(displayName: "A", address: "a.example", userName: "u")
        #expect(Self.controller(records: [one]).selectedHostID == one.id)
        #expect(Self.controller(records: []).selectedHostID == nil)
        let two = HostRecord(displayName: "B", address: "b.example", userName: "u")
        #expect(Self.controller(records: [one, two]).selectedHostID == nil)
    }

    @Test("the empty first screen shows with no records, the detail with one")
    func emptyState() {
        let empty = Self.controller(records: [])
        #expect(!empty.detail.emptyView.isHidden)
        #expect(empty.detail.detailStack.isHidden)
        let one = Self.controller(records: [HostRecord(displayName: "A", address: "a.example", userName: "u")])
        #expect(one.detail.emptyView.isHidden)
        #expect(!one.detail.detailStack.isHidden)
    }

    @Test("Connect and Remove… validate against the selection, the Connect button and the active host")
    func validation() {
        let record = HostRecord(displayName: "A", address: "a.example", userName: "u")
        let controller = Self.controller(records: [record])
        let connect = NSButton(title: "Connect", target: nil, action: nil)
        let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
        let title = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
        controller.installSessionControls(NSStackView(views: [title, status, connect, disconnect]), title: title, status: status,
                                          connect: connect, disconnect: disconnect)
        #expect(title.stringValue == "A")
        let connectItem = NSMenuItem(title: "Connect", action: MainMenu.connectAction, keyEquivalent: "")
        let removeItem = NSMenuItem(title: "Remove", action: MainWindowController.removeAction, keyEquivalent: "")
        #expect(controller.validateMenuItem(connectItem))
        connect.isEnabled = false
        #expect(!controller.validateMenuItem(connectItem))
        #expect(controller.validateMenuItem(removeItem))
        controller.activeHostID = record.id
        #expect(!controller.validateMenuItem(removeItem), "the active host cannot be removed")
        #expect(connect.superview != nil && disconnect.superview != nil, "both buttons are laid out")
    }

    @Test("the Disconnect button's enablement is reported as session presence")
    func sessionPresence() {
        let controller = Self.controller(records: [])
        let connect = NSButton(title: "Connect", target: nil, action: nil)
        let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
        disconnect.isEnabled = false
        let title = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
        controller.installSessionControls(NSStackView(views: [title, status, connect, disconnect]), title: title, status: status,
                                          connect: connect, disconnect: disconnect)
        var seen: [Bool] = []
        controller.onSessionPresenceChange = { seen.append($0) }
        disconnect.isEnabled = true
        disconnect.isEnabled = false
        #expect(seen == [true, false])
    }

    @Test("gate r1 I-2: a closed Hosts window comes back through showHosts, and View ▸ Show Hosts targets the controller")
    func showHostsAfterClose() throws {
        _ = NSApplication.shared
        let controller = Self.controller(records: [])
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        #expect(!window.isReleasedWhenClosed, "closing only orders the window out")
        controller.showWindow(nil)
        #expect(window.isVisible)
        window.close()
        #expect(!window.isVisible)
        controller.showHosts(nil)
        #expect(window.isVisible, "showHosts brings the closed window back")
        window.close()

        let menus = MainMenu.build()
        let showHosts = try #require(menus.mainMenu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == MainMenu.showHostsAction })
        #expect(showHosts.target == nil, "built nil-target (T-1)")
        #expect(MainMenu.bindShowHosts(in: menus.mainMenu, to: controller))
        #expect(showHosts.target === controller, "explicit target: reachable while the window is closed")
        #expect(!window.isVisible)
        NSApp.sendAction(MainMenu.showHostsAction, to: showHosts.target, from: showHosts)
        #expect(window.isVisible, "the bound item's action shows the closed window")
        #expect(!MainMenu.bindShowHosts(in: NSMenu(title: "empty"), to: controller))
    }

    @Test("gate r1 m-13: Connect to is ignored while the Connect button is disabled (a preflight or a session), selection untouched")
    func connectToIgnoredWhileBusy() throws {
        _ = NSApplication.shared
        let first = HostRecord(displayName: "A", address: "a.example", userName: "u")
        let second = HostRecord(displayName: "B", address: "b.example", userName: "u")
        let controller = Self.controller(records: [first, second])
        defer { controller.window?.orderOut(nil) }
        let connect = NSButton(title: "Connect", target: nil, action: nil)
        let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
        let title = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
        controller.installSessionControls(NSStackView(views: [title, status, connect, disconnect]), title: title, status: status,
                                          connect: connect, disconnect: disconnect)
        controller.select(first.id)
        connect.isEnabled = false
        controller.connect(to: second.id)
        #expect(controller.selectedHostID == first.id, "the sidebar keeps the host being dialled")
        connect.isEnabled = true
        controller.connect(to: second.id)
        #expect(controller.selectedHostID == second.id)
    }

    @Test("banners stack by id; the same id replaces its banner")
    func banners() {
        let controller = Self.controller(records: [])
        controller.showBanner(.init(id: "cert", title: "t", body: "b", tone: .error, actions: []))
        controller.showBanner(.init(id: "cert", title: "t2", body: "b", tone: .error, actions: []))
        controller.showBanner(.init(id: "pin", title: "t", body: "b", tone: .warning, actions: []))
        #expect(controller.bannerIDs == ["cert", "pin"])
        controller.removeBanner(id: "cert")
        #expect(controller.bannerIDs == ["pin"])
        controller.clearBanners()
        #expect(controller.bannerIDs.isEmpty)
    }
}
