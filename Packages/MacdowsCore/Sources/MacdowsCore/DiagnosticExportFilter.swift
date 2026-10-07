import Foundation

/// ADR-0024 D-8 (X-b): the diagnostic export's line filter as a DEFAULT-DENY grammar of registered
/// line shapes. A line is exported only if it matches a registered shape (source + tag + message
/// prefix + level floor); every other line is withheld and only counted, so a new log line is
/// never exported until someone registers its shape (the cost is visible as "N lines withheld").
///
/// Rules, applied in this order to every line:
///  1. PEM text is never exported, whatever shape it would match (the certificate itself is
///     represented by its fingerprint; ADR-0024 D-8 "PEM 全文").
///  2. The first registered shape that matches decides the line's class; no match -> withheld.
///  3. `.keyWitness` lines are exported only when the export includes account names and
///     key-witness lines (`a_include`), and withheld otherwise.
///  4. `.accountSegment(field:)` lines are exported with the value after `field` replaced by
///     `<account>` unless the export includes account names; with it, they are exported as is.
///  5. The home directory prefix is replaced by `~` everywhere (paths carry the local user name).
///
/// What can never be exported does not depend on `includeAccountAndKeyWitness`: passwords and their
/// derivatives, keychain attributes and launch-knob names / values have no registered shape at all,
/// and rule 1 is unconditional. The shapes registered here are the ones the bridge and the App emit
/// today; the export UI (settings slice) appends its own only by adding to `registered`.
public enum DiagnosticExportFilter {

    public enum Source: String, Sendable {
        /// The App's own `os.Logger` lines.
        case app
        /// FreeRDP / WinPR lines, as the WLog callback hands them over.
        case freerdp
    }

    /// WLog's levels, which the App's own lines are mapped onto.
    public enum Level: Int, Comparable, Sendable {
        case trace = 0, debug, info, warn, error, fatal

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum LineClass: Equatable, Sendable {
        case plain
        case accountSegment(field: String)
        case keyWitness
    }

    /// One registered line shape.
    public struct Shape: Equatable, Sendable {
        public let source: Source
        /// The logger tag. With `tagIsPrefix` the line's tag only has to start with it.
        public let tag: String
        public let tagIsPrefix: Bool
        /// The message must start with this (may be empty).
        public let messagePrefix: String
        /// Lines below this level do not match.
        public let minimumLevel: Level
        public let lineClass: LineClass

        public init(source: Source, tag: String, tagIsPrefix: Bool = false, messagePrefix: String, minimumLevel: Level, lineClass: LineClass) {
            self.source = source
            self.tag = tag
            self.tagIsPrefix = tagIsPrefix
            self.messagePrefix = messagePrefix
            self.minimumLevel = minimumLevel
            self.lineClass = lineClass
        }

        func matches(_ line: Line) -> Bool {
            guard line.source == source, line.level >= minimumLevel else { return false }
            let tagMatches = tagIsPrefix ? line.tag.hasPrefix(tag) : line.tag == tag
            return tagMatches && line.message.hasPrefix(messagePrefix)
        }
    }

    /// One collected log line.
    public struct Line: Equatable, Sendable {
        public let source: Source
        public let level: Level
        public let tag: String
        public let message: String

        public init(source: Source, level: Level, tag: String, message: String) {
            self.source = source
            self.level = level
            self.tag = tag
            self.message = message
        }
    }

    public struct Result: Equatable, Sendable {
        public let exported: [String]
        public let withheld: Int
    }

    /// The bridge's own WLog tag (`CLIENT_TAG("macdows")`).
    public static let bridgeTag = "com.freerdp.client.macdows"

    /// The Standard level's FreeRDP floor (ADR-0024 D-8: Standard = WLog WARN; Detailed stays
    /// disabled in v1, its pre-registered ceiling is INFO).
    public static let standardFreeRDPFloor: Level = .warn

    /// Registered shapes, most specific first (the first match wins).
    public static let registered: [Shape] = [
        // The bridge's key witness: one line per key event, a keystroke log while its knob is on.
        Shape(source: .freerdp, tag: bridgeTag, messagePrefix: "[key-witness] ", minimumLevel: .info, lineClass: .keyWitness),
        // The bridge's certificate rejection line: fingerprint, flags, route -- never the PEM.
        Shape(source: .freerdp, tag: bridgeTag, messagePrefix: "[cert] ", minimumLevel: .info, lineClass: .plain),
        // The reconnect driver's frozen judgement line.
        Shape(source: .app, tag: "Reconnect", messagePrefix: "[reconnect] ", minimumLevel: .info, lineClass: .plain),
        // The App's connect-path line, whose `user=` field is the account segment.
        Shape(source: .app, tag: "Connect", messagePrefix: "[connect] ", minimumLevel: .info, lineClass: .accountSegment(field: "user=")),
        // Any other FreeRDP / WinPR line at the Standard floor.
        Shape(source: .freerdp, tag: "com.", tagIsPrefix: true, messagePrefix: "", minimumLevel: standardFreeRDPFloor, lineClass: .plain),
    ]

    static let pemMarkers = ["-----BEGIN", "-----END"]

    public static func export(
        _ lines: [Line], includeAccountAndKeyWitness: Bool, homeDirectory: String?, shapes: [Shape] = registered
    ) -> Result {
        var exported: [String] = []
        var withheld = 0
        for line in lines {
            if pemMarkers.contains(where: { line.message.contains($0) }) {
                withheld += 1
                continue
            }
            guard let shape = shapes.first(where: { $0.matches(line) }) else {
                withheld += 1
                continue
            }
            var message = line.message
            switch shape.lineClass {
            case .plain:
                break
            case .keyWitness:
                guard includeAccountAndKeyWitness else {
                    withheld += 1
                    continue
                }
            case .accountSegment(let field):
                if !includeAccountAndKeyWitness {
                    message = redact(field: field, in: message)
                }
            }
            if let homeDirectory, !homeDirectory.isEmpty, homeDirectory != "/" {
                message = message.replacingOccurrences(of: homeDirectory, with: "~")
            }
            exported.append("\(line.source.rawValue) \(line.tag) \(message)")
        }
        return Result(exported: exported, withheld: withheld)
    }

    /// Every value following `field` (up to the next whitespace) becomes `<account>`.
    static func redact(field: String, in message: String) -> String {
        var out = ""
        var rest = Substring(message)
        while let range = rest.range(of: field) {
            out += rest[rest.startIndex..<range.upperBound]
            out += "<account>"
            rest = rest[range.upperBound...]
            if let end = rest.firstIndex(where: { $0.isWhitespace }) {
                rest = rest[end...]
            } else {
                rest = rest[rest.endIndex...]
            }
        }
        out += rest
        return out
    }
}
