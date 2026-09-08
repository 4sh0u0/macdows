import Testing
@testable import MacdowsCore

/// ADR-0018 U-1 ruling (owner, 2026-09-08 13:28 JST): the product advertises **D** -- DesktopScaleFactor
/// = round(rasterScale × 100), DeviceScaleFactor stays 100 -- as its DEFAULT, revocable by ADR addendum.
/// `ScaleAdvertisement.productDefault(rasterScale:)` is the ONE place that says so: the App's session
/// setup (lane H) and window-smoke's knob-unset path both call it, so "what the product advertises"
/// cannot drift between the two. At 1x it is 100/100, wire-identical to not advertising at all.
@Suite("ScaleAdvertisement.productDefault (ADR-0018 U-1 = D)")
struct ProductScaleDefaultTests {
    @Test("2x -> DesktopScaleFactor 200, DeviceScaleFactor 100 (option D, not DD)")
    func twoXIsDesktopOnly() {
        let d = ScaleAdvertisement.productDefault(rasterScale: 2)
        #expect(d?.desktopScaleFactor == 200)
        #expect(d?.deviceScaleFactor == 100)
    }

    @Test("1x -> notAdvertising (100/100)")
    func oneXIsNotAdvertising() {
        #expect(ScaleAdvertisement.productDefault(rasterScale: 1) == .notAdvertising)
    }

    @Test("out-of-domain scales are refused, not clamped (0.5x, 6x, NaN)")
    func outOfDomainIsNil() {
        #expect(ScaleAdvertisement.productDefault(rasterScale: 0.5) == nil)
        #expect(ScaleAdvertisement.productDefault(rasterScale: 6) == nil)
        #expect(ScaleAdvertisement.productDefault(rasterScale: .nan) == nil)
    }

    @Test("the default IS option D: equal to proposedDesktopOnly across the domain (a swap to DD is red at every step)")
    func equalsOptionDAcrossTheDomain() {
        for s in stride(from: 1.0, through: 5.0, by: 0.25) {
            #expect(ScaleAdvertisement.productDefault(rasterScale: s) == ScaleAdvertisement.proposedDesktopOnly(rasterScale: s), "at \(s)x")
        }
    }
}
