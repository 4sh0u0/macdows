import Foundation

/// A window's local NSWindow resize bounds, derived from MS-RDPERP's `ServerMinMaxInfo`
/// (adr/0008 §1) track-size fields. `nil` on either side of a pair means "don't constrain
/// that bound" — the caller applies this straight onto `NSWindow.minSize`/`.maxSize`
/// (`RemoteWindow.applyTrackSizeConstraints`), substituting AppKit's own "unconstrained"
/// sentinels (`.zero` / `.greatestFiniteMagnitude`) for `nil` at that point, not here — this
/// type stays free of the AppKit boundary (adr/0006 §2), same split every other pure type
/// in this package already draws.
public struct WindowTrackSizeConstraints: Equatable, Sendable {
    public var minWidth: Double?
    public var minHeight: Double?
    public var maxWidth: Double?
    public var maxHeight: Double?

    public init(minWidth: Double?, minHeight: Double?, maxWidth: Double?, maxHeight: Double?) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

/// Phase 2 W3 (docs/plans/phase2.md §2 W3, adr/0008 §1): translates `ServerMinMaxInfo`'s
/// four track-size fields (`TS_RAIL_ORDER_MINMAXINFO`'s `ptMinTrackSize`/`ptMaxTrackSize` —
/// the two fields Win32's own `WM_GETMINMAXINFO` uses for interactive resize bounds, not
/// `ptMaxSize`/`ptMaxPosition`, which describe the *maximized* geometry and aren't
/// consumed by this pass) into a sentinel-filtered `WindowTrackSizeConstraints`. Deliberately
/// pure (no AppKit), mirroring `WindowMappability`/`StyleTranslator`'s own "same
/// implementation for the live AppKit consumer and for MacdowsCoreTests" split.
public enum MinMaxInfoTranslator {
    /// `CRDPEvent.minTrackWidth/minTrackHeight/maxTrackWidth/maxTrackHeight` are already
    /// widened from the wire's `INT16` to `int32_t` (CRSession.h's own doc comment on those
    /// properties — a uniformity widening, not a claim the upstream narrowing needs fixing).
    /// A field left unset by the server is `0` (Win32's own `WM_GETMINMAXINFO` contract:
    /// the struct is default-filled by the system, then the app overrides only the fields
    /// it cares about — an untouched field reads as its default, not as an explicit "zero
    /// size" request) — `0` is therefore filtered to `nil` here, never handed to
    /// `NSWindow.minSize`/`.maxSize` as a literal, which would otherwise clamp a window to
    /// zero width/height. A negative reading is stronger than merely absent: no genuine
    /// track size can be negative at all, so it's treated identically to `0` (defensive
    /// against a corrupt/unexpected wire value, per adr/0008 §0's caveat that this event's
    /// shape has never actually been observed against a real sample) rather than being
    /// passed through and silently misinterpreted as a request to shrink/grow past zero.
    public static func constraints(
        minTrackWidth: Int32, minTrackHeight: Int32, maxTrackWidth: Int32, maxTrackHeight: Int32
    ) -> WindowTrackSizeConstraints {
        func sanitized(_ value: Int32) -> Double? {
            value > 0 ? Double(value) : nil
        }
        return WindowTrackSizeConstraints(
            minWidth: sanitized(minTrackWidth),
            minHeight: sanitized(minTrackHeight),
            maxWidth: sanitized(maxTrackWidth),
            maxHeight: sanitized(maxTrackHeight)
        )
    }
}
