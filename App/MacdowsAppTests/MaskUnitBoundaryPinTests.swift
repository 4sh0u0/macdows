import Foundation
import Testing

// W3 lane B (ADR-0018 §2 / U-4 direction (i)): the unit boundary of the mask pipeline is crossed
// inside MacdowsCore (`WindowShape.computeMask(..., rasterScale:)`, pinned behaviourally in
// MacdowsCore's WindowShapeUnitBoundaryTests) -- but only if the registry, the one caller, hands
// it the frozen topology's rasterScale. "Revert the registry-side conversion to the identity"
// (drop the argument, pass 1, or re-grow a local pt-bounds-only path) must be red here. Source
// pins, same technique as the A2 / lane G / lane E pins (whitespace-collapsed substrings).
private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("mask unit boundary plumbing (W3 lane B)")
struct MaskUnitBoundaryPinTests {
    @Test("the registry's one computeMask call passes the frozen topology's rasterScale")
    func registryPassesRasterScale() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindowRegistry.swift")
        // The CALL, not doc-comment mentions of the function (maskContentSize's comment names it).
        #expect(occurrences(of: "return WindowShape.computeMask( visibilityRects: state.visibilityRects", in: src) == 1)
        #expect(src.contains("isMaximized: state.isMaximized, // remote px per mac pt"))
        #expect(src.contains("rasterScale: topology.rasterScale )"))
    }

    @Test("the M1 record-only path is gone: no one-shot warning flag, bounds retyped in points only")
    func recordOnlyPathIsGone() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindowRegistry.swift")
        #expect(!src.contains("warnedMaskUnitScaleGap"))
        #expect(!src.contains("recorded, not corrected"))
        #expect(src.contains("private static func maskContentSize(fromContentRectInPoints contentSize: NSSize) -> WindowShape.ContentSize"))
    }

    @Test("RemoteWindow still applies LayerRects as points through the identity conversion (both ends move together)")
    func remoteWindowKeepsTheIdentityConversion() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindow.swift")
        #expect(src.contains("layerPoints"))
        #expect(!src.contains("rasterScale"))
    }
}
