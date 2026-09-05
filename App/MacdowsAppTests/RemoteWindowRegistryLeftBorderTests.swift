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
        let topology = try fixtureTopology()
        let session = CRSession(host: "", user: "", password: "", program: "")
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
        var frame = window.frame
        frame.origin.x = originX
        window.setFrame(frame, display: false)
        return Double(window.contentRect(forFrameRect: window.frame).origin.x)
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
}
