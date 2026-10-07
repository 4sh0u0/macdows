import AppKit
import Testing

// UI slice ④ (UI-1 spec §4.1, the "no session" row): the Hosts window's status bar reads
// "Not connected" from the moment its view is loaded, before the App writes anything to it.

@MainActor
@Suite("Hosts window status bar with no session (UI slice ④)")
struct HostDetailStatusBarTests {
    @Test("a freshly loaded detail view shows st_off with the idle marker, never an empty bar")
    func statusBarStartsNotConnected() throws {
        let detail = HostDetailViewController(
            editAction: NSSelectorFromString("edit:"), removeAction: NSSelectorFromString("remove:"),
            showAction: NSSelectorFromString("show:"), addAction: NSSelectorFromString("add:")
        )
        detail.loadViewIfNeeded()
        #expect(detail.statusBarLabel.stringValue == UIStrings.notConnected)
        #expect(!detail.statusBarLabel.stringValue.isEmpty)
        let image = try #require(detail.statusBarMarker.image)
        let idle = try #require(NSImage(systemSymbolName: HostListViewController.Marker.idle.symbol, accessibilityDescription: nil))
        #expect(image.size == idle.size)
        #expect(detail.statusBarMarker.contentTintColor == HostListViewController.Marker.idle.color)
    }
}
