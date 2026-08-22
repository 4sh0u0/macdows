import Foundation

/// A window rectangle in Windows screen-space coordinates: origin at the top-left of the
/// (virtual) desktop, Y increasing downward. `x`/`y` may be negative for monitors placed
/// left of or above the primary monitor in a multi-monitor layout.
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
public enum WindowGeometry {
    /// Converts a Windows-space rect to macOS-space, given the primary monitor's height.
    public static func macRect(from windowsRect: WindowsRect, primaryMonitorHeight: Double) -> MacRect {
        MacRect(
            x: windowsRect.x,
            y: primaryMonitorHeight - windowsRect.y - windowsRect.height,
            width: windowsRect.width,
            height: windowsRect.height
        )
    }

    /// Converts a macOS-space rect back to Windows-space, given the same primary monitor
    /// height used to produce it. This is the exact inverse of
    /// `macRect(from:primaryMonitorHeight:)` — round-tripping through both directions
    /// with the same `primaryMonitorHeight` returns the original rect.
    public static func windowsRect(from macRect: MacRect, primaryMonitorHeight: Double) -> WindowsRect {
        WindowsRect(
            x: macRect.x,
            y: primaryMonitorHeight - macRect.y - macRect.height,
            width: macRect.width,
            height: macRect.height
        )
    }

    /// W4c: converts a single point — e.g. a mouse click's location, already resolved to
    /// this Mac's global screen space (a window's own frame origin plus an AppKit event's
    /// `locationInWindow`, which `NSEvent` itself always reports bottom-left-origin/Y-up
    /// regardless of whether the receiving view opts into `isFlipped`) — into the
    /// corresponding Windows-space absolute desktop coordinate a RAIL mouse input PDU
    /// needs. Same Y-flip as `windowsRect(from:primaryMonitorHeight:)`, but without that
    /// function's `- height` term: a bare point has no height to anchor against, only the
    /// rect case needs to map a rect's *top* edge (Windows convention) onto mac's
    /// bottom-anchored origin.
    public static func windowsPoint(from macPoint: MacPoint, primaryMonitorHeight: Double) -> WindowsPoint {
        WindowsPoint(x: macPoint.x, y: primaryMonitorHeight - macPoint.y)
    }

    /// The exact inverse of `windowsPoint(from:primaryMonitorHeight:)` — not needed by any
    /// current caller (RAIL only ever tells this project window *rectangles*, never bare
    /// points, on the inbound side), provided for symmetry and because it's what makes the
    /// round-trip identity actually testable in both directions.
    public static func macPoint(from windowsPoint: WindowsPoint, primaryMonitorHeight: Double) -> MacPoint {
        MacPoint(x: windowsPoint.x, y: primaryMonitorHeight - windowsPoint.y)
    }
}

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
    /// `macRect(from:primaryMonitorHeight:)` conversion, so the two corrections (RAIL-size
    /// vs display-size, then Windows-space vs mac-space) compose rather than duplicate each
    /// other's job.
    public static func displayRect(from railRect: WindowsRect, correction: WindowGeometryCorrection) -> WindowsRect {
        WindowsRect(
            x: railRect.x + correction.originX, y: railRect.y + correction.originY,
            width: railRect.width + correction.width, height: railRect.height + correction.height
        )
    }

    /// The exact inverse of `displayRect(from:correction:)` -- the outbound direction.
    /// `RemoteWindowRegistry.handleLocalGeometrySettled` calls this after
    /// `windowsRect(from:primaryMonitorHeight:)`, before turning the result into the
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
    public static func clientWindowMoveLeft(fromVisibleLeft visibleLeft: Double, measuredLeftBorder: Double) -> Double {
        visibleLeft - measuredLeftBorder
    }
}
