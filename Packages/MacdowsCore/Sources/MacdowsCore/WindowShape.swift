import Foundation

/// adr/0010 §2/§3: turns a window's most recently known `visibilityRects` (wire-relative,
/// RECTANGLE_16, unsigned pixels) into a set of layer-space rects a consumer can build a
/// `CAShapeLayer` mask from — pure logic, no AppKit/CoreGraphics (adr/0006 §2's no-AppKit
/// boundary, same discipline `WindowGeometry` already follows: that file defines its own
/// `WindowsRect`/`MacRect` rather than importing CoreGraphics for `CGRect`, and this type
/// follows the identical precedent with `LayerRect` below). `App/RemoteWindowRendering/
/// RemoteWindow.swift` is the only consumer: it converts `LayerRect` to `CGRect` at the
/// AppKit boundary and builds a `CAShapeLayer` mask from the result.
public enum WindowShape {
    /// One wire `RECTANGLE_16` as `Double`s (never `UInt16` here — the transform's additive
    /// terms, `Δx`/`Δy` below, can legitimately go negative before clipping, and Swift's
    /// `UInt16` would trap). Field names/order match `crdpq_rect_t` exactly.
    public struct WireRect: Sendable, Equatable {
        public var left: Double
        public var top: Double
        public var right: Double
        public var bottom: Double

        public init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    /// A rect in the content layer's own coordinate space (macOS non-flipped layer
    /// geometry: origin bottom-left, y increasing upward) — the space `CALayer.mask`'s path
    /// is built in, distinct from both `WindowsRect` (Windows desktop space) and `MacRect`
    /// (mac SCREEN space, anchored on the primary screen's height — a completely different
    /// flip than this one; adr/0010 §2 explicitly warns against reusing `WindowGeometry.
    /// macRect` here for exactly this reason).
    public struct LayerRect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }
        var isEmpty: Bool { width <= 0 || height <= 0 }

        /// Clips `self` to `bounds`, never enlarging — a plain-Double reimplementation of
        /// `CGRect.intersection(_:)` (this package imports no CoreGraphics, see this type's
        /// own doc comment), narrow enough that pulling in a whole framework for it isn't
        /// worth the platform coupling.
        func clipped(to bounds: LayerRect) -> LayerRect {
            let x0 = max(x, bounds.x)
            let y0 = max(y, bounds.y)
            let x1 = min(maxX, bounds.maxX)
            let y1 = min(maxY, bounds.maxY)
            guard x1 > x0, y1 > y0 else {
                return LayerRect(x: 0, y: 0, width: 0, height: 0)
            }
            return LayerRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// The content layer's own size in points — mapped-canonical (adr/0010 §2: "内容视图尺寸已
    /// 与 mapped 像素等值"), i.e. the same size the caller already computed for
    /// `RemoteWindow.updateFrame(contentRect:)`'s content rect.
    public struct ContentSize: Sendable, Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// `computeMask(...)`'s return value. `.none` means "apply no mask at all" — the
    /// window shows its full content rect, unclipped. This is the outcome for every one of
    /// adr/0010 §3's five fail-open rules that this function itself can decide (rules 1-4;
    /// rule 5, "don't update while minimized," is a caller-side "don't call this function at
    /// all" decision, not something this function can express in its return value).
    /// `.rects` carries the fully-transformed, already-clipped layer-space rects to mask
    /// with — this can legitimately be an empty array (every wire rect clipped away to
    /// nothing, e.g. a stale rect set from before a resize) without collapsing back to
    /// `.none`: adr/0010 §3 rule 3's "count 0 → no mask, not invisible" is specifically about
    /// the WIRE's own reported count being zero, not about this function's own clipping step
    /// discarding every rect it was actually given — a caller asked for a real clip, and an
    /// empty result is that clip's own honest (if degenerate) answer, not a signal to ignore
    /// the request.
    public enum MaskResult: Sendable, Equatable {
        case none
        case rects([LayerRect])
    }

    /// - Parameters:
    ///   - visibilityRects: the window's most recently known wire rects (already bounded to
    ///     `CRDPQ_MAX_VISIBILITY_RECTS`/32 by the transport layer — this function makes no
    ///     assumption about that bound, it just transforms whatever it's given).
    ///   - wireCount: the wire's own `numVisibilityRects` (adr/0010 §3 rule 3's zero check —
    ///     deliberately the WIRE count, not `visibilityRects.count`, matching
    ///     `crdpq_window_order_t.numVisibilityRects`'s own "wire value, not stored count"
    ///     convention).
    ///   - truncated: adr/0010 §3 rule 1.
    ///   - windowOffset: `(windowOffsetX, windowOffsetY)` — the window's own RAIL origin.
    ///   - visibleOffset: `(visibleOffsetX, visibleOffsetY)`, or `nil` if `VIS_OFFSET` has
    ///     never been observed for this window (adr/0010 §3 rule 2). Callers MUST pass `nil`
    ///     here rather than substituting `windowOffset` or `(0, 0)` — see `MaskResult`'s own
    ///     "never assume `visibleOffset == windowOffset`" warning, which this parameter
    ///     exists to make impossible to get wrong by construction.
    ///   - correction: `WindowGeometryCorrection` — only `originX`/`originY` are consumed
    ///     here (today always 0, `WindowGeometryCorrection.zero`'s own doc comment); `width`/
    ///     `height` are ignored (those correct RAIL's reported window SIZE against the
    ///     GFX-mapped display size, a concern this function's caller already folds into
    ///     `contentSize` below, not something this transform's own coordinate math needs
    ///     separately).
    ///   - topInset: adr/0010 §6's placeholder for a future remote-titlebar crop — a pure
    ///     additive term in step 1, always 0 today.
    ///   - contentSize: see `ContentSize`'s own doc comment.
    ///   - isMaximized: adr/0010 §3 rule 4 (`PendingWindowState.isMaximized`, `show == 0x03`).
    ///
    /// adr/0010 §2's three-step transform, applied per rect, after adr/0010 §3's four
    /// function-decidable fail-open rules have all been checked (in the ADR's own listed
    /// order — the checks are independent short-circuits, so evaluation order has no
    /// behavioral effect beyond matching the ADR's own numbering for readability):
    /// 1. Re-anchor (Windows space, y down, content top-left origin): `Δx = visibleOffsetX −
    ///    windowOffsetX − correction.originX`, `Δy = visibleOffsetY − windowOffsetY −
    ///    correction.originY − topInset`; `local = r` shifted by `(Δx, Δy)`.
    /// 2. Flip y once (macOS non-flipped layer geometry, origin bottom-left): a rect's layer
    ///    y-origin is `contentSize.height − local.bottom`.
    /// 3. Clip to `(0, 0, contentSize)`; a rect with an empty intersection is dropped, never
    ///    enlarged past what the server actually reported.
    public static func computeMask(
        visibilityRects: [WireRect],
        wireCount: UInt32,
        truncated: Bool,
        windowOffset: (x: Double, y: Double),
        visibleOffset: (x: Double, y: Double)?,
        correction: WindowGeometryCorrection,
        topInset: Double,
        contentSize: ContentSize,
        isMaximized: Bool
    ) -> MaskResult {
        // adr/0010 §3 rule 1: truncated wire count → integrity of the set itself is
        // suspect (the server sent more rects than fit) — degrade to no mask.
        guard !truncated else { return .none }
        // adr/0010 §3 rule 4: a maximized window's visibility rects are frame-inset
        // (FreeRDP's own xf_rail.c finding, cited verbatim in the ADR) — applying them
        // would clip a fully-maximized window down by that inset. Clear the mask instead.
        guard !isMaximized else { return .none }
        // adr/0010 §3 rule 3: the wire's own count is zero — "no mask," never "invisible."
        guard wireCount > 0 else { return .none }
        // adr/0010 §3 rule 2: the anchor this transform needs has never actually been
        // observed for this window — NEVER assume it equals windowOffset or (0, 0); the
        // only safe reading is "shape unknown," which means no mask at all.
        guard let visibleOffset else { return .none }

        guard contentSize.width > 0, contentSize.height > 0 else { return .none }

        let dx = visibleOffset.x - windowOffset.x - correction.originX
        let dy = visibleOffset.y - windowOffset.y - correction.originY - topInset
        let height = contentSize.height
        let bounds = LayerRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)

        var transformed: [LayerRect] = []
        transformed.reserveCapacity(visibilityRects.count)
        for r in visibilityRects {
            // Step 1: re-anchor onto the window's own content-relative coordinate frame.
            let localLeft = r.left + dx
            let localTop = r.top + dy
            let localRight = r.right + dx
            let localBottom = r.bottom + dy

            // Step 2: flip y once, into layer space (origin bottom-left) — NOT
            // `WindowGeometry.macRect`'s screen-space flip (that anchors on the primary
            // screen's height for a completely different coordinate system; see this
            // function's own doc comment / adr/0010 §2's explicit warning against reusing
            // it here).
            let layerRect = LayerRect(
                x: localLeft, y: height - localBottom,
                width: localRight - localLeft, height: localBottom - localTop
            )

            // Step 3: clip to the content bounds — never enlarge a server-reported rect
            // that falls (even partially) outside the window's own current size.
            let clipped = layerRect.clipped(to: bounds)
            if !clipped.isEmpty {
                transformed.append(clipped)
            }
        }
        return .rects(transformed)
    }
}
