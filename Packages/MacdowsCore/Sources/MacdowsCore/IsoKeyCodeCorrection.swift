import Foundation

/// The three physical Mac keyboard layouts `KBGetLayoutType`/`fixKeyCode()` distinguish
/// (adr/0011 §4) -- `RemoteWindowRegistry` detects this once per session (`KBGetLayoutType(
/// LMGetKbdType())`, Carbon/HIToolbox) and injects it here; this package stays Carbon-free
/// itself (adr/0006 §2), same "detection is AppKit-side, translation is pure" split every
/// other MacdowsCore type already follows (`ModifierKeyTracker`, `CommandKeyMapper`).
public enum MacKeyboardType: Sendable, Equatable {
    case ansi
    case iso
    case jis
}

/// adr/0011 §4: the ISO-keyboard Grave(`` ` ``)/Section(`§`) keycode swap --
/// `ThirdParty/FreeRDP/client/Mac/MRDPView.m`'s `fixKeyCode()`, ISO branch only. adr/0011
/// §0a corrects a prior (wrong) assumption that this correction depended on the pressed
/// key's character: the vendored `fixKeyCode()`'s only branch that's actually *live* is a
/// pure `type == APPLE_KEYBOARD_TYPE_ISO` check (MRDPView.m:468-476); the Hungarian branch
/// that reads a character is `#if 0`'d out entirely (MRDPView.m:448-466) and dead. This
/// function is therefore keyed on keyboard type alone, exactly mirroring that live branch,
/// and is a pure, offline-testable function -- no AppKit/Carbon/FreeRDP dependency.
public enum IsoKeyCodeCorrection {
    /// `winpr/include/winpr/input.h`'s `APPLE_VK_ANSI_Grave` (0x32) / `APPLE_VK_ISO_Section`
    /// (0x0A) -- duplicated here narrowly rather than importing a FreeRDP header, mirroring
    /// this codebase's existing precedent for re-deriving a handful of wire constants
    /// locally instead of pulling in a whole dependency (e.g.
    /// `RemoteWindowRegistry.SysCommand`/`WindowOrderField`, `CRDPQueue`'s own text-buffer
    /// constants).
    private static let grave: UInt16 = 0x32
    private static let section: UInt16 = 0x0A

    /// Swaps Grave<->Section on an ISO keyboard; passes every other `macKeyCode` (and every
    /// keycode at all on ANSI/JIS) through unchanged. Mirrors `fixKeyCode()`'s live branch
    /// verbatim (MRDPView.m:470-476).
    public static func correct(macKeyCode: UInt16, keyboardType: MacKeyboardType) -> UInt16 {
        guard keyboardType == .iso else { return macKeyCode }
        switch macKeyCode {
        case grave: return section
        case section: return grave
        default: return macKeyCode
        }
    }
}
