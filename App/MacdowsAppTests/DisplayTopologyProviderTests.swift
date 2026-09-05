import AppKit
import MacdowsCore
import Testing

// Lane D7 (docs/plans/phase3.md:248, App-target test bundle pre-hung on W2): the first real
// tests for the App-side rendering layer. The sources under test are compiled directly into
// this bundle (App/project.yml's MacdowsAppTests target, mirroring the window-smoke
// source-sharing precedent), so `internal` members are same-module visible without `@testable`
// and the production Sources carry zero test-motivated changes (phase3.md:82/:171/:257).
//
// COVERAGE BOUNDARY, registered deliberately (the ReplayExpansionTests precedent) -- what this
// bundle's headless run CANNOT reach, and why each gap is a boundary rather than a refactor:
//
//  * `DisplayTopologyProvider.screenParametersDidChange`'s stale verdict, TRUE branch: the
//    provider's screen read (`readTopologyFromScreens`) is private and reads the real
//    `NSScreen.screens`, so no test can make the post-change layout differ from the frozen
//    snapshot without a physical display change. The false-when-equal half IS pinned below
//    (`observerAfterFreezeReportsUnchangedLayoutAsNotStale`), which still kills the
//    `!=` -> `==` mutation on `DisplayTopologyProvider.swift:269`.
//  * `RemoteWindowRegistry` / `RemoteWindow`: every decision seam in both is `private`. An
//    UNSTARTED `CRSession` is enough to drive the registry headless
//    (`RemoteWindowRegistryLeftBorderTests`, 2026-09-05: `initWithHost:` only allocates queues),
//    so the reachable surface is the outbound rect via `onWindowMoveSent`, not the private
//    seams. Their pure decision logic already
//    lives in `MacdowsCore` (`WindowGeometry`/`WindowMappability`/`StyleTranslator`/
//    `ZOrderSync`/`WindowShape`/`FocusAuthority`, covered by `swift test`); what remains in
//    the App files is AppKit/session orchestration, reachable only with a live session or a
//    running app. Registered, not tested -- the D7 boundary forbids injectability refactors.
//  * `AppDelegate`: its only branching (the display-change status-note text) is embedded in a
//    closure attached inside `applicationDidFinishLaunching`, which builds real windows and
//    activates NSApp. No pure seam is reachable without launching the app.
//  * Tests touching `NSScreen.screens` are vacuous on a truly headless Mac (no display): they
//    return early rather than fail, and the empty-list contract is pinned separately by
//    `emptyScreenListYieldsNoTopology`. On the project's actual hardware (one display,
//    phase3.md:219) every test below runs its full body -- but "runs its full body" is not
//    "every assertion discriminates" (review d7-r1 Important):
//  * SINGLE-DISPLAY DEGENERACY FAMILY: on a one-screen machine the primary screen's
//    `frame.origin` is (0,0), `isPrimary` is trivially true, and `backingScaleFactor` is
//    whatever the one panel reports (1x here) -- so the origin-axis, primary-flag and
//    scale assertions in `adapterMapsEachScreenFieldForField` cannot fail on this
//    hardware (an origin x/y swap mutation SURVIVES; measured in review). What that test
//    genuinely pins on this machine is the size mapping. The family reds only on
//    multi-display or 2x hardware; registered, not solved -- no injection seam exists
//    without the refactor D7 forbids.

@MainActor
@Suite("DisplayTopologyProvider")
struct DisplayTopologyProviderTests {
    /// ADR 0015 §2 rule 1: the adapter maps four fields per screen, verbatim -- frame origin
    /// and size in mac points, `backingScaleFactor` into BOTH scale ratios (§3's answer P),
    /// and `isPrimary` == "index 0", explicitly not `NSScreen.main`.
    @Test func adapterMapsEachScreenFieldForField() throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return } // headless: registered boundary, see file header
        let topology = try #require(DisplayTopologyProvider.topology(of: screens))
        try #require(topology.displays.count == screens.count)
        for (index, pair) in zip(topology.displays, screens).enumerated() {
            let (display, screen) = pair
            #expect(display.origin.x == Double(screen.frame.origin.x))
            #expect(display.origin.y == Double(screen.frame.origin.y))
            #expect(display.size.width == Double(screen.frame.width))
            #expect(display.size.height == Double(screen.frame.height))
            #expect(display.scale.remotePixelsPerPoint == Double(screen.backingScaleFactor))
            #expect(display.scale.backingPixelsPerPoint == Double(screen.backingScaleFactor))
            #expect(display.isPrimary == (index == 0))
        }
    }

    /// ADR 0015 §5.A.6: an empty screen list yields no topology (never a zero-size one) --
    /// the adapter must forward `DisplayTopology.init(displays:)`'s rejection, not paper over
    /// it with a default.
    @Test func emptyScreenListYieldsNoTopology() {
        #expect(DisplayTopologyProvider.topology(of: []) == nil)
    }

    /// ADR 0015 §5.A.4: the size `freezeSessionSnapshot()` returns is derived from the very
    /// snapshot it stores -- and `endSession()` drops the frozen state while leaving the live
    /// topology cache alone.
    @Test func freezePairsReturnedSizeWithSnapshotAndEndSessionClearsIt() throws {
        let provider = DisplayTopologyProvider(notificationCenter: NotificationCenter())
        let size = provider.freezeSessionSnapshot()
        guard !NSScreen.screens.isEmpty else {
            #expect(size == nil) // §5.A.6: nothing to send
            #expect(provider.sessionSnapshot == nil)
            return
        }
        let frozen = try #require(provider.sessionSnapshot)
        #expect(size == frozen.desktopSizeInRemotePixels)
        #expect(provider.sessionDesktopSize == size)
        provider.endSession()
        #expect(provider.sessionSnapshot == nil)
        #expect(provider.sessionDesktopSize == nil)
        #expect(provider.currentTopology != nil) // the live cache is not session state
    }

    /// ADR 0015 §5.A.2: before any freeze, a screen-parameter change reports "no session"
    /// (`sessionDesktopSize == nil`) and is never stale.
    @Test func observerBeforeAnyFreezeReportsNoSession() {
        let center = NotificationCenter()
        let provider = DisplayTopologyProvider(notificationCenter: center)
        var captured: DisplayTopologyProvider.ScreenParametersChange?
        provider.onScreenParametersChange = { captured = $0 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        guard let change = captured else {
            Issue.record("observer never fired for the injected center's notification")
            return
        }
        #expect(change.sessionDesktopSize == nil)
        #expect(!change.connectedDesktopSizeIsStale)
        #expect(change.currentTopologyIsEmpty == NSScreen.screens.isEmpty)
    }

    /// ADR 0015 §5.A.2/§5.A.3: with a session frozen and the layout physically unchanged, the
    /// verdict is NOT stale, the payload still carries the frozen size, and the frozen
    /// snapshot survives the notification untouched (the observer must not replace it).
    @Test func observerAfterFreezeReportsUnchangedLayoutAsNotStale() throws {
        guard !NSScreen.screens.isEmpty else { return } // headless: registered boundary
        let center = NotificationCenter()
        let provider = DisplayTopologyProvider(notificationCenter: center)
        let frozenSize = try #require(provider.freezeSessionSnapshot())
        let frozenSnapshot = try #require(provider.sessionSnapshot)
        var captured: DisplayTopologyProvider.ScreenParametersChange?
        provider.onScreenParametersChange = { captured = $0 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let change = try #require(captured)
        #expect(!change.connectedDesktopSizeIsStale)
        #expect(change.sessionDesktopSize == frozenSize)
        #expect(change.previous != nil)
        #expect(!change.currentTopologyIsEmpty)
        #expect(provider.sessionSnapshot == frozenSnapshot) // §5.A.3: no snapshot replacement
    }

    /// `ScreenParametersChange`'s own value logic, driven off a fixture topology (no screens
    /// involved): `currentTopologyIsEmpty` derives from `current`, and `description` renders
    /// the session size in `WxHrpx` form plus the verdict.
    @Test func screenParametersChangeValueLogic() throws {
        let fixture = try #require(DisplayTopology(displays: [
            DisplayTopology.Display(
                origin: MacPoint(x: 0, y: 0),
                size: MacSize(width: 1000, height: 600),
                scale: DisplayScale(remotePixelsPerPoint: 2, backingPixelsPerPoint: 2),
                isPrimary: true
            )
        ]))
        let stale = DisplayTopologyProvider.ScreenParametersChange(
            previous: nil,
            current: fixture,
            sessionDesktopSize: fixture.desktopSizeInRemotePixels,
            connectedDesktopSizeIsStale: true
        )
        #expect(!stale.currentTopologyIsEmpty)
        #expect(stale.description.contains("2000x1200rpx"))
        #expect(stale.description.contains("stale=true"))

        let empty = DisplayTopologyProvider.ScreenParametersChange(
            previous: nil, current: nil, sessionDesktopSize: nil,
            connectedDesktopSizeIsStale: false
        )
        #expect(empty.currentTopologyIsEmpty)
        #expect(empty.description.contains("<no usable display>"))
        #expect(empty.description.contains("stale=false"))
    }
}
