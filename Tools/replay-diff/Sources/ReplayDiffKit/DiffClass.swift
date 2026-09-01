import Foundation

/// The differ's classification vocabulary.
///
/// This enum *is* the lane's exposed contract (M1 L5: "→ `replay-diff` CLI + diff-class
/// vocabulary"): the upgrade-gate runbook and every drill record classify their findings
/// with these names, so adding a case is a documented change, not an implementation
/// detail. Cases are ordered from most local (one field) to most global (a whole event
/// type), which is also the order the text report prints them in.
public enum DiffClass: String, Sendable, Codable, CaseIterable {
    /// Two matched events carry the same field with different values.
    case fieldValueChanged

    /// Two matched events disagree about whether a field is present at all. Distinct from
    /// ``fieldValueChanged`` because "the probe started logging a new field" and "the
    /// value moved" are different findings with different follow-ups (adr/0008 §5's
    /// append-only field rule makes the first one expected on a probe upgrade).
    case fieldPresenceChanged

    /// An event type both sides have, but with a different number of occurrences — or with
    /// its occurrences attributed to a different set of windows/surfaces.
    case eventCountChanged

    /// A matched pair of events sits further apart in the two streams than
    /// ``DifferOptions/orderTolerance`` allows.
    case eventOrderChanged

    /// An entire `ev` name appears on exactly one side, with no known local explanation.
    /// The load-bearing regression signal of the whole gate.
    case eventTypeOnlyOnOneSide

    /// An entire `ev` name appears on exactly one side and a ``KnownDifferenceTable``
    /// entry attributes it to a known **local difference** between the two recordings.
    ///
    /// Mandated by M1 wave-1 ruling F-1, pre-seeded with the scaled-surface-map case.
    /// Always ``DiffSeverity/expected``: a drill record must not report it as an upstream
    /// difference.
    ///
    /// "Local **difference**", deliberately, rather than naming a mechanism: L4's audit
    /// (recorded in `deps/freerdp.lock`'s CORRECTION note) falsified the FFmpeg/AVC-flip
    /// attribution for
    /// the one pre-seeded case and forbids assertions in *both* directions — the class means
    /// "expected against this baseline, not an upstream regression", and says nothing about
    /// mechanism. Review rounds 1-2 spelled this case after the then-assumed cause; the
    /// controller ruled it renamed before first use, precisely because a drill record is
    /// long-lived evidence and a name that asserts a mechanism this table refuses to assert
    /// would outlive the assumption. Nothing had shipped, so there is no compatibility alias.
    case knownLocalDifference

    /// A line one side could not be parsed. Always a finding, never silence — a gate that
    /// skipped unreadable lines would report "clean" on a file it only half read.
    case unparsableLine

    /// One-line description, printed by `--legend` and by the text report's footer so an
    /// artifact is self-explanatory without the runbook.
    public var summary: String {
        switch self {
        case .fieldValueChanged:
            return "a matched event's field holds a different value"
        case .fieldPresenceChanged:
            return "a matched event has a field on one side only"
        case .eventCountChanged:
            return "an event type occurs a different number of times, or against different windows/surfaces"
        case .eventOrderChanged:
            return "a matched event moved further than the order tolerance allows"
        case .eventTypeOnlyOnOneSide:
            return "an entire event type is present on one side only, unexplained"
        case .knownLocalDifference:
            return "an entire event type is present on one side only, attributable to a known local difference between the two recordings (not an upstream regression; mechanism not asserted)"
        case .unparsableLine:
            return "a line could not be parsed as a RailEvent"
        }
    }

    /// Default severity. Only ``knownLocalDifference`` is non-failing, and only
    /// because a table entry had to positively claim the event.
    public var defaultSeverity: DiffSeverity {
        self == .knownLocalDifference ? .expected : .regression
    }
}

/// Whether a difference should fail the gate.
public enum DiffSeverity: String, Sendable, Codable {
    /// Unexplained: the gate fails.
    case regression
    /// Explained by a recorded local cause: reported, but the gate still passes (unless
    /// the caller asked for `--fail-on-expected`).
    case expected
}

/// One classified difference.
public struct Difference: Sendable, Equatable, Codable {
    public let diffClass: DiffClass
    public let severity: DiffSeverity
    /// The `ev` name the difference is about. `nil` only for ``DiffClass/unparsableLine``,
    /// where there is no parsed event to name.
    public let eventName: String?
    /// The field name, for the field-level classes.
    public let field: String?
    /// Already rendered through ``FieldPolicy/render(_:field:maxLength:)`` — redacted and
    /// length-capped. Never a raw capture value.
    public let baselineValue: String?
    public let candidateValue: String?
    public let baselineLine: Int?
    public let candidateLine: Int?
    /// Free text; for ``DiffClass/knownLocalDifference`` this carries the table
    /// entry's cause and reference.
    public let detail: String

    public init(
        diffClass: DiffClass,
        severity: DiffSeverity? = nil,
        eventName: String? = nil,
        field: String? = nil,
        baselineValue: String? = nil,
        candidateValue: String? = nil,
        baselineLine: Int? = nil,
        candidateLine: Int? = nil,
        detail: String = ""
    ) {
        self.diffClass = diffClass
        self.severity = severity ?? diffClass.defaultSeverity
        self.eventName = eventName
        self.field = field
        self.baselineValue = baselineValue
        self.candidateValue = candidateValue
        self.baselineLine = baselineLine
        self.candidateLine = candidateLine
        self.detail = detail
    }
}
