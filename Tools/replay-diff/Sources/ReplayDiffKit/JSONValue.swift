import Foundation

/// A JSON number kept in the widest lossless form the source line actually used.
///
/// Why not just `Double`: `RailEvent`'s own doc comment records that real captures carry
/// `style` values like `2_147_483_648` (bit 31 set) and that `GfxMapSurfaceToWindow`'s
/// `windowId` is `UInt64` on the wire. A differ that rounded those through `Double` could
/// report two distinct 64-bit identifiers as equal, which is precisely the failure mode a
/// regression gate must not have.
///
/// Equality and hashing go through ``canonical`` so that `5`, `5` and `5.0` compare equal
/// regardless of which arm the decoder happened to take on each side of the diff.
public enum JSONNumber: Sendable {
    case signed(Int64)
    case unsigned(UInt64)
    case floating(Double)

    /// A stable textual form: the exact digits for integers, and an integral rendering for
    /// a floating value that is exactly integral and inside the range where `Double` still
    /// represents every integer (2^53).
    public var canonical: String {
        switch self {
        case .signed(let value):
            return String(value)
        case .unsigned(let value):
            return String(value)
        case .floating(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                return String(Int64(value))
            }
            return String(value)
        }
    }
}

extension JSONNumber: Hashable {
    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        lhs.canonical == rhs.canonical
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }
}

/// A structural JSON value.
///
/// The differ needs *field-level* access to every key on a probe line, including keys on
/// an event `MacdowsCore` does not model yet (`RailEventKind.unknown`). `RailEventKind` is
/// a closed enum of associated values with no field-name reflection, so the typed model
/// cannot answer "which keys does this line have, and what changed". This type carries the
/// structural half; ``ReplayStream`` joins it back onto MacdowsCore's typed parse so the
/// two never disagree about which lines are valid. See ``ReplayStream/parse(contents:label:)``.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Order matters: `Bool` is tried before the integer arms because Foundation's
        // JSONDecoder is strict in both directions (it will not read `1` as `Bool`, nor
        // `true` as `Int64`), and `Int64` before `UInt64` so that the common signed
        // fields (`windowOffsetX`, `posY`, ...) keep their sign rather than failing.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(.signed(value))
        } else if let value = try? container.decode(UInt64.self) {
            self = .number(.unsigned(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(.floating(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not a JSON null/bool/number/string/array/object"
            )
        }
    }
}

extension JSONValue {
    /// A deterministic one-line rendering, used in diff output and as the identity-tuple
    /// text. Object keys are sorted so two structurally equal objects always render
    /// identically regardless of `Dictionary` iteration order.
    public var displayString: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.canonical
        case .string(let value):
            return "\"\(value)\""
        case .array(let values):
            return "[" + values.map(\.displayString).joined(separator: ",") + "]"
        case .object(let fields):
            let body = fields.keys.sorted()
                .map { "\($0):\(fields[$0]!.displayString)" }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    /// The integer this value carries, if it is an *integral* number — `nil` for a string,
    /// a bool, a container, or a fractional number.
    ///
    /// Used only by identifier canonicalization, which must not touch string or fractional
    /// fields: an ordinal handed to a fractional value would be a claim that a fraction is
    /// a kernel handle. Every identifier is an integer on the wire, so the fractional arm
    /// is unreachable against a real probe — the guard is here because this accessor is the
    /// canonicalizer's only type filter, and a silently-widened filter is how the
    /// canonicalizer would start renaming fields it has no business touching.
    public var integerCanonicalForm: String? {
        guard case .number(let number) = self else { return nil }
        if case .floating(let value) = number {
            guard value.isFinite, value == value.rounded() else { return nil }
        }
        return number.canonical
    }
}

extension JSONValue {
    /// Decodes one JSONL line into its top-level field map. Throws for anything that is not
    /// a JSON *object* (a bare array or scalar line is not a probe event). Nested objects
    /// and arrays inside a field decode and compare normally — only the top level has to be
    /// an object.
    static func decodeObject(from data: Data) throws -> [String: JSONValue] {
        let decoder = JSONDecoder()
        return try decoder.decode([String: JSONValue].self, from: data)
    }
}
