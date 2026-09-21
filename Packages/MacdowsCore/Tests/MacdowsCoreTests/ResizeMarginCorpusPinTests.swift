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
// What the census showed on the retired 1x corpus (2026-09-08): WindowCreate 138 orders, 7 with
// both margin bits, all WS_POPUP helpers (style 0x80000000, 1009x4 / 0x0), 6 THICKFRAME creates
// none of them margin-bearing; WindowUpdate 64 orders, 6 with both bits, one per scenario, all on
// the same THICKFRAME window (id 328256, create style 0x000F0000).
//
// RECOMPUTED on the 2026-09-21 2x corpus (U-7 rebaseline) -- the numbers below are measured, and
// two of the 1x conclusions do NOT survive the re-record; they are restated here rather than
// quietly dropped:
//   * WindowCreate: 125 orders, 14 with both margin bits, and they are no longer one shape class:
//     eight distinct (style, w, h) shapes appear, including the About dialog (0x80080000,
//     1072x928), the Registry Editor window (0x000F0000, 966x688) and the tray-flyout class
//     (0x800B0000 / 0x800F0000).
//   * THICKFRAME creates: 5, and 2 of them DO carry both bits -- the 1x "none margin-bearing"
//     finding is a property of that session, not of the protocol. The margins now reach a
//     resizable window on the CREATE as well as on updates.
//   * WindowUpdate: 65 orders, 4 with both bits, and NOT one per scenario (s1/s4/s5a/s5b have one
//     each, s2/s3 none), on two distinct create-time styles (0x000F0000 and 0x800F0000).
// The probe now DOES log the four `resizeMargin*` values (ADR-0018 U-5 step 1), so the 2x samples
// carry them; this census still counts BITS only, deliberately -- the value side belongs to
// `ResizeMarginPayloadTests` and to whatever consumer ADR-0018 U-5 step 3 rules in.
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
        "frozen corpus: creates 125 / margin-bearing 14 across eight shape classes; THICKFRAME creates 5, two of them margin-bearing",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenCreates() throws {
        var total = ResizeMarginCensus()
        for scenario in ReplayTests.Scenario.allCases {
            total += ResizeMarginCensus.of(try ReplayTests.replay(scenario).events)
        }
        #expect(total.creates == 125)
        #expect(total.createsWithBothBits == 14)
        #expect(total.createBitShapes == [
            [0x000F_0000, 966, 688],
            [0x8000_0000, 0, 0],
            [0x8000_0000, 1280, 720],
            [0x8000_0000, 2530, 4],
            [0x8000_0000, 2560, 1440],
            [0x8008_0000, 1072, 928],
            [0x800B_0000, 262, 71],
            [0x800F_0000, 240, 60],
        ])
        #expect(total.thickFrameCreates == 5)
        // NOT zero any more (it was on the 1x corpus): a resizable window's CREATE does carry
        // the margins in this session. Pinned as the measured value, not widened away.
        #expect(total.thickFrameCreatesWithBothBits == 2)
    }

    /// Margin-bearing updates per scenario. The 1x corpus had exactly one in every scenario,
    /// which the pin asserted as a uniform literal; the 2x corpus does not (s2/s3 have none),
    /// so the same "exact per-scenario count" semantics is restated as a table instead of
    /// being widened to a range.
    static let expectedMarginUpdatesWithBothBits: [ReplayTests.Scenario: Int] = [
        .s1: 1, .s2: 0, .s3: 0, .s4: 1, .s5a: 1, .s5b: 1,
    ]

    @Test(
        "frozen corpus: updates 65 / margin-bearing 4 -- per-scenario table, on create styles 0x000F0000 and 0x800F0000",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func frozenUpdates() throws {
        var total = ResizeMarginCensus()
        for scenario in ReplayTests.Scenario.allCases {
            let c = ResizeMarginCensus.of(try ReplayTests.replay(scenario).events)
            let expected = try #require(Self.expectedMarginUpdatesWithBothBits[scenario])
            #expect(c.updatesWithBothBits == expected, "scenario \(scenario.rawValue)")
            total += c
        }
        #expect(total.updates == 65)
        #expect(total.updatesWithBothBits == 4)
        #expect(total.updateBitWindowsCreateStyles == [0x000F_0000, 0x800F_0000])
    }
}
