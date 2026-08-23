import Testing
@testable import MacdowsCore

@Suite("UnicodeTextExpansion")
struct UnicodeTextExpansionTests {
    @Test("empty string expands to zero events")
    func emptyStringIsZeroEvents() {
        #expect(UnicodeTextExpansion.events(for: "").isEmpty)
    }

    @Test("a single BMP character expands to exactly one down/release pair")
    func singleCharacterIsOnePair() {
        let events = UnicodeTextExpansion.events(for: "A")
        #expect(events == [
            UnicodeKeyEvent(code: 0x0041, down: true),
            UnicodeKeyEvent(code: 0x0041, down: false),
        ])
    }

    @Test("a multi-character string expands to one pair per code unit, in order")
    func multipleCharactersExpandInOrder() {
        let events = UnicodeTextExpansion.events(for: "AB")
        #expect(events == [
            UnicodeKeyEvent(code: 0x0041, down: true),
            UnicodeKeyEvent(code: 0x0041, down: false),
            UnicodeKeyEvent(code: 0x0042, down: true),
            UnicodeKeyEvent(code: 0x0042, down: false),
        ])
    }

    @Test("a surrogate pair (emoji) expands to two down/release pairs, not one")
    func surrogatePairIsTwoPairs() {
        // U+1F600 GRINNING FACE -- UTF-16 surrogate pair 0xD83D 0xDE00.
        let events = UnicodeTextExpansion.events(for: "\u{1F600}")
        #expect(events == [
            UnicodeKeyEvent(code: 0xD83D, down: true),
            UnicodeKeyEvent(code: 0xD83D, down: false),
            UnicodeKeyEvent(code: 0xDE00, down: true),
            UnicodeKeyEvent(code: 0xDE00, down: false),
        ])
    }

    @Test("CJK text expands one pair per UTF-16 code unit (BMP, no surrogates)")
    func cjkTextExpandsPerCodeUnit() {
        let events = UnicodeTextExpansion.events(for: "你好")
        #expect(events.count == 4)
        #expect(events[0] == UnicodeKeyEvent(code: "你".utf16.first!, down: true))
        #expect(events[1] == UnicodeKeyEvent(code: "你".utf16.first!, down: false))
        #expect(events[2] == UnicodeKeyEvent(code: "好".utf16.first!, down: true))
        #expect(events[3] == UnicodeKeyEvent(code: "好".utf16.first!, down: false))
    }
}
