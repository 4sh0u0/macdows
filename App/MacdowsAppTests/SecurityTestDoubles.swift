import Foundation
import MacdowsCore

/// ADR-0024 D-10 ⑤: in-memory `CredentialStore` / `PinStore` doubles with call counters and
/// injectable failures. Shared by the store, rotation and connect-flow tests.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HostID: [UInt8]] = [:]
    private(set) var readCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    var readFailure: Int32?
    var deleteFailure: Int32?

    func read(for host: HostID) -> CredentialReadResult {
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if let readFailure { return .unavailable(status: readFailure) }
        guard let bytes = items[host] else { return .notSaved }
        return .found(SessionSecret(bytes: bytes))
    }

    func save(_ secret: SessionSecret, for host: HostID, displayName: String) throws {
        lock.lock(); defer { lock.unlock() }
        saveCount += 1
        items[host] = secret.withUnsafeData { [UInt8]($0) }
    }

    func delete(for host: HostID) throws {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        if let deleteFailure { throw KeychainItems.WriteError(status: deleteFailure) }
        items[host] = nil
    }

    func has(_ host: HostID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items[host] != nil
    }
}

final class InMemoryPinStore: PinStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [HostID: PinRecord] = [:]
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    /// Hosts whose read fails (D-3′ pin unavailable).
    var unreadable: Set<HostID> = []
    var deleteFailure: Int32?

    func read(for host: HostID) -> PinReadResult {
        lock.lock(); defer { lock.unlock() }
        if unreadable.contains(host) { return .unavailable(status: -25308) }
        guard let record = records[host] else { return .missing }
        return .found(record)
    }

    func write(_ record: PinRecord, for host: HostID, displayName: String) throws {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        records[host] = record
    }

    func delete(for host: HostID) throws {
        lock.lock(); defer { lock.unlock() }
        deleteCount += 1
        if let deleteFailure { throw PinStoreError.writeFailed(status: deleteFailure) }
        records[host] = nil
    }

    func hostsWithItems() throws -> [HostID] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.keys).sorted { $0.keychainAccount < $1.keychainAccount }
    }

    func seed(_ record: PinRecord, for host: HostID) {
        lock.lock(); defer { lock.unlock() }
        records[host] = record
    }
}

enum TestFingerprints {
    static let a = CertificateFingerprint(canonical: String(repeating: "a", count: 64))!
    static let b = CertificateFingerprint(canonical: String(repeating: "b", count: 64))!
    static let c = CertificateFingerprint(canonical: String(repeating: "c", count: 64))!
}
