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
    ///
    /// UNIT (ADR-0015 §1 vocabulary, M1/L8 tagging pass): **remote px** — the RDP wire's own
    /// unit, the same one `WindowsRect` carries, and the reason `ContentSize` (mac pt) needed
    /// the unit contract spelled out on it: these two types meet inside `computeMask`.
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
    ///
    /// UNIT (ADR-0015 §1 vocabulary, M1/L8 tagging pass): **mac pt**, measured from the
    /// layer's own bottom-left corner rather than the primary screen's — the two differ in
    /// origin, not in unit. `ContentSize`'s own note carries the pipeline's full unit
    /// contract; the only consumer is `RemoteWindow.applyMaskNow`, which turns each of these
    /// into a `CGRect` in the same points through one named, identity conversion
    /// (`App/RemoteWindowRendering/RemoteWindow.swift`, `CGRect.init(layerPoints:)`).
    ///
    /// THE adr/0010 §2 BAN IS NOW PINNED, not merely documented: ADR-0015 §7's "(c) 的位置
    /// 更正" warns that an implementer told to "route the mask through a named conversion"
    /// is most likely to reach for `WindowGeometry.macRect` — the one function this
    /// paragraph forbids. `WindowShapeTests.maskFlipAnchorsOnContentHeightNotThePrimaryScreenHeight`
    /// asserts the difference numerically (a fixture where the two flips disagree by 660 pt),
    /// so the ban fails a test rather than a code review from here on.
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
    ///
    /// UNIT CONTRACT (ADR-0015 §7 (c) + §9's L8 row; the tag is **record-only**, U5 —
    /// `m1-wave1-rulings.md:4`). §7 requires three elements at every F6 site, in this order:
    ///
    /// 1. **CURRENT UNIT: mac pt** (ADR-0015 §1's vocabulary). This value reaches
    ///    `computeMask` from `RemoteWindowRegistry.computeMaskResult`
    ///    (`RemoteWindowRegistry.swift:1086-1098`) as `macContentRect(...)`'s `NSSize` — an
    ///    AppKit size, therefore points, and specifically the output side of
    ///    `WindowGeometry.macRect`'s remote-px → mac-pt conversion. The `visibilityRects`
    ///    handed to that SAME call are **remote px**, straight off the wire (`WireRect`'s own
    ///    note). That one call is therefore the mask pipeline's unit boundary — ADR-0015 §7's
    ///    "(c) 的位置更正" locates the boundary at the registry, explicitly **not** in this
    ///    file and **not** in `RemoteWindow`. This type's job is to state which side of the
    ///    boundary it stands on; crossing it is the caller's.
    /// 2. **W3 TRIGGER: the first session with `DisplayScale.remotePixelsPerPoint != 1`.**
    ///    `computeMask` below clips remote-px wire rects against this mac-pt bounds and flips
    ///    them around this mac-pt height. That arithmetic is unit-homogeneous only while one
    ///    remote pixel is one point, which ADR-0015 §0a/§0c record as true of every
    ///    configuration that exists today (we advertise no `DesktopScaleFactor`; `docs/plans/
    ///    phase3.md:219`: the single display is 1x). It is not a coincidence to rely on
    ///    silently, which is why it is written down here rather than left to the reader.
    /// 3. **WHAT CHANGES WHEN IT FIRES (shape, not value — U5 is record-only).** The caller's
    ///    boundary conversion becomes explicit at the registry: wire rects are divided into
    ///    layer points there, before they ever meet this size, and this type goes on meaning
    ///    exactly "the layer's own bounds, in mac pt". **Whether that divisor really is
    ///    `rasterScale` is W3's to measure, not M1's to guess** (ADR-0015 §7 (c) row, §8), so
    ///    this milestone adds no scale arithmetic anywhere in this file — ADR-0015 §9's L8
    ///    row: "L8 不在本波次引入任何比例乘法". At `remotePixelsPerPoint == 1` every form of
    ///    that future conversion is the identity, which is what "no rendering behavior change"
    ///    means concretely for this wave.
    ///
    /// AND THE OUTPUT IS `LayerRect`, NOT `MacRect`: this height is the mask's flip anchor, in
    /// the layer's OWN space. The primary screen's height (`DisplayFlipAnchor.
    /// primaryHeightInPoints`) is a different anchor for a different space and must never be
    /// substituted here — adr/0010 §2's ban, restated by ADR-0015 §7 and now pinned by
    /// `WindowShapeTests.maskFlipAnchorsOnContentHeightNotThePrimaryScreenHeight`.
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
