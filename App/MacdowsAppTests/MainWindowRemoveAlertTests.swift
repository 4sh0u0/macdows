import AppKit
import Foundation
import MacdowsCore
import Testing

// Finding F-6 (owner in-person batch 2026-10-07, ruled "the same as F-2"): the Remove Host warning
// keeps Remove as its first button -- the response the sheet checks -- but Cancel is the default
// button: Return cancels, Escape still cancels through `AlertKeys.cancelOnEscape`, and Remove never
// has a key. Offline: the alert is built (and, for the Escape route, ordered in without a sheet);
// the buttons' own action is replaced, so nothing is removed and no store is touched.

private func removeAlertRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func removeAlertSource(_ relative: String) throws -> String {
    try String(contentsOf: removeAlertRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded.
private func removeAlertCodeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.components(separatedBy: "//").first ?? "" }
        .joined(separator: " ")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func removeAlertOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Takes the place of the alert's own button action, so a click is recorded instead of ending a sheet.
@MainActor
private final class ButtonClickRecorder: NSObject {
    var clicked: [String] = []
    @objc func click(_ sender: NSButton) { clicked.append(sender.title) }
}

/// The alert panel's first responder in the stop test: records every key-down that reaches the
/// window past the local monitors.
private final class KeyDownRecorderView: NSView {
    var keyCodes: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}

@MainActor
@Suite("F-6 — the Remove Host warning's keys, offline", .serialized)
struct MainWindowRemoveAlertTests {
    private static let record = HostRecord(displayName: "A", address: "a.example", userName: "u")

    @Test("the Remove alert: Remove first, destructive and keyless; Cancel second and the default button (Return)")
    func removeAlertShape() {
        let alert = MainWindowController.makeRemoveAlert(for: Self.record)
        #expect(alert.alertStyle == .warning)
        #expect(alert.messageText == UIStrings.removeTitle(Self.record.title))
        #expect(alert.informativeText == UIStrings.removeBody)
        #expect(alert.buttons.map(\.title) == [UIStrings.removeConfirm, UIStrings.cancel], "the order the sheet's response relies on")
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent.isEmpty, "Remove has no key (AppKit gave it Return at addButton time)")
        #expect(!alert.buttons[1].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\r", "Cancel is the default button")
        #expect(alert.window.defaultButtonCell === alert.buttons[1].cell)
        // What the sheet shows: layout keeps the keys where they were put.
        alert.layout()
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "\r"])
        #expect(alert.window.defaultButtonCell === alert.buttons[1].cell)
    }

    @Test("AppKit's own assignment, which the shape pin overrides: the first button gets Return, the Cancel-titled one Escape")
    func appKitAssignmentBeforeTheFix() {
        // Without this the "Remove has no key" pin could pass with the clearing line gone.
        let alert = NSAlert()
        let remove = alert.addButton(withTitle: UIStrings.removeConfirm)
        remove.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: UIStrings.cancel)
        #expect(remove.keyEquivalent == "\r")
        #expect(cancel.keyEquivalent == "\u{1b}")
    }

    @Test("Escape clicks Cancel, the second button, while the monitor is installed, and nothing once it is removed")
    func escapeClicksCancelNotTheFirstButton() throws {
        _ = NSApplication.shared
        let alert = MainWindowController.makeRemoveAlert(for: Self.record)
        alert.layout()
        let recorder = ButtonClickRecorder()
        for button in alert.buttons {
            button.target = recorder
            button.action = #selector(ButtonClickRecorder.click(_:))
        }
        // An event names its window by number, which the alert's panel only has once ordered in.
        alert.window.orderFront(nil)
        defer { alert.window.orderOut(nil) }
        #expect(alert.window.windowNumber > 0)
        func escape() -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: alert.window.windowNumber,
                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 0x35)
        }
        let monitor = try #require(AlertKeys.cancelOnEscape(alert, cancel: alert.buttons[1]))
        NSApplication.shared.sendEvent(try #require(escape()))
        NSEvent.removeMonitor(monitor)
        #expect(recorder.clicked == [UIStrings.cancel], "Escape is Cancel, never Remove")
        NSApplication.shared.sendEvent(try #require(escape()))
        #expect(recorder.clicked == [UIStrings.cancel], "Cancel's Return replaced its derived Escape: the monitor is the only Escape route")
    }

    @Test("a handled Escape stops at the monitor: it never reaches the alert window, and does once the monitor is removed (r1 m-1)")
    func handledEscapeStopsAtTheMonitor() throws {
        _ = NSApplication.shared
        let alert = MainWindowController.makeRemoveAlert(for: Self.record)
        let reached = KeyDownRecorderView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        alert.accessoryView = reached
        alert.layout()
        let recorder = ButtonClickRecorder()
        for button in alert.buttons {
            button.target = recorder
            button.action = #selector(ButtonClickRecorder.click(_:))
        }
        // Local monitors do not run in install order (measured offline on macOS 27.2: either of two
        // runs first), so a second monitor cannot tell whether this one stopped the event. The key
        // window's first responder can: past the monitors, a key event goes to the key window only.
        alert.window.makeKeyAndOrderFront(nil)
        defer { alert.window.orderOut(nil) }
        #expect(alert.window.makeFirstResponder(reached))
        var monitor = AlertKeys.cancelOnEscape(alert, cancel: alert.buttons[1])
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        #expect(monitor != nil)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: alert.window.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 0x35))
        NSApplication.shared.sendEvent(escape)
        #expect(recorder.clicked == [UIStrings.cancel])
        #expect(reached.keyCodes.isEmpty, "the monitor handled the Escape and returned nil: it went no further")
        if let installed = monitor {
            NSEvent.removeMonitor(installed)
            monitor = nil
        }
        NSApplication.shared.sendEvent(escape)
        #expect(reached.keyCodes == [0x35], "without the monitor the same Escape reaches the window, so the check above is live")
        #expect(recorder.clicked == [UIStrings.cancel], "and Cancel is not clicked again")
    }

    @Test("the sheet path: the Escape monitor installed once on Cancel and removed in the callback; Remove is still the first-button response")
    func removeHostSourceShape() throws {
        let code = removeAlertCodeOnly(try removeAlertSource("App/UI/Main/MainWindowController.swift"))
        #expect(removeAlertOccurrences(of: "cancelOnEscape(", in: code) == 1)
        #expect(removeAlertOccurrences(of: "removeMonitor(", in: code) == 1)
        #expect(removeAlertOccurrences(of: ".alertFirstButtonReturn", in: code) == 1)
        #expect(code.contains("let alert = Self.makeRemoveAlert(for: record) "
                              + "let escape = AlertKeys.cancelOnEscape(alert, cancel: alert.buttons[1]) "
                              + "alert.beginSheetModal(for: window) { [weak self] response in "
                              + "if let escape { NSEvent.removeMonitor(escape) } "
                              + "guard response == .alertFirstButtonReturn, let self else { return }"),
                "built by makeRemoveAlert, the monitor on Cancel (the second button), removed before the response is read")
        #expect(removeAlertOccurrences(of: "keyEquivalent", in: code) == 2, "Remove's cleared key and Cancel's Return")
        #expect(code.contains("remove.keyEquivalent = \"\""))
        #expect(code.contains("cancel.keyEquivalent = \"\\r\""))
    }

    @Test("AlertKeys is the App's one key-down monitor and clicks the button it is given, not the first")
    func alertKeysIsTheOneMonitor() throws {
        let helper = removeAlertCodeOnly(try removeAlertSource("App/UI/Style/AlertKeys.swift"))
        #expect(helper.contains("cancel.performClick(nil)"))
        #expect(!helper.contains("buttons.first") && !helper.contains("buttons[0]"))
        #expect(removeAlertOccurrences(of: "cancel.performClick(nil) return nil", in: helper) == 1, "a handled Escape stops there (r1 m-1)")
        #expect(removeAlertOccurrences(of: "return event", in: helper) == 1, "only the guard passes an event on")
        var monitors: [String: Int] = [:]
        var calls: [String: Int] = [:]
        var scanned = 0
        for directory in ["App/Macdows", "App/UI", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
            let root = removeAlertRepoRoot().appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(atPath: root.path))
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                scanned += 1
                let code = removeAlertCodeOnly(try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8))
                let name = (entry as NSString).lastPathComponent
                if case let n = removeAlertOccurrences(of: "addLocalMonitorForEvents", in: code), n > 0 { monitors[name] = n }
                if case let n = removeAlertOccurrences(of: "AlertKeys.cancelOnEscape(", in: code), n > 0 { calls[name] = n }
            }
        }
        #expect(scanned > 20)
        #expect(monitors == ["AlertKeys.swift": 1])
        #expect(calls == ["SettingsWindowController.swift": 1, "MainWindowController.swift": 1], "the Reset and Remove alerts")
    }
}
