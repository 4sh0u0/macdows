import Testing
@testable import MacdowsCore

/// Phase 2 W2 (`docs/plans/phase2.md` §2 W2): exhaustive per-bit coverage for
/// `StyleTranslator.chrome(style:styleEx:hasTitle:ownerWindowId:)`, entirely offline -- no
/// AppKit, matching `WindowMappabilityTests`'/`ZOrderSyncTests`' own no-AppKit precedent for
/// this package's pure-logic surface.
@Suite("StyleTranslator")
struct StyleTranslatorTests {
    // MARK: - Win32 style bit values, independently re-declared (not imported from
    // StyleTranslator's own `internal`-visibility constants) so a typo in the production
    // constants can't silently make its own test agree with itself -- verified against
    // ThirdParty/FreeRDP/include/freerdp/window.h, same source StyleTranslator itself cites.
    static let wsCaption: UInt32 = 0x00C0_0000
    static let wsSysMenu: UInt32 = 0x0008_0000
    static let wsMinimizeBox: UInt32 = 0x0002_0000
    static let wsMaximizeBox: UInt32 = 0x0001_0000
    static let wsThickFrame: UInt32 = 0x0004_0000
    static let wsPopup: UInt32 = 0x8000_0000
    static let wsExToolWindow: UInt32 = 0x0000_0080
    static let wsExTopmost: UInt32 = 0x0000_0008
    static let wsExNoActivate: UInt32 = 0x0800_0000

    @Test("zero style: fully borderless, matching RemoteWindow's pre-W2 default")
    func zeroStyleIsBorderless() {
        let chrome = StyleTranslator.chrome(style: 0, styleEx: 0, hasTitle: false, ownerWindowId: 0)
        #expect(chrome == .borderless)
    }

    @Test("style with no chrome-implying bit (e.g. bare WS_POPUP): still borderless")
    func popupAloneIsBorderless() {
        // The desktop-container/IME-overlay signature (WindowMappability.styleDesktopContainerOnly)
        // never actually reaches this function in production (WindowMappability filters it
        // out before a window is ever created) but this function must still degrade safely
        // if it did -- fail-open, not a crash or an unintended "titled" result.
        let chrome = StyleTranslator.chrome(style: Self.wsPopup, styleEx: 0, hasTitle: false, ownerWindowId: 0)
        #expect(chrome == .borderless)
    }

    @Test("WS_CAPTION alone: titled, but no traffic light gets enabled")
    func captionAloneGivesTitledNoButtons() {
        let chrome = StyleTranslator.chrome(style: Self.wsCaption, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.titled)
        #expect(!chrome.closable)
        #expect(!chrome.miniaturizable)
        #expect(!chrome.zoomable)
        #expect(!chrome.resizable)
        #expect(chrome.hasShadow)
        #expect(chrome.level == .normal)
    }

    @Test("WS_SYSMENU alone (no WS_CAPTION): still titled+closable -- the real About-dialog shape")
    func sysMenuAloneWithoutCaptionStillTitles() {
        // Real captured evidence, not a hypothetical: winver.exe's About-Windows dialog
        // carries style 0x80080000 = WS_POPUP | WS_SYSMENU with NO WS_CAPTION bit at all
        // (samples/phase05-rail-events-2026-08-19, cross-checked in ReplayTests) -- this is
        // exactly why `titled` can't key off WS_CAPTION alone (see StyleTranslator's own
        // `styleCaption` doc comment).
        let chrome = StyleTranslator.chrome(style: Self.wsPopup | Self.wsSysMenu, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.titled)
        #expect(chrome.closable)
        #expect(!chrome.miniaturizable)
        #expect(!chrome.zoomable)
        #expect(!chrome.resizable)
    }

    @Test("real About-Windows dialog style (0x80080000): closable, no maximize/minimize/resize")
    func aboutWindowsDialogShape() {
        let chrome = StyleTranslator.chrome(style: 0x8008_0000, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.titled)
        #expect(chrome.closable)
        #expect(!chrome.zoomable, "phase2.md §4 W2 acceptance: 真机 About 框无最大化钮")
        #expect(!chrome.miniaturizable)
        #expect(!chrome.resizable)
    }

    @Test("real resizable content window style (0xF0000): full decoration, all four boxes")
    func resizableContentWindowShape() {
        // Real captured evidence: the sample set's one "resizable content window"
        // (Notepad/Registry-Editor-class) carries style 0xF0000 = WS_MAXIMIZEBOX |
        // WS_MINIMIZEBOX | WS_THICKFRAME | WS_SYSMENU, no WS_CAPTION bit either.
        let chrome = StyleTranslator.chrome(style: 0x000F_0000, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.titled)
        #expect(chrome.closable)
        #expect(chrome.miniaturizable)
        #expect(chrome.zoomable)
        #expect(chrome.resizable)
    }

    @Test("WS_SYSMENU bit independently drives closable", arguments: [false, true])
    func sysMenuDrivesClosable(_ present: Bool) {
        let style = Self.wsCaption | (present ? Self.wsSysMenu : 0)
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.closable == present)
    }

    @Test("WS_MINIMIZEBOX bit independently drives miniaturizable", arguments: [false, true])
    func minimizeBoxDrivesMiniaturizable(_ present: Bool) {
        let style = Self.wsCaption | (present ? Self.wsMinimizeBox : 0)
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.miniaturizable == present)
    }

    @Test("WS_MAXIMIZEBOX bit independently drives zoomable", arguments: [false, true])
    func maximizeBoxDrivesZoomable(_ present: Bool) {
        let style = Self.wsCaption | (present ? Self.wsMaximizeBox : 0)
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.zoomable == present)
    }

    @Test("WS_THICKFRAME bit independently drives resizable", arguments: [false, true])
    func thickFrameDrivesResizable(_ present: Bool) {
        let style = Self.wsCaption | (present ? Self.wsThickFrame : 0)
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.resizable == present)
    }

    @Test("WS_EX_TOPMOST drives floating level, independent of titled")
    func topmostDrivesFloatingLevelEvenUntitled() {
        // No chrome-implying style bit at all -- this is the "untitled but should still
        // float" case an undecorated topmost popup needs (StyleTranslator's own `level`
        // doc comment).
        let chrome = StyleTranslator.chrome(style: 0, styleEx: Self.wsExTopmost, hasTitle: false, ownerWindowId: 0)
        #expect(!chrome.titled)
        #expect(chrome.level == .floating)
    }

    @Test("no WS_EX_TOPMOST: normal level")
    func noTopmostIsNormalLevel() {
        let chrome = StyleTranslator.chrome(style: Self.wsCaption, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.level == .normal)
    }

    @Test("WS_EX_TOOLWINDOW suppresses both zoomable and miniaturizable, even when the underlying boxes are set")
    func toolWindowSuppressesZoomAndMinimize() {
        let style = Self.wsCaption | Self.wsSysMenu | Self.wsMinimizeBox | Self.wsMaximizeBox | Self.wsThickFrame
        let chrome = StyleTranslator.chrome(style: style, styleEx: Self.wsExToolWindow, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.titled)
        #expect(chrome.closable)
        #expect(!chrome.miniaturizable, "WS_EX_TOOLWINDOW: no taskbar/Alt+Tab presence, no natural minimize target")
        #expect(!chrome.zoomable, "WS_EX_TOOLWINDOW: utility-ish, no maximize")
        // WS_THICKFRAME (resizable) is untouched by the tool-window rule -- a floating
        // utility palette can still be edge-resizable even though it can't maximize.
        #expect(chrome.resizable)
    }

    @Test("owned window (nonzero ownerWindowId) suppresses zoomable only, not closable/miniaturizable")
    func ownedWindowSuppressesZoomableOnly() {
        let style = Self.wsCaption | Self.wsSysMenu | Self.wsMinimizeBox | Self.wsMaximizeBox | Self.wsThickFrame
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 424_242)
        #expect(chrome.closable)
        #expect(chrome.miniaturizable)
        #expect(!chrome.zoomable, "an owned window has no independent maximize target (Win32 owned-window convention)")
        #expect(chrome.resizable)
    }

    @Test("unowned window (ownerWindowId == 0) does not suppress zoomable")
    func unownedWindowKeepsZoomable() {
        let style = Self.wsCaption | Self.wsMaximizeBox
        let chrome = StyleTranslator.chrome(style: style, styleEx: 0, hasTitle: true, ownerWindowId: 0)
        #expect(chrome.zoomable)
    }

    @Test("hasTitle does not change the computed chrome -- accepted, not yet consumed", arguments: [false, true])
    func hasTitleIsForwardCompatibleNoOp(_ hasTitle: Bool) {
        let style = Self.wsCaption | Self.wsSysMenu | Self.wsMinimizeBox | Self.wsMaximizeBox | Self.wsThickFrame
        let withTitle = StyleTranslator.chrome(style: style, styleEx: Self.wsExTopmost, hasTitle: true, ownerWindowId: 0)
        let withoutTitle = StyleTranslator.chrome(style: style, styleEx: Self.wsExTopmost, hasTitle: false, ownerWindowId: 0)
        #expect(withTitle == withoutTitle)
        // The parameterized `hasTitle` argument itself is unused beyond documenting intent
        // via its own value in the test name/arguments list -- both branches above already
        // cover true/false directly.
        _ = hasTitle
    }

    @Test("hasShadow is always true -- matches RemoteWindow's pre-W2 unconditional default")
    func hasShadowAlwaysTrue() {
        #expect(StyleTranslator.chrome(style: 0, styleEx: 0, hasTitle: false, ownerWindowId: 0).hasShadow)
        #expect(StyleTranslator.chrome(style: 0x000F_0000, styleEx: 0, hasTitle: true, ownerWindowId: 0).hasShadow)
    }
}
