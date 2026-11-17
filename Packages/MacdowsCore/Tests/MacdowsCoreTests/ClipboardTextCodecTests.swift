import MacdowsCore
import Testing

// S7 (clipboard T1 text conversion). Every fixture string here is invented for the test.
// Expectations are written as UTF-16 code units or Unicode scalar values, never as String
// literals compared with ==: Swift treats "\r\n" as one Character, and String equality is
// canonical equivalence, so a String comparison could hide exactly the line-ending detail
// these rules are about.

enum ClipboardCodecFixtures {
    static let cr: UInt16 = 0x000D
    static let lf: UInt16 = 0x000A

    /// UTF-16 code units -> little-endian bytes, with no terminator added.
    static func le(_ units: [UInt16]) -> [UInt8] {
        units.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }

    static func units(_ text: String) -> [UInt16] { Array(text.utf16) }

    /// The decoded text's scalar values, or nil when decoding refused the input.
    static func decodedScalars(_ bytes: [UInt8]) -> [UInt32]? {
        guard case .text(let text) = ClipboardTextCodec.decodeUnicodeText(bytes) else { return nil }
        return text.value.unicodeScalars.map(\.value)
    }

    static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    /// The encoded bytes, re-read as code units (the trailing NUL included).
    static func encodedUnits(_ text: String) -> [UInt16] {
        let bytes = ClipboardTextCodec.encodeUnicodeText(text).bytes
        return stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8) }
    }
}

@Suite("Clipboard S7: CF_UNICODETEXT bytes -> String")
struct ClipboardTextDecodeTests {
    typealias F = ClipboardCodecFixtures

    @Test("ASCII with its NUL terminator decodes to the same text")
    func ascii() {
        #expect(F.decodedScalars(F.le(F.units("fixture-alpha 42") + [0])) == F.scalars("fixture-alpha 42"))
    }

    @Test("CJK decodes")
    func cjk() {
        #expect(F.decodedScalars(F.le(F.units("测试夹具文本") + [0])) == F.scalars("测试夹具文本"))
    }

    @Test("an emoji's surrogate pair decodes to one scalar")
    func emojiSurrogatePair() {
        let units = F.units("x🧪y")
        #expect(units == [0x0078, 0xD83E, 0xDDEA, 0x0079])
        #expect(F.decodedScalars(F.le(units + [0])) == [0x78, 0x1F9EA, 0x79])
    }

    @Test("a lead surrogate followed by a non-trail becomes one U+FFFD and the next unit survives")
    func loneLeadSurrogate() {
        #expect(F.decodedScalars(F.le([0xD83E, 0x0041, 0])) == [0xFFFD, 0x41])
    }

    @Test("a lead surrogate as the very last unit (no NUL) becomes U+FFFD")
    func loneLeadSurrogateAtEnd() {
        #expect(F.decodedScalars(F.le([0x0041, 0xD83E])) == [0x41, 0xFFFD])
    }

    @Test("a lead surrogate right before the NUL becomes U+FFFD; what follows the NUL is gone")
    func loneLeadSurrogateBeforeNul() {
        #expect(F.decodedScalars(F.le([0x0041, 0xD83E, 0, 0xDDEA])) == [0x41, 0xFFFD])
    }

    @Test("a trail surrogate with no lead becomes one U+FFFD")
    func loneTrailSurrogate() {
        #expect(F.decodedScalars(F.le([0xDDEA, 0x0041])) == [0xFFFD, 0x41])
    }

    @Test("a reversed pair is two lone surrogates: two U+FFFD")
    func reversedPair() {
        #expect(F.decodedScalars(F.le([0xDDEA, 0xD83E])) == [0xFFFD, 0xFFFD])
    }

    @Test("lead, lead, trail: the first lead is lone, the second pairs")
    func leadLeadTrail() {
        #expect(F.decodedScalars(F.le([0xD83E, 0xD83E, 0xDDEA])) == [0xFFFD, 0x1F9EA])
    }

    /// Version 3: odd is malformed only when no NUL unit ends the text first. (Version 2
    /// refused every odd count, including `[0, 0, 0]`, which is now the empty text.)
    @Test("no NUL unit and an odd byte count is malformed, refused with its reason", arguments: [
        [UInt8(0x41)],
        [UInt8(0x00)],
        [UInt8(0x41), 0x00, 0x42],
        [UInt8(0x41), 0x00, 0x00],
        [UInt8(0x41), 0x00, 0x42, 0x00, 0x43],
    ])
    func oddByteCountWithoutNul(_ bytes: [UInt8]) {
        #expect(ClipboardTextCodec.decodeUnicodeText(bytes) == .failure(.oddByteCount))
    }

    @Test("a NUL unit first, then an odd tail: accepted up to the NUL")
    func oddWithNulFirst() {
        #expect(F.decodedScalars(F.le(F.units("ab") + [0]) + [0x63]) == F.scalars("ab"))
        #expect(F.decodedScalars(F.le(F.units("ab") + [0] + F.units("cd")) + [0x7F]) == F.scalars("ab"))
        #expect(F.decodedScalars([0x00, 0x00, 0x00]) == [])
    }

    @Test("the NUL in the last whole unit, then one stray byte: accepted")
    func nulInLastWholeUnitThenStrayByte() {
        let bytes = F.le(F.units("fixture-γ") + [0]) + [0x5A]
        #expect(bytes.count % 2 == 1)
        #expect(F.decodedScalars(bytes) == F.scalars("fixture-γ"))
    }

    @Test("no NUL unit and an even byte count: used to the end")
    func evenWithoutNul() {
        #expect(F.decodedScalars(F.le(F.units("fixture-δ 测"))) == F.scalars("fixture-δ 测"))
    }

    @Test("a single byte is malformed, whatever it is", arguments: [UInt8(0x00), 0x41, 0xFF])
    func singleByte(_ byte: UInt8) {
        #expect(ClipboardTextCodec.decodeUnicodeText([byte]) == .failure(.oddByteCount))
    }

    @Test("no NUL terminator: every unit is used")
    func noTerminator() {
        #expect(F.decodedScalars(F.le(F.units("fixture-beta"))) == F.scalars("fixture-beta"))
    }

    @Test("a NUL in the middle ends the text; everything after it is discarded")
    func nulInTheMiddle() {
        #expect(F.decodedScalars(F.le(F.units("ab") + [0] + F.units("cd") + [0])) == F.scalars("ab"))
    }

    @Test("empty input decodes to the empty string")
    func emptyInput() {
        #expect(F.decodedScalars([]) == [])
    }

    @Test("only a NUL, or a NUL first, decodes to the empty string")
    func onlyNul() {
        #expect(F.decodedScalars([0, 0]) == [])
        #expect(F.decodedScalars(F.le([0] + F.units("hidden-tail"))) == [])
    }

    @Test("CR LF becomes LF")
    func crlfBecomesLf() {
        #expect(F.decodedScalars(F.le(F.units("l1") + [F.cr, F.lf] + F.units("l2") + [F.cr, F.lf, 0]))
                == F.scalars("l1") + [0x0A] + F.scalars("l2") + [0x0A])
    }

    @Test("a lone LF stays LF")
    func loneLf() {
        #expect(F.decodedScalars(F.le([0x61, F.lf, 0x62, 0])) == [0x61, 0x0A, 0x62])
    }

    @Test("a lone CR stays CR, in the middle and at the end")
    func loneCr() {
        #expect(F.decodedScalars(F.le([0x61, F.cr, 0x62, 0])) == [0x61, 0x0D, 0x62])
        #expect(F.decodedScalars(F.le([0x61, F.cr])) == [0x61, 0x0D])
    }

    @Test("CR CR LF becomes CR LF: the first CR is lone, the second pairs")
    func crCrLf() {
        #expect(F.decodedScalars(F.le([0x61, F.cr, F.cr, F.lf, 0x62])) == [0x61, 0x0D, 0x0A, 0x62])
    }

    @Test("LF CR is not a pair: both stay")
    func lfCr() {
        #expect(F.decodedScalars(F.le([F.lf, F.cr])) == [0x0A, 0x0D])
    }

    @Test("a CR whose LF comes after the NUL is lone")
    func crBeforeNulThenLf() {
        #expect(F.decodedScalars(F.le([0x61, F.cr, 0, F.lf])) == [0x61, 0x0D])
    }
}

@Suite("Clipboard S7: String -> CF_UNICODETEXT bytes")
struct ClipboardTextEncodeTests {
    typealias F = ClipboardCodecFixtures

    @Test("ASCII, CJK and an emoji encode as UTF-16LE plus one NUL unit", arguments: [
        "fixture-alpha 42", "测试夹具文本", "x🧪y🦊",
    ])
    func plainText(_ text: String) {
        #expect(F.encodedUnits(text) == F.units(text) + [0])
        let bytes = ClipboardTextCodec.encodeUnicodeText(text).bytes
        #expect(bytes.count == (text.utf16.count + 1) * 2)
        #expect(bytes.suffix(2) == [0, 0])
    }

    @Test("the emoji's bytes are little-endian surrogate halves")
    func littleEndian() {
        #expect(ClipboardTextCodec.encodeUnicodeText("🧪").bytes == [0x3E, 0xD8, 0xEA, 0xDD, 0x00, 0x00])
    }

    @Test("a lone LF becomes CR LF")
    func loneLfBecomesCrLf() {
        #expect(F.encodedUnits("a\nb") == [0x61, F.cr, F.lf, 0x62, 0])
        #expect(F.encodedUnits("\nx") == [F.cr, F.lf, 0x78, 0])
        #expect(F.encodedUnits("\n\n") == [F.cr, F.lf, F.cr, F.lf, 0])
    }

    @Test("an existing CR LF is left alone, never CR CR LF")
    func existingCrLfUnchanged() {
        #expect(F.encodedUnits("a\r\nb") == [0x61, F.cr, F.lf, 0x62, 0])
    }

    @Test("a lone CR is left alone")
    func loneCrUnchanged() {
        #expect(F.encodedUnits("a\rb") == [0x61, F.cr, 0x62, 0])
        #expect(F.encodedUnits("\r\r\n") == [F.cr, F.cr, F.lf, 0])
        #expect(F.encodedUnits("\n\r") == [F.cr, F.lf, F.cr, 0])
    }

    /// Gate r1, I-2: "is this LF already preceded by CR?" looks at the unit RIGHT BEFORE it,
    /// not at whether a CR occurred anywhere earlier. A CR -- lone or in a CR LF pair -- earlier
    /// in the text must not stop a later lone LF from becoming CR LF. The round-trip property
    /// cannot see this (decoding keeps a bare LF as it is), so each case is pinned unit by unit.
    @Test("a lone LF after an earlier CR still becomes CR LF", arguments: [
        ("a\r\n\nb", [0x61, 0x0D, 0x0A, 0x0D, 0x0A, 0x62, 0]),
        ("\r\n\n", [0x0D, 0x0A, 0x0D, 0x0A, 0]),
        ("a\rb\nc", [0x61, 0x0D, 0x62, 0x0D, 0x0A, 0x63, 0]),
        ("\r\r\n\n", [0x0D, 0x0D, 0x0A, 0x0D, 0x0A, 0]),
        ("\rx\n", [0x0D, 0x78, 0x0D, 0x0A, 0]),
        ("\r\n\r\n\n", [0x0D, 0x0A, 0x0D, 0x0A, 0x0D, 0x0A, 0]),
        ("\r\n测\n", [0x0D, 0x0A, 0x6D4B, 0x0D, 0x0A, 0]),
        ("\r🧪\n", [0x0D, 0xD83E, 0xDDEA, 0x0D, 0x0A, 0]),
    ] as [(String, [UInt16])])
    func loneLfAfterEarlierCr(_ text: String, _ expected: [UInt16]) {
        #expect(F.encodedUnits(text) == expected)
    }

    @Test("the text ends at its first U+0000")
    func endsAtFirstNul() {
        #expect(F.encodedUnits("ab\u{0}cd") == [0x61, 0x62, 0])
        #expect(F.encodedUnits("\u{0}fixture") == [0])
    }

    @Test("the empty string is just the terminator")
    func emptyString() {
        #expect(ClipboardTextCodec.encodeUnicodeText("").bytes == [0, 0])
    }
}

/// Deterministic generator for the round-trip property (SplitMix64): the same strings on every
/// run and every machine, so a failure is always reproducible.
struct ClipboardSplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Clipboard S7: the round-trip property")
struct ClipboardTextRoundTripTests {
    typealias F = ClipboardCodecFixtures

    /// Building blocks: ASCII, controls other than CR/NUL, BMP CJK, astral emoji, the BMP
    /// edge below the surrogates, private use, the last scalar, and LF on its own.
    static let pieces: [String] = [
        "a", "Z", "0", " ", "\t", "\n", "测", "试", "é", "🧪", "🦊", "\u{D7FF}", "\u{E000}",
        "\u{FFFD}", "\u{10FFFF}", "fixture",
    ]

    static func randomText(using rng: inout ClipboardSplitMix64, extraPieces: [String] = []) -> String {
        let all = pieces + extraPieces
        let length = Int(rng.next() % 40)
        return (0..<length).map { _ in all[Int(rng.next() % UInt64(all.count))] }.joined()
    }

    @Test("text with no U+0000, no lone CR (and, being a Swift String, no lone surrogate) comes back identical")
    func identityWithoutCr() {
        var rng = ClipboardSplitMix64(state: 0x5EED_0001)
        for _ in 0..<500 {
            let text = Self.randomText(using: &rng)
            let back = F.decodedScalars(ClipboardTextCodec.encodeUnicodeText(text).bytes)
            #expect(back == F.scalars(text), "round trip changed a \(text.utf16.count)-unit generated text")
        }
    }

    @Test("the one exception: an original CR LF comes back as LF, and nothing else changes")
    func crlfComesBackAsLf() {
        #expect(F.decodedScalars(ClipboardTextCodec.encodeUnicodeText("x\r\ny").bytes) == [0x78, 0x0A, 0x79])

        var rng = ClipboardSplitMix64(state: 0x5EED_0002)
        for _ in 0..<500 {
            let text = Self.randomText(using: &rng, extraPieces: ["\r\n", "\r\n"])
            var expected: [UInt32] = []
            let original = F.scalars(text)
            var i = 0
            while i < original.count {
                if original[i] == 0x0D, i + 1 < original.count, original[i + 1] == 0x0A {
                    i += 1
                    continue
                }
                expected.append(original[i])
                i += 1
            }
            let back = F.decodedScalars(ClipboardTextCodec.encodeUnicodeText(text).bytes)
            #expect(back == expected, "round trip of a \(text.utf16.count)-unit generated text with CR LF")
        }
    }
}

/// Gate r1's S7 fuzz, folded in (I-2): fixed seeds, a fixed number of cases, inputs biased
/// towards the units the rules are about (NUL, CR, LF, lone and paired surrogates). Each test
/// stops at its first failing case and records one issue naming the seed, the case number and
/// the generated input as UTF-16 units -- the inputs are built from invented pieces, so the
/// message carries no real content -- so a failure is reproducible and the log stays short.
@Suite("Clipboard S7: fixed-seed fuzz of both directions")
struct ClipboardTextFuzzTests {
    static let cases = 20_000

    /// A 64-bit LCG (Knuth's MMIX constants): deterministic on every machine.
    struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static func hex(_ units: [UInt16]) -> String {
        units.map { String($0, radix: 16) }.joined(separator: " ")
    }

    /// Up to 39 units, three in four drawn from the interesting ones, plus a stray byte one
    /// time in three.
    static func bytes(_ g: inout LCG) -> [UInt8] {
        let units: [UInt16] = [0x0000, 0x000D, 0x000A, 0x0041, 0x6D4B, 0xD83E, 0xDDEA, 0xDC00, 0xDBFF, 0xFFFF, 0xFEFF]
        var out: [UInt8] = []
        for _ in 0..<g.below(40) {
            let unit: UInt16 = g.below(4) == 0 ? UInt16(truncatingIfNeeded: g.next()) : units[g.below(units.count)]
            out.append(UInt8(truncatingIfNeeded: unit))
            out.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        if g.below(3) == 0 { out.append(UInt8(truncatingIfNeeded: g.next())) }
        return out
    }

    /// What S7 says decode(encode(s)) is: s up to its first U+0000, with every CR LF as LF.
    static func normalize(_ text: String) -> [Unicode.Scalar] {
        var scalars = Array(text.unicodeScalars)
        if let nul = scalars.firstIndex(of: "\u{0}") { scalars.removeSubrange(nul...) }
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                i += 1
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return out
    }

    @Test("decode never crashes; it fails iff there is no NUL unit and the count is odd; no U+0000 survives; never more units out than in")
    func decodeFuzz() {
        let seed: UInt64 = 0xC11B
        var g = LCG(state: seed)
        for index in 0..<Self.cases {
            let bytes = Self.bytes(&g)
            var hasNul = false
            var i = 0
            while i + 1 < bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0 { hasNul = true; break }
                i += 2
            }
            var problems: [String] = []
            switch ClipboardTextCodec.decodeUnicodeText(bytes) {
            case .failure(.oddByteCount):
                if hasNul || bytes.count % 2 == 0 { problems.append("refused although it has a NUL unit or an even count") }
            case .text(let text):
                if !hasNul && bytes.count % 2 == 1 { problems.append("accepted no NUL unit with an odd count") }
                if text.value.unicodeScalars.contains("\u{0}") { problems.append("U+0000 in the text") }
                if text.utf16Count > bytes.count / 2 { problems.append("more units out than in") }
            }
            if !problems.isEmpty {
                Issue.record("seed \(String(seed, radix: 16)) case \(index) (\(bytes.count) bytes): \(problems)")
                return
            }
        }
    }

    @Test("encode: even length, one trailing NUL unit and no other, every LF right after a CR; decode(encode(s)) is s up to U+0000 with CR LF as LF")
    func encodeFuzz() {
        let seed: UInt64 = 0xE7C0
        var g = LCG(state: seed)
        let pieces = ["\r", "\n", "\r\n", "\u{0}", "a", "测", "🧪", "\u{FEFF}", "\u{2028}", "\r\r\n", "\n\r"]
        for index in 0..<Self.cases {
            var text = ""
            for _ in 0..<g.below(12) { text += pieces[g.below(pieces.count)] }
            let bytes = ClipboardTextCodec.encodeUnicodeText(text).bytes
            var problems: [String] = []
            var units: [UInt16] = []
            if bytes.count % 2 != 0 || bytes.count < 2 {
                problems.append("length \(bytes.count)")
            } else {
                units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
                if units.last != 0 { problems.append("no trailing NUL unit") }
                if units.dropLast().contains(0) { problems.append("a NUL unit before the end") }
                for (k, unit) in units.enumerated() where unit == 0x0A && (k == 0 || units[k - 1] != 0x0D) {
                    problems.append("bare LF at unit \(k)")
                }
                if case .text(let back) = ClipboardTextCodec.decodeUnicodeText(bytes) {
                    if !back.value.unicodeScalars.elementsEqual(Self.normalize(text)) { problems.append("round trip differs") }
                } else {
                    problems.append("its own encoding does not decode")
                }
            }
            if !problems.isEmpty {
                Issue.record("seed \(String(seed, radix: 16)) case \(index): input units [\(Self.hex(Array(text.utf16)))] -> [\(Self.hex(units))]: \(problems)")
                return
            }
        }
    }
}
