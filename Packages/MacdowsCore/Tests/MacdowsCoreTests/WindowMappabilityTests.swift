import Testing
@testable import MacdowsCore

/// Phase 2 W2 (`docs/plans/phase2.md` §2 W2): targeted unit coverage for
/// `WindowMappability`'s ghost-sliver rule, entirely offline -- no AppKit, matching
/// `ZOrderSyncTests`'/`FocusAuthorityTests`' own no-AppKit precedent for this package's
/// pure-logic surface. `ReplayTests.w0StyleFilterDropsExpectedWindowIdSet` already covers
/// the real sample-driven fixture (including this rule's actual effect on the four real
/// ghost windowIds); this suite isolates the rule's own boundary behavior with synthetic
/// inputs the six samples don't happen to exercise.
@Suite("WindowMappability")
struct WindowMappabilityTests {
    static let ghostWidth: UInt32 = 136
    static let ghostHeight: UInt32 = 39
    /// The four real ghost windows' exact styleEx (`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
    /// WS_EX_TOPMOST`), verified directly against `samples/phase05-rail-events-2026-08-19`
    /// (see `WindowMappability.isGhostSliverHelper`'s own doc comment for the full
    /// grounding).
    static let ghostStyleEx: UInt32 = 0x0800_0088
    static let ghostStyle: UInt32 = 0x800B_0000

    private static func mappable(
        width: UInt32 = ghostWidth, height: UInt32 = ghostHeight, style: UInt32 = ghostStyle,
        styleEx: UInt32 = ghostStyleEx, ownerWindowId: UInt32 = 0, title: String = ""
    ) -> Bool {
        WindowMappability.isMappableWindow(
            width: width, height: height, style: style, styleEx: styleEx,
            ownerWindowId: ownerWindowId, fieldFlags: 0, title: title
        )
    }

    @Test("exact ghost signature (both ex-style bits, empty title, unowned): excluded")
    func exactGhostSignatureIsExcluded() {
        #expect(!Self.mappable())
    }

    @Test("real ghost windowId's exact recorded fields (983208 from s1-baseline.jsonl): excluded")
    func realGhostWindowIdFieldsAreExcluded() {
        #expect(!Self.mappable(width: 136, height: 39, style: 0x800B_0000, styleEx: 0x0800_0088, ownerWindowId: 0, title: ""))
    }

    @Test("only WS_EX_TOOLWINDOW set (no WS_EX_NOACTIVATE): fails open, still mappable")
    func toolWindowAloneFailsOpen() {
        #expect(Self.mappable(styleEx: 0x0000_0080))
    }

    @Test("only WS_EX_NOACTIVATE set (no WS_EX_TOOLWINDOW): fails open, still mappable")
    func noActivateAloneFailsOpen() {
        #expect(Self.mappable(styleEx: 0x0800_0000))
    }

    @Test("both ex-style bits but a non-empty title: fails open, still mappable")
    func titledGhostShapeFailsOpen() {
        #expect(Self.mappable(title: "Notifications"))
    }

    @Test("both ex-style bits, empty title, but owned (ownerWindowId != 0): fails open, still mappable")
    func ownedGhostShapeFailsOpen() {
        #expect(Self.mappable(ownerWindowId: 12345))
    }

    @Test("ghost signature at a totally different size: still excluded -- the rule is style-based, not size-based")
    func ghostSignatureAtDifferentSizeStillExcluded() {
        #expect(!Self.mappable(width: 2000, height: 1500))
    }

    @Test("desktop-container exact-style window (0x80000000) is excluded independent of this rule")
    func desktopContainerStillExcludedByPriorRule() {
        // styleEx here matches every real "Windows 输入体验" overlay observed in the
        // samples (0x08000088, same TOOLWINDOW|NOACTIVATE|TOPMOST bits as the ghosts) --
        // already caught by the pre-existing exact-style check before this rule even runs;
        // confirms no double-counting/ordering issue between the two checks.
        #expect(!Self.mappable(width: 2560, height: 1410, style: 0x8000_0000, styleEx: 0x0800_0088))
    }

    @Test("a real content window's style (About-dialog shape) is never excluded by the ghost rule")
    func realContentWindowNeverMatchesGhostRule() {
        #expect(Self.mappable(width: 536, height: 521, style: 0x8008_0000, styleEx: 0, ownerWindowId: 0, title: "About Windows"))
    }
}
