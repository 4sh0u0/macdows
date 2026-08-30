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

import AppKit
import CoreGraphics
import Foundation
import MacdowsCore

func parseEnvFile(_ path: String) -> [String: String] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        out[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
    }
    return out
}

func resolveCredential(_ fileEnv: [String: String], envVarName: String, fileKey: String) -> String? {
    if let fromEnv = ProcessInfo.processInfo.environment[envVarName], !fromEnv.isEmpty {
        return fromEnv
    }
    return fileEnv[fileKey]
}

let fileEnv = parseEnvFile(NSHomeDirectory() + "/.config/macdows/host.env")
guard
    let host = resolveCredential(fileEnv, envVarName: "WIN_HOST", fileKey: "WIN_HOST"),
    let user = resolveCredential(fileEnv, envVarName: "WIN_USER", fileKey: "WIN_USER"),
    let pass = resolveCredential(fileEnv, envVarName: "WIN_PASS", fileKey: "WIN_PASS"),
    !host.isEmpty, !user.isEmpty, !pass.isEmpty
else {
    print("window-smoke: missing WIN_HOST/WIN_USER/WIN_PASS (env vars, or ~/.config/macdows/host.env)")
    exit(2)
}
print(
    "window-smoke: credentials resolved (host=\(host.count) chars, user=\(user.count) chars, "
        + "pass=\(pass.count) chars -- values never printed)"
)

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
/// moves (then resizes) the About window's real `NSWindow` via `-setFrame:display:` and
/// asserts the settle path this fires round-trips through `CRSession.sendWindowMove` and
/// back via a real `WindowUpdate`. See `runMoveResizeScenario`'s own doc comment for the
/// acknowledged honesty gap against a genuine mouse-driven drag. Requires
/// WINDOW_SMOKE_EXTRA_APPS (multiwin prereq), same convention as WINDOW_SMOKE_MAXIMIZE.
let moveResizeScenarioEnabled = ProcessInfo.processInfo.environment["WINDOW_SMOKE_MOVE"] == "1"

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

    // Phase 1 acceptance state (see the extraApps/cyclesTotal globals' doc comments).
    private var extraAppsLaunched = false
    /// windowIds already present the moment the extra apps were exec'd -- the multi-window
    /// assertion only counts windows that appeared AFTER (2026-08-22 review HIGH: leftover
    /// windows from a long-lived session could satisfy a bare count with zero extra apps
    /// actually launching).
    private var windowIdsBeforeExtraApps: Set<UInt32> = []
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
    /// `grew`: did a WindowUpdate report width >=2000pt within 5s of SC_MAXIMIZE.
    /// `mappedWithContent`: was the window still mapped (visible, real content) at that
    /// point -- closes W0's deferred M1 acceptance debt ("a maximized window must build",
    /// phase2.md W0/M1) even on the failure path (checked at the 5s timeout too).
    private var maximizeResult: (grew: Bool, mappedWithContent: Bool)?
    /// Did a later WindowUpdate report width <1000pt within 5s of SC_RESTORE.
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
    /// `(matched, oscillated)` per leg -- `matched`: did any WindowUpdate-applied content
    /// rect for the target window round-trip to that leg's target within ±1pt inside the 3s
    /// budget. `oscillated`: did any LATER observed content rect in the same leg diverge
    /// from the target again after the first match (a real generic ping-pong detector isn't
    /// needed here -- this bounded window only needs "reaches the one target this leg cares
    /// about, and stays there").
    private var moveResult: (matched: Bool, oscillated: Bool)?
    private var resizeResult: (matched: Bool, oscillated: Bool)?
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
    /// geometry-carrying WindowUpdate/WindowCreate for `moveResizeWindowId`, recorded by
    /// `drainNow()`'s own event-kind switch, timestamped against `startTime` -- reset at the
    /// start of each leg so a leg's own oscillation check never sees the PRIOR leg's settle
    /// history. Each entry is `window.contentRect(forFrameRect: window.frame)` at the moment
    /// the WindowUpdate was applied (post `registry.handle(event)`), so a suppressed
    /// (ignored) echo during the in-flight gesture naturally never shows up here as a
    /// spurious "match" -- and so this scenario's own comparisons stay in the SAME rect
    /// space `RemoteWindow`/`RemoteWindowRegistry` actually round-trip through the wire,
    /// rather than the raw outer frame (which differs from content rect by this window's
    /// chrome insets once it's titled).
    private var moveResizeObservedContentRects: [(contentRect: NSRect, at: TimeInterval)] = []

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
        registry = RemoteWindowRegistry(session: newSession)
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
            let elapsed = self.startTime.map { Date().timeIntervalSince($0) } ?? -1
            print(
                "[move-resize] sent ClientWindowMove at elapsed=\(String(format: "%.3f", elapsed))s "
                    + "windowId=\(windowId) left=\(left) top=\(top) right=\(right) bottom=\(bottom)"
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
        // Remote desktop sized to the primary screen, matching the production
        // AppDelegate (server clamps remote windows to this desktop; see
        // CRSession.desktopWidth's doc for the drag-wall/click-desync failure mode).
        if let screen = NSScreen.screens.first {
            newSession.desktopWidth = UInt32(max(0, screen.frame.width))
            newSession.desktopHeight = UInt32(max(0, screen.frame.height))
        }
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
                self.moveResizeObservedContentRects.append((contentRect: contentRect, at: Date().timeIntervalSince(self.startTime)))
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

        checkFirstFrameGate(registry.windowSnapshots())
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
        let overallDeadline = max(
            max(rotationDeadline, maximizeDeadline),
            max(moveResizeDeadline, max(popupDeadline, inputScriptDeadline))
        )
        let rotationReady = focusRotationTotal == 0 || focusRotationDone || rotationStalled
        let maximizeReady = !maximizeScenarioEnabled || maximizePhase == .done || maximizeStalled
        let moveResizeReady = !moveResizeScenarioEnabled || moveResizePhase == .done || moveResizeStalled
        let popupReady = !popupScenarioEnabled || popupPhase == .done || popupStalled
        let inputScriptReady = !inputScriptScenarioActive || inputScriptComplete || inputScriptStalled
        if elapsed >= overallDeadline, rotationReady, maximizeReady, moveResizeReady, popupReady, inputScriptReady {
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

    private func finishCycle(session: CRSession, registry: RemoteWindowRegistry, rendered: Bool,
                             closed: Bool, seconds: Double) {
        let clean = session.shutdownAndWait()
        // Post-shutdown, a drain can NEVER clean the registry: shutdownAndWait's own
        // step-4 loop already consumed the .disconnected event, and its final step bumped
        // the generation, so everything still queued is stale-generation and gets
        // discarded (2026-08-22 review BLOCKER -- an earlier "forced drain" here delivered
        // zero events and proved nothing). The registry offers an explicit reset for
        // exactly this driver; the empty-check right after is the structural sanity assert.
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

        var ok = true
        func check(_ cond: Bool, _ message: String) {
            print("[assert] \(cond ? "PASS" : "FAIL"): \(message)")
            if !cond { ok = false }
        }

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
            if let snap, snap.frame.width >= 2000, snap.isVisible, snap.hasDisplayedContent {
                maximizeResult = (grew: true, mappedWithContent: true)
                print("[maximize] windowId=\(windowId) grew to \(Int(snap.frame.width))x\(Int(snap.frame.height)), still mapped with content")
                session.sendSysCommand(windowId, command: SC.restore)
                print("[maximize] sent SC_RESTORE to windowId=\(windowId)")
                maximizePhase = .awaitingRestore(windowId: windowId, sentAt: Date())
            } else if Date().timeIntervalSince(sentAt) >= Self.maximizePollTimeout {
                let mappedWithContent = snap?.isVisible == true && snap?.hasDisplayedContent == true
                maximizeResult = (grew: false, mappedWithContent: mappedWithContent)
                print("[maximize] windowId=\(windowId) FAILED to reach >=2000pt width within 5s "
                    + "(got \(snap.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "no snapshot"))")
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
            if let snap, snap.frame.width < 1000 {
                restoreResult = true
                print("[maximize] windowId=\(windowId) restored to \(Int(snap.frame.width))x\(Int(snap.frame.height))")
                session.sendSysCommand(windowId, command: SC.close)
                print("[maximize] sent SC_CLOSE to windowId=\(windowId)")
                maximizeCloseTargetId = windowId
                maximizePhase = .awaitingClose(windowId: windowId, sentAt: Date())
            } else if Date().timeIntervalSince(sentAt) >= Self.maximizePollTimeout {
                restoreResult = false
                print("[maximize] windowId=\(windowId) FAILED to restore below 1000pt width within 5s "
                    + "(got \(snap.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "no snapshot"))")
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
    /// the About window's real `NSWindow`, purely programmatically -- no human drag is
    /// available to an automated harness. Uses `-setFrame:display:`, which AppKit confirms
    /// posts `NSWindow.didMoveNotification` for a programmatic origin change exactly as it
    /// would for an interactive one, so this exercises the REAL production settle path
    /// (`RemoteWindow.handleLocalDidMove` -> 200ms debounce -> `onLocalGeometrySettled` ->
    /// `RemoteWindowRegistry.handleLocalGeometrySettled` -> `CRSession.sendWindowMove`) end
    /// to end, not a bypass or a direct call into any of those methods.
    ///
    /// HONESTY GAP (acknowledged, per the task spec's own wording): `-setFrame:display:`
    /// does NOT post `NSWindow.willStartLiveResizeNotification`/`didEndLiveResizeNotification`
    /// -- those fire ONLY for a genuine interactive (mouse-driven) resize, which nothing in
    /// this headless harness can produce. Both legs below therefore exercise the SAME
    /// didMove-debounce settle path `RemoteWindow` uses for a move, never the live-resize
    /// begin/end path it separately implements for an interactive resize -- that path has
    /// no automated coverage at all in this harness. The About window is additionally not
    /// resizable (StyleTranslatorTests' `aboutWindowsDialogShape`), so even a real
    /// interactive resize could never be driven against it regardless; `-setFrame:display:`
    /// still changes its frame at the wire/model level regardless of `styleMask`, which is
    /// what the resize leg actually verifies (does a programmatic geometry change round-trip
    /// through `ClientWindowMove` and back) -- at the acknowledged cost of the live-resize
    /// notification pair having zero coverage from any window in this run.
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
            guard let w = registry.windowSnapshots().first(where: { snap in
                snap.isVisible && snap.hasDisplayedContent
                    && (snap.title.localizedCaseInsensitiveContains("about") || snap.title.contains("关于"))
            }), let window = registry.window(forWindowId: w.windowId) else { return }
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
            // handleLocalDidMove` -> `settleLocalMove`) itself reports too -- comparing
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
            guard let outcome = evaluateMoveResizeLeg(target: target, sentAt: sentAt, matchPositionOnly: true) else { return }
            moveResult = outcome
            print("[move-resize] move leg resolved (position-only): matched=\(outcome.matched) oscillated=\(outcome.oscillated)")
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
            guard let outcome = evaluateMoveResizeLeg(target: target, sentAt: sentAt, matchPositionOnly: false) else { return }
            resizeResult = outcome
            print("[move-resize] resize leg resolved: matched=\(outcome.matched) oscillated=\(outcome.oscillated)")
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
    /// WindowUpdate-applied content rect recorded in `moveResizeObservedContentRects`
    /// matched `target` within ±1pt per axis -- and, once matched, did any LATER recorded
    /// content rect in the same leg diverge from `target` again (ping-pong)? Returns `nil`
    /// while the leg is still within budget and not yet resolved either way (neither
    /// matched-and-settled nor timed out) -- the caller polls this once per tick until it
    /// resolves.
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
    /// `WindowGeometry.macRect(from:primaryMonitorHeight:)`'s own formula is
    /// `y = primaryMonitorHeight - windowsY - height`, so when round 6's own remap-on-move
    /// finding changes a rect's height mid-leg, its mac-space Y shifts too even though the
    /// underlying Windows-space TOP edge never moved at all (this run: target computed at
    /// h=521 gave mac y=797; the observed rect, remapped to h=514, gave mac y=804 for the
    /// IDENTICAL Windows-space top=122). Comparing raw mac-space `x`/`y` for the
    /// `matchPositionOnly` case was therefore comparing two DIFFERENT physical quantities
    /// whenever height changed -- not a false positive from a genuine position error, but a
    /// coordinate-representation artifact. Fixed by converting BOTH `target` and each
    /// observed rect through the existing, already-tested `WindowGeometry.windowsRect(from:
    /// primaryMonitorHeight:)` (never a second, ad hoc coordinate-math implementation here,
    /// matching every other geometry boundary crossing in this project) and comparing the
    /// resulting Windows-space `x`/`y` (top-left, height-invariant by construction: each
    /// rect's own height is baked into ITS OWN conversion, so two rects that agree on the
    /// Windows-space top edge always compare equal regardless of what their heights happen
    /// to be). Scoped to `matchPositionOnly` only, per instruction ("keep everything else as
    /// is") -- the resize leg's full-rect path is untouched, since it already separately
    /// requires height to match, at which point the two representations agree anyway.
    private func evaluateMoveResizeLeg(target: NSRect, sentAt: Date, matchPositionOnly: Bool) -> (matched: Bool, oscillated: Bool)? {
        let primaryMonitorHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        func windowsTopLeft(_ r: NSRect) -> WindowsRect {
            WindowGeometry.windowsRect(
                from: MacRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height),
                primaryMonitorHeight: primaryMonitorHeight
            )
        }
        func closeEnough(_ a: NSRect) -> Bool {
            if matchPositionOnly {
                let aTopLeft = windowsTopLeft(a)
                let targetTopLeft = windowsTopLeft(target)
                return abs(aTopLeft.x - targetTopLeft.x) <= 1 && abs(aTopLeft.y - targetTopLeft.y) <= 1
            }
            let positionMatches = abs(a.origin.x - target.origin.x) <= 1 && abs(a.origin.y - target.origin.y) <= 1
            return positionMatches
                && abs(a.width - target.width) <= 1 && abs(a.height - target.height) <= 1
        }
        let contentRects = moveResizeObservedContentRects.map(\.contentRect)
        guard let firstMatchIndex = contentRects.firstIndex(where: closeEnough) else {
            if Date().timeIntervalSince(sentAt) >= Self.moveResizePollTimeout {
                return (matched: false, oscillated: false)
            }
            return nil
        }
        let oscillated = contentRects[(firstMatchIndex + 1)...].contains { !closeEnough($0) }
        // A brief settle window after the first match, so a late-arriving divergent
        // WindowUpdate still has a chance to be observed as oscillation before this leg
        // resolves -- unless oscillation has already been directly observed, in which case
        // there's nothing left to wait for.
        guard oscillated || Date().timeIntervalSince(sentAt) >= min(Self.moveResizePollTimeout, 1.0) else {
            return nil
        }
        return (matched: true, oscillated: oscillated)
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
        // Same plausible-content band (>=150x80) `finish()`'s own per-window size assertion
        // and `focusRotationCandidateWindows` use -- never a sliver/ghost window.
        guard let snapshot = registry.windowSnapshots().first(where: {
            $0.isVisible && $0.hasDisplayedContent && $0.frame.width >= 150 && $0.frame.height >= 80
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
    /// displayed content, same plausible-content band (`>=150x80`) `finish()`'s own
    /// per-window size assertion uses, sorted by windowId for a deterministic rotation
    /// order (window creation/arrival order is not guaranteed stable across a run).
    private func focusRotationCandidateWindows(_ registry: RemoteWindowRegistry) -> [RemoteWindowRegistry.WindowSnapshot] {
        registry.windowSnapshots()
            .filter { $0.isVisible && $0.hasDisplayedContent && $0.frame.width >= 150 && $0.frame.height >= 80 }
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

    private func finish() {
        drainTimer?.invalidate()
        drainTimer = nil

        let snapshots = registry.windowSnapshots()
        let visibleWindows = snapshots.filter(\.isVisible)
        let cleanShutdown = session.shutdownAndWait()

        var ok = true
        func check(_ cond: Bool, _ message: String) {
            print("[assert] \(cond ? "PASS" : "FAIL"): \(message)")
            if !cond { ok = false }
        }

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
            print("[tray] realIconMaxObserved=\(trayDiag.realIconMaxObserved) iconSkipped=\(trayDiag.iconSkippedCount) storeOverflow=\(trayDiag.storeOverflowCount)")
            check(trayDiag.createsSeen >= 1, "tray scenario saw at least one NotifyIconCreate (got creates=\(trayDiag.createsSeen))")
            check(
                trayDiag.realIconMaxObserved >= 1,
                "at least one NSStatusItem displayed the REAL remote icon bitmap while alive (adr/0013 acceptance) (realIconMaxObserved=\(trayDiag.realIconMaxObserved))"
            )
            // R1 finding 3: iconSkipped conflates three causes -- converter rejection,
            // side-store slot exhaustion, and the deferred CACHED_ICON variant (adr/0013
            // §2) -- so a red here says "an icon on the wire never became a bitmap", and
            // WHICH cause needs the bridge log line / storeOverflow counter to pin down.
            check(
                trayDiag.iconSkippedCount == 0,
                "no wire icon was skipped (converter rejection, store exhaustion, or a CACHED_ICON reference -- all three count here; got iconSkipped=\(trayDiag.iconSkippedCount))"
            )
            check(trayDiag.storeOverflowCount == 0, "icon store never overflowed (got storeOverflow=\(trayDiag.storeOverflowCount))")
        }

        // W4c: skip when an input test is active -- a *successful* click/Enter can
        // legitimately close the only window this session had open (observed in practice:
        // a lab session with nothing else left over from a prior round), which is the win
        // condition, not a failure. The input test's own assertion further down is what
        // actually gates this mode; this generic check was never designed with "the target
        // window's own successful closure empties the whole session" in mind.
        if inputTestMode == nil {
            check(!visibleWindows.isEmpty, "at least one visible RemoteWindow (got \(visibleWindows.count))")
            // Phase 1 acceptance: with extra apps launched into the same session, N NEW
            // visible content windows (windowIds not present at exec time) must have
            // appeared, and no ClientExecute may have failed -- a bare total count could
            // be satisfied by leftover windows from an earlier session with zero extra
            // apps actually launching (2026-08-22 review HIGH).
            if !extraApps.isEmpty {
                let newContentWindows = visibleWindows.filter {
                    // Same 150x80 floor as the per-window band assert below.
                    $0.frame.width >= 150 && $0.frame.height >= 80 && $0.hasDisplayedContent
                        && !windowIdsBeforeExtraApps.contains($0.windowId)
                }
                check(
                    newContentWindows.count >= extraApps.count,
                    "multi-window scenario: >=\(extraApps.count) NEW visible content windows appeared after the "
                        + "extra execs (got \(newContentWindows.count): "
                        + "\(newContentWindows.map(\.title).joined(separator: " | ")))"
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

        // H3, revised for Phase 2 W0① (docs/plans/phase2.md W0①): every visible window's
        // size must clear a broad, non-brittle plausible-content floor. The upper bound
        // this band used to carry (2000pt) existed only to independently catch a
        // regression in RemoteWindowRegistry's now-removed size-only cap (`isLikelyContentWindow`,
        // `width>=2000 && height>=1000`) -- W0① replaced that cap with a style/owner-based
        // filter (adr/0008 §3), and a maximized real content window is now explicitly
        // SUPPOSED to become a large visible RemoteWindow, so re-imposing that same 2000pt
        // ceiling here would silently reintroduce the exact regression this pass exists to
        // fix. The desktop-container window itself ("Program Manager") is still excluded
        // -- now by RemoteWindowRegistry's style check, not by this harness duplicating a
        // size heuristic -- so no upper bound is needed to catch that specific case
        // anymore. What remains is a generous garbage-value sanity net only, one order of
        // magnitude under RemoteWindowRegistry's own 16384 hard ceiling
        // (WindowMappability.isMappableWindow), loose enough that no plausible maximized
        // window on any real display trips it. No maximize e2e is added here (deferred to
        // W2 -- no SysCommand lever exposed yet); this only stops the band itself from
        // becoming a second place a maximize regression would need fixing.
        for w in visibleWindows {
            let width = w.frame.width
            let height = w.frame.height
            // Band floor 150x80, not the original 300x300: the Phase 1 acceptance matrix
            // surfaced real, legitimate short dialogs (dxdiag's initial progress window is
            // 478x188 against the lab host) that 300x300 wrongly rejected. 150x80 still
            // excludes every RAIL helper class actually observed (1x1 bookkeeping windows,
            // the 136x39 tray helper, 1009x4 edge strips) -- which is this band's job.
            check(
                width >= 150 && height >= 80 && width < 10000 && height < 10000,
                "visible window \"\(w.title)\" (id \(w.windowId)) size is in the plausible-content band "
                    + "(got \(width)x\(height))"
            )
        }

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
                let w = aboutWindow.frame.width
                let h = aboutWindow.frame.height
                // Tighter band than the general one above: the actual About Windows dialog
                // is consistently ~536x521 against the real lab host; some slack for
                // DPI/theme differences, but tight enough to still mean something as an
                // anchor.
                check(
                    w >= 400 && w <= 700 && h >= 400 && h <= 700,
                    "the About-Windows-anchored window's size matches winver.exe's dialog (got \(w)x\(h))"
                )
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
                    "maximize scenario: SC_MAXIMIZE grew the About window to >=2000pt width within 5s"
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
                check(restoreResult, "maximize scenario: SC_RESTORE shrank the window back below 1000pt width within 5s")
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
        // drag) and why the resize leg still runs against the (non-resizable) About window
        // anyway.
        if moveResizeScenarioEnabled {
            if let moveResult {
                // Team-lead review round 6: POSITION-only, not full-rect -- see
                // evaluateMoveResizeLeg's own doc comment for why size is out of scope for a
                // pure move (the server's own prerogative to remap the surface mid-move,
                // observed live this round).
                check(
                    moveResult.matched,
                    "move-resize scenario: move leg's WindowUpdate round-tripped to the new POSITION (±1pt) "
                        + "within 3s -- size is not asserted here, it is the server's own prerogative for a pure "
                        + "move (see runMoveResizeScenario's own doc comment)"
                )
                check(
                    !moveResult.oscillated,
                    "move-resize scenario: move leg settled without POSITION oscillation (no later WindowUpdate "
                        + "diverged from the matched target's x/y)"
                )
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
                        resizeResult.matched,
                        "move-resize scenario: resize leg's WindowUpdate round-tripped to the new content rect "
                            + "within ±1pt within 3s"
                    )
                    check(!resizeResult.oscillated, "move-resize scenario: resize leg settled without oscillation")
                } else {
                    print(
                        "[info] move-resize scenario: resize leg's target window was NOT resizable at send time "
                            + "(About is never resizable -- StyleTranslatorTests' aboutWindowsDialogShape) -- "
                            + "matched=\(resizeResult.matched) oscillated=\(resizeResult.oscillated), reported "
                            + "informationally, not gated"
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
                check(
                    !latencies.isEmpty && popupPercentileMs(0.95) <= 100.0,
                    "popup scenario: WindowCreate→first-content p95 <= 100ms over \(latencies.count) sample(s) "
                        + "(docs/plans/phase2.md §4 W4's LAN gate) (got "
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

let delegate = WindowSmokeDelegate(
    host: host, user: user, pass: pass, screenshotPath: screenshotPath, launchedProgram: launchedProgram,
    launchedAppKind: launchedAppKind, inputTestMode: inputTestMode
)
let app = NSApplication.shared
// .accessory: no Dock icon/menu bar needed for a CLI verification harness, but this still
// needs to be a real running NSApplication (not headless) for NSWindow/CALayer/
// CATransaction to actually composite -- team-lead's explicit requirement.
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
