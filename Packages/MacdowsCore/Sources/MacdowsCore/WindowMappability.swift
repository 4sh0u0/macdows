import Foundation

/// Phase 2 W0① (`docs/plans/phase2.md` W0①, `docs/adr/0008` §3): the style/owner-based
/// decision for whether a RAIL top-level window order should ever become a real,
/// user-visible NSWindow, replacing W0's temporary width/height-only cap (which dropped
/// every maximized content window — the whole point of this pass, see
/// `RemoteWindowRegistry`'s prior `isLikelyContentWindow`).
///
/// Deliberately pure logic (no AppKit, adr/0006 §2's no-AppKit boundary) so both
/// `RemoteWindowRegistry` (the AppKit-side live consumer, `App/RemoteWindowRendering/`)
/// and this package's own replay-fixture regression test
/// (`MacdowsCoreTests/ReplayTests.swift`) exercise the exact same implementation, rather
/// than risking silent drift between a "real" filter and a hand-reimplemented test double.
public enum WindowMappability {
    /// `WS_CHILD` (0x40000000, `freerdp/window.h`) — a child window is never a legitimate
    /// standalone top-level NSWindow, regardless of size. Not observed set on any top-level
    /// RAIL window order in the six phase05 samples (RAIL itself shouldn't ever send one),
    /// but MS-RDPERP doesn't forbid a server from doing so — a defensive, protocol-level
    /// guard rather than one derived from sample evidence.
    private static let styleChild: UInt32 = 0x4000_0000

    /// The exact `style` value (no other bits) RAIL's own desktop-container window
    /// ("Program Manager", the whole remote virtual desktop's root — windowId 524454 across
    /// every phase05 sample) and Windows' own multi-monitor "Windows 输入体验" (Text Input
    /// Experience) overlay windows carry in every one of the six phase05 samples — verified
    /// directly against every `WindowCreate` in `samples/phase05-rail-events-2026-08-19/*.jsonl`
    /// (see `ReplayTests`' W0① fixture): `WS_POPUP` (0x80000000) alone, with neither
    /// `WS_VISIBLE` nor `WS_SYSMENU` nor any other decoration bit. No legitimate content
    /// window across any sample ever matches this exact value — real dialogs carry at
    /// least `WS_SYSMENU` (the About-Windows dialog's 0x80080000, the systray-adjacent
    /// popup's 0x800B0000), and real resizable windows are `WS_OVERLAPPED`-based (bit 31
    /// clear, e.g. 0xF0000). This same exact-equality signature also happens to catch
    /// every degenerate 0x0/1x1/edge-strip RAIL helper window observed in the samples,
    /// which all share it too. `fieldFlags` was also checked (adr/0008 §3's "style/
    /// fieldFlags signature") and found identical (0x1100DF1E) across both the excluded
    /// junk windows and the kept content windows in every sample — fieldFlags is not the
    /// discriminator here, style is.
    ///
    /// adr/0010 W4 real-host correction (2026-08-23, first popup-scenario run): bare
    /// `WS_POPUP` is ALSO the exact style of a live, real menu/system-menu popup — About's
    /// own Alt+Space system menu was observed live as windowId 4523408, 183x50,
    /// `style=0x80000000` (this exact value), `styleEx=0x00000088`, `ownerWindowId=2622898`
    /// (the About window itself). Style equality alone is therefore NOT the desktop-
    /// container/IME-overlay discriminator this rule's own name claims — `isMappableWindow`
    /// below additionally requires `ownerWindowId == 0` before excluding: every desktop-
    /// container/IME-overlay/degenerate-helper window this rule was ever meant to catch is
    /// desktop-owned (adr/0008 §0 documents `ownerWindowId` was never actually recorded in
    /// any of the six phase05 samples — rail-probe.c never logged it — so all 17 of that
    /// fixture's per-scenario excluded ids decode `ownerWindowId == 0` today regardless;
    /// `ReplayTests.w0StyleFilterDropsExpectedWindowIdSet` is therefore unaffected by this
    /// change, and its own comment now states that check explicitly), while a live popup
    /// menu is always OWNED by the window whose system/context menu it is. An owned bare-
    /// `WS_POPUP` window fails open (stays mappable) instead.
    private static let styleDesktopContainerOnly: UInt32 = 0x8000_0000

    /// `WS_EX_TOOLWINDOW` (0x00000080, `freerdp/window.h`) — per MSDN, "does not appear in
    /// the taskbar or in the dialog that appears when the user presses ALT+TAB": the
    /// standard Win32 signature for a floating helper/utility window, not a normal
    /// top-level application window. Also `StyleTranslator.styleExToolWindow` — duplicated
    /// here rather than shared, matching this file's own precedent of not cross-importing
    /// bit constants between this package's independent pure-logic units.
    private static let styleExToolWindow: UInt32 = 0x0000_0080
    /// `WS_EX_NOACTIVATE` (0x08000000) — the window never receives the input focus and is
    /// never brought to the foreground on click; per MSDN this exists specifically for
    /// passive helper UI a user interacts with by clicking through to the window beneath.
    private static let styleExNoActivate: UInt32 = 0x0800_0000

    /// Phase 2 W2 ghost-sliver rule (`docs/plans/phase2.md` §2 W2): four blank 136x39
    /// RAIL-shown helper windows are a live, real UX bug -- empty-title slivers that pass
    /// this filter's exact-style desktop-container check (their `style`, `0x800B0000`, is
    /// NOT the exact `styleDesktopContainerOnly` value) and so become real, visible-but-
    /// blank `NSWindow`s today.
    ///
    /// **Grounded in real capture data, not pure speculation**: all four ghosts (windowIds
    /// 983208/132042/132028/66450, present in every one of the six
    /// `samples/phase05-rail-events-2026-08-19` captures) carry the EXACT same
    /// `styleEx = 0x08000088` = `WS_EX_NOACTIVATE (0x08000000) | WS_EX_TOOLWINDOW
    /// (0x00000080) | WS_EX_TOPMOST (0x00000008)`, and `title == ""`, verified directly
    /// against the raw JSONL (not reconstructed from a summary). Cross-checked against
    /// EVERY OTHER window in all six samples that carries either the TOOLWINDOW or
    /// NOACTIVATE bit (a full grep sweep, not a spot check): every single one of them
    /// already has `style == styleDesktopContainerOnly` exactly (the five multi-monitor
    /// "Windows 输入体验" overlays and every degenerate 0x0/1x1/396x0/1009x4 helper) and so
    /// is already excluded by the check above — this new rule changes the outcome for
    /// these four windowIds ONLY across the entire sample set, zero collateral impact.
    ///
    /// **What is NOT sample-verified**: `ownerWindowId`'s real wire value for these four
    /// windows — adr/0008 §0 documents that no phase05 sample ever captured
    /// `ownerWindowId`'s actual value (rail-probe.c never logged it), so `ownerWindowId ==
    /// 0` below is required but unconfirmed against real bits; a tray-flyout helper window
    /// being desktop-owned (0) rather than owned by a specific parent is the reasonable
    /// expectation, not a verified fact. This is exactly the gap `Tools/window-smoke`'s new
    /// `[style-dump]` line (this same pass) exists to close on the next live run.
    ///
    /// Requires BOTH ex-style bits together (not either alone) and both the empty title AND
    /// the unowned check — the exact three-way signature actually observed, deliberately
    /// tighter than "any one signal," to minimize the chance of hiding some legitimate
    /// TOOLWINDOW-only palette this rule was never meant to catch. Fails OPEN (stays
    /// mappable) the instant any one of the three conditions doesn't hold, per the plan's
    /// "unknown styles render visible" principle applied narrowly to this one guessed rule
    /// — not a general allow/deny-list.
    private static func isGhostSliverHelper(styleEx: UInt32, ownerWindowId: UInt32, title: String) -> Bool {
        let ghostExStyle = styleExToolWindow | styleExNoActivate
        return styleEx & ghostExStyle == ghostExStyle && title.isEmpty && ownerWindowId == 0
    }

    /// Per `docs/plans/phase2.md` §2 W2's stated principle, an unrecognized style FAILS
    /// OPEN (returns `true`) — this only excludes what's actually been observed to be
    /// non-content; it is not a general allow/deny-list policy.
    ///
    /// `fieldFlags` is accepted now (adr/0008 §3's owner field, wired end-to-end starting
    /// this pass) but not yet consumed by any branch below — a forward-compatible signature
    /// for W1's Z-order/owner work and W4's IME-candidate-window classification, both
    /// expected to need it, rather than changing this signature a second time. `styleEx`/
    /// `ownerWindowId` were accepted-but-unconsumed as of W0①; this W2 pass is their first
    /// real consumer (the ghost-sliver rule above), alongside the newly added `title`.
    public static func isMappableWindow(
        width: UInt32, height: UInt32, style: UInt32, styleEx: UInt32,
        ownerWindowId: UInt32, fieldFlags: UInt32, title: String
    ) -> Bool {
        if width <= 1 || height <= 1 { return false }
        // Garbage-value guard carried over unchanged from the size-only filter: no sane
        // single window exceeds 16384 in either dimension (also guards against a
        // 0x80000000-wide order silently misdecoding as huge-but-positive under UInt32).
        if width > 16384 || height > 16384 { return false }
        if style & styleChild != 0 { return false }
        // adr/0010 W4 real-host correction: bare WS_POPUP alone is ALSO a live menu/
        // system-menu popup's exact style (see styleDesktopContainerOnly's own doc comment
        // for the real-host evidence) -- ownerWindowId == 0 is what actually distinguishes
        // "desktop-container/IME-overlay/degenerate-helper" (always unowned) from "a real
        // popup menu" (always owned by the window whose menu it is). An owned bare-WS_POPUP
        // window fails open here, same "unknown/unexpected shape stays visible" principle
        // every other rule in this function already follows.
        if style == styleDesktopContainerOnly, ownerWindowId == 0 { return false }
        if isGhostSliverHelper(styleEx: styleEx, ownerWindowId: ownerWindowId, title: title) { return false }
        return true
    }
}
