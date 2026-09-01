import Foundation

/// A window rectangle in Windows screen-space coordinates: origin at the top-left of the
/// (virtual) desktop, Y increasing downward. `x`/`y` may be negative for monitors placed
/// left of or above the primary monitor in a multi-monitor layout.
///
/// UNIT (M1/W1, phase3.md §1 F1): **remote pixels** -- the RDP wire's own unit, what RAIL
/// window orders and GFX surface maps count in. Not mac points. On every configuration that
/// exists today the two are numerically identical (we advertise no `DesktopScaleFactor`, so
/// the server's pixel grid is our point grid -- see `DisplayScale.remotePixelsPerPoint`),
/// which is exactly why the distinction had to be made in the type system before it could be
/// made anywhere else.
public struct WindowsRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A window rectangle in macOS screen-space coordinates: origin at the bottom-left of the
/// primary screen, Y increasing upward — the convention `NSScreen`/`NSWindow`/`CGRect`
/// already use on macOS.
///
/// UNIT (M1/W1): **mac points**, never backing pixels. Backing pixels are the third space
/// phase3.md §1 F1 names and the one this milestone deliberately does not enter -- see
/// `DisplayScale.backingPixelsPerPoint`, recorded and unapplied.
public struct MacRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A single point in Windows screen-space coordinates (top-left origin, Y down) — same
/// convention as `WindowsRect`.
public struct WindowsPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A single point in macOS screen-space coordinates (bottom-left origin, Y up) — same
/// convention as `MacRect`.
public struct MacPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Pure-function conversion between Windows and macOS screen-space rectangles.
///
/// Both coordinate systems agree on the X axis (rightward) and on rectangle width/height;
/// the only thing that differs is the Y axis's direction and origin. Windows' virtual
/// desktop origin is the *primary* monitor's top-left corner (Y down); macOS' global
/// origin is the *primary* screen's bottom-left corner (Y up). Anchoring the flip on
/// `primaryMonitorHeight` — the primary monitor's height, not the bounding height of the
/// whole (possibly multi-monitor) virtual desktop — is what keeps both systems agreeing
/// on where that shared origin corner actually is; anchoring on any other height would
/// shift the primary monitor itself away from y=0 in one of the two coordinate spaces.
/// This type deliberately does not know how to compute that height itself — resolving
/// actual screen topology is an AppKit/CoreGraphics concern that lives above this
/// package's no-AppKit boundary (adr/0006 §2); `WindowGeometry` only does the arithmetic
/// once a caller has that number in hand.
///
/// M1/W1 UPDATE (`docs/plans/phase3.md:109`, §1 F1). The four conversions no longer take a
/// bare `primaryMonitorHeight: Double`; they take a `DisplayFlipAnchor` obtained from a
/// `DisplayTopology`, or the topology itself. Two things changed and it is worth being
/// precise about which:
///
///  1. **The anchor became un-mistakable, through the topology-taking API.** Everything the
///     paragraph above argues is still exactly true; what changed is that a topology value
///     puts a *union* height within reach for the first time, so the argument needed to stop
///     being an argument. ADR §4.A.1/§4.A.2 require two mechanisms and both are in place:
///     `DisplayFlipAnchor` has no public initializer, so the height inside it can only have
///     come from `DisplayTopology.primary.size.height`; and
///     `DisplayTopology.unionBoundsInPoints` vends `DesktopUnionBoundsInPoints.Scalar`, not
///     `Double`, so a union height cannot be handed to anything that takes a length.
///     **Scope of that claim, stated precisely because r1 review found the wave-1 version of it
///     over-stated:** it held only for this API while the deprecated `primaryMonitorHeight:`
///     shims still accepted a bare `Double` -- they had to, or un-migrated call sites would not
///     compile, and they were therefore the one remaining door. **Wave 3 (L9) deleted them**
///     once the last call site migrated (see the MARK below), so the claim is now unqualified:
///     no entry point in this file takes a primary-display height. (Precise wording matters in this
///     file: `MacRect`/`WindowsRect` obviously still take a `height` -- what no longer exists is a
///     way to supply the Y-flip ANCHOR as a bare `Double`.)
///  2. **A scale dimension appeared.** `DisplayFlipAnchor.remotePixelsPerPoint` -- the
///     topology's `rasterScale`, i.e. the primary display's ratio (ADR §2 rule 2) -- divides on
///     the way in and multiplies on the way out, which is what makes `WindowsRect` (remote
///     pixels) and `MacRect` (mac points) genuinely different units rather than the same
///     `Double` twice. It is **1** in every configuration that exists today -- we advertise no
///     `DesktopScaleFactor` (F3, ADR §0c) -- so this is not a behavior change; at scale 1 the
///     expressions below are literally the old ones. The 2x fixtures in
///     `WindowGeometryTests` are offline coverage for the path W3 will eventually turn on,
///     not a claim that anything measures 2x today (`docs/plans/phase3.md:219`, §8.5).
///
/// The pre-M1 `primaryMonitorHeight:` entry points survived as deprecated shims at the bottom of
/// this file for waves 1-2 and were deleted in wave 3; the MARK there records why they existed
/// and why nothing of that shape may come back.
public enum WindowGeometry {
    // MARK: - The four conversions (M1/W1 signatures)
    //
    // ADR §9's L2 row says the new entries take "only the topology". Each conversion has two:
    // `in topology:` and `anchoredTo anchor:`. That is conformant, and the reason is worth one
    // note so a later conformance pass does not re-open it (r2 review N-4b). §4.A.1 states two
    // literal prohibitions -- no bare-`Double` height overload, and no `unionBounds` overload --
    // and both hold: a `DisplayFlipAnchor` is obtainable only from a `DisplayTopology`
    // (its initializer is internal), so `anchoredTo:` cannot express a scale or a height the
    // topology did not produce. The form existed originally because the (now deleted) deprecated
    // shims had to forward into something; it stays because it is what lets a caller -- and the
    // tests -- build one anchor per case instead of re-deriving it per conversion.

    /// Converts a Windows-space rect (remote pixels) to macOS-space (points), anchored on the
    /// topology's primary display.
    public static func macRect(from windowsRect: WindowsRect, in topology: DisplayTopology) -> MacRect {
        macRect(from: windowsRect, anchoredTo: topology.flipAnchor)
    }

    /// Converts a Windows-space rect (remote pixels) to macOS-space (points).
    ///
    /// The Y term is written as `primaryHeight - y/s - height/s` rather than the algebraically
    /// equal `primaryHeight - (y + height)/s` so that at `s == 1` it is character-for-character
    /// the pre-M1 expression: this conversion is on the live window-placement path, and "the
    /// arithmetic is provably unchanged where nothing is scaled" is worth more than one saved
    /// division.
    public static func macRect(from windowsRect: WindowsRect, anchoredTo anchor: DisplayFlipAnchor) -> MacRect {
        let scale = anchor.remotePixelsPerPoint
        return MacRect(
            x: windowsRect.x / scale,
            y: anchor.primaryHeightInPoints - windowsRect.y / scale - windowsRect.height / scale,
            width: windowsRect.width / scale,
            height: windowsRect.height / scale
        )
    }

    /// Converts a macOS-space rect (points) back to Windows-space (remote pixels), anchored on
    /// the topology's primary display.
    public static func windowsRect(from macRect: MacRect, in topology: DisplayTopology) -> WindowsRect {
        windowsRect(from: macRect, anchoredTo: topology.flipAnchor)
    }

    /// Converts a macOS-space rect (points) back to Windows-space (remote pixels), given the
    /// same anchor used to produce it. This is the exact inverse of
    /// `macRect(from:anchoredTo:)` — round-tripping through both directions with the same
    /// anchor returns the original rect.
    ///
    /// "Exact" is meant literally and is tested as such
    /// (`WindowGeometryTests.rectRoundTripIsIdentityAcrossScalesAndOffsets`). It holds for the
    /// documented fixture range -- integer-valued remote pixels at `remotePixelsPerPoint ∈
    /// {1, 2}` -- because both factors are powers of two, so every division and multiplication
    /// here is exact in binary floating point and nothing accumulates. A future non-power-of-two
    /// scale would need that claim re-examined rather than assumed; there is no such scale today.
    public static func windowsRect(from macRect: MacRect, anchoredTo anchor: DisplayFlipAnchor) -> WindowsRect {
        let scale = anchor.remotePixelsPerPoint
        return WindowsRect(
            x: macRect.x * scale,
            y: (anchor.primaryHeightInPoints - macRect.y - macRect.height) * scale,
            width: macRect.width * scale,
            height: macRect.height * scale
        )
    }

    /// W4c: converts a single point — e.g. a mouse click's location, already resolved to
    /// this Mac's global screen space (a window's own frame origin plus an AppKit event's
    /// `locationInWindow`, which `NSEvent` itself always reports bottom-left-origin/Y-up
    /// regardless of whether the receiving view opts into `isFlipped`) — into the
    /// corresponding Windows-space absolute desktop coordinate a RAIL mouse input PDU
    /// needs. Same Y-flip as `windowsRect(from:anchoredTo:)`, but without that
    /// function's `- height` term: a bare point has no height to anchor against, only the
    /// rect case needs to map a rect's *top* edge (Windows convention) onto mac's
    /// bottom-anchored origin.
    public static func windowsPoint(from macPoint: MacPoint, anchoredTo anchor: DisplayFlipAnchor) -> WindowsPoint {
        let scale = anchor.remotePixelsPerPoint
        return WindowsPoint(
            x: macPoint.x * scale,
            y: (anchor.primaryHeightInPoints - macPoint.y) * scale
        )
    }

    /// W4c point transform, anchored on the topology's primary display.
    public static func windowsPoint(from macPoint: MacPoint, in topology: DisplayTopology) -> WindowsPoint {
        windowsPoint(from: macPoint, anchoredTo: topology.flipAnchor)
    }

    /// The exact inverse of `windowsPoint(from:anchoredTo:)` — not needed by any
    /// current caller (RAIL only ever tells this project window *rectangles*, never bare
    /// points, on the inbound side), provided for symmetry and because it's what makes the
    /// round-trip identity actually testable in both directions.
    public static func macPoint(from windowsPoint: WindowsPoint, anchoredTo anchor: DisplayFlipAnchor) -> MacPoint {
        let scale = anchor.remotePixelsPerPoint
        return MacPoint(
            x: windowsPoint.x / scale,
            y: anchor.primaryHeightInPoints - windowsPoint.y / scale
        )
    }

    /// The exact inverse of `windowsPoint(from:in:)`, anchored on the topology's primary
    /// display.
    public static func macPoint(from windowsPoint: WindowsPoint, in topology: DisplayTopology) -> MacPoint {
        macPoint(from: windowsPoint, anchoredTo: topology.flipAnchor)
    }
}

// MARK: - Pre-M1 signatures: DELETED in M1 wave 3 (L9)
//
// Four `primaryMonitorHeight: Double` entry points lived here, `@available(*, deprecated)`, from
// wave 1 until wave 3. They existed only so the tree kept building across the wave boundary: the
// `window-smoke` target compiles `RemoteWindowRendering` too (`App/project.yml:395-397`), so
// removing the bare-`Double` entries in wave 1 would have broken wave 2's full-build gate with an
// error no wave-2 lane owned a file to fix. ADR-0015 §9's L9 row assigned the deletion to the lane
// that migrated the last call site (`Tools/window-smoke/main.swift`'s `evaluateMoveResizeLeg`),
// and this is that deletion; a repo-wide grep over `App/`, `Packages/`, `Tools/` and `Scripts/`
// found no remaining caller first.
//
// The point of recording it here rather than deleting silently: with the shims gone, **there is
// no longer any way in this package to reach the Y flip with a bare length**. `DisplayFlipAnchor`
// has no public initializer and `DisplayTopology.unionBoundsInPoints` vends `Scalar`, not
// `Double`, so ADR §4.A.1/§4.A.2's two mechanisms now hold without the exception the header above
// used to have to state. Nothing bare-`Double`-taking may be added back: that would reopen the
// door on purpose, and the migration target is always `…(in: topology)`.

/// Phase 2 W3 round 3 (2026-08-23, real-host regression, team-lead review): a signed,
/// per-window correction between RAIL's own reported `WINDOW_ORDER_FIELD_WND_SIZE`
/// (`windowWidth`/`windowHeight`) and what this window's content view actually DISPLAYS
/// (the GFX `MapSurfaceToWindow` order's `mappedWidth`/`mappedHeight` -- definitionally the
/// displayed size, since `RemoteWindow.present`'s `contentsRect` crop already targets it).
///
/// Real-host evidence (About window, this fix's own origin): raw RAIL
/// `offsetX=338 offsetY=62 windowWidth=494 windowHeight=500` against a GFX-mapped visible
/// size of `508x507` -- `width`/`height` below are `mapped - RAIL`, so `(+14, +7)` for this
/// window: the displayed content is LARGER than what RAIL calls this window's own size, not
/// smaller (the earlier, inverted assumption -- "RAIL is the outer rect, visible content is
/// inset from it" -- doubled the round-trip error instead of cancelling it once real wire
/// data was actually checked).
///
/// `originX`/`originY` are ZERO in this correction, deliberately, not merely "not yet
/// measured": `RDPGFX_MAP_SURFACE_TO_WINDOW_PDU` (`CRSession.mm`'s own
/// `crb_gfx_map_surface_to_window`) carries ONLY `mappedWidth`/`mappedHeight` -- no
/// position field exists on that PDU to derive an origin delta from at all, and RAIL's own
/// `offsetX`/`offsetY` (`WINDOW_ORDER_FIELD_WND_OFFSET`) is the only position signal this
/// client ever receives for a window, so there is no independent second measurement to
/// diff it against the way `mappedWidth`/`mappedHeight` diffs against `windowWidth`/
/// `windowHeight`. Modeling it as an unconditionally-zero field of a general 4-component
/// correction (rather than omitting origin correction from the type entirely) keeps this a
/// documented, deliberate "no evidence for a nonzero value" finding rather than a silent
/// structural absence -- flagged for W4's shaped-window work to revisit if a future PDU or
/// sample ever supplies an independent position measurement to correct against.
///
/// UNIT (M1/W1 tagging pass; U5 ruling = record-only): all four components are **remote
/// pixels**. Both quantities they are derived from are wire values in remote pixels -- RAIL's
/// `windowWidth`/`windowHeight` and GFX's `mappedWidth`/`mappedHeight` -- so this correction
/// composes with `displayRect`/`railRect` entirely inside Windows space, BEFORE any Y flip or
/// point conversion, and carries no scale dimension of its own. W3 TRIGGER: if a session ever
/// runs with `DisplayScale.remotePixelsPerPoint != 1`, re-measure -- these numbers came off a
/// 1x host (`docs/plans/phase3.md:219`) and nothing establishes that a window-manager border
/// delta scales linearly with DPI. No value changes in M1 (§3 item 5: this batch moves units
/// only; the values wait for W3's real-host data).
public struct WindowGeometryCorrection: Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public static let zero = WindowGeometryCorrection(originX: 0, originY: 0, width: 0, height: 0)
}

extension WindowGeometry {
    /// Applies `correction` to `railRect` (RAIL's own reported Windows-space rect),
    /// producing the rect that should actually be displayed -- the inbound direction.
    /// `RemoteWindowRegistry.macContentRect(for:windowId:)` calls this before the existing
    /// `macRect(from:anchoredTo:)` conversion, so the two corrections (RAIL-size
    /// vs display-size, then Windows-space vs mac-space) compose rather than duplicate each
    /// other's job. Both input and output are remote pixels (see
    /// `WindowGeometryCorrection`'s unit note); the point conversion happens strictly after.
    public static func displayRect(from railRect: WindowsRect, correction: WindowGeometryCorrection) -> WindowsRect {
        WindowsRect(
            x: railRect.x + correction.originX, y: railRect.y + correction.originY,
            width: railRect.width + correction.width, height: railRect.height + correction.height
        )
    }

    /// The exact inverse of `displayRect(from:correction:)` -- the outbound direction.
    /// `RemoteWindowRegistry.handleLocalGeometrySettled` calls this after
    /// `windowsRect(from:anchoredTo:)`, before turning the result into the
    /// `left`/`top`/`right`/`bottom` `ClientWindowMove` sends. Round-tripping any
    /// `WindowsRect` through `displayRect(from:correction:)` then this function, with the
    /// SAME `correction`, is always the identity — verified by
    /// `WindowGeometryTests.railDisplayRoundTripIsIdentity` using this fix's own real-host
    /// numbers, a property that holds regardless of what `correction`'s actual values turn
    /// out to be (including the current all-zero-origin one), so no future edit to either
    /// function can silently reintroduce a sign mismatch between the two directions without
    /// that test catching it.
    public static func railRect(from displayRect: WindowsRect, correction: WindowGeometryCorrection) -> WindowsRect {
        WindowsRect(
            x: displayRect.x - correction.originX, y: displayRect.y - correction.originY,
            width: displayRect.width - correction.width, height: displayRect.height - correction.height
        )
    }

    /// Team-lead review round 5 (2026-08-23, real-host evidence: THREE separate runs each
    /// sent `left=331` and received `338` in the immediate next `WindowUpdate`, a clean +7
    /// every time). Deliberately NOT a `WindowGeometryCorrection.originX` applied through
    /// `displayRect`/`railRect` above, even though that was the team lead's own first
    /// proposal -- worked through here because the sign/placement matters and a wrong one
    /// has already cost two prior rounds.
    ///
    /// THE ALGEBRA: let `V` be the true visible-space X target (this round: 331), `B` the
    /// measured left-border amount (7). The evidence's own causal chain (self-consistent,
    /// verified against the actual send/echo pair, not merely asserted):
    /// 1. We sent `left = V` (331) UNCORRECTED. The server received it and set its window's
    ///    OUTER rect's left to exactly that: `outer_left = 331`.
    /// 2. The server's window has an invisible LEFT border of width `B`: the VISIBLE content
    ///    sits INSET from the outer edge by `B`, i.e. `visible_left = outer_left + B`.
    /// 3. `WindowUpdate.offsetX` reports `visible_left` directly (no further correction --
    ///    this is the "inbound already correct" half of the finding, unchanged by this fix).
    /// 4. `visible_left = 331 + 7 = 338` -- exactly the observed echo. Self-consistent.
    ///
    /// Solving forward (what SHOULD be sent so the resulting visible_left lands on `V`, not
    /// `V+B`): `V = outer_left_to_send + B` => `outer_left_to_send = V - B`. This function
    /// is exactly that subtraction.
    ///
    /// WHY NOT fold this into `WindowGeometryCorrection.originX` (the team lead's literal
    /// instruction): `displayRect`/`railRect` apply the SAME correction symmetrically both
    /// directions. Setting `originX` nonzero to fix outbound would ALSO shift every INBOUND
    /// `WindowUpdate.offsetX` read by the same amount (`displayRect.x = railRect.x +
    /// originX`) -- but step 3 above is exactly the evidence that inbound needs NO
    /// correction at all. Applying it symmetrically would fix the send and simultaneously
    /// break every subsequent read by re-introducing the same error in the opposite
    /// direction. Verified by direct substitution before writing this function, not assumed
    /// -- see `WindowGeometryTests.clientWindowMoveLeftAppliesTheMeasuredBorder` for the
    /// worked check that this specific (asymmetric, outbound-only) shape is what actually
    /// reconciles both the send and the read against the real numbers.
    ///
    /// SCOPE, deliberately narrow: only X/`left` has three consistent real-host
    /// measurements. Y was never actually tested this round (a separate AppKit frame-clamp
    /// bug meant Y never genuinely moved at all -- see `RemoteWindow`'s own real-host
    /// regression notes on the harness fix), so no analogous Y adjustment is applied here;
    /// `top`/`bottom` stay exactly as `railRect(from:correction:)` computes them. Also
    /// deliberately does NOT touch width/right: the measured value happens to equal half of
    /// this window's own separately-measured `sizeCorrection.width` (14/2=7), but that could
    /// be numerical coincidence for this one window's border -- extrapolating a matching
    /// "right also needs +7" adjustment would assume a symmetric-border model that actually
    /// CONTRADICTS the already-validated size correction's own sign (`mapped > RAIL` for
    /// width, the opposite direction a left+right-inflating border would imply for an
    /// "outer" rect) -- left uncorrected pending real evidence, not silently assumed either
    /// way.
    ///
    /// UNIT (M1/W1 tagging pass; U5 ruling = record-only): both parameters and the result are
    /// **remote pixels**, in Windows space -- this subtraction happens after
    /// `railRect(from:correction:)` and before the `left`/`top`/`right`/`bottom` integers go
    /// on the wire, so no point conversion or Y flip is involved and no scale applies. The 7
    /// this is called with lives at its own call site
    /// (`RemoteWindowRegistry.swift:1818-1820`, F6(a)); M1 changes neither that value nor this
    /// function's arithmetic. W3 TRIGGER: re-measure the border on a session where
    /// `DisplayScale.remotePixelsPerPoint != 1`. A window-manager border is plausibly a
    /// DPI-dependent quantity, and all three real-host measurements behind the 7 were taken on
    /// the same 1x host (`docs/plans/phase3.md:219`), so "7 remote pixels" and "7 points"
    /// are indistinguishable in the existing evidence -- which is exactly why the value is
    /// recorded rather than migrated (§3 item 5, §8.5: no 2x measurement exists yet).
    public static func clientWindowMoveLeft(fromVisibleLeft visibleLeft: Double, measuredLeftBorder: Double) -> Double {
        visibleLeft - measuredLeftBorder
    }
}
