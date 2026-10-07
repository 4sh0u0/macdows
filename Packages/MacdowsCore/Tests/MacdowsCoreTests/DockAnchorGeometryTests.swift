import CoreGraphics
import Testing

@testable import MacdowsCore

/// ADR-0025 §3.1 item 4: the start panel's anchor geometry, offline. Every expected frame is
/// written out as numbers (the arithmetic is in the comment next to it), so a changed gap, a
/// dropped flip term or a lost clamp shows up as a wrong number rather than a self-consistent one.
///
/// Fixtures, AppKit global coordinates (origin at the primary's bottom-left, y up), a 25 pt menu
/// bar, a 70 pt Dock band, a 320 x 450 panel unless a test says otherwise.
@Suite("DockAnchorGeometry: Dock edge, AX flip, anchors and clamping")
struct DockAnchorGeometryTests {

    private static let panel = CGSize(width: 320, height: 450)
    private static let primaryFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let primaryMaxY: CGFloat = 900

    /// Primary 1440 x 900 with the Dock at the bottom: visible y 70...875.
    private static let dockBottom = AnchorScreen(frame: primaryFrame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
    /// Dock on the left: visible x 70...1440.
    private static let dockLeft = AnchorScreen(frame: primaryFrame, visibleFrame: CGRect(x: 70, y: 0, width: 1370, height: 875))
    /// Dock on the right: visible x 0...1370.
    private static let dockRight = AnchorScreen(frame: primaryFrame, visibleFrame: CGRect(x: 0, y: 0, width: 1370, height: 875))
    /// Auto-hidden Dock (or the Dock on another screen): only the menu bar is cut off.
    private static let noDock = AnchorScreen(frame: primaryFrame, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

    /// A 1920 x 1080 secondary LEFT of the primary, Dock at its bottom: visible y 80...1055.
    private static let secondaryLeft = AnchorScreen(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 80, width: 1920, height: 975))
    /// A 1920 x 1080 secondary ABOVE the primary, Dock at its bottom: visible y 980...1955.
    private static let secondaryAbove = AnchorScreen(
        frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 980, width: 1920, height: 975))

    private static func frame(_ anchor: PanelAnchor, _ screens: [AnchorScreen], size: CGSize = panel,
                              hint: DockEdge? = nil) -> CGRect {
        DockAnchorGeometry.panelFrame(size: size, anchor: anchor, screens: screens, dockEdgeHint: hint)
    }

    /// The clamp area: `visibleFrame` inset by 8, or by 4 at the top for the status item.
    private static func inside(_ rect: CGRect, _ screen: AnchorScreen, top: CGFloat = 8) -> Bool {
        let v = screen.visibleFrame
        return rect.minX >= v.minX + 8 && rect.maxX <= v.maxX - 8 && rect.minY >= v.minY + 8 && rect.maxY <= v.maxY - top
    }

    // MARK: - the design note's numbers

    @Test("the gaps are the design note's: Dock 8, screen inset 8, status item 4")
    func constants() {
        #expect(DockAnchorGeometry.dockGap == 8)
        #expect(DockAnchorGeometry.screenInset == 8)
        #expect(DockAnchorGeometry.statusItemGap == 4)
    }

    // MARK: - Dock edge

    @Test("the Dock edge is where visibleFrame falls short of frame at the bottom, left or right")
    func dockEdgeFromGap() {
        func edge(_ s: AnchorScreen) -> DockEdge? { DockAnchorGeometry.dockEdge(frame: s.frame, visibleFrame: s.visibleFrame) }
        #expect(edge(Self.dockBottom) == .bottom)
        #expect(edge(Self.dockLeft) == .left)
        #expect(edge(Self.dockRight) == .right)
        // The menu bar's top gap is not a Dock; no other gap means unknown.
        #expect(edge(Self.noDock) == nil)
        #expect(edge(Self.secondaryLeft) == .bottom)
        #expect(edge(Self.secondaryAbove) == .bottom)
        // An auto-hidden Dock that leaves a thin strip still names its edge.
        #expect(DockAnchorGeometry.dockEdge(frame: Self.primaryFrame, visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 871)) == .bottom)
        // Two gaps: the wider wins.
        #expect(DockAnchorGeometry.dockEdge(frame: Self.primaryFrame, visibleFrame: CGRect(x: 4, y: 70, width: 1436, height: 805)) == .bottom)
        #expect(DockAnchorGeometry.dockEdge(frame: Self.primaryFrame, visibleFrame: CGRect(x: 70, y: 4, width: 1370, height: 871)) == .left)
    }

    @Test("the nearest Dock edge to a point, bottom / left / right only")
    func nearestEdge() {
        let f = Self.primaryFrame
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 720, y: 2), in: f) == .bottom)
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 3, y: 450), in: f) == .left)
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 1437, y: 450), in: f) == .right)
        // Near the top the Dock can still only be bottom / left / right.
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 200, y: 899), in: f) == .left)
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 1300, y: 899), in: f) == .right)
        // Ties go bottom, then left, then right.
        let square = CGRect(x: 0, y: 0, width: 900, height: 900)
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 450, y: 450), in: square) == .bottom)
        #expect(DockAnchorGeometry.nearestDockEdge(to: CGPoint(x: 450, y: 600), in: square) == .left)
    }

    // MARK: - AX flip

    @Test("an AX frame flips to AppKit by primaryMaxY - y - height")
    func axFlipValues() {
        // 900 - 850 - 50 = 0
        #expect(DockAnchorGeometry.appKitRect(fromAX: CGRect(x: 100, y: 850, width: 64, height: 50), primaryMaxY: 900)
                == CGRect(x: 100, y: 0, width: 64, height: 50))
        // The menu bar strip: 900 - 0 - 25 = 875
        #expect(DockAnchorGeometry.appKitRect(fromAX: CGRect(x: 0, y: 0, width: 1440, height: 25), primaryMaxY: 900)
                == CGRect(x: 0, y: 875, width: 1440, height: 25))
        // A screen ABOVE the primary has negative AX y: 900 - (-69) - 64 = 905
        #expect(DockAnchorGeometry.appKitRect(fromAX: CGRect(x: 928, y: -69, width: 64, height: 64), primaryMaxY: 900)
                == CGRect(x: 928, y: 905, width: 64, height: 64))
        // And back: 900 - 905 - 64 = -69
        #expect(DockAnchorGeometry.axRect(fromAppKit: CGRect(x: 928, y: 905, width: 64, height: 64), primaryMaxY: 900)
                == CGRect(x: 928, y: -69, width: 64, height: 64))
    }

    @Test("the flip round-trips, including off-primary and negative coordinates")
    func axFlipRoundTrip() {
        let rects = [
            CGRect(x: 688, y: 832, width: 64, height: 64),
            CGRect(x: -1000, y: 1010, width: 64, height: 64),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            CGRect(x: 12.5, y: 33.25, width: 7, height: 3.5),
        ]
        for rect in rects {
            for maxY: CGFloat in [900, 1117, 1440] {
                let there = DockAnchorGeometry.appKitRect(fromAX: rect, primaryMaxY: maxY)
                #expect(DockAnchorGeometry.axRect(fromAppKit: there, primaryMaxY: maxY) == rect)
            }
        }
    }

    // MARK: - choosing the anchor (the sender gate)

    @Test("not from the Dock: the fallback, whatever else is known")
    func nonDockSenderFallsBack() {
        let pointer = CGPoint(x: 100, y: 30)
        let ax = CGRect(x: 688, y: 832, width: 64, height: 64)
        #expect(DockAnchorGeometry.dockAnchor(fromDock: false, pointer: pointer, axIconFrame: ax, primaryMaxY: 900) == .fallback)
        #expect(DockAnchorGeometry.dockAnchor(fromDock: false, pointer: pointer, axIconFrame: nil, primaryMaxY: 900) == .fallback)
        // ...and lands where the fallback lands, not under the pointer.
        let anchor = DockAnchorGeometry.dockAnchor(fromDock: false, pointer: pointer, axIconFrame: ax, primaryMaxY: 900)
        #expect(Self.frame(anchor, [Self.dockBottom]) == CGRect(x: 560, y: 78, width: 320, height: 450))
    }

    @Test("from the Dock: the AX frame when there is one, else the pointer, else the fallback")
    func dockSenderOrder() {
        let pointer = CGPoint(x: 100, y: 30)
        let ax = CGRect(x: 688, y: 832, width: 64, height: 64)
        #expect(DockAnchorGeometry.dockAnchor(fromDock: true, pointer: pointer, axIconFrame: ax, primaryMaxY: 900)
                == .dockIcon(axFrame: ax, primaryMaxY: 900))
        #expect(DockAnchorGeometry.dockAnchor(fromDock: true, pointer: pointer, axIconFrame: nil, primaryMaxY: 900)
                == .dockPointer(pointer))
        #expect(DockAnchorGeometry.dockAnchor(fromDock: true, pointer: nil, axIconFrame: nil, primaryMaxY: 900) == .fallback)
    }

    // MARK: - L-p, one screen, three edges

    @Test("L-p, Dock at the bottom: centred on the pointer, 8 above the Dock")
    func pointerBottom() {
        // x = 720 - 160 = 560, y = 70 + 8 = 78
        #expect(Self.frame(.dockPointer(CGPoint(x: 720, y: 30)), [Self.dockBottom]) == CGRect(x: 560, y: 78, width: 320, height: 450))
    }

    @Test("L-p, Dock on the left: centred on the pointer's y, 8 right of the Dock")
    func pointerLeft() {
        // x = 70 + 8 = 78, y = 450 - 225 = 225
        #expect(Self.frame(.dockPointer(CGPoint(x: 30, y: 450)), [Self.dockLeft]) == CGRect(x: 78, y: 225, width: 320, height: 450))
    }

    @Test("L-p, Dock on the right: centred on the pointer's y, 8 left of the Dock")
    func pointerRight() {
        // x = 1370 - 8 - 320 = 1042, y = 225
        #expect(Self.frame(.dockPointer(CGPoint(x: 1410, y: 450)), [Self.dockRight]) == CGRect(x: 1042, y: 225, width: 320, height: 450))
    }

    // MARK: - L-ax

    @Test("L-ax uses the icon's midline, flipped from AX coordinates")
    func axIconBottom() {
        // AppKit icon (688, 4, 64, 64) is AX y = 900 - 4 - 64 = 832; midX 720 -> x = 560, y = 78
        let anchor = PanelAnchor.dockIcon(axFrame: CGRect(x: 688, y: 832, width: 64, height: 64), primaryMaxY: 900)
        #expect(Self.frame(anchor, [Self.dockBottom]) == CGRect(x: 560, y: 78, width: 320, height: 450))
    }

    @Test("L-ax under magnification: the inflated frame's height moves nothing")
    func axIconMagnified() {
        // AX (668, 772, 104, 124) -> AppKit y = 900 - 772 - 124 = 4; midX still 720
        let anchor = PanelAnchor.dockIcon(axFrame: CGRect(x: 668, y: 772, width: 104, height: 124), primaryMaxY: 900)
        #expect(Self.frame(anchor, [Self.dockBottom]) == CGRect(x: 560, y: 78, width: 320, height: 450))
    }

    @Test("L-ax with the Dock on the left: the icon's midY")
    func axIconLeft() {
        // AppKit icon (4, 418, 64, 64) is AX y = 900 - 418 - 64 = 418; midY 450 -> y = 225, x = 78
        let anchor = PanelAnchor.dockIcon(axFrame: CGRect(x: 4, y: 418, width: 64, height: 64), primaryMaxY: 900)
        #expect(Self.frame(anchor, [Self.dockLeft]) == CGRect(x: 78, y: 225, width: 320, height: 450))
    }

    // MARK: - two screens

    @Test("a secondary screen on the left carries the Dock: the panel opens there")
    func secondaryOnTheLeft() {
        let screens = [Self.noDock, Self.secondaryLeft]
        // x = -960 - 160 = -1120, y = 80 + 8 = 88
        #expect(Self.frame(.dockPointer(CGPoint(x: -960, y: 40)), screens) == CGRect(x: -1120, y: 88, width: 320, height: 450))
        // AX: AppKit icon (-992, 8, 64, 64) is AX y = 900 - 8 - 64 = 828
        let anchor = PanelAnchor.dockIcon(axFrame: CGRect(x: -992, y: 828, width: 64, height: 64), primaryMaxY: 900)
        #expect(Self.frame(anchor, screens) == CGRect(x: -1120, y: 88, width: 320, height: 450))
    }

    @Test("a secondary screen above the primary: negative AX y lands on it")
    func secondaryAbove() {
        let screens = [Self.noDock, Self.secondaryAbove]
        // x = 960 - 160 = 800, y = 980 + 8 = 988
        #expect(Self.frame(.dockPointer(CGPoint(x: 960, y: 940)), screens) == CGRect(x: 800, y: 988, width: 320, height: 450))
        // AppKit icon (928, 905, 64, 64) is AX y = -69 (see axFlipValues)
        let anchor = PanelAnchor.dockIcon(axFrame: CGRect(x: 928, y: -69, width: 64, height: 64), primaryMaxY: 900)
        #expect(Self.frame(anchor, screens) == CGRect(x: 800, y: 988, width: 320, height: 450))
    }

    // MARK: - auto-hide (no gap)

    @Test("auto-hidden Dock: the nearest edge to the pointer, 8 inside the screen")
    func autoHideNearestEdge() {
        // bottom: x = 560, y = 0 + 8 = 8
        #expect(Self.frame(.dockPointer(CGPoint(x: 720, y: 2)), [Self.noDock]) == CGRect(x: 560, y: 8, width: 320, height: 450))
        // left: x = 0 + 8 = 8, y = 450 - 225 = 225
        #expect(Self.frame(.dockPointer(CGPoint(x: 3, y: 450)), [Self.noDock]) == CGRect(x: 8, y: 225, width: 320, height: 450))
        // right: x = 1440 - 8 - 320 = 1112
        #expect(Self.frame(.dockPointer(CGPoint(x: 1437, y: 450)), [Self.noDock]) == CGRect(x: 1112, y: 225, width: 320, height: 450))
    }

    @Test("auto-hidden Dock: a hint beats the nearest edge, a real gap beats the hint")
    func autoHideHint() {
        // No gap, hint right: x = 1112; y = 2 - 225 clamps up to 8.
        #expect(Self.frame(.dockPointer(CGPoint(x: 720, y: 2)), [Self.noDock], hint: .right) == CGRect(x: 1112, y: 8, width: 320, height: 450))
        // A gap at the bottom ignores the hint.
        #expect(Self.frame(.dockPointer(CGPoint(x: 720, y: 30)), [Self.dockBottom], hint: .left) == CGRect(x: 560, y: 78, width: 320, height: 450))
    }

    // MARK: - fallback

    @Test("the fallback centres on the Dock edge of the screen that shows the Dock")
    func fallback() {
        // bottom: x = 720 - 160 = 560, y = 78
        #expect(Self.frame(.fallback, [Self.dockBottom]) == CGRect(x: 560, y: 78, width: 320, height: 450))
        // left: x = 78, y = 437.5 - 225 = 212.5, rounded to 213
        #expect(Self.frame(.fallback, [Self.dockLeft]) == CGRect(x: 78, y: 213, width: 320, height: 450))
        // right: x = 1042, y = 213
        #expect(Self.frame(.fallback, [Self.dockRight]) == CGRect(x: 1042, y: 213, width: 320, height: 450))
        // Dock on the secondary: x = -960 - 160 = -1120, y = 88
        #expect(Self.frame(.fallback, [Self.noDock, Self.secondaryLeft]) == CGRect(x: -1120, y: 88, width: 320, height: 450))
        // No Dock anywhere: the primary's bottom, or the hint.
        #expect(Self.frame(.fallback, [Self.noDock]) == CGRect(x: 560, y: 8, width: 320, height: 450))
        #expect(Self.frame(.fallback, [Self.noDock], hint: .left) == CGRect(x: 8, y: 213, width: 320, height: 450))
    }

    // MARK: - status item

    @Test("status item: 4 below the button, leading edges aligned")
    func statusItem() {
        // x = 900, y = 875 - 4 - 450 = 421 (top 871 = visible top - 4)
        let rect = Self.frame(.statusItem(buttonFrame: CGRect(x: 900, y: 875, width: 30, height: 25)), [Self.dockBottom])
        #expect(rect == CGRect(x: 900, y: 421, width: 320, height: 450))
        #expect(Self.inside(rect, Self.dockBottom, top: 4))
    }

    @Test("status item near the right edge slides left to stay 8 inside")
    func statusItemNearTheEdge() {
        // x = 1300 would end at 1620; clamped to 1440 - 8 - 320 = 1112
        #expect(Self.frame(.statusItem(buttonFrame: CGRect(x: 1300, y: 875, width: 30, height: 25)), [Self.dockBottom])
                == CGRect(x: 1112, y: 421, width: 320, height: 450))
    }

    @Test("status item on a secondary screen above")
    func statusItemOnSecondary() {
        // Button at the secondary's menu bar (y 1955...1980): x = 100, y = 1955 - 4 - 450 = 1501
        #expect(Self.frame(.statusItem(buttonFrame: CGRect(x: 100, y: 1955, width: 30, height: 25)), [Self.noDock, Self.secondaryAbove])
                == CGRect(x: 100, y: 1501, width: 320, height: 450))
    }

    // MARK: - clamping and the size cap

    @Test("an icon near a corner slides the panel along the Dock, never off the screen")
    func cornerClamp() {
        // bottom, far left: 20 - 160 = -140 -> 8; far right: 1430 - 160 = 1270 -> 1112
        #expect(Self.frame(.dockPointer(CGPoint(x: 20, y: 30)), [Self.dockBottom]) == CGRect(x: 8, y: 78, width: 320, height: 450))
        #expect(Self.frame(.dockPointer(CGPoint(x: 1430, y: 30)), [Self.dockBottom]) == CGRect(x: 1112, y: 78, width: 320, height: 450))
        // left, near the bottom: 50 - 225 -> 8; near the top: 870 - 225 = 645 -> 875 - 8 - 450 = 417
        #expect(Self.frame(.dockPointer(CGPoint(x: 30, y: 50)), [Self.dockLeft]) == CGRect(x: 78, y: 8, width: 320, height: 450))
        #expect(Self.frame(.dockPointer(CGPoint(x: 30, y: 870)), [Self.dockLeft]) == CGRect(x: 78, y: 417, width: 320, height: 450))
    }

    @Test("a panel taller than the screen is capped at visibleFrame - 16")
    func heightCap() {
        let tall = CGSize(width: 320, height: 2000)
        // bottom: height 805 - 16 = 789, y = 78, top = 867 = 875 - 8
        #expect(Self.frame(.dockPointer(CGPoint(x: 720, y: 30)), [Self.dockBottom], size: tall) == CGRect(x: 560, y: 78, width: 320, height: 789))
        // left: height 875 - 16 = 859, y clamps to 8
        #expect(Self.frame(.dockPointer(CGPoint(x: 30, y: 450)), [Self.dockLeft], size: tall) == CGRect(x: 78, y: 8, width: 320, height: 859))
        // status item: height 789, top at 871
        #expect(Self.frame(.statusItem(buttonFrame: CGRect(x: 900, y: 875, width: 30, height: 25)), [Self.dockBottom], size: tall)
                == CGRect(x: 900, y: 82, width: 320, height: 789))
    }

    @Test("every anchor on every fixture stays inside visibleFrame inset by 8, on whole points")
    func clampSweep() {
        let fixtures: [[AnchorScreen]] = [[Self.dockBottom], [Self.dockLeft], [Self.dockRight], [Self.noDock],
                                          [Self.noDock, Self.secondaryLeft], [Self.noDock, Self.secondaryAbove]]
        for screens in fixtures {
            let union = screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            for xStep in 0...16 {
                for yStep in 0...16 {
                    let point = CGPoint(x: union.minX + union.width * CGFloat(xStep) / 16 + 0.37,
                                        y: union.minY + union.height * CGFloat(yStep) / 16 + 0.61)
                    for size in [Self.panel, CGSize(width: 320, height: 2000)] {
                        let anchors: [PanelAnchor] = [
                            .dockPointer(point),
                            .dockIcon(axFrame: DockAnchorGeometry.axRect(fromAppKit: CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64),
                                                                         primaryMaxY: Self.primaryMaxY),
                                      primaryMaxY: Self.primaryMaxY),
                            .fallback,
                        ]
                        for anchor in anchors {
                            let rect = Self.frame(anchor, screens, size: size)
                            let host = screens.first { $0.frame.intersects(rect) }
                            #expect(host.map { Self.inside(rect, $0) } == true, "\(anchor) \(size)")
                            #expect(rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded(), "\(anchor)")
                        }
                    }
                }
            }
        }
    }

    @Test("no screens: the size at the origin, nothing to clamp into")
    func noScreens() {
        #expect(Self.frame(.fallback, []) == CGRect(x: 0, y: 0, width: 320, height: 450))
        #expect(Self.frame(.dockPointer(CGPoint(x: 5, y: 5)), []) == CGRect(x: 0, y: 0, width: 320, height: 450))
    }

    @Test("a pointer outside every screen uses the nearest one")
    func pointerOffScreen() {
        // x = 1440 is the primary's maxX (outside a half-open rect): still the primary, right of centre clamps.
        #expect(Self.frame(.dockPointer(CGPoint(x: 1440, y: 30)), [Self.dockBottom]) == CGRect(x: 1112, y: 78, width: 320, height: 450))
    }
}
