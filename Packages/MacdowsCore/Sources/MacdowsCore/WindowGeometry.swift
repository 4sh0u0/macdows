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
