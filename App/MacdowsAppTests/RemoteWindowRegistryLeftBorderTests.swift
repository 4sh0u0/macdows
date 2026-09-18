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
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
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
        let topology = try fixtureTopology()
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
        // `right` moves with `left` (same width), and `top`/`bottom` are untouched by the style.
        #expect(thickFrameMove.right - aboutMove.right == 2)
        #expect(thickFrameMove.top == aboutMove.top)
        #expect(thickFrameMove.bottom == aboutMove.bottom)
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
        // The tier is a LEFT-border axis only: `right` still moves with `left`, and Y is
        // untouched -- the ADR table's K (whose Y component is nonzero even at 96 DPI) is
        // deliberately not wired into this leg.
        #expect(thickFrameMove.right - aboutMove.right == 1)
        #expect(thickFrameMove.top == aboutMove.top)
        #expect(thickFrameMove.bottom == aboutMove.bottom)
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
    /// the case also says what DOES change: `left` by 4 (11 - 7) and `right` with it, while the
    /// width on the wire is identical.
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
        #expect(move192.bottom == move96.bottom)
        // ... and the axis that DOES move, in the same case: 11 instead of 7.
        #expect(Double(move192.left) == (Double(content192.origin.x) - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder192).rounded())
        #expect(Double(move96.left) == (Double(content96.origin.x) - WindowGeometry.aboutCalibratedClientWindowMoveLeftBorder).rounded())
        #expect(move96.left - move192.left == 4)
        #expect(move96.right - move192.right == 4)
        #expect(move192.right - move192.left == move96.right - move96.left)
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
