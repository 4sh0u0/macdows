import Testing
@testable import MacdowsCore

@Suite("WindowGeometry")
struct WindowGeometryTests {
    // Primary 1920x1080 monitor as the reference frame for most cases below.
    static let primaryHeight = 1080.0

    @Test("origin-anchored window maps to the top of mac screen space")
    func originWindow() {
        let windowsRect = WindowsRect(x: 0, y: 0, width: 800, height: 600)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryHeight)

        // Windows (0,0) is the top-left of the primary monitor; in mac space (bottom-left
        // origin, Y up) that same physical spot is at y = primaryMonitorHeight - height.
        #expect(mac == MacRect(x: 0, y: 480, width: 800, height: 600))
    }

    @Test("window flush with the bottom of the primary monitor maps to mac y = 0")
    func bottomAlignedWindow() {
        let windowsRect = WindowsRect(x: 100, y: 880, width: 400, height: 200)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryHeight)

        #expect(mac == MacRect(x: 100, y: 0, width: 400, height: 200))
    }

    @Test("secondary monitor above the primary produces negative Windows Y and mac Y past the top edge")
    func monitorAbovePrimary() {
        // A 1920x300 secondary monitor docked directly above the primary, left edges
        // aligned: its Windows-space rect spans y ∈ [-300, 0].
        let windowsRect = WindowsRect(x: 0, y: -300, width: 1920, height: 300)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryHeight)

        // In mac space the primary spans y ∈ [0, 1080], so a monitor docked above it
        // should start exactly at the primary's top edge and extend past it.
        #expect(mac == MacRect(x: 0, y: 1080, width: 1920, height: 300))
    }

    @Test("monitor to the left of the primary produces negative X, unchanged by the Y flip")
    func monitorLeftOfPrimary() {
        // A 1920x1080 secondary monitor docked to the left of the primary, top edges
        // aligned: its Windows-space rect spans x ∈ [-1920, 0], y ∈ [0, 1080].
        let windowsRect = WindowsRect(x: -1920, y: 0, width: 1920, height: 1080)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryHeight)

        #expect(mac == MacRect(x: -1920, y: 0, width: 1920, height: 1080))
    }

    @Test("a taller primary monitor (1440p) produces the same shape, anchored differently")
    func tallerPrimaryMonitor() {
        // Same window as originWindow(), but against a 2560x1440 primary instead of
        // 1920x1080 — the primary-monitor-height anchor, not any hardcoded 1080, is what
        // must drive the flip.
        let windowsRect = WindowsRect(x: 0, y: 0, width: 800, height: 600)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: 1440)

        #expect(mac == MacRect(x: 0, y: 840, width: 800, height: 600))
    }

    @Test("the same Windows rect maps to mac Y values that differ by exactly the height delta between two primary monitor heights",
          arguments: [
            WindowsRect(x: 0, y: 0, width: 800, height: 600),
            WindowsRect(x: -1920, y: -300, width: 1920, height: 300),
            WindowsRect(x: 250, y: 940, width: 640, height: 480),
          ])
    func macYScalesLinearlyWithPrimaryMonitorHeight(_ windowsRect: WindowsRect) {
        let heightA = Self.primaryHeight // 1080
        let heightB = 1440.0

        let macA = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: heightA)
        let macB = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: heightB)

        // macRect.y = primaryMonitorHeight - windowsRect.y - windowsRect.height, so
        // changing only primaryMonitorHeight shifts mac.y by exactly the same delta —
        // x, width, and height must not move at all.
        #expect(macB.y - macA.y == heightB - heightA)
        #expect(macA.x == macB.x)
        #expect(macA.width == macB.width)
        #expect(macA.height == macB.height)
    }

    @Test("windowsRect(from:primaryMonitorHeight:) is the exact inverse of macRect(from:primaryMonitorHeight:)",
          arguments: [
            WindowsRect(x: 0, y: 0, width: 800, height: 600),
            WindowsRect(x: -1920, y: -300, width: 1920, height: 300),
            WindowsRect(x: 250, y: 940, width: 640, height: 480),
            WindowsRect(x: -37, y: 1200, width: 1, height: 1),
          ])
    func roundTrip(_ original: WindowsRect) {
        let mac = WindowGeometry.macRect(from: original, primaryMonitorHeight: Self.primaryHeight)
        let roundTripped = WindowGeometry.windowsRect(from: mac, primaryMonitorHeight: Self.primaryHeight)

        #expect(roundTripped == original)
    }

    // MARK: - W4c: point-level transform (mouse input)

    @Test("windowsPoint(from:) matches windowsRect(from:) for a zero-size rect at the same origin")
    func pointMatchesZeroSizeRect() {
        // A point and a zero-width/zero-height rect anchored at the same mac-space
        // location must produce the same Windows-space coordinate -- windowsRect's own
        // "- height" term is a no-op when height is 0, so the two formulas coincide
        // exactly at this one boundary case, which is a cheap way to cross-check the new
        // point transform against the already-tested rect one without duplicating its
        // whole test matrix.
        let mac = MacPoint(x: 250, y: 640)
        let macAsRect = MacRect(x: mac.x, y: mac.y, width: 0, height: 0)

        let point = WindowGeometry.windowsPoint(from: mac, primaryMonitorHeight: Self.primaryHeight)
        let rect = WindowGeometry.windowsRect(from: macAsRect, primaryMonitorHeight: Self.primaryHeight)

        #expect(point.x == rect.x)
        #expect(point.y == rect.y)
    }

    @Test("windowsPoint(from:primaryMonitorHeight:) is the exact inverse of macPoint(from:primaryMonitorHeight:)",
          arguments: [
            WindowsPoint(x: 0, y: 0),
            WindowsPoint(x: 466, y: 489),                 // a plausible in-window click location
            WindowsPoint(x: -1920, y: -300),               // secondary monitor above-and-left of primary
            WindowsPoint(x: 250, y: 940),
            WindowsPoint(x: -37, y: 1200),
          ])
    func pointRoundTrip(_ original: WindowsPoint) {
        let mac = WindowGeometry.macPoint(from: original, primaryMonitorHeight: Self.primaryHeight)
        let roundTripped = WindowGeometry.windowsPoint(from: mac, primaryMonitorHeight: Self.primaryHeight)

        #expect(roundTripped == original)
    }

    @Test("a point on a monitor above-and-left of the primary (both coordinates negative in Windows space) round-trips correctly")
    func pointMultiMonitorNegativeCoordinates() {
        // A 1920x1080 secondary monitor docked above-and-left of the primary: any point on
        // it has BOTH Windows-space coordinates negative (x < 0 from being left of the
        // primary's left edge, y < 0 from being above the primary's top edge).
        let original = WindowsPoint(x: -960, y: -540)
        let mac = WindowGeometry.macPoint(from: original, primaryMonitorHeight: Self.primaryHeight)

        // Windows y=-540 is 540px above the primary's top edge (Windows y=0); in mac space
        // (bottom-left origin, Y up) the primary's top edge is at y=primaryMonitorHeight,
        // so this point must land 540px *above* that.
        #expect(mac == MacPoint(x: -960, y: Self.primaryHeight + 540))

        let roundTripped = WindowGeometry.windowsPoint(from: mac, primaryMonitorHeight: Self.primaryHeight)
        #expect(roundTripped == original)
    }

    // W4c review M1: the point-level transform's own primaryMonitorHeight-scaling
    // coverage, mirroring tallerPrimaryMonitor()/macYScalesLinearlyWithPrimaryMonitorHeight()
    // above for the rect side -- without this, a caller could hardcode 1080 inside
    // macPoint(from:primaryMonitorHeight:)/windowsPoint(from:primaryMonitorHeight:) and every
    // *other* point test above would still pass (they all use Self.primaryHeight == 1080
    // exclusively), silently breaking any real screen whose primary monitor isn't 1080
    // tall.

    @Test("macPoint(from:primaryMonitorHeight:) against a taller (1440p) primary monitor produces the same shape, anchored differently")
    func pointTallerPrimaryMonitor() {
        // Same worked point as pointRoundTrip's "plausible in-window click location" case,
        // but against a 2560x1440 primary instead of 1920x1080.
        let windowsPoint = WindowsPoint(x: 466, y: 489)
        let mac = WindowGeometry.macPoint(from: windowsPoint, primaryMonitorHeight: 1440)

        #expect(mac == MacPoint(x: 466, y: 1440 - 489))
    }

    @Test("the same Windows point maps to mac Y values that differ by exactly the height delta between two primary monitor heights",
          arguments: [
            WindowsPoint(x: 0, y: 0),
            WindowsPoint(x: -960, y: -540),
            WindowsPoint(x: 466, y: 489),
          ])
    func pointYScalesLinearlyWithPrimaryMonitorHeight(_ windowsPoint: WindowsPoint) {
        let heightA = Self.primaryHeight // 1080
        let heightB = 1440.0

        let macA = WindowGeometry.macPoint(from: windowsPoint, primaryMonitorHeight: heightA)
        let macB = WindowGeometry.macPoint(from: windowsPoint, primaryMonitorHeight: heightB)

        // macPoint.y = primaryMonitorHeight - windowsPoint.y, so changing only
        // primaryMonitorHeight shifts mac.y by exactly the same delta -- x must not move.
        #expect(macB.y - macA.y == heightB - heightA)
        #expect(macA.x == macB.x)
    }

    // TODO: RAIL's actual wire representation for window/monitor coordinates is INT32
    // (MS-RDPERP window order fields), not a floating-point type. WindowsRect/MacRect are
    // Double today because nothing upstream of this package has been wired up to hand
    // over real RAIL geometry yet (adr/0005's event queue work is still ahead of this).
    // Once that lands, consider whether WindowGeometry should model coordinates as Int32
    // directly rather than converting at the boundary — for now this test only pins down
    // that integer-valued inputs round-trip exactly (no accumulated floating-point drift
    // from the two flip operations), which is the property an Int32 model would need to
    // preserve trivially.
    @Test("round trip is exact for integer-valued coordinates (stand-in for RAIL's INT32 wire type)",
          arguments: [
            WindowsRect(x: 0, y: 0, width: 1, height: 1),
            // Near INT32's range boundary — these are integer literals, not derived via
            // `/ 2` (which would silently promote to floating-point division here and
            // produce a .5 fraction, defeating the "integer-valued input" premise).
            WindowsRect(x: -1073741824, y: 1073741823, width: 1920, height: 1080),
            WindowsRect(x: 37, y: -940, width: 640, height: 480),
          ])
    func integerRoundTrip(_ original: WindowsRect) {
        let primaryMonitorHeight = 2160.0
        let mac = WindowGeometry.macRect(from: original, primaryMonitorHeight: primaryMonitorHeight)
        let roundTripped = WindowGeometry.windowsRect(from: mac, primaryMonitorHeight: primaryMonitorHeight)

        #expect(roundTripped == original)
        #expect(roundTripped.x == roundTripped.x.rounded())
        #expect(roundTripped.y == roundTripped.y.rounded())
    }

    @Test("width and height are never touched by the conversion")
    func dimensionsUnchanged() {
        let windowsRect = WindowsRect(x: -500, y: -500, width: 1234.5, height: 567.25)
        let mac = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryHeight)

        #expect(mac.width == windowsRect.width)
        #expect(mac.height == windowsRect.height)
    }
}
