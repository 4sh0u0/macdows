import Foundation

/// Tuning for one diff run.
public struct DifferOptions: Sendable, Equatable {
    public var fieldPolicy: FieldPolicy
    public var knownDifferenceTable: KnownDifferenceTable

    /// Replace session-scoped handle values with per-side first-appearance ordinals before
    /// comparing (`windowId: 65832` → `window#0`). On by default; without it, *no* pair of
    /// separately recorded captures can ever match, because a re-record gets fresh HWNDs
    /// and surface ids for the same user actions. Turn off with `--no-canonical-ids` when
    /// diffing two captures from the same session, where the raw ids are meaningful.
    public var canonicalizeIdentifiers: Bool

    /// How far a matched event may move **across producer lanes**, measured in positions
    /// among *matched* events, not in raw line numbers.
    ///
    /// Rationale, measured rather than assumed. Every one of the six frozen phase05
    /// captures has **three** concurrent producer threads, not two, and the lane an event
    /// came off is fully determined by its `ev` name (see ``EventLane``):
    ///
    /// | lane | tids per capture | `ev` names |
    /// |---|---|---|
    /// | `main` (RAIL) | 1 | `PreConnect`, `PostConnect`, `WindowCreate`, `WindowUpdate`, `WindowIcon`, `MonitoredDesktop`, `NotifyIcon*`, `SecondExec*`, `DurationElapsed`, … |
    /// | `gfx` (RDPGFX DVC) | 1 | `Gfx*` |
    /// | `server` (RAIL-server callbacks) | 1 | `Server*` |
    /// | `ambiguous` | 2 | `ChannelConnected`, `ChannelDisconnected` — the only two names observed on more than one thread |
    ///
    /// Interleaving *between* those three lanes near a given instant is genuine run-to-run
    /// noise, which is what this window absorbs. Order *within* one lane is a single
    /// thread's own callback order and is therefore causal — it gets
    /// ``laneOrderTolerance`` (default `0`) instead. An earlier revision of this comment
    /// derived the default from a two-lane model and applied it globally; round-1 review
    /// showed that let a same-thread causal inversion (`WindowIcon` and `MonitoredDesktop`
    /// hoisted above the `WindowCreate` they reference, all on the main lane) pass clean.
    ///
    /// `0` demands exact order everywhere and is the right setting for a same-session
    /// self-diff.
    ///
    /// Rank-based rather than index-based on purpose: when a single event moves a long way,
    /// everything it passed shifts by one position, and comparing ranks lets *this*
    /// tolerance absorb the bystanders' 1-position shift so the move reads as one finding
    /// about the event that moved.
    ///
    /// That property is a consequence of the tolerance being ≥ 1, **not** of rank comparison
    /// itself, and it therefore does **not** hold within a lane at the default
    /// ``laneOrderTolerance`` of `0`, where every bystander fires too: one adjacent same-lane
    /// swap → 2 findings, one 2-position same-lane move → 3. That is the deliberate price of
    /// catching causal inversions; an operator reading N same-lane order findings should
    /// look for one move, not N.
    public var orderTolerance: Int

    /// How far a matched event may move *within its own producer lane*. Default `0`: a
    /// lane is one thread, and one thread's event order is causal, so any movement inside
    /// it is a real difference rather than interleaving noise.
    ///
    /// Raise it only if a real re-record shows within-lane jitter that is genuinely not
    /// meaningful — and record that in the drill, because it is the setting that decides
    /// whether "the server did B before A this time" is a finding.
    ///
    /// Events whose lane is ``EventLane/ambiguous`` (observed on more than one thread) and
    /// events MacdowsCore does not model (unknown thread) are exempt from the within-lane
    /// check and are governed by ``orderTolerance`` alone.
    public var laneOrderTolerance: Int

    /// Output-only cap on a rendered value's length.
    public var maxValueLength: Int

    public init(
        fieldPolicy: FieldPolicy = .default,
        knownDifferenceTable: KnownDifferenceTable = .preSeeded,
        canonicalizeIdentifiers: Bool = true,
        orderTolerance: Int = 2,
        laneOrderTolerance: Int = 0,
        maxValueLength: Int = 120
    ) {
        self.fieldPolicy = fieldPolicy
        self.knownDifferenceTable = knownDifferenceTable
        self.canonicalizeIdentifiers = canonicalizeIdentifiers
        self.orderTolerance = orderTolerance
        self.laneOrderTolerance = laneOrderTolerance
        self.maxValueLength = maxValueLength
    }
}

/// Which producer thread an event came off, derived from its `ev` name.
///
/// Derived from the name rather than from `tid` because `tid` is a raw `pthread_self()`
/// address that a re-record never reproduces (``FieldPolicy/defaultIgnoredFields``). The
/// derivation is *verified* against the frozen baseline, not assumed: in all six phase05
/// captures each of `main`/`gfx`/`server` maps to exactly one tid, the three tids are
/// distinct, and `ChannelConnected`/`ChannelDisconnected` are the only names ever seen on
/// more than one. `LaneOrderTests` re-checks that against the real captures.
///
/// Rot resistance comes from ``mainLaneEventNames`` being an allow-list, **not** from that
/// census: the frozen captures cannot contain an event a future probe adds (U7 freezes
/// them), so a census over them could never fail for that reason. An earlier revision
/// claimed otherwise. What actually holds the line is that an unlisted, non-`Gfx*`,
/// non-`Server*` name resolves to ``ambiguous`` and is exempt from the within-lane check
/// until someone measures its thread — pinned by `LaneAllowListTests`.
public enum EventLane: String, Sendable, Equatable, CaseIterable {
    case main
    case gfx
    case server
    /// Observed on more than one thread, or from an event MacdowsCore does not model (whose
    /// thread we therefore cannot claim to know). Exempt from the within-lane order check.
    case ambiguous

    /// The two names verified to appear on more than one thread in every frozen capture.
    public static let ambiguousEventNames: Set<String> = ["ChannelConnected", "ChannelDisconnected"]

    /// `ev` names measured on the main RAIL thread in the frozen captures.
    ///
    /// An explicit allow-list, not a fall-through, and that is the point. `Gfx*`/`Server*`
    /// are *structural* claims — every such event comes off the RDPGFX DVC callback set or
    /// the RAIL-server callback set respectively — but "everything else is the main thread"
    /// is not a claim, it is an assumption, and round-2 review named it: a probe build that
    /// adds a modelled `ev` name would have been silently given lane tolerance 0 on a thread
    /// nobody measured, which is exactly the manufactured-finding hazard ``ambiguous`` exists
    /// to prevent. Anything not listed here and not `Gfx*`/`Server*` is ``ambiguous`` until
    /// someone measures it and adds it in a reviewed edit.
    ///
    /// `LaneAllowListTests` pins both directions: every name here must be one MacdowsCore
    /// actually models (no typos, no dead entries), and every main-lane name observed in the
    /// six frozen captures must be here (no measured traffic silently demoted to ambiguous).
    /// Today this is *exactly* the set measured in the six captures — nothing inferred.
    /// `WindowDelete`, `NonMonitoredDesktop`, `ConnectFailed` and friends are modelled by
    /// MacdowsCore and are almost certainly main-lane, but they occur zero times in the
    /// frozen data, so they are deliberately absent: `ambiguous` costs a little coverage,
    /// an unmeasured lane assignment costs correctness.
    public static let mainLaneEventNames: Set<String> = [
        "ClientRailServerStartCmd",
        "ConnectSucceeded",
        "DurationElapsed",
        "MonitoredDesktop",
        "NotifyIconCreate",
        "NotifyIconDelete",
        "NotifyIconUpdate",
        "PostConnect",
        "PostDisconnect",
        "PostFinalDisconnect",
        "PreConnect",
        "SecondExecBegin",
        "SecondExecEnd",
        "WindowCachedIcon",
        "WindowCreate",
        "WindowIcon",
        "WindowUpdate",
    ]

    /// - Parameter isModelled: `false` for `RailEventKind.unknown`. A name this package has
    ///   never seen gets ``ambiguous``: guessing a lane for an unknown event would
    ///   manufacture within-lane findings out of an assumption.
    public static func lane(forEventName name: String, isModelled: Bool = true) -> EventLane {
        guard isModelled, !ambiguousEventNames.contains(name) else { return .ambiguous }
        if name.hasPrefix("Gfx") { return .gfx }
        if name.hasPrefix("Server") { return .server }
        // No `return .main` fall-through — see `mainLaneEventNames`.
        return mainLaneEventNames.contains(name) ? .main : .ambiguous
    }
}

/// Compares two `rail-probe` JSONL captures for *semantic* difference: what the server
/// did, ignoring when it did it, which thread carried it, and which kernel handles the
/// session happened to allocate.
///
/// Algorithm, in order:
///
/// 1. **Parse failures** on either side become ``DiffClass/unparsableLine`` findings.
/// 2. **Identifier canonicalization** (optional, default on) rewrites handle-valued fields
///    to per-side, per-namespace, first-appearance ordinals.
/// 3. **Type census.** An `ev` name present on exactly one side is a whole-type finding:
///    ``DiffClass/knownLocalDifference`` when the ``KnownDifferenceTable`` claims it
///    on that side — as an appearance *or* as the superseded half of a substitution, see
///    ``KnownDifferenceTable/resolution(for:presentOnlyOn:baselineOnlyNames:candidateOnlyNames:)``
///    — otherwise ``DiffClass/eventTypeOnlyOnOneSide``. Its individual occurrences are then
///    *excluded* from step 4 — they have no counterpart by construction, and re-reporting
///    each of them would bury the one finding that matters under a hundred that do not.
///    **Exception: a substitution pair has a counterpart** — see step 4b.
/// 4. **Matching**, for names both sides have: bucket by `ev` name, sub-bucket by identity
///    tuple (the canonicalized identifier fields), then pair positionally inside each
///    sub-bucket. Leftovers are ``DiffClass/eventCountChanged``. This is what tolerates
///    cross-type reordering exactly, rather than approximately.
/// 5. **Field comparison** per matched pair, over the union of both sides' keys minus the
///    ignored set.
/// 4b. **Substituted classes.** When an entry's `supersedes` fires, excusing the whole-type
///    *presence* difference must not excuse what is inside it. The two one-sided occurrence
///    sets are matched by identity tuple and field-compared exactly like a same-name pair,
///    minus the entry's declared `newFields` (which are counted and reported once). Counts
///    must correspond and unmatched identities are ``DiffClass/eventCountChanged``
///    regressions. Round-2 review showed why: without this, `supersedes` firing took the
///    whole RDPGFX surface-mapping class out of the gate, and every surface in the six
///    captures remapped at 1×1 still came out `PASS, exit 0`.
/// 6. **Order check** over matched pairs: within the event's own producer lane against
///    ``DifferOptions/laneOrderTolerance`` (default `0`, because a lane is one thread and
///    one thread's order is causal), and across lanes against
///    ``DifferOptions/orderTolerance``. At most one finding per pair, the within-lane one
///    preferred because it is the more specific statement.
///
/// ## Known limitations
///
/// **Ordinal-shift cascade (W2 batch 2).** Canonical ordinals are assigned in
/// first-appearance order, so an event that changes *which* handle appears first shifts
/// every later ordinal in that namespace. Measured on a real capture: **one** extra
/// `WindowCreate` prepended to `s3-multiapp.jsonl` (145 lines) yields **98
/// `eventCountChanged` findings on its own**, and roughly 190 findings in total. Only the
/// 98 is construction-independent — it falls straight out of the ordinal shift and is
/// pinned by `CascadeBlastRadiusTests`; the `fieldValueChanged` and `eventOrderChanged`
/// counts depend on the payload of the injected window (round-1 measured 180 total, round 2
/// 193–196 with the lane rule, from two differently-shaped injected lines), so no exact
/// total is quoted here. The propagation is what matters: the `window` namespace shift
/// reaches every identity bucket that references a window, which is most of the stream. A
/// live re-record that opens one transient window the baseline did not (a splash screen, a
/// tooltip, a tray flyout) lands here.
///
/// The tool fails *loudly*, never silently, so the verdict is not misleading — but a
/// three-figure report for one extra window is exactly the false-alarm shape
/// ``KnownDifferenceTable``'s own doc warns trains an operator to ignore the gate. First-line
/// remedy for the operator: read the report's **cascade note** and the *first*
/// `eventCountChanged`, and check whether the candidate simply has an extra window early in
/// the stream. ``DifferOptions/canonicalizeIdentifiers`` = false is the documented escape
/// hatch but is the wrong tool here — it makes every handle differ. The real fix is
/// payload-anchored identity (title-keyed where a title is present), deferred to W2 batch 2.
///
/// **Residual silent reorder class.** With ``DifferOptions/laneOrderTolerance`` at its
/// default `0`, within-lane causal inversions are caught. What remains tolerated is
/// reordering *between* lanes within ``DifferOptions/orderTolerance`` positions — e.g. a
/// `Gfx*` surface map sliding two positions past a `WindowUpdate`, or a `Server*` callback
/// past a `MonitoredDesktop`. `WindowModel` treats most such pairs as independent, so
/// phase 2 would not object either.
///
/// **Compensating control, and its off switch.** The lifecycle-breaking subset of any
/// reorder — an update/icon/delete for a window that does not exist yet — is caught not
/// here but by **phase 2** of `Scripts/upgrade-gate.sh`: `Scripts/replay.sh` runs
/// `ReplayTests.zeroAnomalies`, which asserts `WindowModel` reports no `Anomaly` over the
/// *candidate* directory. Verified in round-1 review: injecting a `WindowUpdate` for an
/// unknown window makes phase 2 fail and the gate exit 1. That control is **removed by
/// `--skip-replay`**, which is therefore not a mere speed-up — running phase 3 alone gives
/// up the differ's backstop for cross-lane reordering.
public struct SemanticDiffer: Sendable {
    public var options: DifferOptions

    public init(options: DifferOptions = DifferOptions()) {
        self.options = options
    }

    public func diff(baseline: ReplayStream, candidate: ReplayStream) -> DiffReport {
        var differences: [Difference] = []
        var notes: [String] = []

        // 1. Parse failures.
        for failure in baseline.parseFailures {
            differences.append(
                Difference(
                    diffClass: .unparsableLine,
                    baselineLine: failure.lineNumber,
                    detail: "baseline: \(failure.reason)"
                )
            )
        }
        for failure in candidate.parseFailures {
            differences.append(
                Difference(
                    diffClass: .unparsableLine,
                    candidateLine: failure.lineNumber,
                    detail: "candidate: \(failure.reason)"
                )
            )
        }

        // 2. Identifier canonicalization.
        let baselineRecords = canonicalized(baseline.records)
        let candidateRecords = canonicalized(candidate.records)

        // 3. Type census.
        let baselineByName = bucketByEventName(baselineRecords)
        let candidateByName = bucketByEventName(candidateRecords)
        let baselineNames = Set(baselineByName.keys)
        let candidateNames = Set(candidateByName.keys)

        // Both one-sided sets are computed before either is classified: the substitution
        // rule needs to see the *other* side's census to decide whether a disappearance has
        // a replacement standing right next to it.
        let baselineOnlyNames = baselineNames.subtracting(candidateNames)
        let candidateOnlyNames = candidateNames.subtracting(baselineNames)

        // Substitution pairs discovered while classifying: (superseded name, superseding
        // name, entry). Step 4b compares their occurrences against each other.
        var substitutions: [(superseded: String, superseding: String, entry: KnownDifferenceEntry)] = []

        for name in baselineOnlyNames.sorted() {
            let (difference, resolution) = wholeTypeDifference(
                eventName: name,
                side: .baseline,
                count: baselineByName[name]?.count ?? 0,
                firstLine: baselineByName[name]?.first?.lineNumber,
                baselineOnlyNames: baselineOnlyNames,
                candidateOnlyNames: candidateOnlyNames
            )
            differences.append(difference)
            if let resolution, resolution.role == .superseded, resolution.entry.expectedSide == .candidate {
                substitutions.append((superseded: name, superseding: resolution.entry.eventName, entry: resolution.entry))
            }
        }
        for name in candidateOnlyNames.sorted() {
            let (difference, resolution) = wholeTypeDifference(
                eventName: name,
                side: .candidate,
                count: candidateByName[name]?.count ?? 0,
                firstLine: candidateByName[name]?.first?.lineNumber,
                baselineOnlyNames: baselineOnlyNames,
                candidateOnlyNames: candidateOnlyNames
            )
            differences.append(difference)
            if let resolution, resolution.role == .superseded, resolution.entry.expectedSide == .baseline {
                substitutions.append((superseded: name, superseding: resolution.entry.eventName, entry: resolution.entry))
            }
        }

        // 4 + 5. Matching and field comparison, for names both sides have.
        var matchedPairs: [(baseline: ReplayRecord, candidate: ReplayRecord)] = []
        for name in baselineNames.intersection(candidateNames).sorted() {
            let (pairs, countFindings) = match(
                eventName: name,
                baseline: baselineByName[name] ?? [],
                candidate: candidateByName[name] ?? []
            )
            matchedPairs.append(contentsOf: pairs)
            differences.append(contentsOf: countFindings)
            for pair in pairs {
                let outcome = compareFields(eventName: name, pair: pair)
                differences.append(contentsOf: outcome.findings)
            }
        }

        // 4b. Substituted classes. Excusing the whole-type *presence* difference must not
        // excuse everything inside it: the two one-sided occurrence sets are matched by
        // identity tuple and field-compared exactly like a same-name pair, minus the
        // entry's declared `newFields`. Without this, `supersedes` firing would take the
        // entire class out of the gate — round-2 review turned every surface in the six
        // captures into a 1x1 mapping and still got `PASS, exit 0`.
        for substitution in substitutions.sorted(by: { $0.superseded < $1.superseded }) {
            // Resolve each name against the side it is actually on, indexed by side rather
            // than by "old"/"new". An earlier revision computed an `oldSide`/`newSide` pair
            // and transposed the two names in the `expectedSide == .baseline` arm: both
            // lookups then missed, `match` got two empty arrays, and the entire step
            // silently did nothing for every mirrored entry — restoring round-2's
            // false-green while the artifact claimed the occurrences had been compared
            // (round-3 finding N-8). Naming the bindings after sides makes the invariant
            // checkable by eye: the entry's own (superseding) type lives on
            // `entry.expectedSide`, and the type it supersedes lives on the other side.
            let supersedingSide = substitution.entry.expectedSide
            let baselineHalf = supersedingSide == .baseline
                ? baselineByName[substitution.superseding]
                : baselineByName[substitution.superseded]
            let candidateHalf = supersedingSide == .baseline
                ? candidateByName[substitution.superseded]
                : candidateByName[substitution.superseding]
            // Label reads baseline→candidate, whichever variant is on which side.
            let label = supersedingSide == .baseline
                ? "\(substitution.superseding)→\(substitution.superseded)"
                : "\(substitution.superseded)→\(substitution.superseding)"
            let (pairs, countFindings) = match(
                eventName: label,
                baseline: baselineHalf ?? [],
                candidate: candidateHalf ?? []
            )
            matchedPairs.append(contentsOf: pairs)
            differences.append(contentsOf: countFindings)

            var newFieldHits: [String: Int] = [:]
            for pair in pairs {
                let outcome = compareFields(
                    eventName: label,
                    pair: pair,
                    expectedNewFields: Set(substitution.entry.newFields),
                    // The declared new fields belong to the superseding variant, so they are
                    // exempt only on the side that variant is on.
                    newFieldSide: supersedingSide
                )
                differences.append(contentsOf: outcome.findings)
                for (field, count) in outcome.expectedNewFieldHits {
                    newFieldHits[field, default: 0] += count
                }
            }
            // One record per declared new field, not one per event: the artifact should say
            // "target* arrived on 19 matched events", not say it 19 times.
            for field in substitution.entry.newFields.sorted() {
                guard let hits = newFieldHits[field], hits > 0 else { continue }
                let present = "present on \(hits) matched event(s)"
                differences.append(
                    Difference(
                        diffClass: .knownLocalDifference,
                        eventName: label,
                        field: field,
                        baselineValue: supersedingSide == .baseline ? present : "<absent>",
                        candidateValue: supersedingSide == .baseline ? "<absent>" : present,
                        detail: "declared new field of the \(substitution.entry.eventName) variant — exempt from"
                            + " field comparison because its presence IS the variant; every other field of these"
                            + " \(pairs.count) matched event(s) was compared normally"
                    )
                )
            }
        }

        // 6. Order.
        differences.append(contentsOf: orderFindings(for: matchedPairs))

        // Notes.
        if options.canonicalizeIdentifiers {
            let namespaces = Set(options.fieldPolicy.identifierNamespaces.values).sorted()
            notes.append(
                "identifier canonicalization ON for namespaces [\(namespaces.joined(separator: ", "))]"
                    + " — handle values are compared as per-side first-appearance ordinals"
            )
        } else {
            notes.append("identifier canonicalization OFF — raw handle values are compared literally")
        }
        notes.append(
            "ignored fields: [\(options.fieldPolicy.ignoredFields.sorted().joined(separator: ", "))];"
                + " order tolerance: \(options.orderTolerance) matched position(s) across lanes,"
                + " \(options.laneOrderTolerance) within a lane"
        )
        // The active known-difference table goes into the artifact for the same reason the
        // ignored-field set does: it is the other way to make the gate pass, and a drill run
        // with a one-off --known-difference-table that happens not to fire must not produce an
        // artifact indistinguishable from a run with the built-in table.
        let activeEntries = options.knownDifferenceTable.entries.values.sorted { $0.eventName < $1.eventName }
        if activeEntries.isEmpty {
            notes.append("known-difference table: empty — no event type can be excused")
        } else {
            notes.append(
                "known-difference table (\(activeEntries.count) entr\(activeEntries.count == 1 ? "y" : "ies")): "
                    + activeEntries.map { entry in
                        let supersedes = entry.supersedes.map { ", supersedes \($0)" } ?? ""
                        return "\(entry.eventName) expected on \(entry.expectedSide.rawValue)\(supersedes)"
                    }.joined(separator: "; ")
            )
        }
        let unmodelled = baseline.unmodelledEventNames.union(candidate.unmodelledEventNames)
        if !unmodelled.isEmpty {
            notes.append(
                "event names MacdowsCore does not model yet (compared structurally, not a difference): "
                    + unmodelled.sorted().joined(separator: ", ")
            )
        }
        notes.append(contentsOf: cascadeNotes(baseline: baseline.records, candidate: candidate.records))

        return DiffReport(
            baselineLabel: baseline.label,
            candidateLabel: candidate.label,
            baselineEventCount: baseline.records.count,
            candidateEventCount: candidate.records.count,
            differences: differences,
            notes: notes
        )
    }

    // MARK: - Step 2

    private func canonicalized(_ records: [ReplayRecord]) -> [ReplayRecord] {
        guard options.canonicalizeIdentifiers else { return records }
        let identifierFields = options.fieldPolicy.sortedIdentifierFieldNames
        var nextOrdinal: [String: Int] = [:]
        var tokens: [String: [String: String]] = [:]

        return records.map { record in
            var fields = record.fields
            for fieldName in identifierFields {
                guard let raw = fields[fieldName]?.integerCanonicalForm,
                      let namespace = options.fieldPolicy.namespace(of: fieldName)
                else { continue }
                // 0 is RAIL's/RDPGFX's null handle ("no owner", "no active window"). It
                // must stay a distinguishable constant rather than becoming ordinal #0,
                // or "this window gained an owner" would read as "the ordinals shifted".
                if raw == "0" {
                    fields[fieldName] = .string("\(namespace)#none")
                    continue
                }
                if let existing = tokens[namespace]?[raw] {
                    fields[fieldName] = .string(existing)
                    continue
                }
                let ordinal = nextOrdinal[namespace, default: 0]
                nextOrdinal[namespace] = ordinal + 1
                let token = "\(namespace)#\(ordinal)"
                tokens[namespace, default: [:]][raw] = token
                fields[fieldName] = .string(token)
            }
            return ReplayRecord(
                lineNumber: record.lineNumber,
                eventName: record.eventName,
                fields: fields,
                isModelled: record.isModelled
            )
        }
    }

    // MARK: - Step 3

    private func bucketByEventName(_ records: [ReplayRecord]) -> [String: [ReplayRecord]] {
        var buckets: [String: [ReplayRecord]] = [:]
        for record in records {
            buckets[record.eventName, default: []].append(record)
        }
        return buckets
    }

    private func wholeTypeDifference(
        eventName: String,
        side: DiffSide,
        count: Int,
        firstLine: Int?,
        baselineOnlyNames: Set<String>,
        candidateOnlyNames: Set<String>
    ) -> (difference: Difference, resolution: (entry: KnownDifferenceEntry, role: SupersessionRole)?) {
        let onBaseline = side == .baseline
        let baselineValue = onBaseline ? "\(count) occurrence(s)" : "absent"
        let candidateValue = onBaseline ? "absent" : "\(count) occurrence(s)"
        let resolution = options.knownDifferenceTable.resolution(
            for: eventName,
            presentOnlyOn: side,
            baselineOnlyNames: baselineOnlyNames,
            candidateOnlyNames: candidateOnlyNames
        )
        guard let resolution else {
            return (
                Difference(
                    diffClass: .eventTypeOnlyOnOneSide,
                    eventName: eventName,
                    baselineValue: baselineValue,
                    candidateValue: candidateValue,
                    baselineLine: onBaseline ? firstLine : nil,
                    candidateLine: onBaseline ? nil : firstLine,
                    detail: "no known-difference table entry claims this event type on the \(side.rawValue) side"
                ),
                nil
            )
        }
        let lead: String
        switch resolution.role {
        case .appeared:
            // The clause "…ARE compared against these one-by-one" is a claim about work the
            // differ did. It may only be printed when step 4b will actually run, which needs
            // the partner to be one-sided on the OPPOSITE side. An earlier revision printed
            // it whenever `supersedes` was merely *set*, so a pure addition (partner present
            // on both sides) produced an artifact asserting a comparison that never happened
            // — round-3 finding N-9. Same information, opposite polarity: say plainly when
            // nothing was compared.
            if let partner = resolution.entry.supersedes {
                let partnerOnOppositeSide = side == .candidate
                    ? baselineOnlyNames.contains(partner)
                    : candidateOnlyNames.contains(partner)
                let partnerOnThisSide = (side == .baseline ? baselineOnlyNames : candidateOnlyNames).contains(partner)
                if partnerOnOppositeSide {
                    lead = "known local difference (paired with \(partner), whose occurrences ARE compared against"
                        + " these one-by-one — only the presence of the type itself is excused):"
                } else {
                    let why = partnerOnThisSide
                        ? "\(partner) is one-sided on the SAME side, so nothing was superseded"
                        : "\(partner) is not one-sided here (present on both sides, or on neither)"
                    lead = "known local difference. NOT field-compared: \(why), so there is no counterpart set to"
                        + " pair these \(count) occurrence(s) against. Their presence is excused; their payload and"
                        + " identity were NOT examined:"
                }
            } else {
                lead = "known local difference (pure addition, no paired type — these \(count) occurrence(s) have no"
                    + " counterpart to compare against and their payload was NOT examined):"
            }
        case .superseded:
            // Always paired by construction: `resolution` only returns `.superseded` when the
            // superseding type is one-sided on its expected side, which is exactly step 4b's
            // firing condition, so this clause cannot outrun the work.
            // Name the counterpart and where it is, so the reader can check the claim from
            // the same report instead of taking the classifier's word for it.
            lead = """
                known local difference: paired with \(resolution.entry.eventName), which appears only on the \
                \(resolution.entry.expectedSide.rawValue) side of this same comparison; these occurrences ARE \
                matched against it and field-compared —
                """
        }
        return (
            Difference(
                diffClass: .knownLocalDifference,
                eventName: eventName,
                baselineValue: baselineValue,
                candidateValue: candidateValue,
                baselineLine: onBaseline ? firstLine : nil,
                candidateLine: onBaseline ? nil : firstLine,
                detail: "\(lead) \(resolution.entry.cause)\nreference: \(resolution.entry.reference)"
            ),
            resolution
        )
    }

    /// Report notes warning that an identifier-ordinal cascade is in play.
    ///
    /// Not a ``DiffClass``: the cascade is not itself a difference, it is the *explanation*
    /// for a possibly enormous pile of them (see this type's "known limitations"). Putting
    /// it in the artifact as a note gives the operator the first-line remedy at the point of
    /// reading, which is the whole reason a three-figure report is dangerous — nobody reads
    /// finding 137 to work out that finding 1 caused it.
    private func cascadeNotes(baseline: [ReplayRecord], candidate: [ReplayRecord]) -> [String] {
        guard options.canonicalizeIdentifiers else { return [] }
        let baselineCounts = distinctHandleCounts(baseline)
        let candidateCounts = distinctHandleCounts(candidate)
        var notes: [String] = []
        for namespace in Set(baselineCounts.keys).union(candidateCounts.keys).sorted() {
            let before = baselineCounts[namespace] ?? 0
            let after = candidateCounts[namespace] ?? 0
            guard before != after else { continue }
            notes.append(
                "CASCADE RISK: the candidate has \(after) distinct `\(namespace)` handle(s) against the "
                    + "baseline's \(before). Ordinals are assigned in first-appearance order, so an extra or "
                    + "missing handle EARLY in the stream shifts every later `\(namespace)` ordinal and can turn "
                    + "one real difference into hundreds (measured: one extra WindowCreate at the head of a "
                    + "145-line capture → 98 eventCountChanged findings alone, ~190 in total). Read the FIRST "
                    + "eventCountChanged below and check "
                    + "whether the candidate simply opened one extra transient window; if so, the rest of this "
                    + "report is one finding wearing a costume. --no-canonical-ids is NOT the remedy (it makes "
                    + "every handle differ); payload-anchored identity is W2 batch 2."
            )
        }
        return notes
    }

    private func distinctHandleCounts(_ records: [ReplayRecord]) -> [String: Int] {
        var seen: [String: Set<String>] = [:]
        for record in records {
            for fieldName in options.fieldPolicy.sortedIdentifierFieldNames {
                guard let raw = record.fields[fieldName]?.integerCanonicalForm,
                      raw != "0",
                      let namespace = options.fieldPolicy.namespace(of: fieldName)
                else { continue }
                seen[namespace, default: []].insert(raw)
            }
        }
        return seen.mapValues(\.count)
    }

    // MARK: - Step 4

    /// The canonicalized identifier tuple that decides which occurrences of one event name
    /// are candidates for each other. Rendered as sorted `name=value` pairs so it is
    /// deterministic and printable.
    private func identityTuple(_ record: ReplayRecord) -> String {
        let parts = options.fieldPolicy.sortedIdentifierFieldNames.compactMap { name -> String? in
            guard let value = record.fields[name] else { return nil }
            return "\(name)=\(value.displayString)"
        }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    private func match(
        eventName: String,
        baseline: [ReplayRecord],
        candidate: [ReplayRecord]
    ) -> (pairs: [(baseline: ReplayRecord, candidate: ReplayRecord)], countFindings: [Difference]) {
        var baselineGroups: [String: [ReplayRecord]] = [:]
        var candidateGroups: [String: [ReplayRecord]] = [:]
        for record in baseline {
            baselineGroups[identityTuple(record), default: []].append(record)
        }
        for record in candidate {
            candidateGroups[identityTuple(record), default: []].append(record)
        }

        var pairs: [(baseline: ReplayRecord, candidate: ReplayRecord)] = []
        var findings: [Difference] = []
        // Sorted rather than first-appearance order: the output must not depend on
        // Dictionary iteration order.
        for key in Set(baselineGroups.keys).union(candidateGroups.keys).sorted() {
            let lhs = baselineGroups[key] ?? []
            let rhs = candidateGroups[key] ?? []
            let paired = min(lhs.count, rhs.count)
            for index in 0..<paired {
                pairs.append((baseline: lhs[index], candidate: rhs[index]))
            }
            guard lhs.count != rhs.count else { continue }
            findings.append(
                Difference(
                    diffClass: .eventCountChanged,
                    eventName: eventName,
                    baselineValue: "\(lhs.count) occurrence(s)",
                    candidateValue: "\(rhs.count) occurrence(s)",
                    baselineLine: lhs.count > paired ? lhs[paired].lineNumber : lhs.first?.lineNumber,
                    candidateLine: rhs.count > paired ? rhs[paired].lineNumber : rhs.first?.lineNumber,
                    detail: "identity \(key)"
                )
            )
        }
        return (pairs, findings)
    }

    // MARK: - Step 5

    /// What one matched pair's field comparison produced.
    struct FieldComparison {
        var findings: [Difference] = []
        /// Declared `newFields` that were absent on the counterpart side and present on the
        /// variant's own side — exempted from comparison, counted here so the caller can
        /// record them once for the whole class instead of once per event.
        var expectedNewFieldHits: [String: Int] = [:]
    }

    /// - Parameters:
    ///   - expectedNewFields: keys the arriving variant structurally carries and its
    ///     counterpart cannot. Exempt **only** in the one direction that matches the
    ///     variant; a declared new field showing up on the wrong side is a real finding.
    ///   - newFieldSide: the side the arriving variant is on.
    private func compareFields(
        eventName: String,
        pair: (baseline: ReplayRecord, candidate: ReplayRecord),
        expectedNewFields: Set<String> = [],
        newFieldSide: DiffSide = .candidate
    ) -> FieldComparison {
        var result = FieldComparison()
        let keys = Set(pair.baseline.fields.keys)
            .union(pair.candidate.fields.keys)
            .subtracting(options.fieldPolicy.ignoredFields)
            .sorted()
        for key in keys {
            let lhs = pair.baseline.fields[key]
            let rhs = pair.candidate.fields[key]
            if lhs == rhs { continue }
            if expectedNewFields.contains(key) {
                let absentOnCounterpart = newFieldSide == .candidate ? (lhs == nil && rhs != nil) : (rhs == nil && lhs != nil)
                if absentOnCounterpart {
                    result.expectedNewFieldHits[key, default: 0] += 1
                    continue
                }
                // Present on both sides with different values, or present only on the
                // counterpart: neither is "the variant carries a field the other cannot",
                // so it falls through to normal comparison.
            }
            let klass: DiffClass = (lhs == nil || rhs == nil) ? .fieldPresenceChanged : .fieldValueChanged
            result.findings.append(
                Difference(
                    diffClass: klass,
                    eventName: eventName,
                    field: key,
                    baselineValue: options.fieldPolicy.render(lhs, field: key, maxLength: options.maxValueLength),
                    candidateValue: options.fieldPolicy.render(rhs, field: key, maxLength: options.maxValueLength),
                    baselineLine: pair.baseline.lineNumber,
                    candidateLine: pair.candidate.lineNumber,
                    detail: klass == .fieldPresenceChanged
                        ? "field present on the \(lhs == nil ? "candidate" : "baseline") side only"
                        : ""
                )
            )
        }
        return result
    }

    // MARK: - Step 6

    /// Two rank checks, at most one finding per matched pair.
    ///
    /// - **Within the event's own producer lane**, against ``DifferOptions/laneOrderTolerance``
    ///   (default `0`). A lane is one thread; one thread's callback order is causal, so any
    ///   movement inside it is a real difference. This is what catches a same-lane causal
    ///   inversion — `WindowIcon`/`MonitoredDesktop` hoisted above the `WindowCreate` they
    ///   reference — which a purely global window with a non-zero tolerance swallows.
    /// - **Globally**, against ``DifferOptions/orderTolerance``. Still needed: an event alone
    ///   in its lane has a constant lane rank, so a large *cross-lane* move (a `Gfx*` event
    ///   hoisted to the head of the stream) is invisible to the within-lane check.
    ///
    /// The within-lane finding wins when both fire, because it is the more specific
    /// statement about the same event. Emitting both would double-count one movement.
    private func orderFindings(
        for matchedPairs: [(baseline: ReplayRecord, candidate: ReplayRecord)]
    ) -> [Difference] {
        guard matchedPairs.count > 1 else { return [] }
        // Clamped, not guarded on. `DifferOptions` is public, and an earlier revision
        // returned `[]` outright for a negative `orderTolerance` — so a library caller
        // setting `-1` to mean "strictest" got no order checking at all, lane check
        // included. Negative means zero: the strictest thing a tolerance can be.
        let globalTolerance = max(0, options.orderTolerance)
        let laneTolerance = max(0, options.laneOrderTolerance)
        let byBaseline = ranking(matchedPairs.indices, by: { matchedPairs[$0].baseline.lineNumber })
        let byCandidate = ranking(matchedPairs.indices, by: { matchedPairs[$0].candidate.lineNumber })

        // Lane ranks: the same rank computation, restricted to the indices of one lane. An
        // event's lane comes from its `ev` name on the baseline side; a matched pair always
        // shares an `ev` name, so the two sides can never disagree about the lane.
        var lanes: [Int: EventLane] = [:]
        var laneMembers: [EventLane: [Int]] = [:]
        for index in matchedPairs.indices {
            let record = matchedPairs[index].baseline
            let lane = EventLane.lane(forEventName: record.eventName, isModelled: record.isModelled)
            lanes[index] = lane
            guard lane != .ambiguous else { continue }
            laneMembers[lane, default: []].append(index)
        }
        var laneBaselineRank: [Int: Int] = [:]
        var laneCandidateRank: [Int: Int] = [:]
        for (_, members) in laneMembers {
            for (rank, index) in ranking(members, by: { matchedPairs[$0].baseline.lineNumber }).enumerated() {
                laneBaselineRank[index] = rank
            }
            for (rank, index) in ranking(members, by: { matchedPairs[$0].candidate.lineNumber }).enumerated() {
                laneCandidateRank[index] = rank
            }
        }

        var baselineRank = [Int](repeating: 0, count: matchedPairs.count)
        var candidateRank = [Int](repeating: 0, count: matchedPairs.count)
        for (rank, index) in byBaseline.enumerated() { baselineRank[index] = rank }
        for (rank, index) in byCandidate.enumerated() { candidateRank[index] = rank }

        var findings: [Difference] = []
        for index in byBaseline {
            let pair = matchedPairs[index]
            let lane = lanes[index] ?? .ambiguous
            var detail: String?
            var baselineText = ""
            var candidateText = ""

            if let laneBefore = laneBaselineRank[index], let laneAfter = laneCandidateRank[index] {
                let laneDisplacement = abs(laneBefore - laneAfter)
                if laneDisplacement > laneTolerance {
                    baselineText = "\(lane.rawValue)-lane position \(laneBefore)"
                    candidateText = "\(lane.rawValue)-lane position \(laneAfter)"
                    detail = "moved \(laneDisplacement) position(s) WITHIN the `\(lane.rawValue)` producer lane"
                        + " (one thread, so its order is causal); lane tolerance is \(laneTolerance)"
                }
            }
            if detail == nil {
                let displacement = abs(baselineRank[index] - candidateRank[index])
                guard displacement > globalTolerance else { continue }
                baselineText = "matched position \(baselineRank[index])"
                candidateText = "matched position \(candidateRank[index])"
                detail = "moved \(displacement) matched position(s) across lanes,"
                    + " tolerance is \(globalTolerance)"
            }

            findings.append(
                Difference(
                    diffClass: .eventOrderChanged,
                    eventName: pair.baseline.eventName,
                    baselineValue: baselineText,
                    candidateValue: candidateText,
                    baselineLine: pair.baseline.lineNumber,
                    candidateLine: pair.candidate.lineNumber,
                    detail: detail ?? ""
                )
            )
        }
        return findings
    }

    /// Indices sorted by a line number. Factored out so the global and per-lane rank
    /// computations cannot drift apart.
    private func ranking<S: Sequence<Int>>(_ indices: S, by lineNumber: (Int) -> Int) -> [Int] {
        indices.sorted { lineNumber($0) < lineNumber($1) }
    }
}
