import Foundation
import Testing

// ADR-0017 §4 row A2 (owner ruling 2026-09-08 00:55 "开 A2 车道"; adr/0005 §2): the RDPGFX
// decode path must be installed when the channel comes up -- `gdi_graphics_pipeline_init_ex`
// nulls `SurfaceCommand`/`UpdateSurfaces` when `DeactivateClientDecoding` is TRUE, and the
// symptom of an upstream drift there is "black window, zero errors". Until this lane the guard
// was `WINPR_ASSERT`, i.e. libc `assert()`: it ABORTS THE WHOLE PROCESS instead of refusing the
// session, it disappears under any build configuration that defines NDEBUG (this project's
// Release does NOT define it today -- gate a2-gfx-invariant r1 verified that by compiling and
// running an assert under the Release flags -- but nothing pins that, and Xcode's own release
// templates do define it), and it cannot be exercised headlessly. The explicit form refuses the
// session and SURFACES a distinct error (`-lastConnectError`) so the App re-enables Connect and
// shows the reason instead of sitting at "Connecting..." forever (gate r1 B-1).
//
// Two kinds of pin, on purpose (mirrors the pwsh suite's static pins accepted in
// snapshot-window-gate-r1 / snapshot-clock-gate-r1):
//   * behaviour of the pure predicate `CRBGfxDecodePathIntact` (sibling file, needs the
//     bridging header) -- what "intact" means;
//   * source-text pins over the call sites (`App/CRBridge/CRSession.mm` RDPGFX branch and its
//     T_rdp thread epilogue, `Tools/rail-probe/rail-probe.c` --decode branch and main loop):
//     the predicate is CALLED, the failure path ABORTS the connection AND is SURFACED (flag ->
//     `lastConnectError` / non-zero probe result), and the assert form is gone. A predicate
//     nobody calls pins nothing (the About-target lane's lesson, review about-target-r1 I-1).
// Matching collapses whitespace runs to one space and cuts blocks at their own closing brace,
// so a harmless reformat does not false-fail and a moved boundary is reported, not swallowed
// (gate r1 m-1).

private func repoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func source(_ relative: String) throws -> String {
    let raw = try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    // Collapse every whitespace run (incl. newlines) to one space: pins are about tokens, not layout.
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The brace-delimited block that follows `anchor`: from the first `{` after the anchor to its
/// matching `}`. Nil when the anchor or a balanced block cannot be found (reported by the caller).
private func block(after anchor: String, in src: String) -> Substring? {
    guard let a = src.range(of: anchor), let open = src[a.upperBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var i = open
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { return src[open...i] } }
        i = src.index(after: i)
    }
    return nil
}

@Suite("GFX decode-path invariant (ADR-0017 §4 A2)")
struct GfxDecodePathInvariantSourcePins {
    @Test("CRSession.mm no longer guards the decode path with WINPR_ASSERT")
    func bridgeHasNoAssertGuard() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        #expect(!src.contains("WINPR_ASSERT(gfx->SurfaceCommand"))
        #expect(!src.contains("WINPR_ASSERT(gfx->UpdateSurfaces"))
    }

    @Test("CRSession.mm's RDPGFX branch calls the predicate before installing hooks, flags the refusal and aborts")
    func bridgeCallsPredicateFlagsAndAborts() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        guard let branch = block(after: "strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0", in: src) else {
            Issue.record("RDPGFX branch block not found"); return
        }
        #expect(branch.contains("CRBGfxDecodePathIntact("))
        #expect(branch.contains("p->decodePathRefused = TRUE;"))
        #expect(branch.contains("freerdp_abort_connect_context(&p->common.context);"))
        if let check = branch.range(of: "CRBGfxDecodePathIntact("),
           let hook = branch.range(of: "gfx->MapSurfaceToWindow = crb_gfx_map_surface_to_window") {
            #expect(check.lowerBound < hook.lowerBound)
        } else {
            Issue.record("predicate call or hook install not found in the RDPGFX branch")
        }
    }

    @Test("CRSession.mm's T_rdp thread surfaces the refusal as a distinct -lastConnectError (not a silent disconnect)")
    func bridgeSurfacesRefusal() throws {
        let src = try source("App/CRBridge/CRSession.mm")
        guard let thread = block(after: "static void *crb_rdp_thread_main(void *arg)", in: src) else {
            Issue.record("crb_rdp_thread_main block not found"); return
        }
        #expect(thread.contains("decodePathRefused"))
        #expect(thread.contains("crb_decode_path_refusal_error("))
        // The refusal error must be assigned on the NORMAL-loop-exit path -- after the
        // `while (!freerdp_shall_disconnect_context` loop and before the DISCONNECTED sentinel
        // is posted -- because the DVC (and so the check) comes up after freerdp_connect
        // returned TRUE, and that path exits the loop with a clean last error. An assignment
        // that exists only on the connect-failure path (earlier in the function) does not
        // count: gate r1 mutant M6 removed the epilogue one and an order-only pin survived.
        guard let loop = thread.range(of: "while (!freerdp_shall_disconnect_context(instance->context))"),
              let post = thread.range(of: "ev.type = CRDPQ_EVENT_DISCONNECTED;") else {
            Issue.record("event loop or DISCONNECTED post not found in crb_rdp_thread_main"); return
        }
        let epilogue = thread[loop.upperBound..<post.lowerBound]
        #expect(epilogue.contains("session.lastConnectError = crb_decode_path_refusal_error("))
    }

    @Test("rail-probe's --decode branch flags and aborts, and the main loop turns the flag into a non-zero result")
    func probeDecodeBranchAbortsAndFails() throws {
        let src = try source("Tools/rail-probe/rail-probe.c")
        guard let decode = block(after: "if (p->cfg.decode)", in: src) else {
            Issue.record("--decode block not found"); return
        }
        #expect(decode.contains("gfx->SurfaceCommand == NULL"))
        #expect(decode.contains("gfx->UpdateSurfaces == NULL"))
        #expect(decode.contains("p->decodePathRefused = TRUE;"))
        #expect(decode.contains("freerdp_abort_connect_context(&p->common.context);"))
        guard let loop = block(after: "static DWORD probe_main_loop(freerdp* instance, probeContext* p)", in: src) else {
            Issue.record("probe_main_loop block not found"); return
        }
        #expect(loop.contains("p->decodePathRefused"))
        #expect(loop.contains("DecodePathRefused"))
    }
}
