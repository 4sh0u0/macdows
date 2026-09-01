import CryptoKit
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
        return defaultFrozenSamplesDir
    }

    /// The default (U7-frozen) sample directory, resolved by path regardless of any
    /// `$SAMPLES_DIR` override — the freeze-guard tests below always check *this*
    /// directory's content, even while the rest of the suite replays an overridden one.
    static var defaultFrozenSamplesDir: URL {
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

    // MARK: - Suite layering: frozen-baseline content fingerprint (W2 batch 2 Lane A)
    //
    // 2026-09-01 upgrade-gate drill finding (2026-09-drill-01, replay.log): this suite mixes
    // two kinds of assertion. The *portable invariants* (zero parse failures, zero anomalies,
    // and the protocol/scenario-contract assertions r1 review moved back — see below) must
    // hold for ANY legal recording, including a candidate re-record fed through the upgrade
    // gate's stage-② full-suite replay. The *frozen-baseline feature pins* (exact window
    // counts, exact windowId sets, exact binding counts, locale-dependent title literals)
    // pin the 2026-08-19 capture session's own constitution and by construction cannot hold
    // for any other session. The gate below splits the two layers: feature-pin tests run
    // only when the samples under replay ARE (by content, not by path) the frozen baseline,
    // and otherwise skip *visibly* via `.enabled(if:)` — never silently pass.
    //
    // r1 review correction (H1) — the gated set was re-scoped by classification, not by
    // "everything scenario-shaped": a pin belongs behind the gate ONLY if it pins the frozen
    // session's composition. Assertions that any legal recording of the same scenario must
    // satisfy (protocol facts and scenario contracts — s2's zero-GFX legacy path, s4's
    // bad-path error shape, s1's "a GFX session settles at least one binding", s3's "the
    // scenario launches exactly two apps" — each stated by the scenario definition table in
    // samples/phase05-rail-events-2026-08-19/README.md:8-14, the in-repo authority this
    // classification is read off of, not reverse-engineered from the data) are UNCONDITIONAL: they are exactly the signals
    // the upgrade gate exists to catch on a candidate, and the drill evidence
    // (.build/upgrade-gate/2026-09-drill-01-live/replay.log + laneA-candidate-run.log)
    // shows they pass on the candidate re-record today. What stays gated: the four tests
    // the drill actually turned red (exact counts/id sets), `s5bReconnect` (its >= 20
    // threshold derives from this session's 23-window composition), and the two
    // locale-dependent title literals split out of s1/s3.
    //
    // ACCEPTED RESIDUAL RISK (r1 M4, recorded deliberately): a stray `SAMPLES_DIR` left in
    // the environment (CI config, shell profile) silently degrades a default run to the
    // portable layer only. `featurePinsOnlySkipUnderExplicitOverride` below catches the
    // worse variant (pins skipping with NO override in effect — e.g. fingerprint-logic rot),
    // but it cannot distinguish a deliberate override from a forgotten one: any non-empty
    // `SAMPLES_DIR` is taken at face value as candidate mode. Accepted because the override
    // is this package's documented replay mechanism (`Scripts/replay.sh`) and a run's skip
    // lines name the reason visibly.
    //
    // Expected SHA-256 values generated from the frozen directory itself with:
    //   shasum -a 256 samples/phase05-rail-events-2026-08-19/*.jsonl
    // (run 2026-09-01 at repo root, branch == main == 2dd3019). These doubly serve as a U7
    // freeze guard: `frozenSamplesFingerprintIntact` below red-flags any byte-level change
    // to the frozen samples themselves.
    static let frozenBaselineSHA256: [Scenario: String] = [
        .s1: "3f28f61d287ef682c1659767d23216efbab7971443392834cf5b9cf0ccea9108",
        .s2: "13376500b4aedc86367b001def887f87a8ba20190f4b8ad52b41d3b1908be4a3",
        .s3: "8e87a56e9ac47ea103609baf6b952daa3cdbdf935edcd285fcf12a27d1b4a0af",
        .s4: "18cdbea083fcd66c128d6a1839fdbd560edf0b748ab901d4205cf2ac3b0e87ab",
        .s5a: "650697c5302d3aa916a5ba9c9f15d62b18b28224df7d78a0249f55fd8e5cb895",
        .s5b: "4f689ffda896d5ecb8fbb472331cc3bb0177e2a14daf5d55b06abb444547ba12",
    ]

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Content-based (not path-based) check: every one of the six scenario files in `dir`
    /// hashes to its pinned frozen-baseline SHA-256. Any unreadable or mismatching file
    /// means "not the frozen baseline". Path comparison was deliberately rejected: a
    /// `SAMPLES_DIR` pointing at a *copy* of the frozen files is still the baseline, and a
    /// tampered file at the default path is *not*.
    static func directoryMatchesFrozenBaseline(_ dir: URL) -> Bool {
        for scenario in Scenario.allCases {
            let url = dir.appendingPathComponent("\(scenario.rawValue).jsonl")
            // r1 review (LOW): `guard let`, not force-unwrap — a future `Scenario` case
            // added without a pinned hash must make this return `false` (fail-closed, the
            // pins skip visibly and the anti-rot guard below turns red), not crash the
            // whole test process.
            guard let expected = frozenBaselineSHA256[scenario],
                  let data = try? Data(contentsOf: url),
                  sha256Hex(of: data) == expected
            else { return false }
        }
        return true
    }

    /// Computed once per process against the *effective* samples directory (override
    /// included) — this is the exact value every `.enabled(if:)` feature-pin trait keys on.
    static let samplesDirIsFrozenBaseline: Bool = directoryMatchesFrozenBaseline(samplesDir)

    /// The one skip-reason string, shared by every feature-pin trait so the skip output is
    /// uniform and greppable.
    static let featurePinSkipReason: Comment =
        "frozen-baseline feature pin: samples under replay are not (by content) the 2026-08-19 frozen baseline — pinned session-composition expectations cannot apply, skipping visibly"

    // MARK: - Unconditional freeze/anti-rot guards for the layering itself

    /// U7 freeze guard, unconditional (runs regardless of `$SAMPLES_DIR`): the *default*
    /// frozen sample directory's bytes must match the pinned fingerprints. If a frozen
    /// sample is ever accidentally edited, re-recorded in place, or corrupted, this test —
    /// not a mysterious cascade of feature-pin failures/skips — is what turns red.
    @Test("U7 freeze guard: default frozen sample directory matches its pinned SHA-256 fingerprint")
    func frozenSamplesFingerprintIntact() throws {
        for scenario in Scenario.allCases {
            let url = Self.defaultFrozenSamplesDir.appendingPathComponent("\(scenario.rawValue).jsonl")
            let data = try Data(contentsOf: url)
            let actual = Self.sha256Hex(of: data)
            let pinned = try #require(Self.frozenBaselineSHA256[scenario], "no pinned hash for \(scenario.rawValue)")
            #expect(
                actual == pinned,
                "frozen sample \(scenario.rawValue).jsonl changed: sha256 \(actual), pinned \(pinned)"
            )
        }
    }

    /// Anti-rot meta-guard, unconditional: the layering *predicate itself* must classify the
    /// default frozen directory as baseline. Division of labor with the U7 guard above,
    /// stated so neither gets "deduplicated" away (r1 review, LOW): on a *sample-content*
    /// change both turn red together; this guard's UNIQUE detection case is a bug in the
    /// predicate/fingerprint logic itself (stale hash table, broken hashing, a Scenario case
    /// without a pinned hash) — the situation where U7 stays green while every feature pin
    /// would otherwise skip forever, each skip individually "visible" but collectively easy
    /// to normalize, with nothing red anywhere.
    @Test("anti-rot: layering predicate recognizes the default frozen directory as baseline")
    func layeringPredicateRecognizesFrozenBaseline() {
        #expect(Self.directoryMatchesFrozenBaseline(Self.defaultFrozenSamplesDir))
    }

    /// r1 review M4: the trait keys on the *effective* directory while the guard above keys
    /// on the *default* one, and the two legitimately diverge under a `SAMPLES_DIR` override
    /// (candidate mode). This third unconditional guard pins the only remaining illegitimate
    /// combination: feature pins skipping although NO override is in effect — which would
    /// mean the effective-directory predicate evaluation itself rotted (e.g. an env-reading
    /// bug, or the effective dir resolving somewhere unexpected). What it deliberately does
    /// NOT catch — a stray-but-set `SAMPLES_DIR` left over in the environment — is recorded
    /// as an accepted residual risk in the layering MARK above.
    @Test("anti-rot: feature pins may only skip under an explicit SAMPLES_DIR override")
    func featurePinsOnlySkipUnderExplicitOverride() {
        let override = ProcessInfo.processInfo.environment["SAMPLES_DIR"] ?? ""
        #expect(
            Self.samplesDirIsFrozenBaseline || !override.isEmpty,
            "feature pins are being skipped, but no SAMPLES_DIR override is in effect — the default run silently degraded to the portable layer"
        )
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
    //
    // r1 review H1 re-scoped this section. It is now MIXED, per-test, by classification
    // (see the layering MARK above): protocol/scenario-contract assertions run
    // unconditionally — they must hold for ANY legal recording of the same scenario, and
    // the 2026-09 drill candidate proves they do (all six were green on the candidate,
    // replay.log:811-839 shows they were never among the 20 red issues) — while
    // composition/locale pins carry the fingerprint trait. `s1Baseline`/`s3MultiApp` were
    // each split in two along exactly that line.

    /// PORTABLE (r1 H1): any legal s1 recording is a hi-def GFX session, so at least one
    /// surface binding must settle — scenario contract, not this session's composition.
    /// If a FreeRDP upgrade ever makes s1 settle zero bindings, a candidate re-record must
    /// turn this red, not skip it.
    @Test("s1: at least one surface binding settles (scenario contract — any legal s1 recording)")
    func s1SurfaceBindingSettles() throws {
        let replay = try Self.replay(.s1)
        #expect(!replay.model.surfaceBindings.isEmpty)
    }

    /// FROZEN PIN (r1 H1 split, locale half): the exact title literal depends on the
    /// remote host being zh-CN Windows and on winver's own wording — session composition,
    /// not scenario contract.
    @Test(
        "s1 (frozen pin): a window acquires the \"About Windows\" title (zh-CN locale literal)",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func s1Baseline() throws {
        let replay = try Self.replay(.s1)

        // Title is empty at WindowCreate and set by a later WindowUpdate (real capture
        // behavior — Create establishes the windowId, Update fills in the title), so this
        // checks final model state, not the WindowCreate event itself.
        let aboutWindowsTitle = "关于\u{201C}Windows\u{201D}" // curly quotes verified byte-for-byte against the sample (U+201C/U+201D)
        #expect(replay.model.windows.values.contains { $0.title == aboutWindowsTitle })
    }

    /// PORTABLE (r1 H1): `--no-hidef` forcing the legacy standard update path is a
    /// PROTOCOL fact (the test title has always said so: that path never sends
    /// `GfxMapSurfaceToWindow`), so zero GFX map events is a property of every legal s2
    /// recording. If an upstream change ever makes the legacy path emit GFX maps, the
    /// candidate replay must turn red here — gating this away was r1's "the gate's reason
    /// to exist got trimmed" example.
    @Test("s2 (--no-hidef): zero GfxMapSurfaceToWindow events — legacy standard path never sends them")
    func s2NoHiDef() throws {
        let replay = try Self.replay(.s2)
        let gfxMapCount = Self.count(replay.events) {
            if case .gfxMapSurfaceToWindow = $0 { return true }
            return false
        }
        #expect(gfxMapCount == 0)
    }

    /// PORTABLE (r1 H1): the s3 scenario definition launches exactly two applications, so
    /// exactly two successful `ServerExecuteResult`s is a scenario contract any legal s3
    /// recording satisfies. Host-state dependence, eyes open (r2 LOW-3): if a future
    /// legitimate re-record's second launch fails host-side (a policy change denying
    /// regedit, say), this reds on a legal candidate — that red means "check the host
    /// before blaming the recording", and is wanted: a candidate that cannot run the
    /// scenario is not a candidate.
    @Test("s3: exactly two successful ServerExecuteResult (scenario contract — the probe launches two apps)")
    func s3TwoSuccessfulExecs() throws {
        let replay = try Self.replay(.s3)
        let successCount = replay.model.execResults.filter { $0.execResult == 0 }.count
        #expect(successCount == 2)
    }

    /// FROZEN PIN (r1 H1 split, locale half): "注册表" is regedit's zh-CN window title —
    /// same locale dependence as the s1 title literal.
    @Test(
        "s3 (frozen pin): a Registry Editor window appears (zh-CN locale literal)",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
    func s3MultiApp() throws {
        let replay = try Self.replay(.s3)
        #expect(replay.model.windows.values.contains { $0.title.contains("注册表") })
    }

    /// PORTABLE (r1 H1): the s4 scenario definition feeds a nonexistent path, and
    /// MS-RDPERP fixes the failure shape — `RAIL_EXEC_E_FILE_NOT_FOUND` (5) with raw
    /// Win32 `ERROR_FILE_NOT_FOUND` (2). Any legal s4 recording must contain it; an
    /// upstream change that morphs the error shape must turn a candidate replay red.
    @Test("s4 (bad path): a clean RAIL_EXEC_E_FILE_NOT_FOUND-shaped failure, not a crash")
    func s4BadPath() throws {
        let replay = try Self.replay(.s4)
        #expect(replay.model.execResults.contains { $0.execResult == 5 && $0.rawResult == 2 })
    }

    /// FROZEN PIN (r1 H1 confirmed the gating): the >= 20 threshold derives from this
    /// session's own 23-window composition, so it stays behind the fingerprint gate.
    @Test(
        "s5b (post-reconnect): server fully re-sends the window list (>= 20 WindowCreate)",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason)
    )
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
    @Test(
        "GFX-traffic scenarios settle an exact, scenario-specific surfaceBindings count",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: [
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
    @Test(
        "surfaces 1 and 3 (windowIds 65548, 66174) never settle — real, not a model bug",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: [
            ReplayTests.Scenario.s1, .s3, .s4, .s5a, .s5b,
        ]
    )
    func phantomSurfacesStayPending(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.model.pendingBindings[1] == 65548)
        #expect(replay.model.pendingBindings[3] == 66174)
    }

    /// PORTABLE (r1 H1): s2 has no GFX traffic at all (see `s2NoHiDef` — a protocol fact
    /// of the legacy path, not this session's composition), so nothing can ever be pending
    /// or settled; follows for any legal s2 recording and runs unconditionally.
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
    @Test(
        "every scenario ends with 23 windows and an active monitored desktop",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func finalWindowCount(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        #expect(replay.model.windows.count == 23)
        #expect(replay.model.monitoredDesktopActive)
    }

    // MARK: - Phase 2 W0① replay fixture (docs/plans/phase2.md W0①, adr/0008 §3)
    //
    // adr/0010 W4 real-host correction (2026-08-23): `WindowMappability`'s bare-WS_POPUP
    // desktop-container exclusion now additionally requires `ownerWindowId == 0` (a live
    // popup menu is also bare WS_POPUP, but always OWNED -- see
    // `WindowMappability.styleDesktopContainerOnly`'s own doc comment for the real-host
    // evidence that forced this). Explicitly verified this fixture is UNAFFECTED, not just
    // assumed: `grep -l ownerWindowId samples/phase05-rail-events-2026-08-19/*.jsonl` across
    // all six files returns zero matches (exit 1, no file lists it) -- the key never appears
    // at all, so every window in every sample decodes `ownerWindowId == 0` via
    // `WindowOrderPayload`'s own `decodeIfPresent ?? 0` fallback (confirmed at the source,
    // not re-derived from the coverage note below, which already stated this for a different
    // reason). The `style == styleDesktopContainerOnly` branch's added `ownerWindowId == 0`
    // condition is therefore trivially satisfied for every one of the 17 windowIds it drops
    // per scenario below -- the expected set is unchanged.
    //
    // Set-equality, not count-equality, per docs/plans/phase2.md's W0 acceptance
    // criterion — a filter that drops the wrong 17 windowIds but still drops exactly 17
    // must fail this test. Every set below was derived by direct inspection: every
    // WindowCreate/Update's `style` field across all six samples was dumped and cross-
    // checked (see `WindowMappability.swift`'s own doc comment for the underlying
    // evidence) against `WindowMappability.isMappableWindow`'s actual implementation, not
    // reimplemented by hand here — this fixture calls the real function.
    //
    // The pattern is identical across every one of the six samples: exactly 17 of the 23
    // windows share the EXACT style value 0x80000000 (`WS_POPUP` alone, no other bits) —
    // the desktop-container "Program Manager" window (windowId 524454), five multi-monitor
    // "Windows 输入体验" (Text Input Experience) overlay windows, and eleven degenerate
    // 0x0/1x1/396x0/1009x4 RAIL helper windows that happen to carry the same style value.
    // Of the remaining 6, four are the W2 ghost-sliver windows (windowIds 983208, 132042,
    // 132028, 66450; 136x39, style 0x800B0000, styleEx 0x08000088 = WS_EX_NOACTIVATE |
    // WS_EX_TOOLWINDOW | WS_EX_TOPMOST, title "" — verified directly against the raw JSONL,
    // see `WindowMappability.isGhostSliverHelper`'s own doc comment) — now ALSO dropped, by
    // the W2 ghost-sliver rule rather than the style-equality check above. The final 2 are
    // real content-class windows this filter still keeps: the 536x521 About-Windows-class
    // dialog (0x80080000) and one resizable content window (0xF0000, Notepad/Registry-
    // Editor-class, ~1000-1500px).
    //
    // Coverage note: this fixture can only exercise `isMappableWindow`'s size-garbage,
    // style-equality, and ghost-sliver branches. adr/0008 §0 documents that none of the six
    // samples ever sets `WINDOW_ORDER_FIELD_OWNER` on a `WindowUpdate` (only on
    // `WindowCreate`, and `rail-probe.c` never logs `ownerWindowId`'s actual wire value at
    // all — it always decodes as 0 here per adr/0008 §5's replay-compat rule), and no
    // sample ever sets `WS_CHILD` on a top-level window order — so the `ownerWindowId`/
    // `WS_CHILD` branches (including the ghost-sliver rule's own `ownerWindowId == 0` leg)
    // are exercised only by `WindowMappabilityTests`'/`WindowModelTests`' synthetic-event
    // unit tests, not here; this fixture's ghost-sliver coverage is real for `styleEx`/
    // `title` only.
    static let expectedDroppedWindowIds: [Scenario: Set<UInt32>] = [
        .s1: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 328280, 393802, 524454, 918094, 983208],
        .s2: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 393802, 524454, 917764, 983208, 1_573_240],
        .s3: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 393802, 524454, 983208, 2_425_392, 5_898_488],
        .s4: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 393802, 524454, 983208, 1_048_700, 1_704_536],
        .s5a: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 393802, 524454, 983208, 983518, 2_950_242],
        .s5b: [65982, 65992, 65994, 65996, 65998, 66034, 66066, 66450, 66462, 66472, 131948, 131976, 132028, 132042, 132112, 197612, 393802, 524454, 983208, 1_638_650, 1_638_988],
    ]

    @Test(
        "W0①/W2 style filter drops exactly the desktop-container + IME-overlay + degenerate-helper + ghost-sliver windowId set, per scenario, not merely the right count",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func w0StyleFilterDropsExpectedWindowIdSet(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)

        // Evaluated against each window's FINAL merged state (matching how the live
        // RemoteWindowRegistry re-evaluates on every order using its own accumulated
        // PendingWindowState) — not fieldFlags from any specific order, which
        // isMappableWindow doesn't yet consume (see WindowMappability.swift).
        let droppedWindowIds = Set(replay.model.windows.compactMap { windowId, state -> UInt32? in
            let mappable = WindowMappability.isMappableWindow(
                width: state.width, height: state.height, style: state.style, styleEx: state.styleEx,
                ownerWindowId: state.ownerWindowId, fieldFlags: 0, title: state.title
            )
            return mappable ? nil : windowId
        })

        let expected = Self.expectedDroppedWindowIds[scenario]!
        #expect(
            droppedWindowIds == expected,
            "dropped windowId set mismatch for \(scenario): got \(droppedWindowIds.sorted()), want \(expected.sorted())"
        )
    }
}
