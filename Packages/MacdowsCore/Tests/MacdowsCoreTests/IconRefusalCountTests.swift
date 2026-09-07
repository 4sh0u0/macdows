import CRDPQueue
import Foundation
import Testing

// W3 lane G (ADR-0018 §2 / U-6 first step; drill-01 §8.1's cheapest path): `crdpq_icon_convert`
// already tells its causes apart by return code, but the bridge folded every non-OK code into
// the single `iconSkipped` bit, so an oversize (>48) refusal and a bad-bpp refusal were
// indistinguishable downstream -- and ADR-0015 §7 (b)'s trigger ("the oversize cause is
// separately countable") could never fire. The store now keeps cumulative per-cause refusal
// counters, plus an `oversize` counter that counts only the DIMENSIONS refusals whose width or
// height actually exceeds CRDPQ_ICON_MAX_DIM (a zero-sized icon is a DIMENSIONS refusal too,
// but not an oversize one). Same lifetime contract as `crdpq_icon_store_overflow_count`:
// cumulative, survives `crdpq_icon_store_clear`.
@Suite("icon store refusal counters (W3 lane G)")
struct IconRefusalCountTests {
    private func withStore(_ body: (OpaquePointer) -> Void) {
        let store = crdpq_icon_store_create()
        precondition(store != nil)
        defer { crdpq_icon_store_destroy(store) }
        body(store!)
    }

    @Test("a fresh store has no refusals of any cause and no oversize refusals")
    func freshIsZero() {
        withStore { s in
            #expect(crdpq_icon_store_oversize_count(s) == 0)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_DIMENSIONS) == 0)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_BPP) == 0)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_OK) == 0)
        }
    }

    @Test("an oversize refusal and a bad-bpp refusal are counted apart (the gap this lane closes)")
    func oversizeAndBppAreDistinguishable() {
        withStore { s in
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_DIMENSIONS, 49, 49)
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_BPP, 32, 32)
            #expect(crdpq_icon_store_oversize_count(s) == 1)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_DIMENSIONS) == 1)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_BPP) == 1)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_COLOR_TABLE) == 0)
        }
    }

    @Test("a zero-sized icon is a DIMENSIONS refusal but NOT an oversize one; either axis over the cap is")
    func zeroSizeIsNotOversize() {
        withStore { s in
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_DIMENSIONS, 0, 16)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_DIMENSIONS) == 1)
            #expect(crdpq_icon_store_oversize_count(s) == 0)
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_DIMENSIONS, 16, UInt32(CRDPQ_ICON_MAX_DIM) + 1)
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_DIMENSIONS, UInt32(CRDPQ_ICON_MAX_DIM) + 1, 16)
            #expect(crdpq_icon_store_oversize_count(s) == 2)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_DIMENSIONS) == 3)
        }
    }

    @Test("CRDPQ_ICON_OK is not a refusal and is never counted; a NULL store reads 0 and tolerates notes")
    func okAndNullAreInert() {
        withStore { s in
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_OK, 49, 49)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_OK) == 0)
            #expect(crdpq_icon_store_oversize_count(s) == 0)
        }
        crdpq_icon_store_note_convert_refusal(nil, CRDPQ_ICON_ERR_DIMENSIONS, 49, 49)
        #expect(crdpq_icon_store_oversize_count(nil) == 0)
        #expect(crdpq_icon_store_refusal_count(nil, CRDPQ_ICON_ERR_DIMENSIONS) == 0)
    }

    @Test("the counters are cumulative for the store's lifetime: clear() keeps them, like overflow_count")
    func countersSurviveClear() {
        withStore { s in
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_DIMENSIONS, 64, 64)
            crdpq_icon_store_note_convert_refusal(s, CRDPQ_ICON_ERR_BITS_MASK, 16, 16)
            crdpq_icon_store_clear(s)
            #expect(crdpq_icon_store_oversize_count(s) == 1)
            #expect(crdpq_icon_store_refusal_count(s, CRDPQ_ICON_ERR_BITS_MASK) == 1)
        }
    }
}
