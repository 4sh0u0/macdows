import Foundation
import Testing
@testable import ReplayDiffKit

/// W2 batch 2 (D10 noise-vocabulary/pairing review): **payload-anchored identity**, the
/// "real fix" the ordinal-shift-cascade limitation deferred here by name (the old
/// `SemanticDiffer` Known-limitations note, `Tools/replay-diff/README.md`, and
/// review-L5-r1 §a.4 all said: title-keyed where a title is present, W2 batch 2).
///
/// The mechanism under test: `window`-namespace handles whose stream carries a non-empty
/// `title` for them (any WindowCreate/WindowUpdate order, first non-empty title wins) are
/// canonicalized to a title-anchored token instead of a first-appearance ordinal — so an
/// extra or missing window EARLY in the stream no longer shifts every later window's
/// identity, **for windows whose title is unique**. Same-title duplicates disambiguate by
/// a per-side first-appearance `#k` — the ordinal mechanism reduced to the group, with
/// the group's residual cascade intact (review W2b-r1 F2). Untitled handles and the
/// `surface`/`notifyIcon` namespaces (no payload to anchor on) keep plain ordinals: the
/// cascade is *collapsed where a unique title exists*, not abolished —
/// `untitledResidualCascades` and `sameTitleGroupChangeRaisesNote` below pin the honest
/// residuals.
@Suite("W2b2 title-anchored identity collapses the ordinal-shift cascade")
struct TitleAnchoredIdentityTests {
    // MARK: - Fixture builders (fixtures live in Tests/, never samples/ — U7)

    static func windowCreate(tMs: Int, id: UInt32, title: String, width: Int = 320) -> String {
        """
        {"t_ms":\(tMs),"tid":"0x1f6be3540","ev":"WindowCreate","windowId":\(id),\
        "fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":\(width),\
        "windowHeight":240,"numVisibilityRects":1,"style":382664704,"styleEx":256,\
        "show":5,"title":"\(title)"}
        """
    }

    static func windowIcon(tMs: Int, id: UInt32) -> String {
        #"{"t_ms":\#(tMs),"tid":"0x1f6be3540","ev":"WindowIcon","windowId":\#(id)}"#
    }

    static func stream(_ lines: [String], label: String) -> ReplayStream {
        ReplayStream.parse(contents: lines.joined(separator: "\n") + "\n", label: label)
    }

    // MARK: - The documented experiment, titled variant

    /// The exact experiment the old limitation note measured (one extra WindowCreate,
    /// carrying a unique title, prepended to the real 145-line s3-multiapp capture): it
    /// used to yield 98 eventCountChanged findings and ~190 in total, all but one of them
    /// costume. With title anchoring it must collapse to the one finding that is real —
    /// the extra window itself — and the window-namespace cascade note must NOT fire (no
    /// un-anchored handle count changed: the extra window is uniquely titled, and the
    /// IME same-title group's membership is untouched).
    @Test("the documented titled-extra experiment collapses to exactly one real finding")
    func titledExperimentCollapses() throws {
        let url = try #require(PhaseSamples.url(named: "s3-multiapp"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        let extra = Self.windowCreate(tMs: 1, id: 11111, title: "Extra Head Window")
        let mutated = [lines[0], extra] + lines.dropFirst()

        let report = SemanticDiffer().diff(
            baseline: ReplayStream.parse(contents: contents, label: "s3"),
            candidate: ReplayStream.parse(contents: mutated.joined(separator: "\n") + "\n", label: "s3-plus-one")
        )
        #expect(report.differences.count == 1, "expected the cascade to collapse, got: \(report.differences.count)")
        let finding = try #require(report.differences.first)
        #expect(finding.diffClass == .eventCountChanged)
        #expect(finding.eventName == "WindowCreate")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") },
                "a uniquely-titled extra window must not raise the cascade note any more")
    }

    // MARK: - Identity theft at the head of a synthetic stream

    /// Baseline opens A then B (an icon lands on B); candidate opens a brand-new C first.
    /// Ordinal identity paired A-with-C and B-with-A and orphaned everything downstream;
    /// title anchoring must keep A↔A and B↔B (icon included) and report exactly the one
    /// genuinely-new window.
    @Test("a new titled window at the head no longer steals every later identity")
    func headInsertionDoesNotStealIdentity() throws {
        let baseline = Self.stream([
            Self.windowCreate(tMs: 10, id: 101, title: "Alpha"),
            Self.windowCreate(tMs: 20, id: 202, title: "Beta"),
            Self.windowIcon(tMs: 30, id: 202),
        ], label: "base")
        let candidate = Self.stream([
            Self.windowCreate(tMs: 10, id: 555, title: "Gamma"),
            Self.windowCreate(tMs: 20, id: 666, title: "Alpha"),
            Self.windowCreate(tMs: 30, id: 777, title: "Beta"),
            Self.windowIcon(tMs: 40, id: 777),
        ], label: "cand")

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let finding = try #require(report.differences.first)
        #expect(finding.diffClass == .eventCountChanged)
        #expect(finding.eventName == "WindowCreate")
    }

    // MARK: - Same-title disambiguation must stay observable

    /// Two windows sharing one title must not collapse into one identity. The fixture is
    /// deliberately asymmetric (review W2b-r1 F3 caught the symmetric version as
    /// unfailable — index-wise pairing inside one merged bucket reported zero either
    /// way): an icon sits on the SECOND same-title window in the baseline and on the
    /// FIRST in the candidate. Correct disambiguation reports the migration as two count
    /// findings (`window@Chrome#1` vs `window@Chrome`); a "just key on the title string"
    /// rewrite merges the bucket, pairs the icons, and reports zero — red here. Pairs
    /// 1:1 across sides only while the group's relative order is stable; per-side `#k`
    /// makes no cross-side promise beyond that (see the class doc's same-title residual).
    @Test("same-title windows stay distinct identities — an icon moving between them is reported")
    func sameTitleDisambiguation() {
        let baseline = Self.stream([
            Self.windowCreate(tMs: 10, id: 101, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 202, title: "Chrome", width: 800),
            Self.windowIcon(tMs: 30, id: 202),
        ], label: "base")
        let candidate = Self.stream([
            Self.windowCreate(tMs: 10, id: 909, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 404, title: "Chrome", width: 800),
            Self.windowIcon(tMs: 30, id: 909),
        ], label: "cand")

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "unexpected: \(report.differences)")
        #expect(counts.allSatisfy { $0.eventName == "WindowIcon" })
    }

    /// Review W2b-r1 F1: a title that literally contains the disambiguator separator must
    /// not forge another window's token. Un-escaped, `Chrome#1` (a perfectly ordinary
    /// Windows title shape) collides with the second `Chrome`'s `window@Chrome#1`, the
    /// two handles merge into one bucket, and a real icon migration between them came
    /// back `PASS`/exit 0 — a silent false negative in a regression gate. With escaping
    /// the migration is reported.
    @Test("a title containing '#' cannot forge a disambiguated token")
    func titleWithHashDoesNotCollide() {
        let baseline = Self.stream([
            Self.windowCreate(tMs: 10, id: 101, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 202, title: "Chrome", width: 800),
            Self.windowCreate(tMs: 30, id: 303, title: "Chrome#1", width: 640),
            Self.windowIcon(tMs: 40, id: 202),
        ], label: "base")
        let candidate = Self.stream([
            Self.windowCreate(tMs: 10, id: 901, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 902, title: "Chrome", width: 800),
            Self.windowCreate(tMs: 30, id: 903, title: "Chrome#1", width: 640),
            Self.windowIcon(tMs: 40, id: 903),
        ], label: "cand")

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "the icon moved between two REAL windows — must be reported: \(report.differences)")
        #expect(counts.allSatisfy { $0.eventName == "WindowIcon" })
    }

    /// Review W2b-r2 finding R2-2: the class doc and README quote **8** as the same-title
    /// group's only clean single-cause measurement (a pure creation-order swap: equal
    /// handle counts, no surface jitter, no note). Pinned against the real capture, same
    /// N-4 discipline as the 49 (53 before untitled anchoring step 1).
    @Test("a two-line creation-order swap inside the same-title group measures exactly 8 findings, no note")
    func sameTitleGroupSwapMeasuresEight() throws {
        let url = try #require(PhaseSamples.url(named: "s3-multiapp"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        // The group's titles ride WindowUpdate events; `#k` is assigned at each HANDLE's
        // first appearance — its untitled WindowCreate — so the swap that shifts `k` is a
        // swap of the two earliest member CREATES, located via the titled updates.
        let memberIds = Set(lines.compactMap { line -> Substring? in
            guard line.contains(#""title":"Windows 输入体验""#),
                  let match = line.range(of: #""windowId":[0-9]+"#, options: .regularExpression)
            else { return nil }
            return line[match].dropFirst(#""windowId":"#.count)
        })
        #expect(memberIds.count == 5, "the documented IME-overlay group has five members, got \(memberIds.count)")
        let createIndexes = memberIds.compactMap { id in
            lines.firstIndex { $0.contains(#""ev":"WindowCreate""#) && $0.contains("\"windowId\":\(id),") }
        }.sorted()
        #expect(createIndexes.count == 5, "every member needs a WindowCreate, got \(createIndexes.count)")
        var mutated = lines
        mutated.swapAt(createIndexes[0], createIndexes[1])

        let report = SemanticDiffer().diff(
            baseline: ReplayStream.parse(contents: contents, label: "s3"),
            candidate: ReplayStream.parse(contents: mutated.joined(separator: "\n") + "\n", label: "s3-group-swap")
        )
        #expect(report.differences.count == 8, "the documented in-group swap measurement drifted: \(report.differences.count)")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") },
                "equal counts — count inequality is the note's only trigger")
    }

    /// Review W2b-r1 F6 / r2 R2-3: the redaction guard must not stay untested dead code.
    /// With `title` redacted, anchoring would copy the very value redaction hides into
    /// four unredacted identifier fields and every `identity …` line — so the prescan
    /// falls back to ordinals wholesale, and no report string may carry a title.
    @Test("redacting 'title' disables anchoring instead of leaking titles through tokens")
    func redactedTitleDisablesAnchoring() {
        var options = DifferOptions()
        options.fieldPolicy.redactedFields.insert("title")
        let baseline = Self.stream([
            Self.windowCreate(tMs: 10, id: 101, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 202, title: "Chrome", width: 800),
            Self.windowIcon(tMs: 30, id: 202),
        ], label: "base")
        let candidate = Self.stream([
            Self.windowCreate(tMs: 10, id: 909, title: "Chrome", width: 400),
            Self.windowCreate(tMs: 20, id: 404, title: "Chrome", width: 800),
            Self.windowIcon(tMs: 30, id: 909),
        ], label: "cand")

        let report = SemanticDiffer(options: options).diff(baseline: baseline, candidate: candidate)
        // Ordinal identity still reports the migration (window#1 vs window#0) — redaction
        // costs anchoring quality, never detection.
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(counts.count == 2, "unexpected: \(report.differences)")
        for difference in report.differences {
            #expect(!difference.detail.contains("window@"), "anchored token leaked under redaction: \(difference.detail)")
            #expect(!difference.detail.contains("Chrome"), "title text leaked under redaction: \(difference.detail)")
        }
    }

    /// Review W2b-r1 F2: a same-title group's `#k` is a per-side first-appearance index —
    /// a membership change in the group shifts the other members' identities, which is a
    /// cascade, and the note must fire for it (the group's members count as un-anchored).
    @Test("a same-title group membership change raises the cascade note")
    func sameTitleGroupChangeRaisesNote() throws {
        let baseline = Self.stream([
            Self.windowCreate(tMs: 10, id: 101, title: "IME", width: 400),
            Self.windowCreate(tMs: 20, id: 202, title: "IME", width: 800),
        ], label: "base")
        let candidate = Self.stream([
            Self.windowCreate(tMs: 5, id: 555, title: "IME", width: 320),
            Self.windowCreate(tMs: 10, id: 901, title: "IME", width: 400),
            Self.windowCreate(tMs: 20, id: 902, title: "IME", width: 800),
        ], label: "cand")

        let report = SemanticDiffer().diff(baseline: baseline, candidate: candidate)
        let cascade = try #require(report.notes.first { $0.hasPrefix("CASCADE RISK") })
        #expect(cascade.contains("`window`"))
        #expect(cascade.contains("3 distinct"))
        #expect(cascade.contains("baseline's 2"))
    }

    // MARK: - The honest residual

    /// The same head-insertion experiment with an *untitled* extra window: nothing to
    /// anchor on, so the untitled ordinal pool shifts and the cascade persists. This pin
    /// keeps the residual named — if it ever shrinks (or grows) the note text and the
    /// README's Known-limitations section must move with it. History: 53 while the
    /// `0xFFFFFFFF` no-active-window constant was still ordinalised; 49 since untitled
    /// anchoring step 1 made it a constant (`IdentifierConstantTests`). Per-class, the
    /// synthetic experiment moved MonitoredDesktop 2 → 0 and WindowCreate 9 → 7 in this
    /// class — but this experiment carries the constant on BOTH sides, which is not the
    /// scenario step 1 targets, and its TOTAL rose 87 → 118 (eventOrderChanged 22 → 51, of
    /// which MonitoredDesktop 0 → 18 — the constant's occurrences now pair instead of being
    /// leftovers, so their positional drift is reported; WindowCreate fieldValueChanged
    /// 12 → 18 — all six from the injected synthetic window now MIS-pairing with a real
    /// untitled one and comparing payloads instead of being a leftover).
    /// The step's own measurement is the real frozen×re-record corpus, quoted in the class
    /// doc: 946 → 879.
    @Test("an untitled extra head window still cascades — the residual the note keeps naming")
    func untitledResidualCascades() throws {
        let url = try #require(PhaseSamples.url(named: "s3-multiapp"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        // The prose (this suite's doc, the class doc, the README, the runtime note) names
        // a 145-line capture; the number stays pinned here, with the 49 it produces
        // (review W2b-r1 F4 — the pin rode the deleted 98-experiment test and must not
        // be lost with it).
        #expect(lines.count == 145, "the documented experiment names a 145-line capture, got \(lines.count)")
        let extra = Self.windowCreate(tMs: 1, id: 11111, title: "")
        let mutated = [lines[0], extra] + lines.dropFirst()

        let report = SemanticDiffer().diff(
            baseline: ReplayStream.parse(contents: contents, label: "s3"),
            candidate: ReplayStream.parse(contents: mutated.joined(separator: "\n") + "\n", label: "s3-plus-untitled")
        )
        // Exact pin, per round-2 finding N-4's lesson (pin only the construction-
        // independent count, and pin it against the real capture the prose names) — this
        // is the number the CASCADE note quotes, so the two must move together.
        let counts = report.differences.filter { $0.diffClass == .eventCountChanged }.count
        #expect(counts == 49, "the documented untitled residual drifted: \(counts)")
        let note = try #require(report.notes.first { $0.hasPrefix("CASCADE RISK") },
                                "an untitled handle-count change must still raise the note")
        #expect(note.contains("49 eventCountChanged"),
                "the note's quoted residual must match the measured one")
    }
}
