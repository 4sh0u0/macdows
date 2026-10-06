import AppKit

/// adr/0022: the App's main menu -- Macdows, File, Edit, View, Window, Help. Slice ⓪ built
/// Macdows / Edit / Window; slice ② (adr/0022 §4, UI-1 spec §6.1) adds File, View and Help.
///
/// Two halves, kept apart on purpose (adr/0022 D-8 T-1, D-9):
///  - `build()` is a pure constructor. It returns menus and touches no global state, so the test
///    bundle can call it and compare every title, key equivalent, selector and target.
///  - `install(on:)` is the only place that hands them to AppKit: the three assignments to the
///    application's main, services and windows menus. `main.swift` calls it once, before `run()`.
///
/// Routing rules this file keeps:
///  - Every item is nil-target with a standard AppKit selector (or none), so the responder chain
///    decides and validates it (adr/0022 D-4 E1: with a remote window key, nothing on its chain
///    implements cut/copy/paste/selectAll, so those items disable themselves; Enter Full Screen
///    and Bring All to Front reach the remote window's backing window, whose default-deny
///    validation greys them). No item sends a key to Windows (adr/0022 I-3).
///  - Slice ② wires only actions that already exist (UI-1 spec §8 ②). File ▸ Disconnect is the
///    scaffold's End-session action (adr/0022 D-11 K3-R, `disconnectItem()`); New Host…, Edit
///    Host…, Connect, Show Hosts and the three Help items have no action yet (slices ① / ③), so
///    AppKit keeps them disabled. Nothing here reaches `connectTapped` or the registry's
///    reconnect seam.
///  - The key equivalents of the four Mac-reserved items come from `LocalKeyEquivalent`, the
///    same constant `RemoteWindowContentView` decides its claims with (adr/0022 D-3). Every other
///    key equivalent here -- slice ②'s ⌘N, ⌘↩, ⇧⌘D, ⌘1 and ⌃⌘F included -- is claimed by a
///    key remote window before the menu bar sees it (adr/0022 D-2 B), so it only acts while a Mac
///    window is key or when the item is chosen with the pointer.
///  - File has no Close Window item (UI-1 spec §6.1 footnote): on the scaffold window ⌘W would
///    close the last window and terminate the app, ending the session, and AppKit would inject an
///    enabled ⌥⌘W Close All next to it. It waits for slice ①, which owns the main window's
///    lifetime.
///  - `install(on:)` turns automatic window tabbing off before handing the menus over, so AppKit
///    never injects its tab items (Show Previous / Next Tab ⌃⇧⇥ / ⌃⇥, Show Tab Bar, …) into Window
///    / View. A matching item swallows its key even while disabled, so with them a key remote
///    window would never see Ctrl+Tab (adr/0022 R-11). The Mac side has no tabbed windows.
///  - Settings… has no action yet (there is no settings window), so AppKit keeps it disabled; ⌘,
///    still stays on the Mac.
///  - Titles come from `Localizable.xcstrings` (en, zh-Hans, ja), keyed by the UI-1 string table's
///    keys; the default value is the English text.
@MainActor
enum MainMenu {
    /// The menus `install(on:)` hands to AppKit.
    struct Menus {
        let mainMenu: NSMenu
        let servicesMenu: NSMenu
        let windowsMenu: NSMenu
    }

    /// Builds the three menus. Pure: no application state is read or written.
    static func build() -> Menus {
        let mainMenu = NSMenu(title: "Main Menu")

        // Macdows (the application menu; AppKit shows the app's name as its title).
        let appMenu = NSMenu(title: "Macdows")
        appMenu.addItem(item(
            String(localized: "m_app_about", defaultValue: "About Macdows", comment: "Application menu: About item"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(item(
            String(localized: "m_settings", defaultValue: "Settings…", comment: "Application menu: Settings item"),
            action: nil, reserved: .settings
        ))
        appMenu.addItem(.separator())
        let servicesTitle = String(localized: "m_services", defaultValue: "Services", comment: "Application menu: Services submenu")
        let servicesMenu = NSMenu(title: servicesTitle)
        let servicesItem = item(servicesTitle, action: nil)
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(item(
            String(localized: "m_hide", defaultValue: "Hide Macdows", comment: "Application menu: Hide item"),
            action: #selector(NSApplication.hide(_:)), reserved: .hide
        ))
        appMenu.addItem(item(
            String(localized: "m_hide_others", defaultValue: "Hide Others", comment: "Application menu: Hide Others item"),
            action: #selector(NSApplication.hideOtherApplications(_:)), reserved: .hideOthers
        ))
        appMenu.addItem(item(
            String(localized: "m_show_all", defaultValue: "Show All", comment: "Application menu: Show All item"),
            action: #selector(NSApplication.unhideAllApplications(_:))
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(item(
            String(localized: "m_quit", defaultValue: "Quit Macdows", comment: "Application menu: Quit item"),
            action: #selector(NSApplication.terminate(_:)), reserved: .quit
        ))
        mainMenu.addItem(topLevel("Macdows", submenu: appMenu))

        // File (adr/0022 slice ②; UI-1 spec §6.1).
        let fileMenu = NSMenu(title: String(localized: "m_file", defaultValue: "File", comment: "Main menu: File menu"))
        fileMenu.addItem(item(
            String(localized: "m_new_host", defaultValue: "New Host…", comment: "File menu: New Host item (UI slice 1)"),
            action: nil, key: "n", modifiers: [.command]
        ))
        fileMenu.addItem(item(
            String(localized: "edit_host", defaultValue: "Edit Host…", comment: "File menu: Edit Host item (UI slice 1)"),
            action: nil
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(
            String(localized: "connect", defaultValue: "Connect", comment: "File menu: Connect item (UI slice 1)"),
            action: nil, key: "\r", modifiers: [.command]
        ))
        fileMenu.addItem(disconnectItem())
        mainMenu.addItem(topLevel(fileMenu.title, submenu: fileMenu))

        // Edit (adr/0022 D-4 E1).
        let editMenu = NSMenu(title: String(localized: "m_edit", defaultValue: "Edit", comment: "Main menu: Edit menu"))
        editMenu.addItem(item(
            String(localized: "m_undo", defaultValue: "Undo", comment: "Edit menu: Undo item"),
            action: Selector(("undo:")), key: "z", modifiers: [.command]
        ))
        editMenu.addItem(item(
            String(localized: "m_redo", defaultValue: "Redo", comment: "Edit menu: Redo item"),
            action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(item(
            String(localized: "m_cut", defaultValue: "Cut", comment: "Edit menu: Cut item"),
            action: #selector(NSText.cut(_:)), key: "x", modifiers: [.command]
        ))
        editMenu.addItem(item(
            String(localized: "m_copy", defaultValue: "Copy", comment: "Edit menu: Copy item"),
            action: #selector(NSText.copy(_:)), key: "c", modifiers: [.command]
        ))
        editMenu.addItem(item(
            String(localized: "m_paste", defaultValue: "Paste", comment: "Edit menu: Paste item"),
            action: #selector(NSText.paste(_:)), key: "v", modifiers: [.command]
        ))
        editMenu.addItem(item(
            String(localized: "m_select_all", defaultValue: "Select All", comment: "Edit menu: Select All item"),
            action: #selector(NSText.selectAll(_:)), key: "a", modifiers: [.command]
        ))
        mainMenu.addItem(topLevel(editMenu.title, submenu: editMenu))

        // View (adr/0022 slice ②). Enter Full Screen is the standard `toggleFullScreen:` item.
        // AppKit still adds its own: at run time it hides this ⌃⌘F item and inserts a visible
        // fn-F Enter Full Screen with the same selector (and then injects none into Window). On a
        // key remote window both reach the backing window, whose default-deny validation greys
        // them (adr/0022 R-11; "full screen applies to the main window only", UI-1 spec §6.1).
        let viewMenu = NSMenu(title: String(localized: "m_view", defaultValue: "View", comment: "Main menu: View menu"))
        viewMenu.addItem(item(
            String(localized: "m_show_hosts", defaultValue: "Show Hosts", comment: "View menu: Show Hosts item (UI slice 1)"),
            action: nil, key: "1", modifiers: [.command]
        ))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item(
            String(localized: "m_fullscreen", defaultValue: "Enter Full Screen", comment: "View menu: Enter Full Screen item"),
            action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.control, .command]
        ))
        mainMenu.addItem(topLevel(viewMenu.title, submenu: viewMenu))

        // Window (adr/0022 D-5 W2: remote windows exclude themselves from its list; D-10:
        // Minimize / Zoom reach a key remote window's chrome route through the responder chain).
        let windowMenu = NSMenu(title: String(localized: "m_window", defaultValue: "Window", comment: "Main menu: Window menu"))
        windowMenu.addItem(item(
            String(localized: "m_minimize", defaultValue: "Minimize", comment: "Window menu: Minimize item"),
            action: #selector(NSWindow.performMiniaturize(_:)), key: "m", modifiers: [.command]
        ))
        windowMenu.addItem(item(
            String(localized: "m_zoom", defaultValue: "Zoom", comment: "Window menu: Zoom item"),
            action: #selector(NSWindow.performZoom(_:))
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item(
            String(localized: "m_front", defaultValue: "Bring All to Front", comment: "Window menu: Bring All to Front item"),
            action: #selector(NSApplication.arrangeInFront(_:))
        ))
        mainMenu.addItem(topLevel(windowMenu.title, submenu: windowMenu))

        // Help (adr/0022 slice ②): all three items wait for later slices.
        let helpMenu = NSMenu(title: String(localized: "m_help", defaultValue: "Help", comment: "Main menu: Help menu"))
        helpMenu.addItem(item(
            String(localized: "m_help_item", defaultValue: "Macdows Help", comment: "Help menu: Macdows Help item"),
            action: nil
        ))
        helpMenu.addItem(item(
            String(localized: "m_shortcuts", defaultValue: "Keyboard Shortcuts", comment: "Help menu: Keyboard Shortcuts item"),
            action: nil
        ))
        helpMenu.addItem(item(
            String(localized: "m_ack", defaultValue: "Acknowledgements", comment: "Help menu: Acknowledgements item"),
            action: nil
        ))
        mainMenu.addItem(topLevel(helpMenu.title, submenu: helpMenu))

        return Menus(mainMenu: mainMenu, servicesMenu: servicesMenu, windowsMenu: windowMenu)
    }

    /// Hands the menus to AppKit. The only writer of the three application menu properties.
    /// Automatic window tabbing goes off first, before AppKit sees any menu (see the type doc).
    static func install(on app: NSApplication) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let menus = build()
        app.mainMenu = menus.mainMenu
        app.servicesMenu = menus.servicesMenu
        app.windowsMenu = menus.windowsMenu
    }

    // MARK: - Disconnect (adr/0022 D-11 K3-R)

    /// The scaffold's End-session action -- the same method the Disconnect button calls. Named
    /// here, once, and used only by `disconnectItem()` and by `AppDelegate`'s validation of it.
    static let disconnectAction = NSSelectorFromString("endSessionTapped")

    /// File ▸ Disconnect, and the status item's Disconnect (`StatusItemController` builds its item
    /// here too): nil-target, so the action reaches `AppDelegate` through the responder chain --
    /// no remote window implements it -- and `AppDelegate` enables it exactly while a session
    /// exists, the scaffold button's own predicate. ⇧⌘D is claimed by a key remote window first
    /// (adr/0022 D-2 B), so from the keyboard it acts only while a Mac window is key.
    static func disconnectItem() -> NSMenuItem {
        item(
            String(localized: "disconnect", defaultValue: "Disconnect", comment: "File menu and status menu: end the current session"),
            action: disconnectAction, key: "d", modifiers: [.command, .shift]
        )
    }

    // MARK: - Item helpers (target always nil)

    private static func item(
        _ title: String, action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func item(_ title: String, action: Selector?, reserved: LocalKeyEquivalent) -> NSMenuItem {
        item(title, action: action, key: reserved.character, modifiers: reserved.modifiers)
    }

    private static func topLevel(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = self.item(title, action: nil)
        item.submenu = submenu
        return item
    }
}
