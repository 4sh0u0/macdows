import Foundation
import Testing
@testable import ReplayDiffKit

/// Acceptance row 1 of M1 lane L5: **identical inputs → empty diff.**
///
/// Test suites in this target are swift-testing `@Suite` structs rather than XCTest
/// classes, matching the repo's existing convention (all 23 suites in
/// `Packages/MacdowsCore/Tests/MacdowsCoreTests` are swift-testing; the repo contains no
/// `import XCTest`).
@Suite("L5-1 identical inputs produce an empty diff")
struct IdenticalStreamsTests {
    @Test("a fixture capture diffed against itself reports nothing")
    func identicalFixtureIsClean() {
        let baseline = CaptureFixture.baselineStream(label: "baseline")
        let candidate = CaptureFixture.baselineStream(label: "candidate")

        // Guard against a vacuous pass: an empty-vs-empty diff is also "clean".
        #expect(baseline.records.count == CaptureFixture.baseline.count)
        #expect(baseline.parseFailures.isEmpty)
        #expect(candidate.records.count == CaptureFixture.baseline.count)

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
        #expect(!report.hasRegressions)
        #expect(report.baselineEventCount == report.candidateEventCount)
    }

    @Test("cleanliness does not depend on the order tolerance being permissive")
    func identicalFixtureIsCleanUnderExactOrdering() {
        var options = DifferOptions()
        options.orderTolerance = 0
        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    @Test("cleanliness does not depend on identifier canonicalization")
    func identicalFixtureIsCleanWithRawIdentifiers() {
        var options = DifferOptions()
        options.canonicalizeIdentifiers = false
        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The offline half of the lane's end-to-end acceptance, asserted in-process so a
    /// regression shows up in `swift test` and not only in `Scripts/upgrade-gate.sh`:
    /// every real phase05 capture, diffed against itself, is clean — and parses without a
    /// single failure, so the run is not clean merely because nothing was read.
    @Test("every phase05 sample is clean against itself", arguments: PhaseSamples.names)
    func phase05SampleIsCleanAgainstItself(name: String) throws {
        let url = try #require(PhaseSamples.url(named: name), "sample not found: \(name)")
        let baseline = try ReplayStream.parse(fileAt: url)
        let candidate = try ReplayStream.parse(fileAt: url)

        #expect(baseline.parseFailures.isEmpty, "\(name): \(baseline.parseFailures)")
        #expect(baseline.records.count > 100, "\(name): only \(baseline.records.count) events parsed")

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        #expect(report.differences.isEmpty, "\(name): \(report.differences)")
    }
}

/// Locates the frozen phase05 captures relative to this source file, the same way
/// `MacdowsCoreTests/ReplayTests.swift:23-35` does, so the suite works from a fresh
/// checkout with no environment setup.
enum PhaseSamples {
    static let names = ["s1-baseline", "s2-nohidef", "s3-multiapp", "s4-badpath", "s5a", "s5b"]

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SAMPLES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> ReplayDiffKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> replay-diff/
            .deletingLastPathComponent() // -> Tools/
            .deletingLastPathComponent() // -> repo root
            .appendingPathComponent("samples/phase05-rail-events-2026-08-19", isDirectory: true)
    }

    static func url(named name: String) -> URL? {
        let url = directory.appendingPathComponent("\(name).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
