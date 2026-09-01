import Foundation
import Testing
@testable import ReplayDiffKit

/// Round-2 finding **N-1**: `supersedes` must *pair for comparison*, never *excuse from
/// comparison*.
///
/// Round 1 modelled only the arriving half of a substitution, so the vanishing half read as
/// an upstream regression (loud false alarm). The round-1 fix excused both halves by
/// **name** — and because step 3 excludes one-sided types from pairing, that took the whole
/// event class out of the gate. Round-2 review reproduced the consequence on the real
/// captures: every surface in all six re-mapped at 1×1 instead of 2560×1440 — a total
/// graphics regression — came out `PASS, exit 0`, with totals byte-identical to an honest
/// flip. And since the frozen baseline is pre-flip forever, that was the *steady state* of
/// every future drill, not an edge case.
///
/// The three shapes below are the reviewer's own constructions and are the acceptance
/// criteria for this round: honest flip → PASS, geometry destroyed → FAIL, surface
/// re-attributed to a different window → FAIL.
@Suite("L5-7 a substituted class is compared, not excused")
struct SubstitutionComparisonTests {
    // MARK: - Fixtures

    /// Two windows, both created on both sides, and one surface mapped to the first.
    /// Deliberately cascade-free: identical `WindowCreate`s in identical order mean the
    /// `window` ordinals cannot shift, so anything reported here comes from the
    /// substitution logic and not from the ordinal cascade (which is what made the
    /// reviewer's ADV-4 fail for the wrong reason).
    static let baseline: [String] = [
        #"{"t_ms":0,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":1001,"fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Alpha"}"#,
        #"{"t_ms":10,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":1002,"fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":400,"windowHeight":300,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Beta"}"#,
        #"{"t_ms":20,"tid":"0x2f6be3540","ev":"GfxMapSurfaceToWindow","surfaceId":1,"windowId":1001,"mappedWidth":800,"mappedHeight":600}"#,
    ]

    /// The plain map replaced by the scaled variant. `windowId`/`surfaceId`/`mapped*` are
    /// controllable so each shape below perturbs exactly one thing.
    static func scaledMap(windowId: Int = 1001, mappedWidth: Int = 800, mappedHeight: Int = 600) -> String {
        """
        {"t_ms":20,"tid":"0x2f6be3540","ev":"GfxMapSurfaceToScaledWindow","surfaceId":1,\
        "windowId":\(windowId),"mappedWidth":\(mappedWidth),"mappedHeight":\(mappedHeight),\
        "targetWidth":1600,"targetHeight":1200}
        """
    }

    static func candidate(replacingMapWith line: String) -> [String] {
        Array(baseline.dropLast()) + [line]
    }

    static func report(_ candidateLines: [String], options: DifferOptions = DifferOptions()) -> DiffReport {
        SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(baseline, label: "pre-flip"),
            candidate: CaptureFixture.stream(candidateLines, label: "post-flip")
        )
    }

    // MARK: - Shape 1: the honest flip still passes

    @Test("an honest flip — same surface, same window, same geometry — passes")
    func honestFlipPasses() {
        let report = Self.report(Self.candidate(replacingMapWith: Self.scaledMap()))
        #expect(!report.hasRegressions, "unexpected: \(report.regressions)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        // Two whole-type presence findings, plus one per declared new field — reported once
        // for the whole class, not once per matched event.
        #expect(report.differences.count == 4, "unexpected: \(report.differences)")
        let newFieldFindings = report.differences.filter { $0.field != nil }
        #expect(Set(newFieldFindings.compactMap(\.field)) == ["targetWidth", "targetHeight"])
        #expect(newFieldFindings.allSatisfy { $0.candidateValue == "present on 1 matched event(s)" })
    }

    /// The excuse must *say* it is only excusing presence. An operator reading the artifact
    /// has to be able to tell "the class was compared" from "the class was skipped".
    @Test("the whole-type finding states that the occurrences are still compared")
    func wholeTypeFindingSaysComparisonHappened() throws {
        let report = Self.report(Self.candidate(replacingMapWith: Self.scaledMap()))
        let lost = try #require(report.differences.first { $0.eventName == "GfxMapSurfaceToWindow" })
        #expect(lost.detail.contains("ARE matched against it and field-compared"))
        // ...and it must not assert the falsified mechanism (round-2 finding N-6).
        #expect(lost.detail.contains("MECHANISM OPEN"))
        #expect(!lost.detail.contains("which flips the client's AVC capability advertisement"))
    }

    // MARK: - Shape 2: ADV-3, geometry destroyed

    /// Reviewer's ADV-3. The flip is honest in every respect except that the mapped
    /// geometry is destroyed. Round 2 returned `PASS`; this must FAIL.
    @Test("ADV-3: a flip that also destroys the mapped geometry FAILS")
    func adv3GeometryDestroyedFails() throws {
        let report = Self.report(
            Self.candidate(replacingMapWith: Self.scaledMap(mappedWidth: 1, mappedHeight: 1))
        )
        #expect(report.hasRegressions)
        let geometry = report.differences.filter { $0.diffClass == .fieldValueChanged }
        #expect(geometry.count == 2, "unexpected: \(report.differences)")
        #expect(Set(geometry.compactMap(\.field)) == ["mappedWidth", "mappedHeight"])
        // The finding names the pair it came from, so the reader knows which comparison ran.
        #expect(geometry.allSatisfy { $0.eventName == "GfxMapSurfaceToWindow→GfxMapSurfaceToScaledWindow" })
        let width = try #require(geometry.first { $0.field == "mappedWidth" })
        #expect(width.baselineValue == "800")
        #expect(width.candidateValue == "1")
    }

    // MARK: - Shape 3: ADV-1, re-attributed to a different window

    /// Reviewer's ADV-1: both windows exist on both sides, but in the candidate the surface
    /// is mapped to Beta instead of Alpha — Alpha's content is never drawn. The identity
    /// tuple is the matching key, so the two occurrences land in different buckets and the
    /// mismatch is reported as ``DiffClass/eventCountChanged`` on both.
    @Test("ADV-1: a surface re-attributed to a different window FAILS")
    func adv1ReattributionFails() {
        let report = Self.report(Self.candidate(replacingMapWith: Self.scaledMap(windowId: 1002)))
        #expect(report.hasRegressions)
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "unexpected: \(report.differences)")
        #expect(counts.allSatisfy { $0.eventName == "GfxMapSurfaceToWindow→GfxMapSurfaceToScaledWindow" })
        // Title anchoring (W2 batch 2): Alpha and Beta are titled, so the two orphaned
        // sides name the windows themselves — better evidence than the old ordinals.
        #expect(counts.contains { $0.detail.contains("windowId=\"window@Alpha\"") })
        #expect(counts.contains { $0.detail.contains("windowId=\"window@Beta\"") })
    }

    // MARK: - Counts must correspond

    /// The collapse shape: many plain maps become one scaled map. Round 2 caught this only
    /// incidentally, via the ordinal cascade that deleting lines happens to cause; here the
    /// line count is preserved by adding a second window mapping, so the *only* thing wrong
    /// is that one identity lost its mapping.
    @Test("unequal occurrence counts across the pair are a regression")
    func unequalCountsAreARegression() {
        var baselineLines = Self.baseline
        baselineLines.append(
            #"{"t_ms":30,"tid":"0x2f6be3540","ev":"GfxMapSurfaceToWindow","surfaceId":2,"windowId":1002,"mappedWidth":400,"mappedHeight":300}"#
        )
        // Candidate: only ONE of the two surfaces gets a scaled mapping.
        let candidateLines = Array(baselineLines.dropLast(2)) + [Self.scaledMap()]

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(baselineLines, label: "two-surfaces"),
            candidate: CaptureFixture.stream(candidateLines, label: "one-surface")
        )
        #expect(report.hasRegressions)
        #expect(report.differences.contains {
            $0.diffClass == .eventCountChanged && $0.detail.contains("surfaceId=\"surface#1\"")
        })
    }

    // MARK: - Negative controls on the newFields exemption

    /// A declared new field is exempt only in the direction that matches the variant. One
    /// present on the *old* side and missing from the new one is the opposite of "the
    /// variant carries a field the other cannot" — it is a field that went away.
    ///
    /// Built on a synthetic variant pair rather than the real one: `RailEvent` requires
    /// **both** `targetWidth` and `targetHeight` on a scaled map, so a real scaled event
    /// missing one is an unparsable line, not a presence change. Two unmodelled names have
    /// no payload requirements and isolate the guard exactly.
    @Test("a declared new field on the WRONG side is not exempt")
    func newFieldOnTheWrongSideIsReported() throws {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "FutureVariantB",
                expectedSide: .candidate,
                supersedes: "FutureVariantA",
                newFields: ["extra"],
                cause: "fixture variant pair",
                reference: "unit test"
            )
        ])
        // `extra` sits on the OLD side, where the declaration does not apply.
        let baselineLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantA","surfaceId":1,"extra":7}"#]
        let candidateLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantB","surfaceId":1}"#]

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(baselineLines, label: "old-has-extra"),
            candidate: CaptureFixture.stream(candidateLines, label: "new-lacks-extra")
        )
        let presence = report.differences.filter { $0.diffClass == .fieldPresenceChanged }
        #expect(presence.count == 1, "unexpected: \(report.differences)")
        #expect(presence.first?.field == "extra")
        #expect(presence.first?.baselineValue == "7")
        #expect(presence.first?.candidateValue == "<absent>")
        #expect(report.hasRegressions)
    }

    /// The positive control for the pair above: the same declaration, the same two names,
    /// with `extra` on the side the declaration names — exempt, counted, gate passes.
    @Test("the same declared new field on the RIGHT side is exempt and counted")
    func newFieldOnTheRightSideIsExempt() throws {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "FutureVariantB",
                expectedSide: .candidate,
                supersedes: "FutureVariantA",
                newFields: ["extra"],
                cause: "fixture variant pair",
                reference: "unit test"
            )
        ])
        let baselineLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantA","surfaceId":1}"#]
        let candidateLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantB","surfaceId":1,"extra":7}"#]

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(baselineLines, label: "old"),
            candidate: CaptureFixture.stream(candidateLines, label: "new-has-extra")
        )
        #expect(!report.hasRegressions, "unexpected: \(report.regressions)")
        let record = try #require(report.differences.first { $0.field == "extra" })
        #expect(record.diffClass == .knownLocalDifference)
        #expect(record.candidateValue == "present on 1 matched event(s)")
    }

    /// ...and a declared new field present on *both* sides with different values falls
    /// through to ordinary comparison rather than being waved past.
    @Test("a declared new field present on both sides is compared normally")
    func newFieldPresentOnBothSidesIsCompared() {
        var baselineLines = Self.baseline
        baselineLines[2] = String(baselineLines[2].dropLast()) + ",\"targetWidth\":1600,\"targetHeight\":1200}"
        let candidateLines = Self.candidate(replacingMapWith: Self.scaledMap())
            .map { $0.replacingOccurrences(of: "\"targetWidth\":1600", with: "\"targetWidth\":3200") }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(baselineLines, label: "both-have-target"),
            candidate: CaptureFixture.stream(candidateLines, label: "target-changed")
        )
        #expect(report.differences.contains {
            $0.diffClass == .fieldValueChanged && $0.field == "targetWidth"
                && $0.baselineValue == "1600" && $0.candidateValue == "3200"
        })
        #expect(report.hasRegressions)
    }

    /// The exemption belongs to the entry, not to the field name: an entry that declares no
    /// `newFields` gets no exemption, and `target*` reads as a presence change.
    @Test("without a newFields declaration the arriving fields are presence changes")
    func withoutNewFieldsDeclarationTargetFieldsAreReported() {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "GfxMapSurfaceToScaledWindow",
                expectedSide: .candidate,
                supersedes: "GfxMapSurfaceToWindow",
                cause: "fixture entry with no declared new fields",
                reference: "unit test"
            )
        ])

        let report = Self.report(Self.candidate(replacingMapWith: Self.scaledMap()), options: options)
        let presence = report.differences.filter { $0.diffClass == .fieldPresenceChanged }
        #expect(Set(presence.compactMap(\.field)) == ["targetWidth", "targetHeight"])
        #expect(report.hasRegressions)
    }

    // MARK: - The mirror direction (round-3 finding N-8)
    //
    // Every test above uses the pre-seeded entry, whose `expectedSide` is `.candidate`. An
    // operator-authored `--known-difference-table` entry may name `.baseline` instead — the
    // natural shape of a revert/downgrade drill, where the frozen baseline holds the NEWER
    // variant and the candidate is the one being rolled back to. Round-3 review found step 4b
    // transposed the two names in that arm: both lookups missed, `match` got two empty
    // arrays, the step silently did nothing, and the whole class went back to a pure
    // name-level excuse — `PASS, exit 0` on a total graphics regression, while the artifact
    // printed "these occurrences ARE matched against it and field-compared". The suite stayed
    // green at 80/9 both with and without the bug, because nothing exercised this arm.

    /// A table entry mirroring the pre-seeded one: the scaled variant is the *baseline*-side
    /// type, the plain variant is what the candidate reverts to.
    static let mirroredTable = KnownDifferenceTable(entries: [
        KnownDifferenceEntry(
            eventName: "GfxMapSurfaceToScaledWindow",
            expectedSide: .baseline,
            supersedes: "GfxMapSurfaceToWindow",
            newFields: ["targetWidth", "targetHeight"],
            cause: "fixture: revert-drill shape — the newer variant is on the frozen baseline",
            reference: "unit test"
        )
    ])

    static func mirroredOptions() -> DifferOptions {
        var options = DifferOptions()
        options.knownDifferenceTable = Self.mirroredTable
        return options
    }

    /// Baseline holds the scaled variant; candidate reverts to the plain one, same surface,
    /// same window, same geometry. Nothing is wrong, so the gate must pass.
    @Test("mirror: an honest revert passes")
    func mirroredHonestRevertPasses() {
        let report = SemanticDiffer(options: Self.mirroredOptions()).diff(
            baseline: CaptureFixture.stream(Self.candidate(replacingMapWith: Self.scaledMap()), label: "newer-baseline"),
            candidate: CaptureFixture.stream(Self.baseline, label: "reverted-candidate")
        )
        #expect(!report.hasRegressions, "unexpected: \(report.regressions)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(report.differences.count == 4, "unexpected: \(report.differences)")
        // The label reads baseline→candidate in this direction too.
        #expect(report.differences.contains {
            $0.eventName == "GfxMapSurfaceToScaledWindow→GfxMapSurfaceToWindow"
        })
        // `newFields` are exempt on the side the scaled variant is on — the BASELINE here.
        let newFieldRecords = report.differences.filter { $0.field != nil }
        #expect(Set(newFieldRecords.compactMap(\.field)) == ["targetWidth", "targetHeight"])
        #expect(newFieldRecords.allSatisfy { $0.baselineValue == "present on 1 matched event(s)" })
        #expect(newFieldRecords.allSatisfy { $0.candidateValue == "<absent>" })
    }

    /// **Mirrored ADV-3.** The revert also destroys the mapped geometry. This is the shape
    /// that passed clean under the transposition; it must FAIL.
    @Test("mirror: ADV-3 — a revert that destroys the mapped geometry FAILS")
    func mirroredAdv3GeometryDestroyedFails() throws {
        var revertedLines = Self.baseline
        revertedLines[2] = revertedLines[2]
            .replacingOccurrences(of: "\"mappedWidth\":800,\"mappedHeight\":600", with: "\"mappedWidth\":1,\"mappedHeight\":1")

        let report = SemanticDiffer(options: Self.mirroredOptions()).diff(
            baseline: CaptureFixture.stream(Self.candidate(replacingMapWith: Self.scaledMap()), label: "newer-baseline"),
            candidate: CaptureFixture.stream(revertedLines, label: "reverted-1x1")
        )
        #expect(report.hasRegressions, "mirror arm of step 4b is dead again — N-8 has regressed")
        // Reviewer's measured shape for the fixed arm: 6 findings, 2 of them regressions.
        #expect(report.differences.count == 6, "unexpected: \(report.differences)")
        #expect(report.regressions.count == 2, "unexpected: \(report.regressions)")
        let geometry = report.differences.filter { $0.diffClass == .fieldValueChanged }
        #expect(Set(geometry.compactMap(\.field)) == ["mappedWidth", "mappedHeight"])
        #expect(geometry.allSatisfy { $0.eventName == "GfxMapSurfaceToScaledWindow→GfxMapSurfaceToWindow" })
        let width = try #require(geometry.first { $0.field == "mappedWidth" })
        #expect(width.baselineValue == "800")
        #expect(width.candidateValue == "1")
    }

    /// **Mirrored ADV-1.** Same direction, re-attributed surface: still a regression.
    @Test("mirror: a surface re-attributed to a different window FAILS")
    func mirroredReattributionFails() {
        var revertedLines = Self.baseline
        revertedLines[2] = revertedLines[2].replacingOccurrences(of: "\"windowId\":1001", with: "\"windowId\":1002")

        let report = SemanticDiffer(options: Self.mirroredOptions()).diff(
            baseline: CaptureFixture.stream(Self.candidate(replacingMapWith: Self.scaledMap()), label: "newer-baseline"),
            candidate: CaptureFixture.stream(revertedLines, label: "reverted-reattributed")
        )
        #expect(report.hasRegressions)
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "unexpected: \(report.differences)")
        #expect(counts.allSatisfy { $0.eventName == "GfxMapSurfaceToScaledWindow→GfxMapSurfaceToWindow" })
    }

    /// Mirrored counterpart of `newFieldOnTheWrongSideIsReported`: with the variant on the
    /// baseline, the "wrong side" for a declared new field is the *candidate*.
    @Test("mirror: a declared new field on the WRONG side is not exempt")
    func mirroredNewFieldOnTheWrongSideIsReported() throws {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "FutureVariantB",
                expectedSide: .baseline,
                supersedes: "FutureVariantA",
                newFields: ["extra"],
                cause: "fixture variant pair, mirrored",
                reference: "unit test"
            )
        ])
        // `extra` belongs to FutureVariantB (baseline side). Here it sits on the candidate's
        // FutureVariantA instead — the wrong side, so not exempt.
        let baselineLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantB","surfaceId":1}"#]
        let candidateLines = [#"{"t_ms":1,"tid":"0x1f6be3540","ev":"FutureVariantA","surfaceId":1,"extra":7}"#]

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(baselineLines, label: "b-lacks-extra"),
            candidate: CaptureFixture.stream(candidateLines, label: "a-has-extra")
        )
        let presence = report.differences.filter { $0.diffClass == .fieldPresenceChanged }
        #expect(presence.count == 1, "unexpected: \(report.differences)")
        #expect(presence.first?.field == "extra")
        #expect(presence.first?.candidateValue == "7")
        #expect(report.hasRegressions)
    }

    // MARK: - Artifact truthfulness (round-3 finding N-9)

    /// **ADV-7.** A pure addition: the candidate keeps every plain map *and* additionally
    /// emits the excused scaled type. The plain type is on both sides, so nothing was
    /// superseded and there is no counterpart set to pair against — which is fine. What is
    /// not fine is claiming otherwise, which the artifact used to do.
    @Test("N-9: when nothing is paired, the artifact says so instead of claiming a comparison")
    func unpairedAdditionSaysItWasNotCompared() throws {
        // Baseline: plain map. Candidate: plain map (unchanged) + a scaled map as well.
        let candidateLines = Self.baseline + [Self.scaledMap(mappedWidth: 1, mappedHeight: 1)]

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(Self.baseline, label: "plain-only"),
            candidate: CaptureFixture.stream(candidateLines, label: "plain-plus-scaled")
        )
        let scaled = try #require(report.differences.first { $0.eventName == "GfxMapSurfaceToScaledWindow" })
        #expect(scaled.diffClass == .knownLocalDifference)
        // No comparison happened, and the detail must not pretend one did.
        #expect(!report.differences.contains { $0.diffClass == .fieldValueChanged })
        #expect(!scaled.detail.contains("ARE compared against these one-by-one"))
        #expect(scaled.detail.contains("NOT field-compared"))
        #expect(scaled.detail.contains("present on both sides, or on neither"))
        #expect(scaled.detail.contains("payload and identity were NOT examined"))
    }

    /// The positive branch of the same clause: when the pairing *does* fire, the claim is
    /// printed — otherwise N-9's fix would have silenced a true statement.
    @Test("N-9: when the pairing does fire, the artifact says the occurrences were compared")
    func pairedSubstitutionSaysItWasCompared() throws {
        let report = Self.report(Self.candidate(replacingMapWith: Self.scaledMap()))
        let scaled = try #require(report.differences.first {
            $0.eventName == "GfxMapSurfaceToScaledWindow" && $0.field == nil
        })
        #expect(scaled.detail.contains("ARE compared against these one-by-one"))
        #expect(!scaled.detail.contains("NOT field-compared"))
    }

    /// The third branch: both types one-sided on the *same* side (the N-2 shape). Nothing was
    /// superseded, and the artifact must name that specific reason rather than the generic one.
    @Test("N-9: a same-side co-appearance names its own reason")
    func sameSideCoAppearanceNamesItsReason() throws {
        // Baseline has neither map type; candidate gains both.
        let baselineLines = Array(Self.baseline.dropLast())
        let candidateLines = Self.baseline + [Self.scaledMap()]

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(baselineLines, label: "neither"),
            candidate: CaptureFixture.stream(candidateLines, label: "both")
        )
        let scaled = try #require(report.differences.first { $0.eventName == "GfxMapSurfaceToScaledWindow" })
        #expect(scaled.detail.contains("one-sided on the SAME side, so nothing was superseded"))
        #expect(!scaled.detail.contains("ARE compared against these one-by-one"))
        // ...and the co-appearing plain type is still an unexplained regression (N-2).
        #expect(report.hasRegressions)
    }

    /// A pure-addition entry with no `supersedes` at all: also must not claim a comparison.
    @Test("N-9: a pure-addition entry states it has no counterpart")
    func pureAdditionEntryStatesNoCounterpart() throws {
        var options = DifferOptions()
        options.knownDifferenceTable = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "FutureVariantB",
                expectedSide: .candidate,
                cause: "fixture pure addition",
                reference: "unit test"
            )
        ])
        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(Self.baseline, label: "base"),
            candidate: CaptureFixture.stream(
                Self.baseline + [#"{"t_ms":30,"tid":"0x1f6be3540","ev":"FutureVariantB","surfaceId":9}"#],
                label: "plus-addition"
            )
        )
        let added = try #require(report.differences.first { $0.eventName == "FutureVariantB" })
        #expect(added.diffClass == .knownLocalDifference)
        #expect(added.detail.contains("pure addition, no paired type"))
        #expect(added.detail.contains("payload was NOT examined"))
        #expect(!added.detail.contains("ARE compared"))
    }

    // MARK: - The real captures, end to end

    /// The reviewer's decisive invocation, in-process over all six frozen captures: the
    /// honest flip passes, the same flip with 1×1 geometry does not. Fixtures prove the
    /// logic; this proves it on the data the gate will actually see.
    @Test("on the six frozen captures: honest flip passes, 1x1 geometry fails")
    func realCapturesHonestFlipVersusDestroyedGeometry() throws {
        func flip(_ contents: String, destroyGeometry: Bool) -> String {
            contents.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
                let line = String(rawLine)
                guard line.contains("\"ev\":\"GfxMapSurfaceToWindow\"") else { return line }
                var flipped = line.replacingOccurrences(
                    of: "\"ev\":\"GfxMapSurfaceToWindow\"",
                    with: "\"ev\":\"GfxMapSurfaceToScaledWindow\""
                )
                if destroyGeometry {
                    flipped = flipped.replacingOccurrences(
                        of: "\"mappedWidth\":[0-9]+,\"mappedHeight\":[0-9]+",
                        with: "\"mappedWidth\":1,\"mappedHeight\":1",
                        options: .regularExpression
                    )
                }
                return String(flipped.dropLast()) + ",\"targetWidth\":1600,\"targetHeight\":1200}"
            }.joined(separator: "\n")
        }

        var sawAnyFlip = false
        for name in PhaseSamples.names {
            let url = try #require(PhaseSamples.url(named: name))
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard contents.contains("\"ev\":\"GfxMapSurfaceToWindow\"") else { continue }
            sawAnyFlip = true
            let baseline = ReplayStream.parse(contents: contents, label: name)

            let honest = SemanticDiffer().diff(
                baseline: baseline,
                candidate: ReplayStream.parse(contents: flip(contents, destroyGeometry: false), label: name)
            )
            #expect(!honest.hasRegressions, "\(name) honest flip: \(honest.regressions)")

            let destroyed = SemanticDiffer().diff(
                baseline: baseline,
                candidate: ReplayStream.parse(contents: flip(contents, destroyGeometry: true), label: name)
            )
            #expect(destroyed.hasRegressions, "\(name) 1x1 geometry passed — N-1 has regressed")
            #expect(destroyed.regressions.allSatisfy { $0.diffClass == .fieldValueChanged })
            #expect(destroyed.regressions.contains { $0.field == "mappedWidth" })
        }
        // s2-nohidef has zero surface maps; the loop must still have done real work.
        #expect(sawAnyFlip)
    }
}
