import AppKit

/// The start panel's window (ADR-0025 §2, design note §2): a borderless, non-activating panel.
///
/// Probe K1 / K2: such a panel cannot become key unless the class says so, and only
/// `makeKeyAndOrderFront(nil)` then makes it key -- without bringing the App to the front. While the
/// App is not active the main menu's key equivalents never reach this window, so it handles its own:
/// Esc and ⌘. (`cancelOperation:`), ⌘W (`closeKeyWindow:`, the Close Window item's action when the
/// App is active, and `performKeyEquivalent` when it is not).
final class StartPanelWindow: NSPanel {
    /// Asks the controller to close the panel.
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { StartPanelPolicy.overridesCanBecomeKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    @objc func closeKeyWindow(_ sender: Any?) {
        onDismiss?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isDismissKeyEquivalent(event) {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘W and ⌘. with no other modifier.
    static func isDismissKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
        else { return false }
        return ["w", "."].contains(event.charactersIgnoringModifiers ?? "")
    }
}

/// The header's state mark (design note §2): a filled green dot when live, a half-filled orange
/// dot while connecting or reconnecting. Shape and colour both carry the state, and the status text
/// beside it says it again (UI-1 spec §7.1: never colour alone).
final class StartPanelMarkerView: NSView {
    enum Kind: Equatable {
        case live
        case pending
    }

    var kind: Kind = .live {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - 10) / 2, y: (bounds.height - 10) / 2, width: 10, height: 10).insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: rect)
        switch kind {
        case .live:
            NSColor.systemGreen.setFill()
            circle.fill()
        case .pending:
            NSColor.systemOrange.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)).addClip()
            NSColor.systemOrange.setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// One clickable row (design note §2): 28 pt high, corner radius 10, a neutral fill on hover,
/// press and keyboard selection (`tertiarySystemFill`, §10 item 3) with the system focus ring on
/// keyboard selection; the title in the label colour, the qualifier and arguments in the secondary
/// colour; a small spinner at the end while a launch is pending. A disabled row keeps the secondary
/// colour and no hover. An accessibility button: VoiceOver presses it and opens its menu.
final class StartPanelRowView: NSView {
    var onPress: (() -> Void)?
    /// Arrow keys and typing, handed to the controller; true = handled.
    var onKey: ((NSEvent) -> Bool)?
    /// The row's context menu (Pin / Unpin / Remove from Recent), if it has one.
    var menuProvider: (() -> NSMenu?)?

    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let trailingGlyph = NSImageView()

    var isEnabled = true {
        didSet { applyAppearance() }
    }

    var isPending = false {
        didSet {
            spinner.isHidden = !isPending
            if isPending { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    private var isHovered = false
    private var isPressed = false
    private var tracking: NSTrackingArea?

    init(title: String, detail: String, help: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: StartPanelPolicy.width - 12, height: StartPanelPolicy.rowHeight))
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = detail.isEmpty
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        trailingGlyph.isHidden = true
        let row = NSStackView(views: [titleLabel, detailLabel, NSView(), spinner, trailingGlyph])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: StartPanelPolicy.rowHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = help
        setAccessibilityLabel(detail.isEmpty ? title : title + " " + detail)
        setAccessibilityHelp(help)
        focusRingType = .exterior
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the Return glyph at the row's end (the default action's mark, design note §2).
    func showReturnGlyph(_ shown: Bool) {
        trailingGlyph.image = NSImage(systemSymbolName: "return", accessibilityDescription: nil)
        trailingGlyph.contentTintColor = .secondaryLabelColor
        trailingGlyph.isHidden = !shown
    }

    private func applyAppearance() {
        titleLabel.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        if !isEnabled {
            isHovered = false
            isPressed = false
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let selected = window?.firstResponder === self
        guard isEnabled, isHovered || isPressed || selected else { return }
        NSColor.tertiarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    // MARK: Focus and keys

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Mouse

    /// The labels never take a click: the whole row is the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        return true
    }
}
