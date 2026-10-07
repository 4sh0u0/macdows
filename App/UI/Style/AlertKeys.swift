import AppKit

/// The keys of a warning alert whose Cancel button is the default button (findings F-2 and F-6).
///
/// `NSAlert.addButton(withTitle:)` gives the first button Return and a button titled Cancel
/// Escape (the Cancel rule wins when Cancel is first), and on macOS 27 `NSAlert.layout()` takes
/// Return away from a button with `hasDestructiveAction` -- so left alone such an alert has no
/// default button and Return only beeps. Each caller gives its Cancel button Return by hand and
/// takes it away from every other button; setting Cancel's key equivalent replaces the derived
/// Escape, which `cancelOnEscape(_:cancel:)` restores while the alert is shown.
@MainActor
enum AlertKeys {
    /// Whether `event` is a plain Escape key-down in `window` (the alert's Cancel action).
    static func isEscape(_ event: NSEvent, in window: NSWindow) -> Bool {
        event.type == .keyDown && event.keyCode == escapeKeyCode && event.window === window
            && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// `kVK_Escape`: the physical key, whatever the keyboard layout.
    private static let escapeKeyCode: UInt16 = 0x35

    /// While `alert` is shown, Escape clicks `cancel`, the alert's Cancel button -- named by the
    /// caller, because it is not the first button in every alert. Remove the returned monitor when
    /// the alert ends.
    static func cancelOnEscape(_ alert: NSAlert, cancel: NSButton) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert, weak cancel] event in
            guard let alert, let cancel, isEscape(event, in: alert.window) else { return event }
            cancel.performClick(nil)
            return nil
        }
    }
}
