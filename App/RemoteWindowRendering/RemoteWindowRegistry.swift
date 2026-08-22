import AppKit
import MacdowsCore
import os

/// Local re-derivation of TS_WINDOW_STATE_ORDER's field-presence bits actually needed for
/// rendering (offset/size/show/title). MacdowsCore's WindowModel.swift is the canonical
/// reference for these values (verified there against
/// ThirdParty/FreeRDP/include/freerdp/window.h and libfreerdp/core/window.c's own order
/// parser) — duplicated here, narrowly, rather than exported from MacdowsCore, because
/// this module sits on the AppKit side of adr/0006 §2's no-AppKit boundary and
/// WindowModel's merge policy is deliberately scoped to MacdowsCore's own pure-logic
/// replay/test surface, not a second live-rendering consumer. Mirrors crdpq.h's own
/// precedent of not sharing these constants with its C transport layer either.
private enum WindowOrderField {
    static let owner: UInt32 = 0x0000_0002
    static let title: UInt32 = 0x0000_0004
    static let style: UInt32 = 0x0000_0008 // gates BOTH style and extendedStyle together
    static let show: UInt32 = 0x0000_0010
    static let size: UInt32 = 0x0000_0400
    static let offset: UInt32 = 0x0000_0800
    /// `WINDOW_ORDER_FIELD_DESKTOP_ZORDER` (window.h) -- MonitoredDesktop-only, gates
    /// `CRDPEvent.windowIds` (adr/0008 §2a). Distinct bit space from the WindowCreate/
    /// Update bits above (MonitoredDesktop's `fieldFlags` uses `WINDOW_ORDER_FIELD_DESKTOP_*`
    /// constants, not the `WINDOW_ORDER_FIELD_*` ones those gate).
    static let desktopZOrder: UInt32 = 0x0000_0010
}

/// Accumulated per-windowId state this registry needs to paint something and decide
/// whether it's mappable — narrower than MacdowsCore.WindowState (no visibility-rects;
/// this rendering layer doesn't consume them yet, that being adr/0008 §6's deferred W1
/// work). style/styleEx/ownerWindowId were added in Phase 2 W0① specifically to drive
/// `WindowMappability.isMappableWindow` below, replacing the old size-only cap.
private struct PendingWindowState {
    var offsetX: Int32 = 0
    var offsetY: Int32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var show: UInt32 = 0
    var title: String = ""
    var style: UInt32 = 0
    var styleEx: UInt32 = 0
    var ownerWindowId: UInt32 = 0

    /// Applies only the sub-fields `event.fieldFlags` actually flags present — a delta
    /// order's unset bit means "unchanged", not "reset to zero/empty" (same invariant
    /// MacdowsCore.WindowState.merge documents and enforces for the JSONL-replay path).
    mutating func merge(_ event: CRDPEvent) {
        let flags = event.fieldFlags
        if flags & WindowOrderField.owner != 0 {
            ownerWindowId = event.ownerWindowId
        }
        if flags & WindowOrderField.offset != 0 {
            offsetX = event.offsetX
            offsetY = event.offsetY
        }
        if flags & WindowOrderField.size != 0 {
            width = event.windowWidth
            height = event.windowHeight
        }
        if flags & WindowOrderField.style != 0 {
            style = event.style
            styleEx = event.styleEx
        }
        if flags & WindowOrderField.show != 0 {
            show = event.show
        }
        if flags & WindowOrderField.title != 0 {
            title = event.title
        }
    }

    var hasKnownSize: Bool { width > 0 && height > 0 }
    /// WINDOW_HIDE == 0 (freerdp/window.h); any other show value means shown in some form.
    var isVisible: Bool { show != 0 }
}

/// The most recently observed `MonitoredDesktop` order, as pure data (adr/0008 §6: W1's
/// focus-convergence/Z-order *policy* is explicitly deferred until real data has been
/// observed live -- this struct only records what the server last said, it decides
/// nothing). Exposed for `Tools/window-smoke`'s harness via
/// `RemoteWindowRegistry.serverDesktopState`, not consumed by any rendering/input path yet
/// (the actual focus *policy* consumer is `FocusAuthority`, fed separately by
/// `handleMonitoredDesktop` below -- this struct stays a passive observability record).
struct ServerDesktopState: Equatable {
    /// adr/0012 §3: `MacdowsCore.ServerActiveWindow` classifies the server's raw
    /// `activeWindowId` into its three distinct meanings (window / desktop-focused /
    /// unmonitored) -- see that type's own doc comment for why `0` must never be folded
    /// into `.unmonitored` nor compared as if it were `.window(0)`. Supersedes the old
    /// `activeWindowId: UInt32?` shape, which already kept the `0xFFFFFFFF` sentinel out of
    /// `.some(0)` but gave callers no named way to recognize `0` as "the desktop", adr/0012
    /// §3's own gap callout ("该处必须同时辨出0").
    var activeWindow: ServerActiveWindow = .unmonitored
    /// Top-to-bottom Z order (adr/0008 §2a), gated on `WINDOW_ORDER_FIELD_DESKTOP_ZORDER`
    /// (0x10) -- empty when the most recent order didn't carry that bit.
    var windowIds: [UInt32] = []
    /// The wire's own count, which may exceed `windowIds.count` if the server's array was
    /// larger than `CRDPQEvent`'s `CRDPQ_MAX_WINDOW_IDS` (96) bound.
    var numWindowIds: UInt32 = 0
    var windowIdsTruncated: Bool = false
}

/// Owns every `RemoteWindow` for one `CRSession`, driven entirely by that session's
/// drained control-lane events (adr/0005 §2/§3). `@MainActor` — this *is* T_main's window-
/// management state, matching `CRSession`'s own threading contract (every method on
/// `CRSession` is safe to call from whatever thread owns it; this registry is that
/// thread's own bookkeeping on top of it).
@MainActor
final class RemoteWindowRegistry {
    private let session: CRSession
    private var windows: [UInt32: RemoteWindow] = [:]
    private var geometry: [UInt32: PendingWindowState] = [:]
    /// surfaceId -> the windowId it's currently mapped to (from SurfaceMapped events), so
    /// a later FrameReady(surfaceId) can be routed to the right RemoteWindow. Unlike
    /// MacdowsCore.WindowModel's surfaceBindings/pendingBindings pair, this registry
    /// doesn't separately track "settled vs. pending" — a FrameReady for a surfaceId whose
    /// window doesn't exist yet (or is filtered out, see isMappableWindow) is simply
    /// skipped; adr/0005 §1's "a GFX frame is state, not an event" means nothing is lost by doing so —
    /// the next FrameReady for the same surfaceId will retry once/if the window exists.
    private var surfaceToWindow: [UInt32: UInt32] = [:]
    /// Per-surface mapped sub-rect size (GFX mappedWidth/Height) -- the real content
    /// region inside the 64-aligned surface allocation; RemoteWindow.present crops the
    /// layer to it. Populated by .surfaceMapped, dropped alongside surfaceToWindow.
    private var surfaceMappedSize: [UInt32: CGSize] = [:]
    private var currentGeneration: UInt32?
    /// adr/0008 §6 / task item 5: pure-data record of the last MonitoredDesktop order, no
    /// ordering/focus policy attached. See `ServerDesktopState`'s own doc comment.
    private var desktopState = ServerDesktopState()

    /// Z-order diagnostics (phase2.md §2 W1's final slice) -- cumulative for this
    /// registry's lifetime (not reset on reconnect, unlike `desktopState`: these are "how
    /// much has this registry ever done," not per-connection state). Exposed via
    /// `zOrderDiagnostics()` for `Tools/window-smoke`'s `[zorder]` summary line.
    private var zOrderArraysReceivedCount = 0
    private var zOrderAppliesPerformedCount = 0
    private var zOrderSkippedUnknownTotal = 0

    /// TEMPORARY debug instrumentation (2026-08-23 Z-order reversal investigation,
    /// team-lead-requested -- real-host evidence: local top-down stacking observed as a
    /// near-exact reversal of the last server windowIds array, with appliesPerformed=1
    /// across 31 arrays received, meaning `ZOrderSync.plan` judged "already matches" 30
    /// times in a row while the FINAL physical order disagreed with the server array).
    /// When `true`, `applyZOrder` prints a `[zorder-trace]` line for every MonitoredDesktop
    /// order carrying a DESKTOP_ZORDER array: exactly what `ZOrderSync.plan` compared
    /// internally (`Plan.target`/`currentRestricted`), the physical local stacking
    /// immediately before and after this call's apply, and -- only on the calls where the
    /// plan itself claimed a match -- a harness-style direct recomputation cross-check.
    /// That cross-check exists specifically to discriminate a real bug in `plan()`'s own
    /// match logic from a shared direction/semantic assumption both `plan()` and the
    /// harness's own final comparison would independently agree on (in which case the
    /// cross-check agrees with `plan()` too, and nothing extra prints). Off by default --
    /// zero cost, zero behavior change for the production app and for any window-smoke run
    /// that doesn't explicitly opt in (`Tools/window-smoke/main.swift` sets this only for
    /// the multi-window scenario). Remove once the investigation concludes.
    var zOrderTraceEnabled = false

    /// adr/0012: server-authoritative + local-optimistic-prediction focus state machine.
    /// Pure logic lives entirely in `MacdowsCore.FocusAuthority` (no AppKit/CRSession, no
    /// `Date()`); this registry owns the one instance for the session's lifetime, feeds it
    /// every relevant input, and executes every effect it returns via `execute(_:)` below --
    /// adr/0012 §4's "纯状态机进MacdowsCore，RemoteWindowRegistry只做消费与副作用" split.
    private let focusAuthority = FocusAuthority()

    /// W4c review H1: *session-level* modifier state — one physical keyboard, one tracked
    /// set, not per-window. The original per-window `[UInt32: NSEvent.ModifierFlags]`
    /// dictionary had a real bug: a modifier pressed while window A was focused, then
    /// released while window B was focused instead (B's own dictionary entry never
    /// recorded the press), left that bit permanently stuck "held" in RDP's own remote-side
    /// state — no transition was ever observed to clear it, since diffing happened
    /// per-window rather than against one shared truth. `MacdowsCore.ModifierKeyTracker`
    /// does the actual diff/release-sequence computation (unit-tested there, offline, no
    /// AppKit/CRSession needed); this var is the one piece of mutable state it's diffed
    /// against. Cleared (not "flushed" — the connection this state described is already
    /// gone) on `closeAllWindows`, and force-flushed via `ModifierKeyTracker.releaseAll`
    /// on a `.focusLost` event (see `handleInput`'s own case).
    private var heldModifierKeys: ModifierKeySet = []
    /// W4c: last time a `.mouseMoved` event was actually forwarded for each window, for the
    /// move-event throttle in `handleInput` (task spec: "move events may be throttled at 8ms" — AppKit's
    /// native mouseMoved/mouseDragged rate is far higher than the outbound lane needs).
    private var lastMoveSentAt: [UInt32: CFAbsoluteTime] = [:]
    private static let moveThrottleInterval: CFAbsoluteTime = 0.008
    /// Trailing-edge state for the move throttle: the throttle used to plain DROP moves
    /// inside the 8ms window, so a burst's FINAL cursor position often never reached the
    /// server -- hover states stuck one step behind the cursor, and a warp-then-click sent
    /// its button event with no preceding motion at the final spot (both observed live
    /// during the 2026-08-21 input investigation, where the dropped tail invalidated a
    /// whole class of hover probes). A throttled move now parks here and a flush fires
    /// once the throttle window elapses, superseded by any newer send for the same window.
    private var pendingTrailingMove: [UInt32: NSPoint] = [:]

    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "RemoteWindowRendering")
    /// L1 (W4b review): logged once, not on every event, so a genuinely no-display
    /// environment doesn't spam this on every drained window order — the actual skip
    /// behavior in handleWindowOrder still applies every time regardless of this flag.
    private static var warnedZeroPrimaryMonitorHeight = false

    init(session: CRSession) {
        self.session = session
    }

    /// adr/0005 §2 / W4b task spec: "primaryMonitorHeight takes NSScreen.screens' primary screen" —
    /// `NSScreen.screens.first`, not `NSScreen.main` (which tracks keyboard focus, a
    /// different concept). `NSScreen.screens` is documented to list the primary display
    /// (the one containing the menu bar, i.e. Windows-space origin (0,0)'s counterpart)
    /// first.
    private static var primaryMonitorHeight: Double {
        // NSRect.height is CGFloat, not Double -- an explicit conversion (harmless on this
        // 64-bit-only project, adr/0005's own target) rather than a type mismatch.
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Phase 2 W0① (docs/plans/phase2.md W0①, adr/0008 §3): thin call-site wrapper over
    /// `MacdowsCore.WindowMappability.isMappableWindow` — the actual decision logic lives
    /// there (a pure, no-AppKit function) specifically so this AppKit-side live path and
    /// `MacdowsCoreTests`' replay-fixture regression test exercise the identical
    /// implementation. Replaces the prior W4b `isLikelyContentWindow`, whose own doc
    /// comment called its `width >= 2000 && height >= 1000` cap an explicitly temporary
    /// policy — it dropped every maximized content window (Word, Edge, ...), which is
    /// exactly what this pass exists to stop doing.
    private static func isMappableWindow(_ state: PendingWindowState, fieldFlags: UInt32) -> Bool {
        WindowMappability.isMappableWindow(
            width: state.width, height: state.height, style: state.style, styleEx: state.styleEx,
            ownerWindowId: state.ownerWindowId, fieldFlags: fieldFlags
        )
    }

    /// Call once per drained event, in delivery order (`session.drainEvents { registry.handle($0) }`)
    /// — there is no separate flush step; every event, including FrameReady, is applied as
    /// it arrives.
    func handle(_ event: CRDPEvent) {
        // adr/0005 §4's generation protocol: `-drainEventsWithHandler:` already filters
        // out stale-generation events before this method ever sees them, so any
        // generation change observed *here* is a genuine, first-time-seen reconnect
        // boundary — every window this registry currently tracks is from a connection
        // that's now gone (a clean reconnect always tears down and rebuilds RAIL/RDPGFX
        // state from scratch), so it's closed unconditionally, not merged forward.
        if currentGeneration != event.generation {
            closeAllWindows()
            currentGeneration = event.generation
        }

        // adr/0012 §4 task item 2: opportunistic tick on every drained event -- cheap (a
        // no-op whenever FocusAuthority isn't `.converging`), and covers the common case
        // (events keep arriving during a convergence attempt) without a repeating timer.
        // `scheduleFocusAuthorityTick` (called from the mouseButton `.down` case) covers the
        // complementary "server goes quiet" case with a self-rescheduling chain of one-shot
        // timers (2026-08-23 follow-up: periodic re-arm, see that method's own doc comment).
        execute(focusAuthority.tick(now: CFAbsoluteTimeGetCurrent()))

        switch event.kind {
        case .windowCreate, .windowUpdate:
            handleWindowOrder(event)
        case .windowDelete:
            handleWindowDelete(windowId: event.windowId)
        case .surfaceMapped:
            surfaceToWindow[event.surfaceId] = UInt32(truncatingIfNeeded: event.mappedWindowId)
            // The mapped sub-rect of the (64-aligned, padded) surface this window shows --
            // consumed by RemoteWindow.present's contentsRect crop; see its comment for
            // why skipping this crop was the white-edges/dead-clicks root cause.
            if event.mappedWidth > 0, event.mappedHeight > 0 {
                surfaceMappedSize[event.surfaceId] = CGSize(
                    width: CGFloat(event.mappedWidth), height: CGFloat(event.mappedHeight))
            }
        case .frameReady:
            handleFrameReady(surfaceId: event.surfaceId)
        case .disconnected:
            closeAllWindows()
        case .monitoredDesktop:
            handleMonitoredDesktop(event)
        case .localMoveSize, .minMaxInfo, .zOrderSync:
            // adr/0008 §1/§6: contract-only wiring -- these three now decode and reach
            // here, but no sync/policy code exists yet ("拿到真数据前不写策略"). LocalMoveSize
            // in particular was never observed in any phase05 sample (adr/0008 §0's
            // caveat); logging its first live occurrence is a verification step, not
            // acted-upon data.
            Self.logger.debug("received \(String(describing: event.kind), privacy: .public) windowId=\(event.windowId, privacy: .public) (recorded only, no policy attached -- adr/0008 §6)")
        case .windowIcon, .notifyIconCreate, .notifyIconUpdate, .notifyIconDelete,
             .execResult, .handshakeFlags:
            break
        @unknown default:
            break
        }
    }

    /// adr/0008 §2a / §6: records the server's own MonitoredDesktop state as pure data --
    /// no focus/Z-order policy. `event.windowId` carries `activeWindowId` (see
    /// `CRDPEvent.windowId`'s own doc comment); `ServerActiveWindow.init(rawActiveWindowId:)`
    /// classifies it once, here, so nothing downstream ever has to re-derive the two
    /// sentinel checks (adr/0012 §3). Also the sole feed into `FocusAuthority`'s policy --
    /// this is the "real MonitoredDesktop order" adr/0012 §2's reconnect discipline requires
    /// before the keyboard-lane gate can ever reopen.
    private func handleMonitoredDesktop(_ event: CRDPEvent) {
        desktopState.activeWindow = ServerActiveWindow(rawActiveWindowId: event.windowId)
        desktopState.numWindowIds = event.numWindowIds
        desktopState.windowIdsTruncated = event.windowIdsTruncated
        if event.fieldFlags & WindowOrderField.desktopZOrder != 0 {
            desktopState.windowIds = event.windowIds.map { $0.uint32Value }
            zOrderArraysReceivedCount += 1
            applyZOrder(desktopState.windowIds)
        }
        execute(focusAuthority.serverDesktopUpdate(rawActiveWindowId: event.windowId, at: CFAbsoluteTimeGetCurrent()))
    }

    /// Phase 2 W1's final slice (docs/plans/phase2.md §2 W1, §9 D3; adr/0008 §2a/§4;
    /// adr/0012 §5's own note that Z-order was deferred until the focus gate passed --
    /// it has). Pure ordering logic lives entirely in `MacdowsCore.ZOrderSync` (no
    /// AppKit); this method's only job is gathering the two AppKit-side inputs it needs
    /// (which windowIds this registry currently renders, and their current on-screen
    /// stacking order) and executing the plan it returns -- same split as
    /// `FocusAuthority`/`execute(_:)` above, just without a persistent effect-list type
    /// since `ZOrderSync` is a stateless pure function, not a state machine.
    ///
    /// Deliberately does NOT touch key/main window status (adr/0012 §4's "只做消费与副作用"
    /// split reserves focus for `FocusAuthority` alone) -- `NSWindow.order(_:relativeTo:)`
    /// only changes front-to-back list position, never key/main state.
    ///
    /// TODO(W3, docs/plans/phase2.md W3): once local move/resize (LMS_* handshake) lands,
    /// this must be suppressed while a local drag/interaction is in flight for the window(s)
    /// involved -- reordering mid-drag would fight the user's own gesture. No such guard
    /// exists yet because local move tracking isn't implemented until W3; this always
    /// applies unconditionally for now.
    private func applyZOrder(_ serverTopDown: [UInt32]) {
        // Restrict to windows that are actually on screen: NSWindow.order(_:relativeTo:)
        // INSERTS an ordered-out window into the window list, so including a hidden
        // window here would force it visible -- bypassing both the RAIL show state and
        // the first-frame gate (observed live as blank 136x39 helper windows popping in
        // the moment Z-order application landed). Hidden windows take their place in the
        // stacking order when their own visibility path orders them front.
        //
        // 2026-08-23 real-host trace (Z-order reversal investigation): this used to be a
        // SEPARATE `windows.compactMap { $0.value.window.isVisible ? ... }` sweep, and it
        // was starving `ZOrderSync.plan`'s `locallyKnown` input -- the trace showed
        // `plan.target` staying EMPTY across 21 consecutive MonitoredDesktop arrays while
        // `currentTopDownWindowIds()` had already grown to 7 real on-screen windows (a
        // direct cross-check confirmed the disagreement: at the seq where a real apply
        // finally ran, the server array actually named all 7 of those ids, but the
        // `.isVisible` sweep had recognized only 1 of them the whole time). The exact
        // AppKit mechanism behind that `.isVisible` disagreement is still not pinned down
        // (a lightweight breadcrumb for it stays in `traceZOrder`, gated the same as the
        // rest of this file's trace instrumentation) -- but it doesn't need to be, because
        // `currentTopDownWindowIds()` is already ground truth for "on screen right now"
        // (it's built by filtering `NSApp.orderedWindows` itself, which per Apple's own
        // documented contract only ever lists genuinely on-screen windows): a window
        // present in ITS output is on screen by construction, with no second, independently
        // computed set that can silently drift out of sync with it. This still preserves
        // the exact protection this comment opens with -- a hidden/gate-held window is
        // never in `currentTopDownWindowIds()`'s output, so it's never in `locallyKnown`,
        // so no instruction can ever reference it.
        let localBefore = currentTopDownWindowIds()
        let visibleIds = Set(localBefore)
        let plan = ZOrderSync.plan(
            serverTopDown: serverTopDown,
            locallyKnown: visibleIds,
            currentLocalTopDown: localBefore
        )
        if !plan.instructions.isEmpty {
            zOrderAppliesPerformedCount += 1
        }
        if plan.unknownSkippedCount > 0 {
            zOrderSkippedUnknownTotal += plan.unknownSkippedCount
            Self.logger.debug("Z-order sync: \(plan.unknownSkippedCount, privacy: .public) server windowId(s) not locally known (filtered/not-yet-created -- adr/0008 §4, not an error)")
        }
        for instruction in plan.instructions {
            guard let window = windows[instruction.windowId]?.window else { continue }
            if let belowId = instruction.belowWindowId, let anchor = windows[belowId]?.window {
                window.order(.below, relativeTo: anchor.windowNumber)
            } else {
                // ZOrderSync.Instruction's own doc comment: nil belowWindowId means "no
                // known window belongs above this one" -- otherWin 0 with .above is
                // AppKit's own idiom for "make this the frontmost window of the app"
                // (NSWindow.order(_:relativeTo:)'s documented otherWin==0 behavior).
                window.order(.above, relativeTo: 0)
            }
        }

        if zOrderTraceEnabled {
            traceZOrder(serverTopDown: serverTopDown, localBefore: localBefore, plan: plan)
        }
    }

    /// TEMPORARY debug instrumentation -- see `zOrderTraceEnabled`'s own doc comment for
    /// why this exists and what it's trying to discriminate. `seq` reuses
    /// `zOrderArraysReceivedCount` (already incremented once per Z-array-carrying order,
    /// in lockstep with every `applyZOrder` call) rather than a second counter.
    private func traceZOrder(serverTopDown: [UInt32], localBefore: [UInt32], plan: ZOrderSync.Plan) {
        let seq = zOrderArraysReceivedCount
        let localAfter = currentTopDownWindowIds()
        let verdict = plan.instructions.isEmpty ? "match" : "\(plan.instructions.count) instructions"
        print("[zorder-trace] seq=\(seq) serverRestricted=\(plan.target) localBefore=\(localBefore) "
            + "verdict=\(verdict) localAfter=\(localAfter)")

        // Breadcrumb only (2026-08-23 investigation): `locallyKnown` no longer depends on
        // `.isVisible` (applyZOrder now derives it from `localBefore` itself), but the
        // disagreement that motivated that change -- a window confirmed present in
        // `NSApp.orderedWindows` (i.e. in `localBefore`) whose own `.isVisible` still reads
        // false -- is still worth surfacing if it recurs, since the underlying AppKit
        // mechanism behind it was never pinned down, only sidestepped. Cheap (one pass over
        // the already-small `windows` dict) and trace-gated, so this costs nothing outside
        // the investigation.
        let stillDisagreeing = windows.compactMap { id, remoteWindow -> UInt32? in
            localBefore.contains(id) && !remoteWindow.window.isVisible ? id : nil
        }
        if !stillDisagreeing.isEmpty {
            print("[zorder-trace] isVisible/orderedWindows disagreement at seq=\(seq): ids present in "
                + "localBefore (on screen per NSApp.orderedWindows) but window.isVisible==false: "
                + "\(stillDisagreeing.sorted())")
        }

        guard plan.instructions.isEmpty else { return }
        // ONE targeted diagnostic: plan() said "already matches" -- cross-check that
        // verdict against a harness-style DIRECT recomputation from the same localBefore
        // snapshot (mirrors exactly what Tools/window-smoke's own finish() assertion
        // computes: filter each side to ids present in the other, preserving each side's
        // own relative order). If plan()'s own match logic and this direct recomputation
        // ever disagree, that's a real bug in plan()'s comparison, not a shared direction/
        // semantic assumption -- a shared assumption would make both sides wrong the same
        // way, and this recomputation would then silently agree with plan() too.
        let localBeforeSet = Set(localBefore)
        let serverSet = Set(serverTopDown)
        let harnessServerRestricted = serverTopDown.filter { localBeforeSet.contains($0) }
        let harnessLocalRestricted = localBefore.filter { serverSet.contains($0) }
        if harnessServerRestricted != harnessLocalRestricted {
            print("[zorder-trace] MATCH-VERDICT DISAGREEMENT at seq=\(seq): plan said match (internal "
                + "target=\(plan.target) currentRestricted=\(plan.currentRestricted)) but a harness-style direct "
                + "recomputation disagrees (serverRestricted=\(harnessServerRestricted) "
                + "localRestricted=\(harnessLocalRestricted))")
        }
    }

    /// This registry's own current top-down (topmost-first) local stacking order,
    /// restricted to the windowIds it renders. `NSApp.orderedWindows` is already
    /// documented to return the app's window list front-to-back, so this is a single pass
    /// over it rather than reading each window's own `NSWindow.orderedIndex` and sorting
    /// manually -- same information, one fewer step. Shared by `applyZOrder` (as
    /// `ZOrderSync`'s `currentLocalTopDown` input) and exposed to `Tools/window-smoke`'s
    /// own Z-order consistency assertion, so the harness measures the exact same ordering
    /// the sync logic itself acted on rather than a second, separately-computed notion of
    /// "current order."
    func currentTopDownWindowIds() -> [UInt32] {
        let numberToId = Dictionary(uniqueKeysWithValues: windows.map { ($0.value.window.windowNumber, $0.key) })
        return NSApp.orderedWindows.compactMap { numberToId[$0.windowNumber] }
    }

    /// Diagnostics only (Tools/window-smoke's `[zorder]` summary line) -- see the three
    /// backing counters' own doc comment for what each one means.
    struct ZOrderDiagnostics {
        let arraysReceived: Int
        let appliesPerformed: Int
        let skippedUnknownTotal: Int
    }
    func zOrderDiagnostics() -> ZOrderDiagnostics {
        ZOrderDiagnostics(
            arraysReceived: zOrderArraysReceivedCount, appliesPerformed: zOrderAppliesPerformedCount,
            skippedUnknownTotal: zOrderSkippedUnknownTotal
        )
    }

    private func handleWindowOrder(_ event: CRDPEvent) {
        let windowId = event.windowId
        var state = geometry[windowId] ?? PendingWindowState()
        state.merge(event)
        geometry[windowId] = state

        guard state.hasKnownSize, Self.isMappableWindow(state, fieldFlags: event.fieldFlags) else {
            // Not enough geometry yet, or filtered out (see isMappableWindow) — if a
            // RemoteWindow was already created for this windowId before it grew into a
            // filtered style (not expected in practice, but not assumed impossible either),
            // it's deliberately left alone here rather than torn down mid-session; only
            // WindowDelete/a generation rollover removes an existing RemoteWindow.
            return
        }
        guard let generation = currentGeneration else { return }

        // L1: primaryMonitorHeight==0 means NSScreen.screens was empty (no display
        // attached/available — plausible headless or display-asleep). WindowGeometry.
        // macRect would still compute *something* from a zero height (a bogus, likely
        // negative Y), silently placing/moving a window at a coordinate that was never
        // actually meaningful. Skip positioning entirely instead — this event's geometry
        // is still recorded above (state merge already ran), so once a real screen becomes
        // available a later update (or this same accumulated state, re-evaluated) positions
        // correctly rather than needing the server to resend anything.
        guard Self.primaryMonitorHeight > 0 else {
            if !Self.warnedZeroPrimaryMonitorHeight {
                Self.warnedZeroPrimaryMonitorHeight = true
                Self.logger.warning(
                    "primaryMonitorHeight is 0 (NSScreen.screens is empty) -- skipping window positioning rather than producing a bogus coordinate"
                )
            }
            return
        }

        let frame = macFrame(for: state)
        if let existing = windows[windowId] {
            existing.updateFrame(frame)
            existing.updateTitle(state.title)
            // Only reorder this window's front/back position when *this specific delta*
            // actually carries a show-state change — calling setVisible (hence
            // orderFront) on every unrelated geometry/title-only update was needlessly
            // pulling a window to the front of AppKit's window stack just because it
            // happened to receive some other kind of update, fighting for Z-order against
            // other windows that hadn't changed visibility at all (observed against a real
            // host with several leftover RemoteApp windows already open in the session:
            // an idle window could still end up on top of a freshly launched one). Full
            // Z-order fidelity is still Phase 2 (adr/0005 §7) — this only stops a kind of
            // update this registry doesn't model at all from having an unintended Z-order
            // side effect.
            if event.fieldFlags & WindowOrderField.show != 0 {
                existing.setVisible(state.isVisible)
            }
        } else {
            let key = RemoteWindowKey(windowId: windowId, generation: generation)
            let window = RemoteWindow(key: key, frame: frame, title: state.title)
            window.onInput = { [weak self] event in
                self?.handleInput(windowId: windowId, event: event)
            }
            windows[windowId] = window
            window.setVisible(state.isVisible)
        }
    }

    /// The one and only place Windows-space geometry becomes an `NSRect` — always through
    /// `MacdowsCore.WindowGeometry`, per the W4b task spec's explicit instruction never
    /// to reimplement this math anywhere else in this layer.
    private func macFrame(for state: PendingWindowState) -> NSRect {
        let windowsRect = WindowsRect(
            x: Double(state.offsetX),
            y: Double(state.offsetY),
            width: Double(state.width),
            height: Double(state.height)
        )
        let macRect = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryMonitorHeight)
        return NSRect(x: macRect.x, y: macRect.y, width: macRect.width, height: macRect.height)
    }

    private func handleWindowDelete(windowId: UInt32) {
        geometry.removeValue(forKey: windowId)
        let droppedSurfaces = surfaceToWindow.filter { $0.value == windowId }.map(\.key)
        for sid in droppedSurfaces {
            surfaceMappedSize.removeValue(forKey: sid)
        }
        surfaceToWindow = surfaceToWindow.filter { $0.value != windowId }
        // heldModifierKeys is deliberately NOT touched here (W4c review H1) -- it is
        // session-level, not per-window; a modifier held while this specific window closes
        // is still physically held on the keyboard and may still need its RELEASE observed
        // via whatever window next receives it, or via a .focusLost flush.
        lastMoveSentAt.removeValue(forKey: windowId)
        pendingTrailingMove.removeValue(forKey: windowId)
        if let window = windows.removeValue(forKey: windowId) {
            window.close(via: session)
        }
    }

    /// W4c: routes one `RemoteWindowInputEvent` from `windowId`'s `RemoteWindow` to
    /// `CRSession` (adr/0005's Phase 1 "clickable/interactive" milestone). This is the
    /// one and only place a mac-screen point becomes a Windows-space absolute desktop
    /// coordinate for *input* — mirrors `macFrame(for:)` being the one and only place the
    /// reverse direction happens for window geometry; `RemoteWindowContentView` never does
    /// this conversion itself.
    private func handleInput(windowId: UInt32, event: RemoteWindowInputEvent) {
        switch event {
        case .mouseMoved(let screenPoint):
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastMoveSentAt[windowId], now - last < Self.moveThrottleInterval {
                // Inside the throttle window: park this position and arrange for it to be
                // sent when the window elapses, instead of dropping it (see
                // pendingTrailingMove's comment for why dropping the tail was a real bug).
                let alreadyPending = pendingTrailingMove[windowId] != nil
                pendingTrailingMove[windowId] = screenPoint
                if !alreadyPending {
                    let delay = Self.moveThrottleInterval - (now - last)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated {
                            self?.flushTrailingMove(windowId: windowId)
                        }
                    }
                }
                return
            }
            pendingTrailingMove.removeValue(forKey: windowId)
            lastMoveSentAt[windowId] = now
            let point = remotePoint(from: screenPoint)
            session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))

        case .mouseButton(let button, let down, let screenPoint):
            // A button event carries its own position -- any parked trailing move is now
            // stale (and letting it fire after the click would jiggle the remote pointer).
            pendingTrailingMove.removeValue(forKey: windowId)
            if down {
                // Click-to-activate (W4c task spec: "this is also where the real fix for the
                // white-block bug lands") — the existing unconditional local optimistic
                // prediction (adr/0012 §0: this ADR doesn't introduce it, it puts authority
                // and rollback around it), now routed through FocusAuthority so the
                // keyboard-lane gate closes for this epoch and the soft/hard deadlines start
                // ticking. `execute` maps its `.sendActivate`/`.makeKey` effects onto the
                // exact same `session.activateWindow`/`activateLocally()` calls this used to
                // make directly -- a redundant Activate/makeKey on an already-focused window
                // is still just a fire-and-forget no-op cost, not a correctness risk.
                let now = CFAbsoluteTimeGetCurrent()
                execute(focusAuthority.localActivate(windowId: windowId, at: now))
                scheduleFocusAuthorityTick()
            }
            let point = remotePoint(from: screenPoint)
            session.send(crMouseButton(for: button), down: down, atX: Int32(point.x), y: Int32(point.y))

        case .scrollWheel(let deltaX, let deltaY, let screenPoint):
            // Same reasoning as .mouseButton above: this event carries its own position,
            // so a parked trailing move is stale and would drag the pointer backwards.
            pendingTrailingMove.removeValue(forKey: windowId)
            // Matches ThirdParty/FreeRDP/client/Mac/MRDPView.m's own -scrollWheel:: vertical
            // takes priority over horizontal for a single physical scroll event, not both
            // sent together. W4c review L1: the priority check itself must use an epsilon
            // (fabsf(dy) > FLT_EPSILON in the reference implementation), not a bare "!= 0"
            // -- a primarily-horizontal gesture can carry a negligible but technically
            // nonzero deltaY (trackpad noise), and a bare "!= 0" check let that tiny value
            // always win the vertical branch, silently swallowing every horizontal scroll
            // that happened to arrive with any deltaY noise at all.
            let point = remotePoint(from: screenPoint)
            if Float(abs(deltaY)) > Float.ulpOfOne {
                session.sendMouseVerticalWheelDelta(deltaY, atX: Int32(point.x), y: Int32(point.y))
            } else if Float(abs(deltaX)) > Float.ulpOfOne {
                session.sendMouseHorizontalWheelDelta(deltaX, atX: Int32(point.x), y: Int32(point.y))
            }

        case .keyDown(let macKeyCode):
            // adr/0012 §2: keyboard is focus-addressed (the wire message itself carries no
            // windowId -- CRSession.h's `sendKeyDown:`/`sendKeyUp:` take only a scancode),
            // so it must not reach the wire until FocusAuthority confirms the server's own
            // `activeWindowId` actually matches what we're claiming key for. Routed through
            // the gate rather than sent directly, unlike mouse (position-addressed, §2:
            // "鼠标是位置寻址，天然免闸").
            execute(focusAuthority.enqueueKeyboardEvent(.keyDown(macKeyCode: macKeyCode), at: CFAbsoluteTimeGetCurrent()))

        case .keyUp(let macKeyCode):
            execute(focusAuthority.enqueueKeyboardEvent(.keyUp(macKeyCode: macKeyCode), at: CFAbsoluteTimeGetCurrent()))

        case .flagsChanged(let modifierFlags):
            // heldModifierKeys tracks physical keyboard state at *capture* time,
            // independent of gating -- the diff itself (which bits actually transitioned)
            // must happen now, against the last raw observation, same as before this ADR.
            // What's new: each individual transition is now a `KeyboardLaneEvent` routed
            // through the gate ("闸的粒度是整条键盘车道", §2), not sent to the wire directly
            // -- FocusAuthority buffers or passes it through exactly like keyDown/keyUp.
            let current = Self.modifierKeySet(from: modifierFlags)
            let transitions = ModifierKeyTracker.transitions(from: heldModifierKeys, to: current)
            heldModifierKeys = current
            for transition in transitions {
                execute(focusAuthority.enqueueKeyboardEvent(.modifierKey(transition.key, down: transition.down), at: CFAbsoluteTimeGetCurrent()))
            }

        case .focusLost:
            // W4c review H1: this window (or its content view) can no longer be trusted to
            // observe the physical keyboard -- unconditionally release every bit this
            // session-level tracker currently has marked as held, rather than leaving RDP's
            // own modifier state stuck on a release that might never arrive. Deliberately
            // NOT routed through FocusAuthority's gate: a focus-loss release is the safety
            // mechanism itself, not the "focus-addressed input" the gate exists to protect
            // against buffering/misdirecting -- it must fire immediately regardless of
            // whatever convergence is in flight.
            releaseAllHeldModifiers()
        }
    }

    /// Executes `FocusAuthority`'s returned effects against this registry's AppKit/CRSession
    /// machinery -- adr/0012 §4's "RemoteWindowRegistry只做消费与副作用" half of the split (the
    /// state machine itself, in `MacdowsCore.FocusAuthority`, touches neither). Applied in
    /// the order `FocusAuthority` returned them.
    private func execute(_ effects: [FocusAuthorityEffect]) {
        for effect in effects {
            switch effect {
            case .sendActivate(let windowId):
                session.activateWindow(windowId)

            case .makeKey(let windowId):
                guard let window = windows[windowId] else {
                    // adr/0012 §3: a server value naming a window unknown to this registry
                    // (filtered out by W0 style/owner filtering, or not yet created) is
                    // still authoritative truth -- FocusAuthority converges on it
                    // regardless. There is simply no local NSWindow to give key status to;
                    // this registry is the one place that knows that, so it's the one place
                    // that warns about it, not FocusAuthority itself (which has no notion
                    // of "windows this registry happens to render").
                    Self.logger.warning("FocusAuthority.makeKey for windowId=\(windowId, privacy: .public) has no local RemoteWindow (adr/0012 §3: authority accepted, no local window to key)")
                    continue
                }
                window.activateLocally()

            case .resignKey(let windowId):
                // Best-effort: no clean AppKit primitive exists to force an arbitrary
                // window to give up key status while staying visible (the closest is
                // `-resignKey` -- ObjC `resignKeyWindow`, Swift-renamed -- whose default
                // implementation exists specifically to update a window's own visual
                // key-appearance and post `NSWindow.didResignKeyNotification`; calling it
                // directly here is the "existing... machinery" the task calls for, not a
                // new mechanism). A windowId FocusAuthority tracked but this registry never
                // had a window for is a silent no-op -- nothing to visually un-key.
                windows[windowId]?.window.resignKey()

            case .flushBufferedInput(let events):
                for event in events {
                    sendKeyboardLaneEvent(event)
                }

            case .dropBufferedInput(let count, let withModifierRelease):
                if count > 0 {
                    Self.logger.debug("FocusAuthority dropped \(count, privacy: .public) buffered keyboard-lane event(s)")
                }
                if withModifierRelease {
                    // adr/0012 §2: hard rollback and epoch supersede both require a
                    // releaseAll, independent of whatever happened to actually be sitting in
                    // FocusAuthority's own FIFO at that moment (see FocusAuthority's own doc
                    // comment on why it doesn't try to compute this itself) -- the same
                    // machinery `.focusLost` above already uses.
                    releaseAllHeldModifiers()
                }

            case .warn(let reason):
                Self.logger.warning("FocusAuthority: \(String(describing: reason), privacy: .public)")
            }
        }
    }

    private func sendKeyboardLaneEvent(_ event: KeyboardLaneEvent) {
        switch event {
        case .keyDown(let macKeyCode):
            session.sendKeyDown(macKeyCode)
        case .keyUp(let macKeyCode):
            session.sendKeyUp(macKeyCode)
        case .modifierKey(let key, let down):
            session.send(Self.crModifierKey(for: key), down: down)
        }
    }

    /// Shared by `.focusLost` (immediate/ungated) and `.dropBufferedInput(...,
    /// withModifierRelease: true)` (also immediate/ungated -- see that effect's own doc
    /// comment) -- both need the exact same "release everything this session-level tracker
    /// currently has marked as held" flow (W4c review H1).
    private func releaseAllHeldModifiers() {
        let releases = ModifierKeyTracker.releaseAll(heldModifierKeys)
        heldModifierKeys = []
        for release in releases {
            session.send(Self.crModifierKey(for: release.key), down: release.down)
        }
    }

    /// adr/0012 §4 task item 2: `FocusAuthority`'s periodic re-arm and hard-rollback
    /// machinery only fires when `tick(now:)` is actually called at some point after each
    /// threshold elapses -- `handle(_:)` already does this opportunistically on every
    /// drained event, which covers the common case (events keep arriving during a
    /// convergence attempt). This covers the complementary *quiet* case: if the server goes
    /// completely silent for the whole window (no MonitoredDesktop, no window order,
    /// nothing), these timers are what still fire the periodic re-arm/rollback on schedule.
    ///
    /// 2026-08-23 follow-up (periodic re-arm, up to ~9-19 re-arms per epoch depending on
    /// cold-start vs steady-state): a single pair of one-shot timers (at the old fixed
    /// soft/hard marks) no longer covers the whole window on its own -- this now CHAINS one
    /// `asyncAfter` every `softDeadlineInterval` (mirroring `pendingTrailingMove`'s own
    /// `asyncAfter` idiom above, still no repeating `Timer`), re-arming itself from each
    /// fire for as long as `focusAuthority.state` is still `.converging`, and stopping the
    /// moment it isn't (converged, hard-rolled-back, or superseded -- whichever `tick(now:)`
    /// itself already decided). Deliberately doesn't need to know cold-start vs
    /// steady-state, or even the hard deadline's value at all -- `tick(now:)` in
    /// MacdowsCore is the sole authority on when the epoch actually ends; this loop just
    /// keeps knocking until there's nothing left to knock for. Safe to call redundantly
    /// (e.g. from every `localActivate`, including the same-target nudge case that doesn't
    /// reset any deadline, or with a prior chain from a just-superseded epoch still
    /// in-flight): each fire's own `tick(now:)` call is itself a no-op whenever nothing has
    /// actually crossed a threshold yet, and a chain that finds `state` no longer
    /// `.converging` simply stops rescheduling itself.
    private func scheduleFocusAuthorityTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusAuthority.softDeadlineInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.tickFocusAuthorityAndReschedule()
            }
        }
    }

    private func tickFocusAuthorityAndReschedule() {
        execute(focusAuthority.tick(now: CFAbsoluteTimeGetCurrent()))
        if case .converging = focusAuthority.state {
            scheduleFocusAuthorityTick()
        }
    }

    /// Trailing-edge flush for the move throttle (see `pendingTrailingMove`): sends the
    /// last position a throttled burst parked, unless a newer send for this window already
    /// superseded it (an unthrottled move clears the pending entry; a closed window drops
    /// out of `windows`).
    private func flushTrailingMove(windowId: UInt32) {
        guard let screenPoint = pendingTrailingMove.removeValue(forKey: windowId),
              windows[windowId] != nil
        else { return }
        lastMoveSentAt[windowId] = CFAbsoluteTimeGetCurrent()
        let point = remotePoint(from: screenPoint)
        session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))
    }

    /// The one and only place a mac-screen point becomes a `WindowsPoint`, exactly
    /// mirroring `macFrame(for:)` above for the reverse (Windows-rect -> mac-rect)
    /// direction. Always through `MacdowsCore.WindowGeometry` — never a second, ad hoc
    /// coordinate-math implementation in this file or `RemoteWindowContentView`.
    private func remotePoint(from screenPoint: NSPoint) -> WindowsPoint {
        WindowGeometry.windowsPoint(
            from: MacPoint(x: screenPoint.x, y: screenPoint.y),
            primaryMonitorHeight: Self.primaryMonitorHeight
        )
    }

    private func crMouseButton(for button: RemoteWindowMouseButton) -> CRMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .middle: return .middle
        }
    }

    /// The AppKit -> `MacdowsCore` boundary conversion for modifier state (W4c review
    /// H1): `RemoteWindowContentView` reports raw `NSEvent.ModifierFlags`; the actual
    /// diff/release-sequence logic lives entirely in the no-AppKit
    /// `MacdowsCore.ModifierKeyTracker` (adr/0006 §2), so this is the one place that
    /// bridges one representation to the other. Same eight keys, same order, as
    /// MRDPView.m's own updateFlagStates (Help/Function added per W4c review M4).
    private static func modifierKeySet(from flags: NSEvent.ModifierFlags) -> ModifierKeySet {
        var result: ModifierKeySet = []
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.numericPad) { result.insert(.numericPad) }
        if flags.contains(.help) { result.insert(.help) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    /// `MacdowsCore.ModifierKeySet`'s single-key constants -> the `CRModifierKey`
    /// `CRSession.send(_:down:)` expects for it. `ModifierKeyTracker` only ever hands back
    /// single-bit `Transition.key` values (see its own `allKeys`-driven implementation), so
    /// this never needs to handle a multi-bit set.
    private static func crModifierKey(for key: ModifierKeySet) -> CRModifierKey {
        switch key {
        case .capsLock: return .capsLock
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .numericPad: return .numericPad
        case .help: return .help
        case .function: return .function
        default:
            // Unreachable in practice (see this function's own doc comment), but
            // ModifierKeySet is an OptionSet, not a closed enum, so the switch must be
            // exhaustive -- .command is as reasonable a default as any single-key fallback,
            // and this path is never actually exercised.
            return .command
        }
    }

    private func handleFrameReady(surfaceId: UInt32) {
        guard let windowId = surfaceToWindow[surfaceId], let window = windows[windowId] else {
            // Either not yet bound to a window, or bound to a window this registry isn't
            // rendering (isMappableWindow filter) — either way, nothing to present;
            // see surfaceToWindow's own doc comment for why this is safe to just skip.
            return
        }
        guard let surface = session.copyPublishedSurface(surfaceId) else {
            // Already consumed by an earlier FrameReady for the same publish, or rejected
            // as stale-generation by CRSession itself — nothing new to display.
            return
        }
        window.present(surface: surface, mappedSize: surfaceMappedSize[surfaceId], via: session)
    }

    /// Diagnostics only (Tools/window-smoke's assertion battery) — not used by the real
    /// app's own rendering path, which never needs to enumerate live windows externally.
    struct WindowSnapshot {
        let windowId: UInt32
        let frame: NSRect
        let isVisible: Bool
        let hasDisplayedContent: Bool
        let title: String
        /// Phase 2 W0③ first-frame gating diagnostic -- see `RemoteWindow.firstFrameTimedOut`'s
        /// own doc comment.
        let firstFrameTimedOut: Bool
    }

    /// Diagnostics only (Tools/window-smoke's W4c input end-to-end assertions) — exposes
    /// the live `NSWindow` so a test harness can synthesize and dispatch a real `NSEvent`
    /// at it, exercising the actual AppKit hit-testing/first-responder dispatch path
    /// rather than calling `RemoteWindowContentView`'s event-handling methods directly (a
    /// test that bypassed real dispatch would only prove the method bodies work, not that
    /// a genuine click/keystroke actually reaches them). Not used by the real rendering
    /// path, which never needs to reach back into an individual window externally.
    func window(forWindowId windowId: UInt32) -> NSWindow? {
        windows[windowId]?.window
    }

    /// Diagnostics only (adr/0008 §6 / task item 5) -- the most recently observed
    /// MonitoredDesktop state, pure data, no ordering/focus policy. Sibling to
    /// `windowSnapshots()` for `Tools/window-smoke`'s harness to assert against once real
    /// activeWindowId/Z-order data is flowing.
    func serverDesktopState() -> ServerDesktopState {
        desktopState
    }

    func windowSnapshots() -> [WindowSnapshot] {
        windows.map { windowId, window in
            WindowSnapshot(
                windowId: windowId, frame: window.frame, isVisible: window.isVisible,
                hasDisplayedContent: window.hasDisplayedContent, title: window.title,
                firstFrameTimedOut: window.firstFrameTimedOut
            )
        }
    }

    /// Diagnostics only (window-smoke's pixel-level assertion, W4b review round 2). See
    /// `RemoteWindow.nonWhitePixelRatio(inBottomFraction:sampleCount:)`'s own doc comment.
    func nonWhitePixelRatio(windowId: UInt32, inBottomFraction bottomFraction: Double, sampleCount: Int) -> Double? {
        windows[windowId]?.nonWhitePixelRatio(inBottomFraction: bottomFraction, sampleCount: sampleCount)
    }

    /// Explicit between-connections reset, for callers that drive reconnects themselves
    /// (window-smoke's WINDOW_SMOKE_CYCLES soak). Necessary because a `shutdownAndWait`
    /// leaves NOTHING for a drain to deliver -- its own step-4 loop consumes the
    /// `.disconnected` event and its final step bumps the generation, after which
    /// `drainEventsWithHandler` discards every remaining (now stale-generation) event --
    /// so neither of `handle()`'s two cleanup triggers (generation change, `.disconnected`)
    /// can ever fire from a post-shutdown drain (2026-08-22 review BLOCKER: the soak's
    /// "forced drain" delivered zero events and the previous cycle's windows survived
    /// into the next). The real app never needs this: it only shuts down at
    /// `applicationWillTerminate`.
    func prepareForReconnect() {
        closeAllWindows()
        currentGeneration = nil
    }

    private func closeAllWindows() {
        for (_, window) in windows {
            window.close(via: session)
        }
        windows.removeAll()
        geometry.removeAll()
        surfaceToWindow.removeAll()
        surfaceMappedSize.removeAll()
        desktopState = ServerDesktopState()
        // adr/0012 §2 reconnect discipline: reset to `.unmonitored` -- the gate can only
        // reopen on a subsequent *real* MonitoredDesktop order, never by any timeout.
        // Covers both this method's two callers: the generation-rollover branch in
        // `handle(_:)` and the explicit `prepareForReconnect()` driver, since both route
        // through here. Effects intentionally discarded, matching `heldModifierKeys`'
        // own reset right below -- the connection this buffered/keyed state described is
        // already gone, so there is nothing left to send any of it to.
        _ = focusAuthority.generationReset()
        // No RELEASE flush here (unlike the .focusLost case) -- the connection this
        // tracked state described is already gone, so there is nothing left to send it to.
        heldModifierKeys = []
        lastMoveSentAt.removeAll()
        pendingTrailingMove.removeAll()
    }
}
