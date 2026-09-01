import Foundation
import Testing
@testable import ReplayDiffKit

/// P1 (upgrade-gate drill 2026-09-drill-01 §7.2, sample-audit §7(g)): the instrumented
/// probe logs `GfxCapsAdvertise`/`GfxCapsConfirm` on every session, and the six frozen
/// 2026-08-19 baselines structurally cannot contain either — the probe that recorded them
/// predates the instrumentation. Without pre-seeded entries the very next gate run would
/// report the instrumentation itself as two `eventTypeOnlyOnOneSide` regressions. Same
/// table mechanism as F-1's entry, but a pure addition: no `supersedes`, because nothing
/// disappears from the baseline in exchange.
@Suite("P1 caps instrumentation is a known local difference, not a regression")
struct CapsInstrumentationTests {
    static let capsLines = [
        #"{"t_ms":41,"tid":"0x2f6be3540","ev":"GfxCapsAdvertise","capsSetCount":2,"capsSets":"0x00080004:0x00000000,0x000A0701:0x00000080"}"#,
        #"{"t_ms":58,"tid":"0x2f6be3540","ev":"GfxCapsConfirm","version":"0x000A0701","flags":"0x00000080"}"#,
    ]

    @Test("preSeeded explains each caps event as candidate-only, pure addition",
          arguments: ["GfxCapsAdvertise", "GfxCapsConfirm"])
    func preSeededExplainsCapsEvent(name: String) throws {
        let entry = try #require(
            KnownDifferenceTable.preSeeded.explanation(for: name, presentOnlyOn: .candidate)
        )
        #expect(entry.expectedSide == .candidate)
        #expect(entry.supersedes == nil)
        #expect(entry.reference.contains("P1"))
    }

    @Test("a candidate carrying both caps events passes the gate as knownLocalDifference")
    func capsEventsAreExpectedNotRegressions() {
        let mutated = CaptureFixture.inserting(
            CaptureFixture.baseline,
            Self.capsLines,
            atIndex: CaptureFixture.Line.windowCreate.rawValue
        )
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "instrumented-probe")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(!report.hasRegressions)
    }

    /// Through the real seam (`ReplayStream` asks MacdowsCore to decode, and `isModelled`
    /// is derived from whether the decode landed on `RailEventKind.unknown`), not a direct
    /// call to the lane classifier with its defaulted `isModelled: true` — that variant
    /// passed for any `Gfx`-prefixed string and survived reverting `RailEvent.swift`
    /// entirely (review R1 finding I-2, the shift's 5th unfailable-test catch). Reverting
    /// the two `RailEventKind` cases now turns `unmodelledEventNames` non-empty and this
    /// red.
    @Test("both caps events are modelled by MacdowsCore and ride the gfx lane")
    func capsEventsAreModelledAndGfxLane() throws {
        let stream = CaptureFixture.stream(
            CaptureFixture.inserting(
                CaptureFixture.baseline,
                Self.capsLines,
                atIndex: CaptureFixture.Line.windowCreate.rawValue
            ),
            label: "instrumented-probe"
        )
        #expect(stream.unmodelledEventNames.isEmpty)
        for name in ["GfxCapsAdvertise", "GfxCapsConfirm"] {
            let record = try #require(stream.records.first { $0.eventName == name })
            #expect(record.isModelled)
            #expect(EventLane.lane(forEventName: record.eventName, isModelled: record.isModelled) == .gfx)
        }
    }

    /// R1 finding I-3: a full advertise list is ~329 chars (15 capsets, and the ones that
    /// carry SCALEDMAP_DISABLE sit at the END in wire order), while report rendering caps
    /// values at `DifferOptions.maxValueLength` (120) — which would cut exactly the tail
    /// this instrumentation exists to show. `capsSets` is exempt from truncation; other
    /// fields keep the cap.
    @Test("capsSets renders untruncated in reports; other long values still cap")
    func capsSetsRendersUntruncated() {
        let policy = FieldPolicy.default
        let fullList = Array(repeating: "0x000A0701:0x00000080", count: 15).joined(separator: ",")
        // displayString wraps strings in quotes; the assertion is about truncation, not quoting.
        #expect(policy.render(.string(fullList), field: "capsSets", maxLength: 120) == "\"\(fullList)\"")
        let other = policy.render(.string(fullList), field: "title", maxLength: 120)
        #expect(other.hasSuffix("chars)"), "non-exempt fields must keep the length cap: \(other)")
    }
}
