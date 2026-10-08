import AppKit
import ApplicationServices
import Combine

/// ADR-0025 R-2 / design note §7 / §10 items 6 and 7: the App's one stored start-panel preference
/// -- "Precise Dock positioning", one `UserDefaults` key, false by default -- and the Accessibility
/// state the Settings page shows beside it.
///
/// Lives here and not in `App/UI/Settings/` on purpose (owner ruling §10-7): the Settings files keep
/// no settings and touch no persistence API (`SettingsWindowTests` pins that); they render this
/// object and call its methods.
///
/// Accessibility rules this type keeps (ADR-0025 §1.3, probe A2):
///  - Reading the trust state is `AXIsProcessTrusted()` only -- read-only, no prompt, no TCC write.
///    It is read when the Settings page appears and when the App becomes active, never in a loop.
///  - The system prompt (`AXIsProcessTrustedWithOptions` with the prompt option) is asked for in
///    exactly one place: the user switching the setting on. Declining keeps the box ticked and
///    nothing asks again; the panel quietly anchors at the pointer instead.
///  - This type makes no Accessibility ELEMENT call at all. The only element calls in the App are
///    `DockAnchorLocator`'s, behind its own `AXIsProcessTrusted()` check.
@MainActor
final class StartPanelPreferences: ObservableObject {
    /// The one key (§10-7).
    static let preciseDockPositioningKey = "startPanel.preciseDockPositioning"

    /// System Settings ▸ Privacy & Security ▸ Accessibility.
    static let accessibilityPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// The App's instance, on the standard defaults.
    static let shared = StartPanelPreferences()

    @Published private(set) var preciseDockPositioning: Bool
    /// The last `AXIsProcessTrusted()` reading; false until the first read.
    @Published private(set) var accessibilityTrusted = false

    private let defaults: UserDefaults
    private let trustReader: () -> Bool
    private let trustPrompter: () -> Void
    private let opener: (URL) -> Void
    /// Kept for the process's life: `shared` is the only instance that observes, and the
    /// observer holds this object weakly.
    private var activationObserver: (any NSObjectProtocol)?

    /// Tests pass their own suite and stand-ins for the three system calls.
    init(defaults: UserDefaults = .standard,
         trustReader: @escaping () -> Bool = StartPanelPreferences.isAccessibilityTrusted,
         trustPrompter: @escaping () -> Void = StartPanelPreferences.promptForAccessibility,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         observesActivation: Bool = true) {
        self.defaults = defaults
        self.trustReader = trustReader
        self.trustPrompter = trustPrompter
        self.opener = opener
        preciseDockPositioning = defaults.bool(forKey: Self.preciseDockPositioningKey)
        if observesActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTrust() }
            }
        }
    }

    /// The Settings checkbox. Switching it on asks the system for access once (the only prompt the
    /// App ever shows); switching it off stops every Accessibility call.
    func setPreciseDockPositioning(_ on: Bool) {
        let wasOn = preciseDockPositioning
        preciseDockPositioning = on
        defaults.set(on, forKey: Self.preciseDockPositioningKey)
        if on && !wasOn {
            trustPrompter()
        }
        refreshTrust()
    }

    /// Re-reads the trust state, without a prompt.
    func refreshTrust() {
        accessibilityTrusted = trustReader()
    }

    /// §10-6: the secondary line and the button show while the setting is on and access is not
    /// granted.
    var showsAuthorizationHint: Bool {
        preciseDockPositioning && !accessibilityTrusted
    }

    /// `sp_ax_open`: opens the Accessibility list in System Settings.
    func openAccessibilityPrivacy() {
        opener(Self.accessibilityPrivacyURL)
    }

    /// The read-only trust check (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// The one prompting call. The option's key is spelled out rather than read from
    /// `kAXTrustedCheckOptionPrompt`, a global the Swift 6 checker treats as shared mutable state.
    nonisolated static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
