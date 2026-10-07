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
///  - Slice ② wired only actions that already existed (UI-1 spec §8 ②). File ▸ Disconnect is the
///    End-session action (adr/0022 D-11 K3-R, `disconnectItem()`). Slice ① (ADR-0024 §3 adr/0022
///    row) gives New Host…, Edit Host…, Connect and View ▸ Show Hosts their actions -- nil-target
///    selectors the Hosts window's controller implements (`newHostAction` …); Connect presses the
///    App's own Connect button from there, so there is still one connect path. The menu structure
///    and every key equivalent are unchanged. The three Help items have no action (their
///    content belongs to Phase 4, UI-1 §9), so AppKit keeps them disabled. Nothing here reaches
///    `connectTapped` or the registry's reconnect seam.
///  - The key equivalents of the four Mac-reserved items come from `LocalKeyEquivalent`, the
///    same constant `RemoteWindowContentView` decides its claims with (adr/0022 D-3). Every other
///    key equivalent here -- slice ②'s ⌘N, ⌘↩, ⇧⌘D, ⌘1 and ⌃⌘F included -- is claimed by a
///    key remote window before the menu bar sees it (adr/0022 D-2 B), so it only acts while a Mac
///    window is key or when the item is chosen with the pointer.
///  - File ▸ Close Window ⌘W (UI-1 spec §6.1; adr/0022 §3 ⌘W row, "② adds Close Window") closes
///    the key Mac window -- the Hosts window or Settings -- and nothing else. The reason it was
///    deferred (on the scaffold window ⌘W closed the last window and terminated the App) is gone
///    since slice ①: the App no longer terminates after its last window closes, and both Mac
///    windows only order out (`isReleasedWhenClosed = false`) and come back through View ▸ Show
///    Hosts, the status item, a Dock reopen or ⌘,. Its action is NOT AppKit's `performClose:`: a
///    `performClose:` item with ⌘W makes AppKit inject an alternate ⌥⌘W Close All (`closeAll:`,
///    enabled even while a remote window is key, closing every titled window). `closeKeyWindow:`
///    is our own nil-target selector, implemented by the two Mac window controllers (each calls
///    `performClose` on its own window and validates the item only while that window is key), so
///    nothing is injected and a remote window -- whose chain implements no `closeKeyWindow:` --
///    leaves the item grey. ⌘W on a key remote window is still claimed by its content view and
///    sent as SC_CLOSE (adr/0022 D-3); the reserved set is unchanged.
///  - `install(on:)` turns automatic window tabbing off before handing the menus over, so AppKit
///    never injects its tab items (Show Previous / Next Tab ⌃⇧⇥ / ⌃⇥, Show Tab Bar, …) into Window
///    / View. A matching item swallows its key even while disabled, so with them a key remote
///    window would never see Ctrl+Tab (adr/0022 R-11). The Mac side has no tabbed windows.
///  - Settings… (⌘,, still one of the four keys the Mac keeps) opens the Settings window (UI slice
///    ③): `showSettings:`, which the Hosts window's controller implements and which `bindShowHosts`
///    binds to it explicitly, for the same reason as Show Hosts -- it has to work while no Macdows
///    window is key. The status item's Settings… performs this same item (`performSettings`).
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
            action: settingsAction, reserved: .settings
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
            action: newHostAction, key: "n", modifiers: [.command]
        ))
        fileMenu.addItem(item(
            String(localized: "edit_host", defaultValue: "Edit Host…", comment: "File menu: Edit Host item (UI slice 1)"),
            action: editHostAction
        ))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(
            String(localized: "connect", defaultValue: "Connect", comment: "File menu: Connect item (UI slice 1)"),
            action: connectAction, key: "\r", modifiers: [.command]
        ))
        fileMenu.addItem(disconnectItem())
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(
            String(localized: "m_close", defaultValue: "Close Window", comment: "File menu: Close Window item (closes the key Mac window)"),
            action: closeWindowAction, key: "w", modifiers: [.command]
        ))
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
            action: showHostsAction, key: "1", modifiers: [.command]
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

    // MARK: - Slice ① actions (ADR-0024 §3, adr/0022 row): the Hosts window controller's

    /// File ▸ New Host… (⌘N).
    static let newHostAction = NSSelectorFromString("newHost:")
    /// File ▸ Edit Host….
    static let editHostAction = NSSelectorFromString("editHost:")
    /// File ▸ Connect (⌘↩): the controller presses the App's Connect button.
    static let connectAction = NSSelectorFromString("connectSelectedHost:")
    /// View ▸ Show Hosts (⌘1).
    static let showHostsAction = NSSelectorFromString("showHosts:")
    /// Macdows ▸ Settings… (⌘,; UI slice ③): the Hosts window's controller opens the Settings window.
    static let settingsAction = NSSelectorFromString("showSettings:")
    /// File ▸ Close Window (⌘W; UI-9): closes the key Mac window. Implemented by
    /// `MainWindowController` and `SettingsWindowController`, never by a remote window; not
    /// `performClose:`, so AppKit injects no ⌥⌘W Close All (see the type doc).
    static let closeWindowAction = NSSelectorFromString("closeKeyWindow:")

    /// Gate r1 I-2: View ▸ Show Hosts must reach the Hosts window while that window is closed, and
    /// a closed window's controller is not in the responder chain -- a nil-target item would grey
    /// out exactly when it is needed. So this one item gets an explicit target, the Hosts window's
    /// controller, once that controller exists (the App calls this after `install(on:)`). The
    /// other slice ① items stay nil-target. Returns false when the menu has no Show Hosts item.
    ///
    /// UI slice ③: Settings… needs the same thing (⌘, must open Settings while a remote window or
    /// no window is key), and it opens through the same controller, so this binds it too. The
    /// App's single call site is unchanged.
    @discardableResult
    static func bindShowHosts(in mainMenu: NSMenu?, to target: AnyObject) -> Bool {
        let items = mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        guard let showHosts = items.first(where: { $0.action == showHostsAction }) else { return false }
        showHosts.target = target
        settingsItem(in: mainMenu)?.target = target
        return true
    }

    /// Macdows ▸ Settings…, if `mainMenu` has it.
    static func settingsItem(in mainMenu: NSMenu?) -> NSMenuItem? {
        mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == settingsAction }
    }

    /// UI slice ③: the status item's Settings… performs the main menu's Settings… item -- its
    /// action, sent to its target (the Hosts window's controller once bound; the responder chain
    /// before that). Returns false when nothing handled it.
    @discardableResult
    static func performSettings(in mainMenu: NSMenu?, from sender: Any?) -> Bool {
        guard let item = settingsItem(in: mainMenu), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: sender)
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

    // MARK: - Item helpers (target always nil; `bindShowHosts` is the one later exception)

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
