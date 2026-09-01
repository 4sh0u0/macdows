import Foundation
import ReplayDiffKit

/// Hand-rolled argv parsing.
///
/// Deliberately not swift-argument-parser: that would be the package's only remote
/// dependency, and the whole point of this tool is that `Scripts/upgrade-gate.sh` can
/// build and run it on a machine with no network. See `Package.swift`'s header.
struct CommandLineOptions {
    enum OutputFormat: String {
        case text
        case json
    }

    var baselinePath: String = ""
    var candidatePath: String = ""
    var format: OutputFormat = .text
    var differOptions = DifferOptions()
    var failOnExpected = false

    enum ParseOutcome {
        case run(CommandLineOptions)
        case printHelp
        case printLegend
    }

    enum ParseError: Error, CustomStringConvertible {
        case unknownOption(String)
        case missingValue(String)
        case badValue(option: String, value: String)
        case wrongPositionalCount(Int)
        case knownDifferenceTableUnreadable(path: String, reason: String)

        var description: String {
            switch self {
            case .unknownOption(let option):
                return "unknown option: \(option)"
            case .missingValue(let option):
                return "\(option) requires a value"
            case .badValue(let option, let value):
                return "invalid value for \(option): \(value)"
            case .wrongPositionalCount(let count):
                return "expected exactly 2 positional arguments (baseline, candidate), got \(count)"
            case .knownDifferenceTableUnreadable(let path, let reason):
                return "cannot read known-difference table \(path): \(reason)"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> ParseOutcome {
        var options = CommandLineOptions()
        var positionals: [String] = []
        var extraIgnoredFields: Set<String> = []
        var extraRedactedFields: Set<String> = []
        var comparedTimingFields = false
        var tableOverride: KnownDifferenceTable?

        var index = 0
        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(option) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .printHelp
            case "--legend":
                return .printLegend
            case "--format":
                let raw = try value(for: argument)
                guard let format = OutputFormat(rawValue: raw) else {
                    throw ParseError.badValue(option: argument, value: raw)
                }
                options.format = format
            case "--order-tolerance":
                let raw = try value(for: argument)
                guard let tolerance = Int(raw), tolerance >= 0 else {
                    throw ParseError.badValue(option: argument, value: raw)
                }
                options.differOptions.orderTolerance = tolerance
            case "--lane-order-tolerance":
                let raw = try value(for: argument)
                guard let tolerance = Int(raw), tolerance >= 0 else {
                    throw ParseError.badValue(option: argument, value: raw)
                }
                options.differOptions.laneOrderTolerance = tolerance
            case "--max-value-length":
                let raw = try value(for: argument)
                guard let length = Int(raw), length >= 0 else {
                    throw ParseError.badValue(option: argument, value: raw)
                }
                options.differOptions.maxValueLength = length
            case "--ignore-field":
                extraIgnoredFields.insert(try value(for: argument))
            case "--redact-field":
                extraRedactedFields.insert(try value(for: argument))
            case "--compare-timing-fields":
                comparedTimingFields = true
            case "--no-canonical-ids":
                options.differOptions.canonicalizeIdentifiers = false
            case "--fail-on-expected":
                options.failOnExpected = true
            case "--known-difference-table":
                let path = try value(for: argument)
                do {
                    tableOverride = try KnownDifferenceTable.load(fromJSONAt: URL(fileURLWithPath: path))
                } catch {
                    throw ParseError.knownDifferenceTableUnreadable(
                        path: URL(fileURLWithPath: path).lastPathComponent,
                        reason: "\(error)"
                    )
                }
            default:
                if argument.hasPrefix("-") && argument != "-" {
                    throw ParseError.unknownOption(argument)
                }
                positionals.append(argument)
            }
            index += 1
        }

        guard positionals.count == 2 else {
            throw ParseError.wrongPositionalCount(positionals.count)
        }
        options.baselinePath = positionals[0]
        options.candidatePath = positionals[1]

        var policy = FieldPolicy.default
        if comparedTimingFields {
            // Only `tid` stays ignored: it is a raw pthread address that no re-record can
            // reproduce, so comparing it is never informative. `t_ms`/`sinceConnectMs`
            // become comparable, which is only useful for a same-session A/B of two
            // post-processed copies of one capture.
            policy.ignoredFields = ["tid"]
        }
        policy.ignoredFields.formUnion(extraIgnoredFields)
        policy.redactedFields.formUnion(extraRedactedFields)
        options.differOptions.fieldPolicy = policy
        if let tableOverride {
            options.differOptions.knownDifferenceTable = KnownDifferenceTable.preSeeded.merging(tableOverride)
        }
        return .run(options)
    }

    static let helpText = """
        replay-diff — semantic diff of two rail-probe JSONL captures.

        USAGE
          replay-diff [options] <baseline> <candidate>

          <baseline>/<candidate> are either two .jsonl captures or two directories of
          them. Directory mode pairs files by base name; a file present on one side only
          is reported as unpaired, never silently skipped.

        WHAT "SEMANTIC" MEANS
          Timestamps (t_ms), thread ids (tid) and run duration (sinceConnectMs) are
          ignored. Session-scoped handles (windowId/ownerWindowId/activeWindowId/
          windowIdMarker, surfaceId, notifyIconId) are compared as per-side
          first-appearance ordinals, so a re-record's fresh HWNDs do not read as changes
          while "these events are about the same window" still does. Events are matched
          per event type and identity tuple, so cross-type reordering is tolerated
          exactly. Residual movement is checked twice: within the event's own producer
          lane (main / gfx / server, derived from the ev name and verified against the
          frozen captures) at --lane-order-tolerance, because one lane is one thread and
          its order is causal; and across lanes at --order-tolerance, because interleaving
          between three concurrent producers is real run-to-run noise.

        OPTIONS
          --format text|json        Output format (default: text).
          --order-tolerance N       Matched positions an event may move ACROSS lanes
                                    (default: 2; 0 = exact order).
          --lane-order-tolerance N  Positions an event may move WITHIN its own producer
                                    lane (default: 0 — a lane is one thread).
          --no-canonical-ids        Compare raw handle values instead of ordinals. For a
                                    same-session A/B only: across a re-record it makes
                                    every handle differ.
          --compare-timing-fields   Stop ignoring t_ms/sinceConnectMs (tid stays ignored).
          --ignore-field NAME       Additionally ignore NAME (repeatable).
          --redact-field NAME       Additionally redact NAME in output (repeatable).
          --max-value-length N      Truncate rendered values at N chars (default: 120;
                                    0 disables truncation entirely).
          --known-difference-table FILE JSON array of known-local-difference explanations,
                                    merged over the built-in table. NOT repeatable — the
                                    last one given wins; put every entry in the one file.
                                    A file naming the same event twice is refused.
                                    Fields: eventName, expectedSide, cause, reference,
                                    plus optional supersedes and newFields. See --legend.

        WHAT AN ENTRY DOES, AND DOES NOT, EXCUSE
          An entry excuses the PRESENCE of an event type on one side. It never excuses what
          is inside it. When `supersedes` names a counterpart, the two one-sided occurrence
          sets are matched by identity tuple and field-compared like any other pair — counts
          must correspond, unmatched identities are regressions, and every field except the
          declared `newFields` is compared normally.
          --fail-on-expected        Exit non-zero even for explained differences.
          --legend                  Print the difference-class vocabulary and exit.
          -h, --help                This text.

        EXIT CODES
          0  no differences, or only differences explained by the known-difference table
          1  at least one unexplained difference (gate failure)
          2  the gate could not run (bad arguments, unreadable input)

        REDACTION
          Certificate/host fields (host, commonName, subject, issuer, fingerprint) are
          compared but never printed — this tool's output is meant to be attached to a
          drill record. Raw source lines are never echoed.

        NETWORK
          None. This tool never opens a socket and never needs a live host.
        """

    static var legendText: String {
        var lines = ["replay-diff difference classes:", ""]
        for klass in DiffClass.allCases {
            lines.append("  \(klass.rawValue)")
            lines.append("      \(klass.summary)")
            lines.append("      severity: \(klass.defaultSeverity.rawValue)")
        }
        lines.append("")
        lines.append("Built-in known-difference entries (--known-difference-table adds more):")
        for entry in KnownDifferenceTable.preSeeded.entries.values.sorted(by: { $0.eventName < $1.eventName }) {
            lines.append("  \(entry.eventName) — expected on the \(entry.expectedSide.rawValue) side")
            if let supersedes = entry.supersedes {
                lines.append(
                    "      supersedes: \(supersedes) — its absence from the"
                        + " \(entry.expectedSide.rawValue) side is excused too, but ONLY when this event"
                        + " actually appears there in the same comparison; a lone disappearance stays a"
                        + " regression. The two occurrence sets are then MATCHED and field-compared:"
                        + " presence is excused, payload and identity are not."
                )
                if !entry.newFields.isEmpty {
                    lines.append(
                        "      newFields: \(entry.newFields.sorted().joined(separator: ", "))"
                            + " — exempt from field comparison only when absent on the counterpart side;"
                            + " counted and reported once per field."
                    )
                }
            }
            lines.append("      \(entry.cause)")
            lines.append("      reference: \(entry.reference)")
        }
        return lines.joined(separator: "\n")
    }
}
