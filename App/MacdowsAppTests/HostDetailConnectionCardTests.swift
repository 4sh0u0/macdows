import AppKit
import Testing

// UI-10 (UI-1 spec §1, the Connection card): `show(_:)` refills the card on every detail refresh
// (selection change, `activeHostID` set at connection start and end, `reloadHosts()`). Each refill
// must leave exactly the six current rows in the grid and no orphaned views from an earlier
// refill -- an orphan keeps its last frame and draws under the new text (the doubled labels and
// the unreadable Security row seen in person on 2026-10-07).

@MainActor
@Suite("Host detail Connection card refills without leftovers (UI-10)")
struct HostDetailConnectionCardTests {
    private static func makeDetail() -> HostDetailViewController {
        let detail = HostDetailViewController(
            editAction: NSSelectorFromString("edit:"), removeAction: NSSelectorFromString("remove:"),
            showAction: NSSelectorFromString("show:"), addAction: NSSelectorFromString("add:")
        )
        detail.loadViewIfNeeded()
        return detail
    }

    /// The one grid in the detail (the Connection card), found in the view tree so the test does
    /// not depend on the property's access level.
    private static func grid(in detail: HostDetailViewController) throws -> NSGridView {
        let grids = descendants(of: detail.view).compactMap { $0 as? NSGridView }
        #expect(grids.count == 1)
        return try #require(grids.first)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        descendants(of: view).compactMap { $0 as? NSTextField }
    }

    private static func assertCard(_ detail: HostDetailViewController, shows record: HostRecord) throws {
        let grid = try grid(in: detail)
        // (a) exactly the six rows: Address, Port, User name, Password, Certificate, Security.
        #expect(grid.numberOfRows == 6)
        let tree = descendants(of: grid)
        // (b) no orphans: every text field and button under the grid belongs to a live cell.
        for view in tree where view is NSTextField || view is NSButton {
            #expect(grid.cell(for: view) != nil, "orphaned \(type(of: view)) under the Connection grid")
        }
        // (c) the text-field count of one fill: 6 labels + 5 single-field values (Address, Port,
        // User name, Password, Security) + 1 certificate text (pinned: the "Pinned · SHA-256"
        // value beside the Show button, which is an NSButton and not counted; not pinned: one
        // wrapping label) = 12 in both shapes.
        #expect(textFields(in: grid).count == 6 + 5 + 1)
        // (d) the values are the newest record's.
        func valueText(row: Int) throws -> String {
            let content = try #require(grid.cell(atColumnIndex: 1, rowIndex: row).contentView)
            if let field = content as? NSTextField { return field.stringValue }
            let fields = textFields(in: content)
            #expect(fields.count == 1)
            return try #require(fields.first).stringValue
        }
        #expect(try valueText(row: 0) == record.address)
        #expect(try valueText(row: 1) == String(record.port))
        #expect(try valueText(row: 2) == record.userName)
        #expect(try valueText(row: 3) == (record.remembersPassword ? UIStrings.savedInKeychain : UIStrings.askedEachTime))
        #expect(try valueText(row: 4) == (record.pinned ? UIStrings.pinnedSHA256 : UIStrings.notPinned))
        #expect(try valueText(row: 5) == UIStrings.nlaRequired)
        // (e) the reused Show button sits in the grid once when pinned, not at all otherwise.
        let showCount = tree.filter { $0 === detail.showButton }.count
        #expect(showCount == (record.pinned ? 1 : 0))
    }

    @Test("show(a), show(a), show(b) leaves six rows, no orphans and the newest values each time")
    func refillsLeaveNoLeftovers() throws {
        let detail = Self.makeDetail()
        let a = HostRecord(displayName: "workstation.example", address: "workstation.example", port: 3389,
                           userName: "user", remembersPassword: true, pinned: true)
        let b = HostRecord(displayName: "workstation.example", address: "192.0.2.10", port: 3390,
                           userName: "user", remembersPassword: false, pinned: false)
        detail.show(a)
        try Self.assertCard(detail, shows: a)
        detail.show(a)
        try Self.assertCard(detail, shows: a)
        detail.show(b)
        try Self.assertCard(detail, shows: b)
    }

    @Test("an unpinned host turning pinned brings the Show button back exactly once, still wired")
    func showButtonReturnsWhenPinned() throws {
        let detail = Self.makeDetail()
        let unpinned = HostRecord(displayName: "workstation.example", address: "192.0.2.10",
                                  userName: "user", remembersPassword: true, pinned: false)
        var pinned = unpinned
        pinned.pinned = true
        detail.show(pinned)
        detail.show(unpinned)
        try Self.assertCard(detail, shows: unpinned)
        detail.show(pinned)
        try Self.assertCard(detail, shows: pinned)
        #expect(detail.showButton.action == NSSelectorFromString("show:"))
        #expect(detail.showButton.title == UIStrings.show)
    }
}
