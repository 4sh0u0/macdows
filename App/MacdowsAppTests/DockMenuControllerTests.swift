import AppKit
import Foundation
import MacdowsCore
import Testing

// ADR-0025 R-1 (a-0) / design note §8: the Dock menu built offline from a reading and a host's
// lists; and the status item's Run… (R-8, design note §9).

@MainActor
@Suite("DockMenuController (ADR-0025 R-1, design note §8)")
struct DockMenuControllerTests {
    private static let now = Date(timeIntervalSince1970: 0)

    private static func lists(pinned: Int, recent: Int) -> HostLaunchItems {
        HostLaunchItems(
            pinned: (0..<pinned).map { LaunchItem(displayName: "p\($0).exe", program: "p\($0).exe", arguments: "", date: now) },
            recent: (0..<recent).map { LaunchItem(displayName: "r\($0).exe", program: "r\($0).exe", arguments: "", date: now) }
        )
    }

    private static func reading(_ state: ReconnectDriver.State?, session: Bool = true) -> StartPanelController.Reading {
        .init(hasSession: session, state: state, host: HostID(), hostTitle: "workstation.example")
    }

    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test("live: at most 3 pinned, ---, at most 5 recent, ---, Run…, Open Macdows; empty sections take their separator")
    func liveShape() {
        let full = DockMenuController.menu(for: Self.reading(.live), lists: Self.lists(pinned: 4, recent: 7), target: nil)
        #expect(Self.titles(full) == ["p0.exe", "p1.exe", "p2.exe", "---", "r0.exe", "r1.exe", "r2.exe", "r3.exe", "r4.exe", "---",
                                      "Run…", "Open Macdows"])
        #expect(full.items.allSatisfy { $0.isSeparatorItem || $0.isEnabled })
        #expect(!full.autoenablesItems)
        #expect(Self.titles(DockMenuController.menu(for: Self.reading(.live), lists: Self.lists(pinned: 0, recent: 2), target: nil))
                == ["r0.exe", "r1.exe", "---", "Run…", "Open Macdows"])
        #expect(Self.titles(DockMenuController.menu(for: Self.reading(.live), lists: Self.lists(pinned: 1, recent: 0), target: nil))
                == ["p0.exe", "---", "Run…", "Open Macdows"])
        #expect(Self.titles(DockMenuController.menu(for: Self.reading(.live), lists: HostLaunchItems(), target: nil)) == ["Run…", "Open Macdows"])
    }

    @Test("not live: one disabled status line, ---, Run… (disabled only with no session), Open Macdows; no programs")
    func nonLiveShape() {
        let cases: [(StartPanelController.Reading, String, Bool)] = [
            (Self.reading(.idle), "Connecting…", true),
            (Self.reading(nil), "Connecting…", true),
            (Self.reading(.waiting(attempt: 0, delay: .seconds(1))), "Reconnecting to workstation.example", true),
            (Self.reading(.reconnecting(attempt: 1)), "Reconnecting to workstation.example", true),
            (Self.reading(.gaveUp(.policy(.attemptsExhausted))), "Not connected", false),
            (Self.reading(nil, session: false), "Not connected", false),
        ]
        for (reading, status, runEnabled) in cases {
            let menu = DockMenuController.menu(for: reading, lists: Self.lists(pinned: 2, recent: 2), target: nil)
            #expect(Self.titles(menu) == [status, "---", "Run…", "Open Macdows"], "\(String(describing: reading.state))")
            #expect(!menu.items[0].isEnabled)
            #expect(menu.items[2].isEnabled == runEnabled)
            #expect(menu.items[3].isEnabled)
        }
    }

    /// RE-WRITTEN by the a-1 in-person fold (F-a1-2, owner ruling (a)): the Dock drops an attributed
    /// title's colours, so the arguments are set off by " — " in a plain title and no attributed title
    /// is set; the 40-character middle cut applies to the whole string.
    @Test("titles longer than 40 characters are cut in the middle to exactly 40; arguments follow an em dash in a plain title (F-a1-2)")
    func titles() throws {
        let long = String(repeating: "x", count: 92)
        let cut = DockMenuController.truncated(long, limit: 40)
        #expect(cut.count == 40 && cut.contains("…") && cut.hasPrefix("xxxx") && cut.hasSuffix("xxxx"))
        #expect(DockMenuController.truncated("short.exe", limit: 40) == "short.exe")
        #expect(DockMenuController.argumentSeparator.unicodeScalars.map(\.value) == [0x20, 0x2014, 0x20])
        let lists = HostLaunchItems(pinned: [LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#, arguments: "/open", date: Self.now)],
                                    recent: [LaunchItem(displayName: "notepad.exe", program: "notepad.exe", arguments: "", date: Self.now),
                                             LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#,
                                                        arguments: String(repeating: "a", count: 50), date: Self.now)])
        let items = DockMenuController.menu(for: Self.reading(.live), lists: lists, target: nil).items
        let item = try #require(items.first)
        #expect(item.title == "Example.exe — /open")
        #expect(item.attributedTitle == nil, "a plain title: the Dock would drop the colours anyway")
        #expect(item.toolTip == #"C:\Tools\Example.exe /open"#)
        #expect(item.action == #selector(DockMenuController.launchProgram(_:)))
        let plain = try #require(items.first { $0.title == "notepad.exe" }, "no arguments: the program alone, no dash")
        #expect(plain.attributedTitle == nil)
        let longRow = try #require(items.last { !$0.isSeparatorItem && $0.action == #selector(DockMenuController.launchProgram(_:)) })
        let whole = "Example.exe — " + String(repeating: "a", count: 50)
        #expect(longRow.title == DockMenuController.truncated(whole, limit: 40), "the middle cut runs over the whole string")
        #expect(longRow.title.count == 40 && longRow.title.hasPrefix("Example.exe — ") && longRow.attributedTitle == nil)
    }

    /// Gate r1 observation (813d76f): two rows of a section with the same display name carry their
    /// parent folder as a qualifier, and the Dock menu shows it -- in parentheses after the title,
    /// before the em dash -- so the two rows no longer read identically. Catalog order, plain titles,
    /// the full commands as tooltips.
    @Test("same display name in one section: \"Example.exe (Tools) — /open\" and \"Example.exe (Other)\", in catalog order")
    func duplicateNamesCarryTheQualifier() throws {
        let lists = HostLaunchItems(pinned: [LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#, arguments: "/open", date: Self.now),
                                             LaunchItem(displayName: "Example.exe", program: #"C:\Other\Example.exe"#, arguments: "", date: Self.now)],
                                    recent: [])
        let menu = DockMenuController.menu(for: Self.reading(.live), lists: lists, target: nil)
        let rows = menu.items.filter { $0.action == #selector(DockMenuController.launchProgram(_:)) }
        #expect(rows.map(\.title) == ["Example.exe (Tools) — /open", "Example.exe (Other)"])
        #expect(rows.allSatisfy { $0.attributedTitle == nil })
        #expect(rows.map(\.toolTip) == [#"C:\Tools\Example.exe /open"#, #"C:\Other\Example.exe"#])
        #expect(Self.titles(menu) == ["Example.exe (Tools) — /open", "Example.exe (Other)", "---", "Run…", "Open Macdows"])
    }

    /// The 40-character middle cut runs over the qualified whole: a 50-character qualifier, or a
    /// qualified row's 50-character arguments, still gives exactly 40 characters that start with the
    /// title and its opening parenthesis.
    @Test("the 40-character cut applies to the qualified title as a whole")
    func theCutCoversTheQualifier() throws {
        let folder = String(repeating: "q", count: 50)
        let arguments = String(repeating: "a", count: 50)
        let lists = HostLaunchItems(pinned: [LaunchItem(displayName: "Example.exe", program: "C:\\" + folder + "\\Example.exe", arguments: "", date: Self.now),
                                             LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#, arguments: arguments, date: Self.now)],
                                    recent: [])
        let rows = DockMenuController.menu(for: Self.reading(.live), lists: lists, target: nil).items
            .filter { $0.action == #selector(DockMenuController.launchProgram(_:)) }
        try #require(rows.count == 2)
        #expect(rows[0].title == DockMenuController.truncated("Example.exe (" + folder + ")", limit: 40))
        #expect(rows[0].title.count == 40 && rows[0].title.hasPrefix("Example.exe (") && rows[0].title.hasSuffix(")"))
        #expect(rows[1].title == DockMenuController.truncated("Example.exe (Tools) — " + arguments, limit: 40))
        #expect(rows[1].title.count == 40 && rows[1].title.hasPrefix("Example.exe (Tools)"))
        #expect(rows.allSatisfy { $0.attributedTitle == nil })
    }

    /// F-a1-2's other half: the panel keeps the secondary colour -- its rows were never attributed
    /// strings: the title is one label in the label colour, the arguments another in the secondary.
    @Test("F-a1-2: the panel's row keeps the arguments in their own secondary-colour label")
    func panelRowKeepsTheSecondaryColour() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: #"C:\Tools\Example.exe"#, arguments: "/open"), displayName: "Example.exe",
                           for: StartPanelControllerTests.host, at: Self.now)
        let controller = StartPanelController(items: store, launcher: AppLauncher(timeout: .seconds(8), clock: DispatchReconnectClock()),
                                              preferences: StartPanelControllerTests.preferences())
        controller.reading = { .init(hasSession: true, state: .live, host: StartPanelControllerTests.host, hostTitle: "workstation.example") }
        controller.render()
        let row = try #require(controller.itemRows.first?.view)
        #expect(row.titleLabel.stringValue == "Example.exe" && row.titleLabel.textColor == .labelColor)
        #expect(row.detailLabel.stringValue == "/open" && row.detailLabel.textColor == .secondaryLabelColor)
        #expect(!row.detailLabel.isHidden)
        #expect(!row.titleLabel.stringValue.contains(DockMenuController.argumentSeparator), "no dash in the panel")
    }

    @Test("every action targets the Dock menu controller, never the App delegate (S-5)")
    func actionsTargetTheController() {
        let store = LaunchItemStore(fileURL: nil)
        let controller = StartPanelController(items: store, launcher: AppLauncher(timeout: .seconds(8), clock: DispatchReconnectClock()),
                                              preferences: StartPanelControllerTests.preferences())
        controller.reading = { Self.reading(.live) }
        let menu = controller.dockMenu.makeMenu()
        #expect(menu.items.compactMap(\.action) == [#selector(DockMenuController.runProgram(_:)), #selector(DockMenuController.openMacdows(_:))])
        #expect(menu.items.allSatisfy { $0.target === controller.dockMenu })
    }
}

@MainActor
@Suite("StatusItemController Run… (ADR-0025 R-8, design note §9)")
struct StatusItemRunItemTests {
    @Test("with a session Run… is enabled, sits above Open Macdows and hands the button frame to the App")
    func runWithSession() {
        let controller = StatusItemController()
        controller.reading = { .init(hasSession: true, state: .live, host: "workstation.example") }
        controller.refresh()
        let visible = controller.menu.items.filter { !$0.isHidden }
        let run = visible.firstIndex { $0 === controller.runItem }
        let open = visible.firstIndex { $0 === controller.openItem }
        #expect(run != nil && open != nil && run! + 1 == open!)
        #expect(controller.runItem.title == "Run…")
        #expect(controller.runItem.isEnabled && controller.validateMenuItem(controller.runItem))
        #expect(controller.validateMenuItem(controller.openItem), "every other item keeps AppKit's answer")
        var asked: [CGRect?] = []
        controller.onRun = { asked.append($0) }
        _ = controller.runItem.target?.perform(controller.runItem.action, with: controller.runItem)
        #expect(asked.count == 1 && asked[0] == nil, "not installed: no button frame yet")

        controller.reading = { .noSession }
        controller.refresh()
        #expect(!controller.runItem.isEnabled)
        _ = controller.runItem.target?.perform(controller.runItem.action, with: controller.runItem)
        #expect(asked.count == 1, "no session: Run… does nothing")
    }

    @Test("with a session the status menu reads, top to bottom, with Run… above Open Macdows")
    func sequenceWithSession() {
        let controller = StatusItemController()
        controller.reading = { .init(hasSession: true, state: nil, host: "h") }
        controller.refresh()
        let titles = controller.menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "---" : $0.title }
        #expect(titles == ["Connecting…", "---", "Connect to", "One session at a time. Disconnect first.", "Disconnect", "---",
                           "Run…", "Open Macdows", "Settings…", "---", "Quit Macdows"])
    }
}
