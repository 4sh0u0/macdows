import Foundation

/// Phase 2 W2 (`docs/plans/phase2.md` §2 W2, adr/0008 §3's style/owner wire contract): the
/// AppKit-facing chrome one RAIL top-level window should get, derived purely from its Win32
/// `style`/`styleEx` bits (plus title/owner presence). Pure value type -- no AppKit (adr/0006
/// §2's no-AppKit boundary, same discipline `WindowMappability`/`ZOrderSync` already follow)
/// -- `RemoteWindow`/`RemoteWindowRegistry` are the only consumers, translating this into an
/// actual `NSWindow.styleMask`/`.level`/`.hasShadow` and traffic-light wiring (App/RemoteWindowRendering).
public struct WindowChrome: Sendable, Equatable {
    /// `WS_CAPTION`-family decoration present -- gates every other field below. When
    /// `false`, every other field is forced to its off/`.normal` value regardless of what
    /// `StyleTranslator.chrome` computed for them individually (see that function's own
    /// doc comment): a window with none of the decoration-implying bits gets the exact
    /// same fully-borderless chrome `RemoteWindow` has always used, matching the plan's
    /// "unknown styles render visible but undecorated" fail-open principle.
    public var titled: Bool
    /// `WS_SYSMENU` -- drives both `NSWindow.StyleMask.closable` and, transitively, whether
    /// `RemoteWindowBackingWindow`'s close-button/⌘W path is ever reachable at all (AppKit
    /// won't show or enable a close affordance without this bit).
    public var closable: Bool
    /// `WS_MINIMIZEBOX` -- drives `NSWindow.StyleMask.miniaturizable`.
    public var miniaturizable: Bool
    /// `WS_MAXIMIZEBOX` -- intent for the zoom (green) button. NOTE: AppKit itself only
    /// exposes ONE styleMask bit (`.resizable`) that controls both "the user can drag-resize
    /// this window's edges" AND "the zoom button is enabled" -- there is no independent
    /// "zoom enabled" bit in `NSWindow.StyleMask`, so `RemoteWindow` applies `.resizable`
    /// whenever `resizable` below is `true` and otherwise leaves the zoom button visually
    /// disabled even if this flag is `true`. Every real WS_MAXIMIZEBOX-bearing window
    /// observed in `samples/phase05-rail-events-2026-08-19` also carries WS_THICKFRAME
    /// (the one "resizable content window" per style `0xF0000` = MAXIMIZEBOX|MINIMIZEBOX|
    /// THICKFRAME|SYSMENU) — no sample exhibits WS_MAXIMIZEBOX without WS_THICKFRAME, so
    /// this AppKit coupling has not been observed to matter in practice; kept as its own
    /// field (rather than folded into `resizable`) so that gap is visible in the type
    /// itself and W2's exhaustive table tests can assert the Win32-faithful value even
    /// though `RemoteWindow` can't always fully honor it today.
    public var zoomable: Bool
    /// `WS_THICKFRAME` (== `WS_SIZEBOX`, same bit) -- drives `NSWindow.StyleMask.resizable`
    /// (local edge/corner drag-resize) and, per `zoomable`'s own doc comment, the zoom
    /// button's enabled state too.
    public var resizable: Bool
    /// Always `true` today -- matches `RemoteWindow`'s prior unconditional `win.hasShadow =
    /// true` exactly (H0's own doc comment). No sample evidence yet motivates varying this
    /// per style (a shadow is always safe/visible; the fail-open precedent this package
    /// follows throughout treats "always show" as the safe default absent a specific,
    /// evidenced reason to suppress). Exposed on `WindowChrome` rather than hardcoded a
    /// second time in `RemoteWindow` so a future evidenced exception has one place to land.
    public var hasShadow: Bool
    /// `WS_EX_TOPMOST` -- `.floating` keeps the window above normal-level windows,
    /// independent of `titled`: an untitled topmost popup (e.g. a context-menu-shaped
    /// window) should still float even though it never gets traffic lights.
    public var level: Level

    public enum Level: Sendable, Equatable {
        case normal
        case floating
    }

    public static let borderless = WindowChrome(
        titled: false, closable: false, miniaturizable: false, zoomable: false,
        resizable: false, hasShadow: true, level: .normal
    )
}

public enum StyleTranslator {
    // MARK: - `style` (WS_*) bits, verified against ThirdParty/FreeRDP/include/freerdp/window.h

    /// `WS_CAPTION` (0x00C00000) -- itself `WS_BORDER | WS_DLGFRAME`. NOTE: real RAIL wire
    /// data does NOT reliably set this bit on windows that unambiguously want a title bar --
    /// the About-Windows dialog's own captured style, `0x80080000` (`samples/phase05-rail-
    /// events-2026-08-19`, cross-checked in `ReplayTests`), is `WS_POPUP | WS_SYSMENU` with
    /// NO `WS_CAPTION` bit at all, even though `WS_SYSMENU` requires `WS_CAPTION` on a real
    /// desktop Win32 window per MSDN. `titled` below therefore keys off ANY decoration-
    /// implying bit, not this one alone -- see `titled`'s own reasoning.
    static let styleCaption: UInt32 = 0x00C0_0000
    /// `WS_SYSMENU` (0x00080000).
    static let styleSysMenu: UInt32 = 0x0008_0000
    /// `WS_MINIMIZEBOX` (0x00020000). Numerically identical to `WS_GROUP` (a *child*-control
    /// style) -- Win32 reuses this bit across the two contexts; every window this translator
    /// ever sees is a top-level RAIL window (never a child, per `WindowMappability`'s own
    /// `WS_CHILD` guard upstream), so the WS_MINIMIZEBOX reading is always the correct one
    /// here.
    static let styleMinimizeBox: UInt32 = 0x0002_0000
    /// `WS_MAXIMIZEBOX` (0x00010000).
    static let styleMaximizeBox: UInt32 = 0x0001_0000
    /// `WS_THICKFRAME` (0x00040000, == `WS_SIZEBOX`, the same bit under two names).
    static let styleThickFrame: UInt32 = 0x0004_0000

    // MARK: - `styleEx` (WS_EX_*) bits

    /// `WS_EX_TOOLWINDOW` (0x00000080) -- per MSDN, "does not appear in the taskbar or in
    /// the dialog that appears when the user presses ALT+TAB": the standard Win32 signature
    /// for a floating helper/utility window, not a normal top-level application window.
    static let styleExToolWindow: UInt32 = 0x0000_0080
    /// `WS_EX_TOPMOST` (0x00000008).
    static let styleExTopmost: UInt32 = 0x0000_0008

    /// Every bit that plausibly signals "this window wants some kind of native chrome" --
    /// deliberately broader than `styleCaption` alone (see that constant's own doc comment
    /// for why `WS_CAPTION` by itself under-fires against real captured data). A window
    /// with NONE of these set gets fully borderless chrome, matching the plan's "unknown
    /// styles render visible but undecorated" fail-open principle exactly as
    /// `WindowMappability`'s `isMappableWindow` already fails open on unrecognized styles
    /// for the separate "should this even become a window" question.
    private static let chromeImplyingBits: UInt32 =
        styleCaption | styleSysMenu | styleMinimizeBox | styleMaximizeBox | styleThickFrame

    /// Translates one window's Win32 style/styleEx (+ title/owner presence) into the chrome
    /// `RemoteWindow` should apply. Table-driven in the sense that stands up under a truth
    /// table: every field below is an independent function of exactly one or two style
    /// bits, verified per-field against real captured samples (see each constant's own doc
    /// comment and `StyleTranslatorTests`' exhaustive per-bit coverage), not a heuristic
    /// blend.
    ///
    /// - Parameters:
    ///   - hasTitle: whether this window's most recently merged title is non-empty. Accepted
    ///     now (per the task's own "(+ title/owner presence)" input list) but not consumed
    ///     by any branch below -- no sample or documented Win32 convention was found during
    ///     this pass that ties title presence to *chrome* specifically (as opposed to what
    ///     text a titlebar displays, which `RemoteWindow.updateTitle` already handles
    ///     independently of this function). Kept in the signature so a future, evidenced
    ///     rule doesn't need a second signature change -- the same forward-compatible
    ///     pattern `WindowMappability.isMappableWindow` already established for its own
    ///     then-unconsumed `styleEx`/`ownerWindowId` parameters.
    ///   - ownerWindowId: 0 means unowned/desktop-owned (a legitimate value, not just "field
    ///     absent" -- same caveat as everywhere else this field appears, adr/0008 §3).
    ///     Consumed by exactly one rule below (see `zoomable`'s computation) -- a judgment
    ///     call grounded in documented Win32 "owned window" conventions, NOT in sample
    ///     evidence (adr/0008 §0: `ownerWindowId`'s actual wire value was never captured by
    ///     any of the six phase05 samples, so this specific rule has no direct sample to
    ///     check against and should be weighed accordingly).
    public static func chrome(style: UInt32, styleEx: UInt32, hasTitle: Bool, ownerWindowId: UInt32) -> WindowChrome {
        // `level` is computed unconditionally, below, and is the one field NOT gated on
        // `titled` -- an untitled topmost popup (e.g. a context-menu-shaped window) should
        // still float above normal-level windows even though it never gets traffic lights
        // (see `WindowChrome.level`'s own doc comment). Everything else genuinely IS gated:
        // a window with none of `chromeImplyingBits` set gets every other field at its off
        // value, matching the plan's "unknown styles render visible but undecorated"
        // fail-open principle.
        let level: WindowChrome.Level = styleEx & styleExTopmost != 0 ? .floating : .normal
        guard style & chromeImplyingBits != 0 else {
            var borderless = WindowChrome.borderless
            borderless.level = level
            return borderless
        }

        let closable = style & styleSysMenu != 0
        let miniaturizable = style & styleMinimizeBox != 0
        let resizable = style & styleThickFrame != 0
        var zoomable = style & styleMaximizeBox != 0

        // WS_EX_TOOLWINDOW ("utility-ish", per the task spec): a floating helper/utility
        // window per MSDN's own description (no taskbar/Alt+Tab presence) has no natural
        // place for either a maximize or a minimize action to go, so both are suppressed
        // here regardless of what WS_MAXIMIZEBOX/WS_MINIMIZEBOX individually said. This is
        // the only "smaller chrome" approximation this pass makes -- AppKit has no
        // styleMask-level notion of a physically smaller titlebar for a plain `NSWindow`
        // (only `NSPanel`'s `.utilityWindow`, not used here, per adr/0006 §2's AppKit
        // boundary living entirely in `App/RemoteWindowRendering`, not this package).
        var effectiveMiniaturizable = miniaturizable
        if styleEx & styleExToolWindow != 0 {
            zoomable = false
            effectiveMiniaturizable = false
        }

        // Owned-window convention (judgment call, NOT sample-verified -- see this
        // function's own `ownerWindowId` parameter doc comment): a window owned by another
        // window has no independent taskbar entry and is not conventionally offered an
        // independent maximize action either (Win32's own "owned windows" semantics --
        // maximizing an owned dialog has no well-defined "restore to what" target the way a
        // real top-level application window does). Applied narrowly to `zoomable` only,
        // not `effectiveMiniaturizable`/`closable` -- minimizing/closing an owned dialog is
        // unremarkable and common (every "Save As"/"Properties"-class dialog has a working
        // close box), so only the maximize suppression is defensible here.
        if ownerWindowId != 0 {
            zoomable = false
        }

        return WindowChrome(
            titled: true,
            closable: closable,
            miniaturizable: effectiveMiniaturizable,
            zoomable: zoomable,
            resizable: resizable,
            hasShadow: true,
            level: level
        )
    }
}
