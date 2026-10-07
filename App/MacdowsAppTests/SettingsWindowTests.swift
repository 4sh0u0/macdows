import AppKit
import Foundation
import MacdowsCore
import SwiftUI
import Testing

// UI slice ③ commit 2 (UI-1 spec §1 / §3 / §4.6 / §8 ③ / §9 / §10): the Settings window, offline --
// its shape, its three entry points, that every control the model disables is really disabled in
// the rendered page, that the read-only texts match what the code does (reconnect policy, the ⌘
// table), that the overrides row counts without naming, and the Reset All Pins / Export flows run
// through the store doubles. No alert, panel or keychain item is shown or touched.

private func settingsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func settingsSource(_ relative: String) throws -> String {
    try String(contentsOf: settingsRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded.
private func settingsCodeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.components(separatedBy: "//").first ?? "" }
        .joined(separator: " ")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func settingsOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private let settingsDirectory = "App/UI/Settings"

private func settingsFiles() throws -> [(name: String, code: String)] {
    let root = settingsRepoRoot().appendingPathComponent(settingsDirectory)
    return try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }.sorted()
        .map { ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
}

@MainActor
@Suite("UI slice ③ — the Settings window, offline", .serialized)
struct SettingsWindowTests {
    static func controller(store: HostRecordStore = HostRecordStore(fileURL: nil), pins: InMemoryPinStore = InMemoryPinStore(),
                           buffer: DiagnosticLogBuffer = DiagnosticLogBuffer(capacity: 50),
                           environment: [String: String] = [:]) -> SettingsWindowController {
        _ = NSApplication.shared
        return SettingsWindowController(actions: HostActions(credentials: InMemoryCredentialStore(), pins: pins), store: store,
                                        buffer: buffer, environment: environment)
    }

    /// Every NSButton / NSPopUpButton item in `view`'s tree, by its `settings.<key>` identifier.
    static func controls(in view: NSView) -> [String: (enabled: Bool, on: Bool)] {
        var found: [String: (enabled: Bool, on: Bool)] = [:]
        func walk(_ view: NSView) {
            if let popUp = view as? NSPopUpButton {
                for item in popUp.itemArray {
                    if let id = item.identifier?.rawValue {
                        found[id] = (popUp.isEnabled && item.isEnabled, popUp.selectedItem === item)
                    }
                }
            } else if let button = view as? NSButton, let id = button.identifier?.rawValue, id.hasPrefix("settings.") {
                found[id] = (button.isEnabled, button.state == .on)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: - Shape

    @Test("720 × 520, four toolbar tabs General / Keyboard / Display / Advanced, each a SwiftUI page; closing only orders out")
    func windowShape() throws {
        let controller = Self.controller()
        let window = try #require(controller.window)
        controller.show()
        defer { window.orderOut(nil) }
        #expect(window.frame.size == SettingsWindowController.windowSize)
        #expect(SettingsWindowController.windowSize == NSSize(width: 720, height: 520))
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.styleMask.contains(.resizable))
        #expect(controller.tabs.tabStyle == .toolbar)
        #expect(controller.tabs.tabViewItems.map { $0.identifier as? String } == ["general", "keyboard", "display", "advanced"])
        #expect(controller.tabs.tabViewItems.map(\.label) == [SettingsStrings.tabGeneral, SettingsStrings.tabKeyboard,
                                                               SettingsStrings.tabDisplay, SettingsStrings.tabAdvanced])
        #expect(controller.tabs.tabViewItems.allSatisfy { $0.viewController is NSHostingController<SettingsGeneralPage>
            || $0.viewController is NSHostingController<SettingsKeyboardPage>
            || $0.viewController is NSHostingController<SettingsDisplayPage>
            || $0.viewController is NSHostingController<SettingsAdvancedPage> })
        for page in SettingsWindowController.Page.allCases {
            controller.select(page)
            #expect(controller.selectedPage == page)
            #expect(window.title == controller.tabs.tabViewItems[controller.tabs.selectedTabViewItemIndex].label, "title follows the tab")
            #expect(window.frame.size == SettingsWindowController.windowSize, "\(page) keeps the size")
        }
        window.close()
        #expect(!window.isVisible)
        controller.show()
        #expect(window.isVisible)
    }

    // MARK: - Entry points

    @Test("Settings… (⌘,), the status item's Settings… and the toolbar button all reach showSettings: on the Hosts window's controller")
    func entryPoints() throws {
        _ = NSApplication.shared
        let hosts = MainWindowController(store: HostRecordStore(fileURL: nil),
                                         actions: HostActions(credentials: InMemoryCredentialStore(), pins: InMemoryPinStore()))
        defer { hosts.window?.orderOut(nil); hosts.settings.window?.orderOut(nil) }
        #expect(MainWindowController.instancesRespond(to: MainMenu.settingsAction))
        #expect(MainMenu.settingsAction == NSSelectorFromString("showSettings:"))

        let menus = MainMenu.build()
        let item = try #require(MainMenu.settingsItem(in: menus.mainMenu))
        #expect(item.target == nil, "built nil-target (T-1)")
        #expect(item.keyEquivalent == LocalKeyEquivalent.settings.character)
        #expect(item.keyEquivalentModifierMask == LocalKeyEquivalent.settings.modifiers, "⌘, stays one of the four Mac keys")
        #expect(MainMenu.bindShowHosts(in: menus.mainMenu, to: hosts))
        #expect(item.target === hosts, "bound with Show Hosts: reachable while no Macdows window is key")
        #expect(hosts.validateMenuItem(item))

        let settingsWindow = try #require(hosts.settings.window)
        #expect(!settingsWindow.isVisible)
        #expect(MainMenu.performSettings(in: menus.mainMenu, from: nil), "the status item's path: the main menu item's action and target")
        #expect(settingsWindow.isVisible)
        settingsWindow.close()

        NSApp.sendAction(MainMenu.settingsAction, to: item.target, from: item)
        #expect(settingsWindow.isVisible, "the menu item itself")
        settingsWindow.close()

        let status = StatusItemController()
        #expect(status.settingsItem.target === status && status.settingsItem.action == NSSelectorFromString("openSettings:"))
        let statusSource = settingsCodeOnly(try settingsSource("App/Macdows/StatusMenu/StatusItemController.swift"))
        #expect(statusSource.contains("@objc private func openSettings(_ sender: Any?) { NSApp.activate(ignoringOtherApps: true) MainMenu.performSettings(in: NSApp.mainMenu, from: sender) }"))

        let toolbarItem = try #require(hosts.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings" })
        #expect(toolbarItem.action == MainMenu.settingsAction && toolbarItem.target === hosts)
        #expect(!MainMenu.performSettings(in: NSMenu(title: "empty"), from: nil))
    }

    @Test("S-5 and the menu structure: AppDelegate is untouched by Settings, and Settings… is still the third item of the Macdows menu")
    func appDelegateUntouched() throws {
        let delegate = settingsCodeOnly(try settingsSource("App/Macdows/AppDelegate.swift"))
        #expect(settingsOccurrences(of: "@objc", in: delegate) == 2)
        #expect(settingsOccurrences(of: "Settings", in: delegate) == 0)
        let appMenu = try #require(MainMenu.build().mainMenu.items.first?.submenu)
        #expect(appMenu.items[2].action == MainMenu.settingsAction)
    }

    // MARK: - Only existing capabilities; everything else disabled

    @Test("the model: only today's behaviour is enabled, it is the selected one, and every disabled choice says Coming later")
    func modelEnablesOnlyTodaysBehaviour() {
        let groups: [[SettingsModel.Choice]] = [SettingsModel.commandKey, SettingsModel.scale, SettingsModel.logDetail]
        for group in groups {
            #expect(group.filter(\.isEnabled).count == 1)
            #expect(group.filter(\.isSelected).map(\.id) == group.filter(\.isEnabled).map(\.id))
        }
        let all = groups.flatMap { $0 } + [SettingsModel.launchOpensHosts, SettingsModel.followDisplays, SettingsModel.restoreWindows] + SettingsModel.notifications
        for choice in all where !choice.isEnabled {
            #expect(choice.showsComingLater, "\(choice.id)")
        }
        let disabled = SettingsModel.disabledChoices().mapValues { $0.map(\.id) }
        #expect(disabled["general"] == ["g_launch_v", "g_n1", "g_n2", "g_n3"])
        #expect(disabled["keyboard"] == ["k_cmd_win", "k_cmd_ctrl"])
        #expect(disabled["display"] == ["100%", "200%", "d_follow", "d_restore"])
        #expect(disabled["advanced"] == ["a_log_det"])
        #expect(SettingsModel.launchOpensHosts.isSelected, "the Hosts window does open at launch today")
    }

    @Test("rendered: each page's system controls are enabled exactly as the model says, with the model's state")
    func renderedControlsMatchTheModel() throws {
        let controller = Self.controller()
        let window = try #require(controller.window)
        controller.show()
        defer { window.orderOut(nil) }
        let expected: [SettingsWindowController.Page: [SettingsModel.Choice]] = [
            .general: [SettingsModel.launchOpensHosts] + SettingsModel.notifications,
            .keyboard: SettingsModel.commandKey,
            .display: SettingsModel.scale + [SettingsModel.followDisplays, SettingsModel.restoreWindows],
            .advanced: SettingsModel.logDetail,
        ]
        for page in SettingsWindowController.Page.allCases {
            controller.select(page)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let view = try #require(controller.tabs.tabViewItems[controller.tabs.selectedTabViewItemIndex].viewController?.view)
            let found = Self.controls(in: view)
            let choices = try #require(expected[page])
            #expect(found.count == choices.count, "\(page): \(found.keys.sorted())")
            for choice in choices {
                let control = try #require(found["settings.\(choice.id)"], "\(page): \(choice.id)")
                #expect(control.enabled == choice.isEnabled, "\(choice.id) enabled")
                #expect(control.on == choice.isSelected, "\(choice.id) state")
            }
        }
    }

    @Test("source: every model control is built with .disabled from the model and a Coming later label; nothing is stored")
    func pagesApplyTheModel() throws {
        let pages = settingsCodeOnly(try settingsSource("\(settingsDirectory)/SettingsPages.swift"))
        #expect(pages.contains("SettingsChoiceButton(kind: kind, choice: choice) .fixedSize() .disabled(!choice.isEnabled) if choice.showsComingLater { ComingLaterLabel() }"))
        #expect(pages.contains("button.isEnabled = choice.isEnabled && environmentEnabled"))
        #expect(pages.contains("button.lastItem?.isEnabled = choice.isEnabled"))
        #expect(settingsOccurrences(of: "Toggle(", in: pages) == 1, "a_include is the one live control")
        #expect(pages.contains("Toggle(isOn: $state.includeAccountAndKeyWitness)"))
        for file in try settingsFiles() {
            let code = settingsCodeOnly(file.code)
            for forbidden in ["UserDefaults", "@AppStorage", "@SceneStorage", "NSUserDefaults"] {
                #expect(!code.contains(forbidden), "\(file.name): \(forbidden) -- the window keeps no settings")
            }
        }
    }

    // MARK: - Read-only texts match the code

    @Test("General: 'Reconnect up to 4 times' and the 1 / 2 / 4 / 8 s waits are ReconnectPolicy's")
    func reconnectTextMatchesThePolicy() throws {
        #expect(SettingsModel.reconnectsAfterTheFirstAttempt == 4)
        #expect(SettingsStrings.reconnectPolicy.contains("\(SettingsModel.reconnectsAfterTheFirstAttempt)"))
        let waits = try (0..<SettingsModel.reconnectsAfterTheFirstAttempt).map { try ReconnectPolicy.decision(afterFailedAttempt: $0) }
        #expect(waits == [.retry(after: .seconds(1)), .retry(after: .seconds(2)), .retry(after: .seconds(4)), .retry(after: .seconds(8))])
        #expect(try ReconnectPolicy.decision(afterFailedAttempt: 4) == .giveUp(reason: .attemptsExhausted))
        #expect(SettingsStrings.reconnectPolicyNote.contains("1, 2, 4 and 8 seconds"))
    }

    @Test("Keyboard: the ⌘ table's letter row is exactly CommandKeyMapper's Ctrl set; ⇧⌘Z, ⌘W, ⌘Space / ⌘Tab and the rest as the mapper does")
    func keyboardTableMatchesTheMapper() {
        func press(_ character: String, shift: Bool = false) -> CommandKeyMapperOutput {
            let mapper = CommandKeyMapper()
            _ = mapper.commandChanged(down: true)
            if shift { _ = mapper.shiftChanged(down: true) }
            return mapper.key(down: true, macKeyCode: 0, charactersIgnoringModifiers: character)
        }
        let mapped = Set(SettingsModel.mappedLetters.map { $0.lowercased() })
        for letter in "abcdefghijklmnopqrstuvwxyz".map(String.init) {
            let output = press(letter)
            if mapped.contains(letter) {
                guard case .wire(let events) = output else { Issue.record("\(letter): \(output)"); continue }
                #expect(events.first == .modifierKey(.control, down: true), "⌘\(letter) -> Ctrl + the same letter")
            } else if letter == "w" {
                #expect(output == .closeRequest)
            } else if letter == "q" {
                #expect(output == .wire([]), "⌘Q is not sent (the Mac keeps it)")
            } else {
                guard case .wire(let events) = output else { Issue.record("\(letter): \(output)"); continue }
                #expect(events.first == .modifierKey(.command, down: true), "⌘\(letter) -> Windows key + \(letter)")
            }
        }
        guard case .wire(let redo) = press("z", shift: true) else { Issue.record("⇧⌘Z"); return }
        #expect(redo.contains(.keyDown(macKeyCode: 0x10)), "⇧⌘Z -> Ctrl + Y")
        #expect(press(" ") == .wire([]) && press("\t") == .wire([]), "⌘Space / ⌘Tab never reach Windows")

        let rows = SettingsModel.keyRows()
        #expect(rows.map(\.mac) == ["⌘ + A C F N O P S V X Z", "⇧⌘Z", "⌘W", "⌘Q, ⌘H, ⌥⌘H, ⌘,", "⌘Space, ⌘Tab", SettingsStrings.rowOtherKeys])
        #expect(rows[3].mac == LocalKeyEquivalent.reserved.map(SettingsModel.symbols).joined(separator: ", "), "the kept row is adr/0022 D-3's set")
        #expect(rows.map(\.windows) == [SettingsStrings.rowLetters, SettingsStrings.rowRedo, SettingsStrings.rowClose,
                                        SettingsStrings.rowKept, SettingsStrings.rowMacOS, SettingsStrings.rowOther])
    }

    // MARK: - Launch overrides (§10 ②)

    @Test("the overrides row counts the seven known knobs by presence and never shows a name or a value")
    func overridesCountOnly() throws {
        var environment: [String: String] = [:]
        for (index, name) in SettingsModel.knownOverrideNames.enumerated() {
            environment[name] = "fixture-value-\(index)"
        }
        environment[ShellAutolaunch.autoconnectKey + "_UNKNOWN"] = "fixture-unknown"
        environment["PATH"] = "/usr/bin"
        #expect(SettingsModel.knownOverrideNames.count == 7 && Set(SettingsModel.knownOverrideNames).count == 7)
        #expect(SettingsModel.activeOverrideCount(in: environment) == 7, "only the seven, and an empty value still counts")
        #expect(SettingsModel.activeOverrideCount(in: [:]) == 0)
        #expect(SettingsModel.activeOverrideCount(in: [ShellAutolaunch.keyWitnessKey: "", ShellAutolaunch.quitAfterKey: "5"]) == 2)
        let text = SettingsModel.overridesText(count: SettingsModel.activeOverrideCount(in: environment))
        #expect(text == SettingsStrings.overridesActive(7))
        #expect(SettingsModel.overridesText(count: 0) == SettingsStrings.overridesNone)
        for (name, value) in environment {
            #expect(!text.contains(name) && !text.contains(value), "the row never names \(name.count)-character keys or shows values")
        }
        let controller = Self.controller(environment: environment)
        #expect(controller.advanced.overrideCount == 7)

        for file in try settingsFiles() {
            let code = settingsCodeOnly(file.code)
            #expect(!code.contains("MACDOWS" + "_"), "\(file.name) spells a knob name")
            for writer in ["setenv(", "unsetenv(", "putenv(", "environment[", "ProcessInfo.processInfo.environment"] where code.contains(writer) {
                let allowed = (file.name == "SettingsModel.swift" && writer == "environment[" && settingsOccurrences(of: "environment[", in: code) == 1
                               && code.contains("knownOverrideNames.filter { environment[$0] != nil }.count"))
                    || (file.name == "SettingsWindowController.swift" && writer == "ProcessInfo.processInfo.environment"
                        && settingsOccurrences(of: writer, in: code) == 1)
                #expect(allowed, "\(file.name): \(writer)")
            }
        }
    }

    @Test("General has exactly three rows (At launch / If the connection drops / Notifications); no 'disconnect when the last window closes' row (UI-1 v0.2 §10 (7))")
    func generalHasNoLastWindowRow() throws {
        let pages = settingsCodeOnly(try settingsSource("\(settingsDirectory)/SettingsPages.swift"))
        let start = try #require(pages.range(of: "struct SettingsGeneralPage"))
        let end = try #require(pages.range(of: "struct SettingsKeyboardPage"))
        let general = String(pages[start.lowerBound..<end.lowerBound])
        #expect(settingsOccurrences(of: "SettingsRow(", in: general) == 3)
        #expect(general.contains("SettingsRow(SettingsStrings.launch)") && general.contains("SettingsRow(SettingsStrings.connectionDrops)")
                && general.contains("SettingsRow(SettingsStrings.notifications)"))
        let catalog = try settingsSource("App/Macdows/Localizable.xcstrings")
        let general_keys = ["g_launch", "g_launch_v", "g_drop", "g_drop_n", "g_drop_v", "g_notif", "g_n1", "g_n2", "g_n3"]
        let found = try Regex(#""(g_[a-z0-9_]+)" : \{"#)
        let names = Set(catalog.matches(of: found).compactMap { $0.output[1].substring.map(String.init) })
        #expect(names == Set(general_keys), "no g_last / g_last_v key in the catalog")
        for file in try settingsFiles() {
            let code = settingsCodeOnly(file.code)
            #expect(!code.contains("g_last"), "\(file.name)")
            #expect(!code.contains("lastWindow") && !code.contains("LastWindow"), "\(file.name)")
        }
    }

    // MARK: - Reset All Pins… (ADR-0024 D-6)

    @Test("Reset All Pins: confirmed -> pins cleared (presets kept), records unpinned with a row, the count reported")
    func resetAllPinsFlow() async throws {
        let store = HostRecordStore(fileURL: nil)
        let first = HostRecord(displayName: "A", address: "a.example", userName: "u", pinned: true)
        let second = HostRecord(displayName: "B", address: "b.example", userName: "u", pinned: true)
        store.upsert(first)
        store.upsert(second)
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(sha256: TestFingerprints.a, expected: TestFingerprints.b), for: first.id)
        pins.seed(PinRecord(sha256: TestFingerprints.c), for: second.id)
        let controller = Self.controller(store: store, pins: pins)
        var asked = 0
        var reports: [String] = []
        controller.confirmReset = { _, completion in asked += 1; completion(true) }
        controller.report = { _, message in reports.append(message) }

        controller.resetAllPins()
        #expect(controller.advanced.isBusy, "both buttons wait while it runs")
        await controller.pendingWork?.value
        #expect(asked == 1)
        #expect(pins.records[first.id] == PinRecord(expected: TestFingerprints.b), "E-a: the preset is kept")
        #expect(pins.records[second.id] == nil, "an item left empty is deleted")
        #expect(store.records.allSatisfy { !$0.pinned })
        #expect(store.records.allSatisfy { $0.recent.first?.event == .allPinsReset })
        #expect(reports == [SettingsStrings.resetDone(2)])
        #expect(!controller.advanced.isBusy)
    }

    @Test("Reset All Pins: cancelled -> nothing touched; a store failure -> the failure is reported and the records stay pinned")
    func resetAllPinsCancelAndFailure() async throws {
        let store = HostRecordStore(fileURL: nil)
        let record = HostRecord(displayName: "A", address: "a.example", userName: "u", pinned: true)
        store.upsert(record)
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(sha256: TestFingerprints.a), for: record.id)
        let controller = Self.controller(store: store, pins: pins)
        var reports: [String] = []
        controller.report = { _, message in reports.append(message) }
        controller.confirmReset = { _, completion in completion(false) }
        controller.resetAllPins()
        #expect(controller.pendingWork == nil)
        #expect(pins.records[record.id]?.sha256 == TestFingerprints.a && store.record(record.id)?.pinned == true)
        #expect(pins.writeCount == 0 && pins.deleteCount == 0)

        pins.deleteFailure = -25299
        controller.confirmReset = { _, completion in completion(true) }
        controller.resetAllPins()
        await controller.pendingWork?.value
        #expect(reports == [SettingsStrings.resetFailed])
        #expect(store.record(record.id)?.pinned == true, "noteAllPinsReset only after the keychain half succeeded")
        #expect(!controller.advanced.isBusy)
    }

    @Test("Reset All Pins: a failure part-way -> the hosts already cleared are unpinned, the others stay pinned (gate r1 m-3)")
    func resetAllPinsPartialFailure() async throws {
        let store = HostRecordStore(fileURL: nil)
        var records = [HostRecord(displayName: "A", address: "a.example", userName: "u", pinned: true),
                       HostRecord(displayName: "B", address: "b.example", userName: "u", pinned: true)]
        // The pin store walks hosts in account order: the first is cleared, the second cannot be read.
        records.sort { $0.id.keychainAccount < $1.id.keychainAccount }
        let good = records[0], stuck = records[1]
        records.forEach { store.upsert($0) }
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(sha256: TestFingerprints.a), for: good.id)
        pins.seed(PinRecord(sha256: TestFingerprints.c), for: stuck.id)
        pins.unreadable = [stuck.id]
        let controller = Self.controller(store: store, pins: pins)
        var reports: [String] = []
        controller.report = { _, message in reports.append(message) }
        controller.confirmReset = { _, completion in completion(true) }
        controller.resetAllPins()
        await controller.pendingWork?.value
        #expect(pins.records[good.id]?.sha256 == nil, "the readable host's pin is gone")
        #expect(pins.records[stuck.id]?.sha256 == TestFingerprints.c, "the unreadable host's pin is untouched")
        #expect(store.record(good.id)?.pinned == false, "cleared host: record unpinned")
        #expect(store.record(good.id)?.recent.first?.event == .allPinsReset)
        #expect(store.record(stuck.id)?.pinned == true, "uncleared host: record still pinned")
        #expect(store.record(stuck.id)?.recent.isEmpty == true)
        #expect(reports == [SettingsStrings.resetPartial(1)], "cleared N, then the failure")
        #expect(!controller.advanced.isBusy)
    }

    @Test("the Reset alert: Cancel first (Return, with Escape derived by AppKit), Reset second and destructive, no hand-set key equivalent (gate r1 I-1)")
    func resetAlertShape() throws {
        let alert = SettingsWindowController.makeResetAlert()
        #expect(alert.alertStyle == .warning)
        #expect(alert.buttons.map(\.title) == [UIStrings.cancel, SettingsStrings.resetConfirm])
        // AppKit gives the first button Return (and Escape from its title) only when the sheet is
        // shown, so that half is checked in the .app probe; offline: nothing is set by hand.
        #expect(alert.buttons[1].keyEquivalent.isEmpty, "Reset has no key")
        #expect(alert.buttons[1].hasDestructiveAction)
        let code = settingsCodeOnly(try settingsSource("\(settingsDirectory)/SettingsWindowController.swift"))
        #expect(!code.contains("keyEquivalent"), "an explicit key equivalent replaces the Escape AppKit derives from the Cancel title")
        #expect(code.contains("completion(response == .alertSecondButtonReturn)"))
        #expect(!code.contains(".alertFirstButtonReturn"), "the first button is Cancel")
        #expect(code.contains("await HostOperations.resetAllPins(actions: actions, store: store)"), "only calls the existing operation")
        for file in try settingsFiles() {
            let other = settingsCodeOnly(file.code)
            #expect(!other.contains("SecItem") && !other.contains("KeychainItems") && !other.contains(".delete(for:"), "\(file.name) touches the keychain itself")
        }
    }

    // MARK: - Export Diagnostics… (ADR-0024 D-8)

    @Test("Export: the chosen file gets the filtered buffer, the result names the file only, and a_include is cleared afterwards")
    func exportFlow() throws {
        let buffer = DiagnosticLogBuffer(capacity: 20)
        buffer.append(.init(source: .freerdp, level: .info, tag: DiagnosticExportFilter.bridgeTag, message: "[key-witness] seq=1 kind=scancode flags=0x0000 code=0x1e rc=1"))
        buffer.append(.init(source: .app, level: .info, tag: "Reconnect", message: "[reconnect] attempt=1 delay-ms=1000 state=waiting cause="))
        buffer.append(.init(source: .app, level: .info, tag: "Autolaunch", message: "[autolaunch] press=connect"))
        let controller = Self.controller(buffer: buffer)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macdows-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("export.txt")
        var reports: [String] = []
        controller.report = { _, message in reports.append(message) }
        controller.chooseExportURL = { _, completion in completion(url) }

        controller.exportDiagnostics()
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[reconnect] attempt=1") && !text.contains("[key-witness]"), "default: key-witness left out")
        #expect(text.hasSuffix("# 2 lines not exported\n"))
        #expect(controller.advanced.exportResult == SettingsStrings.exportDone(fileName: "export.txt", linesLeftOut: 2))
        #expect(!(controller.advanced.exportResult ?? "").contains(folder.path), "the result never shows the folder")

        controller.advanced.includeAccountAndKeyWitness = true
        controller.exportDiagnostics()
        text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[key-witness] seq=1"), "this export includes them")
        #expect(!controller.advanced.includeAccountAndKeyWitness, "a_include applies to one export only")

        controller.advanced.includeAccountAndKeyWitness = true
        controller.chooseExportURL = { _, completion in completion(nil) }
        controller.exportDiagnostics()
        #expect(controller.advanced.includeAccountAndKeyWitness, "a cancelled panel exports nothing and keeps the choice")

        controller.chooseExportURL = { _, completion in completion(folder.appendingPathComponent("missing/export.txt")) }
        controller.exportDiagnostics()
        #expect(reports == [SettingsStrings.exportFailed])
        #expect(!controller.advanced.includeAccountAndKeyWitness)
        #expect(reports.isEmpty == false && SettingsWindowController.defaultExportName(at: Date(timeIntervalSince1970: 0)).hasSuffix(".txt"))
    }

    // MARK: - §9 / §8: no appearance or language switch, glass only behind #available

    @Test("§9: no in-app appearance, theme or language switch; §3: the form body has no material or glass of its own")
    func noAppearanceOrLanguageSwitch() throws {
        for file in try settingsFiles() {
            let code = settingsCodeOnly(file.code)
            for forbidden in ["preferredColorScheme", "NSAppearance", ".appearance =", "AppleLanguages", ".environment(\\.locale", "colorScheme",
                              "Material", "NSVisualEffectView", "background(.ultra", "background(.regular"] {
                #expect(!code.contains(forbidden), "\(file.name): \(forbidden)")
            }
        }
    }

    @Test("§8: the Settings window's one glass call lives in GlassStyle.swift behind #available(macOS 26, *) with a bordered fallback")
    func glassOnlyBehindAvailable() throws {
        let glass = settingsCodeOnly(try settingsSource("App/UI/Style/GlassStyle.swift"))
        #expect(glass.contains("func settingsSecondaryButtonStyle() -> some View { if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) } }"))
        let pages = settingsCodeOnly(try settingsSource("\(settingsDirectory)/SettingsPages.swift"))
        #expect(settingsOccurrences(of: ".settingsSecondaryButtonStyle()", in: pages) == 2, "Export Diagnostics… and Reset All Pins…")
        let project = try settingsSource("App/project.yml")
        #expect(project.contains("MACOSX_DEPLOYMENT_TARGET: \"14.0\""))
    }

    // MARK: - Strings

    @Test("every Settings string key is in the String Catalog in en, zh-Hans and ja; the formats keep their placeholders")
    func stringsAreInTheCatalog() throws {
        let data = try Data(contentsOf: settingsRepoRoot().appendingPathComponent("App/Macdows/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let code = try settingsSource("\(settingsDirectory)/SettingsStrings.swift")
        let keys = try Regex(#"(?:localized: |forKey: )"([a-z0-9_]+)""#)
        var found: [String] = []
        for match in code.matches(of: keys) {
            if let key = match.output[1].substring { found.append(String(key)) }
        }
        #expect(found.count == 67)
        func value(_ key: String, _ language: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        for key in found {
            for language in ["en", "zh-Hans", "ja"] {
                #expect(!(value(key, language) ?? "").isEmpty, "\(key) \(language)")
            }
        }
        for language in ["en", "zh-Hans", "ja"] {
            #expect(value("a_ov_active", language)?.hasPrefix("%lld") == true)
            #expect(value("a_reset_done", language)?.contains("%lld") == true)
            #expect(value("a_export_done", language)?.contains("%1$@") == true && value("a_export_done", language)?.contains("%2$lld") == true)
        }
    }
}
