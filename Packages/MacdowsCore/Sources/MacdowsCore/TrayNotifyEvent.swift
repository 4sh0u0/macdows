import Foundation

/// adr/0014 §1: the `message` values this client sends in a RAIL ClientNotifyEvent
/// (`RAIL_NOTIFY_EVENT_ORDER.message`, `ThirdParty/FreeRDP/include/freerdp/rail.h:437` — a
/// wire **UINT32**, unlike `RAIL_SYSCOMMAND_ORDER.command`'s UINT16 at rail.h:430, which is
/// why every value here is `UInt32` and `CRSession.sendNotifyEvent` takes a `uint32_t`).
/// Values duplicated narrowly from `rail.h:137-138`, cited rather than imported — the same
/// precedent `IsoKeyCodeCorrection`'s keycodes and `RemoteWindowRegistry.SysCommand`'s `SC_*`
/// values already set for small wire constants in this AppKit-free, FreeRDP-free package.
///
/// **Why a raw button-down/up pair and not `NIN_SELECT`** (adr/0014 §1, the ratified v1
/// shape): MS-RDPERP attaches a version precondition to the `NIN_*` family (and to
/// `WM_CONTEXTMENU`) — the server only accepts those once the notify icon has declared a
/// sufficient `NOTIFY_ICON_STATE_ORDER.version`. That field is now merely OBSERVED (adr/0014
/// §7 bridges it for counting/logging), never consulted, so sending a `NIN_*` message would
/// be sending a PDU whose precondition this client cannot check. `WM_LBUTTONDOWN`/
/// `WM_LBUTTONUP` carry no such precondition: they are what a real shell delivers to a tray
/// icon's owner window for an ordinary left click, and MS-RDPERP 3.3.5.2.5.4 gives ZERO
/// delivery acknowledgement either way, so an unacknowledged, silently-refused `NIN_SELECT`
/// would be indistinguishable from a working one.
///
/// Right-click, double-click, balloon (`NIN_BALLOON*`) and every other `NIN_*` message stay
/// deliberately out of scope for v1 (adr/0014 §1), matching the W6 degradation form
/// `TrayStatusController` already implements on the AppKit side (no `NSStatusItem.menu` is
/// ever installed, so no right-click path exists to forward in the first place).
public enum TrayNotifyEvent {
    /// `WM_LBUTTONDOWN` (rail.h:137).
    public static let wmLButtonDown: UInt32 = 0x0000_0201
    /// `WM_LBUTTONUP` (rail.h:138).
    public static let wmLButtonUp: UInt32 = 0x0000_0202

    /// One left click on a tray icon, in wire order: down, then up — sent as TWO independent
    /// ClientNotifyEvent PDUs (adr/0014 §1/§2), not one compound message. Order is the
    /// outbound queue's own FIFO guarantee (adr/0005 §3), not something either PDU encodes,
    /// which is exactly why this is an ordered `Array` and not a `Set`: a caller iterating it
    /// in the order given is the whole contract.
    public static let leftClickSequence: [UInt32] = [wmLButtonDown, wmLButtonUp]
}
