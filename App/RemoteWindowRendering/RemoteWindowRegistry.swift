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
    /// `removeAll()`, same as every other per-connection resource this registry owns. See
    /// `TrayStatusController`'s own doc comment for the two real wire-contract gaps this
    /// round found (no icon pixel/title data, no outbound click lane) and why neither is
    /// worked around here.
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
        self.macKeyboardType = Self.detectKeyboardType()
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
            trayStatusController.handleNotifyIconCreate(
                windowId: event.windowId, notifyIconId: event.notifyIconId,
                ownerWindowTitle: ownerWindowTitle(for: event.windowId)
            )
        case .notifyIconUpdate:
            trayStatusController.handleNotifyIconUpdate(
                windowId: event.windowId, notifyIconId: event.notifyIconId,
                ownerWindowTitle: ownerWindowTitle(for: event.windowId)
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

    /// Diagnostics only (Tools/window-smoke's `[tray]` summary line, phase2.md §4 W6
    /// acceptance) -- thin passthrough to `trayStatusController.diagnostics()`, same
    /// "Registry exposes, controller/state owns" split `zOrderDiagnostics()` above already
    /// establishes for its own counters.
    func trayDiagnostics() -> TrayStatusController.Diagnostics {
        trayStatusController.diagnostics()
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

        let contentRect = macContentRect(for: state, windowId: windowId)
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
                existing.applyMask(computeMaskResult(for: state, windowId: windowId, contentSize: contentRect.size))
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
            window.applyChrome(chrome)
            windows[windowId] = window
            if !state.isMinimized {
                window.applyMask(computeMaskResult(for: state, windowId: windowId, contentSize: contentRect.size))
            }
            updateParentChild(windowId: windowId, ownerWindowId: state.ownerWindowId)
            window.setVisible(state.isVisible)
        }
    }

    /// adr/0010 §2: gathers this window's shape inputs (visibilityRects/anchor/correction
    /// already tracked by `geometry`/`sizeCorrection`) and calls the pure
    /// `MacdowsCore.WindowShape.computeMask` transform -- same "translate in MacdowsCore,
    /// apply in the App target" split `isMappableWindow`/`chrome` already establish.
    private func computeMaskResult(for state: PendingWindowState, windowId: UInt32, contentSize: NSSize) -> WindowShape.MaskResult {
        let correction = sizeCorrection(for: state, windowId: windowId)
        return WindowShape.computeMask(
            visibilityRects: state.visibilityRects,
            wireCount: state.numVisibilityRects,
            truncated: state.visibilityRectsTruncated,
            windowOffset: (x: Double(state.offsetX), y: Double(state.offsetY)),
            visibleOffset: state.hasSeenVisibleOffset ? (x: Double(state.visibleOffsetX), y: Double(state.visibleOffsetY)) : nil,
            correction: correction,
            topInset: 0,
            contentSize: WindowShape.ContentSize(width: Double(contentSize.width), height: Double(contentSize.height)),
            isMaximized: state.isMaximized
        )
    }

    /// adr/0010 §4: resolves/updates `windowId`'s real `NSWindow.addChildWindow` attachment
    /// against its most recently merged `ownerWindowId`. Idempotent against a redundant call
    /// with the same, already-attached owner. Re-evaluated on every order (not just
    /// creation) since `ownerWindowId` is itself a delta-merged sub-field that could in
    /// principle change -- cheap either way (a dictionary lookup plus, at most, one
    /// AppKit call).
    private func updateParentChild(windowId: UInt32, ownerWindowId: UInt32) {
        let currentOwnerId = attachedChildOwner[windowId]

        if ownerWindowId != 0, let ownerWindow = windows[ownerWindowId] {
            guard currentOwnerId != ownerWindowId else { return } // already correctly attached
            guard let childWindow = windows[windowId] else { return }
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
    /// macRect(from:primaryMonitorHeight:)`) was always correct -- only the RESULT's meaning
    /// was mislabeled. `RemoteWindow.updateFrame(contentRect:)` is what actually derives the
    /// real outer frame from this value, via `NSWindow.frameRect(forContentRect:)`.
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
    private func macContentRect(for state: PendingWindowState, windowId: UInt32) -> NSRect {
        let correction = sizeCorrection(for: state, windowId: windowId)
        let railRect = WindowsRect(x: Double(state.offsetX), y: Double(state.offsetY), width: Double(state.width), height: Double(state.height))
        let windowsRect = WindowGeometry.displayRect(from: railRect, correction: correction)
        let macRect = WindowGeometry.macRect(from: windowsRect, primaryMonitorHeight: Self.primaryMonitorHeight)
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
            // adr/0011 §1/§2: an IME commit -- same gate as every other keyboard-lane
            // event (adr/0012 §2 unchanged), atomic (whole string, one buffer slot).
            execute(focusAuthority.enqueueKeyboardEvent(.unicodeText(text), at: CFAbsoluteTimeGetCurrent()))
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
        lastMoveSentAt[windowId] = CFAbsoluteTimeGetCurrent()
        let point = remotePoint(from: screenPoint)
        session.sendMouseMoveTo(x: Int32(point.x), y: Int32(point.y))
    }

    /// Phase 2 W3 (docs/plans/phase2.md §2 W3): the one and only place a settled local
    /// window CONTENT rect becomes a `CRSession.sendWindowMove` call -- the exact inverse of
    /// `macContentRect(for:)` above, through the same `MacdowsCore.WindowGeometry` conversion
    /// every other geometry boundary crossing in this file already uses
    /// (`WindowGeometry.windowsRect(from:primaryMonitorHeight:)` is literally
    /// `macRect(from:primaryMonitorHeight:)`'s documented inverse). `contentRect` arrives
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
        guard Self.primaryMonitorHeight > 0 else { return } // L1: see macContentRect(for:)'s own guard
        let macRect = MacRect(x: contentRect.origin.x, y: contentRect.origin.y, width: contentRect.size.width, height: contentRect.size.height)
        let displayedWindowsRect = WindowGeometry.windowsRect(from: macRect, primaryMonitorHeight: Self.primaryMonitorHeight)
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
    private static let measuredClientWindowMoveLeftBorder: Double = 7

    /// The one and only place a mac-screen point becomes a `WindowsPoint`, exactly
    /// mirroring `macContentRect(for:)` above for the reverse (Windows-rect -> mac-rect)
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
        // above -- torn down unconditionally on both this method's callers (generation
        // rollover, explicit prepareForReconnect()). createsSeen/updatesSeen/deletesSeen are
        // NOT reset by this (see TrayStatusController.statusItems' own doc comment).
        trayStatusController.removeAll()
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
        // adr/0011 §3: same "no flush, connection is gone" reasoning extends to the new
        // ledger and the Cmd remap state machine.
        wireHeldModifiers = []
        commandKeyMapper.reset()
        lastMoveSentAt.removeAll()
        pendingTrailingMove.removeAll()
    }
}
