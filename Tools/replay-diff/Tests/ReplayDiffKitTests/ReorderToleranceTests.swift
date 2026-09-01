import Foundation
import Testing
@testable import ReplayDiffKit

/// Acceptance row 3 of M1 lane L5: **a reordered-within-tolerance pair → empty diff.**
///
/// The reorder that actually happens is cross-lane: the frozen captures have three
/// concurrent producer threads (`main`, `gfx`, `server` — see ``LaneOrderTests``), so an
/// RDPGFX event and a RAIL event recorded microseconds apart can land either way round on
/// two runs of the same scenario. The fixture's swap is exactly that pair
/// (`GfxMapSurfaceToWindow` on `0x2f6…` against `MonitoredDesktop` on `0x1f6…`).
///
/// Movement *within* one lane is a different question with a different answer — one thread's
/// order is causal, so it gets tolerance 0. That half lives in `L5-6`.
@Suite("L5-3 reordering within tolerance produces an empty diff")
struct ReorderToleranceTests {
    @Test("swapping two adjacent cross-channel events is not a difference")
    func adjacentCrossChannelSwapIsClean() {
        let swapped = CaptureFixture.swapping(
            CaptureFixture.baseline,
            .gfxMapSurfaceToWindow,
            .monitoredDesktop
        )
        #expect(swapped != CaptureFixture.baseline)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(swapped, label: "swapped")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The tolerance must be a threshold, not an amnesty. With `--order-tolerance 0` the
    /// same swap is reported — once per displaced event, and as nothing else.
    @Test("the same swap is reported under exact ordering")
    func adjacentSwapIsReportedAtToleranceZero() {
        var options = DifferOptions()
        options.orderTolerance = 0
        let swapped = CaptureFixture.swapping(
            CaptureFixture.baseline,
            .gfxMapSurfaceToWindow,
            .monitoredDesktop
        )

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(swapped, label: "swapped")
        )
        #expect(report.differences.count == 2, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .eventOrderChanged })
        #expect(Set(report.differences.compactMap(\.eventName)) == ["GfxMapSurfaceToWindow", "MonitoredDesktop"])
    }

    /// A move beyond the tolerance is reported — and reported *once*, about the event that
    /// moved, not once per event it moved past. That is what the rank-displacement rule
    /// buys over comparing raw line numbers: hoisting one event to the front of a
    /// seven-line capture shifts four other events by one position each, and none of those
    /// four is a finding.
    @Test("a move beyond the tolerance yields exactly one order finding")
    func longMoveIsReportedOnce() throws {
        let moved = CaptureFixture.moving(CaptureFixture.baseline, .gfxMapSurfaceToWindow, toIndex: 0)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(moved, label: "moved")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .eventOrderChanged)
        #expect(difference.eventName == "GfxMapSurfaceToWindow")
        #expect(difference.severity == .regression)
    }

    /// Reordering must not be confused with duplication or loss: the tolerated swap keeps
    /// every event, and the differ must still be able to tell when one goes missing.
    @Test("dropping an event is still reported after a tolerated swap")
    func toleratedSwapDoesNotMaskALostEvent() {
        var mutated = CaptureFixture.swapping(
            CaptureFixture.baseline,
            .gfxMapSurfaceToWindow,
            .monitoredDesktop
        )
        mutated.removeAll { $0.contains("\"ev\":\"ChannelConnected\"") }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "swapped-and-dropped")
        )
        #expect(report.hasRegressions)
        #expect(report.differences.contains {
            $0.diffClass == .eventTypeOnlyOnOneSide && $0.eventName == "ChannelConnected"
        })
    }
}
