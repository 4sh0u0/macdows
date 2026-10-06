import AppKit
import MacdowsCore
import Testing

// Lane D7, rewritten for adr/0023 (D-5 R1 + K-a): `TrayStatusController` keeps an entry table
// and touches no status bar, so every path is offline-reachable now -- create / update / delete /
// removeAll and the click's FORWARD branch included (the W6-era boundary "the forward branch
// needs a live NSStatusItem on the operator's menu bar" is gone with the status items). See
// DisplayTopologyProviderTests.swift's file header for the lane's shared coverage-boundary
// register. adr/0023 D-8's offline pins here: ① entries vs liveCount, ② icon form, ④ title
// table, ⑤ click forwarding at the controller, ⑦ main-actor isolation. ①′ and ③ (the menu side)
// are in StatusItemTraySectionTests; ⑥ (source pins) in StatusItemControllerTests.

/// A tightly packed premultiplied RGBA bitmap, `side` x `side`, every pixel opaque red.
private func trayTestRGBA(side: Int) -> Data {
    Data((0..<(side * side)).flatMap { _ in [UInt8(255), 0, 0, 255] })
}

private func trayTestPayload(side: Int = 32, tip: String? = nil) -> TrayStatusController.IconPayload {
    TrayStatusController.IconPayload(rgba: trayTestRGBA(side: side), width: side, height: side, skipped: false, cached: false, toolTip: tip)
}

@MainActor
@Suite("TrayStatusController")
struct TrayStatusControllerTests {
    /// adr/0014 §7 + §9.1: distinct versions latch (and only distinct ones), the set is
    /// hard-capped at `maxObservedVersions` -- checked before insert, so the 17th distinct
    /// value is dropped, not trimmed in later -- and diagnostics report the set sorted.
    @Test func notifyIconVersionLatchIsDistinctSortedAndCapped() {
        let controller = TrayStatusController()

        controller.noteNotifyIconVersion(7)
        controller.noteNotifyIconVersion(7)
        controller.noteNotifyIconVersion(3)
        #expect(controller.diagnostics().observedNotifyIconVersions == [3, 7])

        // 20 distinct values total (3 and 7 recount as already-seen): the cap must hold.
        for version in UInt32(100)..<120 {
            controller.noteNotifyIconVersion(version)
        }
        let observed = controller.diagnostics().observedNotifyIconVersions
        #expect(observed.count == TrayStatusController.maxObservedVersions)
        #expect(observed == [3, 7] + Array(UInt32(100)..<114)) // 2 + 14 = the 16 first-seen values
        #expect(observed == observed.sorted())
    }

    /// adr/0014 §4: a click whose key has no live entry is DROPPED -- counted in
    /// `clicksDroppedIconGone`, never handed to `onLeftClick`, never counted as forwarded.
    @Test func leftClickWithNoLiveIconIsDroppedNotForwarded() {
        let controller = TrayStatusController()
        var forwarded: [(UInt32, UInt32)] = []
        controller.onLeftClick = { forwarded.append(($0, $1)) }

        controller.handleLeftClick(tag: TrayButtonTag.pack(windowId: 5, notifyIconId: 9))
        controller.handleLeftClick(tag: TrayButtonTag.pack(windowId: 5, notifyIconId: 9))

        #expect(forwarded.isEmpty)
        let diagnostics = controller.diagnostics()
        #expect(diagnostics.clicksDroppedIconGone == 2)
        #expect(diagnostics.clicksForwarded == 0)
        #expect(diagnostics.notifyEventsSent == 0)
    }

    /// The two pushed-in counters' distinct semantics (adr/0013 §1, adr/0014 §5):
    /// `noteNotifyEventSent` ACCUMULATES one per PDU, while `noteStoreOverflowCount` is a
    /// plain ASSIGNMENT of the C side-store's own monotonic counter -- pushing a smaller
    /// value must replace, not add.
    @Test func pushedInCountersAccumulateVsAssign() {
        let controller = TrayStatusController()
        controller.noteNotifyEventSent()
        controller.noteNotifyEventSent()
        controller.noteNotifyEventSent()
        controller.noteStoreOverflowCount(5)
        controller.noteStoreOverflowCount(3)
        // W3 lane G: the oversize-refusal count is pushed in the same "latest value" way.
        controller.noteStoreOversizeRefusalCount(4)
        controller.noteStoreOversizeRefusalCount(2)

        let diagnostics = controller.diagnostics()
        #expect(diagnostics.notifyEventsSent == 3)
        #expect(diagnostics.storeOverflowCount == 3)
        #expect(diagnostics.storeOversizeRefusalCount == 2)
    }

    /// A fresh controller's diagnostics are all-zero/empty -- the baseline every cumulative
    /// assertion above counts up from.
    @Test func freshControllerDiagnosticsAreZero() {
        let diagnostics = TrayStatusController().diagnostics()
        #expect(diagnostics.createsSeen == 0)
        #expect(diagnostics.updatesSeen == 0)
        #expect(diagnostics.deletesSeen == 0)
        #expect(diagnostics.liveCount == 0)
        #expect(diagnostics.realIconCount == 0)
        #expect(diagnostics.iconSkippedCount == 0)
        #expect(diagnostics.cachedIconCount == 0)
        #expect(diagnostics.realIconMaxObserved == 0)
        #expect(diagnostics.storeOverflowCount == 0)
        #expect(diagnostics.storeOversizeRefusalCount == 0)
        #expect(diagnostics.clicksForwarded == 0)
        #expect(diagnostics.clicksDroppedIconGone == 0)
        #expect(diagnostics.notifyEventsSent == 0)
        #expect(diagnostics.observedNotifyIconVersions.isEmpty)
    }

    // MARK: - adr/0023 D-8 ①: entries, liveCount and the change stream

    /// ① W6-1: after any create / update / delete sequence the live entry count, `liveCount` and
    /// `creates - deletes` (for orders that hit live keys) agree; entries keep first-seen order;
    /// an update rewrites in place; `removeAll()` empties the table but no counter.
    @Test("① entries follow create / update / delete / removeAll, liveCount == entries.count, first-seen order")
    func entriesFollowTheOrders() {
        let controller = TrayStatusController()
        var changes: [TrayStatusController.MenuChange] = []
        controller.onMenuChange = { changes.append($0) }

        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 10, ownerWindowTitle: nil, icon: trayTestPayload(tip: "a"))
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 11, ownerWindowTitle: nil, icon: trayTestPayload(tip: "b"))
        controller.handleNotifyIconCreate(windowId: 2, notifyIconId: 10, ownerWindowTitle: nil, icon: trayTestPayload(tip: "c"))
        controller.handleNotifyIconUpdate(windowId: 1, notifyIconId: 11, ownerWindowTitle: nil, icon: trayTestPayload(tip: "b2"))
        #expect(controller.entries.map(\.title) == ["a", "b2", "c"])
        #expect(controller.diagnostics().liveCount == 3)

        controller.handleNotifyIconDelete(windowId: 1, notifyIconId: 10)
        #expect(controller.entries.map(\.key) == [
            NotifyIconState(windowId: 1, notifyIconId: 11), NotifyIconState(windowId: 2, notifyIconId: 10),
        ])
        let mid = controller.diagnostics()
        #expect(mid.liveCount == controller.entries.count)
        #expect(mid.liveCount == mid.createsSeen - mid.deletesSeen)

        // An unknown delete counts the order, changes nothing, announces nothing.
        let before = changes.count
        controller.handleNotifyIconDelete(windowId: 9, notifyIconId: 9)
        #expect(changes.count == before)
        #expect(controller.diagnostics().deletesSeen == 2)
        #expect(controller.entries.count == 2)

        controller.removeAll()
        let after = controller.diagnostics()
        #expect(controller.entries.isEmpty)
        #expect(after.liveCount == 0)
        #expect(after.realIconCount == 0)
        #expect(after.createsSeen == 3 && after.updatesSeen == 1 && after.deletesSeen == 2, "counters survive removeAll()")
        #expect(changes == [
            .inserted(index: 0), .inserted(index: 1), .inserted(index: 2), .updated(index: 1),
            .removed(index: 0, key: NotifyIconState(windowId: 1, notifyIconId: 10)), .removedAll,
        ])
    }

    @Test("① an update before any create appends an entry; a repeated create rewrites in place")
    func updateBeforeCreateAndRecreate() {
        let controller = TrayStatusController()
        var changes: [TrayStatusController.MenuChange] = []
        controller.onMenuChange = { changes.append($0) }
        controller.handleNotifyIconUpdate(windowId: 3, notifyIconId: 1, ownerWindowTitle: "Owner", icon: .absent)
        controller.handleNotifyIconCreate(windowId: 3, notifyIconId: 1, ownerWindowTitle: "Owner", icon: trayTestPayload(tip: "x"))
        #expect(changes == [.inserted(index: 0), .updated(index: 0)])
        #expect(controller.entries.count == 1)
        #expect(controller.entries[0].title == "x")
    }

    // MARK: - ②: the icon

    @Test("② a real bitmap becomes a 16 pt non-template image; no icon or a refused one, the template placeholder")
    func iconForm() throws {
        let controller = TrayStatusController()
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: nil, icon: trayTestPayload(side: 32))
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 2, ownerWindowTitle: nil, icon: .absent)
        controller.handleNotifyIconCreate(
            windowId: 1, notifyIconId: 3, ownerWindowTitle: nil,
            icon: .init(rgba: nil, width: 0, height: 0, skipped: true, cached: false, toolTip: nil)
        )
        // Short pixel data for its stated size: refused by the decoder, placeholder shown.
        controller.handleNotifyIconCreate(
            windowId: 1, notifyIconId: 4, ownerWindowTitle: nil,
            icon: .init(rgba: trayTestRGBA(side: 4), width: 16, height: 16, skipped: false, cached: false, toolTip: nil)
        )
        let entries = controller.entries
        try #require(entries.count == 4)
        #expect(entries[0].isPlaceholder == false)
        #expect(entries[0].image.isTemplate == false)
        #expect(entries[0].image.size == NSSize(width: 16, height: 16))
        #expect(TrayStatusController.menuItemIconEdge == 16)
        for entry in entries.dropFirst() {
            #expect(entry.isPlaceholder)
            #expect(entry.image === TrayStatusController.placeholderImage)
            #expect(entry.image.isTemplate)
        }
        let diagnostics = controller.diagnostics()
        #expect(diagnostics.realIconCount == 1)
        #expect(diagnostics.realIconMaxObserved == 1)
        #expect(diagnostics.iconSkippedCount == 1)

        // An update that brings the real bitmap flips the placeholder off, in place.
        controller.handleNotifyIconUpdate(windowId: 1, notifyIconId: 2, ownerWindowTitle: nil, icon: trayTestPayload(side: 16))
        #expect(controller.entries[1].isPlaceholder == false)
        #expect(controller.diagnostics().realIconCount == 2)
    }

    // MARK: - ④: the title table (adr/0023 D-1 N-a)

    @Test(
        "④ title: wire tooltip, then owner title, then Tray app n; first line; control and format characters gone; 48 graphemes + …",
        arguments: [
            // (wire, owner, expected title, expected tooltip)
            ("Volume", nil, "Volume", "Volume"),
            ("", "Owner window", "Owner window", "Owner window"),
            (nil, "Owner window", "Owner window", "Owner window"),
            ("\u{0007}\u{202E}\n  ", "Owner", "Owner", "Owner"),
            ("Line one\r\nLine two", nil, "Line one", "Line one\nLine two"),
            ("\n\nSecond\u{2028}Third", nil, "Second", "Second\nThird"),
            ("Bi\u{202E}di\u{2066}x\u{200F}", nil, "Bidix", "Bidix"),
            ("Tab\there", nil, "Tab here", "Tab here"),
            ("👩‍💻 dev", nil, "👩‍💻 dev", "👩‍💻 dev"),
        ] as [(String?, String?, String, String)]
    )
    func titleTable(wire: String?, owner: String?, title: String, toolTip: String) {
        let text = TrayStatusController.menuText(wire: wire, ownerWindowTitle: owner, ordinal: 1)
        #expect(text.title == title)
        #expect(text.toolTip == toolTip)
    }

    @Test("④ nothing usable: the numbered fallback, with no tooltip; numbers are first-seen and stable per key")
    func fallbackTitleIsNumbered() {
        let none = TrayStatusController.menuText(wire: "\u{0001}", ownerWindowTitle: " ", ordinal: 3)
        #expect(none.title == "Tray app 3")
        #expect(none.toolTip == nil)

        let controller = TrayStatusController()
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: nil)
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 2, ownerWindowTitle: nil)
        controller.handleNotifyIconDelete(windowId: 1, notifyIconId: 1)
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: nil)
        #expect(controller.entries.map(\.title) == ["Tray app 2", "Tray app 1"])
        controller.removeAll()
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 2, ownerWindowTitle: nil)
        #expect(controller.entries.map(\.title) == ["Tray app 1"], "a new connection numbers from 1")
    }

    @Test("④ a long title is cut at 48 grapheme clusters plus an ellipsis; the tooltip keeps all of it")
    func longTitleIsCutByGrapheme() {
        let long = String(repeating: "é", count: 30) + String(repeating: "👍🏽", count: 30)
        let text = TrayStatusController.menuText(wire: long, ownerWindowTitle: nil, ordinal: 1)
        #expect(text.title.count == 49)
        #expect(text.title.hasSuffix("…"))
        #expect(text.title == String(long.prefix(48)) + "…")
        #expect(text.toolTip == long)
        let exact = String(repeating: "x", count: 48)
        #expect(TrayStatusController.menuText(wire: exact, ownerWindowTitle: nil, ordinal: 1).title == exact)
        #expect(TrayStatusController.menuTitleLimit == 48)
    }

    @Test("④ a tooltip-less update keeps the wire tooltip (delta merge) instead of falling back to the owner title")
    func tooltipLessUpdateKeepsTheWireTitle() {
        let controller = TrayStatusController()
        controller.handleNotifyIconCreate(windowId: 1, notifyIconId: 1, ownerWindowTitle: "Owner", icon: trayTestPayload(tip: "Wire"))
        controller.handleNotifyIconUpdate(windowId: 1, notifyIconId: 1, ownerWindowTitle: "Owner", icon: trayTestPayload(tip: nil))
        #expect(controller.entries[0].title == "Wire")
    }

    // MARK: - ⑤: the click, controller side

    @Test("⑤ a click on a live entry's tag forwards exactly that key once; a deleted key's tag is dropped")
    func clickForwardsTheLiveKey() {
        let controller = TrayStatusController()
        var forwarded: [NotifyIconState] = []
        controller.onLeftClick = { forwarded.append(NotifyIconState(windowId: $0, notifyIconId: $1)) }
        controller.handleNotifyIconCreate(windowId: 0xFFFF_FFFF, notifyIconId: 0x8000_0001, ownerWindowTitle: nil)
        let entry = controller.entries[0]
        controller.handleLeftClick(tag: entry.tag)
        #expect(forwarded == [NotifyIconState(windowId: 0xFFFF_FFFF, notifyIconId: 0x8000_0001)])
        #expect(controller.diagnostics().clicksForwarded == 1)

        controller.handleNotifyIconDelete(windowId: 0xFFFF_FFFF, notifyIconId: 0x8000_0001)
        controller.handleLeftClick(tag: entry.tag)
        #expect(forwarded.count == 1)
        #expect(controller.diagnostics().clicksDroppedIconGone == 1)
    }

    // MARK: - ⑦: isolation

    @Test("⑦ TrayStatusController is @MainActor (source pin, call shape)")
    func controllerIsMainActor() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RemoteWindowRendering/TrayStatusController.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("@MainActor\nfinal class TrayStatusController {"))
    }
}
