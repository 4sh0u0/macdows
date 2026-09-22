import Foundation
import Testing

// adr/0019 §2 lane B. The reconnect step itself lives in ObjC++ (`CRSession.mm`), in a target that
// has no test bundle of its own: `CRBridge` is a static library the app, the two smoke tools and
// this bundle all link, and nothing offline can call into it without a live FreeRDP context. Every
// claim this file makes is therefore made by whitespace-collapsed source matching, the same
// technique `ClientRectPlumbingPinTests` / `AdvertisedScaleKnobPinTests` / `MaskUnitBoundaryPinTests`
// already use for exactly this reason.
//
// What is being protected, and why source text is the only thing that can protect it:
//
//  1. A reconnect is an ORDER, not a value. `-shutdownAndWait` walks adr/0005 §4's five steps and
//     bumps the generation counter as the last of them; `-start` builds a new context; and the
//     caller's own per-connection state has to be re-taken in the window between the two. Every
//     one of those is a side effect on C-level resources with no return value to assert on. The
//     bug this file exists to catch is a REORDERING -- a clear that moves after the bump, a
//     `prepare` that moves after the `-start`, a second generation bump -- and a reordering leaves
//     every runtime signal offline code can reach exactly where it was.
//
//  2. `Tools/window-smoke` has spelled the same three steps out by hand since W4b, and its own
//     comment (`main.swift`, `finishCycle`) records the finding this lane acts on: reversing the
//     middle two is invisible to every offline test. Lane B's answer is
//     `-restartForReconnectPreparing:`, which makes the order a property of the type. These pins
//     are what keep the type's implementation honest, since the type itself cannot.
//
//  3. The driver that sits above it (`App/SessionControl/ReconnectDriver.swift`) must NOT be
//     linked into `window-smoke`. The fixture is the only reconnect driver that exists today and
//     it drives reconnects on its own schedule; a second driver inside the same binary would race
//     it. That is a build-graph claim -- it lives in `project.yml` and nowhere else -- so the
//     third suite below reads `project.yml`.
//
// Deliberately NOT pinned here: anything about WHEN to reconnect. The back-off math is
// `MacdowsCore.ReconnectPolicy` (lane A, its own tests) and the state machine is
// `ReconnectDriverTests`; both are ordinary offline Swift and need no pin.
//
// This bundle does not run in Tier 1 (ubuntu-latest has no Xcode); it runs in Tier 2.

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// One source file with every run of whitespace collapsed to a single space, so a pin is about the
/// tokens and not about how the file happens to be wrapped or indented.
private func source(_ relative: String) throws -> String {
    let raw = try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// One source file with its lines intact -- for YAML, where indentation is the syntax.
private func rawSource(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// The text between `signature` and `next`, i.e. one method body plus the doc comment of the method
/// that follows it. Both markers are required to be present exactly once and in that order, so a
/// pin can never silently degrade into "searched the whole file" because a signature was reworded.
///
/// Trailing comment inclusion is harmless for every pin below: each one asserts either a call shape
/// that a comment does not contain, or a position relative to another call shape in the same slice.
private func slice(from signature: String, to next: String, in collapsed: String) throws -> String {
    #expect(occurrences(of: signature, in: collapsed) == 1, "marker not unique: \(signature)")
    #expect(occurrences(of: next, in: collapsed) == 1, "marker not unique: \(next)")
    let start = try #require(collapsed.range(of: signature))
    let end = try #require(collapsed.range(of: next))
    #expect(start.upperBound <= end.lowerBound, "\(signature) must come before \(next)")
    return String(collapsed[start.upperBound..<end.lowerBound])
}

/// The index of `needle` inside `haystack`, for the ordering pins. Fails the test rather than
/// returning a sentinel, so "the call vanished" can never read as "the call is in the right place".
private func index(of needle: String, in haystack: String) throws -> String.Index {
    let found = try #require(haystack.range(of: needle), "not found: \(needle)")
    return found.lowerBound
}

/// The four method markers this file slices `CRSession.mm` on, in the order they appear in it.
private enum Marker {
    static let start = "- (void)start {"
    static let shutdown = "- (BOOL)shutdownAndWait {"
    /// `NS_NOESCAPE` is part of the marker, not noise: the header declares it (it is what lets a
    /// `@MainActor` Swift caller pass an actor-isolated closure), and clang warns if the
    /// implementation drops it. Pinning the annotated form keeps the two in step.
    static let restart = "- (BOOL)restartForReconnectPreparing:(NS_NOESCAPE void (^)(void))prepare {"
    static let drain = "- (NSUInteger)drainEventsWithHandler:(void (^)(CRDPEvent *event))handler {"
    static let afterDrain = "- (uint32_t)currentGeneration {"
}

private let bridgeImplementation = "App/CRBridge/CRSession.mm"

@Suite("reconnect: the five-step teardown keeps its shape (adr/0019 §2 lane B)")
struct ReconnectTeardownShapePinTests {

    /// Pin ①. The generation counter is adr/0005 §3's whole stale-event protocol: every drained
    /// event carries the generation it was posted under, and `-drainEventsWithHandler:` discards
    /// the ones that do not match. "Exactly one bump per reconnect" is therefore not a nicety --
    /// a second bump would make the surviving in-flight events of ONE connection look like two
    /// connections' worth of staleness, and a missing bump would hand a new connection's registry
    /// the previous connection's leftovers as if they were current.
    ///
    /// The new reconnect entry point is where a second bump would most plausibly be added ("bump
    /// it here too, to be sure"), so it is named explicitly rather than covered by the file-wide
    /// count alone.
    @Test("crdpq_generation_bump appears exactly once, inside -shutdownAndWait, and never in the reconnect step")
    func generationBumpIsSingleAndBelongsToShutdown() throws {
        let mm = try source(bridgeImplementation)
        #expect(occurrences(of: "crdpq_generation_bump(", in: mm) == 1)

        let shutdownBody = try slice(from: Marker.shutdown, to: Marker.restart, in: mm)
        #expect(shutdownBody.contains("crdpq_generation_bump(_controlQueue);"))

        // Call shape, not name: the reconnect step's own doc comment names the bump (it explains
        // that `-shutdownAndWait` is where the single one lives), and a bare-name pin would go red
        // on a comment that is telling the truth. Every pin in this file matches a call.
        let restartBody = try slice(from: Marker.restart, to: Marker.drain, in: mm)
        #expect(!restartBody.contains("crdpq_generation_bump("))
    }

    /// Pin ②. The per-connection resources, by call shape and by owner. The outbound queue is
    /// created once (in `-start`) and destroyed twice (`-start`'s own `cleanup:` label for a
    /// failed connect, and step 5 of `-shutdownAndWait`) -- the asymmetry is the point, and a
    /// reconnect step that "helpfully" created or destroyed one of these itself would either leak
    /// a queue per reconnect or free a live one.
    ///
    /// The surface table and the icon store are CLEARED, never destroyed, because both objects
    /// outlive a connection while their contents do not; pinning the exact `clear(_ivar)` shapes
    /// is what keeps a later change from swapping one for a `destroy` that would leave the next
    /// connection holding a freed table.
    @Test("the per-connection resources are created and torn down in exactly one place each")
    func perConnectionResourceCallsAreWhereTheyBelong() throws {
        let mm = try source(bridgeImplementation)
        let startBody = try slice(from: Marker.start, to: Marker.shutdown, in: mm)
        let shutdownBody = try slice(from: Marker.shutdown, to: Marker.restart, in: mm)
        let restartBody = try slice(from: Marker.restart, to: Marker.drain, in: mm)

        #expect(occurrences(of: "crdpq_outbound_create(", in: mm) == 1)
        #expect(occurrences(of: "crdpq_outbound_create(", in: startBody) == 1)

        #expect(occurrences(of: "crdpq_outbound_destroy(", in: mm) == 2)
        #expect(occurrences(of: "crdpq_outbound_destroy(", in: startBody) == 1)
        #expect(occurrences(of: "crdpq_outbound_destroy(", in: shutdownBody) == 1)

        #expect(occurrences(of: "crsurface_table_clear(_surfaceSlots)", in: mm) == 1)
        #expect(occurrences(of: "crsurface_table_clear(_surfaceSlots)", in: shutdownBody) == 1)

        #expect(occurrences(of: "crdpq_icon_store_clear(_iconStore)", in: mm) == 1)
        #expect(occurrences(of: "crdpq_icon_store_clear(_iconStore)", in: shutdownBody) == 1)

        // The reconnect step composes; it does not reimplement.
        #expect(!restartBody.contains("crdpq_outbound_create("))
        #expect(!restartBody.contains("crdpq_outbound_destroy("))
        #expect(!restartBody.contains("crsurface_table_clear("))
        #expect(!restartBody.contains("crdpq_icon_store_clear("))
    }

    /// Pin ③. Clear BEFORE bump, for both tables. This is the ordering that cannot be observed
    /// from outside: after the bump, everything still queued from the old connection is stale and
    /// gets discarded by the generation gate, so a clear that ran after it would still LOOK like a
    /// clean reconnect -- the windows would be gone, the counters would count up -- while the
    /// surface buffers and tray-icon pixels of the connection being torn down stayed alive for the
    /// whole of the next one. Reversing these two lines is the mutation this pin exists for.
    @Test("both session-scoped tables are cleared before the generation is bumped")
    func tablesAreClearedBeforeTheBump() throws {
        let mm = try source(bridgeImplementation)
        let shutdownBody = try slice(from: Marker.shutdown, to: Marker.restart, in: mm)

        let bump = try index(of: "crdpq_generation_bump(", in: shutdownBody)
        let surfaceClear = try index(of: "crsurface_table_clear(_surfaceSlots)", in: shutdownBody)
        let iconClear = try index(of: "crdpq_icon_store_clear(_iconStore)", in: shutdownBody)

        #expect(surfaceClear < bump)
        #expect(iconClear < bump)
    }
}

@Suite("reconnect: -restartForReconnectPreparing: fixes the order (adr/0019 §2 lane B)")
struct ReconnectStepShapePinTests {

    /// Pin ③b. The whole reason this method exists: `prepare` runs AFTER the shutdown completed
    /// and BEFORE the next connect attempt. `Tools/window-smoke` spells the same three steps out
    /// by hand and its own comment records that reversing the middle two -- re-taking the caller's
    /// per-connection state against the OLD layout and then telling the server about the new one
    /// -- is caught by nothing offline. Inside this method the order is structural; this pin is
    /// what keeps the structure from being edited away.
    @Test("prepare runs strictly between the shutdown and the start")
    func prepareRunsBetweenShutdownAndStart() throws {
        let mm = try source(bridgeImplementation)
        let restartBody = try slice(from: Marker.restart, to: Marker.drain, in: mm)

        let shutdown = try index(of: "[self shutdownAndWait];", in: restartBody)
        let prepareCall = try index(of: "prepare();", in: restartBody)
        let start = try index(of: "[self start];", in: restartBody)

        #expect(shutdown < prepareCall)
        #expect(prepareCall < start)

        // Exactly one of each: a second `-start` (a "retry once inline") would turn one reconnect
        // into two connect attempts that the driver's attempt index never counted.
        #expect(occurrences(of: "[self start];", in: restartBody) == 1)
        #expect(occurrences(of: "[self shutdownAndWait];", in: restartBody) == 1)
        #expect(occurrences(of: "prepare();", in: restartBody) == 1)

        // No timing, no retry, no policy inside the bridge: adr/0019 §2 splits the math (lane A,
        // `MacdowsCore.ReconnectPolicy`) from the step (this method) from the driver (lane B).
        #expect(!restartBody.contains("ReconnectPolicy"))
        #expect(!restartBody.contains("usleep"))
        #expect(!restartBody.contains("dispatch_after"))
    }

    /// Pin ⑨c (addition, see this file's report entry). The attempt counter increments once per
    /// reconnect performed, at the one point that pairs it one-to-one with the generation bump
    /// that just happened -- immediately after `-shutdownAndWait` returns. Counted here rather
    /// than inside `-shutdownAndWait` on purpose: `-dealloc` and the app's terminate path shut a
    /// session down without ever reconnecting, and counting those would make the number mean
    /// "teardowns" while its name and its consumer (a back-off attempt index) mean "reconnects".
    @Test("reconnectAttemptCount increments exactly once per reconnect, right after the shutdown")
    func attemptCounterIncrementsOncePerReconnect() throws {
        let mm = try source(bridgeImplementation)
        #expect(occurrences(of: "atomic_fetch_add(&_reconnectAttemptCount", in: mm) == 1)

        let restartBody = try slice(from: Marker.restart, to: Marker.drain, in: mm)
        let shutdown = try index(of: "[self shutdownAndWait];", in: restartBody)
        let bumpCounter = try index(of: "atomic_fetch_add(&_reconnectAttemptCount", in: restartBody)
        let start = try index(of: "[self start];", in: restartBody)
        #expect(shutdown < bumpCounter)
        #expect(bumpCounter < start)

        // Initialised with the other cumulative counters, never reset anywhere else.
        #expect(occurrences(of: "atomic_init(&_reconnectAttemptCount, 0ULL);", in: mm) == 1)
        #expect(occurrences(of: "atomic_store(&_reconnectAttemptCount", in: mm) == 0)
    }

    /// Gate r1 I-3. The counter's header contract says it moves in lock-step with the generation
    /// counter, and that has to be true on EVERY path through this method, not just the one the
    /// driver takes. `-shutdownAndWait` early-returns without bumping when the session is already
    /// idle, so an unconditional increment would count a "reconnect" that tore nothing down.
    ///
    /// The claim is structural and the only way to check it offline is the source: a behaviour test
    /// would need a real `CRSession` that is idle, and calling this method on one runs a real
    /// `-start` -- a connection attempt, from a unit test bundle. The pin asserts the three pieces
    /// of the guard and their order: read the generation, shut down, compare, and only then count.
    @Test("the attempt counter is guarded by an actual generation change, not counted unconditionally")
    func attemptCounterOnlyCountsARealTeardown() throws {
        let mm = try source(bridgeImplementation)
        let restartBody = try slice(from: Marker.restart, to: Marker.drain, in: mm)

        let readBefore = try index(
            of: "uint32_t generationBeforeShutdown = [self currentGeneration];", in: restartBody)
        let shutdown = try index(of: "[self shutdownAndWait];", in: restartBody)
        let guardLine = try index(
            of: "if ([self currentGeneration] != generationBeforeShutdown)", in: restartBody)
        let bumpCounter = try index(of: "atomic_fetch_add(&_reconnectAttemptCount", in: restartBody)

        #expect(readBefore < shutdown)
        #expect(shutdown < guardLine)
        #expect(guardLine < bumpCounter)

        #expect(occurrences(of: "uint32_t generationBeforeShutdown", in: mm) == 1)
        #expect(occurrences(of: "if ([self currentGeneration] != generationBeforeShutdown)", in: mm) == 1)
    }
}

@Suite("reconnect: the sentinel memory bit and the teardown-intent bit (adr/0019 §2 lane B)")
struct ReconnectSentinelPinTests {

    /// Pin ⑨. Step 4 of `-shutdownAndWait` reports clean-vs-forced by draining until it sees the
    /// `DISCONNECTED` sentinel itself. That is correct only when the caller has not been draining
    /// too -- and on an UNEXPECTED disconnect it always has: the owner's drain consumes the
    /// sentinel first, step 4 then polls its full 100 x 50 ms budget (a five-second main-thread
    /// stall, once per reconnect) and reports `clean == NO` for a connection that ended perfectly
    /// cleanly. The fix is a per-connection memory bit that records that the sentinel ARRIVED,
    /// whoever consumed it, and seeds step 4 from it.
    ///
    /// Three sites, pinned by call shape rather than by counting the identifier (a doc comment
    /// mentioning the name would make a raw name count red for no reason). The seed pin also
    /// asserts the pre-change shape `= NO;` is gone, which is the single edit this whole pin is
    /// about.
    @Test("the disconnect sentinel is remembered per connection and seeds step 4")
    func sentinelMemoryBitHasItsThreeSites() throws {
        let mm = try source(bridgeImplementation)

        // Declared once, as a per-connection ivar.
        #expect(occurrences(of: "BOOL _disconnectSentinelSeen;", in: mm) == 1)

        // Cleared at the top of every new connection, and nowhere else. (The drain writes through
        // a pointer, so this is the only direct assignment in the file.)
        #expect(occurrences(of: "_disconnectSentinelSeen =", in: mm) == 1)
        #expect(occurrences(of: "_disconnectSentinelSeen = NO;", in: mm) == 1)
        let startBody = try slice(from: Marker.start, to: Marker.shutdown, in: mm)
        #expect(startBody.contains("_disconnectSentinelSeen = NO;"))

        // Set by the drain, once, through the visitor's context struct.
        #expect(occurrences(of: "*dctx->disconnectSentinelSeen = YES;", in: mm) == 1)
        #expect(occurrences(of: "&_disconnectSentinelSeen", in: mm) == 1)

        // Read by step 4 as its seed -- and the old unconditional `NO` seed is gone.
        let shutdownBody = try slice(from: Marker.shutdown, to: Marker.restart, in: mm)
        #expect(shutdownBody.contains("__block BOOL sawDisconnected = _disconnectSentinelSeen;"))
        #expect(occurrences(of: "__block BOOL sawDisconnected = NO;", in: mm) == 0)
        #expect(occurrences(of: "__block BOOL sawDisconnected =", in: mm) == 1)
    }

    /// Pin ⑨ (continued). WHERE the bit is set inside the drain visitor decides what it means.
    /// After the generation gate: a previous connection's leftover sentinel says nothing about
    /// this connection, and seeding step 4 from it would report a clean shutdown for a hung one.
    /// Before the handler runs: the handler is where a caller may decide to tear the session down
    /// in response to the disconnect it was just handed, and the bit has to be true by then --
    /// that re-entrant path (drain -> handler -> shutdown) is precisely the driver's own.
    @Test("the sentinel bit is set after the generation gate and before the handler runs")
    func sentinelBitIsSetInsideTheGate() throws {
        let mm = try source(bridgeImplementation)
        let drainBody = try slice(from: Marker.drain, to: Marker.afterDrain, in: mm)

        let gate = try index(of: "if (ev->generation != dctx->expectedGeneration)", in: drainBody)
        let setBit = try index(of: "*dctx->disconnectSentinelSeen = YES;", in: drainBody)
        let handler = try index(of: "dctx->handler(event);", in: drainBody)

        #expect(gate < setBit)
        #expect(setBit < handler)
        // Guarded by the event type, not set for every drained event.
        #expect(drainBody.contains("if (ev->type == CRDPQ_EVENT_DISCONNECTED) *dctx->disconnectSentinelSeen = YES;"))
    }

    /// Pin ⑨b (addition, see this file's report entry). `CRDPQ_EVENT_DISCONNECTED` carries no
    /// reason, and the same sentinel is posted for a server-side drop, a failed connect and a
    /// locally requested shutdown. `teardownInitiated` is the only thing that distinguishes them,
    /// so where it is set and cleared IS its definition: YES from the moment the teardown starts
    /// doing work, NO again at the top of the next connection. Set after the idle early-return --
    /// an idle no-op tore nothing down, and claiming otherwise would leave the flag stuck YES with
    /// no `-start` on the way to clear it, which reads as "never reconnect again".
    @Test("teardownInitiated is set when the teardown begins and cleared by the next start")
    func teardownIntentBitHasItsTwoSites() throws {
        let mm = try source(bridgeImplementation)
        #expect(occurrences(of: "_teardownInitiated =", in: mm) == 2)
        #expect(occurrences(of: "_teardownInitiated = YES;", in: mm) == 1)
        #expect(occurrences(of: "_teardownInitiated = NO;", in: mm) == 1)

        let startBody = try slice(from: Marker.start, to: Marker.shutdown, in: mm)
        #expect(startBody.contains("_teardownInitiated = NO;"))

        let shutdownBody = try slice(from: Marker.shutdown, to: Marker.restart, in: mm)
        #expect(shutdownBody.contains("_teardownInitiated = YES;"))
        // After the idle early-return, and before step 1 does anything observable.
        let idleReturn = try index(of: "if (_state == CRSessionStateIdle) return YES;", in: shutdownBody)
        let setFlag = try index(of: "_teardownInitiated = YES;", in: shutdownBody)
        let seal = try index(of: "crdpq_outbound_seal(", in: shutdownBody)
        #expect(idleReturn < setFlag)
        #expect(setFlag < seal)
    }
}

// MARK: - Pin ⑧: the build graph, and the not-wired lock

/// The `- path:` entries of one target's `sources:` list, read from the `targets:` section only
/// (`schemes:` further down repeats the same target names). Line-oriented, because YAML
/// indentation is the syntax here and the whitespace-collapsing helper above would destroy it.
private func targetSourcePaths(_ target: String, in projectYAML: String) throws -> [String] {
    let lines = projectYAML.components(separatedBy: "\n")
    let targetsStart = try #require(lines.firstIndex(of: "targets:"), "no targets: section")
    // The next column-0 key ends the section.
    let afterTargets = lines[(targetsStart + 1)...]
    let targetsEnd = afterTargets.firstIndex { line in
        guard let first = line.first else { return false }
        return !first.isWhitespace && !line.hasPrefix("#")
    } ?? lines.endIndex

    let section = lines[(targetsStart + 1)..<targetsEnd]
    let header = "  \(target):"
    let targetStart = try #require(section.firstIndex(of: header), "no target \(target) in targets:")
    let body = section[(targetStart + 1)...]
    let targetEnd = body.firstIndex { $0.hasPrefix("  ") && !$0.hasPrefix("   ") && $0.hasSuffix(":") }
        ?? section.endIndex

    var paths: [String] = []
    var inSources = false
    for line in section[(targetStart + 1)..<targetEnd] {
        if line == "    sources:" {
            inSources = true
            continue
        }
        guard inSources else { continue }
        // The sources list ends at the next key at the same indentation (`settings:`, `dependencies:`).
        if line.hasPrefix("    ") && !line.hasPrefix("     ") && line.hasSuffix(":") { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- path:") else { continue }
        paths.append(String(trimmed.dropFirst("- path:".count)).trimmingCharacters(in: .whitespaces))
    }
    return paths
}

/// Every `.swift` file under `relative`, recursively, as repo-relative paths -- a directory walk
/// rather than a hand-kept list, so a file added tomorrow is covered the day it lands.
private func swiftFiles(under relative: String) throws -> [String] {
    let root = repoRoot().appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var out: [String] = []
    for case let entry as String in walker where entry.hasSuffix(".swift") {
        let directories = entry.split(separator: "/").dropLast()
        guard !directories.contains(where: { $0.hasPrefix("build") || $0 == ".build" }) else { continue }
        out.append("\(relative)/\(entry)")
    }
    return out.sorted()
}

@Suite("reconnect: the driver is linked where it belongs and wired nowhere (adr/0019 §2 lane B)")
struct ReconnectDriverLinkagePinTests {

    /// Pin ⑧, first half: the three-sided build-graph claim.
    ///
    /// `Tools/window-smoke` is today's only reconnect driver -- it tears down and restarts a
    /// session once per soak cycle, on its own schedule, and its `clean` / `leftoverWindows` /
    /// `freezeCount` assertions are all written against exactly that sequence. A second driver
    /// inside the same binary, reacting to the very `.disconnected` the fixture caused, would race
    /// it and make those numbers mean something else. Keeping `SessionControl` out of that
    /// target's sources is what makes the type not exist in the fixture binary at all: a LINK-time
    /// guarantee, not a discipline about who calls what.
    ///
    /// The other two sides are what make the guarantee meaningful rather than vacuous -- the app
    /// compiles the driver (so it can eventually be wired, lane D) and this test bundle compiles
    /// it (so `ReconnectDriverTests` can reach it at all).
    @Test("SessionControl is a source of Macdows and MacdowsAppTests, and never of window-smoke")
    func sessionControlIsLinkedIntoExactlyTwoTargets() throws {
        let yaml = try rawSource("App/project.yml")

        let app = try targetSourcePaths("Macdows", in: yaml)
        #expect(app.contains("SessionControl"), "Macdows sources: \(app)")

        let tests = try targetSourcePaths("MacdowsAppTests", in: yaml)
        #expect(tests.contains("SessionControl"), "MacdowsAppTests sources: \(tests)")

        // Exact list, not just "does not contain": the fixture's sources are the whole claim, and
        // an equality pin also catches a `SessionControl` that arrives spelled some other way
        // (`../App/SessionControl`, a glob, an `includes:`).
        let fixture = try targetSourcePaths("window-smoke", in: yaml)
        #expect(fixture == ["../Tools/window-smoke", "RemoteWindowRendering"], "window-smoke sources: \(fixture)")
    }

    /// Pin ⑧, second half: the NOT-WIRED lock. Lane B ships the driver as "exists, nobody attaches
    /// it" -- the same shape lane A's `ReconnectPolicy` shipped in. Wiring is lane D, because the
    /// driver alone cannot repair the App's UI state: the Connect button is disabled the moment it
    /// is pressed and re-enabled only on a connect ERROR, so a session that reconnects underneath
    /// a status line nobody told about it leaves the user looking at a lie.
    ///
    /// This pin is therefore a LANE MARKER, and lane D is expected to change it in the same commit
    /// that wires the driver -- it is not a permanent prohibition, and it should not be read as
    /// one. It is here so that "not wired" is a checked fact for as long as it is claimed.
    @Test("nothing in the app entry point, the fixture or the scripts references ReconnectDriver")
    func driverIsReferencedByNoCaller() throws {
        // Gate r1 m-2: `Scripts` really is walked, not just named in the title -- the tree does
        // contain Swift there (`Scripts/lab/display_mode.swift`), and a pin whose title promises a
        // directory it never opens is the same defect as a pin that matches a name instead of a
        // call.
        let files = try swiftFiles(under: "App/Macdows")
            + swiftFiles(under: "Tools")
            + swiftFiles(under: "Scripts")
        #expect(files.contains("Scripts/lab/display_mode.swift"), "the Scripts walk found nothing")
        for file in files {
            let text = try source(file)
            #expect(occurrences(of: "ReconnectDriver", in: text) == 0, "wired in \(file)")
        }
    }
}
