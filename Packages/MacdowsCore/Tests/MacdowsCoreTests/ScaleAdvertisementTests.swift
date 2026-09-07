import Testing
@testable import MacdowsCore

/// W3 lane D (ADR-0018 §2 / U-1): the PURE half of "advertise `DesktopScaleFactor` /
/// `DeviceScaleFactor`" -- the arithmetic and the wire domains, with no wiring into
/// `CRSession` (that waits for the owner's U-1 ruling). Facts these pin (ADR-0018 §0 (f)):
/// TS_UD_CS_CORE carries both as UINT32 percentages, written unconditionally; upstream's
/// interoperability domains are desktop ∈ [100, 500] and device ∈ {100, 140, 180}; the
/// two fields are distinct and MUST NOT be swapped (the vendored `settings.c` cross-wiring
/// is exactly that mistake, in another code path). A value outside the domain is refused,
/// never clamped -- a wrong topology must not silently advertise the maximum.
@Suite("ScaleAdvertisement (W3 lane D, pure half)")
struct ScaleAdvertisementTests {
    @Test("the default is the not-advertising pair (100 / 100) and reads as `none` in the matrix field")
    func notAdvertisingIsTheDefault() {
        #expect(ScaleAdvertisement.notAdvertising.desktopScaleFactor == 100)
        #expect(ScaleAdvertisement.notAdvertising.deviceScaleFactor == 100)
        #expect(ScaleAdvertisement.notAdvertising.isNotAdvertising)
        #expect(ScaleAdvertisement.notAdvertising.matrixFieldValue == "none")
    }

    @Test("domains: desktop must be within 100...500, device must be one of 100/140/180; anything else is refused, not clamped")
    func domains() {
        #expect(ScaleAdvertisement(desktopScaleFactor: 100, deviceScaleFactor: 100) != nil)
        #expect(ScaleAdvertisement(desktopScaleFactor: 500, deviceScaleFactor: 180) != nil)
        #expect(ScaleAdvertisement(desktopScaleFactor: 99, deviceScaleFactor: 100) == nil)
        #expect(ScaleAdvertisement(desktopScaleFactor: 501, deviceScaleFactor: 100) == nil)
        #expect(ScaleAdvertisement(desktopScaleFactor: 200, deviceScaleFactor: 150) == nil)
        #expect(ScaleAdvertisement(desktopScaleFactor: 200, deviceScaleFactor: 200) == nil)
    }

    @Test("the two fields keep their identity: desktop is desktop, device is device (never swapped)")
    func fieldsAreNotSwapped() {
        let a = ScaleAdvertisement(desktopScaleFactor: 200, deviceScaleFactor: 180)
        #expect(a?.desktopScaleFactor == 200)
        #expect(a?.deviceScaleFactor == 180)
        #expect(a?.matrixFieldValue == "DesktopScaleFactor=200,DeviceScaleFactor=180")
    }

    @Test("rasterScale 1 proposes `none` under both options; there is nothing to advertise at 1x")
    func oneXIsNotAdvertising() {
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 1) == .notAdvertising)
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: 1) == .notAdvertising)
    }

    @Test("option D at 2x: desktop 200, device stays 100; the matrix field omits the default device part")
    func optionDAtTwoX() {
        let d = ScaleAdvertisement.proposedDesktopOnly(rasterScale: 2)
        #expect(d?.desktopScaleFactor == 200)
        #expect(d?.deviceScaleFactor == 100)
        #expect(d?.matrixFieldValue == "DesktopScaleFactor=200")
    }

    @Test("option DD at 2x: desktop 200, device = the nearest allowed value (180); 1.5x -> 150 / 140")
    func optionDDNearestDevice() {
        let dd2 = ScaleAdvertisement.proposedBoth(rasterScale: 2)
        #expect(dd2?.desktopScaleFactor == 200)
        #expect(dd2?.deviceScaleFactor == 180)
        let dd15 = ScaleAdvertisement.proposedBoth(rasterScale: 1.5)
        #expect(dd15?.desktopScaleFactor == 150)
        #expect(dd15?.deviceScaleFactor == 140)
    }

    @Test("a rasterScale whose desktop percentage leaves the domain is refused, not clamped (6x -> 600 -> nil); below 1 likewise")
    func outOfDomainRasterScaleIsRefused() {
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 6) == nil)
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: 6) == nil)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 0.5) == nil)
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: 5) != nil) // 500 is the last legal value
    }

    @Test("non-integral percentages round to the nearest whole percent (1.25x -> 125)")
    func rounding() {
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 1.25)?.desktopScaleFactor == 125)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 1.004)?.desktopScaleFactor == 100)
    }

    @Test("an exact half rounds away from zero (1.125x -> 112.5 -> 113); 1.005x is 100.4999... in binary and rounds to 100, not 101")
    func halfRoundsAwayFromZero() {
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 1.125)?.desktopScaleFactor == 113)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 1.005)?.desktopScaleFactor == 100)
    }

    @Test("a tie between two allowed device values resolves to the LOWER one (1.2x -> 120: 100 not 140; 1.6x -> 160: 140 not 180)")
    func tieResolvesToTheLowerDevice() {
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: 1.2)?.deviceScaleFactor == 100)
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: 1.6)?.deviceScaleFactor == 140)
    }

    @Test("NaN, +-infinity, zero and a negative rasterScale are refused (nil), never converted")
    func nonFiniteAndNonPositiveAreRefused() {
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: .nan) == nil)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: .infinity) == nil)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: -.infinity) == nil)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: 0) == nil)
        #expect(ScaleAdvertisement.proposedDesktopOnly(rasterScale: -2) == nil)
        #expect(ScaleAdvertisement.proposedBoth(rasterScale: .nan) == nil)
    }
}
