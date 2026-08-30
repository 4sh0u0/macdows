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
/// **One real gap remains, flagged rather than worked around:**
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
    /// Latest observed value of `CRSession.iconStoreOverflowCount` — the C side-store's own
    /// counter for icons refused because all `CRDPQ_ICON_SLOTS` (16) slots were held by other
    /// keys (adr/0013 §1). Pushed in by `RemoteWindowRegistry` (which owns the `CRSession`
    /// reference) on every notify-icon order rather than pulled from here, keeping this type's
    /// dependency surface at "AppKit + values handed to it", exactly as before.
    private(set) var storeOverflowCount = 0

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
        /// Cumulative; the C side-store's slot-exhaustion counter (adr/0013 §1), as last
        /// pushed in by `RemoteWindowRegistry`.
        let storeOverflowCount: Int
    }
    func diagnostics() -> Diagnostics {
        Diagnostics(
            createsSeen: createsSeen, updatesSeen: updatesSeen, deletesSeen: deletesSeen,
            liveCount: statusItems.count, realIconCount: realIconKeys.count,
            iconSkippedCount: iconSkippedCount, storeOverflowCount: storeOverflowCount
        )
    }

    /// adr/0013 §1: latest `CRSession.iconStoreOverflowCount`, pushed in by
    /// `RemoteWindowRegistry` (the CRSession owner) on every notify-icon order. Monotonic on
    /// the C side, so this is a plain assignment rather than an accumulation.
    func noteStoreOverflowCount(_ count: Int) {
        storeOverflowCount = count
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
        /// `NOTIFY_ICON_STATE_ORDER.toolTip`, or `nil` when the order didn't carry the
        /// `WINDOW_ORDER_FIELD_NOTIFY_TIP` bit.
        let toolTip: String?

        static let absent = IconPayload(rgba: nil, width: 0, height: 0, skipped: false, toolTip: nil)
    }

    /// A `NotifyIconCreate` order. `ownerWindowTitle` is whatever `RemoteWindowRegistry`
    /// already knows for `ownerWindowId` (its own `geometry[windowId]?.title`, or `nil` if
    /// unknown/empty) -- post-adr/0013 it is the FALLBACK tooltip only, used when the order
    /// itself carried no `toolTip` (see `resolvedTooltip`).
    func handleNotifyIconCreate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        createsSeen += 1
        let tooltip = Self.resolvedTooltip(wire: icon.toolTip, ownerWindowTitle: ownerWindowTitle)
        model.create(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: tooltip))
        upsertStatusItem(windowId: windowId, notifyIconId: notifyIconId, tooltip: tooltip, icon: icon)
    }

    /// A `NotifyIconUpdate` order -- update-in-place: reuses the existing `NSStatusItem` for
    /// this key if one is already live (the common case), or creates one if this is the first
    /// order this controller has seen for this key at all (`TrayModel.update`'s own tolerance
    /// for an update-before-create ordering, see its doc comment).
    func handleNotifyIconUpdate(windowId: UInt32, notifyIconId: UInt32, ownerWindowTitle: String?, icon: IconPayload = .absent) {
        updatesSeen += 1
        let tooltip = Self.resolvedTooltip(wire: icon.toolTip, ownerWindowTitle: ownerWindowTitle)
        model.update(windowId: windowId, notifyIconId: notifyIconId, info: TrayIconInfo(tooltip: tooltip))
        upsertStatusItem(windowId: windowId, notifyIconId: notifyIconId, tooltip: tooltip, icon: icon)
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
        realIconKeys.removeAll()
        model = TrayModel()
    }

    private func upsertStatusItem(windowId: UInt32, notifyIconId: UInt32, tooltip: String?, icon: IconPayload) {
        let key = NotifyIconState(windowId: windowId, notifyIconId: notifyIconId)
        if icon.skipped {
            iconSkippedCount += 1
            Self.logger.info(
                "notify icon windowId=\(windowId, privacy: .public) notifyIconId=\(notifyIconId, privacy: .public) carried an icon this client refused (adr/0013 §2 iconSkipped) -- showing the placeholder instead"
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
