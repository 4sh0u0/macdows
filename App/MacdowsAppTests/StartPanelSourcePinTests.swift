import Foundation
import Testing

// ADR-0025 §3.2 S-1…S-5 and the probe-fold's Accessibility rule, as source. Counted by call shape on
// comment-stripped code (`//` and `///` lines cut), never by bare name.

private func pinRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func pinSource(_ relative: String) throws -> String {
    try String(contentsOf: pinRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded.
private func pinCode(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex..<marker.lowerBound]
        }
        .joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func pinCount(_ needle: String, _ haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Every Swift product source under `App/` (tests and the generated project excluded), code only.
private func productSources() throws -> [(path: String, code: String)] {
    var files: [(String, String)] = []
    for directory in ["App/Macdows", "App/UI", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
        let root = pinRoot().appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
        for case let entry as String in walker where entry.hasSuffix(".swift") {
            files.append(("\(directory)/\(entry)", pinCode(try pinSource("\(directory)/\(entry)"))))
        }
    }
    return files.sorted { $0.0 < $1.0 }
}

/// The start panel's launch path: the launcher and every StartPanel file.
private func launchPathSources() throws -> [(path: String, code: String)] {
    try productSources().filter { $0.path == "App/SessionControl/AppLauncher.swift" || $0.path.hasPrefix("App/UI/StartPanel/") }
}

/// The text of the braces that open at the first `{` after `start` (nested braces matched).
private func braced(_ code: String, from start: String.Index) -> Substring? {
    guard let open = code[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < code.endIndex {
        if code[index] == "{" { depth += 1 }
        if code[index] == "}" {
            depth -= 1
            if depth == 0 { return code[open...index] }
        }
        index = code.index(after: index)
    }
    return nil
}

@Suite("ADR-0025 §3.2 — the start panel's source pins (S-1…S-5, the Accessibility rule)")
struct StartPanelSourcePinTests {

    @Test("the walk finds the launch path: the launcher and eight StartPanel files")
    func theWalkFindsTheFiles() throws {
        let paths = try launchPathSources().map(\.path)
        #expect(paths.count == 9, "\(paths)")
        #expect(paths.contains("App/UI/StartPanel/StartPanelController.swift") && paths.contains("App/SessionControl/AppLauncher.swift"))
    }

    /// S-1 (adr/0014 §3): launching never activates a window; the server activates the one it creates.
    @Test("S-1: the launch path never calls activateWindow( or localActivate(")
    func s1NoActivation() throws {
        for file in try launchPathSources() {
            for shape in ["activateWindow(", "localActivate(", "focusAuthority"] {
                #expect(pinCount(shape, file.code) == 0, "\(file.path): \(shape)")
            }
        }
    }

    /// S-2: the program and the arguments never reach a log. The needle: every interpolation inside a
    /// logging call (`logger.` + a level, `print(`, `NSLog(`, `os_log(`) in the launch path, and in
    /// the registry's ExecResult branch, names none of the variables that hold them.
    @Test("S-2: no log call in the launch path or the registry's ExecResult branch interpolates a program or arguments")
    func s2NoCommandInLogs() throws {
        let banned = ["program", "arguments", "command", "text", "stringvalue", "row", "item"]
        var logCalls = 0
        for file in try launchPathSources() {
            for opener in ["logger.notice(", "logger.info(", "logger.debug(", "logger.error(", "logger.warning(", "logger.fault(",
                           "print(", "NSLog(", "os_log("] {
                for piece in file.code.components(separatedBy: opener).dropFirst() {
                    logCalls += 1
                    let statement = piece.components(separatedBy: "\")").first ?? ""
                    for interpolation in statement.components(separatedBy: "\\(").dropFirst() {
                        let expression = interpolation.prefix { $0 != "," && $0 != ")" }
                        for name in banned {
                            #expect(!expression.lowercased().contains(name), "\(file.path): a log interpolates \(expression)")
                        }
                    }
                }
            }
        }
        #expect(logCalls == 4, "the launcher's four lines: sent, result, unmatched, timeout (\(logCalls))")
        let registry = pinCode(try pinSource("App/RemoteWindowRendering/RemoteWindowRegistry.swift"))
        let branch = try #require(registry.range(of: "case .execResult:"))
        let next = try #require(registry.range(of: "case .windowIcon, .handshakeFlags:", range: branch.upperBound..<registry.endIndex))
        let body = registry[branch.upperBound..<next.lowerBound]
        #expect(!body.contains("logger") && !body.contains("print(") && !body.contains("NSLog("))
    }

    /// S-3: the bridge's two frozen lines are untouched (BridgeExecWitnessPinTests holds their call
    /// shapes; this is the plain literal check from the App side).
    @Test("S-3: CRSession.mm's ServerExecuteResult and outbound-execute lines are literally unchanged")
    func s3FrozenLines() throws {
        let bridge = try pinSource("App/CRBridge/CRSession.mm")
        #expect(pinCount("WLog_INFO(TAG, \"ServerExecuteResult flags=%u execResult=%u rawResult=%u\", (unsigned)execResult->flags, "
                         + "(unsigned)execResult->execResult, (unsigned)execResult->rawResult);", bridge) == 1)
        #expect(pinCount("WLog_INFO(TAG, \"outbound execute sent rc=%u\", (unsigned)rc);", bridge) == 1)
    }

    /// S-4: one forward, out of the break case, and nothing else in the registry reads the result.
    @Test("S-4: the registry's .execResult is a single forward and no longer falls into the break case")
    func s4SingleForward() throws {
        let registry = pinCode(try pinSource("App/RemoteWindowRendering/RemoteWindowRegistry.swift"))
        #expect(pinCount("case .execResult: onExecResult?(event.execResult, event.rawResult, event.program) "
                         + "case .windowIcon, .handshakeFlags: break", registry) == 1)
        #expect(pinCount("onExecResult?(", registry) == 1)
        #expect(pinCount("case .execResult:", registry) == 1)
        // A shared case list spells `.execResult, .x` or `.x, .execResult`; the forward's own
        // `event.execResult, event.rawResult` is neither.
        #expect(pinCount(".execResult, .", registry) == 0 && pinCount(", .execResult", registry) == 0, "not in a shared case list")
        #expect(pinCount("var onExecResult: ((_ execResult: UInt32, _ rawResult: UInt32, _ program: String) -> Void)?", registry) == 1)
        let delegate = pinCode(try pinSource("App/Macdows/AppDelegate.swift"))
        #expect(pinCount("newRegistry.onExecResult = { [weak self] execResult, rawResult, program in "
                         + "self?.startPanel.handleExecResult(execResult: execResult, rawResult: rawResult, program: program) }", delegate) == 1)
        #expect(pinCount(".onExecResult =", delegate) == 1)
    }

    /// S-5: the unattended knob's call is untouched and the product path has its own; the App delegate
    /// keeps its two `@objc` methods (the Dock menu's actions live in DockMenuController).
    @Test("S-5: executeProgram( stays the knob's single call; launchProgram( is the launcher's; @objc stays 2 in the App delegate")
    func s5KnobUntouched() throws {
        let delegate = pinCode(try pinSource("App/Macdows/AppDelegate.swift"))
        #expect(pinCount("session.executeProgram(extraExecProgram)", delegate) == 1)
        #expect(pinCount("executeProgram(", delegate) == 1)
        #expect(pinCount("launchProgram(", delegate) == 0)
        #expect(pinCount("@objc", delegate) == 2)
        let launcher = pinCode(try pinSource("App/SessionControl/AppLauncher.swift"))
        #expect(pinCount("session.launchProgram(command.program, arguments: command.arguments.isEmpty ? nil : command.arguments)", launcher) == 1)
        #expect(pinCount("executeProgram(", launcher) == 0)
        var launchCalls: [String: Int] = [:]
        for file in try productSources() where pinCount(".launchProgram(", file.code) > 0 {
            launchCalls[file.path] = pinCount(".launchProgram(", file.code)
        }
        #expect(launchCalls == ["App/SessionControl/AppLauncher.swift": 1], "\(launchCalls)")
        let menu = pinCode(try pinSource("App/UI/StartPanel/DockMenuController.swift"))
        #expect(pinCount("@objc func", menu) == 3)
    }

    /// Probe A2, a load-bearing rule: an Accessibility ELEMENT call made without access makes the
    /// system record the App in the Accessibility list. Every such call in the App is in one function
    /// of DockAnchorLocator.swift whose first statement is the trust check -- so an untrusted App
    /// makes none -- and the prompting call is in StartPanelPreferences only, behind the user's switch.
    @Test("AX: every Accessibility element call is behind AXIsProcessTrusted() in DockAnchorLocator's one function; the prompt only in the preference")
    func accessibilityDiscipline() throws {
        let elementCalls = ["AXUIElementCreateApplication(", "AXUIElementCreateSystemWide(", "AXUIElementCopyAttributeValue(",
                            "AXUIElementCopyAttributeValues(", "AXUIElementCopyAttributeNames(", "AXUIElementSetAttributeValue(",
                            "AXUIElementPerformAction(", "AXUIElementCopyElementAtPosition(", "AXObserverCreate("]
        var found: [String: Int] = [:]
        var prompts: [String: Int] = [:]
        for file in try productSources() {
            let calls = elementCalls.reduce(0) { $0 + pinCount($1, file.code) }
            if calls > 0 { found[file.path] = calls }
            let prompt = pinCount("AXIsProcessTrustedWithOptions(", file.code)
            if prompt > 0 { prompts[file.path] = prompt }
        }
        #expect(Set(found.keys) == ["App/UI/StartPanel/DockAnchorLocator.swift"], "\(found)")
        #expect(prompts == ["App/UI/StartPanel/StartPanelPreferences.swift": 1], "\(prompts)")

        let locator = pinCode(try pinSource("App/UI/StartPanel/DockAnchorLocator.swift"))
        let start = try #require(locator.range(of: "private static func copyDockIconFrame(bundleURL: URL, title: String) -> CGRect? {"))
        let body = try #require(braced(locator, from: start.lowerBound))
        #expect(body.hasPrefix("{ guard AXIsProcessTrusted() else { return nil }"), "the trust check is the first statement")
        let total = elementCalls.reduce(0) { $0 + pinCount($1, locator) }
        let inside = elementCalls.reduce(0) { $0 + pinCount($1, String(body)) }
        #expect(total == inside && total >= 2, "every element call is in that body (\(inside) of \(total))")
        #expect(pinCount("copyDockIconFrame(", locator) == 2, "declared once, called once")
        #expect(locator.contains("guard preferences.preciseDockPositioning else { return nil } return Self.copyDockIconFrame("),
                "only while the setting is on")

        let preferences = pinCode(try pinSource("App/UI/StartPanel/StartPanelPreferences.swift"))
        #expect(pinCount("trustPrompter()", preferences) == 1)
        #expect(preferences.contains("if on && !wasOn { trustPrompter() }"), "asked once, when the user switches it on")
    }

    @Test("R-1′ sender gate: the reopen's sender pid from keySenderPIDAttr, compared with the Dock process's")
    func senderGateShape() throws {
        let locator = pinCode(try pinSource("App/UI/StartPanel/DockAnchorLocator.swift"))
        #expect(locator.contains("event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))"))
        #expect(locator.contains("NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier) .contains { $0.processIdentifier == pid }"))
        let controller = pinCode(try pinSource("App/UI/StartPanel/StartPanelController.swift"))
        #expect(controller.contains("let fromDock = locator.currentEventIsFromDock() if StartPanelPolicy.requiresDockSender && !fromDock { return false }"))
        #expect(controller.contains("panel.makeKeyAndOrderFront(nil)"), "probe K2: the call that makes the panel key")
        #expect(pinCount("orderFront(nil)", controller) == 0 && pinCount("orderFrontRegardless(", controller) == 0)
    }

    @Test("§10-7: the start-panel preference is the App's only UserDefaults user; NSScreen is still read in one file")
    func onePreferenceStore() throws {
        var defaults: [String] = []
        var screens: [String] = []
        for file in try productSources() {
            if file.code.contains("UserDefaults") { defaults.append(file.path) }
            if file.code.contains("NSScreen.screens") { screens.append(file.path) }
        }
        #expect(defaults == ["App/UI/StartPanel/StartPanelPreferences.swift"])
        #expect(screens == ["App/RemoteWindowRendering/DisplayTopologyProvider.swift"], "adr/0015 §5.A.5")
    }

    @Test("the App delegate's session end reaches the panel through the presence hook, and the teardown is untouched")
    func panelClosesOnEverySessionEnd() throws {
        let delegate = pinCode(try pinSource("App/Macdows/AppDelegate.swift"))
        #expect(delegate.contains("private func sessionPresenceChanged(_ present: Bool) { startPanel.refresh() guard !present, !isDraining else { return }"))
        #expect(delegate.contains("statusItemController.refresh() startPanel.refresh() if case .gaveUp = state { tearDownSession() }"))
        #expect(pinCount("startPanel.refresh()", delegate) == 2)
        #expect(pinCount("startPanel", delegate.components(separatedBy: "private func tearDownSession()").last?
            .components(separatedBy: "private func applyShell(").first ?? "") == 0)
    }
}
