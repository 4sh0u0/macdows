import Foundation
import Testing

// W3 lane G (ADR-0018 §2 / U-6 first step): the store's per-cause refusal counters (pinned in
// MacdowsCore's IconRefusalCountTests) only mean something if the ONE place that learns the
// cause -- CRSession.mm's notify-icon callback, where `crdpq_icon_convert`'s return code is in
// hand -- reports it, and if the count then travels to the diagnostics line the 2x checkpoint
// will read (CRSession passthrough -> RemoteWindowRegistry -> TrayStatusController.Diagnostics
// -> window-smoke's `[tray]` line). Source pins over those four hops, same technique as the A2
// lane's pins (whitespace-collapsed substring matching).
private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

@Suite("icon refusal count plumbing (W3 lane G)")
struct IconRefusalCountPinTests {
    @Test("the bridge reports every conversion refusal to the store with its cause and dimensions")
    func bridgeReportsRefusal() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        #expect(src.contains("crdpq_icon_store_note_convert_refusal(icons, rc, icon->width, icon->height);"))
        #expect(src.contains("- (uint64_t)iconStoreOversizeRefusalCount"))
        #expect(src.contains("crdpq_icon_store_oversize_count(_iconStore)"))
    }

    @Test("CRSession.h exposes the oversize-refusal passthrough next to the overflow one")
    func headerExposesPassthrough() throws {
        let src = try source("App/CRBridge/CRSession.h")
        #expect(src.contains("@property (nonatomic, readonly) uint64_t iconStoreOversizeRefusalCount;"))
    }

    @Test("RemoteWindowRegistry pushes the oversize-refusal count into the tray controller on notify-icon create and update")
    func registryPushesCount() throws {
        let src = try source("App/RemoteWindowRendering/RemoteWindowRegistry.swift")
        let needle = "trayStatusController.noteStoreOversizeRefusalCount(Int(session.iconStoreOversizeRefusalCount))"
        #expect(src.components(separatedBy: needle).count - 1 >= 2)
    }

    @Test("window-smoke's [tray] diagnostics line prints the oversize-refusal count (the 2x checkpoint reads it there)")
    func smokePrintsCount() throws {
        let src = try source("Tools/window-smoke/main.swift")
        #expect(src.contains("storeOversizeRefusals=\\(trayDiag.storeOversizeRefusalCount)"))
    }
}
