import AppKit

/// UI-1 spec §1 / §3 / §4.3: the content side of the main window -- the banner area under the
/// toolbar, then either the empty first screen (`em_*`) or the selected host's detail: the
/// session controls (handed in by the App: title, status line, Connect / Disconnect), Edit… /
/// Remove…, the Connection card and Recent connections. Content layer: no glass here except the
/// banners and the buttons (§3 material rule), all through `GlassStyle`.
@MainActor
final class HostDetailViewController: NSViewController {
    let bannerStack = NSStackView()
    let emptyView = NSStackView()
    let detailStack = NSStackView()
    let editButton: NSButton
    let removeButton: NSButton
    let showButton: NSButton
    let addHostButton: NSButton
    let statusBarLabel = NSTextField(labelWithString: "")
    let statusBarMarker = NSImageView()
    private let connectionGrid = NSGridView()
    private let recentStack = NSStackView()
    private var sessionControls: NSStackView?

    init(editAction: Selector, removeAction: Selector, showAction: Selector, addAction: Selector) {
        editButton = NSButton(title: UIStrings.edit, target: nil, action: editAction)
        removeButton = NSButton(title: UIStrings.remove, target: nil, action: removeAction)
        showButton = NSButton(title: UIStrings.show, target: nil, action: showAction)
        addHostButton = NSButton(title: UIStrings.addHost, target: nil, action: addAction)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        bannerStack.orientation = .vertical
        bannerStack.alignment = .leading
        bannerStack.spacing = 8
        bannerStack.translatesAutoresizingMaskIntoConstraints = false

        // Empty first screen.
        let emptyTitle = NSTextField(labelWithString: UIStrings.emptyTitle)
        emptyTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        let emptyBody = NSTextField(wrappingLabelWithString: UIStrings.emptyBody)
        emptyBody.alignment = .center
        let emptyNote = NSTextField(wrappingLabelWithString: UIStrings.emptyNote)
        emptyNote.alignment = .center
        emptyNote.font = .systemFont(ofSize: 11)
        emptyNote.textColor = .secondaryLabelColor
        GlassStyle.stylePrimary(addHostButton, isDefault: false)
        for view in [emptyTitle, emptyBody, emptyNote, addHostButton] { emptyView.addArrangedSubview(view) }
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 12
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        emptyNote.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        // Detail.
        for button in [editButton, removeButton] { GlassStyle.styleSecondary(button) }
        GlassStyle.styleSecondary(showButton)
        showButton.controlSize = .small
        let manage = GlassStyle.buttonGroup([editButton, removeButton])
        connectionGrid.rowSpacing = 10
        connectionGrid.columnSpacing = 12
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 6
        let connectionCard = Self.card(title: UIStrings.connectionHeader, content: connectionGrid)
        let recentCard = Self.card(title: UIStrings.recentHeader, content: recentStack)
        for view in [manage, connectionCard, recentCard] { detailStack.addArrangedSubview(view) }
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 16
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        connectionCard.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        recentCard.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true

        // Status bar (content layer, 28 pt).
        statusBarLabel.font = .systemFont(ofSize: 11)
        statusBarLabel.textColor = .secondaryLabelColor
        statusBarMarker.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        let statusBar = NSStackView(views: [statusBarMarker, statusBarLabel])
        statusBar.orientation = .horizontal
        statusBar.spacing = 6
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailStack)
        scroll.documentView = document

        let root = NSView()
        root.setAccessibilityLabel(UIStrings.hostDetails)
        for view in [bannerStack, scroll, emptyView, statusBar] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            bannerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bannerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: bannerStack.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            detailStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            detailStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            detailStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            detailStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        view = root
        // UI-1 spec §4.1: with no session the status bar reads "Not connected" from the start;
        // the App overwrites it once a connection chain begins.
        setStatusBar(UIStrings.notConnected, marker: .idle)
    }

    /// The App's session controls -- the host title, the status line and the Connect / Disconnect
    /// buttons, built by the App in one stack -- placed at the top of the detail. The two buttons
    /// are moved into a button group inside that same stack (they stay in it).
    func installSessionControls(_ stack: NSStackView, title: NSTextField, status: NSTextField,
                                connect: NSButton, disconnect: NSButton) {
        loadViewIfNeeded()
        sessionControls = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .left
        status.alignment = .left
        status.font = .systemFont(ofSize: 12)
        stack.removeArrangedSubview(connect)
        stack.removeArrangedSubview(disconnect)
        connect.removeFromSuperview()
        disconnect.removeFromSuperview()
        connect.title = UIStrings.connect
        disconnect.title = UIStrings.disconnect
        GlassStyle.stylePrimary(connect)
        GlassStyle.styleSecondary(disconnect)
        stack.addArrangedSubview(GlassStyle.buttonGroup([connect, disconnect]))
        detailStack.insertArrangedSubview(stack, at: 0)
    }

    func showEmpty(_ empty: Bool) {
        loadViewIfNeeded()
        emptyView.isHidden = !empty
        detailStack.isHidden = empty
    }

    func setStatusBar(_ text: String, marker: HostListViewController.Marker) {
        loadViewIfNeeded()
        statusBarLabel.stringValue = text
        statusBarMarker.image = NSImage(systemSymbolName: marker.symbol, accessibilityDescription: nil)
        statusBarMarker.contentTintColor = marker.color
    }

    /// The status bar's text without touching its marker (UI slice ④). Written only when it
    /// changed, because the App calls this on every drain tick.
    func setStatusBarText(_ text: String) {
        loadViewIfNeeded()
        if statusBarLabel.stringValue != text { statusBarLabel.stringValue = text }
    }

    /// Fills the Connection and Recent cards for `record`.
    func show(_ record: HostRecord) {
        loadViewIfNeeded()
        while connectionGrid.numberOfRows > 0 { connectionGrid.removeRow(at: 0) }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        func value(_ text: String) -> NSTextField {
            let value = NSTextField(labelWithString: text)
            value.isSelectable = true
            return value
        }
        connectionGrid.addRow(with: [label(UIStrings.fieldAddress), value(record.address)])
        connectionGrid.addRow(with: [label(UIStrings.fieldPort), value(String(record.port))])
        connectionGrid.addRow(with: [label(UIStrings.fieldUser), value(record.userName)])
        connectionGrid.addRow(with: [label(UIStrings.fieldPassword),
                                     value(record.remembersPassword ? UIStrings.savedInKeychain : UIStrings.askedEachTime)])
        let certificate: NSView
        if record.pinned {
            let row = NSStackView(views: [value(UIStrings.pinnedSHA256), showButton])
            row.orientation = .horizontal
            row.spacing = 8
            certificate = row
        } else {
            let text = NSTextField(wrappingLabelWithString: UIStrings.notPinned)
            text.textColor = .secondaryLabelColor
            certificate = text
        }
        connectionGrid.addRow(with: [label(UIStrings.fieldCertificate), certificate])
        connectionGrid.addRow(with: [label(UIStrings.fieldSecurity), value(UIStrings.nlaRequired)])
        connectionGrid.column(at: 0).xPlacement = .trailing
        connectionGrid.rowAlignment = .firstBaseline

        for view in recentStack.arrangedSubviews {
            recentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if record.recent.isEmpty {
            let none = NSTextField(labelWithString: UIStrings.recentNone)
            none.textColor = .secondaryLabelColor
            recentStack.addArrangedSubview(none)
        }
        for entry in record.recent {
            let when = NSTextField(labelWithString: DateFormatter.localizedString(from: entry.date, dateStyle: .medium, timeStyle: .short))
            when.textColor = .secondaryLabelColor
            when.font = .systemFont(ofSize: 12)
            var text = UIStrings.recentEvent(entry.event)
            if let detail = entry.detail { text += " (\(detail))" }
            let what = NSTextField(labelWithString: text)
            what.font = .systemFont(ofSize: 12)
            let row = NSStackView(views: [when, what])
            row.orientation = .horizontal
            row.spacing = 12
            recentStack.addArrangedSubview(row)
        }
    }

    // MARK: Banners

    func setBanners(_ banners: [BannerView]) {
        loadViewIfNeeded()
        for view in bannerStack.arrangedSubviews {
            bannerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for banner in banners {
            bannerStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true
        }
    }

    /// A grouped card (content layer, standard fill, corner radius 12; no glass, §3).
    static func card(title: String, content: NSView) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        content.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        let stack = NSStackView(views: [heading, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}

/// A top-to-bottom document view for the detail's scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
