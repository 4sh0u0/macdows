import Foundation
import Testing

// W3 route B step 1 (survey §5 (b), §6.2 route B). The four RAIL client-rect fields cross three
// layers that no offline test can otherwise reach -- a C POD, an ObjC++ bridge, and a Swift tool
// with no test target of its own -- so they are pinned here by whitespace-collapsed source
// matching, the same technique AdvertisedScaleKnobPinTests / MaskUnitBoundaryPinTests already use
// for exactly these three files.
//
// What each pin is a MUST-RED for:
//   1. crdpq.h -- the four fields exist, are INT32 (not UINT32: a negative windowClientDelta is the
//      ordinary case), and the size assert moved with them.
//   2. CRSession.mm -- each PAIR is copied behind its OWN validity bit, in two separate `if`s.
//      Collapsing them into one gate, or dropping the gate entirely, is the predicted bug: window.c
//      reads the two pairs independently (:334, :395), so one gate covering both silently publishes
//      whichever pair the order never carried as if the server had sent it. Nothing else in this
//      repo can catch that -- CRBridge has no test bundle, and a live run would only show it as
//      plausible-looking zeros.
//   3. CRSession.h -- the four properties are declared readonly on CRDPEvent (window-smoke's only
//      access route).
//   4. window-smoke -- the `[client-rect]` line's exact shape, its per-group bit gating, and its
//      emission gate. The update gate is EITHER bit, not both.
//
// MEASUREMENT ONLY is itself pinned: nothing in the rendering package, and nothing in
// `WindowGeometry`, may read any of the four. That is the claim that keeps `rasterScale == 1`
// product behaviour bit-identical, and it is the one that would decay first if a later lane started
// wiring before the 1x/2x values exist. The pin enumerates `App/RemoteWindowRendering/` rather than
// naming files, so a file added to that package is covered the day it lands.
//
// There is a STRUCTURAL guarantee underneath that pin, and the next lane -- the one that will
// actually wire these values -- should know it before it starts. The product rendering path does
// not use `MacdowsCore.WindowState` at all: `RemoteWindowRegistry` keeps its own private
// `PendingWindowState`, and `WindowState` / `WindowOrderPayload` serve the JSONL replay path only.
// So growing those two types cannot move product behaviour by construction, not merely by
// inspection -- and the corollary is that a wiring step is not "read the new field in
// `WindowState`"; it has to carry the value across into the registry's own state first, which is
// where the review that step needs will be.
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

/// Every `.swift` file directly under `relative`, as repo-relative paths. A directory listing
/// rather than a hand-kept list: the MEASUREMENT-ONLY claim is about a package, and a claim about
/// a package that is checked against three of its files is only a claim about three files.
private func swiftFiles(under relative: String) throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: repoRoot().appendingPathComponent(relative).path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()
        .map { "\(relative)/\($0)" }
}

@Suite("client-rect plumbing (W3 route B step 1)")
struct ClientRectPlumbingPinTests {
    @Test("crdpq.h carries the four fields as INT32 at the struct tail, with the size assert moved to 588")
    func podCarriesTheFields() throws {
        let src = try source("Packages/MacdowsCore/Sources/CRDPQueue/include/crdpq.h")
        #expect(src.contains("int32_t clientOffsetX; int32_t clientOffsetY; int32_t windowClientDeltaX; int32_t windowClientDeltaY; } crdpq_window_order_t;"))
        #expect(src.contains("_Static_assert(sizeof(crdpq_window_order_t) == 588,"))
        #expect(src.contains("_Static_assert(sizeof(crdpq_event_payload_t) == 592,"))
        #expect(src.contains("_Static_assert(sizeof(CrdpEvent) == 600,"))
        // The field that is deliberately NOT here. If a later lane adds it, this pin should fail
        // and force the census (0 of 202 orders) to be re-run rather than silently assumed stale.
        // Matched as a DECLARATION, not as a bare name: crdpq.h's own doc comment names
        // `clientAreaWidth/Height` while explaining why they are absent, and a name-only pin would
        // read that prose as the thing it forbids.
        #expect(!src.contains("clientAreaWidth;"))
        #expect(!src.contains("clientAreaHeight;"))
    }

    @Test("CRSession.mm copies each client-rect PAIR behind its OWN validity bit -- two separate ifs, each macro used exactly once")
    func bridgeGatesEachPairOnItsOwnBit() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        let offsetBlock = "if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET) { "
            + "ev.payload.windowOrder.clientOffsetX = windowState->clientOffsetX; "
            + "ev.payload.windowOrder.clientOffsetY = windowState->clientOffsetY; }"
        let deltaBlock = "if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_WND_CLIENT_DELTA) { "
            + "ev.payload.windowOrder.windowClientDeltaX = windowState->windowClientDeltaX; "
            + "ev.payload.windowOrder.windowClientDeltaY = windowState->windowClientDeltaY; }"
        #expect(occurrences(of: offsetBlock, in: src) == 1)
        #expect(occurrences(of: deltaBlock, in: src) == 1)
        // Exactly once each, so a second (ungated, or differently-gated) write site is visible.
        // These two macro spellings appear nowhere else in this file, comments included.
        #expect(occurrences(of: "WINDOW_ORDER_FIELD_CLIENT_AREA_OFFSET", in: src) == 1)
        #expect(occurrences(of: "WINDOW_ORDER_FIELD_WND_CLIENT_DELTA", in: src) == 1)
        // The read side: a plain copy out of the already-gated POD into the ObjC event.
        let readSide = "out.clientOffsetX = wo->clientOffsetX; out.clientOffsetY = wo->clientOffsetY;"
            + " out.windowClientDeltaX = wo->windowClientDeltaX; out.windowClientDeltaY = wo->windowClientDeltaY;"
        #expect(src.contains(readSide))
    }

    @Test("CRSession.h declares the four as readonly int32_t on CRDPEvent")
    func headerDeclaresTheFour() throws {
        let src = try source("App/CRBridge/CRSession.h")
        for name in ["clientOffsetX", "clientOffsetY", "windowClientDeltaX", "windowClientDeltaY"] {
            #expect(src.contains("@property (nonatomic, readonly) int32_t \(name);"), "missing declaration for \(name)")
        }
    }

    @Test("window-smoke's [client-rect] line has the pinned shape, gates every group on its own bit, and says rm=n/a")
    func smokeLineShape() throws {
        let src = try source("Tools/window-smoke/main.swift")
        // Assembled as an array join, not a chain of `+` inside `#expect`: the macro re-types the
        // whole expression and an eight-term concatenation there hits the compiler's type-check
        // time limit.
        let line = [
            "return \"[client-rect] id=\\(event.windowId) style=\\(styleText) \"",
            "+ String(format: \"ff=0x%08X \", ff)",
            "+ \"win=\\(sizeText) \"",
            "+ \"off=\\(pair(offsetFieldBit, event.offsetX, event.offsetY)) \"",
            "+ \"coff=\\(pair(clientAreaOffsetBit, event.clientOffsetX, event.clientOffsetY)) \"",
            "+ \"delta=\\(pair(wndClientDeltaBit, event.windowClientDeltaX, event.windowClientDeltaY)) \"",
            "+ \"voff=\\(pair(visOffsetFieldBit, event.visibleOffsetX, event.visibleOffsetY)) \"",
            "+ \"rm=n/a\"",
        ].joined(separator: " ")
        #expect(src.contains(line))
        // The gate helper itself: bit absent renders "n/a", never a misleading (0,0).
        #expect(src.contains("func pair(_ bit: UInt32, _ x: Int32, _ y: Int32) -> String { ff & bit != 0 ? \"(\\(x),\\(y))\" : \"n/a\" }"))
        #expect(src.contains("let clientAreaOffsetBit: UInt32 = 0x0000_4000"))
        #expect(src.contains("let wndClientDeltaBit: UInt32 = 0x0000_8000"))
    }

    @Test("window-smoke emits one line per window's FIRST create, and per update carrying EITHER bit (not both)")
    func smokeEmissionGate() throws {
        let src = try source("Tools/window-smoke/main.swift")
        #expect(src.contains("let clientRectBits: UInt32 = 0x0000_4000 | 0x0000_8000"))
        let gate = [
            "if event.kind == .windowCreate, !clientRectCreateLogged.contains(event.windowId) {",
            "clientRectCreateLogged.insert(event.windowId) print(Self.clientRectLine(for: event))",
            "} else if event.kind == .windowUpdate, event.fieldFlags & clientRectBits != 0 {",
            "print(Self.clientRectLine(for: event)) }",
        ].joined(separator: " ")
        #expect(src.contains(gate))
        #expect(occurrences(of: "print(Self.clientRectLine(for: event))", in: src) == 2)
    }

    @Test("MEASUREMENT ONLY: no file of the rendering package, and no outbound-geometry path, reads any of the four")
    func nothingConsumesThemYet() throws {
        var files = try swiftFiles(under: "App/RemoteWindowRendering")
        // The count is asserted so a MOVE fails loudly. Without it, renaming or relocating the
        // package would leave this pin iterating an empty list and passing while checking nothing
        // -- the vacuous-pin failure mode, which is worse than no pin because it reads as covered.
        #expect(files.count >= 5, "App/RemoteWindowRendering/ listed \(files.count) Swift file(s): \(files)")
        // The geometry arithmetic itself: not in that package, and the other half of the claim.
        files.append("Packages/MacdowsCore/Sources/MacdowsCore/WindowGeometry.swift")
        for file in files {
            let src = try source(file)
            for name in ["clientOffsetX", "clientOffsetY", "windowClientDeltaX", "windowClientDeltaY"] {
                #expect(occurrences(of: name, in: src) == 0, "\(file) mentions \(name) -- this step wires nothing")
            }
        }
    }
}
