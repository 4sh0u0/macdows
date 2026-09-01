import Foundation
import Testing
@testable import ReplayDiffKit

/// Acceptance row 4 of M1 lane L5: **a changed field value → exactly one classified
/// difference.**
///
/// "Exactly one" is the load-bearing half. A differ that reports one real change as
/// fourteen cascading findings is a differ nobody reads, and an upgrade gate nobody reads
/// is an upgrade gate that does not exist.
@Suite("L5-4 a changed field value yields exactly one classified difference")
struct ChangedFieldTests {
    @Test("one changed geometry field is one fieldValueChanged and nothing else")
    func oneChangedFieldIsOneDifference() throws {
        let mutated = CaptureFixture.changingNumber(
            CaptureFixture.baseline,
            on: .windowCreate,
            key: "windowWidth",
            to: 900
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "changed-width")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .fieldValueChanged)
        #expect(difference.severity == .regression)
        #expect(difference.eventName == "WindowCreate")
        #expect(difference.field == "windowWidth")
        #expect(difference.baselineValue == "800")
        #expect(difference.candidateValue == "900")
        #expect(difference.baselineLine == CaptureFixture.Line.windowCreate.rawValue + 1)
        #expect(difference.candidateLine == CaptureFixture.Line.windowCreate.rawValue + 1)
        #expect(report.hasRegressions)
    }

    @Test("a changed string field is one difference too")
    func changedStringFieldIsOneDifference() throws {
        var mutated = CaptureFixture.baseline
        mutated[CaptureFixture.Line.channelConnected.rawValue] = mutated[
            CaptureFixture.Line.channelConnected.rawValue
        ].replacingOccurrences(of: "\"rdpdr\"", with: "\"cliprdr\"")

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "changed-channel")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .fieldValueChanged)
        #expect(difference.field == "name")
        #expect(difference.baselineValue == "\"rdpdr\"")
        #expect(difference.candidateValue == "\"cliprdr\"")
    }

    /// Two independent changes are two findings, not one aggregated "the event differs".
    /// Field granularity is what lets a drill record say *what* moved.
    @Test("two changed fields on one event are two findings, one per field")
    func twoChangedFieldsAreTwoDifferences() {
        var mutated = CaptureFixture.changingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "windowWidth", to: 900
        )
        mutated = CaptureFixture.changingNumber(mutated, on: .windowCreate, key: "windowHeight", to: 700)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "changed-size")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .fieldValueChanged })
        #expect(Set(report.differences.compactMap(\.field)) == ["windowWidth", "windowHeight"])
    }

    /// A field appearing or disappearing gets its own class. adr/0008 §5's replay-compat
    /// rule makes "the probe grew a field" an *expected* shape of change on a probe
    /// upgrade, so it must be distinguishable from "the value moved" at a glance.
    /// `visibleOffsetX` is adr/0010 §1's field and is emitted by no current probe build —
    /// exactly the append-only case.
    @Test("a field present on one side only is fieldPresenceChanged, not fieldValueChanged")
    func newFieldIsItsOwnClass() throws {
        let mutated = CaptureFixture.addingNumber(
            CaptureFixture.baseline,
            on: .windowCreate,
            key: "visibleOffsetX",
            value: 12
        )

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "grew-visibleOffsetX")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .fieldPresenceChanged)
        #expect(difference.field == "visibleOffsetX")
        #expect(difference.baselineValue == "<absent>")
        #expect(difference.candidateValue == "12")
    }

    /// A change inside a redacted field is still detected, and its value still never
    /// printed. Project red line: this tool's output becomes a drill evidence artifact.
    @Test("a redacted field's change is reported without disclosing either value")
    func redactedFieldChangeIsReportedButNotDisclosed() throws {
        // A hand-built pair rather than the shared fixture: no phase05 capture contains
        // VerifyCertificateEx (RailEvent's own doc comment records that), so the redaction
        // path has to be exercised deliberately.
        let template = """
            {"t_ms":10,"tid":"0x1f6be3540","ev":"VerifyCertificateEx","host":"HOSTVALUE",\
            "port":3389,"commonName":"CNVALUE","subject":"SUBJVALUE","issuer":"ISSVALUE",\
            "fingerprint":"FPVALUE","flags":0}
            """
        let baseline = CaptureFixture.stream(
            [template.replacingOccurrences(of: "SUBJVALUE", with: "subject-alpha")],
            label: "cert-baseline"
        )
        let candidate = CaptureFixture.stream(
            [template.replacingOccurrences(of: "SUBJVALUE", with: "subject-beta")],
            label: "cert-candidate"
        )

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .fieldValueChanged)
        #expect(difference.field == "subject")
        #expect(difference.baselineValue?.hasPrefix("<redacted:") == true)
        #expect(difference.candidateValue?.hasPrefix("<redacted:") == true)

        let rendered = DiffReportSet(reports: [report]).textReport()
        #expect(!rendered.contains("subject-alpha"))
        #expect(!rendered.contains("subject-beta"))
        #expect(!rendered.contains("HOSTVALUE"))
    }
}
