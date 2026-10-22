import Testing
@testable import MacdowsCore

// F-ja-4 lane E: `DisplayTopology.workAreaInRemotePixels`, the work area the bridge reports to the
// RAIL server with `SPI_SET_WORK_AREA` right after the vendored start command (which reports the
// whole desktop). Owner rulings 2026-10-22: the measure is `visibleFrame` (menu bar AND Dock
// excluded), window-smoke adopts it through the same function, and a mid-session Dock / menu-bar
// change is not followed (frozen until the next reconnect, like the desktop size).
//
// The numbers in W1 / W2 are the lane memo's §1.2 table: the owner Mac read at 1x on 2026-10-22
// (`frame = (0,0,2560,1440)`, `visibleFrame = (0,90,2560,1320)`: menu bar 30 pt, Dock 90 pt at the
// bottom), and the 2x row derived from it (menu bar 30 pt corroborated by the relay's XQuartz
// screen height; the Dock's 90 pt at 2x is the memo's inference, U-2). Expected values are worked
// out by hand in the comment above each case, from the flip
//   left = minX·s, top = (H − maxY)·s, right = maxX·s, bottom = (H − minY)·s
// with s = rasterScale and H = the primary's frame height -- never by calling the code under test.

private func display(
    x: Double = 0, y: Double = 0, width: Double, height: Double,
    scale: DisplayScale = .unscaled, isPrimary: Bool = true, visibleFrame: MacRect? = nil
) -> DisplayTopology.Display {
    DisplayTopology.Display(
        origin: MacPoint(x: x, y: y),
        size: MacSize(width: width, height: height),
        scale: scale,
        isPrimary: isPrimary,
        visibleFrame: visibleFrame
    )
}

private func workArea(_ displays: [DisplayTopology.Display]) throws -> WorkAreaInRemotePixels? {
    try #require(DisplayTopology(displays: displays)).workAreaInRemotePixels
}

/// `(left, top, right, bottom)` of a work area, so an expectation reads as one tuple.
private func edges(_ area: WorkAreaInRemotePixels?) -> [Int]? {
    area.map { [Int($0.left), Int($0.top), Int($0.right), Int($0.bottom)] }
}

/// A 1.5x scale -- not a mode this project's hardware has, only the fixture that makes rounding
/// observable (at 1x / 2x with integer points nothing is ever rounded).
private let scale1_5 = DisplayScale(remotePixelsPerPoint: 1.5, backingPixelsPerPoint: 1.5)

@Suite("DisplayTopology.workAreaInRemotePixels (F-ja-4 lane E)")
struct WorkAreaTests {

    /// W1. The owner Mac at 1x, as read on 2026-10-22.
    ///   left = 0, top = (1440 − 1410)·1 = 30, right = 2560, bottom = (1440 − 90)·1 = 1350.
    /// MUST-RED for: reading `frame` instead of `visibleFrame` (gives 0,0,2560,1440).
    @Test("W1 1x: menu bar 30 pt and Dock 90 pt leave (0,30,2560,1350)")
    func oneX() throws {
        let area = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 0, y: 90, width: 2560, height: 1320)),
        ])
        #expect(edges(area) == [0, 30, 2560, 1350])
    }

    /// W2. The same panel at "looks like 1280x720" (rasterScale 2).
    ///   left = 0, top = (720 − 690)·2 = 60, right = 1280·2 = 2560, bottom = (720 − 90)·2 = 1260.
    /// The desktop is 2560x1440 remote px, exactly as at 1x (ADR-0015 §3.5 F2).
    @Test("W2 2x: the same insets in points become (0,60,2560,1260) remote px")
    func twoX() throws {
        let topology = try #require(DisplayTopology(displays: [
            display(width: 1280, height: 720, scale: .fullyScaled2x,
                    visibleFrame: MacRect(x: 0, y: 90, width: 1280, height: 600)),
        ]))
        #expect(edges(topology.workAreaInRemotePixels) == [0, 60, 2560, 1260])
        #expect(topology.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 2560, height: 1440))
    }

    /// W3. The Dock on the left or the right edge moves `left` / `right`, and the menu bar still
    /// takes the top 30 pt.
    ///   left Dock 90 pt:  visibleFrame (90, 0, 2470, 1410) -> (90, 1440−1410 = 30, 2560, 1440)
    ///   right Dock 90 pt: visibleFrame (0, 0, 2470, 1410)  -> (0, 30, 2470, 1440)
    @Test("W3 a Dock on the left or the right moves left / right")
    func dockOnTheSide() throws {
        let left = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 90, y: 0, width: 2470, height: 1410)),
        ])
        #expect(edges(left) == [90, 30, 2560, 1440])
        let right = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 0, y: 0, width: 2470, height: 1410)),
        ])
        #expect(edges(right) == [0, 30, 2470, 1440])
    }

    /// W4. `visibleFrame == frame` -- given explicitly, or left at its default -- is exactly the
    /// whole desktop: the numbers the vendored start command already sends, so a display without a
    /// menu bar or Dock puts today's bytes on the wire.
    /// MUST-RED for: a default `visibleFrame` other than the frame (mutant M7).
    @Test("W4 visibleFrame == frame, explicit or by default, is exactly the whole desktop")
    func wholeFrameIsTheWholeDesktop() throws {
        let explicit = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 0, y: 0, width: 2560, height: 1440)),
        ])
        #expect(edges(explicit) == [0, 0, 2560, 1440])

        let defaulted1x = try workArea([display(width: 2560, height: 1440)])
        #expect(edges(defaulted1x) == [0, 0, 2560, 1440])
        let defaulted2x = try workArea([display(width: 1280, height: 720, scale: .fullyScaled2x)])
        #expect(edges(defaulted2x) == [0, 0, 2560, 1440])

        let single = try #require(DisplayTopology.single(widthInPoints: 1920, heightInPoints: 1080))
        #expect(single.primary.visibleFrame == single.primary.frameInPoints)
        #expect(edges(single.workAreaInRemotePixels) == [0, 0, 1920, 1080])
    }

    /// W4, over every existing ADR-0015 §3.5 / supplement fixture (all of them built without a
    /// `visibleFrame`): the work area is the primary's own frame in remote pixels -- `(0, 0,
    /// primaryWidth·s, primaryHeight·s)` -- and on the single-display rows that is the desktop.
    /// MUST-RED for: mutant M7, on every row.
    @Test("W4 every pre-lane fixture's work area is its primary's frame", arguments: DisplayTopologyFixtures.union)
    func preLaneFixturesKeepThePrimaryFrame(_ fixture: UnionFixture) throws {
        let topology = try #require(DisplayTopology(displays: fixture.displays))
        let primary = topology.primary
        let s = topology.rasterScale
        #expect(edges(topology.workAreaInRemotePixels)
            == [0, 0, Int(primary.size.width * s), Int(primary.size.height * s)])
        if fixture.displays.count == 1 {
            let desktop = topology.desktopSizeInRemotePixels
            #expect(edges(topology.workAreaInRemotePixels) == [0, 0, desktop.width, desktop.height])
        }
    }

    /// W5. A `visibleFrame` reaching outside the frame (AppKit never reports one; this is the
    /// clip's own fixture) is clipped into `[0, desktop]`, edge by edge.
    ///   (−100, −50, 3000, 1600): left −100 -> 0, top 1440 − 1550 = −110 -> 0,
    ///                            right 2900 -> 2560, bottom 1440 + 50 = 1490 -> 1440
    ///   (−10, 100, 2600, 1400):  left −10 -> 0, top 1440 − 1500 = −60 -> 0,
    ///                            right 2590 -> 2560, bottom 1440 − 100 = 1340
    @Test("W5 a visibleFrame beyond the frame is clipped into the desktop")
    func clippedToTheDesktop() throws {
        let beyond = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: -100, y: -50, width: 3000, height: 1600)),
        ])
        #expect(edges(beyond) == [0, 0, 2560, 1440])
        let partly = try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: -10, y: 100, width: 2600, height: 1400)),
        ])
        #expect(edges(partly) == [0, 0, 2560, 1340])
    }

    /// W6. Only the PRIMARY's `visibleFrame` counts, chosen by `isPrimary` and not by position:
    /// the secondary is listed FIRST here, so a `displays.first` read would pick it up.
    ///   desktop = (2560 + 1920, 1440) = 4480x1440 (secondary right, bottoms aligned)
    ///   primary visibleFrame (0, 90, 2560, 1320) -> (0, 30, 2560, 1350)
    ///   (the secondary's (2560, 0, 1920, 1050) would give (2560, 390, 4480, 1440))
    /// MUST-RED for: `displays.first` instead of the primary (mutant M4).
    @Test("W6 only the primary's visibleFrame counts, whatever the display order")
    func primaryOnly() throws {
        let primary = display(width: 2560, height: 1440,
                              visibleFrame: MacRect(x: 0, y: 90, width: 2560, height: 1320))
        func secondary(_ visibleFrame: MacRect) -> DisplayTopology.Display {
            display(x: 2560, y: 0, width: 1920, height: 1080, isPrimary: false, visibleFrame: visibleFrame)
        }
        let topology = try #require(DisplayTopology(displays: [
            secondary(MacRect(x: 2560, y: 0, width: 1920, height: 1050)), primary,
        ]))
        #expect(topology.desktopSizeInRemotePixels == DesktopSizeInRemotePixels(width: 4480, height: 1440))
        #expect(edges(topology.workAreaInRemotePixels) == [0, 30, 2560, 1350])

        // A different secondary visibleFrame changes nothing.
        let other = try workArea([secondary(MacRect(x: 2600, y: 10, width: 1800, height: 1000)), primary])
        #expect(edges(other) == [0, 30, 2560, 1350])
        // And primary-first gives the same answer.
        let primaryFirst = try workArea([primary, secondary(MacRect(x: 2560, y: 0, width: 1920, height: 1050))])
        #expect(edges(primaryFirst) == [0, 30, 2560, 1350])
    }

    /// W7. At a fractional scale the edges round INWARD: left / top up, right / bottom down, so the
    /// work area never claims a pixel row partly under the menu bar or the Dock.
    ///   frame 1000x700 at 1.5x (desktop 1500x1050); visibleFrame (10.5, 41, 979, 625.5):
    ///   left   = 10.5·1.5            = 15.75  -> 16
    ///   top    = (700 − 666.5)·1.5   = 50.25  -> 51
    ///   right  = (10.5 + 979)·1.5    = 1484.25 -> 1484
    ///   bottom = (700 − 41)·1.5      = 988.5  -> 988
    /// (Every intermediate is exact in binary floating point.)
    /// MUST-RED for: rounding outward / the directions swapped (mutant M6 gives 15,50,1485,989).
    @Test("W7 a fractional scale rounds inward: left/top up, right/bottom down")
    func roundsInward() throws {
        let area = try workArea([
            display(width: 1000, height: 700, scale: scale1_5,
                    visibleFrame: MacRect(x: 10.5, y: 41, width: 979, height: 625.5)),
        ])
        #expect(edges(area) == [16, 51, 1484, 988])
    }

    /// A rectangle that is empty after clipping and rounding, or not finite, cannot be sent; the
    /// caller then sends nothing and the server keeps the start command's whole desktop.
    ///   (3000, 0, 100, 100): left 3000 -> 2560, right 3100 -> 2560 -- empty
    ///   zero height; and a NaN edge
    ///   1.5x (0, 0.2, 1000, 0.4): top (700 − 0.6)·1.5 = 1049.1 -> 1050, bottom 1049.7 -> 1049 -- empty
    @Test("an empty or non-finite work area is nil, never a degenerate rectangle")
    func emptyIsNil() throws {
        #expect(try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 3000, y: 0, width: 100, height: 100)),
        ]) == nil)
        #expect(try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 0, y: 100, width: 2560, height: 0)),
        ]) == nil)
        #expect(try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: .nan, y: 0, width: 2560, height: 1440)),
        ]) == nil)
        #expect(try workArea([
            display(width: 1000, height: 700, scale: scale1_5,
                    visibleFrame: MacRect(x: 0, y: 0.2, width: 1000, height: 0.4)),
        ]) == nil)
    }

    /// `visibleFrame` is read by nothing but the work area: the desktop size, the flip anchor, the
    /// union, the per-display Windows frames and BOTH descriptions are identical with and without
    /// it. The descriptions matter on their own -- archived oslog lines carry their exact text.
    @Test("visibleFrame changes no pre-lane derivation and neither description")
    func nothingElseReadsIt() throws {
        let plain = try #require(DisplayTopology(displays: [
            display(width: 1280, height: 720, scale: .fullyScaled2x),
            display(x: 1280, y: -360, width: 1920, height: 1080, isPrimary: false),
        ]))
        let withInsets = try #require(DisplayTopology(displays: [
            display(width: 1280, height: 720, scale: .fullyScaled2x,
                    visibleFrame: MacRect(x: 0, y: 90, width: 1280, height: 600)),
            display(x: 1280, y: -360, width: 1920, height: 1080, isPrimary: false,
                    visibleFrame: MacRect(x: 1280, y: -360, width: 1920, height: 1050)),
        ]))
        #expect(withInsets.desktopSizeInRemotePixels == plain.desktopSizeInRemotePixels)
        #expect(withInsets.flipAnchor == plain.flipAnchor)
        #expect(withInsets.unionBoundsInPoints == plain.unionBoundsInPoints)
        #expect(withInsets.rasterScale == plain.rasterScale)
        #expect(withInsets.isUniformScale == plain.isUniformScale)
        for index in plain.displays.indices {
            #expect(withInsets.frameInRemotePixels(ofDisplayAt: index) == plain.frameInRemotePixels(ofDisplayAt: index))
            #expect(withInsets.displays[index].description == plain.displays[index].description)
        }
        #expect(withInsets.description == plain.description)
        // The two differ only where they should.
        #expect(edges(plain.workAreaInRemotePixels) == [0, 0, 2560, 1440])
        #expect(edges(withInsets.workAreaInRemotePixels) == [0, 60, 2560, 1260])
    }

    /// The log field: four integers and three commas, the shape the host-side sampler prints the
    /// server's own view in (`wa=0,30,2560,1350`), so the two lines compare by eye.
    @Test("wireFields is left,top,right,bottom and nothing else")
    func wireFieldsShape() throws {
        let area = try #require(try workArea([
            display(width: 2560, height: 1440, visibleFrame: MacRect(x: 0, y: 90, width: 2560, height: 1320)),
        ]))
        #expect(area.wireFields == "0,30,2560,1350")
        #expect(area.wireFields.allSatisfy { $0.isNumber || $0 == "," })
    }
}
