import AppKit
import MacdowsCore
import os

/// Mirrors this session's RAIL notification-area (systray) icons as ordered MENU ENTRIES for the
/// "Remote tray" section of the Macdows status item's menu (adr/0023, which retires Phase 2 W6's
/// one-`NSStatusItem`-per-icon form, docs/plans/phase2.md §2 W6 / §4 W6). `@MainActor`, matching
/// `RemoteWindowRegistry` (the sole owner of one `TrayStatusController` instance,
/// session-scoped) -- the `NSImage`s it builds and the click it forwards are main-thread work.
///
/// **What this type owns, and what it does not (adr/0023 D-6 P-a).** It owns the entry table --
/// key, sanitised title, full tooltip text, image, placeholder flag, in first-seen order -- and
/// publishes every change to it through `onMenuChange` (insert / update / remove at a position,
/// or "everything removed"). It never builds, holds or edits an `NSMenu` or an `NSMenuItem`, and it
/// never touches the system status bar (adr/0023 D-5 R1): the status item controller in `App/Macdows`
/// is the one writer of the menu's structure and mirrors these entries into it, including while
/// the menu is open (D-3 M-a). Because the table lives here, `Diagnostics.liveCount` (the W6-1
/// count) is the same number whether or not any menu mirrors it -- `Tools/window-smoke` has no
/// status item and reads it all the same.
///
/// **Shape kept from W6 (adr/0023 D-5 K-a: the name, the registry property, `removeAll()`,
/// `handleLeftClick(tag:)`, the `note*` pushes, `diagnostics()` and `maxObservedVersions` are
/// unchanged).** Icon display + left-click forwarding only. No balloon notifications (adr/0023
/// D-7 B-a), no right-click, double-click or middle-click (D-2 C1, adr/0014 §1).
///
/// **Gap 1 (no icon pixels, no tooltip) is CLOSED by adr/0013.** Pixels ride a bounded side store
/// (`crdpq_icon_store_t`, 16 slots x 48x48 RGBA) and the control event carries only a slot
/// reference (adr/0013 §1); `crdpq_icon_convert` does the DIB->premultiplied-RGBA decode on T_rdp
/// (adr/0013 §2); the tooltip appends to the POD via the `crdpq_text_t` truncation precedent. This
/// type renders `event.iconRGBA` as a real `NSImage` and prefers `event.toolTip` over the
/// owner-window-title fallback. What remains intentionally degraded: an icon this client refuses
/// (oversize/unsupported bpp/store exhaustion/the deferred `CACHED_ICON` variant, adr/0013 §2)
/// falls back to the placeholder, counted via `Diagnostics.iconSkippedCount` -- fail-open, not
/// silent.
///
/// **Gap 2 (no outbound wire lane for tray clicks) is CLOSED by adr/0014.** `handleLeftClick(tag:)`
/// hands the unpacked key to `onLeftClick`, which `RemoteWindowRegistry` wires to two
/// `CRSession.sendNotifyEvent` calls: `WM_LBUTTONDOWN` then `WM_LBUTTONUP`
/// (`MacdowsCore.TrayNotifyEvent.leftClickSequence`). Choosing an entry's menu item is that one
/// left click (adr/0023 D-2 C1), forwarded synchronously from the item's action (T-a). Out of
/// scope, per adr/0014 §1: `NIN_SELECT` and the rest of the `NIN_*` family, right-click /
/// `WM_CONTEXTMENU`, double-click, and balloons.
@MainActor
final class TrayStatusController {
    private var model = TrayModel()
    /// One entry per live notify icon, in first-seen order (the wire carries no tray ordering,
    /// adr/0023 D-1), keyed the same way `model.icons` is (adr/0008-aligned `(windowId,
    /// notifyIconId)` composite identity -- see `TrayModel`'s own doc comment for why
    /// `notifyIconId` alone isn't a safe key). Reset (along with `model`) by `removeAll()`;
    /// EVERY counter below (`createsSeen`/`updatesSeen`/`deletesSeen`, the adr/0013 icon
    /// counters, and adr/0014's own click/PDU/version counters) is NOT reset -- same "cumulative
    /// for this registry's lifetime, not reset on reconnect" precedent `RemoteWindowRegistry`'s
    /// own `zOrderArraysReceivedCount`/`zOrderAppliesPerformedCount`/`zOrderSkippedUnknownTotal`
    /// already establish (see those ivars' own doc comment) -- a post-shutdown
    /// `Tools/window-smoke` diagnostics read (`finish()`, after `session.shutdownAndWait()` has
    /// already torn down every live entry via `removeAll()`) must still see the real per-session
    /// totals, not zeros.
    private(set) var entries: [MenuEntry] = []

    /// The subset of `entries`' keys whose entry currently shows a REAL remote bitmap rather than
    /// `placeholderImage` (adr/0013 §3). Kept as a separate set rather than re-derived from the
    /// entries' images at diagnostics time, because the acceptance criterion this feeds
    /// (`realIconCount >= 1`) needs to be exact. Kept in sync with `entries` at every mutation
    /// point, and cleared alongside it by `removeAll()`.
    private var realIconKeys: Set<NotifyIconState> = []

    /// adr/0023 D-1 N-a: the number a key's fallback title ("Tray app %d") carries, handed out
    /// in first-seen order and kept for the key while this connection lasts, so an icon that is
    /// deleted and re-created keeps its number. Cleared by `removeAll()`: a new connection numbers
    /// from 1 again.
    private var fallbackOrdinals: [NotifyIconState: Int] = [:]

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
    /// the moment a real bitmap is installed in `upsertEntry`, NOT timer-sampled (a
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
    /// W3 lane G (ADR-0018 §2 / U-6 first step): latest observed value of
    /// `CRSession.iconStoreOversizeRefusalCount` -- the side-store's count of bitmaps refused
    /// because an axis exceeded `CRDPQ_ICON_MAX_DIM`, separated from the other `iconSkipped`
    /// causes. Pushed in by `RemoteWindowRegistry` the same way as `storeOverflowCount`.
    private(set) var storeOversizeRefusalCount = 0
    /// adr/0014 §1: left clicks this controller actually handed to `onLeftClick` -- one per
    /// CLICK, not per PDU (see `notifyEventsSent`). Cumulative, NOT reset by `removeAll()`,
    /// same post-shutdown-read reasoning as `createsSeen` above.
    private(set) var clicksForwarded = 0
    /// adr/0014 §4: left clicks dropped because the icon's entry was already gone by the time the
    /// click handler ran. Expected to stay 0 in steady state -- the menu side removes an entry's
    /// item in the same main-actor turn the delete arrives in, including while the menu is open
    /// (adr/0023 D-3 M-a), so a click arriving for a key this controller no longer tracks means
    /// the two got out of sync, which is a BUG SIGNAL, not a routine race (adr/0023 U-3 records
    /// the one ordering that could make it one: a drain between the menu's selection and the
    /// action). Deliberately logged at `.warning` EVERY time rather than once
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

    /// Menu-item icon edge length, in points (adr/0023 D-1 I-a: 16 pt, down from the 18 pt square
    /// a W6 `NSStatusItem` used -- a deliberate change, UI-1 spec §6.3). The remote bitmap arrives
    /// at whatever the server sent (16/32/48 square in practice) and is scaled to this by setting
    /// `NSImage.size` rather than by resampling the pixels, so AppKit picks the filtering and the
    /// backing store stays at native resolution for Retina.
    static let menuItemIconEdge: CGFloat = 16

    /// adr/0023 D-1 N-a: a menu title is cut to this many grapheme clusters, plus an ellipsis.
    static let menuTitleLimit = 48

    /// SF Symbol placeholder — post-adr/0013 this is the FALLBACK, not the only form: it is
    /// what an entry shows when the order carried no icon at all, or when the icon it carried
    /// was refused (adr/0013 §2's `iconSkipped`). `.isTemplate` so AppKit tints it correctly
    /// against both light and dark menus (adr/0023 D-1 I-a keeps the template placeholder). `app.badge` (available since SF Symbols 2 / macOS 11)
    /// reads as "an app has something to tell you," a reasonable stand-in for an unknown
    /// remote tray icon. Falls back to a plain empty `NSImage` (never crashes/force-unwraps)
    /// if the symbol name is ever unavailable in some future SDK -- the same fail-open
    /// discipline this codebase already applies everywhere else (adr/0008 §4).
    static let placeholderImage: NSImage = {
        let image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: "Remote notification area icon")
        image?.isTemplate = true
        return image ?? NSImage()
    }()

    /// `liveCount` is the live ENTRY count -- the LHS of the W6-1 acceptance formula as adr/0023
    /// D-3 rewrites phase2.md §4 W6 ("托盘侧活条目数 == create − delete"), whether or not a menu
    /// mirrors the entries. Exposed for `Tools/window-smoke`'s `[tray]` diagnostics line via
    /// `RemoteWindowRegistry.trayDiagnostics()`, whose field names and order are unchanged.
    struct Diagnostics {
        let createsSeen: Int
        let updatesSeen: Int
        let deletesSeen: Int
        let liveCount: Int
        /// adr/0013 §4's real-machine acceptance criterion (`realIconCount >= 1`): live entries
        /// currently showing a real remote bitmap, i.e. `liveCount` MINUS the ones still
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
        /// Cumulative; the C side-store's oversize-refusal counter (W3 lane G), as last pushed in
        /// by `RemoteWindowRegistry`. Read at the 2x checkpoint (ADR-0018 U-6); no gate today.
        let storeOversizeRefusalCount: Int
        /// Cumulative; see `clicksForwarded`'s own doc comment (adr/0014 §5).
        let clicksForwarded: Int
        /// Cumulative; see `clicksDroppedIconGone`'s own doc comment -- an acceptance gate
        /// asserts this is 0, because a nonzero value is an entry bookkeeping bug, not a
        /// tolerated race.
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
            liveCount: entries.count, realIconCount: realIconKeys.count,
            iconSkippedCount: iconSkippedCount, cachedIconCount: cachedIconCount,
            realIconMaxObserved: realIconMaxObserved,
            storeOverflowCount: storeOverflowCount,
            storeOversizeRefusalCount: storeOversizeRefusalCount,
            clicksForwarded: clicksForwarded, clicksDroppedIconGone: clicksDroppedIconGone,
            notifyEventsSent: notifyEventsSent,
            observedNotifyIconVersions: observedNotifyIconVersions.sorted()
        )
    }

    /// adr/0013 §1: latest `CRSession.iconStoreOverflowCount`, pushed in by
    /// `RemoteWindowRegistry` (the CRSession owner) on every notify-icon order. Monotonic on
    /// the C side, so this is a plain assignment rather than an accumulation.
    func noteStoreOversizeRefusalCount(_ count: Int) {
        storeOversizeRefusalCount = count
    }

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
    /// unknown/empty) -- post-adr/0013 it is the FALLBACK title only, used when the order
    /// itself carried no usable `toolTip` (see `menuText(wire:ownerWindowTitle:ordinal:)`).
    func handleNotifyIconCreate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        createsSeen += 1
        // R1 finding 1: the model stores the WIRE tooltip truth (nil = the order didn't
        // carry the NOTIFY_TIP bit), never the display-resolved value -- the owner-title
        // fallback is applied when the entry is built below, so a later tooltip-less delta
        // can't launder the fallback into "what the server said".
        model.create(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: icon.toolTip))
        upsertEntry(windowId: windowId, notifyIconId: notifyIconId, ownerWindowTitle: ownerWindowTitle, icon: icon)
    }

    /// A `NotifyIconUpdate` order -- update-in-place: rewrites the existing entry for this key
    /// at its existing position if one is already live (the common case), or appends one if this
    /// is the first order this controller has seen for this key at all (`TrayModel.update`'s own
    /// tolerance for an update-before-create ordering, see its doc comment).
    func handleNotifyIconUpdate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        updatesSeen += 1
        // R1 finding 1: `TrayModel.update` delta-merges -- an update without the NOTIFY_TIP
        // bit keeps the key's previously-seen wire tooltip (the exact mirror of the C
        // side-store re-referencing this key's pixel slot for an icon-less update), so an
        // ordinary icon-only state change no longer blanks a real tooltip down to the
        // owner-title fallback. The entry then shows the MERGED wire truth, resolved
        // against the fallback only when no order ever carried a tooltip at all.
        model.update(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: icon.toolTip))
        upsertEntry(windowId: windowId, notifyIconId: notifyIconId, ownerWindowTitle: ownerWindowTitle, icon: icon)
    }

    /// The delta-merged wire tooltip `TrayModel` currently tracks for this key -- the single
    /// source the title resolution reads, so display resolution always sees the merge result,
    /// never one order's own (possibly bit-absent) field.
    private func storedTooltip(for key: NotifyIconState) -> String? {
        model.icons[key]?.tooltip
    }

    /// A `NotifyIconDelete` order. Tolerates a key with no live entry (unknown-delete, matching
    /// `TrayModel.delete`'s own tolerance) -- `deletesSeen` still counts the ORDER received,
    /// matching `TrayModel`'s own "count the wire event, not just the ones that hit something"
    /// reasoning, since the W6-1 acceptance formula needs that count.
    func handleNotifyIconDelete(windowId: UInt32, notifyIconId: UInt32) {
        deletesSeen += 1
        model.delete(windowId: windowId, notifyIconId: notifyIconId)
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        realIconKeys.remove(key)
        if let index = entryIndex(for: key) {
            entries.remove(at: index)
            onMenuChange?(.removed(index: index, key: key))
        }
    }

    /// Session-scoped teardown -- called from `RemoteWindowRegistry.closeAllWindows()` (all
    /// four of its callers: the generation-rollover branch in `handle(_:)`, the
    /// `.disconnected` case, the explicit `prepareForReconnect()` driver, and the session-end
    /// entry, `closeWindowsForSessionEnd()`), matching how that method already tears down
    /// every other per-connection resource it owns. Clears the LIVE model/entries only -- see
    /// `entries`' own doc comment for why none of this type's counters (including adr/0014's
    /// `clicksForwarded`/`notifyEventsSent`) are reset here. Announced as `.removedAll` even when
    /// nothing was live, so a mirror re-reads its section state on every teardown.
    func removeAll() {
        entries.removeAll()
        realIconKeys.removeAll()
        fallbackOrdinals.removeAll()
        model = TrayModel()
        onMenuChange?(.removedAll)
    }

    // MARK: - The entry table (adr/0023 D-6 P-a)

    /// One live notify icon, as the menu side mirrors it. A value: the menu side copies what it
    /// needs into its own `NSMenuItem` and never hands anything back.
    struct MenuEntry {
        let key: NotifyIconState
        /// Sanitised, single-line, at most `menuTitleLimit` grapheme clusters plus an ellipsis
        /// (adr/0023 D-1 N-a). Never empty: the last fallback is the numbered "Tray app %d".
        let title: String
        /// The whole sanitised text the title was cut from, for `NSMenuItem.toolTip`; nil when
        /// the title is the numbered fallback (there is nothing more to show).
        let toolTip: String?
        /// The remote bitmap (16 pt, not a template) or `placeholderImage` (a template).
        let image: NSImage
        let isPlaceholder: Bool
        /// `TrayButtonTag.pack(key)` -- what the menu side writes into `NSMenuItem.tag` and
        /// hands back to `handleLeftClick(tag:)`.
        var tag: Int { TrayButtonTag.pack(windowId: key.windowId, notifyIconId: key.notifyIconId) }
    }

    /// A change to `entries`, with the position it happened at (adr/0023 D-6 P-a: fine-grained,
    /// so the menu side can insert / rewrite / remove one item in an open menu, D-3 M-a).
    enum MenuChange: Equatable {
        /// `entries[index]` is new.
        case inserted(index: Int)
        /// `entries[index]` was rewritten in place (image, title or tooltip).
        case updated(index: Int)
        /// The entry that was at `index` is gone.
        case removed(index: Int, key: NotifyIconState)
        /// `removeAll()`: no entry is left.
        case removedAll
    }

    /// The menu side's subscription (one subscriber: the status item controller's tray section).
    /// Called after `entries` has changed, on the main actor, in the same turn as the RAIL order
    /// that caused it. `nil` is a safe no-op -- `Tools/window-smoke` reads `entries` and
    /// `diagnostics()` without ever subscribing.
    var onMenuChange: ((MenuChange) -> Void)?

    private func entryIndex(for key: NotifyIconState) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    private func upsertEntry(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload) {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        if icon.skipped {
            iconSkippedCount += 1
            if icon.cached { cachedIconCount += 1 }
            Self.logger.info(
                "notify icon windowId=\(windowId, privacy: .public) notifyIconId=\(notifyIconId, privacy: .public) carried an icon this client refused (adr/0013 §2 iconSkipped, cached=\(icon.cached, privacy: .public)) -- showing the placeholder instead"
            )
        }
        let ordinal: Int
        if let known = fallbackOrdinals[key] {
            ordinal = known
        } else {
            ordinal = fallbackOrdinals.count + 1
            fallbackOrdinals[key] = ordinal
        }
        // adr/0013 §3: a real remote bitmap when one arrived and could be turned into an
        // image, the placeholder otherwise -- deliberately unconditional in both directions,
        // so what an entry shows is always a function of the order that just arrived and
        // never of accumulated history. An icon-less NotifyIconUpdate (a tooltip-only change,
        // say) still lands in the first branch, because the bridge re-references this key's
        // existing side-store slot for exactly that case rather than sending no pixels; the
        // placeholder branch really does mean "the server has no icon for this, or the one it
        // sent was refused". `realIconKeys` mirrors the branch taken, because
        // `Diagnostics.realIconCount` (adr/0013 §4's acceptance assertion) has to be exact.
        let image: NSImage
        let isPlaceholder: Bool
        if let real = Self.menuItemImage(from: icon) {
            image = real
            isPlaceholder = false
            realIconKeys.insert(key)
            realIconMaxObserved = max(realIconMaxObserved, realIconKeys.count)
        } else {
            image = Self.placeholderImage
            isPlaceholder = true
            realIconKeys.remove(key)
        }
        let text = Self.menuText(wire: storedTooltip(for: key), ownerWindowTitle: ownerWindowTitle, ordinal: ordinal)
        let entry = MenuEntry(key: key, title: text.title, toolTip: text.toolTip, image: image, isPlaceholder: isPlaceholder)
        if let index = entryIndex(for: key) {
            entries[index] = entry
            onMenuChange?(.updated(index: index))
        } else {
            entries.append(entry)
            onMenuChange?(.inserted(index: entries.count - 1))
        }
    }

    // MARK: - Titles (adr/0023 D-1 N-a)

    /// adr/0023 D-1 N-a, adr/0013 §3's precedence: the wire's own notify-icon tooltip wins; the
    /// owner window's title is next, kept because a server may legitimately send a notify icon
    /// with no tooltip at all; the numbered "Tray app %d" (string key `si_tray_n`) is last. Each
    /// candidate is sanitised BEFORE it is judged empty, so a tooltip made only of control
    /// characters or blank lines counts as absent. The tooltip is untrusted remote text (up to
    /// 256 bytes after the bridge's own cut, adr/0013), so the title is its first line with
    /// control and format characters removed, cut at `menuTitleLimit` grapheme clusters; the
    /// whole sanitised text goes to the tooltip.
    static func menuText(wire: String?, ownerWindowTitle: String?, ordinal: Int) -> (title: String, toolTip: String?) {
        for candidate in [wire, ownerWindowTitle] {
            guard let candidate else { continue }
            let full = sanitizedText(candidate)
            let firstLine = full.split(separator: "\n", omittingEmptySubsequences: true)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard let firstLine else { continue }
            return (truncatedTitle(firstLine), full)
        }
        let format = Bundle.main.localizedString(forKey: "si_tray_n", value: "Tray app %d", table: nil)
        return (String(format: format, Int32(clamping: ordinal)), nil)
    }

    /// Line breaks of every kind folded to "\n" and tabs to spaces, then every other Unicode
    /// control (Cc) and format (Cf) scalar removed except the zero-width joiner U+200D (which emoji
    /// sequences need); BiDi embeddings, overrides and isolates are Cf and go. Leading and
    /// trailing whitespace trimmed.
    static func sanitizedText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let isCR = scalar == "\r"
            defer { previousWasCR = isCR }
            switch scalar.value {
            case 0x0A where previousWasCR:
                continue // CR LF is one break
            case 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                scalars.append("\n")
                continue
            case 0x09:
                scalars.append(" ") // a tab separates words; keep it as a space
                continue
            case 0x200D:
                scalars.append(scalar)
                continue
            default:
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cut at `menuTitleLimit` grapheme clusters (Swift `Character`s, so an emoji or a base letter
    /// with its combining marks is never split), with "…" appended when anything was cut.
    static func truncatedTitle(_ line: String) -> String {
        guard line.count > menuTitleLimit else { return line }
        return String(line.prefix(menuTitleLimit)) + "…"
    }

    /// adr/0013 §3: `Data` (premultiplied RGBA8888, top-down, tight `width * 4` rows -- the
    /// exact shape `crdpq_icon_convert` writes) -> `CGDataProvider` -> `CGImage` -> `NSImage`,
    /// sized to a `menuItemIconEdge` square. Returns `nil` -- never a blank image -- for any absent or
    /// malformed payload, so the caller's placeholder branch stays the single fallback path.
    ///
    /// Deliberately NOT `.isTemplate`: a template image is flattened to a tint mask, which
    /// would discard the remote icon's colors entirely and make every tray icon look identical
    /// again (the exact placeholder problem adr/0013 exists to fix; adr/0023 D-1 I-a keeps it).
    /// The trade-off is that a remote icon does not auto-tint for appearance changes, which is
    /// the same trade-off any colored menu-item image on macOS already makes.
    ///
    /// `NSImage.size` is set in POINTS while the `CGImage` keeps its native pixel dimensions,
    /// so a 32x32 remote bitmap on a Retina display renders at native resolution inside a
    /// 16 pt square rather than being resampled down first.
    static func menuItemImage(from icon: IconPayload) -> NSImage? {
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
        let image = NSImage(cgImage: cgImage, size: NSSize(width: menuItemIconEdge, height: menuItemIconEdge))
        image.isTemplate = false
        return image
    }

    // The `(windowId, notifyIconId)` <-> tag packing lives in `MacdowsCore.TrayButtonTag`, bit
    // layout pinned there against literals. It used to pack a status-bar button's tag; since
    // adr/0023 it packs the Remote tray section's `NSMenuItem.tag` (`MenuEntry.tag`). Both the
    // menu side and `RemoteWindowRegistry.debugSimulateTrayClick` go through that one
    // implementation.

    /// Called by `RemoteWindowRegistry` (which owns the `CRSession`) for each forwarded left
    /// click, with the clicked icon's own `(windowId, notifyIconId)` wire identity. `nil` (the
    /// default) is a safe no-op -- nothing here requires it ever being set, matching
    /// `CRSession.onEventsAvailable`'s own precedent.
    var onLeftClick: ((_ windowId: UInt32, _ notifyIconId: UInt32) -> Void)?

    /// adr/0014 §1: unpacks the tag, re-checks that the icon is still live, and hands the key to
    /// `onLeftClick`. The one entry point for a click: the Remote tray section's menu-item action
    /// calls it with the chosen item's tag (adr/0023 D-2 C1 + T-a, synchronously from the
    /// action), and the offline harness path (`RemoteWindowRegistry.debugSimulateTrayClick`)
    /// enters it with the same packed tag. The liveness re-check is not ceremony: an entry's item
    /// is chosen through AppKit, so a `NotifyIconDelete` drained between the selection and this
    /// call would otherwise send a notify event addressed at an icon the server has already
    /// destroyed (adr/0023 U-3).
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
        let (windowId, notifyIconId) = TrayButtonTag.unpack(tag)
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        guard entryIndex(for: key) != nil else {
            clicksDroppedIconGone += 1
            // Every time, not once (see `clicksDroppedIconGone`'s own doc comment): this is
            // a bug signal, and its rate and its keys are the diagnosis.
            Self.logger.warning(
                "tray icon left-clicked notifyIconId=\(notifyIconId, privacy: .public) ownerWindowId=\(windowId, privacy: .public) -- but no live tray entry is tracked for that key; dropping the click rather than addressing a ClientNotifyEvent at a destroyed icon (droppedIconGone=\(self.clicksDroppedIconGone, privacy: .public))"
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
