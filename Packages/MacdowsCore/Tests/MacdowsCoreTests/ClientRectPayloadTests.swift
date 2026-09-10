import Foundation
import Testing
@testable import MacdowsCore

/// W3 route B step 1 (survey `docs/upgrade-gate/2026-09-10-about-offset-offline-survey.md`
/// §5 (b), §6.2 route B; ADR-0018 §5.1 item 2): rail-probe's WindowCreate / WindowUpdate
/// lines now also carry the two RAIL client-rectangle anchors --
/// `WINDOW_STATE_ORDER.clientOffsetX/Y` (gated by
/// `WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET`, 0x4000) and `windowClientDeltaX/Y` (gated by
/// `WINDOW_ORDER_FIELD_WND_CLIENT_DELTA`, 0x8000). Both are **remote px**, signed, read by
/// `libfreerdp/core/window.c:334-340` and `:395-401` through `Stream_Read_INT32`.
///
/// MEASUREMENT ONLY. Nothing consumes these values: `macContentRect` and the outbound
/// `ClientWindowMove` deduction are byte-for-byte unchanged by this step. The point is that the
/// corpus census (`ClientRectCorpusPinTests`) found both bits on 142 of the 202 window orders while
/// `CLIENT_AREA_SIZE` (0x10000) was never sent at all -- so these two pairs are the only per-window
/// client-rect quantities the server actually puts on the wire, and until a 1x/2x recording says
/// what they hold, no constant may be replaced by them.
///
/// Those two numbers are this lane's own recount over the six U7-frozen recordings, pinned in
/// `ClientRectCorpusPinTests.frozenBitCensus`. The survey's §1 per-recording table is NOT
/// reproducible -- recounting it disagrees in both directions (one recording low, five high), so it
/// is not a "the survey also counted a seventh recording" offset -- and the pin, not the survey
/// table, is the number of record here. The survey's DIRECTION (both bits ride on essentially every
/// geometry order, CLIENT_AREA_SIZE on none) is unaffected.
///
/// Recordings made before this step -- the frozen corpus included -- carry no such keys and decode
/// as 0, per adr/0008 §5's append-only rule. 0 is a legitimate value once the bit is set, so a
/// consumer gates on the flag bit, never on "delta != 0".
@Suite("client-rect payload (route B step 1)")
struct ClientRectPayloadTests {
    static func decode(_ json: String) throws -> RailEventKind {
        try JSONDecoder().decode(RailEvent.self, from: Data(json.utf8)).kind
    }

    /// `fieldFlags` 0x1100DF1E is the corpus's own WindowCreate shape (survey §1) -- it carries
    /// both CLIENT_AREA_OFFSET and WND_CLIENT_DELTA and does NOT carry CLIENT_AREA_SIZE.
    static let base = "\"t_ms\":1,\"tid\":\"main\",\"windowId\":328208,\"fieldFlags\":%FLAGS%,\"windowOffsetX\":46,\"windowOffsetY\":60,"
        + "\"windowWidth\":1044,\"windowHeight\":940,\"numVisibilityRects\":1,\"style\":2148007936,\"styleEx\":256,\"show\":5,\"title\":\"about\""

    @Test("the four client-rect fields decode from a WindowCreate line, and negative deltas stay negative")
    func clientRectDecodes() throws {
        let line = "{\"ev\":\"WindowCreate\"," + Self.base.replacingOccurrences(of: "%FLAGS%", with: "285269790")
            + ",\"resizeMarginLeft\":0,\"resizeMarginTop\":0,\"resizeMarginRight\":0,\"resizeMarginBottom\":0"
            + ",\"clientOffsetX\":53,\"clientOffsetY\":91,\"windowClientDeltaX\":7,\"windowClientDeltaY\":-31}"
        guard case .windowCreate(let p) = try Self.decode(line) else { Issue.record("not a WindowCreate"); return }
        #expect(p.clientOffsetX == 53)
        #expect(p.clientOffsetY == 91)
        #expect(p.windowClientDeltaX == 7)
        // Signed, not UInt32: window.c reads all four through Stream_Read_INT32. A negative
        // windowClientDelta is exactly what a title bar above the window origin produces, so
        // this is the case an accidental unsigned type would break.
        #expect(p.windowClientDeltaY == -31)
        #expect(p.fieldFlags & 0x4000 != 0 && p.fieldFlags & 0x8000 != 0)
        #expect(p.fieldFlags & 0x0001_0000 == 0, "0x1100DF1E carries no CLIENT_AREA_SIZE -- the census's 0-of-202 finding")
    }

    @Test("a line without the keys (every recording before this step) decodes with all four at 0 -- the frozen corpus keeps decoding")
    func absentKeysDecodeAsZero() throws {
        let line = "{\"ev\":\"WindowUpdate\"," + Self.base.replacingOccurrences(of: "%FLAGS%", with: "16777220") + "}"
        guard case .windowUpdate(let p) = try Self.decode(line) else { Issue.record("not a WindowUpdate"); return }
        #expect(p.clientOffsetX == 0 && p.clientOffsetY == 0)
        #expect(p.windowClientDeltaX == 0 && p.windowClientDeltaY == 0)
    }

    @Test("rail-probe emits the four keys on the WindowCreate/WindowUpdate line, after the resize margins, as %d (signed)")
    func emitterCarriesTheKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Tools/rail-probe/rail-probe.c"), encoding: .utf8)
        let collapsed = src.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let clientRect = "\\\"clientOffsetX\\\":%d,\\\"clientOffsetY\\\":%d,\\\"windowClientDeltaX\\\":%d,\\\"windowClientDeltaY\\\":%d\""
        let margins = "\\\"resizeMarginLeft\\\":%u,"
        let clientRectAt = collapsed.range(of: clientRect)?.lowerBound
        let marginsAt = collapsed.range(of: margins)?.lowerBound
        #expect(clientRectAt != nil && marginsAt != nil)
        if let clientRectAt, let marginsAt { #expect(marginsAt < clientRectAt, "adr/0008 §5: new fields append") }
        // Pinned as the argument-list SHAPE, not as a name count: a name count also matches
        // doc comments, and a comment mentioning the field is not a call that passes it.
        #expect(collapsed.contains("windowState->clientOffsetX, windowState->clientOffsetY, windowState->windowClientDeltaX, windowState->windowClientDeltaY"))
    }
}
