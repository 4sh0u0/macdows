import Foundation

/// A platform-neutral snapshot of which modifier keys are currently held, mirroring the
/// eight keys CRBridge's `CRModifierKey` / `ThirdParty/FreeRDP/client/Mac/MRDPView.m`'s
/// `updateFlagState` distinguish. `OptionSet` rather than importing AppKit's
/// `NSEvent.ModifierFlags` directly -- this package stays no-AppKit (adr/0006 §2);
/// `RemoteWindowRegistry` (AppKit-side) is responsible for converting
/// `NSEvent.ModifierFlags` into this type at the boundary.
public struct ModifierKeySet: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let capsLock = ModifierKeySet(rawValue: 1 << 0)
    public static let shift = ModifierKeySet(rawValue: 1 << 1)
    public static let control = ModifierKeySet(rawValue: 1 << 2)
    public static let option = ModifierKeySet(rawValue: 1 << 3)
    public static let command = ModifierKeySet(rawValue: 1 << 4)
    public static let numericPad = ModifierKeySet(rawValue: 1 << 5)
    // W4c review M4: MRDPView.m:624-631 -- NSEventModifierFlagHelp and
    // NSEventModifierFlagFunction are two *distinct* NSEvent bits, but both resolve to the
    // same RDP_SCANCODE_HELP on the wire. Kept as two separate keys here (not collapsed
    // into one), mirroring the reference implementation's own two separate switch cases,
    // so a caller diffing `NSEvent.modifierFlags` bit-for-bit doesn't have to special-case
    // "these two AppKit bits happen to share one RDP scancode" itself.
    public static let help = ModifierKeySet(rawValue: 1 << 6)
    public static let function = ModifierKeySet(rawValue: 1 << 7)

    /// Every individual bit, in the same order MRDPView.m's updateFlagStates checks them
    /// (Help/Function appended after the original six, matching where MRDPView.m's own
    /// switch statement lists them) -- callers needing a per-key list (e.g. "which keys are
    /// currently held, one at a time") iterate this array rather than reimplementing the
    /// enumeration.
    public static let allKeys: [ModifierKeySet] = [
        .capsLock, .shift, .control, .option, .command, .numericPad, .help, .function,
    ]
}

/// Pure diff/release logic for modifier-key tracking (W4c H1 review fix): given the
/// previously-known held set and a newly-observed one, which individual keys transitioned,
/// and -- separately -- given a currently-held set (e.g. at focus loss), which keys need an
/// unconditional RELEASE to bring RDP's own modifier state back in sync with "nothing
/// held". No AppKit/CRSession dependency, so this is directly unit-testable (adr/0006 §2)
/// without a live session or a real Mac keyboard event.
///
/// H1's core fix: this tracker's state must be *session-level* (one instance, one
/// `ModifierKeySet` var), not per-window. A physical modifier key is a single piece of
/// state on one physical keyboard -- tracking it separately per `RemoteWindow` let a
/// press recorded while window A was focused go unmatched by its own release if the user
/// released it while window B was focused instead (B's own dictionary entry never recorded
/// the press in the first place), leaving RDP's remote-side modifier state permanently
/// stuck "held" with no transition ever observed to clear it. `RemoteWindowRegistry` is
/// responsible for owning exactly one `ModifierKeySet` for the whole session and routing
/// every window's `flagsChanged`-equivalent event through the same tracker.
public enum ModifierKeyTracker {
    /// One bit's change, in the order `ModifierKeySet.allKeys` enumerates them.
    public struct Transition: Equatable, Sendable {
        public let key: ModifierKeySet
        public let down: Bool
        public init(key: ModifierKeySet, down: Bool) {
            self.key = key
            self.down = down
        }
    }

    /// Diffs `previous` against `current`, returning one `Transition` per bit that actually
    /// flipped (mirrors MRDPView.m's own updateFlagState/updateFlagStates: one DOWN or
    /// RELEASE call per changed bit, nothing for unchanged bits, in `allKeys`' own order).
    public static func transitions(from previous: ModifierKeySet, to current: ModifierKeySet) -> [Transition] {
        ModifierKeySet.allKeys.compactMap { key in
            let was = previous.contains(key)
            let isNow = current.contains(key)
            guard was != isNow else { return nil }
            return Transition(key: key, down: isNow)
        }
    }

    /// W4c H1: given the set of modifiers currently tracked as held (e.g. right before a
    /// window resigns key/first-responder status, when this client can no longer reliably
    /// observe the physical keyboard), the RELEASE transitions needed to bring tracked
    /// state back to "nothing held" -- one per currently-set bit, all `down: false`, in
    /// `allKeys`' own order. Sending these unconditionally (rather than waiting for a real
    /// release event that might never arrive on this window again) is what keeps RDP's own
    /// modifier state from getting stuck.
    public static func releaseAll(_ held: ModifierKeySet) -> [Transition] {
        ModifierKeySet.allKeys.filter(held.contains).map { Transition(key: $0, down: false) }
    }
}
