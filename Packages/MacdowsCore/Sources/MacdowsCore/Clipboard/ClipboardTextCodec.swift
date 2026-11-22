/// Why `ClipboardTextCodec.decodeUnicodeText` refused its input. S7 has exactly one way for
/// `CF_UNICODETEXT` bytes to be malformed -- everything else (a missing NUL, a lone surrogate,
/// a stray byte after the NUL) has a defined repair -- so this has exactly one case; new ones
/// append.
public enum ClipboardDecodeFailure: String, CaseIterable, Sendable {
    /// No NUL code unit and an odd number of bytes: the text runs to the end, and its last
    /// byte cannot be half of a UTF-16 code unit.
    case oddByteCount = "odd-byte-count"
}

/// The outcome of decoding `CF_UNICODETEXT` bytes. Never thrown, never a crash: malformed
/// input is a value.
public enum ClipboardDecodeResult: Equatable, Sendable {
    case text(ClipboardText)
    case failure(ClipboardDecodeFailure)
}

extension ClipboardDecodeResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .text(let text): "ClipboardDecodeResult.text(utf16Count: \(text.utf16Count))"
        case .failure(let reason): "ClipboardDecodeResult.failure(\(reason.rawValue))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        switch self {
        case .text(let text): Mirror(self, children: ["text.utf16Count": text.utf16Count], displayStyle: .enum)
        case .failure(let reason): Mirror(self, children: ["failure": reason.rawValue], displayStyle: .enum)
        }
    }
}

/// S7: `CF_UNICODETEXT` bytes <-> `String`, both directions. Works on UTF-16 code units and
/// Unicode scalars throughout, never on `Character`s: Swift treats "\r\n" as ONE grapheme, so
/// any line-ending rule written against characters would silently miss every CR LF pair.
public enum ClipboardTextCodec {
    private static let nul: UInt16 = 0x0000
    private static let lineFeed: UInt16 = 0x000A
    private static let carriageReturn: UInt16 = 0x000D
    private static let replacement: Unicode.Scalar = "\u{FFFD}"

    /// Windows -> Mac. The rules, in the order they apply:
    /// 1. the bytes are read from the start as UTF-16LE code units up to the first NUL unit,
    ///    which ends the text (everything after it is discarded -- that is `CF_UNICODETEXT`'s
    ///    own convention). With a NUL unit, the total byte count does not matter, odd or even;
    /// 2. with no NUL unit, an even byte count uses every unit, and an odd one is malformed
    ///    and refused (`.failure(.oddByteCount)`): the text would run into a half unit;
    /// 3. a lone surrogate -- a lead not followed by a trail, or a trail not preceded by a
    ///    lead -- becomes one U+FFFD each;
    /// 4. every CR LF pair becomes LF; a CR not followed by LF is kept as it is.
    public static func decodeUnicodeText(_ bytes: [UInt8]) -> ClipboardDecodeResult {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var offset = 0
        var foundNul = false
        // Whole units only: a trailing odd byte is never read as part of one.
        while offset + 1 < bytes.count {
            let unit = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if unit == nul {
                foundNul = true
                break
            }
            units.append(unit)
            offset += 2
        }
        if !foundNul, bytes.count % 2 != 0 { return .failure(.oddByteCount) }

        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < units.count {
            let unit = units[index]
            let next: UInt16? = index + 1 < units.count ? units[index + 1] : nil
            if unit == carriageReturn, next == lineFeed {
                // Drop the CR of a CR LF pair; the LF is appended by the next iteration.
                index += 1
                continue
            }
            if UTF16.isLeadSurrogate(unit) {
                if let trail = next, UTF16.isTrailSurrogate(trail) {
                    let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
                    // Always a valid scalar (U+10000...U+10FFFF); the fallback is unreachable.
                    scalars.append(Unicode.Scalar(value) ?? replacement)
                    index += 2
                    continue
                }
                // A lead surrogate with no trail after it.
                scalars.append(replacement)
                index += 1
                continue
            }
            if let scalar = Unicode.Scalar(unit) {
                scalars.append(scalar)
            } else {
                // A trail surrogate with no lead before it (the only UInt16 that fails here).
                scalars.append(replacement)
            }
            index += 1
        }
        return .text(ClipboardText(String(scalars)))
    }

    /// Mac -> Windows. The rules, in the order they apply:
    /// 1. the text ends at its first U+0000 (the receiver would stop reading there anyway);
    /// 2. every LF not already preceded by CR becomes CR LF; an existing CR LF is left as it
    ///    is (never CR CR LF), and a CR on its own is left as it is;
    /// 3. the result is UTF-16LE with one NUL code unit (two zero bytes) appended.
    /// A Swift `String` cannot hold a lone surrogate, so there is nothing to repair here.
    public static func encodeUnicodeText(_ text: String) -> ClipboardBytes {
        var bytes: [UInt8] = []
        // Sized from the units before the first U+0000, never from the whole text: a text
        // that ends early must not reserve memory for the tail it drops.
        bytes.reserveCapacity(encodedByteCountFloor(text, stoppingAbove: .max))
        var previous = nul
        for unit in text.utf16 {
            if unit == nul { break }
            if unit == lineFeed, previous != carriageReturn {
                append(carriageReturn, to: &bytes)
            }
            append(unit, to: &bytes)
            previous = unit
        }
        append(nul, to: &bytes)
        return ClipboardBytes(bytes)
    }

    /// The fewest bytes `encodeUnicodeText(text)` can produce: two per UTF-16 unit before the
    /// first U+0000, plus two for the terminating NUL. Encoding only ever adds to this (each
    /// lone LF gains a CR), so a floor over a limit means the encoding is over it too.
    /// Walks the UTF-16 view without allocating, and stops as soon as the count passes
    /// `ceiling`: the result is exact when it is at most `ceiling`, and otherwise some value
    /// above `ceiling` -- so a text of any size costs at most `ceiling / 2` steps. Always more
    /// than 2 when any unit precedes the first U+0000, whatever `ceiling` is.
    static func encodedByteCountFloor(_ text: String, stoppingAbove ceiling: Int) -> Int {
        var bytes = 2
        for unit in text.utf16 {
            if unit == nul { break }
            bytes += 2
            if bytes > ceiling { break }
        }
        return bytes
    }

    private static func append(_ unit: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: unit))
        bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
    }
}
