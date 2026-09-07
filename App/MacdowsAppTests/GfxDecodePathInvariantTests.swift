import Foundation
import Testing

// ADR-0017 §4 row A2 (owner ruling 2026-09-08 00:55 "开 A2 车道"; adr/0005 §2): the RDPGFX
// decode path must be installed when the channel comes up -- `gdi_graphics_pipeline_init_ex`
// nulls `SurfaceCommand`/`UpdateSurfaces` when `DeactivateClientDecoding` is TRUE, and the
// symptom of an upstream drift there is "black window, zero errors". Until this lane the
// guard was `WINPR_ASSERT`, which compiles to nothing under NDEBUG (Xcode Release), so the
// shipped binary had NO guard. These pins hold the guard in its explicit form.
//
// Two kinds of pin, on purpose (mirrors the pwsh suite's static pins accepted in
// snapshot-window-gate-r1 / snapshot-clock-gate-r1):
//   * behaviour of the pure predicate `CRBGfxDecodePathIntact` (sibling file, needs the
//     bridging header) -- what "intact" means;
//   * source-text pins over the two call sites (`App/CRBridge/CRSession.mm` RDPGFX branch,
//     `Tools/rail-probe/rail-probe.c` --decode branch): the predicate is CALLED and the
//     failure path ABORTS the connection, and the NDEBUG-transparent WINPR_ASSERT form is gone.
//     A predicate nobody calls pins nothing (the About-target lane's lesson, review
//     about-target-r1 I-1).
// Reading the sources by path is safe here: this bundle compiles the bridge sources directly
// and `#filePath` is the test file's own location, so the repo root is two directories up.

private func repoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func source(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// The RDPGFX branch of `crb_on_channel_connected`: from the channel-name comparison to the
/// next `else`.
private func gfxBranch(of src: String) -> Substring {
    guard let start = src.range(of: "strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0") else { return "" }
    let tail = src[start.upperBound...]
    guard let end = tail.range(of: "\n    else") else { return tail }
    return tail[..<end.lowerBound]
}

@Suite("GFX decode-path invariant (ADR-0017 §4 A2)")
struct GfxDecodePathInvariantSourcePins {
    @Test("CRSession.mm no longer guards the decode path with WINPR_ASSERT (a no-op under NDEBUG)")
    func bridgeHasNoAssertGuard() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        #expect(!src.contains("WINPR_ASSERT(gfx->SurfaceCommand"))
        #expect(!src.contains("WINPR_ASSERT(gfx->UpdateSurfaces"))
    }

    @Test("CRSession.mm's RDPGFX branch calls the predicate and aborts the connection when it fails")
    func bridgeCallsPredicateAndAborts() throws {
        let branch = gfxBranch(of: try source("App/CRBridge/CRSession.mm"))
        #expect(branch.contains("CRBGfxDecodePathIntact("))
        #expect(branch.contains("freerdp_abort_connect_context(&p->common.context)"))
        // The check must run before the bridge installs its own hooks on the context.
        if let check = branch.range(of: "CRBGfxDecodePathIntact("),
           let hook = branch.range(of: "gfx->MapSurfaceToWindow = crb_gfx_map_surface_to_window") {
            #expect(check.lowerBound < hook.lowerBound)
        } else {
            Issue.record("predicate call or hook install not found in the RDPGFX branch")
        }
    }

    @Test("rail-probe's --decode branch refuses a session whose decode path is not installed")
    func probeDecodeBranchAborts() throws {
        let src = try source("Tools/rail-probe/rail-probe.c")
        guard let decode = src.range(of: "if (p->cfg.decode)") else {
            Issue.record("--decode branch not found"); return
        }
        let after = src[decode.upperBound...]
        let window = after.prefix(1200)
        #expect(window.contains("gfx->SurfaceCommand == NULL"))
        #expect(window.contains("gfx->UpdateSurfaces == NULL"))
        #expect(window.contains("freerdp_abort_connect_context(&p->common.context)"))
    }
}
