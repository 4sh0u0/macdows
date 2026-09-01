import AppKit
import MacdowsCore
import Testing

// Lane D7: `TrayStatusController`'s seams that never touch `NSStatusBar`. See
// DisplayTopologyProviderTests.swift's file header for the lane's shared coverage-boundary
// register; boundaries specific to THIS file:
//
//  * `handleNotifyIconCreate/Update/Delete`'s live half and `removeAll()` install/remove REAL
//    `NSStatusItem`s on the running user session's menu bar (`NSStatusBar.system`), and
//    `handleLeftClick`'s FORWARD branch is only reachable once a live item exists for the
//    key. Deliberately not exercised from a test bundle: mutating the operator's actual menu
//    bar is a side effect a unit run must not have, and there is no injection seam for the
//    status bar (adding one is exactly the test-motivated Sources change the D7 boundary
//    forbids). The drop branch, which the guard makes reachable without any item, IS pinned.
//  * `menuBarImage(from:)` / `resolvedTooltip(wire:ownerWindowTitle:)` are `private`.
//    The tooltip precedence and the delta-merge they feed are pinned at the `TrayModel`
//    level by MacdowsCore's own `swift test` suite; the CGImage decode has no reachable seam.

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

    /// adr/0014 §4: a click whose key has no live `NSStatusItem` is DROPPED -- counted in
    /// `clicksDroppedIconGone`, never handed to `onLeftClick`, never counted as forwarded.
    /// (The guard is what makes this branch reachable with no menu-bar side effect at all.)
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

        let diagnostics = controller.diagnostics()
        #expect(diagnostics.notifyEventsSent == 3)
        #expect(diagnostics.storeOverflowCount == 3)
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
        #expect(diagnostics.clicksForwarded == 0)
        #expect(diagnostics.clicksDroppedIconGone == 0)
        #expect(diagnostics.notifyEventsSent == 0)
        #expect(diagnostics.observedNotifyIconVersions.isEmpty)
    }
}
