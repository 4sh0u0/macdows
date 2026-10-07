import Foundation
import MacdowsCore
import os

/// UI slice ① (ADR-0024 D-2 / D-2′ / D-5): the App's bookkeeping for ONE connection chain, and the
/// off-main-thread halves of its keychain writes.
///
/// A chain is the `CRSession` built for one Connect press (it holds the password bytes until it is
/// deallocated) together with the host record it dials and the trust context its certificate
/// callback judges by. When the callback rejects a certificate, the App's teardown drops its own
/// reference to that `CRSession`, and `PendingCertificateReview` keeps the chain alive -- and with
/// it the password -- only while the user is looking at the certificate sheet: Trust / Replace
/// re-`-start`s the SAME session with a new trust snapshot (no second credential read), Cancel
/// drops the review and with it the last reference, which overwrites the password.
@MainActor
struct PendingCertificateReview {
    let session: CRSession
    let host: HostID
    let verdict: CertificateDecision.Verdict
    let subject: String?
    let issuer: String?
}

/// The keychain writes a chain makes, off the main thread (they can block, ADR-0024 probe K), on
/// `KeychainQueue` (gate r1 m-5: a blocked call holds that queue's thread, not one of the
/// cooperative pool's).
@MainActor
enum ConnectChain {
    /// The `[connect]` lines (ADR-0024 D-8 registers their shape). Never an address, an account or
    /// a secret.
    static let log = Logger(subsystem: "dev.haru.macdows", category: "Connect")

    /// Saves a Password-sheet password with Remember ticked. Returns false on failure (the chain
    /// still connects; the password just is not remembered).
    static func savePassword(_ secret: SessionSecret, for host: HostID, displayName: String,
                             credentials: any CredentialStore) async -> Bool {
        await KeychainQueue.run { () -> Bool in
            (try? credentials.save(secret, for: host, displayName: displayName)) != nil
        }
    }

    /// Trust and Pin / Replace Pin and Connect (`ConnectFlow.confirm`), off the main thread.
    static func confirm(_ review: PendingCertificateReview, displayName: String, pins: any PinStore) async
        -> Result<(CertificateDecision.Context, ConnectFlow.Confirmation), ConnectFlow.ConfirmError> {
        let verdict = review.verdict, subject = review.subject, issuer = review.issuer, host = review.host
        let outcome = await KeychainQueue.run { () -> ConfirmOutcome in
            ConfirmOutcome(ConnectFlow.confirm(verdict, subject: subject, issuer: issuer, host: host, displayName: displayName, pins: pins))
        }
        return outcome.result
    }

    /// The preset written as the pin after a handshake that matched it (ADR-0024 D-5).
    static func writePresetPin(_ expected: CertificateFingerprint, for host: HostID, displayName: String,
                               pins: any PinStore) async -> Bool {
        await KeychainQueue.run { () -> Bool in
            ConnectFlow.writePresetPin(expected, host: host, displayName: displayName, pins: pins)
        }
    }

    /// `Result` with a tuple success is not `Sendable`; this box carries it across the hop.
    private struct ConfirmOutcome: @unchecked Sendable {
        let result: Result<(CertificateDecision.Context, ConnectFlow.Confirmation), ConnectFlow.ConfirmError>
        init(_ result: Result<(CertificateDecision.Context, ConnectFlow.Confirmation), ConnectFlow.ConfirmError>) {
            self.result = result
        }
    }

    /// The marker, window subtitle and status-bar text for a chain state (UI-1 spec §4.1).
    struct Presentation: Equatable {
        let marker: HostListViewController.Marker
        let subtitle: String?
        let statusBar: String
    }

    static func presentation(hasSession: Bool, state: ReconnectDriver.State?, hostTitle: String) -> Presentation {
        guard hasSession else {
            return Presentation(marker: .idle, subtitle: nil, statusBar: UIStrings.notConnected)
        }
        switch state {
        case .live?:
            return Presentation(marker: .live, subtitle: UIStrings.connectedTo(hostTitle), statusBar: UIStrings.connected)
        case .waiting?, .reconnecting?:
            return Presentation(marker: .reconnecting, subtitle: UIStrings.connectionLostTo(hostTitle), statusBar: UIStrings.reconnecting)
        case .gaveUp?:
            return Presentation(marker: .failed, subtitle: nil, statusBar: UIStrings.connectionFailed)
        case .idle?, nil:
            return Presentation(marker: .connecting, subtitle: UIStrings.connectingTo(hostTitle), statusBar: UIStrings.connecting)
        }
    }
}
