import Foundation

/// One outbound Unicode keyboard wire event -- a single UTF-16 code unit's down or release
/// (adr/0011 §0b/§1). Mirrors `ModifierKeyTracker.Transition`'s shape for the same reason:
/// a small, `Equatable` value the offline test battery can assert sequences of directly.
public struct UnicodeKeyEvent: Equatable, Sendable {
    public let code: UInt16
    public let down: Bool
    public init(code: UInt16, down: Bool) {
        self.code = code
        self.down = down
    }
}

/// Pure specification of `CRSession.sendUnicodeText:`'s own per-UTF-16-code-unit
/// expansion (adr/0011 §1: "码元展开发生在真正出线的那一个出口"; adr/0011 §5 item 3's offline
/// acceptance battery). `CRSession.mm` cannot itself run under `swift test` (it links
/// FreeRDP/AppKit), so this function exists specifically to give that ObjC method's
/// expansion logic an offline-testable, pure-Swift twin -- `-sendUnicodeText:`'s own loop
/// must be kept in lock-step with this one by inspection (both are a straightforward
/// "iterate `.utf16`, emit down then up per unit"); see that method's own doc comment in
/// CRSession.mm, which cross-references this type.
public enum UnicodeTextExpansion {
    /// One down/release pair per UTF-16 code unit, in string order -- a surrogate pair
    /// (e.g. an emoji) yields two pairs (4 events), never one; an empty string yields no
    /// events at all.
    public static func events(for text: String) -> [UnicodeKeyEvent] {
        var result: [UnicodeKeyEvent] = []
        result.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            result.append(UnicodeKeyEvent(code: unit, down: true))
            result.append(UnicodeKeyEvent(code: unit, down: false))
        }
        return result
    }
}
