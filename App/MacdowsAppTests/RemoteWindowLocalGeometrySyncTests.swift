import AppKit
import Testing

// F-R2 (docs/upgrade-gate/2026-09-resize-leg-live.md §3.2, real-host run 2026-09-02): a
// programmatic `-setFrame:display:` that changes the window's SIZE posts only
// `NSWindow.didResizeNotification` -- never `didMoveNotification`, even when the origin
// changes in the same call, and never the live-resize begin/end pair (that pair is
// interactive-only). Measured on this machine: six scenarios in the controller's
// `.titled/.resizable` probe, corroborated by an independent five-scenario probe (review
// resize-live-r1) and two borderless re-runs (review resize-live-r2; review fr2-r1's own
// probe was borderless too); this suite re-pins the behaviour on the borderless styleMask
// production actually uses.
// `RemoteWindow` used to observe `didMove` + the live-resize pair only, so a non-interactive
// local size change never reached `onLocalGeometrySettled` and therefore never became a
// `ClientWindowMove`: the resize leg of window-smoke's move/resize scenario had no sync exit
// at all, and neither would any other non-interactive frame change AppKit applies on the
// window's behalf (min/max constraints were measured NOT to be one -- setting them neither
// moves an existing frame nor posts anything, review fr2-r1).
//
// These tests drive the REAL `NSWindow` inside a `RemoteWindow` (constructible headless: the
// D7 bundle already compiles `RemoteWindowRendering` in) and observe the one production hook
// the registry consumes, `onLocalGeometrySettled`. They wait through the real 200ms debounce
// (`RemoteWindow.moveSettleDebounce`) on the main queue rather than reaching into it.
//
// COVERAGE BOUNDARY (registered, not a refactor): the `isInLiveResize` guard on the resize
// path cannot be exercised here -- AppKit only posts `willStartLiveResizeNotification` for a
// mouse-tracked resize loop, which no headless harness can synthesize (the same boundary
// window-smoke's own HONESTY GAP comment records). Likewise unmeasured (review fr2-r1 I-2):
// whether AppKit posts a trailing `didResize` AFTER `didEndLiveResizeNotification` -- if so the
// same rect would settle twice (a duplicate `ClientWindowMove`); one hand-driven resize on a
// live host decides it. What CAN be pinned is everything a programmatic frame change reaches:
// size-only, origin+size, pure move, a burst coalescing into one settle, a same-frame re-apply
// after a real settle, the server-driven apply NOT echoing back, and observer scoping on both
// halves (one window's resize must not settle another; nor must its move).
//
// Also unpinned, and left so on purpose: `close(via:)`'s observer teardown (five
// `removeObserver` calls: didResignKey plus the four geometry observers) has no coverage
// anywhere -- driving it needs a `CRSession`, which
// is not constructible headless, and adding a test seam would cross the D7 boundary (no
// test-motivated changes to the production Sources). Registered, not silently assumed.
//
// Where two windows appear in one test they take distinct `RemoteWindowKey.windowId`s purely
// to mirror production; nothing in this suite keys on them -- the scoping key is the NSWindow
// instance.
@MainActor
@Suite("RemoteWindow local geometry -> server sync (F-R2)")
struct RemoteWindowLocalGeometrySyncTests {
    private final class SettleBox {
        var rects: [NSRect] = []
    }

    private static let base = NSRect(x: 100, y: 100, width: 400, height: 300)

    private static func make(
        windowId: UInt32 = 7, firstFrameTimeout: TimeInterval = 3600
    ) -> (RemoteWindow, SettleBox) {
        let rw = RemoteWindow(
            key: RemoteWindowKey(windowId: windowId, generation: 0), contentRect: base,
            title: "sync-probe", firstFrameTimeout: firstFrameTimeout
        )
        let box = SettleBox()
        rw.onLocalGeometrySettled = { box.rects.append($0) }
        return (rw, box)
    }

    /// Comfortably past `RemoteWindow.moveSettleDebounce` (0.2s); the main actor is released
    /// during the sleep, so the debounce work item dispatched to the main queue can run. Used
    /// where the assertion is "NO settle happens" -- a fixed wait is the only way to bound that.
    private static func waitPastDebounce() async throws {
        try await Task.sleep(for: .milliseconds(450))
    }

    /// Polls for the FIRST settle (20ms steps, 2s cap) and then waits one more debounce-plus so
    /// a second, unwanted settle would still be observed -- "exactly once" needs both halves.
    /// Polling rather than a fixed sleep keeps a starved main queue from turning a correct
    /// settle into a false red (review fr2-r1 m-5). Bounds a second settle scheduled within
    /// ~300ms of the first (one debounce + 100ms); a longer chain is out of scope here -- the
    /// notifications this suite drives are delivered synchronously inside `setFrame`.
    private static func waitForFirstSettleThenOneMoreDebounce(_ box: SettleBox) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while box.rects.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    /// The F-R2 defect itself: a size-only frame change (window-smoke's resize leg shape:
    /// +100 wide, origin untouched) must settle exactly once, with the NEW content rect.
    @Test func sizeOnlyProgrammaticChangeSettlesOnceWithNewContentRect() async throws {
        let (rw, box) = Self.make()
        var frame = rw.window.frame
        frame.size.width += 100
        rw.window.setFrame(frame, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(box)
        #expect(box.rects.count == 1)
        #expect(box.rects.first?.size.width == Self.base.width + 100)
        #expect(box.rects.first?.size.height == Self.base.height)
        // The gesture claimed suppression once and released it once -- a resize path that
        // forgot the release would leave the server's own WindowUpdates ignored forever.
        #expect(rw.debugGeometrySuppressionCount == 0)
    }

    /// Origin AND size in one call: AppKit posts only `didResize` (probe scenario C), so this
    /// is the case a "make the harness move the origin too" workaround would NOT have fixed.
    /// Exactly one settle, carrying both the new origin and the new size.
    @Test func originAndSizeChangedTogetherSettlesExactlyOnce() async throws {
        let (rw, box) = Self.make()
        let target = NSRect(x: 180, y: 40, width: 500, height: 350)
        rw.window.setFrame(target, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(box)
        #expect(box.rects.count == 1)
        #expect(box.rects.first == rw.window.contentRect(forFrameRect: target))
        #expect(rw.debugGeometrySuppressionCount == 0)
    }

    /// Regression pin for the pre-existing `didMove` path: a pure move (probe scenario A)
    /// still settles exactly once -- adding a second observer must not double-settle a move.
    @Test func pureMoveStillSettlesExactlyOnce() async throws {
        let (rw, box) = Self.make()
        let target = NSRect(x: 180, y: 40, width: Self.base.width, height: Self.base.height)
        rw.window.setFrame(target, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(box)
        #expect(box.rects.count == 1)
        #expect(box.rects.first?.origin == target.origin)
        #expect(rw.debugGeometrySuppressionCount == 0)
    }

    /// Repeated resizes inside the debounce window coalesce into ONE settle that reports the
    /// LAST frame -- the resize path must ride the same trailing-edge debounce a native drag
    /// uses, not settle per notification.
    @Test func rapidResizeBurstCoalescesIntoOneSettleReportingTheLastFrame() async throws {
        let (rw, box) = Self.make()
        for extra in [10, 20, 30] {
            var frame = Self.base
            frame.size.width += CGFloat(extra)
            rw.window.setFrame(frame, display: true)
        }
        try await Self.waitForFirstSettleThenOneMoreDebounce(box)
        #expect(box.rects.count == 1)
        #expect(box.rects.first?.size.width == Self.base.width + 30)
        #expect(rw.debugGeometrySuppressionCount == 0)
    }

    /// Re-applying the identical frame posts nothing (probe scenario F) and must not settle --
    /// pinned AFTER a real resize has settled once, so the counter assertion has teeth (a
    /// re-apply that leaked a claim or a second settle would show up against the baseline of 1).
    @Test func reapplyingTheSameFrameAfterARealSettleDoesNotSettleAgain() async throws {
        let (rw, box) = Self.make()
        var frame = rw.window.frame
        frame.size.width += 50
        rw.window.setFrame(frame, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(box)
        try #require(box.rects.count == 1)
        rw.window.setFrame(rw.window.frame, display: true)
        try await Self.waitPastDebounce()
        #expect(box.rects.count == 1)
        #expect(rw.debugGeometrySuppressionCount == 0)
    }

    /// The didResize half of the observer scoping pin (review fr2-r1 I-3) -- see
    /// `movingOneWindowDoesNotSettleAnother` for the didMove half. Each observer is registered
    /// with `object: win`, so resizing one RemoteWindow must not settle another; an `object: nil`
    /// regression would make every window echo every other window's resize as its own
    /// `ClientWindowMove`. The scoping key is the NSWindow instance, not the windowId.
    @Test func resizingOneWindowDoesNotSettleAnother() async throws {
        let (a, boxA) = Self.make(windowId: 7)
        let (b, boxB) = Self.make(windowId: 8)
        var frame = b.window.frame
        frame.size.width += 100
        b.window.setFrame(frame, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(boxB)
        #expect(boxB.rects.count == 1)
        #expect(boxA.rects.isEmpty)
        #expect(a.debugGeometrySuppressionCount == 0)
        #expect(b.debugGeometrySuppressionCount == 0)
    }

    /// The `didMove` half of the same scoping pin (review fr2-r2 I-1): moving one window must
    /// not settle another. Without this, an `object: nil` regression on the didMove observer
    /// survived the suite -- every window would have echoed every other window's move.
    @Test func movingOneWindowDoesNotSettleAnother() async throws {
        let (a, boxA) = Self.make(windowId: 7)
        let (b, boxB) = Self.make(windowId: 8)
        var frame = a.window.frame
        frame.origin.x += 80
        frame.origin.y -= 60
        a.window.setFrame(frame, display: true)
        try await Self.waitForFirstSettleThenOneMoreDebounce(boxA)
        #expect(boxA.rects.count == 1)
        #expect(boxB.rects.isEmpty)
        #expect(a.debugGeometrySuppressionCount == 0)
        #expect(b.debugGeometrySuppressionCount == 0)
    }

    /// The guard the new observer must share with `didMove`: a SERVER-driven frame apply
    /// (`updateFrame`, i.e. an ordinary `WindowUpdate`) changes the size too, but must not be
    /// echoed back as a local settle -- otherwise every server resize would round-trip as a
    /// spurious `ClientWindowMove`. The first-frame gate is cleared through its timeout path
    /// (short `firstFrameTimeout`) so the apply is real, not merely recorded as pending.
    @Test func serverDrivenFrameApplyIsNotEchoedBackAsALocalSettle() async throws {
        let (rw, box) = Self.make(firstFrameTimeout: 0.05)
        try await Task.sleep(for: .milliseconds(150))
        let serverContent = NSRect(x: 100, y: 100, width: 520, height: 300)
        rw.updateFrame(contentRect: serverContent)
        try await Self.waitPastDebounce()
        // The apply happened ...
        #expect(rw.window.contentRect(forFrameRect: rw.window.frame) == serverContent)
        // ... and was not echoed.
        #expect(box.rects.isEmpty)
        #expect(rw.debugGeometrySuppressionCount == 0)
    }
}
