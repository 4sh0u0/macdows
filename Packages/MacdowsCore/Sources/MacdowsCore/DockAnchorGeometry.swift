// CoreGraphics, not AppKit: the CGRect / CGPoint values and their Equatable conformances live in
// its overlay (Foundation alone does not bring the conformances in). Elsewhere Foundation has both.
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

// ADR-0025 §1.3 / §3.1 item 4, design note 2026-10-07 §1: where the start panel opens.
//
// The App gathers the facts -- which process sent the reopen, the pointer, the Dock item's AX
// frame when the precise-positioning setting is on and authorised, each screen's `frame` and
// `visibleFrame`, the primary screen's height -- and this file turns them into one panel frame.
// Pure arithmetic on CGRect / CGPoint in AppKit's global coordinates (origin at the primary
// screen's bottom-left, y up); no AppKit, no AX, no screen lookups, so every anchor shape below is
// exercised offline. Facts not yet measured on this machine (the AX coordinate origin, whether an
// auto-hidden Dock leaves a strip in `visibleFrame`) are the ADR's P-AX probe; the conversions
// here follow the ADR's stated assumption and the tests pin that assumption as numbers.
//
// The rules, with the design note's values:
//  - The Dock's edge on a screen is where `visibleFrame` falls short of `frame` at the bottom, left
//    or right (the top gap is the menu bar). No gap -- an auto-hidden Dock, or a screen without the
//    Dock -- means unknown; the caller may pass a hint, else the edge nearest the pointer (which is
//    on the Dock: the sender gate passed) or, with nothing to go on, the bottom.
//  - A Dock anchor centres the panel on the icon's midline (the pointer's coordinate for L-p, the
//    AX frame's centre for L-ax -- never its height, which magnification inflates) and puts the
//    panel's Dock-side edge `dockGap` outside the Dock's inner edge, i.e. `visibleFrame`'s edge.
//  - The fallback (L-fb: the request did not come from the Dock) centres the panel on the Dock
//    edge of the screen that shows the Dock, else the primary.
//  - A status-item anchor hangs the panel `statusItemGap` below the button, leading edges aligned.
//  - Every frame is then clamped into the anchor screen's `visibleFrame` inset by `screenInset`
//    (`statusItemGap` at the top for the status-item anchor), and the panel's size is capped at
//    `visibleFrame` minus twice `screenInset` -- an icon near a corner slides the panel along the
//    edge, never off the screen.

/// A screen edge the Dock can sit on (System Settings offers no top position).
public enum DockEdge: Equatable, Sendable, CaseIterable {
    case bottom
    case left
    case right
}

/// One display, as AppKit reports it: `NSScreen.frame` and `NSScreen.visibleFrame`, both in global
/// AppKit coordinates.
public struct AnchorScreen: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// What the panel is anchored to.
public enum PanelAnchor: Equatable, Sendable {
    /// L-p: the pointer at the Dock click, in AppKit global coordinates.
    case dockPointer(CGPoint)
    /// L-ax: the Dock item's frame as the Accessibility API reports it (origin at the primary
    /// screen's TOP-left, y down), with the primary screen's `frame.maxY` to flip it by.
    case dockIcon(axFrame: CGRect, primaryMaxY: CGFloat)
    /// The status item's button frame, in AppKit global coordinates.
    case statusItem(buttonFrame: CGRect)
    /// L-fb: no usable Dock position; centre on the Dock edge.
    case fallback
}

public enum DockAnchorGeometry {
    /// Gap between the Dock's inner edge and the panel (design note §1, anchor row).
    public static let dockGap: CGFloat = 8
    /// How far inside `visibleFrame` every panel edge stays (design note §1, clamp row).
    public static let screenInset: CGFloat = 8
    /// Gap between the status-item button and the panel's top edge; also the top clamp inset for
    /// that anchor (design note §1, anchor and clamp rows).
    public static let statusItemGap: CGFloat = 4

    // MARK: - Dock edge

    /// The edge whose `frame` / `visibleFrame` gap shows the Dock, or nil when there is none. When
    /// more than one side has a gap the widest wins, ties in the order bottom, left, right.
    public static func dockEdge(frame: CGRect, visibleFrame: CGRect) -> DockEdge? {
        let gaps: [(DockEdge, CGFloat)] = [
            (.bottom, visibleFrame.minY - frame.minY),
            (.left, visibleFrame.minX - frame.minX),
            (.right, frame.maxX - visibleFrame.maxX),
        ]
        var best: (edge: DockEdge, width: CGFloat)?
        for (edge, width) in gaps where width > 0 {
            if let current = best, current.width >= width {
                continue
            }
            best = (edge, width)
        }
        return best?.edge
    }

    /// The Dock edge (bottom, left or right) of `frame` closest to `point`; ties in the order
    /// bottom, left, right. Only meaningful for a point already known to be on the Dock.
    public static func nearestDockEdge(to point: CGPoint, in frame: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, abs(point.y - frame.minY)),
            (.left, abs(point.x - frame.minX)),
            (.right, abs(frame.maxX - point.x)),
        ]
        var best = distances[0]
        for distance in distances.dropFirst() where distance.1 < best.1 {
            best = distance
        }
        return best.0
    }

    // MARK: - Accessibility frame flip

    /// An AX frame (origin at the primary screen's top-left, y down) in AppKit global coordinates:
    /// y = `primaryMaxY` - axY - height. `primaryMaxY` is the primary screen's `frame.maxY`.
    public static func appKitRect(fromAX axRect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: axRect.minX, y: primaryMaxY - axRect.minY - axRect.height,
               width: axRect.width, height: axRect.height)
    }

    /// The inverse of `appKitRect(fromAX:primaryMaxY:)` (the flip is its own inverse).
    public static func axRect(fromAppKit rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.minY - rect.height,
               width: rect.width, height: rect.height)
    }

    // MARK: - Choosing the anchor

    /// The anchor for a Dock-originated request (ADR-0025 §1.3, R-2): not from the Dock -> the
    /// fallback, whatever else is known; from the Dock -> the AX icon frame when the caller has
    /// one (precise positioning on and authorised), else the pointer, else the fallback.
    public static func dockAnchor(fromDock: Bool, pointer: CGPoint?, axIconFrame: CGRect?,
                                  primaryMaxY: CGFloat) -> PanelAnchor {
        guard fromDock else { return .fallback }
        if let axIconFrame {
            return .dockIcon(axFrame: axIconFrame, primaryMaxY: primaryMaxY)
        }
        if let pointer {
            return .dockPointer(pointer)
        }
        return .fallback
    }

    // MARK: - The panel frame

    /// The panel's frame for `anchor`, given its preferred `size` and the screens (`screens[0]` is
    /// the primary, as `NSScreen.screens` orders them). `dockEdgeHint` stands in for the Dock edge
    /// when the anchor screen shows no gap (an auto-hidden Dock). With no screens at all there is
    /// nothing to clamp into, and the frame is `size` at the origin.
    public static func panelFrame(size: CGSize, anchor: PanelAnchor, screens: [AnchorScreen],
                                  dockEdgeHint: DockEdge? = nil) -> CGRect {
        guard let primary = screens.first else {
            return CGRect(origin: .zero, size: size)
        }
        switch anchor {
        case .dockPointer(let point):
            let screen = self.screen(containing: point, in: screens) ?? primary
            let edge = dockEdge(frame: screen.frame, visibleFrame: screen.visibleFrame)
                ?? dockEdgeHint ?? nearestDockEdge(to: point, in: screen.frame)
            return dockFrame(size: size, midline: point, edge: edge, screen: screen)
        case .dockIcon(let axFrame, let primaryMaxY):
            let icon = appKitRect(fromAX: axFrame, primaryMaxY: primaryMaxY)
            let centre = CGPoint(x: icon.midX, y: icon.midY)
            let screen = self.screen(containing: centre, in: screens) ?? primary
            let edge = dockEdge(frame: screen.frame, visibleFrame: screen.visibleFrame)
                ?? dockEdgeHint ?? nearestDockEdge(to: centre, in: screen.frame)
            return dockFrame(size: size, midline: centre, edge: edge, screen: screen)
        case .statusItem(let button):
            let centre = CGPoint(x: button.midX, y: button.midY)
            let screen = self.screen(containing: centre, in: screens) ?? primary
            let capped = cap(size, in: screen.visibleFrame)
            let origin = CGPoint(x: button.minX, y: button.minY - statusItemGap - capped.height)
            return clamp(CGRect(origin: origin, size: capped),
                         into: clampArea(screen.visibleFrame, topInset: statusItemGap))
        case .fallback:
            let screen = screens.first { dockEdge(frame: $0.frame, visibleFrame: $0.visibleFrame) != nil }
                ?? primary
            let edge = dockEdge(frame: screen.frame, visibleFrame: screen.visibleFrame)
                ?? dockEdgeHint ?? .bottom
            let middle = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
            return dockFrame(size: size, midline: middle, edge: edge, screen: screen)
        }
    }

    /// Centre on `midline` along `edge`, Dock-side edge `dockGap` inside `visibleFrame`, clamped.
    private static func dockFrame(size: CGSize, midline: CGPoint, edge: DockEdge,
                                  screen: AnchorScreen) -> CGRect {
        let visible = screen.visibleFrame
        let capped = cap(size, in: visible)
        let origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: midline.x - capped.width / 2, y: visible.minY + dockGap)
        case .left:
            origin = CGPoint(x: visible.minX + dockGap, y: midline.y - capped.height / 2)
        case .right:
            origin = CGPoint(x: visible.maxX - dockGap - capped.width, y: midline.y - capped.height / 2)
        }
        return clamp(CGRect(origin: origin, size: capped), into: clampArea(visible, topInset: screenInset))
    }

    /// `size` capped at `visible` minus `screenInset` on every side (design note §1, row-count
    /// row: the height limit is `visibleFrame.height` - 16).
    private static func cap(_ size: CGSize, in visible: CGRect) -> CGSize {
        CGSize(width: min(size.width, max(0, visible.width - 2 * screenInset)),
               height: min(size.height, max(0, visible.height - 2 * screenInset)))
    }

    private static func clampArea(_ visible: CGRect, topInset: CGFloat) -> CGRect {
        CGRect(x: visible.minX + screenInset, y: visible.minY + screenInset,
               width: max(0, visible.width - 2 * screenInset),
               height: max(0, visible.height - screenInset - topInset))
    }

    /// Whole-point origin, then moved (never resized) to lie inside `area`. Rounding first keeps
    /// the clamp's guarantee exact.
    private static func clamp(_ rect: CGRect, into area: CGRect) -> CGRect {
        var x = rect.minX.rounded()
        var y = rect.minY.rounded()
        x = min(max(x, area.minX), area.maxX - rect.width)
        y = min(max(y, area.minY), area.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// The screen whose frame contains `point`, else the one nearest to it.
    private static func screen(containing point: CGPoint, in screens: [AnchorScreen]) -> AnchorScreen? {
        if let hit = screens.first(where: { $0.frame.contains(point) }) {
            return hit
        }
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { distance($0.frame) < distance($1.frame) }
    }
}
