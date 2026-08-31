import Testing
@testable import MacdowsCore

/// Deterministic generator, so the 1024-pair sweep below covers a wide, unbiased slice of the
/// `UInt32 x UInt32` domain while still failing identically on every machine and every rerun --
/// a genuinely random sweep would turn a layout regression into a flake that reproduces on
/// someone else's laptop and not on the reporter's. SplitMix64 (Steele/Lea/Flood 2014), chosen
/// because it is four lines and needs no state beyond a seed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// adr/0014 §1's `(windowId, notifyIconId)` <-> `NSStatusBarButton.tag` packing, which moved
/// out of `TrayStatusController` (App target, no test bundle) into `MacdowsCore` precisely so
/// these can exist.
///
/// The round-trip tests below would pass against ANY injective packing -- including one whose
/// bit layout silently changed -- which is why `layoutIsPinnedToLiteralTagValues` exists: its
/// expected values were computed with the pre-move implementation and written down, so a
/// re-derived-from-scratch layout that is merely self-consistent goes red instead of green.
/// That matters here because the tag is not private state: it is written into a live AppKit
/// `NSStatusBarButton` by one call site and read back by another, and adr/0014's offline
/// harness path (`RemoteWindowRegistry.debugSimulateTrayClick`) packs its own tag the same
/// way, so all three have to agree bit for bit forever.
@Suite("TrayButtonTag")
struct TrayButtonTagTests {
    /// Every value here was produced by running the ORIGINAL
    /// `TrayStatusController.packTag`/`unpackTag` (as of df79b11, verbatim) before the move,
    /// then pasted in as a literal. They are the layout, stated independently of the code that
    /// implements it.
    ///
    /// The pairs are chosen so no single mistake passes all of them: the first is
    /// byte-asymmetric in both halves (a field swap or a byte-order slip changes it), the
    /// second is the sign-bit case (`windowId >= 0x8000_0000` must yield a NEGATIVE `Int`, not
    /// a trap and not a clamp), `(1, 0)` vs `(0, 1)` pin which half is high, and the all-ones
    /// pair pins the full-width case at `-1`.
    @Test("bit layout is pinned to literal tag values computed from the pre-move implementation")
    func layoutIsPinnedToLiteralTagValues() {
        #expect(TrayButtonTag.pack(windowId: 0x1234_5678, notifyIconId: 0x9ABC_DEF0) == 1_311_768_467_463_790_320)
        #expect(TrayButtonTag.pack(windowId: 0xAABB_CCDD, notifyIconId: 0x1122_3344) == -6_144_092_016_769_617_084)
        #expect(TrayButtonTag.pack(windowId: .max, notifyIconId: .max) == -1)
        #expect(TrayButtonTag.pack(windowId: 1, notifyIconId: 0) == 4_294_967_296)
        #expect(TrayButtonTag.pack(windowId: 0, notifyIconId: 1) == 1)
        #expect(TrayButtonTag.pack(windowId: 0, notifyIconId: 0) == 0)

        // The same pin from the read side: `unpack` is not merely SOME inverse of whatever
        // `pack` does, it decodes these specific literals into these specific halves. A layout
        // change that flipped both functions together would satisfy every round-trip test in
        // this file and still be caught by this pair of assertions.
        let decoded = TrayButtonTag.unpack(1_311_768_467_463_790_320)
        #expect(decoded.windowId == 0x1234_5678)
        #expect(decoded.notifyIconId == 0x9ABC_DEF0)

        let decodedNegative = TrayButtonTag.unpack(-6_144_092_016_769_617_084)
        #expect(decodedNegative.windowId == 0xAABB_CCDD)
        #expect(decodedNegative.notifyIconId == 0x1122_3344)
    }

    @Test("round trip is the identity on the domain's corners and on mixed values")
    func roundTripOnBoundaryValues() {
        let corners: [(windowId: UInt32, notifyIconId: UInt32)] = [
            (0, 0),
            (0, .max),
            (.max, 0),
            (.max, .max),
            (1, 1),
            (0x8000_0000, 0x8000_0000), // both halves' sign bits set
            (0x8000_0000, 0x7FFF_FFFF),
            (0x7FFF_FFFF, 0x8000_0000),
            (0x0000_FFFF, 0xFFFF_0000),
            (42, 7),
        ]
        for pair in corners {
            let unpacked = TrayButtonTag.unpack(TrayButtonTag.pack(windowId: pair.windowId, notifyIconId: pair.notifyIconId))
            #expect(unpacked.windowId == pair.windowId, "windowId lost for \(pair)")
            #expect(unpacked.notifyIconId == pair.notifyIconId, "notifyIconId lost for \(pair)")
        }
    }

    /// 1024 pseudo-random pairs from a fixed seed: round-trip identity AND injectivity in one
    /// sweep. Injectivity is the property `TrayStatusController.handleLeftClick(tag:)` actually
    /// depends on -- two live tray icons whose keys collided on one tag would route one icon's
    /// clicks to the other -- and it is checked against a key built by STRING concatenation
    /// rather than by any shift-or arithmetic, so the dedupe cannot agree with a broken packing
    /// by sharing its bug.
    @Test("1024 seeded random pairs: round trip is the identity and no two pairs collide")
    func seededSweepRoundTripsAndNeverCollides() {
        var rng = SplitMix64(seed: 0x0D14_2026_0831_C0DE)
        var tagsByKey: [String: Int] = [:]

        for _ in 0..<1024 {
            let windowId = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)
            let notifyIconId = UInt32.random(in: UInt32.min...UInt32.max, using: &rng)
            let tag = TrayButtonTag.pack(windowId: windowId, notifyIconId: notifyIconId)

            let unpacked = TrayButtonTag.unpack(tag)
            #expect(unpacked.windowId == windowId)
            #expect(unpacked.notifyIconId == notifyIconId)

            tagsByKey["\(windowId)|\(notifyIconId)"] = tag
        }

        // Distinct keys must map to distinct tags. Comparing the two counts (rather than
        // asserting a fixed number of samples) keeps this correct even though the generator is
        // free to repeat a pair.
        #expect(tagsByKey.count > 1000, "the seeded sweep must actually cover >1000 distinct pairs")
        #expect(Set(tagsByKey.values).count == tagsByKey.count, "two distinct (windowId, notifyIconId) keys packed to the same tag")
    }

    @Test("the tag is 64 bits wide -- the whole premise of packing two UInt32s into one Int")
    func tagIsSixtyFourBitsWide() {
        // `Int` is 64-bit on this project's only target. A 32-bit `Int` would make the packing
        // above lossy rather than merely wrong, and every round-trip assertion in this file
        // would start failing for a reason that is not the packing's fault -- state it once,
        // here, so that failure is legible.
        #expect(MemoryLayout<Int>.size == 8)
        #expect(MemoryLayout.size(ofValue: TrayButtonTag.pack(windowId: 1, notifyIconId: 1)) == 8)
    }
}
