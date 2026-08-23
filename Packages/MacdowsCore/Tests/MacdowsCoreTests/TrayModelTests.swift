import Testing
@testable import MacdowsCore

/// Phase 2 W6 (docs/plans/phase2.md §2 W6 / §4 W6 acceptance: "NSStatusItem 数量 ==
/// create−delete, delete 清零"): offline unit coverage for `TrayModel`'s create/update/delete
/// policy -- entirely no-AppKit, matching `MinMaxInfoTranslatorTests`'/`ZOrderSyncTests`' own
/// precedent for this package's pure-logic surface. `TrayStatusController` (App target) is
/// what actually turns this into real `NSStatusItem`s; these tests only cover the state
/// machine it's driven by.
///
/// Every mutating-call result is captured into a local `let` before being handed to
/// `#expect` -- `#expect(model.create(...))` directly doesn't compile (the macro's function-
/// call rewrite treats the receiver as immutable, "cannot use mutating member on immutable
/// value: '$0' is immutable"), so this file never calls a mutating `TrayModel` method as a
/// direct `#expect` argument.
@Suite("TrayModel")
struct TrayModelTests {
    @Test("count == creates - deletes across a create/create/create/delete sequence")
    func countMatchesCreateMinusDelete() {
        var model = TrayModel()
        let created1 = model.create(windowId: 1, notifyIconId: 100)
        let created2 = model.create(windowId: 1, notifyIconId: 101)
        let created3 = model.create(windowId: 2, notifyIconId: 200)
        #expect(created1)
        #expect(created2)
        #expect(created3)
        #expect(model.count == 3)

        let removed = model.delete(windowId: 1, notifyIconId: 101)
        #expect(removed)
        #expect(model.count == 2)
        #expect(model.icons.keys.contains(NotifyIconState(windowId: 1, notifyIconId: 100)))
        #expect(model.icons.keys.contains(NotifyIconState(windowId: 2, notifyIconId: 200)))
    }

    @Test("update-in-place: an Update for an already-tracked key replaces its info without changing count")
    func updateInPlace() {
        var model = TrayModel()
        model.create(windowId: 5, notifyIconId: 50, info: TrayIconInfo(tooltip: "before"))
        #expect(model.count == 1)

        let wasNew = model.update(windowId: 5, notifyIconId: 50, info: TrayIconInfo(tooltip: "after"))
        #expect(!wasNew)
        #expect(model.count == 1)
        #expect(model.icons[NotifyIconState(windowId: 5, notifyIconId: 50)]?.tooltip == "after")
    }

    @Test("an Update for a not-yet-created key creates it in place (tolerated, not dropped)")
    func updateBeforeCreateIsTolerated() {
        var model = TrayModel()
        let wasNew = model.update(windowId: 9, notifyIconId: 90, info: TrayIconInfo(tooltip: "first seen as update"))
        #expect(wasNew)
        #expect(model.count == 1)
        #expect(model.icons[NotifyIconState(windowId: 9, notifyIconId: 90)]?.tooltip == "first seen as update")
    }

    @Test("delete-clears: a Delete for a tracked key removes it entirely")
    func deleteClears() {
        var model = TrayModel()
        model.create(windowId: 7, notifyIconId: 70)
        #expect(model.count == 1)

        let removed = model.delete(windowId: 7, notifyIconId: 70)
        #expect(removed)
        #expect(model.count == 0)
        #expect(model.icons.isEmpty)
    }

    @Test("unknown-delete tolerated: a Delete for a key never created is a no-op, not a crash")
    func unknownDeleteIsTolerated() {
        var model = TrayModel()
        let removed = model.delete(windowId: 123, notifyIconId: 456)
        #expect(!removed)
        #expect(model.count == 0)

        // A subsequent, legitimate create/delete pair still behaves normally -- the earlier
        // unknown delete left no residual state behind.
        model.create(windowId: 1, notifyIconId: 1)
        #expect(model.count == 1)
        let removedAgain = model.delete(windowId: 1, notifyIconId: 1)
        #expect(removedAgain)
        #expect(model.count == 0)
    }

    @Test("a duplicate Create for an already-tracked key overwrites info, not counted twice")
    func duplicateCreateOverwrites() {
        var model = TrayModel()
        let wasNewFirstTime = model.create(windowId: 3, notifyIconId: 30, info: TrayIconInfo(tooltip: "v1"))
        #expect(wasNewFirstTime)
        let wasNewSecondTime = model.create(windowId: 3, notifyIconId: 30, info: TrayIconInfo(tooltip: "v2"))
        #expect(!wasNewSecondTime)
        #expect(model.count == 1)
        #expect(model.icons[NotifyIconState(windowId: 3, notifyIconId: 30)]?.tooltip == "v2")
    }

    @Test("windowId is part of the key -- two owner windows reusing the same notifyIconId stay distinct")
    func windowIdDisambiguatesKey() {
        var model = TrayModel()
        model.create(windowId: 1, notifyIconId: 1, info: TrayIconInfo(tooltip: "owner A"))
        model.create(windowId: 2, notifyIconId: 1, info: TrayIconInfo(tooltip: "owner B"))
        #expect(model.count == 2)

        let removed = model.delete(windowId: 1, notifyIconId: 1)
        #expect(removed)
        #expect(model.count == 1)
        #expect(model.icons[NotifyIconState(windowId: 2, notifyIconId: 1)]?.tooltip == "owner B")
    }
}
