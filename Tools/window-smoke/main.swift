// window-smoke: W4b's real-host pixel-path verification harness. Unlike Tools/bridge-smoke
// (headless, no AppKit), this drives a real NSApplication so RemoteWindowRegistry/
// RemoteWindow actually create and composite on-screen NSWindows, connects to the real
// Windows host described by ~/.config/macdows/host.env (or WIN_HOST/WIN_USER/WIN_PASS
// env vars, which take priority -- same convention as bridge-smoke and Tools/rail-probe),
// launches winver.exe, runs for 25 seconds, gives an external screenshot-capturer time to
// act at the 15s mark (see below -- this process does NOT reliably capture its own
// screenshot), then runs the full shutdown protocol and prints a hard-assertion summary
// (exit code reflects pass/fail, matching bridge-smoke's own H4 discipline).
//
// Screenshot capture is NOT this process's own responsibility, and not
// run-window-smoke.command's either -- confirmed empirically (W4b verification): Screen
// Recording TCC is evaluated against the *directly capturing* process's own code identity,
// which does not propagate through a launch chain the way local-network access does. Under
// this repo's Terminal-relay verification setup, NEITHER this process's own screencapture
// attempt NOR the launcher script's own (run as a child of a freshly-relaunched
// Terminal.app window) succeed -- both reliably fail with "could not create image from
// display". The only identity in that setup confirmed to hold the permission is the
// orchestrating operator's own already-running shell process, invoked directly, timed via
// sleep against this process's own known 15s mark. `finish()` below verifies the evidence
// file was actually produced *by this run* (mtime after this process's own launch, correct
// PNG header, minimum size) rather than trusting any particular call's exit code, so
// whichever process ends up doing the actual capture, a stale/leftover file from an earlier
// run can never masquerade as this run's own evidence.
//
// Never prints WIN_HOST/WIN_USER/WIN_PASS raw values (red line) -- only their lengths.
//
// Refuses to dial anything outside the owner's own lab network: MacdowsCore.LabBoundary (the
// in-process mirror of Scripts/lib.sh's crdp_assert_lab_boundary) runs after the credentials
// resolve and before any CRSession exists, and exits 78 on a refusal. That gate lives here, and
// not only in run-window-smoke.command, because this binary is directly runnable out of
// DerivedData without the launcher.
//
// `WINDOW_SMOKE_SELFTEST=1` (M1 L9) runs this harness's own offline decision logic against
// fixtures and exits, touching no credential, no host.env and no socket -- see
// `WindowSmokeGateSelfTest` below for what it covers and why a tool target needs it at all.

import AppKit
import CoreGraphics
import Foundation
import MacdowsCore

// MARK: - The offline decision logic this harness gates on (M1 L9; adr/0015 §6)
//
// Everything between here and `WindowSmokeGateSelfTest` is PURE: no AppKit, no session, no
// clock, no host. It is lifted out of `WindowSmokeDelegate` for one reason -- `window-smoke` is
// a tool target with no test bundle, so decision arithmetic that lives inside the delegate is
// unreachable by `swift test` and unfalsifiable by anything short of a live host, which is
// exactly the shape adr/0015 §9's L9 row must not have.
//
// Two rules this section is written to:
//  1. **Every geometry conversion delegates to `MacdowsCore.WindowGeometry` / `DisplayTopology`**
//     -- the already-tested entries -- and never re-implements a flip here. `evaluateMoveResizeLeg`'s
//     round-7 note records what a second, ad hoc implementation costs.
//  2. **Every decision made here is exercised offline** by `WindowSmokeGateSelfTest`, which
//     `WINDOW_SMOKE_SELFTEST=1` runs below, BEFORE this file reads a credential, consults the lab
//     boundary or constructs a session. That mode is the mutation-testing surface for the two
//     load-bearing choices in this file (the tolerance's value, and the space the comparison
//     happens in); see the self-test's own header.

/// The move/resize round-trip gate: did an observed window rect reach the rect this harness
/// asked for, judged **in remote pixels** (adr/0015 §6.1)?
enum MoveResizeGate {
    /// **The geometry tolerance. UNIT: remote px** (adr/0015 §1's vocabulary; §6.1 pins the unit,
    /// `docs/plans/phase3.md:131` pins the gate this replaces).
    ///
    /// **VALUE = 0, and the value is the OWNER's, not this harness's.** U6, ruled 2026-09-01
    /// 19:19 (recorded at adr/0015 §6's ruling note and `docs/plans/phase3.md:131`): the pre-M1
    /// gate was "position and size each within `<= 1`", compared in mac points; M1 both changes
    /// the unit and tightens the number, and the tightening half is a pricing decision that
    /// belongs to the owner because only a live run can pay it.
    ///
    /// **RE-OPEN PATH, deliberately left visible rather than pre-applied:** if the live
    /// checkpoints (C-1/C-3) show 0 is not reachable on a real host, `docs/plans/phase3.md:131`
    /// is the clause to go back to the owner with -- it allows `<= 1` remote px, but only WITH
    /// the jitter source recorded, i.e. "we measured N remote px of jitter and it comes from X",
    /// never a bare loosening. Nothing in this file may raise this number on its own.
    ///
    /// Lives here, in the tool, rather than in `MacdowsCore`: it prices a smoke-test gate, not a
    /// library contract. The package's own round-trip identities are asserted with `==` and no
    /// tolerance at all (adr/0015 §9's offline-acceptance item 2), which is the stricter,
    /// separate claim.
    static let toleranceInRemotePixels: Double = 0

    /// Whether a leg "reached its target and stayed there". Three states, because the old
    /// `Bool` had only two and lied in the third: on the 2026-09-02 real-host run
    /// (env-202609-14) both red legs printed "settled without oscillation" as PASS although the
    /// rect never matched -- the unmatched branches hard-coded `false`, so the assertion could
    /// not fail (review resize-live-r1 I1, r2). `unjudgeable` is what those legs actually were.
    enum OscillationVerdict: Equatable {
        /// The leg could not be judged: no frozen topology to judge in, no geometry-carrying
        /// observation at all, or observations that never matched inside the budget -- in each
        /// case "did it stay there" has no referent. `observations` = how many geometry-carrying
        /// updates were seen for the leg (0 = none); WHICH of the three causes applies is in the
        /// leg's own detail text, not here (review oscillation-verdict-r1 I-1).
        case unjudgeable(observations: Int)
        /// Matched, and every later observation still matched.
        case none
        /// Matched, then at least one later observation diverged again.
        case oscillated

        var isOscillated: Bool { self == .oscillated }
        var text: String {
            switch self {
            case .unjudgeable(let n): return "unjudgeable (\(n) observation(s); cause in the leg's detail)"
            case .none: return "none"
            case .oscillated: return "oscillated"
            }
        }
    }

    /// Pure form of the leg's oscillation scan: `rectPassedPerObservation[i]` is whether the
    /// i-th observed rect passed the RECT half. Failures BEFORE the first match are the leg
    /// still travelling and are not oscillation; only a later divergence is.
    static func oscillationVerdict(rectPassedPerObservation: [Bool]) -> OscillationVerdict {
        guard let firstMatch = rectPassedPerObservation.firstIndex(of: true) else {
            return .unjudgeable(observations: rectPassedPerObservation.count)
        }
        return rectPassedPerObservation[(firstMatch + 1)...].contains(false) ? .oscillated : .none
    }

    /// Whether a `surfaceMapped` event is an observation for the move/resize leg in flight: the
    /// registry re-applies the target's frame when its surface remap lands ("mapped is
    /// canonical", `RemoteWindowRegistry.surfaceMapped` handling), and the leg must sample that
    /// re-applied content rect too -- on the 2026-09-02 F0 runs the only sample was taken at the
    /// WindowUpdate, still carrying the old mapped size (F0-2, docs/upgrade-gate/
    /// 2026-09-f0-control-live.md §3 item 3). Pure so the self-test can pin the gating.
    static func remapObservationApplies(eventWindowId: UInt32, targetWindowId: UInt32?, legAwaitingSettle: Bool) -> Bool {
        guard legAwaitingSettle, let targetWindowId else { return false }
        return eventWindowId == targetWindowId
    }

    /// One leg's paired verdict (adr/0015 §6.3): a RECT comparison and the single-POINT reverse
    /// mapping of the same target's top-left corner, kept as two separately-named results.
    ///
    /// **WHAT THE PAIRING DOES AND DOES NOT DO — stated exactly, because an earlier version of this
    /// comment over-claimed it and review (rev-L9 I-2) disproved the claim by brute force.**
    ///
    /// The point half computes the same corner through a different package entry:
    /// `WindowGeometry.windowsPoint` has **no `- height` term** (`WindowGeometry.swift`'s own note,
    /// adr/0015 §4.5) and is the entry real mouse input travels (`RemoteWindowRegistry`'s
    /// `windowsPoint` call site). But on **today's** formulas the two are algebraically identical
    /// for a rect's top-left -- rect: `(H − macY − macH) * s`; point on `(x, macY + macH)`:
    /// `(H − (macY + macH)) * s` -- so:
    ///
    ///  * it is NOT true that a live sign/anchor error in `windowsPoint` would show up here as a
    ///    disagreement. A uniform error cancels in the observed-vs-target *delta*, and today's
    ///    `rasterScale == 1` cancels a scale-placement error too. Review brute-forced 3M random
    ///    triples: the ONLY rect-pass/point-fail cases are IEEE-754 association artifacts of ~1.1e-13
    ///    (see `withinToleranceInRemotePixels`).
    ///  * what the pairing DOES deliver is threefold, and all three are real: (1) adr/0015 §6.3's
    ///    literal requirement -- both comparisons computed and asserted as a named pair, the leg
    ///    failing if either fails, the output naming which; (2) a **guard against future divergence**
    ///    of the two package entries, which are separate code paths that nothing else in the tree
    ///    forces to agree; (3) offline, the point half's own **numbers** are pinned by
    ///    `WindowSmokeGateSelfTest.pointPathPinsItsOwnNumbers` at 1x and 2x -- that pin is what
    ///    actually caught a package-side `windowsPoint` scale-placement regression in review (R1),
    ///    invisible at 1x.
    ///
    /// The honest summary: the point half's live value is contingent (it fires only if the two
    /// package entries ever stop agreeing), its offline value is demonstrated. Neither is the
    /// "detects present-day anchor bugs" claim this comment used to make.
    struct LegVerdict: Equatable {
        /// The observed rect, converted into Windows space (remote px) through the topology.
        let observedInRemotePixels: WindowsRect
        /// The target rect this leg asked for, same conversion, same topology.
        let targetInRemotePixels: WindowsRect
        /// The observed rect's TOP-LEFT corner, taken through the POINT path instead.
        let observedTopLeftViaPointPath: WindowsPoint
        /// The target rect's top-left corner through the point path.
        let targetTopLeftViaPointPath: WindowsPoint
        /// `true` when width/height are out of scope for this leg -- the move leg's round-6
        /// finding (a pure move's size is the server's own prerogative).
        let positionOnly: Bool
        let rectCheckPassed: Bool
        let pointCheckPassed: Bool

        /// The leg's verdict: **a leg passes only if BOTH halves pass** (§6.3).
        var passed: Bool { rectCheckPassed && pointCheckPassed }

        /// Names WHICH half failed, so a red run never leaves that to be inferred.
        ///
        /// The disagreement clause deliberately does NOT say "one of the two flips must be wrong"
        /// any more (rev-L9 I-2/M-3): the two flips are algebraically identical for a rect's
        /// top-left today, so the only *reachable* cause of a divergence at tolerance 0 is IEEE-754
        /// association (`(H − y − h)` vs `(H − (y + h))` differ by ~1e-13 for some non-dyadic
        /// inputs). The first person to see this line must not be sent hunting an anchor bug that
        /// cannot exist yet -- and must not "fix" it with an epsilon, which is a U6 re-open, not a
        /// bug fix. Both possible causes are therefore named, smallest-first.
        var pairedVerdictText: String {
            var text = "rectCheck=\(rectCheckPassed ? "PASS" : "FAIL") pointCheck=\(pointCheckPassed ? "PASS" : "FAIL")"
            if rectCheckPassed != pointCheckPassed {
                text += " -- PATHS DISAGREE about the same rect. Two possible causes, in order of "
                    + "likelihood: (a) IEEE-754 association between `(H − y − h)` and `(H − (y + h))` "
                    + "at tolerance 0 -- check whether |pointDelta − rectDelta| is ~1e-13, and if so "
                    + "this is representational, NOT an anchor bug, and NOT to be fixed with an "
                    + "epsilon (that would overturn owner ruling U6; the re-open path is "
                    + "docs/plans/phase3.md:131); (b) the two MacdowsCore entries "
                    + "(`windowsRect` / `windowsPoint`) have genuinely diverged, which is the future "
                    + "regression this pair exists to catch (adr/0015 §6.3)"
            }
            return text
        }

        /// The measured error, in remote px, next to the tolerance it was judged against.
        var deltaText: String {
            let dx = observedInRemotePixels.x - targetInRemotePixels.x
            let dy = observedInRemotePixels.y - targetInRemotePixels.y
            let dw = observedInRemotePixels.width - targetInRemotePixels.width
            let dh = observedInRemotePixels.height - targetInRemotePixels.height
            let pdx = observedTopLeftViaPointPath.x - targetTopLeftViaPointPath.x
            let pdy = observedTopLeftViaPointPath.y - targetTopLeftViaPointPath.y
            return "rectDelta=(dx=\(Self.fmt(dx)),dy=\(Self.fmt(dy))"
                + (positionOnly ? "" : ",dw=\(Self.fmt(dw)),dh=\(Self.fmt(dh))")
                + ") pointDelta=(dx=\(Self.fmt(pdx)),dy=\(Self.fmt(pdy))) remote px"
                + " tolerance=\(Self.fmt(MoveResizeGate.toleranceInRemotePixels)) remote px (U6)"
                + (positionOnly ? " [position-only leg: size is the server's prerogative, round 6]" : "")
        }

        private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
    }

    /// mac screen space is bottom-left-origin/Y-up, so a rect's **top** edge -- the one Windows
    /// space anchors on -- is `y + height`. Written once, here, rather than at each caller.
    static func macTopLeft(of rect: MacRect) -> MacPoint {
        MacPoint(x: rect.x, y: rect.y + rect.height)
    }

    /// `|a - b| <= tolerance`, both operands already in remote px. The comparison space is the
    /// whole point: at `rasterScale == 1` remote px and mac pt are numerically identical, so this
    /// function's inputs are what pins the unit, not its arithmetic.
    ///
    /// **THIS EXPRESSION IS THE GATE, not `toleranceInRemotePixels` alone** (rev-L9 I-1). Asserting
    /// the constant's value proves nothing about the threshold actually in force: adding an epsilon
    /// HERE loosens owner ruling U6 while every "the tolerance is 0" assertion stays green. That is
    /// why `WindowSmokeGateSelfTest` pins the *effective* threshold with sub-remote-pixel rejection
    /// cases (a 0.25 remote px error, and 1e-4/1e-7 through this function directly) rather than
    /// only pinning the symbol. Any edit that widens this comparison -- by any amount, under any
    /// justification -- is an owner decision, and the path for it is `docs/plans/phase3.md:131`.
    ///
    /// The one thing that will genuinely tempt such an edit, recorded so it is refused knowingly
    /// (rev-L9 M-3): at tolerance 0 the rect flip `(H − y − h)` and the point flip `(H − (y + h))`
    /// are algebraically equal but not bit-equal in IEEE-754, so non-dyadic inputs can differ by
    /// ~1e-13 and produce a false red. Today that is essentially unreachable -- observed rects come
    /// from integer RAIL values and AppKit targets on 1x hardware are integral or half-integral, all
    /// exactly representable -- and adr/0015 §6.4(a) already owns the trigger that would change it
    /// (a non-power-of-two `rasterScale` invalidates the 0-tolerance premise and must go back to the
    /// owner). So: diagnose it, report it, do not absorb it.
    static func withinToleranceInRemotePixels(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= toleranceInRemotePixels
    }

    /// Judges one observed rect against one target rect. **Both conversions go through the
    /// session's frozen topology** -- the same value the desktop size was derived from (adr/0015
    /// §5.A.4's same-source invariant), never a fresh screen read.
    static func evaluate(
        observed: MacRect, target: MacRect, in topology: DisplayTopology, positionOnly: Bool
    ) -> LegVerdict {
        let observedRect = WindowGeometry.windowsRect(from: observed, in: topology)
        let targetRect = WindowGeometry.windowsRect(from: target, in: topology)
        let observedPoint = WindowGeometry.windowsPoint(from: macTopLeft(of: observed), in: topology)
        let targetPoint = WindowGeometry.windowsPoint(from: macTopLeft(of: target), in: topology)

        // Position first, in Windows space, for both legs. Round 7's finding is why: mac-space Y
        // entangles height (`macRect.y = primaryHeight - windowsY - height`), so comparing raw mac
        // `y` for a rect whose height the server remapped mid-leg compares two different physical
        // quantities. The Windows-space top edge is height-invariant by construction.
        var rectPassed = withinToleranceInRemotePixels(observedRect.x, targetRect.x)
            && withinToleranceInRemotePixels(observedRect.y, targetRect.y)
        if !positionOnly {
            rectPassed = rectPassed
                && withinToleranceInRemotePixels(observedRect.width, targetRect.width)
                && withinToleranceInRemotePixels(observedRect.height, targetRect.height)
        }
        let pointPassed = withinToleranceInRemotePixels(observedPoint.x, targetPoint.x)
            && withinToleranceInRemotePixels(observedPoint.y, targetPoint.y)

        return LegVerdict(
            observedInRemotePixels: observedRect,
            targetInRemotePixels: targetRect,
            observedTopLeftViaPointPath: observedPoint,
            targetTopLeftViaPointPath: targetPoint,
            positionOnly: positionOnly,
            rectCheckPassed: rectPassed,
            pointCheckPassed: pointPassed
        )
    }
}

/// F2's visible half (`docs/plans/phase3.md:132`, adr/0015 §8's "measure, don't consume"): what
/// the server's GFX surface maps actually said their **target** size was, aggregated over a run.
///
/// L3 promoted `targetWidth`/`targetHeight` from a log line to an event field; this is the
/// consumer that makes the measurement visible. **Nothing here may influence rendering, sizing or
/// coordinate conversion** -- that is W3's, and `crdpq.h`'s own note on these fields forbids it.
///
/// SENTINEL HANDLING, verbatim from `crdpq.h`/`CRSession.h`: `(0, 0)` means "no target hint
/// accompanied this map" (the plain PDU, which has no such fields on the wire), and a consumer
/// "must therefore check BOTH members against 0 before using either". So a sentinel pair is
/// **counted, never treated as an observation** -- folding it in would report a 0x0 target size
/// that no server ever sent. A pair with exactly ONE zero is neither: it is a malformed hint
/// (`crdpq.h` notes the protocol does not forbid a server sending one and FreeRDP validates
/// neither field), counted separately so it can never hide inside either bucket.
struct GfxTargetHintTally {
    struct SizeInRemotePixels: Hashable {
        let width: UInt32
        let height: UInt32
    }

    /// Every SURFACE_MAPPED event seen, both PDU variants.
    private(set) var surfaceMapEventsSeen = 0
    /// Events carrying the `(0, 0)` sentinel, i.e. the plain variant.
    private(set) var hintAbsentEvents = 0
    /// Events carrying exactly one zero dimension -- unusable, and not a sentinel.
    private(set) var degenerateHintEvents = 0
    /// Distinct usable target sizes, with the number of events that carried each.
    private(set) var observations: [SizeInRemotePixels: Int] = [:]

    var usableHintEvents: Int { observations.values.reduce(0, +) }

    mutating func record(targetWidthInRemotePixels: UInt32, targetHeightInRemotePixels: UInt32) {
        surfaceMapEventsSeen += 1
        if targetWidthInRemotePixels == 0, targetHeightInRemotePixels == 0 {
            hintAbsentEvents += 1
            return
        }
        if targetWidthInRemotePixels == 0 || targetHeightInRemotePixels == 0 {
            degenerateHintEvents += 1
            return
        }
        let size = SizeInRemotePixels(width: targetWidthInRemotePixels, height: targetHeightInRemotePixels)
        observations[size, default: 0] += 1
    }

    /// The `[gfx] target=` line, in one of its two well-formed shapes.
    ///
    /// **It is never empty and never absent** (`docs/plans/phase3.md:132` gates on it): "absent
    /// because no scaled map ever arrived" and "absent because the measurement itself fell off"
    /// would be indistinguishable to a log reader, and the second is precisely the regression
    /// this line exists to make impossible. The counters ride along in both shapes so the
    /// denominator is always stated.
    var summaryLine: String {
        var line = "[gfx] target= "
        if observations.isEmpty {
            line += surfaceMapEventsSeen == 0
                ? "none (no surface-map events observed this run)"
                : "none (no usable target hint on any of \(surfaceMapEventsSeen) surface-map event(s) -- "
                    + "\(hintAbsentEvents) carried the (0,0) sentinel, i.e. the plain MapSurfaceToWindow PDU"
                    + (degenerateHintEvents > 0
                        ? ", \(degenerateHintEvents) carried an unusable one-zero hint" : "")
                    + ")"
        } else {
            // Deterministic order (count desc, then size) so two runs' lines are diffable.
            let ordered = observations.sorted {
                $0.value != $1.value ? $0.value > $1.value
                    : ($0.key.width != $1.key.width ? $0.key.width < $1.key.width : $0.key.height < $1.key.height)
            }
            line += ordered.map { "\($0.key.width)x\($0.key.height) remote px (n=\($0.value))" }
                .joined(separator: ", ")
        }
        line += " [surfaceMapEvents=\(surfaceMapEventsSeen) hintAbsent=\(hintAbsentEvents) "
            + "usableHint=\(usableHintEvents)"
        if degenerateHintEvents > 0 {
            line += " degenerateHint=\(degenerateHintEvents)"
        }
        return line + "] (measurement only, adr/0015 §8: nothing branches on it in M1)"
    }
}

/// M1's live acceptance item 1 (`docs/plans/phase3.md:130`) — **F1, "red today, green on
/// delivery"**: an `NSWindow`'s content **backing-pixel** size must equal the GFX `mappedSize`
/// that window was given.
///
/// WHY THIS MEASUREMENT IS THE MILESTONE'S REASON TO EXIST. `mappedSize` is **remote px** (the GFX
/// map order's own unit, `crdpq.h`); an `NSWindow`'s content backing size is **backing px** =
/// mac pt x that window's `backingScaleFactor`. adr/0015 §1's identity `remote px == backing px`
/// is exactly the claim these two numbers test, and today nothing enforces it: the layer's
/// `contentsGravity = .resize` (`RemoteWindow.swift:420`) stretches a remote-px raster into
/// whatever backing store AppKit gave the view, so on a 2x display the two differ by exactly the
/// `backingScaleFactor` and the picture is silently upsampled rather than sharp.
///
/// **EXPECTED VERDICTS, stated up front so a RED is not mistaken for a regression:**
///  * **1x display (today's only hardware, `docs/plans/phase3.md:219`): GREEN.** `backingScaleFactor`
///    is 1, so backing px and mac pt are the same number and the identity holds trivially.
///  * **2x display: RED, and that RED is the deliverable** — it is 验收-真机-1 itself
///    (`docs/plans/phase3.md:130`: "今天必红、转绿即交付"). `RemoteWindow.present`'s own W3-TRIGGER
///    note (`RemoteWindow.swift:1120-1129`) names the mechanism and the factor: moving the window
///    onto a Retina display makes `backingPixelsPerPoint != 1` while `remotePixelsPerPoint` stays
///    1 (`DisplayScale.retinaBackingOnly`), "and it is the `backingScaleFactor` factor phase3.md §1
///    F1 names; the 'red today, green on delivery' assertion … is the measurement for THIS
///    trigger". A GREEN on a 2x display before W3 lands would mean the measurement is broken, not
///    that the bug is fixed.
///
/// **MEASUREMENT ONLY in M1 — this verdict must never move `ok` or the exit code.** M1 is a
/// measurement batch; touching `contentsScale`/backing alignment is W3's (adr/0015 §8), and this
/// harness's own gate would otherwise go permanently red on the very display the checkpoint needs
/// to run on. W3 is what promotes this line into the gate.
///
/// **The comparison is exact.** It measures a factor-of-two discrepancy, not jitter, so there is
/// no tolerance here and none may be added: unlike `MoveResizeGate`, whose 0 is an owner-priced
/// gate value (U6), this one is 0 because any nonzero difference already means the two spaces
/// disagree. Deliberately NOT rounded either -- rounding to the nearest backing pixel would be a
/// tolerance wearing a different hat, and AppKit's `convertToBacking` returns integral sizes for
/// the integral content rects this path produces anyway, so rounding would buy nothing and hide
/// a genuine sub-pixel disagreement.
enum F1BackingVsMapped {
    enum Verdict: String {
        case green = "GREEN"
        case red = "RED"
    }

    /// One window's pairing at present time. All four size fields are stored as `Double` because
    /// that is what AppKit and the GFX payload hand over; the verdict compares them exactly.
    struct Observation: Equatable {
        let windowId: UInt32
        /// `contentView.convertToBacking(bounds).size` -- **backing px**.
        let backingWidthInBackingPixels: Double
        let backingHeightInBackingPixels: Double
        /// The same content rect in **mac pt**, kept only so the line can state the implied scale.
        let contentWidthInPoints: Double
        let contentHeightInPoints: Double
        /// `RemoteWindowRegistry.debugMappedSize` -- the GFX map order's `mappedWidth/Height`,
        /// **remote px**.
        let mappedWidthInRemotePixels: Double
        let mappedHeightInRemotePixels: Double

        /// EXACT equality, both axes. See the type's own note on why there is no tolerance and no
        /// rounding.
        var verdict: Verdict {
            backingWidthInBackingPixels == mappedWidthInRemotePixels
                && backingHeightInBackingPixels == mappedHeightInRemotePixels ? .green : .red
        }

        /// Derived from this window's own conversion rather than read from `NSScreen`/`NSWindow`:
        /// adr/0015 §5.A.5 confines screen reads to the topology provider, and this number is a
        /// diagnostic label, never a geometry input. `nil` for a zero-width content rect.
        var impliedBackingScale: Double? {
            contentWidthInPoints > 0 ? backingWidthInBackingPixels / contentWidthInPoints : nil
        }

        var line: String {
            let scale = impliedBackingScale.map { String(format: "%.2f", $0) } ?? "unknown"
            return "[f1] windowId=\(windowId)"
                + " backing=\(Self.fmt(backingWidthInBackingPixels))x\(Self.fmt(backingHeightInBackingPixels)) backing px"
                + " mapped=\(Self.fmt(mappedWidthInRemotePixels))x\(Self.fmt(mappedHeightInRemotePixels)) remote px"
                + " content=\(Self.fmt(contentWidthInPoints))x\(Self.fmt(contentHeightInPoints)) mac pt"
                + " impliedBackingScale=\(scale)"
                + " delta=(\(Self.fmt(backingWidthInBackingPixels - mappedWidthInRemotePixels)),"
                + "\(Self.fmt(backingHeightInBackingPixels - mappedHeightInRemotePixels)))"
                + " verdict=\(verdict.rawValue)"
        }

        /// Integral values print without a decimal tail; anything fractional keeps three places, so
        /// a sub-pixel disagreement is visible rather than rounded away in the log too.
        static func fmt(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
        }
    }
}

/// Run-scoped record of the F1 measurement: dedupes the per-window line (a 60fps stream would
/// otherwise print one line per frame) and produces the one summary every run must emit.
struct F1BackingVsMappedTally {
    /// The most recent observation per window -- the dedupe key AND the summary's input, so the
    /// summary always describes the LAST state of each window rather than a first impression.
    private(set) var lastByWindow: [UInt32: F1BackingVsMapped.Observation] = [:]
    /// Every sample taken, including repeats (the denominator for "did this actually run").
    private(set) var samplesTaken = 0
    /// Windows that were RED at any point, even if a later observation went GREEN -- a verdict
    /// that flips mid-run is itself a finding, and a summary that only reported the final state
    /// would hide it.
    private(set) var everRedWindows: Set<UInt32> = []

    /// Records `observation` and returns it **only when it is worth printing** -- i.e. the first
    /// sample for that window, or one whose numbers changed since the last printed line. Returns
    /// `nil` for an unchanged repeat.
    mutating func record(_ observation: F1BackingVsMapped.Observation) -> F1BackingVsMapped.Observation? {
        samplesTaken += 1
        if observation.verdict == .red { everRedWindows.insert(observation.windowId) }
        let previous = lastByWindow[observation.windowId]
        lastByWindow[observation.windowId] = observation
        return previous == observation ? nil : observation
    }

    /// The one `[f1] summary:` line, printed on EVERY run from every terminal path -- same
    /// discipline as `GfxTargetHintTally.summaryLine`, and for the same reason: "absent because no
    /// window was ever measurable" and "absent because the measurement fell off" must not look
    /// alike, least of all on the checkpoint run this measurement exists for.
    var summaryLine: String {
        let tail = " (MEASUREMENT ONLY in M1: this verdict does not affect the exit code. "
            + "docs/plans/phase3.md:130 -- GREEN expected at 1x, RED expected on a 2x display "
            + "today and that RED is the deliverable; W3 promotes it into the gate)"
        guard !lastByWindow.isEmpty else {
            return "[f1] summary: none (no window with both a presented frame and a GFX mapped size "
                + "was observed this run; samples=\(samplesTaken))" + tail
        }
        let green = lastByWindow.values.filter { $0.verdict == .green }.count
        let red = lastByWindow.values.count - green
        let redDetail = lastByWindow.values
            .filter { $0.verdict == .red }
            .sorted { $0.windowId < $1.windowId }
            .map { "\($0.windowId): backing=\(F1BackingVsMapped.Observation.fmt($0.backingWidthInBackingPixels))x\(F1BackingVsMapped.Observation.fmt($0.backingHeightInBackingPixels)) vs mapped=\(F1BackingVsMapped.Observation.fmt($0.mappedWidthInRemotePixels))x\(F1BackingVsMapped.Observation.fmt($0.mappedHeightInRemotePixels))" }
            .joined(separator: "; ")
        return "[f1] summary: windows=\(lastByWindow.count) GREEN=\(green) RED=\(red)"
            + " samples=\(samplesTaken) everRed=\(everRedWindows.count)"
            + (redDetail.isEmpty ? "" : " red[\(redDetail)]") + tail
    }
}

/// H3's visible-window size bands, re-expressed in **remote px** (adr/0015 §6 rule 1: the unit
/// is remote px). Both bands' constants are RAIL-observed remote-pixel facts -- the 150x80 floor
/// from the 136x39 tray helper / 1009x4 edge strips / dxdiag's 478x188 progress dialog, the
/// About anchor from winver's ~536x521 dialog -- but until the C-2 checkpoint (2026-09-01) they
/// were compared against `NSWindow.frame` in mac pt, an identity that only holds at rasterScale
/// 1. In the 2x checkpoint session the About window's own F1 line measured `mapped=522x515
/// remote px content=261x258 mac pt`, i.e. the frame under comparison was about half the
/// remote-px constants, and the anchor band went red against correct behaviour (C-2 run 1's
/// only FAIL; `docs/reviews/2026-09-01-unattended/c2-checkpoint-record.md`). The frame is
/// converted through the session's FROZEN topology first -- the same `rasterScale` the desktop
/// size was derived from (§5.A.4's same-source invariant), never a fresh screen read -- and only
/// then compared to the remote-px constants. Every size-band consumer in this file goes through
/// here (`finish()`'s two asserts, `focusRotationCandidateWindows`, `runUnicodeDegradeScenario`'s
/// target lock, the extra-apps new-window count), so the constants have exactly one home.
///
/// Known limit, shared with the desktop-size derivation it mirrors: `rasterScale` is the
/// PRIMARY display's factor (adr/0015 §2 rule 2). In a non-uniform topology
/// (`isUniformScale == false`, which `DisplayTopologyProvider` already warns about) a window on a
/// secondary display converts with the primary's factor; today's hardware is single-display.
/// Offline pins: `WindowSmokeGateSelfTest`'s `sizeBand*` cases.
enum SizeBand {
    struct RemotePixelSize: Equatable {
        let width: Double
        let height: Double
    }

    /// A mac-pt frame size through the session's frozen topology. adr/0015 §3 applies
    /// `rasterScale` exactly once when turning points into remote px; this is that one
    /// multiplication, applied to a size.
    static func remotePixelSize(ofFrameSize size: CGSize, in topology: DisplayTopology) -> RemotePixelSize {
        RemotePixelSize(width: size.width * topology.rasterScale, height: size.height * topology.rasterScale)
    }

    /// Plausible-content floor (inclusive) and garbage ceiling (exclusive), remote px. The floor
    /// is 150x80, not the original 300x300: the Phase 1 acceptance matrix surfaced real, legitimate
    /// short dialogs (dxdiag's initial progress window is 478x188 against the lab host) that
    /// 300x300 wrongly rejected; 150x80 still excludes every RAIL helper class actually observed
    /// (1x1 bookkeeping windows, the 136x39 tray helper, 1009x4 edge strips) -- the HEIGHT floor is
    /// the only thing that rejects an edge strip, which is why the self-test pins each axis alone.
    ///
    /// The ceiling's history is a guardrail, not trivia. The band used to carry a 2000(pt) upper
    /// bound that existed only to independently re-catch a regression in RemoteWindowRegistry's
    /// now-removed size-only cap (`isLikelyContentWindow`, `width>=2000 && height>=1000`). Phase 2
    /// W0(1) (docs/plans/phase2.md) replaced THAT registry cap with a style/owner-based filter
    /// (adr/0008 §3), and a maximized real content window is now explicitly SUPPOSED to become a
    /// large visible RemoteWindow -- so re-imposing a 2000 ceiling here would silently reintroduce
    /// the exact regression W0(1) fixed. The desktop-container window itself ("Program Manager")
    /// is excluded by the registry's style check, not by any size heuristic in this harness, so no
    /// upper bound is needed to catch it. What remains is a garbage-value net at 10000 remote px,
    /// comfortably under RemoteWindowRegistry's own 16384 hard limit
    /// (`WindowMappability.isMappableWindow`) and loose enough that no plausible maximized window
    /// on any real display trips it.
    static let plausibleContentFloor = RemotePixelSize(width: 150, height: 80)
    static let garbageCeiling: Double = 10000
    static func isPlausibleContent(_ size: RemotePixelSize) -> Bool {
        size.width >= plausibleContentFloor.width && size.height >= plausibleContentFloor.height
            && size.width < garbageCeiling && size.height < garbageCeiling
    }

    /// winver.exe's About Windows dialog: consistently ~536x521 remote px against the real lab
    /// host; 400...700 on BOTH axes leaves slack for theme differences while still meaning
    /// something as an anchor. DPI is no longer a reason for slack: the conversion above absorbs
    /// the scale factor, and the residual F1 records on odd remote-px dimensions (±1 remote px on
    /// the return trip: 515 remote px -> 257.5 pt -> 258 backing px -> 516, C-2's `delta=(0,1)`) is
    /// two orders under the band's ±100.
    static let aboutWindowsRange: ClosedRange<Double> = 400...700
    static func isAboutWindowsDialog(_ size: RemotePixelSize) -> Bool {
        aboutWindowsRange.contains(size.width) && aboutWindowsRange.contains(size.height)
    }

    /// The maximize scenario's two width thresholds, remote px. Observed against the lab host's
    /// 2560-remote-px-wide desktop at rasterScale 1: a maximized About window spans the desktop
    /// (>= 2000), a restored one is back near its ~536 natural width (< 1000). Until this landed
    /// both were compared against `NSWindow.frame.width` in pt (review sizeband-r1 I2): a 2x
    /// session's maximized 2560-remote-px window is a 1280 pt frame and read as "did not grow",
    /// while a 600 pt frame (1200 remote px, NOT restored) read as restored. Same conversion as
    /// the content bands; the constants keep their 1x meaning. A desktop-relative threshold
    /// (fraction of the frozen `sessionDesktopSizeInRemotePixels`) would be the principled next
    /// form and is deliberately NOT introduced here -- this change only fixes the unit.
    static let maximizedWidthFloor: Double = 2000
    static let restoredWidthCeiling: Double = 1000
    static func isMaximizedWidth(_ size: RemotePixelSize) -> Bool { size.width >= maximizedWidthFloor }
    static func isRestoredWidth(_ size: RemotePixelSize) -> Bool { size.width < restoredWidthCeiling }

    /// The converted size plus the one-line rendering every band assertion prints, so a failure
    /// names both units and the factor that linked them.
    static func describe(frameSize: CGSize, in topology: DisplayTopology) -> (RemotePixelSize, String) {
        let px = remotePixelSize(ofFrameSize: frameSize, in: topology)
        return (px, "\(px.width)x\(px.height) remote px = \(frameSize.width)x\(frameSize.height) pt at rasterScale \(topology.rasterScale)")
    }
}

/// `WINDOW_SMOKE_SELFTEST=1`: runs the pure gates above against fixtures and exits.
///
/// WHY THIS EXISTS. `window-smoke` has no test bundle and cannot get one without touching another
/// lane's file (`App/project.yml`), yet L9's own instruction is that no assertion may be
/// "structurally unfailable". This mode is the falsification surface: it is deterministic, needs
/// no display, no host and no credential (it runs before `host.env` is even looked at), and each
/// case below is written so that a specific mutation turns it red. The mutations verified when it
/// was written, and the case that catches each:
///
///  * tolerance `0` -> `1` remote px   => `toleranceRejectsAOneRemotePixelError`
///  * the comparison space put back in mac pt (compare `MacRect.y` instead of the Windows-space
///    top edge) => `positionOnlyIsHeightInvariantInWindowsSpace`
///  * the `(0,0)` sentinel counted as an observation => `sentinelPairIsNotAnObservation`
///  * the paired verdict reduced to the rect half alone => `aLegFailsIfEitherHalfFails`
///  * the point path's anchor/sign disturbed => `pointPathPinsItsOwnNumbers`
///  * **the effective threshold loosened without touching the constant**
///    (`<= toleranceInRemotePixels + 0.75`) => `toleranceRejectsAQuarterRemotePixelError` and
///    `thePredicateItselfAdmitsOnlyAnExactMatch`. Added in fix round 1: review (rev-L9 I-1) found
///    that mutation surviving, because every earlier error fixture injected exactly 1.0 remote px.
///  * `MacdowsCore.windowsPoint` mis-scaling that is invisible at 1x (`(H − y) * s` -> `H − y * s`)
///    => `pointPathPinsItsOwnNumbers at rasterScale 2` (found KILLED by review's own R1 mutation --
///    the 2x pin is what makes a package-side regression visible offline).
///  * **F1's verdict inverted, or its exactness weakened** (`==` -> `abs(...) <= 1`, or a rounding
///    step) => `f1RedAtTwoX` / `f1AdmitsOnlyExactEquality` (L9b). F1 is measurement-only and never
///    touches the exit code, which is exactly why its own logic has to be pinned here: nothing in a
///    live run can fail because of it, so nothing in a live run can reveal it broken either.
///  * **the size bands' pt->remote px scaling dropped** (compare `NSWindow.frame` pt directly, the
///    pre-C-2 shape) => `sizeBandJudgesAboutInRemotePixelsAt2x` / `sizeBandFloorIsInclusiveInRemotePixels`;
///    the band loosened to hide the 2x red instead => `sizeBandAboutRejectsHalfSizeAt1x`; one axis
///    of either band dropped => `sizeBandFloorRejectsEachAxisAlone` / `sizeBandAboutNeedsBothAxes` /
///    `sizeBandCeilingRejectsEachAxisAlone`; the maximize thresholds' comparison loosened, or
///    `remotePixelSize` no longer applying `rasterScale` => `sizeBandMaximizeThresholdsAreRemotePixels`.
///    **Not covered here**: the two `runMaximizeScenario` call sites reverting to `snap.frame.width`
///    in pt while still printing the converted value (review sizeband-maximize-r1 D2 survives) --
///    the live wiring has no offline seam; `grep 'frame.width >= 2000'` zero-hit is the only guard.
///  * **the move/resize target filter** losing case-insensitivity, an empty filter no longer
///    meaning "the About heuristic", the `|` alternatives no longer split, or their surrounding
///    whitespace no longer trimmed => `moveResizeTargetFilterSemantics`; the lock no longer
///    skipping pre-existing ids under a filter, skipping them under the About heuristic too, an
///    empty filter counted as explicit, losing its lowest-id ordering, or the pre-existing-only
///    report losing its ascending order => `moveResizeTargetLockExcludesPreExistingOnlyWhenFiltered`.
///    **Not covered here**: `runMoveResizeScenario`'s target lock calling something other than
///    `MoveResizeTarget.lock`, passing it a set other than `windowIdsBeforeExtraApps`, or choosing
///    the wrong one of its two one-shot log lines -- live wiring, no offline seam.
///  * **the multi-window gate** counting a window that merely flashed after the exec, counting a
///    close target that never showed content, or re-adding pre-existing ids =>
///    `multiWindowGateCountsVisibleOrHarnessClosedNewWindows`. **Not covered here** (live wiring,
///    no offline seam): `finish()` passing an empty `closedByHarness`, or only one of its two
///    halves (the F0-H1 defect itself; review multiwindow-gate-r2 MF); the per-tick accumulator
///    dropping `hasDisplayedContent` or the band floor (a weaker accumulator survives every pin,
///    as review multiwindow-gate-r1 M2 measured); the F0 rerun is the live check for the first.
///  * **the remap observation** sampled outside the in-flight window, for a non-target window,
///    or with no target locked => `remapObservationAppliesOnlyToTheInFlightTarget`. **Not covered
///    here** (live wiring, no offline seam): the tap not calling it at all for `surfaceMapped`
///    (the F0-2 defect itself), or passing `event.windowId` instead of `event.mappedWindowId`
///    (a `surfaceMapped` event carries the window in `mappedWindowId`; `windowId` is 0 there --
///    `CRSession.mm` `payload.surfaceMapped.windowId` -> `mappedWindowId`; review
///    remap-observation-r1 M5 measured that mutant surviving). The next F/F0 run's
///    "sources in order: update,remap" text is the live check for both.
///  * **the oscillation verdict** collapsing back to two states (an unmatched leg reported as
///    "none"), counting pre-match failures as oscillation, dropping the post-match scan, or
///    `isOscillated` going constant (the unfailable green reborn through the accessor
///    `check(!oscillated)` reads), or `text` naming the wrong state =>
///    `oscillationVerdictIsUnjudgeableUntilTheRectMatches`. **Not covered here**: `finish()`
///    printing PASS instead of N/A for `.unjudgeable` -- live wiring, no offline seam.
///
/// **Known blind spot, stated rather than papered over** (rev-L9 I-2, R6): replacing the two
/// `WindowGeometry.windowsPoint` calls with a copy of the rect conversion's own origin is an
/// *equivalent* mutant -- identical values, so nothing here can see it. This surface pins the point
/// half's NUMBERS, not that the point entry is the one travelled. Pinning the latter would need a
/// seam this tool has no owned file to build.
///
/// Exit code 0/1, matching every other assertion path in this harness.
enum WindowSmokeGateSelfTest {
    static func run() -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ name: String) {
            print("[selftest] \(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { ok = false }
        }

        // A 1920x1080-point primary at 1x and its 2x twin -- synthetic shapes for arithmetic
        // pins. The lab host's real display is 2560x1440 at 1x native (`docs/plans/phase3.md:219`;
        // 1920x1080 appears there only as a downsampled-2x comparison mode), which is what the
        // `SizeBand` thresholds were observed against.
        guard
            let topology1x = DisplayTopology.single(widthInPoints: 1920, heightInPoints: 1080),
            let topology2x = DisplayTopology.single(
                widthInPoints: 1920, heightInPoints: 1080, scale: .fullyScaled2x
            )
        else {
            print("[selftest] FAIL: could not build the fixture topologies")
            return false
        }

        // --- The tolerance, and the fact that it is 0 -----------------------------------------
        expect(
            MoveResizeGate.toleranceInRemotePixels == 0,
            "the geometry tolerance is 0 remote px (owner ruling U6, 2026-09-01 19:19)"
        )

        let target = MacRect(x: 300, y: 400, width: 500, height: 600)
        expect(
            MoveResizeGate.evaluate(observed: target, target: target, in: topology1x, positionOnly: false).passed,
            "an exactly-equal rect passes both halves of the paired verdict"
        )

        // One remote pixel of error, at 1x: must FAIL at tolerance 0. This is the case that goes
        // green if the constant is loosened to 1, which is what makes the constant's value tested
        // rather than merely written down.
        let offByOneRemotePixel = MacRect(x: 301, y: 400, width: 500, height: 600)
        let offByOne = MoveResizeGate.evaluate(
            observed: offByOneRemotePixel, target: target, in: topology1x, positionOnly: false
        )
        expect(
            !offByOne.rectCheckPassed && !offByOne.pointCheckPassed && !offByOne.passed,
            "toleranceRejectsAOneRemotePixelError: a 1-remote-px X error fails BOTH halves at tolerance 0"
        )

        // Half a mac point at 2x is exactly one remote pixel -- the unit, not the number, decides
        // this one, so it fails only because the comparison happens in remote px.
        let halfPointAt2x = MacRect(x: 300.5, y: 400, width: 500, height: 600)
        expect(
            !MoveResizeGate.evaluate(
                observed: halfPointAt2x, target: target, in: topology2x, positionOnly: false
            ).passed,
            "a half-POINT error at rasterScale 2 is one REMOTE PIXEL of error and fails"
        )

        // SUB-remote-pixel rejection (rev-L9 I-1). Everything above injects exactly 1.0 remote px of
        // error, so any effective threshold in the open interval (0, 1) satisfied all of it -- the
        // mutation `abs(a-b) <= toleranceInRemotePixels + 0.75` left the whole battery green while
        // silently overturning U6. These cases pin the threshold ACTUALLY IN FORCE, not the symbol.
        let quarterRemotePixelOff = MacRect(x: 300.25, y: 400, width: 500, height: 600)
        let quarter = MoveResizeGate.evaluate(
            observed: quarterRemotePixelOff, target: target, in: topology1x, positionOnly: false
        )
        expect(
            !quarter.rectCheckPassed && !quarter.pointCheckPassed && !quarter.passed,
            "toleranceRejectsAQuarterRemotePixelError: 0.25 remote px of X error fails BOTH halves "
                + "-- the gate is the comparison, not the constant"
        )
        // Straight at the predicate, at two more decades, so a smaller epsilon has nowhere to hide.
        // Bound stated honestly: this kills any loosening down to ~1e-7 remote px; a smaller one
        // than that is not detectable here and is not distinguishable from association noise either
        // (see `withinToleranceInRemotePixels`' own note).
        expect(
            MoveResizeGate.withinToleranceInRemotePixels(0, 0)
                && !MoveResizeGate.withinToleranceInRemotePixels(0, 0.0001)
                && !MoveResizeGate.withinToleranceInRemotePixels(100, 100.0000001),
            "thePredicateItselfAdmitsOnlyAnExactMatch: equal passes; 1e-4 and 1e-7 remote px of "
                + "error are both rejected at tolerance 0"
        )

        // --- The comparison space (adr/0015 §6.1, round-7 finding) ----------------------------
        // Same Windows-space top edge, different height: mac-space `y` differs by exactly the
        // height delta, Windows-space `y` does not move at all. A position-only leg must pass.
        // Comparing in mac pt here yields dy = 40 and a false red -- this is the mutation guard
        // for "put the comparison back in mac points".
        let remappedShorter = MacRect(x: 300, y: 440, width: 500, height: 560)
        let heightInvariant = MoveResizeGate.evaluate(
            observed: remappedShorter, target: target, in: topology1x, positionOnly: true
        )
        expect(
            heightInvariant.passed
                && heightInvariant.observedInRemotePixels.y == heightInvariant.targetInRemotePixels.y
                && remappedShorter.y != target.y,
            "positionOnlyIsHeightInvariantInWindowsSpace: a mid-leg height remap moves mac y but not "
                + "the Windows-space top edge, and the position-only leg passes"
        )
        expect(
            !MoveResizeGate.evaluate(
                observed: remappedShorter, target: target, in: topology1x, positionOnly: false
            ).rectCheckPassed,
            "the full-rect leg still fails on that same height change -- position-only is a scope, not a loophole"
        )

        // --- The paired assertion (adr/0015 §6.3) ---------------------------------------------
        // Hand-computed, not derived from the code under test: Windows top edge for the target is
        // 1080 - 400 - 600 = 80, and the point path reaches the same 80 through 1080 - (400+600)
        // with no `- height` term of its own. Both numbers are literals here on purpose -- an
        // anchor or sign change in either path moves one of them.
        let pinned = MoveResizeGate.evaluate(
            observed: target, target: target, in: topology1x, positionOnly: false
        )
        expect(
            pinned.targetInRemotePixels == WindowsRect(x: 300, y: 80, width: 500, height: 600)
                && pinned.targetTopLeftViaPointPath == WindowsPoint(x: 300, y: 80),
            "pointPathPinsItsOwnNumbers: rect top-left (300,80) and point-path top-left (300,80) remote px"
        )
        // At 2x the same rect is a different set of remote pixels, and the two paths must still
        // agree: x*2 = 600, (1080 - 400 - 600)*2 = 160.
        let pinned2x = MoveResizeGate.evaluate(
            observed: target, target: target, in: topology2x, positionOnly: false
        )
        expect(
            pinned2x.targetInRemotePixels == WindowsRect(x: 600, y: 160, width: 1000, height: 1200)
                && pinned2x.targetTopLeftViaPointPath == WindowsPoint(x: 600, y: 160),
            "pointPathPinsItsOwnNumbers at rasterScale 2: (600,160) remote px on both paths"
        )

        let rectOnlyFailed = MoveResizeGate.LegVerdict(
            observedInRemotePixels: WindowsRect(x: 0, y: 0, width: 1, height: 1),
            targetInRemotePixels: WindowsRect(x: 0, y: 0, width: 1, height: 1),
            observedTopLeftViaPointPath: WindowsPoint(x: 0, y: 0),
            targetTopLeftViaPointPath: WindowsPoint(x: 0, y: 0),
            positionOnly: false, rectCheckPassed: false, pointCheckPassed: true
        )
        let pointOnlyFailed = MoveResizeGate.LegVerdict(
            observedInRemotePixels: WindowsRect(x: 0, y: 0, width: 1, height: 1),
            targetInRemotePixels: WindowsRect(x: 0, y: 0, width: 1, height: 1),
            observedTopLeftViaPointPath: WindowsPoint(x: 0, y: 0),
            targetTopLeftViaPointPath: WindowsPoint(x: 0, y: 0),
            positionOnly: false, rectCheckPassed: true, pointCheckPassed: false
        )
        expect(
            !rectOnlyFailed.passed && !pointOnlyFailed.passed
                && rectOnlyFailed.pairedVerdictText.contains("rectCheck=FAIL")
                && pointOnlyFailed.pairedVerdictText.contains("pointCheck=FAIL")
                && pointOnlyFailed.pairedVerdictText.contains("PATHS DISAGREE"),
            "aLegFailsIfEitherHalfFails: either half failing fails the leg, and the text names which"
        )

        // --- The `[gfx] target=` tally --------------------------------------------------------
        var empty = GfxTargetHintTally()
        expect(
            empty.summaryLine.hasPrefix("[gfx] target= ") && empty.summaryLine.contains("none (no surface-map events"),
            "the target line is well-formed and explicit when no surface map was seen at all"
        )

        empty.record(targetWidthInRemotePixels: 0, targetHeightInRemotePixels: 0)
        empty.record(targetWidthInRemotePixels: 0, targetHeightInRemotePixels: 0)
        expect(
            empty.observations.isEmpty && empty.hintAbsentEvents == 2 && empty.usableHintEvents == 0
                && empty.summaryLine.contains("none (no usable target hint on any of 2 surface-map event(s) -- 2 carried the (0,0) sentinel"),
            "sentinelPairIsNotAnObservation: (0,0) is counted as hint-absent, never as a 0x0 target"
        )

        var tally = GfxTargetHintTally()
        tally.record(targetWidthInRemotePixels: 1664, targetHeightInRemotePixels: 960)
        tally.record(targetWidthInRemotePixels: 1664, targetHeightInRemotePixels: 960)
        tally.record(targetWidthInRemotePixels: 1280, targetHeightInRemotePixels: 720)
        tally.record(targetWidthInRemotePixels: 0, targetHeightInRemotePixels: 0)
        tally.record(targetWidthInRemotePixels: 1280, targetHeightInRemotePixels: 0)
        expect(
            tally.observations[.init(width: 1664, height: 960)] == 2
                && tally.observations[.init(width: 1280, height: 720)] == 1
                && tally.hintAbsentEvents == 1 && tally.degenerateHintEvents == 1
                && tally.surfaceMapEventsSeen == 5 && tally.usableHintEvents == 3,
            "the tally separates usable hints, the (0,0) sentinel and a one-zero degenerate hint"
        )
        expect(
            tally.summaryLine.hasPrefix("[gfx] target= 1664x960 remote px (n=2), 1280x720 remote px (n=1)")
                && tally.summaryLine.contains("hintAbsent=1") && tally.summaryLine.contains("degenerateHint=1"),
            "the observed form lists distinct sizes with counts, most frequent first, plus the denominators"
        )

        // --- F1: backing px vs GFX mappedSize (docs/plans/phase3.md:130, M1 L9b) --------------
        // The fixture numbers are a real window's shape: 508x507 remote px is the About window's
        // own GFX-mapped size from the 2026-08-23 real-host run (`WindowGeometry.swift`'s
        // correction note records it), so the 1x and 2x rows below are what this measurement will
        // actually print at the checkpoint, not invented values.
        func f1(backing: (Double, Double), content: (Double, Double), mapped: (Double, Double))
            -> F1BackingVsMapped.Observation
        {
            F1BackingVsMapped.Observation(
                windowId: 4242,
                backingWidthInBackingPixels: backing.0, backingHeightInBackingPixels: backing.1,
                contentWidthInPoints: content.0, contentHeightInPoints: content.1,
                mappedWidthInRemotePixels: mapped.0, mappedHeightInRemotePixels: mapped.1
            )
        }

        let f1At1x = f1(backing: (508, 507), content: (508, 507), mapped: (508, 507))
        expect(
            f1At1x.verdict == .green && f1At1x.impliedBackingScale == 1,
            "f1GreenAtOneX: backing px == mappedSize when backingScaleFactor is 1 (today's hardware)"
        )

        let f1At2x = f1(backing: (1016, 1014), content: (508, 507), mapped: (508, 507))
        expect(
            f1At2x.verdict == .red && f1At2x.impliedBackingScale == 2
                && f1At2x.line.contains("verdict=RED") && f1At2x.line.contains("delta=(508,507)"),
            "f1RedAtTwoX: a factor-of-2 backing store is RED, and the line states the factor and the "
                + "delta -- this RED is 验收-真机-1 itself (docs/plans/phase3.md:130), not a regression"
        )

        // The EFFECTIVE comparison, not just the factor-of-2 headline: one backing pixel of
        // difference must be RED. A `<= 1` or a rounding step introduced here would absorb it and
        // turn this measurement into one that cannot fail for small errors.
        //
        // The 0.25 row is the one that discriminates ROUNDING specifically, and it was added after
        // a mutation survived: `Int(x.rounded()) == Int(y.rounded())` still reports RED for 508.5 vs
        // 508 (508.5 rounds AWAY to 509), so a half-pixel fixture proves nothing about rounding.
        // Sub-half-pixel is the only fixture that does. It pins the type's own stated claim -- exact,
        // unrounded -- rather than a field-reachable scenario: `convertToBacking` of the integral
        // content rects this path produces is itself integral, so a fractional backing size is not
        // expected in a live run. An assertion about a claim is still an assertion.
        expect(
            f1(backing: (509, 507), content: (509, 507), mapped: (508, 507)).verdict == .red
                && f1(backing: (508, 508), content: (508, 508), mapped: (508, 507)).verdict == .red
                && f1(backing: (508.5, 507), content: (508.5, 507), mapped: (508, 507)).verdict == .red
                && f1(backing: (508.25, 507), content: (508.25, 507), mapped: (508, 507)).verdict == .red,
            "f1AdmitsOnlyExactEquality: 1 backing px on either axis -- and a half, and a quarter -- is RED"
        )
        // Direction-independent: the mapped side being the larger one is equally a disagreement.
        expect(
            f1(backing: (508, 507), content: (508, 507), mapped: (1016, 1014)).verdict == .red,
            "f1IsSymmetric: mapped larger than backing is RED too, not silently tolerated"
        )

        var f1Tally = F1BackingVsMappedTally()
        expect(
            f1Tally.summaryLine.hasPrefix("[f1] summary: none (no window with both a presented frame")
                && f1Tally.summaryLine.contains("MEASUREMENT ONLY"),
            "the F1 summary is well-formed and explicit when no window was ever measurable"
        )
        expect(
            f1Tally.record(f1At2x) != nil && f1Tally.record(f1At2x) == nil,
            "f1TallyDedupesUnchangedSamples: the first sample prints, an identical repeat does not"
        )
        let recovered = f1Tally.record(f1At1x)
        expect(
            recovered != nil && f1Tally.samplesTaken == 3 && f1Tally.everRedWindows.count == 1
                && f1Tally.summaryLine.contains("windows=1 GREEN=1 RED=0")
                && f1Tally.summaryLine.contains("everRed=1"),
            "f1TallyKeepsTheLastStateAndRemembersAnEarlierRed: a verdict that flips is still visible"
        )

        // --- H3 size bands judged in remote px (adr/0015 §6.1; C-2 run 1's only FAIL) -----------
        let aboutAt1x = SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 536, height: 521), in: topology1x)
        expect(
            aboutAt1x == SizeBand.RemotePixelSize(width: 536, height: 521) && SizeBand.isAboutWindowsDialog(aboutAt1x),
            "sizeBandAboutAt1x: a 536x521 pt frame is 536x521 remote px and inside the About band"
        )
        // The C-2 shape, as a synthetic half-size frame (the real C-2 F1 line read content 261x258
        // mac pt for mapped 522x515 remote px; 268x260.5 is exactly 536x521 / 2 so the pin stays
        // arithmetic). Judged in pt it is "too small"; judged in remote px it is the same 536x521
        // dialog. Killed by dropping the scaling (comparing frame pt directly) -- the pre-C-2 defect.
        let aboutAt2x = SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 268, height: 260.5), in: topology2x)
        expect(
            aboutAt2x == SizeBand.RemotePixelSize(width: 536, height: 521) && SizeBand.isAboutWindowsDialog(aboutAt2x),
            "sizeBandJudgesAboutInRemotePixelsAt2x: 268x260.5 pt at rasterScale 2 is 536x521 remote px, inside the band"
        )
        // Guard against "fixing" the 2x red by loosening the band instead of scaling: the same
        // half-size frame at 1x really IS a 268x260 remote-px window and must stay outside.
        expect(
            !SizeBand.isAboutWindowsDialog(
                SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 268, height: 260.5), in: topology1x)),
            "sizeBandAboutRejectsHalfSizeAt1x: 268x260.5 remote px is not the About dialog"
        )
        // The plausible-content floor is a remote-px fact too: 75x40 pt at 2x is exactly the
        // 150x80 floor (inclusive); one pt narrower (74 -> 148 remote px) is out, and 75x40 pt at
        // 1x is 75x40 remote px -- under the floor.
        expect(
            SizeBand.isPlausibleContent(
                SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 75, height: 40), in: topology2x))
                && !SizeBand.isPlausibleContent(
                    SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 74, height: 40), in: topology2x))
                && !SizeBand.isPlausibleContent(
                    SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 75, height: 40), in: topology1x)),
            "sizeBandFloorIsInclusiveInRemotePixels: 75x40 pt passes only at 2x; 74x40 pt at 2x and 75x40 pt at 1x are under the floor"
        )
        // Each axis alone must be able to fail (review sizeband-r1 I1: dropping the HEIGHT floor,
        // or judging the About band on width only, survived every earlier pin). The 1009x4 edge
        // strip is the real helper class only the height floor rejects; 100x500 is its transpose.
        expect(
            !SizeBand.isPlausibleContent(
                SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 1009, height: 4), in: topology1x))
                && !SizeBand.isPlausibleContent(
                    SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 100, height: 500), in: topology1x)),
            "sizeBandFloorRejectsEachAxisAlone: a 1009x4 edge strip fails on height, a 100x500 sliver on width"
        )
        expect(
            !SizeBand.isAboutWindowsDialog(SizeBand.RemotePixelSize(width: 536, height: 300))
                && !SizeBand.isAboutWindowsDialog(SizeBand.RemotePixelSize(width: 300, height: 521)),
            "sizeBandAboutNeedsBothAxes: 536x300 and 300x521 remote px are each outside the About band"
        )
        // The maximize scenario's width thresholds are remote px too (sizeband-r1 I2): at 2x a
        // 1280 pt frame is a maximized 2560-remote-px window, and a 600 pt frame (1200 remote px) is
        // NOT restored although 600 < 1000 in pt. Exact boundaries pinned: 1000 pt at 2x is exactly
        // 2000 remote px (inclusive floor); 1000 pt at 1x is exactly 1000 remote px (exclusive ceiling).
        expect(
            SizeBand.isMaximizedWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 1280, height: 800), in: topology2x))
                && !SizeBand.isMaximizedWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 1280, height: 800), in: topology1x))
                && SizeBand.isMaximizedWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 1000, height: 800), in: topology2x))
                && !SizeBand.isMaximizedWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 999.5, height: 800), in: topology2x))
                && SizeBand.isRestoredWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 536, height: 521), in: topology1x))
                && SizeBand.isRestoredWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 268, height: 260.5), in: topology2x))
                && !SizeBand.isRestoredWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 600, height: 400), in: topology2x))
                && !SizeBand.isRestoredWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 1000, height: 400), in: topology1x))
                && SizeBand.isRestoredWidth(SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 999.5, height: 400), in: topology1x)),
            "sizeBandMaximizeThresholdsAreRemotePixels: 1280 pt maximized only at 2x; 600 pt at 2x is not restored; boundaries 2000 inclusive / 1000 exclusive"
        )
        // The ceiling stays a remote-px number as well: 5000x5000 pt at 2x is 10000x10000 remote px
        // and hits the exclusive ceiling, while the same frame at 1x is a legitimate large window.
        expect(
            !SizeBand.isPlausibleContent(
                SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 5000, height: 5000), in: topology2x))
                && SizeBand.isPlausibleContent(
                    SizeBand.remotePixelSize(ofFrameSize: CGSize(width: 5000, height: 5000), in: topology1x)),
            "sizeBandCeilingIsExclusiveInRemotePixels: 5000x5000 pt is garbage at 2x (10000) and plausible at 1x"
        )
        // ...and on each axis alone (review sizeband-r2 I-A2: with only the square sample, dropping
        // one ceiling axis survived every pin). The other axis sits INSIDE the floor on purpose --
        // a 100-px sample here would be rejected by the floor, not the ceiling, and the mutation
        // would survive again (it did, on this pin's first draft).
        expect(
            !SizeBand.isPlausibleContent(SizeBand.RemotePixelSize(width: 10000, height: 500))
                && !SizeBand.isPlausibleContent(SizeBand.RemotePixelSize(width: 500, height: 10000)),
            "sizeBandCeilingRejectsEachAxisAlone: 10000x500 fails on width, 500x10000 on height (both remote px)"
        )

        // --- move/resize target filter (WINDOW_SMOKE_MOVE_TARGET) -----------------------------
        expect(
            MoveResizeTarget.matches(title: "About Windows", filter: nil)
                && MoveResizeTarget.matches(title: "关于 Windows", filter: "")
                && !MoveResizeTarget.matches(title: "Untitled - Notepad", filter: nil)
                && MoveResizeTarget.matches(title: "Untitled - Notepad", filter: "notepad")
                && MoveResizeTarget.matches(title: "无标题 - Notepad", filter: "Notepad")
                && !MoveResizeTarget.matches(title: "About Windows", filter: "Notepad")
                && MoveResizeTarget.matches(title: "无标题 - 记事本", filter: "Notepad|记事本")
                && !MoveResizeTarget.matches(title: "无标题 - 记事本", filter: "Notepad")
                && !MoveResizeTarget.matches(title: "About Windows", filter: "Notepad|记事本")
                && MoveResizeTarget.matches(title: "Untitled - Notepad", filter: "Notepad | 记事本")
                && !MoveResizeTarget.matches(title: "Untitled - Notepad", filter: " | "),
            "moveResizeTargetFilterSemantics: nil/empty = About heuristic (incl. 关于); a filter is |-separated, whitespace-trimmed, case-insensitive substrings and excludes About"
        )

        // --- move/resize target LOCK: pre-existing windows are excluded only under a filter ---
        // (review resize-live-r2 I-2 / r3: with WINDOW_SMOKE_MOVE_TARGET the lock ran before the
        // run's own window appeared and took a leftover window from an earlier run; the About
        // heuristic must keep accepting the first app's window, which is itself pre-existing.)
        let about = MoveResizeTarget.Candidate(windowId: 5, title: "About Windows")
        let oldNotepad = MoveResizeTarget.Candidate(windowId: 10, title: "无标题 - Notepad")
        let newNotepad = MoveResizeTarget.Candidate(windowId: 20, title: "无标题 - Notepad")
        let laterNotepad = MoveResizeTarget.Candidate(windowId: 30, title: "Untitled - Notepad")
        let preExisting: Set<UInt32> = [5, 10]
        expect(
            MoveResizeTarget.lock(candidates: [about, oldNotepad], filter: nil, preExisting: preExisting)?.windowId == 5
                && MoveResizeTarget.lock(candidates: [about, oldNotepad], filter: "", preExisting: preExisting)?.windowId == 5
                && MoveResizeTarget.lock(candidates: [about, oldNotepad, newNotepad], filter: "Notepad", preExisting: preExisting)?.windowId == 20
                && MoveResizeTarget.lock(candidates: [about, oldNotepad], filter: "Notepad", preExisting: preExisting) == nil
                && MoveResizeTarget.lock(candidates: [laterNotepad, newNotepad], filter: "Notepad", preExisting: preExisting)?.windowId == 20
                && MoveResizeTarget.lock(candidates: [about, oldNotepad], filter: "Notepad", preExisting: [])?.windowId == 10
                && MoveResizeTarget.matchedOnlyPreExisting(candidates: [about, oldNotepad], filter: "Notepad", preExisting: preExisting) == [10]
                && MoveResizeTarget.matchedOnlyPreExisting(
                    candidates: [oldNotepad, MoveResizeTarget.Candidate(windowId: 8, title: "Untitled - Notepad")],
                    filter: "Notepad", preExisting: [8, 10]
                ) == [8, 10]
                && MoveResizeTarget.matchedOnlyPreExisting(candidates: [about, oldNotepad, newNotepad], filter: "Notepad", preExisting: preExisting).isEmpty
                && MoveResizeTarget.matchedOnlyPreExisting(candidates: [about], filter: nil, preExisting: preExisting).isEmpty,
            "moveResizeTargetLockExcludesPreExistingOnlyWhenFiltered: About heuristic accepts the (pre-existing) first app; a filter skips ids seen before the extra apps launched, picks the lowest new id, and reports the pre-existing-only ids in ascending order"
        )

        // --- oscillation verdict: unjudgeable when the rect never matched -----------------------
        // (review resize-live-r1 I1 / r2: the two red legs of env-202609-14 printed "settled without
        // oscillation" PASS because the unmatched branches hard-coded `oscillated: false` -- a
        // structurally unfailable green. The verdict now has a third state and finish() reports it
        // as N/A, never as PASS.)
        expect(
            MoveResizeGate.oscillationVerdict(rectPassedPerObservation: []) == .unjudgeable(observations: 0)
                && MoveResizeGate.oscillationVerdict(rectPassedPerObservation: [false, false]) == .unjudgeable(observations: 2)
                && MoveResizeGate.oscillationVerdict(rectPassedPerObservation: [true]) == .none
                && MoveResizeGate.oscillationVerdict(rectPassedPerObservation: [false, true, true]) == .none
                && MoveResizeGate.oscillationVerdict(rectPassedPerObservation: [true, false]) == .oscillated
                && MoveResizeGate.oscillationVerdict(rectPassedPerObservation: [false, true, false, true]) == .oscillated
                && MoveResizeGate.OscillationVerdict.oscillated.isOscillated
                && !MoveResizeGate.OscillationVerdict.none.isOscillated
                && !MoveResizeGate.OscillationVerdict.unjudgeable(observations: 3).isOscillated
                && MoveResizeGate.OscillationVerdict.unjudgeable(observations: 3).text.contains("3 observation")
                && MoveResizeGate.OscillationVerdict.none.text == "none"
                && MoveResizeGate.OscillationVerdict.oscillated.text == "oscillated",
            "oscillationVerdictIsUnjudgeableUntilTheRectMatches: no match => unjudgeable(n); failures BEFORE the first match are not oscillation; any later divergence is; isOscillated is true for exactly the oscillated case and text names each state"
        )

        // --- multi-window gate: a new window that was later closed still counts ---------------
        // (F0 对照 r1, 2026-09-02: once the move/resize target lock picked the run-launched window,
        // its close leg closed that window before finish(), and the assertion -- which counted
        // only windows still VISIBLE at finish -- reported 0 new windows by construction.)
        expect(
            // the run-launched target the close leg closed still counts
            MultiWindowGate.newContentWindowIds(visibleAtFinish: [5, 10], closedByHarness: [709], everSeenContent: [5, 10, 709], before: [5, 10]) == [709]
                // still-visible new window counts
                && MultiWindowGate.newContentWindowIds(visibleAtFinish: [5, 10, 800], closedByHarness: [], everSeenContent: [5, 10, 800], before: [5, 10]) == [800]
                // a window that merely flashed (seen, neither visible now nor closed by us) does NOT count
                && MultiWindowGate.newContentWindowIds(visibleAtFinish: [5], closedByHarness: [], everSeenContent: [5, 900], before: [5]).isEmpty
                // a close target that never showed content does NOT count
                && MultiWindowGate.newContentWindowIds(visibleAtFinish: [5], closedByHarness: [901], everSeenContent: [5], before: [5]).isEmpty
                // pre-existing ids never count, even when we closed them (resize r1's leftover case)
                && MultiWindowGate.newContentWindowIds(visibleAtFinish: [10], closedByHarness: [10], everSeenContent: [10], before: [10]).isEmpty
                && MultiWindowGate.newContentWindowIds(visibleAtFinish: [], closedByHarness: [], everSeenContent: [], before: [5]).isEmpty,
            "multiWindowGateCountsVisibleOrHarnessClosedNewWindows: a new window counts if still visible at finish or closed by this run's own close leg (and it showed content); a mere flash does not; pre-existing ids never do"
        )

        // --- move/resize legs also observe the post-remap content rect -------------------------
        // (F0-2, 2026-09-02 F0 r1/r2: the resize leg's only observation was taken at the
        // WindowUpdate, when the local content rect still carried the OLD GFX-mapped size; the
        // registry re-applies the frame when the surface remap lands, and that re-apply was never
        // sampled, so dw read as -100 against a server that had actually applied +90.)
        expect(
            MoveResizeGate.remapObservationApplies(eventWindowId: 709, targetWindowId: 709, legAwaitingSettle: true)
                && !MoveResizeGate.remapObservationApplies(eventWindowId: 709, targetWindowId: 709, legAwaitingSettle: false)
                && !MoveResizeGate.remapObservationApplies(eventWindowId: 5, targetWindowId: 709, legAwaitingSettle: true)
                && !MoveResizeGate.remapObservationApplies(eventWindowId: 709, targetWindowId: nil, legAwaitingSettle: true),
            "remapObservationAppliesOnlyToTheInFlightTarget: a surface remap is an observation only for the locked target while a leg awaits settle"
        )

        print("[selftest] overall: \(ok ? "PASS" : "FAIL")")
        // rev-L9 M-4: `Scripts/run-window-smoke.command:159` records `DONE exit=$?` and its callers
        // read that line as the whole verdict. A `WINDOW_SMOKE_SELFTEST=1` leaked into the
        // launcher's environment would therefore print `DONE exit=0` for a run that connected to
        // nothing -- and both modes end in a line matching `overall: PASS`. The banner is the
        // cheapest unambiguous discriminator, and it is deliberately the LAST line of the mode.
        print("[selftest] NOTE: SELF-TEST-ONLY run (WINDOW_SMOKE_SELFTEST=1) -- no host was "
            + "contacted, no session was created, and NO live smoke test ran. A zero exit code here "
            + "says nothing whatsoever about the live battery; a real run prints [assert] lines.")
        return ok
    }
}

// Runs before ANY of the environment/credential/boundary work below: this mode never reads
// host.env, never resolves a credential and never constructs a session, which is what makes it
// safe to run in an offline lane (and what makes it usable as a mutation-test surface at all).
if ProcessInfo.processInfo.environment["WINDOW_SMOKE_SELFTEST"] == "1" {
    exit(WindowSmokeGateSelfTest.run() ? 0 : 1)
}

// Three MacdowsCore rules and no local copy of any of them: MacdowsPaths says WHERE host.env
// is, EnvFile.parse says HOW it is read, EnvFile.value says WHICH of the environment variable
// and the file value wins. All three used to be spelled out right here.
//
// The parser was the worst of them. It keyed each line on everything left of the first `=`, so
// `export WIN_HOST=x` landed under the key "export WIN_HOST" and was invisible to the lookup
// below, and it stripped no quotes -- rules that disagreed with the ones
// run-window-smoke.command applies to the SAME file. The disagreement was measured fail-open
// (see EnvFile's own doc comment and this launcher's comment on SMOKE_HOST): on a host.env with
// a bare out-of-boundary line followed by an in-boundary `export` line, the launcher's gate
// approved one host and this harness would have dialled the other. One parser, in the package
// `swift test` can reach, was the fix.
//
// The path and the precedence followed for the same reason, one review later. The path had been
// `NSHomeDirectory() + "/.config/macdows/host.env"` while LabBoundary located ITS file through
// $HOME, so a redirected HOME sent the two halves of one gate decision to two different homes
// (MacdowsPaths' doc comment has the measurement and the four reasons the reconciled order is
// the $HOME-preferring one -- which is also what run-window-smoke.command:99 and lib.sh:57 use,
// so the launcher and this binary now read one file by construction). The precedence had been a
// four-line local function duplicated verbatim in Tools/bridge-smoke/GateShim.swift. Neither
// resolved path nor any credential changes in the default environment; what changes is that
// there is nothing left here for a future edit to change on one side only.
//
// A missing/unreadable host.env is still not fatal here: the WIN_HOST/WIN_USER/WIN_PASS
// environment variables take priority over the file anyway (and are how the launcher hands
// over the exact host its own gate cleared), so an empty dictionary lets that path run and the
// guard below produce the same "missing credentials" message it always has.
let fileEnv = (try? EnvFile.parse(path: MacdowsPaths.hostEnvPath())) ?? [:]
guard
    let host = EnvFile.value(forKey: "WIN_HOST", in: fileEnv),
    let user = EnvFile.value(forKey: "WIN_USER", in: fileEnv),
    let pass = EnvFile.value(forKey: "WIN_PASS", in: fileEnv),
    !host.isEmpty, !user.isEmpty, !pass.isEmpty
else {
    print("window-smoke: missing WIN_HOST/WIN_USER/WIN_PASS (env vars, or ~/.config/macdows/host.env)")
    exit(2)
}
print(
    "window-smoke: credentials resolved (host=\(host.count) chars, user=\(user.count) chars, "
        + "pass=\(pass.count) chars -- values never printed)"
)

// Live-host testing boundary gate (owner rule, 2026-08-31), enforced HERE and not only in
// Scripts/run-window-smoke.command. The launcher already refuses out-of-boundary targets, but
// it is not the only way this binary starts: `xcodebuild -scheme window-smoke` puts a runnable
// executable in DerivedData that anyone (or any future script, or Xcode's own Run button) can
// invoke directly with WIN_HOST set, and that path had no gate at all. The rule is that a
// real-host step may only ever target the owner's own machine on the owner's own LAN, so the
// binary that opens the socket is where it has to be checked.
//
// exit(78) deliberately reuses the launcher's established refusal code, so `DONE exit=78` keeps
// exactly one meaning for every caller and every log reader: boundary refusal, host never
// contacted. Running under the launcher this gate is a cheap second verdict on a string that
// already cleared the shell gate (the launcher exports the exact host it validated, and
// EnvFile.value prefers the environment) -- agreement is the expected outcome and the two
// implementations now share one parsing rule, one precedence rule and one host.env path, so a
// disagreement is a bug in one of them rather than the ambiguity it used to be.
//
// The host is NOT printed, unlike lib.sh's own refusal line: this file's header commits to
// never printing WIN_HOST/WIN_USER/WIN_PASS raw values, and its stdout is tee'd into
// .build/evidence/window-smoke-run.log. The reason category is enough to act on, and carries
// no segment (see LabBoundary's doc comment).
switch LabBoundary.check(host: host) {
case .allowed:
    print("window-smoke: \(LabBoundary.allowedLine)")
case .refused(let refusal):
    print(
        "window-smoke: live-host boundary gate REFUSED this target -- \(refusal.reasonText). "
            + "Nothing was connected; the host value is not printed (red line)."
    )
    exit(78)
}

// H2/L4 (W4b review): the evidence path is now a parameter, not a hardcoded absolute path,
// so this harness (and run-window-smoke.command, which never hardcodes it either) works
// unmodified from any checkout, not just this machine's own lab directory. Relative to the
// process's current working directory when no override is given -- run-window-smoke.command
// `cd`s to the repo root first specifically so this default lands in a predictable, git-
// ignored location (matching the project's existing .build/ convention for build/verification
// artifacts, e.g. .build/freerdp, .build/deps).
let screenshotPath = ProcessInfo.processInfo.environment["WINDOW_SMOKE_SCREENSHOT_PATH"]
    ?? ".build/evidence/w4b-first-window.png"

// W4b review round 2, experiment 2 (control group): which RemoteApp program this run
// launches. Default winver.exe, unchanged from every prior run -- set WINDOW_SMOKE_APP to
// launch something else instead (e.g. regedit.exe), to test whether an app that otherwise
// shows the "white block" symptom as a long-idle background window paints *completely*
// when it's a freshly launched instance in the current session instead.
let launchedProgram = ProcessInfo.processInfo.environment["WINDOW_SMOKE_APP"]
    ?? "C:\\Windows\\System32\\winver.exe"

/// adr/0011 §5 items 5/6: command-line arguments for the RemoteApp launch above, assigned
/// verbatim to `CRSession.programArguments` (MS-RDPERP's `RemoteApplicationArguments`, see
/// that property's own doc comment) before `-start`. Unset (the default) leaves the
/// property nil, i.e. exactly today's argument-less launch for every existing scenario.
///
/// Exists for the input round-trip batteries below: those need the launched app to open a
/// SPECIFIC, pre-seeded file (e.g. `WINDOW_SMOKE_APP=C:\Windows\System32\notepad.exe`
/// with `WINDOW_SMOKE_APP_ARGS=C:\rdp-lab\cmdmap-seed.txt`), so that a Cmd+A/Cmd+C/
/// Cmd+V/Cmd+S chord sequence has real, known text to act on and Notepad can save back in
/// place with no Save-As dialog. Windows-side quoting is the caller's responsibility (the
/// string is passed through untouched, per `programArguments`' own contract).
let launchedProgramArguments = ProcessInfo.processInfo.environment["WINDOW_SMOKE_APP_ARGS"]
    .flatMap { $0.isEmpty ? nil : $0 }

/// Which anchored, gating pixel/size assertion applies to *the window this run itself
/// launched* -- inferred from `launchedProgram`'s path so one harness handles both the
/// default (winver) and control-group (regedit) cases without a separate binary. `.other`
/// gets no anchored assertion (just the generic size-band check every visible window gets).
enum LaunchedAppKind: Equatable {
    case winver
    case regedit
    case other

    init(programPath: String) {
        let lower = programPath.lowercased()
        if lower.contains("winver") {
            self = .winver
        } else if lower.contains("regedit") {
            self = .regedit
        } else {
            self = .other
        }
    }
}
let launchedAppKind = LaunchedAppKind(programPath: launchedProgram)

/// W4c deliverable 5: which synthetic end-to-end input test this run performs, if any —
/// unset (the default) runs the same generic pixel/count assertions every prior run has,
/// unchanged. `.click`/`.enter` additionally synthesize a real `NSEvent` against the
/// launched app's own anchored window partway through the run and assert it closes
/// (`WindowDelete`) within 3 seconds — the W4c task spec's own automated acceptance test
/// for mouse/keyboard input forwarding. Run as two separate invocations (the task spec's
/// own "second run" for the keyboard case) rather than one process testing both, since a window
/// already closed by a successful click can't also be the target of the keyboard test.
enum InputTestMode: String {
    case click
    case enter
    /// adr/0011 §5 item 5. TWO behaviors, selected by `WINDOW_SMOKE_CMDMAP_LIVE`:
    ///
    /// - Unset (the original SCAFFOLD, unchanged): synthesizes a single real Cmd+C `NSEvent`
    ///   sequence against the target window, exercising `CommandKeyMapper`'s wiring end to
    ///   end (`RemoteWindowContentView.keyDown`/`flagsChanged` ->
    ///   `RemoteWindowRegistry.handleInput` -> `CommandKeyMapper` -> the wire), but asserts
    ///   nothing about the result -- the real assertion ("真机Word复制粘贴往返一致") needs a
    ///   live host, which this mode originally had no access to (adr/0012 §4.7's
    ///   host-freshness condition).
    /// - `WINDOW_SMOKE_CMDMAP_LIVE=1` (the live battery): the full adr/0011 §5 item 5
    ///   sequence against a remote Notepad holding a seeded single-line file --
    ///   Cmd+A, Cmd+C, End, Cmd+V, Cmd+V, Cmd+S. See `cmdMapLiveEnabled`'s own doc comment.
    ///
    /// In BOTH cases this mode is deliberately excluded from the generic WindowDelete-based
    /// pass/fail gate `.click`/`.enter` use (see `runInputTest`'s and `finish()`'s own
    /// handling): no chord in either sequence has any reason to close a window.
    case cmdmap
    /// adr/0011 §5 item 6: the IME/Unicode round-trip battery. Delivers ONE composed commit
    /// of a fixed 50-scalar CJK+full-width-punctuation string through the target window's
    /// content view's `NSTextInputClient.insertText(_:replacementRange:)` -- the exact entry
    /// point a real macOS input method uses, never a direct `RemoteWindowRegistry.handleInput`
    /// call -- then saves with Cmd+S so an external readback pass can compare the file on the
    /// host against the expected UTF-8 bytes this harness prints. Like `.cmdmap`, excluded
    /// from the WindowDelete gate: nothing here closes a window.
    case ime
}
let inputTestMode = ProcessInfo.processInfo.environment["WINDOW_SMOKE_INPUT_TEST"]
    .flatMap(InputTestMode.init(rawValue:))

/// adr/0011 §5 item 5's live battery, upgrading `InputTestMode.cmdmap` from scaffold to a
/// real assertion (requires `WINDOW_SMOKE_INPUT_TEST=cmdmap` as well -- on its own this
/// switch does nothing at all, and with it unset `.cmdmap` behaves exactly as it always
/// has). Against the locked target window -- which a live run points at a remote Notepad
/// that opened a seeded single-line text file, via `WINDOW_SMOKE_APP`/`WINDOW_SMOKE_APP_ARGS`
/// plus `WINDOW_SMOKE_INPUT_TARGET_TITLE` -- it synthesizes six real chords in sequence:
/// Cmd+A (select all), Cmd+C (copy), plain End (collapse the selection to the line end, so
/// the pastes APPEND rather than replace the selection), Cmd+V, Cmd+V, Cmd+S. The file
/// therefore ends up holding the seed text three times over, which is what the external
/// readback pass compares against `expected-utf8-hex` (see `finish()`'s own note: the
/// FILE-CONTENT equality is asserted by the controller, not by this process, which has no
/// access to the host's filesystem).
let cmdMapLiveEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_CMDMAP_LIVE"] == "1"

/// The exact text the seeded file handed to `WINDOW_SMOKE_CMDMAP_LIVE`'s Notepad contains --
/// REQUIRED whenever that switch is set (the scenario fails loudly at startup otherwise,
/// see `applicationDidFinishLaunching`), since without it this harness cannot print the
/// `expected-utf8-hex` marker the external comparer needs and the whole run would produce
/// an unverifiable file. Never derived or guessed: the controller seeds the file and passes
/// the identical string here, so a mismatch between the two is a controller bug this
/// harness must not paper over.
let cmdMapSeed = ProcessInfo.processInfo.environment["WINDOW_SMOKE_CMDMAP_SEED"]
    .flatMap { $0.isEmpty ? nil : $0 }

/// The live battery only exists as an upgrade OF `InputTestMode.cmdmap`, never on its own --
/// `WINDOW_SMOKE_CMDMAP_LIVE=1` without `WINDOW_SMOKE_INPUT_TEST=cmdmap` selects no scenario
/// at all (and says so at startup), rather than silently inventing one.
let cmdMapLiveActive = cmdMapLiveEnabled && inputTestMode == .cmdmap

/// adr/0011 §5 item 7's CONSTRUCTIBLE half (the degradation path). When set, the session is
/// started with `CRSession.forceUnicodeInputUnsupported = true` -- the negotiated Unicode
/// capability then reads unsupported no matter what the server actually advertised (see
/// that property's own doc comment for why this override exists at all) -- and this harness
/// delivers TWO IME commits through the same real `NSTextInputClient` path
/// `InputTestMode.ime` uses. `finish()` then asserts adr/0011 §2's degradation discipline
/// exactly: capability read as unsupported, EXACTLY one warning emitted (the warn-once
/// budget), both commits counted as dropped, and nothing reaching the wire.
///
/// Works against the default winver app -- no seeded file, no save, no host-side state at
/// all. Its own env switch, its own checks; the normal-path half of item 7 is
/// `WINDOW_SMOKE_INPUT_TEST=ime`'s own diagnostics gate. The two are mutually exclusive in
/// practice (both drive the shared scripted-input state machine below, and this one runs
/// with no `WINDOW_SMOKE_INPUT_TEST` set at all).
let unicodeDegradeScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_UNICODE_DEGRADE"] == "1"

/// Which window the input-test target lock (`runInputTest`) should pick: the first visible,
/// content-bearing window whose title case-insensitively contains this substring. Unset (the
/// default) keeps the original hardcoded winver-About heuristic ("about"/"关于") exactly as
/// it has always been, so every existing scenario is unaffected.
///
/// Needed by adr/0011 §5 items 5/6: those launch a remote Notepad over a seeded file, whose
/// window title is the file's own name (plus a localized "Notepad"/"记事本" suffix), never
/// anything containing "about".
let inputTargetTitleSubstring = ProcessInfo.processInfo.environment["WINDOW_SMOKE_INPUT_TARGET_TITLE"]
    .flatMap { $0.isEmpty ? nil : $0 }

/// Phase 1 acceptance (multi-window scenario): additional RemoteApp programs to launch
/// into the same session at t=6s, semicolon-separated full Windows paths. When set, the
/// finish battery additionally gates on the visible plausible-band window count reaching
/// 1 + the number of extra apps -- several real windows from several processes in ONE
/// session, the product's core claim (adr/0003's multi-app-single-session risk item).
let extraApps: [String] = (ProcessInfo.processInfo.environment["WINDOW_SMOKE_EXTRA_APPS"] ?? "")
    .split(separator: ";").map(String.init).filter { !$0.isEmpty }

/// Phase 1 acceptance (reconnect soak): connect/disconnect cycle count. A value > 1
/// switches the harness into a dedicated cycle mode -- per cycle: start, wait for at
/// least one visible window with real displayed content, shutdownAndWait, assert clean --
/// exercising adr/0005 §4's full reconnect protocol (generation bump, registry rollover,
/// outbound-queue rebuild) N times back to back, with RSS growth reported at the end.
let cyclesTotal = max(1, Int(ProcessInfo.processInfo.environment["WINDOW_SMOKE_CYCLES"] ?? "") ?? 1)

/// Focus rotation scenario (W1 focus-observability slice, docs/plans/phase2.md §2 W1):
/// number of activate-and-measure-convergence rotations to run once the
/// WINDOW_SMOKE_EXTRA_APPS multi-window setup has settled. 0 (the default) leaves this
/// scenario off entirely -- measurement only, no focus/Z-order policy attached ("拿到真数据前
/// 不写策略"); the >=99% convergence gate is W1's own exit criterion, not asserted here.
let focusRotationTotal = max(0, Int(ProcessInfo.processInfo.environment["WINDOW_SMOKE_FOCUS_ROTATION"] ?? "") ?? 0)

/// adr/0012 follow-up diagnostic, harness-only (no product/FocusAuthority changes):
/// discriminates between two hypotheses for why cycle-mode close-legs were observed to fail
/// 45.5% of the time against a real host after the FocusAuthority gate landed -- (A) server
/// focus is truly absent post-reconnect-churn (the Enter would have failed even ungated), vs
/// (B) `MonitoredDesktop.activeWindowId` lags/misreports actual input focus during that
/// window (the Enter would have landed -- the pre-ADR blind-send harness closed 75-85% of
/// cycles there, which hints at B). Off by default (0 effect on any existing behavior/log
/// line/assertion) -- only when set does a close-leg that fails *because convergence never
/// happened* also blind-send a probe Enter directly via `CRSession`, bypassing
/// RemoteWindowRegistry/FocusAuthority entirely, and report whether the window closed
/// anyway. Purely informational: never changes what a cycle's close-leg gates as.
let closeProbeEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_CLOSE_PROBE"] == "1"

/// Phase 2 W2 task item 5b/5c (docs/plans/phase2.md §2 W2): maximize/restore/close e2e via
/// `CRSession.sendSysCommand(_:command:)`, direct from this harness (no synthetic NSEvent,
/// no traffic-light button click involved) -- a pure wire-level test of the SC_* lane and
/// the server's own response, independent of whatever local UI affordance
/// `RemoteWindowRegistry`'s chrome happens to grant the About window (which, per
/// phase2.md's own acceptance text, should have NO enabled zoom button at all -- see
/// StyleTranslatorTests' `aboutWindowsDialogShape`). Requires WINDOW_SMOKE_EXTRA_APPS
/// (multiwin prereq, per the task spec) -- reuses that scenario's own settling logic.
let maximizeScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_MAXIMIZE"] == "1"

/// Phase 2 W3 (docs/plans/phase2.md §2 W3): automatable local move/resize -> server sync
/// acceptance -- no human drag is available to this harness, so this programmatically
/// moves (then resizes) the target window's real `NSWindow` (About by default -- see
/// `WINDOW_SMOKE_MOVE_TARGET`) via `-setFrame:display:` and
/// asserts the settle path this fires round-trips through `CRSession.sendWindowMove` and
/// back via a real `WindowUpdate`. See `runMoveResizeScenario`'s own doc comment for the
/// acknowledged honesty gap against a genuine mouse-driven drag. Requires
/// WINDOW_SMOKE_EXTRA_APPS (multiwin prereq), same convention as WINDOW_SMOKE_MAXIMIZE.
let moveResizeScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_MOVE"] == "1"
/// WINDOW_SMOKE_MOVE_TARGET=<title substring>: which visible content window the move/resize
/// scenario locks onto. Unset (or empty) keeps the historical About-Windows heuristic. Set it to
/// e.g. `Notepad|记事本` together with `WINDOW_SMOKE_EXTRA_APPS=notepad` to drive the legs against a
/// window that is actually RESIZABLE -- the About dialog never is (StyleTranslatorTests'
/// `aboutWindowsDialogShape`), which is why the 0-remote-px resize half of adr/0015 §6.3 has had
/// no real-host data point (C-2 record, coverage gap). An explicit filter only ever locks a window
/// that appeared AFTER the extra apps were launched (`MoveResizeTarget.lock`): windows already
/// present at that moment -- leftovers from an earlier run, AND the first app's own window
/// (`WINDOW_SMOKE_APP`) -- are skipped, so a filter cannot target the first app; launch that
/// program as an extra app instead. Pure matching/lock logic lives in `MoveResizeTarget` so the
/// self-test can pin it; the wiring itself is live-only.
let moveResizeTargetFilter = ProcessInfo.processInfo.environment["WINDOW_SMOKE_MOVE_TARGET"]

/// Title matching for the move/resize scenario's target lock (see `moveResizeTargetFilter`).
enum MoveResizeTarget {
    /// `nil`/empty filter: the About-Windows heuristic every scenario in this file historically
    /// used (`about`, case-insensitive, or the CJK `关于`). Otherwise `|`-separated alternatives,
    /// each a case-insensitive substring -- `Notepad|记事本` finds `Untitled - Notepad`,
    /// `无标题 - Notepad` AND the fully localised `无标题 - 记事本` a Chinese host shows (review
    /// movetarget-r1 I-1: a single `Notepad` there locks nothing and the run stalls to a false red).
    static func matches(title: String, filter: String?) -> Bool {
        guard let filter, !filter.isEmpty else {
            return title.localizedCaseInsensitiveContains("about") || title.contains("关于")
        }
        // Whitespace around each alternative is not part of it: `Notepad | 记事本` must behave
        // like `Notepad|记事本` (review movetarget-r2 m-1: the untrimmed "Notepad " matched
        // nothing while " 记事本" happened to match -- a half-working filter).
        return filter.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.contains { alternative in
            !alternative.isEmpty && title.localizedCaseInsensitiveContains(alternative)
        }
    }

    /// The two fields the lock decision needs, lifted off `RemoteWindowRegistry`'s snapshot so
    /// the decision itself is a pure function the self-test can drive.
    struct Candidate: Equatable {
        let windowId: UInt32
        let title: String
    }

    /// Whether `filter` names a target explicitly (vs the nil/empty About heuristic).
    private static func isExplicit(_ filter: String?) -> Bool {
        guard let filter else { return false }
        return !filter.isEmpty
    }

    /// The window `runMoveResizeScenario` locks onto, or `nil` to keep waiting (the caller retries
    /// every tick). Lowest `windowId` first, so a filter matching several windows does not depend
    /// on `windowSnapshots()`' dictionary order between runs.
    ///
    /// `preExisting` is the id set captured the moment the extra apps were launched
    /// (`windowIdsBeforeExtraApps`). Under an EXPLICIT filter those ids are skipped: the 2026-09-02
    /// real-host run (env-202609-14, review resize-live-r2 I-2) locked a Notepad left over from an
    /// earlier run because the lock fires as soon as `extraAppsLaunched` is set -- before this
    /// run's own window has appeared -- so "prefer the new one" would have been a no-op (there was
    /// no new one yet) and only exclusion, plus the per-tick retry, waits for it. Consequence: an
    /// explicit filter can never lock the first app's own window either (it pre-exists too). The About
    /// heuristic (nil/empty filter) deliberately does NOT exclude: About is the FIRST app's window,
    /// itself pre-existing at that moment, and the target that path has always meant -- which also
    /// means a leftover About from an earlier run is matched just the same and wins whenever its
    /// id is the lower one. That weakness predates this change (the parent revision's lock was
    /// behaviourally equivalent on that path: first match over the same ascending order) and is
    /// left as is here.
    static func lock(candidates: [Candidate], filter: String?, preExisting: Set<UInt32>) -> Candidate? {
        let explicit = isExplicit(filter)
        return candidates.sorted(by: { $0.windowId < $1.windowId }).first { candidate in
            matches(title: candidate.title, filter: filter) && (!explicit || !preExisting.contains(candidate.windowId))
        }
    }

    /// The ids an explicit filter matched but `lock` skipped as pre-existing -- non-empty exactly
    /// when the filter matches SOMETHING yet nothing this run launched, which is the case the
    /// one-shot "waiting for a window launched by this run" log line names. Empty whenever a new
    /// match exists, and always empty for the About heuristic: it never skips, so its `lock` is
    /// `nil` only when nothing matches at all. Given `lock == nil`, every match IS pre-existing
    /// (an explicit filter would otherwise have locked it), so no `preExisting` test is repeated
    /// here -- an explicit-filter guard was tried in the author's own mutation pass and the
    /// `preExisting` predicate by review movetarget-lock-r1 (its N3); both proved equivalent
    /// mutants and were removed.
    static func matchedOnlyPreExisting(candidates: [Candidate], filter: String?, preExisting: Set<UInt32>) -> [UInt32] {
        guard lock(candidates: candidates, filter: filter, preExisting: preExisting) == nil else { return [] }
        return candidates.filter { matches(title: $0.title, filter: filter) }.map(\.windowId).sorted()
    }
}

/// The multi-window scenario's acceptance, as a pure function: which windows count as "new
/// content windows that appeared after the extra apps were launched". Inputs: the qualifying
/// windows visible at finish(), the ids this run's own close legs closed, and the ids EVER seen
/// visible-with-content after the exec (accumulated per tick): on the 2026-09-02 F0 control run the move/resize target lock picked the
/// run-launched Notepad (as designed since 1f05aa4) and its close leg closed it before finish(),
/// so a visible-at-finish count reported 0 new windows by construction (F0-H1,
/// docs/upgrade-gate/2026-09-f0-control-live.md §3 item 1). `before` is `windowIdsBeforeExtraApps`.
enum MultiWindowGate {
    /// Counts a new window only if it is still a qualifying visible window at finish() OR this
    /// run's own close legs closed it (review multiwindow-gate-r1 I-1: "ever seen" alone would let
    /// any window that merely flashed after the exec -- a popup, a transient dialog -- satisfy the
    /// count; binding it to our own SC_CLOSE targets keeps the causal link to the extra apps).
    /// `everSeenContent` still gates `closedByHarness`: a close target that never showed content
    /// does not count either. `before` = `windowIdsBeforeExtraApps`, subtracted last.
    static func newContentWindowIds(
        visibleAtFinish: Set<UInt32>, closedByHarness: Set<UInt32>, everSeenContent: Set<UInt32>, before: Set<UInt32>
    ) -> Set<UInt32> {
        visibleAtFinish.union(closedByHarness.intersection(everSeenContent)).subtracting(before)
    }
}

/// adr/0010 W4 first slice: menu-popup end-to-end acceptance -- activates the About window
/// (via the real, gated `FocusAuthority` click path, same as `activateForClose`), sends
/// Alt+Space (About's system menu shortcut on Windows), and asserts a NEW child window
/// appears within 5s carrying a real `ownerWindowId` attachment (adr/0010 §4), then that
/// Escape closes it within 3s. Requires `WINDOW_SMOKE_EXTRA_APPS` (multiwin prereq), same
/// convention as `WINDOW_SMOKE_MAXIMIZE`/`WINDOW_SMOKE_MOVE`.
let popupScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_POPUP"] == "1"

/// How many popup open/close ROUNDS `WINDOW_SMOKE_POPUP`'s scenario runs back to back
/// (requires that switch and its own multiwin prereq, both unchanged). 1 -- the default --
/// is the original one-shot: same phases, same log lines, same informational-only latency
/// report, byte for byte.
///
/// >1 turns the scenario into a real sample generator: each round re-arms after the previous
/// popup closed cleanly (recapture the pre-keystroke windowId set, settle, resend Alt+Space
/// -- the About window keeps focus, so the activate leg is NOT re-run except as the single
/// permitted retry when a round's create-poll times out) and contributes one
/// WindowCreate→first-content latency sample. Only at n>1 does `finish()` gate on the
/// ≤100ms p95 LAN budget (docs/plans/phase2.md §4 W4) -- which is exactly the "needs real
/// n>1 data before it can be enforced" condition the one-shot's own informational print has
/// carried since adr/0010 §5.
let popupSamplesTotal = max(1, Int(ProcessInfo.processInfo.environment["WINDOW_SMOKE_POPUP_SAMPLES"] ?? "") ?? 1)

/// adr/0013 acceptance (W6 long tail, "托盘真图标"): when set, this run is expected to be
/// pointed (via `WINDOW_SMOKE_APP`/`WINDOW_SMOKE_APP_ARGS`) at a program that creates at
/// least one notification-area icon -- the lab's PowerShell NotifyIcon driver -- and
/// `finish()` then gates on the REAL icon bitmap having been displayed: because the driver
/// disposes its icon before this harness shuts down (so the existing create−delete formula
/// gate above can see the whole lifecycle), the live `realIconCount` at finish() time is
/// legitimately 0 again -- the acceptance evidence is `Diagnostics.realIconMaxObserved`,
/// latched by `TrayStatusController` at the exact moment a real bitmap is installed (R1
/// finding 2: a poll-based sample would miss a create+delete landing in one drain batch).
let trayScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_TRAY"] == "1"

/// adr/0014 §6 acceptance (W6's outbound tray-click lane): on top of `WINDOW_SMOKE_TRAY`'s own
/// icon-display gates, drive ONE left click through the real click path once a live icon has
/// actually been observed, and gate on what left this process -- `clicksForwarded >= 1`, the
/// `notifyEventsSent == 2 * clicksForwarded` v1 identity, `clicksDroppedIconGone == 0`, the
/// exact `[WM_LBUTTONDOWN, WM_LBUTTONUP]` message sequence in order, the clicked key echoed
/// back bit-for-bit, and a zero `CRSession.outboundDroppedNoRailCount` delta across the click.
///
/// Requires `WINDOW_SMOKE_TRAY=1` (it reuses that scenario's whole "point this run at a
/// tray-icon-bearing program" setup and its `realIconMaxObserved`/`liveCount` evidence as the
/// arming condition) -- same "requires its own prereq switch" convention
/// `WINDOW_SMOKE_POPUP_SAMPLES` already follows. Requested without it, this stays off and says
/// so, rather than silently arming a scenario whose subject never appears.
///
/// **What this does NOT prove**: that the server did anything. MS-RDPERP 3.3.5.2.5.4
/// acknowledges the Client Notification Event PDU with nothing at all -- no response, no error
/// code, no late verdict -- so every assertion below is about what this client SENT. That is
/// the strongest claim available here, and stating it plainly is better than an assertion
/// shaped to look like an end-to-end one.
let trayClickScenarioEnabled: Bool = {
    guard ProcessInfo.processInfo.environment["WINDOW_SMOKE_TRAY_CLICK"] == "1" else { return false }
    if !trayScenarioEnabled {
        print("[config] WINDOW_SMOKE_TRAY_CLICK=1 ignored -- it requires WINDOW_SMOKE_TRAY=1 (the tray scenario's own icon evidence is this scenario's arming condition)")
        return false
    }
    return true
}()

/// Optional target filter for the tray-click scenario (`WINDOW_SMOKE_TRAY_CLICK_TOOLTIP`):
/// when set, the click targets the first LIVE icon whose wire tooltip equals this string
/// exactly, and arming WAITS until such an icon exists (bounded by the scenario's own
/// deadline). Without it the scenario clicks the first live key -- correct for the send-path
/// gates, but in a real session that key is one of the session's standing tray icons, not the
/// lab driver's, so a remote loop-back (the driver writing a marker on MouseUp) would measure
/// the wrong icon. The filter is how the loop-back run says "click MY icon".
let trayClickTooltipFilter: String? = {
    guard trayClickScenarioEnabled else { return nil }
    guard let v = ProcessInfo.processInfo.environment["WINDOW_SMOKE_TRAY_CLICK_TOOLTIP"], !v.isEmpty else { return nil }
    print("[config] tray-click target filter: tooltip == \"\(v)\"")
    return v
}()

/// MS-RDPERP `TS_RAIL_ORDER_SYSCOMMAND` `SC_*` values -- duplicated here from
/// `App/RemoteWindowRendering/RemoteWindowRegistry.swift`'s own `SysCommand` enum (itself
/// verified against `ThirdParty/FreeRDP/include/freerdp/rail.h:126-133`), matching this
/// codebase's established "each layer duplicates narrowly, cites its source" precedent for
/// small numeric constants (see e.g. `WindowOrderField`, duplicated three times over
/// `WindowModel.swift`/`RemoteWindowRegistry.swift`/this file's own `styleDumpLine`).
private enum SC {
    static let maximize: UInt16 = 0xF030
    static let restore: UInt16 = 0xF120
    static let close: UInt16 = 0xF060
}

@MainActor
final class WindowSmokeDelegate: NSObject, NSApplicationDelegate {
    private let host: String
    private let user: String
    private let pass: String
    private let screenshotPath: String
    private let launchedProgram: String
    private let launchedAppKind: LaunchedAppKind
    private let inputTestMode: InputTestMode?

    private var session: CRSession!
    private var registry: RemoteWindowRegistry!
    private var drainTimer: Timer?
    private var startTime: Date!

    /// M1 L9 (adr/0015 §5.A.5, §9's L6/L9 rows): **this run's one and only display-topology
    /// reader**, replacing the two raw `NSScreen.screens.first` reads this file used to make (one
    /// for the desktop size, one for the Y-flip anchor inside `evaluateMoveResizeLeg`) -- two
    /// independent reads of a layout that can change between them, which is the defect §5.A.4
    /// turns into an invariant.
    ///
    /// **The LIVE provider, deliberately not `StaticDisplayTopologyProvider`** -- and this is the
    /// one place where this harness must NOT copy `AppDelegate.swift`'s shape. The App builds a
    /// fresh registry per connect and never reconnects in place, so wrapping the frozen snapshot
    /// there is exactly right. This harness REUSES one registry across a `WINDOW_SMOKE_CYCLES`
    /// soak (`RemoteWindowRegistry.swift:479-508`), and its `prepareForReconnect()` re-take reads
    /// `topologyProvider.currentTopology`: behind a static wrapper that re-take would return the
    /// first cycle's data forever while `sessionTopologyFreezeCount` still counted up, i.e. the
    /// pin would pass on a re-take that measured nothing. The invariant is preserved instead by
    /// ORDER, which `freezeAndApplyDesktopSize(to:reason:)` owns: freeze, re-assign the desktop
    /// size, then `prepareForReconnect()`, in one main-actor turn.
    private let displayTopology = DisplayTopologyProvider()

    /// The desktop size (remote px) this run last froze and handed to `CRSession`, or `nil` if a
    /// freeze ever found no usable display (adr/0015 §5.A.6: in that state nothing is sent).
    private var sessionDesktopSizeInRemotePixels: DesktopSizeInRemotePixels?

    /// F2's measurement (`docs/plans/phase3.md:132`): every SURFACE_MAPPED event's target hint,
    /// aggregated for the one `[gfx] target=` line every run prints at summary time.
    private var gfxTargetHints = GfxTargetHintTally()

    /// F1's measurement (`docs/plans/phase3.md:130`, M1 L9b): the backing-px vs GFX-mappedSize
    /// pairing, sampled at present time. **Measurement only** -- see `F1BackingVsMapped`'s own
    /// note; nothing here may reach `ok` or the exit code.
    private var f1Measurements = F1BackingVsMappedTally()

    // Phase 1 acceptance state (see the extraApps/cyclesTotal globals' doc comments).
    private var extraAppsLaunched = false
    /// windowIds already present the moment the extra apps were exec'd -- the multi-window
    /// assertion only counts windows that appeared AFTER (2026-08-22 review HIGH: leftover
    /// windows from a long-lived session could satisfy a bare count with zero extra apps
    /// actually launching).
    private var windowIdsBeforeExtraApps: Set<UInt32> = []
    /// Every window id seen visible-with-content (and inside the plausible-content band) on any
    /// tick after the extra apps were launched, with the last title seen for it -- the
    /// multi-window assertion's input (`MultiWindowGate`), so a window this run launched and later
    /// closed (the move/resize target since 1f05aa4) still counts as having appeared.
    private var contentWindowsSeenAfterExtraApps: [UInt32: String] = [:]
    /// Every ExecResult with a nonzero (failed) result observed this run.
    private var failedExecResults: [String] = []
    private var cycleIndex = 0
    private var cycleDeadline: Date?
    private var cycleStartedAt: Date?
    private var cycleResults: [(rendered: Bool, closed: Bool, clean: Bool, seconds: Double)] = []
    private var baselineRSS: Int?
    /// Set once this cycle's winver close target is locked -- non-nil means the cycle is
    /// in its close-the-window phase (activate -> settle -> Enter -> wait for delete).
    private var cycleCloseTargetId: UInt32?
    private var cycleCloseDeadline: Date?
    /// Keyboard input is FOCUS-addressed on the server: after a reattach the remote focus
    /// can sit on a different window than our chosen target. adr/0012: the activation click
    /// that locks/re-locks `cycleCloseTargetId` (see `activateForClose`) now routes through
    /// the SAME real mouseDown path the production app uses -- `RemoteWindowRegistry`'s own
    /// `FocusAuthority` gate buffers the Enter keystroke until the server actually confirms
    /// convergence (or drops it on a hard rollback), so this no longer needs to manually
    /// poll `MonitoredDesktop.activeWindowId` before sending it. `cycleEnterAt` is now just
    /// a short settle between the click and the Enter (not a focus-confirmation wait --
    /// same reasoning as `sendSyntheticClick`'s own two-stage gap). Success is still
    /// measured as "the About-window population shrank", not "this exact windowId
    /// vanished" (the server closes whichever winver actually holds focus).
    private var cycleEnterAt: Date?
    private var cycleEnterSent = false
    private var cycleAboutCountAtLock = 0
    /// One retry of the activate+Enter sequence per cycle (observed ~1-in-20 residual
    /// miss even with focus confirmation -- a single re-arm reliably clears it).
    private var cycleCloseRetried = false
    /// When this cycle first showed rendered content -- anchors the grace window for the
    /// About-title target lock (the title often lands on a later WindowUpdate than the
    /// first presented frame; observed live as ~10% of fast cycles spuriously skipping
    /// the close leg entirely when the lock ran one drain too early).
    private var cycleRenderedAt: Date?
    /// adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE): whether the server's
    /// `activeWindow` has been observed to equal `cycleCloseTargetId` at any point since
    /// the target was (most recently) locked -- this harness's own external proxy for "the
    /// FocusAuthority gate actually opened and the real Enter got a chance to reach the
    /// wire," without reaching into FocusAuthority's private state. Reset only when a
    /// *fresh* target is locked (Phase A) -- deliberately NOT reset by the one retry, so a
    /// convergence that happened on the first attempt but not the second still correctly
    /// counts as "convergence happened somewhere in this close-leg" and skips the probe.
    private var cycleTargetEverConverged = false

    // adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE) -- in-flight probe watch
    // state, all nil/empty when no probe is pending (the common case, and always true when
    // closeProbeEnabled is false).
    private struct CloseProbeResult {
        let cycle: Int
        let targetId: UInt32
        let closedDespiteNonConvergence: Bool
    }
    private var closeProbePendingCycle: Int?
    private var closeProbePendingTarget: UInt32?
    private var closeProbePendingAboutCountAtSend: Int?
    private var closeProbePendingDeadline: Date?
    private var closeProbeResults: [CloseProbeResult] = []

    // Flow evidence counters (W1 focus-observability slice, task item 1): proves the
    // eb2e333 MonitoredDesktop/ZOrderSync/MinMaxInfo/LocalMoveSize plumbing is actually
    // live end to end, not just compiled -- see docs/adr/0008 §0 for the sample-derived
    // per-session shapes these counters are checked against (MonitoredDesktop ~25/session,
    // ZOrderSync exactly 1/session). MinMaxInfo/LocalMoveSize are counted but never gated
    // (informational only -- LocalMoveSize in particular needs a local drag, which this
    // headless harness never performs).
    private var monitoredDesktopEventCount = 0
    private var zOrderSyncEventCount = 0
    private var minMaxInfoEventCount = 0
    private var localMoveSizeEventCount = 0
    private var activeWindowIdTransitionCount = 0
    /// windowId -> this run's own elapsed-seconds clock at the moment its `WindowCreate` was
    /// drained -- unconditional (every run, not just WINDOW_SMOKE_POPUP), cheap (one dict
    /// entry per window this run ever creates), and what `runPopupScenario`'s own
    /// WindowCreate→first-content latency measurement reads (adr/0010 §5's acceptance text).
    private var windowCreateTimestamps: [UInt32: TimeInterval] = [:]
    /// Classified (via `RemoteWindowRegistry.serverDesktopState()`, adr/0012 §3) running
    /// value used only to detect and log activeWindow transitions.
    private var flowLastActiveWindow: ServerActiveWindow = .unmonitored

    // Focus rotation scenario state (task item 2): round-robins ClientActivate across the
    // visible content windows the WINDOW_SMOKE_EXTRA_APPS setup produced, once settled, and
    // measures per-rotation convergence of `serverDesktopState().activeWindowId`. See
    // `runFocusRotation` for the state machine.
    private struct FocusRotationResult {
        let targetId: UInt32
        /// Converged within the 500ms soft deadline (adr/0012 §1's gating tier -- W1's own
        /// >=99% exit criterion is measured against this, once this harness has produced
        /// real n>=100 numbers to gate against; not asserted here).
        let softHit: Bool
        /// Converged at all within the eventual (`FocusAuthority.hardDeadlineInterval`,
        /// 5000ms) window -- the observation tier (adr/0012 §4.2: "分开报软截止内命中率
        /// （gating）与最终收敛率（观测）"). `softHit == true` implies `eventualHit == true`.
        let eventualHit: Bool
        let latencyMs: Double?
        /// Only meaningful for an eventual miss -- what the server's activeWindowId
        /// actually was at the eventual cap.
        let observedActiveWindow: ServerActiveWindow
    }
    private var focusRotationReady = false
    private var focusRotationWindowIds: [UInt32] = []
    private var focusRotationsIssued = 0
    private var focusRotationPendingTargetId: UInt32?
    private var focusRotationPendingSentAt: Date?
    /// The 500ms soft-deadline mark (adr/0012 §1) -- convergence observed at or before this
    /// is a `softHit`; after it (but before `focusRotationPendingEventualDeadline`), still an
    /// `eventualHit` but not a `softHit`.
    private var focusRotationPendingSoftDeadline: Date?
    /// The outer poll cutoff -- `FocusAuthority.hardDeadlineInterval` (5000ms) past send,
    /// matching adr/0012 §1's own hard-rollback safety-valve window, so "never converged" in
    /// this harness means the same thing it means to `FocusAuthority` itself.
    private var focusRotationPendingEventualDeadline: Date?
    /// Gates the 300ms inter-rotation settle; nil means "no wait pending" (the first
    /// rotation fires as soon as the scenario becomes ready).
    private var focusRotationNextAllowedAt: Date?
    private var focusRotationDone = false
    private var focusRotationResults: [FocusRotationResult] = []

    private var frameReadyCount = 0
    private var evidenceRoutineRan = false

    // Phase 2 W0③ (first-frame gating): windowIds already checked the first time their
    // own isVisible flipped true -- checked exactly once per windowId so a later
    // legitimate re-hide/re-show (RAIL show-state toggling) never re-triggers this.
    private var firstFrameGateChecked: Set<UInt32> = []
    // One entry per windowId observed visible with neither real content nor a logged
    // timeout -- collected rather than asserted immediately so finish() reports every
    // offender in one gating check, not one assertion per window.
    private var firstFrameGateViolations: [String] = []

    // W4c review: push-drain latency samples, one per drainNow() invocation that observed
    // at least one FRAME_READY -- see drainNow()'s own comment for exactly what this
    // measures and why. Milliseconds, not seconds, matching how the p95 assertion in
    // finish() reports it.
    private var frameLatencySamplesMs: [Double] = []

    // W4c deliverable 5: the input-test target window (the launched app's own anchored
    // window, e.g. winver's About dialog), when and what was sent to it, and whether/when
    // the expected WindowDelete arrived. `inputTestSentAt`/`inputTestWindowDeletedAt` are
    // this run's own elapsed-seconds clock (same `startTime` origin as everything else in
    // this file), not wall time, so the 3s budget check in `finish()` is a plain subtraction.
    private var inputTestWindowId: UInt32?
    private var inputTestSentAt: TimeInterval?
    private var inputTestWindowDeleted = false
    private var inputTestWindowDeletedAt: TimeInterval?
    // User-reported "clicks don't work" review round: set once, right before the first
    // synthetic event is sent (see runInputTest), checked in finish().
    private var keyWindowCheckResult: (passed: Bool, detail: String)?

    // MARK: - Scripted input batteries (adr/0011 §5 items 5/6/7)

    /// One step of a scripted input battery. Three scenarios share this one machine --
    /// `WINDOW_SMOKE_CMDMAP_LIVE` (six chords), `WINDOW_SMOKE_INPUT_TEST=ime` (one IME commit
    /// then Cmd+S) and `WINDOW_SMOKE_UNICODE_DEGRADE` (two IME commits) -- because all three
    /// are the same shape: lock one target window, run the input-test focus preamble against
    /// it, then dispatch a fixed list of real events at real, host-processing-sized gaps.
    /// They differ only in the list, which is exactly what this type carries.
    private struct InputScriptStep {
        /// Human-readable label for this step's own progress line.
        let label: String
        /// Seconds to wait after the PREVIOUS step (or after arming, for the first step)
        /// before dispatching this one. Real gaps, not zero: a real host needs time to
        /// actually process each chord -- the same finding `sendSyntheticClick`'s own
        /// two-stage gap documents (firing two synthetic inputs back to back with no gap made
        /// the remote session miss the second one outright, even with every local
        /// windowId/canBecomeKey check passing).
        let gapBefore: TimeInterval
        let action: Action
        /// Printed verbatim immediately after this step is dispatched, when non-nil -- this
        /// is where the machine-readable markers the external comparer parses come from, so
        /// they are emitted at exactly the step whose completion they describe rather than
        /// batched at the end.
        let markerAfter: String?

        enum Action {
            /// A synthesized real-`NSEvent` chord: optional Cmd-down flagsChanged, keyDown/
            /// keyUp for `macKeyCode` (carrying `characters` as both `characters` and
            /// `charactersIgnoringModifiers`), then the matching Cmd-up flagsChanged.
            case chord(macKeyCode: UInt16, characters: String, command: Bool)
            /// One composed IME commit, delivered through the target window's content view's
            /// `NSTextInputClient.insertText(_:replacementRange:)` -- the exact method a real
            /// macOS input method calls, never `RemoteWindowRegistry.handleInput` directly.
            case imeCommit(text: String)
        }
    }

    /// adr/0011 §5 item 6's fixed probe string: exactly 50 Unicode scalars spanning Han
    /// characters, CJK punctuation (，：、。), full-width brackets/quotes (（）《》), full-width
    /// exclamation/question/semicolon (！？；), the em-dash pair (——), the ellipsis (…) and
    /// full-width digits/latin (０１Ａ) -- deliberately NOT plain ASCII anywhere, since the
    /// whole point is the lane that only exists for text a scancode cannot express (adr/0011
    /// §1: "合成型输入源交回 NSTextInputClient"). Fixed, not generated: the external readback
    /// comparer needs a byte-exact expectation, and `expected-utf8-hex` is derived from this
    /// same constant so the two can never drift.
    private static let imeCommitText =
        "远程视窗如临本机，输入法五十字往返验证：句读、顿号与全角（）《》符号！？；：。破折号——省略…０１Ａ"

    /// The armed script, its target, and its progress. All empty/nil/false on a run where no
    /// scripted battery is active, which is every run that sets none of the three env
    /// switches above (`runInputScript` returns immediately in that case).
    private var inputScriptTag = ""
    private var inputScriptSteps: [InputScriptStep] = []
    private var inputScriptWindowId: UInt32?
    private var inputScriptIndex = 0
    private var inputScriptNextStepAt: Date?
    /// Seconds to keep the run alive after the LAST step is dispatched -- a real host needs
    /// this (the cmdmap/ime batteries end on Cmd+S, whose disk write on the Windows side is
    /// what the external readback pass is going to read).
    private var inputScriptSettle: TimeInterval = 0
    private var inputScriptSettleUntil: Date?
    private var inputScriptChordsDispatched = 0
    private var inputScriptCommitsDelivered = 0
    /// Set when `window.contentView` was not a `RemoteWindowContentView` -- an
    /// assert-fail-the-scenario condition, not something to route around: an IME commit that
    /// did not go through the real `NSTextInputClient` conformance proves nothing about the
    /// path adr/0011 §2 actually ships.
    private var inputScriptCastFailed = false
    private var inputScriptComplete = false

    // Phase 2 W2 task item 5b/5c (WINDOW_SMOKE_MAXIMIZE): maximize -> restore -> close e2e
    // state machine -- see `runMaximizeScenario`'s own doc comment for the full sequence.
    private enum MaximizePhase: Equatable {
        case waitingForTarget
        case awaitingMaximize(windowId: UInt32, sentAt: Date)
        case awaitingRestore(windowId: UInt32, sentAt: Date)
        case awaitingClose(windowId: UInt32, sentAt: Date)
        case done
    }
    private var maximizePhase: MaximizePhase = .waitingForTarget
    private static let maximizePollTimeout: TimeInterval = 5.0
    /// `grew`: did a WindowUpdate report width >= 2000 remote px (`SizeBand.maximizedWidthFloor`,
    /// judged through the frozen topology) within 5s of SC_MAXIMIZE.
    /// `mappedWithContent`: was the window still mapped (visible, real content) at that
    /// point -- closes W0's deferred M1 acceptance debt ("a maximized window must build",
    /// phase2.md W0/M1) even on the failure path (checked at the 5s timeout too).
    private var maximizeResult: (grew: Bool, mappedWithContent: Bool)?
    /// Did a later WindowUpdate report width < 1000 remote px (`SizeBand.restoredWidthCeiling`,
    /// judged through the frozen topology) within 5s of SC_RESTORE.
    private var restoreResult: Bool?
    /// Did WindowDelete arrive within 5s of SC_CLOSE (task item 5c's traffic-light loop
    /// assert) -- resolved via `maximizeCloseTargetId`/`maximizeCloseWindowDeletedAt` below,
    /// set by `drainNow()`'s own windowDelete bookkeeping, mirroring `inputTestWindowId`'s
    /// exact pattern.
    private var closeResult: Bool?
    private var maximizeCloseTargetId: UInt32?
    private var maximizeCloseWindowDeletedAt: TimeInterval?
    /// Team-lead review (2026-08-23, maximize-scenario real-host regression investigation):
    /// set once the target locks (`.waitingForTarget`), so `drainNow()`'s own per-event
    /// closure can trace every geometry-carrying order AND every `ServerLocalMoveSize` event
    /// for this specific window from the start -- unlike `maximizeCloseTargetId`, which is
    /// only set much later (the close leg), this needs to be live from the very first
    /// SC_MAXIMIZE send, since the whole point is observing what happens BETWEEN that send
    /// and the (missing/late) size WindowUpdate.
    private var maximizeTargetWindowId: UInt32?

    // Phase 2 W3 (WINDOW_SMOKE_MOVE): programmatic move -> resize -> server-sync e2e state
    // machine -- see `runMoveResizeScenario`'s own doc comment for the full sequence and
    // its acknowledged honesty gap vs a real mouse-driven drag.
    private enum MoveResizePhase: Equatable {
        case waitingForTarget
        case awaitingMoveSettle(windowId: UInt32, target: NSRect, sentAt: Date)
        case awaitingResizeSettle(windowId: UInt32, target: NSRect, sentAt: Date)
        case awaitingClose(windowId: UInt32, sentAt: Date)
        case done
    }
    private var moveResizePhase: MoveResizePhase = .waitingForTarget
    /// True while either leg is waiting for its round trip -- the window in which a surface remap
    /// on the target is an observation the leg must sample (F0-2).
    private var moveResizeLegAwaitingSettle: Bool {
        switch moveResizePhase {
        case .awaitingMoveSettle, .awaitingResizeSettle: return true
        case .waitingForTarget, .awaitingClose, .done: return false
        }
    }
    private static let moveResizePollTimeout: TimeInterval = 3.0
    /// Team-lead review (2026-08-23 real-host run): mirrors `maximizePollTimeout`'s own 5s
    /// budget for the close leg specifically -- WindowDelete round trips are a full RAIL
    /// request/response, not the local settle-debounce the move/resize legs above wait on,
    /// so it gets its own, longer timeout rather than reusing `moveResizePollTimeout`.
    private static let moveResizeClosePollTimeout: TimeInterval = 5.0
    private var moveResizeWindowId: UInt32?
    /// Team-lead review round 6 (2026-08-23): the GFX-mapped size observed at the moment
    /// the move leg's target was locked -- baseline for the move leg's own "did the server
    /// remap the surface mid-leg" informational report (position-only matching means a size
    /// change during the move leg is expected/legitimate, not a failure, but still worth
    /// surfacing).
    private var moveResizeOriginalMappedSize: CGSize?
    /// One leg's resolved outcome -- `matched`: did any WindowUpdate-applied content rect for
    /// the target window round-trip to that leg's target inside the 3s budget, judged in remote
    /// px within `MoveResizeGate.toleranceInRemotePixels` (M1 L9: the old judgement was "±1pt",
    /// two changes at once -- unit and value, adr/0015 §6.1 + owner ruling U6). `oscillated`:
    /// did any LATER observed content rect in the same leg diverge from the target again after
    /// the first match (a real generic ping-pong detector isn't needed here -- this bounded
    /// window only needs "reaches the one target this leg cares about, and stays there").
    ///
    /// The two named halves of adr/0015 §6.3's paired assertion ride along, because `finish()`
    /// must be able to say WHICH half failed, and `deductionsText` carries §6.2's deduction
    /// record for the exact comparison that produced the verdict.
    struct MoveResizeLegOutcome {
        /// §6.3's RECT half, and the direct descendant of the pre-M1 `matched`: did any observed
        /// rect reach this leg's target inside the budget, judged in remote px at
        /// `MoveResizeGate.toleranceInRemotePixels`?
        let rectCheckPassed: Bool
        /// §6.3's POINT half, judged on **the same observed rect** the rect half selected (or, if
        /// the leg never matched, on the same last rect the rect half was judged against) -- the
        /// pairing is only meaningful if both halves speak about one observation.
        let pointCheckPassed: Bool
        /// `MoveResizeGate.oscillationVerdict` over this leg's observations -- `unjudgeable` when the
        /// leg could not be judged (no frozen topology, no observation, or no match; the cause is in
        /// `detail`), which `finish()` reports as N/A rather than as a PASS.
        let oscillation: MoveResizeGate.OscillationVerdict
        /// Human-readable paired verdict + measured deltas + the deductions in force (§6.2).
        let detail: String

        var oscillated: Bool { oscillation.isOscillated }

        /// The leg's own verdict: both halves, per §6.3.
        var passed: Bool { rectCheckPassed && pointCheckPassed }
    }
    private var moveResult: MoveResizeLegOutcome?
    /// Throttle for the "filter matched no window" line in the target lock (printed once).
    private var moveResizeTargetMissLogged = false
    /// Its sibling for the other one-shot line: the filter matched only windows that pre-date the
    /// extra-app launch. Separate flags so each message can appear once, in whichever order the
    /// live run produces them (review movetarget-lock-r1 I-2: a shared flag let the first printer
    /// swallow the other line for the rest of the run).
    private var moveResizeTargetPreExistingOnlyLogged = false
    private var resizeResult: MoveResizeLegOutcome?
    /// The most recent `ClientWindowMove` this run actually put on the wire for the move/resize
    /// target, verbatim (adr/0015 §6.2's deduction record): the harness knows what Windows-space
    /// rect it ASKED for, so the difference between that and these four integers IS the deduction
    /// the send path applied, measured rather than restated. Restating it would mean copying
    /// `RemoteWindowRegistry.measuredClientWindowMoveLeftBorder` (F6 (a)) into a second file, and
    /// U5's record-only ruling forbids this lane from moving -- or duplicating -- that number.
    /// Timestamped so a verdict can say whether the send it is quoting belongs to the leg being
    /// judged or to an earlier one -- an unlabelled "the deduction was N" taken from the previous
    /// leg's send is exactly the silent absorption §6.2 forbids.
    private var lastClientWindowMoveSent: (left: Int32, top: Int32, right: Int32, bottom: Int32, at: Date)?
    /// Team-lead review round 4 (2026-08-23, no-false-red discipline): whether the real
    /// target window's `NSWindow.styleMask` actually included `.resizable` at the moment
    /// the resize leg was sent (About never does -- StyleTranslatorTests'
    /// `aboutWindowsDialogShape` -- so this scenario's resize-leg round-trip assertion was
    /// gating and failing on EVERY run by design, an assertion bug: the leg proves
    /// "does a programmatic geometry change round-trip through ClientWindowMove", which is
    /// meaningful regardless of resizability, but the round-trip itself failing for a
    /// non-resizable target's wire-level move is not evidence of a real product defect the
    /// way it would be for a genuinely resizable window). `nil` until the resize leg
    /// actually sends (mirrors `resizeResult`'s own "not yet run" state).
    private var moveResizeTargetIsResizable: Bool?
    /// Team-lead review (Fix 2, 2026-08-23 real-host run): this scenario used to leave its
    /// About window open at the end -- a subsequent `WINDOW_SMOKE_CYCLES` soak run then
    /// locked its own close-probe target onto that leftover window (Phase 1's stale-window
    /// contamination class), observed live as 4/20 close-leg failures whose probe target
    /// windowId was actually THIS scenario's own window from an earlier run. `nil` until the
    /// resize leg resolves and the close leg actually gets sent (see `runMoveResizeScenario`'s
    /// `.awaitingResizeSettle` case) -- `finish()` only gates on `moveResizeCloseResult` when
    /// this is non-nil, mirroring how the maximize scenario's own close leg can be skipped on
    /// an earlier-leg failure.
    private var moveResizeCloseTargetId: UInt32?
    private var moveResizeCloseWindowDeletedAt: TimeInterval?
    private var moveResizeCloseResult: Bool?
    /// Content rects (NOT raw `NSWindow.frame` -- team-lead review, 2026-08-23 real-host
    /// run: RAIL geometry maps to a window's CONTENT rect once it has native chrome,
    /// `RemoteWindow.updateFrame`'s own doc comment has the full finding) observed via a
    /// geometry-carrying WindowUpdate/WindowCreate (or, since F0-2, surface remap) for `moveResizeWindowId`, recorded by
    /// `drainNow()`'s own event-kind switch, timestamped against `startTime` -- reset at the
    /// start of each leg so a leg's own oscillation check never sees the PRIOR leg's settle
    /// history. Each entry is `window.contentRect(forFrameRect: window.frame)` at the moment
    /// the WindowUpdate was applied (post `registry.handle(event)`), so a suppressed
    /// (ignored) echo during the in-flight gesture naturally never shows up here as a
    /// spurious "match" -- and so this scenario's own comparisons stay in the SAME rect
    /// space `RemoteWindow`/`RemoteWindowRegistry` actually round-trip through the wire,
    /// rather than the raw outer frame (which differs from content rect by this window's
    /// chrome insets once it's titled).
    /// `source`: "update" for a geometry-carrying WindowCreate/WindowUpdate, "remap" for the frame
    /// re-apply a surface remap triggers (F0-2) -- both are real states the local window went
    /// through and both count for the round-trip match and the oscillation scan.
    private var moveResizeObservedContentRects: [(contentRect: NSRect, at: TimeInterval, source: String)] = []

    // adr/0010 W4 first slice (WINDOW_SMOKE_POPUP): menu-popup e2e state machine -- see
    // `runPopupScenario`'s own doc comment for the full sequence.
    private enum PopupPhase: Equatable {
        case waitingForTarget
        case awaitingActivateSettle(sentAt: Date)
        case awaitingPopupCreate(sentAt: Date)
        case awaitingEscapeSettle(popupWindowId: UInt32, sentAt: Date)
        case awaitingEscapeClose(popupWindowId: UInt32, sentAt: Date)
        /// Team-lead review (2026-08-23, real-host run): the About window used to stay open
        /// at the end of this scenario -- THIRD occurrence of the same stale-window
        /// contamination class `moveResizeCloseTargetId`'s own doc comment already documents
        /// (Fix 2 there; this run's own cycles 2/20-with-probes=0 was this exact class again,
        /// not a regression). Every terminal path (popup appeared and closed cleanly, popup
        /// appeared but never closed, popup never appeared at all) now funnels through this
        /// one cleanup phase before `.done`.
        case awaitingAboutClose(sentAt: Date)
        /// `WINDOW_SMOKE_POPUP_SAMPLES` > 1 only: the inter-round re-arm settle. The About
        /// window keeps focus across a round boundary (the popup that just closed was its own
        /// child; closing it returns focus to the owner), so a round re-arm deliberately does
        /// NOT re-run the activate leg -- it recaptures the pre-keystroke windowId set, waits
        /// out this settle, and sends the next Alt+Space directly. Re-activating between
        /// rounds would make every sample measure a focus round trip this scenario is not
        /// trying to measure, on top of the popup latency it is.
        case awaitingReArmSettle(sentAt: Date)
        case done
    }
    private var popupPhase: PopupPhase = .waitingForTarget
    private static let popupReArmSettle: TimeInterval = 0.5

    /// One round's outcome (`WINDOW_SMOKE_POPUP_SAMPLES`). `latencyMs` is the round's own
    /// WindowCreate→first-content measurement, and is `nil` when the popup never presented
    /// content before Escape closed it -- recorded as a FAILED sample rather than as a
    /// fabricated number, which is also why `ok` requires it: a round that opened and closed
    /// a popup that never painted has not demonstrated the ≤100ms first-content budget
    /// docs/plans/phase2.md §4 W4 gates on, so counting it as a success while quietly leaving
    /// it out of the latency set would make `ok == N` and the p95 gate measure two different
    /// populations.
    private struct PopupRoundResult {
        let appeared: Bool
        let attached: Bool
        let closed: Bool
        let latencyMs: Double?
        var ok: Bool { appeared && attached && closed && latencyMs != nil }
    }
    private var popupRoundResults: [PopupRoundResult] = []
    /// One re-activate retry per round, permitted only when the round's create-poll times out
    /// (multi-round mode only -- at the default N==1 a create-poll timeout still fails
    /// immediately and funnels straight to cleanup, exactly as it always has).
    private var popupCreateRetried = false
    private static let popupCreatePollTimeout: TimeInterval = 5.0
    private static let popupEscapeClosePollTimeout: TimeInterval = 3.0
    private static let popupAboutClosePollTimeout: TimeInterval = 5.0
    /// The About window's own windowId -- this scenario's Alt+Space target and the expected
    /// `ownerWindowId` on the popup that (should) appear in response.
    private var popupOwnerWindowId: UInt32?
    /// windowIds already present the instant before Alt+Space was sent -- mirrors
    /// `windowIdsBeforeExtraApps`' own "only count what appeared AFTER" discipline (2026-08-22
    /// review HIGH), applied here to distinguish the popup this scenario itself opened from
    /// any unrelated window that happened to already exist.
    private var popupWindowIdsBeforeKeystroke: Set<UInt32> = []
    /// Populated once the popup is actually located (owner match among the newly-appeared
    /// windowIds) -- `nil` means "not found yet" throughout `.awaitingPopupCreate`.
    private var popupWindowId: UInt32?
    /// `WindowCreate`'s own elapsed-seconds timestamp for `popupWindowId`, read from
    /// `windowCreateTimestamps` (populated unconditionally in `drainNow()`, not just for
    /// this scenario) the moment the popup is located.
    private var popupCreatedAt: TimeInterval?
    /// Set once `popupWindowId`'s own snapshot first reports `hasDisplayedContent == true`
    /// -- `[popup] WindowCreate→first-content` latency is `popupFirstContentAt -
    /// popupCreatedAt`, informational this run (plan §4 W4's ≤100ms p95 gate needs real n>1
    /// data before it can be enforced, per adr/0010 §5's own acceptance text).
    private var popupFirstContentAt: TimeInterval?
    /// Whether `popupWindowId`, once located, actually carried a nonzero `ownerWindowId`
    /// AND was observed attached as a child of `popupOwnerWindowId` (adr/0010 §4) --
    /// via `RemoteWindowRegistry.attachedOwner(forWindowId:)`, checked once at the moment
    /// the popup is located (attachment is applied synchronously inside the same
    /// `handleWindowOrder` call that creates the window, per `updateParentChild`'s own
    /// call site, so there's no separate settle window needed for this check).
    private var popupAttachedAsChild: Bool?
    /// `true`/`false` once resolved; `nil` means "the 5s poll never located a new,
    /// owner-attached window at all."
    private var popupAppeared: Bool?
    private var popupEscapeSent = false
    private var popupClosedAt: TimeInterval?
    /// Team-lead review: the About-window cleanup leg's own close bookkeeping, same
    /// bookkeeping shape as `maximizeCloseTargetId`/`moveResizeCloseTargetId`.
    private var popupAboutCloseTargetId: UInt32?
    private var popupAboutClosedAt: TimeInterval?
    private var popupAboutCloseResult: Bool?

    // adr/0014 §6 (WINDOW_SMOKE_TRAY_CLICK): one tray left click, driven through the real
    // click path, asserted against what actually left this process -- see
    // `runTrayClickScenario`'s own doc comment for the sequence.

    /// One notify icon's wire identity, exactly as `TrayStatusController` keys its own status
    /// items. Tracked here (create/update insert, delete remove -- from the harness's own
    /// drain loop, not read out of the registry) so this scenario can name a LIVE key to
    /// click: the registry deliberately exposes counts, not the key set, and duplicating the
    /// lifecycle from the same events it consumes keeps that boundary intact.
    private struct NotifyIconKey: Hashable {
        let windowId: UInt32
        let notifyIconId: UInt32
    }
    /// Insertion-ordered, so "pick one live key" is deterministic across runs rather than
    /// dependent on `Set` iteration order -- a flaky choice of target would make a failure
    /// report ambiguous about which icon it referred to.
    private var liveNotifyIconKeys: [NotifyIconKey] = []
    /// Last WIRE tooltip observed per live key (`CRDPEvent.toolTip`, present only when the
    /// order carried the string bit) -- consulted by the tray-click scenario's optional
    /// `WINDOW_SMOKE_TRAY_CLICK_TOOLTIP` target filter. Without a filter the scenario clicks
    /// the FIRST live key, which in a real session is one of the session's own standing tray
    /// icons (Explorer's battery/network/etc. appear within ~2s, long before a lab driver's
    /// PowerShell has even finished loading WinForms) -- fine for send-path gates, useless
    /// for a remote loop-back where the marker-writing driver's OWN icon must be the target.
    private var notifyIconTooltips: [NotifyIconKey: String] = [:]
    private var trayClickTarget: NotifyIconKey?
    private var trayClickDone = false
    /// Every `(windowId, notifyIconId, message)` triple `RemoteWindowRegistry` reported having
    /// posted, in post order -- collected via `onTrayNotifyEventSent` from the one place a PDU
    /// is actually sent, deliberately NOT re-derived from `TrayNotifyEvent` on this side (that
    /// would assert the harness's own copy of the sequence against itself).
    private var trayNotifyEventsSent: [(windowId: UInt32, notifyIconId: UInt32, message: UInt32)] = []
    /// `CRSession.outboundDroppedNoRailCount` read immediately before the click. A nonzero
    /// delta at `finish()` means the outbound lane threw the click's own PDUs away because
    /// RAIL wasn't connected -- the one failure mode a post-side counter alone cannot see.
    private var outboundDroppedNoRailBeforeClick: UInt64?
    /// `CRSession.outboundPostDroppedCount` read at the same instant -- the queue's OWN
    /// post-side rejection counter (capacity ceiling, allocation failure; seal rejections are
    /// invisible to BOTH outbound counters by crdpq contract). The mirror image of the field
    /// above: that one proves the PDUs weren't discarded on the way out of the queue, this
    /// one proves they weren't rejected on the way in for either countable cause. Asserting
    /// only the first would let "the click posted nothing at all" pass green.
    private var outboundPostDroppedBeforeClick: UInt64?

    // W4b review round 2, experiment 1: does sending RAIL ClientActivate for a
    // background/non-focused window prompt the server to (re)send content it never
    // painted for us? Resolved opportunistically to whichever plausible-title window is
    // observed FIRST -- deliberately checked on every tick starting immediately after
    // connect, since an already-open (stale) window's existence syncs to a freshly
    // connecting client during the initial RAIL/RDPGFX handshake, well before this run's
    // own `exec` of `launchedProgram` could possibly round-trip and produce a NEW window
    // with a similar title -- "first observed, locked forever" is what keeps this
    // targeting the pre-existing stale window rather than a fresh one this run itself
    // launches. Matches either winver's "About Windows" or Registry Editor by title, since
    // which one is actually stale in the session varies by what prior runs left behind.
    private var activateExperimentWindowId: UInt32?
    private var activatePreRatio: Double?
    private var activatePostRatio: Double?
    private var didSendActivate = false

    init(host: String, user: String, pass: String, screenshotPath: String, launchedProgram: String,
         launchedAppKind: LaunchedAppKind, inputTestMode: InputTestMode?)
    {
        self.host = host
        self.user = user
        self.pass = pass
        self.screenshotPath = screenshotPath
        self.launchedProgram = launchedProgram
        self.launchedAppKind = launchedAppKind
        self.inputTestMode = inputTestMode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CRSession.logFreeRDPVersion()
        print("[config] launching program=\(launchedProgram) (kind=\(launchedAppKind))")

        // adr/0011 §5 item 5: fail LOUDLY and immediately, not silently or halfway through --
        // the seed is what every downstream artifact of the live battery is defined against
        // (the `expected-utf8-hex` marker the external comparer parses, and the file content
        // the host is supposed to end up holding). A run that dispatched all six chords but
        // could not say what the result should be would produce an unfalsifiable "PASS" for
        // the one assertion this whole scenario exists for, so `finish()` gates on this flag
        // too rather than trusting the operator to have read this line.
        if cmdMapLiveActive, cmdMapSeed == nil {
            print("[cmdmap-live] FAILED: WINDOW_SMOKE_CMDMAP_SEED is required when WINDOW_SMOKE_CMDMAP_LIVE=1 "
                + "(it is the exact text the host-side file was seeded with -- without it this run cannot state "
                + "what the file should contain afterwards, so no chord is dispatched at all)")
        }
        if cmdMapLiveEnabled, inputTestMode != .cmdmap {
            print("[cmdmap-live] ignored: WINDOW_SMOKE_CMDMAP_LIVE=1 only upgrades WINDOW_SMOKE_INPUT_TEST=cmdmap "
                + "(current mode: \(inputTestMode.map { $0.rawValue } ?? "unset"))")
        }
        // adr/0011 §5 items 6/7 drive the SAME scripted-input state machine (one target lock,
        // one script, one settle) -- deliberately, since they are the two halves of the same
        // IME path -- so only one of them can own it per run. Whichever arms first wins; the
        // other's own `finish()` gates then fail loudly rather than reporting a half-run.
        if unicodeDegradeScenarioEnabled, inputTestMode != nil {
            print("[unicode-degrade] WARNING: WINDOW_SMOKE_UNICODE_DEGRADE=1 and WINDOW_SMOKE_INPUT_TEST="
                + "\(inputTestMode.map { $0.rawValue } ?? "?") both request the scripted-input state "
                + "machine -- run them as two separate invocations")
        }

        // User-reported "clicks don't work" review round: a window can only actually
        // *become* key while its owning application is the active/frontmost application --
        // canBecomeKey alone (RemoteWindow.swift's RemoteWindowBackingWindow fix) is
        // necessary but not sufficient. App/Macdows/AppDelegate.swift's own
        // applicationDidFinishLaunching already calls this; this harness, launched
        // headlessly from a Terminal-relayed background process, never did -- confirmed
        // the hard way, by this round's own new canBecomeKey/isKeyWindow assertion
        // failing with canBecomeKey=true but isKeyWindow-after-makeKey()=false until this
        // line was added. Without it, this harness's own synthetic-click e2e tests were
        // only ever proving NSWindow.sendEvent(_:)'s direct-dispatch path works (which
        // doesn't require true key-window status), never the real user-facing path a
        // genuine trackpad click goes through -- exactly the gap that let the real
        // canBecomeKey bug ship unnoticed in the first place.
        NSApp.activate(ignoringOtherApps: true)

        let newSession = CRSession(host: host, user: user, password: pass, program: launchedProgram)
        // adr/0011 §5 items 5/6 (WINDOW_SMOKE_APP_ARGS): RemoteApp launch arguments, so a run
        // can open a SPECIFIC seeded file (e.g. `notepad.exe C:\rdp-lab\cmdmap-seed.txt`) for
        // the input round-trip batteries instead of the argument-less winver every other
        // scenario uses. Set here, before `-start` below -- `programArguments` has the same
        // "read once by the connect path, unsynchronized afterwards" contract `desktopWidth`
        // does, so this is the only correct place for it. Printed (the path is a lab file
        // path, never a credential) so a run's log says what it actually launched.
        if let launchedProgramArguments {
            newSession.programArguments = launchedProgramArguments
            print("[config] programArguments=\(launchedProgramArguments)")
        }
        // adr/0011 §5 item 7 (WINDOW_SMOKE_UNICODE_DEGRADE): same before-`-start` contract.
        // Forces the negotiated Unicode capability to read unsupported, which is what makes
        // adr/0011 §2's degradation path constructible against an ordinary host at all (see
        // `forceUnicodeInputUnsupported`'s own doc comment in CRSession.h).
        if unicodeDegradeScenarioEnabled {
            newSession.forceUnicodeInputUnsupported = true
            print("[config] forceUnicodeInputUnsupported=YES (adr/0011 §5 item 7 degradation scenario)")
        }
        session = newSession
        // M1 L9 (adr/0015 §3 rules 1-4, §5.A.4): freeze this session's topology and hand the
        // derived desktop size to `CRSession` BEFORE the registry is built. Order is load-bearing
        // in both directions. `RemoteWindowRegistry.init` freezes its own snapshot from
        // `topologyProvider.currentTopology` (`RemoteWindowRegistry.swift:389`), and
        // `freezeSessionSnapshot()` is what refreshes that value -- so freezing first is what
        // makes the Y-flip anchor and the desktop size come from one `NSScreen` read rather than
        // two. Assigning the size first additionally arms the registry's own divergence check
        // (`RemoteWindowRegistry.swift:509-534`), which is skipped while `desktopWidth` is still 0.
        freezeAndApplyDesktopSize(to: newSession, reason: "connect")
        registry = RemoteWindowRegistry(session: newSession, topologyProvider: displayTopology)
        // TEMPORARY debug instrumentation (2026-08-23 Z-order reversal investigation) --
        // see RemoteWindowRegistry.zOrderTraceEnabled's own doc comment. Only for the
        // multi-window scenario (task requirement: "keep it cheap, only in the multiwin
        // scenario") -- off (zero cost) for every other run, including cycle mode.
        if !extraApps.isEmpty {
            registry.zOrderTraceEnabled = true
        }
        // Team-lead review round 4 (2026-08-23, W3): logs the VERBATIM rect
        // `handleLocalGeometrySettled` actually sent to `CRSession.sendWindowMove`,
        // independent of and prior to whatever the server later echoes back -- see
        // `RemoteWindowRegistry.onWindowMoveSent`'s own doc comment for why this exists
        // (to distinguish "we sent the wrong thing" from "the server/timing did something
        // unexpected" without re-deriving the outbound math a second time here). Scoped to
        // the move-resize scenario's own target so it stays silent for every other run.
        // `Date().timeIntervalSince(self?.startTime ?? Date())` mirrors the elapsed-seconds
        // clock every other timestamped line in this file already uses.
        registry.onWindowMoveSent = { [weak self] windowId, left, top, right, bottom in
            guard let self, moveResizeScenarioEnabled, windowId == self.moveResizeWindowId else { return }
            // adr/0015 §6.2: kept, not just printed, so each leg's verdict can state the deduction
            // the send path actually applied (this rect vs the one the leg asked for).
            self.lastClientWindowMoveSent = (left: left, top: top, right: right, bottom: bottom, at: Date())
            let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
            print(
                "[move-resize] sent ClientWindowMove at elapsed=\(String(format: "%.3f", elapsed))s "
                    + "windowId=\(windowId) left=\(left) top=\(top) right=\(right) bottom=\(bottom)"
            )
        }
        // adr/0014 §6: the VERBATIM triple each ClientNotifyEvent PDU carried, recorded from
        // the one place a PDU is actually posted -- same reasoning as `onWindowMoveSent`
        // directly above (a harness that recomputed the expected sequence on its own side
        // would be checking its own arithmetic, not the send path's). Scoped to the tray-click
        // scenario so every other run stays silent, exactly like the move-resize line.
        registry.onTrayNotifyEventSent = { [weak self] windowId, notifyIconId, message in
            guard let self, trayClickScenarioEnabled else { return }
            self.trayNotifyEventsSent.append((windowId: windowId, notifyIconId: notifyIconId, message: message))
            let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
            print(
                "[tray-click] sent ClientNotifyEvent at elapsed=\(String(format: "%.3f", elapsed))s "
                    + "windowId=\(windowId) notifyIconId=\(notifyIconId) message=0x\(String(message, radix: 16, uppercase: false))"
            )
        }
        startTime = Date()

        // W4c review: push-style draining, replacing what used to be this timer's main
        // job (root cause of a user-reported ~5 FPS lag -- see CRSession.h's
        // onEventsAvailable doc comment for the full "0.2s Timer -> ~100ms average wait ->
        // ~5 FPS" chain). Fires the moment new control-lane events (including FRAME_READY)
        // are actually posted, already hopped to the main queue and coalesced -- "one
        // burst, one dispatch" -- so drainNow() runs promptly instead of waiting out
        // whatever fraction of a fixed poll interval remained.
        // The remote desktop size used to be set HERE, from `NSScreen.screens.first.frame` --
        // the primary screen's height and width in mac POINTS, one screen only, read a second
        // time and independently of the flip anchor. M1 L9 replaced it with the frozen topology's
        // union in remote pixels (adr/0015 §3, U3 = P), assigned above at
        // `freezeAndApplyDesktopSize(to:reason:)`, before the registry exists. The server still
        // clamps remote windows to this desktop -- see `CRSession.desktopWidth`'s own doc for the
        // drag-wall/click-desync failure mode an undersized one produces.
        newSession.onEventsAvailable = { [weak self] in
            MainActor.assumeIsolated {
                self?.drainNow()
            }
        }
        newSession.start()

        if cyclesTotal > 1 {
            cycleIndex = 1
            cycleStartedAt = Date()
            // First cycle includes exec + first paint against a possibly cold session
            // (~5-10s observed); 25s leaves honest slack without letting a hang stall the
            // whole soak.
            cycleDeadline = Date().addingTimeInterval(25)
            print("[cycles] mode active: \(cyclesTotal) connect/disconnect cycles")
        }

        // M1 (W4b review): Timer's completion closure crosses an isolation boundary from
        // the compiler's static perspective even though it always actually fires on the
        // main run loop -- MainActor.assumeIsolated documents and asserts that fact
        // explicitly (crashing loudly if it's ever somehow wrong) instead of leaving a
        // Swift 6 strict-concurrency warning at this call site.
        //
        // W4c review: no longer responsible for draining (drainNow() above, via
        // onEventsAvailable, owns that now) -- this is purely total-run-duration control
        // (the elapsed >= 15/25 checks) and periodic re-evaluation of the
        // experiment/input-test timing gates, none of which are on the frame-latency
        // critical path.
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// W4c review: the actual drain call, invoked from `CRSession.onEventsAvailable`'s push
    /// notification -- see this property's own CRSession.h doc comment for why this
    /// replaces the old timer-driven poll. Also samples this run's own push-to-present
    /// latency: `pushObservedAt` is captured the moment this method starts running (i.e.
    /// once `dispatch_async(main, ...)` has actually scheduled it), and the sample is the
    /// time from there through `drainEvents`'s own synchronous `registry.handle` ->
    /// `handleFrameReady` -> `present(surface:via:)` chain finishing -- dispatch scheduling
    /// delay plus real processing cost, for any drain batch that carried at least one
    /// FRAME_READY. This is deliberately *not* true wire-level GFX-update-to-present
    /// latency (that would need a timestamp threaded through crdpq's own event struct,
    /// which this fix doesn't add) -- it is the "how long from this app being told a frame
    /// is ready to that frame actually being presented" number the poll-vs-push
    /// architecture change directly controls, and the fair, like-for-like point of
    /// comparison against the old timer's own ~100ms average wait.
    /// M1 L9's half of adr/0015 §5.A.4, and the whole of what `RemoteWindowRegistry.swift:500-508`
    /// calls "what the caller still owes".
    ///
    /// Takes this connection's topology snapshot and assigns the desktop size derived from THAT
    /// SAME read to `CRSession` (§3 rule 3's `desktopSizePx`, remote px). Called at exactly the
    /// two connect moments this harness has: once before the registry is constructed, and once
    /// per soak cycle immediately before `prepareForReconnect()` -- in that order, in the same
    /// main-actor turn. The registry cannot re-send a desktop size itself (that is renegotiation,
    /// W4's, and M1's MUST-NOT list forbids it), so a reconnect keeps the anchor and the desktop
    /// size from one read only because this runs first.
    ///
    /// `nil` return = no usable display, and then **nothing is assigned** (§5.A.6): `0 x 0` would
    /// make FreeRDP fall back to a 1024x768 desktop (`CRSession.h:285-286`), which is the original
    /// invisible-wall fault under a new name. On a reconnect that means the connection keeps the
    /// size the previous freeze gave it -- stale, and said so on the line below, rather than
    /// silently wrong.
    @discardableResult
    private func freezeAndApplyDesktopSize(to session: CRSession, reason: String) -> DesktopSizeInRemotePixels? {
        let desktop = displayTopology.freezeSessionSnapshot()
        sessionDesktopSizeInRemotePixels = desktop
        if let desktop {
            // `UInt32(clamping:)` cannot actually clamp -- `DisplayTopology` guarantees
            // `0 < value <= maxExtentInRemotePixels` -- and is written this way so that if that
            // guarantee is ever relaxed the connect path degrades instead of trapping. Same shape
            // as `AppDelegate.swift:264-265`, deliberately.
            session.desktopWidth = UInt32(clamping: desktop.width)
            session.desktopHeight = UInt32(clamping: desktop.height)
            print(
                "[topology] \(reason): desktop size frozen at \(desktop.width)x\(desktop.height) remote px "
                    + "(adr/0015 §3 rule 3, union of the local screens; anchor and size from one read, §5.A.4)"
            )
        } else {
            print(
                "[topology] \(reason): no usable display -- desktopWidth/Height deliberately NOT set "
                    + "(adr/0015 §5.A.6: 0x0 falls back to FreeRDP's 1024x768 desktop, CRSession.h:285-286). "
                    + "Any previously negotiated size is now stale."
            )
        }
        return desktop
    }

    /// The M1 measurement summaries — F2's `[gfx] target=` (`docs/plans/phase3.md:132`) and F1's
    /// `[f1] summary:` (`:130`) — printed once per RUN from every terminal path (`finish()` and
    /// `finishCycles()` both call THIS, not the individual lines). Never conditional: see
    /// `GfxTargetHintTally.summaryLine` for why an absent line is worse than a "none" line.
    ///
    /// One method rather than two calls per path on purpose (rev-L9 M-5 observed that these lines
    /// are call-site-printed rather than structurally enforced): a future third exit path has one
    /// thing to remember instead of N, and adding an M3 measurement later adds no new call sites.
    private func printMeasurementSummaries() {
        print(gfxTargetHints.summaryLine)
        print(f1Measurements.summaryLine)
    }

    /// F1 (`docs/plans/phase3.md:130`, M1 L9b) sampled at **present time**: called from
    /// `drainNow()` for any drain batch that carried a FRAME_READY, i.e. immediately after
    /// `registry.handle(event)` has synchronously run `handleFrameReady` -> `RemoteWindow.present`
    /// for that frame. That is the moment the window is showing the surface whose `mappedSize`
    /// this compares against, which is why the sample is taken here rather than on a timer.
    ///
    /// The pairing is done from the harness side because `RemoteWindow.present` is not this lane's
    /// file: `windowSnapshots()` supplies the tracked windows, `window(forWindowId:)` the live
    /// `NSWindow`, and `debugMappedSize(forWindowId:)` the GFX mapped size the registry itself
    /// uses for the crop. A window without both a presented frame and a mapped size is **skipped,
    /// not defaulted** -- an invented backing or mapped size would produce exactly the kind of
    /// unfalsifiable GREEN this measurement exists to prevent.
    ///
    /// `convertToBacking` is asked of the CONTENT view, not the window frame: RAIL geometry
    /// round-trips through the content rect once a window has native chrome
    /// (`RemoteWindow.updateFrame`'s own finding), so comparing the frame would be off by this
    /// window's titlebar insets and would report RED at 1x for a reason that has nothing to do
    /// with F1.
    private func sampleF1BackingVsMapped(registry: RemoteWindowRegistry) {
        for snapshot in registry.windowSnapshots() where snapshot.hasDisplayedContent {
            guard let window = registry.window(forWindowId: snapshot.windowId),
                  let contentView = window.contentView,
                  let mapped = registry.debugMappedSize(forWindowId: snapshot.windowId)
            else { continue }
            let contentSizeInPoints = contentView.bounds.size
            let backingSize = contentView.convertToBacking(contentSizeInPoints)
            let observation = F1BackingVsMapped.Observation(
                windowId: snapshot.windowId,
                backingWidthInBackingPixels: Double(backingSize.width),
                backingHeightInBackingPixels: Double(backingSize.height),
                contentWidthInPoints: Double(contentSizeInPoints.width),
                contentHeightInPoints: Double(contentSizeInPoints.height),
                mappedWidthInRemotePixels: Double(mapped.width),
                mappedHeightInRemotePixels: Double(mapped.height)
            )
            // Printed only when the numbers changed (or on the first sample for this window) --
            // a 60fps stream would otherwise bury every other line in the run's log.
            if let changed = f1Measurements.record(observation) {
                print(changed.line)
            }
        }
    }

    /// The ADR §5 reconnect re-take, pinned. `RemoteWindowRegistry.sessionTopologyFreezeCount`
    /// (`RemoteWindowRegistry.swift:462-477`) counts 1 for `init` plus one per
    /// `prepareForReconnect()`; the App target has no test bundle, so this harness is the only
    /// assertion surface that re-take has. `expectedReconnects` is the number of cycles that
    /// actually finished (0 for a single-run), not `WINDOW_SMOKE_CYCLES`, so an aborted soak
    /// still states an exact expectation rather than an approximate one.
    ///
    /// **PROVENANCE — this assertion is L7's handoff, not L9 inventing a gate.** L7 could not pin
    /// its own seam (no test bundle) and wrote the pin's exact form into the registry: "after an
    /// N-cycle `WINDOW_SMOKE_CYCLES` soak (one `prepareForReconnect()` per finished cycle),
    /// `sessionTopologyFreezeCount == N + 1`. A value of 1 means the re-take never fired … Handed
    /// to L9 in `task-L7-report.md` as a wave-3 harness item" (`RemoteWindowRegistry.swift:462-477`),
    /// and the caller's own obligation that this pin guards is stated at
    /// **`RemoteWindowRegistry.swift:500-508` (the `:503` L9 contract)**: freeze and re-assign the
    /// desktop size in the same turn, before `prepareForReconnect()`. This is the observable half
    /// of that contract. It is a NEW gating assertion for live runs (rev-L9 M-2, adjudicated
    /// ACCEPTED by the controller): a soak whose re-take is broken now goes red where before it
    /// went green, which is the point.
    private func topologyFreezeCountCheck(expectedReconnects: Int) -> (passed: Bool, message: String) {
        let expected = expectedReconnects + 1
        let actual = registry.sessionTopologyFreezeCount
        return (
            actual == expected,
            "adr/0015 §5 reconnect re-take: sessionTopologyFreezeCount == \(expected) "
                + "(1 connect + \(expectedReconnects) prepareForReconnect(); got \(actual)). "
                + "A count of 1 after a soak means the re-take never fired"
        )
    }

    private func drainNow() {
        guard let session, let registry, startTime != nil else { return }
        let pushObservedAt = Date()
        var sawFrameReady = false

        _ = session.drainEvents { [weak self] event in
            guard let self else { return }
            registry.handle(event)
            if event.kind == .frameReady {
                self.frameReadyCount += 1
                sawFrameReady = true
            }
            // F2 (`docs/plans/phase3.md:132`, adr/0015 §8): record what the GFX map order said its
            // TARGET size was. `CRDPEventKindSurfaceMapped` covers both PDU variants, and the
            // plain one reports `(0, 0)` -- the sentinel, handled inside the tally, never treated
            // as a 0x0 observation. MEASUREMENT ONLY: nothing downstream may branch on this in M1
            // (`CRSession.h:230-233`), and nothing here does -- it feeds one summary line.
            if event.kind == .surfaceMapped {
                self.gfxTargetHints.record(
                    targetWidthInRemotePixels: event.targetWidth,
                    targetHeightInRemotePixels: event.targetHeight
                )
            }
            // W4c deliverable 5: registry.handle(event) above already removed this
            // windowId from its own tracking for a windowDelete -- this just separately
            // records the fact and the timing for the input-test assertion in finish().
            if event.kind == .windowDelete, let target = self.inputTestWindowId, event.windowId == target,
               !self.inputTestWindowDeleted
            {
                self.inputTestWindowDeleted = true
                self.inputTestWindowDeletedAt = Date().timeIntervalSince(self.startTime)
            }
            // Phase 2 W2 task item 5c: same bookkeeping shape as the input-test case just
            // above, for the maximize scenario's own close leg.
            if event.kind == .windowDelete, let target = self.maximizeCloseTargetId, event.windowId == target,
               self.maximizeCloseWindowDeletedAt == nil
            {
                self.maximizeCloseWindowDeletedAt = Date().timeIntervalSince(self.startTime)
            }
            // Fix 2 (team-lead review, 2026-08-23 real-host run): same bookkeeping shape as
            // the two cases just above, for the move-resize scenario's own close leg.
            if event.kind == .windowDelete, let target = self.moveResizeCloseTargetId, event.windowId == target,
               self.moveResizeCloseWindowDeletedAt == nil
            {
                self.moveResizeCloseWindowDeletedAt = Date().timeIntervalSince(self.startTime)
            }
            // adr/0010 §5: same bookkeeping shape as the two cases just above, for the
            // popup scenario's own Escape-close leg.
            if event.kind == .windowDelete, let target = self.popupWindowId, event.windowId == target,
               self.popupClosedAt == nil
            {
                self.popupClosedAt = Date().timeIntervalSince(self.startTime)
            }
            // Team-lead review: same bookkeeping shape, for the popup scenario's own
            // About-window cleanup leg.
            if event.kind == .windowDelete, let target = self.popupAboutCloseTargetId, event.windowId == target,
               self.popupAboutClosedAt == nil
            {
                self.popupAboutClosedAt = Date().timeIntervalSince(self.startTime)
            }
            // Phase 2 W3 (docs/plans/phase2.md §2 W3): records this window's real CONTENT
            // rect -- post `registry.handle(event)` above, so this reflects whatever
            // `RemoteWindow.updateFrame` actually did, including a no-op if geometry
            // suppression was active -- every time a geometry-carrying WindowCreate/
            // WindowUpdate arrives for the move/resize scenario's own target. Team-lead
            // review (2026-08-23 real-host run): reads `window.contentRect(forFrameRect:
            // window.frame)`, NOT the raw frame -- RAIL geometry round-trips through the
            // CONTENT rect once this window has native chrome (`RemoteWindow.updateFrame`'s
            // own doc comment has the full finding); comparing raw frames here would be off
            // by this window's chrome insets, exactly the bug this fix corrects.
            // `evaluateMoveResizeLeg` reads this sequence for both the round-trip match and
            // the no-oscillation check. Field-flag bits (SIZE=0x0400, OFFSET=0x0800)
            // duplicated here per this file's own established per-layer-cites-source
            // precedent (see the `SC` enum's own doc comment above for the same
            // convention) -- canonical source is MacdowsCore's WindowModel.swift, verified
            // there against freerdp/window.h.
            if moveResizeScenarioEnabled, let target = self.moveResizeWindowId, event.windowId == target,
               event.kind == .windowUpdate || event.kind == .windowCreate,
               event.fieldFlags & 0x0C00 != 0,
               let window = registry.window(forWindowId: target)
            {
                // Team-lead review (2026-08-23, W3 round 2): the RAW wire values this run's
                // round-trip mismatch (x+7 y-53 w-14 h-7) was diagnosed from second-hand, via
                // already-converted mac content rects -- this line exists to let the NEXT run
                // confirm (or refute) `RemoteWindowRegistry.sizeCorrection(for:windowId:)`'s
                // own measured value directly against the actual RAIL offsetX/offsetY/
                // windowWidth/windowHeight and the GFX mapped (visible) size it's derived
                // from, not re-derived arithmetic. Printed for EVERY geometry-carrying order
                // on the target window, not just the ones this scenario's own legs care
                // about, so a server-initiated echo outside the expected sequence is visible
                // too. `impliedSizeCorrection` is signed `mapped - RAIL` (matching
                // `MacdowsCore.WindowGeometryCorrection`'s own sign convention exactly, per
                // the W3 round 3 team-lead review that found round 2's fallback had the sign
                // backwards) -- POSITIVE means the displayed content is LARGER than what RAIL
                // itself reports. Team-lead review round 4: `elapsed` added so this line and
                // the new `onWindowMoveSent`-driven "sent ClientWindowMove" line above share
                // the same clock -- reading both lines in timestamp order on the next run is
                // what actually answers whether a given echo predates or postdates our own
                // send (a stale/out-of-sequence WindowUpdate vs a genuine confirmation).
                //
                // Team-lead review round 5 (2026-08-23): `impliedSizeCorrection` used to be
                // computed from THIS event's own raw `windowWidth`/`windowHeight` fields --
                // garbage on any order that didn't carry `WINDOW_ORDER_FIELD_WND_SIZE`
                // (0x0400) at all (a position-only or style-only update correctly reports
                // these as 0, which the old line then diffed against `mapped` as if it were
                // a real, tiny RAIL size). Now reads
                // `registry.debugAccumulatedRailSize(forWindowId:)` -- the SAME
                // delta-merged, accumulated state `RemoteWindowRegistry.sizeCorrection(for:
                // windowId:)` itself actually uses -- so this line can never diverge from
                // what the real correction logic saw. `accumulated` is printed alongside the
                // raw per-event `windowWidth`/`windowHeight` specifically so a reader can see
                // both at once: whether THIS event carried a size at all (raw, possibly 0)
                // vs. what the registry's own running state currently believes (accumulated,
                // what `impliedSizeCorrection` is actually computed from).
                let mapped = registry.debugMappedSize(forWindowId: target)
                let accumulated = registry.debugAccumulatedRailSize(forWindowId: target)
                let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
                let impliedSizeCorrection: String
                if let mapped, let accumulated {
                    impliedSizeCorrection = "(\(Int(mapped.width) - Int(accumulated.width)),\(Int(mapped.height) - Int(accumulated.height)))"
                } else {
                    impliedSizeCorrection = "n/a"
                }
                print(
                    "[move-resize] raw RAIL geometry at elapsed=\(String(format: "%.3f", elapsed))s "
                        + "for windowId=\(target) kind=\(event.kind): "
                        + "offsetX=\(event.offsetX) offsetY=\(event.offsetY) windowWidth=\(event.windowWidth) "
                        + "windowHeight=\(event.windowHeight) fieldFlags=0x\(String(event.fieldFlags, radix: 16)) "
                        + "accumulatedRAILSize=\(accumulated.map { "\($0.width)x\($0.height)" } ?? "unknown") "
                        + "GFX-mapped(visible)Size=\(mapped.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown") "
                        + "impliedSizeCorrection(mapped-accumulatedRAIL,w,h)=\(impliedSizeCorrection)"
                )
                let contentRect = window.contentRect(forFrameRect: window.frame)
                self.moveResizeObservedContentRects.append((contentRect: contentRect, at: Date().timeIntervalSince(self.startTime), source: "update"))
            }
            // F0-2 (2026-09-02): the surface remap's frame re-apply is the SECOND state the local
            // window reaches after a resize (RAIL update first, remap a beat later), and it is
            // the one whose size the registry treats as canonical. Sample it too, post
            // `registry.handle(event)`, for the locked target while a leg awaits settle.
            if moveResizeScenarioEnabled, event.kind == .surfaceMapped,
               MoveResizeGate.remapObservationApplies(
                   eventWindowId: UInt32(truncatingIfNeeded: event.mappedWindowId), targetWindowId: self.moveResizeWindowId,
                   legAwaitingSettle: self.moveResizeLegAwaitingSettle
               ),
               let target = self.moveResizeWindowId, let window = registry.window(forWindowId: target)
            {
                let contentRect = window.contentRect(forFrameRect: window.frame)
                let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
                print("[move-resize] surface remap at elapsed=\(String(format: "%.3f", elapsed))s for windowId=\(target): "
                    + "mapped=\(event.mappedWidth)x\(event.mappedHeight) -> content rect now \(contentRect) (observation source=remap)")
                self.moveResizeObservedContentRects.append((contentRect: contentRect, at: elapsed, source: "remap"))
            }
            // Team-lead review (2026-08-23, maximize-scenario real-host regression
            // investigation): reuses the move-resize scenario's own raw-RAIL-geometry trace
            // shape, ADDITIONALLY printing this window's live geometry-suppression counter
            // (`RemoteWindow.debugGeometrySuppressionCount`) so a single run can show,
            // directly, whether the maximize's own big WindowUpdate (a) never arrived at
            // all (server-side investigation), or (b) arrived but was silently dropped
            // because `geometryAuthoritySuppressionCount` was nonzero at that exact moment
            // (client bug -- leading hypothesis: `ServerLocalMoveSize` firing around a
            // server-initiated SC_MAXIMIZE, genuinely untested wire behavior per adr/0008
            // §0's own caveat). `ServerLocalMoveSize` itself is also traced explicitly here
            // via `print` -- `RemoteWindowRegistry.handleLocalMoveSize` already logs it, but
            // via `Self.logger.debug` (os.Logger), which does NOT appear in this harness's
            // own stdout-captured log the way every `[maximize]`/`[move-resize]` line does.
            if maximizeScenarioEnabled, let target = self.maximizeTargetWindowId, event.windowId == target {
                let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
                if event.kind == .windowUpdate || event.kind == .windowCreate, event.fieldFlags & 0x0C00 != 0 {
                    let suppression = registry.debugGeometrySuppressionCount(forWindowId: target)
                    print(
                        "[maximize] raw RAIL geometry at elapsed=\(String(format: "%.3f", elapsed))s "
                            + "for windowId=\(target) kind=\(event.kind): offsetX=\(event.offsetX) "
                            + "offsetY=\(event.offsetY) windowWidth=\(event.windowWidth) "
                            + "windowHeight=\(event.windowHeight) show=\(event.show) "
                            + "fieldFlags=0x\(String(event.fieldFlags, radix: 16)) "
                            + "suppressionCount=\(suppression.map(String.init) ?? "no RemoteWindow")"
                    )
                }
                if event.kind == .localMoveSize {
                    let suppression = registry.debugGeometrySuppressionCount(forWindowId: target)
                    print(
                        "[maximize] ServerLocalMoveSize at elapsed=\(String(format: "%.3f", elapsed))s "
                            + "for windowId=\(target): isMoveSizeStart=\(event.isMoveSizeStart) "
                            + "moveSizeType=\(event.moveSizeType) posX=\(event.moveSizePosX) "
                            + "posY=\(event.moveSizePosY) suppressionCountAfter=\(suppression.map(String.init) ?? "no RemoteWindow")"
                    )
                }
            }
            // Multi-window scenario bookkeeping (2026-08-22 review HIGH): a failed
            // ClientExecute (e.g. RAIL_EXEC_E_FILE_NOT_FOUND) must not hide behind
            // leftover windows from an earlier session satisfying the count -- record
            // every failure so finish() can gate on none having occurred.
            if event.kind == .execResult, event.execResult != 0 {
                self.failedExecResults.append("\(event.program) -> \(event.execResult)")
            }
            // Phase 2 W2 task item 2 (docs/plans/phase2.md §2 W2, adr/0008 §3): ground
            // truth for the ghost-sliver rule's one unverified leg (ownerWindowId --
            // WindowMappability.isGhostSliverHelper's own doc comment explains why the six
            // phase05 samples never captured it). One line per WindowCreate, multiwin
            // scenario only (WINDOW_SMOKE_EXTRA_APPS) -- exactly the scenario that produces
            // the four real 136x39 blank-sliver windows this rule targets.
            //
            // adr/0010 W4 real-host correction: EXPLICITLY also fires for the popup
            // scenario (`|| popupScenarioEnabled`) -- this line is exactly what surfaced
            // the WindowMappability owner-gating bug in the first place (windowId 4523408,
            // style=0x80000000, owner=2622898), and until now it only fired there because
            // WINDOW_SMOKE_POPUP's own "multiwin prereq" happened to make `extraApps`
            // non-empty too, not because this condition said so on its own -- a future
            // change to that prereq could silently go dark here. Kept as an explicit `||`
            // rather than relying on the coincidence, so a future WindowCreate/owner miss
            // during the popup wait window stays self-diagnosing regardless of whether the
            // multiwin prereq still holds.
            if event.kind == .windowCreate, !extraApps.isEmpty || popupScenarioEnabled {
                print(Self.styleDumpLine(for: event))
            }
            // adr/0010 §5: unconditional WindowCreate timestamp bookkeeping (see
            // windowCreateTimestamps' own doc comment) -- every run, not just
            // WINDOW_SMOKE_POPUP.
            if event.kind == .windowCreate {
                self.windowCreateTimestamps[event.windowId] = Date().timeIntervalSince(self.startTime)
            }
            // adr/0010 §2/§4: per-MASKED-window shape diagnostic -- rect count + truncated
            // flag, read post `registry.handle(event)` (already applied above) so this
            // reflects whatever PendingWindowState/RemoteWindow actually settled on for this
            // order. Scoped to the popup scenario (the one path this pass actually exercises
            // real visibilityRects/mask data against) so every other run stays silent, and
            // further scoped to windows that actually carry wire OR applied rect data --
            // "per masked window," not every window regardless of whether it has any
            // visibility-rect data at all.
            if popupScenarioEnabled, event.kind == .windowCreate || event.kind == .windowUpdate,
               let diag = registry.shapeDiagnostics(forWindowId: event.windowId),
               diag.wireRectCount > 0 || diag.appliedRectCount > 0
            {
                print("[shape] windowId=\(event.windowId) wireRectCount=\(diag.wireRectCount) truncated=\(diag.truncated) appliedRectCount=\(diag.appliedRectCount)")
            }
            // adr/0014 §6: notify-icon lifecycle tracking for the tray-click scenario's
            // "pick one LIVE key" step. Mirrors `TrayStatusController`'s own create/update/
            // delete bookkeeping (update inserts too -- an update-before-create ordering is
            // tolerated there, see `TrayModel.update`'s doc comment, so assuming create-first
            // here could leave this list empty for an icon that really exists). Scoped to the
            // scenario so every other run pays nothing.
            if trayClickScenarioEnabled {
                let key = NotifyIconKey(windowId: event.windowId, notifyIconId: event.notifyIconId)
                switch event.kind {
                case .notifyIconCreate, .notifyIconUpdate:
                    if !self.liveNotifyIconKeys.contains(key) {
                        self.liveNotifyIconKeys.append(key)
                    }
                    // Wire truth only: absence means "this order didn't carry the bit",
                    // never "the tooltip was cleared" -- same delta semantics TrayModel
                    // documents. An explicit empty string IS a clear, and is recorded.
                    if let tip = event.toolTip {
                        self.notifyIconTooltips[key] = tip
                    }
                case .notifyIconDelete:
                    self.liveNotifyIconKeys.removeAll { $0 == key }
                    self.notifyIconTooltips.removeValue(forKey: key)
                default:
                    break
                }
            }
            // Flow evidence counters (task item 1): counted for every drained event
            // regardless of mode (plain run, extra-apps, cycles) -- only finish()'s
            // gating assertions and the `[flow]` summary print are scoped to the
            // standard (non-cycle) run.
            switch event.kind {
            case .monitoredDesktop:
                self.monitoredDesktopEventCount += 1
                // registry.handle(event) above already applied this order, so
                // serverDesktopState() reflects it -- reads the classified value through
                // the existing accessor rather than re-deriving the two sentinel checks
                // here (adr/0012 §3).
                let currentActive = registry.serverDesktopState().activeWindow
                if currentActive != self.flowLastActiveWindow {
                    print("[flow] activeWindow: \(Self.describe(self.flowLastActiveWindow)) -> \(Self.describe(currentActive))")
                    self.activeWindowIdTransitionCount += 1
                    self.flowLastActiveWindow = currentActive
                }
                // adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE): cheap to track
                // unconditionally (harmless when closeProbeEnabled is false or outside
                // cycle mode, since cycleCloseTargetId then never gets set at all) --
                // records that the server's own truth actually matched this close-leg's
                // target at least once since it was locked.
                if let targetId = self.cycleCloseTargetId, case .window(let active) = currentActive,
                   active == targetId
                {
                    self.cycleTargetEverConverged = true
                }
            case .zOrderSync:
                self.zOrderSyncEventCount += 1
            case .minMaxInfo:
                self.minMaxInfoEventCount += 1
            case .localMoveSize:
                self.localMoveSizeEventCount += 1
            default:
                break
            }
        }

        if sawFrameReady {
            frameLatencySamplesMs.append(Date().timeIntervalSince(pushObservedAt) * 1000)
            // F1 (`docs/plans/phase3.md:130`, M1 L9b): this batch presented at least one frame, so
            // every tracked window that has content is now showing a surface whose `mappedSize`
            // the registry knows -- present time, and the only moment the pairing is meaningful.
            // Sampled AFTER the latency sample so it can never distort that measurement.
            sampleF1BackingVsMapped(registry: registry)
        }

        // Focus rotation convergence poll (task item 2/3): checked once per drain batch
        // ("poll every drain"), reusing this push-driven cadence rather than a separate
        // timer, matching how frame delivery is already sampled above. adr/0012 §4.2: two
        // tiers, not one -- `softHit` (converged at/before the 500ms mark) is what W1's own
        // >=99% exit criterion will gate on once this harness has produced real n>=100
        // numbers; `eventualHit` (converged at all within the outer 5000ms window, matching
        // `FocusAuthority.hardDeadlineInterval`) is the "did convergence eventually happen"
        // observation tier adr/0012 §0's own real-capture data showed never actually fails
        // in steady state ("收敛从未彻底失败，只是有时很慢").
        if let targetId = focusRotationPendingTargetId, let sentAt = focusRotationPendingSentAt,
           let softDeadline = focusRotationPendingSoftDeadline,
           let eventualDeadline = focusRotationPendingEventualDeadline
        {
            let currentActive = registry.serverDesktopState().activeWindow
            if case .window(let active) = currentActive, active == targetId {
                let now = Date()
                let latencyMs = now.timeIntervalSince(sentAt) * 1000
                focusRotationResults.append(FocusRotationResult(
                    targetId: targetId, softHit: now <= softDeadline, eventualHit: true,
                    latencyMs: latencyMs, observedActiveWindow: currentActive))
                resolveFocusRotationPending()
            } else if Date() >= eventualDeadline {
                focusRotationResults.append(FocusRotationResult(
                    targetId: targetId, softHit: false, eventualHit: false, latencyMs: nil,
                    observedActiveWindow: currentActive))
                resolveFocusRotationPending()
            }
        }
    }

    /// Clears the in-flight rotation and arms the 300ms inter-rotation settle
    /// (`focusRotationNextAllowedAt`) -- shared by both the hit and timeout-miss paths in
    /// `drainNow()` above so neither can forget to arm it.
    private func resolveFocusRotationPending() {
        focusRotationPendingTargetId = nil
        focusRotationPendingSentAt = nil
        focusRotationPendingSoftDeadline = nil
        focusRotationPendingEventualDeadline = nil
        focusRotationNextAllowedAt = Date().addingTimeInterval(0.3)
    }

    private func tick() {
        guard let session, let registry, let startTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)

        if cyclesTotal > 1 {
            tickCycles(session: session, registry: registry)
            return
        }

        let tickSnapshots = registry.windowSnapshots()
        checkFirstFrameGate(tickSnapshots)
        if extraAppsLaunched {
            for snap in tickSnapshots
            where snap.isVisible && snap.hasDisplayedContent && isInPlausibleContentBand(snap)
                && !windowIdsBeforeExtraApps.contains(snap.windowId)
            {
                contentWindowsSeenAfterExtraApps[snap.windowId] = snap.title
            }
        }
        runActivateExperiment(elapsed: elapsed, session: session, registry: registry)
        runInputTest(elapsed: elapsed, registry: registry)
        // adr/0011 §5 items 5/6/7: the degradation scenario locks its own target (it is not
        // an InputTestMode); the script driver then dispatches whichever battery got armed --
        // by `runInputTest` above (cmdmap-live/ime) or by the degradation scenario -- one
        // step per tick, gated on each step's own gap.
        runUnicodeDegradeScenario(elapsed: elapsed, registry: registry)
        runInputScript(registry: registry)
        runFocusRotation(elapsed: elapsed, session: session, registry: registry)
        runMaximizeScenario(session: session, registry: registry)
        runMoveResizeScenario(session: session, registry: registry)
        runPopupScenario(session: session, registry: registry)
        runTrayClickScenario(session: session, registry: registry)

        // Phase 1 acceptance: launch the extra apps once the first app's own window has
        // had time to settle -- several ClientExecutes on one live connection is exactly
        // Phase 0.5's S3 scenario, now through the production outbound lane.
        if elapsed >= 6, !extraAppsLaunched, !extraApps.isEmpty {
            extraAppsLaunched = true
            windowIdsBeforeExtraApps = Set(registry.windowSnapshots().map(\.windowId))
            for program in extraApps {
                session.executeProgram(program)
                print("[extra-apps] ClientExecute sent: \(program)")
            }
        }

        if elapsed >= 15, !evidenceRoutineRan {
            evidenceRoutineRan = true
            captureEvidence()
        }

        // Focus rotation (task item 2/3) can need more than the standard 25s budget. The
        // theoretical worst case per rotation is now the eventual (5000ms,
        // FocusAuthority.hardDeadlineInterval) convergence-poll cap plus the 300ms
        // inter-rotation settle (adr/0012 §4.2's two-tier reporting), but the 1.0s/rotation
        // average this budgets stays realistic in practice: adr/0012 §0's own real-capture
        // data (p50=38ms, p95=329ms, max=3754ms across 30 rotations) means only a rare tail
        // ever approaches the eventual cap, not every rotation -- "the deadline scaling
        // exists" already covers n up to 100+ on that basis. `rotationStalled` is a hard
        // failsafe only -- normally `focusRotationDone` is what actually gates the extra
        // wait, not this later fallback deadline; a run that genuinely can't keep up fails
        // the "ran all N rotations" assertion in `finish()` rather than hanging forever.
        let baseDeadline: TimeInterval = 25
        let rotationDeadline = focusRotationTotal > 0
            ? max(baseDeadline, 10 + Double(focusRotationTotal) * 1.0)
            : baseDeadline
        let rotationStalled = focusRotationTotal > 0 && !focusRotationDone && elapsed >= rotationDeadline + 10
        // Phase 2 W2 task item 5b/5c: worst case is extraAppsLaunched (>=6s) + settle for
        // the About target + three back-to-back 5s SC_* polls (maximize/restore/close) --
        // 45s leaves comfortable slack. `maximizeStalled` is the same kind of hard failsafe
        // `rotationStalled` already is: normally `maximizePhase == .done` is what actually
        // gates the extra wait, not this fallback.
        let maximizeDeadline: TimeInterval = maximizeScenarioEnabled ? 45 : baseDeadline
        let maximizeStalled = maximizeScenarioEnabled && maximizePhase != .done && elapsed >= maximizeDeadline + 10
        // Phase 2 W3: worst case is extraAppsLaunched (>=6s) + settle for the About target +
        // two back-to-back (move, resize) legs, each up to the 3s round-trip budget plus the
        // 200ms local settle debounce, + the close leg's own 5s WindowDelete wait (Fix 2) --
        // 40s leaves comfortable slack, same "gated by the phase reaching .done, this is
        // only the hard failsafe" shape `maximizeStalled` already establishes.
        let moveResizeDeadline: TimeInterval = moveResizeScenarioEnabled ? 40 : baseDeadline
        let moveResizeStalled = moveResizeScenarioEnabled && moveResizePhase != .done && elapsed >= moveResizeDeadline + 10
        // adr/0010 W4 first slice: worst case is extraAppsLaunched (>=6s) + settle for the
        // About target + 0.3s activate settle + the popup-appear poll (5s) + a 0.3s
        // first-content-latency settle + the Escape-close poll (3s) + team-lead review's
        // About-window cleanup leg (defensive Escape + SC_CLOSE + up to 5s WindowDelete
        // poll) -- worst case ~19.6s, 30s leaves comfortable slack, same "gated by the phase
        // reaching .done, this is only the hard failsafe" shape
        // `maximizeStalled`/`moveResizeStalled` already establish.
        //
        // `WINDOW_SMOKE_POPUP_SAMPLES` > 1 adds N-1 further rounds, each one a re-arm settle
        // (0.5s) + Alt+Space + up to the 5s create poll + the 0.3s escape settle + up to the
        // 3s escape-close poll, i.e. under 9s worst case -- 10s per extra round keeps the
        // same comfortable-slack convention the 30s base already uses. N==1 leaves this at
        // exactly 30, unchanged.
        let popupDeadline: TimeInterval = popupScenarioEnabled
            ? 30 + Double(popupSamplesTotal - 1) * 10
            : baseDeadline
        let popupStalled = popupScenarioEnabled && popupPhase != .done && elapsed >= popupDeadline + 10
        // adr/0011 §5 items 5/6/7 (WINDOW_SMOKE_CMDMAP_LIVE / WINDOW_SMOKE_INPUT_TEST=ime /
        // WINDOW_SMOKE_UNICODE_DEGRADE): worst case is the input-test target lock (>=5s, later
        // if the launched app is slow to paint) + six chords at 0.4s + the 2s post-Cmd+S
        // settle -- ~10s, so 30s leaves the same comfortable slack every other scenario's
        // deadline does, and `inputScriptStalled` is the same hard failsafe shape (normally
        // `inputScriptComplete` is what gates the wait; a battery whose target never appears
        // fails its own `finish()` assertions rather than hanging).
        let inputScriptScenarioActive = cmdMapLiveActive || inputTestMode == .ime || unicodeDegradeScenarioEnabled
        let inputScriptDeadline: TimeInterval = inputScriptScenarioActive ? 30 : baseDeadline
        let inputScriptStalled = inputScriptScenarioActive && !inputScriptComplete
            && elapsed >= inputScriptDeadline + 10
        // adr/0014 §6: the click itself is instantaneous (two posts onto an in-process queue);
        // the whole wait is for the tray driver to launch and produce a live icon, which the
        // tray scenario's own runs have shown happening within the standard budget. 30s keeps
        // the same comfortable-slack convention as every scenario above, and
        // `trayClickStalled` is the same hard-failsafe shape: normally `trayClickDone` gates
        // the wait, and a run whose icon never appears fails the tray scenario's OWN
        // `realIconMaxObserved >= 1` gate (plus this scenario's `clicksForwarded >= 1`) rather
        // than hanging.
        let trayClickDeadline: TimeInterval = trayClickScenarioEnabled ? 30 : baseDeadline
        let trayClickStalled = trayClickScenarioEnabled && !trayClickDone && elapsed >= trayClickDeadline + 10
        let overallDeadline = max(
            max(rotationDeadline, maximizeDeadline),
            max(moveResizeDeadline, max(popupDeadline, max(inputScriptDeadline, trayClickDeadline)))
        )
        let rotationReady = focusRotationTotal == 0 || focusRotationDone || rotationStalled
        let maximizeReady = !maximizeScenarioEnabled || maximizePhase == .done || maximizeStalled
        let moveResizeReady = !moveResizeScenarioEnabled || moveResizePhase == .done || moveResizeStalled
        let popupReady = !popupScenarioEnabled || popupPhase == .done || popupStalled
        let inputScriptReady = !inputScriptScenarioActive || inputScriptComplete || inputScriptStalled
        let trayClickReady = !trayClickScenarioEnabled || trayClickDone || trayClickStalled
        if elapsed >= overallDeadline, rotationReady, maximizeReady, moveResizeReady, popupReady,
           inputScriptReady, trayClickReady
        {
            finish()
        }
    }

    /// Reconnect-soak driver (`WINDOW_SMOKE_CYCLES` > 1): success for a cycle is at least
    /// one visible window with real displayed content, followed by a clean five-step
    /// shutdown. The standard 25s assertion battery is skipped wholesale in this mode --
    /// its per-window pixel anchors are single-connection semantics; what this mode
    /// gates is the reconnect protocol surviving N round trips without a hang, an unclean
    /// shutdown, or runaway memory.
    private func tickCycles(session: CRSession, registry: RemoteWindowRegistry) {
        guard let deadline = cycleDeadline, let startedAt = cycleStartedAt else { return }
        let seconds = Date().timeIntervalSince(startedAt)

        // adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE): a probe is watching for
        // a delayed close after a blind-sent Enter -- resolve that before touching any of
        // the normal close-leg state below (frozen while this runs). Always false when
        // closeProbeEnabled is false, since closeProbePendingTarget is then never set.
        if closeProbePendingTarget != nil {
            tickCloseProbe(session: session, registry: registry, seconds: seconds)
            return
        }

        // Phase B: this cycle's winver got a synthetic Enter -- wait for its WindowDelete
        // before disconnecting. Closing the window each cycle keeps the server session at
        // a steady state instead of accumulating one winver per cycle: the first 20-cycle
        // run against the real host piled up 14 dialogs and the 15th reattach then hung in
        // session activation past the 25s deadline (the Phase 0 "leftover session causes
        // ACTIVATION_TIMEOUT" behavior class). It also makes every cycle a full input round trip.
        if let targetId = cycleCloseTargetId, let closeDeadline = cycleCloseDeadline {
            if !cycleEnterSent {
                // adr/0012 task item 3: the activation click that locked (or re-locked, on
                // retry) this target already routed through the real mouseDown path ->
                // `FocusAuthority.localActivate` (see `activateForClose`) -- the keyboard-
                // lane gate now owns "don't let this Enter out until the server actually
                // confirms convergence" structurally, so there is no more manual
                // MonitoredDesktop.activeWindowId poll/fallback dance here. `cycleEnterAt`
                // is just a short settle separating the click from the Enter by more than
                // one run-loop turn.
                guard let settleAt = cycleEnterAt, Date() >= settleAt else { return }
                cycleEnterSent = true
                if let nsWindow = registry.window(forWindowId: targetId) {
                    // Redundant with activateForClose's own makeKeyAndOrderFront, but
                    // cheap and matches this file's existing "a redundant Activate/makeKey
                    // is a fire-and-forget no-op cost" precedent -- guards against anything
                    // else having stolen key status during the settle.
                    nsWindow.makeKeyAndOrderFront(nil)
                    sendSyntheticEnter(to: nsWindow)
                }
                return
            }
            let aboutCount = registry.windowSnapshots().filter { snap in
                snap.isVisible
                    && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }.count
            let shrank = aboutCount < cycleAboutCountAtLock
            if !shrank && Date() < closeDeadline { return }
            if !shrank && !cycleCloseRetried {
                cycleCloseRetried = true
                if let nsWindow = registry.window(forWindowId: targetId) {
                    activateForClose(nsWindow)
                }
                cycleEnterAt = Date().addingTimeInterval(0.1)
                cycleEnterSent = false
                cycleCloseDeadline = Date().addingTimeInterval(6)
                return
            }
            print("[cycles] cycle \(cycleIndex)/\(cyclesTotal) close-leg: \(shrank ? "PASS" : "FAIL")"
                + " (retried=\(cycleCloseRetried))")
            // adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE): only fires on the
            // specific failure shape the two hypotheses are about -- the close-leg failed
            // AND the server's own truth never once matched this target across either
            // attempt (the harness-level proxy for "FocusAuthority's gate never opened, the
            // real Enter(s) were buffered and eventually hard-deadline-dropped"). A
            // close-leg that failed for some other reason (convergence DID happen, the
            // gated Enter still didn't close it) isn't this experiment's target and is left
            // alone -- probing it wouldn't distinguish hypothesis A from B.
            if closeProbeEnabled, !shrank, !cycleTargetEverConverged {
                beginCloseProbe(cycle: cycleIndex, targetId: targetId, aboutCountBefore: aboutCount, session: session)
                return
            }
            finishCycle(session: session, registry: registry, rendered: true, closed: shrank,
                        seconds: seconds)
            return
        }

        // Phase A: waiting for this cycle's own render. The >0.5s floor rejects the
        // degenerate instant-pass failure mode (asserting on a previous cycle's leftover
        // windows reads as ~0.05s; a genuine connect + exec + first paint has never been
        // observed under ~1s even against a warm host).
        let rendered = registry.windowSnapshots().contains { $0.isVisible && $0.hasDisplayedContent }
            && seconds > 0.5
        if rendered {
            let aboutWindows = registry.windowSnapshots().filter { snap in
                snap.isVisible
                    && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }
            if let target = aboutWindows.first(where: \.hasDisplayedContent) {
                cycleCloseTargetId = target.windowId
                cycleAboutCountAtLock = aboutWindows.count
                // adr/0012 follow-up diagnostic: a fresh lock starts a fresh close-leg --
                // any convergence observed for a PRIOR cycle's target must not leak into
                // this one's probe-eligibility check.
                cycleTargetEverConverged = false
                // adr/0012 task item 3: remote keyboard focus must actually be ON the
                // target before the Enter is meaningful -- reattached sessions come up
                // with the server's own idea of focus. Activation now goes through the
                // SAME real click path the production app uses (`activateForClose` ->
                // RemoteWindowRegistry.handleInput's mouseButton case ->
                // FocusAuthority.localActivate), not a direct `session.activateWindow`
                // call, so the keyboard-lane gate this arms is honored "by construction"
                // rather than needing this driver to separately poll for confirmation.
                if let nsWindow = registry.window(forWindowId: target.windowId) {
                    activateForClose(nsWindow)
                }
                cycleEnterAt = Date().addingTimeInterval(0.1) // short settle, not a focus wait
                cycleEnterSent = false
                cycleCloseDeadline = Date().addingTimeInterval(6)
                return
            }
            // Rendered but no About-titled target yet. The title regularly arrives on a
            // later WindowUpdate than the first presented frame, so an immediate give-up
            // here spuriously skips the whole close leg on fast cycles -- poll within a
            // grace window before conceding the target really is not coming.
            if cycleRenderedAt == nil { cycleRenderedAt = Date() }
            // 6s: a 3s grace still lost one cycle in ~40 to a late title (observed live
            // 2026-08-23, cycle 2/20 giving up at rendered+3s with the About title
            // arriving after) -- the title is a WindowUpdate the server batches at its
            // own pace under churn.
            if let renderedAt = cycleRenderedAt, Date().timeIntervalSince(renderedAt) < 6.0 {
                return
            }
            finishCycle(session: session, registry: registry, rendered: true, closed: false,
                        seconds: seconds)
            return
        }
        if Date() >= deadline {
            finishCycle(session: session, registry: registry, rendered: false, closed: false,
                        seconds: seconds)
        }
    }

    /// The visible windows as they stood at the END of the most recent cycle, captured before
    /// `shutdownAndWait()` and `prepareForReconnect()` tear the registry down (`closeAllWindows()`
    /// -> `windows.removeAll()`). `finishCycles()` judges the size bands against THIS list: after
    /// the teardown `windowSnapshots()` is empty by construction, and a band pass over that would
    /// be a constant stated as evidence (review sizeband-finishcycles-r1 B1).
    private var lastCycleVisibleWindows: [RemoteWindowRegistry.WindowSnapshot] = []

    private func finishCycle(session: CRSession, registry: RemoteWindowRegistry, rendered: Bool,
                             closed: Bool, seconds: Double) {
        lastCycleVisibleWindows = registry.windowSnapshots().filter(\.isVisible)
        let clean = session.shutdownAndWait()
        // Post-shutdown, a drain can NEVER clean the registry: shutdownAndWait's own
        // step-4 loop already consumed the .disconnected event, and its final step bumped
        // the generation, so everything still queued is stale-generation and gets
        // discarded (2026-08-22 review BLOCKER -- an earlier "forced drain" here delivered
        // zero events and proved nothing). The registry offers an explicit reset for
        // exactly this driver; the empty-check right after is the structural sanity assert.
        //
        // M1 L9 / adr/0015 §5.A.4, and the contract `RemoteWindowRegistry.swift:500-508` states
        // in the caller's direction: `prepareForReconnect()` re-freezes the registry's snapshot
        // from the LIVE provider, and this registry is reused across the whole soak. Re-deriving
        // the desktop size here, immediately before it and in the same turn, is what keeps the
        // next connection's Y-flip anchor and its negotiated desktop size from one `NSScreen`
        // read. Reversing these two lines would freeze the registry against the OLD layout and
        // then tell the server about the new one -- the exact divergence §5.A.4 forbids, and one
        // that no offline test can catch because the registry's own freeze-count still counts up.
        freezeAndApplyDesktopSize(to: session, reason: "cycle \(cycleIndex) reconnect")
        registry.prepareForReconnect()
        let leftover = registry.windowSnapshots().count
        cycleResults.append((rendered: rendered, closed: closed, clean: clean && leftover == 0,
                             seconds: seconds))
        print("[cycles] cycle \(cycleIndex)/\(cyclesTotal): rendered=\(rendered) closed=\(closed) "
            + "clean=\(clean) leftoverWindows=\(leftover) " + String(format: "%.1fs", seconds))
        if baselineRSS == nil { baselineRSS = Self.residentSizeBytes() }
        cycleCloseTargetId = nil
        cycleCloseDeadline = nil
        cycleEnterAt = nil
        cycleEnterSent = false
        cycleAboutCountAtLock = 0
        cycleCloseRetried = false
        cycleTargetEverConverged = false
        cycleRenderedAt = nil
        // adr/0014 §6: the tray-click scenario's per-connection state dies with the
        // connection. `registry.prepareForReconnect()` above tore down every live
        // `NSStatusItem`, so every key in `liveNotifyIconKeys` now names an icon that no
        // longer exists -- and notify-icon ids are per-session, so the next cycle's server may
        // legitimately reuse the same numbers for different icons, which is how a stale key
        // turns into a click addressed at the wrong icon (or at nothing, failing
        // `clicksDroppedIconGone == 0` for a reason that is the harness's fault, not the
        // code's). Clearing here (rather than intersecting the chosen key against registry
        // state at lock time) matches how every other per-cycle field on this driver is
        // handled, and keeps "pick one live key" honest at its source instead of filtering a
        // knowingly-stale list later.
        //
        // Defensive today, deliberately: `tick()` routes cycle-mode runs to `tickCycles` and
        // returns before `runTrayClickScenario` ever gets called, while the drain-side
        // tracking below IS mode-independent -- so the list can go stale in this mode even
        // though nothing consumes it yet. That asymmetry is exactly the kind that stops being
        // harmless the moment the click driver is taught about cycles.
        //
        // `trayClickDone` is deliberately NOT reset: this scenario clicks once per RUN, not
        // once per cycle -- re-arming would make `notifyEventsSent == 2 * clicksForwarded`
        // span every cycle's clicks while the collected message list holds only the last
        // one's, breaking the identity the gate exists to check.
        liveNotifyIconKeys.removeAll()
        notifyIconTooltips.removeAll()
        if !trayClickDone {
            trayClickTarget = nil
            outboundDroppedNoRailBeforeClick = nil
            outboundPostDroppedBeforeClick = nil
        }

        if cycleIndex >= cyclesTotal || !rendered {
            finishCycles()
            return
        }
        cycleIndex += 1
        cycleStartedAt = Date()
        cycleDeadline = Date().addingTimeInterval(25)
        session.start()
    }

    /// adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE), harness-only: starts the
    /// probe watch for one close-leg that failed with the target's convergence never once
    /// observed. `aboutCountBefore` is the About-window count at the moment this fires (the
    /// SAME count `tickCycles`' own `shrank` check just used), so `tickCloseProbe` can
    /// detect a shrink caused specifically by this probe's own blind Enter, not stale state
    /// from before it.
    private func beginCloseProbe(cycle: Int, targetId: UInt32, aboutCountBefore: Int, session: CRSession) {
        print("[close-probe] cycle=\(cycle) target=\(targetId): convergence never observed for "
            + "this close-leg -- blind-sending a probe Enter (bypasses RemoteWindowRegistry/"
            + "FocusAuthority entirely) to test whether it would have landed anyway")
        sendBlindEnter(session: session)
        closeProbePendingCycle = cycle
        closeProbePendingTarget = targetId
        closeProbePendingAboutCountAtSend = aboutCountBefore
        closeProbePendingDeadline = Date().addingTimeInterval(2.0)
    }

    /// adr/0012 follow-up diagnostic: `CRSession.sendKeyDown(_:)`/`sendKeyUp(_:)` are the
    /// same two primitives `RemoteWindowRegistry`'s own keyboard-lane gate calls once it
    /// decides to flush -- called directly here, from the harness, they reach the wire with
    /// no RemoteWindowContentView/RemoteWindowRegistry/FocusAuthority involvement at all
    /// (unlike `sendSyntheticEnter`, which dispatches a real `NSEvent` through
    /// `NSWindow.sendEvent(_:)` and so still goes through the real content-view/registry/
    /// gate path). This is deliberately the *only* place in this harness that calls these
    /// two methods directly -- see the module-level `closeProbeEnabled` doc comment for why.
    private func sendBlindEnter(session: CRSession) {
        let macReturnKeyCode: UInt16 = 36
        session.sendKeyDown(macReturnKeyCode)
        session.sendKeyUp(macReturnKeyCode)
    }

    /// adr/0012 follow-up diagnostic: polls up to 2s for the target's About-window count to
    /// shrink following `beginCloseProbe`'s blind Enter, logs the required per-probe result
    /// line, records it for the final summary, then resumes the normal cycle-finish flow
    /// with the close-leg's own original verdict -- `closed: false` always, since this is
    /// only ever entered from the one call site where the close-leg had already failed
    /// (informational only: the probe's own outcome never changes cycle gating).
    private func tickCloseProbe(session: CRSession, registry: RemoteWindowRegistry, seconds: Double) {
        guard let targetId = closeProbePendingTarget, let cycle = closeProbePendingCycle,
              let deadline = closeProbePendingDeadline, let aboutBefore = closeProbePendingAboutCountAtSend
        else { return }

        let aboutCount = registry.windowSnapshots().filter { snap in
            snap.isVisible
                && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
        }.count
        let closedDespiteNonConvergence = aboutCount < aboutBefore
        guard closedDespiteNonConvergence || Date() >= deadline else { return }

        print("[close-probe] cycle=\(cycle) target=\(targetId) closedDespiteNonConvergence=\(closedDespiteNonConvergence)")
        closeProbeResults.append(CloseProbeResult(
            cycle: cycle, targetId: targetId, closedDespiteNonConvergence: closedDespiteNonConvergence))
        closeProbePendingCycle = nil
        closeProbePendingTarget = nil
        closeProbePendingAboutCountAtSend = nil
        closeProbePendingDeadline = nil

        finishCycle(session: session, registry: registry, rendered: true, closed: false, seconds: seconds)
    }

    private func finishCycles() {
        drainTimer?.invalidate()
        drainTimer = nil
        printRunElapsed()

        var ok = true
        func check(_ cond: Bool, _ message: String) {
            print("[assert] \(cond ? "PASS" : "FAIL"): \(message)")
            if !cond { ok = false }
        }

        // M1 F2 + F1: the same one-per-run measurement lines `finish()` prints -- cycle mode exits
        // through HERE, so omitting them would make the measurements silently mode-dependent.
        printMeasurementSummaries()
        print("[topology] session desktop size after \(cycleResults.count) cycle(s): "
            + (sessionDesktopSizeInRemotePixels.map { "\($0.width)x\($0.height) remote px" }
                ?? "<not set -- no usable display at the last freeze, adr/0015 §5.A.6>"))
        // adr/0015 §5's reconnect re-take, pinned against the soak that actually ran: one freeze
        // at connect plus one per finished cycle (`finishCycle` calls `freezeAndApplyDesktopSize`
        // then `prepareForReconnect()`). This is the assertion the registry's own doc comment
        // hands to this harness -- the App target has no test bundle, so there is no other place
        // it can be made.
        let freezePin = topologyFreezeCountCheck(expectedReconnects: cycleResults.count)
        check(freezePin.passed, freezePin.message)
        // The same size-band pass `finish()` runs, over the windows that were visible at the END
        // of the last cycle (review sizeband-r3 m-1). Cycle mode's `tick()` returns before the
        // per-tick scenarios (unicode-degrade target lock, focus rotation, extra apps), so the
        // only size-band consumer on this exit is the band loop itself and the frozen-topology
        // precondition guards exactly that (review sizeband-finishcycles-r2 I-1 corrected the
        // earlier "per-tick consumers" rationale). NOT over `registry.windowSnapshots()`: by the
        // time this runs, `finishCycle` has already torn the registry down
        // (`prepareForReconnect()` -> `closeAllWindows()`), so that list is empty by construction
        // -- `lastCycleVisibleWindows` is the snapshot taken before the teardown. A clean cycle
        // leaves it empty; a winver the close leg failed to close is still mapped at cycle end
        // and is exactly what gets judged here.
        _ = assertPlausibleContentBands(over: lastCycleVisibleWindows, check: check)

        let renderedCount = cycleResults.filter(\.rendered).count
        let closedCount = cycleResults.filter(\.closed).count
        let cleanCount = cycleResults.filter(\.clean).count
        check(
            cycleResults.count == cyclesTotal && renderedCount == cyclesTotal,
            "all \(cyclesTotal) cycles reached a visible content window (got \(renderedCount) of \(cycleResults.count) attempted)"
        )
        // Floor, not 100%: even with a full activate+Enter retry, ~15-25% of cycles have
        // historically still failed to close their winver -- three different manual-timing
        // strategies produced the same residual rate before adr/0012 (recorded as a Phase 2
        // focus-sync work item), not harness slop. adr/0012 task item 3 replaces the manual
        // timing with the gated path (activateForClose -> FocusAuthority.localActivate,
        // keystrokes flow through the keyboard-lane gate by construction) but deliberately
        // kept this floor unchanged until real gated-path evidence existed. That evidence
        // landed 2026-08-23: after the periodic re-arm + cold-start deadline (adr/0012
        // §4.5) and the target-lock grace fix in this harness, two consecutive healthy-host
        // soaks closed 20/20 + 20/20 with zero retries exhausted -- so this is now the
        // ADR's own W1 exit gate (≤2% failure), not the interim 70% floor.
        check(
            Double(cycleResults.count - closedCount) <= Double(cycleResults.count) * 0.02,
            "close-leg failure rate is <=2% (adr/0012 §4 W1 exit gate) "
                + "(got \(cycleResults.count - closedCount) failures of \(cycleResults.count))"
        )
        if !cycleResults.isEmpty {
            let failureRate = Double(cycleResults.count - closedCount) / Double(cycleResults.count) * 100
            print(String(
                format: "[cycles] close-leg failure rate: %.1f%% (%d of %d cycles failed to close)",
                failureRate, cycleResults.count - closedCount, cycleResults.count
            ))
        }
        check(
            cleanCount == cycleResults.count,
            "every cycle's shutdownAndWait reported clean (got \(cleanCount) of \(cycleResults.count))"
        )
        if let baseline = baselineRSS, let final = Self.residentSizeBytes() {
            let growthMB = Double(final - baseline) / (1024 * 1024)
            print(String(format: "[cycles] RSS growth cycle1->end: %+.1f MB (baseline %.1f MB)",
                         growthMB, Double(baseline) / (1024 * 1024)))
            // Deliberately generous: this is a catastrophic-leak tripwire (a per-cycle
            // leak of surfaces/threads shows up as hundreds of MB over 20 cycles), not a
            // byte-accurate accounting -- CoreAnimation/IOSurface caching makes small
            // positive drift normal and a tight bound flaky.
            check(growthMB < 300, String(format: "RSS growth across cycles stays under the catastrophic-leak tripwire (got %+.1f MB, limit 300 MB)", growthMB))
        } else {
            print("[cycles] RSS growth: unavailable (task_info failed)")
        }
        let times = cycleResults.map(\.seconds).sorted()
        if !times.isEmpty {
            // ceil(0.95n)-1, not Int(0.95n): the latter lands on the MAX for n=20
            // (index 19) instead of the 19th-of-20 value (index 18).
            let p95 = times[max(0, Int((Double(times.count) * 0.95).rounded(.up)) - 1)]
            print(String(format: "[cycles] time-to-content: median %.1fs p95 %.1fs", times[(times.count - 1) / 2], p95))
        }

        // adr/0012 follow-up diagnostic (WINDOW_SMOKE_CLOSE_PROBE): purely informational --
        // never folded into `ok`. `closed` here counts probes where the blind Enter closed
        // the window despite the target having never converged, i.e. hypothesis B's own
        // measured rate (activeWindowId lagging/misreporting real focus).
        if closeProbeEnabled {
            let probeClosedCount = closeProbeResults.filter(\.closedDespiteNonConvergence).count
            print("[close-probe] probes=\(closeProbeResults.count) closed=\(probeClosedCount)")
        }

        print("\noverall: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }

    /// Current process resident size via mach task_info -- the cycle soak's leak signal.
    private static func residentSizeBytes() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int(info.resident_size)
    }

    /// Phase 2 W0③ verification (docs/plans/phase2.md W0 item ③, "首帧门控：首帧前不
    /// orderFront"): the very first time each windowId is observed visible, it must
    /// already have real displayed content -- OR `RemoteWindow`'s 2s no-paint fallback
    /// must have fired for it (plumbed through as `WindowSnapshot.firstFrameTimedOut`) --
    /// never neither. Catches a regression back to the pre-W0③ behavior (ordered front
    /// immediately on WindowCreate, before any frame had a chance to present) without this
    /// harness needing to control frame timing itself.
    private func checkFirstFrameGate(_ snapshots: [RemoteWindowRegistry.WindowSnapshot]) {
        for snap in snapshots where snap.isVisible && !firstFrameGateChecked.contains(snap.windowId) {
            firstFrameGateChecked.insert(snap.windowId)
            if snap.hasDisplayedContent {
                print("[first-frame] windowId=\(snap.windowId) became visible with content already presented")
            } else if snap.firstFrameTimedOut {
                print("[first-frame] windowId=\(snap.windowId) became visible via the 2s no-paint timeout "
                    + "(logged explicitly here, not shown as a silent black box)")
            } else {
                let detail = "windowId=\(snap.windowId) title=\"\(snap.title)\" became visible with no "
                    + "displayed content and no first-frame timeout recorded"
                print("[first-frame] VIOLATION: \(detail)")
                firstFrameGateViolations.append(detail)
            }
        }
    }

    /// Experiment 1 (W4b review round 2): t=6s sample, t=8s ClientActivate, t=20s sample --
    /// see `activateExperimentWindowId`'s own doc comment.
    private func runActivateExperiment(elapsed: TimeInterval, session: CRSession, registry: RemoteWindowRegistry) {
        // Scripted-input scenarios suppress this legacy W4b experiment outright: its t=20s
        // ClientActivate moves SERVER focus, and keyboard input is focus-addressed on the
        // wire (adr/0012 §2) -- the first cmdmap-live host run (2026-08-31) caught exactly
        // this race, the activate firing between the script's Cmd+V and Cmd+S so the save
        // chord landed in the experiment's About window and the file round-trip failed
        // (adr/0011 §5 item 5). An experiment must never steal focus from an acceptance
        // scenario sharing the run.
        if cmdMapLiveActive || inputTestMode == .ime || unicodeDegradeScenarioEnabled { return }
        if activateExperimentWindowId == nil {
            if let w = registry.windowSnapshots().first(where: { snap in
                snap.isVisible
                    && (snap.title.localizedCaseInsensitiveContains("registry") || snap.title.contains("注册表")
                        || snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }) {
                activateExperimentWindowId = w.windowId
                print("[experiment] Activate-experiment target locked: windowId=\(w.windowId) title=\"\(w.title)\"")
            }
        }
        guard let windowId = activateExperimentWindowId else { return }

        if elapsed >= 6, activatePreRatio == nil {
            activatePreRatio = registry.nonWhitePixelRatio(windowId: windowId, inBottomFraction: 0.2, sampleCount: 100)
            print("[experiment] pre-Activate bottom-20% non-white ratio for windowId=\(windowId): "
                + "\(activatePreRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")")
        }
        if elapsed >= 8, !didSendActivate {
            didSendActivate = true
            session.activateWindow(windowId)
            print("[experiment] sent ClientActivate for windowId=\(windowId)")
        }
        if elapsed >= 20, activatePostRatio == nil {
            activatePostRatio = registry.nonWhitePixelRatio(windowId: windowId, inBottomFraction: 0.2, sampleCount: 100)
            print("[experiment] post-Activate bottom-20% non-white ratio for windowId=\(windowId): "
                + "\(activatePostRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")")
        }
    }

    /// Phase 2 W2 task item 5b/5c (WINDOW_SMOKE_MAXIMIZE=1, multiwin prereq): drives the
    /// maximize -> restore -> close sequence directly over `CRSession.sendSysCommand(_:command:)`,
    /// never through a synthetic NSEvent or a real traffic-light button click -- this is a
    /// wire-level test of the SC_* lane and the server's own response, independent of
    /// whatever local UI affordance the About window's own chrome happens to grant it
    /// (which should have no enabled zoom button at all, per the acceptance text this task
    /// separately targets). Target-locking mirrors `runInputTest`'s own "visible +
    /// hasDisplayedContent + About-titled" anchor.
    ///
    /// Advances at most one phase transition per call (mirrors `tickCycles`' own per-tick
    /// state machine shape) -- called every `tick()` once the multiwin setup
    /// (`extraAppsLaunched`) is ready.
    private func runMaximizeScenario(session: CRSession, registry: RemoteWindowRegistry) {
        guard maximizeScenarioEnabled else { return }

        switch maximizePhase {
        case .waitingForTarget:
            guard extraAppsLaunched else { return } // multiwin prereq, per the task spec
            guard let w = registry.windowSnapshots().first(where: { snap in
                snap.isVisible && snap.hasDisplayedContent
                    && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }) else { return }
            maximizeTargetWindowId = w.windowId
            print("[maximize] target locked: windowId=\(w.windowId) title=\"\(w.title)\"")
            session.sendSysCommand(w.windowId, command: SC.maximize)
            print("[maximize] sent SC_MAXIMIZE to windowId=\(w.windowId)")
            maximizePhase = .awaitingMaximize(windowId: w.windowId, sentAt: Date())

        case .awaitingMaximize(let windowId, let sentAt):
            let snap = registry.windowSnapshots().first { $0.windowId == windowId }
            // Judged in remote px through the session's frozen topology (`SizeBand`, review
            // sizeband-r1 I2): the 2000 is a remote-px fact from the 2560-wide lab desktop, and a 2x
            // session's maximized window is a 1280 pt frame. No frozen topology means the width
            // cannot be judged at all -- the leg then times out and says so, never falls back to pt.
            let grown: (SizeBand.RemotePixelSize, String)? = snap.flatMap { s in
                displayTopology.sessionSnapshot.map { SizeBand.describe(frameSize: s.frame.size, in: $0) }
            }
            if let snap, let grown, SizeBand.isMaximizedWidth(grown.0), snap.isVisible, snap.hasDisplayedContent {
                maximizeResult = (grew: true, mappedWithContent: true)
                print("[maximize] windowId=\(windowId) grew to \(grown.1), still mapped with content")
                session.sendSysCommand(windowId, command: SC.restore)
                print("[maximize] sent SC_RESTORE to windowId=\(windowId)")
                maximizePhase = .awaitingRestore(windowId: windowId, sentAt: Date())
            } else if Date().timeIntervalSince(sentAt) >= Self.maximizePollTimeout {
                let mappedWithContent = snap?.isVisible == true && snap?.hasDisplayedContent == true
                maximizeResult = (grew: false, mappedWithContent: mappedWithContent)
                print("[maximize] windowId=\(windowId) FAILED to reach >= \(Int(SizeBand.maximizedWidthFloor)) remote px width within 5s "
                    + "(got \(grown?.1 ?? (snap == nil ? "no snapshot" : "no frozen session topology to convert pt into remote px")))")
                // Still exercise the close leg (task item 5c) even after a maximize
                // failure, skipping straight past the now-moot restore leg, rather than
                // abandoning the rest of the scenario and reporting even less data.
                session.sendSysCommand(windowId, command: SC.close)
                print("[maximize] sent SC_CLOSE to windowId=\(windowId) (restore leg skipped after a maximize failure)")
                maximizeCloseTargetId = windowId
                maximizePhase = .awaitingClose(windowId: windowId, sentAt: Date())
            }

        case .awaitingRestore(let windowId, let sentAt):
            let snap = registry.windowSnapshots().first { $0.windowId == windowId }
            // Same remote-px judgement as the maximize check above.
            let restored: (SizeBand.RemotePixelSize, String)? = snap.flatMap { s in
                displayTopology.sessionSnapshot.map { SizeBand.describe(frameSize: s.frame.size, in: $0) }
            }
            if let restored, SizeBand.isRestoredWidth(restored.0) {
                restoreResult = true
                print("[maximize] windowId=\(windowId) restored to \(restored.1)")
                session.sendSysCommand(windowId, command: SC.close)
                print("[maximize] sent SC_CLOSE to windowId=\(windowId)")
                maximizeCloseTargetId = windowId
                maximizePhase = .awaitingClose(windowId: windowId, sentAt: Date())
            } else if Date().timeIntervalSince(sentAt) >= Self.maximizePollTimeout {
                restoreResult = false
                print("[maximize] windowId=\(windowId) FAILED to restore below \(Int(SizeBand.restoredWidthCeiling)) remote px width within 5s "
                    + "(got \(restored?.1 ?? (snap == nil ? "no snapshot" : "no frozen session topology to convert pt into remote px")))")
                session.sendSysCommand(windowId, command: SC.close)
                print("[maximize] sent SC_CLOSE to windowId=\(windowId)")
                maximizeCloseTargetId = windowId
                maximizePhase = .awaitingClose(windowId: windowId, sentAt: Date())
            }

        case .awaitingClose(_, let sentAt):
            // maximizeCloseWindowDeletedAt is set by drainNow()'s own windowDelete
            // bookkeeping (mirrors inputTestWindowId's exact pattern) -- checked here
            // rather than re-deriving it from a fresh windowSnapshots() scan.
            if maximizeCloseWindowDeletedAt != nil {
                closeResult = true
                print("[maximize] WindowDelete received within 5s of SC_CLOSE")
                maximizePhase = .done
            } else if Date().timeIntervalSince(sentAt) >= Self.maximizePollTimeout {
                closeResult = false
                print("[maximize] FAILED to receive WindowDelete within 5s of SC_CLOSE")
                maximizePhase = .done
            }

        case .done:
            break
        }
    }

    /// Phase 2 W3 (docs/plans/phase2.md §2 W3): drives a move-then-resize sequence against
    /// the target window's real `NSWindow` (About by default -- see `WINDOW_SMOKE_MOVE_TARGET`),
    /// purely programmatically -- no human drag is
    /// available to an automated harness. Uses `-setFrame:display:`, which AppKit confirms
    /// posts `NSWindow.didMoveNotification` for a programmatic origin change exactly as it
    /// would for an interactive one, so this exercises the REAL production settle path
    /// (`RemoteWindow.handleLocalGeometryChanged` -> 200ms debounce -> `onLocalGeometrySettled` ->
    /// `RemoteWindowRegistry.handleLocalGeometrySettled` -> `CRSession.sendWindowMove`) end
    /// to end, not a bypass or a direct call into any of those methods.
    ///
    /// HONESTY GAP (acknowledged, per the task spec's own wording; re-measured 2026-09-02,
    /// F-R2): `-setFrame:display:` does NOT post `NSWindow.willStartLiveResizeNotification`/
    /// `didEndLiveResizeNotification` -- those fire ONLY for a genuine interactive
    /// (mouse-driven) resize, which nothing in this headless harness can produce -- so the
    /// live-resize begin/end path `RemoteWindow` implements for an interactive resize has no
    /// automated coverage at all in this harness. What the two legs DO exercise differs, and
    /// the paragraph this replaces had it wrong: a programmatic frame change that alters the
    /// SIZE posts only `didResizeNotification` (never `didMove`, even when the origin changes
    /// in the same call -- measured on this machine: six scenarios in the controller's probe,
    /// corroborated by an independent five-scenario probe and two borderless re-runs in review;
    /// docs/upgrade-gate/2026-09-resize-leg-live.md §3.2), so the move leg travels the
    /// `didMove` observer and the resize leg the `didResize` observer, both into
    /// `RemoteWindow.handleLocalGeometryChanged`'s shared 200ms debounce. Until that second
    /// observer existed the resize leg had NO sync exit at all -- the 2026-09-02 real-host run
    /// (`env-202609-14`) sent no `ClientWindowMove` for it, which is what surfaced the
    /// production gap (`RemoteWindowLocalGeometrySyncTests` pins the fix). The DEFAULT target,
    /// About, is additionally not resizable (StyleTranslatorTests' `aboutWindowsDialogShape`),
    /// so against it even a real interactive resize could never be driven; with
    /// `WINDOW_SMOKE_MOVE_TARGET` pointing at a resizable window (env-202609-14's notepad) that
    /// half no longer applies, but the live-resize pair still cannot be produced headless.
    /// `-setFrame:display:` changes the frame at the wire/model level regardless of
    /// `styleMask`, which is what the resize leg actually verifies (does a programmatic
    /// geometry change round-trip through `ClientWindowMove` and back).
    ///
    /// Team-lead review (2026-08-23 real-host run): all target/comparison math below is in
    /// CONTENT-RECT space (`window.contentRect(forFrameRect:)`/`window.frameRect(forContentRect:)`),
    /// never the raw `NSWindow.frame` -- matching `RemoteWindow`/`RemoteWindowRegistry`'s own
    /// fix for the same real-host-discovered bug (see `RemoteWindow.updateFrame`'s doc
    /// comment). Also ends with an explicit SC_CLOSE + WindowDelete wait (Fix 2) so this
    /// scenario doesn't leave its About window open for a later `WINDOW_SMOKE_CYCLES` soak
    /// to mistake for a fresh target.
    ///
    /// OBSERVED SERVER BEHAVIOR, worth W4's shaped/popup work keeping in mind (team-lead
    /// review round 6, 2026-08-23 real-host run): after this scenario's own move leg, the
    /// server was observed to REMAP the window's GFX surface mid-move (536x521 -> 522x514,
    /// i.e. down to exactly its RAIL-reported size, with no resize request from this client
    /// at all) -- a plain move can trigger a surface remap as a server-side side effect, not
    /// only an explicit resize. This is why the move leg's own round-trip assertion is
    /// POSITION-only (`evaluateMoveResizeLeg`'s own doc comment) -- size is legitimately the
    /// server's prerogative to change out from under a move, and a future feature that
    /// assumes "size only changes on an explicit resize request" would be building on an
    /// assumption this run's own evidence already contradicts.
    private func runMoveResizeScenario(session: CRSession, registry: RemoteWindowRegistry) {
        guard moveResizeScenarioEnabled else { return }

        switch moveResizePhase {
        case .waitingForTarget:
            guard extraAppsLaunched else { return } // multiwin prereq, per the task spec
            // Sorted by windowId (as `focusRotationCandidateWindows` does): `windowSnapshots()` is
            // dictionary-ordered. `MoveResizeTarget.lock` sorts again on its own, so this order now
            // only fixes the "titles seen" wording of the miss line below between runs.
            let candidates = registry.windowSnapshots().sorted(by: { $0.windowId < $1.windowId })
                .filter { $0.isVisible && $0.hasDisplayedContent }
            // The decision is `MoveResizeTarget.lock`'s (pure, self-tested): under an explicit
            // filter, windows that already existed when the extra apps were launched are skipped,
            // so a leftover from an earlier run can no longer be locked before this run's own
            // window appears (env-202609-14, review resize-live-r2 I-2 / r3 I-r3-1).
            let lockCandidates = candidates.map { MoveResizeTarget.Candidate(windowId: $0.windowId, title: $0.title) }
            guard let locked = MoveResizeTarget.lock(
                      candidates: lockCandidates, filter: moveResizeTargetFilter, preExisting: windowIdsBeforeExtraApps
                  ),
                  let w = candidates.first(where: { $0.windowId == locked.windowId }),
                  let window = registry.window(forWindowId: w.windowId)
            else {
                // A filter that matches nothing would otherwise stall silently for the whole
                // scenario deadline and surface as a generic "no target locked" red (review
                // movetarget-r2 m-2). Say so once, with the titles that WERE visible -- and, when
                // it matched only pre-existing windows, say THAT (the wait is expected). Each line
                // has its own one-shot flag: a run can legitimately show both, in either order.
                if let moveResizeTargetFilter, !candidates.isEmpty,
                   !moveResizeTargetPreExistingOnlyLogged || !moveResizeTargetMissLogged
                {
                    let skipped = MoveResizeTarget.matchedOnlyPreExisting(
                        candidates: lockCandidates, filter: moveResizeTargetFilter, preExisting: windowIdsBeforeExtraApps
                    )
                    if !skipped.isEmpty, !moveResizeTargetPreExistingOnlyLogged {
                        moveResizeTargetPreExistingOnlyLogged = true
                        print("[move-resize] WINDOW_SMOKE_MOVE_TARGET=\"\(moveResizeTargetFilter)\" matched only window(s) that "
                            + "existed before the extra apps were launched (ids \(skipped)); waiting for a window launched by this run")
                    } else if skipped.isEmpty, !moveResizeTargetMissLogged {
                        moveResizeTargetMissLogged = true
                        print("[move-resize] no visible content window matched WINDOW_SMOKE_MOVE_TARGET=\"\(moveResizeTargetFilter)\" "
                            + "(titles seen: \(candidates.map { "\"\($0.title)\"" }.joined(separator: ", ")))")
                    }
                }
                return
            }
            moveResizeWindowId = w.windowId
            // Team-lead review round 6: baseline for the move leg's own "did the mapped
            // size change mid-leg" informational report -- see that report's own comment.
            moveResizeOriginalMappedSize = registry.debugMappedSize(forWindowId: w.windowId)
            let originalContent = window.contentRect(forFrameRect: window.frame)
            // Team-lead review round 5 (2026-08-23, real-host run): +60 in Y (moving the
            // window's titlebar TOWARD the top of the screen) was observed to run the native
            // titlebar off the top of the visible screen/menu-bar area, which AppKit itself
            // clamps back down -- the settle path then HONESTLY reported the clamped (not
            // requested) position, which briefly looked like a server-side "Y never moved"
            // bug but was actually this harness asking for something AppKit would never
            // grant. -60 (down, away from the screen's top edge) avoids that specific
            // failure mode for a window that starts anywhere reasonably below the very top
            // of the screen.
            let targetContent = originalContent.offsetBy(dx: 80, dy: -60)
            let targetFrame = window.frameRect(forContentRect: targetContent)
            print("[move-resize] target locked: windowId=\(w.windowId) title=\"\(w.title)\" originalContent=\(originalContent) -> move target content=\(targetContent)")
            moveResizeObservedContentRects.removeAll()
            window.setFrame(targetFrame, display: true)
            // Team-lead review round 5: assert against the ACTUAL post-setFrame content
            // rect, not the requested one -- more honest regardless of direction chosen
            // (AppKit is free to clamp/adjust ANY requested frame for reasons beyond just
            // the top-of-screen case above, e.g. screen width, Spaces, multi-monitor
            // arrangement), and this is what the real settle path (`RemoteWindow.
            // handleLocalGeometryChanged` -> `settleLocalMove`) itself reports too -- comparing
            // against anything else risks this harness grading AppKit's own clamping as a
            // server round-trip failure.
            let actualSettledContent = window.contentRect(forFrameRect: window.frame)
            if actualSettledContent != targetContent {
                print("[move-resize] NOTE: AppKit did not grant the exact requested content rect -- requested=\(targetContent) actual=\(actualSettledContent) (asserting against actual, per team-lead review round 5)")
            }
            moveResizePhase = .awaitingMoveSettle(windowId: w.windowId, target: actualSettledContent, sentAt: Date())

        case .awaitingMoveSettle(let windowId, let target, let sentAt):
            // Team-lead review round 6: position-only match -- see evaluateMoveResizeLeg's
            // own doc comment for why size is out of scope for a pure move.
            guard let outcome = evaluateMoveResizeLeg(
                windowId: windowId, target: target, sentAt: sentAt, matchPositionOnly: true
            ) else { return }
            moveResult = outcome
            print("[move-resize] move leg resolved (position-only): legPassed=\(outcome.passed) "
                + "oscillation=\(outcome.oscillation.text) \(outcome.detail)")
            if let mapped = registry.debugMappedSize(forWindowId: windowId), let originalMapped = moveResizeOriginalMappedSize,
               mapped != originalMapped
            {
                // Team-lead review round 6: "report size deltas informationally" -- the
                // per-event raw-geometry line already shows mapped size at every order, but
                // this is the one-line summary confirming whether it actually changed
                // between lock and resolve, without requiring a reader to diff every prior
                // line by hand.
                print(
                    "[move-resize] INFO: GFX-mapped size changed during the move leg "
                        + "(server prerogative, not a client request): "
                        + "\(Int(originalMapped.width))x\(Int(originalMapped.height)) -> "
                        + "\(Int(mapped.width))x\(Int(mapped.height))"
                )
            }
            guard let window = registry.window(forWindowId: windowId) else {
                moveResizePhase = .done
                return
            }
            // Task spec: "resize +100pt wider (if resizable -- About isn't; use setFrame
            // anyway wire-level ... note it)" -- see this scenario's own doc comment for
            // the acknowledged honesty gap this leg carries. Team-lead review round 4
            // (2026-08-23, no-false-red discipline): captured HERE, at send time, not
            // re-derived in finish() -- by finish() this window may already be closed (the
            // scenario's own SC_CLOSE leg), so this is the only reliable moment to ask
            // AppKit whether the real target actually supports interactive resize at all.
            moveResizeTargetIsResizable = window.styleMask.contains(.resizable)
            let currentContent = window.contentRect(forFrameRect: window.frame)
            let resizeTargetContent = NSRect(
                x: currentContent.origin.x, y: currentContent.origin.y,
                width: currentContent.width + 100, height: currentContent.height
            )
            let resizeTargetFrame = window.frameRect(forContentRect: resizeTargetContent)
            moveResizeObservedContentRects.removeAll()
            window.setFrame(resizeTargetFrame, display: true)
            print("[move-resize] resize leg sent (content-rect space): \(currentContent) -> \(resizeTargetContent)")
            // Team-lead review round 5: same "assert against actual, not requested" fix as
            // the move leg above -- a +100pt-wider request could in principle also get
            // clamped (e.g. against screen width) even though this specific run's failure
            // was Y-only.
            let actualResizeSettledContent = window.contentRect(forFrameRect: window.frame)
            if actualResizeSettledContent != resizeTargetContent {
                print("[move-resize] NOTE: AppKit did not grant the exact requested resize content rect -- requested=\(resizeTargetContent) actual=\(actualResizeSettledContent) (asserting against actual, per team-lead review round 5)")
            }
            moveResizePhase = .awaitingResizeSettle(windowId: windowId, target: actualResizeSettledContent, sentAt: Date())

        case .awaitingResizeSettle(let windowId, let target, let sentAt):
            // Team-lead review round 6: full-rect match, unchanged -- this leg's whole point
            // is size, unlike the move leg above.
            guard let outcome = evaluateMoveResizeLeg(
                windowId: windowId, target: target, sentAt: sentAt, matchPositionOnly: false
            ) else { return }
            resizeResult = outcome
            print("[move-resize] resize leg resolved: legPassed=\(outcome.passed) "
                + "oscillation=\(outcome.oscillation.text) \(outcome.detail)")
            // Fix 2 (team-lead review): always attempt the close leg here, matching the
            // maximize scenario's own "still exercise the close leg even after an earlier
            // leg's failure" precedent -- cleanup shouldn't depend on the round-trip
            // assertions above having passed.
            session.sendSysCommand(windowId, command: SC.close)
            print("[move-resize] sent SC_CLOSE to windowId=\(windowId)")
            moveResizeCloseTargetId = windowId
            moveResizePhase = .awaitingClose(windowId: windowId, sentAt: Date())

        case .awaitingClose(_, let sentAt):
            // moveResizeCloseWindowDeletedAt is set by drainNow()'s own windowDelete
            // bookkeeping (mirrors maximizeCloseWindowDeletedAt's exact pattern).
            if moveResizeCloseWindowDeletedAt != nil {
                moveResizeCloseResult = true
                print("[move-resize] WindowDelete received within 5s of SC_CLOSE")
                moveResizePhase = .done
            } else if Date().timeIntervalSince(sentAt) >= Self.moveResizeClosePollTimeout {
                moveResizeCloseResult = false
                print("[move-resize] FAILED to receive WindowDelete within 5s of SC_CLOSE")
                moveResizePhase = .done
            }

        case .done:
            break
        }
    }

    /// adr/0010 W4 first slice (WINDOW_SMOKE_POPUP=1): menu-popup end-to-end acceptance --
    /// About has a system menu (its `WS_SYSMENU` bit, `StyleTranslatorTests.
    /// aboutWindowsDialogShape`), and Alt+Space is the standard Windows shortcut that opens
    /// any top-level window's system menu regardless of whether it has a visible titlebar
    /// icon to click -- chosen over a titlebar-icon click (no synthesizable target coordinate
    /// this harness could rely on across DPI/theme) and over charmap/dxdiag's own menu bars
    /// (About is already this run's own locked, real-content-anchored target every other
    /// scenario uses; reusing it avoids adding a second target-lock heuristic).
    ///
    /// Sequence: (1) lock the About window as target (multiwin prereq, mirrors
    /// `runMaximizeScenario`/`runMoveResizeScenario`'s own target-lock shape); (2) activate
    /// it via the REAL gated path (`activateForClose`'s own click-to-focus helper -- adr/0012
    /// §2's "keyboard is focus-addressed" means the keystroke below must not race a focus
    /// convergence that hasn't happened yet); (3) after a 0.3s settle (mirrors
    /// `sendSyntheticClick`'s own two-stage gap reasoning), send Alt+Space; (4) poll up to 5s
    /// for a NEW windowId (not present before the keystroke) that resolves via
    /// `RemoteWindowRegistry.attachedOwner(forWindowId:)` to the About window's own id
    /// (adr/0010 §4's own parent-child attachment, the authoritative "this really is a
    /// popup of that owner" signal -- more reliable than guessing at title emptiness, which
    /// this scenario still logs but does not gate on); (5) once located, send Escape and poll
    /// up to 3s for its `WindowDelete`; (6) team-lead review: EVERY terminal path (popup
    /// closed cleanly, popup located but never closed, popup never located at all) funnels
    /// through `beginAboutCleanup` -- SC_CLOSE on the About window itself, so this scenario
    /// never leaves it open for a later `WINDOW_SMOKE_CYCLES` soak to mistake for a fresh
    /// target (the exact same stale-window contamination class `moveResizeCloseTargetId`'s
    /// own doc comment already documents as Fix 2 there, observed a third time this round).
    private func runPopupScenario(session: CRSession, registry: RemoteWindowRegistry) {
        guard popupScenarioEnabled else { return }

        switch popupPhase {
        case .waitingForTarget:
            guard extraAppsLaunched else { return } // multiwin prereq, per the task spec
            guard let w = registry.windowSnapshots().first(where: { snap in
                snap.isVisible && snap.hasDisplayedContent
                    && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }), let window = registry.window(forWindowId: w.windowId) else { return }
            popupOwnerWindowId = w.windowId
            popupWindowIdsBeforeKeystroke = Set(registry.windowSnapshots().map(\.windowId))
            print("[popup] target locked: windowId=\(w.windowId) title=\"\(w.title)\"")
            // adr/0012: the SAME real mouseDown path `activateForClose` already establishes
            // for the cycle-mode close leg -- routes through FocusAuthority so the keyboard
            // lane's gate actually opens before the Alt+Space keystroke below tries to use it.
            activateForClose(window)
            popupPhase = .awaitingActivateSettle(sentAt: Date())

        case .awaitingActivateSettle(let sentAt):
            guard Date().timeIntervalSince(sentAt) >= 0.3 else { return }
            guard let ownerId = popupOwnerWindowId, let window = registry.window(forWindowId: ownerId) else {
                beginAboutCleanup(session: session, registry: registry)
                return
            }
            sendAltSpace(to: window)
            print("[popup] sent Alt+Space to windowId=\(ownerId)")
            popupPhase = .awaitingPopupCreate(sentAt: Date())

        case .awaitingPopupCreate(let sentAt):
            let currentIds = Set(registry.windowSnapshots().map(\.windowId))
            let newIds = currentIds.subtracting(popupWindowIdsBeforeKeystroke)
            if let located = newIds.first(where: { registry.attachedOwner(forWindowId: $0) == popupOwnerWindowId }) {
                popupWindowId = located
                popupAppeared = true
                popupAttachedAsChild = true
                popupCreatedAt = windowCreateTimestamps[located]
                let snap = registry.windowSnapshots().first { $0.windowId == located }
                print("[popup] popup appeared: windowId=\(located) title=\"\(snap?.title ?? "")\" ownerWindowId=\(registry.attachedOwner(forWindowId: located).map(String.init) ?? "nil")")
                popupPhase = .awaitingEscapeSettle(popupWindowId: located, sentAt: Date())
            } else if Date().timeIntervalSince(sentAt) >= Self.popupCreatePollTimeout {
                // Multi-round mode only (`WINDOW_SMOKE_POPUP_SAMPLES` > 1): ONE re-activate
                // retry before the round is counted failed. A round boundary is the one place
                // this scenario's "the About window keeps focus" assumption can legitimately
                // have lapsed (anything at all could have taken focus on the host between
                // rounds), and a lost Alt+Space is indistinguishable from a lost focus from
                // here -- so the retry re-runs the real gated activate leg and then the
                // ordinary 0.3s-settle-then-Alt+Space path, rather than blind-resending the
                // keystroke into whatever now holds focus. Deliberately NOT applied at the
                // default N==1: that path stays byte-identical to every prior run.
                if popupSamplesTotal > 1, !popupCreateRetried, let ownerId = popupOwnerWindowId,
                   let ownerWindow = registry.window(forWindowId: ownerId)
                {
                    popupCreateRetried = true
                    print("[popup] round \(popupRoundResults.count + 1)/\(popupSamplesTotal): no owner-attached "
                        + "window within 5s of Alt+Space -- one re-activate retry (new windowIds observed: \(newIds.sorted()))")
                    activateForClose(ownerWindow)
                    popupPhase = .awaitingActivateSettle(sentAt: Date())
                    return
                }
                popupAppeared = false
                print("[popup] FAILED: no new owner-attached window appeared within 5s of Alt+Space (new windowIds observed: \(newIds.sorted()))")
                recordPopupRound()
                beginAboutCleanup(session: session, registry: registry)
            }

        case .awaitingEscapeSettle(let popupWindowId, let sentAt):
            // adr/0010 §5: the popup's own first-content latency is informational this run
            // (plan §4 W4's ≤100ms p95 gate needs real n>1 data) -- recorded once, here,
            // rather than blocking this phase on it ever actually becoming true (a popup
            // that never paints, e.g. an empty separator-only menu, must not stall the whole
            // scenario waiting for content that may legitimately never arrive).
            if popupFirstContentAt == nil,
               registry.windowSnapshots().first(where: { $0.windowId == popupWindowId })?.hasDisplayedContent == true
            {
                popupFirstContentAt = Date().timeIntervalSince(startTime)
                if let created = popupCreatedAt, let firstContent = popupFirstContentAt {
                    let latencyMs = (firstContent - created) * 1000
                    // The n>1 wording only holds for the one-shot: once
                    // `WINDOW_SMOKE_POPUP_SAMPLES` > 1 this run IS the n>1 data, and
                    // `finish()`'s own summary gates on the p95 of these very samples. The
                    // N==1 branch is byte-identical to every prior run's line.
                    if popupSamplesTotal > 1 {
                        print("[popup] round \(popupRoundResults.count + 1)/\(popupSamplesTotal) "
                            + "WindowCreate→first-content latency: \(String(format: "%.1f", latencyMs))ms")
                    } else {
                        print("[popup] WindowCreate→first-content latency: \(String(format: "%.1f", latencyMs))ms (informational -- plan §4 W4's ≤100ms p95 gate needs n>1 data)")
                    }
                }
            }
            guard Date().timeIntervalSince(sentAt) >= 0.3 else { return }
            guard let window = registry.window(forWindowId: popupWindowId) else {
                beginAboutCleanup(session: session, registry: registry)
                return
            }
            sendEscape(to: window)
            print("[popup] sent Escape to windowId=\(popupWindowId)")
            popupEscapeSent = true
            popupPhase = .awaitingEscapeClose(popupWindowId: popupWindowId, sentAt: Date())

        case .awaitingEscapeClose(_, let sentAt):
            if popupClosedAt != nil {
                print("[popup] WindowDelete received within 3s of Escape")
                recordPopupRound()
                // `WINDOW_SMOKE_POPUP_SAMPLES`: the ONLY path that re-arms is this one -- a
                // round that closed cleanly. Every other terminal path (create-poll exhausted,
                // Escape never closed the popup) records its failed sample and funnels
                // straight to the About cleanup, preserving the team-lead review invariant
                // that every terminal path goes through `beginAboutCleanup` exactly once,
                // now scoped to "after the FINAL round" rather than "after the only round".
                if popupRoundResults.count < popupSamplesTotal, popupOwnerWindowId.flatMap({ registry.window(forWindowId: $0) }) != nil {
                    beginPopupRound(registry: registry)
                } else {
                    beginAboutCleanup(session: session, registry: registry)
                }
            } else if Date().timeIntervalSince(sentAt) >= Self.popupEscapeClosePollTimeout {
                print("[popup] FAILED to receive WindowDelete within 3s of Escape")
                recordPopupRound()
                beginAboutCleanup(session: session, registry: registry)
            }

        case .awaitingReArmSettle(let sentAt):
            guard Date().timeIntervalSince(sentAt) >= Self.popupReArmSettle else { return }
            guard let ownerId = popupOwnerWindowId, let window = registry.window(forWindowId: ownerId) else {
                beginAboutCleanup(session: session, registry: registry)
                return
            }
            sendAltSpace(to: window)
            print("[popup] round \(popupRoundResults.count + 1)/\(popupSamplesTotal): sent Alt+Space to windowId=\(ownerId)")
            popupPhase = .awaitingPopupCreate(sentAt: Date())

        case .awaitingAboutClose(let sentAt):
            if popupAboutClosedAt != nil {
                popupAboutCloseResult = true
                print("[popup] About-window cleanup: WindowDelete received within 5s of SC_CLOSE")
                popupPhase = .done
            } else if Date().timeIntervalSince(sentAt) >= Self.popupAboutClosePollTimeout {
                popupAboutCloseResult = false
                print("[popup] About-window cleanup FAILED: no WindowDelete within 5s of SC_CLOSE")
                popupPhase = .done
            }

        case .done:
            break
        }
    }

    /// adr/0014 §6 (`WINDOW_SMOKE_TRAY_CLICK=1`, tray-scenario prereq): one left click on one
    /// live tray icon, once per run.
    ///
    /// Arming condition: the tray scenario's own icon evidence -- `realIconMaxObserved >= 1`
    /// AND `liveCount >= 1` -- plus a live key in this harness's own `liveNotifyIconKeys`.
    /// Read these precisely: `realIconMaxObserved` is a SESSION-WIDE latch ("at least one icon
    /// in this session held a real remote bitmap at some point", possibly a different icon,
    /// possibly already deleted), and `liveCount` says a status item exists right now. Neither
    /// says the icon actually clicked below is currently showing a real bitmap, and this
    /// scenario does not need it to: what it asserts is the SEND path (message sequence, key
    /// fidelity, queue admission), none of which depends on the clicked icon's pixels. The
    /// pair is used only to keep the click away from a session where the tray pipeline never
    /// worked at all -- that stricter, per-icon claim is `WINDOW_SMOKE_TRAY`'s own gate, not
    /// this one's.
    ///
    /// The click goes through `RemoteWindowRegistry.debugSimulateTrayClick`, which enters
    /// `TrayStatusController.handleLeftClick(tag:)` with the same packed tag the live
    /// `NSStatusBarButton` carries -- the real path, with AppKit's own event delivery as the
    /// ONLY thing skipped (there is no supported way to synthesize a menu-bar click for
    /// another process's status item). The liveness re-check, the counters, and the registry's
    /// two-PDU send all run exactly as they would for a user's click.
    private func runTrayClickScenario(session: CRSession, registry: RemoteWindowRegistry) {
        guard trayClickScenarioEnabled, !trayClickDone else { return }
        let diag = registry.trayDiagnostics()
        // With a tooltip filter, keep waiting until the NAMED icon is live (the lab driver's
        // own icon appears seconds after the session's standing ones); without one, first
        // live key, as before.
        let candidate: NotifyIconKey?
        if let filter = trayClickTooltipFilter {
            candidate = liveNotifyIconKeys.first { notifyIconTooltips[$0] == filter }
        } else {
            candidate = liveNotifyIconKeys.first
        }
        guard diag.realIconMaxObserved >= 1, diag.liveCount >= 1, let target = candidate else { return }

        trayClickTarget = target
        // Read BEFORE the click, so the delta `finish()` asserts on is attributable to this
        // click's own two posts and not to anything the session dropped earlier (e.g. an early
        // ClientExecute posted before the RAIL channel came up, which is a real and expected
        // occurrence this gate must not be confused by).
        outboundDroppedNoRailBeforeClick = session.outboundDroppedNoRailCount
        // adr/0014 §5/§6: the POST-side counter, snapshotted at the same instant and for the
        // same reason. The drain-side counter above can only see commands that reached the
        // drain -- a click whose two posts were rejected at the queue's door increments
        // nothing there, so on its own that gate stays green on zero PDUs ever enqueued.
        outboundPostDroppedBeforeClick = session.outboundPostDroppedCount
        print("[tray-click] target locked: windowId=\(target.windowId) notifyIconId=\(target.notifyIconId) "
            + "(liveCount=\(diag.liveCount) realIconMaxObserved=\(diag.realIconMaxObserved))")
        registry.debugSimulateTrayClick(windowId: target.windowId, notifyIconId: target.notifyIconId)
        trayClickDone = true
    }

    /// Closes out the round currently in flight (`WINDOW_SMOKE_POPUP_SAMPLES`) -- called from
    /// every one of `runPopupScenario`'s round-terminal paths, exactly once each, right
    /// before that path either re-arms or funnels into the About cleanup. Reads the same
    /// per-round fields `finish()`'s original single-round assertions already read
    /// (`popupAppeared`/`popupAttachedAsChild`/`popupClosedAt`/`popupCreatedAt`/
    /// `popupFirstContentAt`), so a round's recorded result can never diverge from what those
    /// assertions would have said about it.
    ///
    /// Silent (no print of its own) and harmless at the default N==1, where the recorded
    /// result is simply never read: `finish()`'s new sample summary is gated on N>1 precisely
    /// so a one-shot run's output stays byte-identical to every prior run's.
    private func recordPopupRound() {
        let latencyMs: Double?
        if let created = popupCreatedAt, let firstContent = popupFirstContentAt {
            latencyMs = (firstContent - created) * 1000
        } else {
            latencyMs = nil
        }
        popupRoundResults.append(PopupRoundResult(
            appeared: popupAppeared == true,
            attached: popupAttachedAsChild == true,
            closed: popupClosedAt != nil,
            latencyMs: latencyMs
        ))
    }

    /// Arms the NEXT round (`WINDOW_SMOKE_POPUP_SAMPLES` > 1 only): clears every per-round
    /// field so the next round measures itself and nothing else, recaptures
    /// `popupWindowIdsBeforeKeystroke` against the CURRENT window population (the round just
    /// finished deleted its own popup, and the "only count windowIds that appeared AFTER the
    /// keystroke" discipline the original one-shot established has to be re-established per
    /// round, not inherited), and enters the re-arm settle -- which sends the next Alt+Space
    /// without re-running the activate leg (see `PopupPhase.awaitingReArmSettle`).
    private func beginPopupRound(registry: RemoteWindowRegistry) {
        popupWindowId = nil
        popupCreatedAt = nil
        popupFirstContentAt = nil
        popupAttachedAsChild = nil
        popupAppeared = nil
        popupEscapeSent = false
        popupClosedAt = nil
        popupCreateRetried = false
        popupWindowIdsBeforeKeystroke = Set(registry.windowSnapshots().map(\.windowId))
        print("[popup] round \(popupRoundResults.count + 1)/\(popupSamplesTotal): re-arming "
            + "(\(popupRoundResults.filter(\.ok).count)/\(popupRoundResults.count) rounds ok so far)")
        popupPhase = .awaitingReArmSettle(sentAt: Date())
    }

    /// Team-lead review: funnels every terminal path in `runPopupScenario` through one
    /// About-window cleanup leg. Sends a defensive Escape to the About window FIRST --
    /// team-lead's own instruction: "a lingering menu could eat the close" (a still-open
    /// system menu is effectively modal on the desktop; an SC_CLOSE sent to the owner while
    /// its own popup menu is still up risks being swallowed by the menu instead of reaching
    /// the window). This Escape targets the ABOUT window's own `RemoteWindow`, not the
    /// popup's -- deliberately: the popup may already be closed, may have never been
    /// located, or may reference a `RemoteWindow` this harness no longer has a handle to by
    /// the time a terminal path is reached, but keyboard input is FOCUS-addressed on the
    /// wire (adr/0012 §2, `CRSession.sendKeyDown`/`sendKeyUp` carry no windowId at all) --
    /// dispatching the Escape via ANY currently-valid local `RemoteWindow` produces the
    /// identical wire effect, and About is guaranteed to still exist at this point (its own
    /// close hasn't been requested yet). Idempotent/safe to call even if the popup already
    /// closed cleanly on its own (a redundant Escape with nothing open to dismiss is a
    /// harmless no-op, matching every other fire-and-forget outbound call this harness
    /// already makes).
    ///
    /// `WINDOW_SMOKE_POPUP_SAMPLES` > 1: still exactly one cleanup per RUN, not per round --
    /// it now runs after the FINAL round (or after whichever round first failed), which is
    /// how the "every terminal path funnels through here" invariant survives the round loop.
    private func beginAboutCleanup(session: CRSession, registry: RemoteWindowRegistry) {
        guard let ownerId = popupOwnerWindowId else {
            popupPhase = .done
            return
        }
        if let window = registry.window(forWindowId: ownerId) {
            sendEscape(to: window)
            print("[popup] sent defensive Escape to windowId=\(ownerId) before cleanup close (a lingering menu could eat the close)")
        }
        session.sendSysCommand(ownerId, command: SC.close)
        print("[popup] sent SC_CLOSE to windowId=\(ownerId) (cleanup -- avoids leaving a stale About window for a later WINDOW_SMOKE_CYCLES soak to lock onto)")
        popupAboutCloseTargetId = ownerId
        popupPhase = .awaitingAboutClose(sentAt: Date())
    }

    /// Alt+Space: About's system-menu shortcut. `RemoteWindowContentView.flagsChanged`/
    /// `keyDown`/`keyUp` are the same real AppKit dispatch path `sendSyntheticEnter`/
    /// `sendClick` already exercise (never a direct call into
    /// `RemoteWindowRegistry.handleInput`) -- macKeyCode 49 is `kVK_Space`; the wire
    /// translation (`CRSession.sendKeyDown`/`sendModifierKey`) only ever consumes the raw
    /// keyCode/CRModifierKey, never `NSEvent.characters`, so the exact character string
    /// carried by these synthetic events is inert (kept as literal spaces/empty for
    /// readability only).
    private func sendAltSpace(to window: NSWindow) {
        let macSpaceKeyCode: UInt16 = 49
        let timestamp = ProcessInfo.processInfo.systemUptime
        func flagsEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 0
            )
        }
        func keyEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: macSpaceKeyCode
            )
        }
        guard
            let optionDown = flagsEvent(.option),
            let spaceDown = keyEvent(.keyDown, flags: .option),
            let spaceUp = keyEvent(.keyUp, flags: .option),
            let optionUp = flagsEvent([])
        else {
            print("[popup] failed to construct synthetic Alt+Space events")
            return
        }
        window.sendEvent(optionDown)
        window.sendEvent(spaceDown)
        window.sendEvent(spaceUp)
        window.sendEvent(optionUp)
    }

    /// Escape: closes the popup. Same real-dispatch shape as `sendSyntheticEnter` (mac
    /// keyCode 53, `kVK_Escape`).
    private func sendEscape(to window: NSWindow) {
        let macEscapeKeyCode: UInt16 = 53
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: macEscapeKeyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: macEscapeKeyCode
            )
        else {
            print("[popup] failed to construct synthetic Escape events")
            return
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Shared by both legs: within `Self.moveResizePollTimeout` (3s) of `sentAt`, has any
    /// WindowUpdate- or remap-applied content rect recorded in `moveResizeObservedContentRects`
    /// matched `target` -- and, once matched, did any LATER recorded content rect in the same
    /// leg diverge from `target` again (ping-pong)? Returns `nil` while the leg is still within
    /// budget and not yet resolved either way (neither matched-and-settled nor timed out) -- the
    /// caller polls this once per tick until it resolves.
    ///
    /// **M1 L9 (adr/0015 §6, owner ruling U6) changed what "matched" means, in three ways.** The
    /// pre-M1 judgement was "within ±1 per axis", compared partly in mac points; all three
    /// changes are the ADR's, not this harness's:
    ///
    ///  1. **The unit is remote px** (§6.1). Every comparison now happens after conversion into
    ///     Windows space through the session's frozen topology. At today's `rasterScale == 1` the
    ///     numbers are identical to the old ones, which is precisely why the unit had to be
    ///     pinned before a 2x session exists to disambiguate it.
    ///  2. **The tolerance is `MoveResizeGate.toleranceInRemotePixels` = 0** -- owner ruling U6,
    ///     with `docs/plans/phase3.md:131` as the re-open path if a live run proves it unreachable.
    ///     This is a tightening as well as a unit change; see that constant's own note.
    ///  3. **Every leg asserts a PAIR** (§6.3): the rect comparison plus the single-POINT reverse
    ///     mapping of the same target's top-left corner, which travels a code path with no
    ///     `- height` term and therefore has failure modes no rect round-trip can see. The leg
    ///     fails if either half fails, and the outcome names which.
    ///
    /// The deduction record §6.2 requires rides along in `MoveResizeLegOutcome.detail` -- see
    /// `deductionsText(windowId:target:in:)`, which is evaluated at the comparison, not summarised
    /// from an earlier moment.
    ///
    /// Team-lead review round 6 (2026-08-23, real-host run: position round-trip PERFECT,
    /// residual `matched=false` was size-only): `matchPositionOnly` controls whether
    /// `width`/`height` participate in the match/oscillation check at all. The move leg
    /// passes `true` -- for a pure move, size is legitimately the SERVER's prerogative (this
    /// run's own evidence: the server remapped the surface mid-move, 536x521 -> 522x514,
    /// entirely independent of anything this client asked for), so holding the move leg to
    /// the PRE-move size would fail it on a dimension it was never actually testing. The
    /// resize leg keeps `false` (full-rect matching) -- that leg's whole point IS size.
    ///
    /// Team-lead review round 7 (2026-08-23, real-host run: wire perfect AGAIN, yet
    /// position-only still reported `matched=false`): mac-space Y ENTANGLES height --
    /// `WindowGeometry.macRect`'s own formula is `y = primaryHeightInPoints - windowsY/s -
    /// height/s`, so when round 6's own remap-on-move finding changes a rect's height mid-leg,
    /// its mac-space Y shifts too even though the underlying Windows-space TOP edge never moved
    /// at all (this run: target computed at h=521 gave mac y=797; the observed rect, remapped to
    /// h=514, gave mac y=804 for the IDENTICAL Windows-space top=122). Comparing raw mac-space
    /// `x`/`y` was therefore comparing two DIFFERENT physical quantities whenever height changed
    /// -- not a false positive from a genuine position error, but a coordinate-representation
    /// artifact. Fixed by converting BOTH `target` and each observed rect through the existing,
    /// already-tested `WindowGeometry.windowsRect(from:in:)` (never a second, ad hoc
    /// coordinate-math implementation here, matching every other geometry boundary crossing in
    /// this project) and comparing the resulting Windows-space `x`/`y` (top-left, height-invariant
    /// by construction: each rect's own height is baked into ITS OWN conversion, so two rects that
    /// agree on the Windows-space top edge always compare equal regardless of what their heights
    /// happen to be). Round 7 scoped that to `matchPositionOnly`; **M1 L9 extended it to the
    /// full-rect leg too**, because §6.1 requires one comparison space for both -- at
    /// `rasterScale == 1` the full-rect numbers are unchanged by that move (a leg whose size must
    /// match anyway has no entanglement left to expose), so what changed is the unit's
    /// provenance, not any verdict this hardware can produce.
    ///
    /// `WindowSmokeGateSelfTest.positionOnlyIsHeightInvariantInWindowsSpace` is the offline pin
    /// for round 7's finding -- previously the property was argued in this comment and asserted
    /// nowhere.
    private func evaluateMoveResizeLeg(
        windowId: UInt32, target: NSRect, sentAt: Date, matchPositionOnly: Bool
    ) -> MoveResizeLegOutcome? {
        // M1 L9: the anchor comes from the SESSION's frozen snapshot -- the same topology read the
        // desktop size was derived from (adr/0015 §5.A.4) -- and never from a fresh `NSScreen`
        // read, which is the pre-M1 defect this milestone deletes (§5.A.5 listed this exact line
        // as one of the four read sites). `nil` here is a real, nameable state (no usable display,
        // or a freeze that never happened), and the discipline for it is the project-wide one:
        // decline and say so, never fabricate a coordinate from a substituted height.
        guard let topology = displayTopology.sessionSnapshot else {
            return MoveResizeLegOutcome(
                rectCheckPassed: false, pointCheckPassed: false,
                oscillation: .unjudgeable(observations: moveResizeObservedContentRects.count),
                detail: "no frozen session topology (adr/0015 §5.A.6) -- the leg cannot be judged in "
                    + "remote px at all, so it is reported failed rather than compared against a "
                    + "substituted primary height"
            )
        }
        func macRect(_ r: NSRect) -> MacRect {
            MacRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
        }
        let targetMacRect = macRect(target)
        func verdict(_ observed: NSRect) -> MoveResizeGate.LegVerdict {
            MoveResizeGate.evaluate(
                observed: macRect(observed), target: targetMacRect, in: topology,
                positionOnly: matchPositionOnly
            )
        }
        let contentRects = moveResizeObservedContentRects.map(\.contentRect)
        // The SEARCH and the oscillation scan run on the RECT half alone -- deliberately, and this
        // is the round-6/7 logic preserved verbatim except for its unit and tolerance. The point
        // half is then judged on whichever rect the rect half selected, so the two named results
        // always describe ONE observation (adr/0015 §6.3's "for the same target"). Searching on
        // the conjunction instead would let a broken point path silently redefine which rect the
        // rect half was talking about.
        guard let firstMatchIndex = contentRects.firstIndex(where: { verdict($0).rectCheckPassed }) else {
            if Date().timeIntervalSince(sentAt) >= Self.moveResizePollTimeout {
                // Report against the LAST observed rect: it is the server's most recent word on
                // this window, and adr/0015 §6.3 requires the failure to name WHICH of the paired
                // halves failed rather than only that the leg did. Both halves are still judged on
                // that same rect -- including the case where the point half agrees with a target
                // the rect half did not reach, which is itself a finding worth printing.
                guard let last = contentRects.last else {
                    return MoveResizeLegOutcome(
                        rectCheckPassed: false, pointCheckPassed: false, oscillation: .unjudgeable(observations: 0),
                        detail: "no geometry-carrying WindowUpdate/WindowCreate (nor a surface remap) was observed for this leg at all "
                            + "-- neither half of the paired assertion had an observation to judge; "
                            + deductionsText(windowId: windowId, target: targetMacRect, in: topology, legSentAt: sentAt)
                    )
                }
                let failed = verdict(last)
                return MoveResizeLegOutcome(
                    rectCheckPassed: failed.rectCheckPassed, pointCheckPassed: failed.pointCheckPassed,
                    oscillation: .unjudgeable(observations: contentRects.count),
                    detail: "\(failed.pairedVerdictText) \(failed.deltaText) (judged against the LAST of "
                        + "\(contentRects.count) observed rect(s), sources in order: \(moveResizeObservedContentRects.map(\.source).joined(separator: ",")) "
                        + "-- the last is a \(moveResizeObservedContentRects.last?.source ?? "?") observation); "
                        + deductionsText(windowId: windowId, target: targetMacRect, in: topology, legSentAt: sentAt)
                )
            }
            return nil
        }
        let matchedVerdict = verdict(contentRects[firstMatchIndex])
        let oscillation = MoveResizeGate.oscillationVerdict(
            rectPassedPerObservation: contentRects.map { verdict($0).rectCheckPassed }
        )
        let oscillated = oscillation.isOscillated
        // A brief settle window after the first match, so a late-arriving divergent
        // WindowUpdate still has a chance to be observed as oscillation before this leg
        // resolves -- unless oscillation has already been directly observed, in which case
        // there's nothing left to wait for.
        guard oscillated || Date().timeIntervalSince(sentAt) >= min(Self.moveResizePollTimeout, 1.0) else {
            return nil
        }
        return MoveResizeLegOutcome(
            rectCheckPassed: matchedVerdict.rectCheckPassed, pointCheckPassed: matchedVerdict.pointCheckPassed,
            oscillation: oscillation,
            detail: "\(matchedVerdict.pairedVerdictText) \(matchedVerdict.deltaText) (matched on observation "
                + "#\(firstMatchIndex + 1) of \(contentRects.count), a \(moveResizeObservedContentRects[firstMatchIndex].source) observation; "
                + "sources in order: \(moveResizeObservedContentRects.map(\.source).joined(separator: ","))); "
                + deductionsText(windowId: windowId, target: targetMacRect, in: topology, legSentAt: sentAt)
        )
    }

    /// adr/0015 §6.2's deduction record, evaluated AT THE MOMENT of the comparison it is printed
    /// next to -- never summarised from an earlier moment, because the whole reason the clause
    /// exists is the observed mid-session remap (536x521 -> 522x514) that changes what
    /// `sizeCorrection(for:windowId:)` returns partway through a leg.
    ///
    /// **SCOPE, stated precisely because §6.2's word is 逐次 / "per comparison"** (rev-L9 M-3b):
    /// this runs once per leg **resolution** -- i.e. for the comparison that produced the verdict --
    /// not once for each of the intermediate, non-matching comparisons the poll loop makes. That is
    /// a deliberate narrower reading, and it is only defensible because of what covers the gap: the
    /// harness's own comparison deducts nothing (both rects come through the registry's corrected
    /// path), every geometry-carrying order already prints `[move-resize] raw RAIL geometry …` with
    /// the mapped size and implied correction of THAT moment, and the move leg prints
    /// `[move-resize] INFO: GFX-mapped size changed during the move leg` when the remap this clause
    /// was written for actually happens. A reader can therefore reconstruct any intermediate
    /// comparison's deductions from the log; they are not recorded on the verdict line itself.
    ///
    /// This harness's own comparison deducts NOTHING itself: it compares two rects that both went
    /// through the registry's already-corrected placement path. What it must not do is let that
    /// make the deductions invisible ("误差 0" would then be measuring our compensation table, not
    /// the coordinate contract), so the two the registry applies are reported here:
    ///
    ///  * **`sizeCorrection` = GFX mapped size − accumulated RAIL size** (`RemoteWindowRegistry.
    ///    swift:1621`), printed together with **the mapped size current at this comparison** --
    ///    §6.2 requires both, because a deduction derived from mapped size is unreadable without
    ///    the mapped size it came from.
    ///  * **the outbound left-border deduction** (`WindowGeometry.clientWindowMoveLeft`, F6 (a)),
    ///    reported as MEASURED: the Windows-space left this leg asked for, minus the `left` the
    ///    send path actually put on the wire. Deriving it from the observed send rather than
    ///    restating the constant keeps a single source for that number (U5 = record-only forbids
    ///    this lane from moving or duplicating it) and means this line reports the truth even if
    ///    W3 re-measures the constant.
    private func deductionsText(
        windowId: UInt32, target: MacRect, in topology: DisplayTopology, legSentAt: Date
    ) -> String {
        let mapped = registry.debugMappedSize(forWindowId: windowId)
        let accumulated = registry.debugAccumulatedRailSize(forWindowId: windowId)
        let mappedText = mapped.map { "\(Int($0.width))x\(Int($0.height)) remote px" } ?? "unknown"
        let sizeCorrectionText: String
        if let mapped, let accumulated {
            sizeCorrectionText = "(dw=\(Int(mapped.width) - Int(accumulated.width)),"
                + "dh=\(Int(mapped.height) - Int(accumulated.height))) remote px"
        } else {
            sizeCorrectionText = "unknown (no mapped size and/or no accumulated RAIL size for this window)"
        }
        let targetWindowsRect = WindowGeometry.windowsRect(from: target, in: topology)
        let borderText: String
        if let sent = lastClientWindowMoveSent {
            let applied = targetWindowsRect.x - Double(sent.left)
            // Whether the quoted send belongs to THIS leg is stated, never assumed: a leg whose
            // own setFrame produced no send would otherwise silently borrow the previous leg's
            // number and present it as its own deduction.
            let provenance = sent.at >= legSentAt
                ? "this leg's own send"
                : "AN EARLIER LEG's send -- this leg produced no ClientWindowMove of its own"
            borderText = String(
                format: "%.3f remote px (measured: visible left %.3f minus the ClientWindowMove left=%d, ",
                applied, targetWindowsRect.x, sent.left
            ) + provenance + ")"
        } else {
            borderText = "n/a (no ClientWindowMove was observed for this window this run)"
        }
        return "deductions@comparison(adr/0015 §6.2): mappedSize=\(mappedText) "
            + "accumulatedRAILSize=\(accumulated.map { "\($0.width)x\($0.height) remote px" } ?? "unknown") "
            + "sizeCorrection=\(sizeCorrectionText) outboundLeftBorder=\(borderText)"
    }

    /// W4c deliverable 5: locates this run's own launched-app window once it's visible and
    /// has real painted content, sends the one synthetic input event `inputTestMode` calls
    /// for, and leaves `inputTestSentAt`/`inputTestWindowId` set for `finish()` to check
    /// against the `windowDelete` bookkeeping `tick()`'s drain closure above maintains.
    /// `elapsed >= 5` plus `hasDisplayedContent`, not either alone: gives the window a
    /// moment to exist as a RAIL order before checking, but the real gate is "has this
    /// registry actually leased and displayed a surface for it yet" -- clicking/typing at
    /// a window with no content yet would be testing something quite different (whether
    /// input works against a not-yet-painted window) from what this assertion is for.
    private func runInputTest(elapsed: TimeInterval, registry: RemoteWindowRegistry) {
        guard let inputTestMode else { return }

        if inputTestWindowId == nil, elapsed >= 5 {
            if let w = registry.windowSnapshots().first(where: { snap in
                snap.isVisible && snap.hasDisplayedContent && Self.matchesInputTestTarget(snap.title)
            }) {
                inputTestWindowId = w.windowId
                print("[input-test] target locked: windowId=\(w.windowId) title=\"\(w.title)\" mode=\(inputTestMode)")
            }
        }

        guard let windowId = inputTestWindowId, inputTestSentAt == nil else { return }
        guard let window = registry.window(forWindowId: windowId) else { return }

        // User-reported "clicks don't work" review round: verify the actual root cause
        // (a borderless NSWindow defaulting to canBecomeKey/canBecomeMain == false, fixed
        // in RemoteWindow.swift's new RemoteWindowBackingWindow subclass) is really fixed,
        // not just assumed fixed -- both halves matter: canBecomeKey alone doesn't prove
        // -makeKey actually works (AppKit could still refuse for some other reason), and
        // isKeyWindow alone after makeKey() doesn't prove canBecomeKey was the gate that
        // used to block it.
        let canBecomeKey = window.canBecomeKey
        // -makeKey() alone (Apple's own doc note) does not reliably promote a window that
        // isn't already the frontmost among this app's own windows -- and this harness
        // routinely has a dozen-plus tracked RemoteWindows open at once (stale leftovers
        // from prior runs sharing the same long-lived lab session), so the input-test's own
        // target is essentially never already frontmost. -makeKeyAndOrderFront: is the
        // reliable one, and -- not incidentally -- is exactly what the real production path
        // already calls (RemoteWindow.activateLocally(), from RemoteWindowRegistry's own
        // click-to-activate handling): this test should exercise the same call the real app
        // makes, not a different, weaker one.
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        keyWindowCheckResult = (
            passed: canBecomeKey && isKeyAfterMakeKey,
            detail: "windowId=\(windowId): canBecomeKey=\(canBecomeKey), isKeyWindow after makeKeyAndOrderFront=\(isKeyAfterMakeKey)"
        )
        print("[input-test] key-window check: \(keyWindowCheckResult!.detail)")

        inputTestSentAt = elapsed
        switch inputTestMode {
        case .click:
            sendSyntheticClick(to: window)
        case .enter:
            sendSyntheticEnter(to: window)
        case .cmdmap:
            // adr/0011 §5 item 5: the scaffold's single Cmd+C unless the live battery is
            // switched on, in which case the six-chord script below takes over (armed here,
            // dispatched one chord per tick by `runInputScript` -- a single-shot send cannot
            // express the ~0.4s inter-chord gaps a real host needs).
            if cmdMapLiveActive {
                armCmdMapLiveScript(windowId: windowId)
            } else {
                sendSyntheticCmdMap(to: window)
            }
        case .ime:
            armImeScript(windowId: windowId)
        }
    }

    /// The input-test target-lock predicate. `WINDOW_SMOKE_INPUT_TARGET_TITLE`, when set,
    /// replaces the original hardcoded winver-About heuristic wholesale (not "in addition
    /// to"): a run that names a target means that target, and silently falling back to an
    /// About window that happens to be lying around from an earlier run is exactly the
    /// stale-window contamination class this file has already paid for three times
    /// (`moveResizeCloseTargetId`'s own doc comment). Unset keeps the original two-language
    /// title match, unchanged.
    private static func matchesInputTestTarget(_ title: String) -> Bool {
        if let inputTargetTitleSubstring {
            return title.localizedCaseInsensitiveContains(inputTargetTitleSubstring)
        }
        return title.localizedCaseInsensitiveContains("about") || title.contains("关于")
    }

    /// adr/0011 §5 item 5's SCAFFOLD (offline scope this round -- see `InputTestMode.cmdmap`'s
    /// own doc comment): a real Cmd-down flagsChanged, then a 'c' keyDown/keyUp pair (with
    /// `charactersIgnoringModifiers: "c"`), then Cmd-up flagsChanged -- exactly the physical
    /// event sequence `CommandKeyMapper` expects for the Cmd+C row of adr/0011 §3's table.
    /// Dispatched via `NSWindow.sendEvent(_:)`, same as `sendClick(to:at:)`/
    /// `sendSyntheticEnter(to:)` above, so it exercises the real capture path end to end.
    private func sendSyntheticCmdMap(to window: NSWindow) {
        print("[input-test] synthesizing Cmd+C (mac keyCode 8) -- scaffold only, no live assertion this round")
        let timestamp = ProcessInfo.processInfo.systemUptime
        let macCKeyCode: UInt16 = 8 // kVK_ANSI_C

        guard
            let cmdDown = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55 // kVK_Command
            ),
            let cKeyDown = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: macCKeyCode
            ),
            let cKeyUp = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: macCKeyCode
            ),
            let cmdUp = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55
            )
        else {
            print("[input-test] failed to construct synthetic Cmd+C events")
            return
        }
        window.sendEvent(cmdDown)
        window.sendEvent(cKeyDown)
        window.sendEvent(cKeyUp)
        window.sendEvent(cmdUp)
    }

    // MARK: - Scripted input batteries (adr/0011 §5 items 5/6/7)

    /// adr/0011 §5 item 5's LIVE battery (`WINDOW_SMOKE_CMDMAP_LIVE=1`, see that switch's own
    /// doc comment). Arms the six-chord script against the already-locked, already-focused
    /// input-test target -- a remote Notepad holding a seeded single-line file:
    ///
    ///   Cmd+A → Cmd+C → End → Cmd+V → Cmd+V → Cmd+S
    ///
    /// `End` is plain (no modifier) and load-bearing: Cmd+A leaves the whole line selected,
    /// so pasting straight away would REPLACE it and the file would end up holding the seed
    /// once, not three times. Collapsing the selection to the line end first makes both
    /// pastes append. Cmd+S saves the already-named file silently in place -- no Save-As
    /// dialog to steal focus, which is exactly why the scenario needs
    /// `WINDOW_SMOKE_APP_ARGS` to have opened a real file rather than an untitled buffer.
    ///
    /// The chords go out as real `NSEvent`s through `NSWindow.sendEvent(_:)`, the same
    /// dispatch discipline `sendSyntheticCmdMap` established (flagsChanged Cmd-down, keyDown/
    /// keyUp carrying `charactersIgnoringModifiers`, flagsChanged Cmd-up) -- never a direct
    /// `RemoteWindowRegistry.handleInput` call, so `RemoteWindowContentView` ->
    /// `CommandKeyMapper` -> the wire is all genuinely exercised. Operator note (adr/0011
    /// §1's mixing rule): the chords only take the scancode path while the Mac's CURRENT
    /// keyboard input source is ASCII-capable -- a composing CJK source would hand the
    /// letter keys to `interpretKeyEvents` instead, which is the `.ime` battery's lane, not
    /// this one's.
    private func armCmdMapLiveScript(windowId: UInt32) {
        guard let seed = cmdMapSeed else {
            // Already reported loudly at startup (`applicationDidFinishLaunching`) and gated
            // in `finish()` -- nothing is dispatched, deliberately: six chords against a file
            // whose expected content this run cannot state would mutate the host's seed file
            // while proving nothing.
            inputScriptComplete = true
            return
        }
        let expected = String(repeating: seed, count: 3)
        print("[cmdmap-live] seed=\"\(seed)\"")
        let gap: TimeInterval = 0.4
        armInputScript(
            tag: "[cmdmap-live]",
            windowId: windowId,
            settle: 2.0,
            steps: [
                // kVK_ANSI_A / _C / _V / _S and kVK_End -- standard, stable AppKit virtual
                // keycodes (physical position, not layout-dependent), same numbering space
                // `sendSyntheticCmdMap`/`sendSyntheticEnter` already use.
                InputScriptStep(label: "Cmd+A (select all)", gapBefore: gap,
                                action: .chord(macKeyCode: 0, characters: "a", command: true), markerAfter: nil),
                InputScriptStep(label: "Cmd+C (copy)", gapBefore: gap,
                                action: .chord(macKeyCode: 8, characters: "c", command: true), markerAfter: nil),
                InputScriptStep(label: "End (collapse selection to line end)", gapBefore: gap,
                                action: .chord(macKeyCode: 119, characters: "\u{F72B}", command: false), markerAfter: nil),
                InputScriptStep(label: "Cmd+V (paste 1/2)", gapBefore: gap,
                                action: .chord(macKeyCode: 9, characters: "v", command: true), markerAfter: nil),
                InputScriptStep(label: "Cmd+V (paste 2/2)", gapBefore: gap,
                                action: .chord(macKeyCode: 9, characters: "v", command: true), markerAfter: nil),
                InputScriptStep(
                    label: "Cmd+S (save in place)", gapBefore: gap,
                    action: .chord(macKeyCode: 1, characters: "s", command: true),
                    markerAfter: "[cmdmap-live] sequence complete; expected file content = seed x3; "
                        + "expected-utf8-hex=\(Self.utf8Hex(expected))"
                ),
            ]
        )
    }

    /// adr/0011 §5 item 6's IME round-trip battery (`WINDOW_SMOKE_INPUT_TEST=ime`). ONE
    /// composed commit of `Self.imeCommitText` delivered through the target window's content
    /// view's `NSTextInputClient.insertText(_:replacementRange:)` -- the exact method a real
    /// macOS input method calls when a composition commits, so the path under test is the
    /// shipped one (`RemoteWindowContentView.insertText` -> `.unicodeText` ->
    /// `UnicodeInputDegradationGate` -> `FocusAuthority` -> `CRSession.sendUnicodeText`),
    /// not a shortcut into `RemoteWindowRegistry.handleInput` that would skip most of it.
    /// Then Cmd+S, through the same synthesized-chord helper the cmdmap battery uses.
    ///
    /// Operator note: no real input method needs to be SELECTED on the Mac for this -- the
    /// commit is delivered programmatically to the very method an input method would call,
    /// which is the whole point. Run it with an ordinary ASCII-capable source active, so the
    /// Cmd+S that follows still takes the scancode path (adr/0011 §1's mixing rule hands
    /// non-always-scancode keys to `interpretKeyEvents` while a composing source is active,
    /// and a Cmd+S swallowed there would never save the file the readback pass is going to
    /// read).
    private func armImeScript(windowId: UInt32) {
        let text = Self.imeCommitText
        // adr/0011 §5 item 6 says fifty characters; this asserts the constant still IS fifty
        // rather than trusting a comment (an editor auto-correcting one full-width character
        // into two, or eating the em-dash pair, would otherwise silently weaken the probe).
        precondition(text.unicodeScalars.count == 50, "adr/0011 §5 item 6's probe string must be exactly 50 scalars")
        armInputScript(
            tag: "[ime]",
            windowId: windowId,
            settle: 2.0,
            steps: [
                InputScriptStep(
                    label: "IME commit (50 scalars, NSTextInputClient.insertText)", gapBefore: 0.4,
                    action: .imeCommit(text: text),
                    markerAfter: "[ime] committed 50 scalars; expected-utf8-hex=\(Self.utf8Hex(text))"
                ),
                InputScriptStep(label: "Cmd+S (save in place)", gapBefore: 0.5,
                                action: .chord(macKeyCode: 1, characters: "s", command: true), markerAfter: nil),
            ]
        )
    }

    /// adr/0011 §5 item 7's degradation half (`WINDOW_SMOKE_UNICODE_DEGRADE=1`). TWO short,
    /// distinct commits through the SAME real `NSTextInputClient` path the `.ime` battery
    /// uses -- distinct so a reader of `UnicodeInputDegradationGate`'s counters can tell "two
    /// commits arrived" from "one commit was double-counted", short because none of this text
    /// is ever supposed to reach the wire (the session was started with
    /// `forceUnicodeInputUnsupported`, so the gate drops both). No save leg: there is nothing
    /// on the host to save.
    private func armUnicodeDegradeScript(windowId: UInt32) {
        armInputScript(
            tag: "[unicode-degrade]",
            windowId: windowId,
            settle: 0.5,
            steps: [
                InputScriptStep(label: "IME commit 1/2 (expected dropped + warned once)", gapBefore: 0.4,
                                action: .imeCommit(text: "降级一"), markerAfter: nil),
                InputScriptStep(label: "IME commit 2/2 (expected dropped, NOT warned again)", gapBefore: 0.3,
                                action: .imeCommit(text: "降级二"), markerAfter: nil),
            ]
        )
    }

    /// Shared arming for all three batteries above -- records the script and starts the clock
    /// for its first step. Never overwrites an already-armed script (the three scenarios are
    /// mutually exclusive per run; see `applicationDidFinishLaunching`'s own warning).
    private func armInputScript(tag: String, windowId: UInt32, settle: TimeInterval, steps: [InputScriptStep]) {
        guard inputScriptSteps.isEmpty else { return }
        inputScriptTag = tag
        inputScriptWindowId = windowId
        inputScriptSettle = settle
        inputScriptSteps = steps
        inputScriptIndex = 0
        inputScriptNextStepAt = Date().addingTimeInterval(steps.first?.gapBefore ?? 0)
        print("\(tag) armed: \(steps.count) step(s) against windowId=\(windowId), "
            + "\(String(format: "%.1f", settle))s settle after the last one")
    }

    /// Per-tick driver for whichever battery is armed -- one step per tick at most, gated on
    /// that step's own `gapBefore`, in the same "enum/array phase + per-tick driver called
    /// from the run loop" shape `runPopupScenario`/`runMaximizeScenario` already use. Once
    /// every step has been dispatched it holds the run open for `inputScriptSettle` seconds
    /// (the host's own disk write, for the batteries that end on Cmd+S) and then flips
    /// `inputScriptComplete`, which is what lets `tick()`'s deadline logic end the run.
    private func runInputScript(registry: RemoteWindowRegistry) {
        guard !inputScriptSteps.isEmpty, !inputScriptComplete else { return }

        if inputScriptIndex >= inputScriptSteps.count {
            guard let settleUntil = inputScriptSettleUntil, Date() >= settleUntil else { return }
            inputScriptComplete = true
            print("\(inputScriptTag) settled \(String(format: "%.1f", inputScriptSettle))s after the final step "
                + "(chords dispatched=\(inputScriptChordsDispatched), IME commits delivered=\(inputScriptCommitsDelivered))")
            return
        }

        let step = inputScriptSteps[inputScriptIndex]
        guard let due = inputScriptNextStepAt, Date() >= due else { return }
        guard let windowId = inputScriptWindowId, let window = registry.window(forWindowId: windowId) else {
            // The target vanished mid-script (a server-side close, a reconnect). Nothing left
            // to dispatch against; `finish()`'s own per-scenario gates report the shortfall.
            print("\(inputScriptTag) FAILED: target windowId=\(inputScriptWindowId.map(String.init) ?? "nil") "
                + "no longer exists -- \(inputScriptSteps.count - inputScriptIndex) step(s) never dispatched")
            inputScriptComplete = true
            return
        }

        print("\(inputScriptTag) step \(inputScriptIndex + 1)/\(inputScriptSteps.count): \(step.label)")
        switch step.action {
        case .chord(let macKeyCode, let characters, let command):
            if sendChord(to: window, macKeyCode: macKeyCode, characters: characters, command: command) {
                inputScriptChordsDispatched += 1
            }
        case .imeCommit(let text):
            // The cast is the assertion, not a convenience: `insertText(_:replacementRange:)`
            // only means anything here if it lands on the real `RemoteWindowContentView`
            // conformance (adr/0011 §2). A window whose content view is something else is a
            // structural change this scenario must fail on, loudly, rather than route around.
            guard let contentView = window.contentView as? RemoteWindowContentView else {
                inputScriptCastFailed = true
                print("\(inputScriptTag) FAILED: windowId=\(windowId)'s contentView is "
                    + "\(window.contentView.map { String(describing: type(of: $0)) } ?? "nil"), not RemoteWindowContentView "
                    + "-- cannot deliver an IME commit through the real NSTextInputClient path")
                inputScriptComplete = true
                return
            }
            // NSNotFound/0: the conventional "no replacement range" a committing input method
            // passes for a plain insertion (the same convention `selectedRange()`'s own
            // "unknown" answer uses on the other side of this protocol).
            contentView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            inputScriptCommitsDelivered += 1
        }
        if let marker = step.markerAfter {
            print(marker)
        }

        inputScriptIndex += 1
        if inputScriptIndex < inputScriptSteps.count {
            inputScriptNextStepAt = Date().addingTimeInterval(inputScriptSteps[inputScriptIndex].gapBefore)
        } else {
            inputScriptSettleUntil = Date().addingTimeInterval(inputScriptSettle)
        }
    }

    /// One synthesized chord, dispatched via `NSWindow.sendEvent(_:)` -- the same real
    /// capture path (`RemoteWindowContentView.flagsChanged`/`keyDown`/`keyUp` ->
    /// `RemoteWindowRegistry.handleInput`) `sendSyntheticCmdMap`/`sendAltSpace`/`sendEscape`
    /// already exercise, generalized over "which key, with or without Cmd". Returns whether
    /// the events were actually constructed and sent, so the caller's dispatched-count (which
    /// `finish()` gates on) can never overcount a chord AppKit refused to build.
    @discardableResult
    private func sendChord(to window: NSWindow, macKeyCode: UInt16, characters: String, command: Bool) -> Bool {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let flags: NSEvent.ModifierFlags = command ? [.command] : []
        let macCommandKeyCode: UInt16 = 55 // kVK_Command
        func flagsEvent(_ modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifierFlags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: macCommandKeyCode
            )
        }
        guard
            let keyDown = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: macKeyCode
            ),
            let keyUp = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: macKeyCode
            )
        else {
            print("\(inputScriptTag) failed to construct synthetic key events for macKeyCode=\(macKeyCode)")
            return false
        }
        if command {
            guard let commandDown = flagsEvent([.command]), let commandUp = flagsEvent([]) else {
                print("\(inputScriptTag) failed to construct synthetic Cmd flagsChanged events")
                return false
            }
            window.sendEvent(commandDown)
            window.sendEvent(keyDown)
            window.sendEvent(keyUp)
            // adr/0011 §3: the Cmd-up flagsChanged is what closes the chord on the WIRE
            // ledger too (`RemoteWindowRegistry.wireHeldModifiers`), which is why
            // `finish()` can assert "nothing stuck" as a structural invariant rather than a
            // hope -- a chord helper that skipped this would leave Ctrl held on the server.
            window.sendEvent(commandUp)
        } else {
            window.sendEvent(keyDown)
            window.sendEvent(keyUp)
        }
        return true
    }

    /// adr/0011 §5 item 7's degradation scenario driver (`WINDOW_SMOKE_UNICODE_DEGRADE=1`).
    /// Unlike the two batteries above it is NOT an `InputTestMode` -- it needs no particular
    /// app, no seeded file and no title heuristic, just any visible window with real content
    /// (the default winver About dialog does fine), so it does its own target lock and its
    /// own copy of `runInputTest`'s focus preamble rather than borrowing that mode's.
    /// Deliberately stands down when an `InputTestMode` is also set, so which scenario owns
    /// the shared script machine is deterministic rather than a race (see
    /// `applicationDidFinishLaunching`'s own warning line).
    private func runUnicodeDegradeScenario(elapsed: TimeInterval, registry: RemoteWindowRegistry) {
        guard unicodeDegradeScenarioEnabled, inputTestMode == nil else { return }
        guard inputScriptSteps.isEmpty, !inputScriptComplete, elapsed >= 5 else { return }
        // Same plausible-content band (150x80 remote px, `isInPlausibleContentBand`) `finish()`'s
        // own per-window size assertion and `focusRotationCandidateWindows` use -- never a
        // sliver/ghost window.
        guard let snapshot = registry.windowSnapshots().first(where: {
            $0.isVisible && $0.hasDisplayedContent && isInPlausibleContentBand($0)
        }), let window = registry.window(forWindowId: snapshot.windowId) else { return }

        // Identical to `runInputTest`'s preamble, and for the identical reason: an IME commit
        // is focus-addressed input like any other keystroke, so the window has to genuinely
        // be key before the commit is delivered, not merely visible.
        let canBecomeKey = window.canBecomeKey
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        keyWindowCheckResult = (
            passed: canBecomeKey && isKeyAfterMakeKey,
            detail: "windowId=\(snapshot.windowId): canBecomeKey=\(canBecomeKey), isKeyWindow after makeKeyAndOrderFront=\(isKeyAfterMakeKey)"
        )
        print("[unicode-degrade] target locked: windowId=\(snapshot.windowId) title=\"\(snapshot.title)\"")
        print("[unicode-degrade] key-window check: \(keyWindowCheckResult!.detail)")
        armUnicodeDegradeScript(windowId: snapshot.windowId)
    }

    /// Lowercase UTF-8 hex of `text`, the form both live batteries' `expected-utf8-hex`
    /// markers use. Hex, not the text itself: the external comparer reads back a file from
    /// the Windows host and has to compare BYTES (encoding, BOM and line-ending questions all
    /// belong to it), and a log line carrying raw CJK through several terminal/pipe layers is
    /// exactly where a silent transcoding would hide.
    private static func utf8Hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", Int($0)) }.joined()
    }

    /// Mouse half of deliverable 5: a real `NSEvent` mouseDown+mouseUp pair, dispatched via
    /// `NSWindow.sendEvent(_:)` so it exercises the same hit-testing and first-responder
    /// path a genuine trackpad click would -- not a direct call into
    /// `RemoteWindowContentView`'s own override methods, which would only prove those
    /// method bodies work, not that a real click actually reaches them. Target point:
    /// proportional (0.87, 0.94-from-the-top) of the window's own current content size --
    /// the task spec's own reference point for the "确定" (OK) button in winver.exe's About
    /// Windows dialog (~(466,489) in the dialog's usual ~536x521 size) -- computed
    /// proportionally, not as hardcoded pixels, so this still lands correctly if the
    /// dialog's actual size varies slightly by theme/DPI. "0.94-from-the-top" is converted
    /// to AppKit's bottom-left-origin/Y-up local coordinate convention here
    /// (`RemoteWindowContentView` does not override `isFlipped`): `localY = height * (1 -
    /// 0.94)`, landing near the bottom of the Y-up view, which is visually the bottom of
    /// the window -- exactly where the OK button actually sits.
    private func sendSyntheticClick(to window: NSWindow) {
        // User-reported "clicks don't work" review round: two-stage sequence, closer to a
        // real user's actual path -- a real user's first click on a background remote
        // window is very often *not* precisely on the control they eventually want; it
        // lands somewhere else in the window first (title area / background), and only a
        // second, deliberate click actually hits the target control. A single-click test
        // never exercised that "click somewhere else first" step at all, which is exactly
        // the step that depended on RemoteWindowBackingWindow's canBecomeKey/canBecomeMain
        // fix (a window that can't become key on its first click would behave differently
        // depending on whether anything is clicked on it beforehand).
        let size = window.contentView?.bounds.size ?? window.frame.size
        let backgroundPoint = NSPoint(x: size.width * 0.5, y: size.height * 0.85) // upper/background area, away from the OK button
        print("[input-test] synthesizing background click at window-local \(backgroundPoint) (window size \(size)) -- stage 1/2")
        sendClick(to: window, at: backgroundPoint)

        // A real gap, not zero: a genuine user's second click never lands in the same
        // run-loop turn as the first (human reaction time alone rules that out), and --
        // observed directly while developing this fix -- firing both click pairs back-to-
        // back with no gap at all made the remote session's own click handling miss the
        // second click entirely (the OK button never registered, no WindowDelete ever
        // arrived) even though both windowId=/canBecomeKey checks were passing by then.
        // 0.3s: comfortably human, comfortably inside the assertion's own 3s budget
        // (measured from inputTestSentAt, captured before this delay starts).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self != nil else { return }
            let localPoint = NSPoint(x: size.width * 0.87, y: size.height * (1 - 0.94))
            print("[input-test] synthesizing OK-button click at window-local \(localPoint) -- stage 2/2")
            self?.sendClick(to: window, at: localPoint)
        }
    }

    /// Shared by `sendSyntheticClick`'s two stages: one real `NSEvent` mouseDown+mouseUp
    /// pair, dispatched via `NSWindow.sendEvent(_:)` so it exercises the same hit-testing
    /// and first-responder path a genuine trackpad click would -- not a direct call into
    /// `RemoteWindowContentView`'s own override methods, which would only prove those
    /// method bodies work, not that a real click actually reaches them.
    private func sendClick(to window: NSWindow, at localPoint: NSPoint) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: localPoint, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: localPoint, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
            )
        else {
            print("[input-test] failed to construct synthetic mouse events")
            return
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Focus rotation scenario (WINDOW_SMOKE_FOCUS_ROTATION, task item 2): once the
    /// WINDOW_SMOKE_EXTRA_APPS multi-window setup has settled, round-robins
    /// `session.activateWindow(_:)` (the same fire-and-forget ClientActivate call the
    /// Phase 1 cycle soak uses -- see `tickCycles`) across the visible content windows and
    /// records whether/how fast `RemoteWindowRegistry.serverDesktopState().activeWindowId`
    /// converges to each target. Reuses the existing "new content windows since extraApps
    /// exec" settling check from `finish()`'s own multi-window assertion, rather than a
    /// second, separately-tuned readiness heuristic. Measurement only -- no hit-rate gating
    /// here (docs/plans/phase2.md §2 W1: "拿到真数据前不写策略"); `finish()` only asserts
    /// that the scenario actually ran its full N rotations.
    private func runFocusRotation(elapsed: TimeInterval, session: CRSession, registry: RemoteWindowRegistry) {
        guard focusRotationTotal > 0, !focusRotationDone else { return }

        if !focusRotationReady {
            guard extraAppsLaunched else { return }
            let candidates = focusRotationCandidateWindows(registry)
            let newContentWindows = candidates.filter { !windowIdsBeforeExtraApps.contains($0.windowId) }
            guard newContentWindows.count >= extraApps.count else { return }
            focusRotationReady = true
            focusRotationWindowIds = candidates.map(\.windowId)
            print("[focus-rotation] ready: \(focusRotationWindowIds.count) visible content window(s): \(focusRotationWindowIds)")
        }

        // Still waiting on the current rotation's convergence poll/timeout (drainNow()
        // resolves this) -- nothing to issue yet.
        guard focusRotationPendingTargetId == nil else { return }

        if focusRotationsIssued >= focusRotationTotal {
            focusRotationDone = true
            return
        }
        // 300ms inter-rotation settle (nil before the very first rotation -- that one
        // fires as soon as the scenario becomes ready, no wait needed).
        if let nextAllowedAt = focusRotationNextAllowedAt, Date() < nextAllowedAt { return }
        guard !focusRotationWindowIds.isEmpty else { return }

        let targetId = focusRotationWindowIds[focusRotationsIssued % focusRotationWindowIds.count]
        focusRotationsIssued += 1
        session.activateWindow(targetId)
        let sentAt = Date()
        focusRotationPendingTargetId = targetId
        focusRotationPendingSentAt = sentAt
        focusRotationPendingSoftDeadline = sentAt.addingTimeInterval(FocusAuthority.softDeadlineInterval)
        focusRotationPendingEventualDeadline = sentAt.addingTimeInterval(FocusAuthority.hardDeadlineInterval)
        print("[focus-rotation] rotation \(focusRotationsIssued)/\(focusRotationTotal): activating windowId=\(targetId)")
    }

    /// The round-robin candidate pool for `runFocusRotation` -- visible windows with real
    /// displayed content, same plausible-content band (150x80 remote px,
    /// `isInPlausibleContentBand`) `finish()`'s own per-window size assertion uses, sorted by
    /// windowId for a deterministic rotation order (window creation/arrival order is not
    /// guaranteed stable across a run).
    private func focusRotationCandidateWindows(_ registry: RemoteWindowRegistry) -> [RemoteWindowRegistry.WindowSnapshot] {
        registry.windowSnapshots()
            .filter { $0.isVisible && $0.hasDisplayedContent && isInPlausibleContentBand($0) }
            .sorted { $0.windowId < $1.windowId }
    }

    /// Keyboard half of deliverable 5: a real `NSEvent` keyDown+keyUp pair for the Return
    /// key (mac keyCode 36, `kVK_Return`), dispatched the same way as the click case above.
    /// Deliberately exercises the real WinPR translation path
    /// (`CRSession.sendKeyDown:`/`sendKeyUp:` -> `GetVirtualKeyCodeFromKeycode`/
    /// `GetVirtualScanCodeFromVirtualKeyCode`) end to end, rather than hand-constructing
    /// RDP_SCANCODE_RETURN (0x1C) directly and skipping that translation -- a translation
    /// bug in that path would go unnoticed by a test that bypassed it.
    private func sendSyntheticEnter(to window: NSWindow) {
        print("[input-test] synthesizing Return keyDown/keyUp (mac keyCode 36)")
        let macReturnKeyCode: UInt16 = 36
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: macReturnKeyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: macReturnKeyCode
            )
        else {
            print("[input-test] failed to construct synthetic key events")
            return
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// adr/0012 task item 3: shared by the cycle-close leg's lock (`tickCycles` Phase A) and
    /// its single retry -- makes `window` locally key and dispatches one real synthetic
    /// click at a neutral background point via the shared `sendClick(to:at:)` helper. Routes
    /// through `RemoteWindowContentView.mouseDown` -> `RemoteWindowRegistry.handleInput`'s
    /// real mouseButton path, exactly like a genuine trackpad click, rather than the old
    /// direct `session.activateWindow(_:)` call -- so this exercises the actual
    /// `FocusAuthority`-gated activation the production click-to-focus path uses, "by
    /// construction" (the keystroke sent afterward doesn't need its own separate focus
    /// confirmation anymore; see `cycleEnterAt`'s own doc comment). Deliberately a
    /// background point, not the OK button `sendSyntheticClick` targets -- this call's only
    /// job is to establish focus, not to close the window.
    private func activateForClose(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? window.frame.size
        sendClick(to: window, at: NSPoint(x: size.width * 0.5, y: size.height * 0.85))
    }

    /// Phase 2 W2 task item 2: `[style-dump]` line format -- id, WxH, title-or-"<empty>",
    /// style/styleEx as hex, owner (or "unset" if `WINDOW_ORDER_FIELD_OWNER`, 0x2, wasn't
    /// actually set on this specific order -- the field-presence bit `CRDPEvent.ownerWindowId`'s
    /// own doc comment requires checking before treating a bare 0 as authoritative). Style/
    /// styleEx are similarly only meaningful when `WINDOW_ORDER_FIELD_STYLE` (0x8) is set
    /// (gates both together, per `MacdowsCore.WindowModel.swift`'s own `WindowOrderField`,
    /// the canonical reference these bit values are duplicated from -- same "each layer
    /// duplicates narrowly" precedent `RemoteWindowRegistry.WindowOrderField` already
    /// follows). Per adr/0008 §0, every real WindowCreate observed in the six phase05
    /// samples sets both bits, so `"unset"`/`"n/a"` are expected to be rare in practice, not
    /// the common case -- printed explicitly anyway so a genuine gap is visible rather than
    /// silently rendered as a misleading `0`/`0x0`.
    private static func styleDumpLine(for event: CRDPEvent) -> String {
        let ownerFieldBit: UInt32 = 0x0000_0002 // WINDOW_ORDER_FIELD_OWNER
        let styleFieldBit: UInt32 = 0x0000_0008 // WINDOW_ORDER_FIELD_STYLE (gates style+styleEx)
        let hasOwner = event.fieldFlags & ownerFieldBit != 0
        let hasStyle = event.fieldFlags & styleFieldBit != 0
        let ownerText = hasOwner ? String(event.ownerWindowId) : "unset"
        let styleText = hasStyle ? String(format: "0x%08X", event.style) : "n/a"
        let styleExText = hasStyle ? String(format: "0x%08X", event.styleEx) : "n/a"
        let titleText = event.title.isEmpty ? "<empty>" : event.title
        return "[style-dump] id=\(event.windowId) \(event.windowWidth)x\(event.windowHeight) "
            + "title=\"\(titleText)\" style=\(styleText) styleEx=\(styleExText) owner=\(ownerText)"
    }

    /// Human-readable form of `MacdowsCore.ServerActiveWindow` for `[flow]`/`[focus-rotation]`
    /// log lines -- this type has no `CustomStringConvertible` conformance of its own (kept
    /// out of MacdowsCore's pure-logic surface deliberately; formatting is a presentation
    /// concern, not a state-machine one).
    private static func describe(_ truth: ServerActiveWindow) -> String {
        switch truth {
        case .window(let id): return String(id)
        case .desktopFocused: return "desktop"
        case .unmonitored: return "unmonitored"
        }
    }

    /// W4c review: nearest-rank percentile (e.g. `p == 0.95` for p95), used for the
    /// push-drain latency assertion in `finish()`. `nil` for an empty sample set rather
    /// than crashing or returning a made-up 0 -- callers treat that as "nothing to assert,"
    /// not as "latency was zero."
    private static func percentile(_ p: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[rank]
    }

    private func captureEvidence() {
        let outDir = (screenshotPath as NSString).deletingLastPathComponent
        if !outDir.isEmpty {
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        }

        // Best-effort only -- see this file's own header comment for why this reliably
        // fails under the repo's normal verification setup, and why `finish()` doesn't
        // trust this call's exit code either way.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", screenshotPath]
        do {
            try proc.run()
            proc.waitUntilExit()
            print("[evidence] screencapture -x (this process's own attempt) exit=\(proc.terminationStatus)")
        } catch {
            print("[evidence] screencapture failed to launch: \(error)")
        }

        // Corroborating second witness: our own process's actual on-screen window frames,
        // independent of anything RemoteWindowRegistry itself reports.
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let infoList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: AnyObject]] {
            let mine = infoList.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == myPID }
            print("[evidence] CGWindowListCopyWindowInfo: \(mine.count) window(s) owned by this process (pid \(myPID))")
            for w in mine {
                let name = (w[kCGWindowName as String] as? String) ?? "(no name)"
                let bounds = (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
                print("[evidence]   \"\(name)\" bounds=\(bounds)")
            }
        } else {
            print("[evidence] CGWindowListCopyWindowInfo returned nothing")
        }
    }

    /// H2 (W4b review): "the file exists" alone can't distinguish this run's own evidence
    /// from a stale file left over from an earlier run (the previous bug: `tookScreenshot`
    /// asserted only that the capture *routine* had executed, a tautology against its own
    /// unconditional flag-set, and a leftover file from a prior successful run could pass
    /// `fileExists` even if this run's own capture failed). Requires the file to actually
    /// look like fresh evidence: created after this process's own launch, a real PNG
    /// (correct 8-byte signature), and a plausible minimum size for a full-screen capture
    /// (a truncated/corrupt write would be far smaller).
    private func screenshotWasProducedByThisRun() -> (ok: Bool, detail: String) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: screenshotPath) else {
            return (false, "no file at \(screenshotPath)")
        }
        guard let modDate = attrs[.modificationDate] as? Date else {
            return (false, "\(screenshotPath) has no modification date")
        }
        guard modDate > startTime else {
            return (false, "\(screenshotPath) predates this run's own launch (mtime \(modDate) <= \(startTime!))")
        }
        guard let size = attrs[.size] as? Int, size > 100 * 1024 else {
            let size = (attrs[.size] as? Int) ?? -1
            return (false, "\(screenshotPath) is only \(size) bytes (expected > 100KB for a full-screen capture)")
        }
        guard let fh = FileHandle(forReadingAtPath: screenshotPath) else {
            return (false, "\(screenshotPath) could not be opened for reading")
        }
        defer { try? fh.close() }
        let header = fh.readData(ofLength: 8)
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(header) == pngSignature else {
            return (false, "\(screenshotPath) does not start with a PNG signature")
        }
        return (true, "\(screenshotPath) (\(size) bytes, mtime \(modDate))")
    }

    /// The plausible-content band every visible-window selection and assertion in this file
    /// shares, judged in REMOTE PX through the session's frozen topology (`SizeBand`). With no
    /// frozen topology nothing passes: the band cannot be judged in remote px at all, and
    /// comparing frame pt against remote-px constants (correct only at rasterScale 1) is the
    /// pre-C-2 defect this predicate exists to retire -- both exits (`finish()` and
    /// `finishCycles()`) report that state as their own failed check, so a selection that finds
    /// no candidate here never fails silently.
    private func isInPlausibleContentBand(_ snapshot: RemoteWindowRegistry.WindowSnapshot) -> Bool {
        guard let topology = displayTopology.sessionSnapshot else { return false }
        return SizeBand.isPlausibleContent(SizeBand.remotePixelSize(ofFrameSize: snapshot.frame.size, in: topology))
    }

    /// H3's generic plausible-content band over every visible window, asserted at BOTH exits
    /// (`finish()` and `finishCycles()`; review sizeband-r3 m-1: cycle mode used to assert only
    /// that a topology was frozen, never the windows themselves). The precondition check comes
    /// first and is unconditional; with no frozen topology nothing is judged in pt -- the
    /// windows are skipped and the failed precondition is the finding. Returns the frozen
    /// topology so `finish()`'s About anchor can judge against the same value.
    private func assertPlausibleContentBands(
        over visibleWindows: [RemoteWindowRegistry.WindowSnapshot], check: (Bool, String) -> Void
    ) -> DisplayTopology? {
        let topology = displayTopology.sessionSnapshot
        check(
            topology != nil,
            "size bands have a frozen session topology to convert NSWindow.frame pt into remote px "
                + "(adr/0015 §5.A.6: none frozen -- the per-window band checks below are skipped, not judged "
                + "in pt; on the single-run path the per-tick size-band selections also passed nothing)"
        )
        guard let topology else { return nil }
        for w in visibleWindows {
            let (px, detail) = SizeBand.describe(frameSize: w.frame.size, in: topology)
            check(
                SizeBand.isPlausibleContent(px),
                "visible window \"\(w.title)\" (id \(w.windowId)) size is in the plausible-content band "
                    + "(150x80 remote px floor; got \(detail))"
            )
        }
        return topology
    }

    /// One run-level line, on both exits: the interval from `startTime` -- set just BEFORE
    /// `newSession.start()` is called, so it includes connection setup -- to the entry of
    /// `finish()`/`finishCycles()`, i.e. before the assertion battery and the shutdown. Until now the only duration on record came from the wrapper's own
    /// start/stop stamps outside this log (docs/upgrade-gate/2026-09-scaledmap-next-step.md §5
    /// needs a duration the run's own evidence carries; review scaledmap-memo-r2 I-2); the two
    /// differ by the wrapper's own pre-launch work, so records name which one they quote.
    /// Informational, never gated; a missing `startTime` (start was never requested) prints as such.
    private func printRunElapsed() {
        if let startTime {
            print("[run] elapsed since start: \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
        } else {
            print("[run] elapsed since start: n/a (start was never requested)")
        }
    }

    private func finish() {
        drainTimer?.invalidate()
        drainTimer = nil
        printRunElapsed()

        let snapshots = registry.windowSnapshots()
        let visibleWindows = snapshots.filter(\.isVisible)
        // adr/0014 §6: read the outbound lane's two drop counters BEFORE the shutdown below.
        // `-shutdownAndWait` DESTROYS the outbound queue (CRSession.mm step 5), and
        // `outboundPostDroppedCount` is a passthrough to that queue's own counter -- after
        // teardown it necessarily reports 0, which would turn this session's real post-side
        // total into a backwards-moving reading. `outboundDroppedNoRailCount` is ivar-backed
        // and survives, but is snapshotted at the same instant so both sides of the click's
        // bracket are measured against the same moment.
        //
        // `outboundSealRejectedCount` is deliberately NOT read here: the only
        // `crdpq_outbound_seal` caller is `-shutdownAndWait` step 1, which this point has not
        // reached, and the queue is gone once it returns -- so from this harness the counter
        // is structurally 0 at every readable instant, and printing it would state a constant
        // as if it were evidence.
        let outboundDroppedNoRailAtEnd = session.outboundDroppedNoRailCount
        let outboundPostDroppedAtEnd = session.outboundPostDroppedCount
        let cleanShutdown = session.shutdownAndWait()

        var ok = true
        func check(_ cond: Bool, _ message: String) {
            print("[assert] \(cond ? "PASS" : "FAIL"): \(message)")
            if !cond { ok = false }
        }

        // M1 F2 (`docs/plans/phase3.md:132`) and F1 (`:130`): once per RUN, unconditionally, in
        // both terminal paths (`finishCycles()` prints the same lines). Placed at the top of the
        // summary so they cannot be lost behind an early `exit` in some future edit.
        printMeasurementSummaries()
        // The connect-time desktop size actually negotiated, and the ADR §5 re-take pin. A
        // single-run `finish()` performed exactly one freeze (no `prepareForReconnect()` -- see
        // this method's own note on why it never resets the registry).
        print("[topology] session desktop size: "
            + (sessionDesktopSizeInRemotePixels.map { "\($0.width)x\($0.height) remote px" }
                ?? "<never set -- no usable display at connect, adr/0015 §5.A.6>"))
        let freezePin = topologyFreezeCountCheck(expectedReconnects: 0)
        check(freezePin.passed, freezePin.message)

        // Flow evidence counters (task item 1): machine-readable summary of everything
        // eb2e333's MonitoredDesktop/ZOrderSync/MinMaxInfo/LocalMoveSize plumbing actually
        // delivered this run -- printed regardless of pass/fail, same as every other
        // [assert]-adjacent summary line in this function.
        print("[flow] MonitoredDesktop=\(monitoredDesktopEventCount) activeWindowIdTransitions=\(activeWindowIdTransitionCount) "
            + "ZOrderSync=\(zOrderSyncEventCount) MinMaxInfo=\(minMaxInfoEventCount) LocalMoveSize=\(localMoveSizeEventCount)")
        // Gating: proves the eb2e333 contract is live against a real host, per adr/0008 §0's
        // sample-derived per-session shapes (MonitoredDesktop observed ~25/session across
        // six samples; ZOrderSync observed exactly once per sampled session). MinMaxInfo/
        // LocalMoveSize stay informational-only (no gating) -- see their counters' own doc
        // comment for why.
        check(monitoredDesktopEventCount >= 1, "received >=1 MonitoredDesktop event this session (adr/0008 §0: ~25/session observed) (got \(monitoredDesktopEventCount))")
        check(zOrderSyncEventCount >= 1, "received >=1 ZOrderSync event this session (adr/0008 §0: exactly 1/session observed) (got \(zOrderSyncEventCount))")

        // Phase 2 W6 (docs/plans/phase2.md §2 W6 / §4 W6 acceptance: "NSStatusItem 数量 ==
        // create−delete"): printed unconditionally, like [flow]/[zorder] above, regardless of
        // pass/fail. Unlike `finishCycle` (which explicitly calls `registry.prepareForReconnect()`
        // right after its own `shutdownAndWait()`), this single-run `finish()` never resets the
        // registry -- `session.shutdownAndWait()` above tears down the CONNECTION but leaves
        // `registry`'s own bookkeeping (including `trayStatusController`'s live items) exactly
        // as this session's drain loop last left it, so `liveCount` below is real, undisturbed
        // evidence of this session's create/delete balance, not a trivially-zeroed post-teardown
        // read.
        //
        // The count==create−delete assertion itself is gated ONLY when this session actually
        // saw >=1 notify-icon event at all -- most scenarios this harness runs (winver, Word,
        // Edge, popups) never trigger a systray icon, and asserting 0==0−0 on a session that
        // never exercised this path would be a vacuous pass, not real evidence. On a run
        // that IS pointed at a tray-icon-bearing program, `WINDOW_SMOKE_TRAY=1` (below)
        // additionally turns "nothing ever appeared" into a hard failure -- this formula
        // gate alone stays conditional so every OTHER scenario keeps printing zeros
        // ungated, exactly as before.
        let trayDiag = registry.trayDiagnostics()
        print("[tray] creates=\(trayDiag.createsSeen) updates=\(trayDiag.updatesSeen) deletes=\(trayDiag.deletesSeen) liveCount=\(trayDiag.liveCount)")
        if trayDiag.createsSeen > 0 || trayDiag.updatesSeen > 0 || trayDiag.deletesSeen > 0 {
            check(
                trayDiag.liveCount == trayDiag.createsSeen - trayDiag.deletesSeen,
                "NSStatusItem count == create−delete (phase2.md §4 W6 acceptance) (got liveCount=\(trayDiag.liveCount) creates=\(trayDiag.createsSeen) deletes=\(trayDiag.deletesSeen))"
            )
        }
        // adr/0013 acceptance (WINDOW_SMOKE_TRAY=1): the run was pointed at a tray-icon-
        // bearing program, so "no icon ever appeared" is a FAILURE here, not the vacuous-
        // pass case the formula gate above deliberately stays silent on. Four separate
        // checks so a red run says which stage broke: no create at all (driver/launch
        // problem), created but never showed a REAL bitmap (adr/0013's actual claim --
        // conversion or payload path broke; `realIconMaxObserved` is latched by
        // TrayStatusController at install time, R1 finding 2, because the driver disposes
        // before shutdown and a poll could miss a same-batch create+delete), a skip
        // (any of iconSkipped's three causes), or a store overflow (slot accounting broke).
        if trayScenarioEnabled {
            print("[tray] realIconMaxObserved=\(trayDiag.realIconMaxObserved) iconSkipped=\(trayDiag.iconSkippedCount) cachedIcon=\(trayDiag.cachedIconCount) storeOverflow=\(trayDiag.storeOverflowCount)")
            check(trayDiag.createsSeen >= 1, "tray scenario saw at least one NotifyIconCreate (got creates=\(trayDiag.createsSeen))")
            check(
                trayDiag.realIconMaxObserved >= 1,
                "at least one NSStatusItem displayed the REAL remote icon bitmap while alive (adr/0013 acceptance) (realIconMaxObserved=\(trayDiag.realIconMaxObserved))"
            )
            // R1 finding 3, sharpened by the first live run: real Win11 sessions re-send
            // their own tray icons as CACHED_ICON references routinely, so the deferred
            // cache path (adr/0013 §2 -- counted evidence, not a failure) must be excluded
            // here or this gate fails every correct real-world session. What must be zero
            // is the NON-cached remainder: genuine converter rejections and store
            // exhaustion.
            if trayDiag.cachedIconCount > 0 {
                print("[info] tray: \(trayDiag.cachedIconCount) CACHED_ICON reference(s) observed -- deferred protocol path, counted as evidence per adr/0013 §2, not gated")
            }
            check(
                trayDiag.iconSkippedCount - trayDiag.cachedIconCount == 0,
                "no wire icon was skipped for a NON-cached cause (converter rejection or store exhaustion; got iconSkipped=\(trayDiag.iconSkippedCount) of which cached=\(trayDiag.cachedIconCount))"
            )
            check(trayDiag.storeOverflowCount == 0, "icon store never overflowed (got storeOverflow=\(trayDiag.storeOverflowCount))")
            // adr/0014 §7 observation, printed on every tray run (not gated): which
            // NOTIFY_ICON_STATE_ORDER versions this session's server actually sent. An empty
            // list is itself the observation -- it means no order carried
            // WINDOW_ORDER_FIELD_NOTIFY_VERSION at all, which is exactly the state of
            // knowledge that made adr/0014 §1 pick the version-free WM_LBUTTONDOWN/
            // WM_LBUTTONUP pair over NIN_SELECT.
            // adr/0014 §9.1: the set is capped, so a full one is a PREFIX of what the server
            // sent, not the whole of it -- say so rather than letting a reader draw a
            // completeness conclusion the data doesn't support.
            let versionsCapped = trayDiag.observedNotifyIconVersions.count >= TrayStatusController.maxObservedVersions
            print("[tray] observedNotifyIconVersions=\(trayDiag.observedNotifyIconVersions)\(versionsCapped ? " (capped)" : "")")
        }
        // adr/0014 §6 acceptance (WINDOW_SMOKE_TRAY_CLICK=1): everything below is about what
        // this client SENT. MS-RDPERP 3.3.5.2.5.4 acknowledges a Client Notification Event PDU
        // with nothing at all, so there is no server-side leg to assert on here -- unlike the
        // SC_* traffic-light scenarios, whose WindowUpdate/WindowDelete echoes are real
        // server evidence. Seven checks, so a red run says which stage broke: the click never
        // fired, the icon vanished under it, the PDU count diverged from the click count, the
        // wrong messages went out, the wrong key went out, the outbound lane threw the PDUs
        // away because RAIL wasn't connected, or the queue refused to admit them in the first
        // place. The last two bracket the queue deliberately (adr/0014 §5): outbound sends are
        // `void`, so post-side admission and drain-side delivery are separately invisible, and
        // checking only one of them leaves the other's failure mode green.
        if trayClickScenarioEnabled {
            let messages = trayNotifyEventsSent.map(\.message)
            let expectedMessages: [UInt32] = [0x0000_0201, 0x0000_0202]
            let droppedAfter = outboundDroppedNoRailAtEnd
            let postDroppedAfter = outboundPostDroppedAtEnd
            // Both counters are monotonic within a session and both readings above were taken
            // pre-teardown, so `after < before` is impossible today -- `nil` means it happened
            // anyway (a future refactor moving either read past `shutdownAndWait`, say), which
            // is reported as a FAILED check rather than crashing the harness on a `UInt64`
            // underflow trap or, worse, being silently clamped to a passing 0.
            func deltaSinceClick(_ before: UInt64?, _ after: UInt64) -> UInt64? {
                guard let before else { return 0 } // click never armed: the gates below say so
                guard after >= before else { return nil }
                return after - before
            }
            let droppedDelta = deltaSinceClick(outboundDroppedNoRailBeforeClick, droppedAfter)
            let postDroppedDelta = deltaSinceClick(outboundPostDroppedBeforeClick, postDroppedAfter)
            print("[tray-click] clicksForwarded=\(trayDiag.clicksForwarded) notifyEventsSent=\(trayDiag.notifyEventsSent) "
                + "droppedIconGone=\(trayDiag.clicksDroppedIconGone) "
                + "messages=[\(messages.map { "0x" + String($0, radix: 16) }.joined(separator: ", "))] "
                + "outboundDroppedNoRail=\(outboundDroppedNoRailBeforeClick.map(String.init) ?? "n/a")->\(droppedAfter) "
                + "outboundPostDropped=\(outboundPostDroppedBeforeClick.map(String.init) ?? "n/a")->\(postDroppedAfter)")
            check(
                trayDiag.clicksForwarded >= 1,
                "the tray-click scenario forwarded at least one left click (got clicksForwarded=\(trayDiag.clicksForwarded); 0 means no live real-bitmap icon was ever available to click)"
            )
            check(
                trayDiag.clicksDroppedIconGone == 0,
                "no click was dropped for a vanished NSStatusItem (got clicksDroppedIconGone=\(trayDiag.clicksDroppedIconGone) -- nonzero means the status-item table and the click path disagreed about what is live)"
            )
            // adr/0014 §5's deliberately-redundant pair: one click is exactly two PDUs in v1,
            // and the day that stops being true this identity is what says so.
            check(
                trayDiag.notifyEventsSent == 2 * trayDiag.clicksForwarded,
                "v1 invariant notifyEventsSent == 2 * clicksForwarded (got \(trayDiag.notifyEventsSent) vs 2 * \(trayDiag.clicksForwarded))"
            )
            check(
                messages == expectedMessages,
                "the ClientNotifyEvent message sequence is exactly [WM_LBUTTONDOWN, WM_LBUTTONUP] in that order (got [\(messages.map { "0x" + String($0, radix: 16) }.joined(separator: ", "))])"
            )
            // Bit-equality against the key this harness itself chose -- not against whatever
            // the send path happened to report -- so a truncation/repacking bug in the tag's
            // pack -> unpack round trip (truncation-detecting) cannot pass by being
            // self-consistent. Note this simulated path never touches `NSButton.tag` itself:
            // `debugSimulateTrayClick` packs the tag and hands it straight to
            // `handleLeftClick(tag:)`, so what is covered is the packing arithmetic, not
            // AppKit's storage of it.
            if let target = trayClickTarget {
                let keysMatch = !trayNotifyEventsSent.isEmpty && trayNotifyEventsSent.allSatisfy {
                    $0.windowId == target.windowId && $0.notifyIconId == target.notifyIconId
                }
                check(
                    keysMatch,
                    "every ClientNotifyEvent carried the clicked icon's own (windowId=\(target.windowId), notifyIconId=\(target.notifyIconId)) key verbatim (got \(trayNotifyEventsSent.map { "(\($0.windowId), \($0.notifyIconId))" }.joined(separator: ", ")))"
                )
            } else {
                check(false, "the tray-click scenario locked a target icon to click (none was ever live with a real bitmap)")
            }
            check(
                droppedDelta == 0,
                "no outbound command was dropped for a missing RAIL channel across the click (got outboundDroppedNoRailCount delta=\(droppedDelta.map(String.init) ?? "not comparable -- the counter moved backwards"))"
            )
            // adr/0014 §5/§6's seventh gate: the post side. Without it, the six checks above
            // are all satisfiable by a click whose PDUs the queue rejected outright --
            // `clicksForwarded`, `notifyEventsSent` and the collected triples are all recorded
            // by the SENDER, before `crdpq_outbound_post` gets a say, and the drain-side
            // counter above cannot count a command that never made it into the queue.
            check(
                postDroppedDelta == 0,
                "no outbound command was rejected at post time across the click -- capacity ceiling or allocation failure (got outboundPostDroppedCount delta=\(postDroppedDelta.map(String.init) ?? "not comparable -- the counter moved backwards, i.e. it was read after the outbound queue was destroyed"))"
            )
        }

        // W4c: skip when an input test is active -- a *successful* click/Enter can
        // legitimately close the only window this session had open (observed in practice:
        // a lab session with nothing else left over from a prior round), which is the win
        // condition, not a failure. The input test's own assertion further down is what
        // actually gates this mode; this generic check was never designed with "the target
        // window's own successful closure empties the whole session" in mind.
        if trayScenarioEnabled && visibleWindows.isEmpty {
            // First live tray run (2026-08-31): a pure tray driver hosted by Windows
            // Terminal produced ZERO RAIL windows while its notification icon worked
            // perfectly -- which is the very point of a tray app. The tray gates above are
            // this scenario's own acceptance; requiring a visible window here would fail
            // the run for its subject behaving exactly as designed.
            print("[info] tray scenario with zero visible windows -- a windowless tray driver is legitimate; skipping the generic visible-RemoteWindow check")
        } else if inputTestMode == nil {
            check(!visibleWindows.isEmpty, "at least one visible RemoteWindow (got \(visibleWindows.count))")
            // Phase 1 acceptance: with extra apps launched into the same session, N NEW content
            // windows (windowIds not present at exec time) must have appeared -- still visible
            // at finish, or closed by this run's own close legs -- and no ClientExecute may have
            // failed. A bare total count could be satisfied by leftover windows from an earlier
            // session with zero extra apps actually launching (2026-08-22 review HIGH).
            if !extraApps.isEmpty {
                // F0-H1 (2026-09-02): the move/resize scenario's close leg legitimately closes the
                // run-launched target before we get here, so "visible at finish" alone reported 0
                // by construction. A closed target counts only if it was seen visible-with-content
                // inside the band on some tick after the exec (`contentWindowsSeenAfterExtraApps`);
                // a window that merely flashed and was not closed by us does not count (review
                // multiwindow-gate-r1 I-1). `before` is subtracted inside the gate too -- that is
                // the defence for an accumulator populated outside the `extraAppsLaunched` window,
                // not dead code.
                let visibleNewContent = Set(visibleWindows.filter {
                    isInPlausibleContentBand($0) && $0.hasDisplayedContent
                        && !windowIdsBeforeExtraApps.contains($0.windowId)
                }.map(\.windowId))
                // Both halves are the SC_CLOSE-time ids (set on the same line the close is sent),
                // never the lock-time target: a window merely aimed at and gone on its own must
                // not read as "closed by us" (review multiwindow-gate-r2 I-1).
                let closedByHarness = Set([moveResizeCloseTargetId, maximizeCloseTargetId].compactMap { $0 })
                let newContentIds = MultiWindowGate.newContentWindowIds(
                    visibleAtFinish: visibleNewContent, closedByHarness: closedByHarness,
                    everSeenContent: Set(contentWindowsSeenAfterExtraApps.keys), before: windowIdsBeforeExtraApps
                )
                check(
                    newContentIds.count >= extraApps.count,
                    "multi-window scenario: >=\(extraApps.count) NEW content windows appeared after the extra "
                        + "execs (still visible at finish, or closed by this run's own close leg) (got "
                        + "\(newContentIds.count), \(visibleNewContent.count) still visible: "
                        + "\(newContentIds.sorted().map { "\($0)=\"\(contentWindowsSeenAfterExtraApps[$0] ?? "")\"" }.joined(separator: " | ")))"
                )
                check(
                    failedExecResults.isEmpty,
                    "no ClientExecute failed (got \(failedExecResults.isEmpty ? "none" : failedExecResults.joined(separator: ", ")))"
                )

                // Z-order assertion (phase2.md §2 W1's final slice, adr/0008 §2a/§4): once
                // the multi-window setup has settled (this block only runs once the check
                // above has already confirmed that), the local top-down stacking order of
                // RAIL-mapped windows must be a subsequence-consistent match of the last
                // MonitoredDesktop windowIds array -- comparing only ids present in BOTH
                // sequences (adr/0008 §4's binding truncation rule: an id absent from
                // either side is simply not part of the comparison, never treated as
                // "should sink to the bottom"). `registry.currentTopDownWindowIds()` reads
                // the exact same ordering `RemoteWindowRegistry.applyZOrder` itself acted
                // on, not a second, separately-computed notion of "current order".
                let serverZOrder = registry.serverDesktopState().windowIds
                check(
                    !serverZOrder.isEmpty,
                    "the multi-window scenario observed >=1 MonitoredDesktop order carrying a DESKTOP_ZORDER "
                        + "windowIds array (adr/0008 §2a) (got \(serverZOrder.count) id(s) in the last one)"
                )
                if !serverZOrder.isEmpty {
                    let localZOrder = registry.currentTopDownWindowIds()
                    // The topmost LOCAL window is excluded from the comparison: local
                    // optimistic activation (adr/0012 §0 -- makeKey + orderFront on click)
                    // legitimately floats the just-activated window above its position in
                    // the last server array until the NEXT MonitoredDesktop lands, so the
                    // float is a focus question, not a Z-order-application defect. The
                    // relative order of everything beneath it must still match exactly.
                    let localKeyId = localZOrder.first
                    let localSet = Set(localZOrder)
                    let serverSet = Set(serverZOrder)
                    let serverRestricted = serverZOrder.filter { localSet.contains($0) && $0 != localKeyId }
                    let localRestricted = localZOrder.filter { serverSet.contains($0) && $0 != localKeyId }
                    let matched = serverRestricted == localRestricted
                    check(
                        matched,
                        "local top-down window stacking is a subsequence-consistent match of the last "
                            + "MonitoredDesktop windowIds array (adr/0008 §2a/§4: comparing only ids present in both)"
                    )
                    if !matched {
                        print("[zorder] MISMATCH server=\(serverZOrder) local=\(localZOrder) "
                            + "serverRestricted=\(serverRestricted) localRestricted=\(localRestricted)")
                    }
                }
                let zOrderDiag = registry.zOrderDiagnostics()
                print("[zorder] arraysReceived=\(zOrderDiag.arraysReceived) "
                    + "appliesPerformed=\(zOrderDiag.appliesPerformed) skippedUnknown=\(zOrderDiag.skippedUnknownTotal)")
            }
        } else {
            print("[info] input-test mode active (\(inputTestMode!)) -- skipping the generic \"at least one "
                + "visible RemoteWindow\" check (got \(visibleWindows.count); a successful test can legitimately "
                + "leave zero if this was the only window open)")
        }

        // H3, revised for Phase 2 W0① (docs/plans/phase2.md W0①) and re-expressed in REMOTE PX for
        // M1 (adr/0015 §6 rule 1; C-2 run 1's only FAIL): every visible window's size must clear
        // a broad plausible-content floor and stay under a garbage ceiling. `SizeBand` owns both
        // constants, their history (the 150x80 floor, the removed 2000 ceiling, the 10000 net) and
        // the pt->remote px conversion through the session's FROZEN topology -- the same
        // `rasterScale` the desktop size was derived from (§5.A.4), never a fresh screen read. No
        // frozen topology means the sizes cannot be judged in remote px at all; the discipline is
        // the move-resize leg's: report that as a failed check, never fall back to comparing frame
        // pt against remote-px constants (the pre-C-2 shape, correct only at rasterScale 1).
        let sizeBandTopology = assertPlausibleContentBands(over: visibleWindows, check: check)

        // H3: anchor the size assertion on the actual winver.exe "About Windows" dialog by
        // title, rather than "the first visible window" (non-deterministic under Z-order,
        // and observed in practice to sometimes be an unrelated leftover RemoteApp window
        // from an earlier phase of a long-lived host session -- see the W4b report).
        // Gating (counts toward pass/fail) only when this run actually launched winver --
        // round 2's WINDOW_SMOKE_APP parameterization means a run can launch something
        // else entirely, in which case there is no About Windows dialog to find at all.
        let aboutWindow = visibleWindows.first { w in
            w.title.localizedCaseInsensitiveContains("about") || w.title.contains("关于")
        }
        // W4c: when an input test is active, a *successful* click/Enter closes this exact
        // window by design partway through the run -- gating the paint/size checks below on
        // it still being open at t=25s would make a passing input test look like a failure.
        // The input test's own assertion (further down, after the experiment summaries)
        // covers what actually matters in that mode: did the WindowDelete arrive in time.
        // Phase 2 W2 team-lead review: the maximize scenario (WINDOW_SMOKE_MAXIMIZE) closes
        // this exact window by design too (its own SC_CLOSE leg) -- same reasoning, same
        // exclusion; that scenario's own gating assertions (in the maximize-scenario block
        // below) are what actually matter for it, not this generic default-path check.
        // Team-lead review (2026-08-23, move-resize real-host run): WINDOW_SMOKE_MOVE closes
        // its own About target the same way (its own SC_CLOSE leg, Fix 2) -- identical
        // exclusion, extending the pattern this comment already establishes.
        // Team-lead review (2026-08-23, popup real-host run): WINDOW_SMOKE_POPUP now closes
        // its own About target too (`beginAboutCleanup`'s SC_CLOSE cleanup leg) -- same
        // exclusion, same reasoning.
        if launchedAppKind == .winver, inputTestMode == nil, !maximizeScenarioEnabled, !moveResizeScenarioEnabled, !popupScenarioEnabled {
            if let aboutWindow {
                // Tighter band than the general one above, judged in remote px through the same
                // frozen topology (`SizeBand.aboutWindowsRange`). C-2 run 1 went red exactly here
                // at 2x: the About window's F1 line read 522x515 remote px as a 261x258 pt content
                // rect, and the pt frame was compared against remote-px constants.
                if let sizeBandTopology {
                    let (px, detail) = SizeBand.describe(frameSize: aboutWindow.frame.size, in: sizeBandTopology)
                    check(
                        SizeBand.isAboutWindowsDialog(px),
                        "the About-Windows-anchored window's size matches winver.exe's dialog "
                            + "(400...700 remote px on both axes; got \(detail))"
                    )
                }
                // H2/H3 round 2, experiment 2 (control group, W4b review): a *freshly
                // launched* window's own content -- not a stale/backgrounded one -- should
                // paint completely, including its bottom region. Lower threshold than
                // regedit's tree view (10% vs 30%): the About dialog's bottom is mostly
                // whitespace around an OK button and a couple of text lines, genuinely less
                // ink coverage than a populated tree, not evidence of a rendering gap.
                let ratio = registry.nonWhitePixelRatio(
                    windowId: aboutWindow.windowId, inBottomFraction: 0.2, sampleCount: 100
                )
                if let ratio {
                    check(
                        ratio > 0.1,
                        "bottom 20% of the About-Windows-anchored window is >10% non-white pixels, a freshly "
                            + "launched window should paint completely (got \(String(format: "%.1f", ratio * 100))%)"
                    )
                } else {
                    check(false, "could not sample pixels from the About-Windows-anchored window -- no surface displayed")
                }
            } else {
                check(
                    false,
                    "an About-Windows-titled window is among the visible windows (titles seen: "
                        + "\(visibleWindows.map(\.title)))"
                )
            }
        } else if let aboutWindow {
            if inputTestMode != nil {
                print("[info] input-test mode active (\(inputTestMode!)) -- the About-Windows window (id "
                    + "\(aboutWindow.windowId)) is still open at t=25s; the input-test assertion below covers "
                    + "whether it closed in time, not this generic paint/size check")
            } else if maximizeScenarioEnabled {
                print("[info] maximize scenario active -- the About-Windows window (id \(aboutWindow.windowId)) "
                    + "is still open at t=25s (its own close leg may still be in flight, or may have failed); the "
                    + "maximize-scenario assertions above are authoritative for this run, not this generic "
                    + "paint/size check")
            } else if moveResizeScenarioEnabled {
                print("[info] move-resize scenario active -- the About-Windows window (id \(aboutWindow.windowId)) "
                    + "is still open at t=25s (its own close leg may still be in flight, or may have failed); the "
                    + "move-resize-scenario assertions above are authoritative for this run, not this generic "
                    + "paint/size check")
            } else if popupScenarioEnabled {
                print("[info] popup scenario active -- the About-Windows window (id \(aboutWindow.windowId)) is "
                    + "still open at t=25s (its own cleanup close leg may still be in flight, or may have failed); "
                    + "the popup-scenario assertions above are authoritative for this run, not this generic "
                    + "paint/size check")
            } else {
                print("[info] an About-Windows-titled window (id \(aboutWindow.windowId)) is present but this run "
                    + "launched \(launchedProgram), not winver.exe -- not the anchor for this run, informational only")
            }
        } else if maximizeScenarioEnabled {
            // Phase 2 W2 team-lead review: the expected end state for a successful maximize
            // scenario is exactly this -- SC_CLOSE's own WindowDelete already closed the
            // About window (see closeResult, asserted in the maximize-scenario block above).
            // Mirrors the inputTestMode branch below's own "don't sound reassuring when the
            // close was never actually confirmed" discipline.
            if closeResult == true {
                print("[info] maximize scenario active -- no About-Windows window remains open, consistent with "
                    + "the scenario's own SC_CLOSE leg succeeding; see the maximize-scenario assertions above, "
                    + "which are authoritative here")
            } else {
                print("[info] maximize scenario active -- no About-Windows window remains open, but the scenario's "
                    + "own close leg did not confirm success (closeResult=\(String(describing: closeResult))) -- "
                    + "this is NOT necessarily evidence of a successful close; see the maximize-scenario "
                    + "assertions above, which are authoritative here")
            }
        } else if moveResizeScenarioEnabled {
            // Team-lead review (2026-08-23, move-resize real-host run): mirrors the
            // maximizeScenarioEnabled branch immediately above, for WINDOW_SMOKE_MOVE's own
            // SC_CLOSE leg (Fix 2) instead of maximize's.
            if moveResizeCloseResult == true {
                print("[info] move-resize scenario active -- no About-Windows window remains open, consistent "
                    + "with the scenario's own SC_CLOSE leg succeeding; see the move-resize-scenario assertions "
                    + "above, which are authoritative here")
            } else {
                print("[info] move-resize scenario active -- no About-Windows window remains open, but the "
                    + "scenario's own close leg did not confirm success "
                    + "(moveResizeCloseResult=\(String(describing: moveResizeCloseResult))) -- this is NOT "
                    + "necessarily evidence of a successful close; see the move-resize-scenario assertions above, "
                    + "which are authoritative here")
            }
        } else if popupScenarioEnabled {
            // Team-lead review: mirrors the maximizeScenarioEnabled/moveResizeScenarioEnabled
            // branches immediately above, for WINDOW_SMOKE_POPUP's own cleanup SC_CLOSE leg.
            if popupAboutCloseResult == true {
                print("[info] popup scenario active -- no About-Windows window remains open, consistent with the "
                    + "scenario's own cleanup SC_CLOSE leg succeeding; see the popup-scenario assertions above, "
                    + "which are authoritative here")
            } else {
                print("[info] popup scenario active -- no About-Windows window remains open, but the scenario's "
                    + "own cleanup close leg did not confirm success "
                    + "(popupAboutCloseResult=\(String(describing: popupAboutCloseResult))) -- this is NOT "
                    + "necessarily evidence of a successful close; see the popup-scenario assertions above, which "
                    + "are authoritative here")
            }
        } else if inputTestMode != nil {
            // W4c review M2+M3: this branch used to unconditionally claim "consistent with
            // a successful click/Enter having closed it" -- true when a synthetic event was
            // actually sent, but actively misleading when inputTestSentAt is nil (a ready
            // target was never found at all, so there is no About window for an entirely
            // different, more concerning reason: the input-test assertion below will
            // correctly report this as a failure, and this narration must not sound
            // reassuring right above it).
            if inputTestSentAt != nil {
                print("[info] input-test mode active (\(inputTestMode!)) -- no About-Windows window remains open, "
                    + "consistent with a successful click/Enter having closed it; see the input-test assertion below")
            } else {
                print("[info] input-test mode active (\(inputTestMode!)) -- no About-Windows window remains open, "
                    + "but no synthetic \(inputTestMode!) was ever sent (a ready target window was never found) -- "
                    + "this is NOT evidence of a successful close; the input-test assertion below will fail")
            }
        }

        // H2/H3 round 2 (W4b review): pixel-level verification, not eyeballing a
        // screenshot -- the round-1 "screenshot looked fine" conclusion was flat wrong
        // (nothing was actually checking pixel content, and the window in question was
        // partially obscured by unrelated desktop windows in that screenshot anyway).
        // Reads the actual displayed IOSurface's own backing store directly (see
        // RemoteWindow.nonWhitePixelRatio's doc comment), sidestepping Screen Recording
        // TCC and stale-file ambiguity entirely.
        //
        // Gating (counts toward pass/fail) only when THIS run itself launched regedit
        // (launchedAppKind == .regedit, via WINDOW_SMOKE_APP -- experiment 2's control
        // group: a freshly launched instance is expected to paint completely). When
        // regedit merely happens to be present as a stale/long-idle leftover from an
        // earlier phase of the session (the common case for every other run, including the
        // default winver-launching one), this is deliberately NOT gating -- W4b review
        // round 2's own finding is that a stale background window legitimately not
        // repainting is expected server behavior, not a regression in this pipeline; making
        // it gating in that case would leave this assertion permanently red for a known,
        // already-explained condition, masking a real future regression under the noise.
        let regeditWindow = visibleWindows.first { w in
            w.title.localizedCaseInsensitiveContains("registry") || w.title.contains("注册表")
        }
        if launchedAppKind == .regedit {
            if let regeditWindow {
                let ratio = registry.nonWhitePixelRatio(
                    windowId: regeditWindow.windowId, inBottomFraction: 0.2, sampleCount: 100
                )
                if let ratio {
                    check(
                        ratio > 0.3,
                        "bottom 20% of the freshly-launched Registry-Editor window is >30% non-white pixels, not "
                            + "a blank/undrawn region (got \(String(format: "%.1f", ratio * 100))%)"
                    )
                } else {
                    check(false, "could not sample pixels from the freshly-launched Registry-Editor window -- no surface displayed")
                }
            } else {
                check(
                    false,
                    "a Registry-Editor-titled window is among the visible windows (this run launched "
                        + "\(launchedProgram)) -- titles seen: \(visibleWindows.map(\.title))"
                )
            }
        } else if let regeditWindow {
            let ratio = registry.nonWhitePixelRatio(
                windowId: regeditWindow.windowId, inBottomFraction: 0.2, sampleCount: 100
            )
            print("[info] a Registry-Editor-titled window (id \(regeditWindow.windowId)) is present as a "
                + "stale/leftover window, not launched by this run -- bottom-20% non-white ratio: "
                + "\(ratio.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a") (informational only, not gating; "
                + "see W4b review round 2's finding on stale background windows)")
        } else {
            print("[info] no Registry-Editor-titled window present this run -- pixel-level bottom-region "
                + "assertion skipped (this run launched \(launchedProgram))")
        }

        // Experiment 1 summary (W4b review round 2): does ClientActivate prompt the server
        // to repaint a background window's previously-unfilled content?
        if let pre = activatePreRatio, let post = activatePostRatio {
            print("[experiment] Activate repaint test: pre=\(String(format: "%.1f%%", pre * 100)) "
                + "post=\(String(format: "%.1f%%", post * 100)) delta=\(String(format: "%+.1f%%", (post - pre) * 100))")
        } else {
            print("[experiment] Activate repaint test did not run this session (no Registry-Editor-titled "
                + "window was ever observed, or the run ended before t=20s)")
        }
        // Refresh-rect (MS-RDPBCGR TS_REFRESH_RECT_PDU) investigated separately, not
        // attempted here: this vendored FreeRDP exposes no client-callable "send a refresh
        // rect request now" API -- only `pRefreshRect`/`context->update->RefreshRect`
        // (a callback slot for the *opposite* direction, server-to-client) and
        // `update_read_refresh_rect` (FREERDP_LOCAL, parses an incoming PDU, not exported
        // for client code to call). Consistent with refresh-rect being a legacy bitmap-
        // update-era mechanism the RDPGFX pipeline this project uses supersedes.
        print("[experiment] refresh-rect: no client-callable send API exists in this vendored FreeRDP "
            + "(only a receive-side callback slot and a FREERDP_LOCAL parser) -- not attempted")

        // W4c deliverable 5: the actual end-to-end input-forwarding acceptance test --
        // gating (counts toward pass/fail) only when WINDOW_SMOKE_INPUT_TEST was set for
        // this run. `inputTestSentAt == nil` (never found a ready target at all) and
        // "found a target but no WindowDelete arrived in time" are both real failures,
        // reported with different messages so a failing run says which stage broke.
        //
        // W4c review M2+M3: `inputTestPassed` is computed here (not just fed straight into
        // `check`) because the `withContent` assertion further down also needs to know this
        // outcome -- a *successful* input test whose target was the session's only window
        // legitimately leaves zero tracked windows with content, and that check needs to
        // stop requiring content in exactly that one case without becoming unconditionally
        // toothless for every other run.
        // Defaults to false, not true: when inputTestMode is nil (the common case, no
        // input test running at all), this must NOT satisfy the withContent gate below --
        // "false && snapshots.isEmpty" is always false regardless of snapshots, so a
        // normal run that ends with zero tracked windows for some unrelated reason still
        // gets the unconditional, strict withContent check it always has.
        var inputTestPassed = false
        if let inputTestMode, inputTestMode != .cmdmap, inputTestMode != .ime {
            // adr/0011 §5 items 5/6: `.cmdmap` and `.ime` are both excluded from this
            // WindowDelete-based gate -- nothing either of them sends has any reason to close
            // a window (Cmd+C/Cmd+V/Cmd+S against a Notepad, an IME commit into a text field),
            // whereas `.click`/`.enter` both close the About-Windows dialog by design. Their
            // own gates are further down: dispatch counts, the wire modifier ledger, the
            // Unicode degradation diagnostics, and -- for the file contents themselves -- an
            // external readback pass this process cannot perform.
            if let sentAt = inputTestSentAt, let windowId = inputTestWindowId {
                if inputTestWindowDeleted, let deletedAt = inputTestWindowDeletedAt {
                    let delta = deletedAt - sentAt
                    inputTestPassed = delta <= 3.0
                    check(
                        inputTestPassed,
                        "windowId=\(windowId) received WindowDelete within 3s of the synthetic \(inputTestMode) "
                            + "(sent at \(String(format: "%.2f", sentAt))s, deleted at "
                            + "\(String(format: "%.2f", deletedAt))s, delta \(String(format: "%.2f", delta))s)"
                    )
                } else {
                    inputTestPassed = false
                    check(
                        false,
                        "windowId=\(windowId) received WindowDelete within 3s of the synthetic \(inputTestMode) "
                            + "(sent at \(String(format: "%.2f", sentAt))s -- no WindowDelete observed for this "
                            + "windowId before the run ended)"
                    )
                }
            } else {
                inputTestPassed = false
                check(false, "input test (\(inputTestMode)) found a ready target window to act on before the run ended")
            }
        }

        // adr/0011 §5 item 5's LIVE battery (WINDOW_SMOKE_CMDMAP_LIVE=1 + INPUT_TEST=cmdmap).
        // What this process CAN assert: the scenario had a real, focused target; every one of
        // the six chords actually went out as real NSEvents; and the wire-side modifier ledger
        // is empty at the end (adr/0011 §5 item 2's structural "zero stuck modifiers" -- the
        // live twin of MacdowsCore's offline ledger tests). The key-window half of the
        // preamble is gated by the generic `keyWindowCheckResult` assertion further down,
        // which fires for every input-test mode -- not duplicated here.
        //
        // What it CANNOT assert, by construction: whether the file on the Windows host now
        // holds the seed text three times over. This process has no access to the host's
        // filesystem -- the FILE-CONTENT equality is asserted EXTERNALLY, by the controller,
        // in a readback pass that compares the file's bytes against the `expected-utf8-hex`
        // marker printed above (adr/0011 §5 item 5).
        if cmdMapLiveActive {
            check(
                cmdMapSeed != nil,
                "cmdmap-live: WINDOW_SMOKE_CMDMAP_SEED was supplied (without it no chord is dispatched at all -- "
                    + "this run could not state what the host-side file should contain afterwards)"
            )
            check(
                inputTestWindowId != nil,
                "cmdmap-live: an input-test target window was locked before the run ended"
                    + (inputTargetTitleSubstring.map { " (WINDOW_SMOKE_INPUT_TARGET_TITLE=\"\($0)\")" } ?? "")
            )
            check(
                inputScriptChordsDispatched == 6,
                "cmdmap-live: all 6 chords dispatched (Cmd+A, Cmd+C, End, Cmd+V, Cmd+V, Cmd+S) "
                    + "(got \(inputScriptChordsDispatched))"
            )
            check(
                registry.wireHeldModifiersIsEmpty(),
                "cmdmap-live: the wire-side modifier ledger is empty at finish -- zero stuck modifiers after six "
                    + "Cmd chords (adr/0011 §5 item 2, §3's wireHeldModifiers)"
            )
            print("[cmdmap-live] NOTE: file-content equality (seed x3) is asserted EXTERNALLY by the controller's "
                + "readback pass against the expected-utf8-hex marker above -- this process cannot read the host's "
                + "filesystem (adr/0011 §5 item 5)")
        }

        // adr/0011 §5 item 6 (WINDOW_SMOKE_INPUT_TEST=ime) -- the IME round trip, plus the
        // NORMAL-path half of item 7's degradation acceptance: on a server that DID negotiate
        // INPUT_FLAG_UNICODE, the gate must report supported, must have dropped nothing, and
        // must never have warned. (The degraded half is WINDOW_SMOKE_UNICODE_DEGRADE's own
        // block below.) File-content equality is again external -- same readback-pass split
        // the cmdmap-live note above spells out.
        if inputTestMode == .ime {
            let unicodeDiag = registry.unicodeDegradationDiagnostics()
            print("[ime] unicodeInputSupported=\(unicodeDiag.unicodeInputSupported.map(String.init) ?? "not read") "
                + "warningsEmitted=\(unicodeDiag.warningsEmitted) droppedCommits=\(unicodeDiag.droppedCommits)")
            check(
                inputTestWindowId != nil,
                "ime: an input-test target window was locked before the run ended"
                    + (inputTargetTitleSubstring.map { " (WINDOW_SMOKE_INPUT_TARGET_TITLE=\"\($0)\")" } ?? "")
            )
            check(
                inputScriptCommitsDelivered == 1,
                "ime: exactly one 50-scalar commit was delivered through the real "
                    + "NSTextInputClient.insertText(_:replacementRange:) path (got \(inputScriptCommitsDelivered)"
                    + (inputScriptCastFailed ? ", contentView cast to RemoteWindowContentView FAILED" : "") + ")"
            )
            check(
                inputScriptChordsDispatched == 1,
                "ime: the Cmd+S save chord was dispatched (got \(inputScriptChordsDispatched))"
            )
            check(
                unicodeDiag.unicodeInputSupported == true,
                "ime: the server negotiated INPUT_FLAG_UNICODE and the gate read it as supported (adr/0011 §2) "
                    + "(got \(unicodeDiag.unicodeInputSupported.map(String.init) ?? "not read this connection"))"
            )
            check(
                unicodeDiag.droppedCommits == 0,
                "ime: no commit was dropped on the normal path (got \(unicodeDiag.droppedCommits))"
            )
            check(
                unicodeDiag.warningsEmitted == 0,
                "ime: no degradation warning was emitted on the normal path (got \(unicodeDiag.warningsEmitted))"
            )
            check(
                registry.wireHeldModifiersIsEmpty(),
                "ime: the wire-side modifier ledger is empty at finish -- zero stuck modifiers after the Cmd+S "
                    + "chord (adr/0011 §5 item 2, §3's wireHeldModifiers)"
            )
            print("[ime] NOTE: file-content equality is asserted EXTERNALLY by the controller's readback pass "
                + "against the expected-utf8-hex marker above -- this process cannot read the host's filesystem "
                + "(adr/0011 §5 item 6)")
        }

        // adr/0011 §5 item 7's DEGRADED half (WINDOW_SMOKE_UNICODE_DEGRADE=1): with the
        // negotiated capability forced to unsupported, adr/0011 §2's discipline is exactly
        // three numbers -- capability read as unsupported, EXACTLY one warning (the warn-once
        // budget: "降级告警恰好一次"), and every commit accounted for as dropped ("无静默丢字").
        // "Exactly", not ">=", on all three: a second warning is as much a defect as a silent
        // drop, and a third dropped commit would mean something reached this gate that this
        // scenario never sent.
        if unicodeDegradeScenarioEnabled {
            let unicodeDiag = registry.unicodeDegradationDiagnostics()
            print("[unicode-degrade] unicodeInputSupported="
                + "\(unicodeDiag.unicodeInputSupported.map(String.init) ?? "not read") "
                + "warningsEmitted=\(unicodeDiag.warningsEmitted) droppedCommits=\(unicodeDiag.droppedCommits)")
            check(
                inputScriptCommitsDelivered == 2,
                "unicode-degrade: both IME commits were delivered through the real "
                    + "NSTextInputClient.insertText(_:replacementRange:) path (got \(inputScriptCommitsDelivered)"
                    + (inputScriptCastFailed ? ", contentView cast to RemoteWindowContentView FAILED" : "") + ")"
            )
            check(
                unicodeDiag.unicodeInputSupported == false,
                "unicode-degrade: the gate read the negotiated Unicode capability as UNSUPPORTED (got "
                    + "\(unicodeDiag.unicodeInputSupported.map(String.init) ?? "not read this connection") -- "
                    + "\"not read\" means no commit ever reached the gate)"
            )
            check(
                unicodeDiag.warningsEmitted == 1,
                "unicode-degrade: exactly ONE degradation warning was emitted for two dropped commits (adr/0011 §2's "
                    + "warn-once budget) (got \(unicodeDiag.warningsEmitted))"
            )
            check(
                unicodeDiag.droppedCommits == 2,
                "unicode-degrade: both commits were counted as dropped, none silently lost and none reaching the "
                    + "wire (adr/0011 §2: 无静默丢字) (got \(unicodeDiag.droppedCommits))"
            )
        }

        // Focus rotation scenario (task item 2/3): machine-readable summary plus one detail
        // line per eventual miss (target id, observed activeWindow at the eventual/5000ms
        // cap) -- only printed/gated when WINDOW_SMOKE_FOCUS_ROTATION was set for this run.
        // adr/0012 §4.2: reports BOTH tiers -- softHits (converged within the 500ms gating
        // window) and eventualHits (converged at all within the 5000ms eventual window) --
        // and gates on NEITHER rate (docs/plans/phase2.md §2 W1: "拿到真数据前不写策略"; the
        // >=99% soft-hit convergence gate is W1's own exit criterion, applied once this
        // harness has produced real n>=100 numbers to gate against). Gating here stays
        // limited to "did the scenario actually run its N rotations". The general
        // MonitoredDesktop>=1 check above already covers this scenario's own "and
        // MonitoredDesktop count >= 1" requirement -- not duplicated here.
        if focusRotationTotal > 0 {
            let softHits = focusRotationResults.filter(\.softHit)
            let eventualHits = focusRotationResults.filter(\.eventualHit)
            let eventualMisses = focusRotationResults.filter { !$0.eventualHit }
            let latencies = eventualHits.compactMap(\.latencyMs).sorted()
            func percentileMs(_ p: Double) -> Double {
                guard !latencies.isEmpty else { return 0 }
                let rank = max(0, min(latencies.count - 1, Int((p * Double(latencies.count)).rounded(.up)) - 1))
                return latencies[rank]
            }
            print(String(
                format: "[focus-rotation] n=%d softHits=%d eventualHits=%d eventualMisses=%d p50=%.1fms p95=%.1fms maxMs=%.1fms",
                focusRotationTotal, softHits.count, eventualHits.count, eventualMisses.count,
                percentileMs(0.5), percentileMs(0.95), latencies.last ?? 0
            ))
            for miss in eventualMisses {
                print("[focus-rotation] eventual miss detail: target=\(miss.targetId) observedActiveWindow=\(Self.describe(miss.observedActiveWindow))")
            }
            check(
                focusRotationsIssued == focusRotationTotal,
                "focus rotation ran all \(focusRotationTotal) rotations (issued \(focusRotationsIssued))"
            )
        }

        // Phase 2 W2 task item 5b/5c (docs/plans/phase2.md §2 W2): maximize/restore/close
        // e2e over CRSession.sendSysCommand(_:command:) -- gating only when
        // WINDOW_SMOKE_MAXIMIZE was actually set for this run. Closes W0's deferred M1
        // acceptance debt ("a maximized window must build", phase2.md W0/M1) via the
        // `maximizeResult.mappedWithContent` assertion, and gives task item 5c's
        // traffic-light close loop a real, gating check via `closeResult`.
        if maximizeScenarioEnabled {
            if let maximizeResult {
                check(
                    maximizeResult.grew,
                    "maximize scenario: SC_MAXIMIZE grew the About window to >= 2000 remote px width within 5s"
                )
                check(
                    maximizeResult.mappedWithContent,
                    "maximize scenario: the maximized window stayed mapped with real content (closes W0/M1's "
                        + "deferred \"a maximized window must build\" debt)"
                )
            } else {
                check(false, "maximize scenario: a target window was locked and SC_MAXIMIZE was sent before the run ended")
            }
            if let restoreResult {
                check(restoreResult, "maximize scenario: SC_RESTORE shrank the window back below 1000 remote px width within 5s")
            } else {
                check(false, "maximize scenario: the restore leg ran (may be skipped if the maximize leg itself already failed -- see the maximize assertions above)")
            }
            if let closeResult {
                check(
                    closeResult,
                    "maximize scenario (task item 5c): SC_CLOSE via the same sendSysCommand path produced a "
                        + "WindowDelete within 5s"
                )
            } else {
                check(false, "maximize scenario: the close leg ran before the run ended")
            }
        }

        // Phase 2 W3 (docs/plans/phase2.md §2 W3): local move/resize -> server sync
        // automated acceptance -- gating only when WINDOW_SMOKE_MOVE was actually set for
        // this run. See runMoveResizeScenario's own doc comment for the acknowledged
        // honesty gap (programmatic setFrame, not a live-resize-notification-driving real
        // drag) and why the resize leg is programmatic even when `WINDOW_SMOKE_MOVE_TARGET` points it at a resizable window
        // anyway.
        if moveResizeScenarioEnabled {
            if let moveResult {
                // Team-lead review round 6: POSITION-only, not full-rect -- see
                // evaluateMoveResizeLeg's own doc comment for why size is out of scope for a
                // pure move (the server's own prerogative to remap the surface mid-move,
                // observed live this round).
                //
                // M1 L9 / adr/0015 §6.3: the leg's verdict is a PAIR, and the two halves are two
                // separately-named `[assert]` lines rather than one conjunction, so a red run says
                // WHICH path failed while `ok` still goes red if either does. `rectCheckPassed` is
                // the pre-M1 `matched`, re-expressed in remote px; `pointCheckPassed` re-judges
                // THE SAME observed rect through `windowsPoint`, which has no `- height` term and
                // therefore cannot be assumed to agree just because the rect path did.
                check(
                    moveResult.rectCheckPassed,
                    "move-resize scenario: move leg RECT check -- the WindowUpdate round-tripped to the new "
                        + "POSITION within \(MoveResizeGate.toleranceInRemotePixels) remote px (adr/0015 §6.1, "
                        + "owner ruling U6) inside 3s; size is not asserted here, it is the server's own "
                        + "prerogative for a pure move. \(moveResult.detail)"
                )
                check(
                    moveResult.pointCheckPassed,
                    "move-resize scenario: move leg POINT check -- the same target's top-left through "
                        + "WindowGeometry.windowsPoint (adr/0015 §6.3's paired assertion; no `- height` term, "
                        + "so its sign/anchor errors are invisible to the rect check above). \(moveResult.detail)"
                )
                // Three-way, not a Bool: when the leg is unjudgeable (no topology, no observation,
                // or no match -- `detail` says which) there is nothing to have "settled", and
                // printing PASS there was the unfailable green review resize-live-r1 I1 caught on
                // env-202609-14's two red legs.
                switch moveResult.oscillation {
                case .unjudgeable(let n):
                    print("[assert] N/A: move-resize scenario: move leg POSITION oscillation is not judgeable "
                        + "(\(n) observation(s); no match, no observation, or no frozen topology -- see the "
                        + "leg-resolved line); not counted as PASS")
                case .none, .oscillated:
                    check(
                        !moveResult.oscillated,
                        "move-resize scenario: move leg settled without POSITION oscillation (no later WindowUpdate or remap "
                            + "diverged from the matched target's x/y)"
                    )
                }
            } else {
                check(false, "move-resize scenario: a target window was locked and the move leg was sent before the run ended")
            }
            // Team-lead review round 4 (no-false-red discipline): the resize leg's own
            // round-trip is gated (counts toward pass/fail) only when the real target
            // window was actually resizable at send time -- for a non-resizable target
            // (About, always) a wire-level round-trip mismatch is not evidence of a real
            // product defect the same way it would be for a genuinely resizable window
            // (see `moveResizeTargetIsResizable`'s own doc comment), so it's reported as
            // `[info]` only, never flipping `ok`.
            if let resizeResult {
                if moveResizeTargetIsResizable == true {
                    check(
                        resizeResult.rectCheckPassed,
                        "move-resize scenario: resize leg RECT check -- the WindowUpdate round-tripped to the new "
                            + "content rect (position AND size) within \(MoveResizeGate.toleranceInRemotePixels) "
                            + "remote px (adr/0015 §6.1, owner ruling U6) inside 3s. \(resizeResult.detail)"
                    )
                    check(
                        resizeResult.pointCheckPassed,
                        "move-resize scenario: resize leg POINT check -- the same target's top-left through "
                            + "WindowGeometry.windowsPoint (adr/0015 §6.3's paired assertion). \(resizeResult.detail)"
                    )
                    switch resizeResult.oscillation {
                    case .unjudgeable(let n):
                        print("[assert] N/A: move-resize scenario: resize leg oscillation is not judgeable "
                            + "(\(n) observation(s); no match, no observation, or no frozen topology -- see the "
                            + "leg-resolved line); not counted as PASS")
                    case .none, .oscillated:
                        check(!resizeResult.oscillated, "move-resize scenario: resize leg settled without oscillation")
                    }
                } else {
                    // Ungated, but still PAIRED and still fully reported -- adr/0015 §6.3 is about
                    // what a leg's verdict must SAY, and that does not change with whether the
                    // verdict counts toward `ok`.
                    print(
                        "[info] move-resize scenario: resize leg's target window was NOT resizable at send time "
                            + "(the default About target never is -- StyleTranslatorTests' aboutWindowsDialogShape; "
                            + "WINDOW_SMOKE_MOVE_TARGET picks a resizable one) -- "
                            + "legPassed=\(resizeResult.passed) oscillation=\(resizeResult.oscillation.text) "
                            + "rectCheck=\(resizeResult.rectCheckPassed ? "PASS" : "FAIL") "
                            + "pointCheck=\(resizeResult.pointCheckPassed ? "PASS" : "FAIL") "
                            + "\(resizeResult.detail), reported informationally, not gated"
                    )
                }
            } else {
                check(false, "move-resize scenario: the resize leg ran before the run ended (may be skipped if the move leg itself never resolved)")
            }
            // Fix 2 (team-lead review, 2026-08-23 real-host run): only gated once the close
            // leg actually got sent (`moveResizeCloseTargetId` set in the
            // `.awaitingResizeSettle` case above) -- if the resize leg itself never resolved
            // (already reported false above), there was no window left to reliably target a
            // close at, matching the maximize scenario's own "leg may be skipped" precedent.
            if let moveResizeCloseTargetId {
                if let moveResizeCloseResult {
                    check(
                        moveResizeCloseResult,
                        "move-resize scenario (Fix 2): SC_CLOSE for windowId=\(moveResizeCloseTargetId) produced a "
                            + "WindowDelete within 5s (harness cleanup -- avoids leaving a stale About window for a "
                            + "later WINDOW_SMOKE_CYCLES soak to lock onto)"
                    )
                } else {
                    check(false, "move-resize scenario: the close leg was sent before the run ended")
                }
            }
        }

        // adr/0010 W4 first slice (WINDOW_SMOKE_POPUP=1): menu-popup end-to-end acceptance
        // -- gated on the ADR's own three assertions: the popup appeared within 5s, it
        // carried a real owner attachment (adr/0010 §4), and Escape closed it within 3s.
        if popupScenarioEnabled {
            if let popupAppeared {
                check(popupAppeared, "popup scenario: a new window appeared within 5s of Alt+Space")
            } else {
                check(false, "popup scenario: a target window was locked and Alt+Space was sent before the run ended")
            }
            if popupAppeared == true {
                check(
                    popupAttachedAsChild == true,
                    "popup scenario: the new window carried a real ownerWindowId and was observed attached as a "
                        + "child of the About window (adr/0010 §4)"
                )
                // These two lines describe the LAST round only, and their "needs n>1 data"
                // framing is exactly what `WINDOW_SMOKE_POPUP_SAMPLES` > 1 supersedes -- so at
                // n>1 they are suppressed in favour of the real `[popup] samples=...` summary
                // (and its actual gate) a few lines below, rather than printing a stale
                // single-sample claim immediately above it. N==1 is untouched, byte for byte.
                if popupSamplesTotal == 1 {
                    if let created = popupCreatedAt, let firstContent = popupFirstContentAt {
                        print(String(
                            format: "[popup] WindowCreate→first-content: %.1fms (informational -- plan §4 W4's ≤100ms p95 gate needs n>1 data)",
                            (firstContent - created) * 1000
                        ))
                    } else {
                        print("[popup] WindowCreate→first-content: no content ever observed for the popup (informational -- some popup classes, e.g. a separator-only menu, may legitimately never present a GFX frame)")
                    }
                }
                check(
                    popupClosedAt != nil,
                    "popup scenario: Escape produced a WindowDelete within 3s"
                        + (popupEscapeSent ? "" : " (Escape was never actually sent -- the popup was never located in time)")
                )
            }
            // adr/0010 §5 + docs/plans/phase2.md §4 W4 (WINDOW_SMOKE_POPUP_SAMPLES > 1): the
            // multi-round sample summary and the ≤100ms p95 first-content gate the one-shot's
            // own informational print has been waiting on ("needs real n>1 data before it can
            // be enforced"). Nearest-rank percentiles, the same convention -- and the same
            // inline implementation -- the focus-rotation summary below uses.
            //
            // Deliberately silent at the default N==1: that run must stay byte-identical to
            // every prior popup run, right down to which lines it prints, so a single sample
            // stays informational exactly as adr/0010 §5 left it.
            if popupSamplesTotal > 1 {
                let okRounds = popupRoundResults.filter(\.ok).count
                let latencies = popupRoundResults.compactMap(\.latencyMs).sorted()
                func popupPercentileMs(_ p: Double) -> Double {
                    guard !latencies.isEmpty else { return 0 }
                    let rank = max(0, min(latencies.count - 1, Int((p * Double(latencies.count)).rounded(.up)) - 1))
                    return latencies[rank]
                }
                print(String(
                    format: "[popup] samples=%d ok=%d latencies p50=%.1fms p95=%.1fms max=%.1fms",
                    popupSamplesTotal, okRounds, popupPercentileMs(0.5), popupPercentileMs(0.95), latencies.last ?? 0
                ))
                check(
                    okRounds == popupSamplesTotal,
                    "popup scenario: all \(popupSamplesTotal) rounds opened an owner-attached popup that painted "
                        + "content and closed on Escape (got \(okRounds); \(popupRoundResults.count) round(s) ran, "
                        + "\(latencies.count) produced a real first-content latency)"
                )
                // Owner ruling 2026-08-31: the original <=100ms budget (docs/plans/phase2.md
                // §4 W4) was drafted against wired LAN; the formal n=20 run went over WLAN
                // and read p50=124.1 / p95=132.6 / max=134.3ms with a bimodal split (7x
                // 70-87ms -- inside the old gate -- vs 13x 119-134ms, a ~50ms void between,
                // shaped like a missed whole-frame encode window server-side; local present
                // p95 was 3ms). Gate relaxed to <=150ms as the WLAN acceptance bar; a wired
                // retest that would settle the bimodality is an OPTIONAL follow-up, and the
                // 100ms figure remains the wired-LAN aspiration, not this gate.
                check(
                    !latencies.isEmpty && popupPercentileMs(0.95) <= 150.0,
                    "popup scenario: WindowCreate→first-content p95 <= 150ms over \(latencies.count) sample(s) "
                        + "(WLAN gate per owner ruling 2026-08-31; 100ms stays the wired-LAN aspiration) (got "
                        + "\(latencies.isEmpty ? "no samples" : String(format: "%.1fms", popupPercentileMs(0.95))))"
                )
            }
            // Team-lead review: the About-window cleanup leg (`beginAboutCleanup`) always
            // runs, regardless of how the earlier legs resolved -- harness cleanup, avoids
            // leaving a stale About window for a later WINDOW_SMOKE_CYCLES soak to lock onto
            // (Fix 2's own precedent, `moveResizeCloseTargetId`'s doc comment).
            if let popupAboutCloseTargetId {
                check(
                    popupAboutCloseResult == true,
                    "popup scenario (cleanup): SC_CLOSE for windowId=\(popupAboutCloseTargetId) produced a "
                        + "WindowDelete within 5s (harness cleanup)"
                )
            } else {
                check(false, "popup scenario: the About-window cleanup close leg was sent before the run ended")
            }
        }

        // Phase 2 W0③: see checkFirstFrameGate's own doc comment -- every window this run
        // ever observed become visible must have done so either with content already
        // presented or via the logged 2s timeout, never neither.
        check(
            firstFrameGateViolations.isEmpty,
            "no window became visible without either displayed content or a logged first-frame "
                + "timeout (\(firstFrameGateViolations.count) violation(s)"
                + (firstFrameGateViolations.isEmpty ? "" : ": " + firstFrameGateViolations.joined(separator: "; "))
                + ")"
        )

        check(frameReadyCount > 0, "received >=1 FRAME_READY event during the run (got \(frameReadyCount))")

        // W4c review: the push-drain fix's own acceptance criterion -- p95 of
        // frameLatencySamplesMs should be well under the ~100ms average the old 0.2s-Timer
        // polling produced. See drainNow()'s own doc comment for exactly what's sampled.
        if let p95 = Self.percentile(0.95, of: frameLatencySamplesMs) {
            check(
                p95 < 20.0,
                "FRAME_READY push-to-present p95 latency is <20ms (got \(String(format: "%.2f", p95))ms across "
                    + "\(frameLatencySamplesMs.count) samples)"
            )
        } else {
            print("[info] no FRAME_READY-carrying drain batch was observed this run -- latency sampling skipped")
        }

        // User-reported "clicks don't work" review round: only meaningful in input-test
        // mode (runInputTest is the only place that sets this).
        if let keyWindowCheckResult {
            check(keyWindowCheckResult.passed, "window.canBecomeKey and isKeyWindow after makeKeyAndOrderFront (\(keyWindowCheckResult.detail))")
        } else if inputTestMode != nil {
            check(false, "window.canBecomeKey and isKeyWindow after makeKeyAndOrderFront (never ran -- no input-test target window was ever locked)")
        }

        let withContent = snapshots.filter(\.hasDisplayedContent).count
        if inputTestPassed && snapshots.isEmpty {
            // W4c review M2+M3: the input test already passed (its own assertion above
            // confirmed the target windowId's WindowDelete arrived in time) and this
            // registry now tracks literally zero windows at all -- meaning the input
            // test's own target was the only window this session had, and closing it via
            // a successful click/Enter is precisely what emptied `snapshots`. Requiring
            // "at least one window with content" in that specific situation would fail a
            // run for exactly the outcome the test was designed to produce. Every other
            // situation (input test not running, input test failed, or windows remain
            // tracked for any reason) keeps the unconditional, strict check below.
            print("[info] input test passed and left zero tracked windows (its target was the only one) -- "
                + "skipping the generic \"at least one window has non-nil layer.contents\" check")
        } else if trayScenarioEnabled && snapshots.isEmpty {
            // Same reasoning as the visible-RemoteWindow exemption above: a pure tray
            // driver legitimately produces zero windows (first live run: Windows-Terminal-
            // hosted PowerShell, working icon, no RAIL window) -- the tray gates are this
            // scenario's own content assertions.
            print("[info] tray scenario with zero tracked windows -- skipping the generic layer.contents check")
        } else {
            check(
                withContent > 0,
                "at least one window has non-nil layer.contents (got \(withContent) of \(snapshots.count) tracked windows)"
            )
        }

        check(evidenceRoutineRan, "evidence capture routine ran at the 15s mark")
        let screenshotCheck = screenshotWasProducedByThisRun()
        check(screenshotCheck.ok, "screenshot evidence was produced by this run: \(screenshotCheck.detail)")
        check(cleanShutdown, "final shutdownAndWait reported clean")

        print("\noverall: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}

// `NSApplication.shared` FIRST, then the delegate -- the same order `App/Macdows/main.swift` uses,
// and since M1 L9 it matters here too rather than being a stylistic difference: the delegate now
// owns a `DisplayTopologyProvider`, which reads `NSScreen` and registers for
// `NSApplicationDidChangeScreenParameters` in its initializer. Constructing an AppKit-reading
// object before AppKit's own singleton exists is the kind of ordering that works until it does
// not; the connect-time `freezeSessionSnapshot()` would still re-read correctly, but the launch
// read would be the one lying.
let app = NSApplication.shared
let delegate = WindowSmokeDelegate(
    host: host, user: user, pass: pass, screenshotPath: screenshotPath, launchedProgram: launchedProgram,
    launchedAppKind: launchedAppKind, inputTestMode: inputTestMode
)
// .accessory: no Dock icon/menu bar needed for a CLI verification harness, but this still
// needs to be a real running NSApplication (not headless) for NSWindow/CALayer/
// CATransaction to actually composite -- team-lead's explicit requirement.
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
