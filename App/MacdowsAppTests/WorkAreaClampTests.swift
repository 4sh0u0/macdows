import Testing

// F-ja-4 lane E gate r1 m-3: the bridge clamps the work area into the ADVERTISED desktop at
// connect. Window-smoke under `WINDOW_SMOKE_DECLARED_DESKTOP` advertises a desktop smaller than the
// real one while its work area is still derived from the real topology, so without the clamp the
// server would be told a work area that reaches past the desktop it was given (gate r1's example:
// declared 1920x1080, work area 0,30,2560,1350). For the App the clamp is a no-op -- MacdowsCore
// derives the work area from the same freeze as the desktop and clips it there -- which WC1 states.
//
// These drive `+[CRSession clampWorkAreaLeft:top:right:bottom:toDesktopWidth:height:]` directly: the
// pure function `crb_pre_connect` calls, the whole decision, offline. What the connect path does
// with its answer (the WARN, and the refusal of a rectangle the clamp emptied) is pinned as source
// in `BridgeExecWitnessPinTests`, because the connect path cannot be driven offline.
@Suite("F-ja-4 m-3 — the bridge clamps the work area into the advertised desktop")
struct WorkAreaClampTests {

    /// One call, as plain values: the four edges in wire order and the changed flag.
    private static func clamp(
        _ left: UInt32, _ top: UInt32, _ right: UInt32, _ bottom: UInt32,
        desktop width: UInt32, _ height: UInt32
    ) -> (edges: [UInt32], changed: Bool) {
        let result = CRSession.clampWorkAreaLeft(
            left, top: top, right: right, bottom: bottom, toDesktopWidth: width, height: height)
        return ([result.left, result.top, result.right, result.bottom], result.changed.boolValue)
    }

    /// WC1: a work area inside the desktop -- the App's every connect (1x, menu bar 30 pt, Dock
    /// 90 pt) -- comes back byte for byte, unflagged, so the product wire is unchanged.
    @Test("WC1 a work area inside the desktop is returned unchanged and unflagged")
    func insideIsUnchanged() {
        let result = Self.clamp(0, 30, 2560, 1350, desktop: 2560, 1440)
        #expect(result.edges == [0, 30, 2560, 1350])
        #expect(result.changed == false)
        // The two edges equal to the desktop are inside it: right and bottom are exclusive, so a
        // full-width work area IS the desktop's width.
        let whole = Self.clamp(0, 0, 2560, 1440, desktop: 2560, 1440)
        #expect(whole.edges == [0, 0, 2560, 1440])
        #expect(whole.changed == false)
    }

    /// WC2: gate r1 m-3's own example -- the real work area against a smaller declared desktop.
    /// Right is clamped to the WIDTH and bottom to the HEIGHT (clamping right by the height would
    /// give 1080; clamping bottom by the width would leave 1350).
    @Test("WC2 a desktop declared smaller than the work area clamps both far edges and flags it")
    func smallerDesktopClamps() {
        let result = Self.clamp(0, 30, 2560, 1350, desktop: 1920, 1080)
        #expect(result.edges == [0, 30, 1920, 1080])
        #expect(result.changed == true)
    }

    /// WC3: one axis at a time, so each axis's clamp is shown alone -- and on a non-square desktop,
    /// so an edge clamped by the other axis's extent comes out wrong.
    @Test("WC3 only the width, or only the height, exceeding the desktop clamps that axis alone")
    func singleAxis() {
        let wide = Self.clamp(0, 30, 2560, 1000, desktop: 1920, 1080)
        #expect(wide.edges == [0, 30, 1920, 1000])
        #expect(wide.changed == true)
        let tall = Self.clamp(0, 30, 1800, 1350, desktop: 1920, 1080)
        #expect(tall.edges == [0, 30, 1800, 1080])
        #expect(tall.changed == true)
        // The near edges clamp too: a left / top past the desktop is pulled in to it.
        let farOrigin = Self.clamp(2000, 1200, 2560, 1350, desktop: 1920, 1080)
        #expect(farOrigin.edges == [1920, 1080, 1920, 1080])
        #expect(farOrigin.changed == true)
        // Only a NEAR edge past the desktop (an inverted rectangle): left is pulled in, right and
        // bottom do not move, and the clamp must still be flagged -- `changed` is "any edge moved",
        // not "a far edge moved" (lane smoke-wa gate r1 m-2, mutant G1). The rectangle is refused
        // afterwards by the connect path's existing non-empty check; this asserts the function only.
        let nearOnly = Self.clamp(2000, 30, 1500, 1000, desktop: 1920, 1080)
        #expect(nearOnly.edges == [1920, 30, 1500, 1000])
        #expect(nearOnly.changed == true)
    }

    /// WC4: no desktop to clamp into. With either extent 0 the connect path sets no desktop at all
    /// (FreeRDP keeps its own default), so there is nothing to clamp against: the edges come back
    /// as given, unflagged, even when they are far outside anything.
    @Test("WC4 a zero desktop extent clamps nothing and flags nothing, however large the edges")
    func zeroDesktopClampsNothing() {
        let none = Self.clamp(0, 30, 2560, 1350, desktop: 0, 0)
        #expect(none.edges == [0, 30, 2560, 1350])
        #expect(none.changed == false)
        let noHeight = Self.clamp(0, 30, 2560, 1350, desktop: 1920, 0)
        #expect(noHeight.edges == [0, 30, 2560, 1350])
        #expect(noHeight.changed == false)
        let noWidth = Self.clamp(0, 30, 2560, 1350, desktop: 0, 1080)
        #expect(noWidth.edges == [0, 30, 2560, 1350])
        #expect(noWidth.changed == false)
    }

    /// WC5: all four zero is the "send nothing" value (no usable display, or window-smoke's knob at
    /// 0), and it must stay exactly that, unflagged, against any desktop.
    @Test("WC5 all four edges zero stay zero and unflagged")
    func allZeroStaysZero() {
        for (width, height) in [(UInt32(2560), UInt32(1440)), (1920, 1080), (1, 1), (0, 0)] {
            let result = Self.clamp(0, 0, 0, 0, desktop: width, height)
            #expect(result.edges == [0, 0, 0, 0], "desktop \(width)x\(height)")
            #expect(result.changed == false, "desktop \(width)x\(height)")
        }
    }

    /// WC6: a work area wholly to the right of the declared desktop clamps to an EMPTY rectangle
    /// (left == right). The function returns it as it is -- emptiness is not its judgement; the
    /// connect path's pinned TS_RECTANGLE_16 refusal (`left >= right`) is what keeps it off the wire.
    @Test("WC6 a work area clamped to nothing comes back empty, not repaired")
    func clampedToEmptyIsReturnedAsIs() {
        let result = Self.clamp(2000, 30, 2560, 1350, desktop: 1920, 1080)
        #expect(result.edges == [1920, 30, 1920, 1080])
        #expect(result.changed == true)
        #expect(result.edges[0] >= result.edges[2], "left >= right: the connect path's refusal applies")
    }
}
