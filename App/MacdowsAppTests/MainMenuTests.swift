import AppKit
import Testing

// adr/0022 (UI slice ⓪), commit 2: the minimal main menu (D-1 M1, D-4 E1, D-9), the Window menu's
// Minimize / Zoom route for a key remote window (D-10), and D-8's T-1, T-4 and T-7. T-6 (the S-6
// rewrite) is in AppDelegateSessionEndPinTests.
//
// `App/project.yml` compiles exactly one file of `App/Macdows` into this bundle,
// `MainMenu.swift`, so `MainMenu.build()` runs here for real. `main.swift` is read as source.
//
// Coverage boundary, stated (adr/0022 D-8 T-4 "若宿主无法建 key window 则降为记录项"): the xctest
// host cannot make a window key -- `makeKeyAndOrderFront` leaves `isKeyWindow` false and
// `NSApp.keyWindow` nil -- so nil-target validation and a real ⌘A through the menu bar cannot be
// driven end to end here. A standalone .app launched through LaunchServices (`open`) can: gate
// r1's probe `probe-dispatch-order.swift` got a real key window that way. T-4 therefore checks the
// two facts that validation rests on: what the responder chain of a key text field implements
// (the Edit actions are reachable), and what the chain of a key remote window implements
// (cut/copy/paste/selectAll are not, so AppKit disables those items). `NSMenu.performKeyEquivalent`
// returning YES for a matching item even when it is disabled -- first seen while writing this
// file -- has been confirmed by gate r1 on a real key window.

private func mainMenuRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func mainMenuSource(_ relative: String) throws -> String {
    try String(contentsOf: mainMenuRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded -- the same stripping `AppDelegateSessionEndPinTests`
/// uses, so a count is about statements and not about the prose explaining them.
private func mainMenuCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func mainMenuOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@MainActor
@Suite("MainMenu (adr/0022 UI slice ⓪)")
struct MainMenuTests {
    private static let command = NSEvent.ModifierFlags.command.rawValue

    /// One line per item: title | action | key equivalent | modifier mask raw value | target.
    /// An item that carries a submenu is rendered as `submenu`: AppKit itself gives such an item
    /// the `submenuAction:` action and its submenu as target the moment the submenu is attached.
    private static func rows(_ menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "---" }
            if let submenu = item.submenu {
                let wiring = item.action == #selector(NSMenu.submenuAction(_:)) && item.target === submenu
                return "\(item.title)|submenu|\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)|\(wiring ? "own-submenu" : "OTHER")"
            }
            let action = item.action.map { NSStringFromSelector($0) } ?? "nil"
            let target = item.target == nil ? "nil-target" : "TARGET"
            return "\(item.title)|\(action)|\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)|\(target)"
        }
    }

    // MARK: - T-1: structure

    @Test("T-1: three top-level menus -- Macdows, Edit, Window -- and nothing else")
    func topLevelMenus() {
        let menus = MainMenu.build()
        #expect(Self.rows(menus.mainMenu) == [
            "Macdows|submenu||0|own-submenu", "Edit|submenu||0|own-submenu", "Window|submenu||0|own-submenu",
        ])
        #expect(menus.mainMenu.items[2].submenu === menus.windowsMenu)
    }

    @Test("T-1: the Macdows menu, item by item")
    func applicationMenu() throws {
        let menus = MainMenu.build()
        let appMenu = try #require(menus.mainMenu.items[0].submenu)
        let command = Self.command
        let optionCommand = NSEvent.ModifierFlags([.command, .option]).rawValue
        #expect(Self.rows(appMenu) == [
            "About Macdows|orderFrontStandardAboutPanel:||0|nil-target",
            "---",
            "Settings…|nil|,|\(command)|nil-target",
            "---",
            "Services|submenu||0|own-submenu",
            "---",
            "Hide Macdows|hide:|h|\(command)|nil-target",
            "Hide Others|hideOtherApplications:|h|\(optionCommand)|nil-target",
            "Show All|unhideAllApplications:||0|nil-target",
            "---",
            "Quit Macdows|terminate:|q|\(command)|nil-target",
        ])
        #expect(appMenu.items[4].submenu === menus.servicesMenu)
    }

    @Test("T-1: the Edit menu -- nil target, the six standard selectors (adr/0022 D-4 E1)")
    func editMenu() throws {
        let editMenu = try #require(MainMenu.build().mainMenu.items[1].submenu)
        let command = Self.command
        let shiftCommand = NSEvent.ModifierFlags([.command, .shift]).rawValue
        #expect(editMenu.title == "Edit")
        #expect(Self.rows(editMenu) == [
            "Undo|undo:|z|\(command)|nil-target",
            "Redo|redo:|z|\(shiftCommand)|nil-target",
            "---",
            "Cut|cut:|x|\(command)|nil-target",
            "Copy|copy:|c|\(command)|nil-target",
            "Paste|paste:|v|\(command)|nil-target",
            "Select All|selectAll:|a|\(command)|nil-target",
        ])
    }

    @Test("T-1: the Window menu -- Minimize, Zoom, Bring All to Front")
    func windowMenu() {
        let windowsMenu = MainMenu.build().windowsMenu
        #expect(windowsMenu.title == "Window")
        #expect(Self.rows(windowsMenu) == [
            "Minimize|performMiniaturize:|m|\(Self.command)|nil-target",
            "Zoom|performZoom:||0|nil-target",
            "---",
            "Bring All to Front|arrangeInFront:||0|nil-target",
        ])
    }

    @Test("T-1: the menu's local items take their keys from the view's reserved set, and no other item collides with it")
    func reservedItemsComeFromTheSameConstant() {
        let menus = MainMenu.build()
        var reservedSeen: [LocalKeyEquivalent] = []
        var all: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                all.append(item)
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menus.mainMenu)
        for item in all where !item.keyEquivalent.isEmpty {
            let pair = LocalKeyEquivalent(
                character: item.keyEquivalent.lowercased(),
                modifiers: item.keyEquivalentModifierMask.intersection(LocalKeyEquivalent.comparedModifiers)
            )
            if LocalKeyEquivalent.reserved.contains(pair) { reservedSeen.append(pair) }
        }
        #expect(Set(reservedSeen) == Set(LocalKeyEquivalent.reserved))
        #expect(reservedSeen.count == LocalKeyEquivalent.reserved.count)
        // No action item ever carries a target: the responder chain decides (adr/0022 D-4, D-10).
        // (Submenu-carrying items get AppKit's own submenu wiring; `rows` pins that shape.)
        #expect(all.filter { $0.submenu == nil }.allSatisfy { $0.target == nil })
    }

    @Test("T-1: build() is pure -- the application's menus are untouched by it")
    func buildTouchesNoApplicationState() {
        let app = NSApplication.shared
        let before = (app.mainMenu, app.servicesMenu, app.windowsMenu)
        _ = MainMenu.build()
        #expect(app.mainMenu === before.0)
        #expect(app.servicesMenu === before.1)
        #expect(app.windowsMenu === before.2)
    }

    @Test("T-1: the three application-menu assignments live only in install(on:), and main.swift calls it once before run()")
    func installIsTheOnlyWriter() throws {
        let raw = try mainMenuSource("App/Macdows/MainMenu.swift")
        let code = mainMenuCodeOnly(raw)
        let installStart = try #require(code.range(of: "static func install(on app: NSApplication) {"))
        let helpersStart = try #require(code.range(of: "private static func item("))
        let install = String(code[installStart.upperBound..<helpersStart.lowerBound])
        for assignment in [".mainMenu = ", ".servicesMenu = ", ".windowsMenu = "] {
            #expect(mainMenuOccurrences(of: assignment, in: code) == 1, "\(assignment)")
            #expect(mainMenuOccurrences(of: assignment, in: install) == 1, "\(assignment)")
        }
        let main = mainMenuCodeOnly(try mainMenuSource("App/Macdows/main.swift"))
        #expect(mainMenuOccurrences(of: "MainMenu.install(on: app)", in: main) == 1)
        let installCall = try #require(main.range(of: "MainMenu.install(on: app)"))
        let run = try #require(main.range(of: "app.run()"))
        #expect(installCall.lowerBound < run.lowerBound)
    }

    // MARK: - The String Catalog (three languages)

    /// Every Swift file that can resolve a string from the App's catalog: the App's own sources
    /// and the shared rendering sources (the tray's numbered fallback title lives there).
    private static func catalogClientSources() throws -> [String] {
        var files: [String] = []
        for directory in ["App/Macdows", "App/RemoteWindowRendering"] {
            let root = mainMenuRepoRoot().appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(String(url.path.dropFirst(mainMenuRepoRoot().path.count + 1)))
            }
        }
        return files.sorted()
    }

    /// The literal key / default-value pairs a source resolves: `String(localized:defaultValue:)`
    /// for plain titles, `Bundle.localizedString(forKey:value:table:)` for format strings (whose
    /// catalog value is returned unformatted and filled in with `String(format:)`).
    private static func catalogKeys(in raw: String) throws -> [(String, String)] {
        var used: [(String, String)] = []
        for pattern in [#"String\(localized: "(\w+)", defaultValue: "([^"]+)""#, #"localizedString\(forKey: "(\w+)", value: "([^"]+)""#] {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let key = Range(match.range(at: 1), in: raw), let value = Range(match.range(at: 2), in: raw) else { continue }
                used.append((String(raw[key]), String(raw[value])))
            }
        }
        return used
    }

    @Test("every string key the App resolves is in Localizable.xcstrings with en, zh-Hans and ja, en equals the default value, and no key is orphaned")
    func stringCatalogCoversEveryTitle() throws {
        var used: [(String, String)] = []
        for file in try Self.catalogClientSources() {
            used += try Self.catalogKeys(in: try mainMenuSource(file))
        }
        let menuKeys = try Self.catalogKeys(in: try mainMenuSource("App/Macdows/MainMenu.swift"))
        #expect(menuKeys.count >= 18, "the walk found MainMenu.swift's titles")
        // One default value per key, wherever the key is used.
        var defaults: [String: String] = [:]
        for (key, value) in used {
            #expect(defaults[key] == nil || defaults[key] == value, "\(key) has two default values")
            defaults[key] = value
        }

        let data = try Data(contentsOf: mainMenuRepoRoot().appendingPathComponent("App/Macdows/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(Set(strings.keys) == Set(defaults.keys), "no missing and no orphaned keys")
        for (key, defaultValue) in defaults {
            let entry = try #require(strings[key] as? [String: Any], "\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key)")
            #expect(Set(localizations.keys) == ["en", "zh-Hans", "ja"], "\(key)")
            for (language, value) in localizations {
                let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["state"] as? String == "translated", "\(key) \(language)")
                let text = unit?["value"] as? String ?? ""
                #expect(text.count > 0, "\(key) \(language)")
                // A format string keeps its placeholders in every language.
                #expect(text.components(separatedBy: "%").count == defaultValue.components(separatedBy: "%").count, "\(key) \(language)")
                if language == "en" {
                    #expect(unit?["value"] as? String == defaultValue, "\(key)")
                }
            }
        }
    }

    // MARK: - T-4: Edit reachability (responder-chain half; see the file header)

    /// Every responder AppKit's nil-target search would ask for a window whose first responder is
    /// `start`: the chain itself, then the window's delegate, the application and its delegate.
    private static func chainImplements(_ selector: Selector, from start: NSResponder?, window: NSWindow) -> Bool {
        var responder = start
        while let current = responder {
            if current.responds(to: selector) { return true }
            responder = current.nextResponder
        }
        let tail: [AnyObject?] = [window.delegate, NSApplication.shared, NSApplication.shared.delegate]
        return tail.contains { $0?.responds(to: selector) == true }
    }

    @Test("T-4: a first-responder text field's chain implements the Edit actions, and Select All selects")
    func editActionsReachATextField() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "hello world")
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        window.contentView?.addSubview(field)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let editMenu = try #require(MainMenu.build().mainMenu.items[1].submenu)
        for item in editMenu.items where !item.isSeparatorItem {
            let action = try #require(item.action)
            #expect(Self.chainImplements(action, from: window.firstResponder, window: window), "\(item.title)")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let selectAll = try #require(editMenu.items.last?.action)
        #expect(window.firstResponder?.tryToPerform(selectAll, with: nil) == true)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 11))
    }

    @Test("T-4: a remote window's chain implements none of cut/copy/paste/selectAll, so AppKit disables them")
    func editActionsDoNotReachARemoteWindow() throws {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 4, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "edit-probe"
        )
        try #require(remote.window.firstResponder is RemoteWindowContentView)
        for action in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))] {
            #expect(!Self.chainImplements(action, from: remote.window.firstResponder, window: remote.window), "\(action)")
        }
    }

    /// adr/0022 U-5, recorded rather than assumed: NSWindow itself implements `undo:` / `redo:`, so
    /// those two items are decided by the window's own validation, not by "nobody implements
    /// them". With no undo manager history it answers "disabled" -- the value pinned here. Since
    /// gate r1 fold F-1 the backing window's default-deny validation answers NO for these two as
    /// well, so NSWindow's own answer alone can no longer turn this pin red; it now also guards that
    /// default branch.
    @Test("T-4 / U-5: a remote window answers undo:/redo: itself, and validates them as disabled")
    func undoRedoOnARemoteWindowAreDisabled() throws {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 5, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "undo-probe"
        )
        let editMenu = try #require(MainMenu.build().mainMenu.items[1].submenu)
        for item in editMenu.items.prefix(2) {
            let action = try #require(item.action)
            #expect(Self.chainImplements(action, from: remote.window.firstResponder, window: remote.window), "\(item.title)")
            #expect(remote.window.validateMenuItem(item) == false, "\(item.title)")
        }
    }

    // MARK: - T-7: Minimize / Zoom route to the chrome action (adr/0022 D-10)

    private final class ActionBox {
        var actions: [String] = []
    }

    @Test("T-7: performMiniaturize:, performZoom: and zoom: each fire onChromeAction exactly once and do nothing locally")
    func chromeActionsRouteThroughTheBackingWindow() {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 6, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "chrome-probe"
        )
        let box = ActionBox()
        remote.onChromeAction = { box.actions.append("\($0)") }
        let frameBefore = remote.window.frame

        remote.window.performMiniaturize(nil)
        #expect(box.actions == ["minimize"])
        remote.window.performZoom(nil)
        #expect(box.actions == ["minimize", "zoom"])
        remote.window.zoom(nil)
        #expect(box.actions == ["minimize", "zoom", "zoom"])

        // Server-authoritative: nothing happened to the local window.
        #expect(!remote.window.isMiniaturized)
        #expect(remote.window.frame == frameBefore)
    }

    @Test("T-7: Minimize and Zoom validate as enabled exactly while onChromeAction is set")
    func minimizeAndZoomValidateOnTheConsumer() {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 8, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "validate-probe"
        )
        let windowMenu = MainMenu.build().windowsMenu
        let minimize = windowMenu.items[0]
        let zoom = windowMenu.items[1]
        #expect(remote.window.validateMenuItem(minimize) == false)
        #expect(remote.window.validateMenuItem(zoom) == false)
        remote.onChromeAction = { _ in }
        #expect(remote.window.validateMenuItem(minimize) == true)
        #expect(remote.window.validateMenuItem(zoom) == true)
        remote.onChromeAction = nil
        #expect(remote.window.validateMenuItem(minimize) == false)
    }

    /// Gate r1 I-1 (fold F-1): AppKit injects Window-menu items of its own once `windowsMenu` is
    /// set -- Full Screen, Center, Move & Resize -- and, validated by NSWindow's stock answer, they
    /// were enabled for a key borderless remote window, a menu route to the window's local frame
    /// that bypasses D-10. The backing window therefore validates by default-deny: only D-10's two
    /// items, and only while wired. `_zoomCenter:` is the private selector the r1 probe observed
    /// behind Window > Center; it is named here, in a test, and never in product code. Gate r2
    /// m-1: every selector in the table validates TRUE under NSWindow's stock answer on this
    /// window (measured by r2), so each arm goes red if the default-deny is ever removed;
    /// `toggleFullScreen:` was dropped from the table because stock already answers false for a
    /// borderless window (the dedicated test below keeps it as a regression guard only).
    @Test(
        "F-1: a remote window validates every item except D-10's Minimize / Zoom as disabled, wired or not",
        arguments: [
            "_zoomCenter:",
            "_zoomLeft:",
            "orderFront:",
            "arrangeInFront:",
            "someUnrelatedAction:",
        ]
    )
    func everyOtherItemIsDisabledByDefault(selectorName: String) {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 9, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "default-deny-probe"
        )
        let item = NSMenuItem(title: selectorName, action: NSSelectorFromString(selectorName), keyEquivalent: "")
        #expect(remote.window.validateMenuItem(item) == false, "unwired: \(selectorName)")
        remote.onChromeAction = { _ in }
        #expect(remote.window.validateMenuItem(item) == false, "wired: \(selectorName)")

        // The same wired window still enables D-10's two items, so the denial above is not a
        // window that has stopped validating anything.
        let windowMenu = MainMenu.build().windowsMenu
        #expect(remote.window.validateMenuItem(windowMenu.items[0]) == true)
        #expect(remote.window.validateMenuItem(windowMenu.items[1]) == true)
    }

    @Test("F-1: the toggleFullScreen: item, built from its #selector, validates as disabled")
    func fullScreenItemFromSelectorIsDisabled() {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 10, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "full-screen-probe"
        )
        remote.onChromeAction = { _ in }
        let item = NSMenuItem(title: "Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.control, .command]
        #expect(remote.window.validateMenuItem(item) == false)
    }
}
