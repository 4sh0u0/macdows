import AppKit
import ApplicationServices
import MacdowsCore

/// ADR-0025 §1.3: where the start panel opens -- the App-side facts behind MacdowsCore's
/// `DockAnchorGeometry`. All of it runs on the main thread.
///
///  - Sender gate (R-1′): a reopen counts as a Dock click only when the current Apple event's
///    sender pid is the Dock process's (probe R1: the `keySenderPIDAttr` descriptor is 4 bytes of
///    type 'magn', read as SInt32). Unreadable or different -> not the Dock.
///  - L-p: the pointer (`NSEvent.mouseLocation`) -- the Dock click happened under it.
///  - L-ax: the Dock item's own frame, only while "Precise Dock positioning" is on AND
///    `AXIsProcessTrusted()` says the App may ask. Probe A2: an Accessibility ELEMENT call made
///    without access is not harmless -- the system records the App in the Accessibility list -- so
///    every element call below is behind that check, in one function, and an untrusted App makes
///    none.
///  - L-fb: the Dock edge of the Dock's screen, centred.
/// Screens come from `DisplayTopologyProvider.anchorScreens()`, the project's one `NSScreen` reader
/// (adr/0015 §5.A.5).
@MainActor
final class DockAnchorLocator {
    static let dockBundleIdentifier = "com.apple.dock"

    private let preferences: StartPanelPreferences

    init(preferences: StartPanelPreferences) {
        self.preferences = preferences
    }

    // MARK: - Sender gate

    /// True only when the Apple event being handled (the reopen) was sent by the Dock process.
    func currentEventIsFromDock() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)),
              let pid = Self.senderPID(from: descriptor)
        else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .contains { $0.processIdentifier == pid }
    }

    /// The sender pid in a `keySenderPIDAttr` descriptor: exactly four bytes (type 'magn', UInt32 on
    /// the wire), read as a signed pid; anything else, or a pid that is not positive, is nil.
    nonisolated static func senderPID(from descriptor: NSAppleEventDescriptor) -> pid_t? {
        let data = descriptor.data
        guard data.count == MemoryLayout<Int32>.size else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        return value > 0 ? pid_t(value) : nil
    }

    // MARK: - Anchors

    /// The anchor for a Dock reopen: AX frame (if allowed), else the pointer; the fallback when the
    /// reopen did not come from the Dock.
    func anchorForReopen(fromDock: Bool) -> PanelAnchor {
        DockAnchorGeometry.dockAnchor(
            fromDock: fromDock, pointer: NSEvent.mouseLocation,
            axIconFrame: fromDock ? preciseIconFrame() : nil, primaryMaxY: primaryMaxY()
        )
    }

    /// The anchor for the Dock menu's "Run…": the pointer recorded when the menu opened, if it was
    /// on the Dock band of its screen (a right-click on the icon); otherwise -- the menu opened from
    /// the keyboard, or an auto-hidden Dock whose band cannot be told -- the fallback.
    func anchorForDockMenu(pointer: CGPoint?) -> PanelAnchor {
        guard let pointer, Self.isOnDockBand(pointer, screens: screens()) else { return .fallback }
        return DockAnchorGeometry.dockAnchor(fromDock: true, pointer: pointer, axIconFrame: preciseIconFrame(),
                                             primaryMaxY: primaryMaxY())
    }

    /// True when `point` lies in the Dock's strip of the screen that contains it: between `frame`
    /// and `visibleFrame` on the Dock's edge. No strip (no Dock gap) -> false.
    nonisolated static func isOnDockBand(_ point: CGPoint, screens: [AnchorScreen]) -> Bool {
        guard let screen = screens.first(where: { $0.frame.contains(point) }),
              let edge = DockAnchorGeometry.dockEdge(frame: screen.frame, visibleFrame: screen.visibleFrame)
        else { return false }
        switch edge {
        case .bottom: return point.y < screen.visibleFrame.minY
        case .left: return point.x < screen.visibleFrame.minX
        case .right: return point.x >= screen.visibleFrame.maxX
        }
    }

    /// The panel frame for `anchor` and `size` on the current screens.
    func frame(for anchor: PanelAnchor, size: CGSize) -> CGRect {
        DockAnchorGeometry.panelFrame(size: size, anchor: anchor, screens: screens(), dockEdgeHint: Self.dockEdgeHint())
    }

    func screens() -> [AnchorScreen] {
        DisplayTopologyProvider.anchorScreens()
    }

    private func primaryMaxY() -> CGFloat {
        screens().first?.frame.maxY ?? 0
    }

    /// The Dock's configured edge from its preferences domain (probe A3: readable without any
    /// permission). Unset means bottom, the system default.
    static func dockEdgeHint() -> DockEdge {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, dockBundleIdentifier as CFString) as? String
        return dockEdge(fromOrientation: value)
    }

    nonisolated static func dockEdge(fromOrientation value: String?) -> DockEdge {
        switch value {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }

    // MARK: - L-ax (the only Accessibility element calls in the App)

    /// The Macdows Dock item's frame in AX coordinates, or nil. Nothing here runs unless the
    /// setting is on; the first statement of `copyDockIconFrame` is the trust check.
    func preciseIconFrame() -> CGRect? {
        guard preferences.preciseDockPositioning else { return nil }
        return Self.copyDockIconFrame(bundleURL: Bundle.main.bundleURL, title: Self.appDisplayName())
    }

    private static func appDisplayName() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Macdows"
    }

    /// Walks the Dock's AX tree to this App's item: the first AXList's children, matched by
    /// `kAXURLAttribute` (stable) and, for an item without a URL, by title. AX frames are "top-left
    /// of the primary screen, y down"; `DockAnchorGeometry` flips them.
    ///
    /// The trust check is the first statement, and every element call -- the helpers included -- is
    /// in this one body after it (`StartPanelSourcePinTests` holds that as source).
    private static func copyDockIconFrame(bundleURL: URL, title: String) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            copyValue(element, attribute) as? [AXUIElement] ?? []
        }
        func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
            guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! AXValue)
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleIdentifier).first else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = elements(application, kAXChildrenAttribute)
            .first(where: { copyValue($0, kAXRoleAttribute) as? String == "AXList" }) else { return nil }
        let items = elements(list, kAXChildrenAttribute)
        let wanted = bundleURL.standardizedFileURL
        let match = items.first { (copyValue($0, kAXURLAttribute) as? URL)?.standardizedFileURL == wanted }
            ?? items.first { copyValue($0, kAXTitleAttribute) as? String == title }
        guard let item = match,
              let position = axValue(item, kAXPositionAttribute), let extent = axValue(item, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
