import Foundation

/// One notification-area (systray) icon's payload data, as tracked by the live
/// AppKit-side tray rendering path (`TrayStatusController` in the App target).
///
/// `tooltip` used to be permanently `nil` on the live `CRSession` path (Phase 2 W6,
/// docs/plans/phase2.md §2 W6): `crb_notify_icon_create`/`crb_notify_icon_update` discarded
/// the entire `NOTIFY_ICON_STATE_ORDER` payload FreeRDP handed them (`(void)notifyIconState;`)
/// and posted only `windowId`/`notifyIconId` through `crdpq_notify_icon_t`, so nothing — not
/// the icon pixels, not the tooltip — crossed the CRBridge boundary at all. The field was
/// kept anyway, so the contract extension it anticipated wouldn't need a breaking signature
/// change here; adr/0013 is that extension, and it landed exactly as anticipated (a bounded
/// `crdpq_text_t` tooltip appended to the POD, the same truncation precedent
/// `WindowState.title` already uses).
///
/// `TrayStatusController` now fills this with the wire's own `NOTIFY_ICON_STATE_ORDER.toolTip`
/// TRUTH: a `nil` here means "no order in this icon's lifetime has carried the
/// `WINDOW_ORDER_FIELD_NOTIFY_TIP` bit yet" (thanks to `update`'s delta-merge below, a
/// tooltip once seen survives later tooltip-less orders), and an empty string means the
/// server explicitly set an empty tooltip. The owner-window-title DISPLAY fallback lives in
/// `TrayStatusController.resolvedTooltip`, applied at `NSStatusItem` time — deliberately not
/// baked into this stored value, so the wire truth and the display policy can't contaminate
/// each other across deltas (review round R1 finding 1).
public struct TrayIconInfo: Sendable, Equatable {
    public var tooltip: String?

    public init(tooltip: String? = nil) {
        self.tooltip = tooltip
    }
}

/// Pure notify-icon identity/state tracking for the tray-icon-as-`NSStatusItem` rendering
/// path (Phase 2 W6, docs/plans/phase2.md §2 W6 / §4 W6 acceptance: "NSStatusItem 数量 ==
/// create−delete, 图标非空位图, delete 清零"). No AppKit (adr/0006 §2's no-AppKit boundary,
/// the same split `WindowModel`/`WindowMappability`/`StyleTranslator` already establish) —
/// `TrayStatusController` (App target) is the one AppKit-side consumer that turns this into
/// real `NSStatusItem`s.
///
/// Keyed by `NotifyIconState` (the existing `(windowId, notifyIconId)` pair struct defined in
/// `WindowModel.swift`), not by `notifyIconId` alone — matching that struct's own doc comment:
/// a notify icon's owner `windowId` is part of its wire identity (every `NotifyIconCreate`/
/// `Update`/`Delete` order carries both), so two different owner windows could in principle
/// reuse the same `notifyIconId` value for their own, distinct icons. Keying only on
/// `notifyIconId` would silently collide two such icons into a single tracked entry; this
/// follows the same composite-key precedent `WindowModel.notifyIcons` (a `Set<NotifyIconState>`)
/// already established for exactly this data shape, rather than introducing a second,
/// looser-keyed convention for the same wire concept.
///
/// Deliberately a separate type from `WindowModel.notifyIcons`, not reused for it: that
/// `Set<NotifyIconState>` exists purely for the offline JSONL-replay/regression-test path
/// (bare existence tracking, no payload, no create/update/delete counters) — `TrayModel` is
/// the live-rendering-path counterpart, with a `TrayIconInfo` payload per key and (via the
/// call sites' own return values) enough signal for the update-in-place / delete-clears /
/// unknown-delete-tolerated policy `TrayModelTests` locks down.
public struct TrayModel: Sendable, Equatable {
    public private(set) var icons: [NotifyIconState: TrayIconInfo] = [:]

    public init() {}

    public var count: Int { icons.count }

    /// A `NotifyIconCreate` order. A duplicate create for an already-tracked key is not
    /// flagged as an anomaly here (unlike `WindowModel.apply`'s `.windowCreate` case, which
    /// has `Anomaly.duplicateWindowCreate`) — a create starts a fresh icon lifetime, so
    /// `info` unconditionally replaces whatever was previously tracked under this key
    /// (deliberately NOT the delta-merge `update` performs: a re-created icon must not
    /// inherit a tooltip from the lifetime the server just abandoned). Returns whether this
    /// key was newly added (`true`) or already present (`false`), for a caller that wants to
    /// distinguish "created" from "re-created" without a separate lookup.
    @discardableResult
    public mutating func create(windowId: UInt32, notifyIconId: UInt32, info: TrayIconInfo = TrayIconInfo()) -> Bool {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        let isNew = icons[key] == nil
        icons[key] = info
        return isNew
    }

    /// A `NotifyIconUpdate` order. A key not currently tracked is tolerated exactly like
    /// `WindowModel.apply`'s `.notifyIconCreate`/`.notifyIconUpdate` case (both `insert` into
    /// the same `Set` there) — an update-before-create ordering isn't provably impossible on
    /// this wire (adr/0008 §0's own caveat: not every shape has been sample-verified), so this
    /// creates the entry in place rather than silently dropping the update. Returns whether
    /// this key was newly added by this call.
    ///
    /// **Delta-merge (adr/0013 §6.9 / review round R1 finding 1)**: a `NOTIFY_ICON_STATE_ORDER`
    /// is a delta structure like every other RAIL order — an update whose
    /// `WINDOW_ORDER_FIELD_NOTIFY_TIP` bit is absent (`info.tooltip == nil`) says nothing
    /// about the tooltip, so the previously-tracked one is KEPT, not blanked (the exact
    /// mirror of what the C side-store already does for the pixels: a no-icon-bit order
    /// re-references the key's existing slot). An update that DID carry the bit replaces —
    /// including with an explicit empty string, which is the server clearing its tooltip.
    @discardableResult
    public mutating func update(windowId: UInt32, notifyIconId: UInt32, info: TrayIconInfo = TrayIconInfo()) -> Bool {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        let isNew = icons[key] == nil
        if info.tooltip == nil, let prior = icons[key] {
            icons[key] = prior
        } else {
            icons[key] = info
        }
        return isNew
    }

    /// A `NotifyIconDelete` for a key never (or no longer) tracked is tolerated, not an
    /// error — matches `WindowModel.apply`'s own `.notifyIconDelete` case (a `Set.remove` on
    /// an absent element is already a silent no-op there). Returns whether a tracked entry
    /// was actually removed, so a caller (e.g. `TrayStatusController`) knows whether it has a
    /// live `NSStatusItem` to tear down for this key.
    @discardableResult
    public mutating func delete(windowId: UInt32, notifyIconId: UInt32) -> Bool {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        return icons.removeValue(forKey: key) != nil
    }
}
