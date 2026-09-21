import AppKit
import MacdowsCore
import Testing

// F-R1 (`docs/upgrade-gate/2026-09-resize-leg-live.md:32`, running count in
// `docs/upgrade-gate/2026-09-scaledmap-next-step.md:101`): the left inset the server applies to a
// sent `ClientWindowMove` (modelled as DWM's invisible frame) depends on the window's Win32 STYLE -- 5 remote px
// for a `WS_THICKFRAME` window, 7 for the About dialog it was originally calibrated on, both
// measured on the same 1x host. `MacdowsCore.WindowGeometry.clientWindowMoveLeftBorder(
// forStyle:)` is that rule and `WindowGeometryTests` pins its arithmetic offline.
//
// WHY THIS SUITE EXISTS ANYWAY -- the WIRING is a separate claim from the rule. A call site
// that ignores the window's style and passes a fixed value still satisfies every MacdowsCore
// test, because those never call the registry (the About-target lane shipped exactly that
// kind of mutation-transparent call-site change -- review about-target-r1 I-1 and r2 I-1,
// `docs/reviews/2026-09-02-about-target/review-r1.md`). These tests drive the real
// `RemoteWindowRegistry` and read the VERBATIM rect it sends, so "the window's own style
// reached the deduction" is asserted rather than assumed.
//
// WHAT MAKES IT REACHABLE WITHOUT A PRODUCTION SEAM (the D7 boundary forbids test-motivated
// changes to the Sources, phase3.md:82/:171/:257) -- three facts, each checked in the code
// rather than assumed:
//   * `RemoteWindowRegistry.init(session:topologyProvider:)` already takes an injectable
//     `DisplayTopologyProviding`; `MacdowsCore.StaticDisplayTopologyProvider` is the fixture
//     conformer the package ships for exactly this.
//   * `-[CRSession initWithHost:user:password:program:]` only allocates this session's queues
//     and sets `CRSessionStateIdle` -- connecting is `-start`, which is never called here. With
//     no outbound queue, `-sendWindowMove:...` returns immediately, so the sent rect leaves the
//     process nowhere. NOTHING IN THIS SUITE CONTACTS ANY HOST, and the placeholder strings it
//     constructs the session with are empty.
//   * `onWindowMoveSent` is the registry's own pre-existing diagnostic hook (added for
//     window-smoke) and reports the four integers verbatim, without re-deriving them.
// The file header of `DisplayTopologyProviderTests` registers "the registry requires a live
// `CRSession` at init" as a boundary; that is what this suite narrows -- an *unstarted* session
// is enough, a connected one was never needed.
//
// COVERAGE BOUNDARIES, registered rather than worked around:
//   * `CRDPEvent` exposes every field `readonly` and vends no initializer that takes them
//     (`App/CRBridge/CRSession.h:41-283`), so a window order can only be synthesized by
//     overriding the getters in a subclass -- `WindowOrderStub` below. That is a test-local
//     construct; if `CRDPEvent` ever becomes `objc_subclassing_restricted` or its properties
//     stop being overridable, this suite stops compiling rather than silently degrading.
//   * The real deduction happens on remote-pixel values that came from an AppKit frame. On this
//     project's 1x, single-display hardware (phase3.md:219) the point/pixel factor is 1, so the
//     absolute numbers below would not discriminate a stray `rasterScale` factor. What they do
//     discriminate is the border term, which is what F-R1 changed -- and the expected value is
//     computed from the window's OWN post-move content rect, so no assumption about AppKit
//     chrome insets is baked in.
//   * Y/top and width/right are untouched by this lane and are asserted only as "unchanged by
//     the style", not against any measured host number.
@MainActor
@Suite("ClientWindowMove's left border is keyed on the window style (F-R1)")
struct RemoteWindowRegistryLeftBorderTests {
    /// A `WindowCreate` order with fields this test chooses. See the file header for why a
    /// subclass is the only way to build one.
    private final class WindowOrderStub: CRDPEvent {
        /// `WINDOW_ORDER_FIELD_*`, duplicated narrowly from the file-private `WindowOrderField`
        /// in `RemoteWindowRegistry.swift:36-51` -- the same "duplicate the bits, not the
        /// policy" precedent `Tools/window-smoke` follows for its own copy.
        static let fieldTitle: UInt32 = 0x0000_0004
        static let fieldStyle: UInt32 = 0x0000_0008
        static let fieldShow: UInt32 = 0x0000_0010
        static let fieldSize: UInt32 = 0x0000_0400
        static let fieldOffset: UInt32 = 0x0000_0800
        /// `WINDOW_SHOW` (freerdp/window.h) -- any nonzero value means shown.
        static let showNormal: UInt32 = 5

        private let id: UInt32
        private let styleBits: UInt32
        private let flags: UInt32
        private let railX: Int32
        private let railY: Int32
        private let railWidth: UInt32
        private let railHeight: UInt32

        /// - Parameter carriesStyleField: `false` models the case the seam's doc comment calls
        ///   out -- a window whose orders never set `WINDOW_ORDER_FIELD_STYLE`, leaving
        ///   `PendingWindowState.style` at its default 0.
        init(
            windowId: UInt32, style: UInt32, carriesStyleField: Bool = true,
            x: Int32, y: Int32, width: UInt32, height: UInt32
        ) {
            id = windowId
            styleBits = style
            railX = x
            railY = y
            railWidth = width
            railHeight = height
            var flags = Self.fieldOffset | Self.fieldSize | Self.fieldShow | Self.fieldTitle
            if carriesStyleField { flags |= Self.fieldStyle }
            self.flags = flags
            super.init()
        }

        override var kind: CRDPEventKind { .windowCreate }
        override var generation: UInt32 { 0 }
        override var windowId: UInt32 { id }
        override var fieldFlags: UInt32 { flags }
        override var style: UInt32 { styleBits }
        override var styleEx: UInt32 { 0 }
        override var ownerWindowId: UInt32 { 0 }
        override var title: String { "left-border-probe" }
        override var offsetX: Int32 { railX }
        override var offsetY: Int32 { railY }
        override var windowWidth: UInt32 { railWidth }
        override var windowHeight: UInt32 { railHeight }
        override var show: UInt32 { Self.showNormal }
    }

    /// F-R1's own target style: Notepad's `0x000F0000`
    /// (`WS_MAXIMIZEBOX | WS_MINIMIZEBOX | WS_THICKFRAME | WS_SYSMENU`).
    private static let thickFrameStyle: UInt32 = 0x000F_0000
    /// The About dialog's captured style, `WS_POPUP | WS_SYSMENU` -- no `WS_THICKFRAME`.
    private static let aboutStyle: UInt32 = 0x8008_0000

    /// A fixture layout, not this machine's: one 1920x1080 1x primary. Injected through the
    /// registry's existing provider parameter, so nothing here reads `NSScreen`.
    private static func fixtureTopology() throws -> DisplayTopology {
        try fixtureTopology(rasterScale: 1)
    }

    /// The same fixture layout at a chosen raster scale -- what rule R's cases need, since the
    /// rule's tolerance is `rasterScale - 1` and is therefore identically zero on the 1x layout
    /// every other case in this suite uses. Still a fixture and still injected: nothing here
    /// reads `NSScreen`, and the scale the REGISTRY converts with is this one, not the real
    /// display's (the windows themselves are ordinary AppKit windows on whatever screen the test
    /// host has -- which is exactly why every expectation below is derived from the settled
    /// content rect that is read back, never from an assumed one).
    private static func fixtureTopology(rasterScale: Double) throws -> DisplayTopology {
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: rasterScale, backingPixelsPerPoint: rasterScale),
            isPrimary: true
        )
        return try #require(DisplayTopology(displays: [display]))
    }

    private final class SentBox {
        var moves: [UInt32: (left: Int32, top: Int32, right: Int32, bottom: Int32)] = [:]
    }

    /// Builds a registry over an UNSTARTED session (see the file header) with the fixture
    /// topology, and returns it alongside the box its `onWindowMoveSent` records into.
    private static func makeRegistry() throws -> (RemoteWindowRegistry, SentBox) {
        try makeRegistry(advertisedDesktopScaleFactor: 0)
    }

    /// The same harness with this session's advertised `DesktopScaleFactor` set -- the value the
    /// App's own session setup assigns from `ScaleAdvertisement.productDefault(rasterScale:)`
    /// before `-start`, and the ONE input the registry's DPI-tier lookup reads (ADR-0018 §5.2
    /// 增补二 item 2). 0, the property's own default, is what an unstarted session carries when
    /// nothing was advertised, which is why the two pre-tier cases above go through the
    /// zero-argument spelling and keep their expectations unchanged.
    private static func makeRegistry(advertisedDesktopScaleFactor: UInt32) throws -> (RemoteWindowRegistry, SentBox) {
        try makeRegistry(advertisedDesktopScaleFactor: advertisedDesktopScaleFactor, topology: fixtureTopology())
    }

    /// The same harness over a chosen topology -- rule R's own cases need a 2x one. The two
    /// scales are deliberately SEPARATE arguments: `advertisedDesktopScaleFactor` is what the
    /// server was told (it picks the border column) and the topology's `rasterScale` is what
    /// this client converts with (it sets rule R's tolerance). The product pairs them, and the
    /// cases below pass the paired values; keeping them apart is what lets a future case break
    /// the pairing the way the fixture's own `none` knob does on a live 2x session.
    private static func makeRegistry(
        advertisedDesktopScaleFactor: UInt32, topology: DisplayTopology
    ) throws -> (RemoteWindowRegistry, SentBox) {
        let session = CRSession(host: "", user: "", password: "", program: "")
        session.advertisedDesktopScaleFactor = advertisedDesktopScaleFactor
        let registry = RemoteWindowRegistry(
            session: session, topologyProvider: StaticDisplayTopologyProvider(topology)
        )
        let box = SentBox()
        registry.onWindowMoveSent = { windowId, left, top, right, bottom in
            box.moves[windowId] = (left: left, top: top, right: right, bottom: bottom)
        }
        return (registry, box)
    }

    /// Moves `window` to `originX` and returns the content-rect X the registry will actually
    /// have converted -- read from AppKit itself rather than assumed equal to the frame's X, so
    /// no claim about this window's chrome insets is baked into the expectations.
    private static func moveAndReadSettledContentX(_ window: NSWindow, toOriginX originX: CGFloat) -> Double {
        Double(moveAndReadSettledContentRect(window, toOriginX: originX).origin.x)
    }

    /// The same move, returning the WHOLE settled content rect -- what the Y-axis case below
    /// needs, because the `top` the registry sends is a function of the rect's Y and height (the
    /// flip is about the far edge), not of its X.
    private static func moveAndReadSettledContentRect(_ window: NSWindow, toOriginX originX: CGFloat) -> NSRect {
        var frame = window.frame
        frame.origin.x = originX
        window.setFrame(frame, display: false)
        return window.contentRect(forFrameRect: window.frame)
    }

    /// Sets this window's CONTENT height and returns the content rect AppKit actually settled on
    /// -- rule R's cases need a content height they chose, because the artefact the rule exists
    /// for is precisely a content dimension that no longer converts back to the size the server
    /// reported. Goes through `frameRect(forContentRect:)` so no assumption about this window's
    /// titlebar height is baked in, and the caller asserts the returned height rather than
    /// trusting it: AppKit may constrain a frame, and a constrained one must fail the case
    /// loudly instead of quietly changing what is being measured.
    ///
    /// `-setFrame:display:` that changes the SIZE posts `didResize`, which feeds the same
    /// trailing-edge debounce `didMove` does (`RemoteWindow.handleLocalGeometryChanged`), so
    /// this settles exactly like the move helper above.
    ///
    /// THE ORIGIN IS MOVED TOO, and that is load-bearing rather than incidental: AppKit posts
    /// neither notification for a `setFrame:` that changes nothing, and the height this is
    /// called with may be the height the window already has -- a window created from a RAIL size
    /// of 917 remote px at `rasterScale == 2` is 458.5 points tall, which AppKit does not keep,
    /// so it may ALREADY have settled on 459 before this is called. Without the move, that case
    /// silently records no send at all and the test fails as a timeout instead of as an
    /// assertion (observed, first run of this case). It also makes the fixture the shape the
    /// rule is about: a MOVE leg on a window whose local height no longer converts back to the
    /// size the server reported.
    private static func moveAndResizeAndReadSettledContentRect(
        _ window: NSWindow, toOriginX originX: CGFloat, toContentHeight height: CGFloat
    ) -> NSRect {
        var content = window.contentRect(forFrameRect: window.frame)
        content.origin.x = originX
        content.size.height = height
        window.setFrame(window.frameRect(forContentRect: content), display: false)
        return window.contentRect(forFrameRect: window.frame)
    }

    /// The `top` `handleLocalGeometrySettled` is expected to send for `contentRect`, derived the
    /// way that method derives it and with nothing of this lane in it: flip into Windows space
    /// against the fixture topology, then `railRect`, then round.
    ///
    /// `correction: .zero` is the correction the registry itself computes here, not a
    /// simplification: `sizeCorrection(for:windowId:)` returns `.zero` unless the window has a
    /// GFX-mapped surface, and this suite maps none. It would not matter to THIS assertion even
    /// if one existed -- that method's non-zero return sets `width`/`height` only and pins
    /// `originX: 0, originY: 0` -- but the zero is stated as a fixture fact rather than leaned on
    /// as an invariant of a method this file does not own.
    private static func expectedSentTop(forContentRect contentRect: NSRect, in topology: DisplayTopology) -> Int32 {
        let macRect = MacRect(
            x: contentRect.origin.x, y: contentRect.origin.y,
            width: contentRect.size.width, height: contentRect.size.height
        )
        let displayed = WindowGeometry.windowsRect(from: macRect, in: topology)
        return Int32(WindowGeometry.railRect(from: displayed, correction: .zero).y.rounded())
    }

    /// Polls for `count` distinct settles (20ms steps, 3s cap): each window rides
    /// `RemoteWindow.moveSettleDebounce` (0.2s) on the main queue, which the sleep releases.
    private static func waitForMoves(_ box: SentBox, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while box.moves.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The wiring assertion this suite exists for: two windows differing ONLY in their style
    /// bits, moved to the same X, must send `left` values 2 apart -- 7 deducted for the About
    /// style, 5 for the `WS_THICKFRAME` one (F-R1's own delta: the client used to over-deduct by
    /// exactly 2 on Notepad, which is the `dx = -2` the record reports). A call site that passed
    /// a fixed border for every window would send the same `left` for both.
    @Test func styleDecidesTheDeductedLeftBorderOnTheWire() async throws {
        let (registry, box) = try Self.makeRegistry()
        registry.handle(
            WindowOrderStub(windowId: 101, style: Self.thickFrameStyle, x: 300, y: 200, width: 522, height: 514))
        registry.handle(
            WindowOrderStub(windowId: 102, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let thickFrameWindow = try #require(registry.window(forWindowId: 101))
        let aboutWindow = try #require(registry.window(forWindowId: 102))

        let contentX = Self.moveAndReadSettledContentX(thickFrameWindow, toOriginX: 420)
        #expect(Self.moveAndReadSettledContentX(aboutWindow, toOriginX: 420) == contentX)
        try await Self.waitForMoves(box, count: 2)

        let thickFrameMove = try #require(box.moves[101])
        let aboutMove = try #require(box.moves[102])
        #expect(Double(thickFrameMove.left) == (contentX - WindowGeometry.thickFrameClientWindowMoveLeftBorder).rounded())
        #expect(Double(aboutMove.left) == (contentX - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder).rounded())
        // Stated as the signed delta too: this is the one number a swapped/inverted style rule
        // gets backwards while both absolute values still "look like a border deduction".
        #expect(thickFrameMove.left - aboutMove.left == 2)
        // INTENTIONAL UPDATE, adr/0018 §5.2 增补五: `right` and `bottom` are now the visible
        // edges OUTSET by the same B, so they move OPPOSITE to `left` -- the THICKFRAME window
        // (B=5) lands 2 SHORT of the About one (B=7) on both, where before the fix `right`
        // trailed `left` by +2 and `bottom` was identical. `top` is still untouched (the frame's
        // top member is 0 in every measured model), and the sign flip is the whole point: a call
        // site that did not adopt the outset still reports +2 and 0 here.
        #expect(thickFrameMove.right - aboutMove.right == -2)
        #expect(thickFrameMove.top == aboutMove.top)
        #expect(thickFrameMove.bottom - aboutMove.bottom == -2)
    }

    /// The unknown-style case, on the wire: a window whose orders never carried
    /// `WINDOW_ORDER_FIELD_STYLE` keeps `PendingWindowState.style == 0` and must be deducted the
    /// About-calibrated 7 -- exactly what every window got before F-R1. Nothing measured says
    /// what an unknown style's border is; this pins that the answer is "unchanged behaviour",
    /// not the newly added value.
    @Test func aWindowThatNeverAnnouncedItsStyleKeepsThePreviousDeduction() async throws {
        let (registry, box) = try Self.makeRegistry()
        registry.handle(
            WindowOrderStub(windowId: 201, style: 0, carriesStyleField: false, x: 300, y: 200, width: 522, height: 514))
        registry.handle(
            WindowOrderStub(windowId: 202, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let styleLessWindow = try #require(registry.window(forWindowId: 201))
        let aboutWindow = try #require(registry.window(forWindowId: 202))

        let contentX = Self.moveAndReadSettledContentX(styleLessWindow, toOriginX: 380)
        #expect(Self.moveAndReadSettledContentX(aboutWindow, toOriginX: 380) == contentX)
        try await Self.waitForMoves(box, count: 2)

        let styleLessMove = try #require(box.moves[201])
        let aboutMove = try #require(box.moves[202])
        #expect(styleLessMove.left == aboutMove.left)
        #expect(Double(styleLessMove.left) == (contentX - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder).rounded())
    }

    // MARK: - The DPI tier reaches the same deduction (ADR-0018 §5.2 增补二 item 2)

    /// The wiring claim of the route-B lane, stated the same way the style claim above is: two
    /// windows differing only in their style bits, moved to the same X, on a session that
    /// advertised `DesktopScaleFactor=200` -- the sent `left` values must be the 192 column of
    /// the ADR table (11 and 10), not the 96 one (7 and 5). A call site that looked the border
    /// up without a tier satisfies every MacdowsCore test in this lane and still sends the old
    /// numbers on every 2x session; only driving the real registry can tell those apart.
    ///
    /// The delta is asserted too, and it is the discriminating number: 1 at 192 DPI where the
    /// 96 column's is 2. A lookup that returned the 192 column for one row and the 96 column for
    /// the other -- the single most likely table typo -- lands on 11/5 or 7/10, neither of which
    /// has a delta of 1.
    @Test func advertisingTwoHundredDeductsTheOneNineTwoColumnOnTheWire() async throws {
        let (registry, box) = try Self.makeRegistry(advertisedDesktopScaleFactor: 200)
        registry.handle(
            WindowOrderStub(windowId: 301, style: Self.thickFrameStyle, x: 300, y: 200, width: 522, height: 514))
        registry.handle(
            WindowOrderStub(windowId: 302, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let thickFrameWindow = try #require(registry.window(forWindowId: 301))
        let aboutWindow = try #require(registry.window(forWindowId: 302))

        let contentX = Self.moveAndReadSettledContentX(thickFrameWindow, toOriginX: 440)
        #expect(Self.moveAndReadSettledContentX(aboutWindow, toOriginX: 440) == contentX)
        try await Self.waitForMoves(box, count: 2)

        let thickFrameMove = try #require(box.moves[301])
        let aboutMove = try #require(box.moves[302])
        #expect(Double(thickFrameMove.left) == (contentX - WindowGeometry.thickFrameClientWindowMoveLeftBorder192).rounded())
        #expect(Double(aboutMove.left) == (contentX - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder192).rounded())
        #expect(thickFrameMove.left - aboutMove.left == 1)
        // INTENTIONAL UPDATE, adr/0018 §5.2 增补五: same sign flip as the 96-column case, one
        // column over -- B=10 vs B=11 puts the THICKFRAME window 1 SHORT on `right` and on
        // `bottom` (before the fix: +1 and 0). Y is still untouched: the ADR table's K (whose Y
        // component is nonzero even at 96 DPI) is deliberately not wired into this leg, and the
        // outset's own top member is 0.
        #expect(thickFrameMove.right - aboutMove.right == -1)
        #expect(thickFrameMove.top == aboutMove.top)
        #expect(thickFrameMove.bottom - aboutMove.bottom == -1)
    }

    /// 1x BYTE-IDENTITY at the call site, said explicitly rather than inferred from the two
    /// pre-tier cases above: a session that advertised 100 sends exactly what a session that
    /// advertised nothing (0) sends, and both send the 96 column. If the tier were keyed on the
    /// local display scale instead of on the advertisement, this pair would still pass -- which
    /// is why the 150 case below exists as well.
    @Test func advertisingOneHundredOrNothingKeepsTheNinetySixColumn() async throws {
        let (advertised100, box100) = try Self.makeRegistry(advertisedDesktopScaleFactor: 100)
        let (advertisedNone, boxNone) = try Self.makeRegistry(advertisedDesktopScaleFactor: 0)
        advertised100.handle(
            WindowOrderStub(windowId: 311, style: Self.thickFrameStyle, x: 300, y: 200, width: 522, height: 514))
        advertisedNone.handle(
            WindowOrderStub(windowId: 311, style: Self.thickFrameStyle, x: 300, y: 200, width: 522, height: 514))
        let window100 = try #require(advertised100.window(forWindowId: 311))
        let windowNone = try #require(advertisedNone.window(forWindowId: 311))

        let contentX = Self.moveAndReadSettledContentX(window100, toOriginX: 460)
        #expect(Self.moveAndReadSettledContentX(windowNone, toOriginX: 460) == contentX)
        try await Self.waitForMoves(box100, count: 1)
        try await Self.waitForMoves(boxNone, count: 1)

        let move100 = try #require(box100.moves[311])
        let moveNone = try #require(boxNone.moves[311])
        #expect(move100.left == moveNone.left)
        #expect(Double(move100.left) == (contentX - WindowGeometry.thickFrameClientWindowMoveLeftBorder).rounded())
    }

    /// The fallback, on the wire: an advertised scale this project has no reading for (150) is
    /// NOT rounded up into the 192 column -- it deducts today's 96-column border, exactly as 100
    /// and 0 do. `WindowGeometry.DPITier`'s own tests pin the predicate; this pins that the
    /// registry's call site is the one that consumes it.
    @Test func anUnmeasuredAdvertisedScaleStaysOnTheNinetySixColumn() async throws {
        let (registry, box) = try Self.makeRegistry(advertisedDesktopScaleFactor: 150)
        registry.handle(
            WindowOrderStub(windowId: 321, style: Self.thickFrameStyle, x: 300, y: 200, width: 522, height: 514))
        registry.handle(
            WindowOrderStub(windowId: 322, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let thickFrameWindow = try #require(registry.window(forWindowId: 321))
        let aboutWindow = try #require(registry.window(forWindowId: 322))

        let contentX = Self.moveAndReadSettledContentX(thickFrameWindow, toOriginX: 480)
        #expect(Self.moveAndReadSettledContentX(aboutWindow, toOriginX: 480) == contentX)
        try await Self.waitForMoves(box, count: 2)

        let thickFrameMove = try #require(box.moves[321])
        let aboutMove = try #require(box.moves[322])
        #expect(Double(thickFrameMove.left) == (contentX - WindowGeometry.thickFrameClientWindowMoveLeftBorder).rounded())
        #expect(Double(aboutMove.left) == (contentX - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder).rounded())
        #expect(thickFrameMove.left - aboutMove.left == 2)
    }

    /// K NEVER ENTERS THE Y AXIS (prereg gate r1, 2026-09-18). The ADR-0018 §5.2 增补二 table has
    /// a second column beside the left border B -- the client-area inset K -- and K's Y component
    /// is nonzero for exactly this window class (the About row) even at 96 DPI. This move leg
    /// applies NO Y correction at all and must keep applying none: a K wired in here would change
    /// what a 1x session sends for `top`, on the one row whose K.y is not zero, and 1x
    /// byte-identity is this lane's whole premise.
    ///
    /// Asserted the strong way rather than as a cross-tier equality alone: the sent `top` is
    /// checked against the value derived from the window's own settled rect through the same two
    /// public conversions the registry uses, at BOTH tiers. A Y inset applied at either tier
    /// fails that absolute check; one applied at BOTH tiers (the mutation a cross-tier equality
    /// alone would sleep through) fails it too. The left axis is asserted in the same breath, so
    /// the case also says what DOES change: `left` by 4 (11 - 7), and -- since adr/0018 §5.2
    /// 增补五 -- `right`/`bottom` by 4 in the OPPOSITE direction, so the wire width grows by 2B
    /// and the wire height by B. The tier-invariant quantity is the VISIBLE rect both columns
    /// reconstruct to, and that is asserted in place of the old wire-width equality.
    @Test func theTierMovesOnlyTheLeftAxisAndNeverTheTop() async throws {
        let topology = try Self.fixtureTopology()
        let (at192, box192) = try Self.makeRegistry(advertisedDesktopScaleFactor: 200)
        let (at96, box96) = try Self.makeRegistry(advertisedDesktopScaleFactor: 100)
        at192.handle(
            WindowOrderStub(windowId: 331, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        at96.handle(
            WindowOrderStub(windowId: 331, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let window192 = try #require(at192.window(forWindowId: 331))
        let window96 = try #require(at96.window(forWindowId: 331))

        let content192 = Self.moveAndReadSettledContentRect(window192, toOriginX: 500)
        let content96 = Self.moveAndReadSettledContentRect(window96, toOriginX: 500)
        // The two fixtures must be the same rect before any claim about the difference between
        // them means anything -- AppKit settles both, and nothing in this lane touches Y.
        #expect(content192 == content96)
        try await Self.waitForMoves(box192, count: 1)
        try await Self.waitForMoves(box96, count: 1)

        let move192 = try #require(box192.moves[331])
        let move96 = try #require(box96.moves[331])
        let expectedTop = Self.expectedSentTop(forContentRect: content192, in: topology)
        #expect(move192.top == expectedTop)
        #expect(move96.top == expectedTop)
        #expect(move192.top == move96.top)
        // INTENTIONAL UPDATE, adr/0018 §5.2 增补五: `bottom` is now `top + height + B`, so it
        // carries the tier the way `left` does and the two columns differ by 11 - 7 = 4 -- it
        // used to be identical across tiers. `top` above is the assertion that still says the Y
        // ORIGIN takes no correction from either B or K; this one says the far edge takes the
        // outset, which is a different claim about a different edge.
        #expect(move96.bottom - move192.bottom == -4)
        // ... and the axis that DOES move, in the same case: 11 instead of 7.
        #expect(Double(move192.left) == (Double(content192.origin.x) - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder192).rounded())
        #expect(Double(move96.left) == (Double(content96.origin.x) - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder).rounded())
        #expect(move96.left - move192.left == 4)
        // INTENTIONAL UPDATE (x2), adr/0018 §5.2 增补五: `right` now moves AWAY from `left`
        // (outset, not shifted), so the 96 column's right edge is 4 SHORT of the 192 column's
        // instead of 4 past it; and the width on the wire is `ef.width + 2B`, which is 8 wider
        // at 192 than at 96 rather than identical. The old equality was the statement "the tier
        // shifts the window without resizing it"; the wire rect is the OUTER rect, and its
        // width is a function of the frame, so the statement that survives is the one below --
        // both columns still describe the SAME visible window.
        #expect(move96.right - move192.right == -4)
        #expect((move192.right - move192.left) - (move96.right - move96.left) == 8)
        // What the old equality was really protecting, restated on the quantity that is
        // tier-invariant: the VISIBLE width both columns reconstruct to (wire width minus 2B).
        #expect(
            (move192.right - move192.left) - 2 * Int32(WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder192)
                == (move96.right - move96.left) - 2 * Int32(WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder)
        )
    }

    // MARK: - The whole rect is outset by (B, 0, B, B) (adr/0018 §5.2 增补五)

    /// The wiring claim of THIS lane, in absolute terms rather than as a difference between two
    /// windows: all four sent edges, each derived from the window's own settled content rect
    /// through the same two public conversions the registry uses, with the outset applied.
    ///
    /// WHY ABSOLUTE AND NOT ONLY DIFFERENTIAL. The cross-style and cross-tier deltas above are
    /// differences of two sends, so a call site that outset BOTH windows by the wrong quantity
    /// -- or that outset neither -- can still produce the right difference. This case pins each
    /// edge against a number computed outside the registry, which is what actually says "the
    /// pure function reached the wire". It is the App-side half of
    /// `WindowGeometryTests.clientWindowMoveRectOutsetsTheVisibleRect`; that one pins the
    /// arithmetic, this one pins that the arithmetic is the one being sent.
    @Test func theSentRectIsTheVisibleRectOutsetByTheBorder() async throws {
        let topology = try Self.fixtureTopology()
        let (registry, box) = try Self.makeRegistry()
        registry.handle(
            WindowOrderStub(windowId: 401, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 514))
        let window = try #require(registry.window(forWindowId: 401))

        let content = Self.moveAndReadSettledContentRect(window, toOriginX: 520)
        try await Self.waitForMoves(box, count: 1)

        let move = try #require(box.moves[401])
        let border = WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder
        let visible = WindowGeometry.windowsRect(
            from: MacRect(
                x: content.origin.x, y: content.origin.y,
                width: content.size.width, height: content.size.height),
            in: topology
        )

        #expect(Double(move.left) == (visible.x - border).rounded())
        #expect(Double(move.top) == visible.y.rounded())
        #expect(Double(move.right) == (visible.x + visible.width + border).rounded())
        #expect(Double(move.bottom) == (visible.y + visible.height + border).rounded())
        // The two spans, which is the form the live record judges: wire width is `ef.width + 2B`
        // and wire height is `ef.height + B`. Before this lane both were the ef values exactly,
        // which is the D2 shrink-per-leg the fix removes.
        #expect(Double(move.right - move.left) == visible.width + 2 * border)
        #expect(Double(move.bottom - move.top) == visible.height + border)
    }

    // MARK: - Rule R on the wire (adr/0018 §5.2 增补五)

    /// Rule R, driven through the real registry: a 2x session whose window lost a half point
    /// locally sends back the height the SERVER last reported, not the rounded local one.
    ///
    /// The fixture reproduces the recorded shape exactly -- RAIL `WND_SIZE` height 917 remote
    /// px, which is 458.5 mac points at `rasterScale == 2`, against a local content height of
    /// 459 points (918 remote px). Both halves are asserted as fixture facts before the outcome
    /// is, so a case that stopped reproducing the artefact fails as itself rather than as the
    /// rule.
    ///
    /// The width is asserted in the same breath and is NOT snapped by anything: it converts back
    /// exactly, so it exercises the "already equal" side of the same rule.
    @Test func ruleRSendsTheServersOwnHeightWhenAHalfPointWasLostAtTwoX() async throws {
        let topology = try Self.fixtureTopology(rasterScale: 2)
        let (registry, box) = try Self.makeRegistry(advertisedDesktopScaleFactor: 200, topology: topology)
        registry.handle(
            WindowOrderStub(windowId: 411, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 917))
        let window = try #require(registry.window(forWindowId: 411))

        let content = Self.moveAndResizeAndReadSettledContentRect(
            window, toOriginX: 540, toContentHeight: 459)
        // Fixture facts, not outcomes: the local content really is a half point past what 917
        // converts to, so the value the registry sees is 918 and not 917.
        #expect(content.size.height == 459)
        #expect(Double(content.size.height) * topology.rasterScale == 918)
        try await Self.waitForMoves(box, count: 1)

        let move = try #require(box.moves[411])
        let border = WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder192
        #expect(Double(move.bottom - move.top) == 917 + border)
        // Said as the negative too: 918 + B is what an unsnapped send produces, and it is the
        // one-pixel resize request this rule exists to not make.
        #expect(Double(move.bottom - move.top) != 918 + border)
        // The unaffected axis, through the same rule: 522 converts back exactly.
        #expect(Double(move.right - move.left) == 522 + 2 * border)
    }

    /// The 1x control, same shape and same one-pixel gap: rule R's tolerance is `rasterScale -
    /// 1`, so on a 1x session it is zero and NOTHING is ever snapped -- the settled 459 is sent
    /// as 459 even though the server last reported 458.
    ///
    /// This is the case that separates the ruled tolerance from the two obvious neighbours: a
    /// `<= rasterScale` tolerance would snap here (sending 458 + B), and a rule that ignored the
    /// scale entirely would too.
    ///
    /// SCOPED TO RULE R, not to the lane (gate r1 B2). What is byte-identical at 1x is rule R
    /// and the `left`/`top` axes; `right`/`bottom` at 1x are deliberately +B each, which is
    /// exactly what the `459 + border` above says -- the pre-lane spelling of this expectation
    /// would have been a bare `459`. The seven pre-lane 1x pins that stated the old right/bottom
    /// values are updated in this same file, each with its own INTENTIONAL UPDATE note.
    @Test func ruleRNeverSnapsOnAOneXSession() async throws {
        let topology = try Self.fixtureTopology()
        let (registry, box) = try Self.makeRegistry(advertisedDesktopScaleFactor: 100, topology: topology)
        registry.handle(
            WindowOrderStub(windowId: 421, style: Self.aboutStyle, x: 300, y: 200, width: 522, height: 458))
        let window = try #require(registry.window(forWindowId: 421))

        let content = Self.moveAndResizeAndReadSettledContentRect(
            window, toOriginX: 560, toContentHeight: 459)
        #expect(content.size.height == 459)
        #expect(Double(content.size.height) * topology.rasterScale == 459)
        try await Self.waitForMoves(box, count: 1)

        let move = try #require(box.moves[421])
        let border = WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder
        #expect(Double(move.bottom - move.top) == 459 + border)
        #expect(Double(move.bottom - move.top) != 458 + border)
    }
}

/// The fallback LOG, pinned as source rather than as output.
///
/// WHY SOURCE: the line goes to `os_log` through this file's own `Logger`, which no in-process
/// test can read back (`RemoteWindowRegistry.swift`'s own comment on that logger records the
/// same fact: `os_log` "goes to the unified log and never reaches that file"). Capturing it
/// would need `OSLogStore`, an entitlement-sensitive read of the whole system log, for one
/// diagnostic line. So the three properties that make the line correct are pinned where they
/// are decidable: the PREDICATE (`DPITier.isUnmeasuredAdvertisement`, whose truth table is
/// `WindowGeometryDPITierTests.unmeasuredAdvertisementPredicate` in MacdowsCore), the WIRING
/// (the three suite cases above drive 200/150/100/0 through the real registry and read the sent
/// rect), and -- here -- that the warning is emitted exactly once, from one place, behind a
/// warn-once bit of its own. That bit is PER REGISTRY INSTANCE (= per session), which is the one
/// way it differs from the two `sessionTopologyOrWarn()` bits this file has pinned since M1:
/// those report a property of the process or of the machine and are deliberately `static`; this
/// one reports a property of the session that is being warned about (gate r1 m1, 2026-09-18).
///
/// Same technique and same collapsed-substring helper as `ProductScaleDefaultPinTests`.
@Suite("the left-border DPI-tier fallback says so once (source pins)")
struct RemoteWindowRegistryLeftBorderTierLogPinTests {
    private static func registryRawSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("App/RemoteWindowRendering/RemoteWindowRegistry.swift"),
            encoding: .utf8
        )
    }

    private static func registrySource() throws -> String {
        try registryRawSource().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The same file with every `//`-to-end-of-line comment removed BEFORE the whitespace
    /// collapse, so a count over it sees code only (gate r1 m5, 2026-09-18).
    ///
    /// Why a second reader rather than a cleverer needle: the pins below anchor on call SHAPES
    /// precisely because a bare name also matches the prose of a doc comment (project memory:
    /// "source pins must match call shapes, not names"). That defends against a comment being
    /// counted as code; it does NOT defend against a second real READ written in a shape the
    /// pin does not enumerate -- e.g. `foo(session.advertisedDesktopScaleFactor)` in another
    /// method of this file, which is neither an assignment nor the enumerated call. Stripping
    /// the comments turns the bare name back into a usable pin for exactly that case.
    ///
    /// Known and accepted blind spot: a `//` inside a string literal would truncate that line.
    /// The file has no such literal on any line carrying the token pinned below, and a future
    /// one would make the pin RED (a line lost, not a line gained), which is the safe direction.
    private static func registrySourceWithoutComments() throws -> String {
        let stripped = try registryRawSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("the tier is derived from the session's advertised desktop scale, at one call site")
    func theTierComesFromTheSessionAdvertisement() throws {
        let src = try Self.registrySource()
        // ONE read of the advertisement, feeding BOTH the fallback predicate and the tier --
        // the same-read discipline this method already follows for the topology and for the
        // window's own wire state. Two reads of the same session property could disagree.
        // Anchored on the ASSIGNMENT, not on the property name: the method's own doc comment
        // names `session.advertisedDesktopScaleFactor` in prose, and a bare name count reads
        // that as a read (project memory: source pins match call shapes, not names -- measured
        // here, the name count was 2 with exactly one read in the code).
        #expect(Self.occurrences(of: "let advertised = session.advertisedDesktopScaleFactor", in: src) == 1)
        #expect(Self.occurrences(of: "= session.advertisedDesktopScaleFactor", in: src) == 1)
        #expect(Self.occurrences(of: "WindowGeometry.DPITier(advertisedDesktopScaleFactor: advertised)", in: src) == 1)
        // The border is looked up ONCE, with a tier -- a surviving tier-less call would be a
        // second, silently 96-column path through the same method.
        #expect(
            Self.occurrences(
                of: "Self.clientWindowMoveLeftBorder( forStyle: state.style, "
                    + "tier: WindowGeometry.DPITier(advertisedDesktopScaleFactor: advertised) )",
                in: src
            ) == 1
        )
        #expect(Self.occurrences(of: "Self.clientWindowMoveLeftBorder(forStyle: state.style)", in: src) == 0)
        // ... and the shapes above are not an exhaustive list of ways to read a property, so the
        // bare token is counted too -- over CODE ONLY (gate r1 m5). A second read written as a
        // direct argument somewhere else in this file (`foo(session.advertisedDesktopScaleFactor)`)
        // is caught by this and by nothing above it. Exactly one, the `let advertised` assignment;
        // the doc comments that name the property in prose are stripped, not counted.
        let code = try Self.registrySourceWithoutComments()
        #expect(Self.occurrences(of: "session.advertisedDesktopScaleFactor", in: code) == 1)
    }

    @Test("the fallback warning is guarded by the predicate and by a warn-once bit, and fires from one place")
    func theFallbackWarningIsGuardedAndOnce() throws {
        let src = try Self.registrySource()
        #expect(Self.occurrences(of: "WindowGeometry.DPITier.isUnmeasuredAdvertisement(", in: src) == 1)
        #expect(Self.occurrences(of: "!warnedUnmeasuredDesktopScaleAdvertisement", in: src) == 1)
        #expect(Self.occurrences(of: "warnedUnmeasuredDesktopScaleAdvertisement = true", in: src) == 1)
        // PER INSTANCE, not per process (gate r1 m1): the registry is built per connect against
        // one session, and what this line reports is that session's advertisement. A `static`
        // bit here would make a second connection in the same process silent about its own
        // fallback -- and a run record registering "fired / did not fire" for a session would
        // then be recording the FIRST session's answer. Pinned in both directions so the shape
        // cannot drift back: the declaration is `private var`, and no `Self.`-qualified use of
        // the bit survives anywhere in the file.
        #expect(Self.occurrences(of: "private var warnedUnmeasuredDesktopScaleAdvertisement = false", in: src) == 1)
        #expect(Self.occurrences(of: "private static var warnedUnmeasuredDesktopScaleAdvertisement", in: src) == 0)
        #expect(Self.occurrences(of: "Self.warnedUnmeasuredDesktopScaleAdvertisement", in: src) == 0)
        // The text a record reads, built in one place. Written as the interpolation's own shape
        // so a doc comment quoting the words does not count (project memory: source pins match
        // call shapes, not names).
        #expect(
            Self.occurrences(
                of: "\"[geometry] left-border tier fallback: advertised desktop scale \\(advertised, privacy: .public) is not 100/200, using the 96 DPI row\"",
                in: src
            ) == 1
        )
    }
}

/// The outbound rect is assembled in ONE place, from the pure functions -- pinned as source
/// (adr/0018 §5.2 增补五).
///
/// WHY SOURCE AS WELL AS BEHAVIOUR. The suites above drive the registry and read the sent rect,
/// which is the real claim; what they cannot see is a SECOND assembly path through the same
/// file, or a right/bottom edge quietly re-derived from the visible rect's own width beside the
/// pure function's result. The About-target lane shipped exactly that class of change once
/// (review about-target-r1 I-1). These pins hold the shape the behaviour cases assume: one call
/// to the outset function, one call to the snap, one border lookup, and no arithmetic on the
/// visible rect's size anywhere in the file.
///
/// Same technique, same two readers and the same collapsed-substring helper as
/// `RemoteWindowRegistryLeftBorderTierLogPinTests` above; see that suite's own doc comment for
/// why the comment-stripped reader exists and what its one known blind spot is.
@Suite("the outbound ClientWindowMove rect has exactly one assembly point (source pins)")
struct RemoteWindowRegistryOutboundRectPinTests {
    private static func registryRawSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("App/RemoteWindowRendering/RemoteWindowRegistry.swift"),
            encoding: .utf8
        )
    }

    /// Code only: every `//`-to-end-of-line comment removed BEFORE the whitespace collapse, so a
    /// count of zero is a statement about the code and not about the prose that explains it --
    /// which matters more here than anywhere else in this file, because the doc comments on
    /// `handleLocalGeometrySettled` NAME the old `railWindowsRect.width` expression in order to
    /// say it is gone.
    private static func registryCode() throws -> String {
        let stripped = try registryRawSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("the four sent edges come from one clientWindowMoveRect call and from nothing else")
    func theOutboundRectIsAssembledOnce() throws {
        let code = try Self.registryCode()

        // ONE outset, ONE snap, ONE border lookup -- a second of any of them is a second policy
        // for the same wire field.
        #expect(Self.occurrences(of: "WindowGeometry.clientWindowMoveRect(", in: code) == 1)
        #expect(Self.occurrences(of: "WindowGeometry.snappedToLastReportedSize(", in: code) == 1)
        #expect(Self.occurrences(of: "Self.clientWindowMoveLeftBorder(", in: code) == 1)

        // THE OLD ARITHMETIC IS GONE, said on the operand rather than on the expression: before
        // this lane `right` was `correctedLeft + railWindowsRect.width` and `bottom` was
        // `railWindowsRect.y + railWindowsRect.height`, and the sizes of the visible rect are now
        // read by nothing in this file -- they are handed to the snap as a whole rect and never
        // named again. Any re-derivation of an edge from a size has to name one of these.
        #expect(Self.occurrences(of: "railWindowsRect.width", in: code) == 0)
        #expect(Self.occurrences(of: "railWindowsRect.height", in: code) == 0)

        // ... and each of the four integers narrows exactly one member of the pure function's
        // result. A leg that kept one old edge (the single most likely half-adoption) leaves one
        // of these at 0.
        #expect(Self.occurrences(of: "Int32(sent.left.rounded())", in: code) == 1)
        #expect(Self.occurrences(of: "Int32(sent.top.rounded())", in: code) == 1)
        #expect(Self.occurrences(of: "Int32(sent.right.rounded())", in: code) == 1)
        #expect(Self.occurrences(of: "Int32(sent.bottom.rounded())", in: code) == 1)

        // One send, which is what makes "one assembly point" a statement about the wire.
        #expect(Self.occurrences(of: "session.sendWindowMove(", in: code) == 1)

        // THE BORDER REACHES THE OUTSET UNSCALED (gate r1 m3). MacdowsCore's own body pin
        // forbids a scale factor inside `clientWindowMoveRect`, but that says nothing about the
        // ARGUMENT this file passes: `measuredBorder: border * topology.rasterScale` satisfies
        // every count above and is a no-op on every 1x fixture, so it survives all but one
        // behaviour case here. Pinned as the whole collapsed call shape, plus the two spellings
        // of a scaling anywhere in the file's code.
        #expect(
            Self.occurrences(
                of: "WindowGeometry.clientWindowMoveRect( fromVisibleRect: settledVisibleRect, "
                    + "measuredBorder: border )",
                in: code
            ) == 1
        )
        #expect(Self.occurrences(of: "* rasterScale", in: code) == 0)
        #expect(Self.occurrences(of: "rasterScale *", in: code) == 0)
        #expect(Self.occurrences(of: "* topology.rasterScale", in: code) == 0)
    }

    /// The snap's three inputs are the SERVER's own last reported size and the session's raster
    /// scale -- pinned because feeding it anything else (the mapped GFX size, the local frame,
    /// a hard-coded 2) would still satisfy every count above.
    ///
    /// PINNED AS THE WHOLE CALL, not as three names. `rasterScale: topology.rasterScale` is
    /// ALREADY written once in this file by the window-mask path, so a bare `== 1` on that
    /// argument is red on arrival and a `== 2` would pass while saying nothing about which two
    /// sites (project memory: source pins must match call shapes, not names -- measured here,
    /// the argument's count was 2 with exactly one read on this path). The argument count is
    /// kept below as 2, WITH the other site named, so a third reader of the session raster
    /// scale is still red.
    @Test("rule R is fed the last reported RAIL size and the session's raster scale")
    func theSnapReadsTheLastReportedSizeAndTheRasterScale() throws {
        let code = try Self.registryCode()
        #expect(
            Self.occurrences(
                of: "WindowGeometry.snappedToLastReportedSize( railWindowsRect, "
                    + "lastReportedWidth: Double(state.width), lastReportedHeight: Double(state.height), "
                    + "rasterScale: topology.rasterScale )",
                in: code
            ) == 1
        )
        #expect(Self.occurrences(of: "lastReportedWidth: Double(state.width)", in: code) == 1)
        #expect(Self.occurrences(of: "lastReportedHeight: Double(state.height)", in: code) == 1)
        // Two sites read the session's raster scale: `computeMaskResult`'s
        // `WindowShape.computeMask(..., rasterScale:)` call, which predates this lane, and rule
        // R's above. Both take it from the SAME frozen topology snapshot this method already
        // read, which is the same-read discipline §5.A.4 states for the topology.
        #expect(Self.occurrences(of: "rasterScale: topology.rasterScale", in: code) == 2)
    }
}
