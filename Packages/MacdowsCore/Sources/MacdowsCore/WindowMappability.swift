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
    private static let styleDesktopContainerOnly: UInt32 = 0x8000_0000

    /// Per `docs/plans/phase2.md` §2 W2's stated principle, an unrecognized style FAILS
    /// OPEN (returns `true`) — this only excludes what's actually been observed to be
    /// non-content; it is not a general allow/deny-list policy.
    ///
    /// `styleEx`/`ownerWindowId`/`fieldFlags` are accepted now (adr/0008 §3's owner field,
    /// wired end-to-end starting this pass) but not yet consumed by any branch below —
    /// a forward-compatible signature for W1's Z-order/owner work and W4's IME-candidate-
    /// window classification, both expected to need them, rather than changing this
    /// signature a second time.
    public static func isMappableWindow(
        width: UInt32, height: UInt32, style: UInt32, styleEx: UInt32,
        ownerWindowId: UInt32, fieldFlags: UInt32
    ) -> Bool {
        if width <= 1 || height <= 1 { return false }
        // Garbage-value guard carried over unchanged from the size-only filter: no sane
        // single window exceeds 16384 in either dimension (also guards against a
        // 0x80000000-wide order silently misdecoding as huge-but-positive under UInt32).
        if width > 16384 || height > 16384 { return false }
        if style & styleChild != 0 { return false }
        if style == styleDesktopContainerOnly { return false }
        return true
    }
}
