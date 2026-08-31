import Foundation

/// adr/0014 §1: the packing that lets one tray icon's `(windowId, notifyIconId)` wire identity
/// ride in an `NSStatusBarButton.tag`, which AppKit gives as a single `Int`.
///
/// **Bit layout** (this is the contract; `TrayButtonTagTests` pins it against literal values so
/// it cannot drift silently):
///
///     bit 63 ................................ 32 | bit 31 ................. 0
///     windowId (UInt32, verbatim)               | notifyIconId (UInt32, verbatim)
///
/// i.e. `windowId` occupies the high 32 bits, `notifyIconId` the low 32 -- an arbitrary but
/// internally consistent choice, and `unpack` is `pack`'s exact inverse over the whole
/// `UInt32 x UInt32` domain (no value is reserved, no key is unrepresentable, and the mapping
/// is injective, so two distinct keys can never collide on one tag). The `Int` that comes out
/// is a bit pattern, not a number: a `windowId` with its top bit set produces a NEGATIVE tag,
/// which is correct and expected -- `Int(bitPattern:)` and `UInt(bitPattern:)` are the two
/// halves of a lossless reinterpretation here, never an arithmetic conversion that could trap.
///
/// Relies on `Int` being 64-bit, which this project already assumes throughout (see
/// `RemoteWindowRegistry`'s own `RailEventKind` doc comment on `Int32`/`UInt32` field widths
/// for the same "this codebase's one and only target" reasoning).
///
/// **Why this lives in MacdowsCore rather than next to its AppKit caller**: it is pure
/// arithmetic with no AppKit or FreeRDP dependency, and the App target has no test bundle at
/// all -- packing arithmetic that only the App target can see is arithmetic no `swift test`
/// run can check. `TrayStatusController` (which writes the tag into the real button and reads
/// it back on click) and `RemoteWindowRegistry.debugSimulateTrayClick` (which builds the same
/// tag for the offline harness path) both call THIS type, so the harness path and the real
/// AppKit path can never encode the key differently -- a second, hand-rolled packing on either
/// side would test its own arithmetic instead of this one's.
public enum TrayButtonTag {
    /// Packs `(windowId, notifyIconId)` -- each a wire `UInt32` -- into one 64-bit `Int` tag,
    /// per the layout above.
    public static func pack(windowId: UInt32, notifyIconId: UInt32) -> Int {
        Int(bitPattern: UInt(UInt64(windowId) << 32 | UInt64(notifyIconId)))
    }

    /// Exact inverse of `pack`: `unpack(pack(w, n)) == (w, n)` for every `(w, n)`.
    public static func unpack(_ tag: Int) -> (windowId: UInt32, notifyIconId: UInt32) {
        let raw = UInt64(UInt(bitPattern: tag))
        return (UInt32(truncatingIfNeeded: raw >> 32), UInt32(truncatingIfNeeded: raw))
    }
}
