import Foundation
import MacdowsCore
import Testing

// W3 route B step 1 (survey §0/§1/§5 (b)). Sibling of `ResizeMarginCorpusPinTests`, and the reason
// route B was preferred over the `resizeMargin*` road: a census of the three client-rect
// `fieldFlags` bits over the U7-frozen samples, attributing each order to its window's CREATE-time
// style (a WindowUpdate carries `style = 0` when the style field is not part of the update --
// `fieldFlags` decides -- so the update's own `style` column says nothing about the window).
//
// What the census showed on the retired 1x corpus (2026-09-10): 202 orders (138 creates, 64
// updates); CLIENT_AREA_OFFSET, WND_CLIENT_DELTA and VIS_OFFSET each on exactly the same 142;
// CLIENT_AREA_SIZE on zero.
//
// RECOMPUTED on the 2026-09-21 2x corpus (U-7 rebaseline), measured, with one 1x conclusion that
// does NOT survive the re-record:
//   * 190 window orders total: 125 WindowCreate, 65 WindowUpdate.
//   * CLIENT_AREA_OFFSET (0x4000) rides on 126 of them -- all 125 creates plus one update;
//     WND_CLIENT_DELTA (0x8000) rides on 127. The two bits are therefore NOT co-present order for
//     order any more (one update carries the delta without the offset), which is exactly why they
//     have always been counted independently here: window.c:334 and :395 are separate `if`s.
//   * VIS_OFFSET (0x1000) rides on 126 -- the same count as CLIENT_AREA_OFFSET, one fewer than
//     WND_CLIENT_DELTA. The 1x "all three co-present" reading was a property of that session.
//   * CLIENT_AREA_SIZE (0x10000) still rides on ZERO of them. That is the finding that shapes the
//     whole lane: the server never states the client area's SIZE, so no offline fixture can ever
//     check "content rect == server clientArea" (survey §0, §6.1 A). Only the ORIGIN pairs exist.
//
// The census counts BITS, not values, and keeps doing so on the 2x corpus even though its probe
// DOES log `clientOffsetX/Y` and `windowClientDeltaX/Y` (W3 route B step 1): what this pin exists
// to catch is a change in which ORDERS carry the fields. `ClientRectPayloadTests` covers the
// decode side and the value semantics.
//
// Layering (ReplayTests' own rule): the corpus pins are frozen-baseline feature pins
// (`.enabled(if: ReplayTests.samplesDirIsFrozenBaseline)`); the census helper itself is pinned
// portably on synthetic lines so a wrong helper cannot hide behind a skipped pin.

struct ClientRectCensus: Equatable {
    static let clientAreaOffset: UInt32 = 0x0000_4000 // WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET (window.h:39)
    static let wndClientDelta: UInt32 = 0x0000_8000   // WINDOW_ORDER_FIELD_WND_CLIENT_DELTA (window.h:46)
    static let clientAreaSize: UInt32 = 0x0001_0000   // WINDOW_ORDER_FIELD_CLIENT_AREA_SIZE (window.h:40)
    static let visOffset: UInt32 = 0x0000_1000        // WINDOW_ORDER_FIELD_VIS_OFFSET (window.h:49)
    static let thickFrame: UInt32 = 0x0004_0000       // WS_THICKFRAME

    var orders = 0
    var creates = 0
    var updates = 0
    /// Orders carrying each bit, counted independently -- the two pairs have INDEPENDENT validity
    /// bits (window.c:334 and :395 are separate `if`s), exactly like `resizeMargin*`'s X/Y pair.
    var clientAreaOffsetOrders = 0
    var wndClientDeltaOrders = 0
    var visOffsetOrders = 0
    var clientAreaSizeOrders = 0
    var createsWithBothBits = 0
    var updatesWithBothBits = 0
    /// Create-time style of every window whose UPDATE carried both bits (deduplicated).
    var updateBitWindowsCreateStyles: Set<UInt32> = []
    /// Style of every CREATE that carried both bits (deduplicated).
    var createBitStyles: Set<UInt32> = []

    /// Both pairs present. Deliberately NOT "either" -- a consumer that wants the client-rect
    /// origin needs `clientOffset` and `windowClientDelta` to agree about the same order.
    static func hasBothBits(_ fieldFlags: UInt32) -> Bool {
        fieldFlags & clientAreaOffset != 0 && fieldFlags & wndClientDelta != 0
    }

    /// One scenario's events, in file order (creates precede the updates that reference them).
    static func of(_ events: [RailEvent]) -> ClientRectCensus {
        var c = ClientRectCensus()
        var createStyle: [UInt32: UInt32] = [:]
        for e in events {
            let payload: WindowOrderPayload
            let isCreate: Bool
            switch e.kind {
            case .windowCreate(let p): payload = p; isCreate = true
            case .windowUpdate(let p): payload = p; isCreate = false
            default: continue
            }
            c.orders += 1
            let ff = payload.fieldFlags
            if ff & clientAreaOffset != 0 { c.clientAreaOffsetOrders += 1 }
            if ff & wndClientDelta != 0 { c.wndClientDeltaOrders += 1 }
            if ff & visOffset != 0 { c.visOffsetOrders += 1 }
            if ff & clientAreaSize != 0 { c.clientAreaSizeOrders += 1 }
            let both = hasBothBits(ff)
            if isCreate {
                c.creates += 1
                if createStyle[payload.windowId] == nil { createStyle[payload.windowId] = payload.style }
                if both {
                    c.createsWithBothBits += 1
                    c.createBitStyles.insert(payload.style)
                }
            } else {
                c.updates += 1
                if both {
                    c.updatesWithBothBits += 1
                    if let s = createStyle[payload.windowId] { c.updateBitWindowsCreateStyles.insert(s) }
                }
            }
        }
        return c
    }

    static func += (lhs: inout ClientRectCensus, rhs: ClientRectCensus) {
        lhs.orders += rhs.orders
        lhs.creates += rhs.creates
        lhs.updates += rhs.updates
        lhs.clientAreaOffsetOrders += rhs.clientAreaOffsetOrders
        lhs.wndClientDeltaOrders += rhs.wndClientDeltaOrders
        lhs.visOffsetOrders += rhs.visOffsetOrders
        lhs.clientAreaSizeOrders += rhs.clientAreaSizeOrders
        lhs.createsWithBothBits += rhs.createsWithBothBits
        lhs.updatesWithBothBits += rhs.updatesWithBothBits
        lhs.updateBitWindowsCreateStyles.formUnion(rhs.updateBitWindowsCreateStyles)
        lhs.createBitStyles.formUnion(rhs.createBitStyles)
    }
}

@Suite("Client-rect census (W3 route B step 1 / survey §0 CLIENT_AREA_SIZE correction)")
struct ClientRectCorpusPinTests {
    // MARK: portable -- the helper itself, on synthetic lines

    private static func events(_ lines: String) -> [RailEvent] {
        let parsed = RailEvent.parseJSONL(lines)
        precondition(parsed.failures.isEmpty, "fixture must parse: \(parsed.failures)")
        return parsed.events
    }

    private static func create(_ id: UInt32, style: UInt32, fieldFlags: UInt32) -> String {
        #"{"t_ms":1,"tid":"0x1","ev":"WindowCreate","windowId":\#(id),"fieldFlags":\#(fieldFlags),"windowOffsetX":0,"windowOffsetY":0,"windowWidth":10,"windowHeight":10,"numVisibilityRects":1,"style":\#(style),"styleEx":0,"show":0,"title":""}"#
    }

    private static func update(_ id: UInt32, fieldFlags: UInt32) -> String {
        #"{"t_ms":2,"tid":"0x1","ev":"WindowUpdate","windowId":\#(id),"fieldFlags":\#(fieldFlags),"windowOffsetX":0,"windowOffsetY":0,"windowWidth":0,"windowHeight":0,"numVisibilityRects":0,"style":0,"styleEx":0,"show":0,"title":""}"#
    }

    private static let bothBits = ClientRectCensus.clientAreaOffset | ClientRectCensus.wndClientDelta

    @Test("both bits are required; either bit alone is not a client-rect order")
    func bothBitsRequired() {
        #expect(ClientRectCensus.hasBothBits(Self.bothBits))
        #expect(!ClientRectCensus.hasBothBits(ClientRectCensus.clientAreaOffset))
        #expect(!ClientRectCensus.hasBothBits(ClientRectCensus.wndClientDelta))
        #expect(ClientRectCensus.hasBothBits(0x1100_DF1E))  // the corpus's WindowCreate shape
        #expect(ClientRectCensus.hasBothBits(0x0100_DF00))  // the corpus's geometry-delta shape
        #expect(!ClientRectCensus.hasBothBits(0x0100_0004)) // title-only
        #expect(!ClientRectCensus.hasBothBits(0x0900_0080)) // resize-margin-only
    }

    @Test("CLIENT_AREA_SIZE is a different bit from the two this census counts, and 0x1100DF1E does not carry it")
    func clientAreaSizeIsSeparate() {
        #expect(ClientRectCensus.clientAreaSize != ClientRectCensus.clientAreaOffset)
        #expect(ClientRectCensus.clientAreaSize != ClientRectCensus.wndClientDelta)
        #expect(0x1100_DF1E & ClientRectCensus.clientAreaSize == 0)
        let c = ClientRectCensus.of(Self.events(Self.create(1, style: 0, fieldFlags: Self.bothBits | ClientRectCensus.clientAreaSize)))
        #expect(c.clientAreaSizeOrders == 1, "the counter must actually see the bit when it IS set -- otherwise the frozen 0 below is vacuous")
    }

    @Test("an update carrying both bits is attributed to its window's CREATE-time style, not the update's own style field")
    func updateAttribution() {
        let c = ClientRectCensus.of(Self.events([
            Self.create(7, style: ClientRectCensus.thickFrame, fieldFlags: 0x0100_0004),
            Self.update(7, fieldFlags: Self.bothBits),
            Self.update(7, fieldFlags: 0x0000_0002),
        ].joined(separator: "\n")))
        #expect(c.orders == 3 && c.creates == 1 && c.updates == 2)
        #expect(c.updatesWithBothBits == 1)
        #expect(c.updateBitWindowsCreateStyles == [ClientRectCensus.thickFrame])
        #expect(c.createsWithBothBits == 0 && c.createBitStyles.isEmpty)
        #expect(c.clientAreaOffsetOrders == 1 && c.wndClientDeltaOrders == 1)
    }

    @Test("the two bits are counted independently -- an order with only one of them raises exactly one counter")
    func independentCounters() {
        let c = ClientRectCensus.of(Self.events([
            Self.create(1, style: 0, fieldFlags: ClientRectCensus.clientAreaOffset),
            Self.create(2, style: 0, fieldFlags: ClientRectCensus.wndClientDelta),
            Self.create(3, style: 0, fieldFlags: ClientRectCensus.visOffset),
        ].joined(separator: "\n")))
        #expect(c.clientAreaOffsetOrders == 1)
        #expect(c.wndClientDeltaOrders == 1)
        #expect(c.visOffsetOrders == 1)
        #expect(c.createsWithBothBits == 0)
    }

    // MARK: frozen-baseline pins (skip, not pass, under a SAMPLES_DIR override)

    @Test(
        "frozen corpus: 190 window orders; CLIENT_AREA_OFFSET and VIS_OFFSET on 126, WND_CLIENT_DELTA on 127; CLIENT_AREA_SIZE on 0",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenBitCensus() throws {
        var total = ClientRectCensus()
        for scenario in ReplayTests.Scenario.allCases {
            total += ClientRectCensus.of(try ReplayTests.replay(scenario).events)
        }
        #expect(total.orders == 190)
        #expect(total.clientAreaOffsetOrders == 126)
        // One MORE than the offset count: the two bits have INDEPENDENT validity bits and this
        // corpus contains an order that sets only the delta. Pinned as measured; the 1x corpus's
        // equal counts were a property of that session, not a protocol invariant.
        #expect(total.wndClientDeltaOrders == 127)
        // Co-presence, order for order, is measured -- not assumed. adr/0010 §0(b) already warns
        // that visibleOffset and windowOffset are DIFFERENT anchors; this pin records how often
        // that third anchor rides along, so a future divergence is a finding rather than a silent
        // behaviour change.
        #expect(total.visOffsetOrders == 126)
        // The survey's decisive §0 correction, made permanent: the server states the client area's
        // ORIGIN and never its SIZE.
        #expect(total.clientAreaSizeOrders == 0)
    }

    @Test(
        "frozen corpus: all 125 creates carry both bits; only 1 of 65 updates does, on a 0x800F0000 window",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenCreateUpdateSplit() throws {
        var total = ClientRectCensus()
        for scenario in ReplayTests.Scenario.allCases {
            total += ClientRectCensus.of(try ReplayTests.replay(scenario).events)
        }
        #expect(total.creates == 125)
        #expect(total.createsWithBothBits == 125, "every create carries the client-rect origin -- unlike resizeMargin*, which reaches 14 of 125")
        #expect(total.createBitStyles == [0x000F_0000, 0x8000_0000, 0x8008_0000, 0x800B_0000, 0x800F_0000])
        #expect(total.updates == 65)
        #expect(total.updatesWithBothBits == 1)
        #expect(total.updateBitWindowsCreateStyles == [0x800F_0000])
    }
}
