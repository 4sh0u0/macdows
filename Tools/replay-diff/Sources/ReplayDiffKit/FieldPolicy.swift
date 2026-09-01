import Foundation

/// Which fields are noise, which are session-scoped handles, and which must never be
/// printed.
///
/// This is the whole reason the differ is "semantic" rather than a `diff(1)` over two
/// JSONL files: two captures of the same server behaviour disagree on every timestamp,
/// every thread id and every kernel handle, and agree on everything that actually
/// describes what the server did.
public struct FieldPolicy: Sendable, Equatable {
    /// Never compared and never used for matching.
    ///
    /// - `t_ms`: monotonic ms since connect — different on every run by construction.
    /// - `tid`: hex `pthread_self()`; a new run gets new thread addresses. Note the
    ///   consequence: the differ therefore cannot currently assert *per-thread* ordering
    ///   (see ``DifferOptions/orderTolerance`` for the coarser rule it uses instead).
    /// - `sinceConnectMs`: `DurationElapsed`'s payload is the run's own wall duration.
    public static let defaultIgnoredFields: Set<String> = ["t_ms", "tid", "sinceConnectMs"]

    /// Compared, but replaced by a placeholder in *output*.
    ///
    /// These are `VerifyCertificateEx`'s fields. No sample contains that event (its own
    /// `RailEventKind` doc comment says so), but a live re-record on an X.509-fallback
    /// connection would emit the host name, the certificate subject/issuer and its
    /// fingerprint — and this tool's output is meant to become the evidence artifact
    /// attached to an upgrade-gate drill record. Redacting by default means a change is
    /// still *detected* and reported by field name, while the value never reaches a log,
    /// a terminal scrollback or a document. Project red line, non-negotiable.
    public static let defaultRedactedFields: Set<String> = [
        "host", "commonName", "subject", "issuer", "fingerprint",
    ]

    /// Field name → identifier namespace. Values of these fields are session-scoped
    /// handles: a re-record of the very same user actions produces entirely different
    /// window ids and surface ids. Comparing them literally would make every window event
    /// differ; ignoring them entirely would lose "these two events are about the same
    /// window", which is the only thing that makes matching work. So they are
    /// *canonicalized* instead — see ``SemanticDiffer``.
    ///
    /// `windowId`, `ownerWindowId`, `activeWindowId` and `windowIdMarker` share one
    /// namespace because they are all HWNDs drawn from the same server-side space
    /// (`RailEvent.swift`'s payload structs; `ownerWindowId` is adr/0008 §3's owner HWND).
    /// `surfaceId` is the RDPGFX surface space, unrelated. `notifyIconId` is the tray
    /// icon space.
    public static let defaultIdentifierNamespaces: [String: String] = [
        "windowId": "window",
        "ownerWindowId": "window",
        "activeWindowId": "window",
        "windowIdMarker": "window",
        "surfaceId": "surface",
        "notifyIconId": "notifyIcon",
    ]

    /// Compared normally, but exempt from ``render(_:field:maxLength:)``'s length cap.
    ///
    /// - `capsSets`: `GfxCapsAdvertise`'s whole advertised capset list in one string (the
    ///   P1 instrumentation's single-summary-event design). A full FreeRDP advertise is
    ///   ~15 capsets ≈ 329 chars, and the capsets that carry `SCALEDMAP_DISABLE` — the
    ///   reason the field exists — sit at the *end* in wire order, so the default 120-char
    ///   cap would cut exactly the part a drill artifact needs visible. The value's
    ///   character set is closed (`[0-9A-Fx:,]`, built by the probe from `%08X` pairs), so
    ///   the redaction rationale above never applies to it.
    public static let defaultUnTruncatedFields: Set<String> = ["capsSets"]

    public var ignoredFields: Set<String>
    public var redactedFields: Set<String>
    public var identifierNamespaces: [String: String]
    public var unTruncatedFields: Set<String>

    public init(
        ignoredFields: Set<String> = FieldPolicy.defaultIgnoredFields,
        redactedFields: Set<String> = FieldPolicy.defaultRedactedFields,
        identifierNamespaces: [String: String] = FieldPolicy.defaultIdentifierNamespaces,
        unTruncatedFields: Set<String> = FieldPolicy.defaultUnTruncatedFields
    ) {
        self.ignoredFields = ignoredFields
        self.redactedFields = redactedFields
        self.identifierNamespaces = identifierNamespaces
        self.unTruncatedFields = unTruncatedFields
    }

    public static let `default` = FieldPolicy()

    /// Identifier field names in a fixed order. `Dictionary` iteration order is not
    /// stable across runs, and every first-appearance position is assigned on this walk —
    /// the `surface`/`notifyIcon` ordinals, the late pool `window?#k` (untitled anchoring
    /// step 2), and the same-title disambiguator `#k` (W2 batch 2) — so an unsorted walk over
    /// an event carrying two same-namespace identifiers (`WindowUpdate` has both `windowId`
    /// and `ownerWindowId`) could hand out different positions on two runs of the same input.
    /// Sorting makes the differ deterministic. Created untitled windows are the one branch
    /// that no longer depends on it: their `window#k` comes from the WindowCreate-order
    /// prescan, which reads `windowId` alone.
    public var sortedIdentifierFieldNames: [String] {
        identifierNamespaces.keys.sorted()
    }

    public func isRedacted(_ field: String) -> Bool { redactedFields.contains(field) }
    public func namespace(of field: String) -> String? { identifierNamespaces[field] }

    /// Renders a value for output, applying redaction and length capping.
    ///
    /// A redacted value is reported as its length only — enough to see that "the subject
    /// changed" without disclosing either subject.
    public func render(_ value: JSONValue?, field: String, maxLength: Int) -> String {
        guard let value else { return "<absent>" }
        if isRedacted(field) {
            return "<redacted:\(value.displayString.count) chars>"
        }
        let text = value.displayString
        guard maxLength > 0, !unTruncatedFields.contains(field), text.count > maxLength else {
            return text
        }
        return String(text.prefix(maxLength)) + "…(\(text.count) chars)"
    }
}
