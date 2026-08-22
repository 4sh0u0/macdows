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

    // MARK: - Phase 2 W3 round 3: WindowGeometryCorrection (RAIL-size vs GFX-mapped-display-size)

    /// `railRect(from:correction:)` is the exact inverse of `displayRect(from:correction:)`
    /// for ANY signed correction, including the current all-zero-origin one -- team-lead
    /// review's own request: this property must hold no matter what `correction`'s values
    /// turn out to be, so a future edit that gives `displayRect`/`railRect` mismatched signs
    /// (exactly the bug this whole fix round corrects) fails here before it ever reaches a
    /// real host.
    @Test("railRect(from:correction:) is the exact inverse of displayRect(from:correction:)",
          arguments: [
            WindowGeometryCorrection.zero,
            // This fix's own real-host origin: About window, offsetX=338 offsetY=62
            // windowWidth=494 windowHeight=500 against a GFX-mapped visible size of
            // 508x507 -- mapped - RAIL = (+14, +7).
            WindowGeometryCorrection(originX: 0, originY: 0, width: 14, height: 7),
            // A hypothetical future negative correction (mapped SMALLER than RAIL) --
            // nothing in either function's own math assumes the sign, so this must round-trip
            // exactly the same way.
            WindowGeometryCorrection(originX: 0, originY: 0, width: -20, height: -3),
            // A hypothetical nonzero origin correction (W4's shaped-window work, per this
            // type's own doc comment on why origin is zero FOR NOW, not structurally absent).
            WindowGeometryCorrection(originX: 5, originY: -12, width: 14, height: 7),
          ])
    func railDisplayRoundTripIsIdentity(_ correction: WindowGeometryCorrection) {
        let rail = WindowsRect(x: 338, y: 62, width: 494, height: 500)
        let displayed = WindowGeometry.displayRect(from: rail, correction: correction)
        let roundTripped = WindowGeometry.railRect(from: displayed, correction: correction)

        #expect(roundTripped == rail)
    }

    /// This fix's own real-host measurement, pinned down as an explicit example (not just
    /// covered incidentally by the round-trip property above): the About window's real RAIL
    /// rect, corrected by the real measured delta, produces the exact GFX-mapped size --
    /// documents the actual numbers this whole correction mechanism exists for.
    @Test("the real-host measured correction turns RAIL's reported size into the GFX-mapped displayed size")
    func realHostMeasurementProducesDisplayedSize() {
        let rail = WindowsRect(x: 338, y: 62, width: 494, height: 500)
        let correction = WindowGeometryCorrection(originX: 0, originY: 0, width: 14, height: 7)

        let displayed = WindowGeometry.displayRect(from: rail, correction: correction)

        #expect(displayed.width == 508)
        #expect(displayed.height == 507)
        // Origin correction is zero -- the anchor (top-left in Windows space) does not move,
        // only the size grows, extending toward increasing X/Y (right/down).
        #expect(displayed.x == rail.x)
        #expect(displayed.y == rail.y)
    }

    /// Team-lead review round 4 (2026-08-23, real-host move-leg mismatch after round 3's
    /// mapped-canonical fix): reproduces `RemoteWindowRegistry.handleLocalGeometrySettled`'s
    /// EXACT outbound conversion chain (mac content rect -> `windowsRect(from:
    /// primaryMonitorHeight:)` -> `railRect(from:correction:)` -> rounded left/top/right/
    /// bottom), step for step, using this run's own real numbers -- offline, no host needed,
    /// per the team-lead's own instruction that this test's verdict decides whether another
    /// host round is even necessary before fixing.
    ///
    /// Real-host inputs: local drag settled at mac content rect `(331, 917, 536, 521)`
    /// (the harness's own move target: original `(251, 857)` + `(80, 60)`),
    /// `primaryMonitorHeight = 1440`, `correction = (width: 14, height: 7)` (this window's
    /// own measured mapped-minus-RAIL delta, unchanged by a pure move).
    ///
    /// THE ALGEBRA, worked by hand and then asserted by this test:
    /// 1. `windowsRect(from: macRect(331,917,536,521), primaryMonitorHeight: 1440)`:
    ///    `y = 1440 - 917 - 521 = 2`. -> `WindowsRect(x: 331, y: 2, width: 536, height: 521)`.
    /// 2. `railRect(from: that, correction: (14, 7))`: `width = 536-14 = 522`,
    ///    `height = 521-7 = 514`, origin unchanged (zero origin correction).
    ///    -> `WindowsRect(x: 331, y: 2, width: 522, height: 514)`.
    /// 3. `left=331 top=2 right=331+522=853 bottom=2+514=516`.
    ///
    /// VERDICT: this is the MATHEMATICALLY CORRECT `ClientWindowMove` rect for this move --
    /// `left`/`top` land exactly on the intended target, and `width`/`height` (522x514)
    /// exactly reproduce this window's PRE-move RAIL size, unchanged, which is precisely
    /// correct for a pure move (no resize). Today's pure conversion functions have NO BUG
    /// reproducible from this input. The real-host mismatch this test was written to
    /// investigate (server echoed `offsetX=338 offsetY=62 windowWidth=522 windowHeight=514`,
    /// NOT `left=331 top=2` -- `top` exactly matches this window's ORIGINAL pre-move
    /// `offsetY`, as if Y never moved at all, while X overshot by exactly this window's own
    /// width-correction magnitude, +7) must therefore come from EITHER (a) a different
    /// `contentRect` actually reaching `handleLocalGeometrySettled` than the harness's own
    /// intended target (something upstream of this pure math, in `RemoteWindow`'s settle
    /// path or AppKit's own frame bookkeeping, diverged), or (b) the observed "echo" is not
    /// actually a direct confirmation of this specific move at all -- a stale/out-of-sequence
    /// WindowUpdate, exactly the possibility flagged for the next host run's timestamped log
    /// to distinguish (see `Tools/window-smoke`'s own `[move-resize] sent ClientWindowMove`
    /// log line added alongside this test). This test's own passing result is what licenses
    /// looking there rather than at this file.
    ///
    /// Round 5 update (2026-08-23): the real host round confirmed this test's own "no bug
    /// reproducible from this input" verdict was correct as far as it went -- root cause (a)
    /// was real (an AppKit frame-clamp on Y, unrelated to this math) -- but ALSO surfaced a
    /// second, genuinely separate finding this test does NOT cover: `left` itself needs an
    /// additional, asymmetric, outbound-only correction beyond what `railRect(from:
    /// correction:)` computes (see `WindowGeometry.clientWindowMoveLeft`'s own doc comment).
    /// This test intentionally still asserts the OLD (pre-round-5) `left == 331` -- it is
    /// scoped to the SIZE-correction chain in isolation, not `handleLocalGeometrySettled`'s
    /// full current behavior; `clientWindowMoveLeftAppliesTheMeasuredBorder` below covers the
    /// round-5 addition on its own.
    @Test("handleLocalGeometrySettled's outbound chain reproduces the correct RAIL rect for this run's real move")
    func outboundConversionReproducesRealHostMove() {
        let macRect = MacRect(x: 331, y: 917, width: 536, height: 521)
        let primaryMonitorHeight = 1440.0
        let correction = WindowGeometryCorrection(originX: 0, originY: 0, width: 14, height: 7)

        let displayedWindowsRect = WindowGeometry.windowsRect(from: macRect, primaryMonitorHeight: primaryMonitorHeight)
        #expect(displayedWindowsRect == WindowsRect(x: 331, y: 2, width: 536, height: 521))

        let railWindowsRect = WindowGeometry.railRect(from: displayedWindowsRect, correction: correction)
        #expect(railWindowsRect == WindowsRect(x: 331, y: 2, width: 522, height: 514))

        let left = Int32(railWindowsRect.x.rounded())
        let top = Int32(railWindowsRect.y.rounded())
        let right = Int32((railWindowsRect.x + railWindowsRect.width).rounded())
        let bottom = Int32((railWindowsRect.y + railWindowsRect.height).rounded())

        // The mathematically correct target: left/top hit the intended position exactly;
        // width (right-left) and height (bottom-top) exactly reproduce this window's
        // PRE-move RAIL size (522x514), unchanged -- correct for a pure move.
        #expect(left == 331)
        #expect(top == 2)
        #expect(right == 853)
        #expect(bottom == 516)
        #expect(right - left == 522)
        #expect(bottom - top == 514)

        // The ACTUAL real-host echo this test was written to investigate, pinned down as a
        // negative example: today's code does NOT (and per the algebra above, could not)
        // produce this from the given input -- left=338/top=62 is not reachable from a
        // correct application of this fix's own math to this move's real target.
        #expect(left != 338)
        #expect(top != 62)
    }

    /// Team-lead review round 5 (2026-08-23): the actual real-host cause of the round-4
    /// investigation's `left` mismatch, worked and checked here offline. See
    /// `WindowGeometry.clientWindowMoveLeft`'s own doc comment for the full algebra this
    /// test exercises -- summarized: THREE separate runs each sent `left=331` and got back
    /// `offsetX=338` on the very next `WindowUpdate`, a clean +7 every time. The evidence's
    /// own causal chain (worked in the production function's doc comment) implies the
    /// server treats a sent `left` as the window's OUTER rect, inset from the VISIBLE rect
    /// `WindowUpdate.offsetX` reports by a measured 7pt left border -- so sending the
    /// visible target UNCORRECTED (331) makes the server's own reconstruction land 7pt too
    /// far right (338), and the fix must subtract that same 7pt before sending.
    @Test("clientWindowMoveLeft subtracts the measured left border, and the server's own outer->visible reconstruction (visible = outer + border, per this round's evidence) lands the round trip back on target")
    func clientWindowMoveLeftAppliesTheMeasuredBorder() {
        let visibleLeftTarget = 331.0
        let measuredLeftBorder = 7.0

        let sent = WindowGeometry.clientWindowMoveLeft(fromVisibleLeft: visibleLeftTarget, measuredLeftBorder: measuredLeftBorder)
        #expect(sent == 324)

        // Simulates the server's OWN outer->visible reconstruction, per this round's
        // evidence (visible = outer + border) -- not something this package can call
        // directly (it runs on the remote host), but this is exactly the arithmetic that
        // reproduces the observed 331->338 pair when `sent` is fed through it, confirming
        // the correction actually closes the loop rather than merely looking plausible.
        let serverReconstructedVisible = sent + measuredLeftBorder
        #expect(serverReconstructedVisible == visibleLeftTarget)

        // The UNCORRECTED value (matching round 4's `left == 331` test above) is exactly
        // what produced the observed overshoot -- pinned down as a negative example so a
        // future edit can't silently reintroduce sending the raw visible target.
        let uncorrectedReconstruction = visibleLeftTarget + measuredLeftBorder
        #expect(uncorrectedReconstruction == 338) // the actual observed echo, 3 runs running
    }
}
