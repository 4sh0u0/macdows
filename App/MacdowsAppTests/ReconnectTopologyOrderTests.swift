import AppKit
import MacdowsCore
import Testing

// adr/0019 §2 lane C (owner ruling R-3 = K), the behaviour half. The source-text half —
// "the fixture really goes through the product call shape", "the seam has exactly one assignment"
// — is `ReconnectTopologyOrderPinTests` in this directory.
//
// WHAT THE LANE CHANGED, stated as the thing these tests have to discriminate. The reconnect
// re-take used to be TWO statements in a required order: re-derive the display topology, then
// `registry.prepareForReconnect()`. Both `Tools/window-smoke`'s `finishCycle` and lane B's
// `ReconnectDriver.performReconnect` carried a comment saying that reversing them freezes the
// registry against the old layout while the server is told about the new one — the divergence
// adr/0015 §5.A.4 forbids — and BOTH comments also recorded that no offline test could catch it,
// because `sessionTopologyFreezeCount` counts up either way. That is the gap this file closes:
// the re-take is now an ARGUMENT to `prepareForReconnect(refreezingTopologyWith:)`, and the
// fixtures below observe the registry FROM INSIDE that argument, where "has the teardown happened
// yet" is a question with an answer.
//
// THE OBSERVATION TECHNIQUE, and why it is not the freeze count. `RecordingProvider` counts reads
// of `currentTopology`. The registry's re-take performs exactly one such read, so which provider
// it read is a recorded fact rather than an inference: a re-take that ran against the OLD seam
// leaves the new provider on zero reads while the freeze count still rises. `windowSnapshots()`
// read from inside the closure answers the ordering question directly — the table is non-empty
// before `closeAllWindows()` and empty after, and nothing else in the method touches it.
//
// COVERAGE BOUNDARIES, registered rather than worked around:
//
//  * `ReconnectTopologyRefresh.refreeze` takes the App's real `DisplayTopologyProvider`, which is
//    `final` and reads `NSScreen` privately. So the no-usable-display arm (desktop pair left
//    alone, advertised pair zeroed) is unreachable from a test host that has a display, and its
//    twin arm is unreachable from one that does not. Each run checks the arm its host can reach
//    and the OTHER arm is held by a source pin in `ReconnectTopologyOrderPinTests`. Making it
//    reachable needs an injection seam in the provider, which the D7 boundary forbids
//    (phase3.md:82/:171/:257).
//  * "The App really picks up a NEW screen layout across a reconnect" needs a physical display
//    change mid-session and stays a live-host claim. What is offline here is the half that was
//    missing: the new snapshot is handed over, and it is handed over before the teardown.
//  * GATE r1 m-3: the ORDER INSIDE `refreeze` -- freeze first, then read `sessionSnapshot` -- is
//    not discriminated by anything in this file. A test host's layout does not change between two
//    freezes, so both produce the same snapshot and hoisting the advertised-scale block above the
//    freeze is invisible here (it reds only by the accident that a brand-new provider's
//    `sessionSnapshot` is nil before its first freeze, which is NOT the shape of the real
//    reconnect path). That claim is held as one contiguous source needle in
//    `ReconnectTopologyOrderPinTests.theProductRefreezeFreezesBeforeItReadsTheSnapshot`.

/// A `DisplayTopologyProviding` that counts reads, so "which seam did the re-take read" is an
/// observed fact. Labelled because every assertion below is about telling two of them apart.
@MainActor
private final class RecordingProvider: DisplayTopologyProviding {
    let label: String
    private let topology: DisplayTopology?
    private(set) var reads = 0

    init(label: String, topology: DisplayTopology?) {
        self.label = label
        self.topology = topology
    }

    var currentTopology: DisplayTopology? {
        reads += 1
        return topology
    }
}

/// A `WindowCreate` order with fields this file chooses. `CRDPEvent` exposes every field
/// `readonly` and vends no initializer that takes them (`App/CRBridge/CRSession.h`), so a
/// subclass overriding the getters is the only way to build one — the same test-local construct
/// `RemoteWindowRegistryLeftBorderTests` uses, and for the same reason.
private final class WindowCreateStub: CRDPEvent {
    /// `WINDOW_ORDER_FIELD_*`, duplicated narrowly from the file-private `WindowOrderField` in
    /// `RemoteWindowRegistry.swift` — "duplicate the bits, not the policy".
    static let fieldTitle: UInt32 = 0x0000_0004
    static let fieldStyle: UInt32 = 0x0000_0008
    static let fieldShow: UInt32 = 0x0000_0010
    static let fieldSize: UInt32 = 0x0000_0400
    static let fieldOffset: UInt32 = 0x0000_0800
    /// `WINDOW_SHOW` (freerdp/window.h) — any nonzero value means shown.
    static let showNormal: UInt32 = 5

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
    /// `WS_MAXIMIZEBOX | WS_MINIMIZEBOX | WS_THICKFRAME | WS_SYSMENU`, Notepad's own style —
    /// nothing in this file depends on the value, it just has to be a mappable window.
    override var style: UInt32 { 0x000F_0000 }
    override var styleEx: UInt32 { 0 }
    override var ownerWindowId: UInt32 { 0 }
    override var title: String { "reconnect-topology-probe" }
    override var offsetX: Int32 { 300 }
    override var offsetY: Int32 { 200 }
    override var windowWidth: UInt32 { 522 }
    override var windowHeight: UInt32 { 514 }
    override var show: UInt32 { Self.showNormal }
}

/// A fixture layout, not this machine's: one 1920x1080 1x primary, injected through the
/// registry's existing provider parameter so nothing here reads `NSScreen`.
@MainActor
private func fixtureTopology(width: Double = 1920, height: Double = 1080) throws -> DisplayTopology {
    let display = DisplayTopology.Display(
        origin: MacPoint(x: 0, y: 0), size: MacSize(width: width, height: height),
        scale: DisplayScale(remotePixelsPerPoint: 1, backingPixelsPerPoint: 1), isPrimary: true
    )
    return try #require(DisplayTopology(displays: [display]))
}

/// An UNSTARTED `CRSession` (`-initWithHost:...` only allocates this session's queues and sets
/// `CRSessionStateIdle`; connecting is `-start`, which nothing here calls) with a registry over
/// `provider`. NOTHING IN THIS FILE CONTACTS ANY HOST, and the strings are empty.
@MainActor
private func makeRegistry(provider: any DisplayTopologyProviding) -> (CRSession, RemoteWindowRegistry) {
    let session = CRSession(host: "", user: "", password: "", program: "")
    let registry = RemoteWindowRegistry(session: session, topologyProvider: provider)
    return (session, registry)
}

@MainActor
@Suite("prepareForReconnect(refreezingTopologyWith:) — the re-take is the argument (adr/0019 §2 lane C)")
struct ReconnectTopologyOrderTests {

    /// C-1. THE LANE'S WHOLE CLAIM. Everything the caller owes §5.A.4 runs while the registry is
    /// still intact: the window table is populated, the generation is still the old one's, and the
    /// freeze count has not moved. Then, and only then, the teardown.
    ///
    /// MUST-RED for: swapping ① and ② in `prepareForReconnect(refreezingTopologyWith:)` (the
    /// closure would see an empty table), moving the closure call below `refreshSessionTopology`
    /// (the freeze count seen inside would be 2, and the re-take would have read the OLD seam),
    /// and dropping the assignment (`fresh` never installed → zero reads on the new provider).
    @Test func refreezeRunsBeforeTeardown() throws {
        let old = RecordingProvider(label: "old", topology: try fixtureTopology())
        let fresh = RecordingProvider(label: "fresh", topology: try fixtureTopology(width: 2560, height: 1440))
        let (_, registry) = makeRegistry(provider: old)
        registry.handle(WindowCreateStub(windowId: 101))
        try #require(registry.windowSnapshots().count == 1, "the probe window must exist before the teardown")
        try #require(old.reads == 1, "init's freeze is the only read so far")

        var windowsSeenByTheClosure: Int?
        var freezeCountSeenByTheClosure: Int?
        let replaced = registry.prepareForReconnect(refreezingTopologyWith: {
            windowsSeenByTheClosure = registry.windowSnapshots().count
            freezeCountSeenByTheClosure = registry.sessionTopologyFreezeCount
            return fresh
        })

        // The ordering claim, from inside the argument.
        #expect(windowsSeenByTheClosure == 1, "the re-take must run BEFORE closeAllWindows()")
        #expect(freezeCountSeenByTheClosure == 1, "the re-take must run BEFORE refreshSessionTopology()")
        // The installation claim: the re-take that followed read the NEW seam, exactly once, and
        // never went back to the old one.
        #expect(replaced, "a closure that returned a provider must report the seam as replaced")
        #expect(fresh.reads == 1, "the post-teardown re-take must read the provider the closure returned")
        #expect(old.reads == 1, "the old seam must not be read again after it was replaced")
        // And the teardown itself still happened, in full.
        #expect(registry.windowSnapshots().isEmpty)
        #expect(registry.sessionTopologyFreezeCount == 2)
    }

    /// C-2. `sessionTopologyFreezeCount == 1 + N` is the assertion `Tools/window-smoke` makes at
    /// the end of every soak (`main.swift`'s `topologyFreezeCountCheck`, untouched by this lane),
    /// and the whole point of adding an overload is that it does not move.
    ///
    /// MUST-RED for: a no-arg overload that re-implements the body instead of delegating (two
    /// re-takes per call), or a closure overload that re-takes twice to "make sure".
    @Test func freezeCountIsOnePlusNOnBothSpellings() throws {
        let provider = RecordingProvider(label: "live", topology: try fixtureTopology())
        let (_, registry) = makeRegistry(provider: provider)
        #expect(registry.sessionTopologyFreezeCount == 1, "init is the 1 in 1 + N")

        for expected in 2...6 {
            registry.prepareForReconnect(refreezingTopologyWith: { nil })
            #expect(registry.sessionTopologyFreezeCount == expected)
        }
        for expected in 7...9 {
            registry.prepareForReconnect()
            #expect(registry.sessionTopologyFreezeCount == expected)
        }
        // Eight calls, eight reads, plus init's: the count and the reads cannot disagree.
        #expect(provider.reads == 9)
    }

    /// C-3. The no-arg spelling is adr/0019 R-3's N branch — "keep the provider you have" — and it
    /// has to stay literally that. It is the spelling every existing caller uses.
    ///
    /// MUST-RED for: a no-arg overload that quietly swaps in a provider of its own (the recorded
    /// seam would stop being read), and for one that skips the re-take (reads stay at 1).
    @Test func noArgOverloadKeepsTheSameSeamAndStillRefreezes() throws {
        let provider = RecordingProvider(label: "installed-at-init", topology: try fixtureTopology())
        let (_, registry) = makeRegistry(provider: provider)

        registry.prepareForReconnect()

        #expect(provider.reads == 2, "the seam installed at init is still the one being read")
        #expect(registry.sessionTopologyFreezeCount == 2)
    }

    /// The same N branch through the closure spelling: returning `nil` must mean "keep what you
    /// have", not "install nothing and skip the re-take".
    @Test func closureReturningNilKeepsTheSameSeam() throws {
        let provider = RecordingProvider(label: "installed-at-init", topology: try fixtureTopology())
        let (_, registry) = makeRegistry(provider: provider)

        let replaced = registry.prepareForReconnect(refreezingTopologyWith: { nil })

        #expect(!replaced)
        #expect(provider.reads == 2)
        #expect(registry.sessionTopologyFreezeCount == 2)
    }
}

@MainActor
@Suite("ReconnectTopologyRefresh — one read fixes three things (adr/0019 §2 lane C)")
struct ReconnectTopologyRefreshTests {

    /// C-8. The product re-take assigns the desktop pair, the advertised pair and the provider it
    /// returns from ONE freeze. This runs against the App's real `DisplayTopologyProvider`, so the
    /// numbers are this host's — which is why every expectation is stated as a RELATION between
    /// what was assigned and what the provider froze, never as a literal.
    ///
    /// `NotificationCenter()` rather than `.default`: the provider registers a screen-parameter
    /// observer it never removes (it is app-resident by contract), and a test-local centre keeps
    /// this one out of the process-wide one.
    ///
    /// MUST-RED for: deriving the desktop size from a SECOND freeze (the relation to
    /// `sessionSnapshot` breaks the moment the two reads differ, and the one-freeze source pin
    /// catches it on a static layout), resolving the advertised scale against `currentTopology`
    /// instead of the frozen snapshot, and returning the live provider instead of a static
    /// snapshot of it.
    @Test func refreezeAssignsDesktopAndScaleFromOneRead() throws {
        let session = CRSession(host: "", user: "", password: "", program: "")
        // Values no layout can produce, so "left alone" and "assigned" are distinguishable.
        session.desktopWidth = 111
        session.desktopHeight = 222
        session.advertisedDesktopScaleFactor = 999
        session.advertisedDeviceScaleFactor = 888
        let provider = DisplayTopologyProvider(notificationCenter: NotificationCenter())

        let returned = try #require(
            ReconnectTopologyRefresh.refreeze(session: session, topology: provider),
            "the product re-take always hands a provider over -- see its own doc comment on why nil would be wrong"
        )

        // The returned seam is a STATIC snapshot of the freeze, never the live reader itself.
        #expect(!(returned is DisplayTopologyProvider),
                "handing the live provider over would put §5.A.4 back on statement ordering")
        #expect(returned.currentTopology == provider.sessionSnapshot,
                "the seam handed over must be the snapshot this freeze took")

        if let snapshot = provider.sessionSnapshot {
            // This host has a usable display: the desktop pair is what THAT snapshot derives.
            let derived = snapshot.desktopSizeInRemotePixels
            #expect(session.desktopWidth == UInt32(derived.width))
            #expect(session.desktopHeight == UInt32(derived.height))
            // And the advertised pair resolves from the SAME snapshot's raster scale.
            if let advertised = ScaleAdvertisement.productDefault(rasterScale: snapshot.rasterScale) {
                #expect(session.advertisedDesktopScaleFactor == advertised.desktopScaleFactor)
                #expect(session.advertisedDeviceScaleFactor == advertised.deviceScaleFactor)
            } else {
                #expect(session.advertisedDesktopScaleFactor == 0)
                #expect(session.advertisedDeviceScaleFactor == 0)
            }
        } else {
            // Headless host: adr/0015 §5.A.6 — nothing is sent, so the desktop pair keeps the
            // (now stale) value it had, and the advertised pair is zeroed because a reused
            // CRSession would otherwise carry the previous freeze's pair into the next -start.
            #expect(session.desktopWidth == 111)
            #expect(session.desktopHeight == 222)
            #expect(session.advertisedDesktopScaleFactor == 0)
            #expect(session.advertisedDeviceScaleFactor == 0)
            #expect(returned.currentTopology == nil)
        }
    }

    /// GATE r1 m-3. The re-take must do its work on EVERY call, not only on a provider that has
    /// never frozen before — a reconnect always meets an app-resident provider whose
    /// `sessionSnapshot` is the previous session's. The sentinel values assigned between the two
    /// calls are what make "the second call re-assigned from the second freeze" visible.
    ///
    /// MUST-RED for: a `refreeze` that assigns only when nothing was frozen yet, and for one that
    /// returns the FIRST snapshot on a later call.
    ///
    /// REGISTERED LIMIT, and it is the reason the ordering claim lives in
    /// `ReconnectTopologyOrderPinTests.theProductRefreezeFreezesBeforeItReadsTheSnapshot` instead
    /// of here: this host's layout does not change between the two calls, so both freezes produce
    /// the same snapshot and no runtime assertion here can tell "resolved against freeze 2" from
    /// "resolved against freeze 1". Only a physical display change mid-run could, which is a
    /// live-host claim.
    @Test func everyRefreezeReassignsFromItsOwnFreeze() throws {
        let session = CRSession(host: "", user: "", password: "", program: "")
        let provider = DisplayTopologyProvider(notificationCenter: NotificationCenter())

        _ = ReconnectTopologyRefresh.refreeze(session: session, topology: provider)
        let afterFirst = provider.sessionSnapshot
        // Values no layout can produce, so a second call that assigned nothing is visible.
        session.desktopWidth = 111
        session.desktopHeight = 222
        session.advertisedDesktopScaleFactor = 777
        session.advertisedDeviceScaleFactor = 666

        let second = try #require(ReconnectTopologyRefresh.refreeze(session: session, topology: provider))

        #expect(second.currentTopology == provider.sessionSnapshot,
                "the second call hands over the snapshot ITS freeze took")
        #expect(provider.sessionSnapshot == afterFirst,
                "this host's layout did not change between the calls -- see the registered limit")
        if let snapshot = provider.sessionSnapshot {
            let derived = snapshot.desktopSizeInRemotePixels
            #expect(session.desktopWidth == UInt32(derived.width), "the sentinel must have been overwritten")
            #expect(session.desktopHeight == UInt32(derived.height))
            if let advertised = ScaleAdvertisement.productDefault(rasterScale: snapshot.rasterScale) {
                #expect(session.advertisedDesktopScaleFactor == advertised.desktopScaleFactor)
                #expect(session.advertisedDeviceScaleFactor == advertised.deviceScaleFactor)
            } else {
                #expect(session.advertisedDesktopScaleFactor == 0)
                #expect(session.advertisedDeviceScaleFactor == 0)
            }
        } else {
            #expect(session.desktopWidth == 111, "adr/0015 §5.A.6: nothing is sent, so nothing is assigned")
            #expect(session.advertisedDesktopScaleFactor == 0, "the advertised pair is zeroed on every call")
            #expect(session.advertisedDeviceScaleFactor == 0)
        }
    }

    /// The composition this lane exists to make possible: the product re-take, used as the
    /// argument, leaves the registry reading the snapshot it just froze — and the registry's own
    /// freeze count still moves by exactly one.
    ///
    /// MUST-RED for: a `refreeze` that freezes but returns something other than the new snapshot,
    /// and for a `prepareForReconnect` that ignores what the closure returned.
    @Test func refreezeComposesWithThePrepareOverload() throws {
        let initial = RecordingProvider(label: "connect-time", topology: try fixtureTopology())
        let (session, registry) = makeRegistry(provider: initial)
        let provider = DisplayTopologyProvider(notificationCenter: NotificationCenter())

        let replaced = registry.prepareForReconnect(refreezingTopologyWith: {
            ReconnectTopologyRefresh.refreeze(session: session, topology: provider)
        })

        #expect(replaced)
        #expect(initial.reads == 1, "the connect-time seam must not be read after it was replaced")
        #expect(registry.sessionTopologyFreezeCount == 2)
    }
}
