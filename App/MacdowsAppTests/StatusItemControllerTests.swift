import AppKit
import MacdowsCore
import Testing

// adr/0022 D-6 (T1, UI slice ②): the Macdows status item's menu, built offline. `install()` -- the
// one call that touches the system status bar -- is never made here: the operator's menu bar is
// not a test fixture. What it does is pinned as source (⑥ below) and observed on the real machine.

private func statusRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Line comments removed, whitespace folded (the stripping the other source pins use).
private func statusCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func statusOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@MainActor
@Suite("StatusItemController (adr/0022 D-6, UI slice ②)")
struct StatusItemControllerTests {
    private static func visibleTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test("the menu, top to bottom, with no session (UI-1 spec §6.3)")
    func menuWithNoSession() {
        let controller = StatusItemController()
        #expect(Self.visibleTitles(controller.menu) == [
            "Not connected", "---", "Connect to", "Disconnect", "---", "Open Macdows", "Settings…", "---", "Quit Macdows",
        ])
        #expect(controller.detailRow.isHidden)
        #expect(controller.oneSessionItem.isHidden)
        #expect(controller.statusItem == nil, "nothing is put in the menu bar before install()")
        #expect(controller.menu.delegate === controller)
    }

    @Test("Disconnect is MainMenu's Disconnect item -- same action, nil target (adr/0022 D-11 K3-R)")
    func disconnectIsTheSameAction() {
        let controller = StatusItemController()
        let file = MainMenu.disconnectItem()
        #expect(controller.disconnectItem.action == MainMenu.disconnectAction)
        #expect(controller.disconnectItem.target == nil)
        #expect(controller.disconnectItem.title == file.title)
        #expect(controller.disconnectItem.keyEquivalent == file.keyEquivalent)
    }

    @Test("Open Macdows activates the App through this controller; Settings… performs the main menu's Settings… (UI slice ③); Quit is terminate:")
    func otherItems() {
        let controller = StatusItemController()
        #expect(controller.openItem.target === controller)
        #expect(controller.openItem.action == NSSelectorFromString("openMacdows:"))
        #expect(controller.settingsItem.action == NSSelectorFromString("openSettings:"))
        #expect(controller.settingsItem.target === controller)
        #expect(controller.quitItem.action == #selector(NSApplication.terminate(_:)))
        #expect(controller.quitItem.target == nil)
        // UI slice ①: Connect to opens the host-record submenu (StatusItemConnectToTests) and has no
        // action of its own.
        #expect(controller.connectToItem.submenu === controller.connectToMenu)
        #expect(controller.connectToItem.target == nil || controller.connectToItem.target === controller.connectToMenu)
        #expect(controller.statusRow.action == nil && controller.detailRow.action == nil)
    }

    @Test("refresh() re-reads the App: a session shows the one-session line and the connecting row")
    func refreshReadsTheApp() throws {
        let controller = StatusItemController()
        var reading = StatusItemController.SessionReading.noSession
        controller.reading = { reading }
        reading = .init(hasSession: true, state: nil, host: "host.example")
        controller.refresh()
        #expect(controller.statusRow.title == "Connecting…")
        #expect(!controller.oneSessionItem.isHidden)
        #expect(controller.oneSessionItem.title == "One session at a time. Disconnect first.")

        reading = .init(hasSession: true, state: .live, host: "host.example")
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.statusRow.title == "Connected to host.example")
        #expect(controller.detailRow.title.hasPrefix("0 windows · since "))
        #expect(!controller.detailRow.isHidden)
        let since = try #require(controller.liveSince)
        controller.refresh()
        #expect(controller.liveSince == since, "the live-since time is latched, not re-taken on every read")

        reading = .noSession
        controller.bind(nil)
        #expect(controller.statusRow.title == "Not connected")
        #expect(controller.detailRow.isHidden)
        #expect(controller.oneSessionItem.isHidden)
        #expect(controller.liveSince == nil)
    }

    @Test(
        "status rows for each driver state (v1: live / reconnecting / not connected, plus connecting)",
        arguments: [
            (StatusItemController.SessionReading.noSession, StatusItemController.Marker.notConnected, "Not connected", nil),
            (.init(hasSession: true, state: nil, host: "h"), .reconnecting, "Connecting…", nil),
            (.init(hasSession: true, state: .idle, host: "h"), .reconnecting, "Connecting…", nil),
            (.init(hasSession: true, state: .live, host: "h"), .live, "Connected to h", "3 windows · since "),
            (.init(hasSession: true, state: .waiting(attempt: 1, delay: .seconds(2)), host: "h"), .reconnecting, "Reconnecting to h", "Reconnect attempt 2 of 5"),
            (.init(hasSession: true, state: .reconnecting(attempt: 0), host: "h"), .reconnecting, "Reconnecting to h", "Reconnect attempt 1 of 5"),
            (.init(hasSession: true, state: .gaveUp(.policy(.attemptsExhausted)), host: "h"), .notConnected, "Not connected", nil),
            (.init(hasSession: false, state: .live, host: "h"), .notConnected, "Not connected", nil),
        ] as [(StatusItemController.SessionReading, StatusItemController.Marker, String, String?)]
    )
    func statusRows(reading: StatusItemController.SessionReading, marker: StatusItemController.Marker, title: String, detail: String?) {
        let rows = StatusItemController.statusRows(for: reading, windows: 3, liveSince: Date(timeIntervalSince1970: 0))
        #expect(rows.marker == marker)
        #expect(rows.title == title)
        if let detail {
            #expect(rows.detail?.hasPrefix(detail) == true, "\(rows.detail ?? "nil")")
        } else {
            #expect(rows.detail == nil)
        }
        #expect(ReconnectPolicy.maxAttempts == 5, "the table's 'of 5'")
    }

    // MARK: - adr/0023 D-8 ⑥: one status item in the App, none in the tray controller

    /// ⑥. Counted by call shape on comment-stripped code. Every non-test Swift source of the App and
    /// its tools is walked; the one `NSStatusBar.system.statusItem(` is the status item controller's
    /// `install()`, and `TrayStatusController.swift` names the status bar nowhere (adr/0023 D-5 R1).
    @Test("⑥ exactly one NSStatusBar.system.statusItem( in non-test sources, in StatusItemController; TrayStatusController has no NSStatusBar")
    func oneStatusItemInTheApp() throws {
        var hits: [String: Int] = [:]
        var walked = 0
        for directory in ["App", "Tools"] {
            let root = statusRepoRoot().appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = String(url.path.dropFirst(statusRepoRoot().path.count + 1))
                if path.hasPrefix("App/MacdowsAppTests/") || path.contains(".xcodeproj/") { continue }
                walked += 1
                let code = statusCodeOnly(try String(contentsOf: url, encoding: .utf8))
                let count = statusOccurrences(of: "NSStatusBar.system.statusItem(", in: code)
                if count > 0 { hits[path] = count }
                if path == "App/RemoteWindowRendering/TrayStatusController.swift" {
                    #expect(statusOccurrences(of: "NSStatusBar", in: code) == 0)
                    #expect(statusOccurrences(of: "NSStatusItem", in: code) == 0)
                }
            }
        }
        #expect(walked > 20, "the walk found the sources (\(walked))")
        #expect(hits == ["App/Macdows/StatusMenu/StatusItemController.swift": 1], "\(hits)")
        let controller = statusCodeOnly(try String(contentsOf: statusRepoRoot().appendingPathComponent("App/Macdows/StatusMenu/StatusItemController.swift"), encoding: .utf8))
        let install = try #require(controller.range(of: "func install() {"))
        let uninstall = try #require(controller.range(of: "func uninstall() {"))
        let call = try #require(controller.range(of: "NSStatusBar.system.statusItem("))
        #expect(install.upperBound <= call.lowerBound && call.upperBound <= uninstall.lowerBound, "the call is inside install()")
    }

    /// Gate r1 I-3 (UI-4 fold F-3): adr/0023 D-6 P-a's "one writer of this menu's structure", as
    /// source. Comment-stripped: (a) no App source outside `StatusMenu/` reaches the controller's
    /// menu (`statusItemController.menu`, the `.menu.` access form included); (b) inside
    /// `StatusItemController.swift` every `addItem(` / `insertItem(` / `removeItem(` call shape is
    /// in `init`, the one function that builds the menu. The Remote tray section's own edits live in
    /// `StatusItemTraySection.swift`, inside the run it inserted, and are not counted here.
    @Test("D-6 P-a: the status menu's structure is written only by StatusItemController.init (source pin)")
    func statusMenuHasOneStructuralWriter() throws {
        let macdows = statusRepoRoot().appendingPathComponent("App/Macdows")
        let walker = try #require(FileManager.default.enumerator(at: macdows, includingPropertiesForKeys: nil))
        var walked = 0
        var outside: [String: Int] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(statusRepoRoot().path.count + 1))
            if path.hasPrefix("App/Macdows/StatusMenu/") { continue }
            walked += 1
            let code = statusCodeOnly(try String(contentsOf: url, encoding: .utf8))
            let count = statusOccurrences(of: "statusItemController.menu", in: code)
            if count > 0 { outside[path] = count }
        }
        #expect(walked >= 3, "the walk found AppDelegate, MainMenu and main (\(walked))")
        #expect(outside.isEmpty, "\(outside)")

        let code = statusCodeOnly(try String(contentsOf: statusRepoRoot().appendingPathComponent("App/Macdows/StatusMenu/StatusItemController.swift"), encoding: .utf8))
        let initStart = try #require(code.range(of: "override init() {"))
        let initEnd = try #require(code.range(of: "func install() {", range: initStart.upperBound..<code.endIndex))
        let initBody = String(code[initStart.upperBound..<initEnd.lowerBound])
        var inInit = 0
        for shape in ["addItem(", "insertItem(", "removeItem("] {
            let total = statusOccurrences(of: shape, in: code)
            let inside = statusOccurrences(of: shape, in: initBody)
            #expect(total == inside, "\(shape): \(total) in the file, \(inside) in init")
            inInit += inside
        }
        #expect(inInit > 0, "init builds the menu")
    }

    @Test("gate r1 I-2: Open Macdows activates the App and then hands over to onOpenMacdows (source pin)")
    func openMacdowsShowsTheHostsWindow() throws {
        let code = statusCodeOnly(try String(contentsOf: statusRepoRoot().appendingPathComponent("App/Macdows/StatusMenu/StatusItemController.swift"), encoding: .utf8))
        #expect(statusOccurrences(
            of: "@objc private func openMacdows(_ sender: Any?) { NSApp.activate(ignoringOtherApps: true) onOpenMacdows?() }",
            in: code) == 1)
        #expect(statusOccurrences(of: "var onOpenMacdows: (() -> Void)?", in: code) == 1)
    }

    @Test("the App creates the controller once and installs it once, at launch (source pin)")
    func appDelegateInstallsOnce() throws {
        let code = statusCodeOnly(try String(contentsOf: statusRepoRoot().appendingPathComponent("App/Macdows/AppDelegate.swift"), encoding: .utf8))
        #expect(statusOccurrences(of: "StatusItemController()", in: code) == 1)
        #expect(statusOccurrences(of: "statusItemController.install()", in: code) == 1)
        #expect(statusOccurrences(of: "didSet { statusItemController.bind(registry) }", in: code) == 1)
        let launch = try #require(code.range(of: "func applicationDidFinishLaunching(_ notification: Notification) {"))
        let install = try #require(code.range(of: "statusItemController.install()"))
        let next = try #require(code.range(of: "@objc private func connectTapped() {"))
        #expect(launch.upperBound <= install.lowerBound && install.upperBound <= next.lowerBound)
    }
}
