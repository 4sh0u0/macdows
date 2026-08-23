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
/// **Two real gaps this round found, both flagged rather than worked around:**
///
/// 1. **No icon pixel data, no title/tooltip data — nothing beyond `windowId`/`notifyIconId`.**
///    Verified directly against `App/CRBridge/CRSession.mm`'s `crb_notify_icon_create`/
///    `crb_notify_icon_update`: both discard the ENTIRE `NOTIFY_ICON_STATE_ORDER` FreeRDP hands
///    them (`(void)notifyIconState;`) — not just the icon bitmap, but also `toolTip`/`infoTip`/
///    `state`. `crdpq_notify_icon_t` (`crdpq.h`) only ever carries `windowId`/`notifyIconId`.
///    So every `NSStatusItem` here shows a placeholder template image (`placeholderImage`
///    below), and its tooltip -- when set at all -- is the icon's OWNER WINDOW's own title
///    (which IS captured, via ordinary `WindowCreate`/`WindowUpdate` orders), not a
///    notify-icon-specific tooltip. Closing this gap for real needs an adr/0008-style
///    contract extension: `crdpq_notify_icon_t` growing a bounded icon-bitmap field (variable
///    size -- an ADR-worthy decision, not a mechanical POD append like `crdpq_window_order_t`'s
///    past `visibleOffsetX/Y` additions) and/or a bounded tooltip string (the `crdpq_text_t`
///    truncation precedent `WindowState.title` already uses). Deliberately NOT done this
///    round -- out of scope per the W6 task assignment.
///
/// 2. **No outbound wire lane for tray clicks exists in CRBridge today.** FreeRDP DOES define
///    one at the RAIL layer -- `RAIL_NOTIFY_EVENT_ORDER { windowId, notifyIconId, message }`
///    (`ThirdParty/FreeRDP/include/freerdp/rail.h:437`) sent via
///    `RailClientContext.ClientNotifyEvent` (`freerdp/client/rail.h:58-59`), with `message`
///    values like `WM_LBUTTONDOWN`/`WM_LBUTTONUP`/`NIN_SELECT` (`rail.h:135-150`) -- but
///    `CRSession.h` exposes no `-sendNotifyEvent:...` method for it, unlike the
///    `-sendSysCommand:command:` lane `RemoteWindowRegistry.handleChromeAction` already uses
///    for traffic-light actions. `handleLeftClick(notifyIconId:ownerWindowId:)` below only
///    LOGS a click for now, rather than inventing wire behavior this round — adding the
///    CRBridge-side send method is the natural next step once that contract change is made
///    (mirroring `sendSysCommand`'s own shape almost exactly), but it's a CRBridge-boundary
///    change, out of scope for this round's App/MacdowsCore-only assignment.
@MainActor
final class TrayStatusController {
    private var model = TrayModel()
    /// One `NSStatusItem` per live notify icon, keyed the same way `model.icons` is (adr/0008-
    /// aligned `(windowId, notifyIconId)` composite identity — see `TrayModel`'s own doc
    /// comment for why `notifyIconId` alone isn't a safe key). Reset (along with `model`) by
    /// `removeAll()`; `createsSeen`/`updatesSeen`/`deletesSeen` below are NOT reset by it —
    /// same "cumulative for this registry's lifetime, not reset on reconnect" precedent
    /// `RemoteWindowRegistry`'s own `zOrderArraysReceivedCount`/`zOrderAppliesPerformedCount`/
    /// `zOrderSkippedUnknownTotal` already establish (see those ivars' own doc comment) — a
    /// post-shutdown `Tools/window-smoke` diagnostics read (`finish()`, after
    /// `session.shutdownAndWait()` has already torn down every live item via `removeAll()`)
    /// must still see the real per-session totals, not zeros.
    private var statusItems: [NotifyIconState: NSStatusItem] = [:]

    private(set) var createsSeen = 0
    private(set) var updatesSeen = 0
    private(set) var deletesSeen = 0

    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "TrayStatusController")

    /// SF Symbol placeholder (degradation form, gap 1 above) — `.isTemplate` so AppKit tints
    /// it correctly against both light and dark menu bars, matching every other system status
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
    }
    func diagnostics() -> Diagnostics {
        Diagnostics(createsSeen: createsSeen, updatesSeen: updatesSeen, deletesSeen: deletesSeen, liveCount: statusItems.count)
    }

    /// A `NotifyIconCreate` order. `ownerWindowTitle` is whatever `RemoteWindowRegistry`
    /// already knows for `ownerWindowId` (its own `geometry[windowId]?.title`, or `nil` if
    /// unknown/empty) -- see gap 1 above for why this, not a notify-icon-specific tooltip, is
    /// what actually reaches AppKit's `NSStatusItem.button.toolTip`.
    func handleNotifyIconCreate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?) {
        createsSeen += 1
        model.create(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: ownerWindowTitle))
        upsertStatusItem(windowId: windowId, notifyIconId: notifyIconId, tooltip: ownerWindowTitle)
    }

    /// A `NotifyIconUpdate` order -- update-in-place: reuses the existing `NSStatusItem` for
    /// this key if one is already live (the common case), or creates one if this is the first
    /// order this controller has seen for this key at all (`TrayModel.update`'s own tolerance
    /// for an update-before-create ordering, see its doc comment).
    func handleNotifyIconUpdate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?) {
        updatesSeen += 1
        model.update(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: ownerWindowTitle))
        upsertStatusItem(windowId: windowId, notifyIconId: notifyIconId, tooltip: ownerWindowTitle)
    }

    /// A `NotifyIconDelete` order. Tolerates a key with no live `NSStatusItem` (unknown-delete,
    /// matching `TrayModel.delete`'s own tolerance) -- `deletesSeen` still counts the ORDER
    /// received, matching `TrayModel`'s own "count the wire event, not just the ones that hit
    /// something" reasoning, since the phase2.md §4 W6 acceptance formula needs that count.
    func handleNotifyIconDelete(windowId: UInt32, notifyIconId: UInt32) {
        deletesSeen += 1
        model.delete(windowId: windowId, notifyIconId: notifyIconId)
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        if let item = statusItems.removeValue(forKey: key) {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    /// Session-scoped teardown -- called from `RemoteWindowRegistry.closeAllWindows()` (both
    /// its callers: the generation-rollover branch in `handle(_:)` and the explicit
    /// `prepareForReconnect()` driver), matching how that method already tears down every
    /// other per-connection resource it owns. Clears the LIVE model/items only -- see
    /// `statusItems`'s own doc comment for why `createsSeen`/`updatesSeen`/`deletesSeen` are
    /// deliberately NOT reset here.
    func removeAll() {
        for (_, item) in statusItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItems.removeAll()
        model = TrayModel()
    }

    private func upsertStatusItem(windowId: UInt32, notifyIconId: UInt32, tooltip: String?) {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
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
        button.image = Self.placeholderImage
        button.toolTip = tooltip
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // Degradation form: no `item.menu` is ever assigned -- an `NSStatusItem` with no menu
        // and a plain button action responds only to the primary (left) click by default, so
        // this alone is what satisfies "left-click forwarding only, no right-click menus"
        // (phase2.md §2 W6's own timebox fallback) without any extra event-type filtering.
        button.tag = Self.packTag(windowId: windowId, notifyIconId: notifyIconId)
    }

    /// Packs `(windowId, notifyIconId)` -- each a wire `UInt32` -- into one 64-bit `Int` tag,
    /// since `NSButton.tag` is a single `Int` and this project already targets a 64-bit-only
    /// platform (see `RemoteWindowRegistry`'s own `RailEventKind` doc comment on `Int32`/
    /// `UInt32` field widths for the same "this codebase's one and only target" reasoning).
    /// `windowId` occupies the high 32 bits, `notifyIconId` the low 32 -- an arbitrary but
    /// internally consistent choice, `unpackTag` is this function's exact inverse.
    private static func packTag(windowId: UInt32, notifyIconId: UInt32) -> Int {
        Int(bitPattern: UInt(UInt64(windowId) << 32 | UInt64(notifyIconId)))
    }

    private static func unpackTag(_ tag: Int) -> (windowId: UInt32, notifyIconId: UInt32) {
        let raw = UInt64(UInt(bitPattern: tag))
        return (UInt32(truncatingIfNeeded: raw >> 32), UInt32(truncatingIfNeeded: raw))
    }

    /// Left-click handler (degradation form: no right-click menu is ever installed, see
    /// `upsertStatusItem`'s own comment on why that alone excludes right-click). See this
    /// type's own doc comment, gap 2, for why this only LOGS rather than forwarding a real
    /// `RAIL_NOTIFY_EVENT_ORDER` to the session.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let (windowId, notifyIconId) = Self.unpackTag(sender.tag)
        Self.logger.info(
            "tray icon left-clicked notifyIconId=\(notifyIconId, privacy: .public) ownerWindowId=\(windowId, privacy: .public) -- NOT forwarded to the session: CRBridge exposes no outbound RAIL_NOTIFY_EVENT_ORDER lane yet (see TrayStatusController's own doc comment, gap 2 -- FreeRDP's RailClientContext.ClientNotifyEvent exists at the wire layer, but CRSession.h has no send method for it, unlike -sendSysCommand:command: for window chrome actions)"
        )
    }
}
