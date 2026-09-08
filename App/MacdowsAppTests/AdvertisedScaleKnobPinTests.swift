import Foundation
import Testing

// W3 lane E (ADR-0018 §2): the advertised-scale fixture knob is only honest if (1) CRSession sets
// the two TS_UD_CS_CORE scale settings in exactly one place, behind a guard that leaves them
// untouched whenever the properties are left at 0 -- since lane H (ADR-0018 U-1 = D) the App assigns
// the pair from ScaleAdvertisement.productDefault and window-smoke's unset knob follows the same
// default, so 0/0 now means "no usable display" or the explicit `none` switch; "pair zero => no
// setting is set" is still the row's first must-red; (2) window-smoke's
// evidence suffix is built from the values READ BACK from the session, not from the knob or the
// resolved proposal -- "print the derived value" is the row's second must-red; (3) the App target
// never reads the knob. Source pins over those hops, same technique as the A2 / lane G pins
// (whitespace-collapsed substring matching).
private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func source(_ relative: String) throws -> String {
    let raw = try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("advertised-scale knob plumbing (W3 lane E)")
struct AdvertisedScaleKnobPinTests {
    @Test("CRSession.mm sets DesktopScaleFactor / DeviceScaleFactor in ONE guarded block, and nowhere else")
    func bridgeSetsBothBehindTheZeroGuard() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        let block = "if (session.advertisedDesktopScaleFactor > 0 && session.advertisedDeviceScaleFactor > 0) { "
            + "if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, session.advertisedDesktopScaleFactor) || "
            + "!freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, session.advertisedDeviceScaleFactor)) return FALSE; }"
        #expect(occurrences(of: block, in: src) == 1)
        #expect(occurrences(of: "FreeRDP_DesktopScaleFactor", in: src) == 1)
        #expect(occurrences(of: "FreeRDP_DeviceScaleFactor", in: src) == 1)
    }

    @Test("CRSession.h declares the pair with 0 meaning 'leave FreeRDP's defaults'")
    func headerDeclaresThePair() throws {
        let src = try source("App/CRBridge/CRSession.h")
        #expect(src.contains("@property (nonatomic) uint32_t advertisedDesktopScaleFactor;"))
        #expect(src.contains("@property (nonatomic) uint32_t advertisedDeviceScaleFactor;"))
        #expect(src.contains("0 (the default) means \"leave FreeRDP's own defaults untouched\""))
    }

    @Test("window-smoke reads the evidence BACK from the session and appends it to all three [topology] lines")
    func smokeEvidenceIsReadBack() throws {
        let src = try source("Tools/window-smoke/main.swift")
        // Lane H: the readback no longer depends on the knob -- the product default is assigned when
        // the knob is unset, so the evidence must read back in that case too (nil only when 0/0).
        let readBack = "advertisedScaleAssigned = ScaleAdvertisement(desktopScaleFactor: session.advertisedDesktopScaleFactor, deviceScaleFactor: session.advertisedDeviceScaleFactor)"
        #expect(occurrences(of: readBack, in: src) == 1)
        let suffixCall = "AdvertisedScaleKnob.evidenceSuffix(knob: advertisedScaleKnob, assigned: advertisedScaleAssigned)"
        #expect(occurrences(of: suffixCall, in: src) >= 3)
        #expect(src.contains("AdvertisedScaleKnob.resolve(advertisedScaleKnob, rasterScale: displayTopology.sessionSnapshot?.rasterScale)"))
        // Both "nothing to advertise" branches -- a knob that resolves to nothing, and no usable
        // display -- zero the pair: cycle mode reuses one CRSession, so a pair left over from an
        // earlier freeze would be read back by the next -start while the evidence says nothing was
        // advertised (gate w3-lane-e r1 m-1).
        #expect(occurrences(of: "session.advertisedDesktopScaleFactor = 0 session.advertisedDeviceScaleFactor = 0", in: src) == 2)
    }

    @Test("the App target never reads the knob (fixture-only)")
    func appNeverReadsTheKnob() throws {
        let root = repoRoot().appendingPathComponent("App")
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            Issue.record("cannot enumerate App/"); return
        }
        var scanned = 0
        for case let url as URL in it {
            let name = url.lastPathComponent
            if name == "build" || name == "MacdowsAppTests" || name.hasSuffix(".xcodeproj") {
                it.skipDescendants(); continue
            }
            guard ["swift", "m", "mm", "h"].contains(url.pathExtension) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("WINDOW_SMOKE_ADVERTISED_SCALE"), "\(url.lastPathComponent) reads the fixture knob")
            scanned += 1
        }
        #expect(scanned > 10)
    }
}
