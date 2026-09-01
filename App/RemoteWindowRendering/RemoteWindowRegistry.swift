import AppKit
import Carbon
import MacdowsCore
import os

/// adr/0011 §4: `KBGetLayoutType`'s return type (`OSType`, a four-char code) and the
/// three keyboard-type constants it returns -- self-declared because, per the ADR's own
/// verification, the function and these constants exist only in HIToolbox's exported
/// symbol table (`HIToolbox.tbd`/`Carbon.tbd`), with zero header declaration anywhere in
/// the current SDK. `@_silgen_name` links directly against the real exported symbol by
/// name without needing a bridging header -- required here specifically because
/// `RemoteWindowRegistry.swift` is compiled into BOTH the Macdows app target (which has
/// one, `Macdows-Bridging-Header.h`) AND the window-smoke tool target (which does not);
/// `LMGetKbdType()` itself needs no such treatment -- it IS still declared (HIToolbox's
/// `Events.h`, confirmed in the current SDK), reachable via the plain `import Carbon`
/// above.
@_silgen_name("KBGetLayoutType")
private func KBGetLayoutType(_ keyboardType: Int16) -> OSType

/// 'ANSI', 'ISO ', 'JIS ' as `OSType` four-char codes (verified against an older SDK's
/// `Keyboards.h`, since the current SDK carries no header declaration at all -- see
/// `KBGetLayoutType`'s own doc comment above).
private let kKeyboardANSIType: OSType = 0x414E_5349
private let kKeyboardISOType: OSType = 0x4953_4F20
private let kKeyboardJISType: OSType = 0x4A49_5320

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
    /// `WINDOW_ORDER_FIELD_VISIBILITY` (0x0200) -- gates `numVisibilityRects`/
    /// `visibilityRectsTruncated`/`visibilityRects` together (adr/0010 §2). Note this is a
    /// completely different bit than `WINDOW_ORDER_FIELD_WND_RECTS` (0x0100, `windowRects`
    /// -- still not consumed, adr/0010 §0(a)/§7).
    static let visibility: UInt32 = 0x0000_0200
    static let size: UInt32 = 0x0000_0400
    static let offset: UInt32 = 0x0000_0800
    /// `WINDOW_ORDER_FIELD_VIS_OFFSET` (0x1000) -- gates `visibleOffsetX/Y` together
    /// (adr/0010 §1). Distinct anchor from `offset` above (`windowOffsetX/Y`) -- the two
    /// agree only when the window is unoccluded (adr/0010 §0(b)).
    static let visOffset: UInt32 = 0x0000_1000
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
    /// adr/0010 §2/§3: the window's most recently known visibility rects, wire-relative
    /// (visibleOffset-anchored) -- `numVisibilityRects` is the WIRE's own count (may exceed
    /// `visibilityRects.count` only in the truncated case, where `visibilityRects` itself is
    /// already bounded to `CRDPQ_MAX_VISIBILITY_RECTS`), `visibilityRectsTruncated` mirrors
    /// `CRDPEvent`'s own field 1:1. All three are overwritten wholesale on every order that
    /// carries the VISIBILITY bit (MS-RDPERP resends the complete set, never a delta within
    /// the array itself) -- matching `numVisibilityRects`' own pre-existing merge shape.
    var visibilityRects: [WindowShape.WireRect] = []
    var numVisibilityRects: UInt32 = 0
    var visibilityRectsTruncated: Bool = false
    /// adr/0010 §1: `TS_WINDOW_STATE_ORDER.visibleOffsetX/Y`, meaningless until
    /// `hasSeenVisibleOffset` is `true` -- see that flag's own doc comment for the fail-open
    /// discriminator it exists to make possible (adr/0010 §3 rule 2).
    var visibleOffsetX: Int32 = 0
    var visibleOffsetY: Int32 = 0
    var hasSeenVisibleOffset: Bool = false

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
        if flags & WindowOrderField.visOffset != 0 {
            visibleOffsetX = event.visibleOffsetX
            visibleOffsetY = event.visibleOffsetY
            hasSeenVisibleOffset = true
        }
        if flags & WindowOrderField.size != 0 {
            width = event.windowWidth
            height = event.windowHeight
        }
        if flags & WindowOrderField.visibility != 0 {
            numVisibilityRects = event.numVisibilityRects
            visibilityRectsTruncated = event.visibilityRectsTruncated
            visibilityRects = Self.wireRects(from: event.visibilityRects)
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

    /// `CRDPEvent.visibilityRects` is a flattened `[left, top, right, bottom, left, top,
    /// right, bottom, ...]` `NSNumber` array (that class's own doc comment) -- chunks it
    /// back into `WindowShape.WireRect`s. A malformed (non-multiple-of-4) array is defensive
    /// only (should never occur -- `CRDPEventFromCrdpEvent` always appends complete
    /// 4-tuples): any trailing partial group is simply dropped rather than crashing.
    private static func wireRects(from flat: [NSNumber]) -> [WindowShape.WireRect] {
        var out: [WindowShape.WireRect] = []
        out.reserveCapacity(flat.count / 4)
        var i = 0
        while i + 3 < flat.count {
            out.append(WindowShape.WireRect(
                left: flat[i].doubleValue, top: flat[i + 1].doubleValue,
                right: flat[i + 2].doubleValue, bottom: flat[i + 3].doubleValue
            ))
            i += 4
        }
        return out
    }

    var hasKnownSize: Bool { width > 0 && height > 0 }
    /// WINDOW_HIDE == 0 (freerdp/window.h); any other show value means shown in some form.
    var isVisible: Bool { show != 0 }
    /// `WINDOW_SHOW_MAXIMIZED` (0x03, freerdp/window.h) -- Phase 2 W2 task item 3's zoom
    /// button needs this to decide `SC_MAXIMIZE` vs `SC_RESTORE` (RemoteWindowRegistry's
    /// `handleChromeAction`); everywhere else in this file only cares about
    /// `isVisible`/shown-vs-hidden (adr/0005 §7: full minimize/maximize fidelity beyond
    /// this one W2 need is still out of scope).
    var isMaximized: Bool { show == 0x03 }
    /// `WINDOW_SHOW_MINIMIZED` (0x02, freerdp/window.h) -- adr/0010 §3 rule 5's own
    /// discriminator: `handleWindowOrder` must NOT recompute/apply this window's mask while
    /// this is `true` (the server shrinks a minimized window's own reported size, so its
    /// visibility rects at that moment don't describe the restored shape at all).
    var isMinimized: Bool { show == 0x02 }
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

    /// adr/0010 §4: windowId -> the owner windowId it is CURRENTLY attached to via a real
    /// `NSWindow.addChildWindow(_:ordered:.above)` call. Only ever contains entries for
    /// windows presently in that attached state -- a window whose `ownerWindowId` is 0, or
    /// whose owner isn't (yet, or ever) a known `RemoteWindow`, is simply absent here, never
    /// present with some other sentinel value. `Set(attachedChildOwner.keys)` is this
    /// registry's single source of truth for "which windowIds are currently riding an
    /// owner's Z-order" -- `currentTopDownWindowIds()` is the ONE place that subtracts it
    /// (adr/0010 §4's own "必须同时应用到 window-smoke 的 Z 序断言" requirement is satisfied by
    /// every consumer, including `applyZOrder` and window-smoke's own assertion, reading
    /// through that single method rather than each re-deriving the subtraction).
    private var attachedChildOwner: [UInt32: UInt32] = [:]
    /// adr/0010 §4's fail-open case ("属主不在注册表... 窗口照常独立显示 + 告警一次") -- windowIds
    /// already warned about once, so a window whose owner never resolves doesn't spam a
    /// warning on every single subsequent order.
    private var warnedUnresolvedOwner: Set<UInt32> = []

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

    /// Phase 2 W6 (docs/plans/phase2.md §2 W6 / §4 W6): owns every `NSStatusItem` this
    /// session's RAIL notify icons map to. Session-scoped, same lifetime discipline
    /// `focusAuthority` above already establishes -- `closeAllWindows()` tears it down via
    /// `removeAll()`, same as every other per-connection resource this registry owns. Both of
    /// the wire-contract gaps that type's doc comment used to flag are now closed (icon
    /// pixels/tooltip by adr/0013, the outbound click lane by adr/0014) -- this registry is
    /// the AppKit-side half of the second one: it owns the `CRSession`, so it (not the
    /// controller) performs the `sendNotifyEvent` calls a click turns into, via
    /// `handleTrayIconClick` below.
    private let trayStatusController = TrayStatusController()

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
    /// gone) on `closeAllWindows`.
    ///
    /// adr/0011 §3: this tracks **physical** keyboard truth ONLY, for `ModifierKeyTracker`'s
    /// diff source — it is deliberately no longer the release source (see
    /// `wireHeldModifiers` below for that, and `releaseAllHeldModifiers()`'s own doc
    /// comment for the bug this split fixes).
    private var heldModifierKeys: ModifierKeySet = []
    /// adr/0011 §3's new ledger: which `ModifierKeySet` bits are ACTUALLY held on the wire
    /// right now — updated ONLY at the single point a `.modifierKey` `KeyboardLaneEvent`
    /// actually leaves this process (`sendKeyboardLaneEvent`), never at capture time. This
    /// is the authoritative source for `releaseAllHeldModifiers()`: "线上按住了什么只有出线才
    /// 算数" (adr/0011 §3). Distinct from `heldModifierKeys` above (physical truth) precisely
    /// because the two can now legitimately diverge — a physically-held Cmd may be
    /// represented on the wire as Ctrl (via `CommandKeyMapper`'s remap), as LWIN
    /// (passthrough), or as nothing at all (still withheld) — releasing based on physical
    /// truth instead of this ledger would send the WRONG scancode's RELEASE.
    private var wireHeldModifiers: ModifierKeySet = []
    /// adr/0011 §3: the Cmd<->Ctrl remap state machine — one session-level instance,
    /// mirroring `heldModifierKeys`'/`wireHeldModifiers`' own "one physical keyboard, one
    /// tracked state" precedent. Pure `MacdowsCore` logic; this registry only feeds it
    /// events and executes what it returns (`execute(commandKeyMapperOutput:windowId:)`).
    private let commandKeyMapper = CommandKeyMapper()
    /// adr/0011 §4: this Mac's physical keyboard type, detected once via
    /// `KBGetLayoutType(LMGetKbdType())` at registry construction — feeds
    /// `MacdowsCore.IsoKeyCodeCorrection.correct(macKeyCode:keyboardType:)`, applied to
    /// every physical `macKeyCode` before it's used for anything else (both the ordinary
    /// scancode path and `CommandKeyMapper`'s own passthrough forwarding).
    private let macKeyboardType: MacKeyboardType
    /// adr/0011 §2's degradation discipline ("降级纪律"): the one per-connection gate standing
    /// between an IME commit and the keyboard lane. Pure `MacdowsCore` state machine, same
    /// split as `commandKeyMapper`/`focusAuthority` above -- it decides forward-vs-drop and
    /// owns the "warn exactly once" budget; this registry performs the log call and the
    /// enqueue (or, on a drop, neither). Reset alongside every other per-connection input
    /// state in `closeAllWindows()`; its two counters deliberately survive that reset (see
    /// `unicodeDegradationDiagnostics()`).
    private let unicodeInputGate = UnicodeInputDegradationGate()
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
    ///
    /// M1/W1 (ADR-0015 §5.A.6): renamed for the quantity it now guards, and **split in two**.
    /// What is reported is unchanged in meaning — "there is no usable display layout, so skip
    /// rather than compute a coordinate that was never meaningful" — only its source moved, from
    /// a live `NSScreen.screens.first` read to this session's frozen topology snapshot.
    ///
    /// Two flags rather than one, because r1 review (M1) caught the single flag collapsing the
    /// exact distinction it was introduced to preserve: pre-M1 the static bit guarded ONE
    /// condition, whereas `sessionTopologyOrWarn()` now reports two, and first-occurrence-wins
    /// meant a first session that legitimately ran headless would permanently silence the
    /// "wiring defect" message for the rest of the process — the failure the adjacent comment
    /// there says must not happen. The flags stay `static` (process-wide, never reset), which is
    /// the pre-M1 behavior preserved deliberately rather than changed as a side effect of a unit
    /// migration.
    private static var warnedNoProviderInjected = false
    private static var warnedProviderReportsNoDisplay = false

    /// One-shot for `refreshSessionTopology(reason:)`'s ADR §5.A.4 same-source check (r2 review:
    /// it was the one diagnostic in this file without the throttle every other one has). Once per
    /// process is the right grain even though the check itself runs at most once per connect: a
    /// `WINDOW_SMOKE_CYCLES` soak reconnects N times, and a layout that diverged on cycle 1
    /// diverges on all of them — the first report is the finding, the rest are volume. The exact
    /// count is not lost either, since `sessionTopologyFreezeCount` is what a harness asserts on.
    private static var warnedSessionTopologyDesktopDivergence = false

    /// One-shot record for the MASK UNIT BOUNDARY (ADR-0015 §7 (c); U5 = record-only,
    /// `m1-wave1-rulings.md:4`). Set the first time
    /// `maskContentSize(fromContentRectInPoints:rasterScale:)` is asked to cross the mac-point →
    /// wire-unit boundary at a `rasterScale` other than 1 — which is exactly the condition that
    /// makes today's identity crossing wrong. Recorded, never acted on: M1 is a measurement
    /// batch and the factor itself is W3's to decide from a real 2x session.
    private static var warnedMaskUnitScaleGap = false

    /// Builds the registry for one `CRSession` and freezes that session's display topology.
    ///
    /// - Parameter topologyProvider: the display-topology seam
    ///   (`MacdowsCore.DisplayTopologyProviding`). See the stored property's own doc comment for
    ///   why it is optional and what `nil` means; the short version is that this registry no
    ///   longer knows how to find a screen by itself (ADR-0015 §5.A.5).
    init(session: CRSession, topologyProvider: (any DisplayTopologyProviding)? = nil) {
        self.session = session
        self.topologyProvider = topologyProvider
        self.macKeyboardType = Self.detectKeyboardType()
        // ADR-0015 §5.A: the session's snapshot is taken at CONNECT. This initializer is that
        // moment for a registry built per connection (`App/Macdows/AppDelegate.swift:283`,
        // `Tools/window-smoke/main.swift:974`, both immediately before `CRSession.start()`). The
        // only other freeze is `prepareForReconnect()`, the connect moment for a registry that a
        // caller REUSES across connections; see `refreshSessionTopology(reason:)`.
        refreshSessionTopology(reason: "connect")
        // adr/0014 §1: the tray's only outbound edge. Wired once, here, rather than on every
        // notify-icon order -- `trayStatusController` outlives every individual icon, and a
        // per-order assignment would silently depend on an order having arrived before a
        // click could be handled. `[weak self]` because the controller is owned BY this
        // registry: a strong capture would be a retain cycle through a stored closure.
        trayStatusController.onLeftClick = { [weak self] windowId, notifyIconId in
            self?.handleTrayIconClick(windowId: windowId, notifyIconId: notifyIconId)
        }
    }

    /// adr/0011 §4: `KBGetLayoutType(LMGetKbdType())`, once. Deliberately NOT the
    /// IOHIDManager full-device enumeration `ThirdParty/FreeRDP/client/Mac/Keyboard.m`'s
    /// own `mac_detect_keyboard_type()` uses (adr/0011 §4: "沙箱下的HID访问是另一场决策") — one
    /// call, no enumeration, no extra permission surface. "探测失败或符号缺席 → 一律按ANSI处
    /// 理" (adr/0011 §4): never guess when the symbol table lookup or the returned value is
    /// unrecognized — falling back to ANSI is exactly today's pre-adr/0011 behavior (the
    /// ISO gap stays open, rather than risking a WRONG correction on a keyboard this
    /// couldn't actually identify).
    private static func detectKeyboardType() -> MacKeyboardType {
        let layoutType = KBGetLayoutType(Int16(LMGetKbdType()))
        switch layoutType {
        case kKeyboardISOType: return .iso
        case kKeyboardJISType: return .jis
        default: return .ansi // includes kKeyboardANSIType and any unrecognized value
        }
    }

    /// The display-topology seam (`MacdowsCore.DisplayTopologyProviding`), injected — and
    /// deliberately the only way this class can learn anything about screens at all.
    ///
    /// M1/W1 replaced a `private static var primaryMonitorHeight: Double` that lived on this
    /// exact spot and read `NSScreen.screens.first?.frame.height` on every call. Two separate
    /// rulings removed it. ADR-0015 §5.A.5 confines every `NSScreen` read in the project to the
    /// single App-side provider (W1 deliverable 2), because four files were each doing their own
    /// read and nothing made them agree. ADR §5.A.4 then requires that a session's Y-flip anchor
    /// and the desktop size it negotiated come from the SAME read — which a per-call-site live
    /// lookup cannot satisfy even in principle. See `sessionTopology`.
    ///
    /// Optional with a `nil` default for one reason only: the two construction sites belong to
    /// other lanes and migrate in their own waves (`AppDelegate.swift:283`, landed in wave 2;
    /// `Tools/window-smoke/main.swift:974`, wave 3), and this file must not reach into theirs.
    /// `nil` therefore behaves exactly like "no usable display": every consumer skips and warns
    /// once, none of them invents a substitute (ADR §5.A.6). It is a wiring defect rather than a
    /// supported mode, and `sessionTopologyOrWarn()` says so by name in the log.
    private let topologyProvider: (any DisplayTopologyProviding)?

    /// THE SESSION'S FROZEN TOPOLOGY SNAPSHOT — ADR-0015 §5 (U8, answer A), and the landing
    /// point of its §5.A.4 invariant: *within one session, the Y-flip anchor and the desktop
    /// size must come from the same topology read*.
    ///
    /// Why freezing is a deliberate behavior change and not an optimisation: the anchor used to
    /// be re-derived from `NSScreen.screens.first` at every call, while the desktop size the
    /// server clamps windows against is read exactly once on the connect path and never
    /// resynced (`CRSession.h:284-286`). A display change mid-session therefore moved the anchor
    /// immediately and left the server's desktop untouched — coordinates flipped against the new
    /// primary height, clamped against the old desktop, silently misplaced. Freezing degrades
    /// that into "this session keeps using the layout it negotiated until the next reconnect",
    /// which is diagnosable, is bounded by a reconnect, and is precisely what W1's
    /// screen-parameter observer exists to report (ADR §5.A.2's staleness boolean).
    ///
    /// Taken at construction (= connect) and re-taken ONLY in `prepareForReconnect()`, the
    /// connect moment for a registry a caller reuses across connections. `nil` means "no usable
    /// display layout": headless, every display asleep, or — transitionally — no provider
    /// injected. ADR §5.A.6 forbids substituting anything for it, including the `0` this used to
    /// degrade into; `handleWindowOrder`'s guard records what that costs for the session.
    ///
    /// The App hands over `StaticDisplayTopologyProvider(displayTopology.sessionSnapshot)`
    /// (`AppDelegate.swift:283`) rather than the live provider, so in the App this value is the
    /// literal same `DisplayTopology` the session's desktop size was derived from at
    /// `AppDelegate.swift:263` — §5.A.4 holds exactly, not by same-turn reasoning.
    private var sessionTopology: DisplayTopology?

    /// How many times this registry has frozen a topology snapshot: 1 after `init`, plus one per
    /// `prepareForReconnect()`. Diagnostics only, never read on the rendering path — the same
    /// read-only-counter shape this project already uses for facts that are otherwise invisible
    /// (`CRSession.staleEventsDiscardedCount`, `clicksDroppedIconGone`).
    ///
    /// It exists because when it landed the App target had no test bundle
    /// (`m1-execution-plan.md:38`), so the ADR §5 re-take **could not be pinned by an offline
    /// test** — and r1 review found the previous shape was dead code precisely because nothing
    /// pinned it. D7's bundle (MacdowsAppTests, 2026-09-02) has since landed, but this counter
    /// keeps its job: the re-take needs a live `CRSession` mid-reconnect, which no unit test
    /// stages — the counter, not a test, is still the assertion surface.
    /// This is the assertion surface instead, and the assertion is exact: after an
    /// N-cycle `WINDOW_SMOKE_CYCLES` soak (one `prepareForReconnect()` per finished cycle,
    /// `Tools/window-smoke/main.swift:1667`), **`sessionTopologyFreezeCount == N + 1`**. A value
    /// of 1 means the re-take never fired, which is exactly the defect r1 caught. Handed to L9 in
    /// `task-L7-report.md` as a wave-3 harness item; the registry cannot print it itself, and a
    /// `Logger` line would not do — `Scripts/run-window-smoke.command:158` tees stdout/stderr,
    /// while `os_log` goes to the unified log and never reaches that file.
    private(set) var sessionTopologyFreezeCount = 0

    /// Re-freezes `sessionTopology` from the provider. Called from exactly two places, and both
    /// of them are a connect moment for this registry:
    ///
    ///  * `init` — for a caller that builds a registry per connection (`AppDelegate.swift:283`).
    ///  * `prepareForReconnect()` — for a caller that REUSES one registry across connections.
    ///    That is not hypothetical, and r1 review corrected this comment on the point:
    ///    `CRSession.h:357-364` states the `shutdownAndWait()` → `start()` pairing *is*
    ///    adr/0005 §4's reconnect on a surviving `CRSession`, and `window-smoke`'s
    ///    `WINDOW_SMOKE_CYCLES` soak performs exactly it — one session (`main.swift:953`), one
    ///    registry (`:974`), `shutdownAndWait()` at `:1660`, `prepareForReconnect()` at `:1667`,
    ///    `start()` at `:1719`, every cycle. (The pre-fix version of this file placed the re-take
    ///    on `handle(_:)`'s generation rollover, where `prepareForReconnect()`'s
    ///    `currentGeneration = nil` suppressed it forever: ADR §5's re-take never happened for
    ///    the only in-place reconnect the tree performs. The earlier claim that "nothing does
    ///    this yet" came from grepping for `stop`; the method is `shutdownAndWait`.)
    ///
    /// Deliberately NOT called from the screen-parameter observer: ADR §5.A.3 forbids replacing a
    /// live session's snapshot, and doing so would reinstate exactly the anchor-vs-desktop
    /// divergence freezing exists to remove. Deliberately not called from `handle(_:)` either —
    /// see that method's own note on why the first event is not a re-take moment.
    ///
    /// WHAT THE CALLER STILL OWES, now checked instead of merely asked for. This class cannot
    /// re-send a desktop size: that is renegotiation, which M1's MUST-NOT list assigns to W4. So
    /// a reconnect preserves §5.A.4's same-source invariant only if the caller re-derives the
    /// desktop size in the same turn (for L9: `freezeSessionSnapshot()` and re-assigning
    /// `CRSession.desktopWidth/Height` before `main.swift:1719`'s `start()`). Rather than leave
    /// that as a comment the next implementer may not read, the check below **observes** it: if a
    /// desktop size was negotiated and the freshly frozen topology no longer derives that same
    /// size, it says so — once per process, on the same one-shot discipline as every other
    /// diagnostic here. Recorded, not corrected — M1 is a measurement batch.
    private func refreshSessionTopology(reason: String) {
        sessionTopology = topologyProvider?.currentTopology
        sessionTopologyFreezeCount += 1

        // Skipped when nothing has been negotiated: 0/0 means either "not assigned yet" (a caller
        // that sets `desktopWidth` after building the registry -- `window-smoke` does today) or
        // ADR §5.A.6's "no usable display, so send nothing at all". Neither is a divergence, and
        // warning about them would train the reader to ignore the line that matters.
        guard let topology = sessionTopology, session.desktopWidth > 0, session.desktopHeight > 0
        else { return }
        let derived = topology.desktopSizeInRemotePixels
        let negotiated = (width: Int(session.desktopWidth), height: Int(session.desktopHeight))
        if negotiated != (derived.width, derived.height), !Self.warnedSessionTopologyDesktopDivergence {
            Self.warnedSessionTopologyDesktopDivergence = true
            Self.logger.warning(
                """
                topology snapshot (\(reason, privacy: .public)) derives a desktop of \
                \(derived.width, privacy: .public)x\(derived.height, privacy: .public) remote px, \
                but this session negotiated \
                \(negotiated.width, privacy: .public)x\(negotiated.height, privacy: .public) -- \
                the Y-flip anchor and the desktop size are no longer from the same read \
                (adr/0015 §5.A.4). Recorded only; re-sending a desktop size is renegotiation (W4)
                """
            )
        }
    }

    /// This session's topology, or `nil` after warning once. Every consumer in this file goes
    /// through here, so the pre-M1 "skip, warn once, never fake" discipline — which ADR §5.A.6
    /// requires be carried over unchanged rather than reinvented — exists in one place instead
    /// of once per call site.
    private func sessionTopologyOrWarn() -> DisplayTopology? {
        if let sessionTopology { return sessionTopology }
        // The two states are distinguished on purpose: one is an environment the app is expected
        // to survive, the other is a wiring defect that should be fixed. Collapsing them is how a
        // missing injection hides behind "no display" -- which is what a SHARED warn-once bit
        // would have done (r1 review M1), since whichever occurred first in the process would
        // have silenced the other forever. One bit each.
        let reason: String
        if topologyProvider == nil {
            guard !Self.warnedNoProviderInjected else { return nil }
            Self.warnedNoProviderInjected = true
            reason = "no DisplayTopologyProviding was injected at construction (wiring defect)"
        } else {
            guard !Self.warnedProviderReportsNoDisplay else { return nil }
            Self.warnedProviderReportsNoDisplay = true
            reason = "the injected provider reports no usable display (headless, or every display asleep)"
        }
        Self.logger.warning(
            "no display topology for this session -- \(reason, privacy: .public) -- skipping window positioning and input coordinate conversion rather than producing a bogus coordinate"
        )
        return nil
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
            ownerWindowId: state.ownerWindowId, fieldFlags: fieldFlags, title: state.title
        )
    }

    /// Phase 2 W2 (docs/plans/phase2.md §2 W2 task item 1): thin call-site wrapper over
    /// `MacdowsCore.StyleTranslator.chrome`, exactly mirroring `isMappableWindow` above's
    /// own "the real decision lives in the pure MacdowsCore function, this is just field
    /// plumbing" split.
    private static func chrome(for state: PendingWindowState) -> WindowChrome {
        StyleTranslator.chrome(
            style: state.style, styleEx: state.styleEx, hasTitle: !state.title.isEmpty,
            ownerWindowId: state.ownerWindowId
        )
    }

    /// MS-RDPERP `TS_RAIL_ORDER_SYSCOMMAND` `SC_*` values (docs/plans/phase2.md §2 W2 task
    /// item 4) this registry sends via `CRSession.sendSysCommand(_:command:)` for the
    /// traffic-light actions `RemoteWindow.onChromeAction` reports -- verified directly
    /// against `ThirdParty/FreeRDP/include/freerdp/rail.h:126-133`, not trusted from any
    /// secondhand spec summary (team-lead's own instruction: "verify against FreeRDP rail
    /// headers, don't trust my values blindly" -- they check out exactly). Kept local to
    /// this file rather than exposed as a typed enum from `CRSession.h`
    /// (`-sendSysCommand:command:` stays the same kind of raw, undecorated `uint16_t` pipe
    /// every other outbound method on that header already is -- giving `command` a semantic
    /// meaning is this registry's job, the same split `WindowOrderField`'s bit-flag
    /// constants already establish for window-order fields).
    private enum SysCommand {
        static let minimize: UInt16 = 0xF020
        static let maximize: UInt16 = 0xF030
        static let close: UInt16 = 0xF060
        static let restore: UInt16 = 0xF120
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
            // NO TOPOLOGY RE-TAKE HERE, deliberately -- ADR §5's "a reconnect re-takes the
            // snapshot" lands on `prepareForReconnect()` instead (see
            // `refreshSessionTopology(reason:)`). Two reasons, and the second is the load-bearing
            // one:
            //
            //  1. It would be dead anyway. The one in-place reconnect in the tree
            //     (`window-smoke`'s cycles soak) calls `prepareForReconnect()`, which sets
            //     `currentGeneration = nil` -- so a "was there a previous generation" test can
            //     never be true there, and the app builds a fresh registry per connect. r1 review
            //     found exactly this: the branch that used to live here never executed.
            //  2. Even if it did execute, it would be wrong, and destructively so. This branch
            //     fires on the session's FIRST event, which arrives a whole RDP connect
            //     round-trip after the registry was built. The desktop size the server clamps
            //     against was derived from the screens as they were BEFORE that round-trip and is
            //     never resynced (`CRSession.h:284-286`). Re-reading here would swap in whatever
            //     the layout looks like seconds later while the negotiated desktop stayed behind
            //     -- §5.A.4's divergence, reached by way of the clause meant to prevent it. And
            //     the invariant it would break currently holds EXACTLY, not approximately:
            //     `AppDelegate.swift:263` derives the desktop size and freezes the snapshot in
            //     one `NSScreen` read, then `:283` hands the registry
            //     `StaticDisplayTopologyProvider(displayTopology.sessionSnapshot)` -- literally
            //     the same value, not merely a same-turn re-read (r1 review §4). A re-take here
            //     could only degrade that.
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
            let windowId = UInt32(truncatingIfNeeded: event.mappedWindowId)
            // Team-lead review round 5 (2026-08-23): "surfaces can remap" -- a window's
            // surfaceId is not guaranteed stable for the window's whole lifetime (a resize
            // or other server-side event can trigger a fresh MapSurfaceToWindow for a NEW
            // surfaceId pointing at the SAME windowId). Without this cleanup,
            // `surfaceToWindow` could accumulate multiple surfaceId entries all mapping to
            // this windowId, and `mappedSize(forWindowId:)`'s own linear `.first(where:)`
            // scan has no ordering guarantee -- it could return a STALE surface's size
            // instead of the current one, exactly the kind of drift that made
            // `sizeCorrection(for:windowId:)` observed live to evaluate to zero mid-session.
            // Enforcing windowId -> surfaceId as strictly 1:1 here (removing any OTHER
            // surfaceId this windowId was previously associated with) is what actually
            // guarantees that scan can only ever find the current mapping.
            let staleSurfaceIds = surfaceToWindow.filter { $0.value == windowId && $0.key != event.surfaceId }.map(\.key)
            for staleId in staleSurfaceIds {
                surfaceToWindow.removeValue(forKey: staleId)
                surfaceMappedSize.removeValue(forKey: staleId)
            }
            surfaceToWindow[event.surfaceId] = windowId
            // The mapped sub-rect of the (64-aligned, padded) surface this window shows --
            // consumed by RemoteWindow.present's contentsRect crop; see its comment for
            // why skipping this crop was the white-edges/dead-clicks root cause.
            if event.mappedWidth > 0, event.mappedHeight > 0 {
                surfaceMappedSize[event.surfaceId] = CGSize(
                    width: CGFloat(event.mappedWidth), height: CGFloat(event.mappedHeight))
            }
            // Team-lead review round 6 (2026-08-23, maximize-scenario real-host regression
            // -- the actual root cause, after suspects 1/2/3 were each ruled out): the
            // instrumented run showed the maximize's own big WindowUpdate (windowWidth=2560
            // windowHeight=1440) ARRIVING with `suppressionCount==0` -- not suppressed, not
            // dropped by suspects 1-3 -- yet the window stayed at its pre-maximize size.
            // Root cause: `macContentRect(for:windowId:)` pins content SIZE to this
            // window's CURRENT `mappedSize` (round 3's "mapped is canonical" fix, correct
            // for steady state), and the WindowUpdate arrived BEFORE the server's own GFX
            // surface remap caught up -- this handler updated `surfaceMappedSize` above but
            // never re-triggered a frame recompute, so nothing ever re-applied the geometry
            // once the remap actually landed. Recomputing and reapplying HERE (using the
            // registry's own already-accumulated RAIL state -- `geometry[windowId]`, NOT
            // this event's own fields, which carry only `mappedWidth`/`mappedHeight`/
            // `windowId`, no RAIL offset/size at all) closes that gap: WindowUpdate-then-
            // remap (this case) and remap-then-WindowUpdate (the ordinary case
            // `handleWindowOrder` already handles via its own `macContentRect` call) now
            // both converge on the identical final content rect, since both paths funnel
            // through the exact same computation. `existing.updateFrame(contentRect:)` is
            // itself gate-aware (`RemoteWindow.pendingContentRect`'s own doc comment) --
            // this call site does NOT need to check `hasClearedFirstFrameGate` separately;
            // a gate-held window just records the pending target and applies it once the
            // gate clears, same as every other AppKit-mutating call on this class.
            if let existing = windows[windowId], let state = geometry[windowId],
               let topology = sessionTopologyOrWarn() {
                existing.updateFrame(contentRect: macContentRect(for: state, windowId: windowId, in: topology))
            }
        case .frameReady:
            handleFrameReady(surfaceId: event.surfaceId)
        case .disconnected:
            closeAllWindows()
        case .monitoredDesktop:
            handleMonitoredDesktop(event)
        case .localMoveSize:
            // Phase 2 W3 (docs/plans/phase2.md §2 W3, adr/0008 §1): the two simplest
            // ServerLocalMoveSize semantics only -- start/stop suppression. Full LMS_*
            // keyboard-move semantics (what moveSizeType actually encodes) stay explicitly
            // out of scope for this slice.
            handleLocalMoveSize(event)
        case .minMaxInfo:
            // Phase 2 W3 task item 3: apply track-size constraints as NSWindow.minSize/
            // maxSize.
            handleMinMaxInfo(event)
        case .zOrderSync:
            // adr/0008 §6 / adr/0012 §5: Z-order *sequencing* policy stays explicitly out
            // of this ADR's scope -- ZOrderSync itself carries no array (see
            // CRDPEvent.windowId's own doc comment), the real Z-order array arrives via
            // MonitoredDesktop and is already applied in `applyZOrder` above.
            Self.logger.debug("received zOrderSync windowIdMarker=\(event.windowId, privacy: .public) (recorded only, no policy attached -- adr/0008 §6)")
        // Phase 2 W6 (docs/plans/phase2.md §2 W6): the three notify-icon event cases route
        // to `trayStatusController` -- previously part of the unconditional `break` case
        // below alongside `.windowIcon`/`.execResult`/`.handshakeFlags` (still genuinely
        // ignored; no consumer wants them yet).
        case .notifyIconCreate:
            trayStatusController.noteStoreOverflowCount(Int(session.iconStoreOverflowCount))
            noteNotifyIconVersion(from: event)
            trayStatusController.handleNotifyIconCreate(
                windowId: event.windowId, notifyIconId: event.notifyIconId,
                ownerWindowTitle: ownerWindowTitle(for: event.windowId),
                icon: Self.iconPayload(from: event)
            )
        case .notifyIconUpdate:
            trayStatusController.noteStoreOverflowCount(Int(session.iconStoreOverflowCount))
            noteNotifyIconVersion(from: event)
            trayStatusController.handleNotifyIconUpdate(
                windowId: event.windowId, notifyIconId: event.notifyIconId,
                ownerWindowTitle: ownerWindowTitle(for: event.windowId),
                icon: Self.iconPayload(from: event)
            )
        case .notifyIconDelete:
            trayStatusController.handleNotifyIconDelete(windowId: event.windowId, notifyIconId: event.notifyIconId)
        case .windowIcon, .execResult, .handshakeFlags:
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

    /// Phase 2 W6 (docs/plans/phase2.md §2 W6): the tray degradation form's only source of a
    /// human-readable label -- see `TrayStatusController`'s own doc comment (gap 1) for why
    /// this is the OWNER WINDOW's title, not a notify-icon-specific tooltip (nothing beyond
    /// `windowId`/`notifyIconId` crosses the CRBridge boundary for a notify icon order today).
    /// `nil` (not `""`) when the owner window is unknown or its title is empty, matching
    /// `NSStatusItem.button.toolTip`'s own "no tooltip" convention -- an empty-string tooltip
    /// would still show a (blank) tooltip bubble on hover, which isn't the same thing.
    private func ownerWindowTitle(for windowId: UInt32) -> String? {
        guard let title = geometry[windowId]?.title, !title.isEmpty else { return nil }
        return title
    }

    /// Diagnostics only -- true once the first `ServerLocalMoveSize` event of this
    /// registry's lifetime has been logged verbatim (adr/0008 §0's caveat: this wire shape
    /// was NEVER observed in any of the six phase05 samples, so its first live receipt is a
    /// verification event for the shape itself, not already-proven data -- team-lead
    /// instruction to log raw values on first receipt).
    private var loggedFirstLocalMoveSize = false

    /// Phase 2 W3 task item 4 (docs/plans/phase2.md §2 W3): ServerLocalMoveSize's two
    /// simplest semantics only -- `isMoveSizeStart` begins geometry-application suppression
    /// for this window (the server announcing a move/size modality is the same "don't fight
    /// an in-flight gesture" situation a native local drag creates, adr/0012's
    /// optimistic-prediction principle applied to geometry); the stop transition releases it
    /// and treats it like a settle (`RemoteWindow.endServerAnnouncedMoveResize`'s own doc
    /// comment). What `moveSizeType` actually encodes (the LMS_* keyboard-move handshake)
    /// stays explicitly out of scope for this slice -- logged verbatim, not interpreted.
    private func handleLocalMoveSize(_ event: CRDPEvent) {
        if !loggedFirstLocalMoveSize {
            loggedFirstLocalMoveSize = true
            Self.logger.debug(
                "first ServerLocalMoveSize received (UNVERIFIED wire shape, adr/0008 §0/§1): windowId=\(event.windowId, privacy: .public) isMoveSizeStart=\(event.isMoveSizeStart, privacy: .public) moveSizeType=\(event.moveSizeType, privacy: .public) posX=\(event.moveSizePosX, privacy: .public) posY=\(event.moveSizePosY, privacy: .public)")
        } else {
            Self.logger.debug(
                "ServerLocalMoveSize windowId=\(event.windowId, privacy: .public) isMoveSizeStart=\(event.isMoveSizeStart, privacy: .public) moveSizeType=\(event.moveSizeType, privacy: .public)")
        }
        guard let window = windows[event.windowId] else { return }
        if event.isMoveSizeStart {
            window.beginServerAnnouncedMoveResize()
        } else {
            window.endServerAnnouncedMoveResize()
        }
    }

    /// Phase 2 W3 task item 3 (docs/plans/phase2.md §2 W3, adr/0008 §1): applies
    /// `ServerMinMaxInfo`'s track-size fields to this window's `NSWindow.minSize`/`.maxSize`
    /// via `MacdowsCore.MinMaxInfoTranslator` (pure sentinel-filtering logic) +
    /// `RemoteWindow.applyTrackSizeConstraints` (the AppKit application) -- same
    /// "translate in MacdowsCore, apply in the App target" split `isMappableWindow`/`chrome`
    /// above already establish.
    private func handleMinMaxInfo(_ event: CRDPEvent) {
        guard let window = windows[event.windowId] else { return }
        let constraints = MinMaxInfoTranslator.constraints(
            minTrackWidth: event.minTrackWidth, minTrackHeight: event.minTrackHeight,
            maxTrackWidth: event.maxTrackWidth, maxTrackHeight: event.maxTrackHeight
        )
        window.applyTrackSizeConstraints(constraints)
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
        // `.isVisible` sweep had recognized only 1 of them the whole time).
        //
        // CORRECTION (2026-08-23, W2 first-frame-gate investigation round 2): this
        // comment used to claim `currentTopDownWindowIds()` (i.e. `NSApp.orderedWindows`
        // filtering) was reliable ground truth for "on screen right now" on its own --
        // DISPROVEN live (window-smoke-multiwin.log seq=27/28, window-smoke-max.log
        // seq=25): a freshly-`WindowCreate`d window can appear in `NSApp.orderedWindows`
        // (hence in `currentTopDownWindowIds()`'s own output) before its first-frame gate
        // has EVER cleared -- no `applyVisibility`/`orderFront` call had run for it. Once
        // wrongly treated as `locallyKnown`, THIS method's own `window.order(_:relativeTo:)`
        // call below is exactly what turns that mere list presence into a real,
        // orderFront-equivalent visibility flip -- i.e. this method was reproducing the
        // identical bug class this comment's own opening sentence describes, just via a
        // different route than the original ("Z-order reversal") investigation triggered
        // it through. `currentTopDownWindowIds()` now additionally restricts to
        // `RemoteWindow.hasClearedFirstFrameGate` (see that method's own doc comment) --
        // a gate-held window is never in ITS output, so it's never in `locallyKnown`, so no
        // instruction below can ever reference it. The exact AppKit mechanism behind why a
        // `defer: false` `NSWindow` gets *some* window-server registration at construction
        // time is still not pinned down (the `stillDisagreeing`/`[zorder-trace]` breadcrumb
        // below was watching for exactly this shape and is what caught it) -- gate-state
        // filtering sidesteps needing to know why, the same way this fix's predecessor
        // sidestepped the original `.isVisible` disagreement.
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
    ///
    /// Real-host regression, round 2 (2026-08-23, W2 first-frame-gate investigation): this
    /// method's own prior doc comment claimed `NSApp.orderedWindows` was reliable ground
    /// truth for "on screen right now" -- DISPROVEN live. `window-smoke-multiwin.log`
    /// seq=27: windowId 66354's own `localBefore` (this method's return value, sampled
    /// BEFORE that seq's `applyZOrder` ran any instruction) already contained it, moments
    /// after its own `WindowCreate` -- zero `applyChrome`/`applyVisibility`/`orderFront`
    /// call had EVER run for it (no first-frame content, no first-frame timeout logged
    /// either). A `defer: false` `NSWindow` evidently gets *some* window-server
    /// registration at construction time this codebase's earlier Z-order-reversal trace
    /// investigation never isolated -- the `stillDisagreeing`/`[zorder-trace]` breadcrumb
    /// above was watching for exactly this shape and caught it, just one investigation
    /// round too late to prevent this specific bug from shipping. Restricting to
    /// `RemoteWindow.hasClearedFirstFrameGate` here is what actually closes the gap:
    /// `applyZOrder`'s own `window.order(_:relativeTo:)` call is what turns a gate-held
    /// window's mere `orderedWindows`-list presence into a real, `orderFront`-equivalent
    /// visibility flip the moment `ZOrderSync.plan` wrongly treats it as `locallyKnown` --
    /// a gate-held window excluded HERE can never enter `locallyKnown` in the first place,
    /// regardless of what `NSApp.orderedWindows` itself claims.
    ///
    /// adr/0010 §4: ALSO excludes any windowId currently attached as a child (`Set
    /// (attachedChildOwner.keys)`) -- AppKit itself maintains "a child window is always
    /// above its parent" for an attached window, so asking `applyZOrder` to separately
    /// `order(_:relativeTo:)` it fights that built-in mechanism. Doing the subtraction here,
    /// the single method both `applyZOrder` (via this method's own return value feeding both
    /// `ZOrderSync.plan`'s `locallyKnown` and `currentLocalTopDown` inputs) and
    /// `Tools/window-smoke`'s own Z-order assertion read, is the ADR's own explicit
    /// resolution ("这的减法必须同时应用到 window-smoke 的 Z 序断言") -- one source of truth, not
    /// three separately-applied subtractions that could drift apart (exactly the "可见集与
    /// 比较快照不同源" lesson the W1 STATUS entry already paid for once).
    func currentTopDownWindowIds() -> [UInt32] {
        let attachedChildren = Set(attachedChildOwner.keys)
        let numberToId = Dictionary(uniqueKeysWithValues: windows.compactMap { windowId, remoteWindow in
            (remoteWindow.hasClearedFirstFrameGate && !attachedChildren.contains(windowId)) ? (remoteWindow.window.windowNumber, windowId) : nil
        })
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

    /// Diagnostics only (adr/0011 §5 item 7's acceptance: "降级告警恰好一次且无静默丢字") --
    /// the observable half of adr/0011 §2's degradation discipline, for
    /// `Tools/window-smoke`'s own summary line and for whatever product-shell banner
    /// eventually subscribes to it (see the `.unicodeText` capture site's own KNOWN
    /// DEVIATION note).
    struct UnicodeDegradationDiagnostics {
        /// The capability read for the CURRENT connection: `nil` = not yet read this
        /// connection (no IME commit has arrived since the last connect/reset), which is a
        /// genuinely different state from `false` -- a run that never typed anything must
        /// not be mistaken for one that hit the degradation path.
        let unicodeInputSupported: Bool?
        /// Cumulative for this registry's lifetime, NOT reset on reconnect -- same rule as
        /// `zOrderArraysReceivedCount` and friends ("how much has this registry ever done").
        /// A post-shutdown read (necessarily after `closeAllWindows()` has already reset the
        /// per-connection half) still sees the real totals, which is the whole point: the
        /// acceptance assertion is "exactly one warning per degraded connection, and every
        /// dropped commit accounted for".
        let warningsEmitted: Int
        /// Cumulative, same rule. Counts whole commits (adr/0011 §1: one commit is one lane
        /// slot, atomic), not characters or UTF-16 code units.
        let droppedCommits: Int
    }
    func unicodeDegradationDiagnostics() -> UnicodeDegradationDiagnostics {
        UnicodeDegradationDiagnostics(
            unicodeInputSupported: unicodeInputGate.unicodeInputSupported,
            warningsEmitted: unicodeInputGate.warningsEmitted,
            droppedCommits: unicodeInputGate.droppedCommits
        )
    }

    /// Diagnostics only (adr/0011 §5 item 2: "zero stuck modifiers is a structural
    /// assertion") -- whether the wire-side modifier ledger (`wireHeldModifiers`, the
    /// authoritative "what is ACTUALLY held down on the wire right now" state
    /// `releaseAllHeldModifiers()` reads) is currently empty.
    ///
    /// Read-only, and deliberately exposes only the emptiness predicate rather than the set
    /// itself: the assertion this exists for is "nothing is stuck", not "these specific bits
    /// are held", and a harness that could read the whole set would be tempted to encode a
    /// second, drifting notion of what the ledger should contain mid-chord. This is the LIVE
    /// twin of `MacdowsCore`'s own offline ledger tests (`ModifierKeyTracker`/
    /// `CommandKeyMapper` unit tests, which cover the same invariant against synthetic
    /// event sequences with no CRSession or AppKit anywhere): those prove the state machine
    /// computes the right releases; this proves a real chord sequence, dispatched through a
    /// real `NSWindow`/`RemoteWindowContentView` against a real host, actually left nothing
    /// behind (`Tools/window-smoke`'s adr/0011 §5 item 5/6 batteries gate on it).
    func wireHeldModifiersIsEmpty() -> Bool {
        wireHeldModifiers.isEmpty
    }

    /// Diagnostics only (Tools/window-smoke's `[tray]` summary line, phase2.md §4 W6
    /// acceptance) -- thin passthrough to `trayStatusController.diagnostics()`, same
    /// "Registry exposes, controller/state owns" split `zOrderDiagnostics()` above already
    /// establishes for its own counters.
    func trayDiagnostics() -> TrayStatusController.Diagnostics {
        trayStatusController.diagnostics()
    }

    /// adr/0014 §7: forwards a NotifyIconCreate/Update order's `NOTIFY_ICON_STATE_ORDER.version`
    /// to the tray controller's observation latch, and ONLY when the order actually carried
    /// `WINDOW_ORDER_FIELD_NOTIFY_VERSION` -- `CRDPEvent.notifyIconVersion` is 0 both for
    /// "version 0" and for "no version field", and recording the second as an observation would
    /// manufacture evidence. Observation only: nothing in the click path reads this (v1 sends
    /// the version-free WM_LBUTTONDOWN/WM_LBUTTONUP pair unconditionally, adr/0014 §1).
    private func noteNotifyIconVersion(from event: CRDPEvent) {
        guard event.notifyIconVersionPresent else { return }
        trayStatusController.noteNotifyIconVersion(event.notifyIconVersion)
    }

    /// adr/0013 §3: repackages one drained NotifyIconCreate/Update event's icon fields into
    /// the shape `TrayStatusController` consumes. A pure field transcription -- no policy,
    /// which is why it is `static` and lives beside the two call sites rather than inside the
    /// controller (same "Registry adapts, controller renders" split the tray path already
    /// has). The pixels themselves were already copied out of the C side-store and into an
    /// owned `NSData` by `CRDPEventFromCrdpEvent`, so nothing here shares lifetime with the
    /// session (adr/0013 §1's write-on-T_rdp / read-after-drain contract ends at that copy).
    private static func iconPayload(from event: CRDPEvent) -> TrayStatusController.IconPayload {
        TrayStatusController.IconPayload(
            rgba: event.iconRGBA,
            width: Int(event.iconWidth),
            height: Int(event.iconHeight),
            skipped: event.iconSkipped,
            cached: event.iconCached,
            toolTip: event.toolTip
        )
    }

    /// adr/0014 §1: one left click on a tray icon becomes TWO RAIL ClientNotifyEvent PDUs --
    /// `WM_LBUTTONDOWN` then `WM_LBUTTONUP` -- posted as two independent outbound commands.
    /// Their order on the wire is the outbound queue's own FIFO guarantee (adr/0005 §3), not
    /// anything either PDU encodes, which is why this loops `TrayNotifyEvent.leftClickSequence`
    /// (an ordered array, see its own doc comment) rather than sending a single compound
    /// message. `windowId`/`notifyIconId` are the icon's wire identity, forwarded verbatim: a
    /// notify event is self-addressed, so nothing here consults geometry, focus, or the
    /// window table at all.
    ///
    /// No focus/activation call belongs in this path (adr/0014 §3) -- see
    /// `TrayStatusController.handleLeftClick(tag:)`'s own doc comment for the full argument;
    /// the prohibition is stated at the click handler because that is where an "activate the
    /// owner window first" reflex would land.
    private func handleTrayIconClick(windowId: UInt32, notifyIconId: UInt32) {
        for message in TrayNotifyEvent.leftClickSequence {
            session.sendNotifyEvent(windowId, notifyIconId: notifyIconId, message: message)
            trayStatusController.noteNotifyEventSent()
            // Fired per PDU, from the one place a PDU is actually posted, for the same reason
            // `onWindowMoveSent` exists (see its own doc comment): a harness that re-derived
            // "what a click sends" from `TrayNotifyEvent` on its own side would be asserting
            // against its own copy of the sequence, not against what left this process.
            // `nil` (the default) is a safe no-op.
            onTrayNotifyEventSent?(windowId, notifyIconId, message)
        }
    }

    /// See `handleTrayIconClick`'s own doc comment on why this exists. Diagnostics only --
    /// not read anywhere on the real rendering path.
    var onTrayNotifyEventSent: ((_ windowId: UInt32, _ notifyIconId: UInt32, _ message: UInt32) -> Void)?

    /// Diagnostics only (`Tools/window-smoke`'s `WINDOW_SMOKE_TRAY_CLICK` scenario, adr/0014
    /// §6): drives a tray left click for `(windowId, notifyIconId)` through the REAL path --
    /// `TrayStatusController.handleLeftClick(tag:)`, entered with the same packed tag
    /// `upsertStatusItem` writes into the live `NSStatusBarButton`, so the liveness re-check,
    /// the counters, and this registry's own two-PDU send all execute exactly as they do for a
    /// user's click. The ONLY thing skipped is AppKit's own event delivery (there is no
    /// supported way to synthesize a real menu-bar click for another process's status item),
    /// which is also why this is deliberately not a shortcut straight to `handleTrayIconClick`:
    /// a harness bypassing the controller would stop covering the drop-if-gone branch that
    /// makes `clicksDroppedIconGone == 0` a meaningful assertion.
    func debugSimulateTrayClick(windowId: UInt32, notifyIconId: UInt32) {
        trayStatusController.handleLeftClick(
            tag: TrayButtonTag.pack(windowId: windowId, notifyIconId: notifyIconId)
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

        // L1, carried over verbatim in meaning by ADR-0015 §5.A.6, which requires reusing this
        // existing fail-open discipline rather than inventing new behavior for the state: no
        // topology means there is no usable display layout — the screen list
        // was empty (headless or display-asleep) or, transitionally, no provider was injected.
        // `WindowGeometry.macRect` would still compute *something* from whatever anchor we
        // invented for it (before M1: a zero height, hence a bogus and typically negative Y),
        // silently placing/moving a window at a coordinate that was never actually meaningful.
        // Skip positioning entirely instead — this event's geometry is still recorded above (the
        // state merge already ran), so nothing has to be resent by the server.
        //
        // WHAT THIS DOES NOT PROMISE, corrected in r1 review (I2) because the pre-M1 sentence
        // that used to sit here promised the opposite: this is fail-open for the EVENT, not
        // recovery for the SESSION. Before M1 the anchor was re-read per call, so a screen
        // arriving later fixed everything by itself. Under the frozen snapshot it does not:
        // `sessionTopologyOrWarn()` reads stored state, the screen-parameter observer must not
        // replace it (§5.A.3), and no reconnect happens without the caller driving one. A session
        // that connects with no usable display therefore **positions nothing until it
        // reconnects**, and the observer's event is what says why (§5.A.2).
        //
        // That is deliberate, not an oversight, and the alternative was considered rather than
        // overlooked (r1 review's O4). Re-taking as soon as a display appears would make the old
        // sentence true again — and would position windows against a desktop that was never
        // negotiated: with no topology at connect, L6 correctly sets no `desktopWidth/Height` at
        // all (§5.A.6 forbids 0x0), so the server is running FreeRDP's 1024x768 default
        // (`CRSession.h:285-292`). A freshly acquired anchor would be same-read with nothing, and
        // the result is the invisible-wall shape that section records. Waiting for a reconnect --
        // where the anchor and the desktop size are re-derived together -- is the safer side.
        //
        // The binding this produces is also what threads ADR §5.A.4 through the rest of the
        // method: every conversion below — inbound rect, mask bounds, and (via
        // `handleLocalGeometrySettled`) the outbound rect — anchors on this one snapshot rather
        // than on three independent reads that can disagree.
        guard let topology = sessionTopologyOrWarn() else { return }

        let contentRect = macContentRect(for: state, windowId: windowId, in: topology)
        if let existing = windows[windowId] {
            existing.updateFrame(contentRect: contentRect)
            existing.updateTitle(state.title)
            // Phase 2 W2 task item 3: re-derived on every order, cheap and correct either
            // way -- RemoteWindow.applyChrome's own `appliedChrome` equality check already
            // makes this a no-op unless style/styleEx/title/owner actually changed since
            // the last time this window's chrome was applied, so no separate fieldFlags
            // gate is needed here (unlike `setVisible` below, which has a real Z-order side
            // effect worth gating specifically).
            existing.applyChrome(Self.chrome(for: state))
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
            // adr/0010 §2's own "重算时机" clause: any geometry-affecting order recomputes
            // the mask, not only ones that carried the VISIBILITY bit itself -- Δ depends on
            // the window's CURRENT offsetX/Y, which a plain move/resize order changes even
            // without a fresh visibilityRects array. Rule 5 (skip while minimized) is this
            // call site's own responsibility, not `WindowShape.computeMask`'s -- see
            // `PendingWindowState.isMinimized`'s own doc comment.
            if !state.isMinimized {
                existing.applyMask(
                    computeMaskResult(for: state, windowId: windowId, contentSize: contentRect.size, in: topology))
            }
            updateParentChild(windowId: windowId, ownerWindowId: state.ownerWindowId)
        } else {
            let key = RemoteWindowKey(windowId: windowId, generation: generation)
            let chrome = Self.chrome(for: state)
            // adr/0010 §5: the popup tier is picked once, at construction, from this
            // window's own initial chrome -- `WindowChrome.titled == false` is the ADR's own
            // discriminator (NOT `WS_POPUP`; see `StyleTranslator`'s own doc comment for why
            // that would be wrong -- e.g. the About dialog IS `WS_POPUP` but still titled).
            let firstFrameTimeout = chrome.titled ? RemoteWindow.defaultFirstFrameTimeout : RemoteWindow.popupFirstFrameTimeout
            let window = RemoteWindow(key: key, contentRect: contentRect, title: state.title, firstFrameTimeout: firstFrameTimeout)
            window.onInput = { [weak self] event in
                self?.handleInput(windowId: windowId, event: event)
            }
            // Phase 2 W2 task item 3: traffic-light clicks/⌘W/⌘M/double-click-titlebar
            // route here, never mutate `window`'s own NSWindow state locally (server
            // authority -- see RemoteWindow.onChromeAction's own doc comment).
            window.onChromeAction = { [weak self] action in
                self?.handleChromeAction(windowId: windowId, action: action)
            }
            // Phase 2 W3: native drag/resize settle, or the server's own
            // ServerLocalMoveSize stop -- both route through the same
            // RemoteWindow.onLocalGeometrySettled closure (see that property's own doc
            // comment); this registry's only job is the coordinate conversion and the
            // actual CRSession.sendWindowMove call.
            window.onLocalGeometrySettled = { [weak self] contentRect in
                self?.handleLocalGeometrySettled(windowId: windowId, contentRect: contentRect)
            }
            // Real-host regression fix (2026-08-23, popup-scenario live battery): retries
            // `updateParentChild` once this window's own first-frame gate clears -- see
            // `RemoteWindow.onFirstFrameGateCleared`'s own doc comment for why
            // `updateParentChild`'s FIRST attempt (made synchronously below, at creation) is
            // unconditionally skipped for a still-gated child, and `retryParentAttach`'s own
            // doc comment for why re-reading `geometry[windowId]` here (rather than
            // recapturing `state.ownerWindowId` in this closure) is the correct source.
            window.onFirstFrameGateCleared = { [weak self] in
                self?.retryParentAttach(windowId: windowId)
            }
            window.applyChrome(chrome)
            windows[windowId] = window
            if !state.isMinimized {
                window.applyMask(
                    computeMaskResult(for: state, windowId: windowId, contentSize: contentRect.size, in: topology))
            }
            updateParentChild(windowId: windowId, ownerWindowId: state.ownerWindowId)
            window.setVisible(state.isVisible)
        }
    }

    /// adr/0010 §2: gathers this window's shape inputs (visibilityRects/anchor/correction
    /// already tracked by `geometry`/`sizeCorrection`) and calls the pure
    /// `MacdowsCore.WindowShape.computeMask` transform -- same "translate in MacdowsCore,
    /// apply in the App target" split `isMappableWindow`/`chrome` already establish.
    ///
    /// THIS CALL IS THE MASK PIPELINE'S UNIT BOUNDARY — ADR-0015 §7 (c), and specifically that
    /// section's "(c) 的位置更正" note (its relocation of item (c)): the boundary is here, at
    /// this single call, and NOT at
    /// `RemoteWindow.swift:925`, which merely consumes an already-computed `LayerRect`. Read the
    /// argument list as two columns (§1's vocabulary):
    ///   * **remote px** — `visibilityRects` (wire `RECTANGLE_16` off `crdpq_window_order_t`),
    ///     `windowOffset` (RAIL `offsetX`/`offsetY`), `visibleOffset` (RAIL
    ///     `visibleOffsetX`/`Y`), `correction` (`WindowGeometryCorrection`, whose own unit note
    ///     pins it to remote px), `topInset` (adr/0010 §6's placeholder, always 0).
    ///   * **mac pt** — `contentSize`, which arrives from `macContentRect(for:windowId:in:)`,
    ///     i.e. from the far side of a `WindowGeometry.macRect` conversion.
    /// `WindowShape.computeMask` uses that second column as the BOUNDS it clips the first column
    /// against (`WindowShape.swift:161-189`), so the two must be one unit — and today they are,
    /// only because `rasterScale == 1`. `maskContentSize(fromContentRectInPoints:rasterScale:)`
    /// below is the named crossing that makes that dependency visible instead of implicit; see
    /// its own doc comment for why M1 deliberately applies no factor there.
    ///
    /// The named crossing is NOT `WindowGeometry.macRect`, and that is a standing ban rather
    /// than a stylistic choice: adr/0010 §2 forbids reusing it in this pipeline
    /// (`WindowShape.swift:29-34`) and ADR-0015 §7 restates and strengthens the ban, because
    /// the mask lives in LAYER-local space — bottom-left origin, flipped against the content
    /// height — a third coordinate space with nothing in common with the screen-space flip
    /// anchored on the primary display's height. "Route it through a named conversion" must not
    /// be read as "route it through the one named conversion this file already imports".
    ///
    /// `topology` is the session's frozen snapshot, threaded from `handleWindowOrder`'s guard so
    /// that the mask's `rasterScale` and the content rect's flip anchor are the same read
    /// (ADR §5.A.4).
    private func computeMaskResult(
        for state: PendingWindowState,
        windowId: UInt32,
        contentSize: NSSize,
        in topology: DisplayTopology
    ) -> WindowShape.MaskResult {
        let correction = sizeCorrection(for: state, windowId: windowId)
        return WindowShape.computeMask(
            visibilityRects: state.visibilityRects, // remote px (wire RECTANGLE_16)
            wireCount: state.numVisibilityRects, // a count, unitless
            truncated: state.visibilityRectsTruncated,
            windowOffset: (x: Double(state.offsetX), y: Double(state.offsetY)), // remote px (RAIL)
            visibleOffset: state.hasSeenVisibleOffset
                ? (x: Double(state.visibleOffsetX), y: Double(state.visibleOffsetY)) // remote px (RAIL)
                : nil,
            correction: correction, // remote px (WindowGeometryCorrection's own unit note)
            topInset: 0, // remote px (adr/0010 §6 placeholder, always 0)
            contentSize: Self.maskContentSize(
                fromContentRectInPoints: contentSize, // mac pt, from macContentRect
                rasterScale: topology.rasterScale
            ),
            isMaximized: state.isMaximized
        )
    }

    /// THE MASK PIPELINE'S NAMED UNIT CROSSING — ADR-0015 §7 (c), under U5's record-only ruling
    /// (`m1-wave1-rulings.md:4`).
    ///
    /// CURRENT UNIT: in **mac pt** (`macContentRect`'s `NSRect.size`), out a
    /// `WindowShape.ContentSize` that `computeMask` uses as the clip bounds for **remote px**
    /// wire rects. The crossing is therefore real, and today it is the identity — every display
    /// this project has ever run on has `remotePixelsPerPoint == 1`, because we advertise no
    /// `DesktopScaleFactor` (ADR §0a/§0c; `docs/plans/phase3.md:219`).
    ///
    /// WHY NO MULTIPLICATION HERE, stated plainly because writing `× rasterScale` would look
    /// more finished and cost one character: it is not this milestone's call, and doing it would
    /// be actively wrong today. ADR §7 (c) reserves "whether the conversion really multiplies by
    /// `rasterScale`" for W3, and ADR §9's L8 row forbids introducing any scale multiplication
    /// into the mask path in this wave. The substantive reason is that scaling here would move
    /// only half the pipeline: `computeMask` returns `LayerRect`s that `RemoteWindow` compares
    /// against `contentView.bounds.size` in POINTS (`RemoteWindow.swift:925`, with `:951-952` the
    /// mask application; L8's own file reaches the same conclusion independently at `:918-924`),
    /// so multiplying the bounds without dividing the output would change rendered
    /// pixels — which M1 must not do (§9's L8 row spells out that "zero rendering change" means
    /// bit-identical output on today's hardware). What M1 owes is the crossing's *point and
    /// type*, plus a record of the moment it stops being harmless.
    ///
    /// W3 TRIGGER: any session where `rasterScale != 1`. Observed rather than asserted, and
    /// recorded rather than corrected — M1 is a measurement batch, so the handling is the same
    /// one ADR §2 rule 4 fixes for mixed-scale topologies: record once, do not degrade, do not
    /// refuse, do not change behavior. The `!= 1` comparison is exact on purpose: `rasterScale`
    /// is a whole display ratio the collector fills in (1 or 2 today), never an accumulated
    /// computation, so there is no epsilon to reason about.
    ///
    /// TRIGGERED SHAPE (the values, and the choice between the two forms, are W3's — from a real
    /// 2x measurement, not guessed here): convert BOTH ends coherently. Either hand `computeMask`
    /// remote-pixel bounds and divide its `LayerRect`s back to points at the AppKit boundary, or
    /// keep the bounds in points and divide the wire rects on the way in. Which one is a
    /// `WindowShape` API question — it is decided by `WindowShape.ContentSize`'s unit contract —
    /// and cannot be settled by this call site alone.
    private static func maskContentSize(
        fromContentRectInPoints contentSize: NSSize,
        rasterScale: Double
    ) -> WindowShape.ContentSize {
        if rasterScale != 1, !warnedMaskUnitScaleGap {
            warnedMaskUnitScaleGap = true
            logger.warning(
                "mask unit boundary (ADR-0015 §7 (c)): content bounds are mac points but WindowShape.computeMask clips remote-pixel wire rects against them, and rasterScale=\(rasterScale, privacy: .public) != 1 -- recorded, not corrected; the factor is W3's after a real 2x measurement"
            )
        }
        return WindowShape.ContentSize(width: Double(contentSize.width), height: Double(contentSize.height))
    }

    /// adr/0010 §4: resolves/updates `windowId`'s real `NSWindow.addChildWindow` attachment
    /// against its most recently merged `ownerWindowId`. Idempotent against a redundant call
    /// with the same, already-attached owner. Re-evaluated on every order (not just
    /// creation) since `ownerWindowId` is itself a delta-merged sub-field that could in
    /// principle change -- cheap either way (a dictionary lookup plus, at most, one
    /// AppKit call).
    ///
    /// GATE FIFTH BYPASS ROUTE (real-host regression, 2026-08-23, popup-scenario live
    /// battery under the borderless-chrome flip -- confirmed against `window-smoke-popup.log`):
    /// `NSWindow.addChildWindow(_:ordered:)` was observed to materialize a still-gated
    /// (zero-content, never-`orderFront`'d) CHILD window on screen immediately -- the exact
    /// same failure class as the four previously-sealed bypass routes (construction-time
    /// registration, `applyZOrder`'s `order(_:relativeTo:)`, chrome's styleMask/frame
    /// mutation, `activateLocally`'s `makeKeyAndOrderFront`), just a fifth AppKit call site
    /// nobody had gated yet. The log's own event sequence nails it: windowId 66252
    /// (`style=0x80000000`, no chrome-implying bits -- a plain popup, `owner=131174`, an
    /// ALREADY on-screen About window) hit `[first-frame] VIOLATION` immediately after this
    /// method's own call, strictly BEFORE `handleWindowOrder`'s subsequent
    /// `window.setVisible(state.isVisible)` call ever ran -- so `setVisible` cannot have been
    /// the cause; this call was the only AppKit mutation in between. This is not a rare
    /// case: a popup's `WindowCreate` carries a fully-resolved `ownerWindowId` before any
    /// content has ever presented (that's the entire reason the popup first-frame tier
    /// exists at all -- adr/0010 §5), so `windows[windowId]` right below is, for a popup,
    /// essentially ALWAYS still gate-held the very first time this method ever runs for it.
    ///
    /// Fix mirrors the established `pendingChrome`/`pendingMask`/`pendingVisible`/
    /// `pendingActivate` precedent: skip the AppKit call entirely (do not touch
    /// `attachedChildOwner` either -- attachment genuinely hasn't happened) while
    /// `childWindow.hasClearedFirstFrameGate` is false, and retry once it clears via
    /// `RemoteWindow.onFirstFrameGateCleared` -> `retryParentAttach` below. Deliberately
    /// does NOT also gate on the OWNER's own gate state -- every observed and expected
    /// popup owner is an already-displayed top-level window that predates the popup by
    /// construction (a menu/dialog's owner is the window the user was already looking at),
    /// and symmetrically deferring would need a second, reciprocal retry mechanism (owner
    /// gate-clear -> re-attach every pending child) with no real-host evidence yet that it's
    /// needed; flagged here, not silently assumed impossible, should a future run ever show
    /// otherwise.
    private func updateParentChild(windowId: UInt32, ownerWindowId: UInt32) {
        let currentOwnerId = attachedChildOwner[windowId]

        if ownerWindowId != 0, let ownerWindow = windows[ownerWindowId] {
            guard currentOwnerId != ownerWindowId else { return } // already correctly attached
            guard let childWindow = windows[windowId] else { return }
            // See this method's own "GATE FIFTH BYPASS ROUTE" doc comment above --
            // `retryParentAttach` re-invokes this method once the child's gate clears, so
            // this is a genuine "not yet" rather than a permanent skip.
            guard childWindow.hasClearedFirstFrameGate else { return }
            if let currentOwnerId, let oldOwnerWindow = windows[currentOwnerId] {
                oldOwnerWindow.window.removeChildWindow(childWindow.window)
            }
            ownerWindow.window.addChildWindow(childWindow.window, ordered: .above)
            attachedChildOwner[windowId] = ownerWindowId
            warnedUnresolvedOwner.remove(windowId)
        } else {
            // adr/0010 §4 fail-open: ownerWindowId == 0 (desktop-owned, adr/0012 §3's same
            // convention), or the owner isn't (yet, or ever) a window this registry renders
            // -- detach if previously attached, and warn once (not every order) for the
            // "owner not registered" case specifically, since that's the one worth a human
            // noticing (a plain 0 owner is completely ordinary and not worth logging at all).
            if let currentOwnerId, let oldOwnerWindow = windows[currentOwnerId], let childWindow = windows[windowId] {
                oldOwnerWindow.window.removeChildWindow(childWindow.window)
            }
            attachedChildOwner.removeValue(forKey: windowId)
            if ownerWindowId != 0, !warnedUnresolvedOwner.contains(windowId) {
                warnedUnresolvedOwner.insert(windowId)
                Self.logger.warning(
                    "windowId=\(windowId, privacy: .public) has ownerWindowId=\(ownerWindowId, privacy: .public) which is not (yet, or ever) a known RemoteWindow -- adr/0010 §4 fail-open: displaying independently, no parent-child attachment"
                )
            }
        }
    }

    /// `RemoteWindow.onFirstFrameGateCleared`'s registry-side handler (see that property's
    /// own doc comment, and `updateParentChild`'s "GATE FIFTH BYPASS ROUTE" doc comment for
    /// the real-host finding this closes the loop on): re-evaluates `windowId`'s
    /// parent-child attachment now that its own first-frame gate has actually cleared.
    /// Re-reads `geometry[windowId]`'s CURRENT `ownerWindowId` rather than capturing it in
    /// the closure at construction time -- a delta `WindowUpdate` could in principle have
    /// changed it before the gate cleared (the same "current state, not stale capture"
    /// discipline `handleChromeAction`'s `isMaximized` lookup already follows). A window
    /// with no `ownerWindowId` at all (e.g. already closed, or never carried the OWNER
    /// field) is simply not retried -- `geometry[windowId]` is `nil` after
    /// `handleWindowDelete`, and `PendingWindowState.ownerWindowId` defaults to 0
    /// (desktop-owned) otherwise, which `updateParentChild` already treats as "no
    /// attachment needed" -- so this needs no separate guard for either case.
    private func retryParentAttach(windowId: UInt32) {
        guard let ownerWindowId = geometry[windowId]?.ownerWindowId else { return }
        updateParentChild(windowId: windowId, ownerWindowId: ownerWindowId)
    }

    /// The one and only place Windows-space geometry becomes an `NSRect` — always through
    /// `MacdowsCore.WindowGeometry`, per the W4b task spec's explicit instruction never
    /// to reimplement this math anywhere else in this layer.
    ///
    /// Real-host regression (2026-08-23, W3 first live verification, formerly named
    /// `macFrame(for:)`): RAIL's `offsetX/offsetY/width/height` describe the remote
    /// window's own OUTER rect as the remote desktop sees it -- the content view displays
    /// those exact remote pixels verbatim (remote titlebar included, see
    /// `RemoteWindow.init`'s own doc comment), so this conversion's result is the target
    /// window's CONTENT rect, never its `NSWindow.frame` directly. Renamed from `macFrame`
    /// to make that explicit at every call site; the arithmetic itself (`WindowGeometry.
    /// macRect(from:in:)`, which before M1/W1 took a bare primary height) was always correct --
    /// only the RESULT's meaning was mislabeled. `RemoteWindow.updateFrame(contentRect:)` is
    /// what actually derives the real outer frame from this value, via
    /// `NSWindow.frameRect(forContentRect:)`.
    ///
    /// UNITS (M1/W1, ADR-0015 §1): in **remote px** -- `state.offsetX/Y/width/height` are RAIL
    /// wire values -- out **mac pt**, an `NSRect` in AppKit's global screen space. The single
    /// `WindowGeometry.macRect(from:in:)` call is where the two spaces meet, and `topology` is
    /// the session's frozen snapshot (never a fresh screen read), which is ADR §5.A.4's
    /// same-read invariant at its inbound end.
    ///
    /// Second real-host regression (2026-08-23, W3 round 2 -> round 3, team-lead review):
    /// round 2 assumed RAIL's rect was the OUTER (larger) rect, visible content INSET from
    /// it -- WRONG, and confirmed wrong by the very debug line that round added
    /// (`Tools/window-smoke`'s `[move-resize] raw RAIL geometry`): a real capture showed
    /// `offsetX=338 offsetY=62 windowWidth=494 windowHeight=500` against a GFX-mapped
    /// (displayed) size of `508x507` -- RAIL's rect is SMALLER than what's displayed, not
    /// larger. Subtracting a positive inset therefore moved the round-trip further from
    /// correct, not closer (round 2's own numbers: sent a target based on 494x500-ish
    /// content, still `matched=false`).
    ///
    /// Round 3 reframes around the one fact that IS unambiguous (team-lead review): the GFX
    /// `MapSurfaceToWindow` order's `mappedWidth`/`mappedHeight` is, definitionally, what
    /// gets displayed -- `RemoteWindow.present`'s own `contentsRect` crop already targets it
    /// (adr/0005 §2). Before this fix, this window's actual on-screen content SIZE tracked
    /// RAIL's `windowWidth`/`windowHeight` (494x500) while the CALayer's `contentsGravity
    /// == .resize` stretched the (correctly cropped) `508x507`-visible image to fit that
    /// smaller content view -- a real ~2.8%/1.4% stretch distortion, independent of and
    /// compounding the round-trip position bug, now eliminated as a side effect of this fix
    /// (confirmed by inspecting `present(surface:mappedSize:via:)`: `contentsRect` only
    /// crops the SOURCE image within the surface's own 64-aligned allocation, it has no
    /// opinion on the DESTINATION layer/content-view size at all, so a content-view size
    /// mismatch was always silently absorbed as a stretch, never caught).
    ///
    /// `sizeCorrection(for:windowId:)` below returns `MacdowsCore.WindowGeometryCorrection`
    /// (mapped-minus-RAIL, signed, `origin{X,Y} == 0`) MEASURED per-window from data already
    /// flowing through this registry, no wire-protocol extension needed (MS-RDPERP does
    /// carry a more direct field for exactly this concept --
    /// `resizeMarginLeft/Top/Right/Bottom`, `WINDOW_ORDER_FIELD_RESIZE_MARGIN_X/Y`,
    /// `freerdp/window.h:217-220` -- but adr/0008 §0's own sample survey found those bits
    /// inconsistently present across observed WindowCreate `fieldFlags` values, `0x1100DF1E`
    /// lacks them where `0x1900DF9E` has them; wiring a new crdpq POD field for an
    /// inconsistently-sent value needs its own adr/0008-style sample verification pass, out
    /// of scope for this slice). `WindowGeometry.displayRect(from:correction:)` applies it;
    /// see that function's own doc comment for the round-trip-identity guarantee
    /// `WindowGeometryTests` locks down offline.
    ///
    /// F6 (d) -- `resizeMargin*`, the not-taken road above (M1/W1 tagging pass; U5 = record-only,
    /// `m1-wave1-rulings.md:4`; ADR-0015 §7 (d)). Three things this paragraph adds and the one
    /// above does not:
    ///   * UNIT, if it is ever wired: **remote px**. `resizeMarginLeft/Top/Right/Bottom` are
    ///     RAIL window-order fields (`ThirdParty/FreeRDP/include/freerdp/window.h:217-220`), so
    ///     they share the wire's unit with `offsetX/Y` and `windowWidth/Height` -- Windows
    ///     space, before any flip, no `rasterScale` term.
    ///   * The paragraph above states adr/0008 §0's `fieldFlags` inconsistency as a settled
    ///     finding. It is not settled: `docs/plans/phase3.md:232` (§8.14) records that very
    ///     conclusion as still pending re-verification. That distinction is the whole
    ///     content of F6 (d) -- a closed road and an unverified road look identical from here,
    ///     and only one of them is worth re-walking.
    ///   * W3 TRIGGER and TRIGGERED SHAPE (ADR §7 (d)): the trigger is the §8.14 re-verification
    ///     itself, which must happen BEFORE anything is wired -- W3 does not get to skip it on
    ///     the strength of a 2x measurement. If it passes, wire the field and let it replace the
    ///     hardcoded `measuredClientWindowMoveLeftBorder` (F6 (a), below). If it fails, record
    ///     "this road is closed" *with its evidence* at that point, so the next reader does not
    ///     re-derive the survey a third time.
    ///
    /// Origin is NOT corrected (`WindowGeometryCorrection.originX/Y == 0` always, this
    /// slice): `RDPGFX_MAP_SURFACE_TO_WINDOW_PDU` (`CRSession.mm`'s
    /// `crb_gfx_map_surface_to_window`) carries ONLY `mappedWidth`/`mappedHeight` -- no
    /// position field exists to diff against RAIL's `offsetX`/`offsetY` the way
    /// `mappedWidth`/`mappedHeight` diffs against `windowWidth`/`windowHeight`, and RAIL's
    /// own offset is the only position signal this client ever receives at all, so there is
    /// no second, independent measurement to derive an origin delta from (verified by
    /// reading the actual PDU decode, not assumed). Zero-origin also matches the physically
    /// simplest reading of the one real measurement available: anchoring the window's
    /// top-left at RAIL's own `offsetX`/`offsetY` unchanged, and letting the extra
    /// mapped-vs-RAIL size grow toward increasing X/Y (right/down) from that anchor, is
    /// consistent with a capture surface that simply extends a few extra rows/columns past
    /// the window's own reported client rect on those two edges -- a coherent physical
    /// story, not merely "we had no better idea." Flagged in `WindowGeometryCorrection`'s
    /// own doc comment for W4's shaped-window work to revisit if future evidence ever
    /// supplies an independent position measurement.
    private func macContentRect(for state: PendingWindowState, windowId: UInt32, in topology: DisplayTopology) -> NSRect {
        let correction = sizeCorrection(for: state, windowId: windowId)
        let railRect = WindowsRect(x: Double(state.offsetX), y: Double(state.offsetY), width: Double(state.width), height: Double(state.height))
        let windowsRect = WindowGeometry.displayRect(from: railRect, correction: correction)
        let macRect = WindowGeometry.macRect(from: windowsRect, in: topology)
        return NSRect(x: macRect.x, y: macRect.y, width: macRect.width, height: macRect.height)
    }

    /// The signed, per-window `MacdowsCore.WindowGeometryCorrection` (mapped size minus
    /// RAIL's own reported size, `origin{X,Y} == 0`) -- see `macContentRect(for:windowId:)`'s
    /// own doc comment for the full real-host finding and reasoning this implements.
    /// MEASURED: `mappedSize(forWindowId:)` is the GFX `MapSurfaceToWindow` order's own
    /// `mappedWidth`/`mappedHeight` (already captured by `surfaceMappedSize` for
    /// `RemoteWindow.present`'s `contentsRect` crop), the actual pixel dimensions the server
    /// rendered for this window -- whatever a given DPI/theme/Windows-build combination
    /// happens to produce, not assumed. Re-read at EVERY call (never cached) -- team-lead
    /// review round 5 (2026-08-23): the mapped size itself changed mid-session in one real
    /// run (536x521 -> 522x514, "surfaces can remap"), so this must reflect current state at
    /// send/apply time, not a value captured once at window-creation time.
    ///
    /// Real-host regression (round 5): guard failure used to fall back to a hardcoded
    /// nonzero constant (`(14, 7)`, cited from a single earlier run) -- observed live to
    /// produce a WRONG, silently-wrong correction when the guard passed on stale/garbage
    /// data that merely happened to look valid (`state.width > 0` doesn't guarantee `state`
    /// reflects THIS window's current reality if `geometry[windowId]` was itself stale).
    /// Changed to "skip correction (return `.zero`) and warn" per team-lead instruction: a
    /// wrong guess is worse than no correction at all, and the warning makes a
    /// missing/degraded measurement an OBSERVABLE event instead of a silent wrong number --
    /// matches this codebase's established fail-open discipline (adr/0008 §4).
    private func sizeCorrection(for state: PendingWindowState, windowId: UInt32) -> WindowGeometryCorrection {
        guard let mapped = mappedSize(forWindowId: windowId), mapped.width > 0, mapped.height > 0,
              state.width > 0, state.height > 0
        else {
            let mappedDescription = String(describing: mappedSize(forWindowId: windowId))
            Self.logger.warning(
                "sizeCorrection: no valid measurement for windowId=\(windowId, privacy: .public) (mappedSize=\(mappedDescription, privacy: .public) RAIL size=\(state.width, privacy: .public)x\(state.height, privacy: .public)) -- skipping correction (.zero) rather than guessing"
            )
            return .zero
        }
        return WindowGeometryCorrection(
            originX: 0, originY: 0,
            width: Double(mapped.width) - Double(state.width),
            height: Double(mapped.height) - Double(state.height)
        )
    }

    /// Reverse lookup over `surfaceToWindow` (which only maps surfaceId -> windowId) for
    /// `sizeCorrection(for:windowId:)`'s own need to go the other way -- a linear scan, but
    /// over at most a handful of live surfaces per session, called only on a window-order or
    /// local-geometry-settle event, never per-frame.
    private func mappedSize(forWindowId windowId: UInt32) -> CGSize? {
        guard let surfaceId = surfaceToWindow.first(where: { $0.value == windowId })?.key else { return nil }
        return surfaceMappedSize[surfaceId]
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
        warnedUnresolvedOwner.remove(windowId)

        // adr/0010 §4: "父窗口 close(via:) 前必须先 removeChildWindow(_:)" -- detach BOTH
        // directions before this window's own `close(via:)` call below runs: if this window
        // is itself an attached CHILD, detach it from its owner; if it's an attached OWNER
        // (of other windows), detach each of those children from it first, so none of them
        // are left referencing a parent whose `NSWindow` is about to close.
        if let ownerId = attachedChildOwner.removeValue(forKey: windowId),
           let ownerWindow = windows[ownerId], let closingWindow = windows[windowId]
        {
            ownerWindow.window.removeChildWindow(closingWindow.window)
        }
        let childrenOfThis = attachedChildOwner.filter { $0.value == windowId }.map(\.key)
        if !childrenOfThis.isEmpty, let closingWindow = windows[windowId] {
            for childId in childrenOfThis {
                if let childWindow = windows[childId] {
                    closingWindow.window.removeChildWindow(childWindow.window)
                }
                attachedChildOwner.removeValue(forKey: childId)
            }
        }

        if let window = windows.removeValue(forKey: windowId) {
            window.close(via: session)
        }
    }

    /// Phase 2 W2 (docs/plans/phase2.md §2 W2 task item 3): routes one traffic-light action
    /// from `windowId`'s `RemoteWindow` to the matching `SC_*` `CRSession.sendSysCommand`
    /// call -- this registry, not `RemoteWindow`, decides `.zoom`'s direction (`SC_MAXIMIZE`
    /// vs `SC_RESTORE`) because only this registry knows the window's last-known RAIL
    /// show-state (`geometry[windowId]`); `RemoteWindow` itself has no notion of "currently
    /// maximized" at all. Fire-and-forget, same as every other outbound call this registry
    /// makes -- no local NSWindow mutation happens here either; the server's own
    /// WindowDelete/WindowUpdate response is what `handleWindowDelete`/`handleWindowOrder`
    /// eventually act on.
    private func handleChromeAction(windowId: UInt32, action: RemoteWindow.ChromeAction) {
        switch action {
        case .close:
            session.sendSysCommand(windowId, command: SysCommand.close)
        case .minimize:
            session.sendSysCommand(windowId, command: SysCommand.minimize)
        case .zoom:
            let isMaximized = geometry[windowId]?.isMaximized ?? false
            session.sendSysCommand(windowId, command: isMaximized ? SysCommand.restore : SysCommand.maximize)
        }
    }

    /// W4c: routes one `RemoteWindowInputEvent` from `windowId`'s `RemoteWindow` to
    /// `CRSession` (adr/0005's Phase 1 "clickable/interactive" milestone). This is the
    /// one and only place a mac-screen point becomes a Windows-space absolute desktop
    /// coordinate for *input* — mirrors `macContentRect(for:)` being the one and only place
    /// the reverse direction happens for window geometry; `RemoteWindowContentView` never
    /// does this conversion itself.
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
            // ADR-0015 §5.A.6: no topology -> skip the conversion, do not substitute one.
            // Ordered BEFORE the throttle stamp (r1 review M3): `lastMoveSentAt` records a send,
            // and on the skip path no send happens -- stamping it first would let a skipped move
            // throttle the next real one.
            guard let point = remotePoint(from: screenPoint) else { return }
            lastMoveSentAt[windowId] = now
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
            // ADR-0015 §5.A.6, as above. Placed after the focus-authority step deliberately: the
            // local activation is this client's own state machine and is unaffected by whether a
            // coordinate can be expressed; only the wire send is skipped.
            guard let point = remotePoint(from: screenPoint) else { return }
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
            // ADR-0015 §5.A.6, as above.
            guard let point = remotePoint(from: screenPoint) else { return }
            if Float(abs(deltaY)) > Float.ulpOfOne {
                session.sendMouseVerticalWheelDelta(deltaY, atX: Int32(point.x), y: Int32(point.y))
            } else if Float(abs(deltaX)) > Float.ulpOfOne {
                session.sendMouseHorizontalWheelDelta(deltaX, atX: Int32(point.x), y: Int32(point.y))
            }

        case .keyDown(let rawMacKeyCode, _, let charactersIgnoringModifiers):
            // adr/0012 §2: keyboard is focus-addressed (the wire message itself carries no
            // windowId -- CRSession.h's `sendKeyDown:`/`sendKeyUp:` take only a scancode),
            // so it must not reach the wire until FocusAuthority confirms the server's own
            // `activeWindowId` actually matches what we're claiming key for. Routed through
            // the gate rather than sent directly, unlike mouse (position-addressed, §2:
            // "鼠标是位置寻址，天然免闸").
            //
            // adr/0011 §4: ISO Grave/Section correction applies to EVERY physical key,
            // independent of Cmd handling -- done first, here, before either downstream
            // path (CommandKeyMapper's own passthrough forwarding needs the corrected code
            // too).
            let macKeyCode = IsoKeyCodeCorrection.correct(macKeyCode: rawMacKeyCode, keyboardType: macKeyboardType)
            if commandKeyMapper.isActive {
                // adr/0011 §3: translation happens BEFORE the gate -- whatever
                // CommandKeyMapper returns is already line-shape, so it's what actually
                // gets enqueued, not the raw keyDown.
                execute(commandKeyMapperOutput: commandKeyMapper.key(
                    down: true, macKeyCode: macKeyCode, charactersIgnoringModifiers: charactersIgnoringModifiers
                ), windowId: windowId)
            } else {
                execute(focusAuthority.enqueueKeyboardEvent(.keyDown(macKeyCode: macKeyCode), at: CFAbsoluteTimeGetCurrent()))
            }

        case .keyUp(let rawMacKeyCode, _, let charactersIgnoringModifiers):
            let macKeyCode = IsoKeyCodeCorrection.correct(macKeyCode: rawMacKeyCode, keyboardType: macKeyboardType)
            if commandKeyMapper.isActive {
                execute(commandKeyMapperOutput: commandKeyMapper.key(
                    down: false, macKeyCode: macKeyCode, charactersIgnoringModifiers: charactersIgnoringModifiers
                ), windowId: windowId)
            } else {
                execute(focusAuthority.enqueueKeyboardEvent(.keyUp(macKeyCode: macKeyCode), at: CFAbsoluteTimeGetCurrent()))
            }

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
                // adr/0011 §3: Cmd's own wire representation is entirely owned by
                // CommandKeyMapper -- withheld until resolved, never a direct
                // `.modifierKey(.command,...)` passthrough. Shift is intercepted too, but
                // ONLY while a Cmd gesture is undecided/mapped (the only shift-sensitive
                // row, Cmd+Shift+Z); idle-state Shift, and every other modifier bit
                // regardless of state, keeps flowing through the ordinary path unchanged.
                if transition.key == .command {
                    execute(commandKeyMapperOutput: commandKeyMapper.commandChanged(down: transition.down), windowId: windowId)
                } else if transition.key == .shift, commandKeyMapper.isActive {
                    execute(commandKeyMapperOutput: commandKeyMapper.shiftChanged(down: transition.down), windowId: windowId)
                } else {
                    execute(focusAuthority.enqueueKeyboardEvent(.modifierKey(transition.key, down: transition.down), at: CFAbsoluteTimeGetCurrent()))
                }
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
            // adr/0011 §3: abandon any in-flight Cmd gesture too -- its own internal state
            // (e.g. "a chord is open") would otherwise survive focus loss stale; the wire
            // side is already correctly closed out by releaseAllHeldModifiers() above via
            // wireHeldModifiers, independent of whatever CommandKeyMapper still thinks.
            commandKeyMapper.reset()

        case .unicodeText(let text):
            // adr/0011 §2's degradation gate, evaluated BEFORE the lane: on a server whose
            // Input Capability Set never set INPUT_FLAG_UNICODE, FreeRDP's own
            // `freerdp_input_send_unicode_keyboard_event` drops each event with nothing but
            // a WLog_WARN (adr/0011 §0b, "静默丢字...不可接受"), so the IME path has to be
            // disabled here, whole, rather than discovered one lost character at a time.
            //
            // The capability is read lazily, at the first commit that would need it, and
            // cached for the connection (`UnicodeInputDegradationGate`'s own contract).
            // That is sound because `CRSession.unicodeInputSupported` is set on T_rdp
            // immediately after `freerdp_connect` returns TRUE and strictly before the
            // event loop that posts any RAIL order starts running -- so by the time any
            // window exists to have received a keystroke, let alone an IME commit, the
            // answer is already published.
            switch unicodeInputGate.evaluateCommit(readCapability: { self.session.unicodeInputSupported }) {
            case .forward:
                // adr/0011 §1/§2: an IME commit -- same gate as every other keyboard-lane
                // event (adr/0012 §2 unchanged), atomic (whole string, one buffer slot).
                execute(focusAuthority.enqueueKeyboardEvent(.unicodeText(text), at: CFAbsoluteTimeGetCurrent()))
            case .drop(let warn):
                // Dropped HERE, before `enqueueKeyboardEvent` -- deliberately not buffered
                // "in case the server changes its mind": anything that reaches the lane's
                // FIFO can later be flushed to the wire by a gate-open (adr/0012 §2), and
                // this text must never reach a server that would silently discard it.
                if warn {
                    // Length only, never the text itself: an IME commit is by definition
                    // whatever the user just typed (passwords included), and this log is
                    // not a place for it. `.error` rather than `.warning` because adr/0011
                    // §2 wants this "对用户可见" and this is the loudest channel that exists
                    // at harness scope today.
                    //
                    // KNOWN DEVIATION from adr/0011 §2's "对用户可见": v1 user visibility is
                    // this log plus `unicodeDegradationDiagnostics()`, not a UI banner --
                    // there is no product shell to host one yet (the app is a harness with
                    // no chrome of its own beyond per-window titlebars). The gate, its
                    // counters and its warn-once budget are exactly what a banner would
                    // subscribe to once such a shell exists, so this is a missing
                    // presentation layer, not a missing mechanism.
                    Self.logger.error("adr/0011 §2 degradation: server did not negotiate INPUT_FLAG_UNICODE -- IME/Unicode input is disabled for this connection; dropped a \(text.count, privacy: .public)-character commit (further drops are counted, not logged)")
                }
            }
        }
    }

    /// adr/0011 §3: routes one `CommandKeyMapper` result into either the ordinary
    /// `FocusAuthority` gate (`.wire`) or the existing SC_CLOSE traffic-light path
    /// (`.closeRequest`, Cmd+W) -- mirrors `execute(_:)` below's "translate effects into
    /// side effects" shape, one level up the pipeline.
    private func execute(commandKeyMapperOutput output: CommandKeyMapperOutput, windowId: UInt32) {
        switch output {
        case .wire(let events):
            for event in events {
                execute(focusAuthority.enqueueKeyboardEvent(event, at: CFAbsoluteTimeGetCurrent()))
            }
        case .closeRequest:
            handleChromeAction(windowId: windowId, action: .close)
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

    /// The single wire-exit point for the keyboard lane (adr/0011 §3: "只在真正出线的那一个出
    /// 口(sendKeyboardLaneEvent)更新" -- this is that outlet). Every `.modifierKey` sent from
    /// HERE, regardless of source (the ordinary per-bit diff, or a `CommandKeyMapper`-
    /// translated Ctrl/LWIN/Shift event), updates `wireHeldModifiers` -- the ledger
    /// `releaseAllHeldModifiers()` below now reads from instead of physical truth.
    private func sendKeyboardLaneEvent(_ event: KeyboardLaneEvent) {
        switch event {
        case .keyDown(let macKeyCode):
            session.sendKeyDown(macKeyCode)
        case .keyUp(let macKeyCode):
            session.sendKeyUp(macKeyCode)
        case .modifierKey(let key, let down):
            session.send(Self.crModifierKey(for: key), down: down)
            if down {
                wireHeldModifiers.insert(key)
            } else {
                wireHeldModifiers.remove(key)
            }
        case .unicodeText(let text):
            session.sendUnicodeText(text)
        }
    }

    /// Shared by `.focusLost` (immediate/ungated) and `.dropBufferedInput(...,
    /// withModifierRelease: true)` (also immediate/ungated -- see that effect's own doc
    /// comment) -- both need the exact same "release everything actually on the wire right
    /// now" flow (W4c review H1).
    ///
    /// adr/0011 §3: reads `wireHeldModifiers`, NOT `heldModifierKeys` -- this is the fix for
    /// a latent bug the ADR documents: `heldModifierKeys` used to double as both "physical
    /// truth" AND "release source", updated at *capture* time (§3's own Registry:1121
    /// citation) while releases were computed from it at a LATER point (§3's own
    /// Registry:1213-1218 citation) -- any DOWN captured but then discarded (buffer
    /// dropped, gate never opened) had never actually reached the wire, yet still produced
    /// a RELEASE for it. Pre-adr/0011 that was merely an extra harmless RELEASE; post-
    /// adr/0011, with Cmd able to be remapped to a DIFFERENT wire scancode (Ctrl) than its
    /// physical identity (Cmd/LWIN), the same bug would send the WRONG key's RELEASE --
    /// physical Cmd lifting would RELEASE LWIN while Ctrl is what's actually held on the
    /// wire, leaving Ctrl stuck (exactly the shape adr/0012 §2 and W4c review H1 both
    /// already call out as unacceptable).
    private func releaseAllHeldModifiers() {
        let releases = ModifierKeyTracker.releaseAll(wireHeldModifiers)
        wireHeldModifiers = []
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
        // ADR-0015 §5.A.6: no topology -> skip the conversion, do not substitute one. Before the
        // throttle stamp, same reason as `.mouseMoved`'s (r1 review M3).
        guard let point = remotePoint(from: screenPoint) else { return }
        lastMoveSentAt[windowId] = CFAbsoluteTimeGetCurrent()
        session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))
    }

    /// Phase 2 W3 (docs/plans/phase2.md §2 W3): the one and only place a settled local
    /// window CONTENT rect becomes a `CRSession.sendWindowMove` call -- the exact inverse of
    /// `macContentRect(for:)` above, through the same `MacdowsCore.WindowGeometry` conversion
    /// every other geometry boundary crossing in this file already uses
    /// (`WindowGeometry.windowsRect(from:in:)` is literally `macRect(from:in:)`'s documented
    /// inverse -- and since M1/W1 it is inverse in a stronger sense than before: both take the
    /// same `DisplayTopology` value, so the pair cannot be anchored on two different heights
    /// even if the screens change between the inbound and outbound halves of one drag).
    /// UNITS (ADR-0015 §1): in **mac pt**, out **remote px**. `contentRect` arrives
    /// already converted from `NSWindow.frame` to the content rect by `RemoteWindow` itself
    /// (`window.contentRect(forFrameRect:)`, an AppKit-chrome fact that class already owns --
    /// see `RemoteWindow.onLocalGeometrySettled`'s own doc comment; real-host regression,
    /// 2026-08-23: this method used to receive and convert the raw frame directly, which was
    /// off by exactly this window's chrome insets once W2 gave it a native titlebar). RAIL's
    /// own `RAIL_WINDOW_MOVE_ORDER`/`crdpq_cmd_window_move_t` are RECT-shaped (left/top/
    /// right/bottom), not x/y/width/height -- `right`/`bottom` are derived here, at this one
    /// call site, rather than trusting `CRSession.sendWindowMove` to do that arithmetic (see
    /// that method's own doc comment for why its signature is shaped to make that mistake
    /// impossible to reintroduce elsewhere). Values are rounded, not truncated, before
    /// narrowing to `Int32` -- an unrounded truncation would systematically bias every
    /// settled rect's right/bottom edge down-and-left by up to 1pt.
    ///
    /// Second real-host regression (2026-08-23, W3 round 2 -> round 3): `contentRect` is the
    /// DISPLAYED (GFX-mapped-size) rect (see `macContentRect(for:windowId:)`'s own doc
    /// comment for the full reframing) -- `ClientWindowMove` needs RAIL's own size
    /// convention, same as `WindowUpdate` sends it inbound, so `WindowGeometry.railRect(
    /// from:correction:)` (the exact, tested inverse of `displayRect(from:correction:)`
    /// `macContentRect` uses inbound) converts back here, using the SAME
    /// `sizeCorrection(for:windowId:)` value both directions share -- neither direction can
    /// drift out of sync with the other since both call the same correction lookup and the
    /// same pair of inverse pure functions.
    private func handleLocalGeometrySettled(windowId: UInt32, contentRect: NSRect) {
        // L1 / ADR-0015 §5.A.6: same fail-open guard as `handleWindowOrder`'s, same reasons.
        // Reading the SESSION's snapshot (rather than the live layout) is also §5.A.4's
        // same-read invariant at its outbound end: the rect this sends back to the server is
        // un-flipped against exactly the height the rect it came from was flipped against.
        guard let topology = sessionTopologyOrWarn() else { return }
        let macRect = MacRect(x: contentRect.origin.x, y: contentRect.origin.y, width: contentRect.size.width, height: contentRect.size.height)
        let displayedWindowsRect = WindowGeometry.windowsRect(from: macRect, in: topology)
        let correction = sizeCorrection(for: geometry[windowId] ?? PendingWindowState(), windowId: windowId)
        let railWindowsRect = WindowGeometry.railRect(from: displayedWindowsRect, correction: correction)
        // Team-lead review round 5 (2026-08-23): `railWindowsRect.x` above is the VISIBLE
        // left -- `ClientWindowMove`'s own `left` needs the additional, asymmetric,
        // outbound-only border correction `WindowGeometry.clientWindowMoveLeft`'s own doc
        // comment works the full algebra for (three consecutive real-host runs each showed
        // a clean +7 echo). `right` shifts by the same amount as a direct consequence of
        // `left` shifting while `railWindowsRect.width` itself is untouched -- see that
        // function's own doc comment for why width/right are deliberately NOT also adjusted
        // (no matching evidence, and a naive symmetric-border guess for width would actually
        // contradict the already-validated size-correction sign).
        let correctedLeft = WindowGeometry.clientWindowMoveLeft(
            fromVisibleLeft: railWindowsRect.x, measuredLeftBorder: Self.measuredClientWindowMoveLeftBorder
        )
        let left = Int32(correctedLeft.rounded())
        let top = Int32(railWindowsRect.y.rounded())
        let right = Int32((correctedLeft + railWindowsRect.width).rounded())
        let bottom = Int32((railWindowsRect.y + railWindowsRect.height).rounded())
        session.sendWindowMove(windowId, left: left, top: top, right: right, bottom: bottom)
        // Team-lead review round 4 (2026-08-23): a MacdowsCoreTests-level offline
        // reproduction of this exact call's own math (using this round's real-host numbers)
        // already confirmed today's conversion is correct for the input it's given -- the
        // open question is now whether a *different* input reaches this method than
        // intended, or whether the round's observed "echo" wasn't a direct confirmation of
        // this move at all. `onWindowMoveSent` exists so a test harness can log the VERBATIM
        // sent rect without re-deriving this method's own math a second time (which would
        // risk the log itself silently diverging from what's actually sent) -- `nil` (the
        // default) is a safe no-op, matching `CRSession.onEventsAvailable`'s own precedent.
        onWindowMoveSent?(windowId, left, top, right, bottom)
    }

    /// See `handleLocalGeometrySettled`'s own doc comment on why this exists. Diagnostics
    /// only -- not read anywhere on the real rendering path.
    var onWindowMoveSent: ((_ windowId: UInt32, _ left: Int32, _ top: Int32, _ right: Int32, _ bottom: Int32) -> Void)?

    /// Team-lead review round 5 (2026-08-23): the outbound-only left-border amount
    /// `handleLocalGeometrySettled` feeds `WindowGeometry.clientWindowMoveLeft` -- see that
    /// function's own doc comment for the full algebra. NOT derived from
    /// `sizeCorrection.width` (deliberately -- that function's own doc comment explains why
    /// treating "7 == 14/2" as a causal relationship, rather than numerical coincidence for
    /// this one window, isn't something this evidence actually supports) -- a standalone,
    /// evidence-cited constant, same "coarse stand-in until per-window data says otherwise"
    /// status the old `fallbackSizeCorrection` constant had. Unlike `sizeCorrection`, this
    /// has NO independent per-window wire measurement available at all (see
    /// `clientWindowMoveLeft`'s own doc comment: it is inferred purely from three repeated
    /// send/echo deltas, not derived from two independently-known wire quantities the way
    /// `sizeCorrection` is), so there is no "measured, not hardcoded" version of this to
    /// build yet -- flagged for revisiting if a real-host run ever shows a different value
    /// for a different window/DPI/Windows-build.
    ///
    /// F6 (a) -- M1/W1 tagging pass; U5 = record-only (`m1-wave1-rulings.md:4`); ADR-0015 §7 (a):
    ///   * UNIT: **remote px**. It shares a domain with RAIL's own `offsetX` -- it is subtracted
    ///     from `railWindowsRect.x` in Windows space, after the flip and before the
    ///     `left`/`top`/`right`/`bottom` integers go on the wire -- so no point conversion and
    ///     no `rasterScale` term is involved at this site.
    ///   * WHY THE VALUE DOES NOT MOVE IN M1: all three real-host measurements behind the 7 were
    ///     taken on the same 1x host (`docs/plans/phase3.md:219`), where "7 remote px" and
    ///     "7 pt" are numerically indistinguishable. Picking one now would be re-guessing, not
    ///     re-measuring (`phase3.md:223`, §8.5: no 2x measurement exists). The unit above is
    ///     therefore an attribution of the existing evidence, not a new claim about it.
    ///   * W3 TRIGGER: the paragraph above already named it before M1 existed -- "a different
    ///     window/DPI/Windows-build" -- and W3's 2x session is precisely that DPI change.
    ///   * TRIGGERED SHAPE (the value is W3's, from measurement): either ① a constant re-measured
    ///     on a 2x session, or ② an expression derived from RAIL's own `resizeMarginLeft` -- see
    ///     F6 (d) in `macContentRect(for:windowId:in:)`'s doc comment, and note that route
    ///     unblocks only if the adr/0008 §0 `fieldFlags` re-verification (`phase3.md:232`, §8.14)
    ///     passes first. Explicitly NOT "multiply by `rasterScale`": this is a server-side
    ///     window-border thickness, and nothing in evidence says a window-manager border scales
    ///     linearly with DPI (ADR-0015 §7 (a) rules that option out by name).
    private static let measuredClientWindowMoveLeftBorder: Double = 7

    /// The one and only place a mac-screen point becomes a `WindowsPoint`, exactly
    /// mirroring `macContentRect(for:)` above for the reverse (Windows-rect -> mac-rect)
    /// direction. Always through `MacdowsCore.WindowGeometry` — never a second, ad hoc
    /// coordinate-math implementation in this file or `RemoteWindowContentView`.
    /// UNITS (M1/W1, ADR-0015 §1): in **mac pt** (AppKit global screen space), out
    /// **remote px** (an absolute RAIL desktop coordinate). Anchored on the session's frozen
    /// snapshot, like every other conversion here (§5.A.4).
    ///
    /// RETURNS `nil` when this session has no topology, and that is a deliberate behavior
    /// change in that one state. The pre-M1 code fed a zero primary height into the same flip
    /// and sent the resulting coordinate — meaningless, and negative for any point on a real
    /// screen — to the server anyway; there was never a reading under which it was right.
    /// ADR §5.A.6's rule for this state is that consumers *skip the conversion*, never substitute
    /// a value, so the four callers guard instead of sending.
    ///
    /// THE SKIP IS UNREACHABLE, and the reason is structural ordering — not "a mouse event needs
    /// an on-screen window, which needs a screen", which is the weaker argument this comment
    /// carried at r1 and which stops being true the day any of these links moves (r1 review M2,
    /// whose chain this is):
    ///  1. `RemoteWindow` is constructed in exactly one place, in `handleWindowOrder`.
    ///  2. That site is downstream of `guard let topology = sessionTopologyOrWarn()`, so a window
    ///     exists only if the snapshot was non-`nil` when it was created.
    ///  3. The snapshot can only become `nil` inside `refreshSessionTopology(reason:)`, whose two
    ///     callers both run with no window alive — `init` predates every window, and
    ///     `prepareForReconnect()` calls `closeAllWindows()` first, unconditionally.
    ///  4. Input reaches `handleInput` only through `window.onInput`, i.e. only from a live
    ///     window.
    /// ⇒ no window outlives a non-`nil` → `nil` transition ⇒ this cannot return `nil` while any
    /// window exists. A silent skip is acceptable only while that holds; if step 2 or 3 is ever
    /// rearranged, this needs a counter rather than a comment.
    ///
    /// W3 ITEM, named rather than left implicit (r1 review M4): this project's discipline for
    /// dropped wire traffic is a counter, not only a log (`CRSession.staleEventsDiscardedCount`,
    /// `clicksDroppedIconGone`, `crdpq.h:260-275`'s per-cause `iconSkipped` split). These four
    /// skips have none, which M1 can carry only because of the proof above, and adding one now
    /// would be new surface this lane's MUST-NOT discourages. W3 is what makes the topology state
    /// genuinely varied, so W3 is where a per-cause skip counter belongs.
    private func remotePoint(from screenPoint: NSPoint) -> WindowsPoint? {
        guard let topology = sessionTopologyOrWarn() else { return nil }
        return WindowGeometry.windowsPoint(from: MacPoint(x: screenPoint.x, y: screenPoint.y), in: topology)
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

    /// Diagnostics only (Tools/window-smoke's `[move-resize]` raw-geometry debug line,
    /// 2026-08-23 W3 round 2/3 team-lead review) -- exposes `mappedSize(forWindowId:)` (the
    /// GFX-measured visible size `sizeCorrection(for:windowId:)` derives its correction from)
    /// so a test harness can print the RAW RAIL size next to it and confirm/refute the
    /// measured-correction fix directly against real wire values, rather than trusting this
    /// registry's own already-corrected output. Not used by the real rendering path.
    func debugMappedSize(forWindowId windowId: UInt32) -> CGSize? {
        mappedSize(forWindowId: windowId)
    }

    /// Diagnostics only (Tools/window-smoke's `[move-resize]` raw-geometry debug line,
    /// 2026-08-23 W3 round 5 team-lead review) -- the registry's own ACCUMULATED, delta-
    /// merged RAIL size for this window (`geometry[windowId].width/height`, the same value
    /// `sizeCorrection(for:windowId:)` actually reads), as opposed to a single event's own
    /// possibly-zero `windowWidth`/`windowHeight` fields (populated only when that
    /// particular order carries `WINDOW_ORDER_FIELD_WND_SIZE` -- a size-less order, e.g. a
    /// position-only or style-only update, correctly reports these as 0, which is NOT the
    /// same as "this window's size is unknown"). The debug line used to diff a raw event's
    /// own (sometimes-zero) fields against the mapped size, producing garbage
    /// `impliedSizeCorrection` output on any event that happened not to carry the SIZE bit
    /// -- this accessor is what lets that line report the SAME accumulated-state value
    /// `sizeCorrection` itself actually uses, so the diagnostic and the real code path can
    /// never silently diverge. `nil` if this windowId has no tracked geometry at all (should
    /// not happen for a window this registry is actively rendering).
    func debugAccumulatedRailSize(forWindowId windowId: UInt32) -> (width: UInt32, height: UInt32)? {
        guard let state = geometry[windowId] else { return nil }
        return (width: state.width, height: state.height)
    }

    /// Diagnostics only (maximize-scenario real-host regression investigation, 2026-08-23)
    /// -- see `RemoteWindow.debugGeometrySuppressionCount`'s own doc comment. `nil` if this
    /// registry has no `RemoteWindow` for `windowId` at all.
    func debugGeometrySuppressionCount(forWindowId windowId: UInt32) -> Int? {
        windows[windowId]?.debugGeometrySuppressionCount
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

    /// Diagnostics only (adr/0010 §4, `Tools/window-smoke`'s popup scenario) -- `windowId`'s
    /// CURRENTLY attached owner windowId, or `nil` if it isn't attached as a child right now
    /// (whether because `ownerWindowId` is 0, its owner isn't a known window, or it's simply
    /// not tracked at all). Not used by the real rendering path, which never needs to query
    /// this externally.
    func attachedOwner(forWindowId windowId: UInt32) -> UInt32? {
        attachedChildOwner[windowId]
    }

    /// Diagnostics only (adr/0010 §2/§4, `Tools/window-smoke`'s `[shape]` log line) --
    /// `windowId`'s most recently merged visibility-rect wire bookkeeping (count + truncated
    /// flag, `PendingWindowState`'s own fields) alongside the rect count actually applied to
    /// `RemoteWindow.contentLayer.mask` last time `applyMask`/`applyMaskNow` ran -- exposing
    /// both together (rather than just the wire side) lets a harness catch the two silently
    /// diverging (e.g. a fail-open rule firing and clearing the applied mask while the wire
    /// bookkeeping still shows rects). `nil` if this windowId has no tracked geometry at all.
    func shapeDiagnostics(forWindowId windowId: UInt32) -> (wireRectCount: Int, truncated: Bool, appliedRectCount: Int)? {
        guard let state = geometry[windowId] else { return nil }
        return (
            wireRectCount: state.visibilityRects.count, truncated: state.visibilityRectsTruncated,
            appliedRectCount: windows[windowId]?.appliedMaskRectCount ?? 0
        )
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
    ///
    /// M1/W1 (ADR-0015 §5, U8): this is also **the reconnect re-take point** for a reused
    /// registry — the one moment ADR §5 means by "重连就是新会话、新快照". It belongs here rather
    /// than on a generation transition for the reason this method's own existence documents: a
    /// post-`shutdownAndWait` drain delivers nothing, so the generation change is never observed
    /// on this side at all. Called after `shutdownAndWait()` and before the next `start()`
    /// (`Tools/window-smoke/main.swift:1660` → `:1667` → `:1719`), which is exactly the
    /// pre-connect moment `init` occupies for a per-connection registry.
    func prepareForReconnect() {
        closeAllWindows()
        currentGeneration = nil
        refreshSessionTopology(reason: "reconnect")
    }

    private func closeAllWindows() {
        for (_, window) in windows {
            window.close(via: session)
        }
        windows.removeAll()
        geometry.removeAll()
        surfaceToWindow.removeAll()
        surfaceMappedSize.removeAll()
        // adr/0010 §4: unlike `handleWindowDelete` (one window closing while its parent/
        // children stay live, where the ADR's own "removeChildWindow before close" ordering
        // matters), every window here -- parents and attached children alike -- is being
        // torn down in the same sweep; AppKit itself removes a closing child from its
        // parent's `childWindows` list as a documented side effect of `-close`, so there is
        // no dangling parent-child reference left to explicitly sever here. Just drop the
        // bookkeeping.
        attachedChildOwner.removeAll()
        warnedUnresolvedOwner.removeAll()
        // Phase 2 W6 (docs/plans/phase2.md §4 W6 acceptance: "delete 清零"): every live
        // NSStatusItem this session created is session-scoped, same as every RemoteWindow
        // above -- torn down unconditionally on all three of this method's callers (the
        // generation-rollover branch in `handle(_:)`, the `.disconnected` case, and the
        // explicit prepareForReconnect() driver). createsSeen/updatesSeen/deletesSeen are
        // NOT reset by this (see TrayStatusController.statusItems' own doc comment).
        trayStatusController.removeAll()
        desktopState = ServerDesktopState()
        // adr/0012 §2 reconnect discipline: reset to `.unmonitored` -- the gate can only
        // reopen on a subsequent *real* MonitoredDesktop order, never by any timeout.
        // Covers all three of this method's callers: the generation-rollover branch in
        // `handle(_:)`, the `.disconnected` case, and the explicit `prepareForReconnect()`
        // driver, since every one routes through here. Effects intentionally discarded, matching `heldModifierKeys`'
        // own reset right below -- the connection this buffered/keyed state described is
        // already gone, so there is nothing left to send any of it to.
        _ = focusAuthority.generationReset()
        // No RELEASE flush here (unlike the .focusLost case) -- the connection this
        // tracked state described is already gone, so there is nothing left to send it to.
        heldModifierKeys = []
        // adr/0011 §3: same "no flush, connection is gone" reasoning extends to the new
        // ledger and the Cmd remap state machine.
        wireHeldModifiers = []
        commandKeyMapper.reset()
        // adr/0011 §2: the degradation gate is per-CONNECTION -- the next connection
        // re-reads `CRSession.unicodeInputSupported` (itself reset to NO at the top of
        // every `-start`) and, if that one is degraded too, is entitled to its own single
        // warning. Only the cached capability and the warn-once budget are cleared here;
        // `warningsEmitted`/`droppedCommits` are cumulative for this registry's lifetime,
        // exactly like the zOrder counters above (see `unicodeDegradationDiagnostics()`).
        unicodeInputGate.reset()
        lastMoveSentAt.removeAll()
        pendingTrailingMove.removeAll()
    }
}
