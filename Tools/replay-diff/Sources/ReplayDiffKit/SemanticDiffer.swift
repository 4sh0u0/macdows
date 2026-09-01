import Foundation

/// Tuning for one diff run.
public struct DifferOptions: Sendable, Equatable {
    public var fieldPolicy: FieldPolicy
    public var knownDifferenceTable: KnownDifferenceTable

    /// Replace session-scoped handle values with per-side canonical tokens before
    /// comparing: a `window` handle that ever carries a non-empty `title` anchors on it
    /// (`windowId: 65832` → `window@About Windows`; same-title duplicates disambiguate by
    /// first appearance); an untitled window is keyed by its WindowCreate payload class and
    /// its creation order within that class (`window+<style>+<styleEx>+<w>x<h>#k`); a handle
    /// referenced but never created in the capture goes to the late
    /// pool (`window?#k`); `surface` and `notifyIcon` get per-side first-appearance ordinals
    /// (`surfaceId: 7` → `surface#0`); `0` and, for window fields, `0xFFFFFFFF` are constants.
    /// On by
    /// default; without it, *no* pair of separately recorded captures can ever match,
    /// because a re-record gets fresh HWNDs and surface ids for the same user actions.
    /// Turn off with `--no-canonical-ids` when diffing two captures from the same
    /// session, where the raw ids are meaningful.
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
///    to per-side canonical tokens: title-anchored for `window` handles that ever carry
///    a non-empty `title`, WindowCreate-order ordinals for untitled windows, a separate
///    `window?` pool for handles referenced but never created, per-namespace
///    first-appearance ordinals for the rest.
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
/// **Ordinal-shift cascade — collapsed for UNIQUELY-titled windows (W2 batch 2),
/// residual for everything else.** A `window`-namespace handle whose stream carries a
/// non-empty `title` no other handle shares is anchored on it, so an event that changes
/// *which* handle appears first no longer shifts its identity: the experiment that used
/// to yield **98 `eventCountChanged` findings and roughly 190 total** (pre-W2b2 numbers,
/// measured against the then-current implementation and no longer reproducible in-tree;
/// only the 98 was construction-independent, the total depended on the injected payload)
/// from **one** extra uniquely-titled `WindowCreate` prepended to `s3-multiapp.jsonl`
/// (145 lines) now yields exactly **1** finding (pinned by `TitleAnchoredIdentityTests`).
///
/// Four position-keyed populations remain (the constants described further down are not a
/// population: they enter no pool). The cascade note issues one line per pool whose
/// distinct-handle count changed — `window` (created untitled windows and same-title-group
/// members SHARE it), `window?`, `surface`, `notifyIcon` — so a report carries as many such
/// lines as pools that moved.
///
/// - **Untitled `window` handles with a WindowCreate** are keyed by their **payload class**
///   — the `(style, styleEx, windowWidth, windowHeight)` tuple of the first WindowCreate, the
///   four fields the untitled-payload analysis found stable across recording days (§3, 84
///   build-order pairs: style equal in 100%, width/height 92.9%, styleEx 91.7%; every unequal
///   sample was a same-class creation-order swap, which the partition resolves, or an
///   offset/`fieldFlags` difference, which is not in the key) — with the ordinal counted
///   **within the class**
///   (untitled anchoring step 3, `ClassPartitionedIdentityTests`; token
///   `window+<style>+<styleEx>+<w>x<h>#k`). Offsets, `show`, `numVisibilityRects` and
///   `fieldFlags` are session variables and stay out of the key. An extra or missing untitled
///   window therefore shifts only its own class's members. Known limit (record §8 / review
///   G2): the key holds the window's size, so a full-screen untitled window would carry the
///   desktop geometry into its class and a re-record on another desktop size would report it
///   as unpaired rather than mis-paired (today's untitled windows are all small). The ordinal
///   itself comes from **creation order** (step 2, `CreationOrderedIdentityTests`): the main lane
///   (`EventLane.main`) is one thread, so that order is deterministic, unlike "whichever event
///   mentioned the handle first". That race is real but rare in the twelve captures: a first
///   mention before the handle's own WindowCreate happens for 11 of 138 created handles on the
///   frozen side (all via `GfxMapSurfaceToWindow`) and 12 of 143 on the re-record side (6 via
///   `MonitoredDesktop` — the main lane itself — and 6 via gfx maps); among the UNTITLED
///   created handles step 2 governs, only 1 of 84 and 2 of 85. First WindowCreate wins for
///   HWND reuse (`hwndReuseKeepsTheFirstCreationOrdinal`). The head-insertion experiment with
///   an UNTITLED extra window now depends on its class (pinned against the real capture,
///   interlocked with the note's own text): a window of a class s3 does not contain costs
///   exactly **1** finding; a clone of an EXISTING class's member costs, across s3's seven
///   untitled classes, **1–11 `eventCountChanged` / 24–64 findings** — the 4-member 136x39
///   tray-helper class is the harshest by count (11 / 34), the 5-member 0x0 class the mildest
///   multi-member case (3 / 52: its members are nearly indistinguishable, so the shift barely
///   shows), and two singleton classes bound the totals (1 / 24 and 3 / 64). That within-class
///   shift is the residual by construction (15 `eventCountChanged` for the class-blind
///   experiment after step 2, 49 after step 1, 53 before). A re-record that opens one transient
///   untitled window the baseline did not (a splash screen, a tooltip, a tray flyout) lands
///   here — invisible if its class is new, a class-local shift otherwise.
/// - **`window?` — handles referenced but never created in the capture** (windows that
///   existed before the probe attached, notify-icon owners, z-order markers) keep
///   first-appearance ordinals within their own pool, so their churn cannot shift the created
///   windows; the pool's note line has its own text (pre-existing windows, not transient ones —
///   a `window?` handle has no WindowCreate by definition). Taking these out of the created
///   windows' ordinal space is where step 2's measured gain comes from, given how rare the race
///   above is.
/// - **Same-title groups**: duplicates disambiguate by `#k`, a *per-side*
///   first-appearance index — the ordinal mechanism again, reduced to the group. A
///   membership or creation-order drift inside the group mis-pairs its members. Measured
///   on the frozen samples' five-window IME-overlay group (review W2b-r1 F2 / r2-2
///   attribution): a pure two-line creation-order swap, **8 findings** (pinned — the
///   only clean single-cause number; equal counts, so no note); dropping the FIRST
///   member, 98 findings *jointly* — the dropped window carries a Gfx map, so the
///   surface pool shifts too, and the no-`k`-shift control (dropping the LAST member)
///   measures 26, putting the group's own share at ≈72. In the frozen captures 5 of the
///   9 titled handles share that one title, so this is the majority titled case, not a
///   corner.
/// - **`surface`/`notifyIcon`**: no anchorable payload exists on their events; ordinals
///   as before.
///
/// **Measured, step 1** (`0xFFFFFFFF` → constant), on the six frozen×re-record pairs the
/// untitled-payload-stability record §6 quotes at 946
/// (`samples-local/rerecord-2026-09-drill-01`, untracked): total findings **946 → 879** (per
/// scenario 199/116/164/164/162/141 →
/// 192/104/163/165/136/119; s4 rose by one); findings whose identity carries a bare `window#`
/// ordinal 295 → 265 (plus 6 whose identity is the constant token `window#0xFFFFFFFF`; an
/// earlier revision of this paragraph counted those as ordinals and said 271). The synthetic
/// head-insertion experiment above carries the constant on
/// BOTH sides and is not that scenario: `eventCountChanged` 53 → 49 (MonitoredDesktop 2 → 0,
/// WindowCreate 9 → 7), total 87 → 118 — `eventOrderChanged` 22 → 51 (MonitoredDesktop
/// 0 → 18 as the constant's occurrences pair and report drift; WindowCreate 10 → 18; three other
/// events +1) and WindowCreate `fieldValueChanged` 12 → 18, all six from ONE new pairing of the
/// injected synthetic window against a real untitled one (a mis-pair the shifted ordinals
/// produce, not a correct match).
///
/// **Measured, step 2** (creation order + `window?` pool), same corpus: **879 → 831**
/// (`eventCountChanged` 380 → 298, `eventOrderChanged` 295 → 340, `fieldValueChanged`
/// 202 → 191, one-sided types 2 → 2; per scenario 192/104/163/165/136/119 →
/// 192/94/145/156/133/111). Bare `window#` identities 265 → 48 and 135 findings now carry a
/// `window?#` token (an earlier revision said 271 → 54, counting the 6 constant-token
/// identities as ordinals) — they do not sum to 265 because 82 former mis-pairs now pair (the
/// count-changed drop) while newly paired events report order or field findings instead. The
/// synthetic experiment: `eventCountChanged` 49 → 15, total 118 → 121 (order 51 → 71, field
/// 18 → 35).
///
/// **Measured, step 3** (payload-class partition), same corpus: **831 → 794**
/// (`eventCountChanged` 298 → 298, `eventOrderChanged` 340 → 341, `fieldValueChanged`
/// 191 → 153, one-sided types 2 → 2; per scenario 192/94/145/156/133/111 →
/// 181/94/145/138/125/111): the 48 findings that carried a bare `window#` ordinal now carry a
/// class token, and the field-difference drop is windows of different classes no longer being
/// paired positionally. Identity kinds after step 3 across the six pairs: 109 titled, 48
/// class-token, 135 `window?#`, 6 constant, 0 bare ordinals.
///
/// **Constants.** Two identifier values are constants, not handles, and never take an ordinal
/// or enter any pool: `0` (`<namespace>#none`, the null handle) and — `window` namespace only —
/// `0xFFFFFFFF` (`window#0xFFFFFFFF`, MonitoredDesktop's no-active-window sentinel; untitled
/// anchoring step 1, `IdentifierConstantTests`). Until step 1 the latter was ordinalised, and
/// since every frozen capture reports it early and 21–23 times it sat at `window#0` and shifted
/// every later untitled ordinal by one on whichever side carried it — a structural +1 cascade
/// against any re-record that does not report it. Neither constant counts toward the cascade
/// note's totals.
///
/// The tool fails *loudly*, never silently, so the verdict is not misleading — and the
/// report's **cascade note** fires on un-anchored handle-count changes (untitled and
/// same-title-group `window` handles included), telling the operator to read the *first*
/// `eventCountChanged` before the other fifty. A pure in-group reorder with equal counts
/// raises no note — count inequality is the only trigger the note has ever had.
/// ``DifferOptions/canonicalizeIdentifiers`` = false is the documented escape hatch but
/// is the wrong tool here — it makes every handle differ. Anchoring's own trade-off, by
/// design: a window whose title *differs between the two recordings* (a
/// timestamp-bearing document title, a localized shell title) anchors differently per
/// side and reports as two count findings instead of one matched pair with a title
/// `fieldValueChanged` — one honest finding becomes two, never zero.
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
                    + " — titled window handles are compared by title-anchored identity, all other"
                    + " handle values as per-side positions (untitled windows by payload class and WindowCreate"
                    + " order within it, never-created `window?` handles and the other namespaces by first appearance)"
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

    /// First non-empty `title` carried for each raw `window`-namespace handle, scanning
    /// the WHOLE stream before canonicalization: a window whose title only arrives on a
    /// later `WindowUpdate` still anchors, and an early reference to the handle from a
    /// title-less event (`MonitoredDesktop.activeWindowId`, a Gfx map) inherits the
    /// anchored token instead of freezing an ordinal first. Structural, not event-name
    /// keyed: any record carrying both a `windowId` and a non-empty `title` contributes
    /// (today that is exactly the two window-order events). First non-empty title wins —
    /// a mid-session rename does not re-anchor, so the mapping is deterministic per side;
    /// a window whose title DIFFERS between the two recordings anchors differently on
    /// each side and shows up as two count findings rather than one matched pair, which
    /// is the documented trade-off of anchoring on payload (see the README's
    /// Known-limitations section). Same first-wins consequence for HWND reuse (review
    /// W2b-r1 F7): a handle destroyed and re-created for a DIFFERENT window within one
    /// capture keeps the first window's title in its token — the events still pair the
    /// same way ordinals paired them, but the token's name is then actively misleading
    /// for the second lifetime, where `window#7` was merely opaque.
    private func windowTitlesByRawHandle(_ records: [ReplayRecord]) -> [String: String] {
        // Forward-looking redaction guard (review W2b-r1 F6): anchoring copies title text
        // into the four window-namespace identifier fields and into every `identity …`
        // line, none of which redaction covers. Today `title` is not redacted, so this is
        // dead; the day someone hardens `title` into `redactedFields`, anchoring must not
        // become the leak that defeats it — fall back to ordinals wholesale.
        guard !options.fieldPolicy.isRedacted("title") else { return [:] }
        var titles: [String: String] = [:]
        for record in records {
            // Keyed on the literal `windowId` deliberately (review W2b-r1 F10): the title
            // belongs to the window itself, never to the referrer — anchoring on every
            // window-namespace field would make an owner inherit its child's title. If a
            // caller reconfigures `identifierNamespaces` away from `windowId`, the
            // `namespace == windowNamespace` check in `canonicalized` goes nil-false and
            // everything degrades consistently to ordinals.
            guard let titleValue = record.fields["title"],
                  case .string(let title) = titleValue,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = record.fields["windowId"]?.integerCanonicalForm,
                  raw != "0",
                  titles[raw] == nil
            else { continue }
            // Emptiness is judged trimmed, but the stored anchor keeps the title verbatim
            // (review W2b-r2 R2-6): normalizing it would silently merge two titles that
            // differ only in whitespace — a collision, not a cleanup.
            titles[raw] = title
        }
        return titles
    }

    /// Escapes a title for embedding in a canonical token. `#` separates the same-title
    /// disambiguator and `@` introduces the title, so a title that literally contains
    /// either could forge another window's token — a window titled `Chrome#1` must never
    /// collide with the second window titled `Chrome` (review W2b-r1 F1: that collision
    /// merged two real windows into one identity bucket and turned a genuine difference
    /// into PASS/exit 0, the one failure mode this module declares out of bounds).
    /// Percent-escape, `%` first so the escape itself is unambiguous.
    private static func tokenEscapedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "@", with: "%40")
            .replacingOccurrences(of: "#", with: "%23")
    }

    /// `0xFFFFFFFF` as ``JSONValue/integerCanonicalForm`` renders it — the probe prints
    /// `activeWindowId` with `%u` (`rail-probe.c`), so the capture carries the decimal form.
    private static let noActiveWindowRaw = "4294967295"

    /// Server-side constants that travel in identifier fields without being handles. Each
    /// canonicalizes to a fixed token — never an ordinal — and is not counted as an
    /// un-anchored handle, or "this desktop has no active window" would read as "the
    /// ordinals shifted". Both callers (`canonicalized`, `distinctUnanchoredHandleCounts`)
    /// go through here so the two views of "what is a handle" cannot drift apart.
    ///
    /// - `0`, any namespace: RAIL's/RDPGFX's null handle ("no owner", "no active window").
    /// - `0xFFFFFFFF`, `window` namespace only: MonitoredDesktop's sentinel — "no active
    ///   window, or focus is not on the monitored desktop" (adr/0008 §0's capture census:
    ///   134/150 MonitoredDesktop records carried it and it must never be read as a window
    ///   id). Every frozen capture reports it early (from its second MonitoredDesktop on; the
    ///   first reports 0) and 21–23 times; ordinalised, it sat at `window#0` and pushed every
    ///   later untitled ordinal up by one on whichever side carried it — a structural +1
    ///   cascade against any re-record that does not report it (docs
    ///   `upgrade-gate/2026-09-untitled-payload-stability.md` §4.1, step 1 of §7). The
    ///   exemption covers all four `window`-namespace fields (only `activeWindowId` has been
    ///   observed carrying it) and is scoped to `window` because that is the only namespace it
    ///   has been measured in: `surfaceId` is a 16-bit space where the value cannot occur and
    ///   `notifyIconId` may legitimately be 0xFFFFFFFF, so both keep treating it as a value
    ///   (`IdentifierConstantTests` pins the scope).
    ///
    /// The two constants are different server statements and stay distinct tokens. Neither
    /// shape is forgeable: ordinals are `<namespace>#<decimal>`, title tokens start
    /// `<namespace>@` (`tokenEscapedTitle` escapes `@`/`#`), so `#none` / `#0xFFFFFFFF`
    /// collide with nothing a capture can produce.
    private func constantToken(raw: String, namespace: String, windowNamespace: String?) -> String? {
        if raw == "0" { return "\(namespace)#none" }
        if raw == Self.noActiveWindowRaw, namespace == windowNamespace {
            return "\(namespace)#0xFFFFFFFF"
        }
        return nil
    }

    /// Untitled anchoring step 2: the creation-order ordinal of every untitled `window` handle
    /// that has a `WindowCreate` anywhere in the stream — scanned before canonicalization, like
    /// the titles. Creation order inside the main lane (`EventLane.main`, the RAIL orders
    /// thread) is one thread's order and therefore deterministic; first-appearance order across
    /// the whole stream was not, because a `GfxMapSurfaceToWindow` on the gfx thread can mention
    /// a handle before or after its WindowCreate depending on the run (untitled-payload-stability
    /// §4.2 / §7.2). Handles absent from this map — referenced but never created inside the
    /// capture: windows that existed before the probe attached, notify-icon owners — get the late
    /// pool `window?#k` in `canonicalized` instead, so they cannot shift the created windows'
    /// positions (§4.3 / §7.2). **First WindowCreate wins** for HWND reuse (a handle destroyed
    /// and re-created within one capture keeps its first position; the `ordinals[raw] == nil`
    /// guard is what makes that so, and without it the second create would collide with the
    /// next new handle — `hwndReuseKeepsTheFirstCreationOrdinal` pins it), the same trade-off
    /// the title map makes. Keyed on the literal `windowId` for the same reason the title map is
    /// (F10): the creation belongs to the window, never to a referrer. Unlike the title map this
    /// one IS event-name keyed, deliberately: a title is a field that may ride on either
    /// window-order event, whereas creation is the `WindowCreate` event itself and nothing else
    /// carries it.
    ///
    /// Step 3 partitions the ordinal by **payload class**: the `(style, styleEx, windowWidth,
    /// windowHeight)` tuple of that first WindowCreate, with `k` counted WITHIN the class. The
    /// key's cross-session stability is the untitled-payload analysis §3 (84 build-order pairs):
    /// style equal in 100%, windowWidth/windowHeight in 92.9%, styleEx in 91.7% — and every
    /// unequal sample decomposes into either a same-class creation-order swap (an identity
    /// mis-pair the class partition resolves by construction: §5's last column measures 0 class
    /// mismatches) or one of two content-difference families that live entirely in offsets and
    /// `fieldFlags`, which are NOT in the key. Offsets, `show`, `numVisibilityRects` and
    /// `fieldFlags` are session variables and stay out (`ClassPartitionedIdentityTests` pins
    /// that). An extra or missing untitled window therefore shifts only its own class's members,
    /// never the whole untitled population. Known limit (§8, review G2): the key contains the
    /// window's size, and a full-screen untitled window would inherit the environment's desktop
    /// geometry into its class — a re-record on a different desktop size would then report it as
    /// unpaired rather than mis-paired. Both corpora's untitled windows are small (heights
    /// 0/1/4/39, none full-screen). A payload field the decoder did not deliver renders as `?` in
    /// the key (the RailEvent decoder requires the whole window-order payload, so this is
    /// defensive, not a path the corpus takes).
    private func creationOrdinalsByRawHandle(
        _ records: [ReplayRecord], titles: [String: String], windowNamespace: String?
    ) -> [String: CreationIdentity] {
        var identities: [String: CreationIdentity] = [:]
        var nextInClass: [String: Int] = [:]
        for record in records where record.eventName == "WindowCreate" {
            guard let raw = record.fields["windowId"]?.integerCanonicalForm,
                  let namespace = options.fieldPolicy.namespace(of: "windowId"),
                  constantToken(raw: raw, namespace: namespace, windowNamespace: windowNamespace) == nil,
                  titles[raw] == nil,
                  identities[raw] == nil
            else { continue }
            let classKey = Self.payloadClassKey(of: record)
            let k = nextInClass[classKey, default: 0]
            nextInClass[classKey] = k + 1
            identities[raw] = CreationIdentity(classKey: classKey, ordinalInClass: k)
        }
        return identities
    }

    /// What the WindowCreate-order prescan hands back per created untitled handle: the payload
    /// class it belongs to and its creation ordinal within that class (step 3); `canonicalized`
    /// renders the pair as `window+<classKey>#<ordinalInClass>`.
    struct CreationIdentity: Equatable {
        let classKey: String
        let ordinalInClass: Int
    }

    /// `<style>+<styleEx>+<w>x<h>` from a WindowCreate's own fields — decimal integers joined by
    /// separators outside the integer alphabet, so the class key cannot be mistaken for, or forge,
    /// an ordinal (`#<decimal>`), a late-pool token (`?#`) or a title (`@`, which escapes `#`).
    private static func payloadClassKey(of record: ReplayRecord) -> String {
        func component(_ name: String) -> String { record.fields[name]?.integerCanonicalForm ?? "?" }
        return "\(component("style"))+\(component("styleEx"))+\(component("windowWidth"))x\(component("windowHeight"))"
    }

    /// The late pool's namespace label: `window` handles with neither a title nor a WindowCreate
    /// in the capture. A separate position-keyed pool so its churn is counted and named on its
    /// own in the cascade note, never mixed into the created windows' ordinals.
    private static func latePoolNamespace(_ windowNamespace: String) -> String { "\(windowNamespace)?" }

    private func canonicalized(_ records: [ReplayRecord]) -> [ReplayRecord] {
        guard options.canonicalizeIdentifiers else { return records }
        let identifierFields = options.fieldPolicy.sortedIdentifierFieldNames
        // W2 batch 2 (title-anchored identity): `window`-namespace handles that ever
        // carry a title are keyed by that title, not by a first-appearance ordinal — so
        // an extra or missing window early in the stream no longer shifts every later
        // window's identity (the ordinal-shift cascade, measured at 98 eventCountChanged
        // findings from ONE prepended WindowCreate before this landed). The immunity is
        // scoped to UNIQUELY-titled handles: same-title duplicates disambiguate by a
        // per-side first-appearance index `k` — the ordinal mechanism again, reduced to
        // the group — so a same-title group whose membership or creation order drifts
        // between the two recordings still mis-pairs within the group (review W2b-r1 F2;
        // in the frozen samples 5 of the 9 titled handles share one title, so this is the
        // majority case, not a corner). Untitled window handles and the other namespaces
        // (surface/notifyIcon carry no anchorable payload) keep plain ordinals. Both
        // residual populations are what `cascadeNotes` counts.
        let windowNamespace = options.fieldPolicy.namespace(of: "windowId")
        let windowTitles = windowTitlesByRawHandle(records)
        let creationOrdinals = creationOrdinalsByRawHandle(records, titles: windowTitles, windowNamespace: windowNamespace)
        var titleDisambiguator: [String: Int] = [:]
        var nextOrdinal: [String: Int] = [:]
        var tokens: [String: [String: String]] = [:]

        return records.map { record in
            var fields = record.fields
            for fieldName in identifierFields {
                guard let raw = fields[fieldName]?.integerCanonicalForm,
                      let namespace = options.fieldPolicy.namespace(of: fieldName)
                else { continue }
                if let constant = constantToken(raw: raw, namespace: namespace, windowNamespace: windowNamespace) {
                    fields[fieldName] = .string(constant)
                    continue
                }
                if let existing = tokens[namespace]?[raw] {
                    fields[fieldName] = .string(existing)
                    continue
                }
                let token: String
                if namespace == windowNamespace, let title = windowTitles[raw] {
                    let k = titleDisambiguator[title, default: 0]
                    titleDisambiguator[title] = k + 1
                    let escaped = Self.tokenEscapedTitle(title)
                    token = k == 0 ? "\(namespace)@\(escaped)" : "\(namespace)@\(escaped)#\(k)"
                } else if namespace == windowNamespace, let created = creationOrdinals[raw] {
                    // Step 2: creation order, not first mention — an early gfx-lane reference to
                    // this handle gets the same token its WindowCreate will. Step 3: the order is
                    // counted within the window's payload class, and the class is in the token.
                    token = "\(namespace)+\(created.classKey)#\(created.ordinalInClass)"
                } else if namespace == windowNamespace {
                    // Step 2: neither title nor WindowCreate in this capture — the late pool,
                    // position-keyed among its own members only.
                    let pool = Self.latePoolNamespace(namespace)
                    let ordinal = nextOrdinal[pool, default: 0]
                    nextOrdinal[pool] = ordinal + 1
                    token = "\(pool)#\(ordinal)"
                } else {
                    let ordinal = nextOrdinal[namespace, default: 0]
                    nextOrdinal[namespace] = ordinal + 1
                    token = "\(namespace)#\(ordinal)"
                }
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
        let baselineCounts = distinctUnanchoredHandleCounts(baseline)
        let candidateCounts = distinctUnanchoredHandleCounts(candidate)
        var notes: [String] = []
        let windowNamespace = options.fieldPolicy.namespace(of: "windowId")
        for namespace in Set(baselineCounts.keys).union(candidateCounts.keys).sorted() {
            let before = baselineCounts[namespace] ?? 0
            let after = candidateCounts[namespace] ?? 0
            guard before != after else { continue }
            if let windowNamespace, namespace == Self.latePoolNamespace(windowNamespace) {
                // The late pool's own diagnosis: these handles have NO WindowCreate by definition,
                // so the created-window remedy below ("did the candidate open one extra
                // transient window?") would send the operator to the wrong place.
                notes.append(
                    "CASCADE RISK: the candidate has \(after) distinct never-created `\(namespace)` handle(s) "
                        + "against the baseline's \(before). `\(namespace)` handles are referenced (Gfx maps, "
                        + "notify-icon owners, z-order markers) but never created inside the capture — "
                        + "windows that pre-date the probe attaching, or whose owner lives outside the RAIL "
                        + "session. They are position-keyed among THEMSELVES only (per-side first appearance), "
                        + "so an extra or missing one EARLY shifts every later `\(namespace)` identity and can "
                        + "turn one real difference into many; the created windows (`\(windowNamespace)#k`) are "
                        + "NOT affected. Read the FIRST eventCountChanged carrying a `\(namespace)#` identity "
                        + "and check whether the two sessions simply had different pre-existing windows (a "
                        + "leftover RemoteApp window from an earlier session, a different shell state). "
                        + "--no-canonical-ids is NOT the remedy (it makes every handle differ)."
                )
                continue
            }
            notes.append(
                "CASCADE RISK: the candidate has \(after) distinct un-anchored `\(namespace)` handle(s) "
                    + "against the baseline's \(before). Un-anchored handles (`surface`/`notifyIcon` always; "
                    + "`window` handles that never carry a title — keyed by payload class and WindowCreate "
                    + "order WITHIN the class, so an extra or missing one shifts only its class-mates — plus every "
                    + "member of a same-title group, which disambiguate by a per-side first-appearance index; "
                    + "`window?` = handles referenced but never created in this capture, position-keyed among "
                    + "themselves only) are position-keyed, so an extra or missing one EARLY in the stream shifts "
                    + "its class-mates' (or group-mates') positions and can turn one real difference into several "
                    + "(measured: one extra UNTITLED WindowCreate of an EXISTING payload class at the head of a "
                    + "145-line capture costs 1–11 eventCountChanged / 24–64 findings depending on the class — "
                    + "the more distinguishable the class-mates, the more it shows; of a NEW class, exactly 1; "
                    + "only UNIQUELY-titled windows are immune, since W2 batch 2's title-anchored identity). "
                    + "Read the FIRST eventCountChanged below and check "
                    + "whether the candidate simply opened one extra transient window; if so, the rest of this "
                    + "report is one finding wearing a costume. --no-canonical-ids is NOT the remedy (it makes "
                    + "every handle differ)."
            )
        }
        return notes
    }

    /// Handles that still rely on position-keyed identity — the population the cascade
    /// note is about. Only UNIQUELY-titled `window` handles are excluded: their identity
    /// survives an early extra/missing handle, so a count change among them is exactly
    /// one honest finding, not a cascade. A member of a same-title group stays counted
    /// (review W2b-r1 F2): its `#k` disambiguator is a per-side first-appearance index,
    /// so a membership change in the group shifts the other members' identities — the
    /// same blast-radius shape the note exists to explain.
    private func distinctUnanchoredHandleCounts(_ records: [ReplayRecord]) -> [String: Int] {
        let windowNamespace = options.fieldPolicy.namespace(of: "windowId")
        let titles = windowTitlesByRawHandle(records)
        let creationOrdinals = creationOrdinalsByRawHandle(records, titles: titles, windowNamespace: windowNamespace)
        var handlesPerTitle: [String: Int] = [:]
        for title in titles.values { handlesPerTitle[title, default: 0] += 1 }
        var seen: [String: Set<String>] = [:]
        for record in records {
            for fieldName in options.fieldPolicy.sortedIdentifierFieldNames {
                guard let raw = record.fields[fieldName]?.integerCanonicalForm,
                      let namespace = options.fieldPolicy.namespace(of: fieldName),
                      constantToken(raw: raw, namespace: namespace, windowNamespace: windowNamespace) == nil
                else { continue }
                if namespace == windowNamespace, let title = titles[raw],
                   handlesPerTitle[title] == 1 { continue }
                // Step 2: the late pool is counted as its own namespace, so a churn of
                // never-created handles is named as such and never blamed on the created ones.
                if namespace == windowNamespace, titles[raw] == nil, creationOrdinals[raw] == nil {
                    seen[Self.latePoolNamespace(namespace), default: []].insert(raw)
                    continue
                }
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
                    // Display-capped only, at the report's own maxValueLength (one
                    // truncation vocabulary per artifact, review W2b-r2 R2-4): `key`
                    // itself stays uncapped as the bucket key — truncating the KEY could
                    // merge two long same-prefix identities, the F1 collision class in a
                    // different coat. Since title anchoring, an identity string can carry
                    // an arbitrarily long window title (review W2b-r1 F6); the artifact
                    // line gets the same cap-with-length shape FieldPolicy.render uses.
                    detail: "identity \(options.maxValueLength > 0 && key.count > options.maxValueLength ? String(key.prefix(options.maxValueLength)) + "…(\(key.count) chars)" : key)"
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
