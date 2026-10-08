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

/// Gate r1 m-1: keeps each scheduled body so a test can make the launch timeout happen.
@MainActor
private final class PanelClock: ReconnectClock {
    final class Ticket: ReconnectClockTicket {
        var cancelled = false
        let body: @MainActor () -> Void

        init(_ body: @escaping @MainActor () -> Void) {
            self.body = body
        }

        func cancel() { cancelled = true }
    }

    var tickets: [Ticket] = []

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        let ticket = Ticket(body)
        tickets.append(ticket)
        return ticket
    }

    /// Runs every body still pending (each at most once).
    func fireAll() {
        for ticket in tickets where !ticket.cancelled {
            ticket.cancelled = true
            ticket.body()
        }
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
                                       store: LaunchItemStore = LaunchItemStore(fileURL: nil),
                                       clock: PanelClock = PanelClock()) -> (StartPanelController, PanelSender) {
        let launcher = AppLauncher(timeout: StartPanelPolicy.execTimeout, clock: clock)
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
        // a-1b (R-7, ruling ㋱): a launch sent for the host supersedes its waiting failure, so the
        // successful launch comes first and the failure is the last thing before the open.
        controller.runField.stringValue = #"C:\Windows\System32\notepad.exe"#
        controller.submitRunField()
        controller.handleExecResult(execResult: 0, rawResult: 0, program: #"C:\Windows\System32\notepad.exe"#)
        #expect(store.items(for: Self.host).recent.map(\.displayName) == ["notepad.exe"])
        #expect(controller.runField.stringValue.isEmpty, "a successful Run field launch clears the field")

        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        #expect(sender.calls.map(\.program) == [#"C:\Windows\System32\notepad.exe"#, "missing.exe"])
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "MISSING.EXE")
        #expect(store.items(for: Self.host).recent.map(\.displayName) == ["notepad.exe"], "a failure writes nothing")
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "missing.exe"))

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

    // MARK: - Gate r1 folds

    private static func returnKey() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    @Test("gate r1 I-2: a row is a VoiceOver button; a VoiceOver press or Return launches it once; a disabled row refuses")
    func rowAccessibilityAndPress() throws {
        let store = LaunchItemStore(fileURL: nil)
        for (offset, name) in ["a.exe", "b.exe"].enumerated() {
            store.recordLaunch(RunCommand(program: name, arguments: ""), displayName: name, for: Self.host,
                               at: Date(timeIntervalSince1970: TimeInterval(offset)))
        }
        let (controller, sender) = Self.controller(store: store)
        controller.render()
        let first = try #require(controller.itemRows.first?.view)
        #expect(first.isAccessibilityElement())
        #expect(first.accessibilityRole() == .button)
        #expect(first.isAccessibilityEnabled())
        #expect(first.accessibilityLabel() == "b.exe")
        #expect(first.accessibilityPerformPress())
        #expect(sender.calls.map(\.program) == ["b.exe"])
        // The press re-rendered the rows: look the other one up again, then press it with Return.
        let second = try #require(controller.itemRows.first { $0.row.item.program == "a.exe" }?.view)
        #expect(controller.handleRowKey(try Self.returnKey(), from: second))
        #expect(sender.calls.map(\.program) == ["b.exe", "a.exe"])

        let (connecting, idleSender) = Self.controller(state: .idle, store: store)
        connecting.render()
        let disabled = try #require(connecting.itemRows.first?.view)
        #expect(!disabled.isAccessibilityEnabled())
        #expect(!disabled.accessibilityPerformPress())
        #expect(idleSender.calls.isEmpty)
    }

    @Test("gate r1 I-2: the row menus -- Pinned: Unpin; Recent: Pin, separator, Remove from Recent")
    func rowMenus() throws {
        let store = LaunchItemStore(fileURL: nil)
        for name in ["a.exe", "b.exe"] {
            store.recordLaunch(RunCommand(program: name, arguments: ""), displayName: name, for: Self.host, at: Date(timeIntervalSince1970: 0))
        }
        store.pin(try #require(store.items(for: Self.host).recent.first { $0.program == "a.exe" }), for: Self.host, at: Date(timeIntervalSince1970: 0))
        let (controller, _) = Self.controller(store: store)
        controller.render()
        func titles(_ section: LaunchCatalog.Section) throws -> [String] {
            let view = try #require(controller.itemRows.first { $0.row.section == section }?.view)
            let menu = try #require(view.menuProvider?())
            return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
        }
        #expect(try titles(.pinned) == ["Unpin"])
        #expect(try titles(.recent) == ["Pin", "---", "Remove from Recent"])
    }

    @Test("gate r1 m-1: a timeout writes nothing; while open it is the row's and the Run field's reason; closed, it waits for the next open")
    func timeoutsAtThePanel() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: "calc.exe", arguments: ""), displayName: "calc.exe", for: Self.host, at: Date(timeIntervalSince1970: 0))
        let before = store.items(for: Self.host)
        let clock = PanelClock()
        let (controller, sender) = Self.controller(store: store, clock: clock)
        controller.announce = { _, _ in }
        controller.show(anchor: .fallback)
        let calc = try #require(controller.itemRows.first?.row)
        controller.runField.stringValue = "a.exe"
        controller.submitRunField()
        controller.launch(calc)
        #expect(sender.calls.count == 2)
        clock.fireAll()
        #expect(store.items(for: Self.host) == before, "a timeout writes no Recent")
        #expect(controller.runFieldError == "sp_r_timeout")
        #expect(controller.rowErrors[calc.item.key] == "sp_r_timeout")
        #expect(controller.lastFailures.isEmpty)
        controller.close(.dismissed)

        controller.runField.stringValue = "b.exe"
        controller.submitRunField()
        clock.fireAll()
        #expect(store.items(for: Self.host) == before)
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_timeout", programName: "b.exe"))
        controller.show(anchor: .fallback)
        defer { controller.close(.dismissed) }
        let texts = Self.texts(in: try #require(controller.panel.contentView))
        #expect(texts.contains("The last launch did not succeed: Windows did not reply. If the program doesn’t open, try again."))
    }

    @Test("gate r1 m-3 (i): the status-item anchor callback is true on a status-item open and false on its close; Dock opens never call it")
    func statusItemAnchorCallback() {
        let (controller, _) = Self.controller()
        var seen: [Bool] = []
        controller.onStatusItemAnchorChange = { seen.append($0) }
        controller.showFromStatusItem(buttonFrame: CGRect(x: 900, y: 875, width: 30, height: 25))
        #expect(seen == [true] && controller.isAnchoredToStatusItem)
        controller.close(.lostFocus)
        #expect(seen == [true, false])
        controller.show(anchor: .fallback)
        controller.close(.dismissed)
        controller.showFromDockMenu(pointer: nil)
        controller.close(.toggled)
        #expect(seen == [true, false], "Dock and Dock-menu opens leave the status item alone")
        controller.showFromStatusItem(buttonFrame: nil)
        controller.show(anchor: .fallback)
        #expect(seen == [true, false, true, false], "re-opened from elsewhere: no longer the status item's")
        controller.close(.dismissed)
        #expect(seen.count == 4)
        let (none, _) = Self.controller(hasSession: false)
        var noneSeen: [Bool] = []
        none.onStatusItemAnchorChange = { noneSeen.append($0) }
        none.showFromStatusItem(buttonFrame: nil)
        #expect(noneSeen.isEmpty, "no panel, no highlight")
    }

    @Test("gate r1 m-3 (ii): an inline error is announced on its row or the Run field and stays in the row's help; a late one is not announced")
    func inlineErrorsAreAnnounced() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: #"C:\Tools\Example.exe"#, arguments: "/open"), displayName: "Example.exe", for: Self.host,
                           at: Date(timeIntervalSince1970: 0))
        let (controller, _) = Self.controller(store: store)
        var announced: [(element: AnyObject, text: String)] = []
        controller.announce = { announced.append(($0 as AnyObject, $1)) }
        controller.show(anchor: .fallback)
        defer { controller.close(.dismissed) }
        controller.launch(try #require(controller.itemRows.first?.row))
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"c:\tools\example.exe"#)
        let reason = "The program was not found on the remote PC. Check the path."
        let row = try #require(controller.itemRows.first?.view)
        #expect(announced.count == 1)
        #expect(announced.first?.text == reason && announced.first?.element === row)
        let help = try #require(row.accessibilityHelp())
        #expect(help.contains(reason) && help.contains(#"C:\Tools\Example.exe /open"#))
        #expect(row.toolTip == #"C:\Tools\Example.exe /open"#, "the tooltip stays the command")

        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        controller.handleExecResult(execResult: 3, rawResult: 0, program: "missing.exe")
        #expect(announced.count == 2)
        #expect(announced.last?.element === controller.runField && announced.last?.text == "This program is not allowed on the remote PC.")

        controller.close(.dismissed)
        controller.runField.stringValue = "late.exe"
        controller.submitRunField()
        controller.handleExecResult(execResult: 6, rawResult: 0, program: "late.exe")
        #expect(announced.count == 2, "a late failure goes to the next open's bar, unannounced")
    }

    // MARK: - ADR-0025 R-7 (a-1b): the waiting failure, its callback and its clearing points

    private static let notFound = "The program was not found on the remote PC. Check the path."

    private static func item(_ program: String) -> LaunchItem {
        LaunchItem(displayName: program, program: program, arguments: "", date: Date(timeIntervalSince1970: 0))
    }

    /// RE-WRITTEN by the a-1 in-person fold (a-1c, owner ruling (3)): of the three sends below only the
    /// third -- the host's latest -- may leave a late failure, so the first two results now write
    /// nothing, and an equal write of the same failure can no longer happen (a result is matched to one
    /// send once). The no-change guard stays pinned by the sends over an empty table here and by C2's
    /// and C4's empty opens and ends.
    @Test("a-1b C1: a late failure calls back once per change and reads as its sentence; a write that changes nothing calls nothing")
    func lateFailureCallsBackOnChange() {
        let (controller, sender) = Self.controller()
        var changes = 0
        var seen: [String?] = []
        controller.onLastFailureChange = {
            changes += 1
            // Read INSIDE the callback, as AppDelegate's applyShell does: the table must already hold
            // the new value when the callback runs (gate r1 m-1: a willSet would hand out the old table).
            seen.append(controller.lastLaunchFailureReason(for: Self.host))
        }
        // Three Dock-menu sends of one program before any result: none of them changes the empty table.
        for _ in 0..<3 { controller.launchFromDockMenu(Self.item("missing.exe")) }
        #expect(sender.calls.count == 3)
        #expect(changes == 0, "a send over an empty table is no change")
        #expect(controller.lastLaunchFailureReason(for: Self.host) == nil)
        // Results match the oldest pending send first: the first two belong to superseded sends.
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        #expect(changes == 0 && controller.lastLaunchFailureReason(for: Self.host) == nil, "a-1c (3): superseded sends leave nothing")
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        #expect(changes == 1)
        #expect(controller.lastLaunchFailureReason(for: Self.host) == Self.notFound, "the sentence, not the key")
        // Another reason: a new send clears the failure (one change), its own failure is another.
        controller.launchFromDockMenu(Self.item("missing.exe"))
        #expect(changes == 2 && controller.lastLaunchFailureReason(for: Self.host) == nil)
        controller.handleExecResult(execResult: 3, rawResult: 0, program: "missing.exe")
        #expect(changes == 3, "another reason is")
        #expect(controller.lastLaunchFailureReason(for: Self.host) == "This program is not allowed on the remote PC.")
        #expect(controller.lastLaunchFailureReason(for: nil) == nil && controller.lastLaunchFailureReason(for: HostID()) == nil)
        #expect(seen == [Self.notFound, nil, "This program is not allowed on the remote PC."], "each callback saw the table after the write")
        #expect(!controller.isShown)
    }

    @Test("a-1b C2: opening the panel moves the failure into the last-launch strip: one callback, nothing left for the status line")
    func showTakesTheWaitingFailure() {
        let (controller, _) = Self.controller()
        var changes = 0
        var seen: [String?] = []
        controller.onLastFailureChange = {
            changes += 1
            seen.append(controller.lastLaunchFailureReason(for: Self.host))
        }
        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        #expect(changes == 1)
        controller.show(anchor: .fallback)
        defer { controller.close(.dismissed) }
        #expect(changes == 2)
        #expect(seen == [Self.notFound, nil], "the open's callback already sees the table without the failure (gate r1 m-1)")
        #expect(controller.lastLaunchFailureReason(for: Self.host) == nil)
        #expect(controller.shownLastFailure == .init(reasonKey: "sp_r_nf", programName: "missing.exe"))
        controller.close(.dismissed)
        controller.show(anchor: .fallback)
        #expect(changes == 2, "an open with nothing waiting is no change")
        #expect(controller.shownLastFailure == nil)
    }

    @Test("a-1b C3: a launch sent for the host clears its waiting failure -- row, Run field, Dock menu; a refusal or a closed gate does not")
    func aSentLaunchSupersedesTheFailure() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: "calc.exe", arguments: ""), displayName: "calc.exe", for: Self.host, at: Date(timeIntervalSince1970: 0))
        var state: ReconnectDriver.State? = .live
        let (controller, sender) = Self.controller(store: store)
        controller.reading = { .init(hasSession: true, state: state, host: Self.host, hostTitle: "h") }
        var changes = 0
        controller.onLastFailureChange = { changes += 1 }
        func failLate() {
            controller.launchFromDockMenu(Self.item("missing.exe"))
            controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        }
        controller.render()

        failLate()
        #expect(changes == 1 && controller.lastLaunchFailureReason(for: Self.host) == Self.notFound)
        controller.launch(try #require(controller.itemRows.first?.row))
        #expect(changes == 2 && controller.lastLaunchFailureReason(for: Self.host) == nil, "a row launch")
        controller.handleExecResult(execResult: 0, rawResult: 0, program: "calc.exe")

        failLate()
        #expect(changes == 3)
        controller.runField.stringValue = "notepad.exe"
        controller.submitRunField()
        #expect(changes == 4 && controller.lastLaunchFailureReason(for: Self.host) == nil, "a Run field launch")
        controller.handleExecResult(execResult: 0, rawResult: 0, program: "notepad.exe")

        failLate()
        #expect(changes == 5)
        controller.launchFromDockMenu(Self.item("winver.exe"))
        #expect(changes == 6 && controller.lastLaunchFailureReason(for: Self.host) == nil, "a Dock menu launch")

        failLate()
        #expect(changes == 7)
        let sent = sender.calls.count
        controller.runField.stringValue = String(repeating: "a", count: 256)
        controller.submitRunField()
        #expect(controller.runFieldError == "sp_r_long" && sender.calls.count == sent)
        #expect(changes == 7 && controller.lastLaunchFailureReason(for: Self.host) == Self.notFound, "a refusal sends nothing, so supersedes nothing")

        state = .reconnecting(attempt: 0)
        controller.render()
        controller.launch(try #require(controller.itemRows.first?.row))
        controller.runField.stringValue = "notepad.exe"
        controller.submitRunField()
        controller.launchFromDockMenu(Self.item("winver.exe"))
        #expect(sender.calls.count == sent, "the gate is closed")
        #expect(changes == 7 && controller.lastLaunchFailureReason(for: Self.host) == Self.notFound, "nothing sent, nothing superseded")
    }

    @Test("a-1b C4: the session's end clears every waiting failure, once; a dropped connection or a give-up's own refresh keeps it")
    func sessionEndClearsTheFailures() {
        var reading = StartPanelController.Reading(hasSession: true, state: .live, host: Self.host, hostTitle: "h")
        let (controller, _) = Self.controller()
        controller.reading = { reading }
        var changes = 0
        var seen: [String?] = []
        controller.onLastFailureChange = {
            changes += 1
            seen.append(controller.lastLaunchFailureReason(for: Self.host))
        }
        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "missing.exe")
        #expect(changes == 1)
        reading.state = .waiting(attempt: 0, delay: .seconds(1))
        controller.refresh()
        #expect(changes == 1 && controller.lastLaunchFailureReason(for: Self.host) == Self.notFound, "kept for the next live line")
        reading.state = .gaveUp(.policy(.attemptsExhausted))
        controller.refresh()
        #expect(changes == 1, "the give-up's refresh still has the session; its teardown is the end")
        reading = .noSession
        controller.refresh()
        #expect(changes == 2 && controller.lastFailures.isEmpty)
        #expect(controller.lastLaunchFailureReason(for: Self.host) == nil)
        #expect(seen == [Self.notFound, nil], "the end's callback already sees the empty table (gate r1 m-1)")
        controller.refresh()
        #expect(changes == 2, "an end over an empty table is no change")
        reading = .init(hasSession: true, state: nil, host: Self.host, hostTitle: "h")
        controller.refresh()
        #expect(changes == 2, "a session beginning changes nothing")
    }

    @Test("a-1b C5: a failure shown inline in the open panel is not a waiting one: no callback, nothing for the status line")
    func inlineFailuresAreNotWaiting() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: "calc.exe", arguments: ""), displayName: "calc.exe", for: Self.host, at: Date(timeIntervalSince1970: 0))
        let (controller, _) = Self.controller(store: store)
        controller.announce = { _, _ in }
        var changes = 0
        controller.onLastFailureChange = { changes += 1 }
        controller.show(anchor: .fallback)
        defer { controller.close(.dismissed) }
        let calc = try #require(controller.itemRows.first?.row)
        controller.launch(calc)
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "calc.exe")
        controller.runField.stringValue = "missing.exe"
        controller.submitRunField()
        controller.handleExecResult(execResult: 3, rawResult: 0, program: "missing.exe")
        #expect(controller.rowErrors[calc.item.key] == "sp_r_nf" && controller.runFieldError == "sp_r_allow")
        #expect(controller.lastFailures.isEmpty && changes == 0)
        #expect(controller.lastLaunchFailureReason(for: Self.host) == nil)
    }

    // MARK: - a-1c (owner ruling (3)): only the host's latest sent launch leaves a late failure

    @Test("a-1c (d): A then B from the Dock menu; A's late failure is dropped with no callback, B's waits")
    func onlyTheLatestSendLeavesALateFailure() {
        let (controller, sender) = Self.controller()
        var changes = 0
        controller.onLastFailureChange = { changes += 1 }
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        controller.launchFromDockMenu(Self.item(#"C:\Tools\Example.exe"#))
        #expect(sender.calls.map(\.program) == ["notepad.exe", #"C:\Tools\Example.exe"#])
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "notepad.exe")
        #expect(controller.lastFailures.isEmpty && changes == 0, "A was superseded by B: dropped")
        #expect(controller.lastLaunchFailureReason(for: Self.host) == nil)
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        #expect(changes == 1)
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "Example.exe"))
    }

    @Test("a-1c (f): a timeout is judged the same way -- an earlier send's timeout after a later send (even a successful one) writes nothing; the latest's waits")
    func onlyTheLatestSendsTimeoutWaits() {
        let clock = PanelClock()
        let store = LaunchItemStore(fileURL: nil)
        let (controller, _) = Self.controller(store: store, clock: clock)
        var changes = 0
        controller.onLastFailureChange = { changes += 1 }
        // Gate r1 m-4's shape: B succeeds, then A's timeout lands.
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        controller.launchFromDockMenu(Self.item("winver.exe"))
        controller.handleExecResult(execResult: 0, rawResult: 0, program: "winver.exe")
        #expect(store.items(for: Self.host).recent.map(\.displayName) == ["winver.exe"])
        clock.fireAll()
        #expect(controller.launcher.pendingRequests.isEmpty, "A timed out")
        #expect(controller.lastFailures.isEmpty && changes == 0, "B's S_OK is not overwritten by A's timeout")
        // Both time out: only the later one waits.
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        controller.launchFromDockMenu(Self.item(#"C:\Tools\Example.exe"#))
        clock.fireAll()
        #expect(changes == 1)
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_timeout", programName: "Example.exe"))
    }

    /// The clear itself is read as state: request ids never repeat (one launcher for the App's life)
    /// and every send overwrites its host's entry, so a stale entry could neither match nor block a
    /// later outcome -- leaving it is invisible to behaviour, and only `latestSentID.isEmpty` sees it.
    @Test("a-1c (g): the session's end forgets the latest sends; a new session's single late failure still waits")
    func sessionEndForgetsTheLatestSends() {
        var reading = StartPanelController.Reading(hasSession: true, state: .live, host: Self.host, hostTitle: "h")
        let (controller, _) = Self.controller()
        controller.reading = { reading }
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        #expect(controller.latestSentID[Self.host] != nil)
        reading = .noSession
        controller.refresh()
        #expect(controller.latestSentID.isEmpty, "cleared with the waiting failures")
        reading = .init(hasSession: true, state: .live, host: Self.host, hostTitle: "h")
        controller.refresh()
        controller.launchFromDockMenu(Self.item(#"C:\Tools\Example.exe"#))
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "Example.exe"))
    }

    // MARK: - gate r1 (fold-in) m-1 / m-2 / m-3: the row entry writes the latest send, an older S_OK clears nothing (ruling (3)), the clamp holds across a refresh

    @Test("gate r1 m-1 (fold): a row send whose failure lands after the panel closed is the latest send")
    func rowSendIsTheLatestSend() throws {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: #"C:\Tools\Example.exe"#, arguments: ""), displayName: "Example.exe", for: Self.host,
                           at: Date(timeIntervalSince1970: 0))
        let (controller, _) = Self.controller(store: store)
        controller.announce = { _, _ in }
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        controller.show(anchor: .fallback)
        controller.launch(try #require(controller.itemRows.first?.row))
        controller.close(.dismissed)
        controller.handleExecResult(execResult: 5, rawResult: 2, program: "notepad.exe")
        #expect(controller.lastFailures.isEmpty, "m-1a: the earlier Dock-menu send is superseded by the row send")
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "Example.exe"), "m-1b: the row's late failure waits")
    }

    @Test("gate r1 m-2 (fold): an earlier send's S_OK after the latest send's failure clears nothing (ruling (3), not (2))")
    func olderSuccessClearsNothing() {
        let (controller, _) = Self.controller()
        controller.launchFromDockMenu(Self.item("notepad.exe"))
        controller.launchFromDockMenu(Self.item(#"C:\Tools\Example.exe"#))
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        controller.handleExecResult(execResult: 0, rawResult: 0, program: "notepad.exe")
        #expect(controller.lastFailures[Self.host] == .init(reasonKey: "sp_r_nf", programName: "Example.exe"), "m-2")
    }

    @Test("gate r1 m-3 (fold): a panel taller than the visible frame is capped and its content fits the capped frame, also after a refresh")
    func tallPanelIsCappedAlsoAfterRefresh() throws {
        let store = LaunchItemStore(fileURL: nil)
        for i in 0..<8 {
            store.recordLaunch(RunCommand(program: "p\(i).exe", arguments: ""), displayName: "p\(i).exe", for: Self.host,
                               at: Date(timeIntervalSince1970: Double(i)))
        }
        let (controller, _) = Self.controller(store: store)
        controller.announce = { _, _ in }
        controller.locator.screensProvider = {
            [AnchorScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 300), visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 205))]
        }
        controller.show(anchor: .dockPointer(CGPoint(x: 300, y: 30)))
        defer { controller.close(.dismissed) }
        let content = try #require(controller.panel.contentView)
        let frame = controller.panel.frame
        #expect(frame.height <= 205 - 16, "m-3a capped: \(frame)")
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.height <= frame.height + 0.5, "m-3b content fits: \(content.fittingSize) in \(frame)")
        controller.launch(try #require(controller.itemRows.first?.row))
        controller.handleExecResult(execResult: 5, rawResult: 2, program: controller.itemRows.first?.row.item.program ?? "")
        let grown = controller.panel.frame
        content.layoutSubtreeIfNeeded()
        #expect(grown.height <= 205 - 16 && content.fittingSize.height <= grown.height + 0.5, "m-3c after refresh: \(content.fittingSize) in \(grown)")
    }

    // MARK: - F-a1-9: a refresh places the panel again at the anchor it was opened at

    /// One 1440 × 900 screen with a 70 pt Dock gap at the bottom and a 25 pt menu bar, so a frame does
    /// not depend on this machine's displays or Dock.
    private static let fixedScreen = AnchorScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                  visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))

    /// A live panel whose one Recent row is `C:\Tools\Example.exe /open`, placed on `fixedScreen`.
    private static func placedController() -> (StartPanelController, PanelSender) {
        let store = LaunchItemStore(fileURL: nil)
        store.recordLaunch(RunCommand(program: #"C:\Tools\Example.exe"#, arguments: "/open"), displayName: "Example.exe", for: Self.host,
                           at: Date(timeIntervalSince1970: 0))
        let (controller, sender) = Self.controller(store: store)
        controller.announce = { _, _ in }
        controller.locator.screensProvider = { [Self.fixedScreen] }
        return (controller, sender)
    }

    @Test("F-a1-9 (a)/(c): Dock anchor -- an inline reason grows the panel upward (bottom edge and midline stay); cleared, it shrinks back in place")
    func dockAnchoredPanelGrowsUpward() throws {
        let (controller, _) = Self.placedController()
        controller.show(anchor: .dockPointer(CGPoint(x: 300, y: 30)))
        defer { controller.close(.dismissed) }
        let shown = controller.panel.frame
        #expect(shown.minY == 78 && shown.midX == 300, "8 pt above the Dock's inner edge, on the icon's midline: \(shown)")
        controller.launch(try #require(controller.itemRows.first?.row))
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        #expect(controller.rowErrors.count == 1, "the reason shows inline")
        let grown = controller.panel.frame
        #expect(grown.height > shown.height, "the reason line adds height: \(shown) -> \(grown)")
        #expect(grown.minY == shown.minY && grown.minX == shown.minX, "the Dock-side edge stays: it grew upward, not over the Dock")
        // (c) Pressing the row again clears its reason (and sends again).
        controller.launch(try #require(controller.itemRows.first?.row))
        #expect(controller.rowErrors.isEmpty)
        let back = controller.panel.frame
        #expect(back.height == shown.height && back.minY == shown.minY && back.minX == shown.minX, "\(shown) -> \(back)")
    }

    @Test("F-a1-9 (b)/(c): status-item anchor -- an inline reason grows the panel down from under the menu bar (top edge stays); cleared, it shrinks back")
    func statusItemPanelGrowsDown() throws {
        let (controller, _) = Self.placedController()
        controller.showFromStatusItem(buttonFrame: CGRect(x: 900, y: 875, width: 30, height: 25))
        defer { controller.close(.dismissed) }
        let shown = controller.panel.frame
        // The clamp rounds the origin to whole points, so a top edge hung from the button sits within
        // half a point of 871 when the content's height is fractional.
        #expect(abs(shown.maxY - 871) <= 0.5 && shown.minX == 900, "4 pt under the button, leading edges aligned: \(shown)")
        controller.runField.stringValue = #"C:\Tools\Example.exe"#
        controller.submitRunField()
        controller.handleExecResult(execResult: 5, rawResult: 2, program: #"C:\Tools\Example.exe"#)
        #expect(controller.runFieldError == "sp_r_nf")
        let grown = controller.panel.frame
        #expect(grown.height > shown.height, "\(shown) -> \(grown)")
        #expect(abs(grown.maxY - shown.maxY) <= 0.5 && grown.minX == shown.minX, "the top edge stays under the menu bar: \(shown) -> \(grown)")
        // (c) Sending again clears the Run field's reason.
        controller.submitRunField()
        #expect(controller.runFieldError == nil)
        let back = controller.panel.frame
        #expect(back.height == shown.height && abs(back.maxY - shown.maxY) <= 0.5 && back.minX == shown.minX, "\(shown) -> \(back)")
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
