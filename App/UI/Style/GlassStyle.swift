import AppKit

/// UI-1 spec §3 / §8 (deployment-target ruling B): the ONE file in `App/UI` that names a Liquid
/// Glass API. Every such call sits inside an `if #available(macOS 26, *)` branch whose `else` gives
/// §3's "14–25 fallback" -- a standard material or the standard control style, with the same view
/// hierarchy and the same sizes. The deployment target stays 14.0. Components the system dresses
/// in glass by itself on 26 (the standard toolbar, the sidebar, menus, sheets) are not branched at
/// all (§8 general rule). `GlassStyleTests` pins both halves of this as source.
@MainActor
enum GlassStyle {
    /// Banner tint (UI-1 spec §3: warning / error tinted, information untinted).
    enum Tone {
        case information
        case warning
        case error

        var color: NSColor? {
            switch self {
            case .information: return nil
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }
    }

    /// The primary button (Connect, Trust and Pin, the sheets' confirming button): `.glass` with
    /// primary tint prominence, following the system accent colour (no fixed tint, §3 / §9) on 26;
    /// a standard push button, the window's default button, on 14–25.
    static func stylePrimary(_ button: NSButton, isDefault: Bool = true) {
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
            button.tintProminence = .primary
        } else {
            button.bezelStyle = .push
        }
        if isDefault { button.keyEquivalent = "\r" }
    }

    /// Secondary buttons (Disconnect, Edit…, Remove…, Show…, Cancel): `.glass` on 26, push below.
    static func styleSecondary(_ button: NSButton) {
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .push
        }
    }

    /// Buttons of one row merged into one glass group on 26 (`NSGlassEffectContainerView`); a plain
    /// horizontal stack on 14–25. Either way the returned view lays the buttons out left to right
    /// with `spacing`.
    static func buttonGroup(_ buttons: [NSView], spacing: CGFloat = 8) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *) {
            let container = NSGlassEffectContainerView()
            container.contentView = stack
            container.spacing = spacing
            container.translatesAutoresizingMaskIntoConstraints = false
            return container
        } else {
            return stack
        }
    }

    /// A banner's background with `content` inside: `NSGlassEffectView` (Regular, corner radius 16,
    /// a low-saturation tint for warnings / errors) on 26; on 14–25 an `NSVisualEffectView` with the
    /// `.headerView` material and a 12 % wash of the same colour, same radius (§3 banner row).
    static func bannerBackground(containing content: NSView, tone: Tone) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.tintColor = tone.color?.withAlphaComponent(0.18)
            glass.contentView = content
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        } else {
            let material = NSVisualEffectView()
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            if let color = tone.color {
                material.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
            }
            material.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                content.topAnchor.constraint(equalTo: material.topAnchor),
                content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            return material
        }
    }
}
