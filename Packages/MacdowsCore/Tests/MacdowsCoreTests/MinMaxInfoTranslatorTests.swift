import Testing
@testable import MacdowsCore

/// Phase 2 W3 (`docs/plans/phase2.md` §2 W3): targeted unit coverage for
/// `MinMaxInfoTranslator`'s sentinel-filtering, entirely offline -- no AppKit, matching
/// `WindowMappabilityTests`'/`ZOrderSyncTests`' own no-AppKit precedent for this package's
/// pure-logic surface.
@Suite("MinMaxInfoTranslator")
struct MinMaxInfoTranslatorTests {
    @Test("all four fields set to plausible track sizes round-trip as-is")
    func plausibleValuesPassThrough() {
        let c = MinMaxInfoTranslator.constraints(
            minTrackWidth: 200, minTrackHeight: 150, maxTrackWidth: 3000, maxTrackHeight: 2000
        )
        #expect(c.minWidth == 200)
        #expect(c.minHeight == 150)
        #expect(c.maxWidth == 3000)
        #expect(c.maxHeight == 2000)
    }

    @Test("all four fields at 0 (server never set them) become nil, not a zero-size constraint")
    func zeroMeansAbsent() {
        let c = MinMaxInfoTranslator.constraints(
            minTrackWidth: 0, minTrackHeight: 0, maxTrackWidth: 0, maxTrackHeight: 0
        )
        #expect(c.minWidth == nil)
        #expect(c.minHeight == nil)
        #expect(c.maxWidth == nil)
        #expect(c.maxHeight == nil)
    }

    @Test("a negative reading is treated as absent, not as a literal negative constraint")
    func negativeMeansAbsent() {
        let c = MinMaxInfoTranslator.constraints(
            minTrackWidth: -1, minTrackHeight: -100, maxTrackWidth: -1, maxTrackHeight: -1
        )
        #expect(c.minWidth == nil)
        #expect(c.minHeight == nil)
        #expect(c.maxWidth == nil)
        #expect(c.maxHeight == nil)
    }

    @Test("mixed: some fields present, some absent -- each sanitized independently")
    func mixedFieldsAreIndependent() {
        let c = MinMaxInfoTranslator.constraints(
            minTrackWidth: 100, minTrackHeight: 0, maxTrackWidth: 0, maxTrackHeight: 900
        )
        #expect(c.minWidth == 100)
        #expect(c.minHeight == nil)
        #expect(c.maxWidth == nil)
        #expect(c.maxHeight == 900)
    }
}
