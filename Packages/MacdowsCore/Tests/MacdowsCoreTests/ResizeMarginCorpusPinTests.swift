import Foundation
import MacdowsCore
import Testing

// W3 lane A (ADR-0018 §2; ADR-0015 §7 (d) says `resizeMargin*` may only be wired after adr/0008
// §0's fieldFlags finding is re-checked against the corpus). This file IS that re-check, made
// permanent: a census of `WINDOW_ORDER_FIELD_RESIZE_MARGIN_X | _Y` over the U7-frozen samples,
// attributing each order to its window's CREATE-time style (a WindowUpdate carries `style = 0`
// when the style field is not part of the update -- `fieldFlags` decides -- so the update's own
// `style` column says nothing about the window).
//
// What the census shows on the frozen corpus (recomputed 2026-09-08, pinned below):
//   * WindowCreate: 138 orders, 7 with both margin bits -- all seven WS_POPUP helper windows
//     (style 0x80000000, sizes 1009x4 / 0x0); 6 THICKFRAME creates, none with the bits.
//   * WindowUpdate: 64 orders, 6 with both margin bits -- one per scenario, ALL on the same
//     THICKFRAME window (id 328256, create style 0x000F0000).
// So the margins DO reach the one window that could use them, via updates, not creates -- the
// 2026-09-08 survey counted creates only and concluded the opposite (its own §6 flagged the
// gap). rail-probe does not log the margin VALUES at all (no `resizeMargin*` field in any
// sample line), so whether the values are usable stays open until the probe logs them
// (adr/0008 §5 append-only) and a re-record exists -- that is what ADR-0018 U-5 now asks.
//
// Layering (ReplayTests' own rule): the corpus pins are frozen-baseline feature pins
// (`.enabled(if: ReplayTests.samplesDirIsFrozenBaseline)`); the census helper itself is pinned
// portably on synthetic lines so a wrong helper cannot hide behind a skipped pin.

struct ResizeMarginCensus: Equatable {
    static let marginX: UInt32 = 0x0000_0080      // WINDOW_ORDER_FIELD_RESIZE_MARGIN_X (window.h:41)
    static let marginY: UInt32 = 0x0800_0000      // WINDOW_ORDER_FIELD_RESIZE_MARGIN_Y (window.h:42)
    static let thickFrame: UInt32 = 0x0004_0000   // WS_THICKFRAME

    var creates = 0
    var createsWithBothBits = 0
    var thickFrameCreates = 0
    var thickFrameCreatesWithBothBits = 0
    var updates = 0
    var updatesWithBothBits = 0
    /// Create-time style of every window whose UPDATE carried both bits (deduplicated).
    var updateBitWindowsCreateStyles: Set<UInt32> = []
    /// (style, width, height) of every CREATE that carried both bits (deduplicated).
    var createBitShapes: Set<[UInt32]> = []

    static func hasBothBits(_ fieldFlags: UInt32) -> Bool {
        fieldFlags & marginX != 0 && fieldFlags & marginY != 0
    }

    /// One scenario's events, in file order (creates precede the updates that reference them).
    static func of(_ events: [RailEvent]) -> ResizeMarginCensus {
        var c = ResizeMarginCensus()
        var createStyle: [UInt32: UInt32] = [:]
        for e in events {
            switch e.kind {
            case .windowCreate(let p):
                c.creates += 1
                if createStyle[p.windowId] == nil { createStyle[p.windowId] = p.style }
                let both = hasBothBits(p.fieldFlags)
                if both {
                    c.createsWithBothBits += 1
                    c.createBitShapes.insert([p.style, p.windowWidth, p.windowHeight])
                }
                if p.style & thickFrame != 0 {
                    c.thickFrameCreates += 1
                    if both { c.thickFrameCreatesWithBothBits += 1 }
                }
            case .windowUpdate(let p):
                c.updates += 1
                if hasBothBits(p.fieldFlags) {
                    c.updatesWithBothBits += 1
                    if let s = createStyle[p.windowId] { c.updateBitWindowsCreateStyles.insert(s) }
                }
            default:
                break
            }
        }
        return c
    }

    static func += (lhs: inout ResizeMarginCensus, rhs: ResizeMarginCensus) {
        lhs.creates += rhs.creates
        lhs.createsWithBothBits += rhs.createsWithBothBits
        lhs.thickFrameCreates += rhs.thickFrameCreates
        lhs.thickFrameCreatesWithBothBits += rhs.thickFrameCreatesWithBothBits
        lhs.updates += rhs.updates
        lhs.updatesWithBothBits += rhs.updatesWithBothBits
        lhs.updateBitWindowsCreateStyles.formUnion(rhs.updateBitWindowsCreateStyles)
        lhs.createBitShapes.formUnion(rhs.createBitShapes)
    }
}

@Suite("Resize-margin census (W3 lane A / adr/0008 §0 re-check)")
struct ResizeMarginCorpusPinTests {
    // MARK: portable -- the helper itself, on synthetic lines

    private static func events(_ lines: String) -> [RailEvent] {
        let parsed = RailEvent.parseJSONL(lines)
        precondition(parsed.failures.isEmpty, "fixture must parse: \(parsed.failures)")
        return parsed.events
    }

    private static func create(_ id: UInt32, style: UInt32, fieldFlags: UInt32, w: UInt32 = 10, h: UInt32 = 10) -> String {
        #"{"t_ms":1,"tid":"0x1","ev":"WindowCreate","windowId":\#(id),"fieldFlags":\#(fieldFlags),"windowOffsetX":0,"windowOffsetY":0,"windowWidth":\#(w),"windowHeight":\#(h),"numVisibilityRects":1,"style":\#(style),"styleEx":0,"show":0,"title":""}"#
    }

    private static func update(_ id: UInt32, fieldFlags: UInt32) -> String {
        #"{"t_ms":2,"tid":"0x1","ev":"WindowUpdate","windowId":\#(id),"fieldFlags":\#(fieldFlags),"windowOffsetX":0,"windowOffsetY":0,"windowWidth":0,"windowHeight":0,"numVisibilityRects":0,"style":0,"styleEx":0,"show":0,"title":""}"#
    }

    private static let bothBits = ResizeMarginCensus.marginX | ResizeMarginCensus.marginY

    @Test("both bits are required; either bit alone is not a resize-margin order")
    func bothBitsRequired() {
        #expect(ResizeMarginCensus.hasBothBits(Self.bothBits))
        #expect(!ResizeMarginCensus.hasBothBits(ResizeMarginCensus.marginX))
        #expect(!ResizeMarginCensus.hasBothBits(ResizeMarginCensus.marginY))
        #expect(!ResizeMarginCensus.hasBothBits(0x1100_DF1E)) // the corpus's common no-margin flags
        #expect(ResizeMarginCensus.hasBothBits(0x1900_DF9E)) // the corpus's margin-bearing flags
    }

    @Test("a THICKFRAME create carrying the bits is counted against THICKFRAME; a popup create is not")
    func createAttribution() {
        let c = ResizeMarginCensus.of(Self.events([
            Self.create(1, style: ResizeMarginCensus.thickFrame, fieldFlags: Self.bothBits),
            Self.create(2, style: 0x8000_0000, fieldFlags: Self.bothBits, w: 1009, h: 4),
            Self.create(3, style: ResizeMarginCensus.thickFrame, fieldFlags: 0x1100_DF1E),
        ].joined(separator: "\n")))
        #expect(c.creates == 3)
        #expect(c.createsWithBothBits == 2)
        #expect(c.thickFrameCreates == 2)
        #expect(c.thickFrameCreatesWithBothBits == 1)
        #expect(c.createBitShapes == [[ResizeMarginCensus.thickFrame, 10, 10], [0x8000_0000, 1009, 4]])
    }

    @Test("an update carrying the bits is attributed to its window's CREATE-time style, not the update's own style field")
    func updateAttribution() {
        let c = ResizeMarginCensus.of(Self.events([
            Self.create(7, style: ResizeMarginCensus.thickFrame, fieldFlags: 0x1100_DF1E),
            Self.update(7, fieldFlags: Self.bothBits),
            Self.update(7, fieldFlags: 0x0000_0002),
        ].joined(separator: "\n")))
        #expect(c.updates == 2)
        #expect(c.updatesWithBothBits == 1)
        #expect(c.updateBitWindowsCreateStyles == [ResizeMarginCensus.thickFrame])
        #expect(c.thickFrameCreatesWithBothBits == 0)
    }

    // MARK: frozen-baseline pins (skip, not pass, under a SAMPLES_DIR override)

    @Test(
        "frozen corpus: creates 138 / margin-bearing 7 (all WS_POPUP helpers 1009x4 or 0x0); THICKFRAME creates 6, none margin-bearing",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenCreates() throws {
        var total = ResizeMarginCensus()
        for scenario in ReplayTests.Scenario.allCases {
            total += ResizeMarginCensus.of(try ReplayTests.replay(scenario).events)
        }
        #expect(total.creates == 138)
        #expect(total.createsWithBothBits == 7)
        #expect(total.createBitShapes == [[0x8000_0000, 1009, 4], [0x8000_0000, 0, 0]])
        #expect(total.thickFrameCreates == 6)
        #expect(total.thickFrameCreatesWithBothBits == 0)
    }

    @Test(
        "frozen corpus: updates 64 / margin-bearing 6 -- one per scenario, every one on a THICKFRAME window (create style 0x000F0000)",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenUpdates() throws {
        var total = ResizeMarginCensus()
        for scenario in ReplayTests.Scenario.allCases {
            let c = ResizeMarginCensus.of(try ReplayTests.replay(scenario).events)
            #expect(c.updatesWithBothBits == 1, "scenario \(scenario.rawValue)")
            total += c
        }
        #expect(total.updates == 64)
        #expect(total.updatesWithBothBits == 6)
        #expect(total.updateBitWindowsCreateStyles == [0x000F_0000])
    }
}
