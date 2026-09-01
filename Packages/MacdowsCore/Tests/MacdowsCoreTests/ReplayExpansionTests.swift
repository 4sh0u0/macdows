import Foundation
import Testing
@testable import MacdowsCore

/// W2 batch 2 Lane A (D10): replay-driven coverage expansion for the *pure decision layer* —
/// `WindowGeometry`, `MinMaxInfoTranslator`, `StyleTranslator`, `WindowMappability`,
/// `FocusAuthority` (server half) — fed from the same six-scenario JSONL replays
/// `ReplayTests` already drives (this file reuses `ReplayTests.replay(_:)`/`Scenario`
/// directly; same test target, so the internal helpers are visible — nothing is copied).
///
/// Two layers, same split as `ReplayTests`' own layering MARK:
///  * PORTABLE INVARIANTS — must hold for ANY legal recording (frozen baseline *and* an
///    upgrade-gate candidate re-record). Unconditional.
///  * FROZEN-BASELINE FEATURE PINS — pin the 2026-08-19 session's exact translated outputs;
///    gated on `ReplayTests.samplesDirIsFrozenBaseline` (content fingerprint), visible skip
///    otherwise.
///
/// COVERAGE BOUNDARY, registered deliberately (not an oversight) — what replaying these
/// captures CANNOT falsify, and which synthetic-event suite owns each gap instead:
///
///  * `ZOrderSync` / `WindowShape`: the probe cannot feed them — `rail-probe.c`'s
///    `probe_monitored_desktop` (`Tools/rail-probe/rail-probe.c:597-599`) logs only
///    `fieldFlags`/`activeWindowId`/`numWindowIds`, never the `windowIds` *array* a
///    `ZOrderSync` replay would need; likewise the window-order call sites log
///    `numVisibilityRects` as a count only, never the visibility rect list `WindowShape`
///    consumes. Covered by `ZOrderSyncTests`/`WindowShapeTests`.
///  * `WindowMappability`'s `WS_CHILD` and owner branches (r1 review H2): no phase05
///    sample ever sets `WS_CHILD` on a top-level order, and `ownerWindowId` always decodes
///    0 (the probe never logged it) — `ReplayTests`' own W0① coverage note has said so all
///    along. A cross-contract "mappable ⇒ no WS_CHILD" assertion is therefore vacuously
///    true against these samples (r1 verified: deleting the production guard outright
///    stays green), so this file asserts nothing about it. Covered by
///    `WindowMappabilityTests`/`WindowModelTests` synthetic events.
///  * `WindowGeometry` round-trips (r1 review M5): the 1x/2x remote↔pt exact-identity
///    contract is already pinned by `WindowGeometryTests.rectRoundTripIsIdentityAcrossScalesAndOffsets`
///    (+ point/rail-display variants) over a strict superset of what any capture can
///    supply — scales 1 AND 2, off-screen rects, zero-size rects, odd offsets. A
///    sample-fed copy at scale 1 adds no falsification power (the arithmetic is
///    input-independent), so this file deliberately has none.
///  * `FocusAuthority.resignKey` (r1 review H3): producing it on the server-only path
///    needs a truth transition AWAY from a keyed window (window→different-window /
///    →desktop / →unmonitored *after* a window truth); in every phase05 capture the single
///    `.window` truth (328256) is the FINAL MonitoredDesktop of its scenario, so no sample
///    can emit one. Covered by `FocusAuthorityTests` synthetic sequences.
@Suite("ReplayExpansion")
struct ReplayExpansionTests {
    typealias Scenario = ReplayTests.Scenario

    // MARK: - Shared extraction helpers

    /// All `WindowCreate` + `WindowUpdate` payloads of one replay, in event order.
    static func windowOrderPayloads(_ replay: ReplayTests.Replay) -> [WindowOrderPayload] {
        replay.events.compactMap {
            switch $0.kind {
            case .windowCreate(let p), .windowUpdate(let p): return p
            default: return nil
            }
        }
    }

    /// All `ServerMinMaxInfo` events' track-size fields, in event order.
    static func minMaxTrackFields(_ replay: ReplayTests.Replay)
        -> [(minTrackWidth: Int32, minTrackHeight: Int32, maxTrackWidth: Int32, maxTrackHeight: Int32)] {
        replay.events.compactMap {
            if case .serverMinMaxInfo(_, _, _, _, _, let minW, let minH, let maxW, let maxH) = $0.kind {
                return (minW, minH, maxW, maxH)
            }
            return nil
        }
    }

    /// All `MonitoredDesktop` events' `(activeWindowId, tMs)`, in event order.
    static func monitoredDesktopFeed(_ replay: ReplayTests.Replay) -> [(raw: UInt32, tMs: UInt64)] {
        replay.events.compactMap {
            if case .monitoredDesktop(_, let active, _) = $0.kind { return (active, $0.tMs) }
            return nil
        }
    }

    /// One window's final-state chrome decision, rendered as a stable, greppable line —
    /// the exact string shape both the feature-pin tables below and the export command in
    /// their doc comment use, so the pinned literals and the runtime value can never drift
    /// in format. `s` (hasShadow) is included for completeness even though the portable
    /// invariant below already pins it `true` unconditionally.
    static func chromeDescriptor(windowId: UInt32, _ c: WindowChrome) -> String {
        "\(windowId)|t\(c.titled ? 1 : 0)c\(c.closable ? 1 : 0)m\(c.miniaturizable ? 1 : 0)"
            + "z\(c.zoomable ? 1 : 0)r\(c.resizable ? 1 : 0)s\(c.hasShadow ? 1 : 0)"
            + "L\(c.level == .floating ? "f" : "n")"
    }

    /// One translated `WindowTrackSizeConstraints`, rendered as a stable line; `-` is a
    /// `nil` (unconstrained) bound. Same format-stability role as `chromeDescriptor`.
    static func trackSizeDescriptor(_ k: WindowTrackSizeConstraints) -> String {
        func f(_ v: Double?) -> String { v.map { String(Int($0)) } ?? "-" }
        return "min=\(f(k.minWidth))x\(f(k.minHeight)),max=\(f(k.maxWidth))x\(f(k.maxHeight))"
    }

    /// Final-state chrome decision set for one replay: what the live pipeline would feed
    /// `RemoteWindow` per window, via the real `StyleTranslator.chrome` on each window's
    /// final merged state (matching `w0StyleFilterDropsExpectedWindowIdSet`'s final-state
    /// evaluation rationale).
    static func finalChromeDescriptors(_ replay: ReplayTests.Replay) -> Set<String> {
        Set(replay.model.windows.map { windowId, w in
            chromeDescriptor(
                windowId: windowId,
                StyleTranslator.chrome(
                    style: w.style, styleEx: w.styleEx,
                    hasTitle: !w.title.isEmpty, ownerWindowId: w.ownerWindowId
                )
            )
        })
    }

    // MARK: - Portable invariants (run against frozen baseline AND any candidate)

    /// Upgrade-gate assertion ② (W2 item 2; adr/0005 §7 "探针 tid 日志升级为升级门回归
    /// 断言"): the three producer lanes must ride pairwise-DISJOINT thread ids on any
    /// legal recording — `Gfx*` on the DVC thread, window/tray orders on the update
    /// thread, `Server*` RAIL callbacks on the rail channel thread. The three-way split
    /// follows the MEASURED model (`EventLane`'s three lanes; adr/0005's prose groups
    /// RAIL control with orders on "T_rdp", which the frozen captures refine into two
    /// distinct tids — the assertion follows the measurement). This is the recording-side
    /// half of the AsyncUpdate guard: the runtime half (both stacks refuse a session with
    /// `FreeRDP_AsyncUpdate=TRUE`) lives in `crb_post_connect`/`probe_post_connect`, and
    /// this half reds if any upstream change starts delivering one lane's callbacks from
    /// another lane's thread — and each lane must be exactly ONE thread per capture (a
    /// capture is one connection; a thread-pooled DVC model would keep the lanes disjoint
    /// while breaking the risk row's "改 DVC 模型" premise, so disjointness alone is not
    /// enough — review r3 finding L3).
    ///
    /// Classification is by `RailEventKind` case and follows `EventLane`'s discipline
    /// exactly, including its refusals (review r3 M1): only MEASURED lane memberships are
    /// asserted. `windowDelete`/`nonMonitoredDesktop`/`codecStats` occur zero times in
    /// the frozen captures AND the 2026-09-01 candidate, so they are deliberately
    /// EXCLUDED — an unmeasured lane assignment here would feed a manufactured finding
    /// straight into a gate assertion, the exact hazard `EventLane.ambiguous` exists to
    /// prevent. The switch is exhaustive with no default (r3 M2): a future
    /// `RailEventKind` case is a compile error and must be classified — or excluded — by
    /// a reviewed edit. Other exclusions and why (r3 L1/L2): `channelConnected`/
    /// `channelDisconnected` are the two names measured on more than one thread
    /// (`EventLane.ambiguousEventNames`); the probe's own main-loop emissions
    /// (Pre/PostConnect, ConnectSucceeded, DurationElapsed, SecondExec*, failure marks)
    /// are single-threaded but are not producer-lane traffic at all; and
    /// `clientRailServerStartCmd` is the probe's own SEND-side log line — measured riding
    /// the order tid, but it is not a server callback, and excluding it is load-bearing
    /// (classifying it into the server lane would break pairwise disjointness at once).
    ///
    /// Anti-vacuity: all three lanes are non-empty in every frozen scenario AND in the
    /// 2026-09-01 candidate re-record (s2's no-HiDef path still carries 2
    /// GfxResetGraphics — the RDPGFX channel connects either way). A future legal
    /// recording with a genuinely absent gfx channel would red here — like
    /// `s3TwoSuccessfulExecs`, that red means "check what the session did" before
    /// blaming the recording.
    @Test("adr/0005 tid separation: gfx / order / server lanes are one thread each, pairwise disjoint", arguments: Scenario.allCases)
    func lanesRidePairwiseDisjointTids(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        var gfxTids: Set<String> = []
        var orderTids: Set<String> = []
        var serverTids: Set<String> = []
        for event in replay.events {
            switch event.kind {
            case .gfxMapSurfaceToWindow, .gfxMapSurfaceToScaledWindow, .gfxResetGraphics,
                 .gfxCapsAdvertise, .gfxCapsConfirm:
                gfxTids.insert(event.tid)
            case .windowCreate, .windowUpdate, .windowIcon, .windowCachedIcon,
                 .notifyIconCreate, .notifyIconUpdate, .notifyIconDelete,
                 .monitoredDesktop:
                orderTids.insert(event.tid)
            case .serverHandshake, .serverHandshakeEx, .serverExecuteResult, .serverSystemParam,
                 .serverLocalMoveSize, .serverMinMaxInfo, .serverZOrderSync,
                 .serverGetAppIdResponse:
                serverTids.insert(event.tid)
            // Unmeasured in every frozen capture and the candidate — deliberately
            // unclassified (see the doc comment; assigning a lane nobody measured is the
            // manufactured-finding hazard).
            case .windowDelete, .nonMonitoredDesktop, .codecStats:
                continue
            // Not producer-lane traffic: the two genuinely multi-threaded lifecycle
            // names, the probe main loop's own emissions, and the probe's send-side RAIL
            // log (order-tid-riding but not a server callback — load-bearing exclusion).
            case .channelConnected, .channelDisconnected,
                 .preConnect, .postConnect, .postDisconnect, .postFinalDisconnect,
                 .secondExecBegin, .secondExecEnd, .connectFailed, .connectSucceeded,
                 .eventHandlesFailed, .waitFailed, .checkEventHandlesFailed,
                 .durationElapsed, .clientRailServerStartCmd,
                 .verifyCertificateEx, .logonErrorInfo, .unknown:
                continue
            }
        }
        #expect(!gfxTids.isEmpty, "no gfx-lane traffic in \(scenario) — check the session before blaming the recording")
        #expect(!orderTids.isEmpty, "no order-lane traffic in \(scenario)")
        #expect(!serverTids.isEmpty, "no server-lane traffic in \(scenario)")
        for (lane, tids) in [("gfx", gfxTids), ("order", orderTids), ("server", serverTids)] {
            #expect(tids.count == 1,
                    "\(lane) lane rode \(tids.count) threads in \(scenario) — one connection is one thread per lane")
        }
        #expect(gfxTids.isDisjoint(with: orderTids),
                "gfx and order lanes shared threads \(gfxTids.intersection(orderTids)) in \(scenario)")
        #expect(gfxTids.isDisjoint(with: serverTids),
                "gfx and server lanes shared threads \(gfxTids.intersection(serverTids)) in \(scenario)")
        #expect(orderTids.isDisjoint(with: serverTids),
                "order and server lanes shared threads \(orderTids.intersection(serverTids)) in \(scenario)")
    }

    // (r1 review M5: the WindowGeometry round-trip test that stood here was DELETED — see
    // the COVERAGE BOUNDARY entry in the header. `WindowGeometryTests` already pins the
    // identity over a strict superset of anything a capture can feed it.)

    /// `MinMaxInfoTranslator` contract (its own doc comment): `0` and negative wire values
    /// are sentinels/corruption, filtered to `nil` — "never handed to
    /// `NSWindow.minSize`/`.maxSize` as a literal". The contract-level invariant that
    /// leaves: translation is total (no trap on any wire value), and every non-`nil`
    /// bound is strictly positive. (`min <= max` is deliberately NOT asserted: the
    /// translator's contract sanitizes fields independently and promises no cross-field
    /// relationship — asserting one would be inventing a contract.)
    @Test("MinMaxInfoTranslator: total over every ServerMinMaxInfo event, and every non-nil bound is strictly positive", arguments: Scenario.allCases)
    func minMaxTranslationIsTotalAndSanitized(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        let fields = Self.minMaxTrackFields(replay)
        #expect(!fields.isEmpty, "no ServerMinMaxInfo events in \(scenario) — invariant would be vacuous")

        var sawAnyConstrainedBound = false
        for f in fields {
            let k = MinMaxInfoTranslator.constraints(
                minTrackWidth: f.minTrackWidth, minTrackHeight: f.minTrackHeight,
                maxTrackWidth: f.maxTrackWidth, maxTrackHeight: f.maxTrackHeight
            )
            for bound in [k.minWidth, k.minHeight, k.maxWidth, k.maxHeight] {
                if let bound {
                    sawAnyConstrainedBound = true
                    #expect(bound > 0, "sanitized bound must be strictly positive, got \(bound)")
                }
            }
        }
        // Anti-vacuity for the implication itself: real captures carry real track sizes
        // (e.g. s1's 136x39/2580x1460), so at least one non-nil bound must exist — a feed
        // of all-sentinel zeros would make the positivity check above assert nothing.
        #expect(sawAnyConstrainedBound, "every bound decoded as nil in \(scenario) — positivity invariant never exercised")
    }

    /// CONSTANT PIN, sample-independent and honestly labeled as such (r1 review M6/H2):
    /// `WindowChrome.hasShadow`'s contract declares "Always `true` today", and both of
    /// `StyleTranslator.chrome`'s return paths hard-code it. This single synthetic call per
    /// path pins that regression surface — replaying hundreds of sample orders through it
    /// adds nothing (the value is input-independent), so this deliberately does NOT claim
    /// to be replay-driven coverage and takes no scenario argument. The former companion
    /// assertion here ("mappable ⇒ no WS_CHILD") was DELETED per r1 H2: unfalsifiable
    /// against these samples — see the COVERAGE BOUNDARY entry in the header.
    @Test("StyleTranslator: hasShadow contract constant pin ('Always true today') — both return paths, sample-independent")
    func chromeHasShadowContractConstantPin() {
        // Path 1: no chrome-implying bits (bare WS_POPUP) -> the borderless branch.
        let borderless = StyleTranslator.chrome(style: 0x8000_0000, styleEx: 0, hasTitle: false, ownerWindowId: 0)
        #expect(borderless.hasShadow, "borderless branch violated WindowChrome.hasShadow's 'Always true today' contract")
        // Path 2: decorated (WS_SYSMENU set) -> the titled branch.
        let decorated = StyleTranslator.chrome(style: 0x0008_0000, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(decorated.hasShadow, "decorated branch violated WindowChrome.hasShadow's 'Always true today' contract")
    }

    /// The `FocusState` a server-only-fed machine must be in immediately after one truth,
    /// per the adr/0012 §3 three-way classification `ServerActiveWindow` implements and
    /// `serverDesktopUpdate`'s own "no local activation in flight: follow the server's own
    /// truth immediately" contract branch (row 1). Shared by the portable invariant and
    /// the frozen pin below.
    static func mirroredState(ofRawTruth raw: UInt32) -> FocusState {
        switch ServerActiveWindow(rawActiveWindowId: raw) {
        case .window(let id): return .converged(windowId: id)
        case .desktopFocused: return .desktopFocused
        case .unmonitored: return .unmonitored
        }
    }

    /// One `FocusAuthorityEffect`, rendered as a stable line — same format-stability role
    /// as `chromeDescriptor` (shared by the frozen pin's export and its assertion).
    static func effectDescriptor(_ e: FocusAuthorityEffect) -> String {
        switch e {
        case .sendActivate(let id): return "sendActivate(\(id))"
        case .makeKey(let id): return "makeKey(\(id))"
        case .resignKey(let id): return "resignKey(\(id))"
        case .flushBufferedInput(let events): return "flush(\(events.count))"
        case .dropBufferedInput(let count, let mod): return "drop(\(count),mod=\(mod))"
        case .warn(let warning): return "warn(\(warning))"
        }
    }

    /// `FocusAuthority` server half: feed every `MonitoredDesktop.activeWindowId` in event
    /// order (local event domain deliberately NOT fed — this is the pure server-truth
    /// path; `at:` is passed as the sample's own `t_ms`, though `serverDesktopUpdate`'s
    /// current implementation never reads it — noted honestly, not claimed as exercised).
    ///
    /// r1 review H3 rebuilt this test around what the review's own probe established:
    /// s1/s2 feeds contain NO `.window` truth (their composition is 2x `desktopFocused` +
    /// N x `unmonitored`), so a terminal-state-only check is satisfied by a no-op there.
    /// The invariant is therefore asserted PER STEP — contract row 1 says the machine
    /// follows each truth *immediately*, so after every single update the state must equal
    /// that truth's mirror. A no-op'd `serverDesktopUpdate` now fails in ALL six scenarios
    /// (every frozen and candidate scenario contains `desktopFocused` truths that a
    /// no-op'd machine, stuck at the initial `.unmonitored`, does not mirror) — verified
    /// by production-side mutation, see the lane report.
    ///
    /// Effects, data-driven rather than scenario-hardcoded:
    ///  * a feed containing >= 1 `.window` truth MUST produce >= 1 `.makeKey` — the first
    ///    `.window(id)` truth arrives with nothing keyed (nil != id), and row 1 emits
    ///    `.makeKey(id)` for exactly that case;
    ///  * a feed with ZERO `.window` truths must produce ZERO effects — the truthful
    ///    contract expectation (desktop/unmonitored follows with nothing keyed emit no
    ///    effect), pinned as such. For THIS half a no-op is observationally identical by
    ///    contract — its detection power lives in the per-step mirroring above, not here;
    ///  * whatever is produced can only be `.makeKey`/`.resignKey` (buffering, flushing,
    ///    warnings, re-arms all belong to the converging epoch that never exists on this
    ///    path). `.resignKey` itself is sample-unreachable — registered in the COVERAGE
    ///    BOUNDARY header, owned by `FocusAuthorityTests`.
    @Test("FocusAuthority: server-only feed mirrors every truth immediately (per-step), with data-driven effect expectations", arguments: Scenario.allCases)
    func focusAuthorityServerFeedConverges(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        let feed = Self.monitoredDesktopFeed(replay)
        #expect(!feed.isEmpty, "no MonitoredDesktop events in \(scenario) — invariant would be vacuous")

        // Anti-vacuity for the per-step mirror itself: a feed whose every truth classifies
        // as `.unmonitored` (== the machine's initial state) could not distinguish
        // following from a no-op. Every known-legal recording carries at least the
        // desktop-focused composition truths; a recording without any is a data shape this
        // suite has never seen and must be looked at, not silently passed.
        let mirrors = feed.map { Self.mirroredState(ofRawTruth: $0.raw) }
        #expect(
            mirrors.contains { $0 != .unmonitored },
            "every truth in \(scenario) classifies as .unmonitored — per-step mirroring could not falsify a no-op"
        )

        let authority = FocusAuthority()
        var effects: [FocusAuthorityEffect] = []
        for (index, entry) in feed.enumerated() {
            effects += authority.serverDesktopUpdate(rawActiveWindowId: entry.raw, at: Double(entry.tMs) / 1000.0)
            #expect(
                authority.state == mirrors[index],
                "step \(index) (raw \(entry.raw)): state \(authority.state) does not mirror the truth just fed"
            )
        }

        let windowTruthCount = mirrors.reduce(0) { if case .converged = $1 { return $0 + 1 } else { return $0 } }
        let makeKeyCount = effects.reduce(0) { if case .makeKey = $1 { return $0 + 1 } else { return $0 } }
        if windowTruthCount > 0 {
            #expect(makeKeyCount > 0, "\(windowTruthCount) window truth(s) fed but no makeKey emitted")
        } else {
            #expect(effects.isEmpty, "no window truth in the feed, yet effects were emitted: \(effects.map(Self.effectDescriptor))")
        }

        for effect in effects {
            switch effect {
            case .makeKey, .resignKey: break
            default:
                Issue.record("server-only feed produced non-follow effect \(Self.effectDescriptor(effect)) — contract allows only makeKey/resignKey on this path")
            }
        }
    }

    // MARK: - Frozen-baseline feature pins (gated, visible skip on any other recording)

    /// Expected final-state chrome decision per window, per scenario — EXPORTED, not
    /// hand-derived: produced by running the real `StyleTranslator.chrome` over each
    /// frozen replay's final `WindowModel` state via `finalChromeDescriptors(_:)` and
    /// printing `chromeDescriptor` lines (a temporary in-target export test, run once on
    /// 2026-09-01 against the fingerprint-verified frozen samples, then deleted — the
    /// forbidden alternative, re-deriving bit logic by hand, is exactly what this suite's
    /// header rules out). Descriptor format: `windowId|t..c..m..z..r..s..L(n|f)` =
    /// titled/closable/miniaturizable/zoomable/resizable/hasShadow/level.
    ///
    /// Reading the pinned data (cross-checked against the style evidence already recorded
    /// in `ReplayTests`' W0① comment): exactly one window per scenario gets full content
    /// chrome (`t1c1m1z1r1` — the 0xF0000 Notepad/RegEdit-class window 328256), one gets
    /// dialog chrome (`t1c1m0z0r0Ln` — 590880, the About-Windows-class 0x80080000), the
    /// four ghost-sliver helpers (983208/132042/132028/66450, style 0x800B0000 +
    /// WS_EX_TOPMOST) get `t1c1m0z0r0Lf` (SYSMENU implies titled+closable; TOOLWINDOW
    /// suppresses min/zoom; topmost floats), and every bare-WS_POPUP window is untitled
    /// with level tracking its own WS_EX_TOPMOST bit.
    static let expectedChromeDescriptors: [Scenario: Set<String>] = [
        .s1: [
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "328256|t1c1m1z1r1s1Ln",
            "328280|t0c0m0z0r0s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "918094|t0c0m0z0r0s1Lf",
            "983208|t1c1m0z0r0s1Lf",
        ],
        .s2: [
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "1573240|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "328256|t1c1m1z1r1s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "917764|t0c0m0z0r0s1Ln",
            "983208|t1c1m0z0r0s1Lf",
        ],
        .s3: [
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "2425392|t0c0m0z0r0s1Lf",
            "328256|t1c1m1z1r1s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "5898488|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "983208|t1c1m0z0r0s1Lf",
        ],
        .s4: [
            "1048700|t0c0m0z0r0s1Ln",
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "1704536|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "328256|t1c1m1z1r1s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "983208|t1c1m0z0r0s1Lf",
        ],
        .s5a: [
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "2950242|t0c0m0z0r0s1Ln",
            "328256|t1c1m1z1r1s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "983208|t1c1m0z0r0s1Lf",
            "983518|t0c0m0z0r0s1Lf",
        ],
        .s5b: [
            "131948|t0c0m0z0r0s1Ln",
            "131976|t0c0m0z0r0s1Lf",
            "132028|t1c1m0z0r0s1Lf",
            "132042|t1c1m0z0r0s1Lf",
            "132112|t0c0m0z0r0s1Lf",
            "1638650|t0c0m0z0r0s1Ln",
            "1638988|t0c0m0z0r0s1Lf",
            "197612|t0c0m0z0r0s1Lf",
            "328256|t1c1m1z1r1s1Ln",
            "393802|t0c0m0z0r0s1Lf",
            "524454|t0c0m0z0r0s1Ln",
            "590880|t1c1m0z0r0s1Ln",
            "65982|t0c0m0z0r0s1Lf",
            "65992|t0c0m0z0r0s1Ln",
            "65994|t0c0m0z0r0s1Ln",
            "65996|t0c0m0z0r0s1Ln",
            "65998|t0c0m0z0r0s1Ln",
            "66034|t0c0m0z0r0s1Ln",
            "66066|t0c0m0z0r0s1Ln",
            "66450|t1c1m0z0r0s1Lf",
            "66462|t0c0m0z0r0s1Lf",
            "66472|t0c0m0z0r0s1Lf",
            "983208|t1c1m0z0r0s1Lf",
        ],
    ]

    @Test(
        "frozen pin: StyleTranslator's final-state chrome decision set per scenario, exact and element-wise",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func frozenChromeDecisionSet(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        let actual = Self.finalChromeDescriptors(replay)
        let expected = Self.expectedChromeDescriptors[scenario]!
        #expect(
            actual == expected,
            "chrome decision set mismatch for \(scenario): only-in-actual \(actual.subtracting(expected).sorted()), only-in-expected \(expected.subtracting(actual).sorted())"
        )
    }

    /// Expected `ServerMinMaxInfo` event count + deduplicated translated constraint set,
    /// per scenario — exported the same way as `expectedChromeDescriptors` (real
    /// `MinMaxInfoTranslator.constraints` over every event of the fingerprint-verified
    /// frozen samples, deduplicated via `trackSizeDescriptor`, printed, pasted; same
    /// 2026-09-01 export run). The counts sum to the 122 `ServerMinMaxInfo` events the W2
    /// event census recorded across the six files. `min=-x-` is both min bounds decoding
    /// as the 0-sentinel → `nil`.
    static let expectedMinMaxPins: [Scenario: (count: Int, dedupedTranslations: Set<String>)] = [
        .s1: (20, ["min=-x-,max=2580x1460", "min=136x39,max=1044x788", "min=136x39,max=2580x1460"]),
        .s2: (20, ["min=-x-,max=1044x788", "min=136x39,max=1044x788"]),
        .s3: (20, ["min=-x-,max=1044x788", "min=136x39,max=1044x788"]),
        .s4: (21, ["min=-x-,max=1044x788", "min=136x39,max=1044x788"]),
        .s5a: (21, ["min=-x-,max=1044x788", "min=136x39,max=1044x788"]),
        .s5b: (20, ["min=-x-,max=1044x788", "min=136x39,max=1044x788"]),
    ]

    @Test(
        "frozen pin: ServerMinMaxInfo event count and deduplicated translated constraint set per scenario",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func frozenMinMaxTranslationSet(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        let fields = Self.minMaxTrackFields(replay)
        let translated = Set(fields.map {
            Self.trackSizeDescriptor(MinMaxInfoTranslator.constraints(
                minTrackWidth: $0.minTrackWidth, minTrackHeight: $0.minTrackHeight,
                maxTrackWidth: $0.maxTrackWidth, maxTrackHeight: $0.maxTrackHeight
            ))
        })

        let expected = Self.expectedMinMaxPins[scenario]!
        #expect(fields.count == expected.count, "ServerMinMaxInfo count mismatch for \(scenario): \(fields.count) != \(expected.count)")
        #expect(
            translated == expected.dedupedTranslations,
            "translated constraint set mismatch for \(scenario): got \(translated.sorted()), want \(expected.dedupedTranslations.sorted())"
        )
    }

    /// Expected server-focus composition + full `FocusAuthority` effect trace per
    /// scenario — exported like every other frozen pin (a temporary in-target export test
    /// ran the real `FocusAuthority` over the fingerprint-verified frozen samples,
    /// 2026-09-01 r1-fix pass, printed these literals, and was deleted; cross-checked
    /// against a `jq`-level census of `activeWindowId` values, which agrees:
    /// s1 = 22x 0xFFFFFFFF + 2x 0, s2 = 23x + 2x, s3/s4/s5a/s5b add exactly one 328256
    /// as their FINAL MonitoredDesktop).
    ///
    /// This is the frozen-layer half of r1 H3: s1/s2's "no window truth, zero effects" is
    /// pinned HERE as that session's composition (the portable test's zero-effect branch
    /// says any no-window feed behaves this way; this pin says the 2026-08-19 s1/s2 ARE
    /// such feeds), and s3-s5b's `makeKey(328256)` trace is production-derived — a no-op'd
    /// `serverDesktopUpdate` turns those four rows red on the trace alone.
    static let expectedFocusSignal: [Scenario: (feedCount: Int, windowTruths: [UInt32], effects: [String])] = [
        .s1: (24, [], []),
        .s2: (25, [], []),
        .s3: (25, [328256], ["makeKey(328256)"]),
        .s4: (24, [328256], ["makeKey(328256)"]),
        .s5a: (26, [328256], ["makeKey(328256)"]),
        .s5b: (26, [328256], ["makeKey(328256)"]),
    ]

    @Test(
        "frozen pin: MonitoredDesktop focus-signal composition and full FocusAuthority effect trace per scenario",
        .enabled(if: ReplayTests.samplesDirIsFrozenBaseline, ReplayTests.featurePinSkipReason),
        arguments: Scenario.allCases
    )
    func frozenFocusSignalTrace(_ scenario: Scenario) throws {
        let replay = try ReplayTests.replay(scenario)
        let feed = Self.monitoredDesktopFeed(replay)

        let authority = FocusAuthority()
        var effects: [FocusAuthorityEffect] = []
        for entry in feed {
            effects += authority.serverDesktopUpdate(rawActiveWindowId: entry.raw, at: Double(entry.tMs) / 1000.0)
        }
        let windowTruths = feed.compactMap { entry -> UInt32? in
            if case .window(let id) = ServerActiveWindow(rawActiveWindowId: entry.raw) { return id }
            return nil
        }

        let expected = Self.expectedFocusSignal[scenario]!
        #expect(feed.count == expected.feedCount, "MonitoredDesktop count mismatch for \(scenario): \(feed.count) != \(expected.feedCount)")
        #expect(windowTruths == expected.windowTruths, "window-truth sequence mismatch for \(scenario): \(windowTruths) != \(expected.windowTruths)")
        let trace = effects.map(Self.effectDescriptor)
        #expect(trace == expected.effects, "effect trace mismatch for \(scenario): \(trace) != \(expected.effects)")
    }
}
