import AppKit

/// UI-1 spec §1 / §3 / §4.3: one banner under the toolbar -- a title, a body, optional buttons --
/// on the banner background `GlassStyle` builds (glass on 26, a standard material below).
@MainActor
final class BannerView: NSView {
    struct Action {
        let title: String
        let handler: () -> Void
        /// The button's accessibility name when it differs from its title (UI slice ④: `dg_u_x`).
        var accessibilityLabel: String? = nil
    }

    struct Model {
        let id: String
        let title: String
        let body: String
        let tone: GlassStyle.Tone
        let actions: [Action]

        /// Everything a banner shows, without the handlers (closures cannot be compared): two
        /// models with the same signature draw the same banner (UI-9, gate UI-8 R-2).
        struct Signature: Equatable {
            let id: String
            let title: String
            let body: String
            let tone: GlassStyle.Tone
            let buttons: [ButtonSignature]
        }

        /// A button's title and its accessibility name.
        struct ButtonSignature: Equatable {
            let title: String
            let accessibilityLabel: String?
        }

        var signature: Signature {
            Signature(id: id, title: title, body: body, tone: tone,
                      buttons: actions.map { ButtonSignature(title: $0.title, accessibilityLabel: $0.accessibilityLabel) })
        }
    }

    private(set) var model: Model
    private var handlers: [() -> Void] = []

    init(_ model: Model) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        let symbol: String
        switch model.tone {
        case .information: symbol = "info.circle.fill"
        case .warning: symbol = "exclamationmark.triangle.fill"
        case .error: symbol = "xmark.octagon.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = model.tone.color ?? .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: model.body)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .labelColor
        let texts = NSStackView(views: [title, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        var buttons: [NSView] = []
        for (index, action) in model.actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = index
            if let label = action.accessibilityLabel { button.setAccessibilityLabel(label) }
            GlassStyle.styleSecondary(button)
            buttons.append(button)
            handlers.append(action.handler)
        }
        var row: [NSView] = [icon, texts]
        if !buttons.isEmpty { row.append(GlassStyle.buttonGroup(buttons)) }
        let content = NSStackView(views: row)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // F-5: across a horizontal stack, NSStackView keeps the top / bottom edgeInsets only as a
        // priority-250 preference (`>= 0` is the only required edge), so the stack's own hugging
        // pulled the banner down onto a two-line text column and the text touched both edges.
        // Each item keeps the top / bottom inset as a required minimum instead.
        for item in row {
            item.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: content.edgeInsets.top).isActive = true
            content.bottomAnchor.constraint(greaterThanOrEqualTo: item.bottomAnchor, constant: content.edgeInsets.bottom).isActive = true
        }

        let background = GlassStyle.bannerBackground(containing: content, tone: model.tone)
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes `model`'s handlers without rebuilding anything, for a model with this banner's
    /// signature (UI-9): the view stays where it is and its buttons now call the latest handlers.
    /// Returns false, changing nothing, when the signature differs.
    @discardableResult
    func adoptHandlers(of model: Model) -> Bool {
        guard model.signature == self.model.signature else { return false }
        self.model = model
        handlers = model.actions.map(\.handler)
        return true
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }

    /// The buttons, in order (for the offline tests).
    var buttons: [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, button.target === self { found.append(button) }
            view.subviews.forEach(walk)
        }
        walk(self)
        return found.sorted { $0.tag < $1.tag }
    }
}

extension BannerView.Model {
    /// UI slice ④: a session banner from `ShellReconnectPresenter`, its tone mapped onto the
    /// banner tints and each action onto its button title and the handler the App hands in. The
    /// handlers are the App's existing paths (the Hosts window's Disconnect and Connect buttons,
    /// the banner's own removal, Settings > Keyboard); nothing here ends or starts a session itself.
    static func session(_ banner: ShellReconnectPresenter.SessionBanner,
                        disconnect: @escaping () -> Void,
                        dismiss: @escaping () -> Void,
                        reconnect: @escaping () -> Void,
                        learnMore: @escaping () -> Void) -> BannerView.Model {
        let actions = banner.actions.map { action -> BannerView.Action in
            switch action {
            case .disconnect: return .init(title: UIStrings.disconnect, handler: disconnect)
            case .dismiss: return .init(title: UIStrings.dismiss, handler: dismiss, accessibilityLabel: banner.dismissAccessibilityLabel)
            case .reconnect: return .init(title: UIStrings.reconnect, handler: reconnect)
            case .learnMore: return .init(title: UIStrings.learnMore, handler: learnMore)
            }
        }
        let tone: GlassStyle.Tone
        switch banner.tone {
        case .information: tone = .information
        case .warning: tone = .warning
        case .error: tone = .error
        }
        return .init(id: banner.id, title: banner.title, body: banner.body, tone: tone, actions: actions)
    }

    /// UI-1 spec §4.3: the id the first-connect failure banners share (one at a time).
    static let connectFailureID = "connect-failed"

    /// UI-1 spec §4.3: the first-connect failure banner for `kind`, or nil for the kinds that show
    /// none here (a certificate rejection has the certificate path's banner and sheet; any other
    /// failure writes the status bar only). The handlers are the App's existing paths.
    ///
    /// F-1 (owner in-person batch 2026-10-07): the unreachable banner carries Reconnect after Edit
    /// Host…. A give-up banner's Reconnect press clears that banner (`connectTapped`), and when the
    /// network is still down the new chain's first connect fails into THIS banner -- which, with
    /// Edit Host… alone, left no button that connects again until the toolbar's Connect.
    static func connectFailure(_ kind: ConnectFlow.FailureKind, hostTitle: String, address: String, port: Int,
                               editHost: @escaping () -> Void, enterPassword: @escaping () -> Void,
                               reconnect: @escaping () -> Void) -> BannerView.Model? {
        switch kind {
        case .unreachable:
            return .init(id: connectFailureID, title: UIStrings.unreachableTitle(hostTitle),
                         body: UIStrings.unreachableBody(address: address, port: port), tone: .error,
                         actions: [.init(title: UIStrings.editHostAction, handler: editHost),
                                   .init(title: UIStrings.reconnect, handler: reconnect)])
        case .signIn:
            return .init(id: connectFailureID, title: UIStrings.signInTitle(hostTitle), body: UIStrings.signInBody, tone: .error,
                         actions: [.init(title: UIStrings.enterPassword, handler: enterPassword)])
        case .certificate, .other:
            return nil
        }
    }
}
