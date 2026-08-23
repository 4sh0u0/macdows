import Testing
@testable import MacdowsCore

@Suite("IsoKeyCodeCorrection")
struct IsoKeyCodeCorrectionTests {
    private let grave: UInt16 = 0x32
    private let section: UInt16 = 0x0A

    @Test("ANSI keyboard: Grave and Section pass through unchanged")
    func ansiPassesThrough() {
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: grave, keyboardType: .ansi) == grave)
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: section, keyboardType: .ansi) == section)
    }

    @Test("JIS keyboard: Grave and Section pass through unchanged (only ISO swaps)")
    func jisPassesThrough() {
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: grave, keyboardType: .jis) == grave)
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: section, keyboardType: .jis) == section)
    }

    @Test("ISO keyboard: Grave and Section are swapped")
    func isoSwapsGraveAndSection() {
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: grave, keyboardType: .iso) == section)
        #expect(IsoKeyCodeCorrection.correct(macKeyCode: section, keyboardType: .iso) == grave)
    }

    @Test(
        "every other keycode passes through unchanged on every keyboard type",
        arguments: [MacKeyboardType.ansi, .iso, .jis]
    )
    func everyOtherKeyCodeIsUntouched(keyboardType: MacKeyboardType) {
        for code: UInt16 in [0x00, 0x08, 0x24, 0x31, 0x33, 0x7F] {
            #expect(IsoKeyCodeCorrection.correct(macKeyCode: code, keyboardType: keyboardType) == code)
        }
    }
}
