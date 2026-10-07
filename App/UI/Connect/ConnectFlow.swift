import Foundation
import MacdowsCore

/// UI slice ① (ADR-0024 D-1 / D-2 / D-3′ / D-5): the decisions around one Connect press, as
/// functions of their inputs so the chain rules are testable offline with the store doubles.
///
/// A CHAIN starts with a Connect press and lasts as long as the `CRSession` built for it (every
/// automatic reconnect, and the re-`-start` after a certificate confirmation, reuse that session
/// and the password bytes it holds). `preflight` is the ONLY step that reads the credential store,
/// and it runs once per press; nothing in the certificate path takes a credential store at all.
enum ConnectFlow {

    /// What the off-main half of a Connect press found.
    enum Preflight: Sendable {
        /// The live-host boundary gate refused the address (unchanged from the scaffold).
        case refusedByBoundary(LabBoundary.Refusal)
        /// ADR-0024 D-3′ pin unavailable: no connection, no first-use sheet, no retry.
        case pinUnavailable(status: Int32)
        /// Go: the trust context for the bridge's snapshot and, if the keychain had it, the
        /// password. `credential == nil` means the Password sheet asks (not saved, or the keychain
        /// refused -- D-1: never a fallback to any file).
        case ready(context: CertificateDecision.Context, credential: SessionSecret?, credentialStatus: Int32?)
    }

    /// The off-main half of a Connect press. Order: the boundary gate (nothing is read from the
    /// keychain for an address that may not be dialled), then the pin item (a pin that cannot be
    /// read stops here, before the password is touched), then -- only when the host remembers its
    /// password -- the credential, exactly once.
    nonisolated static func preflight(
        host: HostID, address: String, recordSaysPinned: Bool, remembersPassword: Bool,
        credentials: any CredentialStore, pins: any PinStore,
        boundary: (String) -> LabBoundary.Verdict
    ) -> Preflight {
        if case .refused(let refusal) = boundary(address) {
            return .refusedByBoundary(refusal)
        }
        let pinRead = pins.read(for: host)
        switch CertificateDecision.plan(pin: pinRead.decisionInput, recordSaysPinned: recordSaysPinned) {
        case .refusePinUnavailable:
            if case .unavailable(let status) = pinRead { return .pinUnavailable(status: status) }
            return .pinUnavailable(status: -1)
        case .connect(let context):
            guard remembersPassword else {
                return .ready(context: context, credential: nil, credentialStatus: nil)
            }
            switch credentials.read(for: host) {
            case .found(let secret):
                return .ready(context: context, credential: secret, credentialStatus: nil)
            case .notSaved:
                return .ready(context: context, credential: nil, credentialStatus: nil)
            case .unavailable(let status):
                return .ready(context: context, credential: nil, credentialStatus: status)
            }
        }
    }

    /// The bridge's trust snapshot for a context (canonical hex, or nil = accept nothing).
    static func trustSnapshot(for context: CertificateDecision.Context) -> String? {
        CertificateDecision.acceptedFingerprint(for: context)?.canonical
    }

    /// What a confirmed sheet wrote, for the main thread's record update.
    enum Confirmation: Equatable, Sendable {
        case trusted(CertificateFingerprint)
        case replaced(old: CertificateFingerprint?, new: CertificateFingerprint)
    }

    enum ConfirmError: Error, Equatable {
        /// The verdict is not one a sheet can confirm.
        case notConfirmable
        case pinStore(PinStoreError)
    }

    /// Trust and Pin / Replace Pin and Connect, keychain half (ADR-0024 D-5 / D-6). Writes the pin
    /// and returns the context the SAME chain re-`-start`s with (D-2′: no second credential read --
    /// this function is not given a credential store). Off the main thread.
    nonisolated static func confirm(
        _ verdict: CertificateDecision.Verdict, subject: String?, issuer: String?,
        host: HostID, displayName: String, pins: any PinStore
    ) -> Result<(CertificateDecision.Context, Confirmation), ConfirmError> {
        do {
            switch verdict {
            case .firstUse(let presented):
                try pins.pin(presented, source: .trusted, subject: subject, issuer: issuer, for: host, displayName: displayName)
                return .success((.pinned(presented), .trusted(presented)))
            case .changed(let old, _, let presented):
                try pins.replacePin(with: presented, subject: subject, issuer: issuer, for: host, displayName: displayName)
                return .success((.pinned(presented), .replaced(old: old, new: presented)))
            case .accept, .unreadableCertificate, .unsupportedRoute:
                return .failure(.notConfirmable)
            }
        } catch let error as PinStoreError {
            return .failure(.pinStore(error))
        } catch {
            return .failure(.pinStore(.writeFailed(status: -1)))
        }
    }

    /// ADR-0024 D-5: a preset that matched is written as the pin once the handshake succeeded. A
    /// failed write only returns false (the next connect compares against the preset again).
    nonisolated static func writePresetPin(_ expected: CertificateFingerprint, host: HostID, displayName: String,
                                           pins: any PinStore) -> Bool {
        (try? pins.pin(expected, source: .preset, subject: nil, issuer: nil, for: host, displayName: displayName)) != nil
    }

    /// UI-1 spec §4.3: the three first-connect failure banners.
    enum FailureKind: Equatable, Sendable {
        case unreachable
        case signIn
        case certificate
        /// Anything else: the status line only.
        case other
    }

    /// FreeRDP's connect-class codes (`include/freerdp/error.h`, class 2 << 16).
    private static let connectClass = 0x0002_0000

    /// Classifies a failed first connect. A certificate rejection wins over the code (the bridge
    /// reports it as a TLS failure, indistinguishable by code alone -- ADR-0024 §0(f)).
    static func failureKind(errorCode: Int, certificateRejected: Bool) -> FailureKind {
        if certificateRejected { return .certificate }
        guard errorCode & 0xFFFF_0000 == connectClass else { return .other }
        switch errorCode & 0xFFFF {
        case 0x04, 0x05, 0x06, 0x0D, 0x1D:
            return .unreachable
        case 0x09, 0x0A, 0x0E, 0x0F, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B:
            return .signIn
        default:
            return .other
        }
    }
}
