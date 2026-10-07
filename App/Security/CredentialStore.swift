import Foundation

/// What reading a host's saved password returned (ADR-0024 D-1).
enum CredentialReadResult {
    case found(SessionSecret)
    /// No item: the password is not saved; the Password sheet asks for it.
    case notSaved
    /// The keychain refused or failed. D-1: treated exactly like `notSaved` (the Password sheet),
    /// never by falling back to any plaintext file; the status is kept for one log line.
    case unavailable(status: Int32)
}

/// ADR-0024 D-1: where a host's password lives. One keychain implementation and the test doubles;
/// every method may block (see `KeychainItems`) and is called off the main thread.
protocol CredentialStore: Sendable {
    func read(for host: HostID) -> CredentialReadResult
    func save(_ secret: SessionSecret, for host: HostID, displayName: String) throws
    /// A missing item is success.
    func delete(for host: HostID) throws
}

/// The keychain implementation: GenericPassword, service `<bundle-id>.rdp`, account = host UUID,
/// data = the UTF-8 password bytes.
struct KeychainCredentialStore: CredentialStore {
    let service: String

    init(service: String = KeychainItems.service(suffix: "rdp")) {
        self.service = service
    }

    func read(for host: HostID) -> CredentialReadResult {
        Self.result(from: KeychainItems.read(service: service, account: host.keychainAccount))
    }

    /// ADR-0024 D-1, pure (gate r1 I-1): only a missing item is `.notSaved`; every failure is
    /// `.unavailable` (the caller still only asks for the password, but logs the status).
    ///
    /// The returned `Data` is copied into a `SessionSecret` and then dropped, not zeroed: it is a
    /// bridged copy of Security.framework's own buffer, so overwriting it would only add one more
    /// copy and leave the original untouched -- that buffer is outside this App's control
    /// (ADR-0024 RK-1).
    static func result(from read: KeychainItems.ReadResult) -> CredentialReadResult {
        switch read {
        case .found(let data):
            return .found(SessionSecret(copying: data))
        case .notFound:
            return .notSaved
        case .failed(let status):
            return .unavailable(status: status)
        }
    }

    func save(_ secret: SessionSecret, for host: HostID, displayName: String) throws {
        try secret.withUnsafeData { data in
            try KeychainItems.upsert(service: service, account: host.keychainAccount,
                                     label: KeychainItems.label(displayName: displayName), data: data)
        }
    }

    func delete(for host: HostID) throws {
        try KeychainItems.delete(service: service, account: host.keychainAccount)
    }
}
