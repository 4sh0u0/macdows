import Foundation

/// ADR-0024 D-5 / D-3′: the first-connect model as one pure function -- which certificate a
/// connection may accept, and what a rejection means -- so the whole table is testable offline.
///
/// Two halves, run at two different moments:
///
///  1. BEFORE `-start`, on the main thread, from what the pin store returned and the host record's
///     `pinned` bit: `plan(pin:recordSaysPinned:)`. It decides whether to connect at all
///     (`pinUnavailable` does not) and, if so, the trust snapshot handed to the bridge -- the one
///     fingerprint the certificate callback may accept, or none.
///  2. AFTER the callback rejected a certificate (or after a handshake that the snapshot let
///     through): `verdict(for:presented:)` says what the rejection IS -- first use, a changed
///     certificate (against the pin, the preset, or a pin that was lost) -- and whether a preset
///     match should now be written as the pin.
///
/// The bridge's callback compares the presented fingerprint with the snapshot's
/// `acceptedFingerprint` and nothing else (CRSession `-acceptedCertificateFingerprint`), so the
/// table is stated once, here; `acceptedFingerprint` is derived from the same `Context` the
/// verdict reads, and `CertificateDecisionTests` checks that the two agree for every row.
public enum CertificateDecision {

    /// What the pin store returned for one host (ADR-0024 D-3′: a failed READ is not a MISSING pin).
    public enum PinRead: Equatable, Sendable {
        /// The host's pin item, with its pin and/or preset (either may be absent).
        case found(pinned: CertificateFingerprint?, expected: CertificateFingerprint?)
        /// `errSecItemNotFound`: there is no pin item for this host.
        case missing
        /// Any other failure (ACL refusal, `errSecInteractionNotAllowed`, `errSecUserCanceled`, ...).
        case unavailable
    }

    /// Which trust question a connection is asking, decided before `-start`.
    public enum Context: Equatable, Sendable {
        /// The host is pinned; only that fingerprint is accepted.
        case pinned(CertificateFingerprint)
        /// Not pinned, a preset exists; a match is accepted and then pinned (`source = preset`).
        case preset(CertificateFingerprint)
        /// The host record says it was pinned but the pin item is gone (D-3′ pin lost): nothing is
        /// accepted, and the rejection is presented as a change.
        case pinLost
        /// Neither pin nor preset: nothing is accepted; the rejection opens the first-use sheet.
        case firstUse
    }

    /// The outcome of the pre-`-start` half.
    public enum Plan: Equatable, Sendable {
        /// Connect, with this trust context.
        case connect(Context)
        /// D-3′ pin unavailable: do not connect, do not open the first-use sheet, do not retry.
        case refusePinUnavailable
    }

    /// The pre-`-start` half (D-3′ rows first, then D-5's).
    public static func plan(pin: PinRead, recordSaysPinned: Bool) -> Plan {
        switch pin {
        case .unavailable:
            return .refusePinUnavailable
        case .found(let pinned?, _):
            return .connect(.pinned(pinned))
        case .found(nil, let expected):
            if recordSaysPinned { return .connect(.pinLost) }
            if let expected { return .connect(.preset(expected)) }
            return .connect(.firstUse)
        case .missing:
            return .connect(recordSaysPinned ? .pinLost : .firstUse)
        }
    }

    /// The single fingerprint the bridge's callback may accept for this context, or nil (accept
    /// nothing).
    public static func acceptedFingerprint(for context: Context) -> CertificateFingerprint? {
        switch context {
        case .pinned(let pinned): return pinned
        case .preset(let expected): return expected
        case .pinLost, .firstUse: return nil
        }
    }

    /// Where the "old" fingerprint of a changed-certificate sheet came from.
    public enum OldSource: Equatable, Sendable {
        case pin
        case preset
        /// The pin item is gone (D-3′ pin lost); there is no old value to show.
        case lost
    }

    /// The post-handshake / post-rejection half.
    public enum Verdict: Equatable, Sendable {
        /// The presented certificate is the accepted one. `writePresetPin` is true when it matched
        /// a preset on an unpinned host: the main thread writes it as the pin (`source = preset`)
        /// once the handshake succeeded (a failed write only warns; the next connect uses the
        /// preset again).
        case accept(writePresetPin: Bool)
        /// First use: the first-use sheet (`cf_*`), Trust and Pin only after `cf_check`.
        case firstUse(presented: CertificateFingerprint)
        /// A change (`cc_*`): Cancel is the default button, Replace only after `cc_check`.
        case changed(old: CertificateFingerprint?, oldSource: OldSource, presented: CertificateFingerprint)
        /// The callback could not compute a fingerprint for the presented certificate at all;
        /// nothing to show or pin.
        case unreadableCertificate
        /// A redirect or gateway route (v1 supports neither): rejected without a sheet.
        case unsupportedRoute
    }

    /// The post-handshake / post-rejection half. `presented` is nil when the bridge could not
    /// compute a fingerprint; `unsupportedRoute` is the callback's REDIRECT / GATEWAY flag.
    public static func verdict(for context: Context, presented: CertificateFingerprint?, unsupportedRoute: Bool = false) -> Verdict {
        if unsupportedRoute { return .unsupportedRoute }
        guard let presented else { return .unreadableCertificate }
        switch context {
        case .pinned(let pinned):
            return presented == pinned ? .accept(writePresetPin: false) : .changed(old: pinned, oldSource: .pin, presented: presented)
        case .preset(let expected):
            return presented == expected ? .accept(writePresetPin: true) : .changed(old: expected, oldSource: .preset, presented: presented)
        case .pinLost:
            return .changed(old: nil, oldSource: .lost, presented: presented)
        case .firstUse:
            return .firstUse(presented: presented)
        }
    }
}
