import AppKit
import MacdowsCore

/// ADR-0025 a-1: every start-panel value that a probe measured, or that an owner probe may still
/// move, in ONE place. The panel, its anchor and the launcher read these and nothing else, and the
/// construction pins (`StartPanelControllerTests`) read them from here, so a value the owner's
/// in-person probes overturn is a one-line change plus its pin.
///
/// Source of each value: the a-1 probe report (`<lane>/reports/probe-report-a1.md`) as folded by the
/// controller (`<lane>/gates/probe-fold-a1.md`). "Measured" means measured on this machine's
/// macOS 27.2, one screen, Dock visible at the bottom; "pending" names the owner runbook step that
/// can still move it.
enum StartPanelPolicy {
    /// L1 (measured): `.statusBar` (25) and `.popUpMenu` (101) both draw above the Dock (20); the
    /// lower of the two covers fewer system pop-overs. Pending: magnification and auto-hide slide-out
    /// (runbook 4.2 / 4.3); if the Dock covers the panel there, `.popUpMenu` is the next candidate.
    static let level: NSWindow.Level = .statusBar

    /// L2 (measured): read back unchanged and no exception. AppKit validates only
    /// `canJoinAllSpaces + moveToActiveSpace` (it throws); other contradictory pairs are accepted
    /// silently, so the raw value is pinned (0x10a). Pending: full-screen spaces and a second
    /// desktop (runbook 5.x).
    static let collectionBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]

    /// K1 / K4 (measured): a `[.borderless, .nonactivatingPanel]` panel defaults to false, and true
    /// makes `isVisible` report a hidden panel as visible, which breaks the open / close toggle.
    /// The controller closes the panel itself on losing key, on deactivation and on a click
    /// outside it.
    static let hidesOnDeactivate = false

    /// K1 / K2 (measured): a borderless non-activating panel cannot become key unless its class
    /// overrides `canBecomeKey`; with the override, `makeKeyAndOrderFront(nil)` makes it key
    /// without bringing the App to the front. `orderFront` + `makeFirstResponder` does not.
    static let overridesCanBecomeKey = true

    /// ADR-0025 R-1′: only a reopen the Dock process sent opens the panel; a reopen from anywhere
    /// else (an `open` while running, Finder, Launchpad) or one whose sender cannot be read takes
    /// the no-session branch. R1 (measured): `open -a` reads as not the Dock. Pending: the Dock
    /// click's own sender (runbook 1.1).
    static let requiresDockSender = true

    /// Design note §1: the panel's Dock-side edge sits this far outside the Dock's inner edge. The
    /// geometry itself is MacdowsCore's (`DockAnchorGeometry`); this is the same number, named here
    /// so the pins that read this type see it.
    static let dockGap: CGFloat = DockAnchorGeometry.dockGap

    /// ADR-0025 §1.4 (I-2): a launch with no ExecResult after this long reads "no reply"
    /// (`sp_r_timeout`). Pending: the SP-5 in-person timings.
    static let execTimeout: Duration = .seconds(8)

    /// ADR-0025 R-3: the Recent section shows at most this many programs.
    static let recentLimit = 8

    /// Design note §8: the Dock menu lists at most this many pinned and recent programs, and cuts a
    /// title longer than `dockMenuTitleLimit` characters in the middle (`NSMenu` does not).
    static let dockMenuPinnedLimit = 3
    static let dockMenuRecentLimit = 5
    static let dockMenuTitleLimit = 40

    /// Design note §1: the panel's width, row height and corner radius.
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 16

    /// "Click the Dock icon again to close" (design note §6): the Dock click that should close the
    /// panel first takes key away from it (and is a click outside it), so the panel has already
    /// closed itself when the reopen arrives. A Dock reopen this soon after such an automatic close
    /// is the toggle's second click and does not open the panel again. Pending: the order of the two
    /// on a real Dock click (runbook 2.x).
    static let reopenToggleGrace: TimeInterval = 0.5

    /// Showing the panel can coincide with the App's own activation (a Dock click activates the App,
    /// probe K3: a moment later), which hands key back to the App's previous key window. Losing key
    /// this soon after showing makes the panel key again instead of closing it. Pending: the real
    /// order on a Dock click with the Hosts window open (runbook 2.x).
    static let keyLossGraceAfterShow: TimeInterval = 0.3

    /// Design note §6: the fade-in, skipped when Reduce Motion is on.
    static let fadeInDuration: TimeInterval = 0.12
}
