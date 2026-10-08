import AppKit
import MacdowsCore

/// ADR-0025 a-1: the Dock start panel -- a small non-activating panel at the Dock icon (or under the
/// status item) that lists the host's pinned and recent programs and runs a typed one, through
/// `AppLauncher`. Design note 2026-10-07 §1–§6 is its layout and behaviour; `StartPanelPolicy` holds
/// every probe-dependent value it reads.
///
/// States (owner ruling ㋯, §10 item 1 (b)): live, connecting (first connect, driver idle or not
/// armed yet), reconnecting (waiting / reconnecting). No session and a give-up -- which tears the
/// session down -- have no panel: a Dock click then takes the Hosts-window branch. In connecting
/// and reconnecting every launch row and the Run field are disabled and the header says why.
///
/// Closing: Esc, ⌘., ⌘W, a click outside, the panel losing key, the App deactivating, the Dock icon
/// clicked again, the Dock menu opening, a launch from it succeeding, Open Macdows, the session
/// ending. Probe K4: `hidesOnDeactivate` stays false and this controller closes the panel itself,
/// so `isShown` is always the truth. Closing activates nothing (ADR-0025 S-1): the panel orders out
/// and the server's own activation decides which remote window is key.
@MainActor
final class StartPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    /// What the panel reads from the App.
    struct Reading: Equatable {
        var hasSession: Bool
        var state: ReconnectDriver.State?
        var host: HostID?
        var hostTitle: String

        static let noSession = Reading(hasSession: false, state: nil, host: nil, hostTitle: "")
    }

    /// The panel's session states (design note §3, minus the give-up state §10-1 (b) removed).
    enum Phase: Equatable {
        case live
        case connecting
        case reconnecting
    }

    enum CloseReason: Equatable {
        case dismissed
        case lostFocus
        case deactivated
        case clickedOutside
        case toggled
        case launched
        case openedMacdows
        case sessionEnded
        case dockMenu
    }

    /// A launch that failed while the panel was closed, shown once at the next open (design note §2).
    struct LastFailure: Equatable {
        let reasonKey: String
        let programName: String
    }

    /// nil = no panel for this reading (no session, or a give-up about to tear the session down).
    static func phase(for reading: Reading) -> Phase? {
        guard reading.hasSession else { return nil }
        switch reading.state {
        case .live?: return .live
        case .idle?, nil: return .connecting
        case .waiting?, .reconnecting?: return .reconnecting
        case .gaveUp?: return nil
        }
    }

    /// The App's state, read on every open, refresh and launch.
    var reading: () -> Reading = { .noSession } {
        didSet { wireLauncherReading() }
    }

    /// Open Macdows (the panel's last row and the Dock menu's): the App shows the Hosts window.
    var onOpenMacdows: (() -> Void)?

    /// Design note §6: the status item's button stays highlighted while the panel it opened is
    /// open. Called with true when the panel opens from the status item's Run…, and with false when
    /// that panel closes (by any path) or is re-opened from somewhere else. A Dock or Dock-menu open
    /// never calls it. The App forwards it to the status item; the panel knows nothing of it.
    var onStatusItemAnchorChange: ((Bool) -> Void)?

    /// ADR-0025 R-7 (a-1b): the waiting late failures changed -- one was recorded, or one was cleared
    /// (by the next open, a new launch sent for that host, or the session's end). Called only when the
    /// table really changed, never for a write that left it as it was. The App rewrites the Hosts
    /// window's status line from `lastLaunchFailureReason(for:)`; the panel knows nothing of it.
    var onLastFailureChange: (() -> Void)?

    /// Design note §6: an inline error is read out to VoiceOver. A seam so tests can see what is
    /// announced on which element; the App keeps the default, the system announcement.
    var announce: (_ element: Any, _ text: String) -> Void = { element, text in
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    let launcher: AppLauncher
    let items: LaunchItemStore
    let preferences: StartPanelPreferences
    let locator: DockAnchorLocator
    let panel: StartPanelWindow
    private(set) lazy var dockMenu = DockMenuController(controller: self)

    // Views that live as long as the panel.
    let runField = NSTextField()
    private let rootStack = NSStackView()
    private let sectionsStack = NSStackView()
    private let sectionsScroll = NSScrollView()
    private var sectionsHeight: NSLayoutConstraint!
    private let headerMarker = StartPanelMarkerView()
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerStatus = NSTextField(wrappingLabelWithString: "")
    private let runSpinner = NSProgressIndicator()
    private let runReturnGlyph = NSImageView()
    private let runErrorLine = NSStackView()
    private let runErrorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var openRow: StartPanelRowView!
    /// Built once and kept in place, so a refresh never takes the Run field or Open Macdows out of the
    /// window (which would end typing and drop focus -- design note §3: refreshes take no focus).
    private let headerView = NSStackView()
    private let lastFailureContainer = NSStackView()

    // Rebuilt on every render.
    private(set) var itemRows: [(row: LaunchCatalog.Row, view: StartPanelRowView)] = []

    // State.
    private(set) var isShown = false
    private(set) var phase: Phase?
    private var currentHost: HostID?
    private var pendingByKey: [String: Int] = [:]
    /// Inline reasons by command key while the panel is open (read by tests).
    private(set) var rowErrors: [String: String] = [:]
    private var runFieldPending: Int?
    private(set) var runFieldError: String?
    /// The inline error to announce once the panel has re-rendered (design note §6, VoiceOver).
    private var inlineAnnouncement: (rowKey: String?, reasonKey: String)?
    /// True while the panel is open and was opened from the status item's Run…
    private(set) var isAnchoredToStatusItem = false {
        didSet {
            if isAnchoredToStatusItem != oldValue { onStatusItemAnchorChange?(isAnchoredToStatusItem) }
        }
    }
    /// Late failures by host, waiting for the next open (design note §2) and, while live, shown on the
    /// Hosts window's status line (R-7). Cleared by that open, a new launch sent for the host, and the
    /// session's end.
    private(set) var lastFailures: [HostID: LastFailure] = [:] {
        didSet {
            if lastFailures != oldValue { onLastFailureChange?() }
        }
    }
    /// a-1c (owner ruling (3)): each host's latest SENT launch (`AppLauncher.Request.id`). Only that
    /// launch's failure or timeout may wait as a late failure; an earlier launch's outcome that lands
    /// after a later send is dropped. Written where a send clears the waiting failure, emptied with it
    /// at the session's end.
    private(set) var latestSentID: [HostID: Int] = [:]
    private(set) var shownLastFailure: LastFailure?
    /// F-a1-9: the anchor of the current open. A refresh that changes the content's height places the
    /// panel again at it, so a Dock-anchored panel grows away from the Dock (its Dock-side edge stays
    /// `dockGap` outside the Dock) and a status-item panel grows down from under the menu bar.
    private var shownAnchor: PanelAnchor?
    private var shownAt: Date?
    private var lastAutomaticClose: Date?
    private var outsideClickMonitor: Any?
    private var activityObservers: [any NSObjectProtocol] = []

    /// The App's instance: the real store file, the real clock and the shared preference.
    convenience override init() {
        self.init(items: LaunchItemStore(fileURL: LaunchItemStore.defaultFileURL()),
                  launcher: AppLauncher(timeout: StartPanelPolicy.execTimeout, clock: DispatchReconnectClock()),
                  preferences: .shared)
    }

    init(items: LaunchItemStore, launcher: AppLauncher, preferences: StartPanelPreferences) {
        self.items = items
        self.launcher = launcher
        self.preferences = preferences
        locator = DockAnchorLocator(preferences: preferences)
        panel = StartPanelWindow(contentRect: NSRect(x: 0, y: 0, width: StartPanelPolicy.width, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        configurePanel()
        buildChrome()
        launcher.onOutcome = { [weak self] request, outcome in
            self?.handle(request, outcome)
        }
        wireLauncherReading()
    }

    private func wireLauncherReading() {
        launcher.reading = { [weak self] in
            let reading = self?.reading() ?? .noSession
            return AppLauncher.Reading(hasSession: reading.hasSession, state: reading.state, host: reading.host)
        }
    }

    // MARK: - Panel

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = StartPanelPolicy.level
        panel.collectionBehavior = StartPanelPolicy.collectionBehavior
        panel.hidesOnDeactivate = StartPanelPolicy.hidesOnDeactivate
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.close(.dismissed) }
    }

    private func buildChrome() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 0
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = StartPanelFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sectionsStack)
        sectionsScroll.documentView = document
        sectionsScroll.drawsBackground = false
        sectionsScroll.hasVerticalScroller = true
        sectionsScroll.autohidesScrollers = true
        sectionsScroll.scrollerStyle = .overlay
        sectionsScroll.translatesAutoresizingMaskIntoConstraints = false
        sectionsHeight = sectionsScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sectionsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            sectionsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            sectionsStack.topAnchor.constraint(equalTo: document.topAnchor),
            sectionsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: sectionsScroll.contentView.widthAnchor),
            sectionsHeight,
        ])

        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.lineBreakMode = .byTruncatingTail
        headerStatus.font = .systemFont(ofSize: 11)
        headerStatus.textColor = .secondaryLabelColor

        runField.placeholderString = UIStrings.startPanelRunPlaceholder
        runField.setAccessibilityLabel(UIStrings.startPanelRun)
        runField.font = .systemFont(ofSize: 13)
        runField.bezelStyle = .roundedBezel
        runField.usesSingleLineMode = true
        runField.cell?.isScrollable = true
        runField.delegate = self
        runField.translatesAutoresizingMaskIntoConstraints = false
        runField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        runSpinner.style = .spinning
        runSpinner.controlSize = .small
        runSpinner.isDisplayedWhenStopped = false
        runReturnGlyph.image = NSImage(systemSymbolName: "return", accessibilityDescription: nil)
        runReturnGlyph.contentTintColor = .secondaryLabelColor
        runReturnGlyph.isHidden = true
        runErrorLine.orientation = .horizontal
        runErrorLine.alignment = .top
        runErrorLine.spacing = 4
        runErrorLabel.font = .systemFont(ofSize: 11)
        runErrorLabel.textColor = .systemRed
        let errorGlyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        errorGlyph.contentTintColor = .systemRed
        runErrorLine.setViews([errorGlyph, runErrorLabel], in: .leading)
        runErrorLine.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 4, right: 16)

        let open = StartPanelRowView(title: UIStrings.openMacdows, detail: "", help: nil)
        open.onPress = { [weak self] in self?.openMacdows() }
        open.onKey = { [weak self, weak open] event in
            guard let self, let open else { return false }
            return self.handleRowKey(event, from: open)
        }
        openRow = open

        // Wrapping labels measure their height at the panel's text width.
        let textWidth = StartPanelPolicy.width - 32
        headerStatus.preferredMaxLayoutWidth = textWidth
        runErrorLabel.preferredMaxLayoutWidth = textWidth - 18

        let titleLine = NSStackView(views: [headerMarker, headerTitle])
        titleLine.orientation = .horizontal
        titleLine.spacing = 6
        titleLine.alignment = .centerY
        headerView.setViews([titleLine, headerStatus], in: .top)
        headerView.orientation = .vertical
        headerView.alignment = .leading
        headerView.spacing = 2
        headerView.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 6, right: 16)
        headerView.setAccessibilityElement(true)
        headerView.setAccessibilityRole(.group)
        lastFailureContainer.orientation = .vertical
        lastFailureContainer.alignment = .leading

        let terminal = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
        terminal.contentTintColor = .secondaryLabelColor
        let accessory = NSStackView(views: [runSpinner, runReturnGlyph])
        accessory.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let runRow = NSStackView(views: [terminal, runField, accessory])
        runRow.orientation = .horizontal
        runRow.alignment = .centerY
        runRow.spacing = 6
        runRow.edgeInsets = NSEdgeInsets(top: 1, left: 16, bottom: 1, right: 12)
        runRow.heightAnchor.constraint(equalToConstant: StartPanelPolicy.rowHeight).isActive = true

        let views: [NSView] = [headerView, lastFailureContainer, sectionsScroll, separator(), runRow, runErrorLine, separator(),
                               inset(openRow, left: 6, right: 6, bottom: 0)]
        rootStack.setViews(views, in: .top)
        for view in views { stretch(view, in: rootStack) }
        rootStack.widthAnchor.constraint(equalToConstant: StartPanelPolicy.width).isActive = true
        runField.nextKeyView = openRow
        openRow.nextKeyView = runField

        let content = GlassStyle.panelBackground(containing: rootStack)
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.group)
        panel.contentView = content
    }

    // MARK: - Opening and closing

    /// A Dock reopen while a session exists (R-7). Returns true when the panel handled it -- the App
    /// then answers false to AppKit -- and false when the reopen takes the no-session branch: not
    /// from the Dock (R-1′, `StartPanelPolicy.requiresDockSender`) or no panel for this state.
    func toggleForDockReopen() -> Bool {
        let fromDock = locator.currentEventIsFromDock()
        if StartPanelPolicy.requiresDockSender && !fromDock { return false }
        guard Self.phase(for: reading()) != nil else { return false }
        if isShown {
            close(.toggled)
            return true
        }
        if let closedAt = lastAutomaticClose, Date().timeIntervalSince(closedAt) < StartPanelPolicy.reopenToggleGrace {
            lastAutomaticClose = nil
            return true
        }
        show(anchor: locator.anchorForReopen(fromDock: fromDock))
        return true
    }

    /// The status item's "Run…": under the status item button, the Run field focused.
    func showFromStatusItem(buttonFrame: CGRect?) {
        show(anchor: buttonFrame.map { .statusItem(buttonFrame: $0) } ?? .fallback, fromStatusItem: true)
    }

    /// The Dock menu's "Run…".
    func showFromDockMenu(pointer: CGPoint?) {
        show(anchor: locator.anchorForDockMenu(pointer: pointer))
    }

    /// Lays the panel out for the current reading and shows it at `anchor`, key, with the Run field
    /// focused when it can take a launch and Open Macdows the default otherwise (design note §6).
    func show(anchor: PanelAnchor, fromStatusItem: Bool = false) {
        let current = reading()
        guard Self.phase(for: current) != nil else { return }
        if let host = current.host {
            shownLastFailure = lastFailures.removeValue(forKey: host)
        }
        render()
        shownAnchor = anchor
        let frame = placedFrame(for: anchor)
        panel.setFrame(frame, display: true)
        installCloseTriggers()
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = fades ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        focusInitialControl()
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StartPanelPolicy.fadeInDuration
                panel.animator().alphaValue = 1
            }
        }
        isShown = true
        shownAt = Date()
        isAnchoredToStatusItem = fromStatusItem
    }

    /// Closes the panel. Activates nothing (S-1).
    func close(_ reason: CloseReason) {
        guard isShown else { return }
        isShown = false
        removeCloseTriggers()
        switch reason {
        case .lostFocus, .deactivated, .clickedOutside:
            lastAutomaticClose = Date()
        default:
            break
        }
        shownLastFailure = nil
        shownAnchor = nil
        rowErrors = [:]
        runFieldError = nil
        inlineAnnouncement = nil
        panel.orderOut(nil)
        isAnchoredToStatusItem = false
    }

    /// The App's state changed: re-render in place (without taking focus), or close when there is
    /// no panel for the new state. Pending launches are dropped when the session is gone.
    func refresh() {
        let current = reading()
        guard Self.phase(for: current) != nil else {
            if !current.hasSession {
                launcher.cancelAll()
                pendingByKey = [:]
                runFieldPending = nil
                // After `cancelAll`, which reports no outcome, so no late failure can land behind this.
                lastFailures = [:]
                latestSentID = [:]
            }
            close(.sessionEnded)
            return
        }
        if isShown {
            // Item rows are rebuilt; keep a focused one focused. The Run field and Open Macdows stay in
            // place, so their focus (and any typing) is untouched.
            let focusedKey = (panel.firstResponder as? StartPanelRowView).flatMap { view in
                itemRows.first { $0.view === view }?.row.item.key
            }
            render()
            // F-a1-9: an inline reason (or its removal) changed the content's height; without this the
            // window kept its top edge and grew down over the Dock icon.
            if let shownAnchor {
                panel.setFrame(placedFrame(for: shownAnchor), display: true)
            }
            if let focusedKey, let row = itemRows.first(where: { $0.row.item.key == focusedKey && $0.view.isEnabled }) {
                panel.makeFirstResponder(row.view)
            }
        }
    }

    /// The reason sentence of `host`'s waiting late failure, or nil (none, or no host): what the Hosts
    /// window's status line shows while live (R-7, a-1b).
    func lastLaunchFailureReason(for host: HostID?) -> String? {
        host.flatMap { lastFailures[$0] }.map { UIStrings.startPanelReason(forKey: $0.reasonKey) }
    }

    /// The registry's ExecResult, forwarded (S-4).
    func handleExecResult(execResult: UInt32, rawResult: UInt32, program: String) {
        launcher.handleExecResult(execResult: execResult, rawResult: rawResult, program: program)
    }

    /// A host was added, edited or removed: lists of removed hosts go with them (R-6).
    func hostsChanged(remaining: [HostID]) {
        items.retainHosts(Set(remaining))
    }

    func openMacdows() {
        close(.openedMacdows)
        onOpenMacdows?()
    }

    private func placedFrame(for anchor: PanelAnchor) -> CGRect {
        rootStack.layoutSubtreeIfNeeded()
        let fitting = NSSize(width: StartPanelPolicy.width, height: rootStack.fittingSize.height)
        let frame = locator.frame(for: anchor, size: fitting)
        if frame.height < fitting.height {
            sectionsHeight.constant = max(0, sectionsHeight.constant - (fitting.height - frame.height))
        }
        return frame
    }

    private func focusInitialControl() {
        if phase == .live, runField.isEnabled {
            panel.makeFirstResponder(runField)
        } else {
            panel.makeFirstResponder(openRow)
        }
    }

    private func installCloseTriggers() {
        removeCloseTriggers()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.clickedOutside) }
        }
        activityObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(.deactivated) }
            },
        ]
    }

    private func removeCloseTriggers() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activityObservers = []
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isShown else { return }
        // Showing the panel can coincide with the App's own activation, which hands key to the
        // App's previous key window a moment later; keep the panel rather than close it then.
        if let shownAt, Date().timeIntervalSince(shownAt) < StartPanelPolicy.keyLossGraceAfterShow {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isShown else { return }
                self.panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        close(.lostFocus)
    }

    // MARK: - Rendering

    /// Rebuilds the panel's content from the current reading, the host's lists and the launch state.
    func render() {
        let current = reading()
        phase = Self.phase(for: current)
        currentHost = current.host
        let live = phase == .live

        headerTitle.stringValue = current.hostTitle
        switch phase {
        case .live?, nil:
            headerMarker.kind = .live
            headerStatus.stringValue = UIStrings.connected
        case .connecting?:
            headerMarker.kind = .pending
            headerStatus.stringValue = UIStrings.connecting
        case .reconnecting?:
            headerMarker.kind = .pending
            headerStatus.stringValue = UIStrings.startPanelWaiting
        }
        panel.setAccessibilityLabel(UIStrings.startPanelTitle + ", " + current.hostTitle)
        headerView.setAccessibilityLabel(current.hostTitle + ", " + headerStatus.stringValue)

        let bar = shownLastFailure.map(makeLastFailureBar)
        lastFailureContainer.setViews(bar.map { [$0] } ?? [], in: .top)
        if let bar { stretch(bar, in: lastFailureContainer) }
        lastFailureContainer.isHidden = bar == nil

        // Sections.
        let lists = current.host.map(items.items(for:)) ?? HostLaunchItems()
        let sections = LaunchCatalog.sections(for: lists)
        itemRows = []
        var sectionViews: [NSView] = []
        if !sections.pinned.isEmpty {
            sectionViews.append(makeSection(UIStrings.startPanelPinned, rows: sections.pinned, live: live, topSpacing: 6))
        }
        if !sections.recent.isEmpty {
            sectionViews.append(makeSection(UIStrings.startPanelRecent, rows: sections.recent, live: live,
                                            topSpacing: sections.pinned.isEmpty ? 6 : 10))
        } else if sections.pinned.isEmpty {
            let note = NSTextField(wrappingLabelWithString: UIStrings.startPanelEmpty)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = StartPanelPolicy.width - 32
            sectionViews.append(sectionHeader(UIStrings.startPanelRecent, topSpacing: 6))
            sectionViews.append(inset(note, left: 16, right: 16, bottom: 6))
        }
        sectionsStack.setViews(sectionViews, in: .top)
        for view in sectionViews { stretch(view, in: sectionsStack) }
        sectionsHeight.constant = sectionsStack.fittingSize.height

        // The Run row and Open Macdows: updated in place.
        runField.isEnabled = live
        runField.isEditable = live && runFieldPending == nil
        runSpinner.isHidden = runFieldPending == nil
        if runFieldPending != nil { runSpinner.startAnimation(nil) } else { runSpinner.stopAnimation(nil) }
        runReturnGlyph.isHidden = runFieldPending != nil || runField.stringValue.isEmpty || !live
        runErrorLabel.stringValue = runFieldError.map(UIStrings.startPanelReason(forKey:)) ?? ""
        runErrorLine.isHidden = runFieldError == nil
        openRow.showReturnGlyph(!live)
    }

    private func makeSection(_ title: String, rows: [LaunchCatalog.Row], live: Bool, topSpacing: CGFloat) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 0
        section.setAccessibilityElement(true)
        section.setAccessibilityRole(.group)
        section.setAccessibilityLabel(title)
        var views: [NSView] = [sectionHeader(title, topSpacing: topSpacing)]
        for row in rows {
            let detail = [row.qualifier, row.arguments.isEmpty ? nil : row.arguments].compactMap { $0 }.joined(separator: "  ")
            let view = StartPanelRowView(title: row.title, detail: detail, help: row.fullCommand)
            if let reasonKey = rowErrors[row.item.key] {
                // VoiceOver keeps the reason in the row's help; the tooltip stays the command.
                view.setAccessibilityHelp(row.fullCommand + "\n" + UIStrings.startPanelReason(forKey: reasonKey))
            }
            view.isEnabled = live
            view.isPending = pendingByKey[row.item.key] != nil
            view.onPress = { [weak self] in self?.launch(row) }
            view.onKey = { [weak self, weak view] event in
                guard let self, let view else { return false }
                return self.handleRowKey(event, from: view)
            }
            view.menuProvider = { [weak self] in self?.contextMenu(for: row) }
            itemRows.append((row, view))
            views.append(inset(view, left: 6, right: 6, bottom: 0))
            if let key = rowErrors[row.item.key] {
                views.append(errorLine(UIStrings.startPanelReason(forKey: key)))
            }
        }
        section.setViews(views, in: .top)
        for view in views { stretch(view, in: section) }
        return section
    }

    private func sectionHeader(_ title: String, topSpacing: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return inset(label, left: 16, right: 16, bottom: 4, top: topSpacing)
    }

    private func errorLine(_ text: String) -> NSView {
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .systemRed
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.preferredMaxLayoutWidth = StartPanelPolicy.width - 50
        let line = NSStackView(views: [glyph, label])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 4
        line.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 4, right: 16)
        return line
    }

    private func makeLastFailureBar(_ failure: LastFailure) -> NSView {
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .systemOrange
        let line = NSTextField(wrappingLabelWithString: UIStrings.startPanelLastFailure(UIStrings.startPanelReason(forKey: failure.reasonKey)))
        line.font = .systemFont(ofSize: 11)
        line.preferredMaxLayoutWidth = StartPanelPolicy.width - 52
        let name = NSTextField(labelWithString: failure.programName)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [line, name])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let bar = NSStackView(views: [glyph, texts])
        bar.orientation = .horizontal
        bar.alignment = .top
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        return inset(bar, left: 6, right: 6, bottom: 4)
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return inset(line, left: 16, right: 16, bottom: 4, top: 4)
    }

    private func inset(_ view: NSView, left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat = 0) -> NSView {
        let box = NSStackView(views: [view])
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        stretch(view, in: box)
        return box
    }

    private func stretch(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    // MARK: - Launching

    /// A row press: sent once; pressing a pending row again sends nothing; pressing an errored row
    /// clears the error and sends again (design note §3 / §6).
    func launch(_ row: LaunchCatalog.Row) {
        guard pendingByKey[row.item.key] == nil else { return }
        rowErrors[row.item.key] = nil
        shownLastFailure = nil
        switch launcher.launch(program: row.item.program, arguments: row.item.arguments, origin: .row(row.item.id)) {
        case .sent(let request):
            pendingByKey[row.item.key] = request.id
            if let host = request.host {
                lastFailures.removeValue(forKey: host)
                latestSentID[host] = request.id
            }
        case .refused(let key):
            if let key { rowErrors[row.item.key] = key }
        case .notLive:
            return
        }
        if isShown { refresh() } else { render() }
    }

    /// Return in the Run field.
    func submitRunField() {
        guard runFieldPending == nil else { return }
        runFieldError = nil
        shownLastFailure = nil
        switch launcher.launch(text: runField.stringValue, origin: .runField) {
        case .sent(let request):
            runFieldPending = request.id
            if let host = request.host {
                lastFailures.removeValue(forKey: host)
                latestSentID[host] = request.id
            }
        case .refused(let key):
            runFieldError = key
        case .notLive:
            return
        }
        if isShown { refresh() } else { render() }
    }

    /// A Dock menu item: sent at once; the menu has closed, so the outcome is a late one. A send
    /// supersedes the host's waiting failure, as a send from the panel does, and becomes the host's
    /// latest send.
    func launchFromDockMenu(_ item: LaunchItem) {
        if case .sent(let request) = launcher.launch(program: item.program, arguments: item.arguments, origin: .dockMenu),
           let host = request.host {
            lastFailures.removeValue(forKey: host)
            latestSentID[host] = request.id
        }
    }

    /// One launch ended (`AppLauncher.onOutcome`). Success writes Recent -- the only writer of
    /// Recent -- and closes the panel the launch came from; a failure or a timeout shows its reason
    /// where it was asked for while the panel is open, and otherwise waits for the next open -- if it
    /// is the host's latest send (a-1c (3)).
    func handle(_ request: AppLauncher.Request, _ outcome: AppLauncher.Outcome) {
        let key = LaunchItem(displayName: "", program: request.command.program, arguments: request.command.arguments, date: Date()).key
        if pendingByKey[key] == request.id { pendingByKey[key] = nil }
        if runFieldPending == request.id { runFieldPending = nil }
        let programName = LaunchCatalog.displayName(of: request.command.program)
        switch outcome {
        case .succeeded:
            if let host = request.host {
                items.recordLaunch(request.command, displayName: programName, for: host, at: Date())
            }
            if request.origin == .runField { runField.stringValue = "" }
            if isShown && request.origin != .dockMenu && request.host == currentHost {
                close(.launched)
                return
            }
        case .failed(let reasonKey):
            fail(request, reasonKey: reasonKey, key: key, programName: programName)
        case .timedOut:
            fail(request, reasonKey: AppLauncher.timeoutReasonKey, key: key, programName: programName)
        }
        if isShown { refresh() }
        announceInlineError()
    }

    private func fail(_ request: AppLauncher.Request, reasonKey: String, key: String, programName: String) {
        let here = isShown && request.host == currentHost
        switch request.origin {
        case .row where here:
            rowErrors[key] = reasonKey
            inlineAnnouncement = (key, reasonKey)
        case .runField where here:
            runFieldError = reasonKey
            inlineAnnouncement = (nil, reasonKey)
        default:
            // a-1c (owner ruling (3)): only the host's latest sent launch may wait; an earlier one whose
            // outcome lands after a later send is dropped -- no write, no callback.
            if let host = request.host, latestSentID[host] == request.id {
                lastFailures[host] = LastFailure(reasonKey: reasonKey, programName: programName)
            }
        }
    }

    /// Reads the inline error just shown to VoiceOver, on its row (rebuilt by the refresh, so looked
    /// up again) or on the Run field. Only the two inline error branches of `fail` set it.
    private func announceInlineError() {
        guard let pending = inlineAnnouncement else { return }
        inlineAnnouncement = nil
        let element: Any = pending.rowKey.flatMap { key in itemRows.first { $0.row.item.key == key }?.view } ?? runField
        announce(element, UIStrings.startPanelReason(forKey: pending.reasonKey))
    }

    private func contextMenu(for row: LaunchCatalog.Row) -> NSMenu? {
        guard let host = currentHost else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch row.section {
        case .pinned:
            menu.addItem(StartPanelMenuItem(title: UIStrings.startPanelUnpin) { [weak self] in
                self?.items.unpin(row.item, for: host)
                self?.refresh()
            })
        case .recent:
            menu.addItem(StartPanelMenuItem(title: UIStrings.startPanelPin) { [weak self] in
                self?.items.pin(row.item, for: host, at: Date())
                self?.refresh()
            })
            menu.addItem(.separator())
            menu.addItem(StartPanelMenuItem(title: UIStrings.startPanelForget) { [weak self] in
                self?.items.forget(row.item, for: host)
                self?.refresh()
            })
        }
        return menu
    }

    // MARK: - Keyboard

    /// ↑ / ↓ move between enabled rows (pinned, recent, Open Macdows; no wrap); Return and Space press;
    /// a typed character goes back to the Run field with it (design note §6).
    func handleRowKey(_ event: NSEvent, from view: StartPanelRowView) -> Bool {
        let order = itemRows.map(\.view).filter(\.isEnabled) + [openRow!]
        guard let index = order.firstIndex(where: { $0 === view }) else { return false }
        switch event.keyCode {
        case 126: // up
            if index > 0 { panel.makeFirstResponder(order[index - 1]) }
            return true
        case 125: // down
            if index + 1 < order.count { panel.makeFirstResponder(order[index + 1]) }
            return true
        case 36, 76, 49: // return, enter, space
            _ = view.accessibilityPerformPress()
            return true
        default:
            guard runField.isEnabled, let characters = event.characters, !characters.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            panel.makeFirstResponder(runField)
            runField.currentEditor()?.insertText(characters)
            return true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close(.dismissed)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            submitRunField()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if let last = itemRows.map(\.view).last(where: \.isEnabled) {
                panel.makeFirstResponder(last)
            }
            return true
        default:
            return false
        }
    }

    /// Ruling R-a1-1 (i): U+0000 never stays in the Run field (it would read as the execute
    /// buffer's separator); stripped as the text changes, like trailing blanks are trimmed at send.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === runField else { return }
        let text = runField.stringValue
        if text.unicodeScalars.contains("\0") {
            runField.stringValue = Self.strippingNUL(text)
        }
        runReturnGlyph.isHidden = runField.stringValue.isEmpty || runFieldPending != nil
    }

    nonisolated static func strippingNUL(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\0" }))
    }
}

/// A flipped document view, so the sections scroll from the top.
private final class StartPanelFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A menu item that runs a closure (the row menu's three actions).
private final class StartPanelMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runHandler(_ sender: Any?) {
        handler()
    }
}
