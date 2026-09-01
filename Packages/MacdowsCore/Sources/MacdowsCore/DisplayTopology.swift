import Foundation

// Phase 3 M1 / W1 deliverable 1 (`docs/plans/phase3.md:109`): the AppKit-free display
// topology value that `WindowGeometry`'s four conversion functions now anchor on, instead of
// a bare `primaryMonitorHeight: Double`.
//
// CONTRACT: this file implements `docs/adr/0015-display-topology-and-dpi-contract.md`.
// Every rule below that could have been a lane decision is instead a citation into that ADR
// -- §1 (the three-unit vocabulary), §2 (U1: scale is per display, plus a single derived
// `rasterScale`), §3 (U3: the desktop size is remote pixels, and its exact derivation rule),
// §4 (U2: the Y flip anchors on the primary's height and the union height must be
// unreachable from the flip), §9 (the lane's own hard-constraint checklist). Where this file
// and the ADR could drift, the ADR wins; the fixture table in `DisplayTopologyTests` is
// transcribed from ADR §3.5 cell for cell.
//
// WHY A VALUE AND NOT A LOOKUP: phase3.md §1 F1 records that the whole geometry chain has no
// "scale" dimension at all -- the four functions take one `Double` and do a Y flip, and the
// height they are handed comes from `NSScreen.screens.first` at the call site
// (`App/RemoteWindowRendering/RemoteWindowRegistry.swift:373-378`). Two separate defects hide
// in that shape: (a) only the FIRST screen is ever consulted, so the charter's
// "request the desktop size as the union of all local screens" constraint -- in force since
// Phase 1 per `ARCHITECTURE.md:38`, never implemented (F3) -- has nowhere to be expressed;
// and (b) there is no place to put a scale factor, so remote pixels, mac points and backing
// pixels are all silently the same number. This file introduces the value that both of those
// need, WITHOUT introducing AppKit: `Packages/MacdowsCore/Package.swift:21-24` defines this
// target as pure logic that must run under `swift test` with no display, so resolving real
// screens stays above this boundary (the App-side collector, W1's second deliverable) and
// this package only models and computes.
//
// WHAT IS STILL NOT DECIDED HERE, with the ADR section that owns it:
//   * whether W3 advertises `DesktopScaleFactor` at all, and therefore whether
//     `DisplayScale.remotePixelsPerPoint` ever becomes the backing scale -- ADR §8, W3.
//     `DisplayScale` keeps the two ratios separate so that ruling is a one-line change at the
//     collector rather than a re-signature here.
//   * the negative extension of the virtual desktop (displays left of / above the primary),
//     which today's single synthesised server-side monitor cannot express -- ADR §3 rule 4
//     records it as a W4 gap; `desktopSizeInRemotePixels` clips it, loudly and testably,
//     rather than translating the origin (which would trade a visible clamp for an invisible
//     offset).
//   * per-monitor scale on the wire (`MONITOR_ATTRIBUTES`) -- ADR §8, W4. The per-display
//     `scale` field is that landing spot; `rasterScale` is the adapter for "the server only
//     has one raster today" and ADR §8 requires W4 to explicitly keep or delete it.
// None of these are observable today: `docs/plans/phase3.md:219` records that exactly one
// display exists and it is currently 1x, so every multi-display / non-1x row in this file's
// test suite is an offline fixture, not a measurement.

/// A size in macOS points -- the unit `NSScreen.frame`, `NSWindow.frame` and every AppKit
/// layout API use. Distinct from remote-pixel sizes on purpose: phase3.md §1 F1's whole point
/// is that "remote pixel" and "mac point" have been the same `Double` for the entire life of
/// this project, and the first step of separating them is giving them different types.
public struct MacSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The two independent scale factors a single display carries, kept as separate fields
/// rather than one "scale" number.
///
/// phase3.md §1 F1 names THREE spaces -- remote px, mac pt, backing px -- and a single scalar
/// cannot relate three spaces. The two ratios below are what actually exist:
///
/// * `remotePixelsPerPoint` is the only one `WindowGeometry` applies. It answers "how many
///   remote pixels is one mac point on this display", which is decided entirely by what
///   desktop size we asked the server for. Today it is **1** for every display, and that is
///   a fact rather than a placeholder: we never advertise `DesktopScaleFactor` (grep for it
///   under `App`/`Packages`/`Tools`/`Scripts` is empty -- F3, re-verified in ADR §0c), so the
///   server's pixel grid is numerically our point grid.
/// * `backingPixelsPerPoint` is `NSScreen.backingScaleFactor`: what the Mac itself renders
///   at. M1 **records** it and applies it nowhere. Making the two equal -- i.e. asking the
///   server to render at backing resolution -- is exactly the `DesktopScaleFactor` advertising
///   decision ADR §8 assigns to W3, and this milestone's global MUST-NOT list forbids
///   touching it. Recording it now is what lets W3 measure the gap instead of re-guessing it.
///
/// ADR §0 records that the ADR's own "reviewed, not yet ratified" gate is safe precisely
/// because of this split (`adr/0015…:7`): §3's P answer corresponds to `.fullyScaled2x`, its T
/// answer to `.retinaBackingOnly`, and **both are expressible in the landed type**. Whichever
/// the owner ratifies, the change is which ratio the collector fills in -- not a re-signature.
public struct DisplayScale: Equatable, Sendable {
    /// Remote (RDP wire) pixels per macOS point on this display. See the type's own note:
    /// 1 today for every display, by construction, not by omission.
    public var remotePixelsPerPoint: Double

    /// `NSScreen.backingScaleFactor` for this display. Recorded, never applied in M1 (W3).
    public var backingPixelsPerPoint: Double

    public init(remotePixelsPerPoint: Double, backingPixelsPerPoint: Double) {
        self.remotePixelsPerPoint = remotePixelsPerPoint
        self.backingPixelsPerPoint = backingPixelsPerPoint
    }

    /// Today's real configuration and the identity element for both ratios: one remote pixel
    /// per point, one backing pixel per point. `docs/plans/phase3.md:219` records the owner's
    /// measurement -- a single 2560x1440 display running natively, `backingScaleFactor == 1`.
    public static let unscaled = DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1)

    /// A Retina display that the Mac renders at 2x while the RDP session is still negotiated
    /// in points -- i.e. today's code path on a 2x screen, and ADR §3's answer T. This is the
    /// configuration phase3.md's "red today, green on delivery" real-host assertion is about
    /// (`docs/plans/phase3.md:130`): `remotePixelsPerPoint` stays 1 because we advertise no
    /// scale factor, while the Mac's own backing store is 2x, and the difference between those
    /// two numbers IS the missing `backingScaleFactor` factor F1 describes.
    public static let retinaBackingOnly = DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 2)

    /// A fully-2x session -- the server renders at 2x AND the Mac's backing store is 2x. This
    /// is ADR §3's recommended answer P realised on a 2x display. Reaching it on a real host
    /// requires the `DesktopScaleFactor` advertising ADR §8 assigns to W3, so every fixture
    /// using it is offline-only.
    public static let fullyScaled2x = DisplayScale(remotePixelsPerPoint: 2, backingPixelsPerPoint: 2)

    /// Whether both ratios are usable as divisors/multipliers. Checked by
    /// `DisplayTopology.init(displays:)`, which is the only place a scale becomes load-bearing.
    var isUsable: Bool {
        remotePixelsPerPoint.isFinite && remotePixelsPerPoint > 0
            && backingPixelsPerPoint.isFinite && backingPixelsPerPoint > 0
    }
}

/// The virtual desktop's bounding box -- ADR §3 rule 2's `unionBoundsPt`.
///
/// SPACE AND UNIT, both unusual and both deliberate: the axes are **Windows screen space**
/// (top-left origin, Y increasing downward, the primary display's top-left corner at the
/// origin, so `x`/`y` go negative for displays left of / above the primary), but the
/// measurements are **mac points**, not remote pixels. That is not an oversight -- ADR §3's
/// derivation maps every display into Windows space first (rule 1, points only) and applies
/// `rasterScale` exactly once, at rule 3, when producing the desktop size. Keeping the
/// intermediate in points is what makes the single multiplication auditable.
///
/// WHY THE COMPONENTS ARE NOT `Double`. ADR §4.A.2 is explicit: `unionBounds` and
/// `desktopSizePx` must be named types rather than bare lengths, "so that passing the union
/// height to the flip function does not even compile". A `Double` height would be usable
/// anywhere a primary height is -- including the deprecated `primaryMonitorHeight:` shims,
/// which are the one bare-`Double` door left in this package and which live in exactly the
/// wave in which L7 is migrating call sites. So `height` here is a `Scalar`, not a `Double`,
/// and getting the number out is the deliberate, greppable act of reading `.inPoints`.
public struct DesktopUnionBoundsInPoints: Equatable, Sendable {
    /// A measurement in mac points that is **not** interchangeable with a bare `Double`.
    /// Reading `.inPoints` is intentionally a visible step -- see the enclosing type's note.
    public struct Scalar: Equatable, Comparable, Sendable {
        public let inPoints: Double

        init(_ inPoints: Double) { self.inPoints = inPoints }

        public static func < (lhs: Scalar, rhs: Scalar) -> Bool { lhs.inPoints < rhs.inPoints }
    }

    /// Left edge in Windows-space axes. Negative when a display sits left of the primary.
    public let x: Scalar
    /// Top edge in Windows-space axes. Negative when a display sits above the primary.
    public let y: Scalar
    public let width: Scalar
    public let height: Scalar

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = Scalar(x)
        self.y = Scalar(y)
        self.width = Scalar(width)
        self.height = Scalar(height)
    }

    /// Far right edge, `x + width`. ADR §3 rule 3 uses `max(0, maxX)`.
    public var maxX: Scalar { Scalar(x.inPoints + width.inPoints) }
    /// Far bottom edge, `y + height`. ADR §3 rule 3 uses `max(0, maxY)`.
    public var maxY: Scalar { Scalar(y.inPoints + height.inPoints) }
}

/// The desktop size actually sent to the server -- ADR §3 rule 3's `desktopSizePx`, the single
/// value that may reach `CRSession.desktopWidth/Height`.
///
/// Integers, not `Double`s, because the wire field is one: `DesktopWidth`/`DesktopHeight` are
/// written as **UINT16** in the same TS_UD_CS_CORE block that carries the (orthogonal) scale
/// hints (`ThirdParty/FreeRDP/libfreerdp/core/gcc.c:1432-1435` vs `:1502-1503`, ADR §0b).
public struct DesktopSizeInRemotePixels: Equatable, Sendable {
    public let width: Int
    public let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// ADR §3 rule 3's `kMaxDesktopExtentPx`. 65535 is the UINT16 ceiling of the wire field's
    /// own C cast, **not** a protocol bound -- MS-RDPBCGR's real limit on `desktopWidth` was
    /// not verified in the ADR's round and is a C-2 check item (ADR §3's closing note), after
    /// which this constant is refined rather than invented.
    ///
    /// Clamping here is not a cheap-insurance nicety. ADR §3 rule 3 traces the overflow path
    /// through `WINPR_ASSERTING_INT_CAST` (`winpr/include/winpr/cast.h:99-119`) →
    /// `WINPR_ASSERT_AT` → `winpr_internal_assert`, whose verbose branch is a `WINPR_NORETURN`
    /// export and whose enabling option defaults ON upstream
    /// (`ThirdParty/FreeRDP/cmake/CommonConfigOptions.cmake:15-18`) and is never disabled by
    /// `deps/freerdp.lock`: in this repo's own build an out-of-range desktop size **aborts the
    /// process**. Under a build with that option off it silently truncates modulo 65536
    /// instead, which is the harder failure to attribute. Both outcomes are unacceptable, so
    /// the clamp is required independently of build configuration.
    public static let maxExtentInRemotePixels = 65535
}

/// The local display layout, as an immutable value.
///
/// Deliberately a `struct` with no shared instance and no mutating API: M1's lane rules
/// forbid a mutable or global topology, and for a good reason beyond tidiness --
/// `RemoteWindowRegistry` today reads `NSScreen.screens.first` freshly at every call site
/// (`:373-378`), so two conversions inside one logical operation can silently disagree if the
/// screen layout changes between them. ADR §5 turns that into a load-bearing invariant: within
/// one session the Y-flip anchor and the desktop size must come from the SAME topology read,
/// and the session's snapshot is frozen at connect time. Passing one value through an
/// operation is what makes that expressible; the screen-parameter observer (W1 deliverable 2)
/// therefore produces NEW values rather than mutating a shared one.
public struct DisplayTopology: Equatable, Sendable {
    /// One display in the local (Mac) screen layout: origin, size, scale, and whether it is
    /// the primary -- exactly the four fields ADR §2 rule 1 specifies, and the shape W4 fills
    /// in when it wires `MONITOR_ATTRIBUTES` (ADR §8: fill fields, do not change the model).
    ///
    /// COORDINATE SPACE, stated once so no consumer has to guess: `origin` and `size` are in
    /// **macOS screen space** -- bottom-left origin, Y up, the primary display's bottom-left
    /// corner at (0, 0) -- because that is what `NSScreen.frame` reports and this value is
    /// collected from `NSScreen`. Windows-space views of the same layout are *derived*, never
    /// stored (`unionBoundsInPoints`, `frameInRemotePixels(ofDisplayAt:)`); that keeps exactly
    /// one flip in the codebase rather than a stored second opinion that can drift out of
    /// agreement with `WindowGeometry`.
    public struct Display: Equatable, Sendable {
        /// Bottom-left corner of this display in mac screen space, in points. Exactly (0, 0)
        /// for the primary -- enforced by `DisplayTopology.init(displays:)`, see its note.
        public var origin: MacPoint

        /// This display's size in mac points.
        public var size: MacSize

        /// This display's scale factors -- see `DisplayScale`. Per display, per ADR §2 rule 1;
        /// note that geometry uses the derived `rasterScale`, not this field directly (rule 2).
        public var scale: DisplayScale

        /// Whether this is the primary display: the one whose corner both coordinate systems
        /// treat as their origin, and therefore the one whose height anchors every Y flip. A
        /// topology has exactly one (enforced by `DisplayTopology.init(displays:)`).
        public var isPrimary: Bool

        public init(origin: MacPoint, size: MacSize, scale: DisplayScale, isPrimary: Bool) {
            self.origin = origin
            self.size = size
            self.scale = scale
            self.isPrimary = isPrimary
        }

        /// This display's frame in mac screen space (points) -- `origin` and `size` as one rect.
        public var frameInPoints: MacRect {
            MacRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        }

        var isUsable: Bool {
            origin.x.isFinite && origin.y.isFinite
                && size.width.isFinite && size.width > 0
                && size.height.isFinite && size.height > 0
                && scale.isUsable
        }
    }

    /// Every display, in the order the collector supplied them (AppKit's own `NSScreen.screens`
    /// order, which puts the primary first but is not guaranteed to; `primary` does not rely
    /// on position).
    public let displays: [Display]

    /// Index of the single primary display in `displays`. Stored so `primary` is a total
    /// function -- `init(displays:)` has already rejected any input where it would not be.
    private let primaryIndex: Int

    /// Fails -- returns `nil` rather than trapping -- when the input cannot describe a usable
    /// screen layout: no displays at all, no primary or more than one, **a primary that is not
    /// at the mac origin**, a non-positive or non-finite size, or a non-positive scale.
    ///
    /// The primary-at-origin condition is a precondition of the whole coordinate contract, not
    /// a stylistic convention. ADR §3 rule 1 requires that "the primary itself always maps to
    /// (0, 0) -- that is the origin corner the two coordinate systems share", and ADR §4
    /// derives the entire anchor argument from it (upstream agrees: FreeRDP's synthesised
    /// single monitor is pinned at `(0,0)` with `is_primary = TRUE`,
    /// `ThirdParty/FreeRDP/libfreerdp/core/settings.c:1798-1813`). A primary at, say, mac
    /// (100, 50) is accepted by every other check here and then produces a Windows origin of
    /// (100, −50) -- silently, self-consistently, and wrong in every derived value. AppKit does
    /// place the menu-bar screen at (0, 0), so in production this is defence in depth; it stops
    /// mattering being hypothetical the moment a fixture or a future collector gets it wrong,
    /// which would otherwise yield a green, self-consistent, wrong scenario table.
    ///
    /// `nil` is a REAL state, not defensive noise: `RemoteWindowRegistry.swift:983-995`
    /// already documents and handles the empty-`NSScreen.screens` case (headless, or every
    /// display asleep) by skipping window positioning rather than computing a bogus
    /// coordinate. Making the topology failable is how that existing guard survives the
    /// migration -- `guard primaryMonitorHeight > 0` becomes `guard let topology`, with the
    /// same meaning and one fewer magic number. ADR §5.A.6 additionally forbids the collapse
    /// of that state into a `0 x 0` desktop size: 0/0 makes FreeRDP fall back to a 1024x768
    /// desktop (`CRSession.h:285-286`), which is the original "invisible wall" fault. Because
    /// this initializer rejects the empty list outright, `desktopSizeInRemotePixels` is
    /// structurally incapable of being 0 in either dimension.
    public init?(displays: [Display]) {
        guard !displays.isEmpty else { return nil }
        guard displays.allSatisfy(\.isUsable) else { return nil }
        let primaries = displays.indices.filter { displays[$0].isPrimary }
        guard primaries.count == 1, let primaryIndex = primaries.first else { return nil }
        guard displays[primaryIndex].origin == MacPoint(x: 0, y: 0) else { return nil }
        self.displays = displays
        self.primaryIndex = primaryIndex
    }

    /// Convenience for the single-display case -- which is not merely a test shape but the
    /// only configuration that physically exists for this project today
    /// (`docs/plans/phase3.md:219`). Fails on the same conditions as `init(displays:)`.
    public static func single(
        widthInPoints: Double,
        heightInPoints: Double,
        scale: DisplayScale = .unscaled
    ) -> DisplayTopology? {
        DisplayTopology(displays: [
            Display(
                origin: MacPoint(x: 0, y: 0),
                size: MacSize(width: widthInPoints, height: heightInPoints),
                scale: scale,
                isPrimary: true
            )
        ])
    }

    /// The primary display. Total: `init(displays:)` guarantees exactly one exists and that it
    /// sits at the mac origin.
    public var primary: Display { displays[primaryIndex] }

    // MARK: - Derived scale (ADR §2 rules 2 and 4)

    /// The one scale factor every conversion in this package uses: **the primary display's**
    /// `remotePixelsPerPoint` (ADR §2 rule 2).
    ///
    /// Not `max`, not an average, not per display. The reason is the wire, not taste: today
    /// the server sees exactly one monitor and one raster, synthesised from the desktop size we
    /// send (`settings.c:1798-1813`, ADR §0c), so a union assembled from displays with
    /// different scales simply cannot be expressed. Taking the primary's scale keeps the flip
    /// anchor and the raster in the same space -- the primary is where the two coordinate
    /// systems share their origin (ADR §4) and it is already the project's definition of "the"
    /// screen (`RemoteWindowRegistry.swift:373-377`).
    ///
    /// Mapping each display by its OWN scale instead -- the shape this file carried before
    /// r1 review -- looks more faithful and is not: two physically coincident edges on
    /// different displays then land at different Windows-space Y values (720 remote pixels
    /// apart in the mixed-scale fixture), so the result is not a single coordinate space at
    /// all but the bounding box of two mutually inconsistent embeddings. ADR §2 rule 4 chooses
    /// the coherent embedding and makes the price visible via `isUniformScale` instead.
    public var rasterScale: Double { primary.scale.remotePixelsPerPoint }

    /// Whether every display shares `rasterScale` (ADR §2 rule 4).
    ///
    /// When this is `false`, the non-primary displays are being asked for at the primary's
    /// scale -- a known, deliberate, *unexpressible-otherwise* approximation, not a supported
    /// configuration. ADR §2 rule 4 pins the handling exactly: **record once, do not degrade,
    /// do not refuse, do not change behaviour** (M1 is a measurement batch). It also pins who
    /// records it -- the App-side provider, at topology CONSTRUCTION (once per connect, plus
    /// once per observer-reported change), because the construction point is unique while
    /// consumption points are many. This package deliberately exposes only the boolean and logs
    /// nothing: `Package.swift:21-24` leaves it with neither AppKit nor a logging facility.
    public var isUniformScale: Bool {
        displays.allSatisfy { $0.scale.remotePixelsPerPoint == rasterScale }
    }

    // MARK: - The flip anchor

    /// The anchor `WindowGeometry`'s four conversions take: the PRIMARY display's height in
    /// points, paired with `rasterScale`.
    ///
    /// This property is the ONLY way to obtain a `DisplayFlipAnchor` -- see that type's own doc
    /// comment for why that matters. The short version: a topology makes "union height"
    /// available for the first time, and `WindowGeometry.swift`'s existing argument (`:61-74`,
    /// restated as a ruling in ADR §4) is precisely that anchoring the flip on anything other
    /// than the primary's height is wrong. Having the anchor be a nominal type with no public
    /// initializer, and the union bounds be a type whose components are not `Double`, is ADR
    /// §4.A.1/§4.A.2's requirement that the mistake not compile.
    public var flipAnchor: DisplayFlipAnchor {
        DisplayFlipAnchor(
            primaryHeightInPoints: primary.size.height,
            remotePixelsPerPoint: rasterScale
        )
    }

    // MARK: - Union bounds and the desktop size (ADR §3 rules 1-4)

    /// ADR §3 rule 1: this display's frame mapped into Windows-space axes, still measured in
    /// **mac points** -- `x = frame.minX`, `y = primaryHeightPt − frame.maxY`. The primary
    /// itself always maps to `(0, 0)`, which `init(displays:)` guarantees.
    ///
    /// Private and unit-scoped: it is an intermediate of the union derivation, and giving it a
    /// public `WindowsRect` face would put a points value into a type the vocabulary reserves
    /// for remote pixels (ADR §1). `unionBoundsAgreesWithWindowGeometryAtRasterScale` in the
    /// tests pins it against `WindowGeometry`'s own flip so the two cannot drift.
    private func windowsFrameInPoints(of display: Display) -> (x: Double, y: Double, width: Double, height: Double) {
        let frame = display.frameInPoints
        return (
            x: frame.x,
            y: primary.size.height - (frame.y + frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    /// ADR §3 rule 2: the bounding box of every display in Windows-space axes, in mac points.
    /// A **rectangle**, not a size, and its origin may be negative -- that is the whole point:
    /// negative x/y is a display left of / above the primary, which is the case rule 4 records
    /// as a W4 gap. It is also the quantity W4 needs when it wires `MonitorDefArray`, computed
    /// and tested in M1 so W4 does not redo it.
    ///
    /// Its `height` is NOT the flip anchor and generally is not even equal to it -- that is the
    /// hazard this file exists to close, which is why `height` is a `Scalar` rather than a
    /// `Double` (ADR §4.A.2) and why
    /// `WindowGeometryTests.flipAnchorIsThePrimaryHeightNotTheUnionHeight` pins the difference.
    public var unionBoundsInPoints: DesktopUnionBoundsInPoints {
        // Seeded from the PRIMARY's own Windows-space frame, not from sentinels.
        // `init(displays:)` guarantees the primary exists and is finite, so the accumulators
        // start on a real rect and the result is finite by construction -- it does not depend
        // on the loop below running at least once. (r2 review N-2: the previous version of this
        // comment claimed exactly this while the code actually used ±greatestFiniteMagnitude
        // sentinels, where a zero-iteration loop would have yielded a −infinity extent. The
        // code now matches the claim rather than the claim being weakened to match the code.)
        let seed = windowsFrameInPoints(of: primary)
        var minX = seed.x, minY = seed.y
        var maxX = seed.x + seed.width, maxY = seed.y + seed.height
        for display in displays {
            let frame = windowsFrameInPoints(of: display)
            minX = Swift.min(minX, frame.x)
            minY = Swift.min(minY, frame.y)
            maxX = Swift.max(maxX, frame.x + frame.width)
            maxY = Swift.max(maxY, frame.y + frame.height)
        }
        return DesktopUnionBoundsInPoints(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// ADR §3 rule 3: the desktop size to request at connect time, and the only value that may
    /// reach `CRSession.desktopWidth/Height`.
    ///
    /// ```
    /// desktopSizePx = ( max(0, unionBoundsPt.maxX) × rasterScale ,
    ///                   max(0, unionBoundsPt.maxY) × rasterScale )   rounded UP, clamped
    /// ```
    ///
    /// Four parts, each ruled rather than chosen here:
    ///
    /// * **The far EDGES (`maxX`/`maxY`), not the full extent (`width`/`height`).** This is
    ///   where the negative extension is actually clipped, and it is the load-bearing half of
    ///   the rule. The server has one monitor pinned at `(0,0)` (`settings.c:1798-1813`), so a
    ///   display in Windows-negative territory lies outside any desktop we can advertise. ADR
    ///   §3 rule 4 requires that gap be *recorded* as W4 work and explicitly forbids the
    ///   alternative of translating the origin to zero, which would trade a visible server-side
    ///   clamp for an invisible whole-layout offset. ADR fixture F4 asserts the consequence as a
    ///   number -- a topology whose second display is entirely left-of-and-above the primary
    ///   yields exactly the same desktop size as having no second display at all. Using the
    ///   bounding box's `width`/`height` here instead would ask for a raster 2.5x too large in
    ///   that fixture; `negativeExtensionIsClippedNotAbsorbed` and the ADR table both fail if
    ///   anyone tries it (verified by mutation, not assumed).
    /// * **`max(0, …)` is transcribed from the ADR's formula and is, as written here,
    ///   unreachable -- deliberately kept, and deliberately not claimed as tested.** With
    ///   `init(displays:)` guaranteeing a primary at the mac origin with a positive size, the
    ///   primary alone contributes `maxX ≥ primaryWidth > 0` and `maxY ≥ primaryHeight > 0`, so
    ///   neither far edge can be negative and the clamp never fires. No fixture can exercise it
    ///   and none pretends to. It stays because it is the ADR's literal rule and because the
    ///   invariant that makes it dead is exactly the kind W4 may relax when it wires
    ///   `MonitorDefArray` -- at which point this line is the difference between a clipped
    ///   desktop and a negative one.
    /// * **Rounding UP, not down.** ADR §3 rule 3: asking for extra pixels is reversible (the
    ///   server renders a column we do not show); asking for too few is not (that column falls
    ///   outside the desktop and the server clamps windows back inside -- a small-scale
    ///   recurrence of the `CRSession.h:287-292` invisible wall). At `rasterScale ∈ {1,2}` with
    ///   integer point coordinates rounding never occurs at all; it starts to matter only if a
    ///   fractional mode such as 1.5x ever appears, and then the direction is the wall's
    ///   presence or absence.
    /// * **Clamping to `DesktopSizeInRemotePixels.maxExtentInRemotePixels`** -- see that
    ///   constant's own note; out-of-range aborts the process in this repo's build.
    ///
    /// Cannot be zero in either dimension: `init(displays:)` guarantees a primary at the mac
    /// origin with a positive size, so `maxX ≥ primaryWidth > 0` and `maxY ≥ primaryHeight > 0`
    /// -- which is what makes ADR §5.A.6's "never send 0 x 0" unrepresentable here rather than
    /// merely forbidden.
    public var desktopSizeInRemotePixels: DesktopSizeInRemotePixels {
        let bounds = unionBoundsInPoints
        let maxExtent = Double(DesktopSizeInRemotePixels.maxExtentInRemotePixels)

        func extent(_ farEdge: DesktopUnionBoundsInPoints.Scalar) -> Int {
            let positive = Swift.max(0, farEdge.inPoints) * rasterScale
            return Int(Swift.min(positive.rounded(.up), maxExtent))
        }

        return DesktopSizeInRemotePixels(width: extent(bounds.maxX), height: extent(bounds.maxY))
    }

    /// The frame of the display at `index` in Windows screen space (remote pixels), derived --
    /// never stored -- by running that display's own mac-space frame through `WindowGeometry`
    /// with this topology's single anchor, i.e. at `rasterScale`, per ADR §2 rule 2.
    ///
    /// Going through `WindowGeometry` rather than repeating the flip is deliberate: a second
    /// implementation is exactly the failure mode phase3.md §5 risk 5 describes, and the same
    /// discipline the registry is held to ("`WindowGeometry.` remains the file's only
    /// coordinate arithmetic") should hold inside this package too.
    ///
    /// Returns `nil` for an out-of-range index. x/y may be negative -- that is what a display
    /// left of or above the primary looks like in Windows space, and ADR §3 rule 4 is about
    /// what the desktop size can and cannot do with that.
    public func frameInRemotePixels(ofDisplayAt index: Int) -> WindowsRect? {
        guard displays.indices.contains(index) else { return nil }
        return WindowGeometry.windowsRect(from: displays[index].frameInPoints, in: self)
    }
}

extension DisplayTopology.Display: CustomStringConvertible {
    /// Contains local screen geometry only -- no host address, hostname, or credential -- so it
    /// is safe for logs and for redacted evidence artifacts (project red lines).
    public var description: String {
        let primaryTag = isPrimary ? " primary" : ""
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))pt"
            + "@(\(Int(origin.x.rounded())),\(Int(origin.y.rounded())))"
            + " rpx/pt=\(scale.remotePixelsPerPoint) backing=\(scale.backingPixelsPerPoint)\(primaryTag)"
    }
}

extension DisplayTopology: CustomStringConvertible {
    /// One line, no host data (see `DisplayTopology.Display.description`). Exists so the
    /// App-side observer and `window-smoke` log the same shape instead of each inventing one.
    /// Carries `isUniformScale` because ADR §2 rule 4 requires the mixed-scale case to be
    /// recorded once at construction, and a log line that omitted it would be the easiest place
    /// for that requirement to quietly lapse.
    public var description: String {
        let size = desktopSizeInRemotePixels
        return "[\(displays.map(\.description).joined(separator: " | "))]"
            + " desktop=\(size.width)x\(size.height)rpx"
            + " rasterScale=\(rasterScale)\(isUniformScale ? "" : " MIXED-SCALE")"
    }
}

/// The Y-flip anchor plus the remote-pixel/point ratio: everything `WindowGeometry` needs, and
/// nothing it does not.
///
/// THE POINT OF THIS TYPE IS ITS MISSING INITIALIZER. `WindowGeometry.swift:61-74` argues at
/// length -- and ADR §4 rules -- that the flip must anchor on the PRIMARY display's height and
/// never on the bounding height of the whole virtual desktop; before this milestone that was
/// safe mostly because no caller had a union height lying around to get it wrong with.
/// Introducing a topology value removes that accidental safety: a union height reads perfectly
/// plausibly at a call site, and would be wrong on every multi-display layout while remaining
/// exactly right on the single-display one that is the only thing anybody can test against
/// today (`docs/plans/phase3.md:219`). A silent, untestable-in-practice wrong answer is the
/// worst possible shape for that hazard.
///
/// So the closure has two halves, and ADR §4.A.1/§4.A.2 require both:
///  1. this type's memberwise initializer is `internal`, so outside the module the only way to
///     make one is `DisplayTopology.flipAnchor`, which takes the height from
///     `primary.size.height`;
///  2. `DisplayTopology.unionBoundsInPoints` does not vend a `Double` at all -- its components
///     are `DesktopUnionBoundsInPoints.Scalar` -- so the union height cannot be passed to
///     anything that takes a length, including the deprecated `primaryMonitorHeight:` shims.
///
/// Precise scope of the claim (r1 review corrected an over-statement here): what cannot be
/// written is *feeding a union height to the flip*. A caller determined to defeat this can
/// still read `.inPoints`, or synthesise a fake single-display topology whose primary height
/// happens to be the union height. Both are deliberate multi-step acts that read as such; the
/// design target is that the *accidental* form does not compile, and it does not.
public struct DisplayFlipAnchor: Equatable, Sendable {
    /// The primary display's height in mac points. Not the union's height; see this type's
    /// own doc comment, `WindowGeometry.swift:61-74`, and ADR §4.
    public let primaryHeightInPoints: Double

    /// Remote pixels per mac point -- the topology's `rasterScale` (ADR §2 rule 2).
    /// 1 in every configuration that exists today.
    public let remotePixelsPerPoint: Double

    /// Internal on purpose. See the type's doc comment: this is half the mechanism.
    init(primaryHeightInPoints: Double, remotePixelsPerPoint: Double) {
        self.primaryHeightInPoints = primaryHeightInPoints
        self.remotePixelsPerPoint = remotePixelsPerPoint
    }
}

/// The seam between "who knows what the screens are" and "who does geometry with them".
///
/// Declared here, in the pure package, rather than alongside the AppKit collector, so that the
/// App and `Tools/window-smoke` code against an interface instead of against a concrete
/// `NSScreen` reader -- and so that anything that needs a topology can be exercised under
/// `swift test` with `StaticDisplayTopologyProvider` and no display attached, which
/// `Package.swift:21-24` requires of everything in this target.
///
/// `@MainActor` is a real constraint, not decoration: ADR §5.A.5 confines every `NSScreen` read
/// in the project to the single production conformer, which also observes
/// `NSApplicationDidChangeScreenParameters` -- both main-thread affairs -- and the registry that
/// consumes the result is main-actor already. Isolating the protocol means a conformer cannot
/// accidentally publish a screen list read off the main thread.
///
/// A provider returns `nil` for the same reason `DisplayTopology.init(displays:)` is failable:
/// "no usable display" is a state that genuinely occurs (headless, all displays asleep) and
/// that `RemoteWindowRegistry.swift:983-995` already handles by declining to position windows.
/// ADR §5.A.6 adds the hard part -- in that state the desktop size must not be sent at all,
/// never as `0 x 0`.
///
/// Note what this protocol deliberately does NOT promise: that the value it returns is the one
/// the current session is using. ADR §5.A freezes the session's snapshot at connect time and
/// keeps the observer alive for the whole App lifetime precisely so that "the live layout" and
/// "the layout this session negotiated" can differ and be seen to differ. Consumers doing
/// geometry for a live session must use the session's frozen snapshot, not re-read this.
@MainActor
public protocol DisplayTopologyProviding {
    /// The current display layout, or `nil` when there is no usable one.
    var currentTopology: DisplayTopology? { get }
}

/// The injectable default: a provider that returns whatever topology it was constructed with,
/// forever.
///
/// Two jobs. In tests it is the whole point of the protocol existing -- geometry code becomes
/// runnable with a fixture layout and no display. In production it is the honest stand-in for
/// a not-yet-wired call site: a lane that needs a provider before the AppKit collector exists
/// injects one of these with an explicit topology, which is inspectable and obviously fixed,
/// rather than falling back to a hidden global default that looks live and is not.
///
/// Immutable by construction (`let`, value type, no shared instance) -- M1's lane rule against
/// a mutable or global topology applies to the provider as much as to the value. It is also
/// exactly the right shape for ADR §5.A's frozen session snapshot: wrapping the connect-time
/// topology in one of these gives a session a provider that cannot drift.
public struct StaticDisplayTopologyProvider: DisplayTopologyProviding {
    public let currentTopology: DisplayTopology?

    /// - Parameter topology: the layout to report. Passing `nil` models "no usable display",
    ///   which is what makes the headless branch testable.
    public init(_ topology: DisplayTopology?) {
        self.currentTopology = topology
    }
}
