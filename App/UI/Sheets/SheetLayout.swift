import AppKit

/// A sheet window whose Esc is Cancel whatever has focus (UI-1 spec §5.2: "Esc = Cancel", also in
/// the changed variant, where Return is taken by the default Cancel button).
@MainActor
final class SheetWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53, let onCancel {
            onCancel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

/// Shared building blocks of slice ①'s sheets (UI-1 spec §3: system sheets, which take glass on
/// 26 by themselves; widths 560 / 620 / 480).
@MainActor
enum SheetLayout {
    /// A titled sheet window of `width` with `content` pinned inside a 20 pt margin.
    static func makeWindow(width: CGFloat, content: NSView) -> SheetWindow {
        let window = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            host.widthAnchor.constraint(equalToConstant: width),
        ])
        window.contentView = host
        return window
    }

    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    static func body(_ text: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The fingerprint block: monospaced, selectable, four lines of eight bytes, on an opaque field
    /// background (UI-1 spec §3: never directly on glass), with an optional coloured border.
    static func fingerprintField(_ lines: [String], border: NSColor? = nil, dimmed: Bool = false) -> NSView {
        let text = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isSelectable = true
        text.textColor = dimmed ? .secondaryLabelColor : .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = (border ?? NSColor.separatorColor).cgColor
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityValue(lines.joined(separator: " "))
        return box
    }

    /// Label column right-aligned (UI-1 spec §7.4), value column leading.
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
        }
        grid.rowAlignment = .firstBaseline
        return grid
    }

    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }

    static func value(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        return label
    }

    /// The button row: trailing, Cancel left of the confirming button.
    static func buttonRow(_ buttons: [NSButton]) -> NSView {
        let group = GlassStyle.buttonGroup(buttons)
        let row = NSStackView(views: [NSView(), group])
        row.orientation = .horizontal
        row.distribution = .fill
        return row
    }

    static func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
