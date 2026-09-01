import Foundation
import Testing
@testable import ReplayDiffKit

/// Everything `Scripts/upgrade-gate.sh` relies on that is not one of the five acceptance
/// rows: directory pairing, unreadable input, unparsable lines, and report determinism.
/// Kept in its own suite so the five acceptance suites stay one-row-each and readable.
@Suite("L5-plumbing gate-driver behaviour")
struct GateDriverPlumbingTests {
    // MARK: - Directory mode

    /// The gate's default invocation, in-process: the whole frozen samples directory
    /// against itself, which is what `Scripts/upgrade-gate.sh` runs with no arguments.
    @Test("the phase05 directory against itself is clean, over all six captures")
    func phase05DirectoryAgainstItselfIsClean() throws {
        let directory = PhaseSamples.directory.path
        try #require(FileManager.default.fileExists(atPath: directory), "samples directory missing: \(directory)")

        let set = try CaptureSet.compare(
            baselinePath: directory,
            candidatePath: directory,
            differ: SemanticDiffer()
        )
        #expect(set.reports.count == PhaseSamples.names.count)
        #expect(set.unpairedBaselines.isEmpty)
        #expect(set.unpairedCandidates.isEmpty)
        #expect(set.totalDifferences == 0, "unexpected: \(set.reports.flatMap(\.differences))")
        #expect(!set.hasRegressions)
    }

    /// A capture present on one side only must fail the gate. Reporting "no differences"
    /// for a scenario that was never compared is the single worst thing a gate can do.
    @Test("a capture present on one side only fails the run")
    func unpairedCaptureFailsTheRun() throws {
        let root = try TemporaryDirectory()
        let baselineDir = try root.makeSubdirectory("baseline")
        let candidateDir = try root.makeSubdirectory("candidate")
        let contents = CaptureFixture.baseline.joined(separator: "\n") + "\n"
        try contents.write(to: baselineDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try contents.write(to: baselineDir.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        try contents.write(to: candidateDir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let set = try CaptureSet.compare(
            baselinePath: baselineDir.path,
            candidatePath: candidateDir.path,
            differ: SemanticDiffer()
        )
        #expect(set.reports.count == 1)
        #expect(set.unpairedBaselines == ["s2.jsonl"])
        #expect(set.totalDifferences == 0)
        // No *difference* was found, yet the run must still fail.
        #expect(set.hasRegressions)
        #expect(set.textReport().contains("UNPAIRED (baseline side only): s2.jsonl"))
    }

    @Test("mixing a file and a directory is an input error, not a diff")
    func fileAgainstDirectoryIsAnInputError() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent("s1.jsonl")
        try (CaptureFixture.baseline.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: CaptureSetError.mismatchedKinds) {
            _ = try CaptureSet.compare(
                baselinePath: file.path,
                candidatePath: root.url.path,
                differ: SemanticDiffer()
            )
        }
    }

    @Test("a missing input is an input error naming the path")
    func missingInputIsAnInputError() {
        #expect(throws: CaptureSetError.self) {
            _ = try CaptureSet.compare(
                baselinePath: "/nonexistent/baseline.jsonl",
                candidatePath: "/nonexistent/candidate.jsonl",
                differ: SemanticDiffer()
            )
        }
    }

    // MARK: - Unparsable lines

    /// A line the parser cannot read is a finding, never silence. And the finding must not
    /// echo the line: a malformed line from a live re-record can contain anything, and this
    /// text goes into an evidence artifact.
    @Test("a malformed line is reported as unparsableLine without echoing it")
    func malformedLineIsReportedWithoutEchoingIt() throws {
        var mutated = CaptureFixture.baseline
        mutated.append(#"{"t_ms":2100,"tid":"0x1f6be3540","ev":"WindowIcon","windowId":"NOT-A-NUMBER-SENTINEL"}"#)

        let candidate = CaptureFixture.stream(mutated, label: "malformed")
        #expect(candidate.parseFailures.count == 1)

        let report = SemanticDiffer().diff(baseline: CaptureFixture.baselineStream(), candidate: candidate)
        let unparsable = report.differences.filter { $0.diffClass == .unparsableLine }
        #expect(unparsable.count == 1)
        #expect(unparsable.first?.candidateLine == mutated.count)
        #expect(report.hasRegressions)

        let rendered = DiffReportSet(reports: [report]).textReport()
        #expect(!rendered.contains("NOT-A-NUMBER-SENTINEL"))
    }

    /// An `ev` name MacdowsCore does not model yet is *not* a difference when both sides
    /// have it — a newer probe adding an event must not fail the gate (`RailEvent`'s
    /// `.unknown` case exists for exactly this) — but the operator is told.
    @Test("an unmodelled event name is a note on both sides, not a difference")
    func unmodelledEventNameIsANote() {
        let withFuture = CaptureFixture.baseline + [
            #"{"t_ms":2100,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","someField":7}"#
        ]
        let stream = CaptureFixture.stream(withFuture, label: "future")
        #expect(stream.unmodelledEventNames == ["SomeFutureProbeEvent"])
        #expect(stream.parseFailures.isEmpty)

        let report = SemanticDiffer().diff(
            baseline: stream,
            candidate: CaptureFixture.stream(withFuture, label: "future-2")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
        #expect(report.notes.contains { $0.contains("SomeFutureProbeEvent") })
    }

    /// ...and its fields are still compared, because the whole point of the structural
    /// re-read is that an unmodelled event is not an unreadable one.
    @Test("an unmodelled event's fields are still compared")
    func unmodelledEventFieldsAreStillCompared() throws {
        let lhs = CaptureFixture.baseline + [
            #"{"t_ms":2100,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","someField":7}"#
        ]
        let rhs = CaptureFixture.baseline + [
            #"{"t_ms":2100,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","someField":9}"#
        ]

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(lhs, label: "future-7"),
            candidate: CaptureFixture.stream(rhs, label: "future-9")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .fieldValueChanged)
        #expect(difference.field == "someField")
    }

    // MARK: - Report determinism

    /// Two runs over the same inputs must produce byte-identical output, or a drill record
    /// cannot be diffed against the previous drill. `Dictionary` iteration order is the
    /// obvious way to lose this.
    @Test("text and JSON reports are byte-stable across runs")
    func reportsAreDeterministic() throws {
        var mutated = CaptureFixture.changingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "windowWidth", to: 900
        )
        mutated = CaptureFixture.inserting(
            mutated,
            [CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200)],
            atIndex: CaptureFixture.Line.monitoredDesktop.rawValue
        )

        func run() throws -> (String, String) {
            let set = DiffReportSet(reports: [
                SemanticDiffer().diff(
                    baseline: CaptureFixture.baselineStream(),
                    candidate: CaptureFixture.stream(mutated, label: "mutated")
                )
            ])
            return (set.textReport(), try set.jsonReport())
        }

        let first = try run()
        let second = try run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
        #expect(first.0.contains("fieldValueChanged=1"))
        #expect(first.0.contains("knownLocalDifference=1"))
    }

    @Test("the JSON report round-trips")
    func jsonReportRoundTrips() throws {
        let mutated = CaptureFixture.changingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "windowWidth", to: 900
        )
        let set = DiffReportSet(reports: [
            SemanticDiffer().diff(
                baseline: CaptureFixture.baselineStream(),
                candidate: CaptureFixture.stream(mutated, label: "mutated")
            )
        ])
        let json = try set.jsonReport()
        let decoded = try JSONDecoder().decode(DiffReportSet.self, from: Data(json.utf8))
        #expect(decoded == set)
    }

    /// Every class in the vocabulary needs a legend line: the report is an artifact read
    /// months later by someone without the runbook open.
    @Test("every difference class has a non-empty summary")
    func everyClassHasASummary() {
        for klass in DiffClass.allCases {
            #expect(!klass.summary.isEmpty, "\(klass.rawValue) has no summary")
        }
        #expect(DiffClass.allCases.filter { $0.defaultSeverity == .expected } == [.knownLocalDifference])
    }

    // MARK: - Round-1 finding I-3: the ordinal-shift cascade note

    /// One extra *un-anchored* window early in the stream still shifts every later
    /// ordinal handle and turns one real difference into a multi-finding report. Since
    /// W2 batch 2's title-anchored identity the population this can happen to is the
    /// un-anchored one (untitled windows; same-title-group members; surface/notifyIcon
    /// always) — only a UNIQUELY-titled extra window raises no note
    /// (`TitleAnchoredIdentityTests.titledExperimentCollapses` pins that side, and its
    /// `sameTitleGroupChangeRaisesNote` pins the group side). The note must still name
    /// the namespace and the remedy for the residual.
    @Test("an extra un-anchored window handle raises a cascade note naming the namespace and the remedy")
    func cascadeNoteAppearsWhenHandleCountsDiffer() throws {
        let extraWindow = #"{"t_ms":5,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":90001,"fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":320,"windowHeight":240,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":""}"#
        let mutated = CaptureFixture.inserting(CaptureFixture.baseline, [extraWindow], atIndex: 0)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "extra-head-window")
        )
        let cascade = try #require(report.notes.first { $0.hasPrefix("CASCADE RISK") })
        #expect(cascade.contains("`window`"))
        #expect(cascade.contains("1 distinct"))
        #expect(cascade.contains("baseline's 0"))
        // The operator's actual first-line remedy has to be in the note, not only in the
        // README they do not have open.
        #expect(cascade.contains("FIRST eventCountChanged"))
        #expect(cascade.contains("--no-canonical-ids is NOT the remedy"))
        #expect(report.hasRegressions)
    }

    // Round-2 finding N-4's exact-pin duty (the documented cascade-experiment number must
    // be reproduced by a test against the real capture the prose names) moved with the
    // experiment itself: since W2 batch 2's title-anchored identity the TITLED variant
    // collapses to one finding and the documented number is the UNTITLED residual (49) —
    // both halves are pinned in `TitleAnchoredIdentityTests`.

    /// Negative control: the note is evidence-driven, not decoration. Equal handle counts
    /// produce no note at all, so its presence in an artifact means something.
    @Test("no cascade note when the handle counts match")
    func noCascadeNoteWhenHandleCountsMatch() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }

    /// ...and it is specific to canonicalization: with raw ids there are no ordinals to
    /// cascade, so claiming a cascade risk would be a false warning.
    @Test("no cascade note when canonicalization is off")
    func noCascadeNoteWithoutCanonicalization() {
        var options = DifferOptions()
        options.canonicalizeIdentifiers = false
        let extraWindow = #"{"t_ms":5,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":90001,"fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":320,"windowHeight":240,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Extra Head Window"}"#
        let mutated = CaptureFixture.inserting(CaptureFixture.baseline, [extraWindow], atIndex: 0)

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "extra-head-window")
        )
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }

    // MARK: - Round-1 minor findings

    /// M-1: a duplicated `eventName` used to reach `Dictionary(uniqueKeysWithValues:)` and
    /// kill the process with a stdlib assertion (exit 133). A drill operator's typo must
    /// produce a message, not a crash.
    @Test("a known-difference table naming the same event twice is refused, not trapped")
    func duplicateKnownDifferenceEntryIsRefused() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent("table.json")
        try """
            [{"eventName":"GfxMapSurfaceToScaledWindow","expectedSide":"candidate","cause":"a","reference":"r"},
             {"eventName":"GfxMapSurfaceToScaledWindow","expectedSide":"baseline","cause":"b","reference":"r"}]
            """.write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: KnownDifferenceTable.LoadError.duplicateEventName("GfxMapSurfaceToScaledWindow")) {
            _ = try KnownDifferenceTable.load(fromJSONAt: file)
        }
    }

    /// The in-memory initializer must also never trap — it is on the same path — but it
    /// resolves rather than refuses, matching `merging(_:)`'s documented last-wins rule.
    @Test("the in-memory table initializer resolves duplicates instead of trapping")
    func inMemoryTableResolvesDuplicates() {
        let table = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(eventName: "X", expectedSide: .baseline, cause: "first", reference: "r"),
            KnownDifferenceEntry(eventName: "X", expectedSide: .candidate, cause: "second", reference: "r"),
        ])
        #expect(table.entries.count == 1)
        #expect(table.entries["X"]?.cause == "second")
    }

    /// A well-formed table with `supersedes` absent must load — the field is optional and
    /// means "pure addition", so existing tables cannot be invalidated by the I-1 fix.
    @Test("a table without supersedes loads and means pure addition")
    func tableWithoutSupersedesLoads() throws {
        let root = try TemporaryDirectory()
        let file = root.url.appendingPathComponent("table.json")
        try #"[{"eventName":"X","expectedSide":"candidate","cause":"c","reference":"r"}]"#
            .write(to: file, atomically: true, encoding: .utf8)

        let table = try KnownDifferenceTable.load(fromJSONAt: file)
        #expect(table.entries["X"]?.supersedes == nil)
    }

    /// M-2: the join promises that a line MacdowsCore accepted becomes either a record or an
    /// explicit failure — never a silent drop. Asserted as the conservation law it is,
    /// against the real captures: records + failures == non-blank lines, exactly.
    @Test("no line is silently dropped by the parse join", arguments: PhaseSamples.names)
    func parseJoinConservesEveryLine(name: String) throws {
        let url = try #require(PhaseSamples.url(named: name), "sample not found: \(name)")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let nonBlank = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        let stream = ReplayStream.parse(contents: contents, label: name)
        #expect(stream.records.count + stream.parseFailures.count == nonBlank)
        #expect(nonBlank > 100)
    }

    /// M-3: an operator-supplied table must leave a trace in the artifact even when none of
    /// its entries fire — otherwise a run with a one-off excuse is indistinguishable from a
    /// run without one.
    @Test("the active known-difference table is recorded in the notes even when it does not fire")
    func knownDifferenceTableIsRecordedInNotes() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(report.differences.isEmpty)
        let note = report.notes.first { $0.hasPrefix("known-difference table") }
        #expect(note?.contains("GfxMapSurfaceToScaledWindow expected on candidate") == true)
        #expect(note?.contains("supersedes GfxMapSurfaceToWindow") == true)
    }

    @Test("an empty known-difference table says so rather than saying nothing")
    func emptyKnownDifferenceTableIsRecorded() {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable()
        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(report.notes.contains { $0.contains("known-difference table: empty") })
    }

    /// Round-2 finding **N-7**: `DifferOptions` is public, and the order check used to
    /// `guard options.orderTolerance >= 0` and return nothing — so a library caller setting
    /// `-1` to mean "strictest" silently got *no* order checking at all, lane check
    /// included. Negative now clamps to zero, the strictest a tolerance can be.
    @Test("a negative tolerance means strictest, not disabled")
    func negativeToleranceClampsToZero() {
        let swapped = CaptureFixture.swapping(
            CaptureFixture.baseline, .gfxMapSurfaceToWindow, .monitoredDesktop
        )
        var options = DifferOptions()
        options.orderTolerance = -1
        options.laneOrderTolerance = -1

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(swapped, label: "swapped")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .eventOrderChanged })

        // Same result as an explicit 0 — that is what "clamps" means.
        var zeroed = DifferOptions()
        zeroed.orderTolerance = 0
        zeroed.laneOrderTolerance = 0
        let atZero = SemanticDiffer(options: zeroed).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(swapped, label: "swapped")
        )
        #expect(atZero.differences == report.differences)
    }

    /// M-4: `integerCanonicalForm` is the canonicalizer's only type filter. Its doc says
    /// "integral number"; it used to accept any number, so a fractional field would have
    /// been handed a handle ordinal.
    @Test("integerCanonicalForm accepts only integral numbers")
    func integerCanonicalFormRejectsNonIntegers() {
        #expect(JSONValue.number(.signed(-7)).integerCanonicalForm == "-7")
        #expect(JSONValue.number(.unsigned(18_446_744_073_709_551_615)).integerCanonicalForm == "18446744073709551615")
        #expect(JSONValue.number(.floating(42)).integerCanonicalForm == "42")
        #expect(JSONValue.number(.floating(1.5)).integerCanonicalForm == nil)
        #expect(JSONValue.number(.floating(.nan)).integerCanonicalForm == nil)
        #expect(JSONValue.number(.floating(.infinity)).integerCanonicalForm == nil)
        #expect(JSONValue.string("65832").integerCanonicalForm == nil)
        #expect(JSONValue.bool(true).integerCanonicalForm == nil)
        #expect(JSONValue.null.integerCanonicalForm == nil)
    }

    /// ...and the consequence for the canonicalizer: a fractional identifier keeps its own
    /// value rather than being renamed to an ordinal it has no claim to.
    ///
    /// Had it been canonicalized, both sides' first (and only) `surfaceId` would have become
    /// `surface#0`, the two events would have matched, and a real difference would have
    /// vanished. Because it is left alone, the raw fractions land in the identity tuple —
    /// so the difference surfaces as ``DiffClass/eventCountChanged`` (identifier fields are
    /// the matching key, the same behaviour `surfaceReattributionIsReported` pins) with the
    /// unaltered values visible in the detail.
    @Test("a fractional identifier is not canonicalized into a handle ordinal")
    func fractionalIdentifierIsNotCanonicalized() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(
                [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","surfaceId":1.5}"#],
                label: "frac-a"
            ),
            candidate: CaptureFixture.stream(
                [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","surfaceId":2.5}"#],
                label: "frac-b"
            )
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .eventCountChanged })
        #expect(report.differences.contains { $0.detail == "identity surfaceId=1.5" })
        #expect(report.differences.contains { $0.detail == "identity surfaceId=2.5" })
        #expect(!report.differences.contains { $0.detail.contains("surface#") })
    }

    /// The positive counterpart: an *integral* identifier on the same unmodelled event IS
    /// canonicalized, so the two sides match and the raw values never reach the report.
    @Test("an integral identifier on the same event IS canonicalized")
    func integralIdentifierIsCanonicalized() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(
                [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","surfaceId":7}"#],
                label: "int-a"
            ),
            candidate: CaptureFixture.stream(
                [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"SomeFutureProbeEvent","surfaceId":9}"#],
                label: "int-b"
            )
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    // MARK: - Pre-authored known-difference table files (tables/)

    /// The repo ships pre-authored per-drill table files under `Tools/replay-diff/tables/`
    /// (first: the host_freshness-conditioned `WindowCachedIcon` exemption — the
    /// conditionality lives in table *selection*, not schema; see tables/README.md).
    /// This pin keeps loader schema evolution from silently invalidating a shipped file,
    /// and pins the entry's load-bearing shape: a **pure one-sided** exemption
    /// (`WindowIcon` is never one-sided in the corpus, so `supersedes` pairing is
    /// structurally inapplicable), whose cause states the injection precondition in-band.
    /// Review cachedicon-r1: the file holds exactly one entry (I1 — an appended rider
    /// would otherwise load green), and the cause keeps its two ruled guard sentences
    /// (the census-only boundary, and the B2 counter-evidence statement that stops the
    /// WindowIcon count shift from being re-narrated as cache evidence).
    @Test("the shipped window-cached-icon table file loads and keeps its ruled shape")
    func shippedCachedIconTableLoads() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> ReplayDiffKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> replay-diff/
            .appendingPathComponent("tables/window-cached-icon-candidate-cold.json")
        let table = try KnownDifferenceTable.load(fromJSONAt: file)
        #expect(table.entries.count == 1) // nothing rides along in this file
        let entry = try #require(table.entries["WindowCachedIcon"])
        #expect(entry.expectedSide == .baseline) // C-3's verified direction
        #expect(entry.supersedes == nil) // pure addition -- never pair cached vs full icons
        #expect(entry.newFields.isEmpty)
        // The precondition must travel inside the artifact-visible cause text, so a drill
        // report that quotes the entry also quotes when it may be used at all — and the
        // precondition presses the CANDIDATE half only (review cachedicon-r1 B1: the
        // baseline half has no independent record and must not be demanded).
        #expect(entry.cause.contains("host_freshness"))
        #expect(entry.cause.contains("CANDIDATE"))
        #expect(entry.cause.contains("Type-census exemption only"))
        #expect(entry.cause.contains("NOT evidence for the cache story"))
        #expect(!entry.reference.isEmpty)
    }
}

/// A self-cleaning temporary directory for the directory-mode tests.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("replay-diff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }

    func makeSubdirectory(_ name: String) throws -> URL {
        let sub = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
