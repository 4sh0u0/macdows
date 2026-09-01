import Foundation

/// The result of diffing one baseline capture against one candidate capture.
public struct DiffReport: Sendable, Equatable, Codable {
    public let baselineLabel: String
    public let candidateLabel: String
    public let baselineEventCount: Int
    public let candidateEventCount: Int
    public let differences: [Difference]
    /// Informational, never failing: unmodelled event names, canonicalization mode, and
    /// anything else the operator should know while reading the differences.
    public let notes: [String]

    public init(
        baselineLabel: String,
        candidateLabel: String,
        baselineEventCount: Int,
        candidateEventCount: Int,
        differences: [Difference],
        notes: [String]
    ) {
        self.baselineLabel = baselineLabel
        self.candidateLabel = candidateLabel
        self.baselineEventCount = baselineEventCount
        self.candidateEventCount = candidateEventCount
        self.differences = differences
        self.notes = notes
    }

    public var isEmpty: Bool { differences.isEmpty }
    public var regressions: [Difference] { differences.filter { $0.severity == .regression } }
    public var expectedDifferences: [Difference] { differences.filter { $0.severity == .expected } }
    public var hasRegressions: Bool { differences.contains { $0.severity == .regression } }

    /// Count per class, in ``DiffClass/allCases`` order, omitting zero counts.
    public var countsByClass: [(diffClass: DiffClass, count: Int)] {
        DiffClass.allCases.compactMap { klass in
            let count = differences.filter { $0.diffClass == klass }.count
            return count == 0 ? nil : (klass, count)
        }
    }
}

/// A run over one or more capture pairs (a whole samples directory, in the usual case).
public struct DiffReportSet: Sendable, Equatable, Codable {
    public let reports: [DiffReport]
    /// Pairing problems: a capture present in one directory only. Not a ``DiffClass`` —
    /// a missing *file* is a gate-input problem, not a server-behaviour difference.
    public let unpairedBaselines: [String]
    public let unpairedCandidates: [String]

    public init(reports: [DiffReport], unpairedBaselines: [String] = [], unpairedCandidates: [String] = []) {
        self.reports = reports
        self.unpairedBaselines = unpairedBaselines
        self.unpairedCandidates = unpairedCandidates
    }

    public var hasRegressions: Bool {
        !unpairedBaselines.isEmpty || !unpairedCandidates.isEmpty || reports.contains { $0.hasRegressions }
    }

    public var totalDifferences: Int { reports.reduce(0) { $0 + $1.differences.count } }
    public var totalRegressions: Int { reports.reduce(0) { $0 + $1.regressions.count } }
    public var totalExpected: Int { reports.reduce(0) { $0 + $1.expectedDifferences.count } }
}

// MARK: - Rendering

extension DiffReportSet {
    /// Human-readable report. Deterministic: no timestamps, no absolute paths, no
    /// dictionary iteration order — so two runs over the same inputs produce byte-identical
    /// text and a drill record can diff two drills.
    public func textReport() -> String {
        var lines: [String] = []
        for (index, report) in reports.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(contentsOf: report.textReportLines())
        }
        if !unpairedBaselines.isEmpty {
            lines.append("")
            lines.append("UNPAIRED (baseline side only): " + unpairedBaselines.sorted().joined(separator: ", "))
        }
        if !unpairedCandidates.isEmpty {
            if unpairedBaselines.isEmpty { lines.append("") }
            lines.append("UNPAIRED (candidate side only): " + unpairedCandidates.sorted().joined(separator: ", "))
        }
        lines.append("")
        lines.append("=== totals ===")
        lines.append("  captures compared : \(reports.count)")
        lines.append("  differences       : \(totalDifferences)")
        lines.append("  regressions       : \(totalRegressions)")
        lines.append("  expected (local)  : \(totalExpected)")
        lines.append("  verdict           : \(hasRegressions ? "FAIL" : "PASS")")
        if totalDifferences > 0 {
            lines.append("")
            lines.append("=== class legend ===")
            let seen = Set(reports.flatMap { $0.differences.map(\.diffClass) })
            for klass in DiffClass.allCases where seen.contains(klass) {
                lines.append("  \(klass.rawValue): \(klass.summary)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Machine-readable report for a drill record. Sorted keys + pretty printing so the
    /// artifact is reviewable and stable under `git diff`.
    public func jsonReport() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }
}

extension DiffReport {
    func textReportLines() -> [String] {
        var lines: [String] = []
        lines.append("=== \(baselineLabel) -> \(candidateLabel) ===")
        lines.append("  events: baseline \(baselineEventCount), candidate \(candidateEventCount)")
        for note in notes {
            lines.append("  note: \(note)")
        }
        if isEmpty {
            lines.append("  clean: no differences")
            return lines
        }
        let summary = countsByClass
            .map { "\($0.diffClass.rawValue)=\($0.count)" }
            .joined(separator: ", ")
        lines.append("  \(differences.count) difference(s) [\(summary)]")
        // Stable ordering: by class (declaration order), then by baseline line, then by
        // candidate line, then by field name.
        let ordered = differences.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            let li = DiffClass.allCases.firstIndex(of: l.diffClass) ?? 0
            let ri = DiffClass.allCases.firstIndex(of: r.diffClass) ?? 0
            if li != ri { return li < ri }
            if (l.baselineLine ?? Int.max) != (r.baselineLine ?? Int.max) {
                return (l.baselineLine ?? Int.max) < (r.baselineLine ?? Int.max)
            }
            if (l.candidateLine ?? Int.max) != (r.candidateLine ?? Int.max) {
                return (l.candidateLine ?? Int.max) < (r.candidateLine ?? Int.max)
            }
            if (l.field ?? "") != (r.field ?? "") { return (l.field ?? "") < (r.field ?? "") }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for difference in ordered {
            lines.append(contentsOf: difference.textLines())
        }
        return lines
    }
}

extension Difference {
    func textLines() -> [String] {
        var head = "  [\(diffClass.rawValue)]"
        if severity == .expected { head += "(expected)" }
        if let eventName { head += " \(eventName)" }
        if let field { head += "." + field }
        if baselineValue != nil || candidateValue != nil {
            head += ": \(baselineValue ?? "<absent>") -> \(candidateValue ?? "<absent>")"
        }
        var location: [String] = []
        if let baselineLine { location.append("baseline line \(baselineLine)") }
        if let candidateLine { location.append("candidate line \(candidateLine)") }
        if !location.isEmpty { head += " (" + location.joined(separator: ", ") + ")" }
        var lines = [head]
        if !detail.isEmpty {
            for detailLine in detail.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("      " + detailLine)
            }
        }
        return lines
    }
}
