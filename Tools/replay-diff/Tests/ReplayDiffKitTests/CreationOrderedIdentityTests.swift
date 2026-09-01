import Foundation
import Testing
@testable import ReplayDiffKit

/// Untitled anchoring, step 2 (docs `upgrade-gate/2026-09-untitled-payload-stability.md` §4.2–4.3 /
/// §7.2): an untitled `window` handle's ordinal is defined by its **WindowCreate** position only —
/// creation order inside the orders lane, which is one thread and therefore deterministic — not
/// by whichever event happened to mention the handle first. Two mechanisms used to leak into the
/// ordinal pool: a `GfxMapSurfaceToWindow` on the gfx thread can mention a handle before the
/// orders thread delivers its WindowCreate (a race that lands differently every run), and a
/// handle that is referenced but never created inside the capture (a window that already existed
/// when the probe attached; a notify icon's owner) consumed an ordinal too. Referencing events
/// now look the created handle's token up; handles with no WindowCreate at all live in their own
/// late pool `window?#k`, so they cannot shift the created windows' positions.
@Suite("untitled anchoring step 2: ordinals come from WindowCreate order, late handles get their own pool")
struct CreationOrderedIdentityTests {
    static func gfxMap(tMs: Int, surface: UInt32, window: UInt32) -> String {
        #"{"t_ms":\#(tMs),"tid":"0x16f0f7000","ev":"GfxMapSurfaceToWindow","surfaceId":\#(surface),"windowId":\#(window),"mappedWidth":320,"mappedHeight":240}"#
    }
    static func create(_ tMs: Int, _ id: UInt32) -> String {
        TitleAnchoredIdentityTests.windowCreate(tMs: tMs, id: id, title: "")
    }

    /// §4.2: the gfx-lane map mentions X before X's own WindowCreate on one side and after it on
    /// the other. Same windows, same creation order — the identities must pair.
    @Test("a cross-lane first mention no longer decides an untitled handle's ordinal")
    func crossLaneRaceDoesNotOrderUntitledHandles() {
        let x: UInt32 = 197_612, y: UInt32 = 983_208
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.gfxMap(tMs: 9, surface: 3, window: x), Self.create(10, y), Self.create(11, x)],
                label: "map-first"),
            candidate: TitleAnchoredIdentityTests.stream(
                [Self.create(10, y), Self.create(11, x), Self.gfxMap(tMs: 12, surface: 3, window: x)],
                label: "create-first")
        )
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(countChanges.isEmpty, "creation order is identical on both sides: \(countChanges.map(\.detail))")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }

    /// §4.3: a handle that is only ever referenced (here by a Gfx map) and never created must not
    /// consume a `window#k` — the created window keeps `window#0` on both sides. The referenced
    /// handle is still reported: its events are one-sided, and it lives in the late pool, whose
    /// own count change is what the cascade note now names.
    @Test("a referenced-but-never-created handle does not shift the created ordinals")
    func lateHandleDoesNotShiftCreatedOrdinals() {
        let a: UInt32 = 197_612, z: UInt32 = 655_360
        let created = [Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a)]
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream([Self.gfxMap(tMs: 5, surface: 1, window: z)] + created, label: "with-late"),
            candidate: TitleAnchoredIdentityTests.stream(created, label: "without-late")
        )
        let windowFindings = report.differences.filter { $0.eventName == "WindowCreate" || $0.eventName == "WindowIcon" }
        #expect(windowFindings.isEmpty, "the created window must pair on both sides: \(windowFindings.map(\.detail))")
        let oneSided = report.differences.filter { $0.diffClass == .eventTypeOnlyOnOneSide }
        #expect(oneSided.map(\.eventName) == ["GfxMapSurfaceToWindow"], "unexpected: \(oneSided)")
        #expect(!report.notes.contains { $0.contains("un-anchored `window` handle") },
                "the created pool did not change size")
        #expect(report.notes.contains { $0.hasPrefix("CASCADE RISK") && $0.contains("`window?`") },
                "the late pool DID change size (1 vs 0) and the note must say which pool")
    }

    /// The late pool's token is visible in reports, so its shape is contract: `window?#<k>` —
    /// distinct from ordinals (`window#<k>`), titles (`window@…`) and constants (`window#none`).
    @Test("a late handle renders as `window?#k`")
    func lateHandleTokenShape() throws {
        let z: UInt32 = 655_360
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.gfxMap(tMs: 5, surface: 1, window: z), Self.gfxMap(tMs: 6, surface: 2, window: z)], label: "two"),
            candidate: TitleAnchoredIdentityTests.stream([Self.gfxMap(tMs: 5, surface: 1, window: z)], label: "one")
        )
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        let only = try #require(countChanges.first, "one extra map is one count change")
        #expect(countChanges.count == 1, "unexpected: \(countChanges)")
        #expect(only.detail.contains("windowId=\"window?#0\""), "got: \(only.detail)")
    }

    /// HWND reuse (review untitled-step2-r1 I1): a handle destroyed and re-created within one
    /// capture keeps its FIRST creation position. Without the `ordinals[raw] == nil` guard the
    /// second WindowCreate would overwrite A's ordinal with the current count and the next new
    /// handle would collide with it — and an icon that moved from A to C would then compare as
    /// "same window", the silent-PASS shape this module declares out of bounds (W2b-r1 F1).
    @Test("HWND reuse keeps the first creation ordinal, so a moved icon is still a finding")
    func hwndReuseKeepsTheFirstCreationOrdinal() {
        let a: UInt32 = 197_612, c: UInt32 = 983_208
        let icon = TitleAnchoredIdentityTests.windowIcon
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.create(10, a), icon(11, a), Self.create(12, a), Self.create(13, c), icon(14, a)],
                label: "icon-stays-on-a"),
            candidate: TitleAnchoredIdentityTests.stream(
                [Self.create(10, a), icon(11, a), Self.create(12, a), Self.create(13, c), icon(14, c)],
                label: "icon-moves-to-c")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine }, "\(report.differences)")
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged && $0.eventName == "WindowIcon" }
        #expect(countChanges.count == 2, "the icon's second occurrence moved between two DISTINCT windows: \(report.differences)")
        #expect(report.hasRegressions)
    }

    /// Precedence pin: a handle that is never created but DOES carry a title (a pre-existing
    /// shell window whose WindowUpdate names it) anchors on the title as before — the late pool
    /// is only for handles with neither a WindowCreate nor a title. An implementation that
    /// consulted "has a WindowCreate?" before "has a title?" would put both the titled window and
    /// the untitled late handle into `window?` by first appearance, and this fixture's swapped
    /// mention order would then mis-pair them.
    @Test("a titled-but-never-created handle anchors on its title, not on the late pool")
    func titledLateHandleStillAnchorsOnTitle() {
        // A WELL-FORMED WindowUpdate (the RailEvent decoder needs the whole window-order payload):
        // this test's first draft used a truncated line, the decoder dropped it as
        // `unparsableLine`, the shell handle never reached canonicalization, and the test passed
        // against the very mutation it exists to catch. Hence the unparsable guard below.
        func update(tMs: Int, id: UInt32, title: String) -> String {
            #"{"t_ms":\#(tMs),"tid":"0x1f6be3540","ev":"WindowUpdate","windowId":\#(id),"fieldFlags":16777220,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":0,"windowHeight":0,"numVisibilityRects":0,"style":0,"styleEx":0,"show":0,"title":"\#(title)"}"#
        }
        let shell: UInt32 = 65_548, shell2: UInt32 = 65_602, w: UInt32 = 655_360, w2: UInt32 = 655_400
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [update(tMs: 5, id: shell, title: "Program Manager"), Self.gfxMap(tMs: 6, surface: 1, window: w)],
                label: "title-first"),
            candidate: TitleAnchoredIdentityTests.stream(
                [Self.gfxMap(tMs: 5, surface: 1, window: w2), update(tMs: 6, id: shell2, title: "Program Manager")],
                label: "map-first")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine },
                "fixture lines must decode, or the test proves nothing: \(report.differences)")
        #expect(report.differences.isEmpty,
                "title anchors the shell, the late pool holds only the map's handle: \(report.differences.map(\.detail))")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }
}
