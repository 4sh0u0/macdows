import Foundation

/// Phase 2 W1's final slice (`docs/plans/phase2.md` §2 W1, §9 D3 -- "焦点闭环达标后才写Z序策略",
/// unlocked once the focus gate soaked clean): turns the server's authoritative top-down
/// `MonitoredDesktop.windowIds` array (adr/0008 §2a) into the minimal set of local
/// stacking-order changes a consumer needs to apply, without ever touching AppKit itself --
/// same no-AppKit boundary as `WindowMappability`/`FocusAuthority` (adr/0006 §2), and a
/// stateless pure function over its inputs, not a persistent state machine (`WindowMappability`'s
/// precedent, not `FocusAuthority`'s -- there is no cross-call state to own here).
///
/// `RemoteWindowRegistry` is the only consumer: it gathers the AppKit-side inputs (which
/// windowIds it currently renders, and their current on-screen stacking order) and executes
/// the returned `Instruction` list against real `NSWindow`s.
public enum ZOrderSync {
    /// One window that needs to move. Instructions are always returned in top-down order
    /// (index 0 first); applying them in that order lets a consumer rely on
    /// `belowWindowId`'s window already being in its correct final position by the time
    /// each instruction is applied -- see `plan(serverTopDown:locallyKnown:currentLocalTopDown:)`'s
    /// own doc comment for why that invariant holds.
    public struct Instruction: Sendable, Equatable {
        public let windowId: UInt32
        /// The known windowId `windowId` must end up directly below, once this and every
        /// earlier instruction in the same list have been applied. `nil` only for the
        /// topmost entry of the target subsequence -- "no known window belongs above this
        /// one," i.e. `windowId` should become the frontmost window of the app.
        public let belowWindowId: UInt32?
    }

    /// `plan(...)`'s return value. `instructions` is empty both when there is nothing to
    /// reorder (adr/0008 §2a: "output empty when the relative order of the known subset
    /// already matches") and when fewer than two locally-known windows appear in
    /// `serverTopDown` at all (no relative order to establish either way).
    public struct Plan: Sendable, Equatable {
        public let instructions: [Instruction]
        /// Count of `serverTopDown` entries that aren't in `locallyKnown` -- filtered out
        /// by W0's style/owner mappability check, or a window the server has created but
        /// this client hasn't drained a `WindowCreate` for yet. Never an error (adr/0008
        /// §4: truncation/unknown-id gaps are precision degradation, not a failure) --
        /// purely a count for the caller's own observability.
        public let unknownSkippedCount: Int
        /// Debug/observability only (not needed to apply the plan): `serverTopDown`
        /// restricted to `locallyKnown`, in server order -- the exact "target" relative
        /// order this call computed and compared against. `instructions.isEmpty` is
        /// equivalent to `currentRestricted == target`; both are exposed so a caller
        /// instrumenting a live mismatch can print precisely what this function actually
        /// compared, rather than re-deriving an approximation elsewhere that could
        /// silently diverge from what this function really did.
        public let target: [UInt32]
        /// Debug/observability only: `currentLocalTopDown` restricted to `Set(target)`, in
        /// local order -- the other side of the comparison `instructions.isEmpty` reflects.
        public let currentRestricted: [UInt32]
    }

    /// - Parameters:
    ///   - serverTopDown: MS-RDPERP's own top-down Z order (adr/0008 §2a) -- the most
    ///     recent `MonitoredDesktop.windowIds` array. May already be truncated (adr/0008
    ///     §4's `CRDPQ_MAX_WINDOW_IDS` bound); this function makes no assumption about
    ///     whether or how it was bounded, and applies exactly the ids it's given, in order.
    ///   - locallyKnown: every windowId the caller currently renders as a real window.
    ///     `RemoteWindowRegistry` (2026-08-23 Z-order reversal investigation) derives this
    ///     as exactly `Set(currentLocalTopDown)` -- an id must be genuinely on screen to
    ///     touch, and `currentLocalTopDown` is already ground truth for that -- which means
    ///     `locallyKnown ⊆ Set(currentLocalTopDown)` always holds at that call site (see
    ///     the guard below). This function still accepts a `locallyKnown` that names ids
    ///     `currentLocalTopDown` doesn't (a general caller might reasonably track "known"
    ///     separately from "currently laid out"); it just isn't exercised that way by
    ///     `RemoteWindowRegistry` itself anymore.
    ///   - currentLocalTopDown: the caller's own current top-down (topmost-first) stacking
    ///     order. Ids outside `locallyKnown`, or outside `serverTopDown`, are ignored --
    ///     only their relative positions matter, never their absolute ones.
    ///
    /// adr/0008 §4's binding truncation rule, applied here exactly:
    ///   - an id in `serverTopDown` but not in `locallyKnown` is silently skipped (counted
    ///     in `unknownSkippedCount`, never an error) -- "跳过数组内本地未知的id";
    ///   - a `locallyKnown` id absent from `serverTopDown` is NEVER referenced by any
    ///     returned `Instruction` -- it simply never enters `target` below, so nothing
    ///     about its position is ever asserted or moved: "绝不因不在数组里推断该窗口应被置底."
    public static func plan(
        serverTopDown: [UInt32],
        locallyKnown: Set<UInt32>,
        currentLocalTopDown: [UInt32]
    ) -> Plan {
        var unknownSkipped = 0
        var target: [UInt32] = []
        target.reserveCapacity(serverTopDown.count)
        for id in serverTopDown {
            if locallyKnown.contains(id) {
                target.append(id)
            } else {
                unknownSkipped += 1
            }
        }

        // Computed unconditionally (even in the trivial branches below) so `Plan.target`/
        // `currentRestricted` always reflect exactly what this call would have compared,
        // for debug/observability -- cheap (a single filter pass) regardless.
        let targetSet = Set(target)
        let currentRestricted = currentLocalTopDown.filter { targetSet.contains($0) }

        // Fewer than two known windows in the array: there is no relative order to
        // establish (a single window is trivially "in order" with itself; zero means the
        // array was empty or nothing in it was locally known).
        guard target.count > 1 else {
            return Plan(instructions: [], unknownSkippedCount: unknownSkipped, target: target, currentRestricted: currentRestricted)
        }

        guard currentRestricted != target else {
            // Already in the right relative order -- nothing to do (a caller-side
            // `currentLocalTopDown` that's missing some of `target`'s ids, e.g. from a
            // stale snapshot, can never accidentally hit this branch: a length mismatch
            // makes `!=` true, falling through to the full-reorder path below, which is
            // always correct even if redundant).
            return Plan(instructions: [], unknownSkippedCount: unknownSkipped, target: target, currentRestricted: currentRestricted)
        }

        // Not already matching -- (re)apply the full target order top-down. Each
        // instruction anchors `windowId` directly below `target[index - 1]`, which by
        // induction is already in its correct final position once this instruction runs:
        // the very first entry (index 0) has no anchor (`belowWindowId == nil`, "make this
        // the frontmost window"), and every later entry's anchor was itself either already
        // correctly placed (never touched) or was placed by exactly this same loop one
        // iteration earlier -- so processing top-down, in order, is always sufficient.
        var instructions: [Instruction] = []
        instructions.reserveCapacity(target.count)
        for (index, id) in target.enumerated() {
            instructions.append(Instruction(windowId: id, belowWindowId: index == 0 ? nil : target[index - 1]))
        }
        return Plan(instructions: instructions, unknownSkippedCount: unknownSkipped, target: target, currentRestricted: currentRestricted)
    }
}
