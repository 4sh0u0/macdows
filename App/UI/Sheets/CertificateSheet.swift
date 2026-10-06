import AppKit
import MacdowsCore

/// UI-1 spec §4.4 / §5.2, ADR-0024 D-5 / D-3′: the certificate sheet in its three variants.
///
///  - first use: Trust and Pin is the default button but stays disabled until `cf_check` is ticked;
///    Cancel (Esc) = do not connect, do not pin.
///  - changed: Cancel is the DEFAULT button (Return and Esc both cancel); Replace Pin and Connect has
///    no key equivalent and stays disabled until `cc_check` is ticked. The connection was already
///    refused before this sheet appeared. The old value is the pin, the preset, or "missing" (pin
///    lost, D-3′).
///  - details: read-only, Done.
///
/// No "Always trust" and no "Don't ask again" (§5.2).
@MainActor
final class CertificateSheet: NSObject {
    enum Variant: Equatable {
        case firstUse(presented: CertificateFingerprint, subject: String, issuer: String)
        case changed(old: CertificateFingerprint?, oldSource: CertificateDecision.OldSource,
                     presented: CertificateFingerprint, subject: String, issuer: String)
        case details(pinned: CertificateFingerprint, pinnedAt: Date?, subject: String?, issuer: String?)
    }

    let variant: Variant
    let window: SheetWindow
    /// Trust and Pin / Replace Pin and Connect / Done.
    let confirmButton: NSButton
    /// nil in the details variant.
    let cancelButton: NSButton?
    /// The comparison checkbox; nil in the details variant.
    let checkBox: NSButton?
    private var completion: ((Bool) -> Void)?

    init(variant: Variant, hostTitle: String, address: String) {
        self.variant = variant
        var views: [NSView] = []
        let header: NSStackView
        func iconHeader(_ symbol: String, tint: NSColor, title: String) -> NSStackView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = tint
            icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
            let row = NSStackView(views: [icon, SheetLayout.title(title)])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }
        switch variant {
        case .firstUse(let presented, let subject, let issuer):
            header = iconHeader("checkmark.shield", tint: .controlAccentColor, title: UIStrings.firstTitle(hostTitle))
            views = [header, SheetLayout.body(UIStrings.firstBody, secondary: true),
                     SheetLayout.grid([
                        [SheetLayout.label(UIStrings.certHost), SheetLayout.value(address)],
                        [SheetLayout.label(UIStrings.certIssuedTo), SheetLayout.value(subject)],
                        [SheetLayout.label(UIStrings.certIssuer), SheetLayout.value(issuer)],
                     ]),
                     SheetLayout.note(UIStrings.fingerprint),
                     SheetLayout.fingerprintField(presented.displayLines)]
            let box = NSButton(checkboxWithTitle: UIStrings.firstCheck, target: nil, action: nil)
            checkBox = box
            views.append(box)
            confirmButton = NSButton(title: UIStrings.trust, target: nil, action: nil)
            cancelButton = NSButton(title: UIStrings.cancel, target: nil, action: nil)
        case .changed(let old, let oldSource, let presented, let subject, let issuer):
            header = iconHeader("exclamationmark.triangle.fill", tint: .systemRed, title: UIStrings.changedTitle(hostTitle))
            let warning = SheetLayout.body(UIStrings.changedWarning)
            warning.textColor = .systemRed
            views = [header, warning, SheetLayout.body(UIStrings.changedBody, secondary: true)]
            switch (oldSource, old) {
            case (.lost, _), (_, nil):
                views.append(SheetLayout.note(UIStrings.fingerprintPinned))
                views.append(SheetLayout.body(UIStrings.pinLost, secondary: true))
            case (.pin, let old?):
                views.append(SheetLayout.note(UIStrings.fingerprintPinned))
                views.append(SheetLayout.fingerprintField(old.displayLines, dimmed: true))
            case (.preset, let old?):
                views.append(SheetLayout.note(UIStrings.expectedFingerprint))
                views.append(SheetLayout.fingerprintField(old.displayLines, dimmed: true))
            }
            views.append(SheetLayout.note(UIStrings.fingerprintNew))
            views.append(SheetLayout.fingerprintField(presented.displayLines, border: .systemRed))
            views.append(SheetLayout.grid([
                [SheetLayout.label(UIStrings.certHost), SheetLayout.value(address)],
                [SheetLayout.label(UIStrings.certIssuedTo), SheetLayout.value(subject)],
                [SheetLayout.label(UIStrings.certIssuer), SheetLayout.value(issuer)],
            ]))
            let box = NSButton(checkboxWithTitle: UIStrings.changedCheck, target: nil, action: nil)
            checkBox = box
            views.append(box)
            confirmButton = NSButton(title: UIStrings.replace, target: nil, action: nil)
            cancelButton = NSButton(title: UIStrings.cancel, target: nil, action: nil)
        case .details(let pinned, let pinnedAt, let subject, let issuer):
            header = iconHeader("lock.shield", tint: .controlAccentColor, title: UIStrings.pinnedTitle(hostTitle))
            let date = pinnedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? "—"
            views = [header, SheetLayout.body(UIStrings.pinnedBody(date), secondary: true)]
            var rows: [[NSView]] = [[SheetLayout.label(UIStrings.certHost), SheetLayout.value(address)]]
            if let subject, !subject.isEmpty { rows.append([SheetLayout.label(UIStrings.certIssuedTo), SheetLayout.value(subject)]) }
            if let issuer, !issuer.isEmpty { rows.append([SheetLayout.label(UIStrings.certIssuer), SheetLayout.value(issuer)]) }
            views.append(SheetLayout.grid(rows))
            views.append(SheetLayout.note(UIStrings.fingerprintPinned))
            views.append(SheetLayout.fingerprintField(pinned.displayLines))
            views.append(SheetLayout.note(UIStrings.pinnedNote))
            checkBox = nil
            confirmButton = NSButton(title: UIStrings.done, target: nil, action: nil)
            cancelButton = nil
        }
        var buttons: [NSButton] = []
        if let cancelButton { buttons.append(cancelButton) }
        buttons.append(confirmButton)
        views.append(SheetLayout.buttonRow(buttons))
        let width: CGFloat
        if case .changed = variant { width = 620 } else { width = 560 }
        window = SheetLayout.makeWindow(width: width, content: SheetLayout.vertical(views))
        super.init()

        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed(_:))
        cancelButton?.target = self
        cancelButton?.action = #selector(cancelPressed(_:))
        checkBox?.target = self
        checkBox?.action = #selector(checkChanged(_:))
        checkBox?.state = .off
        switch variant {
        case .firstUse:
            GlassStyle.stylePrimary(confirmButton)
            confirmButton.isEnabled = false
            cancelButton.map(GlassStyle.styleSecondary)
            cancelButton?.keyEquivalent = "\u{1b}"
        case .changed:
            // Cancel is the primary, default button: Return cancels, and so does Esc.
            GlassStyle.styleSecondary(confirmButton)
            confirmButton.keyEquivalent = ""
            confirmButton.isEnabled = false
            if let cancelButton {
                GlassStyle.stylePrimary(cancelButton)
                window.defaultButtonCell = cancelButton.cell as? NSButtonCell
            }
        case .details:
            GlassStyle.stylePrimary(confirmButton)
        }
        // Esc is Cancel in every variant (Done in the details one).
        window.onCancel = { [weak self] in self?.finish(false) }
    }

    func begin(on parent: NSWindow, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        parent.beginSheet(window)
    }

    @objc private func checkChanged(_ sender: NSButton) {
        confirmButton.isEnabled = sender.state == .on
    }

    @objc private func confirmPressed(_ sender: Any?) {
        guard confirmButton.isEnabled else { return }
        if case .details = variant { finish(false) } else { finish(true) }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        finish(false)
    }

    private func finish(_ confirmed: Bool) {
        let completion = self.completion
        self.completion = nil
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        completion?(confirmed)
    }
}
