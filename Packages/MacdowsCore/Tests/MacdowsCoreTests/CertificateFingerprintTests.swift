import Foundation
import Testing

@testable import MacdowsCore

/// ADR-0024 D-10 ②: fingerprint normalisation, display form and preset parsing.
@Suite("CertificateFingerprint (ADR-0024 D-3)")
struct CertificateFingerprintTests {
    static let lower = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    @Test("colons, spaces, hyphens and mixed case all normalise to the 64-digit lower-case form")
    func separatorsAndCaseNormalise() throws {
        let colon = "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:aa:BB:cc:DD:ee:FF"
        let spaced = "0011 2233 4455 6677 8899 AABB CCDD EEFF\n0011-2233-4455-6677-8899-aabb-ccdd-eeff"
        for input in [Self.lower, Self.lower.uppercased(), colon, spaced] {
            let parsed = try CertificateFingerprint.parse(input).get()
            #expect(parsed.canonical == Self.lower, "\(input)")
        }
    }

    @Test("equality is canonical equality: case never matters")
    func equalityIgnoresInputCase() throws {
        let a = try CertificateFingerprint.parse(Self.lower).get()
        let b = try CertificateFingerprint.parse(Self.lower.uppercased()).get()
        #expect(a == b)
        #expect(CertificateFingerprint(canonical: Self.lower.uppercased()) == a)
    }

    @Test("20 bytes is refused as SHA-1; other lengths, odd digit counts, stray characters and empty input are refused")
    func refusals() {
        let sha1 = String(repeating: "ab", count: 20)
        #expect(CertificateFingerprint.parse(sha1) == .failure(.sha1Length))
        #expect(CertificateFingerprint.parse(String(repeating: "ab", count: 31)) == .failure(.wrongLength(bytes: 31)))
        #expect(CertificateFingerprint.parse(String(repeating: "ab", count: 33)) == .failure(.wrongLength(bytes: 33)))
        #expect(CertificateFingerprint.parse(String(Self.lower.dropLast())) == .failure(.oddDigitCount))
        #expect(CertificateFingerprint.parse(Self.lower.replacingOccurrences(of: "ff", with: "fg")) == .failure(.invalidCharacter))
        #expect(CertificateFingerprint.parse(" : - ") == .failure(.empty))
        #expect(CertificateFingerprint.parse("") == .failure(.empty))
        #expect(CertificateFingerprint(canonical: "00:11") == nil)
        #expect(CertificateFingerprint(canonical: String(Self.lower.dropLast(2))) == nil)
    }

    @Test("display form: upper case, colon separated, eight bytes per line, four lines")
    func displayForm() throws {
        let fp = try CertificateFingerprint.parse(Self.lower).get()
        #expect(fp.displayLines == [
            "00:11:22:33:44:55:66:77",
            "88:99:AA:BB:CC:DD:EE:FF",
            "00:11:22:33:44:55:66:77",
            "88:99:AA:BB:CC:DD:EE:FF",
        ])
        #expect(fp.shortDisplay == "00:11:22:33:44:55:66:77")
        #expect(try CertificateFingerprint.parse(fp.displayString).get() == fp, "the display form parses back")
    }

    @Test("Codable round-trips the canonical form and rejects anything else")
    func codable() throws {
        let fp = try CertificateFingerprint.parse(Self.lower).get()
        let data = try JSONEncoder().encode([fp])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(Self.lower)\"]")
        #expect(try JSONDecoder().decode([CertificateFingerprint].self, from: data) == [fp])
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([CertificateFingerprint].self, from: Data("[\"00:11\"]".utf8))
        }
    }
}

