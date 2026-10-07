import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// UI slice ③ (UI-1 spec §1 / §3 / §8 ③): the Settings window -- an AppKit window whose content is
/// an `NSTabViewController` with toolbar tabs (General / Keyboard / Display / Advanced; the system
/// toolbar draws them, in glass on 26) and one SwiftUI page per tab (`SettingsPages.swift`). The
/// App stays an AppKit app: SwiftUI is used for these pages only.
///
/// Opened by Settings… (⌘,) in the Macdows menu, by the status item's Settings… and by the Hosts
/// window's toolbar button -- all three reach `MainWindowController.showSettings(_:)`, which owns
/// this controller (it holds the host records and the keychain actions Reset All Pins needs).
/// Closing only orders the window out; File ▸ Close Window (⌘W, `MainMenu.closeWindowAction`)
/// closes it while it is key (UI-9), and ⌘, opens it again.
///
/// The window changes no setting (there are none to change today, see `SettingsModel`). Its two
/// actions use existing capabilities only:
///  - Reset All Pins… (ADR-0024 D-6, UI-1 spec §5.3): a confirmation alert, then
///    `HostOperations.resetAllPins` -- the pin store's `resetAllPins` off the main thread, then
///    `HostRecordStore.noteAllPinsReset` -- then the result.
///  - Export Diagnostics… (ADR-0024 D-8, UI-1 spec §5.5): a save panel, then `DiagnosticExport`
///    over the diagnostics ring buffer with this export's `a_include` choice, which is then cleared.
/// The alert and panel steps are closures so the flows run offline in tests.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// UI-1 spec §3: 720 × 520.
    static let windowSize = NSSize(width: 720, height: 520)

    enum Page: String, CaseIterable {
        case general, keyboard, display, advanced
    }

    let tabs = SettingsTabViewController()
    let advanced: SettingsAdvancedState
    private let actions: HostActions
    private let store: HostRecordStore
    private let buffer: DiagnosticLogBuffer

    /// Asks before Reset All Pins; calls back with true to go ahead. Default: an `NSAlert` sheet.
    var confirmReset: @MainActor (NSWindow, @escaping (Bool) -> Void) -> Void = SettingsWindowController.confirmResetAlert
    /// Asks where to save the export; nil = cancelled. Default: an `NSSavePanel` sheet.
    var chooseExportURL: @MainActor (NSWindow, @escaping (URL?) -> Void) -> Void = SettingsWindowController.savePanel
    /// Shows a one-line result. Default: an informational `NSAlert` sheet.
    var report: @MainActor (NSWindow, String) -> Void = SettingsWindowController.reportAlert
    /// The work the last action started (tests await it).
    private(set) var pendingWork: Task<Void, Never>?

    init(actions: HostActions, store: HostRecordStore, buffer: DiagnosticLogBuffer = .shared,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         startPanel: StartPanelPreferences = .shared) {
        self.actions = actions
        self.store = store
        self.buffer = buffer
        advanced = SettingsAdvancedState(overrideCount: SettingsModel.activeOverrideCount(in: environment))

        tabs.tabStyle = .toolbar
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.setAccessibilityLabel(SettingsStrings.windowLabel)
        super.init(window: window)

        addPage(.general, title: SettingsStrings.tabGeneral, symbol: "gearshape", view: SettingsGeneralPage(startPanel: startPanel))
        addPage(.keyboard, title: SettingsStrings.tabKeyboard, symbol: "keyboard", view: SettingsKeyboardPage())
        addPage(.display, title: SettingsStrings.tabDisplay, symbol: "display", view: SettingsDisplayPage())
        addPage(.advanced, title: SettingsStrings.tabAdvanced, symbol: "gearshape.2", view: SettingsAdvancedPage(state: advanced))
        window.contentViewController = tabs
        window.title = SettingsStrings.tabGeneral
        window.setContentSize(contentSize(for: window))
        tabs.tabView.setAccessibilityLabel(SettingsStrings.tabsLabel)
        window.delegate = self
        window.center()

        advanced.onExport = { [weak self] in self?.exportDiagnostics() }
        advanced.onResetPins = { [weak self] in self?.resetAllPins() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func addPage<Content: View>(_ page: Page, title: String, symbol: String, view: Content) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.identifier = page.rawValue
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    /// The content size that makes the whole window `windowSize` with the tab toolbar shown.
    private func contentSize(for window: NSWindow) -> NSSize {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.windowSize))
        let chrome = frame.height - Self.windowSize.height
        let toolbar = window.frame.height - window.contentLayoutRect.height - chrome
        let size = NSSize(width: Self.windowSize.width, height: Self.windowSize.height - chrome - max(0, toolbar))
        for item in tabs.tabViewItems {
            item.viewController?.preferredContentSize = size
        }
        return size
    }

    /// Shows the window and makes it key (all three entry points end here; the status item's path
    /// activates the App first).
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// File ▸ Close Window (⌘W; UI-9): the standard close of this window (`performClose`, the red
    /// button's path). Enabled only while this window is key, so it never closes Settings from
    /// behind a key remote window or the Reset alert's sheet.
    @objc func closeKeyWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == MainMenu.closeWindowAction else { return true }
        return window?.isKeyWindow == true
    }

    func select(_ page: Page) {
        if let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == page.rawValue }) {
            tabs.selectedTabViewItemIndex = index
        }
    }

    var selectedPage: Page? {
        let index = tabs.selectedTabViewItemIndex
        guard tabs.tabViewItems.indices.contains(index) else { return nil }
        return (tabs.tabViewItems[index].identifier as? String).flatMap(Page.init(rawValue:))
    }

    // MARK: - Reset All Pins… (ADR-0024 D-6)

    func resetAllPins() {
        guard let window, !advanced.isBusy else { return }
        confirmReset(window) { [weak self] confirmed in
            guard confirmed, let self else { return }
            advanced.isBusy = true
            let actions = self.actions
            let store = self.store
            pendingWork = Task { [weak self] in
                let outcome = await HostOperations.resetAllPins(actions: actions, store: store)
                let message: String
                if !outcome.failed {
                    message = SettingsStrings.resetDone(outcome.cleared.count)
                } else if outcome.cleared.isEmpty {
                    message = SettingsStrings.resetFailed
                } else {
                    message = SettingsStrings.resetPartial(outcome.cleared.count)
                }
                guard let self else { return }
                advanced.isBusy = false
                if let window = self.window { report(window, message) }
            }
        }
    }

    /// The Reset warning, not yet shown. Cancel is the default button (Return); Reset has no key.
    static func makeResetAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SettingsStrings.resetTitle
        alert.informativeText = SettingsStrings.resetBody
        // AppKit gives a button titled Cancel the Escape key even when it is the first button, so
        // left alone this alert has no default button and Return only beeps (finding F-2). Cancel
        // takes Return by hand; that replaces the derived Escape, which `AlertKeys.cancelOnEscape`
        // restores while the alert is shown. Reset never gets a key equivalent.
        let cancel = alert.addButton(withTitle: UIStrings.cancel)
        cancel.keyEquivalent = "\r"
        let reset = alert.addButton(withTitle: SettingsStrings.resetConfirm)
        reset.hasDestructiveAction = true
        return alert
    }

    private static func confirmResetAlert(_ window: NSWindow, _ completion: @escaping (Bool) -> Void) {
        let alert = makeResetAlert()
        let escape = AlertKeys.cancelOnEscape(alert, cancel: alert.buttons[0])
        alert.beginSheetModal(for: window) { response in
            if let escape { NSEvent.removeMonitor(escape) }
            completion(response == .alertSecondButtonReturn)
        }
    }

    private static func reportAlert(_ window: NSWindow, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.addButton(withTitle: UIStrings.done)
        alert.beginSheetModal(for: window)
    }

    // MARK: - Export Diagnostics… (ADR-0024 D-8)

    func exportDiagnostics() {
        guard let window, !advanced.isBusy else { return }
        chooseExportURL(window) { [weak self] url in
            guard let self, let url else { return }
            let include = advanced.includeAccountAndKeyWitness
            let output = DiagnosticExport.render(buffer, includeAccountAndKeyWitness: include)
            do {
                try DiagnosticExport.write(output, to: url)
                advanced.exportResult = SettingsStrings.exportDone(fileName: url.lastPathComponent, linesLeftOut: output.withheldCount)
            } catch {
                advanced.exportResult = nil
                if let window = self.window { report(window, SettingsStrings.exportFailed) }
            }
            // `a_include` applies to this export only.
            advanced.includeAccountAndKeyWitness = false
        }
    }

    /// `Macdows Diagnostics 2026-10-07 120301.txt`.
    static func defaultExportName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Macdows Diagnostics \(formatter.string(from: date)).txt"
    }

    private static func savePanel(_ window: NSWindow, _ completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName()
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

/// The Settings window's tab controller: toolbar tabs, and the window title follows the selected
/// tab's label (as the artboards' title bar shows it).
@MainActor
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let label = tabViewItem?.label {
            view.window?.title = label
        }
    }
}
