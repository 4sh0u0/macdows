import AppKit
import IOSurface
import Testing

// O-A (ADR-0018 §5.1 增补 2026-09-10 14:27「①两项都开」): the About-offset survey's decisive
// offline check, as a *measurement-only* diagnostic -- `RemoteWindow.edgeBorderProfile`, read
// straight out of the displayed IOSurface's mapped sub-rect (the same sub-rect `present`'s
// `contentsRect` crop selects), never from a screenshot.
//
// WHAT IT HAS TO DISCRIMINATE, and therefore what these fixtures are shaped like. The survey's
// 1x per-pixel measurement (`docs/upgrade-gate/2026-09-10-about-offset-offline-survey.md` §4)
// found the server's bitmap flush against the mapped rect on all four sides: column 0 / column
// W-1 / row 0 / row H-1 all read as a dark frame (channel mean 67) against the dialog's own
// light background (235-240), and all four rounded corners present. The competing explanation
// left standing there is hypothesis (f) -- at 2x the server DECLARES a mapped rect smaller than
// the window bitmap it actually drew, so the client faithfully crops the right column and bottom
// row away. Offline that is exactly the difference between fixture `fullFrame...` (all four edges
// present) and `rightColumnAndBottomRowMissing...` (top/left present, right/bottom collapsed),
// so both are pinned here with exact numbers rather than a "looks about right" band.
//
// WHAT THE FOUR RATIOS ALONE CANNOT SAY (gate O-A r1 I-1). They read row 0 / row H-1 / column 0
// / column W-1 and nothing else, so the survey's own empty-band model -- a frame INSET by 5-7 px
// (§4's reductio) -- and "that edge carries no frame at all" both report a ratio near zero.
// `firstDark*` scans inward from each edge for the first row/column that is a frame by the
// survey's 0.9 baseline, and `leftBandInsetFiveColumns...` below is the fixture that shows the
// two models producing identical ratios and different `firstDark*`.
//
// THREE MUTATIONS THESE FIXTURES EXIST TO KILL:
//  * dropping the mapped-sub-rect clamp and profiling the whole 64-aligned allocation
//    => `allocationPaddingOutsideTheMappedSubRectIsNeverRead` (padding is dark, content is not:
//    an unclamped reading reports 1.0 on every edge instead of 0.0).
//  * reusing `nonWhitePixelRatio`'s "not close to solid white" test (b/g/r > 240) as the darkness
//    test => `theDialogsOwnBackgroundIsNotDark` (the About background measures 235-240, i.e. it
//    IS "non-white"; a negated-240 predicate calls the whole dialog dark and every ratio 1.0,
//    which would make this diagnostic structurally unable to report anything).
//  * the corner blocks silently reading the same pixels four times, or the right/bottom blocks
//    being anchored at the origin => `rightColumnAndBottomRowMissingCollapsesThoseTwoEdges`
//    (its four corner counts are 11 / 6 / 6 / 0 -- all different).
//
// No image is written anywhere by any of this, and nothing here needs Screen Recording.

/// BGRA, 4 bytes per element -- the byte order adr/0005 §2 established empirically and the one
/// `nonWhitePixelRatio` already reads. Fixtures are grey (b == g == r), so channel order cannot
/// silently matter to a fixture's own expectation; the profile reads all three regardless.
private func makeSurface(allocWidth: Int, allocHeight: Int) -> IOSurface {
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: allocWidth,
        .height: allocHeight,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241 as UInt32   // 'BGRA'
    ]
    guard let surface = IOSurface(properties: properties) else {
        fatalError("IOSurface allocation failed for \(allocWidth)x\(allocHeight)")
    }
    return surface
}

/// A surface with a DIFFERENT element width -- the one shape the profile refuses outright,
/// because its `x * 4` arithmetic would then read pixels that are not there. Returns `nil` if the
/// allocator refuses the request, which the case treats as "cannot test this here" rather than as
/// a failure of the code under test.
private func makeSurface(allocWidth: Int, allocHeight: Int, bytesPerElement: Int) -> IOSurface? {
    IOSurface(properties: [
        .width: allocWidth,
        .height: allocHeight,
        .bytesPerElement: bytesPerElement
    ])
}

/// Writes `value` into B, G and R (A is left at 0xFF) over the given pixel rect, honouring the
/// surface's own `bytesPerRow` -- IOSurface pads rows, and a fixture that assumed width*4 would
/// paint diagonal garbage rather than the frame it claims to paint.
private func fill(_ surface: IOSurface, x: Int, y: Int, width: Int, height: Int, value: UInt8) {
    IOSurfaceLock(surface, IOSurfaceLockOptions(rawValue: 0), nil)
    defer { IOSurfaceUnlock(surface, IOSurfaceLockOptions(rawValue: 0), nil) }
    let base = IOSurfaceGetBaseAddress(surface)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    for row in y..<(y + height) {
        for column in x..<(x + width) {
            let pixel = base.advanced(by: row * bytesPerRow + column * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = value
            pixel[1] = value
            pixel[2] = value
            pixel[3] = 0xFF
        }
    }
}

/// A 1 px frame on the selected edges of the `width` x `height` sub-rect anchored at the
/// surface's top-left -- the same anchor `present`'s crop uses.
private func drawFrame(
    _ surface: IOSurface, width: Int, height: Int, value: UInt8,
    top: Bool = true, bottom: Bool = true, left: Bool = true, right: Bool = true
) {
    if top { fill(surface, x: 0, y: 0, width: width, height: 1, value: value) }
    if bottom { fill(surface, x: 0, y: height - 1, width: width, height: 1, value: value) }
    if left { fill(surface, x: 0, y: 0, width: 1, height: height, value: value) }
    if right { fill(surface, x: width - 1, y: 0, width: 1, height: height, value: value) }
}

/// The single outermost pixel of each corner painted back to the background -- the cheapest
/// stand-in for the anti-aliased rounded corners the survey measured (§4: left-top col1..6 =
/// 12,6,4,2,2,2), enough to prove the edge ratios stay above the survey's 0.9 baseline and the
/// corner counts stay non-zero.
private func roundCorners(_ surface: IOSurface, width: Int, height: Int, background: UInt8) {
    fill(surface, x: 0, y: 0, width: 1, height: 1, value: background)
    fill(surface, x: width - 1, y: 0, width: 1, height: 1, value: background)
    fill(surface, x: 0, y: height - 1, width: 1, height: 1, value: background)
    fill(surface, x: width - 1, y: height - 1, width: 1, height: 1, value: background)
}

/// The survey's own measured greys, so a fixture cannot drift away from the thing it models.
private enum SurveyGrey {
    /// §4: the About dialog's border columns/rows, channel mean 67.
    static let border: UInt8 = 67
    /// §4: the dialog's own light background, 235-240 -- deliberately BELOW `nonWhitePixelRatio`'s
    /// 240 "close to solid white" cut, which is what makes it a mutation detector here.
    static let dialogBackground: UInt8 = 235
    /// Whatever the allocator left in the 64-aligned padding; modelled as solid black.
    static let padding: UInt8 = 0
}

@MainActor
@Suite("edge/corner border profile of the displayed IOSurface (O-A, measurement only)")
struct EdgeBorderProfileTests {
    // About at 1x: mapped 522x514 inside a 576x576 (64-aligned) allocation -- the survey's own
    // numbers (§4, §5 (d)).
    private static let mappedWidth = 522
    private static let mappedHeight = 514
    private static let allocSide = 576

    @Test("a full 1 px frame reads 1.0 on all four edges and 11 dark pixels in each 6x6 corner")
    func fullFrameIsAllFourEdgesAndFourCorners() throws {
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        drawFrame(surface, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.border)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        ))
        #expect(profile.mappedWidth == Self.mappedWidth)
        #expect(profile.mappedHeight == Self.mappedHeight)
        #expect(profile.allocWidth == Self.allocSide)
        #expect(profile.allocHeight == Self.allocSide)
        #expect(profile.topDarkRatio == 1.0)
        #expect(profile.bottomDarkRatio == 1.0)
        #expect(profile.leftDarkRatio == 1.0)
        #expect(profile.rightDarkRatio == 1.0)
        // 6 (the block's own edge row) + 5 (its edge column, minus the shared pixel).
        #expect(profile.topLeftDarkCount == 11)
        #expect(profile.topRightDarkCount == 11)
        #expect(profile.bottomLeftDarkCount == 11)
        #expect(profile.bottomRightDarkCount == 11)
        // A flush frame is offset 0 on every edge -- `firstDark* == 0` and "that edge's ratio is
        // at or above the 0.9 baseline" are the same statement, and this fixture is where the two
        // are checked against each other.
        #expect(profile.firstDarkRowFromTop == 0)
        #expect(profile.firstDarkRowFromBottom == 0)
        #expect(profile.firstDarkColumnFromLeft == 0)
        #expect(profile.firstDarkColumnFromRight == 0)
    }

    @Test("rounded corners keep every edge above the survey's 0.9 baseline and every corner non-zero")
    func roundedCornersStayAboveTheSurveyBaseline() throws {
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        drawFrame(surface, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.border)
        roundCorners(surface, width: Self.mappedWidth, height: Self.mappedHeight, background: SurveyGrey.dialogBackground)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        ))
        // Two pixels lost per horizontal edge (one per corner), two per vertical edge.
        #expect(profile.topDarkRatio == Double(Self.mappedWidth - 2) / Double(Self.mappedWidth))
        #expect(profile.bottomDarkRatio == Double(Self.mappedWidth - 2) / Double(Self.mappedWidth))
        #expect(profile.leftDarkRatio == Double(Self.mappedHeight - 2) / Double(Self.mappedHeight))
        #expect(profile.rightDarkRatio == Double(Self.mappedHeight - 2) / Double(Self.mappedHeight))
        // The survey's own 1x baseline, stated in the shape the live judgement will use.
        #expect(profile.topDarkRatio > 0.9 && profile.bottomDarkRatio > 0.9)
        #expect(profile.leftDarkRatio > 0.9 && profile.rightDarkRatio > 0.9)
        #expect(profile.topLeftDarkCount == 10)
        #expect(profile.topRightDarkCount == 10)
        #expect(profile.bottomLeftDarkCount == 10)
        #expect(profile.bottomRightDarkCount == 10)
        // Two pixels short of a full span is still a frame at the 0.9 baseline, so the rounding
        // does not push any edge's first dark row/column inward.
        #expect(profile.firstDarkRowFromTop == 0 && profile.firstDarkRowFromBottom == 0)
        #expect(profile.firstDarkColumnFromLeft == 0 && profile.firstDarkColumnFromRight == 0)
    }

    @Test("hypothesis (f): a bitmap missing its right column and bottom row collapses exactly those two edges")
    func rightColumnAndBottomRowMissingCollapsesThoseTwoEdges() throws {
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        drawFrame(
            surface, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.border,
            top: true, bottom: false, left: true, right: false
        )

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        ))
        #expect(profile.topDarkRatio == 1.0)
        #expect(profile.leftDarkRatio == 1.0)
        // Not literally 0: the top frame's own last pixel is in the right column, and the left
        // frame's own last pixel is in the bottom row. Stated exactly rather than as "< 0.01", so
        // an off-by-one in either edge's span shows up here.
        #expect(profile.rightDarkRatio == 1.0 / Double(Self.mappedHeight))
        #expect(profile.bottomDarkRatio == 1.0 / Double(Self.mappedWidth))
        #expect(profile.topLeftDarkCount == 11)
        #expect(profile.topRightDarkCount == 6)     // its top row only
        #expect(profile.bottomLeftDarkCount == 6)   // its left column only
        #expect(profile.bottomRightDarkCount == 0)
        // The discriminating shape, restated inward: the two surviving edges are flush, and the
        // two cropped ones have NO frame anywhere within the scanned depth -- which is what
        // separates hypothesis (f) from a frame that merely moved inward.
        #expect(profile.firstDarkRowFromTop == 0 && profile.firstDarkColumnFromLeft == 0)
        #expect(profile.firstDarkRowFromBottom == nil && profile.firstDarkColumnFromRight == nil)
    }

    @Test("the 64-aligned padding outside the mapped sub-rect is never read")
    func allocationPaddingOutsideTheMappedSubRectIsNeverRead() throws {
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        // Everything dark, then the mapped sub-rect painted solid white with NO frame at all:
        // a profile that reads the allocation instead of the mapped rect reports 1.0 everywhere.
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: 255)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        ))
        #expect(profile.topDarkRatio == 0.0)
        #expect(profile.bottomDarkRatio == 0.0)
        #expect(profile.leftDarkRatio == 0.0)
        #expect(profile.rightDarkRatio == 0.0)
        #expect(profile.topLeftDarkCount == 0)
        #expect(profile.topRightDarkCount == 0)
        #expect(profile.bottomLeftDarkCount == 0)
        #expect(profile.bottomRightDarkCount == 0)
        // The inward scan is clamped to the sub-rect too: a scan that walked into the dark
        // padding would report a frame a few rows in on a surface that has none at all.
        #expect(profile.firstDarkRowFromTop == nil && profile.firstDarkRowFromBottom == nil)
        #expect(profile.firstDarkColumnFromLeft == nil && profile.firstDarkColumnFromRight == nil)
    }

    @Test("the dialog's own 235-grey background is not dark (dark is not the negation of 'close to white')")
    func theDialogsOwnBackgroundIsNotDark() throws {
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        // Uniform 235 everywhere -- below `nonWhitePixelRatio`'s 240 white cut, so reusing that
        // function's predicate negated would report a full dark frame on a dialog with no frame.
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.dialogBackground)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        ))
        #expect(profile.topDarkRatio == 0.0)
        #expect(profile.bottomDarkRatio == 0.0)
        #expect(profile.leftDarkRatio == 0.0)
        #expect(profile.rightDarkRatio == 0.0)
        #expect(profile.topLeftDarkCount == 0)
        #expect(profile.bottomRightDarkCount == 0)
        #expect(profile.firstDarkRowFromTop == nil && profile.firstDarkColumnFromLeft == nil)
        // ... and the survey's border grey IS dark, at the same threshold.
        #expect(RemoteWindow.isDarkChannelTriple(
            blue: SurveyGrey.border, green: SurveyGrey.border, red: SurveyGrey.border
        ))
        #expect(!RemoteWindow.isDarkChannelTriple(
            blue: SurveyGrey.dialogBackground, green: SurveyGrey.dialogBackground, red: SurveyGrey.dialogBackground
        ))
    }

    @Test("an unknown, zero or oversized mapped size falls back to the whole allocation")
    func mappedSizeFallbacksMatchNonWhitePixelRatio() throws {
        let side = 64
        func fixture() -> IOSurface {
            let surface = makeSurface(allocWidth: side, allocHeight: side)
            fill(surface, x: 0, y: 0, width: side, height: side, value: 255)
            drawFrame(surface, width: side, height: side, value: SurveyGrey.border)
            return surface
        }
        for mapped in [nil, CGSize(width: 0, height: 0), CGSize(width: 999, height: 999)] as [CGSize?] {
            let profile = try #require(RemoteWindow.edgeBorderProfile(ofSurface: fixture(), mappedSize: mapped))
            #expect(profile.mappedWidth == side)
            #expect(profile.mappedHeight == side)
            #expect(profile.allocWidth == side)
            #expect(profile.topDarkRatio == 1.0)
            #expect(profile.rightDarkRatio == 1.0)
            #expect(profile.bottomRightDarkCount == 11)
            #expect(profile.firstDarkRowFromTop == 0 && profile.firstDarkColumnFromRight == 0)
        }
    }

    @Test("a sub-rect smaller than the 6x6 corner block is clamped, not read out of bounds")
    func tinyMappedSubRectClampsTheCornerBlock() throws {
        let surface = makeSurface(allocWidth: 64, allocHeight: 64)
        fill(surface, x: 0, y: 0, width: 64, height: 64, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: 4, height: 3, value: 255)
        drawFrame(surface, width: 4, height: 3, value: SurveyGrey.border)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: 4, height: 3)
        ))
        #expect(profile.mappedWidth == 4 && profile.mappedHeight == 3)
        #expect(profile.topDarkRatio == 1.0 && profile.bottomDarkRatio == 1.0)
        #expect(profile.leftDarkRatio == 1.0 && profile.rightDarkRatio == 1.0)
        // Corner side clamps to min(6, 4, 3) == 3. A 4x3 frame has exactly two non-frame pixels,
        // (1,1) and (2,1), and every clamped 3x3 block contains both -- so all four read 9-2 = 7.
        // This is also the OVERLAP case the profile's own doc comment states as a reading rule
        // (gate O-A r1 m-11): below 12 px on an axis the corner blocks stop being independent, and
        // four equal counts are an artefact of the clamp rather than a symmetric frame. The
        // fixture keeps that visible instead of leaving it to be rediscovered on a live run.
        #expect(profile.topLeftDarkCount == 7)
        #expect(profile.topRightDarkCount == 7)
        #expect(profile.bottomLeftDarkCount == 7)
        #expect(profile.bottomRightDarkCount == 7)
        // The inward scan is clamped the same way (depth min(8, 3) rows / min(8, 4) columns) and
        // does not read outside the sub-rect; every edge of a 4x3 full frame is flush.
        #expect(profile.firstDarkRowFromTop == 0 && profile.firstDarkRowFromBottom == 0)
        #expect(profile.firstDarkColumnFromLeft == 0 && profile.firstDarkColumnFromRight == 0)
    }

    @Test("an inset frame and a missing frame give the SAME left ratio and different firstDark")
    func leftBandInsetFiveColumnsIsDistinguishedOnlyByTheFirstDarkColumn() throws {
        // The empty-band model, drawn: the whole frame shifted five columns right, so columns 0..4
        // are the dialog's own background and the frame's left edge is column 5. This is the
        // shape the survey's §4 reductio predicts if `mapped` names a rect that includes an
        // invisible band (5-7 px at 1x).
        let inset = 5
        let banded = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(banded, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(banded, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        fill(banded, x: inset, y: 0, width: Self.mappedWidth - inset, height: 1, value: SurveyGrey.border)
        fill(banded, x: inset, y: Self.mappedHeight - 1, width: Self.mappedWidth - inset, height: 1, value: SurveyGrey.border)
        fill(banded, x: inset, y: 0, width: 1, height: Self.mappedHeight, value: SurveyGrey.border)
        fill(banded, x: Self.mappedWidth - 1, y: 0, width: 1, height: Self.mappedHeight, value: SurveyGrey.border)

        // The competing shape: a dialog with NO left frame at all, everything else identical.
        let noLeftFrame = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(noLeftFrame, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(noLeftFrame, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        drawFrame(
            noLeftFrame, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.border,
            top: true, bottom: true, left: false, right: true
        )

        let mapped = CGSize(width: Self.mappedWidth, height: Self.mappedHeight)
        let bandedProfile = try #require(RemoteWindow.edgeBorderProfile(ofSurface: banded, mappedSize: mapped))
        let bareProfile = try #require(RemoteWindow.edgeBorderProfile(ofSurface: noLeftFrame, mappedSize: mapped))

        // THE POINT: column 0 reads the same in both -- exactly 0.0 in the banded one (its column
        // 0 is pure background) and 2/H in the bare one (the top and bottom frames' own pixels).
        // Both are far below the 0.9 baseline, so the four ratios alone cannot separate the two
        // models at all.
        #expect(bandedProfile.leftDarkRatio == 0.0)
        #expect(bareProfile.leftDarkRatio == 2.0 / Double(Self.mappedHeight))
        #expect(bandedProfile.leftDarkRatio < 0.9 && bareProfile.leftDarkRatio < 0.9)
        // ... and firstDark does separate them, by naming where the frame actually is.
        #expect(bandedProfile.firstDarkColumnFromLeft == inset)
        #expect(bareProfile.firstDarkColumnFromLeft == nil)
        // The band shifts the horizontal edges' spans but not their verdict (517/522 > 0.9), so
        // top/bottom stay flush and the right edge stays whole -- i.e. the band is readable as a
        // LEFT-edge fact rather than as a general collapse.
        #expect(bandedProfile.topDarkRatio == Double(Self.mappedWidth - inset) / Double(Self.mappedWidth))
        #expect(bandedProfile.firstDarkRowFromTop == 0 && bandedProfile.firstDarkRowFromBottom == 0)
        #expect(bandedProfile.rightDarkRatio == 1.0 && bandedProfile.firstDarkColumnFromRight == 0)
        // A band deeper than the scan is honestly reported as "none within the depth" rather than
        // guessed at: 8 is the stated depth, so an inset of 8 is already out of range.
        let deep = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(deep, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(deep, x: 0, y: 0, width: Self.mappedWidth, height: Self.mappedHeight, value: SurveyGrey.dialogBackground)
        fill(deep, x: RemoteWindow.firstDarkScanDepth, y: 0, width: 1, height: Self.mappedHeight, value: SurveyGrey.border)
        let deepProfile = try #require(RemoteWindow.edgeBorderProfile(ofSurface: deep, mappedSize: mapped))
        #expect(deepProfile.firstDarkColumnFromLeft == nil)
    }

    @Test("an odd-sized sub-rect anchors the right and bottom corner blocks on the last pixel")
    func oddSizedSubRectKeepsTheFourCornerBlocksDisjoint() throws {
        // 521x513 -- odd on BOTH axes, and comfortably above the 12 px where the corner blocks
        // would start to overlap, so this is the case where the four counts are four independent
        // readings. The About dialog's real sizes are even (522x514 / 1044x940); an odd one is
        // what a helper window or a future theme gives, and an off-by-one in either right/bottom
        // anchor shows up here as a wrong count rather than as a crash.
        let width = 521
        let height = 513
        let surface = makeSurface(allocWidth: Self.allocSide, allocHeight: Self.allocSide)
        fill(surface, x: 0, y: 0, width: Self.allocSide, height: Self.allocSide, value: SurveyGrey.padding)
        fill(surface, x: 0, y: 0, width: width, height: height, value: SurveyGrey.dialogBackground)
        drawFrame(surface, width: width, height: height, value: SurveyGrey.border)
        // ONE corner pixel painted back to background, so the four counts are not all equal: a
        // right/bottom block anchored at the origin would report 10 in the wrong slot.
        fill(surface, x: width - 1, y: 0, width: 1, height: 1, value: SurveyGrey.dialogBackground)

        let profile = try #require(RemoteWindow.edgeBorderProfile(
            ofSurface: surface, mappedSize: CGSize(width: width, height: height)
        ))
        #expect(profile.mappedWidth == width && profile.mappedHeight == height)
        #expect(profile.topDarkRatio == Double(width - 1) / Double(width))
        #expect(profile.rightDarkRatio == Double(height - 1) / Double(height))
        #expect(profile.bottomDarkRatio == 1.0 && profile.leftDarkRatio == 1.0)
        #expect(profile.topLeftDarkCount == 11)
        #expect(profile.topRightDarkCount == 10)
        #expect(profile.bottomLeftDarkCount == 11)
        #expect(profile.bottomRightDarkCount == 11)
        #expect(profile.firstDarkRowFromTop == 0 && profile.firstDarkRowFromBottom == 0)
        #expect(profile.firstDarkColumnFromLeft == 0 && profile.firstDarkColumnFromRight == 0)
    }

    @Test("a surface whose elements are not 4 bytes wide is refused, not misread")
    func aNon32BitSurfaceIsRefusedRatherThanReadWithTheWrongStride() throws {
        // gate O-A r1 m-2. The read below is `x * 4` by construction; on a 2-bytes-per-element
        // surface that arithmetic silently addresses every other pixel and the ratios it returns
        // would look exactly like measurements. `nil` is the only honest answer, and the harness
        // prints it as `unavailable=surface-not-readable` rather than as "nothing displayed".
        let surface = try #require(
            makeSurface(allocWidth: 64, allocHeight: 64, bytesPerElement: 2),
            "the allocator refused a 2-bytes-per-element surface"
        )
        #expect(RemoteWindow.edgeBorderProfile(ofSurface: surface, mappedSize: nil) == nil)
        // ... while the 4-byte sibling of the same size is profiled normally, so the refusal is
        // the stride and not the size.
        let fourByte = try #require(makeSurface(allocWidth: 64, allocHeight: 64, bytesPerElement: 4))
        fill(fourByte, x: 0, y: 0, width: 64, height: 64, value: 255)
        #expect(RemoteWindow.edgeBorderProfile(ofSurface: fourByte, mappedSize: nil) != nil)
    }
}

// MARK: - source pins: this lane changed no geometry

private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("O-A is measurement-only: no geometry moved")
struct EdgeBorderProfileScopePinTests {
    @Test("present()'s mapped-sub-rect crop is untouched, both branches")
    func theCropIsUntouched() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindow.swift")
        #expect(occurrences(of: "contentLayer.contentsRect =", in: src) == 2)
        #expect(src.contains("contentLayer.contentsRect = CGRect(x: 0, y: 1 - h, width: w, height: h)"))
        #expect(src.contains("contentLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)"))
        #expect(src.contains("let w = min(1, mapped.width / allocW)"))
        #expect(src.contains("let h = min(1, mapped.height / allocH)"))
    }

    @Test("the diagnostic is read-only: no writer touches the surface, no image is ever written")
    func theDiagnosticOnlyReads() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindow.swift")
        // kIOSurfaceLockReadOnly (1) is the only lock option this file ever takes.
        #expect(occurrences(of: "IOSurfaceLock(", in: src) == occurrences(of: "IOSurfaceLock(surface, IOSurfaceLockOptions(rawValue: 1", in: src))
        #expect(!src.contains("CGImageDestination"))
        #expect(!src.contains("writeToFile"))
    }

    @Test("the read refuses rather than guesses: the lock's verdict and the element stride")
    func theReadIsGuarded() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindow.swift")
        // gate O-A r1 m-1: a refused lock leaves the base pointer aimed at stale memory, and this
        // diagnostic reads thousands of pixels of it. There is no offline way to make a real lock
        // fail, so the guard is pinned as a call shape instead of exercised.
        #expect(src.contains("guard IOSurfaceLock(surface, IOSurfaceLockOptions(rawValue: 1 /* kIOSurfaceLockReadOnly */), nil) == kIOReturnSuccess else { return nil }"))
        // gate O-A r1 m-2, whose fixture is above; pinned here too so that a later refactor that
        // keeps the fixture passing by widening the guard is still visible as a source change.
        #expect(occurrences(of: "guard IOSurfaceGetBytesPerElement(surface) == 4 else { return nil }", in: src) == 1)
    }

    @Test("the harness reaches the diagnostic through exactly one registry forwarder")
    func oneRegistryForwarder() throws {
        let registry = try source("App/RemoteWindowRendering/RemoteWindowRegistry.swift")
        #expect(occurrences(of: "func edgeBorderProfile(windowId: UInt32)", in: registry) == 1)
        #expect(occurrences(of: "windows[windowId]?.edgeBorderProfile()", in: registry) == 1)
    }
}
