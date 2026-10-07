import AppKit

/// UI-1 spec §1 / §3 / §4.3: one banner under the toolbar -- a title, a body, optional buttons --
/// on the banner background `GlassStyle` builds (glass on 26, a standard material below).
@MainActor
final class BannerView: NSView {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    struct Model {
        let id: String
        let title: String
        let body: String
        let tone: GlassStyle.Tone
        let actions: [Action]
    }

    let model: Model
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

    @objc private func buttonPressed(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}
