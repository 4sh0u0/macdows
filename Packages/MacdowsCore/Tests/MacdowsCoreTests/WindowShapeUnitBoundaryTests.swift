import Testing
@testable import MacdowsCore

/// W3 lane B (ADR-0018 §2 / U-4 direction (i); ADR-0015 §7 (c) item 3): the mask pipeline's unit
/// boundary, made explicit. Every wire-space input to the mask transform -- visibility rects, the
/// RAIL window offset, the visible offset, the geometry correction's origin, the top inset -- is
/// remote px; `ContentSize` is mac pt. The wire-space overload divides each remote-px input by
/// `rasterScale` exactly once, THEN runs the pt-only transform. At rasterScale 1 it is the identity.
///
/// Why the quadrant fixture and not only the full-window one: a full-window wire rect over-covers
/// and step 3's clip trims it back to the content bounds, so it comes out right even through the
/// OLD, unit-mixing path -- it cannot discriminate. A rect whose wire-px left edge is >= the content
/// width in points is clipped away entirely by that old path (a visible quarter of the window
/// vanishes); the correct result is its own quarter of the layer. ADR-0018 §2's lane-B row named the
/// full-window rect as "red today"; this file corrects that: the quadrant is the red one.
@Suite("WindowShape unit boundary (W3 lane B)")
struct WindowShapeUnitBoundaryTests {
    /// 502x353 remote px content at 2x = 251x176.5 mac pt.
    static let contentAtTwoX = WindowShape.ContentSize(width: 251, height: 176.5)

    static func computeAtScale(
        _ rasterScale: Double,
        rects: [WindowShape.WireRect],
        windowOffset: (x: Double, y: Double) = (100, 100),
        visibleOffset: (x: Double, y: Double)? = (100, 100),
        correction: WindowGeometryCorrection = .zero,
        topInset: Double = 0,
        contentSize: WindowShape.ContentSize = contentAtTwoX
    ) -> WindowShape.MaskResult {
        WindowShape.computeMask(
            visibilityRects: rects, wireCount: UInt32(rects.count), truncated: false,
            windowOffset: windowOffset, visibleOffset: visibleOffset,
            correction: correction, topInset: topInset, contentSize: contentSize,
            isMaximized: false, rasterScale: rasterScale
        )
    }

    @Test("2x: the bottom-right quadrant (wire 251,176..502,353) lands in its own quarter of the layer -- the old path clipped it away entirely")
    func quadrantAtTwoXLandsInItsOwnQuarter() {
        let result = Self.computeAtScale(2, rects: [WindowShape.WireRect(left: 251, top: 176, right: 502, bottom: 353)])
        // wire / 2 -> (125.5, 88, 251, 176.5) pt; flip: y = 176.5 - 176.5 = 0, height 88.5.
        #expect(result == .rects([WindowShape.LayerRect(x: 125.5, y: 0, width: 125.5, height: 88.5)]))
    }

    @Test("2x: the full-window wire rect covers the whole content (ADR-0018 lane-B row's own fixture; not discriminating, kept as stated)")
    func fullWindowRectAtTwoXCoversTheWholeContent() {
        let result = Self.computeAtScale(2, rects: [WindowShape.WireRect(left: 0, top: 0, right: 502, bottom: 353)])
        #expect(result == .rects([WindowShape.LayerRect(x: 0, y: 0, width: 251, height: 176.5)]))
    }

    @Test("2x: the offsets and the correction origin are wire space too -- dividing only the rects would misplace an occluded window's mask")
    func offsetsAndCorrectionAreWireSpace() {
        // visibleOffset - windowOffset - correction.origin = (10, 20) - (2, 4) = (8, 16) remote px.
        let result = Self.computeAtScale(
            2, rects: [WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30)],
            windowOffset: (100, 100), visibleOffset: (110, 120),
            correction: WindowGeometryCorrection(originX: 2, originY: 4, width: 0, height: 0)
        )
        // local wire (8, 16, 58, 46) -> pt (4, 8, 29, 23); flip: y = 176.5 - 23 = 153.5, height 15.
        #expect(result == .rects([WindowShape.LayerRect(x: 4, y: 153.5, width: 25, height: 15)]))
    }

    @Test("2x: topInset is wire space (remote px) -- 20 remote px shifts the local frame by 10 pt")
    func topInsetIsWireSpace() {
        let result = Self.computeAtScale(
            2, rects: [WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30)], topInset: 20
        )
        // dy = -20 remote px -> local (0, -20, 50, 10) -> pt (0, -10, 25, 5); flip: y = 176.5 - 5 = 171.5,
        // height 15 -> spans 171.5...186.5, clipped to the 176.5 top: (0, 171.5, 25, 5).
        #expect(result == .rects([WindowShape.LayerRect(x: 0, y: 171.5, width: 25, height: 5)]))
    }

    @Test("1x: the wire-space overload is the identity -- same result as the pt-only transform on the same inputs")
    func identityAtOneX() {
        let rects = [WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30), WindowShape.WireRect(left: 60, top: 10, right: 100, bottom: 60)]
        let content = WindowShape.ContentSize(width: 100, height: 60)
        let viaOverload = Self.computeAtScale(1, rects: rects, windowOffset: (0, 0), visibleOffset: (0, 0), contentSize: content)
        let viaPointsOnly = WindowShape.computeMask(
            visibilityRects: rects, wireCount: 2, truncated: false,
            windowOffset: (0, 0), visibleOffset: (0, 0), correction: .zero, topInset: 0,
            contentSize: content, isMaximized: false
        )
        #expect(viaOverload == viaPointsOnly)
        #expect(viaOverload == .rects([
            WindowShape.LayerRect(x: 0, y: 30, width: 50, height: 30),
            WindowShape.LayerRect(x: 60, y: 0, width: 40, height: 50),
        ]))
    }

    @Test("a non-positive or non-finite rasterScale fails open to no mask (adr/0010 §3's spirit: an unknown unit is 'shape unknown')")
    func badRasterScaleFailsOpen() {
        let rects = [WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30)]
        #expect(Self.computeAtScale(0, rects: rects) == .none)
        #expect(Self.computeAtScale(-2, rects: rects) == .none)
        #expect(Self.computeAtScale(.nan, rects: rects) == .none)
        #expect(Self.computeAtScale(.infinity, rects: rects) == .none)
    }
}
