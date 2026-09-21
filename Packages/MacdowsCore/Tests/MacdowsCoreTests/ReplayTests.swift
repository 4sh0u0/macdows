import CryptoKit
import Foundation
import Testing
@testable import MacdowsCore

/// Replays the six phase05 probe captures (`samples/phase05-rail-events-2026-09-21-2x/*.jsonl`)
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

    /// `samples/phase05-rail-events-2026-09-21-2x`, resolved relative to this source file so
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
        return repoRoot.appendingPathComponent("samples/phase05-rail-events-2026-09-21-2x", isDirectory: true)
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
    // samples/phase05-rail-events-2026-09-21-2x/README.md:9-15, the in-repo authority this
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
    //   shasum -a 256 samples/phase05-rail-events-2026-09-21-2x/*.jsonl
    // (run 2026-09-21 at repo root, branch feat/w3-u7-2x-rebaseline off main == a366832).
    // These doubly serve as a U7 freeze guard: `frozenSamplesFingerprintIntact` below
    // red-flags any byte-level change to the frozen samples themselves.
    static let frozenBaselineSHA256: [Scenario: String] = [
        .s1: "45c4a94db7b0d736b28dfe484a5c8ac19c36f1d9fa6f62395579b45e77d94c69",
        .s2: "192eac1220c905b08c01930ef3ea01c0e6afbb69434a1b76942f2d1d49a35a62",
        .s3: "86f853ed69ed353f2bbdfa07709003df892797933af093c981c03533622c7ba7",
        .s4: "4856cde200d6570f7f184ce5bf27872633ccc5319030388673aa4d53e1292c24",
        .s5a: "c2bf288df5e2d7d400ba9688c2282e2b458ccee7a5c4dfd79e036c078528c7b5",
        .s5b: "40625e004e90c6d476d8721843d09a8677a15da0978eb94983f7ba4dd59804fa",
    ]

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Content-based (not path-based) check: every one of the six scenario files in `dir`
    /// hashes to its entry in `pins`. Any unreadable or mismatching file means "not that
    /// baseline". Path comparison was deliberately rejected: a `SAMPLES_DIR` pointing at a
    /// *copy* of the frozen files is still the baseline, and a tampered file at the default
    /// path is *not*.
    static func directoryMatches(_ dir: URL, _ pins: [Scenario: String]) -> Bool {
        for scenario in Scenario.allCases {
            let url = dir.appendingPathComponent("\(scenario.rawValue).jsonl")
            // r1 review (LOW): `guard let`, not force-unwrap — a future `Scenario` case
            // added without a pinned hash must make this return `false` (fail-closed, the
            // pins skip visibly and the anti-rot guard below turns red), not crash the
            // whole test process.
            guard let expected = pins[scenario],
                  let data = try? Data(contentsOf: url),
                  sha256Hex(of: data) == expected
            else { return false }
        }
        return true
    }

    /// The in-force frozen baseline (the 2026-09-21 2x capture) by content.
    static func directoryMatchesFrozenBaseline(_ dir: URL) -> Bool {
        directoryMatches(dir, frozenBaselineSHA256)
    }

    // MARK: - The retired 1x baseline, kept replayable (U-7 rebaseline, 2026-09-21)
    //
    // The 2026-08-19 1x capture stays in the tree — keeping it is the controller ruling for
    // this lane (adr/0018 §1 U-7 itself only rules "new directory, six file names
    // unchanged") — and stays REPLAYABLE here, for exactly the pins whose *statement shape*
    // — not merely whose numbers — the 2x session changed. adr/0018 §4 risk 3 forbids
    // silently widening such a pin ("rewrite, do not widen"); the rule applied below is
    // instead: the original pin
    // keeps asserting its original literal against the directory it was measured on, and a
    // new same-semantics pin is written for the directory now in force. Two pins qualified
    // (`legacy1xFinalWindowCount`, `legacy1xPhantomSurfacesStayPending`); every other
    // feature pin below simply carries a recomputed 2x value, because its statement shape
    // survived the re-record.

    /// The retired 1x sample directory, resolved by path (never via `$SAMPLES_DIR` — these
    /// pins are about that one historical capture, not about whatever is under replay).
    static var legacy1xSamplesDir: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // ReplayTests.swift -> MacdowsCoreTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> MacdowsCore/
            .deletingLastPathComponent() // -> Packages/
            .deletingLastPathComponent() // -> repo root
        return repoRoot.appendingPathComponent("samples/phase05-rail-events-2026-08-19", isDirectory: true)
    }

    /// The 1x directory's own fingerprints — the values this file pinned as
    /// `frozenBaselineSHA256` from 2026-09-01 until the 2x rebaseline, carried over
    /// verbatim so the legacy pins below are gated by content exactly as they were.
    static let legacy1xBaselineSHA256: [Scenario: String] = [
        .s1: "3f28f61d287ef682c1659767d23216efbab7971443392834cf5b9cf0ccea9108",
        .s2: "13376500b4aedc86367b001def887f87a8ba20190f4b8ad52b41d3b1908be4a3",
        .s3: "8e87a56e9ac47ea103609baf6b952daa3cdbdf935edcd285fcf12a27d1b4a0af",
        .s4: "18cdbea083fcd66c128d6a1839fdbd560edf0b748ab901d4205cf2ac3b0e87ab",
        .s5a: "650697c5302d3aa916a5ba9c9f15d62b18b28224df7d78a0249f55fd8e5cb895",
        .s5b: "4f689ffda896d5ecb8fbb472331cc3bb0177e2a14daf5d55b06abb444547ba12",
    ]

    /// Computed once per process: is the retired 1x directory still present and byte-intact?
    static let legacy1xBaselineIntact: Bool = directoryMatches(legacy1xSamplesDir, legacy1xBaselineSHA256)

    static let legacy1xPinSkipReason: Comment =
        "retired 1x baseline pin: samples/phase05-rail-events-2026-08-19 is absent or no longer byte-identical to its pinned fingerprints — the 1x session composition cannot be asserted, skipping visibly"

    /// Computed once per process against the *effective* samples directory (override
    /// included) — this is the exact value every `.enabled(if:)` feature-pin trait keys on.
    static let samplesDirIsFrozenBaseline: Bool = directoryMatchesFrozenBaseline(samplesDir)

    /// The one skip-reason string, shared by every feature-pin trait so the skip output is
    /// uniform and greppable.
    static let featurePinSkipReason: Comment =
        "frozen-baseline feature pin: samples under replay are not (by content) the 2026-09-21 2x frozen baseline — pinned session-composition expectations cannot apply, skipping visibly"

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

    /// U-7 rebaseline anti-rot (gate r1 I2), unconditional and RED — not a skip gate: the
    /// retired 1x directory's bytes must match `legacy1xBaselineSHA256`, per file. Without
    /// this, `legacy1xBaselineIntact` had no symmetric guard at all: editing or deleting a
    /// retired sample simply made the three retired pins skip (visibly, with a reason) while
    /// the whole run stayed green — exactly the "every skip individually visible, none of
    /// them red" state the three-guard MARK above exists to refuse. The in-force baseline
    /// has three guards; the retired one, which is the likelier thing to be tidied away, had
    /// none. Deleting the retired directory on purpose is therefore a decision that has to
    /// be made here, by deleting this test and the pins it protects, not a silent side
    /// effect.
    @Test("U-7 retired-baseline guard: the 1x sample directory matches its pinned SHA-256 fingerprints")
    func legacy1xSamplesFingerprintIntact() throws {
        for scenario in Scenario.allCases {
            let url = Self.legacy1xSamplesDir.appendingPathComponent("\(scenario.rawValue).jsonl")
            let data = try Data(contentsOf: url)
            let actual = Self.sha256Hex(of: data)
            let pinned = try #require(Self.legacy1xBaselineSHA256[scenario], "no pinned 1x hash for \(scenario.rawValue)")
            #expect(
                actual == pinned,
                "retired 1x sample \(scenario.rawValue).jsonl changed: sha256 \(actual), pinned \(pinned)"
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
        try replay(scenario, in: samplesDir)
    }

    /// Replays one scenario out of an explicitly named directory — used by the retired-1x
    /// pins, which must not follow `$SAMPLES_DIR`.
    static func replay(_ scenario: Scenario, in directory: URL) throws -> Replay {
        let url = directory.appendingPathComponent("\(scenario.rawValue).jsonl")
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
    ///
    /// U-7 2x rebaseline (2026-09-21): re-verified, not carried over. The literal below is
    /// byte-identical in the 2x capture (the host locale did not change), so the pin keeps
    /// its 1x value; what did change is the window carrying it — windowId 327790, 1072x928
    /// remote px, style 0x80080000 (the 1x session's About dialog was 536x521).
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
    ///
    /// U-7 2x rebaseline (2026-09-21): re-verified against the 2x capture — the full title
    /// string there is still regedit's zh-CN one and still contains this substring; the
    /// window is windowId 394088, 966x688 remote px, style 0x000F0000.
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

    /// FROZEN PIN (r1 H1 confirmed the gating): the >= 20 threshold derives from the frozen
    /// session's own window composition, so it stays behind the fingerprint gate.
    ///
    /// U-7 2x rebaseline (2026-09-21): the derivation was re-measured, the literal was not
    /// widened. The 2x s5b capture carries 21 `WindowCreate` orders for 21 distinct windows
    /// (the 1x session's figure was 23), so `>= 20` still sits one below a full re-send and
    /// still reds if the server ever answers a reconnect with a partial list. Deliberately
    /// NOT re-tightened to `>= 21`: the pin's statement is "fully re-sends", and one
    /// transient helper window more or less between two captures is exactly the noise the
    /// original threshold was chosen to absorb.
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

    /// Settled-binding counts are exact per scenario, not a range: s1 settles 13,
    /// s3/s4/s5a/s5b each settle exactly 14. (s2 has zero GFX traffic at all — see
    /// `s2HasNoPendingBindings` — so it's covered separately, not by this test's argument
    /// list.) Pinning down the exact number, not just "13 or 14", is what actually catches
    /// a regression that drops or gains one binding.
    ///
    /// U-7 2x rebaseline (2026-09-21), re-derived from the capture rather than carried
    /// over — the statement shape ("exact, scenario-specific count") survived, the numbers
    /// and their derivation did not. s1 is the first connection of the batch: it carries 14
    /// `GfxMapSurfaceToWindow` orders on surfaceIds 1…14 and exactly one of them (surface 3
    /// -> windowId 65548) targets a window RAIL never creates, so 13 settle. The other four
    /// GFX scenarios reuse an already-running RemoteApp session: 16 map orders on surfaceIds
    /// 0…15, of which two target never-created windows (see `phantomSurfacesStayPending`),
    /// so 14 settle. The 1x baseline's figures were 15/14 for a different reason (surface 0
    /// present in s1); the inversion is session composition, not a model change.
    @Test(
        "GFX-traffic scenarios settle an exact, scenario-specific surfaceBindings count",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: [
        (ReplayTests.Scenario.s1, 13),
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

    /// Structural, not incidental: in every scenario that has GFX traffic, at least one
    /// surface is mapped to a windowId that *never receives a WindowCreate* in that
    /// session — confirmed by scanning for those windowIds across every event type, not
    /// just WindowCreate, in every sample. These are real GFX surfaces that RAIL never
    /// publishes as top-level windows, so `pendingBindings` staying non-empty at the end of
    /// a replay is expected here, not a sign the model failed to settle something it
    /// should have.
    ///
    /// U-7 2x rebaseline (2026-09-21): this pin's STATEMENT SHAPE changed, so per
    /// adr/0018 §4 risk 3 ("rewrite, do not widen") it was not silently widened — the
    /// original
    /// "surfaces 1 and 3, always, in every GFX scenario" form is preserved verbatim
    /// against the directory it was measured on by `legacy1xPhantomSurfacesStayPending`
    /// below, and this pin states what the 2x capture actually shows:
    ///
    ///   * s1 (the batch's first connection, surfaceIds 1…14): surface 3 -> windowId 65548
    ///     (2560x1440 mapped) stays pending; surface 1 is mapped to 131462, the desktop
    ///     container, which IS created here, so it settles.
    ///   * s3/s4/s5a/s5b (later connections into the same already-running RemoteApp
    ///     session, surfaceIds 0…15): surface 1 -> 65548 (2560x1440 mapped) and surface 3
    ///     -> 131262 (1x1 mapped, the "RemoteApp Marker Window" whose WindowCreate only
    ///     appeared in s1) both stay pending.
    ///
    /// windowId 65548 is the one phantom common to both baselines (the 1x capture saw it on
    /// surface 1); 66174, the 1x capture's second phantom, does not appear in the 2x
    /// session at all. Exact dictionary equality, not per-key lookups: a regression that
    /// leaves an EXTRA surface pending must red here too.
    static let expectedPendingBindings: [Scenario: [UInt32: UInt64]] = [
        .s1: [3: 65548],
        .s3: [1: 65548, 3: 131262],
        .s4: [1: 65548, 3: 131262],
        .s5a: [1: 65548, 3: 131262],
        .s5b: [1: 65548, 3: 131262],
    ]

    @Test(
        "GFX scenarios end with exactly the phantom surface -> windowId map that never got a WindowCreate — real, not a model bug",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: [
            ReplayTests.Scenario.s1, .s3, .s4, .s5a, .s5b,
        ]
    )
    func phantomSurfacesStayPending(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        let expected = try #require(Self.expectedPendingBindings[scenario])
        #expect(
            replay.model.pendingBindings == expected,
            "pendingBindings mismatch for \(scenario): got \(replay.model.pendingBindings.sorted { $0.key < $1.key }), want \(expected.sorted { $0.key < $1.key })"
        )
    }

    /// RETIRED 1x PIN, preserved verbatim (U-7 rebaseline): the 2026-08-19 capture's own
    /// phantom structure — surfaces 1 and 3 mapped to windowIds 65548 and 66174, neither
    /// ever created, in every one of its five GFX scenarios. Measured mappedWidth/Height
    /// for surface 1 was 2560x1440 in s1 and 1024x768 in s3/s4/s5a/s5b; surface 3 was
    /// always 1x1. Reads the 1x directory by path (never `$SAMPLES_DIR`) and is gated on
    /// that directory still being byte-intact, so deleting the retired samples makes this
    /// skip visibly instead of failing.
    @Test(
        "retired 1x baseline: surfaces 1 and 3 (windowIds 65548, 66174) never settle",
        .enabled(if: ReplayTests.legacy1xBaselineIntact, ReplayTests.legacy1xPinSkipReason),
        arguments: [
            ReplayTests.Scenario.s1, .s3, .s4, .s5a, .s5b,
        ]
    )
    func legacy1xPhantomSurfacesStayPending(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario, in: Self.legacy1xSamplesDir)
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

    /// Every scenario ends with an exact, scenario-specific number of known windows and an
    /// active MonitoredDesktop — the probe's 15-30s session never closes an application
    /// window, so nothing here exercises `WindowDelete` (0 occurrences in all six samples,
    /// re-confirmed on the 2x capture with `grep -c '"ev":"WindowDelete"'`) even though
    /// `WindowModel` implements it.
    ///
    /// U-7 2x rebaseline (2026-09-21): this pin's STATEMENT SHAPE changed — the 1x capture
    /// ended every one of its six scenarios on the SAME count (23), and that single shared
    /// literal is what the test asserted. The 2x session does not: s2 ends on 20 and the
    /// other five on 21 (s2 is the `--no-hidef` leg, whose legacy path never publishes the
    /// GFX-only marker window). Per adr/0018 §4 risk 3 ("rewrite, do not widen") the
    /// shared-literal form was NOT silently widened to a range: it is preserved against the directory it
    /// was measured on by `legacy1xFinalWindowCount` below, and the same semantics — an
    /// exact final composition count, not a range — is restated here per scenario.
    static let expectedFinalWindowCount: [Scenario: Int] = [
        .s1: 21, .s2: 20, .s3: 21, .s4: 21, .s5a: 21, .s5b: 21,
    ]

    @Test(
        "every scenario ends with its exact window count and an active monitored desktop",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func finalWindowCount(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario)
        let expected = try #require(Self.expectedFinalWindowCount[scenario])
        #expect(
            replay.model.windows.count == expected,
            "final window count mismatch for \(scenario): got \(replay.model.windows.count), want \(expected)"
        )
        #expect(replay.model.monitoredDesktopActive)
    }

    /// RETIRED 1x PIN, preserved verbatim (U-7 rebaseline): the 2026-08-19 capture's own
    /// uniform composition — all six scenarios ended on exactly 23 windows with an active
    /// monitored desktop. Reads the 1x directory by path and is gated on it still being
    /// byte-intact.
    @Test(
        "retired 1x baseline: every scenario ends with 23 windows and an active monitored desktop",
        .enabled(if: ReplayTests.legacy1xBaselineIntact, ReplayTests.legacy1xPinSkipReason),
        arguments: Scenario.allCases
    )
    func legacy1xFinalWindowCount(_ scenario: Scenario) throws {
        let replay = try Self.replay(scenario, in: Self.legacy1xSamplesDir)
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
    // assumed: `grep -l ownerWindowId samples/phase05-rail-events-2026-09-21-2x/*.jsonl`
    // across all six files returns zero matches (exit 1, no file lists it; re-run on the 2x
    // capture, not carried over) -- the key never appears at all, so every window in every
    // sample decodes `ownerWindowId == 0` via `WindowOrderPayload`'s own
    // `decodeIfPresent ?? 0` fallback. The `style == styleDesktopContainerOnly` branch's
    // added `ownerWindowId == 0` condition is therefore trivially satisfied for every
    // windowId it drops per scenario below.
    //
    // Set-equality, not count-equality, per docs/plans/phase2.md's W0 acceptance
    // criterion — a filter that drops the wrong windowIds but still drops exactly the right
    // number must fail this test. The sets below were derived from the samples themselves
    // (every window's final merged state dumped and classified against the real
    // `WindowMappability.isMappableWindow`, which this fixture then calls — not a hand
    // reimplementation).
    //
    // U-7 2x rebaseline (2026-09-21): every windowId changed, as expected for a different
    // capture session, and the composition behind them was re-measured rather than
    // restated. The statement shape is unchanged — each scenario still drops an exact set
    // made up of the same four classes — so this pin carries new values, not a new form.
    // What the 2x session actually contains, per scenario (drop reason = the first branch
    // of `isMappableWindow` that fires):
    //
    //   * degenerate size (width <= 1 or height <= 1): 9 windows in s1, 8 in each of the
    //     other five. The seven common ones are the 0x0 RAIL helpers 65972/65982/65984/
    //     65986/65988/66028 and the 0x0 "Rdptray" window 66068; each scenario adds one or
    //     two more 0x0 helpers of its own (s1 also has 66018 and 131262, the GFX-only
    //     "RemoteApp Marker Window").
    //   * bare WS_POPUP, unowned (style == 0x80000000 exactly): 7 in every scenario — the
    //     four 1280x720 "Windows 输入体验" (Text Input Experience) multi-monitor overlays
    //     66462/66476/66484/66504, the 2560x1440 desktop-container "Program Manager"
    //     window 131462, the 2560x1440 overlay 263022, and one per-scenario 2530x4 edge
    //     strip (66022 / 131634 / 131744 / 1769954 / 721084 / 66672).
    //   * ghost slivers (W2 rule: styleEx == 0x08000088 = WS_EX_NOACTIVATE |
    //     WS_EX_TOOLWINDOW | WS_EX_TOPMOST, empty title, unowned): the same four windowIds
    //     66466/66522/132080/197582 in every scenario, all 262x71 with style 0x800B0000.
    //     (The 1x baseline's four ghosts were 136x39; the size grew with the 2x session,
    //     the signature the rule keys on did not.)
    //   * WS_CHILD / size-garbage: still zero occurrences, in every scenario.
    //
    // The 16 (s1) / 15 (the rest) windows carrying the EXACT style value 0x80000000 are
    // therefore split between the degenerate-size branch and the style branch by size
    // alone; the four 0x800B0000 ghosts and the kept content windows are the remainder.
    // What survives the filter: the 1072x928 About-Windows-class dialog 327790 (style
    // 0x80080000) in all six scenarios, plus the 966x688 Registry-Editor window 394088
    // (style 0x000F0000) in s3/s4/s5a/s5b — the s3 launch stayed open on the host for the
    // rest of the batch, which is why the later scenarios keep two windows and s1/s2 keep
    // one.
    //
    // Coverage note: this fixture can only exercise `isMappableWindow`'s size-garbage,
    // style-equality, and ghost-sliver branches. No sample ever sets
    // `WINDOW_ORDER_FIELD_OWNER` on a `WindowUpdate`, `rail-probe.c` never logs
    // `ownerWindowId`'s wire value at all (adr/0008 §5's replay-compat rule: it always
    // decodes as 0 here), and no sample ever sets `WS_CHILD` on a top-level window order —
    // so the `ownerWindowId`/`WS_CHILD` branches (including the ghost-sliver rule's own
    // `ownerWindowId == 0` leg) are exercised only by `WindowMappabilityTests`'/
    // `WindowModelTests`' synthetic-event unit tests, not here; this fixture's ghost-sliver
    // coverage is real for `styleEx`/`title` only.
    static let expectedDroppedWindowIds: [Scenario: Set<UInt32>] = [
        .s1: [65972, 65982, 65984, 65986, 65988, 66018, 66022, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 131262, 131462, 132080, 197582, 263022],
        .s2: [65972, 65982, 65984, 65986, 65988, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 131462, 131634, 132080, 197084, 197582, 263022],
        .s3: [65972, 65982, 65984, 65986, 65988, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 131462, 131744, 132080, 197582, 263022, 393690],
        .s4: [65972, 65982, 65984, 65986, 65988, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 131462, 132080, 197582, 197680, 263022, 1_769_954],
        .s5a: [65972, 65982, 65984, 65986, 65988, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 131462, 132080, 197582, 263022, 721_084, 2_425_664],
        .s5b: [65972, 65982, 65984, 65986, 65988, 66028, 66068, 66462, 66466, 66476, 66484, 66504, 66522, 66668, 66672, 131462, 132080, 197582, 263022],
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
