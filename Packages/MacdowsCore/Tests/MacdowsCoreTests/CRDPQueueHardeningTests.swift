import CRDPQueue
import Foundation
import Testing

// This file adopts the coverage points from the W3 review's ad-hoc harness programs
// (frames_full.c / stress.c / wakeup.c / trunc.c / sid0.c / sealrace2.c, all originally
// standalone C programs written during the review to reproduce specific bugs) into the
// permanent `swift test` regression suite, per M2 of the W3 fix batch. Each suite below
// names which coverage point it preserves. One coverage point — the table-full path that
// motivated H1 — genuinely cannot be ported here: it requires intercepting `calloc` at
// compile time (the review harness did this via `#define calloc test_calloc` before
// `#include`-ing crdpq_frames.c directly), which has no Swift-callable equivalent without
// invasive production-code changes. That one coverage point is preserved instead as a
// standalone C program at Tools/crdpq-stress/frames_full.c, compiled and run directly by
// Scripts/test-queue.sh (see that file). Every other coverage point ports cleanly to
// Swift Testing and — as a bonus — now gets the same plain/TSan/ASan three-way treatment
// as the rest of this suite for free, without a separate compile step.
//
// Reuses `CRDPQAtomicCounter`, `UnsafeSendableBox`, `crdpqCounterCallback`,
// `makeWindowCreateEvent`, and `drainToArray` from CRDPQueueTests.swift (widened from
// `private` to file-implicit-internal specifically so this file could share them rather
// than duplicating the same unsafe-but-justified patterns a second time).

// MARK: - trunc.c: exhaustive crdpq_text_set boundary checks

@Suite("crdpq_text_set: exhaustive UTF-8 truncation boundary checks")
struct CRDPQTextTruncationTests {
    private static func makeText(_ src: [UInt8]) -> crdpq_text_t {
        var t = crdpq_text_t()
        src.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cstr in
                    crdpq_text_set(&t, cstr, buf.count)
                }
            } else {
                crdpq_text_set(&t, "", 0)
            }
        }
        return t
    }

    private static func prefixBytes(_ t: crdpq_text_t, length: Int) -> [UInt8] {
        var tt = t
        return withUnsafeBytes(of: &tt.bytes) { raw in Array(raw.prefix(length)) }
    }

    private static func nulTerminatedByteCount(_ t: crdpq_text_t) -> Int {
        var tt = t
        return withUnsafeBytes(of: &tt.bytes) { raw -> Int in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!).utf8.count
        }
    }

    @Test("ASCII lengths around the 256-byte buffer boundary", arguments: 253...259)
    func asciiBoundary(_ len: Int) {
        let src = [UInt8](repeating: UInt8(ascii: "x"), count: len)
        let t = Self.makeText(src)
        let bufSize = Int(CRDPQ_TEXT_BUF_SIZE)
        let expectLen = len < bufSize ? len : bufSize - 1
        let expectTrunc = len >= bufSize
        #expect(Int(t.length) == expectLen, "len \(len): length mismatch")
        #expect(t.truncated == expectTrunc, "len \(len): truncated flag mismatch")
        #expect(Self.nulTerminatedByteCount(t) == Int(t.length), "len \(len): strlen(bytes) != length")
    }

    @Test(
        "multi-byte sequence straddling the cut point (byte 255), every intra-sequence cut position",
        arguments: [(n: 2, lead: UInt8(0xC3)), (n: 3, lead: UInt8(0xE4)), (n: 4, lead: UInt8(0xF0))]
    )
    func multiByteStraddlesCutPoint(_ nAndLead: (n: Int, lead: UInt8)) {
        let (n, lead) = nAndLead
        for inside in 1..<n {
            // Cut index 255 lands `inside` bytes into an n-byte sequence starting at `start`.
            let start = 255 - inside
            let len = start + n + 10 // trailing filler so src_len >= 256
            var src = [UInt8](repeating: UInt8(ascii: "a"), count: len)
            src[start] = lead
            for k in 1..<n { src[start + k] = 0x80 }
            let t = Self.makeText(src)
            #expect(Int(t.length) == start, "n=\(n) inside=\(inside): must drop the whole straddling sequence, length mismatch")
            #expect(t.truncated, "n=\(n) inside=\(inside): truncated flag not set")
            let bytes = Self.prefixBytes(t, length: Int(t.length))
            #expect(String(bytes: bytes, encoding: .utf8) != nil, "n=\(n) inside=\(inside): produced invalid UTF-8")
        }
    }

    @Test("a 3-byte sequence ENDING exactly at byte 254 (last full char fits) must NOT be dropped")
    func sequenceEndingExactlyAtBoundaryIsRetained() {
        let start = 252 // occupies 252,253,254; byte 255 is plain 'a'
        var src = [UInt8](repeating: UInt8(ascii: "a"), count: 300)
        src[start] = 0xE4
        src[start + 1] = 0x80
        src[start + 2] = 0x80
        let t = Self.makeText(src)
        #expect(Int(t.length) == 255, "the fully-contained 3-byte sequence must be retained, not dropped")
        let bytes = Self.prefixBytes(t, length: Int(t.length))
        #expect(String(bytes: bytes, encoding: .utf8) != nil, "must still be valid UTF-8")
    }

    @Test("degenerate all-continuation-byte input (invalid UTF-8 on its own) must not underflow")
    func allContinuationBytesInputDoesNotUnderflow() {
        let src = [UInt8](repeating: 0x80, count: 300)
        let t = Self.makeText(src)
        #expect(t.length == 0, "backing up past an unbroken run of continuation bytes must stop at 0, not wrap/underflow")
    }
}

// MARK: - sid0.c: surfaceId=0 is never mistaken for an empty slot

@Suite("crdpq_frames: surfaceId=0 is never mistaken for an empty slot")
struct CRDPQFramesSurfaceIdZeroTests {
    @Test("surfaceId 0 round-trips correctly and survives same-bucket collisions (64, 128)")
    func surfaceIdZeroNotConfusedWithEmptyOrDisplaced() {
        let f = crdpq_frames_create(nil, nil)
        defer { crdpq_frames_destroy(f) }

        var found = false
        _ = crdpq_frame_peek(f, 0, &found)
        #expect(!found, "peek(0) before any publish must report not-found, not a false-positive hit on a zeroed slot")

        #expect(crdpq_frame_publish(f, 0, 42))
        var gen = crdpq_frame_peek(f, 0, &found)
        #expect(found)
        #expect(gen == 42)

        // 64 and 128 collide with 0 under the initial capacity-64 table's mask (63),
        // forcing linear probing past slot 0's own bucket.
        #expect(crdpq_frame_publish(f, 64, 7))
        #expect(crdpq_frame_publish(f, 128, 9))

        gen = crdpq_frame_peek(f, 0, &found)
        #expect(found)
        #expect(gen == 42, "surfaceId 0 must survive same-bucket collisions unmoved")
        gen = crdpq_frame_peek(f, 64, &found)
        #expect(found)
        #expect(gen == 7)
        gen = crdpq_frame_peek(f, 128, &found)
        #expect(found)
        #expect(gen == 9)

        let visited = crdpq_frame_consume(f, nil, nil)
        #expect(visited == 3)

        gen = crdpq_frame_peek(f, 0, &found)
        #expect(found)
        #expect(gen == 42, "consume must clear only the dirty flag, never the retained value")
    }
}

// MARK: - wakeup.c: strictly wakeup-driven consumption, zero polling

@Suite("CRDPQueue control lane: wakeup-driven consumption (consumer never polls)")
struct CRDPQueueWakeupDrivenTests {
    @Test("3 producers + a consumer that ONLY drains on a real wakeup: nothing is ever stranded")
    func wakeupDrivenNoStrandedEvents() {
        let producerCount = 3
        let perProducer = 20_000

        let wakeupCounter = CRDPQAtomicCounter()
        let ctx = Unmanaged.passUnretained(wakeupCounter).toOpaque()
        let q = crdpq_control_create(crdpqCounterCallback, ctx)
        defer { crdpq_control_destroy(q) }
        let boxedQ = UnsafeSendableBox(value: q)

        let group = DispatchGroup()
        for producer: UInt32 in 0..<UInt32(producerCount) {
            group.enter()
            DispatchQueue.global().async {
                for i: UInt32 in 0..<UInt32(perProducer) {
                    var ev = makeWindowCreateEvent(windowId: producer * 1_000_000 + i)
                    _ = crdpq_post(boxedQ.value, &ev)
                }
                group.leave()
            }
        }

        var totalReceived = 0
        var lastSeenWakeups: UInt32 = 0
        var wakeupDrivenDrains = 0

        func drainIfWokenUp() {
            let current = wakeupCounter.current
            if current != lastSeenWakeups {
                lastSeenWakeups = current
                totalReceived += drainToArray(q).count
                wakeupDrivenDrains += 1
            }
        }

        // Strictly wakeup-driven: the queue is never polled unconditionally while
        // producers might still be running — only ever drained in response to an
        // observed change in the wakeup counter.
        while group.wait(timeout: .now()) == .timedOut {
            drainIfWokenUp()
            if wakeupCounter.current == lastSeenWakeups {
                Thread.sleep(forTimeInterval: 0.0001)
            }
        }
        // Producers have finished; give any final in-flight wakeup a bounded chance to
        // land before the last-resort unconditional check below.
        for _ in 0..<200 {
            drainIfWokenUp()
            Thread.sleep(forTimeInterval: 0.001)
        }

        // Prove nothing is left behind: one final UNconditional drain (the only
        // non-wakeup-driven drain in this test, deliberately, to detect a lost wakeup)
        // must find zero leftover events.
        let leftover = drainToArray(q).count
        totalReceived += leftover
        #expect(leftover == 0, "a final unconditional drain found leftover events — a wakeup was lost")
        #expect(totalReceived == producerCount * perProducer, "no event may be lost or duplicated")
        #expect(wakeupDrivenDrains > 0, "sanity: the wakeup-driven loop must have actually drained via a real wakeup at least once, not only via the final unconditional catch-all")
    }
}

// MARK: - stress.c: slow visitor + 4 producers forcing multiple buffer doublings

private final class CRDPQSlowVisitState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextExpectedSequence: [UInt32: UInt32] = [:]
    private(set) var totalReceived = 0
    private(set) var orderViolations = 0
    private(set) var checksumViolations = 0
    private var deliveredSinceSleep = 0

    func record(windowId: UInt32, style: UInt32, title: String) {
        lock.lock()
        defer { lock.unlock() }

        let producer = windowId / 1_000_000
        let seq = windowId % 1_000_000
        if style != windowId { checksumViolations += 1 }
        if title != "w\(producer)-\(seq)" { checksumViolations += 1 }
        if seq != (nextExpectedSequence[producer] ?? 0) { orderViolations += 1 }
        nextExpectedSequence[producer] = seq + 1
        totalReceived += 1

        // Sleep INSIDE the visitor loop, periodically: keeps this drain's snapshot
        // pointer live for a long time while producers keep growing the *other* buffer.
        // Matches stress.c's "every 4096th event" cadence exactly.
        deliveredSinceSleep += 1
        if deliveredSinceSleep >= 4096 {
            deliveredSinceSleep = 0
            Thread.sleep(forTimeInterval: 0.0002)
        }
    }
}

private func crdpqSlowVisitorCallback(_ ev: UnsafePointer<CrdpEvent>?, _ vctx: UnsafeMutableRawPointer?) {
    guard let ev, let vctx else { return }
    let state = Unmanaged<CRDPQSlowVisitState>.fromOpaque(vctx).takeUnretainedValue()
    let e = ev.pointee
    let title = withUnsafeBytes(of: e.payload.windowOrder.title.bytes) { raw -> String in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    state.record(windowId: e.payload.windowOrder.windowId, style: e.payload.windowOrder.style, title: title)
}

@Suite("CRDPQueue control lane: adversarial growth under a slow consumer")
struct CRDPQueueSlowVisitorGrowthTests {
    @Test("slow visitor + 4 producers force the back buffer through multiple doublings past the initial 256-event capacity")
    func slowVisitorForcesRepeatedGrowthPast256() {
        let producerCount = 4
        let perProducer = 60_000

        // This test is specifically about growth/realloc correctness under an adversarial
        // slow consumer, not about M4's capacity ceiling (a separate, dedicated coverage
        // point in CRDPQueueControlCapacityCeilingTests below) — so give it an explicit
        // ceiling far above anything 4 producers * 60_000 events could plausibly pile into
        // one undrained buffer, even under TSan/ASan's heavy slowdown. Using the default
        // 65536-event ceiling here was observed to legitimately trip under ASan/TSan (the
        // sanitizers slow everything down enough that backlog in a single undrained buffer
        // can exceed 65536 before the next drain), which would make this test's "no event
        // lost" assertion fail for a real, intended-behavior reason (M4 rejecting once
        // full) that has nothing to do with what this test exists to verify.
        let q = crdpq_control_create_with_max_capacity(nil, nil, 10_000_000)
        defer { crdpq_control_destroy(q) }
        let boxedQ = UnsafeSendableBox(value: q)

        let state = CRDPQSlowVisitState()
        let stateCtx = Unmanaged.passUnretained(state).toOpaque()

        let group = DispatchGroup()
        for producer: UInt32 in 0..<UInt32(producerCount) {
            group.enter()
            DispatchQueue.global().async {
                for i: UInt32 in 0..<UInt32(perProducer) {
                    var ev = makeWindowCreateEvent(windowId: producer * 1_000_000 + i, title: "w\(producer)-\(i)")
                    ev.payload.windowOrder.style = producer * 1_000_000 + i
                    _ = crdpq_post(boxedQ.value, &ev)
                }
                group.leave()
            }
        }

        while group.wait(timeout: .now()) == .timedOut {
            _ = crdpq_drain(q, crdpqSlowVisitorCallback, stateCtx)
        }
        // Final drains until the buffer is genuinely empty.
        while crdpq_drain(q, crdpqSlowVisitorCallback, stateCtx) > 0 {}

        #expect(state.totalReceived == producerCount * perProducer, "no event may be lost or duplicated")
        #expect(state.orderViolations == 0, "each producer's own events must stay in FIFO order relative to each other")
        #expect(state.checksumViolations == 0, "the deep copy must carry payload fields (style, title) intact across growth/realloc")
        #expect(crdpq_high_water_mark(q) > 256, "hwm must exceed the initial 256-event capacity — otherwise this test isn't actually exercising the growth path it exists to cover (M2 in the W3 review: the pre-existing stress test never forced a realloc at all)")
    }
}

// MARK: - sealrace2.c's coverage point: no enqueue is ever observable after seal()
// has already returned on another thread
//
// sealrace2.c's own technique relied on a `crdpq_test_widen_window()` hook meant to be
// woven into a specially-instrumented build of crdpq_post to deterministically force the
// pre-M1 check-then-lock race window open. That race window no longer exists structurally
// after M1 (the seal check moved inside the same critical section as the enqueue, right
// before the mutation it gates) — there is no separate "check" step left for a hook to
// sit inside. The coverage point this file preserves instead is the same one sealrace.c
// (an earlier, simpler, hook-free harness) demonstrated probabilistically: hammer
// concurrent post() and seal() across many trials and confirm no event tagged
// "definitely issued after seal() completed" is ever found enqueued. This is real
// coverage of the actual, currently-shipping crdpq_post/crdpq_outbound_post, not of a
// hook that was never wired into production code.

@Suite("CRDPQueue: no post ever enqueues strictly after seal() has already returned")
struct CRDPQueueSealRaceTests {
    @Test("control lane: 60 trials of concurrent post()+seal(), zero post-seal enqueues")
    func controlLaneSealRaceNeverEnqueuesAfterSealReturns() {
        let trials = 60
        let producerThreads = 6

        var trialsWithViolation = 0

        for _ in 0..<trials {
            let q = crdpq_control_create(nil, nil)
            defer { crdpq_control_destroy(q) }
            let boxedQ = UnsafeSendableBox(value: q)

            let sealDone = CRDPQAtomicCounter() // 0 = not sealed yet, >0 = sealed
            let stop = CRDPQAtomicCounter() // 0 = keep going, >0 = stop
            let boxedSealDone = UnsafeSendableBox(value: sealDone)
            let boxedStop = UnsafeSendableBox(value: stop)

            let group = DispatchGroup()
            for _ in 0..<producerThreads {
                group.enter()
                DispatchQueue.global().async {
                    while boxedStop.value.current == 0 {
                        // Tag: 0xDEADBEEF if seal_done was ALREADY true when this post was
                        // issued, 1 otherwise. A tagged 0xDEADBEEF event that ends up
                        // enqueued means crdpq_post let something through strictly after
                        // seal() had already returned on the main thread.
                        let tag: UInt32 = boxedSealDone.value.current > 0 ? 0xDEAD_BEEF : 1
                        var ev = makeWindowCreateEvent(windowId: tag)
                        _ = crdpq_post(boxedQ.value, &ev)
                    }
                    group.leave()
                }
            }

            Thread.sleep(forTimeInterval: 0.0003)
            crdpq_seal(q)
            _ = sealDone.increment() // strictly after crdpq_seal() returned
            Thread.sleep(forTimeInterval: 0.002)
            _ = stop.increment()
            group.wait()

            let drained = drainToArray(q)
            let afterSealCount = drained.filter { $0.payload.windowOrder.windowId == 0xDEAD_BEEF }.count
            if afterSealCount > 0 {
                trialsWithViolation += 1
            }
        }

        #expect(trialsWithViolation == 0, "\(trialsWithViolation)/\(trials) trials enqueued an event tagged as issued after crdpq_seal() had already returned")
    }

    @Test("outbound lane: 60 trials of concurrent post()+seal(), zero post-seal enqueues (M1's 'apply the same isomorphism check to outbound' fix, mirrored coverage)")
    func outboundLaneSealRaceNeverEnqueuesAfterSealReturns() {
        let trials = 60
        let producerThreads = 6

        var trialsWithViolation = 0

        for _ in 0..<trials {
            let q = crdpq_outbound_create(nil, nil)
            defer { crdpq_outbound_destroy(q) }
            let boxedQ = UnsafeSendableBox(value: q)

            let sealDone = CRDPQAtomicCounter()
            let stop = CRDPQAtomicCounter()
            let boxedSealDone = UnsafeSendableBox(value: sealDone)
            let boxedStop = UnsafeSendableBox(value: stop)

            let group = DispatchGroup()
            for _ in 0..<producerThreads {
                group.enter()
                DispatchQueue.global().async {
                    while boxedStop.value.current == 0 {
                        var cmd = CrdpCommand()
                        cmd.type = CRDPQ_CMD_ACTIVATE
                        cmd.payload.activate.windowId = boxedSealDone.value.current > 0 ? 0xDEAD_BEEF : 1
                        _ = crdpq_outbound_post(boxedQ.value, &cmd)
                    }
                    group.leave()
                }
            }

            Thread.sleep(forTimeInterval: 0.0003)
            crdpq_outbound_seal(q)
            _ = sealDone.increment()
            Thread.sleep(forTimeInterval: 0.002)
            _ = stop.increment()
            group.wait()

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
            let afterSealCount = drained.filter { $0.payload.activate.windowId == 0xDEAD_BEEF }.count
            if afterSealCount > 0 {
                trialsWithViolation += 1
            }
        }

        #expect(trialsWithViolation == 0, "\(trialsWithViolation)/\(trials) trials enqueued a command tagged as issued after crdpq_outbound_seal() had already returned")
    }
}

// MARK: - M4: capacity ceiling + dropped-count on the control/outbound lanes
//
// Not one of the six ported harness files (M4 is new functionality added in this same fix
// batch, not a pre-existing bug the review's harnesses targeted), but it needs its own
// direct correctness coverage same as everything else in this batch.

@Suite("CRDPQueue control lane: capacity ceiling and dropped-count (M4)")
struct CRDPQueueControlCapacityCeilingTests {
    @Test("posting past a small explicit ceiling is rejected and counted, without corrupting what's already enqueued")
    func postsPastCeilingAreRejectedAndCounted() {
        // A tiny ceiling, deliberately below one doubling past the initial 256-event
        // capacity, so this test is fast and deterministic rather than needing real
        // memory pressure to observe a rejection.
        let ceiling = 256
        let q = crdpq_control_create_with_max_capacity(nil, nil, ceiling)
        defer { crdpq_control_destroy(q) }

        for i: UInt32 in 0..<UInt32(ceiling) {
            var ev = makeWindowCreateEvent(windowId: i)
            #expect(crdpq_post(q, &ev), "posts up to the ceiling must all succeed")
        }
        #expect(crdpq_dropped_count(q) == 0)

        var overflow = makeWindowCreateEvent(windowId: 999)
        #expect(!crdpq_post(q, &overflow), "a post past a full, at-ceiling buffer must be rejected")
        #expect(crdpq_dropped_count(q) == 1)

        var overflow2 = makeWindowCreateEvent(windowId: 1000)
        #expect(!crdpq_post(q, &overflow2))
        #expect(crdpq_dropped_count(q) == 2, "dropped_count must keep accumulating, not saturate at 1")

        // Draining frees the back buffer, so posting can resume afterward.
        let drained = drainToArray(q)
        #expect(drained.count == ceiling, "the rejected posts must never have been enqueued")

        var afterDrain = makeWindowCreateEvent(windowId: 1001)
        #expect(crdpq_post(q, &afterDrain), "a post after a drain frees capacity must succeed again")
        #expect(crdpq_dropped_count(q) == 2, "a successful post must not itself bump dropped_count")
    }

    @Test("crdpq_control_create's default ceiling (65536) never interferes with ordinary small-scale usage")
    func defaultCeilingDoesNotAffectNormalUsage() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }

        for i: UInt32 in 0..<1000 {
            var ev = makeWindowCreateEvent(windowId: i)
            #expect(crdpq_post(q, &ev))
        }
        #expect(crdpq_dropped_count(q) == 0)
    }
}

@Suite("CRDPQueue outbound lane: capacity ceiling and dropped-count (M4)")
struct CRDPQueueOutboundCapacityCeilingTests {
    private static func makeExecuteCommand(program: String) -> CrdpCommand {
        var cmd = CrdpCommand()
        cmd.type = CRDPQ_CMD_EXECUTE
        program.withCString { cstr in
            crdpq_text_set(&cmd.payload.execute.program, cstr, strlen(cstr))
        }
        return cmd
    }

    @Test("posting past a small explicit ceiling is rejected and counted, mirroring the control lane")
    func postsPastCeilingAreRejectedAndCounted() {
        let ceiling = 64
        let q = crdpq_outbound_create_with_max_capacity(nil, nil, ceiling)
        defer { crdpq_outbound_destroy(q) }

        for i in 0..<ceiling {
            var cmd = Self.makeExecuteCommand(program: "x\(i)")
            #expect(crdpq_outbound_post(q, &cmd))
        }
        #expect(crdpq_outbound_dropped_count(q) == 0)

        var overflow = Self.makeExecuteCommand(program: "overflow")
        #expect(!crdpq_outbound_post(q, &overflow))
        #expect(crdpq_outbound_dropped_count(q) == 1)
    }
}

// MARK: - adr/0008: bounded-array truncation semantics + sentinel pass-through
//
// These exercise the CONTRACT crdpq.h/CRSession.mm implement: the wire count is preserved
// even when the array itself is bounded/truncated (a deliberate asymmetry from
// `crdpq_text_t`'s own truncation convention -- see crdpq.h's doc comments on
// `crdpq_monitored_desktop_t`/`crdpq_window_order_t`), CRDPQ_MAX_WINDOW_IDS/
// CRDPQ_MAX_VISIBILITY_RECTS are the actual bounds a caller must clamp to, and both survive
// a real crdpq_post/crdpq_drain round trip (the queue's own POD deep-copy, exercised here
// for the first time against structs this large). NOTE: the *clamping arithmetic* itself
// (`min(wireCount, MAX)`) lives in CRSession.mm's crb_monitored_desktop/crb_window_common
// (Objective-C++, App target) -- not reachable from this Swift package's tests -- so these
// tests apply that same clamp inline when constructing the fixture, then assert the queue
// preserves the result faithfully. End-to-end coverage of CRSession.mm's own clamp sites
// belongs to Tools/window-smoke, not here.

@Suite("adr/0008: MonitoredDesktop.windowIds truncation + activeWindowId sentinel")
struct CRDPQMonitoredDesktopTruncationTests {
    @Test("97 windowIds: exactly 96 stored, truncated flag set, wire count (97) preserved through post/drain")
    func windowIdsTruncatedAt96() {
        let wireCount: UInt32 = 97
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_MONITORED_DESKTOP
        ev.payload.monitoredDesktop.fieldFlags = 0x0000_0010 // WINDOW_ORDER_FIELD_DESKTOP_ZORDER
        ev.payload.monitoredDesktop.numWindowIds = wireCount
        ev.payload.monitoredDesktop.windowIdsTruncated = wireCount > UInt32(CRDPQ_MAX_WINDOW_IDS)
        withUnsafeMutablePointer(to: &ev.payload.monitoredDesktop.windowIds) { arrayPtr in
            arrayPtr.withMemoryRebound(to: UInt32.self, capacity: Int(CRDPQ_MAX_WINDOW_IDS)) { buf in
                for i in 0..<Int(CRDPQ_MAX_WINDOW_IDS) {
                    buf[i] = UInt32(i) + 1000 // distinct, easy-to-spot values
                }
            }
        }

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        #expect(drained.count == 1)

        let md = drained[0].payload.monitoredDesktop
        #expect(md.numWindowIds == 97, "wire count must survive even though only 96 slots exist")
        #expect(md.windowIdsTruncated)
        var mutableMd = md
        withUnsafeMutablePointer(to: &mutableMd.windowIds) { arrayPtr in
            arrayPtr.withMemoryRebound(to: UInt32.self, capacity: Int(CRDPQ_MAX_WINDOW_IDS)) { buf in
                for i in 0..<Int(CRDPQ_MAX_WINDOW_IDS) {
                    #expect(buf[i] == UInt32(i) + 1000, "slot \(i) corrupted by the queue's deep copy")
                }
            }
        }
    }

    @Test("24 windowIds (a real observed maximum, adr/0008 §0): not truncated, wire count == stored count")
    func windowIdsUnderBoundNotTruncated() {
        let count: UInt32 = 24
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_MONITORED_DESKTOP
        ev.payload.monitoredDesktop.fieldFlags = 0x0000_0010
        ev.payload.monitoredDesktop.numWindowIds = count
        ev.payload.monitoredDesktop.windowIdsTruncated = false
        withUnsafeMutablePointer(to: &ev.payload.monitoredDesktop.windowIds) { arrayPtr in
            arrayPtr.withMemoryRebound(to: UInt32.self, capacity: Int(count)) { buf in
                for i in 0..<Int(count) { buf[i] = UInt32(i) }
            }
        }

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        #expect(drained[0].payload.monitoredDesktop.numWindowIds == 24)
        #expect(!drained[0].payload.monitoredDesktop.windowIdsTruncated)
    }

    @Test("activeWindowId's 0xFFFFFFFF sentinel (adr/0008 §0: no active window) survives post/drain unchanged")
    func activeWindowIdSentinelPassesThroughUnchanged() {
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_MONITORED_DESKTOP
        ev.payload.monitoredDesktop.fieldFlags = 0x0000_0020 // WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND
        ev.payload.monitoredDesktop.activeWindowId = 0xFFFF_FFFF

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        #expect(drained[0].payload.monitoredDesktop.activeWindowId == 0xFFFF_FFFF, "the sentinel must not be reinterpreted/clamped by the transport -- that's the consumer's job (adr/0008 §0)")
    }
}

@Suite("adr/0008: WindowOrder.visibilityRects truncation")
struct CRDPQVisibilityRectsTruncationTests {
    @Test("33 rects: exactly 32 stored, truncated flag set, wire count (33) preserved through post/drain")
    func visibilityRectsTruncatedAt32() {
        let wireCount: UInt32 = 33
        var ev = makeWindowCreateEvent(windowId: 42)
        ev.payload.windowOrder.numVisibilityRects = wireCount
        ev.payload.windowOrder.visibilityRectsTruncated = wireCount > UInt32(CRDPQ_MAX_VISIBILITY_RECTS)
        withUnsafeMutablePointer(to: &ev.payload.windowOrder.visibilityRects) { arrayPtr in
            arrayPtr.withMemoryRebound(to: crdpq_rect_t.self, capacity: Int(CRDPQ_MAX_VISIBILITY_RECTS)) { buf in
                for i in 0..<Int(CRDPQ_MAX_VISIBILITY_RECTS) {
                    let v = UInt16(i)
                    buf[i] = crdpq_rect_t(left: v, top: v + 1, right: v + 2, bottom: v + 3)
                }
            }
        }

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        let wo = drained[0].payload.windowOrder
        #expect(wo.numVisibilityRects == 33, "wire count must survive even though only 32 slots exist")
        #expect(wo.visibilityRectsTruncated)
        var mutableWo = wo
        withUnsafeMutablePointer(to: &mutableWo.visibilityRects) { arrayPtr in
            arrayPtr.withMemoryRebound(to: crdpq_rect_t.self, capacity: Int(CRDPQ_MAX_VISIBILITY_RECTS)) { buf in
                for i in 0..<Int(CRDPQ_MAX_VISIBILITY_RECTS) {
                    let v = UInt16(i)
                    #expect(buf[i].left == v && buf[i].top == v + 1 && buf[i].right == v + 2 && buf[i].bottom == v + 3, "slot \(i) corrupted by the queue's deep copy")
                }
            }
        }
    }
}

@Suite("adr/0008: the three previously-unwired event types round-trip through the queue")
struct CRDPQNewEventTypesTests {
    @Test("LocalMoveSize: isMoveSizeStart survives as a real bool, posX/posY as int32_t")
    func localMoveSizeRoundTrips() {
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_LOCAL_MOVE_SIZE
        ev.payload.localMoveSize.windowId = 7
        ev.payload.localMoveSize.isMoveSizeStart = true
        ev.payload.localMoveSize.moveSizeType = 5 // an LMS_* handshake constant, uninterpreted here
        ev.payload.localMoveSize.posX = -120
        ev.payload.localMoveSize.posY = 2580 // near the largest position observed in samples

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        #expect(drained[0].type == CRDPQ_EVENT_LOCAL_MOVE_SIZE)
        let lms = drained[0].payload.localMoveSize
        #expect(lms.windowId == 7)
        #expect(lms.isMoveSizeStart)
        #expect(lms.moveSizeType == 5)
        #expect(lms.posX == -120)
        #expect(lms.posY == 2580)
    }

    @Test("MinMaxInfo: all eight int32_t fields round-trip")
    func minMaxInfoRoundTrips() {
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_MIN_MAX_INFO
        ev.payload.minMaxInfo.windowId = 9
        ev.payload.minMaxInfo.maxWidth = 1920
        ev.payload.minMaxInfo.maxHeight = 1080
        ev.payload.minMaxInfo.maxPosX = -1
        ev.payload.minMaxInfo.maxPosY = -1
        ev.payload.minMaxInfo.minTrackWidth = 160
        ev.payload.minMaxInfo.minTrackHeight = 120
        ev.payload.minMaxInfo.maxTrackWidth = 7680
        ev.payload.minMaxInfo.maxTrackHeight = 4320

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        let mmi = drained[0].payload.minMaxInfo
        #expect(mmi.windowId == 9)
        #expect(mmi.maxWidth == 1920 && mmi.maxHeight == 1080)
        #expect(mmi.maxPosX == -1 && mmi.maxPosY == -1)
        #expect(mmi.minTrackWidth == 160 && mmi.minTrackHeight == 120)
        #expect(mmi.maxTrackWidth == 7680 && mmi.maxTrackHeight == 4320)
    }

    @Test("ZOrderSync: windowIdMarker round-trips, carries no array (adr/0008 §1)")
    func zorderSyncRoundTrips() {
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_ZORDER_SYNC
        ev.payload.zorderSync.windowIdMarker = 0xABCD_1234

        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        #expect(crdpq_post(q, &ev))
        let drained = drainToArray(q)
        #expect(drained[0].payload.zorderSync.windowIdMarker == 0xABCD_1234)
    }
}
