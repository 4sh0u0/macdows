import Foundation
import Testing
@testable import ReplayDiffKit

/// Acceptance row 2 of M1 lane L5: **timestamp/tid-only perturbation → empty diff.**
///
/// This is the property that makes the gate usable at all. Two captures of the same server
/// behaviour never share a single `t_ms` value (monotonic ms since connect) or a single
/// `tid` (a `pthread_self()` address), so a byte diff of two re-records is 100% noise.
@Suite("L5-2 timestamp and thread-id noise produces an empty diff")
struct TimestampAndThreadNoiseTests {
    @Test("rewriting every t_ms and every tid changes nothing semantically")
    func timingAndThreadNoiseIsIgnored() {
        let perturbed = CaptureFixture.perturbTimestampsAndThreadIds(CaptureFixture.baseline)

        // The mutation must actually have bitten, or this suite would pass on a no-op.
        #expect(perturbed != CaptureFixture.baseline)
        for (original, mutated) in zip(CaptureFixture.baseline, perturbed) {
            #expect(original != mutated)
        }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(perturbed, label: "perturbed")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
        #expect(report.candidateEventCount == CaptureFixture.baseline.count)
    }

    /// Session-scoped handles are the second half of the same problem: a re-record of the
    /// identical user actions gets fresh HWNDs and surface ids from the server. Shifting
    /// every identifier by a constant must not read as a difference, because the *shape* of
    /// the identifier graph is unchanged.
    @Test("renumbering every window and surface handle changes nothing semantically")
    func identifierRenumberingIsIgnored() {
        let renumbered = CaptureFixture.baseline.map {
            $0.replacingOccurrences(of: ":65832", with: ":123456")
                .replacingOccurrences(of: "\"surfaceId\":1", with: "\"surfaceId\":42")
        }
        #expect(renumbered != CaptureFixture.baseline)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(renumbered, label: "renumbered")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The negative control for the suite above. "Renumbering is ignored" must not mean
    /// "identifiers are never compared": a *re-attribution* — the same surface now mapped
    /// to a different window — changes the shape of the identifier graph and has to be
    /// reported.
    ///
    /// It surfaces as ``DiffClass/eventCountChanged`` rather than
    /// ``DiffClass/fieldValueChanged`` because identifier fields are the matching key: the
    /// candidate's `GfxMapSurfaceToWindow` no longer belongs to the same identity bucket,
    /// so there is no pair to compare fields within. That is the documented behaviour of
    /// the class ("...or with its occurrences attributed to a different set of
    /// windows/surfaces"), and this test pins it so a future refactor cannot quietly turn
    /// re-attribution into silence.
    @Test("re-attributing a surface to a different window is reported")
    func surfaceReattributionIsReported() {
        var mutated = CaptureFixture.baseline
        mutated[CaptureFixture.Line.gfxMapSurfaceToWindow.rawValue] = mutated[
            CaptureFixture.Line.gfxMapSurfaceToWindow.rawValue
        ].replacingOccurrences(of: "\"windowId\":65832", with: "\"windowId\":99999")

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "reattributed")
        )
        #expect(report.hasRegressions)
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "unexpected: \(report.differences)")
        #expect(counts.allSatisfy { $0.eventName == "GfxMapSurfaceToWindow" })
        // Title anchoring (W2 batch 2): the fixture window is titled, so its identity is
        // the anchored token; the re-attribution target 99999 never carries a title, so it
        // is the first (and only) ordinal handle.
        #expect(counts.contains { $0.detail.contains("windowId=\"window@Fixture Window\"") })
        #expect(counts.contains { $0.detail.contains("windowId=\"window#0\"") })
    }

    /// `--no-canonical-ids` must remain a real switch: with it, raw handle values are the
    /// matching key, so a renumbered capture stops matching at all. Documented as
    /// same-session-only for exactly this reason.
    @Test("with --no-canonical-ids a renumbered capture no longer matches")
    func rawIdentifierModeReportsRenumbering() {
        let renumbered = CaptureFixture.baseline.map {
            $0.replacingOccurrences(of: ":65832", with: ":123456")
        }
        var options = DifferOptions()
        options.canonicalizeIdentifiers = false

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(renumbered, label: "renumbered")
        )
        #expect(report.hasRegressions)
        #expect(report.differences.contains { $0.diffClass == .eventCountChanged })
    }

    /// `--compare-timing-fields` exists for same-session A/B work; prove it is a real
    /// switch and not decoration, so nobody assumes timing can never be compared.
    @Test("timing fields are compared when the policy stops ignoring them")
    func timingCanBeOptedBackIn() {
        var options = DifferOptions()
        options.fieldPolicy.ignoredFields = ["tid"]

        let perturbed = CaptureFixture.perturbTimestampsAndThreadIds(CaptureFixture.baseline)
        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(perturbed, label: "perturbed")
        )
        #expect(report.differences.allSatisfy { $0.field == "t_ms" })
        #expect(report.differences.count == CaptureFixture.baseline.count)
    }
}
