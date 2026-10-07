import Foundation

/// ADR-0024 D-3: a certificate fingerprint -- the SHA-256 of the leaf certificate's DER -- in its
/// one internal form, 64 lower-case hexadecimal digits with no separators.
///
/// Three forms, kept apart on purpose:
///  - the CANONICAL form (`canonical`) is what is stored (pin and preset, `PinRecord`), compared
///    and handed to the bridge's trust snapshot. The bridge computes the presented fingerprint
///    with FreeRDP's own `freerdp_certificate_get_fingerprint_by_hash_ex(cert, "sha256", FALSE)`,
///    which already produces this form (lower-case `%02x`, no separator);
///  - the DISPLAY form (`displayLines`) is upper case, colon-separated, eight bytes per line, four
///    lines (UI-1 spec §5.2);
///  - the INPUT form is whatever a user pastes into the Host Editor's preset field: colons,
///    spaces, hyphens and mixed case are accepted; after normalisation it must be exactly 32
///    bytes. A 20-byte value is refused with its own error (a SHA-1 thumbprint, ADR-0024 U-4).
///
/// Equality is equality of the canonical form, so two fingerprints that differ only in case or
/// separators can never compare unequal, and a case-sensitive comparison cannot creep in at a
/// call site.
public struct CertificateFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    /// SHA-256 digest length in bytes.
    public static let byteCount = 32
    /// SHA-1 digest length in bytes; refused with `ParseError.sha1Length`.
    public static let sha1ByteCount = 20

    /// 64 lower-case hexadecimal digits.
    public let canonical: String

    /// Why an input string is not a SHA-256 fingerprint.
    public enum ParseError: Error, Equatable, Sendable {
        /// Nothing but separators (or nothing at all).
        case empty
        /// A character that is neither a hexadecimal digit nor an accepted separator.
        case invalidCharacter
        /// An odd number of hexadecimal digits.
        case oddDigitCount
        /// 20 bytes: a SHA-1 thumbprint, not the SHA-256 this app pins (ADR-0024 U-4).
        case sha1Length
        /// Any other whole number of bytes.
        case wrongLength(bytes: Int)
    }

    /// Separators accepted between hexadecimal digits in user input.
    public static let acceptedSeparators: Set<Character> = [":", " ", "-", "\t", "\n", "\r"]

    /// Parses user input (any case, `:` / space / `-` separators) into a fingerprint.
    public static func parse(_ input: String) -> Result<CertificateFingerprint, ParseError> {
        var digits: [Character] = []
        digits.reserveCapacity(64)
        for character in input {
            if acceptedSeparators.contains(character) { continue }
            guard character.isASCII, character.isHexDigit else { return .failure(.invalidCharacter) }
            digits.append(Character(character.lowercased()))
        }
        guard !digits.isEmpty else { return .failure(.empty) }
        guard digits.count % 2 == 0 else { return .failure(.oddDigitCount) }
        let bytes = digits.count / 2
        if bytes == sha1ByteCount { return .failure(.sha1Length) }
        guard bytes == byteCount else { return .failure(.wrongLength(bytes: bytes)) }
        return .success(CertificateFingerprint(uncheckedCanonical: String(digits)))
    }

    /// The canonical form only: exactly 64 hexadecimal digits, no separators (either case is
    /// accepted and folded to lower case). Used for values read back from storage or from the
    /// bridge, which must never need the lenient input parser.
    public init?(canonical: String) {
        guard canonical.count == Self.byteCount * 2,
              canonical.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return nil }
        self.canonical = canonical.lowercased()
    }

    private init(uncheckedCanonical: String) {
        canonical = uncheckedCanonical
    }

    /// Upper-case, colon-separated, eight bytes per line, four lines (UI-1 spec §5.2).
    public var displayLines: [String] {
        let pairs = stride(from: 0, to: canonical.count, by: 2).map { offset -> String in
            let start = canonical.index(canonical.startIndex, offsetBy: offset)
            return String(canonical[start..<canonical.index(start, offsetBy: 2)]).uppercased()
        }
        return stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: ":") }
    }

    /// The four display lines joined with newlines.
    public var displayString: String { displayLines.joined(separator: "\n") }

    /// The first eight bytes in display form, for the recent-connections log (ADR-0024 D-6).
    public var shortDisplay: String { displayLines.first ?? "" }

    public var description: String { canonical }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CertificateFingerprint(canonical: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a canonical SHA-256 fingerprint")
        }
        self = value
    }
}
