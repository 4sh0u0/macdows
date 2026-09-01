import Foundation
import Testing
@testable import ReplayDiffKit

/// Untitled anchoring, step 3 (docs `upgrade-gate/2026-09-untitled-payload-stability.md` §2–§3 /
/// §7.3): an untitled created window's token is partitioned by its **payload class** — the
/// `(style, styleEx, windowWidth, windowHeight)` tuple of its first WindowCreate, the four fields
/// the analysis found stable across recording days (style 100% equal in 84 comparable pairs) —
/// with the creation ordinal counted WITHIN the class: `window+<style>+<styleEx>+<w>x<h>#k`.
/// Offsets, `show`, `numVisibilityRects` and `fieldFlags` are session variables (§3) and stay out
/// of the key. An extra or missing window therefore shifts only its own class's members, never
/// the whole untitled population; the residual is the within-class shift, pinned by
/// `TitleAnchoredIdentityTests.untitledResidualCascades`. Components are decimal integers and the
/// separators (`+`, `x`, `#`) are outside the integer alphabet, so — like `window#k`, `window?#k`
/// and the constants — the shape collides with no title token (`window@…`, which escapes `#`).
@Suite("untitled anchoring step 3: untitled windows are keyed by payload class, ordinal within the class")
struct ClassPartitionedIdentityTests {
    /// The shared fixture builder's WindowCreate payload is `style 382664704, styleEx 256,
    /// width 320 (default), height 240`; a different `width` is a different class.
    static func create(_ tMs: Int, _ id: UInt32, width: Int = 320) -> String {
        TitleAnchoredIdentityTests.windowCreate(tMs: tMs, id: id, title: "", width: width)
    }
    static let classToken320 = "window+382664704+256+320x240"

    /// §5's ladder: an extra untitled window of ANOTHER class at the head of the stream is one
    /// finding — the window itself — and leaves every other untitled identity untouched.
    @Test("an extra untitled window of another class shifts nothing")
    func otherClassExtraWindowShiftsNothing() throws {
        let a: UInt32 = 197_612, b: UInt32 = 983_208, x: UInt32 = 11_111
        let shared = [Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a), Self.create(12, b)]
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(shared, label: "two-classes"),
            candidate: TitleAnchoredIdentityTests.stream([Self.create(5, x, width: 640)] + shared, label: "plus-third-class")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine }, "\(report.differences)")
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        let only = try #require(countChanges.first, "exactly the extra window: \(report.differences)")
        #expect(countChanges.count == 1, "unexpected: \(countChanges.map(\.detail))")
        #expect(only.eventName == "WindowCreate")
        #expect(only.detail.contains("windowId=\"window+382664704+256+640x240#0\""), "got: \(only.detail)")
    }

    /// The honest residual: an extra window of the SAME class does shift that class's members —
    /// and the cascade note still fires (2 vs 3 distinct un-anchored `window` handles).
    @Test("an extra untitled window of the same class still shifts its class-mates")
    func sameClassExtraWindowStillCascadesWithinTheClass() {
        let a: UInt32 = 197_612, b: UInt32 = 983_208, x: UInt32 = 11_111
        let shared = [Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a), Self.create(12, b)]
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(shared, label: "same-class"),
            candidate: TitleAnchoredIdentityTests.stream([Self.create(5, x)] + shared, label: "plus-same-class")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine }, "\(report.differences)")
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        // Exactly: the candidate-only third WindowCreate identity (#2) plus the icon, whose
        // window moved from `#0` to `#1` (one identity lost on each side).
        #expect(countChanges.count == 3, "within-class shift is a real residual: \(countChanges.map(\.detail))")
        #expect(report.notes.contains { $0.hasPrefix("CASCADE RISK") && $0.contains("3 distinct") && $0.contains("baseline's 2") })
    }

    /// The token is visible in reports, so its shape is contract.
    @Test("an untitled created window renders as `window+<style>+<styleEx>+<w>x<h>#k`")
    func classTokenShape() throws {
        let a: UInt32 = 197_612
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a), TitleAnchoredIdentityTests.windowIcon(tMs: 12, id: a)],
                label: "two-icons"),
            candidate: TitleAnchoredIdentityTests.stream(
                [Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a)], label: "one-icon")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine }, "\(report.differences)")
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        let only = try #require(countChanges.first)
        #expect(countChanges.count == 1, "unexpected: \(countChanges)")
        #expect(only.detail.contains("windowId=\"\(Self.classToken320)#0\""), "got: \(only.detail)")
    }

    /// §3: offsets, `show`, `numVisibilityRects` and `fieldFlags` are session variables — the same
    /// window with a different offset on the other side must still pair (and report the offset
    /// as a field difference), so none of them may enter the class key. Killed by adding any of
    /// them to the key.
    @Test("session-variable fields stay out of the class key")
    func sessionVariablesAreNotPartOfTheClassKey() {
        let a: UInt32 = 197_612
        let moved = Self.create(10, a)
            .replacingOccurrences(of: "\"windowOffsetX\":0,\"windowOffsetY\":0", with: "\"windowOffsetX\":37,\"windowOffsetY\":91")
            .replacingOccurrences(of: "\"fieldFlags\":13567", with: "\"fieldFlags\":13439")
            .replacingOccurrences(of: "\"show\":5", with: "\"show\":8")
            .replacingOccurrences(of: "\"numVisibilityRects\":1", with: "\"numVisibilityRects\":2")
        #expect(moved != Self.create(10, a), "the fixture mutation must have applied")
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream([Self.create(10, a), TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a)], label: "here"),
            candidate: TitleAnchoredIdentityTests.stream([moved, TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a)], label: "moved")
        )
        #expect(!report.differences.contains { $0.diffClass == .unparsableLine }, "\(report.differences)")
        #expect(report.differences.filter { $0.diffClass == .eventCountChanged }.isEmpty,
                "same class, same window: \(report.differences.map(\.detail))")
        let fields = Set(report.differences.filter { $0.diffClass == .fieldValueChanged }.compactMap(\.field))
        #expect(fields.isSuperset(of: ["windowOffsetX", "windowOffsetY", "show"]), "the session variables are still compared: \(fields)")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }
}
