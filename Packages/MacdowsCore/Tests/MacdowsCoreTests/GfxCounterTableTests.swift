import CRDPQueue
import Foundation
import Testing

// ADR-0018 §5.2 ②, the bridge half. The lane's whole verdict (4a "the client dropped a frame the
// server drew" vs 4b "the server only mapped the surface and never drew") is read off three
// numbers per surface id, so the table that holds them has to be right about exactly three
// things, none of which the live run can check for itself:
//   * `dirty <= updates` always -- the pair IS the 4b test, and a dirty count that could
//     outrun its update count would let "the server drew" be concluded from bookkeeping alone;
//   * a surface the table never saw reads as NOT TRACKED, never as zeros -- zeros are 4b's
//     signature, so a capacity overflow silently formatted as 0/0/0 would manufacture the
//     lane's own conclusion;
//   * counts are per surface id and monotonic for the session -- the remapped-window case the
//     lane exists for is precisely "one window, several surface ids, different histories".
@Suite("GFX per-surface frame counters (ADR-0018 §5.2 ②, measurement only)")
struct GfxCounterTableTests {
    private func withTable(_ body: (OpaquePointer) -> Void) {
        let table = crgfx_counters_create()
        precondition(table != nil)
        defer { crgfx_counters_destroy(table) }
        body(table!)
    }

    /// Reads all four counters, or `nil` for "this table has never seen that surface id".
    private func read(_ table: OpaquePointer, _ surfaceId: UInt32)
        -> (updates: UInt64, dirty: UInt64, publishes: UInt64, stale: UInt64)?
    {
        var updates: UInt64 = 0
        var dirty: UInt64 = 0
        var publishes: UInt64 = 0
        var stale: UInt64 = 0
        guard crgfx_counters_read(table, surfaceId, &updates, &dirty, &publishes, &stale) else {
            return nil
        }
        return (updates, dirty, publishes, stale)
    }

    @Test("a surface nobody ever touched is NOT TRACKED, which is not the same answer as zero")
    func unseenSurfacesAreUntrackedRatherThanZero() {
        withTable { table in
            #expect(read(table, 0) == nil)
            #expect(read(table, 4242) == nil)
            // Surface id 0 is a legal GFX id, so "never seen" cannot be encoded as a zero key:
            // once touched, it must read as tracked with real counts.
            crgfx_counters_note_update(table, 0, false)
            let zero = read(table, 0)
            #expect(zero?.updates == 1 && zero?.dirty == 0 && zero?.publishes == 0)
            #expect(zero?.stale == 0)
        }
    }

    @Test("the dirty count is a subset of the update count, one surface at a time")
    func dirtyIsASubsetOfUpdates() {
        withTable { table in
            // 4b's shape: the hook ran for this surface, and every single time the invalid
            // region was empty -- the server mapped it and drew nothing.
            for _ in 0..<5 { crgfx_counters_note_update(table, 7, false) }
            #expect(read(table, 7)?.updates == 5)
            #expect(read(table, 7)?.dirty == 0)

            // 4a's shape: same hook, same surface, the server did draw.
            crgfx_counters_note_update(table, 7, true)
            crgfx_counters_note_update(table, 7, true)
            #expect(read(table, 7)?.updates == 7)
            #expect(read(table, 7)?.dirty == 2)
        }
    }

    @Test("publishes count the hook's exit, and never invent a slot the entry side did not claim")
    func publishesAreCountedAgainstAnAlreadySeenSurface() {
        withTable { table in
            // A publish for a surface that never entered the hook cannot happen on the real
            // path; if it ever did, it is a defect in the bridge, and inventing a slot here
            // would report it as a legitimately measured surface.
            crgfx_counters_note_publish(table, 9)
            #expect(read(table, 9) == nil)

            crgfx_counters_note_update(table, 9, true)
            crgfx_counters_note_publish(table, 9)
            #expect(read(table, 9)?.updates == 1)
            #expect(read(table, 9)?.publishes == 1)
            // updates > publishes is the "the bridge accepted a frame and never forwarded it"
            // signal the two counters exist to make visible.
            crgfx_counters_note_update(table, 9, true)
            #expect(read(table, 9)?.updates == 2)
            #expect(read(table, 9)?.publishes == 1)
        }
    }

    @Test("each surface id of a remapped window keeps its own history")
    func countsAreKeptPerSurfaceId() {
        withTable { table in
            // The 2026-09-15 About window in miniature: a first surface that was drawn into and
            // published, then two remaps. If the table merged ids, the later surfaces would
            // inherit the first one's counts and every run would read as 4a.
            crgfx_counters_note_update(table, 100, true)
            crgfx_counters_note_publish(table, 100)
            crgfx_counters_note_update(table, 200, false)
            #expect(read(table, 100)?.updates == 1)
            #expect(read(table, 100)?.dirty == 1)
            #expect(read(table, 100)?.publishes == 1)
            #expect(read(table, 200)?.updates == 1)
            #expect(read(table, 200)?.dirty == 0)
            #expect(read(table, 200)?.publishes == 0)
            #expect(read(table, 300) == nil)
        }
    }

    @Test("a reconnect-discarded frame is counted against its own surface, never inventing a slot")
    func staleDiscardsAreCountedPerSurface() {
        withTable { table in
            // The gap this counter closes (gate r1 I-1): between the bridge's publish and
            // anything the registry can see, the drain throws away every event left over from an
            // older connection generation. Without it a surface reads `publishes=N` and silence.
            crgfx_counters_note_stale(table, 3)
            #expect(read(table, 3) == nil, "a stale event alone must not claim a slot")

            crgfx_counters_note_update(table, 3, true)
            crgfx_counters_note_publish(table, 3)
            crgfx_counters_note_stale(table, 3)
            let row = read(table, 3)
            #expect(row?.publishes == 1 && row?.stale == 1)
            // ... and it is its own counter, not a re-labelling of one of the others.
            #expect(row?.updates == 1 && row?.dirty == 1)
        }
    }

    @Test("a full table stops tracking NEW ids and keeps the ones it already holds exact")
    func capacityOverflowLeavesNewIdsUntrackedAndOldOnesIntact() {
        withTable { table in
            for id in 0..<UInt32(CRGFX_COUNTERS_SLOTS) {
                crgfx_counters_note_update(table, id, true)
            }
            #expect(read(table, 0)?.updates == 1)
            #expect(read(table, UInt32(CRGFX_COUNTERS_SLOTS) - 1)?.updates == 1)

            // One past the capacity: dropped, not attributed to somebody else's slot.
            let overflowId = UInt32(CRGFX_COUNTERS_SLOTS)
            crgfx_counters_note_update(table, overflowId, true)
            crgfx_counters_note_publish(table, overflowId)
            crgfx_counters_note_stale(table, overflowId)
            #expect(read(table, overflowId) == nil)

            // ... and the already-tracked ids keep counting, so an overflow costs the run only
            // the surfaces that appeared after it.
            crgfx_counters_note_update(table, 0, true)
            #expect(read(table, 0)?.updates == 2)
            #expect(read(table, 0)?.dirty == 2)
            for id in 0..<UInt32(CRGFX_COUNTERS_SLOTS) {
                #expect(read(table, id) != nil)
            }
        }
    }

    @Test("a NULL table is inert rather than fatal")
    func aNullTableIsInert() {
        // `crgfx_counters_create` can fail only under allocation failure, and a session that
        // lost its diagnostic must keep rendering -- so every entry point tolerates NULL.
        crgfx_counters_note_update(nil, 1, true)
        crgfx_counters_note_publish(nil, 1)
        crgfx_counters_note_stale(nil, 1)
        var updates: UInt64 = 7
        #expect(crgfx_counters_read(nil, 1, &updates, nil, nil, nil) == false)
        #expect(updates == 7)
        crgfx_counters_destroy(nil)
    }
}
