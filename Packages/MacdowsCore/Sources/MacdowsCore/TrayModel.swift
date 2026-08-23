import Foundation

/// One notification-area (systray) icon's payload data, as tracked by the live
/// AppKit-side tray rendering path (`TrayStatusController` in the App target).
///
/// `tooltip` is always `nil` on the live `CRSession` path today (Phase 2 W6, docs/plans/
/// phase2.md §2 W6). Verified against `App/CRBridge/CRSession.mm`'s `crb_notify_icon_create`/
/// `crb_notify_icon_update`: both discard the entire `NOTIFY_ICON_STATE_ORDER` payload FreeRDP
/// hands them (`(void)notifyIconState;`) and post only `windowId`/`notifyIconId` through
/// `crdpq_notify_icon_t` — no title, tooltip, or icon pixel data crosses the CRBridge boundary
/// at all (not "pixels only," the entire payload). `TrayIconInfo` still carries this field, not
/// omitted, so a future contract extension (adr/0008-style: teaching `crdpq_notify_icon_t` a
/// bounded tooltip string, the same `crdpq_text_t` truncation precedent `WindowState.title`
/// already uses) doesn't need a breaking signature change here — only a new call-site value.
/// `RemoteWindowRegistry`'s own v1 workaround is to pass the notify icon's OWNER WINDOW's
/// title (which IS captured, via ordinary `WindowCreate`/`WindowUpdate` orders) as this field
/// when one is known, not a notify-icon-specific tooltip.
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
    /// has `Anomaly.duplicateWindowCreate` specifically because `WindowState` carries
    /// sub-field delta-merge semantics worth protecting) — a notify icon's `TrayIconInfo`
    /// has no such semantics, so `info` simply, unconditionally replaces whatever was
    /// previously tracked under this key. Returns whether this key was newly added (`true`)
    /// or already present (`false`), for a caller that wants to distinguish "created" from
    /// "re-created" without a separate lookup.
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
    @discardableResult
    public mutating func update(windowId: UInt32, notifyIconId: UInt32, info: TrayIconInfo = TrayIconInfo()) -> Bool {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        let isNew = icons[key] == nil
        icons[key] = info
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
