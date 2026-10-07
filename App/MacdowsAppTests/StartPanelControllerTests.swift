import AppKit
import Foundation
import MacdowsCore
import Testing

// ADR-0025 §3.1 items 9 and 7, offline. The panel is built and rendered in the test process, never
// made key (an xctest process cannot own a key window): what needs a key window -- Esc and ⌘W while
// typing, focus loss, the Dock click toggle -- is the `.app` probe's and the in-person batch's.

@MainActor
private final class PanelSender: LaunchSending {
    var calls: [(program: String, arguments: String?)] = []

    func launchProgram(_ program: String, arguments: String?) {
        calls.append((program, arguments))
    }
}

@MainActor
private final class PanelClock: ReconnectClock {
    final class Ticket: ReconnectClockTicket {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        Ticket()
    }
}

@MainActor
@Suite("StartPanelController (ADR-0025 §3.1 item 9)", .serialized)
struct StartPanelControllerTests {
    static let host = HostID()

    static func preferences() -> StartPanelPreferences {
        let suite = "dev.haru.macdows.tests.startpanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StartPanelPreferences(defaults: defaults, trustReader: { false }, trustPrompter: {}, opener: { _ in }, observesActivation: false)
    }

    fileprivate static func controller(state: ReconnectDriver.State? = .live, hasSession: Bool = true,
                           store: LaunchItemStore = LaunchItemStore(fileURL: nil)) -> (StartPanelController, PanelSender) {
        let launcher = AppLauncher(timeout: StartPanelPolicy.execTimeout, clock: PanelClock())
        let controller = StartPanelController(items: store, launcher: launcher, preferences: preferences())
        let sender = PanelSender()
        controller.reading = { .init(hasSession: hasSession, state: state, host: Self.host, hostTitle: "workstation.example") }
        launcher.sender = { sender }
        return (controller, sender)
    }

    /// Every label text under `view`.
    static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
                found.append(field.stringValue)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: - Construction (Q7: a changed policy value is red here)

    @Test("the panel is built from StartPanelPolicy: non-activating borderless panel, level, spaces, key, no hide on deactivate")
    func construction() throws {
        let (controller, _) = Self.controller()
        let panel = controller.panel
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.titled) && !panel.styleMask.contains(.resizable))
        #expect(panel.level == StartPanelPolicy.level)
        #expect(panel.level == .statusBar, "probe L1")
        #expect(panel.collectionBehavior == StartPanelPolicy.collectionBehavior)
        #expect(panel.collectionBehavior.rawValue == 0x10a, "probe L2: [.fullScreenAuxiliary, .moveToActiveSpace, .transient]")
        #expect(panel.hidesOnDeactivate == StartPanelPolicy.hidesOnDeactivate)
        #expect(!panel.hidesOnDeactivate, "probe K4")
        #expect(panel.canBecomeKey == StartPanelPolicy.overridesCanBecomeKey)
        #expect(panel.canBecomeKey, "probe K1: the class overrides it")
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear && panel.hasShadow)
        #expect(!panel.isReleasedWhenClosed)
        #expect(panel.delegate === controller)
    }

    @Test("the policy's other values: Dock sender required, gaps, timeout, limits, sizes, graces")
    func policyValues() {
        #expect(StartPanelPolicy.requiresDockSender)
        #expect(StartPanelPolicy.dockGap == 8 && StartPanelPolicy.dockGap == DockAnchorGeometry.dockGap)
        #expect(StartPanelPolicy.execTimeout == .seconds(8))
        #expect(StartPanelPolicy.recentLimit == 8)
        #expect(StartPanelPolicy.dockMenuPinnedLimit == 3 && StartPanelPolicy.dockMenuRecentLimit == 5 && StartPanelPolicy.dockMenuTitleLimit == 40)
        #expect(StartPanelPolicy.width == 320 && StartPanelPolicy.rowHeight == 28 && StartPanelPolicy.cornerRadius == 16)
        #expect(StartPanelPolicy.reopenToggleGrace == 0.5 && StartPanelPolicy.keyLossGraceAfterShow == 0.3)
        #expect(StartPanelPolicy.fadeInDuration == 0.12)
    }

    // MARK: - States

    @Test("panel states: live / connecting / reconnecting; no session and a give-up have no panel (§10-1 (b))")
    func phases() {
        func phase(_ hasSession: Bool, _ state: ReconnectDriver.State?) -> StartPanelController.Phase? {
            StartPanelController.phase(for: .init(hasSession: hasSession, state: state, host: nil, hostTitle: ""))
        }
        #expect(phase(true, .live) == .live)
        #expect(phase(true, nil) == .connecting && phase(true, .idle) == .connecting)
        #expect(phase(true, .waiting(attempt: 0, delay: .seconds(1))) == .reconnecting && phase(true, .reconnecting(attempt: 2)) == .reconnecting)
        #expect(phase(true, .gaveUp(.policy(.attemptsExhausted))) == nil)
        #expect(phase(false, .live) == nil && phase(false, nil) == nil)
    }

    @Test("not live: every launch row and the Run field are disabled, and the header says why")
    func nonLiveRowsAreDisabledWithText() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: "calc.exe", arguments: ""), displayName: "calc.exe", for: Self.host, at: Date(timeIntervalSince1970: 0))
        for (state, status) in [(ReconnectDriver.State?.none, "Connecting…"), (.idle, "Connecting…"),
                                (.waiting(attempt: 0, delay: .seconds(1)), "Reconnecting. You can launch programs once connected."),
                                (.reconnecting(attempt: 1), "Reconnecting. You can launch programs once connected.")] {
            let (controller, sender) = Self.controller(state: state, store: store)
            controller.render()
            #expect(controller.phase != .live)
            #expect(controller.itemRows.count == 1 && controller.itemRows.allSatisfy { !$0.view.isEnabled })
            #expect(!controller.runField.isEnabled)
            #expect(controller.openRow.isEnabled, "Open Macdows stays usable")
            let texts = Self.texts(in: try #require(controller.panel.contentView))
            #expect(texts.contains(status), "\(texts)")
            #expect(texts.contains("workstation.example"))
            // A press on a disabled row sends nothing (the gate would refuse it anyway).
            controller.launch(controller.itemRows[0].row)
            #expect(sender.calls.isEmpty)
        }
        let (live, _) = Self.controller(state: .live, store: store)
        live.render()
        #expect(live.itemRows.allSatisfy { $0.view.isEnabled } && live.runField.isEnabled)
        #expect(Self.texts(in: try #require(live.panel.contentView)).contains("Connected"))
    }

    @Test("empty lists: the Recent header and the empty note; pinned and recent sections when there are programs")
    func sections() throws {
        let (empty, _) = Self.controller()
        empty.render()
        let texts = Self.texts(in: try #require(empty.panel.contentView))
        #expect(texts.contains("Recent") && texts.contains("Programs you run appear here.") && !texts.contains("Pinned"))
        #expect(texts.contains("Open Macdows"))

        let store = LaunchItemStore(fileURL: nil)
        for name in ["a.exe", "b.exe"] {
            store.recordLaunch(RunCommand(program: name, arguments: ""), displayName: name, for: Self.host, at: Date(timeIntervalSince1970: 0))
        }
        store.pin(try #require(store.items(for: Self.host).recent.first), for: Self.host, at: Date(timeIntervalSince1970: 0))
        let (filled, _) = Self.controller(store: store)
        filled.render()
        #expect(filled.itemRows.map(\.row.section) == [.pinned, .recent])
        let shown = Self.texts(in: try #require(filled.panel.contentView))
        #expect(shown.contains("Pinned") && shown.contains("Recent") && !shown.contains("Programs you run appear here."))
    }

    // MARK: - Launch outcomes (Q1 / Q2)

    @Test("only S_OK writes Recent; a failure while the panel is closed is shown once at the next open")
    func onlySuccessWritesRecent() throws {
        let store = LaunchItemStore(fileURL: nil)
        let (controller, sender) = Self.controller(store: store)
        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        #expect(sender.calls.map(\.program) == ["missing.exe"])
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "MISSING.EXE")
        #expect(store.items(for: Self.host).recent.isEmpty, "a failure writes nothing")
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "missing.exe"))

        controller.runField.stringValue = #"C:\Windows\System32\notepad.exe"#
        controller.submitRunField()
        controller.handleExecResult(execResult: 0, rawResult: 0, program: #"C:\Windows\System32\notepad.exe"#)
        #expect(store.items(for: Self.host).recent.map(\.displayName) == ["notepad.exe"])
        #expect(controller.runField.stringValue.isEmpty, "a successful Run field launch clears the field")

        controller.show(anchor: .fallback)
        defer { controller.close(.dismissed) }
        #expect(controller.shownLastFailure == .init(reasonKey: "sp_r_nf", programName: "missing.exe"))
        #expect(controller.lastFailures[Self.host] == nil, "shown once")
        let texts = Self.texts(in: try #require(controller.panel.contentView))
        #expect(texts.contains("The last launch did not succeed: The program was not found on the remote PC. Check the path."))
    }

    @Test("an unrequested result changes no row: the pending row stays pending, nothing is recorded")
    func unrequestedResultLeavesRowsAlone() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: "calc.exe", arguments: ""), displayName: "calc.exe", for: Self.host, at: Date(timeIntervalSince1970: 0))
        let (controller, sender) = Self.controller(store: store)
        controller.render()
        controller.launch(controller.itemRows[0].row)
        #expect(sender.calls.count == 1)
        #expect(controller.itemRows[0].view.isPending)
        controller.launch(controller.itemRows[0].row)
        #expect(sender.calls.count == 1, "a pending row pressed again sends nothing")
        controller.handleExecResult(execResult: 0, rawResult: 0, program: #"C:\Windows\System32\winver.exe"#)
        controller.render()
        #expect(controller.itemRows[0].view.isPending)
        #expect(controller.launcher.unmatchedResults == 1)
        #expect(controller.lastFailures.isEmpty)
        #expect(store.items(for: Self.host).recent.count == 1 && store.items(for: Self.host).recent[0].date == Date(timeIntervalSince1970: 0))
    }

    @Test("the session ending drops pending launches and closes the panel")
    func sessionEndDropsPending() {
        var hasSession = true
        let (controller, _) = Self.controller()
        controller.reading = { .init(hasSession: hasSession, state: .live, host: Self.host, hostTitle: "h") }
        controller.runField.stringValue = "calc.exe"
        controller.submitRunField()
        #expect(controller.launcher.pendingRequests.count == 1)
        controller.show(anchor: .fallback)
        #expect(controller.isShown)
        hasSession = false
        controller.refresh()
        #expect(!controller.isShown)
        #expect(controller.launcher.pendingRequests.isEmpty)
    }

    @Test("Esc / ⌘. and ⌘W close the panel; Open Macdows closes it and hands over")
    func dismissals() {
        let (controller, _) = Self.controller()
        var opened = 0
        controller.onOpenMacdows = { opened += 1 }
        controller.show(anchor: .fallback)
        controller.panel.cancelOperation(nil)
        #expect(!controller.isShown && !controller.panel.isVisible)
        controller.show(anchor: .fallback)
        controller.panel.closeKeyWindow(nil)
        #expect(!controller.isShown)
        controller.show(anchor: .fallback)
        controller.openMacdows()
        #expect(!controller.isShown && opened == 1)
        let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
        let plainW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
        #expect(commandW.map(StartPanelWindow.isDismissKeyEquivalent) == true)
        #expect(plainW.map(StartPanelWindow.isDismissKeyEquivalent) == false)
    }

    @Test("a reopen whose sender cannot be read is not the Dock's: the panel does not take it (R-1′)")
    func reopenWithoutDockSenderFallsThrough() {
        let (controller, _) = Self.controller()
        #expect(!controller.toggleForDockReopen())
        #expect(!controller.isShown)
    }

    @Test("no panel without a session, whatever opens it")
    func noPanelWithoutSession() {
        let (controller, _) = Self.controller(hasSession: false)
        controller.showFromStatusItem(buttonFrame: CGRect(x: 100, y: 800, width: 24, height: 24))
        #expect(!controller.isShown)
    }

    @Test("a refresh re-renders in place: the Run field and Open Macdows never leave their containers (no focus taken)")
    func refreshKeepsTheRunFieldInPlace() {
        var state: ReconnectDriver.State? = .idle
        let (controller, _) = Self.controller()
        controller.reading = { .init(hasSession: true, state: state, host: Self.host, hostTitle: "h") }
        controller.render()
        let field = controller.runField.superview
        let open = controller.openRow.superview
        #expect(field != nil && open != nil)
        state = .live
        controller.render()
        state = .reconnecting(attempt: 0)
        controller.render()
        #expect(controller.runField.superview === field && controller.openRow.superview === open)
    }

    // MARK: - Ruling R-a1-1 (i)

    @Test("the Run field drops U+0000 as the text changes")
    func runFieldStripsNUL() {
        let (controller, _) = Self.controller()
        controller.runField.stringValue = "note\u{0}pad.exe \u{0}a"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.runField))
        #expect(controller.runField.stringValue == "notepad.exe a")
        #expect(StartPanelController.strippingNUL("\u{0}") == "")
    }
}

@MainActor
@Suite("StartPanelPreferences (ADR-0025 R-2, §10-6 / §10-7)", .serialized)
struct StartPanelPreferencesTests {
    @Test("one key, false by default; switching on prompts once; declining keeps it on with the hint; off prompts nothing")
    func preference() {
        let suite = "dev.haru.macdows.tests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var trusted = false
        var prompts = 0
        var opened: [URL] = []
        let preferences = StartPanelPreferences(defaults: defaults, trustReader: { trusted }, trustPrompter: { prompts += 1 },
                                                opener: { opened.append($0) }, observesActivation: false)
        #expect(StartPanelPreferences.preciseDockPositioningKey == "startPanel.preciseDockPositioning")
        #expect(!preferences.preciseDockPositioning && !preferences.showsAuthorizationHint)
        preferences.setPreciseDockPositioning(true)
        #expect(prompts == 1 && defaults.bool(forKey: StartPanelPreferences.preciseDockPositioningKey))
        #expect(preferences.preciseDockPositioning && preferences.showsAuthorizationHint, "declined: still on, the hint shows")
        preferences.refreshTrust()
        preferences.setPreciseDockPositioning(true)
        #expect(prompts == 1, "never asked again while it stays on")
        trusted = true
        preferences.refreshTrust()
        #expect(!preferences.showsAuthorizationHint)
        preferences.setPreciseDockPositioning(false)
        #expect(prompts == 1 && !defaults.bool(forKey: StartPanelPreferences.preciseDockPositioningKey))
        preferences.openAccessibilityPrivacy()
        #expect(opened == [URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!])
        let reloaded = StartPanelPreferences(defaults: defaults, trustReader: { false }, trustPrompter: {}, opener: { _ in }, observesActivation: false)
        #expect(!reloaded.preciseDockPositioning)
    }
}

@MainActor
@Suite("DockAnchorLocator's pure parts (ADR-0025 §1.3)")
struct DockAnchorLocatorTests {
    @Test("the sender pid: four bytes read as SInt32 (probe R1: type 'magn'); anything else is nil")
    func senderPID() {
        var pid: Int32 = 4242
        let magn = NSAppleEventDescriptor(descriptorType: 0x6D61_676E, bytes: &pid, length: 4)!
        #expect(DockAnchorLocator.senderPID(from: magn) == 4242)
        var zero: Int32 = 0
        #expect(DockAnchorLocator.senderPID(from: NSAppleEventDescriptor(descriptorType: 0x6D61_676E, bytes: &zero, length: 4)!) == nil)
        var wide: Int64 = 4242
        #expect(DockAnchorLocator.senderPID(from: NSAppleEventDescriptor(descriptorType: 0x6D61_676E, bytes: &wide, length: 8)!) == nil)
        #expect(DockAnchorLocator.dockBundleIdentifier == "com.apple.dock")
    }

    @Test("the Dock preference's orientation: left / right, and unset (or anything else) is bottom (probe A3)")
    func orientation() {
        #expect(DockAnchorLocator.dockEdge(fromOrientation: "left") == .left)
        #expect(DockAnchorLocator.dockEdge(fromOrientation: "right") == .right)
        #expect(DockAnchorLocator.dockEdge(fromOrientation: "bottom") == .bottom)
        #expect(DockAnchorLocator.dockEdge(fromOrientation: nil) == .bottom)
    }

    @Test("the Dock menu's pointer counts as on the Dock only inside the screen's Dock strip")
    func dockBand() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bottom = AnchorScreen(frame: frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
        #expect(DockAnchorLocator.isOnDockBand(CGPoint(x: 720, y: 30), screens: [bottom]))
        #expect(!DockAnchorLocator.isOnDockBand(CGPoint(x: 720, y: 300), screens: [bottom]))
        let right = AnchorScreen(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1370, height: 875))
        #expect(DockAnchorLocator.isOnDockBand(CGPoint(x: 1400, y: 300), screens: [right]))
        let hidden = AnchorScreen(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        #expect(!DockAnchorLocator.isOnDockBand(CGPoint(x: 720, y: 2), screens: [hidden]), "no strip: the fallback")
    }
}
