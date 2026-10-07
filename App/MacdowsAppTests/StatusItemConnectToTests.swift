import AppKit
import Testing

// UI slice ① (ADR-0024 §3 adr/0023 row): the status item's Connect to lists the host records the
// App supplies, is usable only without a session, and hands the chosen host to the App. The
// controller stays the one writer of its menu (the submenu's items are replaced in `apply`).

@MainActor
@Suite("StatusItemController — Connect to (UI slice ①)")
struct StatusItemConnectToTests {
    @Test("the submenu mirrors the host entries; choosing one hands its id over")
    func entries() throws {
        let controller = StatusItemController()
        let a = HostID(), b = HostID()
        controller.hostEntries = { [.init(id: a, title: "Office PC"), .init(id: b, title: "Lab PC")] }
        var chosen: [HostID] = []
        controller.onConnectTo = { chosen.append($0) }
        controller.refresh()
        #expect(controller.connectToItem.submenu === controller.connectToMenu)
        #expect(controller.connectToMenu.items.map(\.title) == ["Office PC", "Lab PC"])
        #expect(controller.connectToMenu.items.allSatisfy { $0.isEnabled && $0.target === controller })
        let item = try #require(controller.connectToMenu.items.last)
        controller.connectToHost(item)
        #expect(chosen == [b])
    }

    @Test("with a session, every Connect to entry is disabled and choosing one does nothing")
    func oneSessionAtATime() throws {
        let controller = StatusItemController()
        let a = HostID()
        controller.hostEntries = { [.init(id: a, title: "Office PC")] }
        controller.reading = { .init(hasSession: true, state: .live, host: "a.example") }
        var chosen: [HostID] = []
        controller.onConnectTo = { chosen.append($0) }
        controller.refresh()
        #expect(!controller.connectToItem.isEnabled)
        let item = try #require(controller.connectToMenu.items.first)
        #expect(!item.isEnabled)
        controller.connectToHost(item)
        #expect(chosen.isEmpty)
        #expect(!controller.oneSessionItem.isHidden)
    }

    @Test("no hosts: Connect to stays, disabled, with an empty submenu")
    func noHosts() {
        let controller = StatusItemController()
        controller.refresh()
        #expect(controller.connectToMenu.items.isEmpty)
        #expect(!controller.connectToItem.isEnabled)
    }
}
