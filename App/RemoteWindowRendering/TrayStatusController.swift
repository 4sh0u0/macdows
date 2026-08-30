import AppKit
import MacdowsCore
import os

/// Owns every `NSStatusItem` this session's RAIL notification-area (systray) icons map to
/// (Phase 2 W6, docs/plans/phase2.md §2 W6 / §4 W6 acceptance: "NSStatusItem 数量 ==
/// create−delete, 图标非空位图, delete 清零"). `@MainActor`, matching `RemoteWindowRegistry`
/// (the sole owner of one `TrayStatusController` instance, session-scoped) — `NSStatusBar`/
/// `NSStatusItem` are AppKit main-thread-only APIs.
///
/// **Degradation form implemented, per docs/plans/phase2.md §2 W6's own timebox fallback**:
/// icon display + left-click forwarding only. No balloon notifications, no right-click
/// context menus. This is the plan's OWN designated v1 shape, not a shortcut taken here.
///
/// **Gap 1 (no icon pixels, no tooltip) is CLOSED by adr/0013.** It used to read: both
/// `crb_notify_icon_create` and `crb_notify_icon_update` discarded the entire
/// `NOTIFY_ICON_STATE_ORDER` (`(void)notifyIconState;`) and `crdpq_notify_icon_t` carried
/// nothing but `windowId`/`notifyIconId`, so every `NSStatusItem` showed the same placeholder
/// template image and its tooltip -- when set at all -- was the icon's OWNER WINDOW's title
/// rather than a notify-icon-specific one. adr/0013 resolved the "variable-size pixel payload"
/// question the old note called ADR-worthy: pixels ride a bounded side store
/// (`crdpq_icon_store_t`, 16 slots x 48x48 RGBA) and the control event carries only a slot
/// reference, so the control lane's own growth ceiling never inflates by a bitmap's worth
/// (adr/0013 §1); `crdpq_icon_convert` does the DIB->premultiplied-RGBA decode on T_rdp
/// (adr/0013 §2); and the tooltip appends to the POD via the `crdpq_text_t` truncation
/// precedent that same note pointed at. This type now renders `event.iconRGBA` as a real
/// `NSImage` and prefers `event.toolTip` over the owner-window-title fallback. What remains
/// intentionally degraded: an icon this client refuses (oversize/unsupported bpp/store
/// exhaustion/the deferred `CACHED_ICON` variant, adr/0013 §2) still falls back to the same
/// placeholder, counted via `Diagnostics.iconSkippedCount` -- fail-open, not silent.
///
/// **Gap 2 (no outbound wire lane for tray clicks) is CLOSED by adr/0014.** It used to read:
/// FreeRDP defines `RAIL_NOTIFY_EVENT_ORDER { windowId, notifyIconId, message }`
/// (`ThirdParty/FreeRDP/include/freerdp/rail.h:433-438`) sent via
/// `RailClientContext.ClientNotifyEvent` (`freerdp/client/rail.h:58-59`), but `CRSession.h`
/// exposed no `-sendNotifyEvent:...` method for it, so a click could only be LOGGED. adr/0014
/// added that method (and `CRDPQ_CMD_NOTIFY_EVENT` behind it, appended to the same outbound
/// queue every other outbound command already rides — no new mechanism); `handleLeftClick(
/// tag:)` below now hands the unpacked key to `onLeftClick`, which `RemoteWindowRegistry`
/// wires to two `CRSession.sendNotifyEvent` calls: `WM_LBUTTONDOWN` then `WM_LBUTTONUP`
/// (`MacdowsCore.TrayNotifyEvent.leftClickSequence`). What remains intentionally out of
/// scope, per adr/0014 §1: `NIN_SELECT` and the rest of the `NIN_*` family (their MS-RDPERP
/// version precondition is unverifiable from here — see `TrayNotifyEvent`'s own doc comment),
/// right-click/`WM_CONTEXTMENU`, double-click, and balloons. The W6 degradation form is
/// otherwise unchanged.
@MainActor
final class TrayStatusController {
    private var model = TrayModel()
    /// One `NSStatusItem` per live notify icon, keyed the same way `model.icons` is (adr/0008-
    /// aligned `(windowId, notifyIconId)` composite identity — see `TrayModel`'s own doc
    /// comment for why `notifyIconId` alone isn't a safe key). Reset (along with `model`) by
    /// `removeAll()`; EVERY counter below (`createsSeen`/`updatesSeen`/`deletesSeen`, the
    /// adr/0013 icon counters, and adr/0014's own click/PDU/version counters) is NOT reset —
    /// same "cumulative for this registry's lifetime, not reset on reconnect" precedent
    /// `RemoteWindowRegistry`'s own `zOrderArraysReceivedCount`/`zOrderAppliesPerformedCount`/
    /// `zOrderSkippedUnknownTotal` already establish (see those ivars' own doc comment) — a
    /// post-shutdown `Tools/window-smoke` diagnostics read (`finish()`, after
    /// `session.shutdownAndWait()` has already torn down every live item via `removeAll()`)
    /// must still see the real per-session totals, not zeros.
    private var statusItems: [NotifyIconState: NSStatusItem] = [:]

    /// The subset of `statusItems`'s keys whose button currently shows a REAL remote bitmap
    /// rather than `placeholderImage` (adr/0013 §3). Kept as a separate set rather than
    /// re-derived from `NSStatusItem.button?.image` at diagnostics time, because "is this the
    /// placeholder" is not a question an `NSImage` answers reliably (`.isTemplate` is a
    /// property of what we set, not an identity), and the acceptance criterion this feeds
    /// (`realIconCount >= 1`) needs to be exact. Kept in sync with `statusItems` at every
    /// mutation point, and cleared alongside it by `removeAll()`.
    private var realIconKeys: Set<NotifyIconState> = []

    private(set) var createsSeen = 0
    private(set) var updatesSeen = 0
    private(set) var deletesSeen = 0
    /// Cumulative count of NotifyIconCreate/Update orders that carried an icon this client
    /// refused (adr/0013 §2's `iconSkipped`: oversize, unsupported bpp, self-inconsistent
    /// bitmap fields, side-store slot exhaustion, or the deferred `CACHED_ICON` variant).
    /// NOT reset by `removeAll()`, same "cumulative for this controller's lifetime"
    /// discipline as `createsSeen`/`updatesSeen`/`deletesSeen` above and for the same reason
    /// (a post-shutdown diagnostics read must still see real per-session totals).
    private(set) var iconSkippedCount = 0
    /// The subset of `iconSkippedCount` whose cause was the deferred CACHED_ICON variant
    /// (adr/0013 §2) — split out (R1 finding 3) because the first live run showed real
    /// Win11 sessions re-send their own tray icons as cache references routinely, so an
    /// acceptance gate that lumps this deferred-protocol evidence in with genuine
    /// converter/store failures fails correct sessions. Cumulative, same discipline as
    /// `iconSkippedCount` above.
    private(set) var cachedIconCount = 0
    /// R1 finding 2: the maximum `realIconKeys.count` ever reached -- latched exactly, at
    /// the moment a real bitmap is installed in `upsertStatusItem`, NOT timer-sampled (a
    /// create+delete pair landing inside one drain batch is invisible to any poll, and the
    /// adr/0013 §4 acceptance gate must not fail a pipeline that worked). Cumulative for
    /// this controller's lifetime, NOT reset by `removeAll()`, same post-shutdown-read
    /// reasoning as `createsSeen` above.
    private(set) var realIconMaxObserved = 0
    /// Latest observed value of `CRSession.iconStoreOverflowCount` — the C side-store's own
    /// counter for icons refused because all `CRDPQ_ICON_SLOTS` (16) slots were held by other
    /// keys (adr/0013 §1). Pushed in by `RemoteWindowRegistry` (which owns the `CRSession`
    /// reference) on every notify-icon order rather than pulled from here, keeping this type's
    /// dependency surface at "AppKit + values handed to it", exactly as before.
    private(set) var storeOverflowCount = 0
    /// adr/0014 §1: left clicks this controller actually handed to `onLeftClick` -- one per
    /// CLICK, not per PDU (see `notifyEventsSent`). Cumulative, NOT reset by `removeAll()`,
    /// same post-shutdown-read reasoning as `createsSeen` above.
    private(set) var clicksForwarded = 0
    /// adr/0014 §4: left clicks dropped because the icon's `NSStatusItem` was already gone by
    /// the time the click handler ran. Expected to stay 0 in steady state -- AppKit removes a
    /// status item's button along with the item, so a click arriving for a key this
    /// controller no longer tracks means the two got out of sync, which is a BUG SIGNAL, not
    /// a routine race. Deliberately logged at `.warning` EVERY time rather than once
    /// (unlike the log-once budgets elsewhere in this file): if this ever fires, the
    /// frequency and the keys involved are the diagnosis. Cumulative, same discipline as
    /// every counter above.
    private(set) var clicksDroppedIconGone = 0
    /// adr/0014 §1/§5: individual ClientNotifyEvent PDUs `RemoteWindowRegistry` reported
    /// having posted, pushed in per PDU (this type never touches `CRSession` itself -- same
    /// "values handed to it" split `storeOverflowCount` above already establishes).
    ///
    /// v1 invariant: `notifyEventsSent == 2 * clicksForwarded`, since one click is exactly
    /// the `WM_LBUTTONDOWN`/`WM_LBUTTONUP` pair. Carrying BOTH counters is a deliberate,
    /// documented exception to adr/0013 §6.9's "diagnostics don't carry derivable values"
    /// rule: the derivation IS the assertion. The day the sequence changes (a `NIN_*`
    /// message, a double-click, a right-click lane), that identity breaks in an acceptance
    /// gate instead of silently redefining what a "click" costs on the wire.
    private(set) var notifyEventsSent = 0
    /// adr/0014 §7: every distinct `NOTIFY_ICON_STATE_ORDER.version` this controller has been
    /// told about, up to `maxObservedVersions`. Observation only -- nothing branches on it; it
    /// exists so the MS-RDPERP precondition that ruled `NIN_SELECT` out of v1 stops being
    /// invisible. Cumulative like every counter above (a post-shutdown diagnostics read must
    /// still see what the session actually sent), which also makes the
    /// log-once-per-distinct-version budget in `noteNotifyIconVersion` exactly once per value
    /// for this controller's lifetime.
    private(set) var observedNotifyIconVersions: Set<UInt32> = []
    /// adr/0014 §9.1: hard cap on the set above. This is a `UInt32` straight off the wire and
    /// the server chooses it -- an unbounded `Set` keyed on server-controlled data grows once
    /// per distinct value a peer feels like sending, which is a memory-growth surface, not a
    /// diagnostic. 16 is far past any plausible number of real notify-icon versions (the
    /// protocol's own are single digits) while staying small enough that reaching it is
    /// itself the signal: a session at the cap is sending values this observation was never
    /// designed to characterize, and its diagnostics line says `(capped)` so a reader knows
    /// the set is a prefix of what arrived rather than the whole of it. Values past the cap
    /// are neither stored nor logged -- the log budget is the set membership check, so
    /// dropping the insert drops the log with it, deliberately: an uncapped LOG of
    /// server-chosen values is the same unbounded surface one indirection further out.
    static let maxObservedVersions = 16

    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "TrayStatusController")

    /// Menu-bar icon edge length, in points. 18pt is the conventional square for a
    /// `NSStatusItem.squareLength` item's artwork on a standard-height menu bar — the remote
    /// bitmap arrives at whatever the server sent (16/32/48 square in practice), and is
    /// scaled to this by setting `NSImage.size` rather than by resampling the pixels, so
    /// AppKit picks the filtering and the backing store stays at native resolution for
    /// Retina.
    private static let menuBarIconEdge: CGFloat = 18

    /// SF Symbol placeholder — post-adr/0013 this is the FALLBACK, not the only form: it is
    /// what a status item shows when the order carried no icon at all, or when the icon it
    /// carried was refused (adr/0013 §2's `iconSkipped`). `.isTemplate` so AppKit tints it
    /// correctly against both light and dark menu bars, matching every other system status
    /// item's own rendering convention. `app.badge` (available since SF Symbols 2 / macOS 11)
    /// reads as "an app has something to tell you," a reasonable stand-in for an unknown
    /// remote tray icon. Falls back to a plain empty `NSImage` (never crashes/force-unwraps)
    /// if the symbol name is ever unavailable in some future SDK -- the same fail-open
    /// discipline this codebase already applies everywhere else (adr/0008 §4).
    private static let placeholderImage: NSImage = {
        let image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: "Remote notification area icon")
        image?.isTemplate = true
        return image ?? NSImage()
    }()

    /// The live `NSStatusItem` count -- the LHS of phase2.md §4 W6's own acceptance formula
    /// ("NSStatusItem 数量 == create−delete"). Exposed for `Tools/window-smoke`'s `[tray]`
    /// diagnostics line via `RemoteWindowRegistry.trayDiagnostics()`.
    struct Diagnostics {
        let createsSeen: Int
        let updatesSeen: Int
        let deletesSeen: Int
        let liveCount: Int
        /// adr/0013 §4's real-machine acceptance criterion (`realIconCount >= 1`): live status
        /// items currently showing a real remote bitmap, i.e. `liveCount` MINUS the ones still
        /// on `placeholderImage`. A point-in-time count, not a cumulative one -- unlike the
        /// three `*Seen` counters above, this drops back to 0 when the icons are torn down.
        let realIconCount: Int
        /// Cumulative; see `iconSkippedCount`'s own doc comment.
        let iconSkippedCount: Int
        /// Cumulative; the CACHED_ICON subset of `iconSkippedCount` (R1 finding 3) — an
        /// acceptance gate asserts `iconSkippedCount - cachedIconCount == 0` (no NON-cached
        /// skips) and reports this one as deferred-protocol evidence (adr/0013 §2:
        /// "出现即有计数证据"), never as a failure.
        let cachedIconCount: Int
        /// Cumulative; see `realIconMaxObserved`'s own doc comment (R1 finding 2: the exact,
        /// latched form of the real-bitmap evidence `realIconCount` only shows while alive).
        let realIconMaxObserved: Int
        /// Cumulative; the C side-store's slot-exhaustion counter (adr/0013 §1), as last
        /// pushed in by `RemoteWindowRegistry`.
        let storeOverflowCount: Int
        /// Cumulative; see `clicksForwarded`'s own doc comment (adr/0014 §5).
        let clicksForwarded: Int
        /// Cumulative; see `clicksDroppedIconGone`'s own doc comment -- an acceptance gate
        /// asserts this is 0, because a nonzero value is a status-item bookkeeping bug, not
        /// a tolerated race.
        let clicksDroppedIconGone: Int
        /// Cumulative; see `notifyEventsSent`'s own doc comment, including why this and
        /// `clicksForwarded` are BOTH carried despite `notifyEventsSent == 2 *
        /// clicksForwarded` holding in v1 (adr/0014 §5: the identity is the assertion).
        let notifyEventsSent: Int
        /// adr/0014 §7 observation: the distinct notify-icon versions seen this run, sorted
        /// so a diagnostics line is stable across runs. Empty when no order ever carried the
        /// `WINDOW_ORDER_FIELD_NOTIFY_VERSION` bit -- which is itself the observation. Bounded
        /// by `TrayStatusController.maxObservedVersions` (adr/0014 §9.1); a reader seeing
        /// exactly that many values must treat this as a PREFIX of what arrived, not the whole
        /// set (`Tools/window-smoke` prints `(capped)` for exactly that case).
        let observedNotifyIconVersions: [UInt32]
    }
    func diagnostics() -> Diagnostics {
        Diagnostics(
            createsSeen: createsSeen, updatesSeen: updatesSeen, deletesSeen: deletesSeen,
            liveCount: statusItems.count, realIconCount: realIconKeys.count,
            iconSkippedCount: iconSkippedCount, cachedIconCount: cachedIconCount,
            realIconMaxObserved: realIconMaxObserved,
            storeOverflowCount: storeOverflowCount,
            clicksForwarded: clicksForwarded, clicksDroppedIconGone: clicksDroppedIconGone,
            notifyEventsSent: notifyEventsSent,
            observedNotifyIconVersions: observedNotifyIconVersions.sorted()
        )
    }

    /// adr/0013 §1: latest `CRSession.iconStoreOverflowCount`, pushed in by
    /// `RemoteWindowRegistry` (the CRSession owner) on every notify-icon order. Monotonic on
    /// the C side, so this is a plain assignment rather than an accumulation.
    func noteStoreOverflowCount(_ count: Int) {
        storeOverflowCount = count
    }

    /// adr/0014 §1/§5: one ClientNotifyEvent PDU was posted for a click this controller
    /// forwarded. Pushed in by `RemoteWindowRegistry` (the `CRSession` owner) once per PDU,
    /// same "Registry sends, controller counts" split `noteStoreOverflowCount` above already
    /// establishes -- this type never touches the session. Counting the POST, not a delivery:
    /// MS-RDPERP 3.3.5.2.5.4 acknowledges nothing (see `CRSession.sendNotifyEvent`'s own doc
    /// comment), so "sent" is the strongest fact any counter here could ever hold.
    func noteNotifyEventSent() {
        notifyEventsSent += 1
    }

    /// adr/0014 §7: one `NotifyIconCreate`/`Update` order carried
    /// `WINDOW_ORDER_FIELD_NOTIFY_VERSION`. Latches the value and logs at `.info` exactly once
    /// per distinct version (the set membership check IS the budget -- no separate
    /// warned-once flag), since the interesting event is "a version we hadn't seen", not the
    /// per-order repetition of one the server sends on every update.
    func noteNotifyIconVersion(_ version: UInt32) {
        // adr/0014 §9.1: stop at the cap. Checked BEFORE the insert (never by trimming
        // afterwards), so the set is bounded at every instant rather than on average. Once at
        // the cap this returns for EVERY value, new or already-seen -- which costs nothing,
        // since an already-seen value's only effect would have been the second guard below
        // rejecting it anyway (it was logged the first time).
        guard observedNotifyIconVersions.count < Self.maxObservedVersions else { return }
        guard observedNotifyIconVersions.insert(version).inserted else { return }
        Self.logger.info(
            "notify icon order carried version=\(version, privacy: .public) (adr/0014 §7 observation only -- MS-RDPERP makes the NIN_ message family conditional on this; v1 sends the version-free WM_LBUTTONDOWN/WM_LBUTTONUP pair regardless)"
        )
    }

    /// The wire payload one NotifyIconCreate/Update order carries for rendering purposes
    /// (adr/0013 §3) -- grouped into one struct rather than four more parameters on each of
    /// the two handlers below, since `RemoteWindowRegistry` builds the identical value for
    /// both from the identical `CRDPEvent` fields.
    struct IconPayload {
        /// Premultiplied RGBA8888, top-down, `width * 4` bytes per row. `nil` when the order
        /// carried no icon, when it was refused (`skipped`), or when the side-store slot it
        /// referenced had already been recycled -- all three mean "placeholder" here.
        let rgba: Data?
        let width: Int
        let height: Int
        /// adr/0013 §2's `iconSkipped`: an icon WAS on the wire and this client refused it.
        /// Distinct from `rgba == nil` alone (which also covers "no icon was sent"), and the
        /// only one of the two worth counting as evidence.
        let skipped: Bool
        /// `iconSkipped`'s cause was specifically the deferred CACHED_ICON variant (always
        /// accompanied by `skipped == true`) — see `cachedIconCount`'s doc comment for why
        /// this cause is counted apart (R1 finding 3).
        let cached: Bool
        /// `NOTIFY_ICON_STATE_ORDER.toolTip`, or `nil` when the order didn't carry the
        /// `WINDOW_ORDER_FIELD_NOTIFY_TIP` bit.
        let toolTip: String?

        static let absent = IconPayload(rgba: nil, width: 0, height: 0, skipped: false, cached: false, toolTip: nil)
    }

    /// A `NotifyIconCreate` order. `ownerWindowTitle` is whatever `RemoteWindowRegistry`
    /// already knows for `ownerWindowId` (its own `geometry[windowId]?.title`, or `nil` if
    /// unknown/empty) -- post-adr/0013 it is the FALLBACK tooltip only, used when the order
    /// itself carried no `toolTip` (see `resolvedTooltip`).
    func handleNotifyIconCreate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        createsSeen += 1
        // R1 finding 1: the model stores the WIRE tooltip truth (nil = the order didn't
        // carry the NOTIFY_TIP bit), never the display-resolved value -- the owner-title
        // fallback is applied at NSStatusItem time below, so a later tooltip-less delta
        // can't launder the fallback into "what the server said".
        model.create(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: icon.toolTip))
        upsertStatusItem(
            windowId: windowId, notifyIconId: notifyIconId,
            tooltip: Self.resolvedTooltip(wire: storedTooltip(windowId: windowId, notifyIconId: notifyIconId), ownerWindowTitle: ownerWindowTitle),
            icon: icon
        )
    }

    /// A `NotifyIconUpdate` order -- update-in-place: reuses the existing `NSStatusItem` for
    /// this key if one is already live (the common case), or creates one if this is the first
    /// order this controller has seen for this key at all (`TrayModel.update`'s own tolerance
    /// for an update-before-create ordering, see its doc comment).
    func handleNotifyIconUpdate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        updatesSeen += 1
        // R1 finding 1: `TrayModel.update` delta-merges -- an update without the NOTIFY_TIP
        // bit keeps the key's previously-seen wire tooltip (the exact mirror of the C
        // side-store re-referencing this key's pixel slot for an icon-less update), so an
        // ordinary icon-only state change no longer blanks a real tooltip down to the
        // owner-title fallback. The button then shows the MERGED wire truth, resolved
        // against the fallback only when no order ever carried a tooltip at all.
        model.update(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: icon.toolTip))
        upsertStatusItem(
            windowId: windowId, notifyIconId: notifyIconId,
            tooltip: Self.resolvedTooltip(wire: storedTooltip(windowId: windowId, notifyIconId: notifyIconId), ownerWindowTitle: ownerWindowTitle),
            icon: icon
        )
    }

    /// The delta-merged wire tooltip `TrayModel` currently tracks for this key — the single
    /// source `resolvedTooltip` reads, so display resolution always sees the merge result,
    /// never one order's own (possibly bit-absent) field.
    private func storedTooltip(windowId: UInt32, notifyIconId: UInt32) -> String? {
        model.icons[NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)]?.tooltip
    }

    /// adr/0013 §3's tooltip precedence: the wire's own notify-icon tooltip wins; the owner
    /// window's title is the pre-adr/0013 fallback, kept because a server may legitimately
    /// send a notify icon with no tooltip at all, and a labelled status item is more useful
    /// than an unlabelled one. An empty wire tooltip counts as absent (a zero-length
    /// `NSStatusItem.button.toolTip` and `nil` render identically anyway, so preferring it
    /// over a known window title would be a pure loss).
    private static func resolvedTooltip(wire: String?, ownerWindowTitle: String?) -> String? {
        if let wire, !wire.isEmpty { return wire }
        return ownerWindowTitle
    }

    /// A `NotifyIconDelete` order. Tolerates a key with no live `NSStatusItem` (unknown-delete,
    /// matching `TrayModel.delete`'s own tolerance) -- `deletesSeen` still counts the ORDER
    /// received, matching `TrayModel`'s own "count the wire event, not just the ones that hit
    /// something" reasoning, since the phase2.md §4 W6 acceptance formula needs that count.
    func handleNotifyIconDelete(windowId: UInt32, notifyIconId: UInt32) {
        deletesSeen += 1
        model.delete(windowId: windowId, notifyIconId: notifyIconId)
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        realIconKeys.remove(key)
        if let item = statusItems.removeValue(forKey: key) {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    /// Session-scoped teardown -- called from `RemoteWindowRegistry.closeAllWindows()` (all
    /// three of its callers: the generation-rollover branch in `handle(_:)`, the
    /// `.disconnected` case, and the explicit `prepareForReconnect()` driver), matching how
    /// that method already tears down every
    /// other per-connection resource it owns. Clears the LIVE model/items only -- see
    /// `statusItems`'s own doc comment for why none of this type's counters (including
    /// adr/0014's `clicksForwarded`/`notifyEventsSent`) are reset here.
    func removeAll() {
        for (_, item) in statusItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItems.removeAll()
        realIconKeys.removeAll()
        model = TrayModel()
    }

    private func upsertStatusItem(windowId: UInt32, notifyIconId: UInt32, tooltip: String?, icon: IconPayload) {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        if icon.skipped {
            iconSkippedCount += 1
            if icon.cached { cachedIconCount += 1 }
            Self.logger.info(
                "notify icon windowId=\(windowId, privacy: .public) notifyIconId=\(notifyIconId, privacy: .public) carried an icon this client refused (adr/0013 §2 iconSkipped, cached=\(icon.cached, privacy: .public)) -- showing the placeholder instead"
            )
        }
        let item: NSStatusItem
        if let existing = statusItems[key] {
            item = existing
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItems[key] = item
        }
        guard let button = item.button else {
            Self.logger.warning("NSStatusItem for notifyIconId=\(notifyIconId, privacy: .public) windowId=\(windowId, privacy: .public) has no button -- cannot set image/tooltip/click target")
            return
        }
        // adr/0013 §3: a real remote bitmap when one arrived and could be turned into an
        // image, the placeholder otherwise -- deliberately unconditional in both directions,
        // so what a status item shows is always a function of the order that just arrived and
        // never of accumulated history. An icon-less NotifyIconUpdate (a tooltip-only change,
        // say) still lands in the first branch, because the bridge re-references this key's
        // existing side-store slot for exactly that case rather than sending no pixels; the
        // placeholder branch really does mean "the server has no icon for this, or the one it
        // sent was refused". `realIconKeys` mirrors the branch taken, because
        // `Diagnostics.realIconCount` (adr/0013 §4's acceptance assertion) has to be exact and
        // `NSImage` identity isn't a reliable way to re-derive it afterwards.
        if let image = Self.menuBarImage(from: icon) {
            button.image = image
            realIconKeys.insert(key)
            realIconMaxObserved = max(realIconMaxObserved, realIconKeys.count)
        } else {
            button.image = Self.placeholderImage
            realIconKeys.remove(key)
        }
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Degradation form: no `item.menu` is ever assigned -- an `NSStatusItem` with no menu
        // and a plain button action responds only to the primary (left) click by default, so
        // this alone is what satisfies "left-click forwarding only, no right-click menus"
        // (phase2.md §2 W6's own timebox fallback) without any extra event-type filtering.
        button.tag = Self.packTag(windowId: windowId, notifyIconId: notifyIconId)
    }

    /// adr/0013 §3: `Data` (premultiplied RGBA8888, top-down, tight `width * 4` rows -- the
    /// exact shape `crdpq_icon_convert` writes) -> `CGDataProvider` -> `CGImage` -> `NSImage`,
    /// sized to a menu-bar square. Returns `nil` -- never a blank image -- for any absent or
    /// malformed payload, so the caller's placeholder branch stays the single fallback path.
    ///
    /// Deliberately NOT `.isTemplate`: a template image is flattened to a tint mask, which
    /// would discard the remote icon's colors entirely and make every tray icon look identical
    /// again (the exact placeholder problem adr/0013 exists to fix). The trade-off is that a
    /// remote icon does not auto-tint for menu-bar appearance changes, which is the same
    /// trade-off any colored third-party status item on macOS already makes.
    ///
    /// `NSImage.size` is set in POINTS while the `CGImage` keeps its native pixel dimensions,
    /// so a 32x32 remote bitmap on a Retina display renders at native resolution inside an
    /// 18pt square rather than being resampled down first.
    private static func menuBarImage(from icon: IconPayload) -> NSImage? {
        guard let rgba = icon.rgba, icon.width > 0, icon.height > 0 else { return nil }
        let bytesPerRow = icon.width * 4
        guard rgba.count >= bytesPerRow * icon.height else {
            logger.warning(
                "notify icon bitmap is \(rgba.count, privacy: .public) bytes, short of the \(bytesPerRow * icon.height, privacy: .public) its \(icon.width, privacy: .public)x\(icon.height, privacy: .public) dimensions require -- ignoring (placeholder shown)"
            )
            return nil
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: icon.width,
            height: icon.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            // Premultiplied, alpha last, byte order matching the R,G,B,A byte sequence
            // `crdpq_icon_convert` writes (`.byteOrder32Big` is what makes CoreGraphics read
            // those four bytes in address order rather than as a little-endian word).
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            logger.warning("CGImage construction failed for a \(icon.width, privacy: .public)x\(icon.height, privacy: .public) notify icon -- placeholder shown")
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: menuBarIconEdge, height: menuBarIconEdge))
        image.isTemplate = false
        return image
    }

    /// Packs `(windowId, notifyIconId)` -- each a wire `UInt32` -- into one 64-bit `Int` tag,
    /// since `NSButton.tag` is a single `Int` and this project already targets a 64-bit-only
    /// platform (see `RemoteWindowRegistry`'s own `RailEventKind` doc comment on `Int32`/
    /// `UInt32` field widths for the same "this codebase's one and only target" reasoning).
    /// `windowId` occupies the high 32 bits, `notifyIconId` the low 32 -- an arbitrary but
    /// internally consistent choice, `unpackTag` is this function's exact inverse.
    ///
    /// Internal (not `private`) since adr/0014: `RemoteWindowRegistry.debugSimulateTrayClick`
    /// builds its tag with THIS function so the offline harness path and the real
    /// `NSStatusBarButton.tag` path can never encode the key differently -- a second,
    /// hand-rolled packing in the harness would test its own arithmetic instead of this one's.
    static func packTag(windowId: UInt32, notifyIconId: UInt32) -> Int {
        Int(bitPattern: UInt(UInt64(windowId) << 32 | UInt64(notifyIconId)))
    }

    private static func unpackTag(_ tag: Int) -> (windowId: UInt32, notifyIconId: UInt32) {
        let raw = UInt64(UInt(bitPattern: tag))
        return (UInt32(truncatingIfNeeded: raw >> 32), UInt32(truncatingIfNeeded: raw))
    }

    /// Called by `RemoteWindowRegistry` (which owns the `CRSession`) for each forwarded left
    /// click, with the clicked icon's own `(windowId, notifyIconId)` wire identity. `nil` (the
    /// default) is a safe no-op -- nothing here requires it ever being set, matching
    /// `CRSession.onEventsAvailable`'s own precedent.
    var onLeftClick: ((_ windowId: UInt32, _ notifyIconId: UInt32) -> Void)?

    /// Left-click handler (degradation form: no right-click menu is ever installed, see
    /// `upsertStatusItem`'s own comment on why that alone excludes right-click). AppKit entry
    /// point only -- everything that isn't "get the key out of the sender" lives in
    /// `handleLeftClick(tag:)`, so the offline harness path can exercise the identical logic
    /// (`RemoteWindowRegistry.debugSimulateTrayClick`) with AppKit event delivery as the ONLY
    /// missing piece.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        handleLeftClick(tag: sender.tag)
    }

    /// adr/0014 §1: unpacks the button tag, re-checks that the icon is still live, and hands
    /// the key to `onLeftClick`. The liveness re-check is not ceremony: a click is dispatched
    /// by AppKit, so a `NotifyIconDelete` drained between the press and this call would
    /// otherwise send a notify event addressed at an icon the server has already destroyed.
    ///
    /// **This path deliberately does NOT touch `FocusAuthority`** (adr/0014 §3): no
    /// `activateWindow`, no `focusAuthority.localActivate`, no keyboard-lane interaction of
    /// any kind. A notify event is SELF-ADDRESSED -- the server routes it by the PDU's own
    /// `windowId`/`notifyIconId` pair, so no window has to be focused for it to land. Adding
    /// an activation here would open a focus-convergence window (adr/0012 §2) against an
    /// icon's owner, which for a tray-only app is typically a message-only window that never
    /// becomes the server's active window at all -- gating the keyboard lane for the full
    /// 5-10s deadline every time the user clicks a tray icon, in exchange for nothing this
    /// PDU needs.
    func handleLeftClick(tag: Int) {
        let (windowId, notifyIconId) = Self.unpackTag(tag)
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        guard statusItems[key] != nil else {
            clicksDroppedIconGone += 1
            // Every time, not once (see `clicksDroppedIconGone`'s own doc comment): this is
            // a bug signal, and its rate and its keys are the diagnosis.
            Self.logger.warning(
                "tray icon left-clicked notifyIconId=\(notifyIconId, privacy: .public) ownerWindowId=\(windowId, privacy: .public) -- but no live NSStatusItem is tracked for that key; dropping the click rather than addressing a ClientNotifyEvent at a destroyed icon (droppedIconGone=\(self.clicksDroppedIconGone, privacy: .public))"
            )
            return
        }
        clicksForwarded += 1
        Self.logger.info(
            "tray icon left-clicked notifyIconId=\(notifyIconId, privacy: .public) ownerWindowId=\(windowId, privacy: .public) -- forwarding as a ClientNotifyEvent WM_LBUTTONDOWN/WM_LBUTTONUP pair (adr/0014 §1; no focus/activation is involved, §3)"
        )
        onLeftClick?(windowId, notifyIconId)
    }
}
