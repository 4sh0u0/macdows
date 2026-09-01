import Foundation

/// Which side of a diff a thing was seen on.
public enum DiffSide: String, Sendable, Codable {
    case baseline
    case candidate

    public var opposite: DiffSide { self == .baseline ? .candidate : .baseline }
}

/// Which half of a substitution a one-sided event type is.
public enum SupersessionRole: Sendable, Equatable {
    /// The event type the table entry names: it *appeared* on the entry's expected side.
    case appeared
    /// The event type the entry `supersedes`: it *disappeared* from the opposite side
    /// because the appearing type replaced it.
    case superseded
}

/// One entry in the "this event type is one-sided because of a known difference between the
/// two recordings, not because the remote end regressed" table.
///
/// This type exists because of M1 finding **F-1**. The upgrade gate's whole purpose is to
/// answer "did the thing we are about to upgrade change server behaviour?", and its only
/// tool is a diff against a frozen baseline. But some of the difference between the frozen
/// baseline and any fresh capture is *ours*: a property of how the two recordings were
/// made, not of the thing under test. Reported as an unexplained difference,
/// that is a false alarm that trains the operator to ignore the gate. Reported as an
/// explained, non-regression class, it is exactly the annotation the drill record needs.
public struct KnownDifferenceEntry: Sendable, Equatable, Codable {
    /// The `ev` name this entry explains (e.g. `GfxMapSurfaceToScaledWindow`).
    public let eventName: String
    /// The side the event is *expected* to appear on, as an **empirical** statement about
    /// the two recordings — never a claim about what caused the asymmetry.
    ///
    /// The asymmetry is load-bearing. For the pre-seeded entry it records that the
    /// scaled-map event is absent from the frozen 2026-08-19 captures and present on
    /// post-that-era ones, so it is expected on the **candidate** side. If it ever shows up
    /// only on the *baseline* side the recorded expectation does not hold, the entry does
    /// not apply, and the differ falls back to the unexplained class.
    ///
    /// An earlier revision of this comment derived the asymmetry from the FFmpeg/AVC
    /// capability flip. That attribution was falsified (see ``cause`` and
    /// `deps/freerdp.lock`'s CORRECTION note) and the mechanism is open pending the W2
    /// instrumented re-record. An entry states which side, and on what evidence; it never
    /// states why the server behaved that way.
    public let expectedSide: DiffSide
    /// The event type this one stands in for: the two names describe **the same class of
    /// server behaviour in two variants**, and the differ should compare them against each
    /// other rather than treat one's absence as a loss. `nil` when the entry describes a
    /// pure addition with no counterpart.
    ///
    /// This is a **pairing instruction, not an excuse.** Round-2 review established why the
    /// distinction matters: a name-level excuse plus step 3's "one-sided types are excluded
    /// from pairing" rule composes into "the whole class stops being compared", which turned
    /// a total graphics regression (every surface remapped at 1×1) into `PASS, exit 0`. So
    /// when this fires, the two one-sided occurrence sets are **matched by identity tuple
    /// and field-compared** like any other pair — see ``SemanticDiffer``'s step 4b. Only the
    /// whole-type *presence* difference is excused, and only ``newFields`` are exempt from
    /// field comparison.
    ///
    /// The pairing is deliberately *conditional*: see
    /// ``KnownDifferenceTable/resolution(for:presentOnlyOn:baselineOnlyNames:candidateOnlyNames:)``.
    /// A lone disappearance of the paired type, with nothing appearing opposite it, stays a
    /// regression, for the same reason ``expectedSide`` exists.
    ///
    /// Note what this field does *not* assert. It says the two variants are alternatives of
    /// one behaviour — a structural claim about the two payload types (`RailEvent.swift:151-160`
    /// models them as exactly that, the second carrying two extra fields). It does **not**
    /// assert a cause for which variant a given session gets; see ``cause``.
    public let supersedes: String?

    /// Keys the ``supersedes`` variant carries that its counterpart structurally cannot.
    ///
    /// Exempt from field comparison when they are absent on the counterpart's side and
    /// present on this one — otherwise every matched pair would report them as
    /// ``DiffClass/fieldPresenceChanged``, which is noise: their presence is the definition
    /// of the variant, not a difference within it. They are still *counted* and reported
    /// once per field as an ``DiffSeverity/expected`` finding, so the artifact records that
    /// they arrived. A declared new field appearing on the **wrong** side is not exempt.
    public let newFields: [String]
    /// Plain-language statement of *what is known*, printed into evidence artifacts.
    ///
    /// Must never contain host addresses, host names or credentials. Must also never assert
    /// a mechanism that has not been measured — see the pre-seeded entry for a worked
    /// example of the difference between "observed" and "explained".
    public let cause: String
    /// Where the ruling/finding that authorises this entry is recorded.
    public let reference: String

    public init(
        eventName: String,
        expectedSide: DiffSide,
        supersedes: String? = nil,
        newFields: [String] = [],
        cause: String,
        reference: String
    ) {
        self.eventName = eventName
        self.expectedSide = expectedSide
        self.supersedes = supersedes
        self.newFields = newFields
        self.cause = cause
        self.reference = reference
    }

    /// Hand-written rather than synthesized so `supersedes` and `newFields` are genuinely
    /// **optional in a table file**. Swift only synthesizes `decodeIfPresent` for `Optional`
    /// properties, so a synthesized decoder would have made `newFields` mandatory and broken
    /// every table written before it existed — the same append-only-with-defaults discipline
    /// adr/0008 §5 imposes on the wire format, applied to this file format.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventName = try container.decode(String.self, forKey: .eventName)
        expectedSide = try container.decode(DiffSide.self, forKey: .expectedSide)
        supersedes = try container.decodeIfPresent(String.self, forKey: .supersedes)
        newFields = try container.decodeIfPresent([String].self, forKey: .newFields) ?? []
        cause = try container.decode(String.self, forKey: .cause)
        reference = try container.decode(String.self, forKey: .reference)
    }

    private enum CodingKeys: String, CodingKey {
        case eventName, expectedSide, supersedes, newFields, cause, reference
    }
}

/// The set of ``KnownDifferenceEntry``s in force for a run.
///
/// Kept deliberately small and explicit. Every entry is a difference the gate will *not*
/// fail on, so an over-broad table silently disarms the gate. Entries are added by an
/// owner ruling, either here (permanent, reviewed) or via `--known-difference-table` (one
/// drill, recorded in that drill's record).
public struct KnownDifferenceTable: Sendable, Equatable {
    public private(set) var entries: [String: KnownDifferenceEntry]

    /// `uniquingKeysWith`, never `uniqueKeysWithValues`: the latter *traps* on a duplicate
    /// event name, and this initializer is on the path from an operator-authored
    /// `--known-difference-table` file. A CLI that answers a typo with a stdlib assertion and
    /// SIGILL is not what a drill operator should see. Last entry wins, matching
    /// ``merging(_:)``'s documented precedence — and ``load(fromJSONAt:)`` refuses the file
    /// outright rather than relying on that, so silence is not the file path's behaviour.
    public init(entries: [KnownDifferenceEntry] = []) {
        self.entries = Dictionary(entries.map { ($0.eventName, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// The one entry M1 wave-1 ruling F-1 makes mandatory.
    ///
    /// **The mechanism is open, and this entry says so.** An earlier revision asserted the
    /// FFmpeg/AVC capability flip (Phase 2 W0(2)) as the cause. L4's audit
    /// (recorded in `deps/freerdp.lock`'s own `CORRECTION` note, appended 2026-09-01 to the
    /// "Phase 2 W0(2) AVC caps flip" entry of `cmake_config.corrections_applied`)
    /// **falsified that** on two independent grounds:
    ///
    /// - *Caps*: `rdpgfx_main.c:373-387` sets `RDPGFX_CAPS_FLAG_AVC_DISABLED` in **both**
    ///   arms of the `WITH_GFX_H264` `#ifdef`; the H264 arm is additionally gated on runtime
    ///   `!GfxAVC444`, which defaults `FALSE` (`settings.c:1231-1232`) and is set nowhere in
    ///   this repo. So the flip does not change the caps we advertise. The flag whose *name*
    ///   matches the scaled map — `RDPGFX_CAPS_FLAG_SCALEDMAP_DISABLE`, 10.7+ — is gated on
    ///   `WITH_CAIRO`/`WITH_SWSCALE`, both OFF before and after.
    /// - *Timeline*: the scaled variant was observed on 2026-08-21 at `46e7602`, whose lock
    ///   reads `-DWITH_FFMPEG=OFF`. `WITH_VIDEO_FFMPEG=ON` landed at `a770963`, two days
    ///   later. The variant was seen **before** the flip, on a build with H264 off.
    ///
    /// What survives is empirical and is all this entry claims: the six 2026-08-19 captures
    /// contain **zero** scaled maps (independently re-verified by the M1 L4 audit the lock's
    /// CORRECTION cites — and not for want
    /// of instrumentation: `rail-probe.c:754-767` has handled the scaled variant, with
    /// `target*`, the whole time), while the same host **did** emit the variant in a
    /// 2026-08-21 session. Between those two recordings at least four things differ (client
    /// tool, session desktop size, date/session, and — only afterwards — the FreeRDP build
    /// settings), and the samples cannot separate them.
    ///
    /// So: an **expected delta against a pre-flip-era baseline**, cause unresolved, resolver
    /// = the W2 drill's instrumented re-record (L4 §7(g): rail-probe/CRBridge need a
    /// client-`CapsAdvertise` log first, since `SCALEDMAP_DISABLE` only exists at 10.7+ and
    /// nothing records which capset was negotiated). Assertions are forbidden in **both**
    /// directions: not "this is the AVC flip" (falsified), and not "this is an upstream
    /// FreeRDP regression" (ruling F-1).
    ///
    /// `supersedes` survives the falsification because it is not a causal claim: it says the
    /// plain and scaled maps are two variants of one behaviour, which is a fact about the two
    /// payload types (`RailEvent.swift:151-160`). Under round-2's fix it makes the differ
    /// *compare* the two sets instance-by-instance rather than skip them.
    public static let preSeeded = KnownDifferenceTable(entries: [
        KnownDifferenceEntry(
            eventName: "GfxMapSurfaceToScaledWindow",
            expectedSide: .candidate,
            supersedes: "GfxMapSurfaceToWindow",
            // Structural, not causal: RDPGFX_MAP_SURFACE_TO_SCALED_WINDOW_PDU is the
            // plain PDU plus these two fields (RailEvent.swift:151-160).
            newFields: ["targetWidth", "targetHeight"],
            cause: """
                OBSERVED, MECHANISM OPEN. The six 2026-08-19 phase05 captures contain zero \
                MapSurfaceToScaledWindow events (L4 audit §7, independently re-verified; the \
                probe could already log the variant, so this is absence of the event, not of \
                instrumentation), while the same host did emit the scaled variant in a \
                2026-08-21 session. Its appearance on a post-2026-08-19 capture is therefore \
                an EXPECTED DELTA against this pre-flip-era baseline, and must NOT be \
                recorded as an upstream FreeRDP regression (ruling F-1). It must equally NOT \
                be attributed to the WITH_VIDEO_FFMPEG/AVC caps flip: L4 §7(c)(d) falsified \
                that (AVC_DISABLED is advertised identically before and after; the variant \
                was seen two days BEFORE the flip, on a WITH_FFMPEG=OFF build). Leading open \
                hypothesis is the client's advertised RDPGFX caps (SCALEDMAP_DISABLE, 10.7+), \
                unmeasured because nothing logs the CapsAdvertise PDU or the negotiated \
                capset. At least four things differ between the two recordings (client tool, \
                session desktop size, session/date, FreeRDP build settings) and the samples cannot \
                separate them. RESOLVER: the W2 drill's instrumented re-record. Until then \
                L11 must record freerdp_avc, freerdp_scaledmap_caps, client_tool and \
                session_desktop for BOTH sides and assert no mechanism in either direction.
                """,
            // Tracked-to-tracked only. This string is copied verbatim into drill artifacts
            // and read by people without the private docs repo, so it cites the lock — which
            // carries the whole corrected narrative, including the four fields L11 must
            // record — rather than a `docs/` path that resolves for nobody outside the
            // maintainer's checkout. Repo convention reserves `adr/NNNN` for private-docs
            // pointers; a bare file path is not that convention.
            reference: """
                phase3 M1 finding F-1 / wave-1 ruling F-1; deps/freerdp.lock, \
                cmake_config.corrections_applied — "Phase 2 W0(2) AVC caps flip" entry, \
                CORRECTION 2026-09-01 (falsification, and the four fields L11 must record)
                """
        ),
    ])

    /// The explanation for `eventName` having *appeared* on `side` and nowhere else, or
    /// `nil`. Directional: an entry only ever excuses its own expected side.
    public func explanation(for eventName: String, presentOnlyOn side: DiffSide) -> KnownDifferenceEntry? {
        guard let entry = entries[eventName], entry.expectedSide == side else { return nil }
        return entry
    }

    /// The full resolution for a one-sided event type, covering **both** halves of a
    /// substitution.
    ///
    /// Two ways an entry can claim a one-sided event type:
    ///
    /// 1. ``SupersessionRole/appeared`` — `eventName` is the entry's own event and it turned
    ///    up on the entry's `expectedSide`.
    /// 2. ``SupersessionRole/superseded`` — `eventName` is what some entry `supersedes`, it
    ///    vanished from the side opposite that entry's `expectedSide`, **and** the
    ///    superseding type is itself one-sided on the expected side *in this very
    ///    comparison*.
    ///
    /// That third clause is the whole safety of the feature. `supersedes` is not a licence
    /// to ignore an event type; it is a licence to ignore its disappearance *when the
    /// replacement is right there in the same census*. A lone disappearance — the plain
    /// surface-map gone with no scaled variant appearing — is the "flip was lost" case and
    /// stays ``DiffClass/eventTypeOnlyOnOneSide``, exactly like the mirror case that
    /// `expectedSide` already guards.
    ///
    /// - Parameters:
    ///   - baselineOnlyNames: `ev` names present on the baseline side only, this comparison.
    ///   - candidateOnlyNames: `ev` names present on the candidate side only, this comparison.
    public func resolution(
        for eventName: String,
        presentOnlyOn side: DiffSide,
        baselineOnlyNames: Set<String>,
        candidateOnlyNames: Set<String>
    ) -> (entry: KnownDifferenceEntry, role: SupersessionRole)? {
        if let entry = explanation(for: eventName, presentOnlyOn: side) {
            return (entry, .appeared)
        }
        // Sorted for determinism: two entries could in principle name the same superseded
        // type, and the report must not depend on Dictionary iteration order.
        for entry in entries.values.sorted(by: { $0.eventName < $1.eventName }) {
            guard entry.supersedes == eventName else { continue }
            // The type it replaced must be missing from the side the replacement appeared
            // on — a disappearance on the *same* side as the appearance is not a
            // substitution, it is two unrelated findings.
            guard side == entry.expectedSide.opposite else { continue }
            let replacementIsOneSided = entry.expectedSide == .candidate
                ? candidateOnlyNames.contains(entry.eventName)
                : baselineOnlyNames.contains(entry.eventName)
            guard replacementIsOneSided else { continue }
            return (entry, .superseded)
        }
        return nil
    }

    /// Right-hand entries win on an event-name collision.
    public func merging(_ other: KnownDifferenceTable) -> KnownDifferenceTable {
        var merged = self
        merged.entries.merge(other.entries) { _, new in new }
        return merged
    }

    /// A `--known-difference-table` file the loader refuses.
    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case duplicateEventName(String)

        public var description: String {
            switch self {
            case .duplicateEventName(let name):
                return "two entries name the same event: \(name) — each event type may be explained once"
            }
        }
    }

    /// Loads a table from a JSON array of ``KnownDifferenceEntry`` objects, so a
    /// one-off drill can add an entry without a code change (and without that entry
    /// silently becoming permanent).
    ///
    ///     [{"eventName":"…","expectedSide":"candidate","supersedes":"…","cause":"…","reference":"…"}]
    ///
    /// `supersedes` is optional and absent means "pure addition, not a substitution".
    ///
    /// A duplicated `eventName` is **refused**, not silently resolved: in a file whose whole
    /// purpose is to stop the gate failing on named event types, "which of my two entries
    /// won?" is not a question an operator should have to reverse-engineer from the report.
    public static func load(fromJSONAt url: URL) throws -> KnownDifferenceTable {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([KnownDifferenceEntry].self, from: data)
        var seen = Set<String>()
        for entry in decoded where !seen.insert(entry.eventName).inserted {
            throw LoadError.duplicateEventName(entry.eventName)
        }
        return KnownDifferenceTable(entries: decoded)
    }
}
