import AppKit
import MacdowsCore

/// adr/0023: the "Remote tray" section of the Macdows status item's menu -- one menu item per live
/// remote notify icon, mirrored from a `TrayStatusController`'s entry table (D-6 P-a).
///
/// The menu-side half of P-a. `TrayStatusController` owns the entries and announces each change
/// with its position; this type owns the `NSMenuItem`s and applies every change to them at once,
/// whether or not the menu is open (D-3 M-a). `menuNeedsUpdate(_:)` is not the refresh point: it
/// runs only before a tracking session starts. A delete therefore removes its item in the same
/// main-actor turn as the RAIL order, which is what keeps `clicksDroppedIconGone` a bug signal
/// (adr/0014 §4). Insertions and removals in an OPEN menu are applied directly; whether AppKit
/// re-lays the open menu at once is adr/0023 U-2, checked on the real machine.
///
/// It edits only the run of items it inserted itself, directly after `anchor`, in `menu`, which
/// belongs to the status item controller -- the one writer of that menu's structure. Shape while
/// shown:
///
///     anchor
///     ---------------------------      leading separator
///     Remote tray · <host>              section header (non-interactive, macOS 14+)
///     <entry> ...                       one per entry, in the entries' order
///     <empty state>                     only while there are no entries (disabled)
///     ---------------------------      trailing separator
///
/// While hidden (adr/0023 D-4: first connect not yet live, given up, no session, no source) none of
/// these items is in the menu.
///
/// Choosing an entry is one left click on the icon (D-2 C1): the item's action hands the item's tag
/// to `TrayStatusController.handleLeftClick(tag:)` synchronously (T-a). Nothing here touches focus
/// or activates a window (adr/0014 §3).
@MainActor
final class StatusItemTraySection: NSObject {
    /// How the section shows (adr/0023 D-4).
    enum Presentation: Equatable {
        /// No section items at all.
        case hidden
        /// Header and entries; the empty-state line `si_tray_none` while there are none.
        case live(host: String)
        /// Header and entries; the empty-state line `si_tray_retry` while there are none (a
        /// reconnect has torn the entries down, adr/0023 §0(b)).
        case reconnecting(host: String)
    }

    /// adr/0023 D-4 H-a: the host name in the header is cut at this many grapheme clusters, plus
    /// an ellipsis.
    static let hostLimit = 32

    let menu: NSMenu
    let anchor: NSMenuItem
    private(set) var presentation: Presentation = .hidden
    private weak var source: TrayStatusController?

    let leadingSeparator = NSMenuItem.separator()
    let trailingSeparator = NSMenuItem.separator()
    private(set) var header = NSMenuItem.sectionHeader(title: "")
    let emptyItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()
    /// One item per `source.entries` element, same order, while shown; empty while hidden.
    private(set) var entryItems: [NSMenuItem] = []

    /// `anchor` must already be in `menu`; the section is kept directly after it.
    init(menu: NSMenu, after anchor: NSMenuItem) {
        self.menu = menu
        self.anchor = anchor
        super.init()
    }

    /// Mirrors `source` from now on (nil: an empty source, which hides nothing by itself --
    /// `presentation` decides that). The previous source stops being mirrored.
    func bind(_ source: TrayStatusController?) {
        if let old = self.source, old !== source {
            old.onMenuChange = nil
        }
        self.source = source
        source?.onMenuChange = { [weak self] change in
            self?.apply(change)
        }
        rebuild()
    }

    func setPresentation(_ presentation: Presentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        rebuild()
    }

    var isShown: Bool { presentation != .hidden }

    // MARK: - D-3 M-a: apply one change to the (possibly open) menu

    private func apply(_ change: TrayStatusController.MenuChange) {
        guard isShown, let source else { return }
        switch change {
        case .inserted(let index):
            guard index < source.entries.count, index <= entryItems.count else { return rebuild() }
            let item = makeItem(for: source.entries[index])
            menu.insertItem(item, at: menu.index(of: header) + 1 + index)
            entryItems.insert(item, at: index)
        case .updated(let index):
            guard index < source.entries.count, index < entryItems.count else { return rebuild() }
            configure(entryItems[index], with: source.entries[index])
        case .removed(let index, _):
            guard index < entryItems.count else { return rebuild() }
            menu.removeItem(entryItems[index])
            entryItems.remove(at: index)
        case .removedAll:
            for item in entryItems { menu.removeItem(item) }
            entryItems.removeAll()
        }
        syncEmptyItem()
    }

    /// Removes every item this section put into the menu, then -- unless hidden -- inserts the
    /// whole section again from the source's current entries.
    private func rebuild() {
        for item in [leadingSeparator, header, emptyItem, trailingSeparator] + entryItems where item.menu === menu {
            menu.removeItem(item)
        }
        entryItems.removeAll()
        let host: String
        switch presentation {
        case .hidden:
            return
        case .live(let name), .reconnecting(let name):
            host = name
        }
        let headerTitle = String(localized: "si_tray", defaultValue: "Remote tray", comment: "Status menu: Remote tray section header, followed by the host name")
        header = NSMenuItem.sectionHeader(title: "\(headerTitle) · \(Self.truncatedHost(host))")
        var index = menu.index(of: anchor) + 1
        for item in [leadingSeparator, header] {
            menu.insertItem(item, at: index)
            index += 1
        }
        for entry in source?.entries ?? [] {
            let item = makeItem(for: entry)
            menu.insertItem(item, at: index)
            entryItems.append(item)
            index += 1
        }
        menu.insertItem(trailingSeparator, at: index)
        syncEmptyItem()
    }

    /// The empty-state line is in the menu exactly while the section is shown with no entries.
    private func syncEmptyItem() {
        let wanted = isShown && entryItems.isEmpty
        if wanted {
            emptyItem.title = presentation == .hidden ? "" : emptyStateTitle()
            if emptyItem.menu !== menu {
                menu.insertItem(emptyItem, at: menu.index(of: header) + 1)
            }
        } else if emptyItem.menu === menu {
            menu.removeItem(emptyItem)
        }
    }

    private func emptyStateTitle() -> String {
        if case .reconnecting = presentation {
            return String(localized: "si_tray_retry", defaultValue: "Tray icons come back after reconnecting", comment: "Status menu: Remote tray section while reconnecting")
        }
        return String(localized: "si_tray_none", defaultValue: "No tray icons in this session", comment: "Status menu: Remote tray section with no icons")
    }

    // MARK: - Entry items

    private func makeItem(for entry: TrayStatusController.MenuEntry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(entryChosen(_:)), keyEquivalent: "")
        item.target = self
        configure(item, with: entry)
        return item
    }

    private func configure(_ item: NSMenuItem, with entry: TrayStatusController.MenuEntry) {
        item.title = entry.title
        item.toolTip = entry.toolTip
        item.image = entry.image
        item.tag = entry.tag
        Self.preferVisibleImage(item)
    }

    /// adr/0023 D-2 C1 + T-a: one left click, forwarded from inside the action.
    @objc private func entryChosen(_ sender: NSMenuItem) {
        source?.handleLeftClick(tag: sender.tag)
    }

    /// adr/0023 D-1 V-a. From macOS 27, AppKit decides whether a menu item's image is shown and
    /// typically hides it unless the item asks otherwise (`NSMenuItem.h`, macOS 27 SDK); a remote
    /// tray item is recognised mostly by its icon. The property is reached at run time only --
    /// the selector check, then key-value coding -- so this source names no macOS 27 symbol and
    /// builds against any SDK; on macOS 14-26 the selector is absent and nothing is set. `1` is
    /// `NSMenuItemImageVisibilityVisible`'s raw value in the macOS 27 beta SDK (Automatic = 0,
    /// Visible = 1, Hidden = 2), to be re-checked against the release SDK.
    static func preferVisibleImage(_ item: NSMenuItem) {
        guard item.responds(to: Selector(("setPreferredImageVisibility:"))) else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    /// adr/0023 D-4 H-a: at most `hostLimit` grapheme clusters, "…" appended when cut.
    static func truncatedHost(_ host: String) -> String {
        guard host.count > hostLimit else { return host }
        return String(host.prefix(hostLimit)) + "…"
    }
}
