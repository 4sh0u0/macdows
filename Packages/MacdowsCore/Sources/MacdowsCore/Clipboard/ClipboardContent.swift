// S9: clipboard content never leaves through a description.
//
// Every type in this directory that holds clipboard text or bytes -- the two wrappers below
// and every enum with a case carrying one of them -- overrides all three of Swift's
// value-rendering paths: `description` (string interpolation, `print`, `String(describing:)`),
// `debugDescription` (`String(reflecting:)`, `debugPrint`, test-failure messages, and the
// payload of an enclosing enum's default rendering) and `customMirror` (`dump`, the debugger's
// variable view, anything walking `Mirror`). Each renders only lengths and state. A type that
// overrode one path and not the others would still leak through the rest; the S9 tests check
// all three for every such type.
//
// What this cannot reach: the String/Array storage itself. Swift gives no way to wipe a
// String's buffer when it is released, so a copy that reaches this layer stays in freed
// memory until reused -- the C store's wipe ends at the boundary where Swift takes over.

/// Clipboard text that has crossed (or is about to cross) the session boundary. A wrapper
/// rather than a bare `String` only so that rendering it shows its size, never its content.
public struct ClipboardText: Equatable, Sendable {
    /// The text itself. Reading it is fine; rendering it anywhere a human or a log might see is
    /// what this type exists to prevent.
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Length in UTF-16 code units -- the unit the wire and the limits are counted in.
    public var utf16Count: Int { value.utf16.count }
}

extension ClipboardText: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ClipboardText(utf16Count: \(utf16Count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["utf16Count": utf16Count], displayStyle: .struct)
    }
}

/// Clipboard bytes in wire form: `CF_UNICODETEXT`, UTF-16LE with its terminating NUL.
public struct ClipboardBytes: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var count: Int { bytes.count }
}

extension ClipboardBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ClipboardBytes(count: \(count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["count": count], displayStyle: .struct)
    }
}
