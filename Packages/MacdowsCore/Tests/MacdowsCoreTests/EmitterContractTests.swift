import Foundation
import MacdowsCore
import Testing

// The emitter JSON-key contract (registered by review p1-r2 as a standing structural gap):
// `rail-probe.c` writes every JSONL line through printf format strings, and nothing
// mechanized tied those key names to `RailEvent`'s decoders — renaming a key or an `ev`
// name in C would go green everywhere and only explode on the next live re-record.
//
// This suite closes the gap by reading the format strings themselves: it extracts every
// `log_event(p, "<Name>", "<fmt>", ...)` call site from the C source, substitutes dummy
// values for the printf conversions, assembles each into a full JSONL line exactly the way
// `log_event` does (`{"t_ms":…,"tid":"…","ev":"…",<payload>}`), and feeds the lot to the
// production `RailEvent.parseJSONL`. A renamed/removed/retyped key becomes a parse
// failure; a renamed event name decodes as `.unknown` — both assert red here.
//
// Scope boundary, registered: the CRBridge WLog twins (CRSession.mm's caps lines) share
// the vocabulary by review discipline but emit human-readable WLog text, not gate-consumed
// JSONL — they are outside this contract. The other direction (decoder requiring a key the
// emitter never wrote) is covered by construction: the synthesized lines carry exactly the
// emitted keys, so an over-demanding decoder fails the same assertion.
@Suite("rail-probe emitter JSON-key contract")
struct EmitterContractTests {
    /// One extracted `log_event` call site: the event name(s) (two for the
    /// `isNew ? "WindowCreate" : "WindowUpdate"` ternary) and the concatenated format
    /// string (`nil` payload for the envelope-only `NULL` sites).
    struct EmitSite: Equatable {
        var names: [String]
        var format: String?
    }

    static let probeSource: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MacdowsCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // MacdowsCore/
            .deletingLastPathComponent() // Packages/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tools/rail-probe/rail-probe.c")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    // MARK: - C-source scanning

    /// Extracts every `log_event(p, <name-expr>, <fmt-expr>, …)` call. String-literal-aware
    /// and paren-depth-aware, so casts in the vararg tail and parens inside format strings
    /// cannot derail it. `PRIX32`-style macro tokens between adjacent literals are resolved
    /// the way the C preprocessor would (`"0x%08" PRIX32 "…"` → `0x%08X…`).
    static func extractEmitSites(from source: String) -> [EmitSite] {
        var sites: [EmitSite] = []
        let chars = Array(source)
        let priMap: [String: String] = [
            "PRIu32": "u", "PRId32": "d", "PRIx32": "x", "PRIX32": "X",
            "PRIu64": "llu", "PRId64": "lld", "PRIx64": "llx", "PRIX64": "llX",
        ]
        var search = source.startIndex
        while let call = source.range(of: "log_event(", range: search..<source.endIndex) {
            search = call.upperBound
            var i = source.distance(from: source.startIndex, to: call.upperBound)
            var depth = 1
            // Expression slices at depth 1, split on top-level commas until the call closes.
            var expressions: [[Character]] = [[]]
            scan: while i < chars.count {
                let c = chars[i]
                switch c {
                case "\"":
                    // Copy the whole literal, escapes included, without depth/comma logic.
                    expressions[expressions.count - 1].append(c)
                    i += 1
                    while i < chars.count {
                        expressions[expressions.count - 1].append(chars[i])
                        if chars[i] == "\\" { // escaped char: copy it blindly
                            i += 1
                            if i < chars.count { expressions[expressions.count - 1].append(chars[i]) }
                        } else if chars[i] == "\"" {
                            break
                        }
                        i += 1
                    }
                case "(":
                    depth += 1
                    expressions[expressions.count - 1].append(c)
                case ")":
                    depth -= 1
                    if depth == 0 { break scan }
                    expressions[expressions.count - 1].append(c)
                case ",":
                    if depth == 1 { expressions.append([]) } else { expressions[expressions.count - 1].append(c) }
                default:
                    expressions[expressions.count - 1].append(c)
                }
                i += 1
            }
            guard expressions.count >= 3 else { continue } // not a call shape we know
            let names = stringLiterals(in: String(expressions[1]))
            guard !names.isEmpty else { continue } // first arg is `p`, second must carry names
            let fmtExpr = String(expressions[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if fmtExpr == "NULL" {
                sites.append(EmitSite(names: names, format: nil))
                continue
            }
            // Concatenate literals; resolve PRI* identifier tokens between them.
            var format = ""
            var rest = Substring(fmtExpr)
            while !rest.isEmpty {
                rest = rest.drop(while: { $0.isWhitespace })
                if rest.first == "\"" {
                    guard let (literal, remainder) = leadingStringLiteral(of: rest) else { break }
                    format += literal
                    rest = remainder
                } else {
                    let ident = rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                    guard !ident.isEmpty, let conversion = priMap[String(ident)] else { break }
                    format += conversion
                    rest = rest.dropFirst(ident.count)
                }
            }
            sites.append(EmitSite(names: names, format: format))
        }
        return sites
    }

    /// Every C string literal inside `expression`, unescaped (`\"` → `"`).
    private static func stringLiterals(in expression: String) -> [String] {
        var out: [String] = []
        var rest = Substring(expression)
        while let start = rest.firstIndex(of: "\"") {
            guard let (literal, remainder) = leadingStringLiteral(of: rest[start...]) else { break }
            out.append(literal)
            rest = remainder
        }
        return out
    }

    /// Parses one C string literal at the head of `text` (which must start with `"`),
    /// returning its unescaped contents and the remainder after the closing quote.
    private static func leadingStringLiteral(of text: Substring) -> (String, Substring)? {
        var rest = text.dropFirst() // consume opening quote
        var literal = ""
        while let c = rest.first {
            rest = rest.dropFirst()
            if c == "\\" {
                guard let escaped = rest.first else { return nil }
                rest = rest.dropFirst()
                literal.append(escaped == "n" ? "\n" : escaped)
            } else if c == "\"" {
                return (literal, rest)
            } else {
                literal.append(c)
            }
        }
        return nil
    }

    // MARK: - Dummy-value substitution

    /// Bare (unquoted) `%s` conversions produce a raw JSON value, so the dummy must match
    /// the decoder's expected type. Keyed by the JSON key preceding the conversion; the
    /// contract test *fails* on an unmapped bare `%s` rather than guessing, so a new bare
    /// site forces a conscious entry here.
    static let bareStringDummies: [String: String] = [
        "isMoveSizeStart": "true", // emitter writes the literal `true`/`false`
        "counts": #"{"x":1}"#, // CodecStats: a JSON object of per-codec counters
    ]

    struct SubstitutionProblem: Error { let message: String }

    /// Replaces every printf conversion in `format` with a dummy, returning the JSON
    /// payload fragment, or a description of the first unmapped bare `%s`.
    static func substituteDummies(in format: String) -> Result<String, SubstitutionProblem> {
        var payload = ""
        var rest = Substring(format)
        while let percent = rest.firstIndex(of: "%") {
            payload += rest[..<percent]
            var conv = rest[rest.index(after: percent)...]
            var length = ""
            while let c = conv.first, "0123456789.#-+ l".contains(c) {
                length.append(c)
                conv = conv.dropFirst()
            }
            guard let kind = conv.first else { return .failure(SubstitutionProblem(message: "dangling % in: \(format)")) }
            rest = conv.dropFirst()
            switch kind {
            case "u", "d", "i", "x", "o":
                payload += "1"
            case "X":
                payload += length.contains("08") ? "00000001" : "1"
            case "s":
                if payload.hasSuffix("\"") { // quoted string value: …":"%s"
                    payload += "x"
                } else {
                    let key = payload.split(separator: "\"").dropLast().last.map(String.init) ?? ""
                    guard let dummy = bareStringDummies[key] else {
                        return .failure(SubstitutionProblem(message: "bare %s after key \"\(key)\" has no dummy mapping — extend bareStringDummies"))
                    }
                    payload += dummy
                }
            default:
                return .failure(SubstitutionProblem(message: "unhandled conversion %\(length)\(kind) in: \(format)"))
            }
        }
        payload += rest
        return .success(payload)
    }

    // MARK: - The contract

    /// Extractor-vacuity guards first (an extractor that silently finds nothing — or
    /// silently drops sites — would turn every assertion below vacuous, the "unfailable
    /// test" family), then the join: every synthesized line must parse with zero failures
    /// and land on a modelled kind.
    ///
    /// Value scope (review emitter-r1 m3): the dummies pin **key names and coarse JSON
    /// types only**, never value ranges — a width/signedness regression on the Swift side
    /// (e.g. a field that must hold `2_147_483_648` reverting to `Int32`) is invisible to
    /// a dummy of `1` and stays the decode-tests' job.
    @Test("every emitted event round-trips through the production parser under its own keys")
    func emitterKeysSatisfyTheDecoder() throws {
        try #require(!Self.probeSource.isEmpty, "rail-probe.c not found relative to #filePath — path rot?")
        let sites = Self.extractEmitSites(from: Self.probeSource)
        let names = Set(sites.flatMap(\.names))
        // Vacuity guards. Site count is pinned against an independent second measure of the
        // C source (raw occurrence count of `log_event(`, minus the function's own
        // definition) so a partial extractor regression cannot silently drop sites
        // (review emitter-r1 I2 — the two `guard … continue` paths in the scanner).
        let occurrences = Self.probeSource.components(separatedBy: "log_event(").count - 1
        #expect(sites.count == occurrences - 1, "scanner extracted \(sites.count) of \(occurrences - 1) call sites")
        try #require(names.count >= 35, "extractor found only \(names.count) event names — scanner rot?")
        try #require(names.contains("WindowCreate") && names.contains("WindowUpdate"))
        // The envelope's three keys come from `log_event`'s two fprintf templates in C —
        // extract and pin them so renaming `"ev"` in C reds here (review emitter-r1 I1;
        // without this the Swift-side envelope literal below would be a parallel truth).
        let envelopeTemplates = Self.probeSource.components(separatedBy: "fprintf(p->out, ")
            .dropFirst().compactMap { chunk in Self.leadingStringLiteral(of: Substring(chunk))?.0 }
        try #require(envelopeTemplates.count == 2, "log_event's two envelope fprintf sites not found")
        for template in envelopeTemplates {
            #expect(template.hasPrefix(#"{"t_ms":%llu,"tid":"%s","ev":"%s""#),
                    "envelope template drifted: \(template)")
        }
        // Extractor-content canary: WindowCreate's exact key list, pinned against the C
        // format string. If this line moves, the emitter contract moved with it — update
        // deliberately, alongside the consumers named in the file header.
        let windowOrder = try #require(sites.first { $0.names.contains("WindowCreate") }?.format)
        #expect(windowOrder == "\"windowId\":%u,\"fieldFlags\":%u,\"windowOffsetX\":%d,\"windowOffsetY\":%d,"
            + "\"windowWidth\":%u,\"windowHeight\":%u,\"numVisibilityRects\":%u,"
            + "\"style\":%u,\"styleEx\":%u,\"show\":%u,\"title\":\"%s\"")

        var lines: [String] = []
        var lineEvents: [String] = []
        for site in sites {
            for name in site.names {
                var line = #"{"t_ms":0,"tid":"0x1","ev":"\#(name)""#
                if let format = site.format {
                    switch Self.substituteDummies(in: format) {
                    case .success(let payload): line += "," + payload
                    case .failure(let reason): Issue.record("\(name): \(reason)"); continue
                    }
                }
                line += "}"
                lines.append(line)
                lineEvents.append(name)
            }
        }

        let (events, failures) = RailEvent.parseJSONL(lines.joined(separator: "\n"))
        for failure in failures {
            Issue.record("emitted keys for \(lineEvents[failure.lineNumber - 1]) no longer satisfy the decoder: \(failure.error) — line: \(failure.line)")
        }
        #expect(failures.isEmpty)
        for event in events {
            if case .unknown(let ev) = event.kind {
                let origin = event.lineNumber.map { lineEvents[$0 - 1] } ?? "?"
                Issue.record("emitter event \(ev) (from \(origin)'s line) is not modelled by RailEventKind — register it or record the exemption here")
            }
        }
    }
}
