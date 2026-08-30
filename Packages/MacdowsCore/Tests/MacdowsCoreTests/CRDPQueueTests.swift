import CRDPQueue
import Foundation
import Testing

// MARK: - Test helpers

/// Thread-safe counter used both as a schedule_drain/wakeup call counter and as a
/// generation allocator for the concurrency tests below. Not exposed by the C API —
/// purely a test harness helper, passed to C callbacks via `Unmanaged`.
final class CRDPQAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32 = 0

    func increment() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var current: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Thread-safe `[UInt32: UInt32]`, used to record "the highest generation ever published
/// for this surfaceId" from multiple producer threads, so the frame-lane stress test can
/// assert the C layer's last-writer-wins result against an independently-tracked ground
/// truth.
final class CRDPQMaxTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var maxima: [UInt32: UInt32] = [:]

    func record(surfaceId: UInt32, generation: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if let existing = maxima[surfaceId], existing >= generation { return }
        maxima[surfaceId] = generation
    }

    func max(surfaceId: UInt32) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        return maxima[surfaceId]
    }
}

/// The C queue types (`OpaquePointer`, wrapping `crdpq_control_t`/`crdpq_frames_t`) are
/// genuinely safe to share across threads — that's the entire point of this library's
/// internal locking — but Swift's strict concurrency checker has no way to know that
/// about an opaque C pointer. This box tells it what the C API's own contract already
/// guarantees, scoped to exactly the stress tests below that need to capture a queue
/// pointer into a `@Sendable` closure running on `DispatchQueue.global()`.
///
/// Not `private`: `CRDPQueueHardeningTests.swift`'s own stress tests reuse this (and the
/// other helpers below) rather than duplicating the same unsafe-but-justified pattern a
/// second time.
struct UnsafeSendableBox<Wrapped>: @unchecked Sendable {
    let value: Wrapped
}

func crdpqCounterCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    _ = Unmanaged<CRDPQAtomicCounter>.fromOpaque(ctx).takeUnretainedValue().increment()
}

/// Builds a well-formed WindowCreate event. `generation` is intentionally left at 0 —
/// crdpq_post always overwrites it with the queue's own current generation (see crdpq.h);
/// setting it here would just be silently discarded, which is itself part of what
/// `generationSnapshotIsStampedByPost` asserts.
func makeWindowCreateEvent(windowId: UInt32, title: String = "") -> CrdpEvent {
    var ev = CrdpEvent()
    ev.type = CRDPQ_EVENT_WINDOW_CREATE
    ev.payload.windowOrder.windowId = windowId
    ev.payload.windowOrder.fieldFlags = 0
    ev.payload.windowOrder.offsetX = 0
    ev.payload.windowOrder.offsetY = 0
    ev.payload.windowOrder.width = 0
    ev.payload.windowOrder.height = 0
    ev.payload.windowOrder.style = 0
    ev.payload.windowOrder.styleEx = 0
    ev.payload.windowOrder.show = 0
    title.withCString { cstr in
        crdpq_text_set(&ev.payload.windowOrder.title, cstr, strlen(cstr))
    }
    return ev
}

/// L3 (W3 review): `outPtr` is only valid for the synchronous, non-escaping duration of
/// `withUnsafeMutablePointer`'s closure. That's safe here ONLY because crdpq_drain's
/// contract (crdpq.h's threading contract comment) guarantees the visitor callback runs
/// synchronously, on the calling thread, and never escapes past the call that invoked it
/// — crdpq_drain itself returns before `withUnsafeMutablePointer` does. Do not copy this
/// "stash a live Swift pointer behind an opaque C context" pattern into any code path
/// where the C API might call back asynchronously or after this function has returned;
/// there, `outPtr` would already be dangling. (An explicit-lifetime `ContiguousArray` +
/// `withUnsafeMutableBufferPointer` rewrite was considered and is not required here — the
/// synchronous-callback contract already makes this correct — but keep that alternative in
/// mind if this pattern needs to survive a future crdpq_drain that isn't synchronous.)
func drainToArray(_ q: OpaquePointer!) -> [CrdpEvent] {
    var out: [CrdpEvent] = []
    withUnsafeMutablePointer(to: &out) { outPtr in
        _ = crdpq_drain(
            q,
            { ev, vctx in
                let outPtr = vctx!.assumingMemoryBound(to: [CrdpEvent].self)
                outPtr.pointee.append(ev!.pointee)
            },
            UnsafeMutableRawPointer(outPtr)
        )
    }
    return out
}

// MARK: - Control lane: single-threaded semantics

@Suite("CRDPQueue control lane (single-threaded)")
struct CRDPQueueControlSingleThreadedTests {
    @Test("FIFO order is preserved across a single drain")
    func orderPreserved() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        for i: UInt32 in 0..<1000 {
            var ev = makeWindowCreateEvent(windowId: i)
            #expect(crdpq_post(q, &ev))
        }

        let drained = drainToArray(q)
        #expect(drained.count == 1000)
        for (i, ev) in drained.enumerated() {
            #expect(ev.payload.windowOrder.windowId == UInt32(i))
        }
    }

    @Test("order is preserved across multiple post/drain cycles, growing the buffer along the way")
    func orderPreservedAcrossGrowth() {
        // Initial capacity is 256 (see crdpq_control.c) — post enough to force at least
        // two growth doublings (256 -> 512 -> 1024) within a single undrained batch.
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        for i: UInt32 in 0..<900 {
            var ev = makeWindowCreateEvent(windowId: i)
            #expect(crdpq_post(q, &ev))
        }
        let drained = drainToArray(q)
        #expect(drained.count == 900)
        #expect(drained.map(\.payload.windowOrder.windowId) == Array(0..<900))
        #expect(crdpq_high_water_mark(q) == 900)
    }

    @Test("drain is scheduled at most once per undrained batch")
    func drainScheduledOnce() {
        let counter = CRDPQAtomicCounter()
        let ctx = Unmanaged.passUnretained(counter).toOpaque()
        let q = crdpq_control_create(crdpqCounterCallback, ctx)
        defer { crdpq_control_destroy(q) }

        for i: UInt32 in 0..<50 {
            var ev = makeWindowCreateEvent(windowId: i)
            #expect(crdpq_post(q, &ev))
        }
        #expect(counter.current == 1, "schedule_drain should fire exactly once for a whole undrained batch")

        _ = drainToArray(q) // clears drainScheduled

        var ev = makeWindowCreateEvent(windowId: 999)
        #expect(crdpq_post(q, &ev))
        #expect(counter.current == 2, "a post after a drain should schedule again exactly once")
    }

    @Test("seal rejects all further posts, without enqueueing them")
    func sealRejectsPosts() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        var ev1 = makeWindowCreateEvent(windowId: 1)
        #expect(crdpq_post(q, &ev1))
        #expect(!crdpq_is_sealed(q))

        crdpq_seal(q)
        #expect(crdpq_is_sealed(q))

        var ev2 = makeWindowCreateEvent(windowId: 2)
        #expect(!crdpq_post(q, &ev2))

        let drained = drainToArray(q)
        #expect(drained.count == 1)
        #expect(drained[0].payload.windowOrder.windowId == 1)

        // Idempotent.
        crdpq_seal(q)
        #expect(crdpq_is_sealed(q))
    }

    @Test("crdpq_post stamps the queue's current generation into the event, ignoring whatever the caller set")
    func generationSnapshotIsStampedByPost() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        var ev0 = makeWindowCreateEvent(windowId: 1)
        ev0.generation = 999 // must be ignored/overwritten by crdpq_post
        #expect(crdpq_post(q, &ev0))

        let g1 = crdpq_generation_bump(q)
        #expect(g1 == 1)
        var ev1 = makeWindowCreateEvent(windowId: 2)
        #expect(crdpq_post(q, &ev1))

        let g2 = crdpq_generation_bump(q)
        #expect(g2 == 2)
        var ev2 = makeWindowCreateEvent(windowId: 3)
        #expect(crdpq_post(q, &ev2))

        #expect(crdpq_current_generation(q) == 2)

        let drained = drainToArray(q)
        #expect(drained.map(\.generation) == [0, 1, 2])
    }

    @Test("titles over 256 bytes are truncated at a UTF-8 boundary, never out of bounds")
    func titleTruncation() {
        // 300 ASCII bytes: unambiguous, no multi-byte sequence to worry about splitting.
        let longTitle = String(repeating: "x", count: 300)
        let ev = makeWindowCreateEvent(windowId: 1, title: longTitle)
        #expect(ev.payload.windowOrder.title.truncated)
        #expect(ev.payload.windowOrder.title.length == UInt16(CRDPQ_TEXT_BUF_SIZE - 1))
        let recovered = withUnsafeBytes(of: ev.payload.windowOrder.title.bytes) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        #expect(recovered.utf8.count == Int(CRDPQ_TEXT_BUF_SIZE) - 1)

        // A short title must not be flagged truncated and must round-trip exactly.
        let shortEv = makeWindowCreateEvent(windowId: 2, title: "hello")
        #expect(!shortEv.payload.windowOrder.title.truncated)
        #expect(shortEv.payload.windowOrder.title.length == 5)

        // A title whose 256-byte cut point lands mid-UTF-8-sequence must back up to a
        // codepoint boundary rather than splitting a multi-byte character. Each "关" is
        // 3 UTF-8 bytes; 90 of them is 270 bytes, so the naive byte-255 cut point lands
        // inside the 86th character's 3-byte sequence.
        let cjkTitle = String(repeating: "关", count: 90)
        let cjkEv = makeWindowCreateEvent(windowId: 3, title: cjkTitle)
        #expect(cjkEv.payload.windowOrder.title.truncated)
        let cjkRecovered = withUnsafeBytes(of: cjkEv.payload.windowOrder.title.bytes) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        // Must be valid UTF-8 (String(cString:) would produce replacement characters or
        // truncate garbage on an invalid split — asserting an exact multiple of 3 bytes
        // and a whole number of "关" characters proves the cut landed on a boundary).
        #expect(cjkRecovered.utf8.count % 3 == 0)
        #expect(cjkRecovered.allSatisfy { $0 == "关" })
        #expect(Int(cjkEv.payload.windowOrder.title.length) == cjkRecovered.utf8.count)
    }
}

// MARK: - Frame lane: single-threaded semantics

@Suite("CRDPQueue frame lane (single-threaded)")
struct CRDPQueueFramesSingleThreadedTests {
    @Test("last-writer-wins: a second publish before consume overwrites, doesn't queue")
    func lastWriterWins() {
        let f = crdpq_frames_create(nil, nil)
        defer { crdpq_frames_destroy(f) }

        crdpq_frame_publish(f, 7, 1)
        crdpq_frame_publish(f, 7, 2)
        crdpq_frame_publish(f, 7, 3)

        var visitCount = 0
        var lastGen: UInt32 = 0
        withUnsafeMutablePointer(to: &visitCount) { countPtr in
            _ = crdpq_frame_consume(
                f,
                { surfaceId, generation, vctx in
                    let p = vctx!.assumingMemoryBound(to: Int.self)
                    p.pointee += 1
                },
                UnsafeMutableRawPointer(countPtr)
            )
        }
        #expect(visitCount == 1, "three publishes to the same surface before any consume must yield exactly one visit")

        var found = false
        lastGen = crdpq_frame_peek(f, 7, &found)
        #expect(found)
        #expect(lastGen == 3)
    }

    @Test("consume clears dirty but keeps the last generation as the surface's current value")
    func consumeClearsDirtyNotValue() {
        let f = crdpq_frames_create(nil, nil)
        defer { crdpq_frames_destroy(f) }

        crdpq_frame_publish(f, 1, 10)
        _ = crdpq_frame_consume(f, nil, nil)

        var found = false
        let gen = crdpq_frame_peek(f, 1, &found)
        #expect(found)
        #expect(gen == 10)

        // Nothing dirty now — a second consume with no intervening publish visits nothing.
        var visits = 0
        withUnsafeMutablePointer(to: &visits) { p in
            _ = crdpq_frame_consume(
                f,
                { _, _, vctx in vctx!.assumingMemoryBound(to: Int.self).pointee += 1 },
                UnsafeMutableRawPointer(p)
            )
        }
        #expect(visits == 0)
    }

    @Test("many distinct surfaces grow the slot table correctly (capacity starts at 64)")
    func manySurfacesGrowTable() {
        let f = crdpq_frames_create(nil, nil)
        defer { crdpq_frames_destroy(f) }

        for surfaceId: UInt32 in 0..<500 {
            crdpq_frame_publish(f, surfaceId, surfaceId + 1)
        }
        for surfaceId: UInt32 in 0..<500 {
            var found = false
            let gen = crdpq_frame_peek(f, surfaceId, &found)
            #expect(found)
            #expect(gen == surfaceId + 1)
        }
    }
}

// MARK: - Outbound lane: single-threaded semantics

@Suite("CRDPQueue outbound lane (single-threaded)")
struct CRDPQueueOutboundSingleThreadedTests {
    private static func makeExecuteCommand(program: String) -> CrdpCommand {
        var cmd = CrdpCommand()
        cmd.type = CRDPQ_CMD_EXECUTE
        program.withCString { cstr in
            crdpq_text_set(&cmd.payload.execute.program, cstr, strlen(cstr))
        }
        return cmd
    }

    @Test("order preserved, seal rejects, matching the control lane's contract")
    func basicSemantics() {
        let q = crdpq_outbound_create(nil, nil)
        defer { crdpq_outbound_destroy(q) }

        for i in 0..<10 {
            var cmd = Self.makeExecuteCommand(program: "C:\\app\\\(i).exe")
            #expect(crdpq_outbound_post(q, &cmd))
        }

        var drained: [CrdpCommand] = []
        withUnsafeMutablePointer(to: &drained) { outPtr in
            _ = crdpq_outbound_drain(
                q,
                { cmd, vctx in
                    vctx!.assumingMemoryBound(to: [CrdpCommand].self).pointee.append(cmd!.pointee)
                },
                UnsafeMutableRawPointer(outPtr)
            )
        }
        #expect(drained.count == 10)

        crdpq_outbound_seal(q)
        var rejected = Self.makeExecuteCommand(program: "should not enqueue")
        #expect(!crdpq_outbound_post(q, &rejected))
    }

    /// adr/0014 §4: the outbound lane's FIRST payload round-trip test -- every outbound case
    /// above this one exercises ordering, sealing, wakeup coalescing and capacity, i.e. the
    /// queue's mechanics, and none of them ever looks at what a drained command actually
    /// CONTAINS. `CRDPQ_CMD_NOTIFY_EVENT` is where that gap stops being acceptable: it is the
    /// only outbound command whose payload is three raw wire scalars with no `crdpq_text_set`
    /// (or equivalent) sanity-checking them on the way in.
    ///
    /// This is the RUNTIME half of the `message` width pin; `reportSizes`'s
    /// `MemoryLayout<crdpq_cmd_notify_event_t>.size == 12` is the static half. The value
    /// choices are what make it a real check rather than a tautology:
    ///
    /// - `message = 0xFFFF_FFFF` is precisely the value that survives a `uint16_t` narrowing
    ///   as `0x0000_FFFF` (the predicted bug for this command -- its
    ///   `crdpq_cmd_sys_command_t` sibling genuinely IS UINT16 at rail.h:430, while
    ///   `RAIL_NOTIFY_EVENT_ORDER.message` is UINT32 at rail.h:437). A 16-bit `message` field
    ///   would leave `crdpq_command_payload_t`'s own 260B size untouched, so nothing else in
    ///   this file would go red for it.
    /// - `windowId`/`notifyIconId` are asymmetric, byte-distinct patterns, so a field swap, a
    ///   byte-order mistake, or a memcpy that shifted the payload cannot produce a passing
    ///   result by symmetry -- each assertion below can only hold for its own field's bytes.
    @Test("adr/0014: a NOTIFY_EVENT command's three fields survive post/drain bit-exact")
    func notifyEventRoundTrip() {
        let q = crdpq_outbound_create(nil, nil)
        defer { crdpq_outbound_destroy(q) }

        var cmd = CrdpCommand()
        cmd.type = CRDPQ_CMD_NOTIFY_EVENT
        cmd.payload.notifyEvent.windowId = 0xAABB_CCDD
        cmd.payload.notifyEvent.notifyIconId = 0x1122_3344
        cmd.payload.notifyEvent.message = 0xFFFF_FFFF
        #expect(crdpq_outbound_post(q, &cmd))

        var drained: [CrdpCommand] = []
        let visited = withUnsafeMutablePointer(to: &drained) { outPtr in
            crdpq_outbound_drain(
                q,
                { cmd, vctx in
                    vctx!.assumingMemoryBound(to: [CrdpCommand].self).pointee.append(cmd!.pointee)
                },
                UnsafeMutableRawPointer(outPtr)
            )
        }
        #expect(visited == 1)
        #expect(drained.count == 1)
        guard let seen = drained.first else { return }
        #expect(seen.type == CRDPQ_CMD_NOTIFY_EVENT)
        #expect(seen.payload.notifyEvent.windowId == 0xAABB_CCDD)
        #expect(seen.payload.notifyEvent.notifyIconId == 0x1122_3344)
        #expect(seen.payload.notifyEvent.message == 0xFFFF_FFFF)
    }

    /// The other half of the seal contract (crdpq.h:934-937; post side at :918-924), which `basicSemantics` above
    /// only pins from the post side (`crdpq_outbound_post` returning false). A rejected post
    /// must also leave NOTHING behind for a later drain to hand to `crb_outbound_visitor` --
    /// otherwise a command issued after `-shutdownAndWait` could still reach a RAIL context
    /// that teardown has already torn down. Cheap to state, and the tray-click lane
    /// (adr/0014) depends on it: a click landing during shutdown must be dropped, not queued.
    @Test("a post rejected by seal leaves nothing for a later drain")
    func sealedPostDrainsNothing() {
        let q = crdpq_outbound_create(nil, nil)
        defer { crdpq_outbound_destroy(q) }

        crdpq_outbound_seal(q)
        #expect(crdpq_outbound_is_sealed(q))

        var cmd = CrdpCommand()
        cmd.type = CRDPQ_CMD_NOTIFY_EVENT
        cmd.payload.notifyEvent.windowId = 7
        cmd.payload.notifyEvent.notifyIconId = 1
        cmd.payload.notifyEvent.message = 0x0000_0201
        #expect(!crdpq_outbound_post(q, &cmd))

        var drained: [CrdpCommand] = []
        let visited = withUnsafeMutablePointer(to: &drained) { outPtr in
            crdpq_outbound_drain(
                q,
                { cmd, vctx in
                    vctx!.assumingMemoryBound(to: [CrdpCommand].self).pointee.append(cmd!.pointee)
                },
                UnsafeMutableRawPointer(outPtr)
            )
        }
        #expect(visited == 0)
        #expect(drained.isEmpty)
        // A seal-rejected post is expected post-shutdown behavior, not an overflow --
        // crdpq.h:941-942 excludes it from this counter deliberately, and CRSession's
        // `outboundPostDroppedCount` doc comment depends on that exclusion being real.
        #expect(crdpq_outbound_dropped_count(q) == 0)
    }

    @Test("wakeup fires at most once per undrained batch")
    func wakeupCoalesced() {
        let counter = CRDPQAtomicCounter()
        let ctx = Unmanaged.passUnretained(counter).toOpaque()
        let q = crdpq_outbound_create(crdpqCounterCallback, ctx)
        defer { crdpq_outbound_destroy(q) }

        for i in 0..<20 {
            var cmd = Self.makeExecuteCommand(program: "x\(i)")
            #expect(crdpq_outbound_post(q, &cmd))
        }
        #expect(counter.current == 1)

        _ = crdpq_outbound_drain(q, nil, nil)

        var cmd = Self.makeExecuteCommand(program: "y")
        #expect(crdpq_outbound_post(q, &cmd))
        #expect(counter.current == 2)
    }
}

// MARK: - Multi-threaded stress

@Suite("CRDPQueue multi-threaded stress")
struct CRDPQueueStressTests {
    static let eventsPerProducer = 50_000

    @Test("2 concurrent producers, main-thread draining loop: no loss, per-producer FIFO order preserved")
    func controlLaneStress() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        let boxedQ = UnsafeSendableBox(value: q)
        let group = DispatchGroup()
        for producer: UInt32 in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                for i: UInt32 in 0..<UInt32(Self.eventsPerProducer) {
                    // Encode (producer, sequence) into windowId: producer 0 uses
                    // [0, 50_000), producer 1 uses [1_000_000, 1_050_000) — disjoint
                    // ranges so received events can be attributed back to their producer
                    // after interleaving.
                    var ev = makeWindowCreateEvent(windowId: producer * 1_000_000 + i)
                    _ = crdpq_post(boxedQ.value, &ev)
                }
                group.leave()
            }
        }

        var received: [UInt32] = []
        received.reserveCapacity(2 * Self.eventsPerProducer)
        while group.wait(timeout: .now()) == .timedOut {
            received.append(contentsOf: drainToArray(q).map(\.payload.windowOrder.windowId))
        }
        // Producers have finished, but there may be a final unflushed batch.
        received.append(contentsOf: drainToArray(q).map(\.payload.windowOrder.windowId))

        #expect(received.count == 2 * Self.eventsPerProducer, "no event may be lost or duplicated")

        for producer: UInt32 in 0..<2 {
            let base = producer * 1_000_000
            let ownSequence = received.compactMap { id -> UInt32? in
                id >= base && id < base + UInt32(Self.eventsPerProducer) ? id - base : nil
            }
            #expect(ownSequence.count == Self.eventsPerProducer, "producer \(producer) lost events")
            #expect(ownSequence == Array(0..<UInt32(Self.eventsPerProducer)), "producer \(producer)'s own events must arrive in FIFO order relative to each other, even though interleaved with the other producer's events")
        }
    }

    @Test("2 concurrent producers publishing to a shared surfaceId set: frame lane settles to the true last writer")
    func frameLaneLastWriterWinsUnderConcurrency() {
        let f = crdpq_frames_create(nil, nil)
        defer { crdpq_frames_destroy(f) }

        let surfaceCount: UInt32 = 16
        let publishesPerProducer = 20_000
        let generationSource = CRDPQAtomicCounter() // shared, monotonic across both threads
        let tracker = CRDPQMaxTracker()
        let boxedF = UnsafeSendableBox(value: f)

        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<publishesPerProducer {
                    let surfaceId = UInt32(i) % surfaceCount
                    let generation = generationSource.increment()
                    tracker.record(surfaceId: surfaceId, generation: generation)
                    crdpq_frame_publish(boxedF.value, surfaceId, generation)
                }
                group.leave()
            }
        }
        group.wait()

        // Drain whatever's left dirty so a final peek reflects settled state (peek itself
        // doesn't require a prior consume — publish already writes the slot's value
        // unconditionally — but draining first exercises crdpq_frame_consume under the
        // same contention this test is about, rather than only testing peek in isolation).
        _ = crdpq_frame_consume(f, nil, nil)

        for surfaceId in 0..<surfaceCount {
            guard let expected = tracker.max(surfaceId: surfaceId) else {
                Issue.record("surface \(surfaceId) was never recorded by the test's own tracker")
                continue
            }
            var found = false
            let actual = crdpq_frame_peek(f, surfaceId, &found)
            #expect(found)
            #expect(actual == expected, "surface \(surfaceId): expected the highest-generation publish (\(expected)) to win, got \(actual)")
        }
    }
}

// MARK: - POD layout

@Suite("CRDPQueue POD layout")
struct CRDPQueueLayoutTests {
    /// Pinned to the real, measured layout on arm64/Xcode 27 (captured once via a
    /// temporary print in this test, then hard-coded here — see the W3 report for the
    /// full breakdown). A future field addition is expected to move these numbers; a
    /// surprise jump (e.g. accidental struct padding doubling the union, or a stray
    /// pointer-sized field sneaking non-POD-ness in) is exactly what this test exists to
    /// catch, since nothing else in this suite would notice a layout regression.
    ///
    /// adr/0008 §4/§5 grew the union: `crdpq_window_order_t` gained
    /// `numVisibilityRects`/`visibilityRectsTruncated`/`visibilityRects[32]` (300B -> 564B,
    /// still the union's largest member -- adr/0008 §4's deliberate "take 96, not 255" bound
    /// on `crdpq_monitored_desktop_t.windowIds` exists specifically to keep it that way);
    /// `crdpq_monitored_desktop_t` gained `windowIdsTruncated`/`windowIds[96]` (12B -> 400B).
    /// The three new event structs (`crdpq_local_move_size_t`=16B,
    /// `crdpq_min_max_info_t`=36B, `crdpq_zorder_sync_t`=4B) are all far smaller than
    /// `crdpq_window_order_t` and don't move the union's own size. adr/0010 §1 grew it
    /// again: `crdpq_window_order_t` gained `visibleOffsetX/Y` (564B -> 572B). Every number
    /// below was re-measured with clang/arm64 after adding each ADR's fields (matching
    /// crdpq.h's own `_Static_assert`s), not estimated from either ADR's own illustrative
    /// table.
    @Test("CrdpEvent and CrdpCommand match their measured, known-good sizes")
    func reportSizes() {
        #expect(MemoryLayout<crdpq_text_t>.size == 260)
        #expect(MemoryLayout<crdpq_rect_t>.size == 8)
        #expect(MemoryLayout<crdpq_window_order_t>.size == 572)
        #expect(MemoryLayout<crdpq_monitored_desktop_t>.size == 400)
        #expect(MemoryLayout<crdpq_local_move_size_t>.size == 16)
        #expect(MemoryLayout<crdpq_min_max_info_t>.size == 36)
        #expect(MemoryLayout<crdpq_zorder_sync_t>.size == 4)
        // crdpq_window_order_t (572B, adr/0010 §1) is still this union's largest member;
        // crdpq_event_payload_t's OWN alignment is 8 (crdpq_surface_mapped_t's uint64_t
        // windowId sets that, not crdpq_window_order_t), so the union's size pads up from
        // 572 to the next multiple of 8 = 576B. CrdpEvent adds a 4B type tag + 4B
        // generation on top = 584B total (already 8-aligned, no further padding).
        #expect(MemoryLayout<crdpq_event_payload_t>.size == 576)
        #expect(MemoryLayout<CrdpEvent>.size == 584)
        #expect(MemoryLayout<CrdpEvent>.alignment == 8)

        // crdpq_cmd_execute_t (crdpq_text_t alone, 260B) is the largest CrdpCommand union
        // member; CrdpCommand adds a 4B type tag = 264B total. Unaffected by adr/0008 --
        // the outbound lane (crdpq_outbound_t) is explicitly out of this ADR's scope (§6).
        #expect(MemoryLayout<crdpq_command_payload_t>.size == 260)
        #expect(MemoryLayout<CrdpCommand>.size == 264)
        // adr/0014 §4: three UINT32s = 12B. Pinned separately because the two union-level
        // expectations above CANNOT see this member at all -- it is nowhere near the 260B
        // `crdpq_cmd_execute_t` maximum. The size pin alone is NOT enough to catch the
        // predicted bug for this command -- narrowing `message` to `uint16_t` (plausible,
        // since its `crdpq_cmd_sys_command_t` sibling really is UINT16 at rail.h:430 while
        // `RAIL_NOTIFY_EVENT_ORDER.message` is UINT32 at rail.h:437) leaves sizeof at 12
        // too, the two lost bytes absorbed by tail padding to the struct's 4B alignment.
        // The member-width expectation below is the one that goes red on a narrowing:
        // Swift imports a narrowed field as UInt16, and size(ofValue:) reports 2, not 4.
        #expect(MemoryLayout<crdpq_cmd_notify_event_t>.size == 12)
        let notifyEventProbe = crdpq_cmd_notify_event_t()
        #expect(MemoryLayout.size(ofValue: notifyEventProbe.message) == 4)
        #expect(MemoryLayout.size(ofValue: notifyEventProbe.windowId) == 4)
        #expect(MemoryLayout.size(ofValue: notifyEventProbe.notifyIconId) == 4)
    }
}
