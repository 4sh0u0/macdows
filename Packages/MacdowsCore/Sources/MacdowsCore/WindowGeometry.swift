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
/// point conversion, and carries no scale dimension of its own. W3 TRIGGER, half fired: the
/// values were measured on a 1x host (`docs/plans/phase3.md:219`), and nothing in that data
/// established whether a window-manager border delta scales with DPI. F round 3 (2026-09-06,
/// a 2x session -- `docs/upgrade-gate/2026-09-f-live.md` §2b) gives the first 2x point: the
/// WS_THICKFRAME resize leg reported width 1184 for a sent 1194, the same -10 delta as at 1x
/// (dh -4 vs -5 is the F1 odd-dimension rounding). The record draws its "remote pixels, not
/// DPI-scaled" conclusion from the move leg (5 px deducted, dx=0); this comment reads the
/// unchanged -10 the same way -- an inference consistent with that conclusion, n=1, THICKFRAME
/// only. No About-class window has been measured at 2x; that half of the trigger is still
/// outstanding. No value changes here (M1 §3 item 5 moved units only).
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
    /// on the wire, so no point conversion or Y flip is involved and no scale applies.
    ///
    /// WHAT `measuredLeftBorder` IS CALLED WITH, since the 2026-09-05 per-style lane (acting on
    /// F-R1, found 2026-09-02): not a single constant any more. `clientWindowMoveLeftBorder(forStyle:)` below picks between two
    /// measured values from the window's own Win32 style bits, and
    /// `RemoteWindowRegistry.handleLocalGeometrySettled` -- the only production caller -- calls
    /// this function with that result. This function itself is unchanged by that lane: it was
    /// always "subtract whatever border you measured", and the algebra above holds for either
    /// value (substitute B = 5 or B = 7; nothing in steps 1-3 depends on which -- step 4 is the
    /// About instance, `331 + 7 = 338`).
    ///
    /// THE DPI QUESTION IS HALF ANSWERED. F-R1 did not touch it: every 1x measurement behind
    /// both values came off the same host (`docs/plans/phase3.md:219`), where "5/7 remote
    /// pixels" and "5/7 points" are indistinguishable. F round 3 (2026-09-06, a 2x session --
    /// `docs/upgrade-gate/2026-09-f-live.md` §2b) answered it for WS_THICKFRAME: deducting
    /// 5 REMOTE PIXELS (2.5 pt at `remotePixelsPerPoint == 2`) gave dx=0 on the move leg, so
    /// the 5 is a remote-pixel quantity that does not scale with DPI (n=1). The About-class 7
    /// has NOT been measured at 2x; re-measuring an About-class window on a 2x session is the
    /// half of the trigger still outstanding (§3 item 5, §8.5). What F-R1 changed is the
    /// *other* variable: the border was found to move with the window STYLE on a fixed DPI,
    /// which is why the value is now a function rather than a recorded constant.
    ///
    /// THE "DOES NOT TOUCH WIDTH/RIGHT" PARAGRAPH ABOVE IS SUPERSEDED (adr/0018 §5.2 增补五).
    /// It is left standing as the record of what the evidence supported at the time -- "no
    /// matching evidence, and a symmetric guess would contradict the size correction's sign" was
    /// an accurate reading of the 2026-08 data. Host-side `GetWindowRect` /
    /// `DWMWA_EXTENDED_FRAME_BOUNDS` pairs supplied the missing measurement, ONE ROW PER CELL
    /// of the table below (n=1 per cell; only the `WS_THICKFRAME` @96 cell has a second source
    /// -- see `clientWindowMoveRect`'s own comment for the rows), and the right/bottom outset
    /// now lives in
    /// `clientWindowMoveRect(fromVisibleRect:measuredBorder:)`, which delegates its LEFT edge to
    /// this function unchanged. THIS function still does exactly one subtraction, on one edge.
    public static func clientWindowMoveLeft(fromVisibleLeft visibleLeft: Double, measuredLeftBorder: Double) -> Double {
        visibleLeft - measuredLeftBorder
    }

    /// The four edges of one `ClientWindowMove`, in Windows space -- the shape
    /// `clientWindowMoveRect(fromVisibleRect:measuredBorder:)` returns.
    ///
    /// A named type rather than a tuple because the caller narrows all four to `Int32` and
    /// hands them to a RECT-shaped wire call (`CRSession.sendWindowMove`), where two `Double`s
    /// of the same magnitude are exactly the kind of thing that gets swapped; and because
    /// `left`/`right` are edge COORDINATES, not an origin plus a size -- the distinction
    /// `WindowsRect` cannot make and that this whole finding turns on.
    ///
    /// UNIT: **remote pixels**, the same domain `WindowsRect` is in.
    public struct ClientWindowMoveRect: Equatable, Sendable {
        public var left: Double
        public var top: Double
        public var right: Double
        public var bottom: Double

        public init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    /// The whole outbound rect, from the window's VISIBLE (extended-frame, "ef") rect: the sent
    /// rect is the visible rect OUTSET by `(B, 0, B, B)` -- adr/0018 §5.2 增补五.
    ///
    /// WHAT THIS CORRECTS, and the evidence for it. `clientWindowMoveLeft` above has always
    /// deducted `B` from the left edge alone, on its own three-run send/echo evidence; the doc
    /// comment there states, in the paragraph beginning "Also deliberately does NOT touch
    /// width/right", that no matching evidence existed for the right edge and that a symmetric
    /// guess would contradict the size correction's sign. **That paragraph is now out of date on
    /// the facts** (it is kept where it stands as the record of what was known then): the
    /// 2026-09-21 `winsize` tracking batch read the host's own `GetWindowRect` (wr) and
    /// `DWMWA_EXTENDED_FRAME_BOUNDS` (ef) for the same window in the same tick and
    /// differenced them edge by edge -- ONE PROBE ROW PER CELL, **n=1 per cell**, from batch
    /// `winsize-20260921` (docs record §3.6): About `(7,0,7,7)` @96 (`wr=115,102,737,616`
    /// `ef=122,102,730,609`) and `(11,0,11,11)` @192 (`wr=41,0,1291,918` `ef=52,0,1280,907`);
    /// `WS_THICKFRAME` `(5,0,5,5)` @96 (`wr=147,30,1151,745` `ef=152,30,1146,740`) and
    /// `(10,0,10,10)` @192 (`wr=1,1,1279,689` `ef=11,1,1269,679`). ONLY the THICKFRAME @96 cell
    /// has a second, independent source -- the 2026-09-15 host-rect-keep record's own row for
    /// that class (`wr=198,30,1198,743` `ef=203,30,1193,738`, the same `(5,0,5,5)`); the other
    /// three cells stand on one row each, which is what "n=1 per cell" means here.
    ///
    /// THE RIGHT AND BOTTOM MEMBERS ARE BEING CONSUMED FOR THE FIRST TIME. Every earlier use of
    /// this frame read its LEFT member only (which additionally carries the send/echo evidence
    /// behind `clientWindowMoveLeft` -- three 2026-08-23 runs, F-R1's nine, C-2 run 4), and the
    /// border table's own doc comments say in as many words that nothing consumed right/bottom.
    /// This function is that first consumer, at n=1 per cell.
    ///
    /// A `ClientWindowMove` is landed by the server as the WR rect, so the
    /// rect to send for a target visible rect is that visible rect outset by the same frame.
    /// The "contradicts the size correction's sign" objection does not apply to this shape: the
    /// outset is applied to `railRect(from:correction:)`'s OUTPUT (already back at ef size), not
    /// to the correction, so the two compose rather than duplicate -- exactly the relationship
    /// `displayRect`/`railRect` have inbound vs outbound.
    ///
    /// WHY IT MATTERED IN PRODUCTION (the same batch's D2, 14/14 legs including its 1x
    /// controls): sending the ef WIDTH in the wr slot made the server land a window whose ef
    /// rect was `(2B, B)` SMALLER than the one the user had just dragged, with `x` conserved --
    /// i.e. every move leg shrank the window by one frame. With this outset the sent wr and the
    /// server's landed ef agree, so a pure move sends back exactly the size it was given.
    ///
    /// THE TOP EDGE IS NOT OUTSET, and that is a reading rather than an omission: the frame's
    /// top member measured **0** in every model this project has read (n=9 on the THICKFRAME
    /// side via the F-R1 counter, n=1 on the About side via C-2 run 4's `(7,0,7,7)`, and both
    /// 2026-09-15 host-rect batches at both tiers). It is also why this function still applies
    /// no `K` (the client-area inset of the same ADR table, whose Y component is nonzero on the
    /// About row): `K` has a different consumer and wiring it here would change 1x Y behaviour.
    ///
    /// `left` IS DELEGATED, not recomputed -- every measurement behind `clientWindowMoveLeft`
    /// and behind the border table keeps applying byte for byte, which is what makes "1x `left`
    /// and `top` are unchanged by this lane" a checkable claim rather than an intention.
    ///
    /// 1x IS **NOT** BYTE-IDENTICAL OVERALL, and saying so is part of the finding. The claim in
    /// the paragraph above is scoped to `left`/`top` on purpose: `right` and `bottom` DO move at
    /// 1x, deliberately, by +B each -- the wire width grows by 2B (About +14, `WS_THICKFRAME`
    /// +10) and the wire height by B (+7 / +5). Seven pre-lane 1x pins state the old values and
    /// are updated by this lane, one by one, declared in its gate (adr/0018 §5.2 增补五). What
    /// IS byte-identical at 1x is rule R (tolerance 0) and the two axes above.
    ///
    /// `measuredBorder` IS THE SAME `B` the left edge already used:
    /// `clientWindowMoveLeftBorder(forStyle:tier:)`'s four-cell lookup. This function takes it
    /// as a parameter for the same reason `clientWindowMoveLeft` does -- the table is keyed on
    /// the window's style and on what the session advertised, neither of which this package can
    /// see -- so the one production call site derives it once and passes it in.
    ///
    /// UNIT: **remote pixels** in, remote pixels out. No Y flip and no point conversion happen
    /// here; both are already done by the time this is called.
    public static func clientWindowMoveRect(
        fromVisibleRect visible: WindowsRect, measuredBorder border: Double
    ) -> ClientWindowMoveRect {
        ClientWindowMoveRect(
            left: clientWindowMoveLeft(fromVisibleLeft: visible.x, measuredLeftBorder: border),
            top: visible.y,
            right: visible.x + visible.width + border,
            bottom: visible.y + visible.height + border
        )
    }

    /// RULE R (adr/0018 §5.2 增补五): one settled dimension, reported back as the server's own
    /// last reported value when the two differ by no more than `rasterScale - 1` remote pixels.
    ///
    /// THE ARTEFACT IT EXISTS FOR. On a 2x session the same batch recorded an About-class window
    /// whose RAIL `WINDOW_ORDER_FIELD_WND_SIZE` height was **917** remote px settling locally at
    /// **918**: 917 / 2 = 458.5 mac points, and the local frame does not keep the half point, so
    /// converting back multiplies a rounded 459 by 2. Without this rule a pure MOVE would send a
    /// height one pixel different from the one the server reported, i.e. would ask for a resize
    /// nobody performed.
    ///
    /// THE TOLERANCE IS `rasterScale - 1`, NOT `rasterScale`. One lost half point is worth
    /// `rasterScale / 2` remote px, so the largest artefact at 2x is 1 px and the largest
    /// genuine step a user can express is also the smallest nonzero one -- the two are
    /// distinguishable only up to this bound, and the bound is chosen so that **at 1x it is
    /// zero**: `1 - 1 == 0`, so no 1x session ever snaps and THIS RULE changes no 1x byte. That
    /// claim is about this rule and nothing else -- the same lane's outset does deliberately
    /// move 1x `right`/`bottom` by B (see `clientWindowMoveRect`). A tolerance of `rasterScale`
    /// would swallow a real 1 px resize at 1x, which is the mutation
    /// `ruleRSnapsOnlyWithinTolerance`'s 1x row exists to catch.
    ///
    /// `lastReported <= 0` NEVER SNAPS. `RemoteWindowRegistry.PendingWindowState.width/height`
    /// are 0 for a window whose orders never carried the size field, and snapping to 0 would ask
    /// the server to collapse the window -- the same fail-closed instinct the border table
    /// follows for `style == 0`: never act on a value nobody reported.
    ///
    /// A NON-FINITE OR SUB-UNIT `rasterScale` IS TOLERANCE 0, for the same reason: NaN compares
    /// false against everything, so an unguarded `abs(...) <= rasterScale - 1` would silently
    /// never snap, and a scale below 1 would produce a NEGATIVE tolerance whose behaviour reads
    /// as an accident rather than as a decision. Both are written down as "no snap" instead.
    ///
    /// WHAT IT CANNOT SEE, registered rather than papered over: this seam compares a settled
    /// dimension against the last dimension the server reported, and cannot tell "the user moved
    /// the window and AppKit lost a half point" from "the server resized the window by 1 px and
    /// this client has not applied it yet". Both are within tolerance and both resolve to the
    /// server's value -- which is the harmless direction for the second case (the client is
    /// agreeing with the server about a size the server itself chose) and the correct one for
    /// the first. A leg that resizes by more than the tolerance is never affected.
    ///
    /// AND A THIRD CASE, WHICH IS A REAL COST RATHER THAN AN AMBIGUITY: on a 2x session a
    /// GENUINE 1-remote-pixel resize is absorbed by this rule. It is representable there --
    /// `rasterScale == 2` means a 2x backing store, NSWindow frames align to that grid, so a
    /// 0.5 pt step (= 1 remote px) is a frame a user or a programmatic resize can actually land
    /// on -- and it is exactly the magnitude the artefact occupies, so the two are not
    /// separable by this seam at all. Accepted as a known cost per adr/0018 §5.2 增补五; the
    /// alternative on the table (snap only when the settled size equals the last APPLIED size)
    /// needs a state field this lane does not add. `ruleRSnapsOnlyWithinTolerance`'s S1 row is
    /// the pin for precisely this input -- it reads as "the artefact is absorbed", and it is the
    /// same input a genuine one-pixel 2x resize would present.
    ///
    /// UNIT: **remote pixels** for `local` and `lastReported`; `rasterScale` is remote pixels
    /// per mac point (`DisplayTopology.rasterScale`), and appears here only as the width of the
    /// rounding artefact it can produce.
    public static func snapToLastReportedDimension(
        local: Double, lastReported: Double, rasterScale: Double
    ) -> Double {
        guard lastReported > 0 else { return local }
        let tolerance = (rasterScale.isFinite && rasterScale >= 1) ? rasterScale - 1 : 0
        return abs(local - lastReported) <= tolerance ? lastReported : local
    }

    /// Rule R applied to a whole visible rect: each axis decided on its own by
    /// `snapToLastReportedDimension`, the origin untouched.
    ///
    /// Two axes, two independent decisions -- a leg that genuinely resized the width while the
    /// height only lost a half point keeps the real width change and snaps only the height.
    ///
    /// The ORIGIN is never snapped. Rule R is about the size the server reported
    /// (`WINDOW_ORDER_FIELD_WND_SIZE`); the position a user just dragged to is the one thing on
    /// this path that is genuinely client-authoritative, and the same "lost half point" argument
    /// would, applied to `x`/`y`, pin a window to where the server last saw it.
    ///
    /// Taking the rect (rather than letting the caller destructure it) is what keeps the
    /// outbound size out of the call site's own arithmetic: `RemoteWindowRegistry
    /// .handleLocalGeometrySettled` hands this function the rect and hands the result to
    /// `clientWindowMoveRect`, and never names a width or a height of its own -- pinned as
    /// source in `RemoteWindowRegistryOutboundRectPinTests`.
    public static func snappedToLastReportedSize(
        _ visible: WindowsRect, lastReportedWidth: Double, lastReportedHeight: Double, rasterScale: Double
    ) -> WindowsRect {
        WindowsRect(
            x: visible.x, y: visible.y,
            width: snapToLastReportedDimension(
                local: visible.width, lastReported: lastReportedWidth, rasterScale: rasterScale),
            height: snapToLastReportedDimension(
                local: visible.height, lastReported: lastReportedHeight, rasterScale: rasterScale)
        )
    }

    /// The left inset the server applies to a sent `ClientWindowMove` (modelled as DWM's
    /// invisible frame; what is measured is `reportedOffsetX - sentLeft`), on the About-Windows dialog (style
    /// `0x80080000` = `WS_POPUP | WS_SYSMENU`, no `WS_THICKFRAME`) -- the original calibration
    /// this whole correction was derived from: THREE runs on 2026-08-23 each sent `left=331`
    /// and got `offsetX=338` back on the next `WindowUpdate`, a clean +7 every time (the
    /// algebra is worked in `clientWindowMoveLeft`'s own doc comment). Corroborated once more
    /// by C-2 run 4 (`docs/upgrade-gate/2026-09-scaledmap-next-step.md:101`), whose About-target
    /// move leg sent `left=195` and was reported back at `offsetX=202`, i.e. a measured frame of
    /// (7,0,7,7) -- n=1 for the right/bottom members of that frame, which nothing here consumes.
    ///
    /// PROVENANCE: this is the value that lived at `RemoteWindowRegistry`'s own
    /// `measuredClientWindowMoveLeftBorder` (F6 (a); ADR-0015 §7 (a)) until the 2026-09-05 per-style
    /// lane moved it here so the style rule below could be unit-tested as one pure function. It is
    /// the same number with the same evidence, not a re-derivation. `Tools/window-smoke`'s
    /// `RailComparison.Borders.aboutCalibrated` cites this name, keeping the old one as provenance.
    public static let aboutCalibratedClientWindowMoveLeftBorder: Double = 7

    /// The same inset on the same window class, measured on a **2x session that advertised
    /// `DesktopScaleFactor=200`** -- ADR-0018 §5.2 增补二 item 2's `B @192 DPI` row for
    /// non-`WS_THICKFRAME` windows. Source: the host-side window-rectangle probe's own
    /// `GetWindowRect` / `DWMWA_EXTENDED_FRAME_BOUNDS` pair on the About-class dialog,
    /// `B = ef.l - wr.l = 11`, **n=1**. Both 2026-09-15 host-rect batches read that pair on
    /// THIS class and agree on it, and it is their **About cells only** that are cited here:
    /// `docs/upgrade-gate/2026-09-15-w3-hostrect.md` §3(g)/§6 and
    /// `.../2026-09-15-w3-hostrect-keep.md` §3(g)/§6. The THICKFRAME constant below cites a
    /// different (smaller) set of cells, for the reason its own comment gives.
    ///
    /// 11 IS THE REASON THERE IS A TABLE. Had it come back 14 this would be
    /// `aboutCalibratedClientWindowMoveLeftBorder * rasterScale` and no second constant would
    /// exist. It did not: the border is not linear in the display scale on this row, which is
    /// the option ADR-0015 §7 (a) rules out by name.
    ///
    /// NO SECOND-SOURCE CORROBORATION EXISTS FOR **THIS** CELL (gate r1, 2026-09-18). A draft of
    /// this comment offered a live move leg as one; that leg was on the other row (see
    /// `thickFrameClientWindowMoveLeftBorder192`, which is where the observation moved). This row
    /// stands on the host-side probe alone, and re-measuring it on a 2x session through the
    /// send/echo path is the outstanding half of §3 item 5 / §8.5 at 192 DPI too.
    public static let aboutCalibratedClientWindowMoveLeftBorder192: Double = 11

    /// The same inset on `WS_THICKFRAME` windows -- F-R1
    /// (`docs/upgrade-gate/2026-09-resize-leg-live.md:32`): a Notepad target (style
    /// `0x000F0000`) was asked for visible left 215, was sent `left=208` under the
    /// About-calibrated 7 above, and came back at `offsetX=213` -- the server had inset by 5,
    /// leaving the `dx = -2` that run's move leg reported. The record's running count reached
    /// eight independent runs at C second-step r2 and nine at r3 (the `F-R1 n` counter,
    /// `docs/upgrade-gate/2026-09-scaledmap-next-step.md:101`); r3 additionally read the frame
    /// directly through adr/0015 §6.2's measurement field, `frame=(5,0,5,5)` on all ten legs
    /// (its record entry, `scaledmap-next-step.md:109`).
    ///
    /// The frame's top member measured 0 in both models -- n=9 on the THICKFRAME side (the F-R1
    /// counter) and n=1 on the About side (C-2 run 4's single (7,0,7,7) reading; the 2026-08-23
    /// runs measured `left` only). `clientWindowMoveLeft` has no
    /// `top` sibling for a DIFFERENT reason -- Y was never exercised in the 2026-08-23 round (its
    /// own doc comment, a still-registered gap) -- and these measurements are consistent with,
    /// but do not close, that gap; the same doc explains why there is no `right`/width sibling.
    public static let thickFrameClientWindowMoveLeftBorder: Double = 5

    /// The same inset on `WS_THICKFRAME` windows at **`DesktopScaleFactor=200`** -- ADR-0018
    /// §5.2 增补二 item 2's `B @192 DPI` row for the THICKFRAME class, from the same host-side
    /// `GetWindowRect` / `DWMWA_EXTENDED_FRAME_BOUNDS` probe as the About-class 11 above
    /// (`B = ef.l - wr.l = 10`), **n=1** -- but from **ONE** record, not the two that constant
    /// cites: `docs/upgrade-gate/2026-09-15-w3-hostrect-keep.md` §3(g) (the `5,0,5,5` @96 /
    /// `10,0,10,10` @192 pair) and §6. The EARLIER batch
    /// (`.../2026-09-15-w3-hostrect.md` §3(g)/§6) could not judge this row at all: its
    /// THICKFRAME cells produced no host reading at either scale -- the target was closed by
    /// that run's own close leg before the probe read it -- which is the gap the `-keep` batch
    /// was run to fill (gate r1, 2026-09-18: this comment used to claim both records).
    ///
    /// CORROBORATED ON THE WIRE, by the one live 2x run that moved a window of THIS class
    /// (`docs/upgrade-gate/2026-09-09-w3-2x-checkpoint-c2prime.md` §3.2; the run's own adr/0015
    /// §6.2 measurement lines). Both of that run's legs locked a `style=0x000F0000` target and
    /// deducted the 96 column (`outboundLeftBorder=5.000`, the only column that existed then):
    /// move sent `l=377` and was reported back at `offset 387`; resize sent `l=381` and came
    /// back at `offset 391`. The server's own inset on that window was therefore `10` remote px
    /// on both legs -- this constant, measured through the send/echo path instead of through the
    /// host probe, on a different day and a different batch. Both legs also report
    /// `delta=(dx=5,…)`, which is exactly the under-deduction this table predicts for a 96-column
    /// send at 192 DPI (`10 - 5`), and `frame=(5,0,5,5)` there is the model that was ASSUMED,
    /// not a reading. Two numbers in that run that are NOT this quantity: the local
    /// `rectDelta dx=4.000` (a mac-side rect comparison, and that leg was judged against a
    /// mid-leg remap observation), and the About row's `11 - 7 = 4`; neither belongs to this
    /// constant or to the one above.
    ///
    /// This row DOES happen to be twice its 96-DPI sibling. Recorded as a coincidence of two
    /// independent readings, not as a rule: the other row of the same table is not (7 -> 11),
    /// so a `* rasterScale` implementation would reproduce this number and get the other one
    /// wrong -- which is precisely how a linear model would have survived a one-row test.
    ///
    /// It also does not contradict the 2026-09-06 F round 3 finding that the THICKFRAME 5 "does
    /// not scale with DPI": that run was a 2x DISPLAY, and what this constant is keyed on is the
    /// advertised `DesktopScaleFactor` -- see `DPITier`'s own doc comment for why those are two
    /// different questions, and the 2026-09-18 route-B wiring pre-registration §0 for the ruling.
    public static let thickFrameClientWindowMoveLeftBorder192: Double = 10

    /// F6 (a), as the 2026-09-05 per-style lane rewrote it on F-R1's evidence: the left border
    /// `clientWindowMoveLeft` deducts, chosen from the window's own Win32 `style` bits. This is a
    /// shape ADR-0015 §7 (a) does NOT list: its row offers two options decided by W3's 2x
    /// measurement (a re-measured constant, or a `resizeMargin`-derived expression), and this
    /// two-row style table is a third, taken on the window axis instead (owner ruling
    /// 2026-09-05; the ADR amendment -- a third entry in that row and §6.2's reference to the old
    /// symbol -- is a docs follow-up of the same lane). `WS_THICKFRAME` (== `WS_SIZEBOX`, `StyleTranslator.styleThickFrame`) set ->
    /// `thickFrameClientWindowMoveLeftBorder`; anything else ->
    /// `aboutCalibratedClientWindowMoveLeftBorder`. Each constant carries its own record.
    ///
    /// WHY A STYLE KEY AND NOT A DPI ONE: ADR-0015 §7 (a) named "a different window/DPI/
    /// Windows-build" as this value's trigger, and the one that actually fired was the FIRST
    /// of the three. Both measurements come from the same 1x host and the same Windows build;
    /// the only thing that differs between them is the window's style. Explicitly NOT a
    /// `rasterScale` multiplication -- §7 (a) rules that option out by name, and no evidence
    /// says a window-manager border scales linearly with DPI.
    ///
    /// `style == 0` FALLS TO THE ABOUT VALUE, and that is a decision rather than an accident.
    /// Zero is what `RemoteWindowRegistry`'s `PendingWindowState.style` holds both for a window
    /// whose style genuinely is 0 and for one whose window orders never carried
    /// `WINDOW_ORDER_FIELD_STYLE` at all (a delta order's unset bit means "unchanged", never
    /// "reset to zero" -- `WindowState.merge`'s own invariant), and the two are
    /// indistinguishable here. There is no measurement for "style unknown", so the unknown case
    /// keeps the exact value that was sent for every window before this function existed
    /// instead of acquiring a new, unmeasured one (a different discipline from
    /// `WindowMappability.isMappableWindow`'s fail-open "unknown styles render visible", but the
    /// same instinct: never invent a value for a case nobody measured). A window
    /// that never announces a style also never announces `WS_THICKFRAME`, so nothing here can
    /// tell it apart from a genuine non-THICKFRAME window; if that ever needs to be visible,
    /// the discriminator has to be an explicit "style was received" flag on the wire state, not
    /// a third value invented in this function.
    ///
    /// A TWO-ROW TABLE IS A STAND-IN, not the destination. F6 (d) (see
    /// `RemoteWindowRegistry.macContentRect(for:windowId:in:)`'s doc comment) records the other
    /// road: RAIL's own `resizeMarginLeft/Top/Right/Bottom` would carry this per window on the
    /// wire, with no table at all -- but that road stays blocked until the adr/0008 §0
    /// `fieldFlags` re-verification (`docs/plans/phase3.md:232`, §8.14) decides whether those
    /// bits are reliably sent. Until it does, this table is what the two measurements support:
    /// two styles, two numbers, no interpolation and no third row.
    ///
    /// The same rule, as a measurement-only fixture seam, is `RailComparison.Borders`
    /// `.forStyleBits` in `Tools/window-smoke/main.swift` -- that copy prints §6.2's comparison
    /// and never feeds the wire; this one is the production decision. They are written to agree
    /// on the same bit and the same two values, but NOT by construction: `StyleTranslator
    /// .styleThickFrame` is internal to this module, so the fixture necessarily carries its own
    /// literal (`RailComparison.Borders.wsThickFrame`). The agreement is pinned instead by the
    /// fixture's self-test, which feeds that literal through this function
    /// (`railComparisonBorderModelsAreTheTwoMeasuredOnes`; review border-per-style-r2 I-3 showed
    /// the bit was unpinned before). A divergence is a bug in whichever was edited alone, and
    /// outside that pin it would surface only as a wrong §6.2 measurement line.
    ///
    /// UNIT: **remote px**, the same domain `clientWindowMoveLeft`'s parameters are in.
    ///
    /// SECOND AXIS SINCE ADR-0018 §5.2 增补二 item 2: this one-argument spelling is now the
    /// 96-DPI COLUMN of `clientWindowMoveLeftBorder(forStyle:tier:)`, kept (rather than migrated
    /// away) because it is the exact behaviour every caller and every pin had before the tier
    /// existed -- so "the 96 column is byte-identical to the lane before it" is a statement a
    /// test can make about a real function instead of about a diff.
    public static func clientWindowMoveLeftBorder(forStyle style: UInt32) -> Double {
        clientWindowMoveLeftBorder(forStyle: style, tier: .dpi96)
    }

    /// Which of the two MEASURED DPI columns of the border table (above, and
    /// `clientWindowMoveLeftBorder(forStyle:tier:)` below) a session is in.
    ///
    /// WHY THE ADVERTISED VALUE AND NOT `DisplayTopology.rasterScale`: the two agree only while
    /// the product default is in effect (`ScaleAdvertisement.productDefault(rasterScale:)` maps
    /// 1 <-> 100 and 2 <-> 200), and the fixture's own `WINDOW_SMOKE_ADVERTISED_SCALE=none`
    /// deliberately breaks that agreement -- it advertises NOTHING on a 2x display, so the
    /// server was told the 100 (96-DPI-equivalent) story while `rasterScale` is still 2. Every
    /// `E-none` leg of the 2026-09-15/16 checkpoint batches is that combination. Keying on the
    /// advertisement is keying on what the SERVER was told, which is what decides the frame it
    /// draws; keying on `rasterScale` would put those runs in the 192 column on the strength of
    /// a local display setting the server never heard about (owner ruling recorded in the
    /// 2026-09-18 route-B wiring pre-registration §0, risk 1).
    ///
    /// TWO CASES, NOT A RANGE. `ScaleAdvertisement.desktopScaleRange` is `100...500`, and this
    /// project has a reading for exactly two of those values. Anything else -- 0 (the pair was
    /// never assigned, i.e. nothing advertised), 100, 150, 500 -- takes the 96 column, which is
    /// what every window got before this axis existed. That is the same fail-closed instinct
    /// the style axis already follows for `style == 0`: never invent a value for a case nobody
    /// measured. `isUnmeasuredAdvertisement` exists so a caller can SAY that it is doing this,
    /// once, for a value that is neither of the two ordinary ones.
    public enum DPITier: Equatable, Sendable {
        /// The 1x / `DesktopScaleFactor=100` / nothing-advertised column: 7 and 5, the values
        /// measured on the 1x host in 2026-08 and 2026-09 (F-R1 and the About calibration).
        case dpi96
        /// The `DesktopScaleFactor=200` column: 11 and 10, measured on the 2x sessions of
        /// 2026-09-15 (hostrect and hostrect-keep records, `B = ef.l - wr.l`, n=1 per cell).
        case dpi192

        /// `200` is the only advertised desktop scale with a 192-DPI reading behind it; every
        /// other value, including 0 ("the pair was never assigned"), is the 96 column.
        public init(advertisedDesktopScaleFactor: UInt32) {
            self = advertisedDesktopScaleFactor == 200 ? .dpi192 : .dpi96
        }

        /// True when `value` is none of `0` (nothing advertised), `100` or `200` -- i.e. when
        /// the 96 column is being used as a FALLBACK rather than as the column that value
        /// names. Not an error and not a refusal: the run proceeds on today's numbers. It is
        /// worth one log line because the alternative is a session silently deducting a border
        /// nobody measured for its DPI, which is exactly the class of thing the 2x lane spent
        /// three batches discovering.
        public static func isUnmeasuredAdvertisement(_ value: UInt32) -> Bool {
            value != 0 && value != 100 && value != 200
        }
    }

    /// The left border `clientWindowMoveLeft` deducts, by the window's own Win32 `style` AND the
    /// DPI column this session is in -- ADR-0018 §5.2 增补二 item 2's table, whole:
    ///
    /// | style | B @96 DPI | B @192 DPI |
    /// |---|---|---|
    /// | non-`WS_THICKFRAME` (About; also style-never-received) | 7 | 11 |
    /// | `WS_THICKFRAME` (Notepad) | 5 | 10 |
    ///
    /// NOT A MULTIPLICATION, and that is the finding rather than a style choice: 7 -> 11 is not
    /// 7 x 2, and 5 -> 10 is. A single `rasterScale` factor reproduces one row and breaks the
    /// other, which is why ADR-0015 §7 (a) ruled that shape out by name and why this is a
    /// four-cell lookup with no arithmetic in it at all (pinned:
    /// `theTieredLookupBodyIsATableNotArithmetic`). The @192 readings come from the host-side
    /// probe's own `GetWindowRect`/`DWMWA_EXTENDED_FRAME_BOUNDS` pair (`B = ef.l - wr.l`) in the
    /// 2026-09-15 hostrect and hostrect-keep records, n=1 per cell -- which is also why there is
    /// no third column: nothing was measured at any other DPI, and `DPITier` has no case for one.
    ///
    /// THE STYLE-UNKNOWN x 192 CELL WAS NEVER MEASURED. `style == 0` takes the non-THICKFRAME
    /// row here exactly as it does at 96 DPI, for the reason the one-argument seam's doc comment
    /// above works through in full -- the unknown case keeps the row it already had rather than
    /// acquiring a new number when a second axis appears. STATED AS THE CHOSEN DIRECTION RATHER
    /// THAN AS A FINDING: `(style 0, .dpi192) = 11`, the About row, is a decision this lane took
    /// and NOT a measurement -- no run has ever observed a window that withheld
    /// `WINDOW_ORDER_FIELD_STYLE` on a 192-DPI session, so nothing says 11 is what such a window
    /// would need. It is chosen because it is the direction that keeps the unknown case on the
    /// same row at both tiers; a reading that ever contradicts it changes this cell alone.
    ///
    /// WHAT IS NOT WIRED HERE: the client-area inset **K** from the same ADR table. K is a
    /// separate quantity for a separate (not yet built) consumer, and its Y component is nonzero
    /// for the non-THICKFRAME row even at 96 DPI -- feeding K into the move leg would change 1x
    /// Y-axis behaviour, which today applies no correction at all. This lookup is B only.
    ///
    /// UNIT: **remote px**, the same domain `clientWindowMoveLeft`'s parameters are in -- the
    /// tier selects a row of the table, it does not convert anything.
    public static func clientWindowMoveLeftBorder(forStyle style: UInt32, tier: DPITier) -> Double {
        switch (style & StyleTranslator.styleThickFrame != 0, tier) {
        case (false, .dpi96): return aboutCalibratedClientWindowMoveLeftBorder
        case (true, .dpi96): return thickFrameClientWindowMoveLeftBorder
        case (false, .dpi192): return aboutCalibratedClientWindowMoveLeftBorder192
        case (true, .dpi192): return thickFrameClientWindowMoveLeftBorder192
        }
    }
}
