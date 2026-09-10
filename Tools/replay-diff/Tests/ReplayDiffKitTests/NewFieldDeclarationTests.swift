import Testing
@testable import ReplayDiffKit

/// ADR-0018 U-7 prerequisite: rail-probe's window-order line grew eight keys across two
/// measurement-only steps (four `resizeMargin*`, then four client-rect fields). The frozen
/// 2026-08-19 baselines were recorded by a probe that predates both, so on the first 2x
/// re-record every matched `WindowCreate`/`WindowUpdate` pair would otherwise report eight
/// ``DiffClass/fieldPresenceChanged`` findings — a false alarm proportional to the window count,
/// on the gate whose entire value is that its findings mean something.
///
/// These tests hold the three claims that make the declaration safe rather than merely quiet:
/// it fires only for absent-on-the-counterpart keys, only on the declared side, and it cannot
/// excuse a whole event type going missing.
@Suite("declared appended probe keys (adr/0008 §5)")
struct NewFieldDeclarationTests {
    private static let declaredKeys = [
        "resizeMarginLeft", "resizeMarginTop", "resizeMarginRight", "resizeMarginBottom",
        "clientOffsetX", "clientOffsetY", "windowClientDeltaX", "windowClientDeltaY",
    ]

    // MARK: - A stream with MORE THAN ONE window order per type
    //
    // `CaptureFixture.baseline` carries a single `WindowCreate` and no `WindowUpdate` at all, so
    // against it "one finding per key" and "one finding per key PER MATCHED EVENT" are the same
    // number and the aggregation this whole mechanism exists for cannot be observed. (Round-1
    // review proved that: rewriting the aggregation as one append per hit left the suite 8/8 green
    // and the package 122/122 green.) These lines are local to this suite rather than added to the
    // shared fixture, because every other suite's expected counts are calibrated against that
    // seven-line capture.
    //
    // Three creates and two updates, deliberately MIXED on the client-rect validity bits: two
    // creates and one update carry CLIENT_AREA_OFFSET|WND_CLIENT_DELTA, the rest do not. That is
    // the corpus's own shape (creates carry both, most updates carry neither), and it pins the
    // property that matters here -- the exemption is about a key being ABSENT on the counterpart,
    // never about its value, so the rows whose bits are clear (appended as literal 0, exactly as
    // rail-probe writes them from a zero-initialised WINDOW_STATE_ORDER) are exempt on the same
    // footing as the rows carrying real values.
    private static let bothClientRectBits: UInt32 = 0x0000_C000

    /// One window-order line. `appended` is the difference between the frozen 2026-08-19 probe and
    /// the one built from this change: the newer one writes all eight keys on every window order.
    private static func windowOrder(
        _ ev: String, tMs: Int, id: Int, title: String, fieldFlags: UInt32, appended: Bool
    ) -> String {
        let head = """
            {"t_ms":\(tMs),"tid":"0x1f6be3540","ev":"\(ev)","windowId":\(id),\
            "fieldFlags":\(fieldFlags),"windowOffsetX":100,"windowOffsetY":120,\
            "windowWidth":800,"windowHeight":600,"numVisibilityRects":1,\
            "style":382664704,"styleEx":256,"show":5,"title":"\(title)"
            """
        guard appended else { return head + "}" }
        // Values are 0 exactly where the validity bit is clear -- rail-probe logs the struct
        // unconditionally and FreeRDP zero-initialises it per order, so "the bit is clear" and
        // "the key says 0" arrive together on the wire.
        let carries = fieldFlags & bothClientRectBits != 0
        let cx = carries ? 53 : 0, cy = carries ? 91 : 0
        let dx = carries ? 7 : 0, dy = carries ? -31 : 0
        return head + """
            ,"resizeMarginLeft":0,"resizeMarginTop":0,"resizeMarginRight":0,"resizeMarginBottom":0,\
            "clientOffsetX":\(cx),"clientOffsetY":\(cy),\
            "windowClientDeltaX":\(dx),"windowClientDeltaY":\(dy)}
            """
    }

    /// `appended: false` is the frozen baseline's shape; `true` is a re-record with this probe.
    /// The two differ in nothing else, so every finding a diff of them produces is the append.
    private static func multiWindowStream(appended: Bool, label: String) -> ReplayStream {
        let withBits: UInt32 = 13567 | bothClientRectBits
        let withoutBits: UInt32 = 13567
        let updateWithBits: UInt32 = 0x0100_0004 | bothClientRectBits
        let updateWithoutBits: UInt32 = 0x0100_0004
        let lines = [
            #"{"t_ms":0,"tid":"0x1f6be3540","ev":"PreConnect"}"#,
            #"{"t_ms":10,"tid":"0x1f6be3540","ev":"PostConnect"}"#,
            windowOrder("WindowCreate", tMs: 900, id: 65832, title: "Fixture Window A",
                        fieldFlags: withBits, appended: appended),
            windowOrder("WindowCreate", tMs: 910, id: 65900, title: "Fixture Window B",
                        fieldFlags: withBits, appended: appended),
            windowOrder("WindowCreate", tMs: 920, id: 66004, title: "Fixture Window C",
                        fieldFlags: withoutBits, appended: appended),
            windowOrder("WindowUpdate", tMs: 1200, id: 65832, title: "Fixture Window A",
                        fieldFlags: updateWithBits, appended: appended),
            windowOrder("WindowUpdate", tMs: 1210, id: 65900, title: "Fixture Window B",
                        fieldFlags: updateWithoutBits, appended: appended),
            #"{"t_ms":2000,"tid":"0x1f6be3540","ev":"PostDisconnect"}"#,
        ]
        return CaptureFixture.stream(lines, label: label)
    }

    @Test("the pre-seeded table declares all eight keys for both window-order event types")
    func preSeededCoversBothEventTypes() throws {
        for name in ["WindowCreate", "WindowUpdate"] {
            let declaration = try #require(KnownDifferenceTable.preSeeded.newFieldDeclaration(for: name))
            #expect(declaration.side == .candidate)
            #expect(declaration.fields.sorted() == Self.declaredKeys.sorted())
            // Both strings are rendered verbatim into `--legend` and into every report note, so an
            // empty one would ship an exemption an artifact reader cannot account for.
            #expect(!declaration.cause.isEmpty && !declaration.reference.isEmpty)
        }
        // No other event type is declared: the two window-order kinds share rail-probe's single
        // format string, and nothing else on the wire grew.
        #expect(KnownDifferenceTable.preSeeded.newFieldDeclarations.count == 2)
    }

    @Test("a probe upgrade reports one expected finding per key per event TYPE -- not one per matched event")
    func appendedKeysAreReportedOncePerKey() {
        // Five matched window orders (3 creates + 2 updates), 8 declared keys. The number this
        // pins is 8 + 8 = 16 -- one per key per event type. The failure it exists to catch is
        // 8x3 + 8x2 = 40, i.e. the false alarm proportional to the window count that the whole
        // NewFieldDeclaration mechanism was added to prevent. Against a one-create fixture the
        // two are indistinguishable, which is why this suite builds its own stream.
        let report = SemanticDiffer().diff(
            baseline: Self.multiWindowStream(appended: false, label: "frozen-baseline-probe"),
            candidate: Self.multiWindowStream(appended: true, label: "probe-grew-eight-keys")
        )
        #expect(report.differences.count == 16, "unexpected: \(report.differences)")
        for name in ["WindowCreate", "WindowUpdate"] {
            let forType = report.differences.filter { $0.eventName == name }
            #expect(forType.count == 8, "\(name): \(forType.count) findings, expected 8 -- \(forType)")
            #expect(Set(forType.compactMap(\.field)) == Set(Self.declaredKeys))
        }
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(report.differences.allSatisfy { $0.severity == .expected })
        // The matched-event tally is IN the finding rather than in its multiplicity, so an
        // artifact reader can still tell three grown creates from one. Pinned per type, because
        // getting these two numbers from the same counter is the other way to write the bug.
        #expect(report.differences.filter { $0.eventName == "WindowCreate" }
            .allSatisfy { $0.candidateValue == "present on 3 matched event(s)" })
        #expect(report.differences.filter { $0.eventName == "WindowUpdate" }
            .allSatisfy { $0.candidateValue == "present on 2 matched event(s)" })
        // Absent on the counterpart is the whole test; the VALUE is not. One create and one
        // update carry the client-rect bits clear and therefore append literal 0s, and those rows
        // are exempt on exactly the same footing -- otherwise the gate would fire on every window
        // the server did not send a client rectangle for.
        #expect(report.differences.allSatisfy { $0.baselineValue == "<absent>" })
        // Not a regression: the gate still passes on a pure probe upgrade.
        #expect(!report.hasRegressions)
    }

    @Test("the single-window case still reports one finding per key -- the aggregation has no lower edge")
    func appendedKeysOnASingleEventStillReportOnce() {
        var mutated = CaptureFixture.baseline
        for (index, key) in Self.declaredKeys.enumerated() {
            mutated = CaptureFixture.addingNumber(mutated, on: .windowCreate, key: key, value: index)
        }

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "probe-grew-eight-keys")
        )
        #expect(report.differences.count == 8, "unexpected: \(report.differences)")
        #expect(report.differences.allSatisfy { $0.diffClass == .knownLocalDifference })
        #expect(report.differences.allSatisfy { $0.severity == .expected })
        #expect(Set(report.differences.compactMap(\.field)) == Set(Self.declaredKeys))
        #expect(report.differences.allSatisfy { $0.candidateValue == "present on 1 matched event(s)" })
        #expect(!report.hasRegressions)
    }

    @Test("an UNdeclared appended key is still a regression -- the exemption is a list, not a rule about new keys")
    func undeclaredAppendedKeyStaysAFinding() throws {
        // `visibleOffsetX` is adr/0010 §1's field: real, decodable, and still emitted by no probe
        // build. It is deliberately absent from the declaration, so it must behave exactly as it
        // did before this feature existed (ChangedFieldTests pins the same case independently).
        let mutated = CaptureFixture.addingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "visibleOffsetX", value: 12
        )
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(mutated, label: "grew-undeclared-key")
        )
        let difference = try #require(report.differences.first)
        #expect(report.differences.count == 1)
        #expect(difference.diffClass == .fieldPresenceChanged)
        #expect(difference.severity == .regression)
    }

    @Test("a declared key on the WRONG side is compared normally -- the exemption is directional")
    func declaredKeyOnTheBaselineSideIsNotExempt() throws {
        // Baseline grew the key, candidate did not: that is not "the probe upgraded", it is the
        // recordings being the other way round from what the declaration states, and the gate must
        // say so rather than quietly excuse it.
        let mutated = CaptureFixture.addingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "clientOffsetX", value: 53
        )
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(mutated, label: "baseline-has-the-key"),
            candidate: CaptureFixture.baselineStream(label: "candidate-lacks-it")
        )
        let difference = try #require(report.differences.first)
        #expect(report.differences.count == 1)
        #expect(difference.diffClass == .fieldPresenceChanged)
        #expect(difference.severity == .regression)
    }

    @Test("once BOTH sides carry a declared key, its VALUE is compared normally")
    func valuesAreComparedOnceBothSidesCarryTheKey() throws {
        let withKey = CaptureFixture.addingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "clientOffsetX", value: 53
        )
        let withOtherValue = CaptureFixture.addingNumber(
            CaptureFixture.baseline, on: .windowCreate, key: "clientOffsetX", value: 106
        )
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(withKey, label: "1x"),
            candidate: CaptureFixture.stream(withOtherValue, label: "2x")
        )
        let difference = try #require(report.differences.first)
        #expect(report.differences.count == 1)
        #expect(difference.diffClass == .fieldValueChanged)
        #expect(difference.severity == .regression, "a client-rect value that moved between recordings is exactly what this gate is for")
        #expect(difference.baselineValue == "53" && difference.candidateValue == "106")
    }

    @Test("a declaration cannot excuse a whole event type going missing -- that is why it is not a KnownDifferenceEntry")
    func declarationDoesNotDisarmTheTypeCensus() throws {
        // WindowCreate is declared. Delete it from the baseline entirely: if declarations were
        // implemented as table entries, `explanation(for:presentOnlyOn: .candidate)` would match
        // and downgrade this to knownLocalDifference. It must stay a regression.
        var withoutCreate = CaptureFixture.baseline
        withoutCreate.remove(at: CaptureFixture.Line.windowCreate.rawValue)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(withoutCreate, label: "no-window-create"),
            candidate: CaptureFixture.baselineStream()
        )
        let typeFinding = try #require(report.differences.first { $0.eventName == "WindowCreate" })
        #expect(typeFinding.diffClass == .eventTypeOnlyOnOneSide)
        #expect(typeFinding.severity == .regression)
        #expect(KnownDifferenceTable.preSeeded.explanation(for: "WindowCreate", presentOnlyOn: .candidate) == nil)
    }

    @Test("the artifact's own notes say which keys are declared, so a reader need not open the source")
    func theNotesRecordTheDeclarations() throws {
        let report = SemanticDiffer().diff(
            baseline: Self.multiWindowStream(appended: false, label: "frozen-baseline-probe"),
            candidate: Self.multiWindowStream(appended: true, label: "probe-grew-eight-keys")
        )
        let note = try #require(report.notes.first { $0.hasPrefix("appended-probe-key declarations") })
        for name in ["WindowCreate", "WindowUpdate"] { #expect(note.contains(name)) }
        for key in Self.declaredKeys { #expect(note.contains(key), "note omits \(key)") }
        #expect(note.contains("8 key(s) expected on the candidate side"))
        // A table with no declarations must not print the note at all: an artifact that lists
        // exemptions it does not have is as misleading as one that hides the ones it does.
        let bare = SemanticDiffer(
            options: DifferOptions(knownDifferenceTable: KnownDifferenceTable(entries: []))
        ).diff(
            baseline: Self.multiWindowStream(appended: false, label: "frozen-baseline-probe"),
            candidate: Self.multiWindowStream(appended: true, label: "probe-grew-eight-keys")
        )
        #expect(!bare.notes.contains { $0.hasPrefix("appended-probe-key declarations") })
    }

    @Test("an explicitly empty table declares nothing -- exemptions are never handed out by default")
    func emptyTableDeclaresNothing() {
        let empty = KnownDifferenceTable(entries: [])
        #expect(empty.newFieldDeclarations.isEmpty)
        #expect(empty.newFieldDeclaration(for: "WindowCreate") == nil)
    }

    @Test("merging keeps the left side's declarations -- a --known-difference-table override cannot drop them")
    func mergingPreservesDeclarations() throws {
        let override = KnownDifferenceTable(entries: [
            KnownDifferenceEntry(
                eventName: "SomeOtherEvent", expectedSide: .candidate,
                cause: "fixture", reference: "fixture"
            )
        ])
        let merged = KnownDifferenceTable.preSeeded.merging(override)
        #expect(merged.newFieldDeclaration(for: "WindowCreate") != nil)
        #expect(merged.entries["SomeOtherEvent"] != nil)
    }
}
