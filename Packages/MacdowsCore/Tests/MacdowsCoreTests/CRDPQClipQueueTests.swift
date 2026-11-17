import CRDPQueue
import MacdowsCore
import Testing

// The clipboard additions to the two lanes: four event kinds, three command kinds, one POD
// payload with a flags word. adr/0008 §5's append-only rule says no existing numeric value may
// move, so every value -- old and new -- is pinned here by number. The last suite drives the
// store, the control lane and the Swift session together the way crdpq.h's entry lifecycle
// says the bridge must.

@Suite("CRDPQueue clipboard kinds: append-only enum values")
struct CRDPQClipEnumPinTests {
    @Test("crdpq_event_type_t: the 16 existing kinds keep their numbers; the 4 clipboard kinds are 16, 17, 18, 19")
    func eventKinds() {
        let pinned: [(crdpq_event_type_t, UInt32)] = [
            (CRDPQ_EVENT_WINDOW_CREATE, 0), (CRDPQ_EVENT_WINDOW_UPDATE, 1), (CRDPQ_EVENT_WINDOW_DELETE, 2),
            (CRDPQ_EVENT_WINDOW_ICON, 3), (CRDPQ_EVENT_NOTIFY_ICON_CREATE, 4), (CRDPQ_EVENT_NOTIFY_ICON_UPDATE, 5),
            (CRDPQ_EVENT_NOTIFY_ICON_DELETE, 6), (CRDPQ_EVENT_MONITORED_DESKTOP, 7), (CRDPQ_EVENT_EXEC_RESULT, 8),
            (CRDPQ_EVENT_HANDSHAKE_FLAGS, 9), (CRDPQ_EVENT_SURFACE_MAPPED, 10), (CRDPQ_EVENT_FRAME_READY, 11),
            (CRDPQ_EVENT_DISCONNECTED, 12), (CRDPQ_EVENT_LOCAL_MOVE_SIZE, 13), (CRDPQ_EVENT_MIN_MAX_INFO, 14),
            (CRDPQ_EVENT_ZORDER_SYNC, 15),
            (CRDPQ_EVENT_CLIP_READY, 16), (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, 17), (CRDPQ_EVENT_CLIP_REMOTE_DATA, 18),
            (CRDPQ_EVENT_CLIP_DATA_REQUEST, 19),
        ]
        for (kind, value) in pinned {
            #expect(kind.rawValue == value, "event kind expected at \(value)")
        }
    }

    @Test("crdpq_command_type_t: the 6 existing kinds keep their numbers; the 3 clipboard kinds are 6, 7, 8")
    func commandKinds() {
        let pinned: [(crdpq_command_type_t, UInt32)] = [
            (CRDPQ_CMD_EXECUTE, 0), (CRDPQ_CMD_ACTIVATE, 1), (CRDPQ_CMD_WINDOW_MOVE, 2), (CRDPQ_CMD_SYS_COMMAND, 3),
            (CRDPQ_CMD_INPUT, 4), (CRDPQ_CMD_NOTIFY_EVENT, 5),
            (CRDPQ_CMD_CLIP_ANNOUNCE, 6), (CRDPQ_CMD_CLIP_REQUEST, 7), (CRDPQ_CMD_CLIP_RESPOND, 8),
        ]
        for (kind, value) in pinned {
            #expect(kind.rawValue == value, "command kind expected at \(value)")
        }
    }

    @Test("status, direction and result values are fixed")
    func clipEnums() {
        #expect(CRDPQ_CLIP_STATUS_OK.rawValue == 0)
        #expect(CRDPQ_CLIP_STATUS_FAILED.rawValue == 1)
        #expect(CRDPQ_CLIP_STATUS_NOT_STORED.rawValue == 2)
        #expect(CRDPQ_CLIP_REMOTE_TO_LOCAL.rawValue == 0)
        #expect(CRDPQ_CLIP_LOCAL_TO_REMOTE.rawValue == 1)
        // KEY_IN_USE (gate r1, m-3) went in before the NO_MEMORY anchor while none of these
        // values had been committed; from here on they are fixed.
        let results: [crdpq_clip_result_t] = [
            CRDPQ_CLIP_OK, CRDPQ_CLIP_ERR_ARGUMENT, CRDPQ_CLIP_ERR_STALE_GENERATION, CRDPQ_CLIP_ERR_NOT_FOUND,
            CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE, CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE, CRDPQ_CLIP_ERR_SLOTS_FULL,
            CRDPQ_CLIP_ERR_BUFFER_TOO_SMALL, CRDPQ_CLIP_ERR_KEY_IN_USE, CRDPQ_CLIP_ERR_NO_MEMORY,
        ]
        #expect(results.map(\.rawValue) == Array(0..<10))
    }

    /// The Swift layer cannot import the C module (its sources are pinned free of it), so the
    /// one number both sides must agree on -- "no format", the empty announce list -- is tied
    /// together here.
    @Test("CRDPQ_CLIP_NO_FORMAT is 0, and it is what the Swift layer puts in an empty announce")
    func noFormat() {
        #expect(CRDPQ_CLIP_NO_FORMAT == 0)
        #expect(ClipboardFormatList.empty.announcedFormatId == UInt32(CRDPQ_CLIP_NO_FORMAT))
        #expect(ClipboardFormatList.unicodeText.announcedFormatId == ClipboardFormat.unicodeText)
        #expect(UInt32(CRDPQ_CLIP_NO_FORMAT) != ClipboardFormat.unicodeText)
    }

    /// Same reason as above: the Swift layer decodes REMOTE_FORMATS' `flags` with its own copy
    /// of the two bit values, so a swap on either side must fail here.
    @Test("the REMOTE_FORMATS flag bits are 1 and 2, and the Swift layer decodes exactly these bits")
    func flagBits() {
        #expect(CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT == 0x1)
        #expect(CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED == 0x2)
        #expect(ClipboardRemoteFormats.offersUnicodeTextFlag == UInt32(CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT))
        #expect(ClipboardRemoteFormats.remoteExcludedFlag == UInt32(CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED))
        #expect(ClipboardRemoteFormats(flags: UInt32(CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT))
                == ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false))
        #expect(ClipboardRemoteFormats(flags: UInt32(CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED))
                == ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: true))
        #expect(ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: true).flags
                == UInt32(CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED))
    }
}

@Suite("CRDPQueue clipboard payload: POD layout")
struct CRDPQClipLayoutTests {
    /// Same three pin kinds the surface-map and notify-event payloads use (CRDPQueueTests'
    /// layout suite explains why each sees what the others cannot): size, member width,
    /// member offset.
    @Test("crdpq_clip_ref_t is six uint32_t, 24 bytes, in declaration order; flags is appended last")
    func clipRef() {
        #expect(MemoryLayout<crdpq_clip_ref_t>.size == 24)
        #expect(MemoryLayout<crdpq_clip_ref_t>.alignment == 4)
        let probe = crdpq_clip_ref_t()
        #expect(MemoryLayout.size(ofValue: probe.storeGeneration) == 4)
        #expect(MemoryLayout.size(ofValue: probe.sequence) == 4)
        #expect(MemoryLayout.size(ofValue: probe.formatId) == 4)
        #expect(MemoryLayout.size(ofValue: probe.byteCount) == 4)
        #expect(MemoryLayout.size(ofValue: probe.status) == 4)
        #expect(MemoryLayout.size(ofValue: probe.flags) == 4)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.storeGeneration) == 0)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.sequence) == 4)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.formatId) == 8)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.byteCount) == 12)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.status) == 16)
        #expect(MemoryLayout<crdpq_clip_ref_t>.offset(of: \.flags) == 20)
    }

    @Test("adding it (and growing it to 24) moved neither union nor either envelope")
    func unionsUnchanged() {
        #expect(MemoryLayout<crdpq_event_payload_t>.size == 592)
        #expect(MemoryLayout<CrdpEvent>.size == 600)
        #expect(MemoryLayout<CrdpEvent>.alignment == 8)
        #expect(MemoryLayout<crdpq_command_payload_t>.size == 260)
        #expect(MemoryLayout<CrdpCommand>.size == 264)
    }
}

@Suite("CRDPQueue clipboard kinds: round trips through both lanes")
struct CRDPQClipLaneRoundTripTests {
    static func ref(generation: UInt32 = 0, sequence: UInt32 = 0, formatId: UInt32 = 0, byteCount: UInt32 = 0,
                    status: UInt32 = 0, flags: UInt32 = 0) -> crdpq_clip_ref_t {
        var ref = crdpq_clip_ref_t()
        ref.storeGeneration = generation
        ref.sequence = sequence
        ref.formatId = formatId
        ref.byteCount = byteCount
        ref.status = status
        ref.flags = flags
        return ref
    }

    static func expectSame(_ got: crdpq_clip_ref_t, _ want: crdpq_clip_ref_t, _ index: Int) {
        #expect(got.storeGeneration == want.storeGeneration, "item \(index)")
        #expect(got.sequence == want.sequence, "item \(index)")
        #expect(got.formatId == want.formatId, "item \(index)")
        #expect(got.byteCount == want.byteCount, "item \(index)")
        #expect(got.status == want.status, "item \(index)")
        #expect(got.flags == want.flags, "item \(index)")
    }

    /// Every field used by a kind is distinct from every other field of that item, so a swapped
    /// or shifted field cannot pass by symmetry (the same reasoning `notifyEventRoundTrip`
    /// records). The fields are the ones crdpq.h assigns to each kind.
    @Test("the four clipboard events survive post/drain bit-exact, in order, stamped with the session generation")
    func events() {
        let q = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(q) }
        _ = crdpq_generation_bump(q)

        let items: [(crdpq_event_type_t, crdpq_clip_ref_t)] = [
            (CRDPQ_EVENT_CLIP_READY, Self.ref(generation: 0x0102_0304)),
            (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, Self.ref(generation: 0x0102_0304, flags: CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT)),
            (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, Self.ref(generation: 0x0102_0305, flags: CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED)),
            (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, Self.ref(generation: 0x0102_0306,
                                                       flags: CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED)),
            (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, Self.ref(generation: 0x0102_0307, flags: 0)),
            (CRDPQ_EVENT_CLIP_REMOTE_FORMATS, Self.ref(generation: 0x0102_0308, flags: 0xFFFF_FFFF)),
            (CRDPQ_EVENT_CLIP_REMOTE_DATA, Self.ref(generation: 0x0102_0304, sequence: 0xA1B2_C3D4, byteCount: 0x0040_0000,
                                                    status: CRDPQ_CLIP_STATUS_NOT_STORED.rawValue)),
            (CRDPQ_EVENT_CLIP_REMOTE_DATA, Self.ref(generation: 0x0102_0304, sequence: 0xA1B2_C3D5, status: CRDPQ_CLIP_STATUS_FAILED.rawValue)),
            (CRDPQ_EVENT_CLIP_DATA_REQUEST, Self.ref(generation: 0xFFFF_FFFE, formatId: 0xC0FF)),
        ]
        for (kind, ref) in items {
            var ev = CrdpEvent()
            ev.type = kind
            ev.payload.clip = ref
            #expect(crdpq_post(q, &ev))
        }
        let drained = drainToArray(q)
        #expect(drained.count == items.count)
        guard drained.count == items.count else { return }
        for (i, ev) in drained.enumerated() {
            #expect(ev.type == items[i].0)
            #expect(ev.generation == 1)
            Self.expectSame(ev.payload.clip, items[i].1, i)
        }
    }

    @Test("the three clipboard commands survive post/drain bit-exact, in order")
    func commands() {
        let q = crdpq_outbound_create(nil, nil)
        defer { crdpq_outbound_destroy(q) }
        let items: [(crdpq_command_type_t, crdpq_clip_ref_t)] = [
            (CRDPQ_CMD_CLIP_ANNOUNCE, Self.ref(formatId: ClipboardFormatList.unicodeText.announcedFormatId)),
            (CRDPQ_CMD_CLIP_ANNOUNCE, Self.ref(formatId: ClipboardFormatList.empty.announcedFormatId)),
            (CRDPQ_CMD_CLIP_REQUEST, Self.ref(formatId: 13)),
            (CRDPQ_CMD_CLIP_RESPOND, Self.ref(generation: 0x1122_3344, sequence: 0x5566_7788, formatId: 13,
                                              byteCount: 0x0012_3456, status: CRDPQ_CLIP_STATUS_FAILED.rawValue)),
            (CRDPQ_CMD_CLIP_RESPOND, Self.ref(generation: 0x1122_3344, sequence: 0x5566_7789, formatId: 13,
                                              byteCount: 0x0000_0042, status: CRDPQ_CLIP_STATUS_OK.rawValue)),
        ]
        for (kind, ref) in items {
            var cmd = CrdpCommand()
            cmd.type = kind
            cmd.payload.clip = ref
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
        #expect(drained.count == items.count)
        guard drained.count == items.count else { return }
        for (i, cmd) in drained.enumerated() {
            #expect(cmd.type == items[i].0)
            Self.expectSame(cmd.payload.clip, items[i].1, i)
        }
    }
}

@Suite("CRDPQueue clipboard: a store entry leaves the store on every outcome (crdpq.h, lifecycle of an entry)")
struct CRDPQClipEntryLifecycleTests {
    static let blockLimit = 64 * 1024
    static let text = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false)
    static let noText = ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false)

    /// The bridge's T_clip half of one Format Data Response: put the bytes, then post
    /// REMOTE_DATA -- status OK with the response number as the key, or NOT_STORED (and no
    /// block) when the put was refused. Returns the put's result.
    @discardableResult
    static func produce(store: OpaquePointer?, lane: OpaquePointer?, generation: UInt32, responseNumber: UInt32,
                        bytes: [UInt8]) -> crdpq_clip_result_t {
        let rc = bytes.withUnsafeBufferPointer {
            crdpq_clip_store_put(store, generation, CRDPQ_CLIP_REMOTE_TO_LOCAL, responseNumber, $0.baseAddress, $0.count)
        }
        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_CLIP_REMOTE_DATA
        ev.payload.clip = CRDPQClipLaneRoundTripTests.ref(
            generation: generation, sequence: responseNumber, byteCount: UInt32(bytes.count),
            status: rc == CRDPQ_CLIP_OK ? CRDPQ_CLIP_STATUS_OK.rawValue : CRDPQ_CLIP_STATUS_NOT_STORED.rawValue)
        #expect(crdpq_post(lane, &ev))
        return rc
    }

    /// The bridge's T_main half for one drained REMOTE_DATA: first remove the entry -- take it,
    /// or discard it when the session says the answer cannot be written (`alwaysTake` false) --
    /// then hand the session what that gave.
    static func consume(_ ev: CrdpEvent, store: OpaquePointer?, session: inout ClipboardSession, changeCount: Int,
                        alwaysTake: Bool, now: ContinuousClock.Instant) -> ClipboardRemoteDataResult {
        let ref = ev.payload.clip
        let byteCount = Int(ref.byteCount)
        let response: ClipboardDataResponse
        switch ref.status {
        case CRDPQ_CLIP_STATUS_OK.rawValue:
            if alwaysTake || session.expectsRemoteData {
                var buffer = [UInt8](repeating: 0, count: byteCount)
                var length = 0
                let rc = buffer.withUnsafeMutableBufferPointer {
                    crdpq_clip_store_take(store, ref.storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, ref.sequence,
                                          $0.baseAddress, $0.count, &length)
                }
                response = rc == CRDPQ_CLIP_OK ? .success(ClipboardBytes(Array(buffer.prefix(length))))
                                               : .successWithoutBytes(byteCount: byteCount)
                buffer.withUnsafeMutableBytes { crdpq_clip_wipe($0.baseAddress, $0.count) }
            } else {
                _ = crdpq_clip_store_discard(store, ref.storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, ref.sequence)
                response = .successWithoutBytes(byteCount: byteCount)
            }
        case CRDPQ_CLIP_STATUS_NOT_STORED.rawValue:
            response = .successWithoutBytes(byteCount: byteCount)
        default:
            response = .failure
        }
        return session.remoteDataReceived(response, changeCount: changeCount, now: now)
    }

    /// The brief's case: big blocks, each answering a request a newer list has superseded, so
    /// each event is judged stale and dropped. With the total limit at two blocks and four slots,
    /// a consumer that left even two of them behind would be refused by the third put.
    @Test("one stale big block after another: each is removed, live bytes return to 0, the next block still fits",
          arguments: [true, false])
    func staleBlocksDoNotAccumulate(_ alwaysTake: Bool) {
        let store = crdpq_clip_store_create(Self.blockLimit, 2 * Self.blockLimit)
        defer { crdpq_clip_store_destroy(store) }
        let lane = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(lane) }
        let generation = crdpq_clip_store_generation(store)
        var session = ClipboardSession(policy: ClipboardPolicy(
            mode: .bidirectional, limits: ClipboardLimits(remoteToLocalMaxBytes: Self.blockLimit)))
        let t0 = ContinuousClock.now
        let block = [UInt8](repeating: 0x41, count: Self.blockLimit)
        let rounds = 3 * Int(CRDPQ_CLIP_SLOTS_PER_DIRECTION)
        var responseNumber: UInt32 = 0
        for round in 0..<rounds {
            #expect(session.remoteFormatsReceived(Self.text, changeCount: 1, now: t0).request != nil)
            _ = session.remoteFormatsReceived(Self.noText, changeCount: 1, now: t0)   // supersedes it
            responseNumber &+= 1
            let rc = Self.produce(store: store, lane: lane, generation: generation, responseNumber: responseNumber, bytes: block)
            #expect(rc == CRDPQ_CLIP_OK, "round \(round): the block must fit -- every earlier one was removed")
            let drained = drainToArray(lane)
            #expect(drained.count == 1)
            for ev in drained {
                let result = Self.consume(ev, store: store, session: &session, changeCount: 1, alwaysTake: alwaysTake, now: t0)
                #expect(result.outcome == .drop(.staleAnswer), "round \(round)")
            }
            #expect(crdpq_clip_store_live_bytes(store) == 0, "round \(round)")
            #expect(crdpq_clip_store_live_count(store, CRDPQ_CLIP_REMOTE_TO_LOCAL) == 0, "round \(round)")
        }
        #expect(session.counters.count(ClipboardInboundDropReason.staleAnswer) == rounds)
        let next = Self.produce(store: store, lane: lane, generation: generation, responseNumber: responseNumber &+ 1, bytes: block)
        #expect(next == CRDPQ_CLIP_OK, "the next full-size block still fits")
        #expect(crdpq_clip_store_refusal_count(store, CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE) == 0)
        #expect(crdpq_clip_store_refusal_count(store, CRDPQ_CLIP_ERR_SLOTS_FULL) == 0)
        _ = drainToArray(lane)
    }

    @Test("every other outcome removes its entry too: unexpected, local-newer, over the limit (not stored) and written")
    func everyOutcomeRemoves() {
        let store = crdpq_clip_store_create(Self.blockLimit, 2 * Self.blockLimit)
        defer { crdpq_clip_store_destroy(store) }
        let lane = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(lane) }
        let generation = crdpq_clip_store_generation(store)
        var session = ClipboardSession(policy: ClipboardPolicy(
            mode: .bidirectional, limits: ClipboardLimits(remoteToLocalMaxBytes: Self.blockLimit)))
        let t0 = ContinuousClock.now
        let fixture = ClipboardTextCodec.encodeUnicodeText("fixture lifecycle 测试").bytes
        var responseNumber: UInt32 = 0
        func round(_ bytes: [UInt8], changeCount: Int, expect outcome: ClipboardInboundOutcome, _ label: String) {
            responseNumber &+= 1
            Self.produce(store: store, lane: lane, generation: generation, responseNumber: responseNumber, bytes: bytes)
            for ev in drainToArray(lane) {
                let result = Self.consume(ev, store: store, session: &session, changeCount: changeCount, alwaysTake: false, now: t0)
                #expect(result.outcome == outcome, "\(label)")
            }
            #expect(crdpq_clip_store_live_bytes(store) == 0, "\(label)")
        }
        round(fixture, changeCount: 1, expect: .drop(.unexpectedAnswer), "unexpected")
        _ = session.remoteFormatsReceived(Self.text, changeCount: 1, now: t0)
        round(fixture, changeCount: 2, expect: .drop(.localNewer), "local newer")
        _ = session.remoteFormatsReceived(Self.text, changeCount: 2, now: t0)
        round([UInt8](repeating: 0x41, count: Self.blockLimit + 2), changeCount: 2, expect: .drop(.tooLarge), "over the limit")
        #expect(crdpq_clip_store_refusal_count(store, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE) == 1)
        _ = session.remoteFormatsReceived(Self.text, changeCount: 2, now: t0)
        round(fixture, changeCount: 2, expect: .write(ClipboardText("fixture lifecycle 测试"), sensitive: false), "written")
    }

    /// Gate r1, m-3, end to end: a producer that reuses a live response number -- a channel
    /// reloaded within one connection restarting its counter, say -- gets its put refused and
    /// posts NOT_STORED. The earlier event still takes ITS bytes; under the old upsert it would
    /// have taken the later block's and written the wrong text.
    @Test("a reused response number: the earlier event still takes its own bytes, the later one is not stored")
    func reusedResponseNumber() {
        let store = crdpq_clip_store_create(Self.blockLimit, 2 * Self.blockLimit)
        defer { crdpq_clip_store_destroy(store) }
        let lane = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(lane) }
        let generation = crdpq_clip_store_generation(store)
        var session = ClipboardSession(policy: ClipboardPolicy(
            mode: .bidirectional, limits: ClipboardLimits(remoteToLocalMaxBytes: Self.blockLimit)))
        let t0 = ContinuousClock.now
        #expect(session.remoteFormatsReceived(Self.text, changeCount: 1, now: t0).request != nil)
        let first = ClipboardTextCodec.encodeUnicodeText("fixture first answer").bytes
        let second = ClipboardTextCodec.encodeUnicodeText("fixture other answer").bytes
        #expect(Self.produce(store: store, lane: lane, generation: generation, responseNumber: 1, bytes: first) == CRDPQ_CLIP_OK)
        #expect(Self.produce(store: store, lane: lane, generation: generation, responseNumber: 1, bytes: second)
                == CRDPQ_CLIP_ERR_KEY_IN_USE)
        let drained = drainToArray(lane)
        #expect(drained.count == 2)
        #expect(drained.map(\.payload.clip.status) == [CRDPQ_CLIP_STATUS_OK.rawValue, CRDPQ_CLIP_STATUS_NOT_STORED.rawValue])
        let outcomes = drained.map {
            Self.consume($0, store: store, session: &session, changeCount: 1, alwaysTake: true, now: t0).outcome
        }
        #expect(outcomes == [.write(ClipboardText("fixture first answer"), sensitive: false), .drop(.unexpectedAnswer)])
        #expect(crdpq_clip_store_live_bytes(store) == 0)
        #expect(crdpq_clip_store_refusal_count(store, CRDPQ_CLIP_ERR_KEY_IN_USE) == 1)
    }

    /// Why the contract matters: what the store does to a consumer that keeps the blocks.
    @Test("control: a consumer that skips the removal is refused by the third big put")
    func skippingTheRemovalFillsTheStore() {
        let store = crdpq_clip_store_create(Self.blockLimit, 2 * Self.blockLimit)
        defer { crdpq_clip_store_destroy(store) }
        let lane = crdpq_control_create(nil, nil)
        defer { crdpq_control_destroy(lane) }
        let generation = crdpq_clip_store_generation(store)
        let block = [UInt8](repeating: 0x41, count: Self.blockLimit)
        #expect(Self.produce(store: store, lane: lane, generation: generation, responseNumber: 1, bytes: block) == CRDPQ_CLIP_OK)
        #expect(Self.produce(store: store, lane: lane, generation: generation, responseNumber: 2, bytes: block) == CRDPQ_CLIP_OK)
        #expect(Self.produce(store: store, lane: lane, generation: generation, responseNumber: 3, bytes: block)
                == CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE)
        _ = drainToArray(lane)
    }
}
