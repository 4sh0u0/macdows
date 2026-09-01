import Foundation
import MacdowsCore

/// One event line, as the differ sees it: MacdowsCore's verdict on whether the line is a
/// well-formed `RailEvent` and whether it models the event kind, plus the structural field
/// map the differ actually compares.
public struct ReplayRecord: Sendable, Equatable {
    /// 1-based line number in the source file, straight from
    /// ``MacdowsCore/RailEvent/parseJSONL(_:)``.
    public let lineNumber: Int
    /// The `ev` discriminator verbatim (e.g. `WindowCreate`, `GfxMapSurfaceToScaledWindow`).
    public let eventName: String
    /// Every key on the line except `ev`. Includes keys MacdowsCore does not model.
    public let fields: [String: JSONValue]
    /// `false` when MacdowsCore decoded this line as `RailEventKind.unknown` — i.e. a
    /// newer probe emitted an event name this package predates. Not a difference on its
    /// own (both sides may carry it); surfaced as a report note so the operator knows the
    /// typed model is behind the capture.
    public let isModelled: Bool

    public init(lineNumber: Int, eventName: String, fields: [String: JSONValue], isModelled: Bool) {
        self.lineNumber = lineNumber
        self.eventName = eventName
        self.fields = fields
        self.isModelled = isModelled
    }
}

/// A line one side could not read. Kept per side: a gate that silently skipped a line it
/// could not parse would report "no differences" for a file it never fully read.
public struct ReplayParseFailure: Sendable, Equatable {
    public let lineNumber: Int
    public let reason: String

    public init(lineNumber: Int, reason: String) {
        self.lineNumber = lineNumber
        self.reason = reason
    }
}

/// One side of a diff: a parsed `rail-probe` JSONL capture.
public struct ReplayStream: Sendable, Equatable {
    /// Human label for output (a file's base name, or a caller-supplied fixture name).
    /// Never a value read out of the capture, so a label can never carry host data.
    public let label: String
    public let records: [ReplayRecord]
    public let parseFailures: [ReplayParseFailure]

    public init(label: String, records: [ReplayRecord], parseFailures: [ReplayParseFailure]) {
        self.label = label
        self.records = records
        self.parseFailures = parseFailures
    }

    /// Event names MacdowsCore decoded as `RailEventKind.unknown`.
    public var unmodelledEventNames: Set<String> {
        Set(records.lazy.filter { !$0.isModelled }.map(\.eventName))
    }
}

extension ReplayStream {
    /// Parses a JSONL capture the same way the replay regression gate does.
    ///
    /// MacdowsCore's ``MacdowsCore/RailEvent/parseJSONL(_:)`` is the *authority* on line
    /// validity and on event-kind modelling — this deliberately does not reimplement the
    /// envelope rules (adr/0008 §5's "absent means 0/false" replay-compat rule lives
    /// there, and a second copy would be free to drift). What it adds is a structural
    /// re-read of the same line so the differ can name individual fields, which the closed
    /// `RailEventKind` enum cannot express.
    ///
    /// The two halves are joined on line number, so they can never disagree about which
    /// lines exist: a line MacdowsCore rejected never reaches field comparison, and a line
    /// MacdowsCore accepted but this cannot re-read structurally (impossible in practice —
    /// the typed decode already proved it is a JSON object) becomes an explicit failure
    /// rather than a silently dropped event.
    public static func parse(contents: String, label: String) -> ReplayStream {
        let (events, typedFailures) = RailEvent.parseJSONL(contents)

        var rawByLine: [Int: [String: JSONValue]] = [:]
        var structuralFailures: [Int: String] = [:]
        // Identical line splitting to parseJSONL(_:) so the line numbers line up exactly.
        var lineNumber = 0
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Unreachable for a Swift `String` (it is always valid UTF-8), and kept only for
            // exact structural parity with `RailEvent.parseJSONL`'s own loop — the two must
            // stay line-for-line identical or the line numbers they produce could drift.
            guard let data = line.data(using: .utf8) else {
                structuralFailures[lineNumber] = "not valid UTF-8"
                continue
            }
            do {
                rawByLine[lineNumber] = try JSONValue.decodeObject(from: data)
            } catch {
                structuralFailures[lineNumber] = "line is not a JSON object, or carries a value no JSON type can hold"
            }
        }

        var records: [ReplayRecord] = []
        var failures: [ReplayParseFailure] = typedFailures.map {
            // The raw line text is deliberately *not* carried into the failure: a
            // malformed line from a live re-record could contain anything, and this
            // string ends up in an evidence artifact.
            ReplayParseFailure(lineNumber: $0.lineNumber, reason: "not a well-formed RailEvent")
        }
        records.reserveCapacity(events.count)

        for event in events {
            // Unreachable today — `RailEvent.parseJSONL` assigns `lineNumber` on every
            // successful decode — but `continue` here would be a silent drop, the exact
            // thing the guarantee above forbids, so it records a failure like its two
            // siblings below rather than trusting an invariant it does not own.
            guard let line = event.lineNumber else {
                failures.append(
                    ReplayParseFailure(
                        lineNumber: 0,
                        reason: "event decoded but carried no line number — cannot be located or compared"
                    )
                )
                continue
            }
            guard var fields = rawByLine[line] else {
                failures.append(
                    ReplayParseFailure(
                        lineNumber: line,
                        reason: structuralFailures[line] ?? "line could not be read structurally"
                    )
                )
                continue
            }
            guard case .string(let name)? = fields[Self.discriminatorKey] else {
                // Unreachable in practice: RailEvent's envelope decode already required a
                // string `ev`. Handled rather than force-unwrapped so a future envelope
                // change degrades into a reported failure, not a crash inside a gate.
                failures.append(ReplayParseFailure(lineNumber: line, reason: "missing string `ev` discriminator"))
                continue
            }
            fields.removeValue(forKey: Self.discriminatorKey)
            let modelled: Bool
            if case .unknown = event.kind { modelled = false } else { modelled = true }
            records.append(
                ReplayRecord(lineNumber: line, eventName: name, fields: fields, isModelled: modelled)
            )
        }

        failures.sort { $0.lineNumber < $1.lineNumber }
        return ReplayStream(label: label, records: records, parseFailures: failures)
    }

    /// Convenience for an on-disk capture. The label is the file's base name only — never
    /// the full path, which on a maintainer machine contains a home directory.
    public static func parse(fileAt url: URL) throws -> ReplayStream {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents: contents, label: url.lastPathComponent)
    }

    static let discriminatorKey = "ev"
}
