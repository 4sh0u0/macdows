import AppKit
import MacdowsCore
import Testing

// adr/0023 (with adr/0022 slice ②): the status item controller's Remote tray section wired to a
// real `RemoteWindowRegistry` -- RAIL notify-icon orders in through `handle(_:)`, the section
// mirroring them (W6-2), a chosen item leaving as the two ClientNotifyEvent PDUs (⑤), and the
// section following the session (D-4). The registry runs over an UNSTARTED `CRSession` (nothing
// here contacts any host); the PDUs are observed through `onTrayNotifyEventSent`, the hook fired
// at the one place a PDU is posted. `install()` is never called: no status item is created.

/// A drained notify-icon order, built the only way a `CRDPEvent` can be (a subclass overriding the
/// getters -- the precedent `RemoteWindowRegistrySessionEndTests` and others keep a copy of).
private final class NotifyIconStub: CRDPEvent {
    private let eventKind: CRDPEventKind
    private let owner: UInt32
    private let icon: UInt32
    private let tip: String?
    private let pixels: Data?

    init(_ kind: CRDPEventKind, windowId: UInt32, notifyIconId: UInt32, toolTip: String? = nil, side: Int = 0) {
        eventKind = kind
        owner = windowId
        icon = notifyIconId
        tip = toolTip
        pixels = side > 0 ? Data((0..<(side * side)).flatMap { _ in [UInt8(10), 20, 30, 255] }) : nil
        super.init()
    }

    override var kind: CRDPEventKind { eventKind }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { owner }
    override var notifyIconId: UInt32 { icon }
    override var toolTip: String? { tip }
    override var iconRGBA: Data? { pixels }
    override var iconWidth: UInt32 { pixels == nil ? 0 : UInt32((pixels!.count / 4).squareRootInt) }
    override var iconHeight: UInt32 { iconWidth }
}

private extension Int {
    var squareRootInt: Int { Int(Double(self).squareRoot()) }
}

@MainActor
private func wiringRegistry() throws -> (CRSession, RemoteWindowRegistry) {
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    let topology = try #require(DisplayTopology(displays: [display]))
    let session = CRSession(host: "", user: "", password: "", program: "")
    let registry = RemoteWindowRegistry(session: session, topologyProvider: StaticDisplayTopologyProvider(topology))
    return (session, registry)
}

@MainActor
@Suite("Status item ↔ Remote tray wiring (adr/0023 with adr/0022 slice ②)")
struct StatusItemTrayWiringTests {
    /// The items between the status rows and the gap separator: the section's run.
    private static func sectionRun(_ controller: StatusItemController) -> [NSMenuItem] {
        let menu = controller.menu
        let start = menu.index(of: controller.detailRow) + 1
        let end = menu.index(of: controller.sectionGapSeparator)
        return Array(menu.items[start..<end])
    }

    /// W6-2 in full, on the status menu itself: the section's entry items are exactly the bound
    /// registry's tray entries (count == entries == liveCount; order, key, title, image), each one
    /// is in the status menu, and the section's run is separator / header / those items / separator.
    private static func expectW62(
        _ controller: StatusItemController, _ registry: RemoteWindowRegistry,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let source = registry.trayMenuSource
        let items = controller.traySection.entryItems
        #expect(items.count == source.entries.count, sourceLocation: sourceLocation)
        #expect(items.count == registry.trayDiagnostics().liveCount, sourceLocation: sourceLocation)
        for (item, entry) in zip(items, source.entries) {
            let unpacked = TrayButtonTag.unpack(item.tag)
            #expect(NotifyIconState(windowId: unpacked.windowId, notifyIconId: unpacked.notifyIconId) == entry.key, sourceLocation: sourceLocation)
            #expect(item.title == entry.title, sourceLocation: sourceLocation)
            #expect(item.image != nil, sourceLocation: sourceLocation)
            #expect(item.menu === controller.menu, sourceLocation: sourceLocation)
        }
        let run = sectionRun(controller)
        #expect(run.count == 3 + max(items.count, 1), "\(run.map(\.title))", sourceLocation: sourceLocation)
        #expect(run.first?.isSeparatorItem == true, sourceLocation: sourceLocation)
        #expect(run.last?.isSeparatorItem == true, sourceLocation: sourceLocation)
        #expect(run.dropFirst().first === controller.traySection.header, sourceLocation: sourceLocation)
        if !items.isEmpty, run.count == 3 + items.count {
            #expect(Array(run[2..<(2 + items.count)]).elementsEqual(items, by: ===), sourceLocation: sourceLocation)
        }
    }

    @Test("the registry hands out its one tray controller as the section's source")
    func registryExposesItsTrayController() throws {
        let (_, registry) = try wiringRegistry()
        #expect(registry.trayMenuSource === registry.trayMenuSource)
        registry.handle(NotifyIconStub(.notifyIconCreate, windowId: 3, notifyIconId: 1, toolTip: "t", side: 16))
        #expect(registry.trayMenuSource.entries.count == 1)
        #expect(registry.trayDiagnostics().liveCount == 1)
    }

    @Test("W6-2 end to end: RAIL orders into the registry show up in the status menu at once; a chosen item sends WM_LBUTTONDOWN/UP; teardown and unbinding empty it")
    func endToEnd() throws {
        // Menu item actions are dispatched through NSApplication; when this test runs on its own
        // nothing has touched the shared application yet and the chosen item's action never
        // fires (fold F-6, gate r1 follow-up). Touching it here keeps the test order-independent.
        _ = NSApplication.shared
        let (_, registry) = try wiringRegistry()
        var sent: [String] = []
        registry.onTrayNotifyEventSent = { sent.append("\($0)/\($1)/\(String($2, radix: 16))") }
        let controller = StatusItemController()
        var reading = StatusItemController.SessionReading(hasSession: true, state: .live, host: "host.example")
        controller.reading = { reading }
        controller.bind(registry)

        // Live with no icons: header + "no tray icons", and the gap separator steps aside.
        #expect(controller.traySection.isShown)
        #expect(controller.sectionGapSeparator.isHidden)
        #expect(Self.sectionRun(controller).map { $0.isSeparatorItem ? "---" : $0.title } == [
            "---", "Remote tray · host.example", "No tray icons in this session", "---",
        ])

        registry.handle(NotifyIconStub(.notifyIconCreate, windowId: 9, notifyIconId: 1, toolTip: "Volume", side: 16))
        registry.handle(NotifyIconStub(.notifyIconCreate, windowId: 9, notifyIconId: 2, toolTip: nil))
        let titles = { Self.sectionRun(controller).filter { !$0.isSeparatorItem }.map(\.title) }
        #expect(titles() == ["Remote tray · host.example", "Volume", "Tray app 2"])
        #expect(controller.traySection.entryItems.count == registry.trayDiagnostics().liveCount)
        Self.expectW62(controller, registry)

        // Gate r1 I-3 (UI-4 fold F-3): the controller is the menu's one structural writer, and its
        // refresh paths -- the menu about to open, a driver state change -- leave the section's
        // entries alone. Run both with two entries in the section, twice, and W6-2 still holds.
        for _ in 0..<2 {
            controller.menuNeedsUpdate(controller.menu)
            Self.expectW62(controller, registry)
            controller.refresh()
            Self.expectW62(controller, registry)
        }
        #expect(titles() == ["Remote tray · host.example", "Volume", "Tray app 2"])

        // ⑤: choosing the first entry is one click -> exactly the two PDUs, in order, for that key.
        let first = try #require(controller.traySection.entryItems.first)
        controller.menu.performActionForItem(at: controller.menu.index(of: first))
        #expect(sent == ["9/1/201", "9/1/202"])
        let diag = registry.trayDiagnostics()
        #expect(diag.clicksForwarded == 1)
        #expect(diag.notifyEventsSent == 2 * diag.clicksForwarded)
        #expect(diag.clicksDroppedIconGone == 0)

        registry.handle(NotifyIconStub(.notifyIconDelete, windowId: 9, notifyIconId: 1))
        #expect(titles() == ["Remote tray · host.example", "Tray app 2"])
        #expect(first.menu == nil, "the deleted entry's item left the menu in the same turn (M-a)")

        // A reconnect tears the entries down and the driver reports it: the retry line.
        registry.closeWindowsForSessionEnd()
        reading.state = .waiting(attempt: 0, delay: .seconds(1))
        controller.refresh()
        #expect(titles() == ["Remote tray · host.example", "Tray icons come back after reconnecting"])

        // Session over: no registry, no section, no separators of its own.
        reading = .noSession
        controller.bind(nil)
        #expect(!controller.traySection.isShown)
        #expect(Self.sectionRun(controller).isEmpty)
        #expect(!controller.sectionGapSeparator.isHidden)
        #expect(registry.trayMenuSource.onMenuChange == nil, "the old registry's table is no longer mirrored")
    }

    @Test(
        "D-4: the section follows the driver state -- live shows, waiting / reconnecting shows the retry line, idle / gave up / no session hides",
        arguments: [
            (StatusItemController.SessionReading(hasSession: true, state: .live, host: "h"), "live"),
            (.init(hasSession: true, state: .waiting(attempt: 2, delay: .seconds(4)), host: "h"), "reconnecting"),
            (.init(hasSession: true, state: .reconnecting(attempt: 2), host: "h"), "reconnecting"),
            (.init(hasSession: true, state: .idle, host: "h"), "hidden"),
            (.init(hasSession: true, state: nil, host: "h"), "hidden"),
            (.init(hasSession: true, state: .gaveUp(.policy(.attemptsExhausted)), host: "h"), "hidden"),
            (.noSession, "hidden"),
            (.init(hasSession: false, state: .live, host: "h"), "hidden"),
        ] as [(StatusItemController.SessionReading, String)]
    )
    func presentationFollowsTheState(reading: StatusItemController.SessionReading, expected: String) {
        let presentation = StatusItemController.trayPresentation(for: reading)
        switch (presentation, expected) {
        case (.live(let host), "live"), (.reconnecting(let host), "reconnecting"):
            #expect(host == "h")
        case (.hidden, "hidden"):
            break
        default:
            Issue.record("got \(presentation), expected \(expected)")
        }
    }

    @Test("a session without a registry yet shows no section even when the driver says live")
    func noRegistryNoSection() {
        let controller = StatusItemController()
        controller.reading = { .init(hasSession: true, state: .live, host: "h") }
        controller.refresh()
        #expect(!controller.traySection.isShown)
        #expect(!controller.sectionGapSeparator.isHidden)
    }
}
