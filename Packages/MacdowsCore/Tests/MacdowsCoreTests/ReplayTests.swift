import Foundation
import Testing
@testable import MacdowsCore

/// Replays the six phase05 probe captures (`samples/phase05-rail-events-2026-08-19/*.jsonl`)
/// through `RailEvent.parseJSONL` + `WindowModel`, turning "service-side behavior fixture"
/// into an actual regression gate (adr/0005 §6 / adr/0006 §4's hard-coupling point).
///
/// Every assertion here is grounded in what's *actually in the samples* — verified by
/// direct exploration before writing a single test (`jq`/a throwaway Python state-machine
/// simulation over all six files), not assumed from the protocol spec. Where that
/// exploration turned up a real, reproducible pattern (see the two documented cases in
/// `WindowModel`'s doc comment), it's encoded as an explicit expectation with a comment
/// explaining *why* it's expected, not silently absorbed.
@Suite("Replay")
struct ReplayTests {
    // MARK: - Sample loading

    /// `samples/phase05-rail-events-2026-08-19`, resolved relative to this source file so
    /// tests work from a fresh checkout without any environment setup. `$SAMPLES_DIR`
    /// overrides it (`Scripts/replay.sh` sets this to allow pointing at a different
    /// sample set, e.g. for a truncated-file negative-control run).
    static var samplesDir: URL {
        if let override = ProcessInfo.processInfo.environment["SAMPLES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // ReplayTests.swift -> MacdowsCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> MacdowsCore/
            .deletingLastPathComponent() // -> Packages/
            .deletingLastPathComponent() // -> repo root
        return repoRoot.appendingPathComponent("samples/phase05-rail-events-2026-08-19", isDirectory: true)
    }

    enum Scenario: String, CaseIterable {
        case s1 = "s1-baseline"
        case s2 = "s2-nohidef"
        case s3 = "s3-multiapp"
        case s4 = "s4-badpath"
        case s5a
        case s5b
    }

    struct Replay {
        let events: [RailEvent]
        let failures: [RailEventParseFailure]
        let model: WindowModel
        let anomalies: [Anomaly]
    }

    static func replay(_ scenario: Scenario) throws -> Replay {
        let url = samplesDir.appendingPathComponent("\(scenario.rawValue).jsonl")
        let (events, failures) = try RailEvent.parseJSONL(fileAt: url)
        var model = WindowModel()
        var anomalies: [Anomaly] = []
        for event in events {
            anomalies.append(contentsOf: model.apply(event))
        }
        return Replay(events: events, failures: failures, model: model, anomalies: anomalies)
    }

    static func count(_ events: [RailEvent], isKind predicate: (RailEventKind) -> Bool) -> Int {
        events.reduce(0) { predicate($1.kind) ? $0 + 1 : $0 }
    }

    // MARK: - Cross-scenario hard assertions

    @Test("every scenario parses with zero failures", arguments: Scenario.allCases)
    func zeroParseFailures(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.failures.isEmpty, "parse failures: \(replay.failures)")
    }

    /// Explored, not assumed: a throwaway state-machine simulation over all six files
    /// (before this model existed) found zero duplicate WindowCreates and zero Update/
    /// Delete/Icon orders on a windowId that hadn't been created — every real capture
    /// creates a window before ever touching it again. The two *very* common patterns
    /// that exploration also found (NotifyIcon on an uncreated owner window; GfxMapSurface
    /// ToWindow arriving before its target's WindowCreate) are deliberately not modeled as
    /// anomalies at all — see `WindowModel`'s doc comment. So the real, current-data
    /// expected set for `Anomaly.Kind` is empty, for all six scenarios. That's a genuine
    /// finding worth pinning down as a regression check, not an assumption: if a future
    /// FreeRDP/server version starts reordering RAIL window orders relative to each other,
    /// this is what would catch it.
    @Test("no scenario currently produces any WindowModel anomaly", arguments: Scenario.allCases)
    func zeroAnomalies(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.anomalies.isEmpty, "unexpected anomalies: \(replay.anomalies)")
    }

    // MARK: - Team lead's minimal hard assertion set

    @Test("s1: a window acquires the \"About Windows\" title, and at least one surface binding settles")
    func s1Baseline() throws {
        let replay = try Self.replay(.s1)

        // Title is empty at WindowCreate and set by a later WindowUpdate (real capture
        // behavior — Create establishes the windowId, Update fills in the title), so this
        // checks final model state, not the WindowCreate event itself.
        let aboutWindowsTitle = "关于\u{201C}Windows\u{201D}" // curly quotes verified byte-for-byte against the sample (U+201C/U+201D)
        #expect(replay.model.windows.values.contains { $0.title == aboutWindowsTitle })

        #expect(!replay.model.surfaceBindings.isEmpty)
    }

    @Test("s2 (--no-hidef): zero GfxMapSurfaceToWindow events — legacy standard path never sends them")
    func s2NoHiDef() throws {
        let replay = try Self.replay(.s2)
        let gfxMapCount = Self.count(replay.events) {
            if case .gfxMapSurfaceToWindow = $0 { return true }
            return false
        }
        #expect(gfxMapCount == 0)
    }

    @Test("s3 (multiapp): exactly two successful ServerExecuteResult, including a Registry Editor window")
    func s3MultiApp() throws {
        let replay = try Self.replay(.s3)

        let successCount = replay.model.execResults.filter { $0.execResult == 0 }.count
        #expect(successCount == 2)

        #expect(replay.model.windows.values.contains { $0.title.contains("注册表") })
    }

    @Test("s4 (bad path): a clean RAIL_EXEC_E_FILE_NOT_FOUND-shaped failure, not a crash")
    func s4BadPath() throws {
        let replay = try Self.replay(.s4)
        #expect(replay.model.execResults.contains { $0.execResult == 5 && $0.rawResult == 2 })
    }

    @Test("s5b (post-reconnect): server fully re-sends the window list (>= 20 WindowCreate)")
    func s5bReconnect() throws {
        let replay = try Self.replay(.s5b)
        let createCount = Self.count(replay.events) {
            if case .windowCreate = $0 { return true }
            return false
        }
        #expect(createCount >= 20)
    }

    // MARK: - Additional assertions grounded in real sample data (not the minimal set,
    // but real findings worth pinning down — see the W2 report for the full exploration)

    /// Settled-binding counts are exact per scenario, not a range: s1 settles 15 (it's the
    /// only scenario where surface 0 also picks up an extra binding beyond the 14 the other
    /// four GFX scenarios settle); s3/s4/s5a/s5b each settle exactly 14. (s2 has zero GFX
    /// traffic at all — see `s2HasNoPendingBindings` — so it's covered separately, not by
    /// this test's argument list.) Pinning down the exact number, not just "14 or 15", is
    /// what actually catches a regression that drops or gains one binding.
    @Test("GFX-traffic scenarios settle an exact, scenario-specific surfaceBindings count", arguments: [
        (ReplayTests.Scenario.s1, 15),
        (.s3, 14),
        (.s4, 14),
        (.s5a, 14),
        (.s5b, 14),
    ])
    func surfaceBindingsSettleConsistently(_ scenarioAndExpectedCount: (Scenario, Int)) throws {
        let (scenario, expectedCount) = scenarioAndExpectedCount
        let replay = try Self.replay(scenario)
        #expect(replay.model.surfaceBindings.count == expectedCount)
    }

    /// Structural, not incidental: in every scenario that has GFX traffic, surfaces 1 and
    /// 3 map to windowIds 65548 and 66174 respectively, and *neither ever receives a
    /// WindowCreate* in that session — confirmed by grepping for those windowIds across
    /// every event type, not just WindowCreate, in every sample. These are real GFX
    /// surfaces that RAIL never publishes as top-level windows: measured mappedWidth/Height
    /// for surface 1 is 2560x1440 in s1 specifically, but 1024x768 in s3/s4/s5a/s5b (a
    /// legacy/compositing surface whose size tracks the session's actual resolution);
    /// surface 3 is always 1x1 (a placeholder) across every scenario. `pendingBindings`
    /// staying non-empty at the end of a replay is therefore expected here, not a sign the
    /// model failed to settle something it should have.
    @Test("surfaces 1 and 3 (windowIds 65548, 66174) never settle — real, not a model bug", arguments: [
        ReplayTests.Scenario.s1, .s3, .s4, .s5a, .s5b,
    ])
    func phantomSurfacesStayPending(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.model.pendingBindings[1] == 65548)
        #expect(replay.model.pendingBindings[3] == 66174)
    }

    /// s2 has no GFX traffic at all (see `s2NoHiDef`), so nothing is ever pending either.
    @Test("s2 has no pending surface bindings (no GFX traffic to begin with)")
    func s2HasNoPendingBindings() throws {
        let replay = try Self.replay(.s2)
        #expect(replay.model.pendingBindings.isEmpty)
        #expect(replay.model.surfaceBindings.isEmpty)
    }

    /// Every scenario ends with exactly 23 known windows and an active MonitoredDesktop —
    /// the probe's ~25s session never closes an application window, so nothing here
    /// exercises `WindowDelete` (0 occurrences in all six samples, confirmed during
    /// exploration) even though `WindowModel` implements it.
    @Test("every scenario ends with 23 windows and an active monitored desktop", arguments: Scenario.allCases)
    func finalWindowCount(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.model.windows.count == 23)
        #expect(replay.model.monitoredDesktopActive)
    }
}
