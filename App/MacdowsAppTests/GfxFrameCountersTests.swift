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
    /// The miss reason reported for a surface id NOT in `published` -- the four outcomes the real
    /// bridge distinguishes (ADR-0018 §5.2 ②b). An id that is absent here answers `.noSlot`, the
    /// same answer the real table gives for an id it has no slot for.
    var misses: [UInt32: CRPublishedSurfaceMiss] = [:]
    /// Fabricated bridge counters, per surfaceId. An id that is absent reads as NOT TRACKED --
    /// the same answer the real bridge gives for a surface it never saw.
    var bridgeCounters: [UInt32: BridgeCounters] = [:]

    /// The six numbers `-gfxSurfaceCounters:...` returns, as one value so a test can set them in
    /// one statement and read them back in the order the row prints them.
    struct BridgeCounters {
        var updates: UInt64 = 0
        var dirty: UInt64 = 0
        var writes: UInt64 = 0
        var publishes: UInt64 = 0
        var stale: UInt64 = 0
        var erased: UInt64 = 0
    }

    /// The variant `handleFrameReady` actually calls: the surface if there is one, otherwise the
    /// reason there is not. `IOSurfaceRef`, matching the header's own `CF_RETURNS_RETAINED`
    /// declaration -- the registry consumes it as an `IOSurface`, and the toll-free bridge crosses
    /// on return.
    override func copyPublishedSurface(
        _ surfaceId: UInt32, reason: UnsafeMutablePointer<CRPublishedSurfaceMiss>?
    ) -> IOSurfaceRef? {
        if let surface = published[surfaceId] {
            reason?.pointee = CRPublishedSurfaceMiss.none
            return surface
        }
        reason?.pointee = misses[surfaceId] ?? CRPublishedSurfaceMiss.noSlot
        return nil
    }

    /// Kept in the production shape (the real one is a NULL-reason call to the variant above), so
    /// a future caller of the reason-less entry point sees the same fixture rather than the real
    /// session's empty table.
    override func copyPublishedSurface(_ surfaceId: UInt32) -> IOSurfaceRef? {
        copyPublishedSurface(surfaceId, reason: nil)
    }

    override func gfxSurfaceCounters(
        _ surfaceId: UInt32,
        updates: UnsafeMutablePointer<UInt64>,
        dirty: UnsafeMutablePointer<UInt64>,
        writes: UnsafeMutablePointer<UInt64>,
        publishes: UnsafeMutablePointer<UInt64>,
        stale: UnsafeMutablePointer<UInt64>,
        erased: UnsafeMutablePointer<UInt64>
    ) -> Bool {
        guard let counters = bridgeCounters[surfaceId] else { return false }
        updates.pointee = counters.updates
        dirty.pointee = counters.dirty
        writes.pointee = counters.writes
        publishes.pointee = counters.publishes
        stale.pointee = counters.stale
        erased.pointee = counters.erased
        return true
    }
}

/// The fixtures both suites in this file build on. File-level rather than nested in one suite so
/// the period suite below reuses the same registry, the same fixture topology and the same
/// IOSurface allocation instead of a second copy that could drift from this one.
private enum GfxRegistryFixture {
    /// A fixture layout, not this machine's: one 1920x1080 1x primary, injected through the
    /// registry's existing provider parameter.
    static func fixtureTopology() throws -> DisplayTopology {
        let display = DisplayTopology.Display(
            origin: MacPoint(x: 0, y: 0), size: MacSize(width: 1920, height: 1080),
            scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
        )
        return try #require(DisplayTopology(displays: [display]))
    }

    @MainActor
    static func makeRegistry() throws -> (RemoteWindowRegistry, SurfaceVendingSession) {
        let session = SurfaceVendingSession(host: "", user: "", password: "", program: "")
        let registry = RemoteWindowRegistry(
            session: session,
            topologyProvider: StaticDisplayTopologyProvider(try fixtureTopology())
        )
        return (registry, session)
    }

    /// A tiny BGRA surface -- the frame path only ever hands it to a `CALayer` here, so its
    /// contents are irrelevant; what matters is that it is a real IOSurface the session can vend.
    static func makeSurface() -> IOSurface {
        guard let surface = IOSurface(properties: [
            .width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 as UInt32
        ]) else {
            fatalError("IOSurface allocation failed")
        }
        return surface
    }
}

@MainActor
@Suite("per-surface GFX frame rows (ADR-0018 §5.2 ②, measurement only)")
struct GfxFrameCountersTests {

    @Test("a window's rows are its mapping history in arrival order, with only the last current")
    func historyIsTheRemapSequence() throws {
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
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
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
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
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
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
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
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
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
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
        session.published[11] = GfxRegistryFixture.makeSurface()
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
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
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
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        // Surface 11 as the bridge would report a drawn-and-published surface; surface 12 left
        // absent, i.e. one the bridge's fixed-capacity table never held a slot for.
        session.bridgeCounters[11] = SurfaceVendingSession.BridgeCounters(
            updates: 42, dirty: 7, writes: 40, publishes: 42, stale: 2, erased: 1)
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
            topologyProvider: StaticDisplayTopologyProvider(try GfxRegistryFixture.fixtureTopology())
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


// ADR-0018 §5.2 ②b, the per-mapping-period half -- MEASUREMENT ONLY.
//
// WHY A SECOND SUITE OVER THE SAME REGISTRY. The rows the suite above drives are per SURFACE ID
// and cumulative, and the 2026-09-15 pre-registration recorded first-hand what that costs: when a
// window is re-mapped back to a surface it already used (`A -> B -> A`, two of that batch's three
// pairs), one row sums BOTH mapping periods, so every interpretation rule keyed on "after the last
// remap" became unjudgeable -- `presents>0` on such a row cannot say WHEN the present happened.
// These rows cut the same history at the mappings: one row per mapping period, each carrying the
// DIFFERENCE between the surface's counters at the end of that period and at its start.
//
// AND THE SECOND HALF, from the 2026-09-15 guard trace: the two drop columns of the older row were
// conflations. Guard 1 mixed "no mapping" with "mapped to a window this client does not render"
// (the trace found the 22 were the SECOND), and guard 2 mixed four bridge outcomes the trace could
// only separate by elimination (no slot / never written / already leased / stale generation). All
// six are counted apart here, and each one's own branch is driven below.
@MainActor
@Suite("per-mapping-period GFX rows (ADR-0018 §5.2 ②b, measurement only)")
struct GfxMappingPeriodTests {
    /// Every counter of a period row as one comparable value, so a test states a whole row in one
    /// `#expect` instead of ten -- and a field silently dropped from the row type fails to compile
    /// here rather than passing unnoticed.
    private struct Counts: Equatable {
        var updates: UInt64 = 0
        var dirty: UInt64 = 0
        var writes: UInt64 = 0
        var publishes: UInt64 = 0
        var stale: UInt64 = 0
        var erased: UInt64 = 0
        var ready = 0
        var dropNoMap = 0
        var dropNoWindow = 0
        var dropNoSlot = 0
        var dropNeverWritten = 0
        var dropLeased = 0
        var dropGeneration = 0
        var presents = 0

        init() {}

        init(_ row: RemoteWindowRegistry.GfxPeriodRow) {
            updates = row.updates
            dirty = row.dirty
            writes = row.writes
            publishes = row.publishes
            stale = row.stale
            erased = row.erased
            ready = row.ready
            dropNoMap = row.dropNoMap
            dropNoWindow = row.dropNoWindow
            dropNoSlot = row.dropNoSlot
            dropNeverWritten = row.dropNeverWritten
            dropLeased = row.dropLeased
            dropGeneration = row.dropGeneration
            presents = row.presents
        }

        static func + (lhs: Counts, rhs: Counts) -> Counts {
            var out = Counts()
            out.updates = lhs.updates + rhs.updates
            out.dirty = lhs.dirty + rhs.dirty
            out.writes = lhs.writes + rhs.writes
            out.publishes = lhs.publishes + rhs.publishes
            out.stale = lhs.stale + rhs.stale
            out.erased = lhs.erased + rhs.erased
            out.ready = lhs.ready + rhs.ready
            out.dropNoMap = lhs.dropNoMap + rhs.dropNoMap
            out.dropNoWindow = lhs.dropNoWindow + rhs.dropNoWindow
            out.dropNoSlot = lhs.dropNoSlot + rhs.dropNoSlot
            out.dropNeverWritten = lhs.dropNeverWritten + rhs.dropNeverWritten
            out.dropLeased = lhs.dropLeased + rhs.dropLeased
            out.dropGeneration = lhs.dropGeneration + rhs.dropGeneration
            out.presents = lhs.presents + rhs.presents
            return out
        }
    }

    @Test("A -> B -> A gives (A,1) (B,1) (A,2), each measured over its own interval")
    func remappingBackToASurfaceOpensASecondPeriodRatherThanMergingRows() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))
        // The window moves to another surface; 11 keeps existing, and a frame that arrives for it
        // now has no mapping to route by -- one of the events a cumulative row cannot place in time.
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))
        registry.handle(FrameReadyStub(surfaceId: 11))
        // ... and back, which is where the merged row was born.
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))

        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.map { ($0.surfaceId, $0.period) }.map { "\($0.0):\($0.1)" } == ["11:1", "12:1", "11:2"])
        // THE POINT OF THE LANE: the last period of the current surface carries ONLY what happened
        // after the last remap -- one frame-ready, presented -- while the first period keeps the
        // frame it showed and the drop that followed it.
        #expect(Counts(rows[2]) == { var c = Counts(); c.ready = 1; c.presents = 1; return c }())
        #expect(Counts(rows[0]) == { var c = Counts(); c.ready = 2; c.presents = 1; c.dropNoMap = 1; return c }())
        #expect(Counts(rows[1]) == Counts())
        // Exactly one row may claim the window's current mapping, and it is the LAST period of that
        // surface -- not the first, which is where a lifetime row puts it (`gfxFrameRows`' own
        // `order=1` row for surface 11 is the one that says `current`).
        #expect(rows.filter(\.isCurrent).map { ($0.surfaceId, $0.period) }.map { "\($0.0):\($0.1)" } == ["11:2"])
        #expect(rows.map(\.mappedSize) == [CGSize(width: 522, height: 515), CGSize(width: 500, height: 505),
                                           CGSize(width: 522, height: 515)])
        // THE IDENTITY A RECORD CAN CHECK: for one window and one surface, the periods sum to the
        // cumulative `[gfx-frames]` row printed above them. It holds because the periods partition
        // everything after the first mapping and `period=0` (absent here -- surface 11 arrived
        // clean) holds everything before it.
        let frames = try #require(registry.gfxFrameRows(windowId: 101).first { $0.surfaceId == 11 })
        let summed = rows.filter { $0.surfaceId == 11 }.map(Counts.init).reduce(Counts(), +)
        #expect(summed.ready == frames.ready && summed.presents == frames.presents)
        #expect(summed.dropNoMap + summed.dropNoWindow == frames.dropUnmapped)
        #expect(registry.gfxPeriodRows(windowId: 999).isEmpty)
    }

    @Test("what a surface collected before its first mapping is its period=0 row, frozen")
    func framesBeforeTheFirstMappingLandInPeriodZero() throws {
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        // A frame-ready can precede the mapping that explains it (adr/0005 §1 -- a frame is state,
        // so the client simply retries), and in the 2026-09-15 runs a surface could accrue dozens
        // of drops under a window this client does not render before another window claimed it.
        registry.handle(FrameReadyStub(surfaceId: 21))
        registry.handle(FrameReadyStub(surfaceId: 21))
        registry.handle(SurfaceMappedStub(surfaceId: 21, windowId: 101, mappedWidth: 300, mappedHeight: 200))

        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.map(\.period) == [0, 1])
        // Period 0 is the pre-history, and it is NOT an interval: it carries the baseline itself.
        #expect(Counts(rows[0]) == { var c = Counts(); c.ready = 2; c.dropNoMap = 2; return c }())
        #expect(rows[0].isCurrent == false)
        // No size: the interval predates any mapping of this surface to this window, so nothing was
        // ever announced for it -- the row says `mapped=n/a` rather than borrowing period 1's size.
        #expect(rows[0].mappedSize == nil)
        #expect(rows[1].mappedSize == CGSize(width: 300, height: 200))
        // The mapping period itself starts clean, which is the whole reason the split exists: the
        // two drops belong to the time before the window had anything to do with this surface.
        #expect(Counts(rows[1]) == Counts())
        #expect(rows[1].isCurrent)

        // ... and it stays frozen: a later frame lands in the OPEN period, never in the pre-history.
        registry.handle(FrameReadyStub(surfaceId: 21))
        let after = registry.gfxPeriodRows(windowId: 101)
        #expect(Counts(after[0]) == { var c = Counts(); c.ready = 2; c.dropNoMap = 2; return c }())
        #expect(Counts(after[1]) == { var c = Counts(); c.ready = 1; c.dropNoSlot = 1; return c }())
    }

    @Test("a surface that arrives clean gets no period=0 row at all")
    func aCleanSurfaceHasNoPreHistoryRow() throws {
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        // An all-zero pre-history is not a measurement, and a row of zeros in every run's log would
        // be noise that the one meaningful period=0 row has to be found among.
        #expect(registry.gfxPeriodRows(windowId: 101).map(\.period) == [1])
    }

    @Test("the server re-announcing an unchanged mapping does not cut the period in two")
    func aRepeatedAnnouncementOfTheSameMappingKeepsOnePeriod() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))
        // The same mapping, announced again -- which the server does, and which the lifetime rows
        // already treat as "not a remap". A period is the stretch during which the window was
        // mapped to the surface; a re-announcement is a moment INSIDE one, so cutting here would
        // make the last period mean "since the last re-announcement" and a `presents=0` on it would
        // no longer mean "nothing presented since the remap" -- the exact misreading this lane
        // exists to remove.
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 524, mappedHeight: 516))
        registry.handle(FrameReadyStub(surfaceId: 11))

        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.map(\.period) == [1])
        #expect(Counts(rows[0]) == { var c = Counts(); c.ready = 2; c.presents = 2; return c }())
        // The re-announcement's size still refreshes the open period, exactly as it refreshes the
        // lifetime row -- the newest announced size is the true one.
        #expect(rows[0].mappedSize == CGSize(width: 524, height: 516))
    }

    @Test("each of the six drop causes is counted on its own branch, and the two old totals are their sums")
    func everyDropCauseIsCountedApart() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))

        // 1. no mapping at all for the surface.
        registry.handle(FrameReadyStub(surfaceId: 77))
        // 2. mapped, but to a window this registry does not render (no WindowCreate for 555) --
        //    the branch the 2026-09-15 trace identified as the high-volume one, and the half the
        //    single `drop-unmapped` column could not name.
        registry.handle(SurfaceMappedStub(surfaceId: 78, windowId: 555, mappedWidth: 10, mappedHeight: 10))
        registry.handle(FrameReadyStub(surfaceId: 78))
        // 3-6. a live window, and each of the bridge's four miss reasons in turn.
        for (surfaceId, miss) in [
            (81, CRPublishedSurfaceMiss.noSlot), (82, .neverWritten), (83, .alreadyLeased), (84, .staleGeneration)
        ] {
            session.misses[UInt32(surfaceId)] = miss
            registry.handle(SurfaceMappedStub(
                surfaceId: UInt32(surfaceId), windowId: 101, mappedWidth: 20, mappedHeight: 20))
            registry.handle(FrameReadyStub(surfaceId: UInt32(surfaceId)))
        }
        // ... and one that actually presents, so `ready` has every outcome in it.
        session.published[85] = GfxRegistryFixture.makeSurface()
        registry.handle(SurfaceMappedStub(surfaceId: 85, windowId: 101, mappedWidth: 20, mappedHeight: 20))
        registry.handle(FrameReadyStub(surfaceId: 85))

        let rows = registry.gfxPeriodRows(windowId: 101)
        func row(_ surfaceId: UInt32) throws -> Counts {
            Counts(try #require(rows.first { $0.surfaceId == surfaceId && $0.period == 1 }))
        }
        #expect(try row(81).dropNoSlot == 1)
        #expect(try row(82).dropNeverWritten == 1)
        #expect(try row(83).dropLeased == 1)
        #expect(try row(84).dropGeneration == 1)
        #expect(try row(85).presents == 1)
        // Each on its OWN branch: a row that counted two causes would fail here, which is what
        // makes a mutation that merges any pair visible.
        #expect(try row(81) == { var c = Counts(); c.ready = 1; c.dropNoSlot = 1; return c }())
        #expect(try row(82) == { var c = Counts(); c.ready = 1; c.dropNeverWritten = 1; return c }())
        #expect(try row(83) == { var c = Counts(); c.ready = 1; c.dropLeased = 1; return c }())
        #expect(try row(84) == { var c = Counts(); c.ready = 1; c.dropGeneration = 1; return c }())
        // Guard 1's two halves, each against its own surface.
        let unmapped = registry.gfxPeriodRows(windowId: 555)
        #expect(Counts(try #require(unmapped.first)).dropNoWindow == 1)
        #expect(Counts(try #require(unmapped.first)).dropNoMap == 0)
        let orphan = try #require(registry.gfxFrameOrphanRows().first { $0.surfaceId == 77 })
        #expect(orphan.ready == 1 && orphan.dropUnmapped == 1)

        // THE COMPATIBILITY CONTRACT: the lane-② row still prints exactly two drop columns, and
        // each is the sum of its sub-causes -- so `[gfx-frames]` is byte-identical to what it was.
        for surfaceId in [UInt32(81), 82, 83, 84] {
            let frames = try #require(registry.gfxFrameRows(windowId: 101).first { $0.surfaceId == surfaceId })
            let period = try row(surfaceId)
            #expect(frames.dropNoSurface
                == period.dropNoSlot + period.dropNeverWritten + period.dropLeased + period.dropGeneration)
            #expect(frames.dropUnmapped == period.dropNoMap + period.dropNoWindow)
            // ... and the exact identity the row's own doc comment states.
            #expect(frames.ready == frames.dropUnmapped + frames.dropNoSurface + frames.presents)
        }
    }

    @Test("the reason API's outcomes decide which counter moves, and a real session answers noSlot")
    func theMissReasonDecidesTheCounter() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))

        // The same surface, the same window, the same frame-ready -- only the bridge's answer
        // changes, and each answer moves a different counter. Nothing else in the registry can tell
        // these apart, which is why the reason had to come from the session at all.
        session.misses[11] = .staleGeneration
        registry.handle(FrameReadyStub(surfaceId: 11))
        session.misses[11] = .alreadyLeased
        registry.handle(FrameReadyStub(surfaceId: 11))
        session.misses[11] = .neverWritten
        registry.handle(FrameReadyStub(surfaceId: 11))
        session.misses[11] = .noSlot
        registry.handle(FrameReadyStub(surfaceId: 11))
        // ... and the fifth outcome, a surface actually handed over.
        session.published[11] = GfxRegistryFixture.makeSurface()
        registry.handle(FrameReadyStub(surfaceId: 11))

        let row = Counts(try #require(registry.gfxPeriodRows(windowId: 101).first))
        var expected = Counts()
        expected.ready = 5
        expected.dropGeneration = 1
        expected.dropLeased = 1
        expected.dropNeverWritten = 1
        expected.dropNoSlot = 1
        expected.presents = 1
        #expect(row == expected)

        // The PRODUCTION implementation, not the double: an unstarted session has a real (empty)
        // surface table, so the one outcome reachable offline must be the honest one -- and the
        // out-parameter must be written even though the call returns nothing.
        let real = CRSession(host: "", user: "", password: "", program: "")
        var miss = CRPublishedSurfaceMiss.staleGeneration
        #expect(real.copyPublishedSurface(11, reason: &miss) == nil)
        #expect(miss == .noSlot)
        // The reason-less entry point still exists and still answers the same nothing.
        #expect(real.copyPublishedSurface(11) == nil)
    }

    @Test("writes and erased are per-period differences, and a teardown between periods lands in the period it happened in")
    func bridgeWritesAndTeardownsAreMeasuredPerPeriod() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        session.bridgeCounters[11] = SurfaceVendingSession.BridgeCounters()
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))

        // While the window shows surface 11 the bridge accepts every write it publishes.
        session.bridgeCounters[11] = SurfaceVendingSession.BridgeCounters(
            updates: 10, dirty: 4, writes: 10, publishes: 10, stale: 0, erased: 0)
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))
        // THE 2026-09-15 MECHANISM, in miniature: while the window is on surface 12, an unmap of
        // the window erases surface 11's slot too (the bridge erases by windowId, and this registry
        // is never told). Afterwards the server keeps drawing into 11 -- `updates` and `publishes`
        // rise -- but the writes are declined, because there is no slot to write into.
        session.bridgeCounters[11] = SurfaceVendingSession.BridgeCounters(
            updates: 14, dirty: 6, writes: 10, publishes: 14, stale: 0, erased: 1)
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        session.bridgeCounters[11] = SurfaceVendingSession.BridgeCounters(
            updates: 20, dirty: 9, writes: 12, publishes: 20, stale: 0, erased: 1)

        let rows = registry.gfxPeriodRows(windowId: 101)
        let first = try #require(rows.first { $0.surfaceId == 11 && $0.period == 1 })
        let second = try #require(rows.first { $0.surfaceId == 11 && $0.period == 2 })
        // The teardown happened after the window moved away and before it came back, i.e. inside
        // the interval period 1 covers -- which is exactly why a period runs to the NEXT mapping of
        // the same surface rather than stopping at the un-mapping: ending it early would drop the
        // erase, the extra updates and the declined writes into a gap no row reports.
        #expect(first.erased == 1)
        #expect(first.updates == 14 && first.dirty == 6 && first.writes == 10 && first.publishes == 14)
        // The period the lane reads: since the last remap, the server drew six more frames, the
        // bridge accepted two of the writes, and nothing was torn down.
        #expect(second.erased == 0)
        #expect(second.updates == 6 && second.dirty == 3 && second.writes == 2 && second.publishes == 6)
        #expect(first.tracked && second.tracked)
        // `writes < publishes` over a period is the shape that says a published frame reached no
        // buffer at all -- invisible in every counter the previous lane had.
        #expect(second.writes < second.publishes)
        // And the partition identity holds for the bridge half too.
        #expect(first.updates + second.updates == 20)
        #expect(first.erased + second.erased == 1)
    }

    @Test("an untracked surface reports no bridge measurement rather than a measured zero, per period")
    func untrackedSurfacesSaySoOnEveryPeriodRow() throws {
        let (registry, _) = try GfxRegistryFixture.makeRegistry()
        registry.handle(WindowCreateStub(windowId: 101))
        // No `bridgeCounters` entry: the fixed-capacity table never held a slot for this surface.
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(SurfaceMappedStub(surfaceId: 12, windowId: 101, mappedWidth: 500, mappedHeight: 505))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))

        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.allSatisfy { $0.tracked == false })
        // "Never measured" must not be able to impersonate "measured, and the server drew nothing"
        // -- that zero is one of the two verdicts ADR-0018 §5.2 ② exists to reach.
        #expect(rows.allSatisfy { $0.updates == 0 && $0.dirty == 0 && $0.writes == 0 })
        #expect(rows.allSatisfy { $0.publishes == 0 && $0.stale == 0 && $0.erased == 0 })
    }

    @Test("past the retention cap the OLDEST periods are discarded, counted, and never renumbered")
    func theRetentionCapDropsTheOldestAndSaysSo() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        // A window that keeps being re-mapped -- every resize onto a fresh surface id is a remap,
        // so a long soak can produce arbitrarily many periods, and each one is also a printed line.
        // The cap is what keeps both bounded; this drives it two periods past the edge.
        let cap = RemoteWindowRegistry.gfxMaxMappingPeriodsPerWindow
        // An odd number of steps past the cap, so the LAST mapping is surface 11 again (the
        // alternation makes every even step 11) and the still-open period is one whose frames the
        // fixture actually vends.
        let steps = cap + 3
        for step in 0..<steps {
            let surfaceId: UInt32 = step.isMultiple(of: 2) ? 11 : 12
            registry.handle(SurfaceMappedStub(
                surfaceId: surfaceId, windowId: 101, mappedWidth: 522, mappedHeight: 515))
            registry.handle(FrameReadyStub(surfaceId: 11))
        }

        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.count == cap)
        #expect(registry.gfxPeriodOverflowCount(windowId: 101) == steps - cap)
        // THE NUMBERING INVARIANT the cap must not break: `period=` counts the periods ever OPENED,
        // so the retained rows carry their original numbers. Deriving it from the retained array
        // would hand the same number to two different periods of one surface and make a record's
        // "the last period" ambiguous.
        let elevens = rows.filter { $0.surfaceId == 11 }.map(\.period)
        #expect(elevens == Array(stride(from: elevens[0], through: elevens[0] + elevens.count - 1, by: 1)))
        #expect(elevens.last == (steps + 1) / 2)
        #expect(elevens[0] > 1, "the earliest retained period is not the window's first")
        // The row the lane actually reads survives untouched: dropping the oldest is what makes
        // that possible, and it still measures only what happened after the last remap.
        let current = try #require(rows.last)
        #expect(current.isCurrent && current.surfaceId == 11)
        #expect(current.presents == 1 && current.ready == 1)
        // A window that never overflows says nothing at all -- the harness prints no line for 0.
        registry.handle(WindowCreateStub(windowId: 102))
        registry.handle(SurfaceMappedStub(surfaceId: 13, windowId: 102, mappedWidth: 10, mappedHeight: 10))
        #expect(registry.gfxPeriodOverflowCount(windowId: 102) == 0)
        #expect(registry.gfxPeriodOverflowCount(windowId: 999) == 0)
    }

    @Test("a reconnect does not erase the periods, and the next mapping closes the one before it")
    func periodsSurviveAReconnectAndTheNextMappingEndsTheOldOne() throws {
        let (registry, session) = try GfxRegistryFixture.makeRegistry()
        session.published[11] = GfxRegistryFixture.makeSurface()
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))

        // The soak's own between-cycles call: windows and mappings go, the measurement stays --
        // same contract as the counters these periods are taken from (a counter a reconnect clears
        // cannot be read after the run that produced it).
        registry.prepareForReconnect()
        #expect(registry.gfxPeriodRows(windowId: 101).map(\.period) == [1])

        // The next connection re-creates the same window and re-maps the same surface (RAIL ids are
        // reusable): that opens period 2, which ends period 1 at the frame count it had.
        registry.handle(WindowCreateStub(windowId: 101))
        registry.handle(SurfaceMappedStub(surfaceId: 11, windowId: 101, mappedWidth: 522, mappedHeight: 515))
        registry.handle(FrameReadyStub(surfaceId: 11))
        let rows = registry.gfxPeriodRows(windowId: 101)
        #expect(rows.map(\.period) == [1, 2])
        #expect(Counts(rows[0]) == { var c = Counts(); c.ready = 1; c.presents = 1; return c }())
        #expect(Counts(rows[1]) == { var c = Counts(); c.ready = 1; c.presents = 1; return c }())
        #expect(rows.filter(\.isCurrent).map(\.period) == [2])
    }
}
