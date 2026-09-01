import Foundation
import Testing
@testable import ReplayDiffKit

/// Acceptance row 5 of M1 lane L5: **an event type present in one side only → its own
/// class**, and M1 wave-1 ruling **F-1**: that vocabulary must include a class for "event
/// type present on one side only, attributable to a known local difference",
/// pre-seeded with the scaled-map / AVC-flip case.
///
/// Why F-1 is not decoration: `grep -c MapSurfaceToScaledWindow` over all six frozen
/// phase05 captures is 0. Those were recorded 2026-08-19; the FFmpeg/AVC capability flip
/// that makes the server answer with the scaled surface-map variant landed afterwards, in
/// Phase 2 W0(2). So the very first live re-record the upgrade gate ever sees will show an
/// entire event class on the candidate side and nothing on the baseline side — and that is
/// a known LOCAL difference between the two recordings, not an upstream FreeRDP regression
/// (mechanism deliberately unasserted — see `KnownDifferenceTable`). A gate that cannot say
/// which of the two it is has nothing useful to report.
@Suite("L5-5 an event type on one side only gets its own class")
struct EventTypePresenceTests {
    // MARK: - The unexplained class

    @Test("an unexplained new event type is one eventTypeOnlyOnOneSide finding")
    func newEventTypeIsItsOwnClass() throws {
        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [CaptureFixture.windowDeleteLine],
            atIndex: CaptureFixture.Line.postDisconnect.rawValue
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "with-window-delete")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .eventTypeOnlyOnOneSide)
        #expect(difference.severity == .regression)
        #expect(difference.eventName == "WindowDelete")
        #expect(difference.baselineValue == "absent")
        #expect(difference.candidateValue == "1 occurrence(s)")
        #expect(report.hasRegressions)
    }

    @Test("an event type lost on the candidate side is the same class, mirrored")
    func lostEventTypeIsItsOwnClass() throws {
        var mutated = CaptureFixture.baseline
        mutated.removeAll { $0.contains("\"ev\":\"MonitoredDesktop\"") }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "without-monitored-desktop")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .eventTypeOnlyOnOneSide)
        #expect(difference.eventName == "MonitoredDesktop")
        #expect(difference.baselineValue == "1 occurrence(s)")
        #expect(difference.candidateValue == "absent")
    }

    /// The class is per *type*, not per occurrence: a whole missing event class must be one
    /// line in the report, however many events it contains, or one finding buries the rest.
    @Test("many occurrences of a one-sided type are still one finding")
    func manyOccurrencesAreStillOneFinding() {
        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            (0..<12).map { _ in CaptureFixture.windowDeleteLine },
            atIndex: CaptureFixture.Line.postDisconnect.rawValue
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "many-deletes")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        #expect(report.differences.first?.candidateValue == "12 occurrence(s)")
    }

    // MARK: - F-1: the known-local-difference class

    @Test("the scaled surface-map on the candidate side is knownLocalDifference")
    func scaledSurfaceMapIsExplainedByTheKnownDifferenceTable() throws {
        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [
                CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200),
                CaptureFixture.scaledMapLine(tMs: 930, targetWidth: 1600, targetHeight: 1200),
            ],
            atIndex: CaptureFixture.Line.monitoredDesktop.rawValue
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "post-avc-flip")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .knownLocalDifference)
        #expect(difference.eventName == "GfxMapSurfaceToScaledWindow")
        #expect(difference.candidateValue == "2 occurrence(s)")

        // The whole point of the class: this must NOT fail the gate, and the record must
        // carry the cause and its authority so L11's drill record can transcribe them
        // instead of re-deriving them.
        #expect(difference.severity == .expected)
        #expect(!report.hasRegressions)
        #expect(difference.detail.contains("WITH_VIDEO_FFMPEG"))
        #expect(difference.detail.contains("F-1"))
    }

    /// The explanation is directional. The flip puts the scaled variant on the *new* side;
    /// finding it only on the frozen pre-flip baseline would mean the flip was lost, which
    /// is a real regression and must not inherit the excuse.
    @Test("the same event type on the baseline side only is NOT explained away")
    func scaledSurfaceMapOnTheBaselineSideIsARegression() throws {
        let withScaled = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200)],
            atIndex: CaptureFixture.Line.monitoredDesktop.rawValue
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(withScaled, label: "pre-flip-baseline"),
            candidate: CaptureFixture.baselineStream(label: "flip-lost")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .eventTypeOnlyOnOneSide)
        #expect(difference.severity == .regression)
        #expect(report.hasRegressions)
    }

    /// `--fail-on-expected` exists so a drill can be run in "show me everything" mode
    /// without editing the table.
    @Test("an explained difference still counts, and can still be made to fail")
    func explainedDifferenceIsCountedSeparately() {
        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200)],
            atIndex: CaptureFixture.Line.monitoredDesktop.rawValue
        )
        let set = DiffReportSet(reports: [
            SemanticDiffer().diff(
                baseline: CaptureFixture.baselineStream(),
                candidate: CaptureFixture.stream(mutated, label: "post-avc-flip")
            )
        ])
        #expect(set.totalDifferences == 1)
        #expect(set.totalRegressions == 0)
        #expect(set.totalExpected == 1)
        #expect(!set.hasRegressions)
        #expect(set.textReport().contains(": PASS"))
        #expect(set.textReport().contains("[knownLocalDifference](expected)"))
    }

    /// A table entry supplied at runtime must be able to explain a *different* event
    /// without recompiling, and must merge over — not replace — the built-in F-1 entry.
    @Test("a runtime table entry explains an additional event type")
    func runtimeTableEntryExplainsAnotherType() {
        let extra = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "WindowDelete",
                expectedSide: .candidate,
                cause: "fixture-only entry",
                reference: "unit test"
            )
        ])
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable.preSeeded.merging(extra)

        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [
                CaptureFixture.windowDeleteLine,
                CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200),
            ],
            atIndex: CaptureFixture.Line.postDisconnect.rawValue
        )

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "two-explained-types")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(!report.hasRegressions)
    }

    /// Guards the ruling itself: if someone ever deletes the pre-seeded entry, this fails
    /// before any drill silently reclassifies the AVC flip as an upstream regression.
    @Test("the built-in table still carries F-1's mandated entry")
    func preSeededTableCarriesTheMandatedEntry() throws {
        let entry = try #require(
            KnownDifferenceTable.preSeeded.explanation(
                for: "GfxMapSurfaceToScaledWindow",
                presentOnlyOn: .candidate
            )
        )
        #expect(entry.expectedSide == .candidate)
        #expect(entry.reference.contains("F-1"))
        // The substitution half (round-1 finding I-1) is expressed as a field on this one
        // entry, not as a second row — so the minimality guard below still holds at 1.
        #expect(entry.supersedes == "GfxMapSurfaceToWindow")
        #expect(KnownDifferenceTable.preSeeded.entries.count == 1, "the table must stay minimal — every entry disarms the gate for one event type")
    }

    // MARK: - F-1, substitution half (round-1 finding I-1)
    //
    // The AVC flip is a SUBSTITUTION, not an addition: the server answers with the scaled
    // variant *instead of* the plain one, so the plain type disappears from the candidate in
    // the same breath. Round-1 review reproduced the miss against the real captures — the
    // realistic post-flip candidate came out `regressions: 5, verdict: FAIL`, i.e. the gate
    // reporting our own WITH_VIDEO_FFMPEG=ON as five upstream FreeRDP regressions, which is
    // precisely what ruling F-1 forbids. Three shapes, three tests.

    /// Shape 1 — **substitution**: plain gone, scaled arrived. Both halves expected, gate passes.
    @Test("a substitution excuses BOTH halves and passes the gate")
    func substitutionExcusesBothHalves() {
        // Every plain map replaced by a scaled one, which is what a post-flip re-record of
        // the same scenario actually looks like.
        let mutated = CaptureFixture.baseline.map { line -> String in
            guard line.contains("\"ev\":\"GfxMapSurfaceToWindow\"") else { return line }
            let scaled = line.replacingOccurrences(
                of: "\"ev\":\"GfxMapSurfaceToWindow\"",
                with: "\"ev\":\"GfxMapSurfaceToScaledWindow\""
            )
            return String(scaled.dropLast()) + ",\"targetWidth\":1600,\"targetHeight\":1200}"
        }
        #expect(mutated != CaptureFixture.baseline)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "post-avc-flip")
        )
        // Two whole-type presence findings + one record per declared new field. Round 2's
        // fix also *compares* the two occurrence sets (suite L5-7); this fixture's flip is
        // honest, so that comparison contributes nothing.
        #expect(report.differences.count == 4, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(report.differences.allSatisfy { $0.severity == .expected })
        #expect(!report.hasRegressions)

        let lost = report.differences.first { $0.eventName == "GfxMapSurfaceToWindow" }
        #expect(lost?.candidateValue == "absent")
        // The disappearance must name its counterpart, so a reader can check the claim from
        // the same report rather than trusting the classifier.
        #expect(lost?.detail.contains("paired with GfxMapSurfaceToScaledWindow") == true)
        #expect(lost?.detail.contains("only on the candidate side of this same comparison") == true)
        #expect(lost?.detail.contains("F-1") == true)
    }

    /// Shape 2 — **lone disappearance**, the negative control that keeps `supersedes` from
    /// becoming a blanket excuse. The plain map vanishes and nothing replaces it: that is
    /// the flip having been lost, a real regression, and it must stay one.
    @Test("a lone disappearance with no replacement is still a regression")
    func loneDisappearanceIsStillARegression() throws {
        var mutated = CaptureFixture.baseline
        mutated.removeAll { $0.contains("\"ev\":\"GfxMapSurfaceToWindow\"") }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "flip-lost")
        )
        let whole = report.differences.filter { $0.eventName == "GfxMapSurfaceToWindow" }
        #expect(whole.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(whole.first)
        #expect(difference.diffClass == .eventTypeOnlyOnOneSide)
        #expect(difference.severity == .regression)
        #expect(report.hasRegressions)
    }

    /// Shape 2b — the replacement exists but is present on **both** sides, so it is not the
    /// product of this comparison's flip. The disappearance is then unrelated to it and
    /// stays a regression. This is the clause that makes `supersedes` conditional rather
    /// than a standing pardon for the name it mentions.
    @Test("a disappearance is not excused when the replacement is on both sides")
    func disappearanceNotExcusedWhenReplacementIsNotOneSided() throws {
        // Baseline: plain + scaled. Candidate: scaled only. `GfxMapSurfaceToScaledWindow` is
        // therefore on both sides and cannot be the substitution's arriving half.
        let scaledLine = CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200)
        let baselineLines = CaptureFixture.inserting(
            CaptureFixture.baseline, [scaledLine], atIndex: CaptureFixture.Line.monitoredDesktop.rawValue
        )
        var candidateLines = baselineLines
        candidateLines.removeAll { $0.contains("\"ev\":\"GfxMapSurfaceToWindow\"") }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(baselineLines, label: "both-variants"),
            candidate: CaptureFixture.stream(candidateLines, label: "plain-gone")
        )
        let whole = report.differences.filter { $0.eventName == "GfxMapSurfaceToWindow" }
        #expect(whole.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(whole.first)
        #expect(difference.diffClass == .eventTypeOnlyOnOneSide)
        #expect(difference.severity == .regression)
    }

    /// Shape 2c — the substitution running **backwards**: the scaled variant only on the
    /// baseline, the plain one only on the candidate. Same two event types, opposite sides.
    /// Neither half may be excused; this is the flip being lost, expressed as a swap.
    @Test("the substitution is directional — running it backwards excuses nothing")
    func reversedSubstitutionIsNotExcused() {
        let mutated = CaptureFixture.baseline.map { line -> String in
            guard line.contains("\"ev\":\"GfxMapSurfaceToWindow\"") else { return line }
            let scaled = line.replacingOccurrences(
                of: "\"ev\":\"GfxMapSurfaceToWindow\"",
                with: "\"ev\":\"GfxMapSurfaceToScaledWindow\""
            )
            return String(scaled.dropLast()) + ",\"targetWidth\":1600,\"targetHeight\":1200}"
        }
        // Swapped relative to `substitutionExcusesBothHalves`: the post-flip stream is the
        // BASELINE and the pre-flip one is the candidate.
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(mutated, label: "post-flip-baseline"),
            candidate: CaptureFixture.baselineStream(label: "flip-lost-candidate")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .eventTypeOnlyOnOneSide })
        #expect(report.differences.allSatisfy { $0.severity == .regression })
        #expect(report.hasRegressions)
    }

    /// Shape 2d — round-2 finding **N-2**: the third safety clause,
    /// `side == entry.expectedSide.opposite`, was load-bearing but unpinned — removing it
    /// left the suite green at 62/62. Its job is to stop a *co-appearance* being read as a
    /// substitution: if the baseline has neither map type and the candidate gains **both**,
    /// nothing was replaced, and only the entry's own type may be excused.
    @Test("both types appearing on the SAME side is not a substitution")
    func bothTypesAppearingOnOneSideIsNotASubstitution() throws {
        // Baseline: no surface maps at all. Candidate: gains the plain one AND the scaled one.
        var baselineLines = CaptureFixture.baseline
        baselineLines.removeAll { $0.contains("\"ev\":\"GfxMapSurfaceToWindow\"") }
        let candidateLines = CaptureFixture.inserting(
            baselineLines,
            [
                CaptureFixture.baseline[CaptureFixture.Line.gfxMapSurfaceToWindow.rawValue],
                CaptureFixture.scaledMapLine(tMs: 906, targetWidth: 1600, targetHeight: 1200),
            ],
            atIndex: baselineLines.count - 1
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(baselineLines, label: "neither-map"),
            candidate: CaptureFixture.stream(candidateLines, label: "both-maps")
        )
        let plain = try #require(report.differences.first { $0.eventName == "GfxMapSurfaceToWindow" })
        let scaled = try #require(report.differences.first { $0.eventName == "GfxMapSurfaceToScaledWindow" })
        // The entry's own type is excused (it appeared on its expected side); the type it
        // pairs with appeared on the SAME side, so nothing was superseded.
        #expect(scaled.diffClass == .knownLocalDifference)
        #expect(plain.diffClass == .eventTypeOnlyOnOneSide)
        #expect(plain.severity == .regression)
        #expect(report.hasRegressions)
    }

    /// Shape 3 — a **pure addition** entry (no `supersedes`) must not start excusing
    /// disappearances just because the substitution machinery exists.
    @Test("an entry without supersedes excuses no disappearance")
    func pureAdditionEntryExcusesNoDisappearance() {
        let table = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "WindowDelete",
                expectedSide: .candidate,
                cause: "fixture-only pure addition",
                reference: "unit test"
            )
        ])
        var options = DifferOptions()
        options.knownDifferenceTable = table

        var mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            [CaptureFixture.windowDeleteLine],
            atIndex: CaptureFixture.Line.postDisconnect.rawValue
        )
        mutated.removeAll { $0.contains("\"ev\":\"ChannelConnected\"") }

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "added-and-lost")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.contains {
            $0.eventName == "WindowDelete" && $0.diffClass == .knownLocalDifference
        })
        #expect(report.differences.contains {
            $0.eventName == "ChannelConnected" && $0.diffClass == .eventTypeOnlyOnOneSide
                && $0.severity == .regression
        })
        #expect(report.hasRegressions)
    }
}
