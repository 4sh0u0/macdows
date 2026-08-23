import Testing
@testable import MacdowsCore

/// Phase 2 W4 (docs/plans/phase2.md §2/§4 W4, adr/0010 §2/§3): exhaustive coverage of
/// `WindowShape.computeMask(...)`'s three-step transform and five fail-open rules, entirely
/// offline — no AppKit, matching `WindowMappabilityTests`'/`ZOrderSyncTests`'/
/// `StyleTranslatorTests`' own no-AppKit precedent for this package's pure-logic surface.
@Suite("WindowShape")
struct WindowShapeTests {
    // MARK: - Shared fixtures

    /// A single wire rect spanning a window's own reported top-left 50x30 sub-region,
    /// window-relative (visibleOffset-anchored) as MS-RDPERP defines it.
    static let sampleRect = WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30)

    static func computeUnoccluded(
        rects: [WindowShape.WireRect] = [sampleRect],
        wireCount: UInt32 = 1,
        truncated: Bool = false,
        contentSize: WindowShape.ContentSize = .init(width: 100, height: 60),
        isMaximized: Bool = false
    ) -> WindowShape.MaskResult {
        WindowShape.computeMask(
            visibilityRects: rects, wireCount: wireCount, truncated: truncated,
            windowOffset: (x: 0, y: 0), visibleOffset: (x: 0, y: 0),
            correction: .zero, topInset: 0, contentSize: contentSize, isMaximized: isMaximized
        )
    }

    // MARK: - adr/0010 §3 rule 1: truncated → whole window (no mask)

    @Test("truncated wire count degrades to no mask, even with valid rects and a known anchor")
    func rule1TruncatedDegradesToNoMask() {
        let result = Self.computeUnoccluded(truncated: true)
        #expect(result == .none)
    }

    // MARK: - adr/0010 §3 rule 2: VIS_OFFSET never seen → whole window (no mask)

    @Test("a nil visibleOffset (VIS_OFFSET never observed) degrades to no mask -- never assumed equal to windowOffset")
    func rule2UnknownAnchorDegradesToNoMask() {
        let result = WindowShape.computeMask(
            visibilityRects: [Self.sampleRect], wireCount: 1, truncated: false,
            windowOffset: (x: 10, y: 10), visibleOffset: nil,
            correction: .zero, topInset: 0, contentSize: .init(width: 100, height: 60),
            isMaximized: false
        )
        #expect(result == .none)
    }

    // MARK: - adr/0010 §3 rule 3: numVisibilityRects == 0 → no mask, not invisible

    @Test("wireCount == 0 means no mask, regardless of whatever (stale) rects array is passed")
    func rule3ZeroWireCountMeansNoMaskNotInvisible() {
        // A non-empty rects array with wireCount == 0 is a contradiction that shouldn't
        // occur in practice (the transport layer only ever populates the array when the
        // wire count is nonzero), but this function must still fail open on wireCount
        // alone, not on whether the array happens to be empty.
        let result = Self.computeUnoccluded(wireCount: 0)
        #expect(result == .none)
    }

    @Test("wireCount == 0 with a genuinely empty rects array also means no mask")
    func rule3ZeroWireCountEmptyArray() {
        let result = Self.computeUnoccluded(rects: [], wireCount: 0)
        #expect(result == .none)
    }

    // MARK: - adr/0010 §3 rule 4: maximized → clear mask

    @Test("a maximized window clears the mask even with valid rects and a known anchor")
    func rule4MaximizedClearsMask() {
        let result = Self.computeUnoccluded(isMaximized: true)
        #expect(result == .none)
    }

    // MARK: - Rule priority: rules 1/3/4 all take priority over a would-be-valid transform

    @Test("truncated takes priority even when the window is ALSO maximized")
    func rulesAreIndependentShortCircuits() {
        let result = Self.computeUnoccluded(truncated: true, isMaximized: true)
        #expect(result == .none)
    }

    // MARK: - adr/0010 §2 step 1/2/3: the transform itself, unoccluded (visibleOffset == windowOffset)

    @Test("an unoccluded top-left sub-rect maps to the corresponding top region in layer space")
    func unoccludedTopRectMapsToLayerTop() {
        // Content 100x60; wire rect spans the window's own top 30px (windows-space,
        // y-down): local == the wire rect verbatim, since Δ == (0, 0) when
        // visibleOffset == windowOffset and correction/topInset are both zero.
        let result = Self.computeUnoccluded()
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects.count == 1)
        // Layer space (origin bottom-left): the window's own top 30px of a 60-tall content
        // area is layer y ∈ [30, 60], NOT y ∈ [0, 30] -- the y-flip must land here, not be
        // silently skipped or inverted the wrong way.
        #expect(rects[0] == WindowShape.LayerRect(x: 0, y: 30, width: 50, height: 30))
    }

    @Test("a full-window rect maps to the full content bounds in layer space (degenerate, symmetry-blind sanity check)")
    func fullWindowRectMapsToFullBounds() {
        let result = Self.computeUnoccluded(
            rects: [WindowShape.WireRect(left: 0, top: 0, right: 100, bottom: 60)]
        )
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects == [WindowShape.LayerRect(x: 0, y: 0, width: 100, height: 60)])
    }

    @Test("a bottom-edge sub-rect maps to the layer-space bottom, confirming the flip direction with an asymmetric case")
    func bottomRectMapsToLayerBottom() {
        // Windows-space bottom 10px of a 60-tall window: top=50, bottom=60.
        let result = Self.computeUnoccluded(
            rects: [WindowShape.WireRect(left: 0, top: 50, right: 100, bottom: 60)]
        )
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects == [WindowShape.LayerRect(x: 0, y: 0, width: 100, height: 10)])
    }

    // MARK: - The occluded-window case (visibleOffset != windowOffset) -- adr/0010 §0(b)/§2

    @Test("an occluded window (visibleOffset != windowOffset) re-anchors wire rects correctly, not naively at windowOffset")
    func occludedWindowReanchorsCorrectly() {
        // windowOffset (100, 100): the window's own RAIL-reported origin.
        // visibleOffset (150, 120): the visible-region bounding box is shifted 50 right,
        // 20 down from the window's own origin -- e.g. another window occludes this one's
        // top-left corner. Content size 100x60 (this window's own mapped-canonical size).
        // Wire rect (0,0,50,30): within the visible region's OWN local frame.
        let result = WindowShape.computeMask(
            visibilityRects: [WindowShape.WireRect(left: 0, top: 0, right: 50, bottom: 30)],
            wireCount: 1, truncated: false,
            windowOffset: (x: 100, y: 100), visibleOffset: (x: 150, y: 120),
            correction: .zero, topInset: 0, contentSize: .init(width: 100, height: 60),
            isMaximized: false
        )
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects.count == 1)
        // Worked by hand (see WindowShape.swift's own doc comment / this test's PR
        // description for the derivation): Δx = 150-100-0 = 50, Δy = 120-100-0-0 = 20.
        // local = (50, 20, 100, 50) in windows space (y-down). Layer y-origin =
        // height - local.bottom = 60 - 50 = 10; layer height = local.bottom - local.top =
        // 30. Layer x-origin = local.left = 50; layer width = local.right - local.left = 50.
        #expect(rects[0] == WindowShape.LayerRect(x: 50, y: 10, width: 50, height: 30))
    }

    @Test("an unoccluded window (visibleOffset == windowOffset) is the degenerate zero-delta case of the same transform")
    func unoccludedIsZeroDeltaSpecialCase() {
        let occludedZeroDelta = WindowShape.computeMask(
            visibilityRects: [Self.sampleRect], wireCount: 1, truncated: false,
            windowOffset: (x: 42, y: 17), visibleOffset: (x: 42, y: 17),
            correction: .zero, topInset: 0, contentSize: .init(width: 100, height: 60),
            isMaximized: false
        )
        // Same result as the (0, 0)/(0, 0) baseline -- only the DELTA between windowOffset
        // and visibleOffset matters, not either's absolute value.
        #expect(occludedZeroDelta == Self.computeUnoccluded())
    }

    // MARK: - adr/0010 §2 step 3: clipping never enlarges

    @Test("a rect straddling the content bounds is clipped to the bounds, not enlarged")
    func clippingNeverEnlarges() {
        // Wire rect extends 20px past the right/bottom edges of a 100x60 content area.
        let result = Self.computeUnoccluded(
            rects: [WindowShape.WireRect(left: 80, top: 40, right: 120, bottom: 80)],
            contentSize: .init(width: 100, height: 60)
        )
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects.count == 1)
        // Windows-space local = (80, 40, 100(clip target still 120 pre-clip), 60(pre-clip
        // 80)) -- the transform itself doesn't clip x/width, only the final intersection
        // step does. Layer y-origin = 60 - 80 = -20 pre-clip, height = 80-40=40 pre-clip ->
        // layer rect (80, -20, 40, 40) pre-clip, clipped to bounds (0,0,100,60) -> (80, 0,
        // 20, 20).
        #expect(rects[0] == WindowShape.LayerRect(x: 80, y: 0, width: 20, height: 20))
    }

    @Test("a rect entirely outside the content bounds is dropped, not returned as an empty/negative rect")
    func rectFullyOutsideBoundsIsDropped() {
        let result = Self.computeUnoccluded(
            rects: [WindowShape.WireRect(left: 200, top: 200, right: 250, bottom: 250)],
            contentSize: .init(width: 100, height: 60)
        )
        #expect(result == .rects([]))
    }

    @Test("multiple rects: only the ones that survive clipping are returned, in input order")
    func multipleRectsPartialSurvival() {
        let inBounds = WindowShape.WireRect(left: 0, top: 0, right: 10, bottom: 10)
        let outOfBounds = WindowShape.WireRect(left: 500, top: 500, right: 510, bottom: 510)
        let alsoInBounds = WindowShape.WireRect(left: 90, top: 50, right: 100, bottom: 60)
        let result = Self.computeUnoccluded(
            rects: [inBounds, outOfBounds, alsoInBounds],
            wireCount: 3,
            contentSize: .init(width: 100, height: 60)
        )
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects.count == 2)
        #expect(rects[0] == WindowShape.LayerRect(x: 0, y: 50, width: 10, height: 10))
        #expect(rects[1] == WindowShape.LayerRect(x: 90, y: 0, width: 10, height: 10))
    }

    // MARK: - Scan-band decomposition (a rounded/irregular window's realistic shape)

    @Test("a rounded-corner-style scan-band decomposition (several stacked bands) all survive as separate rects")
    func scanBandDecomposition() {
        // A crude approximation of a rounded top edge: three progressively wider bands
        // stacked top to bottom, each its own wire rect (never merged) -- exactly the
        // "scan-band decomposition" adr/0008 §2b cites as the real shape of a typical
        // rounded/irregular window region.
        let bands = [
            WindowShape.WireRect(left: 20, top: 0, right: 80, bottom: 5),
            WindowShape.WireRect(left: 5, top: 5, right: 95, bottom: 10),
            WindowShape.WireRect(left: 0, top: 10, right: 100, bottom: 60),
        ]
        let result = Self.computeUnoccluded(rects: bands, wireCount: 3)
        guard case .rects(let rects) = result else {
            Issue.record("expected .rects, got \(result)")
            return
        }
        #expect(rects.count == 3)
        #expect(rects[0] == WindowShape.LayerRect(x: 20, y: 55, width: 60, height: 5))
        #expect(rects[1] == WindowShape.LayerRect(x: 5, y: 50, width: 90, height: 5))
        #expect(rects[2] == WindowShape.LayerRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: - topInset / correction.originX/Y: pure additive terms (adr/0010 §2/§6)

    /// An interior rect (20pt margin on every side of a 100x60 content area) — deliberately
    /// NOT `sampleRect`/`fullWindowRect` above, both of which touch a content edge: a small
    /// topInset/correction shift on an edge-touching rect immediately interacts with step
    /// 3's clipping (verified the hard way — see git history of this test), which would
    /// conflate "the additive term shifted the rect" with "the additive term also clipped
    /// it," muddying exactly the property these two tests exist to isolate.
    static let interiorRect = WindowShape.WireRect(left: 20, top: 20, right: 70, bottom: 40)

    @Test("a nonzero topInset shifts every rect up by exactly that amount, purely additively")
    func topInsetIsPureAdditiveTerm() {
        let baseline = Self.computeUnoccluded(rects: [Self.interiorRect])
        let withInset = WindowShape.computeMask(
            visibilityRects: [Self.interiorRect], wireCount: 1, truncated: false,
            windowOffset: (x: 0, y: 0), visibleOffset: (x: 0, y: 0),
            correction: .zero, topInset: 5, contentSize: .init(width: 100, height: 60),
            isMaximized: false
        )
        guard case .rects(let base) = baseline, case .rects(let inset) = withInset else {
            Issue.record("expected .rects for both")
            return
        }
        // topInset subtracts from Δy (adr/0010 §2 step 1), which shifts local.top/bottom
        // DOWN by 5 in windows space -- equivalently, layer y shifts UP by 5 (content
        // effectively starts 5pt lower, so a fixed windows-space rect lands 5pt higher in
        // the already-flipped layer space).
        #expect(inset[0] == WindowShape.LayerRect(x: base[0].x, y: base[0].y + 5, width: base[0].width, height: base[0].height))
    }

    @Test("a nonzero correction.originX/Y shifts every rect by exactly that amount, purely additively")
    func correctionOriginIsPureAdditiveTerm() {
        let baseline = Self.computeUnoccluded(rects: [Self.interiorRect])
        let corrected = WindowShape.computeMask(
            visibilityRects: [Self.interiorRect], wireCount: 1, truncated: false,
            windowOffset: (x: 0, y: 0), visibleOffset: (x: 0, y: 0),
            correction: WindowGeometryCorrection(originX: 3, originY: 4, width: 0, height: 0),
            topInset: 0, contentSize: .init(width: 100, height: 60), isMaximized: false
        )
        guard case .rects(let base) = baseline, case .rects(let corr) = corrected else {
            Issue.record("expected .rects for both")
            return
        }
        // Δx subtracts correction.originX, Δy subtracts correction.originY -- both shift
        // local left/up in windows space, i.e. layer x decreases by originX and layer y
        // increases by originY (mirroring topInset's own sign, since both subtract from Δy).
        #expect(corr[0] == WindowShape.LayerRect(x: base[0].x - 3, y: base[0].y + 4, width: base[0].width, height: base[0].height))
    }

    // MARK: - Zero/degenerate content size (defensive -- should not occur in practice)

    @Test("a zero content size fails open to no mask rather than dividing by / clipping against nothing")
    func zeroContentSizeFailsOpen() {
        let result = Self.computeUnoccluded(contentSize: .init(width: 0, height: 0))
        #expect(result == .none)
    }
}
