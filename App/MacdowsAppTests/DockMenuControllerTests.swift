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

    @Test("titles longer than 40 characters are cut in the middle to exactly 40; arguments ride along in the secondary colour")
    func titles() throws {
        let long = String(repeating: "x", count: 92)
        let cut = DockMenuController.truncated(long, limit: 40)
        #expect(cut.count == 40 && cut.contains("…") && cut.hasPrefix("xxxx") && cut.hasSuffix("xxxx"))
        #expect(DockMenuController.truncated("short.exe", limit: 40) == "short.exe")
        let lists = HostLaunchItems(pinned: [LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#, arguments: "/open", date: Self.now)])
        let item = try #require(DockMenuController.menu(for: Self.reading(.live), lists: lists, target: nil).items.first)
        #expect(item.title == "Example.exe  /open")
        #expect(item.toolTip == #"C:\Tools\Example.exe /open"#)
        #expect(item.attributedTitle?.string == "Example.exe  /open")
        #expect(item.action == #selector(DockMenuController.launchProgram(_:)))
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
