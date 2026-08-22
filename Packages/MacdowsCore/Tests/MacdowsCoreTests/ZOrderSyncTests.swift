import Testing
@testable import MacdowsCore

/// Phase 2 W1's final slice (docs/plans/phase2.md §2 W1, §9 D3): unit coverage for
/// `ZOrderSync.plan(...)`'s adr/0008 §2a/§4 contract, entirely offline -- no AppKit, no
/// `RemoteWindowRegistry`, matching `WindowMappabilityTests`'/`FocusAuthorityTests`' own
/// no-AppKit precedent for this package's pure-logic surface.
@Suite("ZOrderSync")
struct ZOrderSyncTests {
    @Test("empty server array: no-op, nothing skipped")
    func emptyArrayNoOp() {
        let plan = ZOrderSync.plan(serverTopDown: [], locallyKnown: [1, 2, 3], currentLocalTopDown: [1, 2, 3])
        #expect(plan.instructions.isEmpty)
        #expect(plan.unknownSkippedCount == 0)
    }

    @Test("single known window in the array: trivially in order, no instructions")
    func singleWindowTrivial() {
        let plan = ZOrderSync.plan(serverTopDown: [42], locallyKnown: [42], currentLocalTopDown: [42])
        #expect(plan.instructions.isEmpty)
        #expect(plan.unknownSkippedCount == 0)
    }

    @Test("exact match: local stacking already matches the server's relative order -- no-op")
    func exactMatchNoOp() {
        let plan = ZOrderSync.plan(
            serverTopDown: [10, 20, 30],
            locallyKnown: [10, 20, 30],
            currentLocalTopDown: [10, 20, 30]
        )
        #expect(plan.instructions.isEmpty)
        #expect(plan.unknownSkippedCount == 0)
    }

    @Test("exact match with extra untouched local windows interleaved: still a no-op")
    func exactMatchIgnoresUntouchedInterleaving() {
        // Locally, window 99 (not in the server array at all) sits between 10 and 20 --
        // must not affect the match check, since only ids present in BOTH sequences count.
        let plan = ZOrderSync.plan(
            serverTopDown: [10, 20, 30],
            locallyKnown: [10, 20, 30, 99],
            currentLocalTopDown: [10, 99, 20, 30]
        )
        #expect(plan.instructions.isEmpty)
    }

    @Test("full reorder: server order is the exact reverse of local order")
    func fullReorder() {
        let plan = ZOrderSync.plan(
            serverTopDown: [30, 20, 10],
            locallyKnown: [10, 20, 30],
            currentLocalTopDown: [10, 20, 30]
        )
        #expect(plan.instructions == [
            ZOrderSync.Instruction(windowId: 30, belowWindowId: nil),
            ZOrderSync.Instruction(windowId: 20, belowWindowId: 30),
            ZOrderSync.Instruction(windowId: 10, belowWindowId: 20),
        ])
        #expect(plan.unknownSkippedCount == 0)
    }

    @Test("unknown ids in the server array (not locally known) are skipped, not treated as an error")
    func unknownIdsSkipped() {
        // 999 and 888 are in the server's array but this client has never heard of them
        // (filtered by W0 mappability, or not yet created) -- adr/0008 §4: skip, count,
        // never abort.
        let plan = ZOrderSync.plan(
            serverTopDown: [999, 10, 888, 20, 30],
            locallyKnown: [10, 20, 30],
            currentLocalTopDown: [30, 20, 10]
        )
        #expect(plan.unknownSkippedCount == 2)
        // Target order, with the unknown ids filtered out, is [10, 20, 30] -- local is the
        // exact reverse, so a full reorder is expected, entirely in terms of the known ids.
        #expect(plan.instructions == [
            ZOrderSync.Instruction(windowId: 10, belowWindowId: nil),
            ZOrderSync.Instruction(windowId: 20, belowWindowId: 10),
            ZOrderSync.Instruction(windowId: 30, belowWindowId: 20),
        ])
    }

    @Test("a locally-known window absent from the server array is never referenced by any instruction")
    func absentLocalUntouched() {
        // Window 99 is known locally and currently sits on top, but the server's array
        // never mentions it at all -- adr/0008 §4: "local windows ABSENT from the array
        // are left untouched," never demoted for being absent, never referenced.
        let plan = ZOrderSync.plan(
            serverTopDown: [30, 20, 10],
            locallyKnown: [10, 20, 30, 99],
            currentLocalTopDown: [99, 10, 20, 30]
        )
        let referencedIds = Set(plan.instructions.map(\.windowId) + plan.instructions.compactMap(\.belowWindowId))
        #expect(!referencedIds.contains(99))
        #expect(plan.unknownSkippedCount == 0)
        // The known subset (10, 20, 30) is currently in server-reversed order (local has
        // them 10, 20, 30 -- excluding 99 -- while server wants 30, 20, 10), so a reorder
        // over exactly those three ids is still expected.
        #expect(plan.instructions == [
            ZOrderSync.Instruction(windowId: 30, belowWindowId: nil),
            ZOrderSync.Instruction(windowId: 20, belowWindowId: 30),
            ZOrderSync.Instruction(windowId: 10, belowWindowId: 20),
        ])
    }

    @Test("a truncated server array (already bounded upstream) still applies its known prefix normally")
    func truncatedArrayStillApplies() {
        // adr/0008 §4: truncation already happened before this array ever reaches
        // ZOrderSync (CRDPQ_MAX_WINDOW_IDS bounds it upstream) -- this function has no
        // special-case truncation handling at all, and none is needed: it just applies
        // whatever ids it's given, in the order given. Simulate a 96-entry truncated
        // array (the real upper bound, adr/0008 §2a) reduced here to a representative
        // handful for test legibility.
        let plan = ZOrderSync.plan(
            serverTopDown: [5, 4, 3, 2, 1],
            locallyKnown: [1, 2, 3, 4, 5],
            currentLocalTopDown: [1, 2, 3, 4, 5]
        )
        #expect(plan.unknownSkippedCount == 0)
        #expect(plan.instructions.count == 5)
        #expect(plan.instructions.first == ZOrderSync.Instruction(windowId: 5, belowWindowId: nil))
        #expect(plan.instructions.last == ZOrderSync.Instruction(windowId: 1, belowWindowId: 2))
    }

    @Test("Plan.target/currentRestricted expose exactly what was compared, even in the no-op branches")
    func debugFieldsExposeInternalComparison() {
        // Trivial branch (target.count <= 1): target/currentRestricted must still reflect
        // the real filtered values, not be left empty/uncomputed.
        let trivial = ZOrderSync.plan(serverTopDown: [999, 42], locallyKnown: [42], currentLocalTopDown: [42])
        #expect(trivial.target == [42])
        #expect(trivial.currentRestricted == [42])

        // Exact-match branch: both sides equal, confirming instructions.isEmpty really
        // does mean currentRestricted == target, not just an independently-true coincidence.
        let matched = ZOrderSync.plan(serverTopDown: [10, 20, 30], locallyKnown: [10, 20, 30], currentLocalTopDown: [10, 20, 30])
        #expect(matched.target == matched.currentRestricted)
        #expect(matched.target == [10, 20, 30])

        // Reorder branch: target/currentRestricted differ (that's WHY instructions is non-empty).
        let reordered = ZOrderSync.plan(serverTopDown: [30, 20, 10], locallyKnown: [10, 20, 30], currentLocalTopDown: [10, 20, 30])
        #expect(reordered.target == [30, 20, 10])
        #expect(reordered.currentRestricted == [10, 20, 30])
        #expect(reordered.target != reordered.currentRestricted)
    }

    @Test("a currentLocalTopDown missing some target ids still produces a safe, correct full reorder")
    func incompleteCurrentOrderFallsBackToFullReorder() {
        // Defensive case: locallyKnown says window 30 exists, but the caller's own
        // stacking snapshot never mentions it (e.g. a momentarily stale read) -- must not
        // crash; falls through to the general "not an exact match" branch, which always
        // produces a correct (if possibly redundant) full instruction list.
        let plan = ZOrderSync.plan(
            serverTopDown: [10, 20, 30],
            locallyKnown: [10, 20, 30],
            currentLocalTopDown: [10, 20]
        )
        #expect(plan.instructions == [
            ZOrderSync.Instruction(windowId: 10, belowWindowId: nil),
            ZOrderSync.Instruction(windowId: 20, belowWindowId: 10),
            ZOrderSync.Instruction(windowId: 30, belowWindowId: 20),
        ])
    }
}
