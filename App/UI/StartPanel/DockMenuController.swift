import AppKit
import MacdowsCore

/// ADR-0025 R-1 (a-0) / design note §8: the Dock icon's menu, rebuilt every time the Dock asks
/// (`applicationDockMenu(_:)` forwards here in one line). Its actions live in this class, not in the
/// App delegate (ADR-0025 S-5: the delegate keeps its two `@objc` methods).
///
/// Live:      pinned (at most 3) / --- / recent (at most 5) / --- / Run… / Open Macdows
///            (an empty section takes its separator with it).
/// Not live:  one disabled status line / --- / Run… / Open Macdows. The line is `st_connecting`
///            while connecting, `si_retry` while reconnecting and `st_off` with no session (a
///            give-up has no session, §10 item 1 (b)). Run… opens the panel to show the state, and is
///            disabled with no session.
/// Choosing a program sends it at once through the launcher (the menu has closed, so its outcome is
/// a late one); opening the menu closes the panel. Titles longer than 40 characters are cut in the
/// middle here, because `NSMenu` does not cut them.
@MainActor
final class DockMenuController: NSObject {
    private unowned let controller: StartPanelController
    /// Where the pointer was when the Dock asked for the menu: Run…'s anchor (design note §6).
    private(set) var pointerAtOpen: CGPoint?

    init(controller: StartPanelController) {
        self.controller = controller
    }

    /// The menu for the Dock, built from the App's current state.
    func makeMenu() -> NSMenu {
        controller.close(.dockMenu)
        pointerAtOpen = NSEvent.mouseLocation
        let reading = controller.reading()
        let lists = reading.host.map(controller.items.items(for:)) ?? HostLaunchItems()
        return Self.menu(for: reading, lists: lists, target: self)
    }

    /// The menu for `reading` and `lists`, with every action aimed at `target`.
    static func menu(for reading: StartPanelController.Reading, lists: HostLaunchItems, target: DockMenuController?) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let phase = StartPanelController.phase(for: reading)
        if phase == .live {
            let sections = LaunchCatalog.sections(for: lists)
            let pinned = sections.pinned.prefix(StartPanelPolicy.dockMenuPinnedLimit)
            let recent = sections.recent.prefix(StartPanelPolicy.dockMenuRecentLimit)
            for row in pinned {
                menu.addItem(launchItem(row, target: target))
            }
            if !pinned.isEmpty {
                menu.addItem(.separator())
            }
            for row in recent {
                menu.addItem(launchItem(row, target: target))
            }
            if !recent.isEmpty {
                menu.addItem(.separator())
            }
        } else {
            let status = NSMenuItem(title: statusTitle(for: reading, phase: phase), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }
        let run = NSMenuItem(title: UIStrings.startPanelRun, action: #selector(runProgram(_:)), keyEquivalent: "")
        run.target = target
        run.isEnabled = phase != nil
        menu.addItem(run)
        let open = NSMenuItem(title: UIStrings.openMacdows, action: #selector(openMacdows(_:)), keyEquivalent: "")
        open.target = target
        open.isEnabled = true
        menu.addItem(open)
        return menu
    }

    private static func statusTitle(for reading: StartPanelController.Reading, phase: StartPanelController.Phase?) -> String {
        switch phase {
        case .connecting?: UIStrings.connecting
        case .reconnecting?: UIStrings.reconnectingTo(reading.hostTitle)
        case .live?, nil: UIStrings.notConnected
        }
    }

    private static func launchItem(_ row: LaunchCatalog.Row, target: DockMenuController?) -> NSMenuItem {
        let full = row.arguments.isEmpty ? row.title : row.title + "  " + row.arguments
        let title = truncated(full, limit: StartPanelPolicy.dockMenuTitleLimit)
        let item = NSMenuItem(title: title, action: #selector(launchProgram(_:)), keyEquivalent: "")
        item.target = target
        item.isEnabled = true
        item.representedObject = row.item.id.uuidString
        item.toolTip = row.fullCommand
        if title == full, !row.arguments.isEmpty {
            // Design note §8: the arguments in the secondary colour (whether the Dock keeps the colour
            // is probe P-DMENU / runbook 3.1; the plain title says the same either way).
            let attributed = NSMutableAttributedString(string: row.title, attributes: [.foregroundColor: NSColor.labelColor])
            attributed.append(NSAttributedString(string: "  " + row.arguments, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = attributed
        }
        return item
    }

    /// `text` cut in the middle to `limit` characters (an ellipsis included) when it is longer.
    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    // MARK: - Actions

    @objc func launchProgram(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)),
              let host = controller.reading().host else { return }
        let lists = controller.items.items(for: host)
        guard let item = (lists.pinned + lists.recent).first(where: { $0.id == id }) else { return }
        controller.launchFromDockMenu(item)
    }

    @objc func runProgram(_ sender: NSMenuItem) {
        controller.showFromDockMenu(pointer: pointerAtOpen)
    }

    @objc func openMacdows(_ sender: NSMenuItem) {
        controller.openMacdows()
    }
}
