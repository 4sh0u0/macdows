import Foundation
import Testing

// Behaviour of the pure predicate behind ADR-0017 §4 row A2 (see the sibling source-pin
// suite for why the CALL SITE is pinned separately). "Intact" = both RDPGFX decode callbacks
// installed; either missing is the black-window failure mode adr/0005 §2 guards against.
@Suite("CRBGfxDecodePathIntact (ADR-0017 §4 A2)")
struct GfxDecodePathPredicateTests {
    @Test("both callbacks installed -> intact")
    func bothSet() {
        var a = 1, b = 2
        withUnsafePointer(to: &a) { pa in
            withUnsafePointer(to: &b) { pb in
                #expect(CRBGfxDecodePathIntact(UnsafeRawPointer(pa), UnsafeRawPointer(pb)))
            }
        }
    }

    @Test("SurfaceCommand missing -> not intact")
    func surfaceCommandMissing() {
        var b = 2
        withUnsafePointer(to: &b) { pb in
            #expect(!CRBGfxDecodePathIntact(nil, UnsafeRawPointer(pb)))
        }
    }

    @Test("UpdateSurfaces missing -> not intact")
    func updateSurfacesMissing() {
        var a = 1
        withUnsafePointer(to: &a) { pa in
            #expect(!CRBGfxDecodePathIntact(UnsafeRawPointer(pa), nil))
        }
    }

    @Test("both missing -> not intact")
    func bothMissing() {
        #expect(!CRBGfxDecodePathIntact(nil, nil))
    }
}
