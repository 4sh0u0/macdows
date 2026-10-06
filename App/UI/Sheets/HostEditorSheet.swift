import AppKit
import MacdowsCore

/// UI-1 spec §5.1 / §5.2 / §5.4, ADR-0024 D-1′ / D-3: the New / Edit Host sheet.
///
///  - The password is input only: a saved password is never filled in or shown (§5.1 ①); in edit
///    mode the placeholder says it is saved. The eye button reveals only what was typed here.
///  - Remember password in Keychain is ON by default (§5.1 ②).
///  - Touch ID / Mac password is shown DISABLED with "Coming later" (ADR-0024 D-1′ T-1: the
///    file-based keychain this slice uses cannot enforce it; probe K measured
///    `kSecAttrAccessControl` refused for an ad-hoc build).
///  - Network Level Authentication is a read-only row (§5.4, ADR-0024 D-7 L-c).
///  - "Expected certificate fingerprint (optional)" is the preset (§5.2): parsed with
///    `CertificateFingerprint.parse`, SHA-1 lengths refused with their own message. Changing it
///    never touches an existing pin (§5.3).
@MainActor
final class HostEditorSheet: NSObject, NSTextFieldDelegate {
    enum Mode {
        case new
        case edit(HostRecord)
    }

    /// What the editor knows about the stored preset (read off the main thread before it opened).
    enum PresetState: Equatable {
        case loaded(CertificateFingerprint?)
        /// The pin item could not be read: the field is disabled and Save leaves the preset alone.
        case unavailable
    }

    struct Outcome {
        let record: HostRecord
        let changes: HostActions.EditorChanges
    }

    let mode: Mode
    let window: SheetWindow
    let nameField = NSTextField()
    let addressField = NSTextField()
    let portField = NSTextField()
    let userField = NSTextField()
    let passwordField = NSSecureTextField()
    let revealedPasswordField = NSTextField()
    let revealButton: NSButton
    let rememberBox: NSButton
    let touchIDBox: NSButton
    let presetField = NSTextField()
    let errorLabel: NSTextField
    let saveButton: NSButton
    let cancelButton: NSButton
    private let presetState: PresetState
    private var completion: ((Outcome?) -> Void)?

    init(mode: Mode, presetState: PresetState) {
        self.mode = mode
        self.presetState = presetState
        revealButton = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: UIStrings.showPassword) ?? NSImage(),
                                target: nil, action: nil)
        rememberBox = NSButton(checkboxWithTitle: UIStrings.editorRemember, target: nil, action: nil)
        touchIDBox = NSButton(checkboxWithTitle: UIStrings.editorAsk, target: nil, action: nil)
        errorLabel = SheetLayout.note("")
        saveButton = NSButton(title: UIStrings.save, target: nil, action: nil)
        cancelButton = NSButton(title: UIStrings.cancel, target: nil, action: nil)

        let title: String
        switch mode {
        case .new: title = UIStrings.newHost
        case .edit: title = UIStrings.editHostTitle
        }

        for (field, placeholder) in [(nameField, UIStrings.editorNamePlaceholder), (addressField, UIStrings.editorAddressPlaceholder),
                                     (userField, UIStrings.editorUserPlaceholder), (presetField, UIStrings.editorFingerprintPlaceholder)] {
            field.placeholderString = placeholder
        }
        portField.placeholderString = String(HostRecord.defaultPort)
        presetField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        revealedPasswordField.isHidden = true
        revealButton.bezelStyle = .inline
        revealButton.isBordered = false
        revealButton.setAccessibilityLabel(UIStrings.showPassword)
        touchIDBox.isEnabled = false
        touchIDBox.state = .off
        let comingLater = SheetLayout.note(UIStrings.comingLater)
        let touchIDRow = NSStackView(views: [touchIDBox, comingLater])
        touchIDRow.orientation = .horizontal
        touchIDRow.spacing = 6

        let passwordStack = NSStackView(views: [passwordField, revealedPasswordField, revealButton])
        passwordStack.orientation = .horizontal
        passwordStack.spacing = 4
        let nla = SheetLayout.value("\(UIStrings.editorNLA) \(UIStrings.editorRequired)")
        nla.textColor = .secondaryLabelColor
        let presetColumn = SheetLayout.vertical([presetField, SheetLayout.note(UIStrings.editorFingerprintNote)], spacing: 4)
        let presetTitle = SheetLayout.note(UIStrings.editorFingerprint)

        let grid = SheetLayout.grid([
            [SheetLayout.label(UIStrings.editorName), nameField],
            [SheetLayout.label(UIStrings.editorAddress), addressField],
            [SheetLayout.label(UIStrings.editorPort), portField],
            [SheetLayout.label(UIStrings.editorUser), userField],
            [SheetLayout.label(UIStrings.editorPassword), passwordStack],
            [NSGridCell.emptyContentView, rememberBox],
            [NSGridCell.emptyContentView, touchIDRow],
            [NSGridCell.emptyContentView, SheetLayout.note(UIStrings.editorPasswordNote)],
            [SheetLayout.label(UIStrings.editorSignIn), nla],
            [SheetLayout.label(UIStrings.editorCertificate), presetTitle],
            [NSGridCell.emptyContentView, presetColumn],
        ])
        for field in [nameField, addressField, userField, presetField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        }
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        revealedPasswordField.widthAnchor.constraint(equalTo: passwordField.widthAnchor).isActive = true
        errorLabel.textColor = .systemRed

        let content = SheetLayout.vertical([
            SheetLayout.title(title), grid, errorLabel, SheetLayout.buttonRow([cancelButton, saveButton]),
        ])
        window = SheetLayout.makeWindow(width: 560, content: content)
        super.init()

        switch mode {
        case .new:
            rememberBox.state = .on
        case .edit(let record):
            nameField.stringValue = record.displayName
            addressField.stringValue = record.address
            portField.stringValue = String(record.port)
            userField.stringValue = record.userName
            rememberBox.state = record.remembersPassword ? .on : .off
            if record.remembersPassword {
                passwordField.placeholderString = UIStrings.editorPasswordPlaceholderEdit
            }
        }
        switch presetState {
        case .loaded(let fingerprint):
            presetField.stringValue = fingerprint.map { $0.displayLines.joined(separator: ":") } ?? ""
        case .unavailable:
            presetField.isEnabled = false
        }

        revealButton.target = self
        revealButton.action = #selector(toggleReveal(_:))
        for field in [addressField, portField, presetField] { field.delegate = self }
        GlassStyle.styleSecondary(cancelButton)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        GlassStyle.stylePrimary(saveButton)
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        window.onCancel = { [weak self] in self?.cancelPressed(nil) }
        window.initialFirstResponder = nameField
        revalidate()
    }

    func begin(on parent: NSWindow, completion: @escaping (Outcome?) -> Void) {
        self.completion = completion
        parent.beginSheet(window)
    }

    func controlTextDidChange(_ obj: Notification) {
        revalidate()
    }

    // MARK: - Validation (pure, offline-testable)

    enum ValidationError: Error, Equatable {
        case addressRequired
        case portInvalid
        case presetSHA1
        case presetInvalid
    }

    struct Validated: Equatable {
        let address: String
        let port: UInt16
        /// nil = empty field.
        let preset: CertificateFingerprint?
    }

    static func validate(address: String, port: String, preset: String) -> Result<Validated, ValidationError> {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .failure(.addressRequired) }
        let portText = port.trimmingCharacters(in: .whitespaces)
        let portValue: UInt16
        if portText.isEmpty {
            portValue = HostRecord.defaultPort
        } else {
            guard let value = UInt16(portText), value > 0 else { return .failure(.portInvalid) }
            portValue = value
        }
        let presetText = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: CertificateFingerprint?
        if !presetText.isEmpty {
            switch CertificateFingerprint.parse(presetText) {
            case .success(let fingerprint): parsed = fingerprint
            case .failure(.sha1Length): return .failure(.presetSHA1)
            case .failure: return .failure(.presetInvalid)
            }
        }
        return .success(Validated(address: address, port: portValue, preset: parsed))
    }

    private func revalidate() {
        switch Self.validate(address: addressField.stringValue, port: portField.stringValue, preset: presetField.stringValue) {
        case .success:
            errorLabel.stringValue = ""
            saveButton.isEnabled = true
        case .failure(let error):
            // An empty address on a fresh sheet is not yet an error worth shouting about.
            errorLabel.stringValue = (error == .addressRequired && addressField.stringValue.isEmpty) ? "" : Self.message(for: error)
            saveButton.isEnabled = false
        }
    }

    static func message(for error: ValidationError) -> String {
        switch error {
        case .addressRequired: return UIStrings.editorAddressRequired
        case .portInvalid: return UIStrings.editorPortInvalid
        case .presetSHA1: return UIStrings.editorFingerprintSHA1
        case .presetInvalid: return UIStrings.editorFingerprintInvalid
        }
    }

    // MARK: - Actions

    @objc private func toggleReveal(_ sender: Any?) {
        let reveal = revealedPasswordField.isHidden
        if reveal {
            revealedPasswordField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = revealedPasswordField.stringValue
            revealedPasswordField.stringValue = ""
        }
        passwordField.isHidden = reveal
        revealedPasswordField.isHidden = !reveal
        let label = reveal ? UIStrings.hidePassword : UIStrings.showPassword
        revealButton.image = NSImage(systemSymbolName: reveal ? "eye.slash" : "eye", accessibilityDescription: label)
        revealButton.setAccessibilityLabel(label)
    }

    private var typedPassword: String {
        revealedPasswordField.isHidden ? passwordField.stringValue : revealedPasswordField.stringValue
    }

    @objc private func savePressed(_ sender: Any?) {
        guard case .success(let valid) = Self.validate(address: addressField.stringValue, port: portField.stringValue,
                                                        preset: presetField.stringValue) else { return }
        let base: HostRecord
        switch mode {
        case .new: base = HostRecord(displayName: "", address: valid.address, userName: "")
        case .edit(let record): base = record
        }
        var record = base
        record.displayName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        record.address = valid.address
        record.port = valid.port
        record.userName = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        record.remembersPassword = rememberBox.state == .on

        let typed = typedPassword
        let password = typed.isEmpty ? nil : SessionSecret(bytes: Array(typed.utf8))
        passwordField.stringValue = ""
        revealedPasswordField.stringValue = ""

        var expected: CertificateFingerprint??
        if case .loaded(let stored) = presetState, stored != valid.preset {
            expected = .some(valid.preset)
        }
        let changes = HostActions.EditorChanges(host: record.id, displayName: record.title, newPassword: password,
                                                remember: record.remembersPassword, expected: expected)
        finish(Outcome(record: record, changes: changes))
    }

    @objc private func cancelPressed(_ sender: Any?) {
        passwordField.stringValue = ""
        revealedPasswordField.stringValue = ""
        finish(nil)
    }

    private func finish(_ result: Outcome?) {
        let completion = self.completion
        self.completion = nil
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        completion?(result)
    }
}
