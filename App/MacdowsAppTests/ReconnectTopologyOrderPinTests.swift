import Foundation
import Testing

// adr/0019 §2 lane C, the source-text half. Same technique as `ClientRectPlumbingPinTests` /
// `ReconnectSemanticsPinTests` in this directory: whitespace-collapsed matching against files this
// bundle cannot otherwise reach, or against claims that are about SHAPE rather than about a value
// any call can return.
//
// Four claims live here because nothing else can hold them:
//
//  1. `RemoteWindowRegistry.topologyProvider` had to become `var`, and the whole safety of that
//     rests on there being exactly ONE assignment outside `init`. No runtime test can see an
//     assignment that a future lane adds somewhere else in the file; a count can.
//  2. `Tools/window-smoke` has no test target of its own and is not compiled into this bundle, so
//     "the fixture really goes through the product call shape now" is only checkable as text.
//  3. The fixture's print points are the soak's judgement units (the frozen T1–T10 regexes of
//     `docs/upgrade-gate/2026-09-23-reconnect-soak-baseline-prereg.md`). This lane's whole
//     acceptance argument is that it changed a call shape and NOT an output line, and an offline
//     proxy for that claim is worth having even though it cannot replace the side-by-side rerun.
//     IT IS A PROXY: the real judgement is the same-form soak against the `fa69679` baseline.
//  4. `ReconnectTopologyRefresh`'s no-usable-display arm is unreachable on a host with a display
//     (see `ReconnectTopologyOrderTests`' boundary note), and its "one freeze" property is
//     invisible on a static layout because two reads of an unchanging layout agree. Both are
//     pinned as shape.
//
// WHAT A TEXT PIN CANNOT TELL APART, stated once so a future red is read correctly: a doc comment
// that writes an expression down looks exactly like the expression. Every count below is chosen so
// that today's comments do not match it (the assignment pin subtracts `==`; the driver pin keeps
// the `self.` prefix, which the prose deliberately omits), and the cost is that WRITING one of
// these expressions into a new comment turns the pin red. That is the intended trade: the fix is
// to phrase the comment differently, and the alternative — a looser pin — is a pin that misses the
// thing it exists for.

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func source(_ relative: String) throws -> String {
    let raw = try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Every product `.swift` file under `App/` and `Tools/`, as repo-relative paths — the whole thing
/// the "nobody calls it yet" claim is about, enumerated rather than listed by hand.
///
/// Two exclusions, both copied from `ClientRectPlumbingPinTests`' walker and for its reasons.
/// `App/MacdowsAppTests/` is out because the tests DO call the function under test and a pin file
/// would otherwise be its own first failure. Any path component starting with `build` (plus
/// `.build`) is out because those are untracked build PRODUCTS: on a machine that has built the
/// app they hold stale duplicates, and a pin that reads those is asserting against yesterday.
private func productSwiftFiles() throws -> [String] {
    var out: [String] = []
    for root in ["App", "Tools"] {
        let base = repoRoot().appendingPathComponent(root)
        guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
        for case let entry as String in walker where entry.hasSuffix(".swift") {
            guard !entry.hasPrefix("MacdowsAppTests/") else { continue }
            let directories = entry.split(separator: "/").dropLast()
            guard !directories.contains(where: { $0.hasPrefix("build") || $0 == ".build" }) else { continue }
            out.append("\(root)/\(entry)")
        }
    }
    return out.sorted()
}

@MainActor
@Suite("adr/0019 §2 lane C — the re-take order, pinned as source")
struct ReconnectTopologyOrderPinTests {

    private static let registryPath = "App/RemoteWindowRendering/RemoteWindowRegistry.swift"
    private static let refreshPath = "App/RemoteWindowRendering/ReconnectTopologyRefresh.swift"
    private static let driverPath = "App/SessionControl/ReconnectDriver.swift"
    private static let fixturePath = "Tools/window-smoke/main.swift"

    /// C-4. THE SEAM HAS EXACTLY TWO WRITES: `init`'s, and the one inside
    /// `prepareForReconnect(refreezingTopologyWith:)`. Every other assignment would replace the
    /// provider a LIVE session is doing geometry against, which adr/0015 §5.A.3 forbids outright —
    /// and which was structurally impossible while the property was `let`. This count is what
    /// replaces the compiler as the thing that says no.
    ///
    /// `topologyProvider ==` is subtracted because it contains `topologyProvider =` as a
    /// substring: the file has one such comparison (`sessionTopologyOrWarn`'s nil check), and a
    /// pin that counted it would be asserting the wrong number for the right reason.
    @Test func theTopologySeamIsAssignedInExactlyTwoPlaces() throws {
        let text = try source(Self.registryPath)
        let assignments = occurrences(of: "topologyProvider =", in: text)
            - occurrences(of: "topologyProvider ==", in: text)
        #expect(assignments == 2, "assignments to topologyProvider: \(assignments)")
        #expect(occurrences(of: "self.topologyProvider = topologyProvider", in: text) == 1,
                "init's write")
        #expect(occurrences(of: "topologyProvider = fresh", in: text) == 1,
                "the reconnect write, and it takes the closure's value")
        // `var` is the enabling change and is worth naming: if a later lane finds a way back to
        // `let`, this pin should be revisited deliberately rather than deleted quietly.
        #expect(occurrences(of: "private var topologyProvider:", in: text) == 1)
        #expect(occurrences(of: "private let topologyProvider", in: text) == 0)
    }

    /// C-4 (order half). The body of `prepareForReconnect(refreezingTopologyWith:)`, as one
    /// contiguous shape: the closure's value is installed first, and the three statements that
    /// follow are byte-for-byte the body this method has had since W4b, in its original order.
    ///
    /// MUST-RED for: moving the assignment after `closeAllWindows()`, inserting anything between
    /// the teardown steps, or dropping `refreshSessionTopology`.
    @Test func theReconnectBodyRefreezesFirstAndTearsDownAfter() throws {
        let text = try source(Self.registryPath)
        #expect(occurrences(
            of: "if let fresh = refreeze() { topologyProvider = fresh replaced = true } "
                + "else { replaced = false } ",
            in: text) == 1)
        #expect(occurrences(
            of: "closeAllWindows() currentGeneration = nil "
                + "refreshSessionTopology(reason: \"reconnect\") return replaced",
            in: text) == 1)
        // The no-arg spelling is a DELEGATION, not a second copy of the body -- which is what
        // keeps the order above the only place it exists.
        #expect(occurrences(
            of: "func prepareForReconnect() { prepareForReconnect(refreezingTopologyWith: { nil }) }",
            in: text) == 1)
        // GATE r1 m-4. `@discardableResult` is what lets the fixture and the driver call this as a
        // statement; dropping it only produces two "result unused" warnings, so nothing else in
        // the tree would go red. Small, but it is a piece of the call shape.
        #expect(occurrences(
            of: "@discardableResult func prepareForReconnect( refreezingTopologyWith refreeze: "
                + "() -> (any DisplayTopologyProviding)? ) -> Bool {",
            in: text) == 1)
    }

    /// C-5. The fixture drives the only reconnect this tree performs today, and it now does so
    /// through the product call shape. `Tools/window-smoke` is not compiled into this bundle, so
    /// this is the only offline check that it did not quietly go back to two statements.
    ///
    /// The equality between the two counts is the actual assertion: the file mentions
    /// `registry.prepareForReconnect()` twice in PROSE (both inside backticks, both describing
    /// what the teardown does), and a re-added bare call would raise the plain count without
    /// raising the quoted one.
    @Test func theFixtureCallsTheClosureTakingOverload() throws {
        let text = try source(Self.fixturePath)
        let plain = occurrences(of: "registry.prepareForReconnect()", in: text)
        let quoted = occurrences(of: "`registry.prepareForReconnect()`", in: text)
        #expect(plain == quoted, "every no-arg mention must be prose: plain \(plain), quoted \(quoted)")
        #expect(quoted == 2, "the two surviving prose mentions")
        // GATE r1 I-1. The needle runs ON into the next statement on purpose. A pin that only
        // counts occurrences pins the call SHAPE and says nothing about the call's POSITION, and
        // the reviewer's surviving mutant MU8 is exactly that hole: keep this spelling but move
        // the whole call BELOW `let leftover = ...` and every one of the 157 tests stays green,
        // while the soak's `leftoverWindows=` starts counting a table that has not been torn down
        // yet -- i.e. prereg T2's per-cycle value and V-2/V-3's judgement units change under an
        // unchanged call shape. Anchoring the two statements to each other is what closes it.
        #expect(occurrences(
            of: "registry.prepareForReconnect(refreezingTopologyWith: { "
                + "freezeAndApplyDesktopSize(to: session, reason: \"cycle \\(cycleIndex) reconnect\") "
                + "return nil }) "
                + "let leftover = registry.windowSnapshots().count",
            in: text) == 1,
            "finishCycle's one call: re-take as the argument, live provider kept, leftover read after")
    }

    /// C-6. The three print points this lane could plausibly have disturbed, pinned as their exact
    /// argument text. A PROXY for "the soak's output is byte-identical", not a replacement for the
    /// same-form rerun against baseline `fa69679` — the file header says so, and so does the
    /// prereg's own structural limit.
    ///
    /// Two of them are inside `freezeAndApplyDesktopSize`, which this lane moved INTO a closure
    /// without touching a character of its body; the third is `finishCycle`'s own `[cycles]` line,
    /// two statements below the call that changed.
    @Test func theFixturePrintPointsAreUnchanged() throws {
        let text = try source(Self.fixturePath)
        #expect(occurrences(
            of: "\"[topology] \\(reason): desktop size frozen at "
                + "\\(desktop.width)x\\(desktop.height) remote px \"",
            in: text) == 1)
        #expect(occurrences(
            of: "\"[topology] \\(reason): no usable display -- "
                + "desktopWidth/Height deliberately NOT set \"",
            in: text) == 1)
        #expect(occurrences(
            of: "print(\"[cycles] cycle \\(cycleIndex)/\\(cyclesTotal): "
                + "rendered=\\(rendered) closed=\\(closed) \"",
            in: text) == 1)
        // The freeze-count assertion the soak ends on is the fixture's own pin on `1 + N`, and
        // this lane's contract is that it still reads exactly the same. Its message text is a
        // judgement unit of the prereg.
        #expect(occurrences(
            of: "\"(1 connect + \\(expectedReconnects) prepareForReconnect(); got \\(actual)). \"",
            in: text) == 1)
    }

    /// C-7. Lane B's driver called the hook as a statement of its own and then called
    /// `prepareForReconnect()` on the next line — with a comment asking the next reader not to
    /// swap them. Lane C made that an argument. The `self.` prefix is what makes this pin able to
    /// tell the code from the prose: the surrounding comments write `topologyRefresh?()` bare, the
    /// code cannot (the enclosing block is escaping, so the compiler requires the prefix).
    ///
    /// MUST-RED for: reinstating `self.topologyRefresh?()` as its own statement, and for calling
    /// the no-arg `prepareForReconnect()` from the driver.
    @Test func theDriverPassesTheHookAsTheArgument() throws {
        let text = try source(Self.driverPath)
        #expect(occurrences(
            of: "self.registry.prepareForReconnect(refreezingTopologyWith: { "
                + "self.topologyRefresh?() ?? nil })",
            in: text) == 1)
        #expect(occurrences(of: "self.topologyRefresh?()", in: text) == 1,
                "the hook is evaluated in exactly one place, and that place is the argument above")
        #expect(occurrences(of: "registry.prepareForReconnect()", in: text) == 0,
                "the no-arg spelling would put the order back on the caller")
        #expect(occurrences(
            of: "var topologyRefresh: (() -> (any DisplayTopologyProviding)?)?", in: text) == 1,
            "the hook returns the provider; a () -> Void hook cannot be an argument")
    }

    /// C-8 (shape half). `ReconnectTopologyRefresh` freezes ONCE — which is the §5.A.4 invariant
    /// and is invisible to a runtime test on a layout that does not change between two reads — and
    /// its no-usable-display arm zeroes the advertised pair while leaving the desktop pair alone,
    /// which is unreachable from a host that has a display.
    ///
    /// MUST-RED for: a second `freezeSessionSnapshot()`, zeroing the desktop pair (§5.A.6 forbids
    /// sending `0 x 0`), dropping the advertised-pair zeroing (a reused `CRSession` would carry
    /// the previous freeze's pair into the next `-start`), and marking the result discardable —
    /// discarding it is the defect this lane removes.
    @Test func theProductRefreezeReadsOnceAndZeroesOnlyTheAdvertisedPair() throws {
        let text = try source(Self.refreshPath)
        #expect(occurrences(of: "let desktop = topology.freezeSessionSnapshot()", in: text) == 1)
        #expect(occurrences(of: "topology.freezeSessionSnapshot()", in: text) == 1,
                "one read, or the anchor and the desktop size can come from two")
        #expect(occurrences(of: "if let scale = topology.sessionSnapshot?.rasterScale,", in: text) == 1,
                "the advertised pair resolves against the snapshot that freeze took")
        #expect(occurrences(of: "session.advertisedDesktopScaleFactor = 0", in: text) == 1)
        #expect(occurrences(of: "session.advertisedDeviceScaleFactor = 0", in: text) == 1)
        #expect(occurrences(of: "session.desktopWidth = 0", in: text) == 0)
        #expect(occurrences(of: "session.desktopHeight = 0", in: text) == 0)
        #expect(occurrences(of: "return StaticDisplayTopologyProvider(topology.sessionSnapshot) } }",
                            in: text) == 1,
                "the returned seam is a static snapshot of THIS freeze, and it is the last statement")
        #expect(occurrences(of: "@discardableResult static func refreeze", in: text) == 0,
                "a discarded result is a freeze whose new layout never reached the registry")
    }

    /// C-8 (order half). GATE r1 m-3: the two expressions above are pinned as PRESENT, which says
    /// nothing about which runs first — and the reviewer's MU7 (hoisting the advertised-scale
    /// block above the freeze) is only caught at runtime by an accident of the fixture, because a
    /// brand-new provider has a `nil` `sessionSnapshot` before its first freeze. On the real
    /// reconnect path the provider is app-resident and its `sessionSnapshot` is the PREVIOUS
    /// session's, so the same mutation would silently advertise the old raster scale. One
    /// contiguous needle is what makes the order itself the checked thing.
    ///
    /// MUST-RED for: moving either assignment block above the freeze, and for inserting anything
    /// between the freeze and the desktop pair.
    @Test func theProductRefreezeFreezesBeforeItReadsTheSnapshot() throws {
        let text = try source(Self.refreshPath)
        #expect(occurrences(
            of: "let desktop = topology.freezeSessionSnapshot() "
                + "if let desktop { "
                + "session.desktopWidth = UInt32(clamping: desktop.width) "
                + "session.desktopHeight = UInt32(clamping: desktop.height) } "
                + "if let scale = topology.sessionSnapshot?.rasterScale,",
            in: text) == 1,
            "freeze, then the desktop pair, then the advertised pair -- as one contiguous shape")
    }

    /// GATE r1 m-5. `ReconnectTopologyRefresh` is in the same "exists, nobody calls it" state lane
    /// A's `ReconnectPolicy` and lane B's `ReconnectDriver` shipped in, and lane B made that a
    /// CHECKED fact rather than a `git diff` observation. Same here: the argument that "the App's
    /// connect path is bit-identical after lane C" rests on this function having no product call
    /// site at all, and a one-time diff cannot keep saying so.
    ///
    /// The needle keeps the space after `session:` deliberately: a real call reads
    /// `refreeze(session: something,` while the doc comments that name the function write the
    /// selector `refreeze(session:topology:)` with no space. Prose is therefore allowed and calls
    /// are not, which is exactly the distinction this pin needs to make.
    ///
    /// Lane D deletes this test in the same commit that wires the hook up; until then a product
    /// call site is a lane violation, not an improvement.
    @Test func theProductRefreezeHasNoProductCallSiteYet() throws {
        let needle = "ReconnectTopologyRefresh.refreeze(session: "
        var checked = 0
        for relative in try productSwiftFiles() {
            #expect(occurrences(of: needle, in: try source(relative)) == 0, "call site in \(relative)")
            checked += 1
        }
        // A directory walk that found nothing would pass vacuously; the count is the guard. The
        // floor is deliberately loose -- it exists to catch an empty enumeration, not to pin a
        // file count that every future lane would have to update.
        #expect(checked > 20, "product .swift files enumerated: \(checked)")
    }

    /// The product function is where the App's connect-path algorithm now also lives, so the two
    /// must not drift apart silently. `AppDelegate.connect()` is lane D's file and is deliberately
    /// untouched by this lane; what is pinned here is that its three assignments are still spelled
    /// the way `ReconnectTopologyRefresh` spells them, so that a future edit to either side has to
    /// look at both.
    ///
    /// Registered limit: this is a same-spelling pin, not a same-behaviour proof. Making the App's
    /// connect path CALL the product function is the registered follow-up (lane C's blueprint
    /// §2b), deferred because the connect path must stay bit-identical through this batch.
    @Test func theConnectPathStillSpellsTheSameThreeAssignments() throws {
        let appDelegate = try source("App/Macdows/AppDelegate.swift")
        let refresh = try source(Self.refreshPath)
        for assignment in [
            "desktopWidth = UInt32(clamping: desktop.width)",
            "desktopHeight = UInt32(clamping: desktop.height)",
            "advertisedDesktopScaleFactor = advertised.desktopScaleFactor",
            "advertisedDeviceScaleFactor = advertised.deviceScaleFactor",
        ] {
            #expect(occurrences(of: assignment, in: appDelegate) == 1, "connect path: \(assignment)")
            #expect(occurrences(of: assignment, in: refresh) == 1, "reconnect path: \(assignment)")
        }
        #expect(occurrences(of: "ScaleAdvertisement.productDefault(rasterScale: scale)", in: appDelegate) == 1)
        #expect(occurrences(of: "ScaleAdvertisement.productDefault(rasterScale: scale)", in: refresh) == 1)
    }
}
