import Testing
@testable import MacdowsCore

/// Synthetic-event unit tests for `WindowModel.apply(_:)`'s anomaly policy and delta-merge
/// correctness. Complements `ReplayTests`, which only ever exercises the six phase05
/// samples — and those samples, per exploration, never actually hit any of the three
/// `Anomaly.Kind` branches (duplicate create; update/delete/icon on an unknown window).
/// Without tests that hand-construct events to force those paths, they could be deleted
/// outright and every existing test would stay green — confirmed by literally deleting
/// them and re-running the suite before writing these (the W2 review's "mutation A"/
/// "mutation E"; see the fix-batch report for the after-the-fact confirmation that these
/// new tests do catch both).
@Suite("WindowModel synthetic-event unit tests")
struct WindowModelTests {
    // MARK: - Construction helpers

    /// Builds a `WindowOrderPayload` via its (internal, `@testable`-visible) memberwise
    /// init. Every parameter defaults to zero/empty so a test only needs to name the
    /// fields it actually cares about.
    static func windowOrder(
        windowId: UInt32,
        fieldFlags: UInt32,
        offsetX: Int32 = 0,
        offsetY: Int32 = 0,
        width: UInt32 = 0,
        height: UInt32 = 0,
        numVisibilityRects: UInt32 = 0,
        style: UInt32 = 0,
        styleEx: UInt32 = 0,
        show: UInt32 = 0,
        title: String = "",
        ownerWindowId: UInt32 = 0
    ) -> WindowOrderPayload {
        WindowOrderPayload(
            windowId: windowId,
            fieldFlags: fieldFlags,
            windowOffsetX: offsetX,
            windowOffsetY: offsetY,
            windowWidth: width,
            windowHeight: height,
            numVisibilityRects: numVisibilityRects,
            style: style,
            styleEx: styleEx,
            show: show,
            title: title,
            ownerWindowId: ownerWindowId
        )
    }

    static func event(_ kind: RailEventKind, line: Int) -> RailEvent {
        RailEvent(tMs: 0, tid: "0xtest", kind: kind, lineNumber: line)
    }

    // MARK: - Field-presence bits, matching WindowModel.swift's private WindowOrderField
    // (duplicated here deliberately — these tests exist specifically to catch the file
    // under test using the wrong constant, so they must not share that file's constants).

    static let fieldOwner: UInt32 = 0x0000_0002
    static let fieldTitle: UInt32 = 0x0000_0004
    static let fieldStyle: UInt32 = 0x0000_0008
    static let fieldShow: UInt32 = 0x0000_0010
    static let fieldWndRects: UInt32 = 0x0000_0100 // WND_RECTS — must NOT gate numVisibilityRects
    static let fieldVisibility: UInt32 = 0x0000_0200 // VISIBILITY — must gate numVisibilityRects
    static let fieldSize: UInt32 = 0x0000_0400
    static let fieldOffset: UInt32 = 0x0000_0800

    // MARK: - fieldFlags anchor (M2, W4b review): App/RemoteWindowRendering/
    // RemoteWindowRegistry.swift — the Xcode-target Swift rendering layer, a separate
    // module from this package (adr/0006 §2's no-AppKit boundary means it can't import
    // MacdowsCore's internal types or share a constant with WindowModel.swift directly)
    // — keeps its OWN narrow copy of exactly these four bits (offset/size/show/title, the
    // only sub-fields that rendering layer's own merge needs), independent of both this
    // file's constants above and WindowModel.swift's private WindowOrderField. This test
    // hardcodes the same four literal values that copy uses and proves, through
    // WindowModel's own public apply() behavior, that each one really does gate exactly the
    // sub-field that copy assumes it does — the tripwire for the two ever silently
    // drifting apart if WindowModel.swift's bit values (or MS-RDPERP's own wire format)
    // change and RemoteWindowRegistry.swift's copy isn't updated in lockstep.

    @Test("the four fieldFlags bits App/RemoteWindowRendering/RemoteWindowRegistry.swift duplicates each gate exactly the sub-field that copy assumes")
    func remoteWindowRenderingFieldFlagsAnchor() {
        let offsetBit: UInt32 = 0x0000_0800
        let sizeBit: UInt32 = 0x0000_0400
        let showBit: UInt32 = 0x0000_0010
        let titleBit: UInt32 = 0x0000_0004

        var model = WindowModel()
        // Baseline: every field set to a known, non-default value, so a later delta that
        // does NOT carry a given bit can be proven not to have touched that field.
        let baseline = Self.windowOrder(
            windowId: 1,
            fieldFlags: offsetBit | sizeBit | showBit | titleBit,
            offsetX: 10, offsetY: 20, width: 300, height: 400, show: 5, title: "baseline"
        )
        model.apply(Self.event(.windowCreate(baseline), line: 1))

        model.apply(Self.event(.windowUpdate(Self.windowOrder(
            windowId: 1, fieldFlags: offsetBit, offsetX: 111, offsetY: 222
        )), line: 2))
        var state = try! #require(model.windows[1])
        #expect(state.offsetX == 111 && state.offsetY == 222, "offset bit must update offsetX/offsetY")
        #expect(state.width == 300 && state.height == 400, "offset bit must NOT touch size")
        #expect(state.show == 5, "offset bit must NOT touch show")
        #expect(state.title == "baseline", "offset bit must NOT touch title")

        model.apply(Self.event(.windowUpdate(Self.windowOrder(
            windowId: 1, fieldFlags: sizeBit, width: 333, height: 444
        )), line: 3))
        state = try! #require(model.windows[1])
        #expect(state.width == 333 && state.height == 444, "size bit must update width/height")
        #expect(state.offsetX == 111 && state.offsetY == 222, "size bit must NOT touch offset")
        #expect(state.show == 5, "size bit must NOT touch show")
        #expect(state.title == "baseline", "size bit must NOT touch title")

        model.apply(Self.event(.windowUpdate(Self.windowOrder(
            windowId: 1, fieldFlags: showBit, show: 9
        )), line: 4))
        state = try! #require(model.windows[1])
        #expect(state.show == 9, "show bit must update show")
        #expect(state.offsetX == 111 && state.offsetY == 222, "show bit must NOT touch offset")
        #expect(state.width == 333 && state.height == 444, "show bit must NOT touch size")
        #expect(state.title == "baseline", "show bit must NOT touch title")

        model.apply(Self.event(.windowUpdate(Self.windowOrder(
            windowId: 1, fieldFlags: titleBit, title: "updated"
        )), line: 5))
        state = try! #require(model.windows[1])
        #expect(state.title == "updated", "title bit must update title")
        #expect(state.offsetX == 111 && state.offsetY == 222, "title bit must NOT touch offset")
        #expect(state.width == 333 && state.height == 444, "title bit must NOT touch size")
        #expect(state.show == 9, "title bit must NOT touch show")
    }

    // MARK: - Anomaly.Kind.duplicateWindowCreate

    @Test("duplicate WindowCreate reports an anomaly and starts the window fresh — no field inherited from the old identity")
    func duplicateCreateStartsFresh() {
        var model = WindowModel()

        let first = Self.windowOrder(
            windowId: 1,
            fieldFlags: Self.fieldTitle | Self.fieldSize | Self.fieldStyle | Self.fieldShow,
            width: 800, height: 600,
            style: 5, styleEx: 6, show: 1,
            title: "first identity"
        )
        let a1 = model.apply(Self.event(.windowCreate(first), line: 1))
        #expect(a1.isEmpty, "the first create for a fresh windowId must not be flagged")
        #expect(model.windows[1]?.title == "first identity")
        #expect(model.windows[1]?.width == 800)

        // Second create for the *same* windowId, but this time only setting `show` —
        // nothing about title/size/style. "a repeated Create -> flag an Anomaly and
        // overwrite" means overwrite with a fresh identity, not merge onto the first create's leftover state.
        let second = Self.windowOrder(
            windowId: 1,
            fieldFlags: Self.fieldShow,
            show: 2
        )
        let a2 = model.apply(Self.event(.windowCreate(second), line: 2))

        #expect(a2.count == 1)
        guard case .duplicateWindowCreate(let windowId) = a2[0].kind else {
            Issue.record("expected .duplicateWindowCreate, got \(a2[0].kind)")
            return
        }
        #expect(windowId == 1)
        #expect(a2[0].lineNumber == 2, "anomaly must carry the line number of the event that triggered it, not the first create's")

        let state = try! #require(model.windows[1])
        #expect(state.show == 2, "the field the second create *did* set must apply")
        #expect(state.title == "", "title from the first identity must NOT survive a duplicate create")
        #expect(state.width == 0, "width from the first identity must NOT survive a duplicate create")
        #expect(state.height == 0)
        #expect(state.style == 0, "style from the first identity must NOT survive a duplicate create")
        #expect(state.styleEx == 0)
    }

    // MARK: - Anomaly.Kind.updateUnknownWindow

    @Test("WindowUpdate on a never-created windowId is flagged and does not implicitly create the window")
    func updateOnUnknownWindow() {
        var model = WindowModel()
        let payload = Self.windowOrder(windowId: 99, fieldFlags: Self.fieldTitle, title: "ghost")
        let anomalies = model.apply(Self.event(.windowUpdate(payload), line: 7))

        #expect(anomalies.count == 1)
        guard case .updateUnknownWindow(let windowId) = anomalies[0].kind else {
            Issue.record("expected .updateUnknownWindow, got \(anomalies[0].kind)")
            return
        }
        #expect(windowId == 99)
        #expect(anomalies[0].lineNumber == 7)
        #expect(model.windows[99] == nil, "an Update must never implicitly create a window")
    }

    // MARK: - Anomaly.Kind.deleteUnknownWindow

    @Test("WindowDelete on a never-created windowId is flagged and is a no-op")
    func deleteOnUnknownWindow() {
        var model = WindowModel()
        let anomalies = model.apply(Self.event(.windowDelete(windowId: 42), line: 3))

        #expect(anomalies.count == 1)
        guard case .deleteUnknownWindow(let windowId) = anomalies[0].kind else {
            Issue.record("expected .deleteUnknownWindow, got \(anomalies[0].kind)")
            return
        }
        #expect(windowId == 42)
        #expect(anomalies[0].lineNumber == 3)
        #expect(model.windows[42] == nil)
    }

    // MARK: - Anomaly.Kind.iconUnknownWindow

    @Test("WindowIcon on a never-created windowId is flagged", arguments: [
        RailEventKind.windowIcon(windowId: 5),
        RailEventKind.windowCachedIcon(windowId: 5),
    ])
    func iconOnUnknownWindow(_ kind: RailEventKind) {
        var model = WindowModel()
        let anomalies = model.apply(Self.event(kind, line: 11))

        #expect(anomalies.count == 1)
        guard case .iconUnknownWindow(let windowId) = anomalies[0].kind else {
            Issue.record("expected .iconUnknownWindow, got \(anomalies[0].kind)")
            return
        }
        #expect(windowId == 5)
        #expect(anomalies[0].lineNumber == 11)
    }

    @Test("WindowIcon on a known window sets hasIcon and reports no anomaly")
    func iconOnKnownWindow() {
        var model = WindowModel()
        _ = model.apply(Self.event(.windowCreate(Self.windowOrder(windowId: 5, fieldFlags: 0)), line: 1))

        let anomalies = model.apply(Self.event(.windowIcon(windowId: 5), line: 2))
        #expect(anomalies.isEmpty)
        #expect(model.windows[5]?.hasIcon == true)
    }

    // MARK: - Full lifecycle chain: create -> delete -> update

    @Test("create -> delete -> update: the update after a real delete must report updateUnknownWindow, not silently succeed")
    func createDeleteThenUpdateReportsUnknown() {
        var model = WindowModel()

        let created = model.apply(Self.event(.windowCreate(Self.windowOrder(windowId: 8, fieldFlags: Self.fieldTitle, title: "will be deleted")), line: 1))
        #expect(created.isEmpty)
        #expect(model.windows[8] != nil)

        let deleted = model.apply(Self.event(.windowDelete(windowId: 8), line: 2))
        #expect(deleted.isEmpty, "deleting a window that really exists must not itself be flagged")
        #expect(model.windows[8] == nil, "delete must actually remove the window from state — this is exactly what a would-be 'delete is a no-op' mutation would break")

        let updated = model.apply(Self.event(.windowUpdate(Self.windowOrder(windowId: 8, fieldFlags: Self.fieldTitle, title: "should not apply")), line: 3))
        #expect(updated.count == 1)
        guard case .updateUnknownWindow(let windowId) = updated[0].kind else {
            Issue.record("expected .updateUnknownWindow after a real prior delete, got \(updated[0].kind)")
            return
        }
        #expect(windowId == 8)
        #expect(model.windows[8] == nil, "the post-delete update must not resurrect the window")
    }

    // MARK: - M1: WINDOW_ORDER_FIELD_VISIBILITY (0x200) gates numVisibilityRects, not
    // WINDOW_ORDER_FIELD_WND_RECTS (0x100)

    @Test("numVisibilityRects is applied when only the VISIBILITY bit (0x200) is set, WND_RECTS (0x100) unset")
    func visibilityBitGatesNumVisibilityRects() {
        var model = WindowModel()
        _ = model.apply(Self.event(.windowCreate(Self.windowOrder(windowId: 1, fieldFlags: 0)), line: 1))
        #expect(model.windows[1]?.numVisibilityRects == 0)

        // fieldFlags carries VISIBILITY only — explicitly *not* WND_RECTS, which is the
        // bit the pre-fix code incorrectly checked (M1). If WindowModel regresses back to
        // gating on 0x100, this update's numVisibilityRects would be silently dropped.
        let payload = Self.windowOrder(windowId: 1, fieldFlags: Self.fieldVisibility, numVisibilityRects: 5)
        #expect(payload.fieldFlags & Self.fieldWndRects == 0, "test sanity: WND_RECTS must not be set")
        #expect(payload.fieldFlags & Self.fieldVisibility != 0, "test sanity: VISIBILITY must be set")

        let anomalies = model.apply(Self.event(.windowUpdate(payload), line: 2))
        #expect(anomalies.isEmpty)
        #expect(model.windows[1]?.numVisibilityRects == 5)
    }

    @Test("the WND_RECTS bit (0x100) alone does not apply numVisibilityRects")
    func wndRectsBitAloneDoesNotGateNumVisibilityRects() {
        var model = WindowModel()
        _ = model.apply(Self.event(.windowCreate(Self.windowOrder(windowId: 1, fieldFlags: 0)), line: 1))

        let payload = Self.windowOrder(windowId: 1, fieldFlags: Self.fieldWndRects, numVisibilityRects: 9)
        _ = model.apply(Self.event(.windowUpdate(payload), line: 2))
        #expect(model.windows[1]?.numVisibilityRects == 0, "WND_RECTS alone must not apply numVisibilityRects — that would mean the fix regressed to accepting either bit")
    }

    // MARK: - adr/0008 §3: ownerWindowId bit-gated delta-merge

    @Test("WindowCreate with the OWNER bit sets ownerWindowId; a later WindowUpdate without OWNER must not clear it")
    func ownerWindowIdSurvivesUpdateWithoutOwnerBit() {
        var model = WindowModel()

        let created = Self.windowOrder(
            windowId: 1, fieldFlags: Self.fieldOwner | Self.fieldSize,
            width: 800, height: 600, ownerWindowId: 4242
        )
        _ = model.apply(Self.event(.windowCreate(created), line: 1))
        #expect(model.windows[1]?.ownerWindowId == 4242, "OWNER bit on Create must set ownerWindowId")

        // Geometry-only update, deliberately NOT carrying the OWNER bit — matches real
        // capture behavior (adr/0008 §0: OWNER is set on every WindowCreate but absent on
        // every WindowUpdate across all six phase05 samples).
        let moved = Self.windowOrder(windowId: 1, fieldFlags: Self.fieldOffset, offsetX: 10, offsetY: 20)
        #expect(moved.fieldFlags & Self.fieldOwner == 0, "test sanity: OWNER must not be set on this update")
        _ = model.apply(Self.event(.windowUpdate(moved), line: 2))

        let state = try! #require(model.windows[1])
        #expect(state.offsetX == 10 && state.offsetY == 20, "the offset bit's own field must still apply")
        #expect(state.ownerWindowId == 4242, "an update without the OWNER bit must NOT clear the previously-known owner")
    }

    @Test("a WindowUpdate that DOES carry the OWNER bit overwrites ownerWindowId, including to 0")
    func ownerWindowIdUpdatesWhenBitIsSet() {
        var model = WindowModel()
        _ = model.apply(Self.event(.windowCreate(Self.windowOrder(
            windowId: 1, fieldFlags: Self.fieldOwner, ownerWindowId: 4242
        )), line: 1))
        #expect(model.windows[1]?.ownerWindowId == 4242)

        // 0 is itself a legitimate wire value ("no owner"), not "field absent" — the OWNER
        // bit is what carries that meaning, not a non-zero check on the value.
        let reowned = Self.windowOrder(windowId: 1, fieldFlags: Self.fieldOwner, ownerWindowId: 0)
        _ = model.apply(Self.event(.windowUpdate(reowned), line: 2))
        #expect(model.windows[1]?.ownerWindowId == 0, "OWNER bit set with value 0 must overwrite, not be mistaken for 'absent'")
    }
}
