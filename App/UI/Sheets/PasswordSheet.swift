import AppKit

/// UI-1 spec §4.3 / §5.1 ②: the connection password sheet, shown when the host does not remember
/// its password or the keychain did not hand it over (ADR-0024 D-1: treated as "not saved").
/// Remember in Keychain is OFF by default here; the note under it says which way the password
/// goes. The typed text becomes `SessionSecret` bytes and the field is cleared at once.
@MainActor
final class PasswordSheet: NSObject, NSTextFieldDelegate {
    struct Result {
        let secret: SessionSecret
        let remember: Bool
    }

    let window: SheetWindow
    let passwordField = NSSecureTextField()
    let rememberBox: NSButton
    let noteLabel: NSTextField
    let connectButton: NSButton
    let cancelButton: NSButton
    private var completion: ((Result?) -> Void)?

    init(hostTitle: String, userName: String) {
        rememberBox = NSButton(checkboxWithTitle: UIStrings.passwordRemember, target: nil, action: nil)
        noteLabel = SheetLayout.note(UIStrings.passwordNotSaved)
        connectButton = NSButton(title: UIStrings.connect, target: nil, action: nil)
        cancelButton = NSButton(title: UIStrings.cancel, target: nil, action: nil)

        let grid = SheetLayout.grid([
            [SheetLayout.label(UIStrings.certHost), SheetLayout.value(hostTitle)],
            [SheetLayout.label(UIStrings.certUser), SheetLayout.value(userName)],
            [SheetLayout.label(UIStrings.editorPassword), passwordField],
        ])
        passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let content = SheetLayout.vertical([
            SheetLayout.title(UIStrings.passwordTitle(hostTitle)),
            SheetLayout.body(UIStrings.passwordBody, secondary: true),
            grid, rememberBox, noteLabel,
            SheetLayout.buttonRow([cancelButton, connectButton]),
        ])
        window = SheetLayout.makeWindow(width: 480, content: content)
        super.init()

        rememberBox.state = .off
        rememberBox.target = self
        rememberBox.action = #selector(rememberChanged(_:))
        passwordField.delegate = self
        passwordField.setAccessibilityLabel(UIStrings.fieldPassword)
        GlassStyle.styleSecondary(cancelButton)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        GlassStyle.stylePrimary(connectButton)
        connectButton.target = self
        connectButton.action = #selector(connectPressed(_:))
        connectButton.isEnabled = false
        window.initialFirstResponder = passwordField
        window.onCancel = { [weak self] in self?.cancelPressed(nil) }
    }

    func begin(on parent: NSWindow, completion: @escaping (Result?) -> Void) {
        self.completion = completion
        parent.beginSheet(window)
    }

    func controlTextDidChange(_ obj: Notification) {
        connectButton.isEnabled = !passwordField.stringValue.isEmpty
    }

    @objc private func rememberChanged(_ sender: NSButton) {
        noteLabel.stringValue = sender.state == .on ? UIStrings.passwordSaved : UIStrings.passwordNotSaved
    }

    @objc private func connectPressed(_ sender: Any?) {
        guard !passwordField.stringValue.isEmpty else { return }
        let secret = SessionSecret(bytes: Array(passwordField.stringValue.utf8))
        passwordField.stringValue = ""
        finish(Result(secret: secret, remember: rememberBox.state == .on))
    }

    @objc private func cancelPressed(_ sender: Any?) {
        passwordField.stringValue = ""
        finish(nil)
    }

    private func finish(_ result: Result?) {
        let completion = self.completion
        self.completion = nil
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        completion?(result)
    }
}
