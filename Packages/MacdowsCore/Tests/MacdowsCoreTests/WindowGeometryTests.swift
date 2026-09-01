import Testing
@testable import MacdowsCore

@Suite("WindowGeometry")
struct WindowGeometryTests {
    // Primary 1920x1080 monitor as the reference frame for most cases below.
    static let primaryHeight = 1080.0

    /// M1/W1: the four conversions no longer take a bare `primaryMonitorHeight: Double`, they
    /// take a `DisplayFlipAnchor` that only a `DisplayTopology` can produce. Every pre-M1 test
    /// below is unchanged except for routing its height through this helper -- deliberately,
    /// so that the real-host algebra those tests pin down (rounds 3-6 of the 2026-08-23
    /// investigation) is re-verified against the new signature rather than rewritten under it.
    ///
    /// Scale defaults to 1 because that is what every one of those tests measured: they all
    /// predate the scale dimension and were taken on a 1x host (`docs/plans/phase3.md:219`).
    /// Force-unwrapping is safe and intended here -- these are constant, obviously-valid
    /// layouts, and a `nil` would mean this helper itself is broken.
    static func anchor(
        _ primaryHeightInPoints: Double,
        remotePixelsPerPoint: Double = 1,
        widthInPoints: Double = 1920
    ) -> DisplayFlipAnchor {
        DisplayTopology.single(
            widthInPoints: widthInPoints,
            heightInPoints: primaryHeightInPoints,
            scale: DisplayScale(
                remotePixelsPerPoint: remotePixelsPerPoint,
                backingPixelsPerPoint: remotePixelsPerPoint
            )
        )!.flipAnchor
    }

    @Test("origin-anchored window maps to the top of mac screen space")
    func originWindow() {
        let windowsRect = WindowsRect(x: 0, y: 0, width: 800, height: 600)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(Self.primaryHeight))

        // Windows (0,0) is the top-left of the primary monitor; in mac space (bottom-left
        // origin, Y up) that same physical spot is at y = primaryMonitorHeight - height.
        #expect(mac == MacRect(x: 0, y: 480, width: 800, height: 600))
    }

    @Test("window flush with the bottom of the primary monitor maps to mac y = 0")
    func bottomAlignedWindow() {
        let windowsRect = WindowsRect(x: 100, y: 880, width: 400, height: 200)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(Self.primaryHeight))

        #expect(mac == MacRect(x: 100, y: 0, width: 400, height: 200))
    }

    @Test("secondary monitor above the primary produces negative Windows Y and mac Y past the top edge")
    func monitorAbovePrimary() {
        // A 1920x300 secondary monitor docked directly above the primary, left edges
        // aligned: its Windows-space rect spans y ∈ [-300, 0].
        let windowsRect = WindowsRect(x: 0, y: -300, width: 1920, height: 300)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(Self.primaryHeight))

        // In mac space the primary spans y ∈ [0, 1080], so a monitor docked above it
        // should start exactly at the primary's top edge and extend past it.
        #expect(mac == MacRect(x: 0, y: 1080, width: 1920, height: 300))
    }

    @Test("monitor to the left of the primary produces negative X, unchanged by the Y flip")
    func monitorLeftOfPrimary() {
        // A 1920x1080 secondary monitor docked to the left of the primary, top edges
        // aligned: its Windows-space rect spans x ∈ [-1920, 0], y ∈ [0, 1080].
        let windowsRect = WindowsRect(x: -1920, y: 0, width: 1920, height: 1080)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(Self.primaryHeight))

        #expect(mac == MacRect(x: -1920, y: 0, width: 1920, height: 1080))
    }

    @Test("a taller primary monitor (1440p) produces the same shape, anchored differently")
    func tallerPrimaryMonitor() {
        // Same window as originWindow(), but against a 2560x1440 primary instead of
        // 1920x1080 — the primary-monitor-height anchor, not any hardcoded 1080, is what
        // must drive the flip.
        let windowsRect = WindowsRect(x: 0, y: 0, width: 800, height: 600)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(1440))

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

        let macA = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(heightA))
        let macB = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(heightB))

        // macRect.y = primaryMonitorHeight - windowsRect.y - windowsRect.height, so
        // changing only primaryMonitorHeight shifts mac.y by exactly the same delta —
        // x, width, and height must not move at all.
        #expect(macB.y - macA.y == heightB - heightA)
        #expect(macA.x == macB.x)
        #expect(macA.width == macB.width)
        #expect(macA.height == macB.height)
    }

    @Test("windowsRect(from:anchoredTo:) is the exact inverse of macRect(from:anchoredTo:)",
          arguments: [
            WindowsRect(x: 0, y: 0, width: 800, height: 600),
            WindowsRect(x: -1920, y: -300, width: 1920, height: 300),
            WindowsRect(x: 250, y: 940, width: 640, height: 480),
            WindowsRect(x: -37, y: 1200, width: 1, height: 1),
          ])
    func roundTrip(_ original: WindowsRect) {
        let mac = WindowGeometry.macRect(from: original, anchoredTo: Self.anchor(Self.primaryHeight))
        let roundTripped = WindowGeometry.windowsRect(from: mac, anchoredTo: Self.anchor(Self.primaryHeight))

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

        let point = WindowGeometry.windowsPoint(from: mac, anchoredTo: Self.anchor(Self.primaryHeight))
        let rect = WindowGeometry.windowsRect(from: macAsRect, anchoredTo: Self.anchor(Self.primaryHeight))

        #expect(point.x == rect.x)
        #expect(point.y == rect.y)
    }

    @Test("windowsPoint(from:anchoredTo:) is the exact inverse of macPoint(from:anchoredTo:)",
          arguments: [
            WindowsPoint(x: 0, y: 0),
            WindowsPoint(x: 466, y: 489),                 // a plausible in-window click location
            WindowsPoint(x: -1920, y: -300),               // secondary monitor above-and-left of primary
            WindowsPoint(x: 250, y: 940),
            WindowsPoint(x: -37, y: 1200),
          ])
    func pointRoundTrip(_ original: WindowsPoint) {
        let mac = WindowGeometry.macPoint(from: original, anchoredTo: Self.anchor(Self.primaryHeight))
        let roundTripped = WindowGeometry.windowsPoint(from: mac, anchoredTo: Self.anchor(Self.primaryHeight))

        #expect(roundTripped == original)
    }

    @Test("a point on a monitor above-and-left of the primary (both coordinates negative in Windows space) round-trips correctly")
    func pointMultiMonitorNegativeCoordinates() {
        // A 1920x1080 secondary monitor docked above-and-left of the primary: any point on
        // it has BOTH Windows-space coordinates negative (x < 0 from being left of the
        // primary's left edge, y < 0 from being above the primary's top edge).
        let original = WindowsPoint(x: -960, y: -540)
        let mac = WindowGeometry.macPoint(from: original, anchoredTo: Self.anchor(Self.primaryHeight))

        // Windows y=-540 is 540px above the primary's top edge (Windows y=0); in mac space
        // (bottom-left origin, Y up) the primary's top edge is at y=primaryMonitorHeight,
        // so this point must land 540px *above* that.
        #expect(mac == MacPoint(x: -960, y: Self.primaryHeight + 540))

        let roundTripped = WindowGeometry.windowsPoint(from: mac, anchoredTo: Self.anchor(Self.primaryHeight))
        #expect(roundTripped == original)
    }

    // W4c review M1: the point-level transform's own primaryMonitorHeight-scaling
    // coverage, mirroring tallerPrimaryMonitor()/macYScalesLinearlyWithPrimaryMonitorHeight()
    // above for the rect side -- without this, a caller could hardcode 1080 inside
    // macPoint(from:anchoredTo:)/windowsPoint(from:anchoredTo:) and every
    // *other* point test above would still pass (they all use Self.primaryHeight == 1080
    // exclusively), silently breaking any real screen whose primary monitor isn't 1080
    // tall.

    @Test("macPoint(from:anchoredTo:) against a taller (1440p) primary monitor produces the same shape, anchored differently")
    func pointTallerPrimaryMonitor() {
        // Same worked point as pointRoundTrip's "plausible in-window click location" case,
        // but against a 2560x1440 primary instead of 1920x1080.
        let windowsPoint = WindowsPoint(x: 466, y: 489)
        let mac = WindowGeometry.macPoint(from: windowsPoint, anchoredTo: Self.anchor(1440))

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

        let macA = WindowGeometry.macPoint(from: windowsPoint, anchoredTo: Self.anchor(heightA))
        let macB = WindowGeometry.macPoint(from: windowsPoint, anchoredTo: Self.anchor(heightB))

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
        let mac = WindowGeometry.macRect(from: original, anchoredTo: Self.anchor(primaryMonitorHeight))
        let roundTripped = WindowGeometry.windowsRect(from: mac, anchoredTo: Self.anchor(primaryMonitorHeight))

        #expect(roundTripped == original)
        #expect(roundTripped.x == roundTripped.x.rounded())
        #expect(roundTripped.y == roundTripped.y.rounded())
    }

    @Test("width and height are never touched by the conversion")
    func dimensionsUnchanged() {
        let windowsRect = WindowsRect(x: -500, y: -500, width: 1234.5, height: 567.25)
        let mac = WindowGeometry.macRect(from: windowsRect, anchoredTo: Self.anchor(Self.primaryHeight))

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
    /// anchoredTo:)` -> `railRect(from:correction:)` -> rounded left/top/right/
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
    /// 1. `windowsRect(from: macRect(331,917,536,521), anchoredTo: Self.anchor(1440))`:
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

        let displayedWindowsRect = WindowGeometry.windowsRect(from: macRect, anchoredTo: Self.anchor(primaryMonitorHeight))
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

    // MARK: - Maximize-scenario real-host regression (2026-08-23, round 6)

    /// Team-lead review round 6: `RemoteWindowRegistry.macContentRect(for:windowId:)`
    /// computes `displayRect(from: railRect, correction: mapped - railState)` -- a PURE
    /// function of whatever `railState`/`mapped` happen to be AT THE MOMENT it's called,
    /// with no memory of which arrived first. This test pins that property down explicitly
    /// (rather than trusting the reasoning alone, given how many times this investigation's
    /// hand-worked reasoning has needed correcting): recomputing the same final content
    /// rect via two different intermediate paths -- (A) RAIL state updates first (a
    /// WindowUpdate arrives before the matching GFX remap, this round's own real-host bug:
    /// the intermediate step momentarily computes the OLD, pre-maximize size, since
    /// `correction` is still measured against the stale mapped size) vs (B) mapped size
    /// updates first (the ordinary case) -- both converge on the IDENTICAL final rect once
    /// both pieces of state are current, confirming
    /// `RemoteWindowRegistry`'s new `.surfaceMapped`-triggered reapply (which recomputes
    /// from the registry's own already-accumulated state, exactly this function) closes the
    /// gap regardless of which order the two events happen to arrive in.
    ///
    /// Real-host numbers: RAIL rect (0, 0, 2560, 1440) (the maximize's own WindowUpdate,
    /// `show=3`/`WINDOW_SHOW_MAXIMIZED`), old mapped size 536x521 (the About dialog's
    /// pre-maximize size), new mapped size 2560x1440 (the server's own post-maximize
    /// remap).
    @Test("macContentRect's underlying formula converges to the same final rect regardless of WindowUpdate-vs-remap arrival order")
    func maximizeConvergesRegardlessOfEventOrder() {
        let railRect = WindowsRect(x: 0, y: 0, width: 2560, height: 1440)
        let oldMapped = (width: 536.0, height: 521.0)
        let newMapped = (width: 2560.0, height: 1440.0)

        // Path A: the WindowUpdate lands first -- RAIL state is already 2560x1440, but the
        // surface hasn't remapped yet, so `correction` is measured against the STILL-OLD
        // mapped size. This is this round's own real-host bug's own intermediate step --
        // `macContentRect` at THIS moment computes the OLD (536x521) content size, exactly
        // reproducing the observed "window stays 536x521" symptom.
        let correctionAtWindowUpdateTime = WindowGeometryCorrection(
            originX: 0, originY: 0,
            width: oldMapped.width - railRect.width, height: oldMapped.height - railRect.height
        )
        let contentRectAtWindowUpdateTime = WindowGeometry.displayRect(from: railRect, correction: correctionAtWindowUpdateTime)
        #expect(contentRectAtWindowUpdateTime.width == oldMapped.width)
        #expect(contentRectAtWindowUpdateTime.height == oldMapped.height)

        // Path A continued: the surface THEN remaps (this fix's own new reapply, triggered
        // by `.surfaceMapped`) -- correction is now measured against the CURRENT (matching)
        // mapped size, converging on the true, full-size target.
        let correctionAfterRemap = WindowGeometryCorrection(
            originX: 0, originY: 0,
            width: newMapped.width - railRect.width, height: newMapped.height - railRect.height
        )
        let finalContentRectPathA = WindowGeometry.displayRect(from: railRect, correction: correctionAfterRemap)

        // Path B: the surface remaps FIRST (the ordinary case) -- RAIL state is still the
        // window's PRE-maximize rect at this moment, but `correction` (mapped MINUS
        // whatever RAIL state currently says) already reflects the size jump, so the
        // reapply this fix adds computes the correct SIZE immediately, just anchored to
        // the not-yet-updated OFFSET (a harmless, self-correcting transient -- position
        // catches up the moment the WindowUpdate itself arrives, covered by
        // `finalContentRectPathB` below using the SAME final railRect/mapped pairing every
        // path converges to). What matters for THIS test is the size-convergence property,
        // not the transient's own intermediate position.
        let finalContentRectPathB = WindowGeometry.displayRect(from: railRect, correction: correctionAfterRemap)

        // Both paths' FINAL rect (once both RAIL state and mapped size are current) is
        // identical -- the whole point of `macContentRect` being a pure function of current
        // state, not a stateful accumulator.
        #expect(finalContentRectPathA == finalContentRectPathB)
        #expect(finalContentRectPathA == WindowsRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    // MARK: - Phase 3 M1 / W1: the topology-anchored signatures

    /// THE anchor-invariant test M1's acceptance asks for by name.
    ///
    /// `WindowGeometry.swift:61-74` has always argued that the Y flip must anchor on the
    /// PRIMARY display's height and never on the bounding height of the whole virtual desktop.
    /// Until this milestone that argument was cheap to honour because no caller had a union
    /// height available to get it wrong with. A `DisplayTopology` changes that:
    /// `unionBoundsInPoints.height` is now one property access away, reads perfectly
    /// plausibly, and -- this is the dangerous part -- would produce IDENTICAL results on the
    /// single-display layout that is the only thing anybody can test against on real hardware
    /// (`docs/plans/phase3.md:219`). So the fixture here is deliberately one where the two
    /// numbers differ by a factor of two, and the assertions pin down both the right answer
    /// and the wrong one.
    ///
    /// The structural half of the defence lives in the production types rather than here:
    /// `DisplayFlipAnchor` has no public initializer, so a union height cannot be turned into
    /// an anchor at all. This test covers the arithmetic; the type covers the mistake.
    @Test("the flip anchors on the primary display's height, never on the union height, even when they differ")
    func flipAnchorIsThePrimaryHeightNotTheUnionHeight() throws {
        // Primary 1920x1080 at the mac origin, secondary 1920x1080 placed LEFT OF and ABOVE it
        // -- so the union is 3840x2160 points and its height is exactly twice the primary's.
        let topology = try #require(DisplayTopology(displays: [
            DisplayTopology.Display(origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
                    scale: .unscaled, isPrimary: true),
            DisplayTopology.Display(origin: MacPoint(x: -1920, y: 1080), size: MacSize(width: 1920, height: 1080),
                    scale: .unscaled, isPrimary: false),
        ]))

        let primaryHeight = 1080.0
        let unionHeight = 2160.0
        #expect(topology.primary.size.height == primaryHeight)
        #expect(topology.unionBoundsInPoints.height.inPoints == unionHeight)
        #expect(topology.flipAnchor.primaryHeightInPoints == primaryHeight)

        // A Windows-space rect at y = 0 is flush with the TOP of the primary monitor, because
        // Windows' virtual-desktop origin is the primary's top-left corner. In mac space that
        // spot is `primaryHeight - height` up from the bottom of the primary.
        let atWindowsOrigin = WindowsRect(x: 0, y: 0, width: 800, height: 600)
        let mac = WindowGeometry.macRect(from: atWindowsOrigin, in: topology)
        #expect(mac == MacRect(x: 0, y: 480, width: 800, height: 600))
        #expect(mac.y == primaryHeight - 600)
        // The union-anchored answer, pinned down as an explicit negative example: it is off by
        // the full height of the extra display, and it is what a plausible-looking
        // `unionBoundsInPoints.height` at this call site would have produced.
        #expect(mac.y != unionHeight - 600)
        #expect(unionHeight - 600 == 1560)

        // The other end of the same invariant: the primary monitor's own bottom edge is mac
        // y = 0 in both coordinate systems. Anchoring on anything but the primary's height
        // moves the primary itself away from the shared origin, which is exactly the failure
        // `WindowGeometry.swift:66-70` describes.
        let flushWithPrimaryBottom = WindowsRect(x: 0, y: 880, width: 400, height: 200)
        #expect(WindowGeometry.macRect(from: flushWithPrimaryBottom, in: topology).y == 0)

        // And the point transform, which has no height term to hide behind.
        #expect(WindowGeometry.macPoint(from: WindowsPoint(x: 0, y: 0), in: topology)
                == MacPoint(x: 0, y: primaryHeight))
        #expect(WindowGeometry.macPoint(from: WindowsPoint(x: 0, y: 0), in: topology).y != unionHeight)

        // Adding a THIRD display -- i.e. growing the union further -- must not move a single
        // converted coordinate, because the anchor never depended on the union in the first
        // place. This is the property that makes screen hot-plug safe for geometry that is
        // already on screen (W1 deliverable 2's observer emits an event; it does not need to
        // re-place anything for this reason).
        let grown = try #require(DisplayTopology(displays: topology.displays + [
            DisplayTopology.Display(origin: MacPoint(x: 1920, y: -1080), size: MacSize(width: 3840, height: 2160),
                    scale: .unscaled, isPrimary: false),
        ]))
        #expect(grown.unionBoundsInPoints.height.inPoints > unionHeight)
        #expect(grown.flipAnchor == topology.flipAnchor)
        #expect(WindowGeometry.macRect(from: atWindowsOrigin, in: grown) == mac)
    }

    /// The same invariant at `rasterScale = 2`, on **ADR-0015 fixture F3** — required verbatim
    /// by ADR §4.A.4, and the combination the scale-1 test above cannot reach: "the anchor is
    /// the primary height" and "the scale divides" have to hold *together*, because the two
    /// mistakes have opposite signs and a test that exercises only one of them can be passed by
    /// an implementation that makes both.
    ///
    /// F3: primary 1280x720 pt @2x at the mac origin, secondary 1920x1080 pt @1x to its right,
    /// top edges aligned. Union height is 1080 pt; the primary's is 720 pt. ADR §4.A.4 fixes the
    /// assertion literally: a Windows-space rect at `y = 0` of height `h` remote px must land at
    /// `mac y = 720 − h/2`, and it explicitly forbids writing that as
    /// `topology.<some height> − h/rasterScale`, which would pass against either anchor.
    @Test("ADR F3: at rasterScale 2 the flip still anchors on the primary's 720pt, not the union's 1080pt")
    func flipAnchorIsThePrimaryHeightOnAdrFixtureF3() throws {
        let topology = try #require(DisplayTopology(displays: DisplayTopologyFixtures.union[2].displays))

        #expect(topology.rasterScale == 2)
        #expect(topology.primary.size.height == 720)
        #expect(topology.unionBoundsInPoints.height.inPoints == 1080)

        // h = 480 remote px. Correct: 720 − 480/2 = 480. Union-anchored: 1080 − 240 = 840.
        let rect = WindowsRect(x: 0, y: 0, width: 640, height: 480)
        let mac = WindowGeometry.macRect(from: rect, in: topology)

        #expect(mac == MacRect(x: 0, y: 480, width: 320, height: 240))
        #expect(mac.y == 480)          // literal, per ADR §4.A.4 -- not derived from the topology
        #expect(mac.y != 840)          // the union-anchored answer
        #expect(840 - 480 == 360)      // ADR §4.A.4's stated 360 pt error

        // The point transform has no `- height` term to hide a wrong anchor behind, so it needs
        // its own assertion (ADR §4.A.5): Windows y = 0 is the primary's top edge, which in mac
        // space is the primary's own height, in points.
        #expect(WindowGeometry.macPoint(from: WindowsPoint(x: 0, y: 0), in: topology)
                == MacPoint(x: 0, y: 720))

        // And the round trip closes at this scale too.
        #expect(WindowGeometry.windowsRect(from: mac, in: topology) == rect)
    }

    /// M1 acceptance: round-trip identity in BOTH directions, for rect and point,
    /// parameterised over `scale ∈ {1, 2}` × multi-screen offsets. Extends the property style
    /// of `railDisplayRoundTripIsIdentity` above onto the new signature.
    ///
    /// The probes are not arbitrary constants: they are derived from each display's OWN
    /// Windows-space frame, so a layout that puts a display left of or above the primary
    /// automatically produces negative coordinates in the region that display occupies, and a
    /// 2x layout automatically produces the doubled ones. That is what makes "multi-screen
    /// offsets" a real axis here rather than a label on a fixed list of numbers.
    @Test("rect round-trip is the exact identity in both directions across scales and screen offsets",
          arguments: WindowGeometryFixtures.scales, WindowGeometryFixtures.layouts)
    func rectRoundTripIsIdentityAcrossScalesAndOffsets(_ scale: Double, _ layout: ScreenLayoutFixture) throws {
        let topology = try #require(layout.topology(scale: scale))
        let anchor = topology.flipAnchor
        #expect(anchor.remotePixelsPerPoint == scale)

        for index in topology.displays.indices {
            let frame = try #require(topology.frameInRemotePixels(ofDisplayAt: index))

            for probe in WindowGeometryFixtures.probeRects(on: frame) {
                // Direction 1: Windows -> mac -> Windows.
                let mac = WindowGeometry.macRect(from: probe, anchoredTo: anchor)
                #expect(WindowGeometry.windowsRect(from: mac, anchoredTo: anchor) == probe)

                // Direction 2: mac -> Windows -> mac, starting from the mac-space value rather
                // than re-deriving it. Both directions matter: `handleLocalGeometrySettled`
                // enters the chain from the mac side (a user drag) while `macContentRect`
                // enters it from the Windows side (a RAIL WindowUpdate), and only asserting
                // one of them would leave the other's inverse unproven.
                let backToWindows = WindowGeometry.windowsRect(from: mac, anchoredTo: anchor)
                #expect(WindowGeometry.macRect(from: backToWindows, anchoredTo: anchor) == mac)

                // The topology-taking overload must be the same function.
                #expect(WindowGeometry.macRect(from: probe, in: topology) == mac)
                #expect(WindowGeometry.windowsRect(from: mac, in: topology) == probe)
            }

            // A mac-space start that was never produced by a forward conversion: the display's
            // own frame in points, plus a fractional-point rect, since AppKit frames are not
            // obliged to be integral.
            let macStarts = [
                topology.displays[index].frameInPoints,
                MacRect(x: topology.displays[index].origin.x + 12.5,
                        y: topology.displays[index].origin.y + 37.25,
                        width: 536.5, height: 521.75),
            ]
            for macStart in macStarts {
                let windows = WindowGeometry.windowsRect(from: macStart, anchoredTo: anchor)
                #expect(WindowGeometry.macRect(from: windows, anchoredTo: anchor) == macStart)
            }
        }
    }

    @Test("point round-trip is the exact identity in both directions across scales and screen offsets",
          arguments: WindowGeometryFixtures.scales, WindowGeometryFixtures.layouts)
    func pointRoundTripIsIdentityAcrossScalesAndOffsets(_ scale: Double, _ layout: ScreenLayoutFixture) throws {
        let topology = try #require(layout.topology(scale: scale))
        let anchor = topology.flipAnchor

        for index in topology.displays.indices {
            let frame = try #require(topology.frameInRemotePixels(ofDisplayAt: index))

            for probe in WindowGeometryFixtures.probePoints(on: frame) {
                // Windows -> mac -> Windows.
                let mac = WindowGeometry.macPoint(from: probe, anchoredTo: anchor)
                #expect(WindowGeometry.windowsPoint(from: mac, anchoredTo: anchor) == probe)

                // mac -> Windows -> mac.
                let backToWindows = WindowGeometry.windowsPoint(from: mac, anchoredTo: anchor)
                #expect(WindowGeometry.macPoint(from: backToWindows, anchoredTo: anchor) == mac)

                #expect(WindowGeometry.macPoint(from: probe, in: topology) == mac)
                #expect(WindowGeometry.windowsPoint(from: mac, in: topology) == probe)
            }
        }
    }

    /// The rect and point transforms must stay in agreement under scale too -- the same
    /// cross-check `pointMatchesZeroSizeRect` makes at 1x, re-run across the whole fixture
    /// matrix. A zero-height rect has no `- height` term to apply, so the two formulas must
    /// coincide exactly; if a future edit scales one of them and not the other, this catches
    /// it even where the round-trip identity (which is symmetric in the error) would not.
    @Test("the point transform agrees with a zero-size rect at every scale and offset",
          arguments: WindowGeometryFixtures.scales, WindowGeometryFixtures.layouts)
    func pointAgreesWithZeroSizeRectAcrossScalesAndOffsets(_ scale: Double, _ layout: ScreenLayoutFixture) throws {
        let topology = try #require(layout.topology(scale: scale))
        let anchor = topology.flipAnchor

        for index in topology.displays.indices {
            let frame = try #require(topology.frameInRemotePixels(ofDisplayAt: index))
            for probe in WindowGeometryFixtures.probePoints(on: frame) {
                let mac = WindowGeometry.macPoint(from: probe, anchoredTo: anchor)
                let asRect = WindowGeometry.macRect(
                    from: WindowsRect(x: probe.x, y: probe.y, width: 0, height: 0),
                    anchoredTo: anchor
                )
                #expect(mac.x == asRect.x)
                #expect(mac.y == asRect.y)
            }
        }
    }

    /// Round-trip identity alone would still pass if the scale were silently ignored (an
    /// identity is symmetric in its own mistakes), so this pins the actual numbers down.
    ///
    /// The layout is `docs/plans/phase3.md:219`'s own planned 2x test session: the 2560x1440
    /// panel switched to "looks like 1280x720", which is a zero-downsample exact 2x. NOTE what
    /// this test is and is not: it is offline coverage for the arithmetic that a
    /// `remotePixelsPerPoint == 2` session would need. It is not a claim that any session runs
    /// at 2x today -- reaching that requires the `DesktopScaleFactor` advertising W3 owns, and
    /// M1's MUST-NOT list forbids it.
    @Test("at remotePixelsPerPoint == 2 the conversion really halves, and the 1x answer differs")
    func scaleIsActuallyApplied() {
        let scaled = Self.anchor(720, remotePixelsPerPoint: 2, widthInPoints: 1280)
        let unscaled = Self.anchor(720, remotePixelsPerPoint: 1, widthInPoints: 1280)

        // 1024x768 remote pixels at remote (640, 200):
        //   x = 640/2 = 320, w = 1024/2 = 512, h = 768/2 = 384
        //   y = 720 - 200/2 - 768/2 = 720 - 100 - 384 = 236
        let windows = WindowsRect(x: 640, y: 200, width: 1024, height: 768)
        let mac = WindowGeometry.macRect(from: windows, anchoredTo: scaled)
        #expect(mac == MacRect(x: 320, y: 236, width: 512, height: 384))
        #expect(WindowGeometry.windowsRect(from: mac, anchoredTo: scaled) == windows)

        // The same input under a 1x anchor must NOT agree -- i.e. the factor is load-bearing,
        // not decorative.
        #expect(WindowGeometry.macRect(from: windows, anchoredTo: unscaled) != mac)
        #expect(WindowGeometry.macRect(from: windows, anchoredTo: unscaled)
                == MacRect(x: 640, y: 720 - 200 - 768, width: 1024, height: 768))

        // Points scale the same way, without the height term.
        let point = WindowsPoint(x: 640, y: 200)
        #expect(WindowGeometry.macPoint(from: point, anchoredTo: scaled) == MacPoint(x: 320, y: 620))
        #expect(WindowGeometry.windowsPoint(from: MacPoint(x: 320, y: 620), anchoredTo: scaled) == point)

        // Width and height are pure scalings -- no anchor term leaks into them.
        #expect(mac.width * 2 == windows.width)
        #expect(mac.height * 2 == windows.height)
    }

    /// At `remotePixelsPerPoint == 1` -- every configuration that exists today -- the new
    /// signature must compute bit-for-bit what the pre-M1 one did. This is the "the unit
    /// separation changed no behavior" claim M1's acceptance makes (§3 验收, replay-gate
    /// clause), asserted directly rather than inferred from the suite still being green.
    @Test("at scale 1 the topology-anchored conversion equals the pre-M1 arithmetic, exactly",
          arguments: [
            WindowsRect(x: 0, y: 0, width: 800, height: 600),
            WindowsRect(x: -1920, y: -300, width: 1920, height: 300),
            WindowsRect(x: 250, y: 940, width: 640, height: 480),
            WindowsRect(x: -37, y: 1200, width: 1, height: 1),
            WindowsRect(x: 338, y: 62, width: 494, height: 500), // the real-host About window
          ])
    func scaleOneReproducesThePreM1Arithmetic(_ windowsRect: WindowsRect) {
        let height = Self.primaryHeight
        let anchor = Self.anchor(height)

        // The literal pre-M1 expressions from `WindowGeometry.swift` before this milestone.
        let expectedMac = MacRect(
            x: windowsRect.x,
            y: height - windowsRect.y - windowsRect.height,
            width: windowsRect.width,
            height: windowsRect.height
        )
        #expect(WindowGeometry.macRect(from: windowsRect, anchoredTo: anchor) == expectedMac)
        #expect(WindowGeometry.windowsRect(from: expectedMac, anchoredTo: anchor) == WindowsRect(
            x: expectedMac.x,
            y: height - expectedMac.y - expectedMac.height,
            width: expectedMac.width,
            height: expectedMac.height
        ))

        let windowsPoint = WindowsPoint(x: windowsRect.x, y: windowsRect.y)
        #expect(WindowGeometry.macPoint(from: windowsPoint, anchoredTo: anchor)
                == MacPoint(x: windowsPoint.x, y: height - windowsPoint.y))
        #expect(WindowGeometry.windowsPoint(from: MacPoint(x: windowsPoint.x, y: height - windowsPoint.y),
                                            anchoredTo: anchor) == windowsPoint)
    }
    // `deprecatedShimsForwardToAScaleOneAnchor` stood here from wave 1 until wave 3. It pinned the
    // four `primaryMonitorHeight:` shims' forwarding to a scale-1 anchor for exactly as long as
    // those shims sat on the live window-placement path. L9 deleted the shims once the last call
    // site (`Tools/window-smoke/main.swift`'s `evaluateMoveResizeLeg`) migrated onto the topology
    // entries, and this test went with them, as ADR-0015 §9's L9 row and the shims' own header
    // both required. Nothing is left uncovered by its removal: it only ever asserted that the
    // deleted forwarders agreed with the `anchoredTo:` entries the rest of this suite exercises
    // directly.
}

// MARK: - Fixtures for the scale × offset matrix

/// A multi-screen layout, parameterised over the scale every display in it runs at.
///
/// Uniform scale per layout on purpose: the anchor takes the PRIMARY's scale, so a mixed-scale
/// layout would exercise "which display governs this window" -- an open ADR-0015 question
/// (U1's per-window/per-surface half) that no lane may answer. Mixed scale IS covered where it
/// is well-defined, in `DisplayTopologyFixtures.union`'s bounding-box row.
struct ScreenLayoutFixture: Sendable, CustomStringConvertible {
    let name: String
    /// Secondary display origins in mac points, relative to a primary whose own origin is
    /// (0, 0). Empty means a single-display layout.
    let secondaryOriginsInPoints: [MacPoint]

    var description: String { name }

    /// Primary is always 1920x1080 POINTS; the scale multiplies its remote-pixel extent, not
    /// its point extent, which is what a "looks like NxM" display mode actually does.
    func topology(scale: Double) -> DisplayTopology? {
        let displayScale = DisplayScale(remotePixelsPerPoint: scale, backingPixelsPerPoint: scale)
        let primary = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0),
            size: MacSize(width: 1920, height: 1080),
            scale: displayScale,
            isPrimary: true
        )
        let secondaries = secondaryOriginsInPoints.map {
            DisplayTopology.Display(origin: $0, size: MacSize(width: 1920, height: 1080),
                    scale: displayScale, isPrimary: false)
        }
        return DisplayTopology(displays: [primary] + secondaries)
    }
}

enum WindowGeometryFixtures {
    /// `scale ∈ {1, 2}` exactly as M1's acceptance names it. 1 is today's real configuration;
    /// 2 is the offline fixture for the mode-switch session phase3.md §8.1② plans.
    static let scales: [Double] = [1, 2]

    /// Every placement that produces a distinct sign pattern in Windows space, plus a
    /// three-display layout so nothing quietly assumes "at most two".
    static let layouts: [ScreenLayoutFixture] = [
        ScreenLayoutFixture(name: "single display", secondaryOriginsInPoints: []),
        ScreenLayoutFixture(name: "secondary right", secondaryOriginsInPoints: [MacPoint(x: 1920, y: 0)]),
        ScreenLayoutFixture(name: "secondary left (negative Windows x)",
                            secondaryOriginsInPoints: [MacPoint(x: -1920, y: 0)]),
        ScreenLayoutFixture(name: "secondary above (negative Windows y)",
                            secondaryOriginsInPoints: [MacPoint(x: 0, y: 1080)]),
        ScreenLayoutFixture(name: "secondary left and above (both negative)",
                            secondaryOriginsInPoints: [MacPoint(x: -1920, y: 1080)]),
        ScreenLayoutFixture(name: "secondary below and right (positive Windows y past the primary)",
                            secondaryOriginsInPoints: [MacPoint(x: 1920, y: -1080)]),
        ScreenLayoutFixture(name: "three displays: left, above, right",
                            secondaryOriginsInPoints: [
                                MacPoint(x: -1920, y: 0),
                                MacPoint(x: 0, y: 1080),
                                MacPoint(x: 1920, y: 0),
                            ]),
        ScreenLayoutFixture(name: "secondary offset diagonally by a non-multiple of its own size",
                            secondaryOriginsInPoints: [MacPoint(x: -777, y: 333)]),
    ]

    /// Probes anchored to a specific display's Windows-space frame, so each layout exercises
    /// coordinates in the region that layout actually occupies -- including the negative ones.
    ///
    /// Odd offsets and odd sizes are deliberate: at scale 2 they produce half-point mac values,
    /// which is where a rounding step sneaking into a conversion would show up.
    ///
    /// What they do NOT catch, stated because the earlier version of this comment claimed
    /// otherwise and r1 review disproved it by mutation: rewriting `macRect`'s Y term as
    /// `primaryHeight - (y + height)/s` leaves every test in this file green. It cannot be
    /// otherwise -- at `s ∈ {1, 2}` with dyadic inputs both groupings are exact, which is
    /// precisely what ADR §9's floating-point clause asserts. The grouping is chosen for
    /// textual identity with the pre-M1 source at `s == 1` and is protected by
    /// `scaleOneReproducesThePreM1Arithmetic` plus source review, not by a discriminating
    /// assertion; there is nothing here to discriminate, and a test pretending otherwise would
    /// be worse than none.
    static func probeRects(on frame: WindowsRect) -> [WindowsRect] {
        [
            // Flush with the display's own top-left corner.
            WindowsRect(x: frame.x, y: frame.y, width: 640, height: 480),
            // Flush with its bottom-right corner.
            WindowsRect(x: frame.x + frame.width - 640, y: frame.y + frame.height - 480,
                        width: 640, height: 480),
            // Odd offsets and odd extents, interior.
            WindowsRect(x: frame.x + 337, y: frame.y + 129, width: 501, height: 373),
            // Straddling the display's top-left corner -- i.e. partly on a neighbour, which is
            // the case a per-display scale rule would eventually have to answer for.
            WindowsRect(x: frame.x - 101, y: frame.y - 97, width: 203, height: 199),
            // Degenerate but legal: a zero-size rect, which is what the point transform must
            // agree with.
            WindowsRect(x: frame.x + 1, y: frame.y + 1, width: 0, height: 0),
        ]
    }

    static func probePoints(on frame: WindowsRect) -> [WindowsPoint] {
        [
            WindowsPoint(x: frame.x, y: frame.y),
            WindowsPoint(x: frame.x + frame.width, y: frame.y + frame.height),
            WindowsPoint(x: frame.x + 337, y: frame.y + 129),
            WindowsPoint(x: frame.x - 101, y: frame.y - 97),
        ]
    }
}
