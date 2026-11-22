import CRDPQueue
import Foundation
import Testing

// crdpq_clip_store (adr/0026, PROPOSED): the clipboard byte side-store. Byte fixtures are
// invented patterns; no real clipboard content is used anywhere.

enum ClipStoreHarness {
    static let r2l = CRDPQ_CLIP_REMOTE_TO_LOCAL
    static let l2r = CRDPQ_CLIP_LOCAL_TO_REMOTE

    static func put(_ s: OpaquePointer?, _ generation: UInt32, _ direction: crdpq_clip_direction_t, _ key: UInt32,
                    _ bytes: [UInt8]) -> crdpq_clip_result_t {
        bytes.withUnsafeBufferPointer { crdpq_clip_store_put(s, generation, direction, key, $0.baseAddress, $0.count) }
    }

    struct Taken {
        let rc: crdpq_clip_result_t
        let bytes: [UInt8]
        let length: Int
    }

    static func take(_ s: OpaquePointer?, _ generation: UInt32, _ direction: crdpq_clip_direction_t, _ key: UInt32,
                     capacity: Int = 256) -> Taken {
        var dst = [UInt8](repeating: 0xA5, count: capacity)
        var length = -1
        let rc = dst.withUnsafeMutableBufferPointer {
            crdpq_clip_store_take(s, generation, direction, key, $0.baseAddress, $0.count, &length)
        }
        let kept = rc == CRDPQ_CLIP_OK ? Array(dst.prefix(length)) : []
        return Taken(rc: rc, bytes: kept, length: length)
    }

    /// A deterministic, key-dependent pattern, so a block handed to the wrong key is caught.
    static func pattern(key: UInt32, length: Int, salt: UInt8 = 0) -> [UInt8] {
        (0..<length).map { UInt8(truncatingIfNeeded: Int(key) &* 31 &+ $0 &* 7) ^ salt }
    }

    static func refusals(_ s: OpaquePointer?, _ rc: crdpq_clip_result_t) -> Int {
        crdpq_clip_store_refusal_count(s, rc)
    }
}

/// Records every release the store reports. Reached from a C callback through an opaque
/// pointer; the store calls it on whatever thread released the block, hence the lock.
final class ClipReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(length: Int, allZero: Bool)] = []

    func record(length: Int, allZero: Bool) {
        lock.lock(); defer { lock.unlock() }
        entries.append((length, allZero))
    }

    var all: [(length: Int, allZero: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func install(on store: OpaquePointer?) {
        crdpq_clip_store_set_release_observer(store, { bytes, length, ctx in
            guard let ctx else { return }
            let recorder = Unmanaged<ClipReleaseRecorder>.fromOpaque(ctx).takeUnretainedValue()
            let buffer = UnsafeBufferPointer(start: bytes, count: length)
            recorder.record(length: length, allZero: buffer.allSatisfy { $0 == 0 })
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}

@Suite("crdpq_clip_store: one-shot blocks")
struct CRDPQClipStoreBasicsTests {
    typealias H = ClipStoreHarness

    @Test("put then take returns the same bytes, and the take removes the block")
    func roundTripIsOneShot() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        let payload = H.pattern(key: 7, length: 40)
        #expect(H.put(s, 0, H.r2l, 7, payload) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 1)
        #expect(crdpq_clip_store_live_bytes(s) == 40)

        let first = H.take(s, 0, H.r2l, 7)
        #expect(first.rc == CRDPQ_CLIP_OK)
        #expect(first.length == 40)
        #expect(first.bytes == payload)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 0)
        #expect(crdpq_clip_store_live_bytes(s) == 0)

        let second = H.take(s, 0, H.r2l, 7)
        #expect(second.rc == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(second.length == 0)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_NOT_FOUND) == 1)
    }

    @Test("the two directions never overwrite each other, even under the same key")
    func directionsAreSeparate() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        let inbound = H.pattern(key: 5, length: 10, salt: 0x11)
        let outbound = H.pattern(key: 5, length: 20, salt: 0x22)
        #expect(H.put(s, 0, H.r2l, 5, inbound) == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.l2r, 5, outbound) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 1)
        #expect(crdpq_clip_store_live_count(s, H.l2r) == 1)
        #expect(H.take(s, 0, H.l2r, 5).bytes == outbound)
        #expect(H.take(s, 0, H.r2l, 5).bytes == inbound)
    }

    /// Gate r1, m-3: one-shot blocks are never replaced. Under the old upsert the event that
    /// announced the first block would have taken the second block's bytes.
    @Test("a put under a live key is refused as KEY_IN_USE: the live block stays as it was, and the key is free again once taken")
    func liveKeyRefused() {
        for direction in [H.r2l, H.l2r] {
            let s = crdpq_clip_store_create(64, 128)
            defer { crdpq_clip_store_destroy(s) }
            let first = H.pattern(key: 9, length: 30)
            let second = H.pattern(key: 9, length: 12, salt: 0x5A)
            #expect(H.put(s, 0, direction, 9, first) == CRDPQ_CLIP_OK)
            #expect(H.put(s, 0, direction, 9, second) == CRDPQ_CLIP_ERR_KEY_IN_USE, "direction \(direction.rawValue)")
            #expect(H.refusals(s, CRDPQ_CLIP_ERR_KEY_IN_USE) == 1)
            #expect(crdpq_clip_store_live_count(s, direction) == 1)
            #expect(crdpq_clip_store_live_bytes(s) == 30)
            #expect(H.take(s, 0, direction, 9).bytes == first, "direction \(direction.rawValue)")
            #expect(H.take(s, 0, direction, 9).rc == CRDPQ_CLIP_ERR_NOT_FOUND)
            #expect(H.put(s, 0, direction, 9, second) == CRDPQ_CLIP_OK)
            #expect(H.take(s, 0, direction, 9).bytes == second)
        }
    }

    /// Gate r1, m-1: an empty slot's key is 0, so "key 0" is where a lookup that forgot to ask
    /// whether the slot is in use would answer for a block that is not there.
    @Test("a key never put -- key 0 included -- is NOT_FOUND for take and discard; so is a second take of key 0")
    func keyZero() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.take(s, 0, H.r2l, 0).rc == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(crdpq_clip_store_discard(s, 0, H.l2r, 0) == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(H.put(s, 0, H.r2l, 0, [1, 2, 3]) == CRDPQ_CLIP_OK)
        #expect(H.take(s, 0, H.r2l, 0).bytes == [1, 2, 3])
        #expect(H.take(s, 0, H.r2l, 0).rc == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(crdpq_clip_store_discard(s, 0, H.r2l, 0) == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_NOT_FOUND) == 4)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 0)
    }

    @Test("discard removes a block without copying it out")
    func discard() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 8)) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_discard(s, 0, H.r2l, 1) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_bytes(s) == 0)
        #expect(crdpq_clip_store_discard(s, 0, H.r2l, 1) == CRDPQ_CLIP_ERR_NOT_FOUND)
        #expect(H.take(s, 0, H.r2l, 1).rc == CRDPQ_CLIP_ERR_NOT_FOUND)
    }

    @Test("a zero-length block is a legal value: stored, counted as live, taken with no buffer")
    func zeroLength() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(crdpq_clip_store_put(s, 0, H.r2l, 3, nil, 0) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 1)
        #expect(crdpq_clip_store_live_bytes(s) == 0)
        var length = -1
        #expect(crdpq_clip_store_take(s, 0, H.r2l, 3, nil, 0, &length) == CRDPQ_CLIP_OK)
        #expect(length == 0)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 0)
    }

    @Test("a buffer too small is refused with the needed length, and the block stays for a retry")
    func bufferTooSmall() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        let payload = H.pattern(key: 4, length: 33)
        #expect(H.put(s, 0, H.r2l, 4, payload) == CRDPQ_CLIP_OK)
        let short = H.take(s, 0, H.r2l, 4, capacity: 32)
        #expect(short.rc == CRDPQ_CLIP_ERR_BUFFER_TOO_SMALL)
        #expect(short.length == 33)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 1)
        let exact = H.take(s, 0, H.r2l, 4, capacity: 33)
        #expect(exact.rc == CRDPQ_CLIP_OK)
        #expect(exact.bytes == payload)
    }

    @Test("caller bugs are refused as ARGUMENT and counted; a NULL store is refused without a crash")
    func arguments() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        let bogus = crdpq_clip_direction_t(rawValue: 7)
        #expect(H.put(s, 0, bogus, 1, [1, 2]) == CRDPQ_CLIP_ERR_ARGUMENT)
        #expect(crdpq_clip_store_put(s, 0, H.r2l, 1, nil, 4) == CRDPQ_CLIP_ERR_ARGUMENT)
        var length = 0
        #expect(crdpq_clip_store_take(s, 0, H.r2l, 1, nil, 4, &length) == CRDPQ_CLIP_ERR_ARGUMENT)
        #expect(crdpq_clip_store_discard(s, 0, bogus, 1) == CRDPQ_CLIP_ERR_ARGUMENT)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_ARGUMENT) == 4)
        #expect(crdpq_clip_store_live_count(s, bogus) == 0)

        #expect(H.put(nil, 0, H.r2l, 1, [1]) == CRDPQ_CLIP_ERR_ARGUMENT)
        #expect(H.take(nil, 0, H.r2l, 1).rc == CRDPQ_CLIP_ERR_ARGUMENT)
        #expect(crdpq_clip_store_generation(nil) == 0)
        #expect(crdpq_clip_store_clear(nil) == 0)
        #expect(crdpq_clip_store_refusal_count(nil, CRDPQ_CLIP_ERR_ARGUMENT) == 0)
        crdpq_clip_store_destroy(nil)
    }
}

@Suite("crdpq_clip_store: block, total and slot limits")
struct CRDPQClipStoreLimitTests {
    typealias H = ClipStoreHarness

    @Test("a block exactly at the block limit is stored; one byte more is refused before allocation")
    func blockLimit() {
        let s = crdpq_clip_store_create(64, 1024)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 64)) == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.r2l, 2, H.pattern(key: 2, length: 65)) == CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE) == 1)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 1)
    }

    @Test("the total limit spans both directions; exactly reaching it is fine, one byte over is not")
    func totalLimit() {
        let s = crdpq_clip_store_create(64, 100)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 64)) == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.l2r, 1, H.pattern(key: 1, length: 36)) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_bytes(s) == 100)
        #expect(H.put(s, 0, H.l2r, 2, [0xEE]) == CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE) == 1)
        // A zero-length block still fits.
        #expect(crdpq_clip_store_put(s, 0, H.l2r, 3, nil, 0) == CRDPQ_CLIP_OK)
    }

    /// The key is judged before the total: a collision is the caller's bug whatever room is
    /// left, and a refused put takes no room.
    @Test("a live key is refused as KEY_IN_USE before the total limit is judged, and the refused put takes no room")
    func liveKeyBeforeTotal() {
        let s = crdpq_clip_store_create(64, 100)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 64)) == CRDPQ_CLIP_OK)
        // 64 more would also be over the total: the key decides.
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 64, salt: 1)) == CRDPQ_CLIP_ERR_KEY_IN_USE)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE) == 0)
        #expect(crdpq_clip_store_live_bytes(s) == 64)
        #expect(H.put(s, 0, H.l2r, 1, H.pattern(key: 1, length: 37)) == CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE)
        #expect(H.put(s, 0, H.l2r, 1, H.pattern(key: 1, length: 36)) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_live_bytes(s) == 100)
    }

    @Test("each direction holds at most CRDPQ_CLIP_SLOTS_PER_DIRECTION blocks; the other keeps its own")
    func slots() {
        #expect(CRDPQ_CLIP_SLOTS_PER_DIRECTION == 4)
        let s = crdpq_clip_store_create(16, 1024)
        defer { crdpq_clip_store_destroy(s) }
        for key: UInt32 in 0..<4 {
            #expect(H.put(s, 0, H.r2l, key, [UInt8(key)]) == CRDPQ_CLIP_OK)
        }
        #expect(H.put(s, 0, H.r2l, 99, [1]) == CRDPQ_CLIP_ERR_SLOTS_FULL)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_SLOTS_FULL) == 1)
        // A live key with every slot taken is still a key collision, not a full table.
        #expect(H.put(s, 0, H.r2l, 2, [9, 9]) == CRDPQ_CLIP_ERR_KEY_IN_USE)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_SLOTS_FULL) == 1)
        #expect(H.put(s, 0, H.l2r, 99, [1]) == CRDPQ_CLIP_OK)
        // Taking one frees a slot.
        #expect(H.take(s, 0, H.r2l, 0).rc == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.r2l, 99, [1]) == CRDPQ_CLIP_OK)
    }

    @Test("a total limit below the block limit is raised to it")
    func totalClampedUp() {
        let s = crdpq_clip_store_create(64, 10)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 64)) == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.r2l, 2, [1]) == CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE)
    }
}

@Suite("crdpq_clip_store: generations")
struct CRDPQClipStoreGenerationTests {
    typealias H = ClipStoreHarness

    @Test("a new store is at generation 0; clear empties both directions and moves to 1")
    func clearBumps() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(crdpq_clip_store_generation(s) == 0)
        #expect(H.put(s, 0, H.r2l, 1, [1, 2, 3]) == CRDPQ_CLIP_OK)
        #expect(H.put(s, 0, H.l2r, 1, [4, 5]) == CRDPQ_CLIP_OK)
        #expect(crdpq_clip_store_clear(s) == 1)
        #expect(crdpq_clip_store_generation(s) == 1)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 0)
        #expect(crdpq_clip_store_live_count(s, H.l2r) == 0)
        #expect(crdpq_clip_store_live_bytes(s) == 0)
    }

    @Test("after a clear, the old generation is refused for put, take and discard; the new one works")
    func oldGenerationRefused() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, [1, 2, 3]) == CRDPQ_CLIP_OK)
        _ = crdpq_clip_store_clear(s)
        // An event from before the reconnect cannot take anything...
        #expect(H.take(s, 0, H.r2l, 1).rc == CRDPQ_CLIP_ERR_STALE_GENERATION)
        #expect(crdpq_clip_store_discard(s, 0, H.r2l, 1) == CRDPQ_CLIP_ERR_STALE_GENERATION)
        // ...and a late producer from before it cannot plant anything.
        #expect(H.put(s, 0, H.r2l, 2, [7]) == CRDPQ_CLIP_ERR_STALE_GENERATION)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_STALE_GENERATION) == 3)
        #expect(crdpq_clip_store_live_bytes(s) == 0)

        #expect(H.put(s, 1, H.r2l, 2, [7, 8]) == CRDPQ_CLIP_OK)
        #expect(H.take(s, 1, H.r2l, 2).bytes == [7, 8])
        // The block cleared away is not resurrected under the new generation either.
        #expect(H.take(s, 1, H.r2l, 1).rc == CRDPQ_CLIP_ERR_NOT_FOUND)
    }

    @Test("a new-session event cannot take an old-session block either (a generation from the future)")
    func futureGenerationRefused() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, [1]) == CRDPQ_CLIP_OK)
        #expect(H.take(s, 1, H.r2l, 1).rc == CRDPQ_CLIP_ERR_STALE_GENERATION)
        #expect(H.take(s, 0, H.r2l, 1).rc == CRDPQ_CLIP_OK)
    }

    /// Gate r1, m-2: the generation is judged before anything about the key, so a late
    /// producer of the old session that happens to reuse a key live in the new one is refused
    /// as stale -- it neither plants its bytes nor is mistaken for a key collision.
    @Test("an old- or future-generation put onto a key live in the current generation is refused as stale; the live block stays")
    func stalePutOntoLiveKey() {
        let s = crdpq_clip_store_create(64, 128)
        defer { crdpq_clip_store_destroy(s) }
        let g1 = crdpq_clip_store_clear(s)
        #expect(H.put(s, g1, H.r2l, 5, [9, 9]) == CRDPQ_CLIP_OK)
        #expect(H.put(s, g1 &- 1, H.r2l, 5, [1, 1, 1]) == CRDPQ_CLIP_ERR_STALE_GENERATION)
        #expect(H.put(s, g1 &+ 1, H.r2l, 5, [2]) == CRDPQ_CLIP_ERR_STALE_GENERATION)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_STALE_GENERATION) == 2)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_KEY_IN_USE) == 0)
        #expect(crdpq_clip_store_live_bytes(s) == 2)
        #expect(H.take(s, g1, H.r2l, 5).bytes == [9, 9])
    }

    @Test("refusal counters are cumulative across clears")
    func countersSurviveClear() {
        let s = crdpq_clip_store_create(8, 16)
        defer { crdpq_clip_store_destroy(s) }
        #expect(H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 9)) == CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE)
        _ = crdpq_clip_store_clear(s)
        _ = crdpq_clip_store_clear(s)
        #expect(crdpq_clip_store_generation(s) == 2)
        #expect(H.refusals(s, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE) == 1)
    }

    @Test("each refusal is counted under its own cause and no other; OK and out-of-range codes read 0")
    func countersAreByCause() {
        let s = crdpq_clip_store_create(8, 16)
        defer { crdpq_clip_store_destroy(s) }
        _ = H.take(s, 0, H.r2l, 1)                                // NOT_FOUND
        _ = H.put(s, 3, H.r2l, 1, [1])                             // STALE_GENERATION
        _ = H.put(s, 0, H.r2l, 1, H.pattern(key: 1, length: 9))   // BLOCK_TOO_LARGE
        _ = H.put(s, 0, H.r2l, 2, [1])                             // OK
        _ = H.put(s, 0, H.r2l, 2, [2])                             // KEY_IN_USE
        let expected: [(crdpq_clip_result_t, Int)] = [
            (CRDPQ_CLIP_ERR_ARGUMENT, 0), (CRDPQ_CLIP_ERR_STALE_GENERATION, 1), (CRDPQ_CLIP_ERR_NOT_FOUND, 1),
            (CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE, 1), (CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE, 0), (CRDPQ_CLIP_ERR_SLOTS_FULL, 0),
            (CRDPQ_CLIP_ERR_BUFFER_TOO_SMALL, 0), (CRDPQ_CLIP_ERR_KEY_IN_USE, 1), (CRDPQ_CLIP_ERR_NO_MEMORY, 0),
        ]
        for (rc, count) in expected {
            #expect(H.refusals(s, rc) == count, "cause \(rc.rawValue)")
        }
        #expect(H.refusals(s, CRDPQ_CLIP_OK) == 0)
        #expect(H.refusals(s, crdpq_clip_result_t(rawValue: 99)) == 0)
    }
}

@Suite("crdpq_clip_store: every released block is wiped first")
struct CRDPQClipStoreWipeTests {
    typealias H = ClipStoreHarness

    /// A store with a recorder installed; the recorder outlives the store.
    static func withObservedStore(_ body: (OpaquePointer?, ClipReleaseRecorder) -> Void) -> ClipReleaseRecorder {
        let recorder = ClipReleaseRecorder()
        let s = crdpq_clip_store_create(64, 128)
        recorder.install(on: s)
        body(s, recorder)
        crdpq_clip_store_destroy(s)
        return recorder
    }

    static let nonZero: [UInt8] = (1...24).map { UInt8($0) }

    @Test("take: the store's copy is zero when released, and the caller still got the bytes")
    func takeWipes() {
        let recorder = Self.withObservedStore { s, recorder in
            #expect(H.put(s, 0, H.r2l, 1, Self.nonZero) == CRDPQ_CLIP_OK)
            #expect(H.take(s, 0, H.r2l, 1).bytes == Self.nonZero)
            #expect(recorder.all.count == 1)
        }
        #expect(recorder.all.map(\.length) == [24])
        #expect(recorder.all.allSatisfy { $0.allZero })
    }

    @Test("discard, a refused put's own copy (key in use, stale generation), clear and destroy all wipe")
    func everyPathWipes() {
        let recorder = Self.withObservedStore { s, recorder in
            #expect(H.put(s, 0, H.r2l, 1, Self.nonZero) == CRDPQ_CLIP_OK)
            #expect(crdpq_clip_store_discard(s, 0, H.r2l, 1) == CRDPQ_CLIP_OK)          // 1: discard (24)
            #expect(H.put(s, 0, H.r2l, 2, Array(Self.nonZero.prefix(10))) == CRDPQ_CLIP_OK)
            #expect(H.put(s, 0, H.r2l, 2, Array(Self.nonZero.prefix(11))) == CRDPQ_CLIP_ERR_KEY_IN_USE) // 2: refused copy (11)
            #expect(recorder.all.map(\.length) == [24, 11], "the live block under key 2 must not be released")
            #expect(H.put(s, 5, H.r2l, 3, Array(Self.nonZero.prefix(12))) == CRDPQ_CLIP_ERR_STALE_GENERATION) // 3: refused copy (12)
            #expect(H.put(s, 0, H.l2r, 4, Array(Self.nonZero.prefix(13))) == CRDPQ_CLIP_OK)
            _ = crdpq_clip_store_clear(s)                                                // 4, 5: cleared (10, 13)
            #expect(H.put(s, 1, H.l2r, 5, Array(Self.nonZero.prefix(14))) == CRDPQ_CLIP_OK)
        }                                                                                // 6: destroyed (14)
        #expect(recorder.all.map(\.length).sorted() == [10, 11, 12, 13, 14, 24])
        #expect(recorder.all.allSatisfy { $0.allZero }, "every block must be zero by the time it is released")
    }

    @Test("crdpq_clip_wipe zeroes a caller's own buffer, and tolerates NULL and 0")
    func wipeHelper() {
        var buffer: [UInt8] = Self.nonZero
        buffer.withUnsafeMutableBytes { crdpq_clip_wipe($0.baseAddress, $0.count) }
        #expect(buffer.allSatisfy { $0 == 0 })
        crdpq_clip_wipe(nil, 0)
        crdpq_clip_wipe(nil, 8)
        var untouched: [UInt8] = [7]
        untouched.withUnsafeMutableBytes { crdpq_clip_wipe($0.baseAddress, 0) }
        #expect(untouched == [7])
    }

    /// The deleted-wipe mutant is caught by the observer tests above. A plain-memset mutant is
    /// NOT -- it zeroes just as well at every optimization level this suite runs at, and the
    /// difference is only what an optimizer is permitted to delete (see crdpq_clip_wipe's doc
    /// comment). So the choice itself is pinned, on the source, in its exact call shape.
    @Test("the wipe is memset_s, and the file has no plain memset or bzero call")
    func wipeIsMemsetS() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CRDPQueue/crdpq_clip.c")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("(void)memset_s(p, n, 0, n);"))
        #expect(source.contains("int memset_s(void* s, size_t smax, int c, size_t n);"))
        let plainCall = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(memset|bzero|explicit_bzero)\s*\("#)
        let range = NSRange(source.startIndex..., in: source)
        #expect(plainCall.numberOfMatches(in: source, range: range) == 0)
    }
}

@Suite("crdpq_clip_store: concurrent use, the way the lanes use it (blocking waits, no spinning)")
struct CRDPQClipStoreConcurrencyTests {
    typealias H = ClipStoreHarness

    /// Runs `body` on a dedicated thread (not the GCD pool: these bodies block on semaphores,
    /// and a blocked pool thread on a 2-core runner is exactly the starvation Tier 2's
    /// `--no-parallel` note warns about).
    static func spawn(_ group: DispatchGroup, _ body: @escaping @Sendable () -> Void) {
        group.enter()
        let thread = Thread {
            body()
            group.leave()
        }
        thread.start()
    }

    /// Every blocking wait is bounded (gate r1, m-8). A worker whose wait runs out records it
    /// and returns; the test thread's join has a longer bound and fails the test instead of
    /// hanging the bundle. What this cannot bound: a thread deadlocked INSIDE a store call --
    /// the join then times out and the store is deliberately leaked (destroying it under a
    /// thread still inside it would be a use-after-free), and a single-threaded deadlock in
    /// another test still needs the CI job's own timeout.
    static let workerWait: DispatchTimeInterval = .seconds(60)
    static let joinWait: DispatchTimeInterval = .seconds(150)

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UInt32: Int] = [:]
        private var corruptCount = 0
        private var timeoutCount = 0

        func note(_ rc: crdpq_clip_result_t) {
            lock.lock(); defer { lock.unlock() }
            counts[rc.rawValue, default: 0] += 1
        }
        func noteCorrupt() {
            lock.lock(); defer { lock.unlock() }
            corruptCount += 1
        }
        func noteTimeout() {
            lock.lock(); defer { lock.unlock() }
            timeoutCount += 1
        }
        var corrupt: Int {
            lock.lock(); defer { lock.unlock() }
            return corruptCount
        }
        var timeouts: Int {
            lock.lock(); defer { lock.unlock() }
            return timeoutCount
        }
        func count(_ rc: crdpq_clip_result_t) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[rc.rawValue, default: 0]
        }
        var other: Int {
            lock.lock(); defer { lock.unlock() }
            let known: Set<UInt32> = [CRDPQ_CLIP_OK.rawValue, CRDPQ_CLIP_ERR_STALE_GENERATION.rawValue,
                                      CRDPQ_CLIP_ERR_NOT_FOUND.rawValue]
            return counts.filter { !known.contains($0.key) }.values.reduce(0, +)
        }
    }

    /// The production shape: per direction one producer thread puts block i, one consumer
    /// thread takes it -- the consumer only after the producer said so (the lane's
    /// post/drain edge, modelled by a semaphore), the producer never more than the slot count
    /// ahead. Both directions at once, so four threads share one store.
    @Test("producer/consumer handoff in both directions at once: every block arrives intact, exactly once")
    func handoffBothDirections() {
        let perDirection = 3_000
        let s = crdpq_clip_store_create(64, 512)
        var joined = false
        defer { if joined { crdpq_clip_store_destroy(s) } }
        let store = UnsafeSendableBox(value: s)
        let tally = Tally()
        let group = DispatchGroup()

        for (direction, salt) in [(H.r2l, UInt8(0x0F)), (H.l2r, UInt8(0xF0))] {
            let ready = DispatchSemaphore(value: 0)
            // Created at 0 and signalled up to the slot count, NOT created at the slot count:
            // libdispatch traps (SIGTRAP) when a semaphore is released with a value below the
            // one it was created with -- exactly what a consumer that gave up waiting leaves
            // behind, so the bundle would crash instead of this test failing.
            let free = DispatchSemaphore(value: 0)
            for _ in 0..<Int(CRDPQ_CLIP_SLOTS_PER_DIRECTION) { free.signal() }
            Self.spawn(group) {
                for i in 0..<perDirection {
                    guard free.wait(timeout: .now() + Self.workerWait) == .success else {
                        tally.noteTimeout()
                        return
                    }
                    let key = UInt32(i)
                    tally.note(H.put(store.value, 0, direction, key, H.pattern(key: key, length: i % 37, salt: salt)))
                    ready.signal()
                }
            }
            Self.spawn(group) {
                for i in 0..<perDirection {
                    guard ready.wait(timeout: .now() + Self.workerWait) == .success else {
                        tally.noteTimeout()
                        return
                    }
                    let key = UInt32(i)
                    let taken = H.take(store.value, 0, direction, key, capacity: 64)
                    tally.note(taken.rc)
                    if taken.rc == CRDPQ_CLIP_OK, taken.bytes != H.pattern(key: key, length: i % 37, salt: salt) {
                        tally.noteCorrupt()
                    }
                    free.signal()
                }
            }
        }
        joined = group.wait(timeout: .now() + Self.joinWait) == .success
        #expect(joined, "the four workers must finish; the store is leaked if one is still inside it")
        guard joined else { return }

        #expect(tally.timeouts == 0, "no worker may have given up waiting")
        #expect(tally.count(CRDPQ_CLIP_OK) == 4 * perDirection, "every put and every take must succeed")
        #expect(tally.corrupt == 0, "a block must arrive as it was put, under its own key")
        #expect(tally.other == 0)
        #expect(crdpq_clip_store_live_bytes(s) == 0)
        #expect(crdpq_clip_store_live_count(s, H.r2l) == 0)
        #expect(crdpq_clip_store_live_count(s, H.l2r) == 0)
        #expect(crdpq_clip_store_refusal_count(s, CRDPQ_CLIP_ERR_SLOTS_FULL) == 0)
    }

    /// Clears racing live traffic, the abnormal-teardown case. Workers use whatever generation
    /// is current when they start an iteration; a clear may land anywhere. The only legal
    /// outcomes are OK (with intact bytes), STALE_GENERATION and NOT_FOUND, and the store's own
    /// per-cause counters must agree exactly with what the callers saw.
    @Test("clears racing puts and takes: no corruption, no leak, counters agree with the callers")
    func clearsRacingTraffic() {
        let iterations = 2_000
        let ticksPerWorker = iterations / 20
        let s = crdpq_clip_store_create(64, 512)
        var joined = false
        defer { if joined { crdpq_clip_store_destroy(s) } }
        let store = UnsafeSendableBox(value: s)
        let tally = Tally()
        let tick = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for (direction, salt) in [(H.r2l, UInt8(0x33)), (H.l2r, UInt8(0xCC))] {
            Self.spawn(group) {
                for i in 0..<iterations {
                    let generation = crdpq_clip_store_generation(store.value)
                    let key = UInt32(i)
                    let payload = H.pattern(key: key, length: 1 + i % 40, salt: salt)
                    tally.note(H.put(store.value, generation, direction, key, payload))
                    let taken = H.take(store.value, generation, direction, key, capacity: 64)
                    tally.note(taken.rc)
                    if taken.rc == CRDPQ_CLIP_OK, taken.bytes != payload { tally.noteCorrupt() }
                    if i % 20 == 19 { tick.signal() }
                }
            }
        }
        // The clearer waits (blocking, bounded) for the workers' ticks, so its clears
        // interleave with their traffic without a single spin.
        Self.spawn(group) {
            for _ in 0..<(2 * ticksPerWorker) {
                guard tick.wait(timeout: .now() + Self.workerWait) == .success else {
                    tally.noteTimeout()
                    return
                }
                _ = crdpq_clip_store_clear(store.value)
            }
        }
        joined = group.wait(timeout: .now() + Self.joinWait) == .success
        #expect(joined, "the workers and the clearer must finish; the store is leaked if one is still inside it")
        guard joined else { return }
        _ = crdpq_clip_store_clear(s)

        #expect(tally.timeouts == 0, "the clearer must not have given up waiting for a tick")
        #expect(tally.corrupt == 0)
        #expect(tally.other == 0, "only OK, STALE_GENERATION and NOT_FOUND are legal here")
        #expect(tally.count(CRDPQ_CLIP_OK) + tally.count(CRDPQ_CLIP_ERR_STALE_GENERATION)
                + tally.count(CRDPQ_CLIP_ERR_NOT_FOUND) == 4 * iterations)
        #expect(crdpq_clip_store_refusal_count(s, CRDPQ_CLIP_ERR_STALE_GENERATION) == tally.count(CRDPQ_CLIP_ERR_STALE_GENERATION))
        #expect(crdpq_clip_store_refusal_count(s, CRDPQ_CLIP_ERR_NOT_FOUND) == tally.count(CRDPQ_CLIP_ERR_NOT_FOUND))
        #expect(crdpq_clip_store_generation(s) == UInt32(2 * ticksPerWorker + 1))
        #expect(crdpq_clip_store_live_bytes(s) == 0)
    }
}
