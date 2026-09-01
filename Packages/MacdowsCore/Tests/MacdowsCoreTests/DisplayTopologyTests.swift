import Testing
@testable import MacdowsCore

/// One row of the union / desktop-size table test.
///
/// Rows **F1-F4 are transcribed from ADR-0015 §3.5 cell for cell** -- that table is binding on
/// this lane ("四个 fixture 期望值照 §3.5 抄，一格不改", ADR §9's L2 row), so a disagreement
/// here is a defect in this file, never a local improvement. Rows prefixed `S` are lane
/// supplements that add coverage the ADR table does not need but deliverable ⑥ does; they
/// change no ADR cell.
///
/// `docs/matrix/scenarios.md` (M1 deliverable ⑥, L10) transcribes these rows one-to-one.
struct UnionFixture: Sendable, CustomStringConvertible {
    let name: String
    let displays: [DisplayTopology.Display]
    /// ADR §3 rule 2's `unionBoundsPt`: Windows-space axes, measured in mac POINTS, origin may
    /// be negative. `(x, y, width, height)`.
    let expectedUnionInPoints: (x: Double, y: Double, width: Double, height: Double)
    let expectedRasterScale: Double
    let expectedIsUniformScale: Bool
    /// ADR §3 rule 3's `desktopSizePx` -- the only value that may reach
    /// `CRSession.desktopWidth/Height`.
    let expectedDesktopSize: (width: Int, height: Int)

    var description: String { name }
}

struct InvalidTopologyFixture: Sendable, CustomStringConvertible {
    let name: String
    let displays: [DisplayTopology.Display]
    var description: String { name }
}

/// File-scope so `@Test(arguments:)` can name them unambiguously, and so the scenario table
/// L10 transcribes has one obvious address to point at.
enum DisplayTopologyFixtures {
    static func display(
        x: Double, y: Double, width: Double, height: Double,
        scale: DisplayScale = .unscaled, isPrimary: Bool = false
    ) -> DisplayTopology.Display {
        DisplayTopology.Display(
            origin: MacPoint(x: x, y: y),
            size: MacSize(width: width, height: height),
            scale: scale,
            isPrimary: isPrimary
        )
    }

    /// The union / desktop-size table. Every expected value is derived by ADR §3's three rules,
    /// worked out in the comment above each row:
    ///   1. each display into Windows-space axes, in points: `x = frame.minX`,
    ///      `y = primaryHeightPt − frame.maxY`;
    ///   2. `unionBoundsPt` = bounding box of those (a rect, origin may be negative);
    ///   3. `desktopSizePx` = `(max(0, maxX), max(0, maxY)) × rasterScale`, rounded up, clamped.
    static let union: [UnionFixture] = [
        // ADR F1 -- the actual hardware today (`plans/phase3.md:219`: one 2560x1440 panel at
        // native 1x). Proves M1's change is the IDENTITY on the only configuration that exists,
        // i.e. real-host regression risk from this lane is zero.
        //   primary -> (0, 1440−1440 = 0, 2560, 1440)
        //   desktop -> (2560, 1440) × 1
        UnionFixture(
            name: "ADR F1 — single display, 1x (today's real hardware)",
            displays: [display(x: 0, y: 0, width: 2560, height: 1440, isPrimary: true)],
            expectedUnionInPoints: (0, 0, 2560, 1440),
            expectedRasterScale: 1,
            expectedIsUniformScale: true,
            expectedDesktopSize: (2560, 1440)
        ),
        // ADR F2 -- the same panel switched to "looks like 1280x720", a zero-downsample exact 2x
        // (`plans/phase3.md:219`②). Note the desktop size is IDENTICAL to F1: the same physical
        // raster, requested in remote pixels. Under ADR §3's rejected answer T this cell would
        // read 1280x720 -- i.e. the invisible wall back at the middle of the screen (§3 理由 2).
        //   primary -> (0, 720−720 = 0, 1280, 720);  desktop -> (1280, 720) × 2
        UnionFixture(
            name: "ADR F2 — single display, 2x (same panel, 1280x720 points)",
            displays: [display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true)],
            expectedUnionInPoints: (0, 0, 1280, 720),
            expectedRasterScale: 2,
            expectedIsUniformScale: true,
            expectedDesktopSize: (2560, 1440)
        ),
        // ADR F3 -- mixed scale, secondary to the RIGHT with its TOP edge aligned to the
        // primary's top (mac y increases upward, so the secondary spans mac y ∈ [−360, 720]).
        //   primary   -> (0,    720−720  = 0,    1280, 720)
        //   secondary -> (1280, 720−720  = 0,    1920, 1080)      [frame.maxY = −360+1080 = 720]
        //   union     -> x ∈ [0, 3200], y ∈ [0, 1080]  =>  (0, 0, 3200, 1080)
        //   desktop   -> (3200, 1080) × rasterScale 2 = 6400 x 2160
        // The price of mixed scale is visible right here: the 1x secondary is requested at 2x,
        // so its half of the raster is upsampled on display. `isUniformScale == false` is the
        // signal ADR §2 rule 4 requires the App-side provider to record once, at construction.
        // OFFLINE-FIXTURE-ONLY (§8.1: one monitor exists).
        //
        // C-2 HOOK, transcribed from ADR §3.5's own note on this row: 6400 is "本表唯一一个依赖
        // 未核实前提的数字" -- it exceeds the usual RDP desktop-width range, and the real
        // protocol bound is unverified (ADR §3's closing未实测 item). If C-2 shows the bound is
        // below 6400, THIS CELL AND `DesktopSizeInRemotePixels.maxExtentInRemotePixels` change
        // together and the other rows are unaffected. Written down here, on the row, so it
        // surfaces as a known pending premise rather than as "a fixture mysteriously went red".
        UnionFixture(
            name: "ADR F3 — dual display, mixed scale (2x primary + 1x secondary right)",
            displays: [
                display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
                display(x: 1280, y: -360, width: 1920, height: 1080, scale: .unscaled),
            ],
            expectedUnionInPoints: (0, 0, 3200, 1080),
            expectedRasterScale: 2,
            expectedIsUniformScale: false,
            expectedDesktopSize: (6400, 2160)
        ),
        // ADR F4 -- the whole secondary lies LEFT OF and ABOVE the primary, i.e. entirely in
        // Windows-negative territory.
        //   primary   -> (0,     720−720  = 0,     1280, 720)
        //   secondary -> (−1920, 720−1800 = −1080, 1920, 1080)    [frame.maxY = 720+1080 = 1800]
        //   union     -> x ∈ [−1920, 1280], y ∈ [−1080, 720]  =>  (−1920, −1080, 3200, 1800)
        //   desktop   -> (max(0,1280), max(0,720)) × 2 = 2560 x 1440
        // The expected desktop size is EXACTLY F2's -- identical to having no second display at
        // all. That is ADR §3 rule 4 asserted as a number rather than left in a comment: the
        // negative extension is unrepresentable to a server that synthesises one monitor pinned
        // at (0,0) (`settings.c:1798-1813`), and clipping it is a recorded W4 gap, whereas
        // translating the origin to zero would trade a visible clamp for an invisible offset.
        // OFFLINE-FIXTURE-ONLY.
        UnionFixture(
            name: "ADR F4 — secondary left of AND above the primary (clipped negative extension)",
            displays: [
                display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
                display(x: -1920, y: 720, width: 1920, height: 1080, scale: .fullyScaled2x),
            ],
            expectedUnionInPoints: (-1920, -1080, 3200, 1800),
            expectedRasterScale: 2,
            expectedIsUniformScale: true,
            expectedDesktopSize: (2560, 1440)
        ),
        // S1 (lane supplement, changes no ADR cell) -- two identical 1x displays side by side,
        // bottom edges aligned. Deliverable ⑥ asks for a "dual same-DPI" scenario and the ADR
        // table has none; this gives L10 a fixture to transcribe instead of inventing one.
        //   primary   -> (0,    1080−1080 = 0, 1920, 1080)
        //   secondary -> (1920, 1080−1080 = 0, 1920, 1080)
        //   union (0, 0, 3840, 1080);  desktop (3840, 1080) × 1
        // OFFLINE-FIXTURE-ONLY.
        UnionFixture(
            name: "S1 — dual display, same scale (1x), secondary to the right",
            displays: [
                display(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
                display(x: 1920, y: 0, width: 1920, height: 1080),
            ],
            expectedUnionInPoints: (0, 0, 3840, 1080),
            expectedRasterScale: 1,
            expectedIsUniformScale: true,
            expectedDesktopSize: (3840, 1080)
        ),
    ]

    /// The mixed-scale layout whose two displays' BOTTOM edges are physically coincident in mac
    /// space (both at mac y = 0). Used by the coincident-edges regression test; kept separate
    /// from the ADR table because it is a regression fixture, not a scenario.
    static let coincidentBottomEdgesMixedScale: [DisplayTopology.Display] = [
        display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
        display(x: 1280, y: 0, width: 1920, height: 1080, scale: .unscaled),
    ]

    /// `init(displays:)` returns `nil` -- it does not trap and it does not repair. Each row
    /// below is a state that would otherwise produce a silently wrong coordinate: a missing
    /// primary has no anchor, two primaries have an ambiguous one, a primary away from the mac
    /// origin breaks the shared-origin-corner premise the whole contract rests on (ADR §3
    /// rule 1, §4), and a zero or negative scale is a division by zero or a mirror image
    /// waiting to happen.
    static let invalid: [InvalidTopologyFixture] = [
        InvalidTopologyFixture(name: "no displays at all (headless / every display asleep)", displays: []),
        InvalidTopologyFixture(name: "no primary", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080),
        ]),
        InvalidTopologyFixture(name: "two primaries", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            display(x: 1920, y: 0, width: 1920, height: 1080, isPrimary: true),
        ]),
        // r1 review I-4: accepted before the fix, and then every derived value was silently
        // offset -- `frameInRemotePixels(ofDisplayAt: 0)` returned (100, −50, 1920, 1080)
        // instead of (0, 0, 1920, 1080), i.e. the Windows origin stopped being the primary's
        // top-left corner while every other check stayed green.
        InvalidTopologyFixture(name: "primary not at the mac origin (Windows origin would stop being its top-left corner)", displays: [
            display(x: 100, y: 50, width: 1920, height: 1080, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "primary off-origin by a single point", displays: [
            display(x: 0, y: 1, width: 1920, height: 1080, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "zero-height display", displays: [
            display(x: 0, y: 0, width: 1920, height: 0, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "zero-width display", displays: [
            display(x: 0, y: 0, width: 0, height: 1080, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "negative size", displays: [
            display(x: 0, y: 0, width: -1920, height: -1080, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "zero remote-pixels-per-point (would divide by zero)", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080,
                    scale: DisplayScale(remotePixelsPerPoint: 0, backingPixelsPerPoint: 1),
                    isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "negative remote-pixels-per-point (would mirror every coordinate)", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080,
                    scale: DisplayScale(remotePixelsPerPoint: -1, backingPixelsPerPoint: 1),
                    isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "zero backing scale", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080,
                    scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 0),
                    isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "non-finite size", displays: [
            display(x: 0, y: 0, width: .infinity, height: 1080, isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "NaN origin", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            display(x: .nan, y: 0, width: 1920, height: 1080),
        ]),
        InvalidTopologyFixture(name: "NaN scale", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080,
                    scale: DisplayScale(remotePixelsPerPoint: .nan, backingPixelsPerPoint: 1),
                    isPrimary: true),
        ]),
        InvalidTopologyFixture(name: "one valid display and one unusable one", displays: [
            display(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            display(x: 1920, y: 0, width: 1920, height: 0),
        ]),
    ]
}

/// Phase 3 M1 / W1: the `DisplayTopology` value's own coverage, against ADR-0015.
///
/// SCOPE NOTE, stated once and true of every non-1x and every multi-display case below:
/// `docs/plans/phase3.md:219` records the owner's measurement that exactly one display exists
/// and it currently runs at 1x. Every fixture here that is not "single display, scale 1" is an
/// OFFLINE FIXTURE -- a statement about what the arithmetic must do if such a layout existed,
/// never a claim that one was observed. That distinction is what M1's deliverable ⑥ asks the
/// scenario table to carry through into documentation, so it is worth carrying in the tests
/// the table is transcribed from.
@Suite("DisplayTopology")
struct DisplayTopologyTests {

    // MARK: - The ADR §3.5 table (M1 acceptance: "topology fixture -> expected desktop size")

    @Test("union bounds, rasterScale, uniformity and desktop size match ADR-0015 §3.5 exactly",
          arguments: DisplayTopologyFixtures.union)
    func adrUnionTable(_ fixture: UnionFixture) throws {
        let topology = try #require(DisplayTopology(displays: fixture.displays))

        let bounds = topology.unionBoundsInPoints
        #expect(bounds.x.inPoints == fixture.expectedUnionInPoints.x)
        #expect(bounds.y.inPoints == fixture.expectedUnionInPoints.y)
        #expect(bounds.width.inPoints == fixture.expectedUnionInPoints.width)
        #expect(bounds.height.inPoints == fixture.expectedUnionInPoints.height)

        #expect(topology.rasterScale == fixture.expectedRasterScale)
        #expect(topology.isUniformScale == fixture.expectedIsUniformScale)

        // Exact, not approximate. ADR §9's offline-acceptance item 4 requires `==` rather than a
        // tolerance, and the fixture table uses only powers-of-two scales so that the claim is
        // actually true in IEEE-754 rather than merely asserted.
        #expect(topology.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(
            width: fixture.expectedDesktopSize.width,
            height: fixture.expectedDesktopSize.height
        ))
    }

    /// ADR §3 rule 3's `max(0, …)` is the difference between "we clip the negative extension and
    /// record it as a W4 gap" and "we quietly ask for a raster four times too large". Asserting
    /// F4 == F2 in one place makes the rule's whole point a single comparison.
    @Test("a display entirely left of and above the primary changes the desktop size not at all")
    func negativeExtensionIsClippedNotAbsorbed() throws {
        let withSecondary = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[3].displays))
        let primaryOnly = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[1].displays))

        #expect(withSecondary.desktopSizeInRemotePixels == primaryOnly.desktopSizeInRemotePixels)

        // ...and the clipped extension is still *visible* in the union bounds, which is what
        // makes it a recorded gap rather than a silent loss (ADR §3 rules 2 and 4). The
        // full-bounding-box answer a naive implementation would send is pinned here as the
        // negative example: 3200 x 1800 points -> 6400 x 3600 remote pixels.
        let bounds = withSecondary.unionBoundsInPoints
        #expect(bounds.x.inPoints == -1920)
        #expect(bounds.y.inPoints == -1080)
        #expect(bounds.width.inPoints * withSecondary.rasterScale == 6400)
        #expect(bounds.height.inPoints * withSecondary.rasterScale == 3600)
        #expect(withSecondary.desktopSizeInRemotePixels.width != 6400)
        #expect(withSecondary.desktopSizeInRemotePixels.height != 3600)
    }

    /// ADR §3 rule 3 rounds **up**, and says why: extra pixels are reversible (the server renders
    /// a column we never show), missing pixels are not (that column falls outside the desktop and
    /// the server clamps windows back inside -- the invisible wall in miniature). At the powers-
    /// of-two scales the fixtures use, rounding never triggers; a fractional point size is the
    /// only way to exercise the direction today.
    @Test("the desktop size rounds up, never down")
    func desktopSizeRoundsUp() throws {
        let topology = try #require(DisplayTopology.single(widthInPoints: 1000.5, heightInPoints: 700.25))
        #expect(topology.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 1001, height: 701))

        let scaled = try #require(DisplayTopology.single(
            widthInPoints: 1000.5, heightInPoints: 700.25, scale: .fullyScaled2x
        ))
        // 1000.5 × 2 = 2001 exactly; 700.25 × 2 = 1400.5 -> 1401.
        #expect(scaled.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 2001, height: 1401))
    }

    /// ADR §3 rule 3's clamp. Not cheap insurance: the ADR traces the overflow path to
    /// `WINPR_ASSERTING_INT_CAST` and shows that in this repo's own build configuration an
    /// out-of-range desktop size **aborts the process**, while a build with the verbose-assert
    /// option off truncates modulo 65536 instead.
    @Test("the desktop size is clamped to the UINT16 wire ceiling rather than overflowing it")
    func desktopSizeIsClamped() throws {
        let huge = try #require(DisplayTopology.single(
            widthInPoints: 40000, heightInPoints: 35000, scale: .fullyScaled2x
        ))
        #expect(huge.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(
            width: DesktopSizeInRemotePixels.maxExtentInRemotePixels,
            height: DesktopSizeInRemotePixels.maxExtentInRemotePixels
        ))
        #expect(DesktopSizeInRemotePixels.maxExtentInRemotePixels == 65535)

        // Clamping is per axis, not all-or-nothing: 40000 pt × 2 = 80000 overflows while
        // 30000 pt × 2 = 60000 does not, and the in-range axis must pass through untouched.
        let oneAxisOnly = try #require(DisplayTopology.single(
            widthInPoints: 40000, heightInPoints: 30000, scale: .fullyScaled2x
        ))
        #expect(oneAxisOnly.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(
            width: DesktopSizeInRemotePixels.maxExtentInRemotePixels, height: 60000
        ))

        // Just under the ceiling must NOT be clamped -- otherwise the test above would pass for
        // an implementation that clamps everything.
        let justUnder = try #require(DisplayTopology.single(widthInPoints: 65535, heightInPoints: 1080))
        #expect(justUnder.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 65535, height: 1080))
    }

    /// ADR §5.A.6 forbids ever sending `0 x 0` (FreeRDP falls back to a 1024x768 desktop, which
    /// is the original invisible-wall fault, `CRSession.h:285-286`). Here that is structural
    /// rather than a rule to remember: the initializer rejects the empty display list, and the
    /// primary is guaranteed to sit at the origin with a positive size, so both extents are
    /// bounded below by the primary's own.
    @Test("the desktop size can never be zero in either dimension",
          arguments: DisplayTopologyFixtures.union)
    func desktopSizeIsNeverZero(_ fixture: UnionFixture) throws {
        let topology = try #require(DisplayTopology(displays: fixture.displays))
        let size = topology.desktopSizeInRemotePixels

        #expect(size.width > 0)
        #expect(size.height > 0)
        // Bounded below by the primary alone, which is what makes it structural.
        #expect(Double(size.width) >= topology.primary.size.width * topology.rasterScale)
        #expect(Double(size.height) >= topology.primary.size.height * topology.rasterScale)
    }

    /// Drift guard between the two derivations. `unionBoundsInPoints` computes ADR rule 1's flip
    /// inline (it must, to stay in point units), while `frameInRemotePixels(ofDisplayAt:)` goes
    /// through `WindowGeometry`. If those ever disagree, this package has grown the second
    /// coordinate-arithmetic implementation the whole design exists to prevent.
    @Test("the union derivation agrees with WindowGeometry's own flip, scaled by rasterScale",
          arguments: DisplayTopologyFixtures.union)
    func unionBoundsAgreesWithWindowGeometryAtRasterScale(_ fixture: UnionFixture) throws {
        let topology = try #require(DisplayTopology(displays: fixture.displays))
        let scale = topology.rasterScale

        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for index in topology.displays.indices {
            let frame = try #require(topology.frameInRemotePixels(ofDisplayAt: index))
            minX = Swift.min(minX, frame.x)
            minY = Swift.min(minY, frame.y)
            maxX = Swift.max(maxX, frame.x + frame.width)
            maxY = Swift.max(maxY, frame.y + frame.height)
        }

        let bounds = topology.unionBoundsInPoints
        #expect(minX == bounds.x.inPoints * scale)
        #expect(minY == bounds.y.inPoints * scale)
        #expect(maxX - minX == bounds.width.inPoints * scale)
        #expect(maxY - minY == bounds.height.inPoints * scale)
    }

    @Test("a single-display topology's union is that display, and its desktop size is scaled once")
    func singleDisplayUnionIsTheDisplay() throws {
        let topology = try #require(DisplayTopology.single(widthInPoints: 2560, heightInPoints: 1440))

        let bounds = topology.unionBoundsInPoints
        #expect(bounds.x.inPoints == 0)
        #expect(bounds.y.inPoints == 0)
        #expect(bounds.width.inPoints == 2560)
        #expect(bounds.height.inPoints == 1440)
        #expect(topology.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 2560, height: 1440))
        #expect(topology.primary.isPrimary)
        #expect(topology.isUniformScale)
    }

    // MARK: - rasterScale and uniformity (ADR §2 rules 2 and 4)

    /// r1 review I-2's regression case, made executable -- **through the code path the defect
    /// actually lived in**.
    ///
    /// The fixture: two displays whose bottom edges are physically coincident in mac space
    /// (both at mac y = 0) but whose scales differ. Mapping each display by its OWN scale --
    /// the rule this file carried before r1 review -- sends those two coincident edges to
    /// Windows y = 1440 and y = 720: 720 remote pixels apart, i.e. the result is not one
    /// coordinate space but the bounding box of two mutually inconsistent embeddings, and the
    /// origin corner the whole contract rests on stops being shared. Under ADR §2 rule 2's
    /// single `rasterScale` the embedding is one affine map and the edges coincide again.
    ///
    /// WHICH HALF OF THIS TEST DISCRIMINATES, stated because r2 review caught the earlier
    /// version of this comment claiming coverage it did not have (r1's M-3 class):
    ///  * The `frameInRemotePixels` half below **does**. That is where the per-display mapping
    ///    lived, so restoring it makes these assertions fail. Verified by mutation, both ways.
    ///  * The `windowsPoint` half below **does not**, and never could: that function resolves
    ///    to `topology.flipAnchor` -- the *primary's* scale -- and did so before the fix too, so
    ///    two points at the same mac y agree under any implementation of its signature. It is
    ///    kept as a statement of the ADR §2 rule 2 semantics at the point entry point (and it
    ///    does fail if the anchor itself is broken), not as a guard against the shear.
    ///
    /// The shear's removal is also enforced by something no runtime test can assert: the
    /// deletion of `flipAnchor(forDisplayAt:)`, which was the other way to reach a per-display
    /// scale. That one is guarded by the compiler.
    @Test("physically coincident edges on displays of different scale stay coincident in Windows space")
    func coincidentEdgesStayCoincidentUnderRasterScale() throws {
        let topology = try #require(
            DisplayTopology(displays: DisplayTopologyFixtures.coincidentBottomEdgesMixedScale)
        )
        #expect(topology.rasterScale == 2)
        #expect(!topology.isUniformScale)

        // THE DISCRIMINATING HALF. Both displays' bottom edges sit at mac y = 0, so in Windows
        // space (Y down) both must land on the same far edge.
        //   primary   (0,0,1280,720)pt   -> y = (720−720)×2 = 0,    h = 1440  => bottom 1440
        //   secondary (1280,0,1920,1080) -> y = (720−1080)×2 = −720, h = 2160  => bottom 1440
        let primaryFrame = try #require(topology.frameInRemotePixels(ofDisplayAt: 0))
        let secondaryFrame = try #require(topology.frameInRemotePixels(ofDisplayAt: 1))
        let primaryBottom = primaryFrame.y + primaryFrame.height
        let secondaryBottom = secondaryFrame.y + secondaryFrame.height

        #expect(primaryBottom == 1440)   // literals, not derived from the topology
        #expect(secondaryBottom == 1440)
        #expect(primaryBottom == secondaryBottom)

        // The pre-fix answer for the secondary, pinned as an explicit negative example: with
        // its OWN scale of 1 it mapped to y = (720−1080)×1 = −360, h = 1080, so its bottom edge
        // landed at 720 -- 720 remote pixels of silent vertical shear away from the primary
        // edge it physically touches.
        #expect(secondaryBottom != 720)
        #expect(secondaryBottom - 720 == 720)

        // THE NON-DISCRIMINATING HALF (see the doc comment): the same rule stated at the point
        // transform. Hard-coded: (720 − 0) × rasterScale 2.
        #expect(WindowGeometry.windowsPoint(from: MacPoint(x: 10, y: 0), in: topology).y == 1440)
        #expect(WindowGeometry.windowsPoint(from: MacPoint(x: 2000, y: 0), in: topology).y == 1440)
    }

    @Test("rasterScale is the primary's ratio -- not the maximum, not an average, not per display")
    func rasterScaleIsThePrimarys() throws {
        // Primary deliberately NOT first in the array and deliberately NOT the largest scale.
        let topology = try #require(DisplayTopology(displays: [
            DisplayTopologyFixtures.display(x: -1920, y: 0, width: 1920, height: 1080, scale: .fullyScaled2x),
            DisplayTopologyFixtures.display(x: 0, y: 0, width: 1920, height: 1080, scale: .unscaled, isPrimary: true),
        ]))

        #expect(topology.rasterScale == 1)
        #expect(topology.rasterScale == topology.primary.scale.remotePixelsPerPoint)
        #expect(topology.flipAnchor.remotePixelsPerPoint == topology.rasterScale)
        #expect(!topology.isUniformScale)
    }

    @Test("isUniformScale is true exactly when every display shares rasterScale")
    func uniformityPredicate() throws {
        let uniform = try #require(DisplayTopology(displays: [
            DisplayTopologyFixtures.display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
            DisplayTopologyFixtures.display(x: 1280, y: 0, width: 1280, height: 720, scale: .fullyScaled2x),
        ]))
        #expect(uniform.isUniformScale)

        let mixed = try #require(DisplayTopology(displays: [
            DisplayTopologyFixtures.display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
            DisplayTopologyFixtures.display(x: 1280, y: 0, width: 1280, height: 720, scale: .unscaled),
        ]))
        #expect(!mixed.isUniformScale)

        // A single display is trivially uniform -- the only configuration that exists today.
        let single = try #require(DisplayTopology.single(widthInPoints: 2560, heightInPoints: 1440))
        #expect(single.isUniformScale)

        // Uniformity looks only at `remotePixelsPerPoint`: backing scale is recorded, never
        // applied, so a topology mixing backing scales is still uniform for geometry purposes.
        let mixedBackingOnly = try #require(DisplayTopology(displays: [
            DisplayTopologyFixtures.display(x: 0, y: 0, width: 1280, height: 720, scale: .unscaled, isPrimary: true),
            DisplayTopologyFixtures.display(x: 1280, y: 0, width: 1280, height: 720, scale: .retinaBackingOnly),
        ]))
        #expect(mixedBackingOnly.isUniformScale)
    }

    /// U3 / W3 guard. `backingPixelsPerPoint` is recorded by M1 and applied by nothing; if a
    /// future edit quietly starts folding it into the desktop size, that would BE the
    /// `DesktopScaleFactor` advertising decision ADR §8 reserves for W3, taken silently. Two
    /// topologies that differ only in backing scale must be indistinguishable in every
    /// geometric output.
    @Test("backing scale is recorded and never enters any geometry")
    func backingScaleIsRecordedNotApplied() throws {
        let plain = try #require(DisplayTopology.single(
            widthInPoints: 1280, heightInPoints: 720, scale: .unscaled
        ))
        let retina = try #require(DisplayTopology.single(
            widthInPoints: 1280, heightInPoints: 720, scale: .retinaBackingOnly
        ))

        #expect(retina.primary.scale.backingPixelsPerPoint == 2)
        #expect(retina.primary.scale.remotePixelsPerPoint == 1)

        #expect(retina.unionBoundsInPoints == plain.unionBoundsInPoints)
        #expect(retina.desktopSizeInRemotePixels == plain.desktopSizeInRemotePixels)
        #expect(retina.rasterScale == plain.rasterScale)
        #expect(retina.flipAnchor == plain.flipAnchor)

        // ...and the two scale factors really are independent fields, i.e. the type can
        // express the gap phase3.md:130's "red today" real-host assertion is about, and can
        // express both of ADR §3's candidate answers (P = .fullyScaled2x, T = .retinaBackingOnly).
        #expect(DisplayScale.retinaBackingOnly.remotePixelsPerPoint
                != DisplayScale.retinaBackingOnly.backingPixelsPerPoint)
        #expect(DisplayScale.fullyScaled2x.remotePixelsPerPoint
                == DisplayScale.fullyScaled2x.backingPixelsPerPoint)
    }

    // MARK: - Per-display frames

    @Test("each display's Windows-space frame uses rasterScale, not its own scale")
    func perDisplayRemoteFrames() throws {
        let topology = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[2].displays)) // ADR F3

        // primary: (0, 0, 1280, 720) points × 2
        #expect(topology.frameInRemotePixels(ofDisplayAt: 0)
                == WindowsRect(x: 0, y: 0, width: 2560, height: 1440))
        // secondary: (1280, 0, 1920, 1080) points × 2 -- its OWN scale is 1, and that is
        // deliberately not what is used (ADR §2 rule 2).
        #expect(topology.frameInRemotePixels(ofDisplayAt: 1)
                == WindowsRect(x: 2560, y: 0, width: 3840, height: 2160))
        #expect(topology.displays[1].scale.remotePixelsPerPoint == 1)

        #expect(topology.frameInRemotePixels(ofDisplayAt: 2) == nil)
        #expect(topology.frameInRemotePixels(ofDisplayAt: -1) == nil)
    }

    // MARK: - The flip anchor

    @Test("flipAnchor takes the primary display's height and rasterScale")
    func flipAnchorComesFromThePrimary() throws {
        // Primary deliberately NOT first in the array, and deliberately the SHORTER of the two
        // displays, so "took displays[0]" and "took the tallest" both fail here.
        let topology = try #require(DisplayTopology(displays: [
            DisplayTopologyFixtures.display(x: -1920, y: 0, width: 1920, height: 1200, scale: .fullyScaled2x),
            DisplayTopologyFixtures.display(x: 0, y: 0, width: 1280, height: 720, scale: .fullyScaled2x, isPrimary: true),
        ]))

        #expect(topology.primary.size.height == 720)
        #expect(topology.flipAnchor.primaryHeightInPoints == 720)
        #expect(topology.flipAnchor.remotePixelsPerPoint == 2)

        // The union is taller than the primary here (1200 > 720), which is precisely the
        // number a careless anchor would pick up -- and which the type system now refuses to
        // hand over as a bare length (ADR §4.A.2): reading it requires `.inPoints`.
        #expect(topology.unionBoundsInPoints.height.inPoints == 1200)
        #expect(topology.flipAnchor.primaryHeightInPoints != topology.unionBoundsInPoints.height.inPoints)
    }

    // MARK: - Validity

    @Test("an unusable screen layout produces nil rather than a topology that computes garbage",
          arguments: DisplayTopologyFixtures.invalid)
    func invalidTopologiesAreRejected(_ fixture: InvalidTopologyFixture) {
        #expect(DisplayTopology(displays: fixture.displays) == nil)
    }

    /// The positive half of I-4's guard: a primary exactly at the mac origin is accepted, and it
    /// is the case that makes ADR §3 rule 1's "the primary always maps to (0, 0)" true.
    @Test("a primary at the mac origin is accepted and maps to the Windows origin")
    func primaryAtOriginMapsToWindowsOrigin() throws {
        let topology = try #require(DisplayTopology.single(widthInPoints: 1920, heightInPoints: 1080))
        #expect(topology.frameInRemotePixels(ofDisplayAt: 0)
                == WindowsRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(topology.unionBoundsInPoints.x.inPoints == 0)
        #expect(topology.unionBoundsInPoints.y.inPoints == 0)
    }

    @Test("the single-display convenience rejects the same inputs init(displays:) does")
    func singleRejectsUnusableInput() {
        #expect(DisplayTopology.single(widthInPoints: 0, heightInPoints: 1080) == nil)
        #expect(DisplayTopology.single(widthInPoints: 1920, heightInPoints: 0) == nil)
        #expect(DisplayTopology.single(widthInPoints: .nan, heightInPoints: 1080) == nil)
        #expect(DisplayTopology.single(
            widthInPoints: 1920, heightInPoints: 1080,
            scale: DisplayScale(remotePixelsPerPoint: 0, backingPixelsPerPoint: 1)
        ) == nil)
    }

    /// The `nil` case is a real state, not merely a defensive one:
    /// `RemoteWindowRegistry.swift:983-995` already declines to position windows when
    /// `NSScreen.screens` is empty. This asserts the replacement guard has the same shape --
    /// `guard let topology` instead of `guard primaryMonitorHeight > 0`.
    @Test("the empty-screen-list case is representable as nil, matching the registry's existing headless guard")
    func headlessIsRepresentable() {
        let topology = DisplayTopology(displays: [])
        #expect(topology == nil)
        if let topology { Issue.record("expected nil for an empty display list, got \(topology)") }
    }

    // MARK: - Value semantics

    @Test("topologies are values: equal inputs compare equal, and a copy is unaffected by a later one")
    func valueSemantics() throws {
        let displays = DisplayTopologyFixtures.union[4].displays
        let first = try #require(DisplayTopology(displays: displays))
        let second = try #require(DisplayTopology(displays: displays))
        #expect(first == second)

        // Taking a copy and then building a DIFFERENT topology must not disturb the copy --
        // trivially true for a struct whose own storage is `let`, asserted because M1's lane
        // rule ("the topology value must not be mutable or global") is exactly what would be
        // violated if this type were ever quietly turned into a class or given a shared
        // instance. Note the element structs expose `var` properties: a `Display` read out of a
        // topology is a copy, so mutating it cannot reach back into the topology.
        let copy = first
        let other = try #require(DisplayTopology.single(widthInPoints: 800, heightInPoints: 600))
        #expect(copy == first)
        #expect(copy != other)

        var mutatedElement = first.displays[0]
        mutatedElement.size = MacSize(width: 1, height: 1)
        #expect(first.displays[0].size != mutatedElement.size)
        #expect(first == second)
    }

    @Test("the description carries screen geometry only -- no host data")
    func descriptionIsRedactionSafe() throws {
        let topology = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[2].displays)) // ADR F3
        let text = topology.description

        // Redaction is structural, not filtered: the only values interpolated in are this
        // topology's own numbers, so the string is fully determined by the fixture and there
        // is no channel through which a host address, hostname, or credential could reach it.
        // Asserting the whole string, rather than probing for forbidden substrings, is what
        // makes that a checkable claim -- any future field added to the description breaks
        // this test and has to be re-justified against the project's red lines.
        #expect(text == "[1280x720pt@(0,0) rpx/pt=2.0 backing=2.0 primary"
                + " | 1920x1080pt@(1280,-360) rpx/pt=1.0 backing=1.0]"
                + " desktop=6400x2160rpx rasterScale=2.0 MIXED-SCALE")

        // The mixed-scale marker is not cosmetic: ADR §2 rule 4 requires the case to be
        // recorded, and a log line that dropped it is the easiest place for that to lapse.
        let uniform = try #require(DisplayTopology.single(widthInPoints: 2560, heightInPoints: 1440))
        #expect(!uniform.description.contains("MIXED-SCALE"))
    }

    // MARK: - The provider seam

    @MainActor
    @Test("the injectable default provider reports exactly the topology it was given")
    func staticProviderReportsItsTopology() throws {
        let topology = try #require(DisplayTopology.single(widthInPoints: 2560, heightInPoints: 1440))
        let provider: any DisplayTopologyProviding = StaticDisplayTopologyProvider(topology)

        #expect(provider.currentTopology == topology)
    }

    @MainActor
    @Test("the injectable default provider can also report the no-usable-display state")
    func staticProviderCanReportNoDisplay() {
        let provider: any DisplayTopologyProviding = StaticDisplayTopologyProvider(nil)
        #expect(provider.currentTopology == nil)
    }

    /// The seam's actual job: geometry code takes `any DisplayTopologyProviding` and is
    /// therefore runnable under `swift test` with no display attached, which
    /// `Package.swift:21-24` requires of everything in this target. This stands in for the
    /// wave-2 call sites (registry, window-smoke) so the interface is exercised before they
    /// exist, rather than being declared and left unproven.
    @MainActor
    @Test("a consumer written against the protocol works with the static provider and no display")
    func protocolIsUsableAsASeam() throws {
        func desktopSize(from provider: any DisplayTopologyProviding) -> DesktopSizeInRemotePixels? {
            provider.currentTopology?.desktopSizeInRemotePixels
        }

        let topology = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[3].displays)) // ADR F4
        #expect(desktopSize(from: StaticDisplayTopologyProvider(topology))
                == DesktopSizeInRemotePixels(width: 2560, height: 1440))
        #expect(desktopSize(from: StaticDisplayTopologyProvider(nil)) == nil)
    }
}
