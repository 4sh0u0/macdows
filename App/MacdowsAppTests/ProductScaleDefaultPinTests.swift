import Foundation
import Testing

// W3 lane H (ADR-0018 U-1 ruled D, 2026-09-08 13:28 JST): the product default is wired in ONE place
// on each side -- the App's session setup assigns the pair from `ScaleAdvertisement.productDefault`
// right after freezing the topology, and window-smoke's knob-unset path resolves through the same
// function, so the fixture measures what the product ships. `none` is now the explicit OFF switch.
// Source pins, same technique as the A2 / lane E pins (whitespace-collapsed substrings).
private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("product default advertised scale (W3 lane H, U-1 = D)")
struct ProductScaleDefaultPinTests {
    @Test("AppDelegate assigns BOTH fields from productDefault, once, from the frozen snapshot's rasterScale")
    func appDelegateWiresTheDefault() throws {
        let src = try source("App/Macdows/AppDelegate.swift")
        let block = "if let scale = displayTopology.sessionSnapshot?.rasterScale, let advertised = ScaleAdvertisement.productDefault(rasterScale: scale) { "
            + "newSession.advertisedDesktopScaleFactor = advertised.desktopScaleFactor "
            + "newSession.advertisedDeviceScaleFactor = advertised.deviceScaleFactor }"
        #expect(occurrences(of: block, in: src) == 1)
        #expect(occurrences(of: "advertisedDesktopScaleFactor =", in: src) == 1)
        #expect(occurrences(of: "advertisedDeviceScaleFactor =", in: src) == 1)
    }

    @Test("CRSession.h no longer claims the product never assigns the pair")
    func headerDocUpdated() throws {
        let src = try source("App/CRBridge/CRSession.h")
        #expect(!src.contains("the product, which never assigns this pair"))
        #expect(src.contains("ScaleAdvertisement.productDefault"))
    }

    @Test("window-smoke: knob unset resolves through productDefault; `none` is the explicit OFF switch")
    func smokeFollowsTheProductDefault() throws {
        let src = try source("Tools/window-smoke/main.swift")
        #expect(src.contains("case .unset: guard let rasterScale else { return nil } return ScaleAdvertisement.productDefault(rasterScale: rasterScale)"))
        #expect(src.contains("case \"none\": return .forcedNone"))
        #expect(src.contains("case .forcedNone, .invalid: return nil"))
    }
}
