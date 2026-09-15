import AppKit
import IOSurface
import MacdowsCore
import Testing

// ADR-0018 §5.2 ② (owner ruling 2026-09-15 15:32 JST), the registry half -- MEASUREMENT ONLY.
//
// WHAT THE LANE HAS TO DECIDE. A RAIL window can be re-mapped onto a new GFX surface
// mid-session. The 2026-09-15 About window took one frame on its first surface and was then
// re-mapped twice with nothing ever presented again, and the run record could not say which of
// two mutually exclusive things happened:
//   4a -- the server DID draw into the new surface and the frame was lost on this side, or
//   4b -- the server only mapped it and never drew.
// `.surfaceMapped` remaps and re-applies geometry without ever presenting, and `handleFrameReady`
// has two SILENT drop points, so a lost frame leaves no trace anywhere. The rows this suite
// drives are that trace: per surface of a window, what arrived and what became of it.
//
// WHY THESE FIXTURES CAN EXIST AT ALL (the same three facts `RemoteWindowRegistryLeftBorderTests`
// establishes in its own header, plus one new one):
//   * an UNSTARTED `CRSession` is enough to build a registry, and nothing here contacts any host;
//   * `CRDPEvent` vends no initializer, so events are synthesized by overriding its getters;
//   * `StaticDisplayTopologyProvider` supplies a fixture layout, so nothing reads `NSScreen`;
//   * NEW: `-copyPublishedSurface:` is an ordinary overridable method, so a session double can
//     hand the registry a locally allocated IOSurface. That is what makes `presents` and the
//     "a live window but no surface to hand over" drop reachable offline -- the gap the O-A lane
//     registered on 2026-09-15 ("the registry-level path is not drivable offline") and the only
//     reason the counters can be tested rather than merely pinned.
//
// WHAT IS STILL OUT OF REACH OFFLINE, registered rather than worked around: the BRIDGE-side
// counters (`updates`/`dirty`/`publishes`/`stale`) are fed by the GFX `UpdateWindowFromSurface`
// hook and by the drain's generation filter, which need a real RDPGFX channel and a real
// reconnect. The counter TABLE itself is unit-tested in
// `MacdowsCoreTests.GfxCounterTableTests`; what this suite covers is that the registry MERGES it
// faithfully, including the "not tracked" verdict -- with a real session offline, every row must
// say `tracked=no`, because nothing has ever drawn.

/// A `SurfaceMapped` order with fields the test chooses. See the file header for why a subclass
/// is the only way to build one.
private final class SurfaceMappedStub: CRDPEvent {
    private let surface: UInt32
    private let window: UInt64
    private let width: UInt32
    private let height: UInt32

    init(surfaceId: UInt32, windowId: UInt32, mappedWidth: UInt32, mappedHeight: UInt32) {
        surface = surfaceId
        window = UInt64(windowId)
        width = mappedWidth
        height = mappedHeight
        super.init()
    }

    override var kind: CRDPEventKind { .surfaceMapped }
    override var generation: UInt32 { 0 }
    override var surfaceId: UInt32 { surface }
    override var mappedWindowId: UInt64 { window }
    override var mappedWidth: UInt32 { width }
    override var mappedHeight: UInt32 { height }
}

/// The frame-readiness doorbell, carrying only a surfaceId -- exactly as much as the real one
/// does (adr/0005 §1: a frame is state, the event carries no pixels).
private final class FrameReadyStub: CRDPEvent {
    private let surface: UInt32

    init(surfaceId: UInt32) {
        surface = surfaceId
        super.init()
    }

    override var kind: CRDPEventKind { .frameReady }
    override var generation: UInt32 { 0 }
    override var surfaceId: UInt32 { surface }
}

/// A minimal `WindowCreate` -- enough for `isMappableWindow` to accept it and for the registry to
/// build a real `RemoteWindow`. Modelled on `RemoteWindowRegistryLeftBorderTests`' own stub.
private final class WindowCreateStub: CRDPEvent {
    static let fieldTitle: UInt32 = 0x0000_0004
    static let fieldStyle: UInt32 = 0x0000_0008
    static let fieldShow: UInt32 = 0x0000_0010
    static let fieldSize: UInt32 = 0x0000_0400
    static let fieldOffset: UInt32 = 0x0000_0800
    /// `WINDOW_SHOW` (freerdp/window.h) -- any nonzero value means shown.
    static let showNormal: UInt32 = 5
    /// The About dialog's captured style, `WS_POPUP | WS_SYSMENU` -- the window this lane's own
    /// live case is about.
    static let aboutStyle: UInt32 = 0x8008_0000

    private let id: UInt32

    init(windowId: UInt32) {
        id = windowId
        super.init()
    }

    override var kind: CRDPEventKind { .windowCreate }
    override var generation: UInt32 { 0 }
    override var windowId: UInt32 { id }
    override var fieldFlags: UInt32 {
        Self.fieldOffset | Self.fieldSize | Self.fieldShow | Self.fieldTitle | Self.fieldStyle
    }
    override var style: UInt32 { Self.aboutStyle }
    override var styleEx: UInt32 { 0 }
    override var ownerWindowId: UInt32 { 0 }
    override var title: String { "gfx-frames-probe" }
    override var offsetX: Int32 { 300 }
    override var offsetY: Int32 { 200 }
    override var windowWidth: UInt32 { 522 }
    override var windowHeight: UInt32 { 515 }
    override var show: UInt32 { Self.showNormal }
}

/// An unstarted session that hands out a prepared surface for the surface ids the test names,
/// and `nil` for every other -- i.e. the two outcomes `handleFrameReady`'s second guard
/// distinguishes, chosen per surface instead of by connection state.
///
/// It also fabricates BRIDGE counters, which is the only way to test the merge offline: with no
/// RDPGFX channel the real table is empty for every id, so a suite that used only the real getter
/// could never tell "the registry reports the bridge's numbers" from "the registry reports zeros".
private final class SurfaceVendingSession: CRSession {
    /// Surface ids this session will hand a real IOSurface for, and the surface it hands.
    var published: [UInt32: IOSurface] = [:]
    /// Fabricated bridge counters, per surfaceId. An id that is absent reads as NOT TRACKED --
    /// the same answer the real bridge gives for a surface it never saw.
    var bridgeCounters: [UInt32: (updates: UInt64, dirty: UInt64, publishes: UInt64, stale: UInt64)] = [:]

    /// `IOSurfaceRef`, matching the header's own `CF_RETURNS_RETAINED` declaration -- the
    /// registry consumes it as an `IOSurface`, and the toll-free bridge crosses on return.
    override func copyPublishedSurface(_ surfaceId: UInt32) -> IOSurfaceRef? {
        published[surfaceId]
    }

    override func gfxSurfaceCounters(
        _ surfaceId: UInt32,
        updates: UnsafeMutablePointer<UInt64>,
        dirty: UnsafeMutablePointer<UInt64>,
        publishes: UnsafeMutablePointer<UInt64>,
        stale: UnsafeMutablePointer<UInt64>
    ) -> Bool {
        guard let counters = bridgeCounters[surfaceId] else { return false }
        updates.pointee = counters.updates
        dirty.pointee = counters.dirty
        publishes.pointee = counters.publishes
        stale.pointee = counters.stale
        return true
    }
}

@MainActor
@Suite("per-surface GFX frame rows (ADR-0018 §5.2 ②, measurement only)")
struct GfxFrameCountersTests {
    /// A fixture layout, not this machine's: one 1920x1080 1x primary, injected through the
    /// registry's existing provider parameter.
    private static func fixtureTopology() throws -> DisplayTopology {
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
        )
        return try #require(DisplayTopology(displays: [display]))
    }

    private static func makeRegistry() throws -> (RemoteWindowRegistry, SurfaceVendingSession) {
        let session = SurfaceVendingSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(
            session: session,
            topologyProvider: StaticDisplayTopologyProvider(try fixtureTopology())
        )
        return (registry, session)
    }

    /// A tiny BGRA surface -- the frame path only ever hands it to a `CALayer` here, so its
    /// contents are irrelevant; what matters is that it is a real IOSurface the session can vend.
    private static func makeSurface() -> IOSurface {
        guard let surface = IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 as UInt32
        ]) else {
            fatalError("IOSurface allocation failed")
        }
        return surface
    }

    @Test("a window's rows are its mapping history in arrival order, with only the last current")
    func historyIsTheRemapSequence() throws {
        let (registry, _) = try Self.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        // The server re-announcing an unchanged mapping is not a remap: a second row here would
        // read as one, and the whole point of `order=` is that it counts remaps.
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))

        let rows = registry.gfxFrameRows(windowId: 101)
        #expect(rows.map(\.surfaceId) == [11, 12])
        #expect(rows.map(\.order) == [1, 2])
        // `current` is the registry's own 1:1 mapping, which is why the older surface -- whose
        // `surfaceMappedSize` entry the remap deleted -- can still be reported at its own size.
        #expect(rows.map(\.isCurrent) == [false, true])
        #expect(rows[0].mappedSize == CGSize(width: 522, height: 515))
        #expect(rows[1].mappedSize == CGSize(width: 500, height: 505))
        #expect(registry.gfxFrameOrphanRows().isEmpty)
        // A window nobody ever mapped has no rows at all -- an invented row would name a surface
        // id that does not exist.
        #expect(registry.gfxFrameRows(windowId: 999).isEmpty)
    }

    @Test("the 2026-09-15 shape: a remap with no frame behind it leaves the new surface at zero")
    func aRemapWithNoFrameLeavesTheNewSurfaceEmpty() throws {
        let (registry, session) = try Self.makeRegistry()
        session.published[11] = Self.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))
        // ... and then the remap the About window took, with nothing published behind it.
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))

        let rows = registry.gfxFrameRows(windowId: 101)
        #expect(rows.count == 2)
        // The first surface keeps its history: the remap did not move, merge or reset it.
        #expect(rows[0].ready == 1 && rows[0].presents == 1)
        #expect(rows[0].dropUnmapped == 0 && rows[0].dropNoSurface == 0)
        // The second is the answer the run record could not give: nothing arrived for it at all.
        // Read together with `tracked`/`dirty`, this is what separates ADR-0018 §5.2 ②'s 4b (the
        // server never drew) from 4a (it drew and the frame was lost here).
        #expect(rows[1].ready == 0 && rows[1].presents == 0)
        #expect(rows[1].dropUnmapped == 0 && rows[1].dropNoSurface == 0)
        // The per-window counter the `[edge-presents]` line reads is the sum of the per-surface
        // ones: two measurements of the same frames, taken at different places, must agree. That
        // holds because a surface id occupies exactly one row (see the A -> B -> A case above);
        // it is false for any history that can repeat an id.
        #expect(registry.presentCount(windowId: 101) == rows.reduce(0) { $0 + $1.presents })
    }

    @Test("a re-map back to an earlier surface keeps one row per surface and one current row")
    func aRemapBackToAnEarlierSurfaceDoesNotDuplicateRows() throws {
        let (registry, session) = try Self.makeRegistry()
        session.published[11] = Self.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        // A -> B -> A, reachable from server orders alone: the 1:1 cleanup drops A from
        // `surfaceToWindow` when B is mapped and re-adds it when A comes back.
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))

        let rows = registry.gfxFrameRows(windowId: 101)
        // TWO rows, not three: the registry's counters are keyed by surfaceId, so a second row
        // for surface 11 would print its whole tally twice and make any column sum double-count.
        #expect(rows.map(\.surfaceId) == [11, 12])
        #expect(rows.map(\.order) == [1, 2])
        // ... and exactly ONE of them is current. Two rows claiming `current=yes` would make the
        // word mean neither, and it has to mean what `[f1]`/`[edge]` mean by it.
        #expect(rows.filter(\.isCurrent).map(\.surfaceId) == [11])
        // The partition that the single-row rule buys: summing the per-surface presents over a
        // window's rows reproduces the window's own counter, which is what `[edge-presents]`
        // prints. With a duplicated row this reads 3 against a presentCount of 2.
        #expect(registry.presentCount(windowId: 101) == 2)
        #expect(rows.reduce(0) { $0 + $1.presents } == 2)
        // The re-mapped entry keeps its first-seen position and refreshes its size.
        #expect(rows[0].mappedSize == CGSize(width: 522, height: 515))
    }

    @Test("a surface mapped to a window this registry does not render is still printed, as id=none")
    func aSurfaceOwnedByAnUnrenderedWindowIsReportedAsAnOrphan() throws {
        let (registry, _) = try Self.makeRegistry()
        // No WindowCreate for 555: `.surfaceMapped` still records the mapping (the real handler
        // does it unconditionally), so this surface HAS an owner -- just not one with a
        // `RemoteWindow`, which is the second half of `handleFrameReady`'s first guard and
        // exactly what the harness's per-window loop can never print.
        registry.handle(SurfaceMappedStub(surfaceId: 21, windowId: 555, mappedWidth: 300, mappedHeight: 200))
        registry.handle(FrameReadyStub(surfaceId: 21))

        let orphans = registry.gfxFrameOrphanRows()
        #expect(orphans.map(\.surfaceId) == [21])
        let orphan = try #require(orphans.first)
        #expect(orphan.windowId == nil && orphan.order == 0 && orphan.mappedSize == nil)
        #expect(orphan.ready == 1 && orphan.dropUnmapped == 1 && orphan.presents == 0)
        // The data exists under that windowId; what it lacks is a printer, which is why the row
        // has to appear here. (`id=none` cannot say WHICH of the two causes applies -- see
        // `gfxFrameOrphanRows`' own doc comment.)
        #expect(registry.gfxFrameRows(windowId: 555).map(\.surfaceId) == [21])
        // ... and once a rendered window owns it, it stops being printed as an orphan.
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 21, windowId: 101, mappedWidth: 300, mappedHeight: 200))
        #expect(registry.gfxFrameOrphanRows().isEmpty)
    }

    @Test("the two silent drop points are counted apart, and account for every frame-ready")
    func bothDropPointsAreCountedApart() throws {
        let (registry, session) = try Self.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))

        // Drop 1 -- no live window for the surface. Here it is "never mapped"; the same guard
        // also covers "mapped to a window this registry does not render", a conflation this lane
        // measures rather than reshapes.
        registry.handle(FrameReadyStub(surfaceId: 77))
        registry.handle(FrameReadyStub(surfaceId: 77))

        // Drop 2 -- a live window, but the bridge has nothing to hand over (already consumed, or
        // refused as belonging to an older connection generation).
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))

        // ... and then a real one, so the same surface shows both outcomes.
        session.published[11] = Self.makeSurface()
        registry.handle(FrameReadyStub(surfaceId: 11))

        let mapped = try #require(registry.gfxFrameRows(windowId: 101).first)
        #expect(mapped.ready == 2)
        #expect(mapped.dropNoSurface == 1)
        #expect(mapped.presents == 1)
        #expect(mapped.dropUnmapped == 0)
        // The partition that makes the row readable at all: every frame-ready ended in exactly
        // one of the three outcomes, so a fourth exit added later shows up as a missing frame
        // rather than as nothing.
        #expect(mapped.ready == mapped.dropUnmapped + mapped.dropNoSurface + mapped.presents)

        let orphans = registry.gfxFrameOrphanRows()
        #expect(orphans.count == 1)
        let orphan = try #require(orphans.first)
        #expect(orphan.windowId == nil && orphan.order == 0 && orphan.isCurrent == false)
        #expect(orphan.surfaceId == 77 && orphan.ready == 2 && orphan.dropUnmapped == 2)
        #expect(orphan.mappedSize == nil && orphan.presents == 0)
    }

    @Test("a surface stops being an orphan once a window claims it, keeping the counts it earned")
    func anOrphanSurfaceKeepsItsCountsOnceMapped() throws {
        let (registry, _) = try Self.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        // The real ordering hazard this models: a frame-ready can arrive before the mapping that
        // explains it (adr/0005 §1 -- a frame is state, so the client simply retries later).
        registry.handle(FrameReadyStub(surfaceId: 11))
        #expect(registry.gfxFrameOrphanRows().map(\.surfaceId) == [11])

        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        #expect(registry.gfxFrameOrphanRows().isEmpty)

        // Counters are keyed by surface, not by row, so the earlier drop is still attached to
        // the surface that suffered it -- a row that started counting at the mapping would hide
        // exactly the pre-mapping drops the orphan list exists to surface.
        let row = try #require(registry.gfxFrameRows(windowId: 101).first)
        #expect(row.surfaceId == 11 && row.order == 1 && row.isCurrent)
        #expect(row.ready == 1 && row.dropUnmapped == 1 && row.presents == 0)
    }

    @Test("the bridge's counters are reported verbatim, and an unmeasured surface says so")
    func bridgeCountersAreMergedAndUntrackedIsNotZero() throws {
        let (registry, session) = try Self.makeRegistry()
        // Surface 11 as the bridge would report a drawn-and-published surface; surface 12 left
        // absent, i.e. one the bridge's fixed-capacity table never held a slot for.
        session.bridgeCounters[11] = (updates: 42, dirty: 7, publishes: 42, stale: 2)
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))

        let rows = registry.gfxFrameRows(windowId: 101)
        #expect(rows[0].tracked)
        #expect(rows[0].updates == 42 && rows[0].dirty == 7 && rows[0].publishes == 42)
        // The drain-side discard is reported per surface too, not folded into the session-wide
        // counter -- it is the term that makes `publishes = stale + ready + in-flight` complete.
        #expect(rows[0].stale == 2)
        // NOT zeros-with-tracked-true: "nothing was ever drawn into this surface" is one of the
        // two verdicts the lane exists to reach, so an unmeasured surface must never be able to
        // impersonate it.
        #expect(rows[1].tracked == false)
        #expect(rows[1].updates == 0 && rows[1].dirty == 0 && rows[1].publishes == 0)
        #expect(rows[1].stale == 0)
    }

    @Test("with a real session and no GFX channel, every row honestly reports no bridge measurement")
    func aRealSessionOfflineReportsEveryRowUntracked() throws {
        // The offline boundary, asserted rather than assumed: the bridge counters are written by
        // the GFX hook, which never runs without a live RDPGFX channel. A registry over a real
        // (unstarted) session must therefore say `tracked == false` everywhere -- if this ever
        // starts reporting `true`, the counters are being fed by something other than the hook.
        let session = CRSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(
            session: session,
            topologyProvider: StaticDisplayTopologyProvider(try Self.fixtureTopology())
        )
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))

        let row = try #require(registry.gfxFrameRows(windowId: 101).first)
        #expect(row.tracked == false)
        #expect(row.updates == 0 && row.dirty == 0 && row.publishes == 0 && row.stale == 0)
        // ... and the registry half still measures, which is what makes the pair readable.
        #expect(row.ready == 0 && row.mappedSize == CGSize(width: 522, height: 515))
    }
}
