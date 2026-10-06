import AppKit

/// adr/0022 (UI slice ⓪): the App's minimal main menu -- Macdows, Edit and Window, nothing else
/// (UI-1 spec §8 ⓪; File, View, Help and the status item arrive in slice ②).
///
/// Two halves, kept apart on purpose (adr/0022 D-8 T-1, D-9):
///  - `build()` is a pure constructor. It returns menus and touches no global state, so the test
///    bundle can call it and compare every title, key equivalent, selector and target.
///  - `install(on:)` is the only place that hands them to AppKit: the three assignments to the
///    application's main, services and windows menus. `main.swift` calls it once, before `run()`.
///
/// Routing rules this file keeps:
///  - Every item is nil-target with a standard AppKit selector, so the responder chain decides
///    and validates it (adr/0022 D-4 E1: with a remote window key, nothing on its chain
///    implements cut/copy/paste/selectAll, so those items disable themselves). No item sends a
///    key to Windows (adr/0022 I-3), and nothing here reaches the session controls -- ending a
///    session from the menu is slice ② (adr/0022 D-11).
///  - The key equivalents of the four Mac-reserved items come from `LocalKeyEquivalent`, the
///    same constant `RemoteWindowContentView` decides its claims with (adr/0022 D-3). Every other
///    key equivalent here is claimed by a key remote window before the menu bar sees it
///    (adr/0022 D-2 B), so it only acts while a Mac window is key.
///  - Settings… has no action in ⓪ (there is no settings window yet), so AppKit keeps it
///    disabled; ⌘, still stays on the Mac.
///  - Titles come from `Localizable.xcstrings` (en, zh-Hans, ja), keyed by the UI-1 string table's
///    `m_*` keys; the default value is the English text.
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

        return Menus(mainMenu: mainMenu, servicesMenu: servicesMenu, windowsMenu: windowMenu)
    }

    /// Hands the menus to AppKit. The only writer of the three application menu properties.
    static func install(on app: NSApplication) {
        let menus = build()
        app.mainMenu = menus.mainMenu
        app.servicesMenu = menus.servicesMenu
        app.windowsMenu = menus.windowsMenu
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
