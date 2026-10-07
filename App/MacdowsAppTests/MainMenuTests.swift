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

/// A window whose key state the test decides (the xctest host cannot make a window key).
private final class MainMenuKeyStateWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
@Suite("MainMenu (adr/0022 UI slices ⓪ and ②)")
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

    @Test("T-1: six top-level menus -- Macdows, File, Edit, View, Window, Help -- and nothing else (adr/0022 slice ②)")
    func topLevelMenus() {
        let menus = MainMenu.build()
        #expect(Self.rows(menus.mainMenu) == [
            "Macdows|submenu||0|own-submenu", "File|submenu||0|own-submenu", "Edit|submenu||0|own-submenu",
            "View|submenu||0|own-submenu", "Window|submenu||0|own-submenu", "Help|submenu||0|own-submenu",
        ])
        #expect(menus.mainMenu.items[4].submenu === menus.windowsMenu)
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
            "Settings…|showSettings:|,|\(command)|nil-target",
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
        let editMenu = try #require(MainMenu.build().mainMenu.items[2].submenu)
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

    /// No Close Window (UI-1 spec §6.1 footnote, gate r1 I-2): it waits for slice ①'s main-window
    /// lifetime, and with it AppKit's injected ⌥⌘W Close All goes too.
    ///
    /// RE-FROZEN by UI slice ① (ADR-0024 §3, adr/0022 row): New Host…, Edit Host… and Connect gain
    /// their nil-target actions -- the Hosts window controller's `newHost:`, `editHost:` and
    /// `connectSelectedHost:` -- with titles, key equivalents and order unchanged. Connect is still
    /// not `connectTapped` (S-6 (ii)).
    @Test("T-1: the File menu (slice ① actions on slice ②'s structure), and there is no Close Window")
    func fileMenu() throws {
        let fileMenu = try #require(MainMenu.build().mainMenu.items[1].submenu)
        let command = Self.command
        let shiftCommand = NSEvent.ModifierFlags([.command, .shift]).rawValue
        #expect(fileMenu.title == "File")
        #expect(Self.rows(fileMenu) == [
            "New Host…|newHost:|n|\(command)|nil-target",
            "Edit Host…|editHost:||0|nil-target",
            "---",
            "Connect|connectSelectedHost:|\r|\(command)|nil-target",
            "Disconnect|endSessionTapped|d|\(shiftCommand)|nil-target",
        ])
    }

    @Test("T-1: the View menu -- Show Hosts is slice ①'s showHosts:, Enter Full Screen is the standard item")
    func viewMenu() throws {
        let viewMenu = try #require(MainMenu.build().mainMenu.items[3].submenu)
        let controlCommand = NSEvent.ModifierFlags([.control, .command]).rawValue
        #expect(viewMenu.title == "View")
        #expect(Self.rows(viewMenu) == [
            "Show Hosts|showHosts:|1|\(Self.command)|nil-target",
            "---",
            "Enter Full Screen|toggleFullScreen:|f|\(controlCommand)|nil-target",
        ])
    }

    @Test("T-1: the Help menu (adr/0022 slice ②) -- three items, none wired yet")
    func helpMenu() throws {
        let helpMenu = try #require(MainMenu.build().mainMenu.items[5].submenu)
        #expect(helpMenu.title == "Help")
        #expect(Self.rows(helpMenu) == [
            "Macdows Help|nil||0|nil-target",
            "Keyboard Shortcuts|nil||0|nil-target",
            "Acknowledgements|nil||0|nil-target",
        ])
    }

    /// adr/0022 §4: every key equivalent slice ② adds is registered as remote or local, here, as a
    /// claim decision of a key remote window's content view: local = the four reserved pairs (the
    /// view answers NO, the menu acts), remote = everything else (the view claims it and the menu
    /// never sees it). The table must cover every key equivalent the built menu carries, so a new
    /// shortcut without a registration is red.
    @Test("T-1: every key equivalent in the menu is registered remote or local, and a key remote view claims exactly the remote ones")
    func everyKeyEquivalentIsRegistered() throws {
        let registered: [String: Bool] = [ // "key/modifiers" -> claimed by a key remote view (remote)
            "q/⌘": false, "h/⌘": false, "h/⌥⌘": false, ",/⌘": false,
            "n/⌘": true, "\r/⌘": true, "d/⇧⌘": true,
            "z/⌘": true, "z/⇧⌘": true, "x/⌘": true, "c/⌘": true, "v/⌘": true, "a/⌘": true,
            "1/⌘": true, "f/⌃⌘": true, "m/⌘": true,
        ]
        func name(_ item: NSMenuItem) -> String {
            let m = item.keyEquivalentModifierMask
            let mods = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
            return "\(item.keyEquivalent)/\(mods)"
        }
        var seen: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty { seen.append(name(item)) }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(MainMenu.build().mainMenu)
        #expect(Set(seen) == Set(registered.keys), "every shortcut registered, nothing registered that the menu lacks")
        #expect(seen.count == Set(seen).count, "no two items share a key equivalent")

        let keyCodes: [String: UInt16] = ["q": 12, "h": 4, ",": 43, "n": 45, "\r": 36, "d": 2, "z": 6, "x": 7, "c": 8, "v": 9, "a": 0, "1": 18, "f": 3, "m": 46]
        for (pair, remote) in registered {
            let parts = pair.split(separator: "/", maxSplits: 1).map(String.init)
            var flags: NSEvent.ModifierFlags = []
            if parts[1].contains("⌃") { flags.insert(.control) }
            if parts[1].contains("⌥") { flags.insert(.option) }
            if parts[1].contains("⇧") { flags.insert(.shift) }
            if parts[1].contains("⌘") { flags.insert(.command) }
            let window = MainMenuKeyStateWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = RemoteWindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            window.contentView = view
            view.onEvent = { _ in }
            _ = window.makeFirstResponder(view)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: parts[0], charactersIgnoringModifiers: parts[0], isARepeat: false, keyCode: keyCodes[parts[0]] ?? 0
            ))
            #expect(view.performKeyEquivalent(with: event) == remote, "\(pair) should be \(remote ? "remote (claimed)" : "local")")
        }
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

    /// Gate r1 I-1 (UI-4 fold F-1): with automatic window tabbing on, AppKit injects its tab items
    /// (Show Previous / Next Tab ⌃⇧⇥ / ⌃⇥, Show Tab Bar, Show All Tabs, …) into Window / View, and a
    /// matching menu item swallows its key even while disabled -- so a key remote window never saw
    /// Ctrl+Tab. `install(on:)` turns tabbing off exactly once, before any of the three menu
    /// assignments, and nowhere else in the file.
    @Test("F-1: install(on:) turns automatic window tabbing off once, before the three menu assignments")
    func installTurnsWindowTabbingOffFirst() throws {
        let code = mainMenuCodeOnly(try mainMenuSource("App/Macdows/MainMenu.swift"))
        let statement = "NSWindow.allowsAutomaticWindowTabbing = false"
        #expect(mainMenuOccurrences(of: "allowsAutomaticWindowTabbing", in: code) == 1)
        let installStart = try #require(code.range(of: "static func install(on app: NSApplication) {"))
        let installEnd = try #require(code.range(of: "static let disconnectAction", range: installStart.upperBound..<code.endIndex))
        let install = String(code[installStart.upperBound..<installEnd.lowerBound])
        #expect(mainMenuOccurrences(of: statement, in: install) == 1)
        let tabbing = try #require(install.range(of: statement))
        for assignment in [".mainMenu = ", ".servicesMenu = ", ".windowsMenu = "] {
            let at = try #require(install.range(of: assignment), "\(assignment)")
            #expect(tabbing.lowerBound < at.lowerBound, "tabbing off before \(assignment)")
        }
    }

    /// The offline half of F-1: `install(on:)` run for real on the test process's application
    /// leaves automatic window tabbing off. The suite is `@MainActor` and this test never
    /// suspends, so no other test observes the swapped menus; they are put back before it returns.
    @Test("F-1: after install(on:), NSWindow.allowsAutomaticWindowTabbing is false")
    func installLeavesWindowTabbingOff() {
        let app = NSApplication.shared
        let before = (app.mainMenu, app.servicesMenu, app.windowsMenu, NSWindow.allowsAutomaticWindowTabbing)
        defer {
            app.mainMenu = before.0
            app.servicesMenu = before.1
            app.windowsMenu = before.2
            NSWindow.allowsAutomaticWindowTabbing = before.3
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        MainMenu.install(on: app)
        #expect(NSWindow.allowsAutomaticWindowTabbing == false)
    }

    // MARK: - The String Catalog (three languages)

    /// Every Swift file that can resolve a string from the App's catalog: the App's own sources
    /// and the shared rendering sources (the tray's numbered fallback title lives there), and --
    /// since UI slice ④ -- `App/SessionControl`, where `ShellReconnectPresenter` resolves the
    /// session-state strings through `ShellText`.
    private static func catalogClientSources() throws -> [String] {
        var files: [String] = []
        for directory in ["App/Macdows", "App/RemoteWindowRendering", "App/UI", "App/SessionControl"] {
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
    /// catalog value is returned unformatted and filled in with `String(format:)`), and the
    /// session-state presenter's `text.string(_:_:)` / `text.format(_:_:_:)` (UI slice ④).
    private static func catalogKeys(in raw: String) throws -> [(String, String)] {
        var used: [(String, String)] = []
        for pattern in [#"String\(localized: "(\w+)", defaultValue: "([^"]+)""#, #"localizedString\(forKey: "(\w+)", value: "([^"]+)""#,
                        #"text\.(?:string|format)\(\s*"(\w+)",\s*"([^"]+)""#] {
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
                // A plain string unit, or (gate r1 m-10, `hosts3` in English) plural variations whose
                // `other` form is the default value.
                let plural = ((value as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any]
                let units: [(form: String, unit: [String: Any]?)] = plural.map { forms in
                    forms.map { (form: $0.key, unit: ($0.value as? [String: Any])?["stringUnit"] as? [String: Any]) }
                } ?? [(form: "other", unit: (value as? [String: Any])?["stringUnit"] as? [String: Any])]
                if let plural {
                    #expect(Set(plural.keys).isSuperset(of: ["one", "other"]), "\(key) \(language) plural forms")
                }
                for (form, unit) in units {
                    #expect(unit?["state"] as? String == "translated", "\(key) \(language) \(form)")
                    let text = unit?["value"] as? String ?? ""
                    #expect(text.count > 0, "\(key) \(language) \(form)")
                    // A format string keeps its placeholders in every language and form.
                    #expect(text.components(separatedBy: "%").count == defaultValue.components(separatedBy: "%").count, "\(key) \(language) \(form)")
                    if language == "en" && form == "other" {
                        #expect(unit?["value"] as? String == defaultValue, "\(key)")
                    }
                }
            }
            if key == "hosts3" {
                #expect(((localizations["en"] as? [String: Any])?["variations"] as? [String: Any])?["plural"] != nil,
                        "gate r1 m-10: English has one / other")
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
        let editMenu = try #require(MainMenu.build().mainMenu.items[2].submenu)
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
        let editMenu = try #require(MainMenu.build().mainMenu.items[2].submenu)
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

    // MARK: - adr/0022 slice ②: what a key remote window greys, and what it leaves to AppKit

    /// The first object on a remote window's nil-target search that implements `selector`: the
    /// responder chain from its first responder, then the window's delegate, then the application.
    private static func firstImplementer(_ selector: Selector, in remote: RemoteWindow) -> AnyObject? {
        var responder: NSResponder? = remote.window.firstResponder
        while let current = responder {
            if current.responds(to: selector) { return current }
            responder = current.nextResponder
        }
        if let delegate = remote.window.delegate, delegate.responds(to: selector) { return delegate }
        return NSApplication.shared.responds(to: selector) ? NSApplication.shared : nil
    }

    /// UI-1 spec §6.1 / adr/0022 §4 and R-11: View ▸ Enter Full Screen and Window ▸ Bring All to
    /// Front, chosen with the pointer while a remote window is key, reach the
    /// remote window's backing window (the first implementer of their action on its chain) and are
    /// greyed by its default-deny validation, wired or not. `arrangeInFront:` is an NSApplication
    /// action; the backing window answers it only so that it is the one asked.
    @Test("slice ②: Enter Full Screen and Bring All to Front are decided by a remote window, and greyed")
    func remoteWindowGreysTheWindowItems() throws {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 11, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "slice-2-probe"
        )
        let menus = MainMenu.build()
        let fullScreen = try #require(menus.mainMenu.items[3].submenu?.items.last)
        let front = try #require(menus.windowsMenu.items.last)
        #expect(fullScreen.action == #selector(NSWindow.toggleFullScreen(_:)))
        #expect(front.action == #selector(NSApplication.arrangeInFront(_:)))
        for wired in [false, true] {
            remote.onChromeAction = wired ? { _ in } : nil
            for item in [fullScreen, front] {
                let action = try #require(item.action)
                #expect(Self.firstImplementer(action, in: remote) === remote.window, "\(item.title) is decided by the remote window")
                #expect(remote.window.validateMenuItem(item) == false, "\(item.title) greyed (wired: \(wired))")
            }
        }
        // The backing window's arrangeInFront: does nothing to the window when called directly.
        let frame = remote.window.frame
        _ = remote.window.tryToPerform(#selector(NSApplication.arrangeInFront(_:)), with: nil)
        #expect(remote.window.frame == frame)
    }

    /// adr/0022 D-11: Disconnect is not decided by a remote window -- nothing on its chain
    /// implements the End-session action -- so a pointer choice still reaches the App delegate and
    /// its `session != nil` validation (AppDelegateSessionEndPinTests pins that half as source).
    @Test("slice ②: File ▸ Disconnect is not decided by a remote window; the App delegate is asked")
    func disconnectPassesARemoteWindowBy() throws {
        let remote = RemoteWindow(
            key: RemoteWindowKey(windowId: 12, generation: 0),
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), title: "disconnect-probe"
        )
        let disconnect = try #require(MainMenu.build().mainMenu.items[1].submenu?.items[4])
        #expect(disconnect.action == MainMenu.disconnectAction)
        #expect(Self.firstImplementer(MainMenu.disconnectAction, in: remote) == nil)
    }
}
