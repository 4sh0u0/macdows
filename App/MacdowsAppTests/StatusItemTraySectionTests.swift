import AppKit
import MacdowsCore
import Testing

// adr/0023 D-8 ①′ (W6-2, the menu side) and ③ (image visibility), plus ⑤'s menu-item half: the
// Remote tray section mirrors a `TrayStatusController` into an `NSMenu` built here, offline. No
// status item is created and `NSStatusBar.system` is never touched -- the section only ever sees
// the menu it is given. "Open menu" cannot be simulated here (no tracking session in a test
// bundle); M-a's claim tested here is the structural one -- every change is applied to the menu at
// once, with no `menuNeedsUpdate(_:)` call in between. Whether AppKit re-lays an OPEN menu at once
// is adr/0023 U-2 (real machine), and whether the main queue runs while one is open is U-1 (D-8
// ⑧(a) probe, ⑧(b) real machine).

private func sectionRGBA(side: Int) -> Data {
    Data((0..<(side * side)).flatMap { _ in [UInt8(0), 128, 255, 255] })
}

private func sectionPayload(tip: String? = nil) -> TrayStatusController.IconPayload {
    .init(rgba: sectionRGBA(side: 16), width: 16, height: 16, skipped: false, cached: false, toolTip: tip)
}

@MainActor
@Suite("StatusItemTraySection (adr/0023 ①′ / ③)")
struct StatusItemTraySectionTests {
    /// A menu shaped like the status item's: a status row, the anchor the section follows, and
    /// one item after it, so the section's own run is bounded on both sides.
    private static func makeMenu() -> (NSMenu, NSMenuItem, NSMenuItem) {
        let menu = NSMenu(title: "status")
        menu.addItem(NSMenuItem(title: "Status", action: nil, keyEquivalent: ""))
        let anchor = NSMenuItem(title: "Detail", action: nil, keyEquivalent: "")
        menu.addItem(anchor)
        let after = NSMenuItem(title: "Connect to", action: nil, keyEquivalent: "")
        menu.addItem(after)
        return (menu, anchor, after)
    }

    /// The items strictly between `anchor` and `after`.
    private static func run(_ menu: NSMenu, _ anchor: NSMenuItem, _ after: NSMenuItem) -> [NSMenuItem] {
        let start = menu.index(of: anchor) + 1
        let end = menu.index(of: after)
        return Array(menu.items[start..<end])
    }

    /// W6-2, checked after every step: the section's entry items are exactly the model's entries
    /// (count, order, tag unpacks to the key, image present), and the run is
    /// separator / header / entries-or-empty-line / separator.
    private static func expectMirrors(
        _ section: StatusItemTraySection, _ source: TrayStatusController,
        _ menu: NSMenu, _ anchor: NSMenuItem, _ after: NSMenuItem,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let run = run(menu, anchor, after)
        let items = section.entryItems
        #expect(items.count == source.entries.count, sourceLocation: sourceLocation)
        #expect(items.count == source.diagnostics().liveCount, sourceLocation: sourceLocation)
        for (item, entry) in zip(items, source.entries) {
            let unpacked = TrayButtonTag.unpack(item.tag)
            #expect(NotifyIconState(windowId: unpacked.windowId, notifyIconId: unpacked.notifyIconId) == entry.key, sourceLocation: sourceLocation)
            #expect(item.image != nil, sourceLocation: sourceLocation)
            #expect(item.title == entry.title, sourceLocation: sourceLocation)
            #expect(item.menu === menu, sourceLocation: sourceLocation)
        }
        #expect(run.count == 3 + max(items.count, 1), "\(run.map(\.title))", sourceLocation: sourceLocation)
        #expect(run.first?.isSeparatorItem == true, sourceLocation: sourceLocation)
        #expect(run.last?.isSeparatorItem == true, sourceLocation: sourceLocation)
        #expect(run.dropFirst().first === section.header, sourceLocation: sourceLocation)
        if items.isEmpty {
            #expect(run[2] === section.emptyItem, sourceLocation: sourceLocation)
        } else {
            #expect(Array(run[2..<(2 + items.count)]).elementsEqual(items, by: ===), sourceLocation: sourceLocation)
        }
    }

    @Test("①′ W6-2: insert / update / remove keep the section equal to the model, applied at once")
    func sectionMirrorsTheModel() {
        let (menu, anchor, after) = Self.makeMenu()
        let source = TrayStatusController()
        let section = StatusItemTraySection(menu: menu, after: anchor)
        section.bind(source)
        section.setPresentation(.live(host: "host.example"))
        Self.expectMirrors(section, source, menu, anchor, after)
        #expect(section.emptyItem.title == "No tray icons in this session")
        #expect(section.header.title == "Remote tray · host.example")

        source.handleNotifyIconCreate(windowId: 7, notifyIconId: 1, ownerWindowTitle: nil, icon: sectionPayload(tip: "One"))
        Self.expectMirrors(section, source, menu, anchor, after)
        source.handleNotifyIconCreate(windowId: 7, notifyIconId: 2, ownerWindowTitle: "Owner", icon: .absent)
        source.handleNotifyIconCreate(windowId: 8, notifyIconId: 1, ownerWindowTitle: nil, icon: sectionPayload(tip: "Three"))
        Self.expectMirrors(section, source, menu, anchor, after)

        let middle = section.entryItems[1]
        source.handleNotifyIconUpdate(windowId: 7, notifyIconId: 2, ownerWindowTitle: "Owner", icon: sectionPayload(tip: "Two"))
        Self.expectMirrors(section, source, menu, anchor, after)
        #expect(section.entryItems[1] === middle, "an update rewrites the same item in place")
        #expect(middle.title == "Two")

        source.handleNotifyIconDelete(windowId: 7, notifyIconId: 1)
        Self.expectMirrors(section, source, menu, anchor, after)
        #expect(section.entryItems.map(\.title) == ["Two", "Three"])
        source.handleNotifyIconDelete(windowId: 7, notifyIconId: 2)
        source.handleNotifyIconDelete(windowId: 8, notifyIconId: 1)
        Self.expectMirrors(section, source, menu, anchor, after)
        #expect(section.entryItems.isEmpty)
    }

    @Test("①′ removeAll empties the section to the empty line; an empty source or hiding removes the section and both separators")
    func teardownAndEmptySource() {
        let (menu, anchor, after) = Self.makeMenu()
        let source = TrayStatusController()
        let section = StatusItemTraySection(menu: menu, after: anchor)
        section.bind(source)
        section.setPresentation(.live(host: "h"))
        for id in UInt32(1)...4 {
            source.handleNotifyIconCreate(windowId: 1, notifyIconId: id, ownerWindowTitle: nil, icon: sectionPayload(tip: "t\(id)"))
        }
        Self.expectMirrors(section, source, menu, anchor, after)

        source.removeAll()
        Self.expectMirrors(section, source, menu, anchor, after)

        section.setPresentation(.reconnecting(host: "h"))
        Self.expectMirrors(section, source, menu, anchor, after)
        #expect(section.emptyItem.title == "Tray icons come back after reconnecting")

        section.setPresentation(.hidden)
        #expect(Self.run(menu, anchor, after).isEmpty)
        #expect(menu.items.count == 3)

        // Changes while hidden are not applied, and showing again rebuilds from the model.
        source.handleNotifyIconCreate(windowId: 2, notifyIconId: 1, ownerWindowTitle: nil, icon: sectionPayload(tip: "back"))
        #expect(Self.run(menu, anchor, after).isEmpty)
        section.setPresentation(.live(host: "h"))
        Self.expectMirrors(section, source, menu, anchor, after)

        // An empty source (registry == nil) leaves no entry items behind.
        section.bind(nil)
        #expect(section.entryItems.isEmpty)
        #expect(source.onMenuChange == nil, "the old source is no longer mirrored")
        section.setPresentation(.hidden)
        #expect(menu.items.count == 3)
        #expect(menu.items.allSatisfy { !$0.isSeparatorItem })
    }

    @Test("①′ binding a source that already has entries mirrors them at once")
    func bindingAPopulatedSource() {
        let (menu, anchor, after) = Self.makeMenu()
        let source = TrayStatusController()
        source.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: nil, icon: sectionPayload(tip: "a"))
        source.handleNotifyIconCreate(windowId: 1, notifyIconId: 2, ownerWindowTitle: nil, icon: sectionPayload(tip: "b"))
        let section = StatusItemTraySection(menu: menu, after: anchor)
        section.setPresentation(.live(host: "h"))
        section.bind(source)
        Self.expectMirrors(section, source, menu, anchor, after)
    }

    @Test("the header's host name is cut at 32 grapheme clusters plus an ellipsis")
    func hostIsTruncated() {
        let long = String(repeating: "w", count: 40)
        #expect(StatusItemTraySection.truncatedHost(long) == String(repeating: "w", count: 32) + "…")
        #expect(StatusItemTraySection.truncatedHost("short") == "short")
        #expect(StatusItemTraySection.hostLimit == 32)
    }

    // MARK: - ⑤ menu-item half

    @Test("⑤ choosing an entry's item forwards that key as one left click; after the delete the stale item cannot reach the wire")
    func choosingAnItemForwardsTheClick() throws {
        let (menu, anchor, _) = Self.makeMenu()
        let source = TrayStatusController()
        var forwarded: [NotifyIconState] = []
        source.onLeftClick = { forwarded.append(NotifyIconState(windowId: $0, notifyIconId: $1)) }
        let section = StatusItemTraySection(menu: menu, after: anchor)
        section.bind(source)
        section.setPresentation(.live(host: "h"))
        source.handleNotifyIconCreate(windowId: 40, notifyIconId: 2, ownerWindowTitle: nil, icon: sectionPayload(tip: "x"))
        source.handleNotifyIconCreate(windowId: 41, notifyIconId: 3, ownerWindowTitle: nil, icon: sectionPayload(tip: "y"))

        let second = try #require(section.entryItems.last)
        menu.performActionForItem(at: menu.index(of: second))
        #expect(forwarded == [NotifyIconState(windowId: 41, notifyIconId: 3)])
        #expect(source.diagnostics().clicksForwarded == 1)

        // The item is gone from the menu with the delete (M-a); a click racing it is dropped.
        source.handleNotifyIconDelete(windowId: 41, notifyIconId: 3)
        #expect(menu.index(of: second) == -1)
        source.handleLeftClick(tag: second.tag)
        #expect(forwarded.count == 1)
        #expect(source.diagnostics().clicksDroppedIconGone == 1)
    }

    // MARK: - ③ image visibility (adr/0023 D-1 V-a)

    @Test("③ entry items ask for a visible image where the run time has the property (macOS 27), and set nothing elsewhere")
    func imageVisibility() throws {
        let (menu, anchor, _) = Self.makeMenu()
        let source = TrayStatusController()
        let section = StatusItemTraySection(menu: menu, after: anchor)
        section.bind(source)
        section.setPresentation(.live(host: "h"))
        source.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: nil, icon: sectionPayload())
        let item = try #require(section.entryItems.first)
        let probe = NSMenuItem(title: "untouched", action: nil, keyEquivalent: "")
        if item.responds(to: Selector(("setPreferredImageVisibility:"))) {
            #expect((item.value(forKey: "preferredImageVisibility") as? Int) == 1, "Visible")
            #expect((probe.value(forKey: "preferredImageVisibility") as? Int) == 0, "a fresh item is Automatic")
        } else {
            // macOS 14-26: the selector is absent; the helper must not reach key-value coding.
            StatusItemTraySection.preferVisibleImage(probe)
            #expect(item.image != nil)
        }
    }
}
