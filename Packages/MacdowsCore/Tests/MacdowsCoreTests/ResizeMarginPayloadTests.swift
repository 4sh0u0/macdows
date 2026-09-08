import Foundation
import Testing
@testable import MacdowsCore

/// W3 / ADR-0018 U-5 step 1 (ADR-0015 §7 (d)): rail-probe's WindowCreate / WindowUpdate lines now
/// carry the four RAIL resize margins (`WINDOW_STATE_ORDER.resizeMarginLeft/Top/Right/Bottom`,
/// remote px; Left/Right are meaningful when `fieldFlags` has RESIZE_MARGIN_X 0x80, Top/Bottom when
/// it has RESIZE_MARGIN_Y 0x08000000 -- two independent bits, as window.c reads them),
/// so a 2x recording can answer whether the THICKFRAME margins scale with DPI (the census in
/// ResizeMarginCorpusPinTests only counts the flag bits -- the VALUES were never recorded). Old
/// recordings, the frozen corpus included, lack the keys and decode as 0 -- a value, not an
/// absence, so consumers must gate on the flag bits, never on "margin != 0".
@Suite("resize-margin payload (U-5 step 1)")
struct ResizeMarginPayloadTests {
    static func decode(_ json: String) throws -> RailEventKind {
        try JSONDecoder().decode(RailEvent.self, from: Data(json.utf8)).kind
    }

    static let base = "\"t_ms\":1,\"tid\":\"main\",\"windowId\":328256,\"fieldFlags\":%FLAGS%,\"windowOffsetX\":10,\"windowOffsetY\":20,"
        + "\"windowWidth\":1194,\"windowHeight\":727,\"numVisibilityRects\":1,\"style\":983040,\"styleEx\":256,\"show\":5,\"title\":\"winver\""

    @Test("the four margins decode from a WindowCreate line in rail-probe's key order")
    func marginsDecode() throws {
        let line = "{\"ev\":\"WindowCreate\"," + Self.base.replacingOccurrences(of: "%FLAGS%", with: "134217856")
            + ",\"resizeMarginLeft\":8,\"resizeMarginTop\":31,\"resizeMarginRight\":8,\"resizeMarginBottom\":8}"
        guard case .windowCreate(let p) = try Self.decode(line) else { Issue.record("not a WindowCreate"); return }
        #expect(p.resizeMarginLeft == 8)
        #expect(p.resizeMarginTop == 31)
        #expect(p.resizeMarginRight == 8)
        #expect(p.resizeMarginBottom == 8)
        #expect(p.fieldFlags & 0x80 != 0 && p.fieldFlags & 0x0800_0000 != 0)
    }

    @Test("a line without the keys (every recording before this step) decodes with margins 0 -- the frozen corpus keeps decoding")
    func absentKeysDecodeAsZero() throws {
        let line = "{\"ev\":\"WindowUpdate\"," + Self.base.replacingOccurrences(of: "%FLAGS%", with: "128") + "}"
        guard case .windowUpdate(let p) = try Self.decode(line) else { Issue.record("not a WindowUpdate"); return }
        #expect(p.resizeMarginLeft == 0 && p.resizeMarginTop == 0 && p.resizeMarginRight == 0 && p.resizeMarginBottom == 0)
    }

    @Test("rail-probe emits the four keys on the WindowCreate/WindowUpdate line, after title, in Left/Top/Right/Bottom order (the census's key order)")
    func emitterCarriesTheKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Tools/rail-probe/rail-probe.c"), encoding: .utf8)
        let collapsed = src.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let margins = "\\\"resizeMarginLeft\\\":%u,\\\"resizeMarginTop\\\":%u,\\\"resizeMarginRight\\\":%u,\\\"resizeMarginBottom\\\":%u\""
        let title = "\\\"title\\\":\\\"%s\\\",\""
        let marginsAt = collapsed.range(of: margins)?.lowerBound
        let titleAt = collapsed.range(of: title)?.lowerBound
        #expect(marginsAt != nil && titleAt != nil)
        if let marginsAt, let titleAt { #expect(titleAt < marginsAt) }
        #expect(collapsed.contains("windowState->resizeMarginLeft, windowState->resizeMarginTop, windowState->resizeMarginRight, windowState->resizeMarginBottom"))
    }
}
