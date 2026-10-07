import Foundation
import MacdowsCore

/// ADR-0024 D-3 (K-a): a host's certificate pin item -- a keychain GenericPassword item (service
/// `<bundle-id>.cert-pin`, account = host UUID) whose data is this record as JSON. The preset
/// ("expected") fingerprint lives in the same item: both are integrity assets, and an Application
/// Support file or a `defaults write` could be changed by any process of the same user without a
/// prompt.
struct PinRecord: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Written after a handshake that matched the preset (D-5).
        case preset
        /// Trust and Pin on the first-use sheet.
        case trusted
        /// Replace Pin and Connect on the changed-certificate sheet (D-6).
        case replaced
    }

    /// The pinned fingerprint; nil while the host is not pinned (preset only, or after Reset).
    var sha256: CertificateFingerprint?
    /// The preset from the Host Editor ("Expected certificate fingerprint (optional)").
    var expected: CertificateFingerprint?
    var pinnedAt: Date?
    var source: Source?
    var subject: String?
    var issuer: String?
    /// The pin a Replace superseded (D-6).
    var previous: CertificateFingerprint?

    var isEmpty: Bool { sha256 == nil && expected == nil }
}

/// What reading a host's pin item returned (ADR-0024 D-3′).
enum PinReadResult: Equatable, Sendable {
    case found(PinRecord)
    /// errSecItemNotFound only.
    case missing
    /// Any other failure -- including a record that does not decode: an item that exists but
    /// cannot be read is never treated as "no pin".
    case unavailable(status: Int32)

    /// The decision table's input.
    var decisionInput: CertificateDecision.PinRead {
        switch self {
        case .found(let record): return .found(pinned: record.sha256, expected: record.expected)
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
    }
}

/// Raised by the read-modify-write operations below instead of writing over an item they could
/// not read.
enum PinStoreError: Error, Equatable {
    case unreadable(status: Int32)
    case writeFailed(status: Int32)
}

/// ADR-0024 D-3 / D-6: where a host's pin item lives. One keychain implementation and the test
/// doubles; every method may block and is called off the main thread.
protocol PinStore: Sendable {
    func read(for host: HostID) -> PinReadResult
    func write(_ record: PinRecord, for host: HostID, displayName: String) throws
    /// A missing item is success.
    func delete(for host: HostID) throws
    /// Every host that has a pin item (attributes only).
    func hostsWithItems() throws -> [HostID]
}

struct KeychainPinStore: PinStore {
    let service: String

    init(service: String = KeychainItems.service(suffix: "cert-pin")) {
        self.service = service
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func read(for host: HostID) -> PinReadResult {
        Self.result(from: KeychainItems.read(service: service, account: host.keychainAccount))
    }

    /// ADR-0024 D-3′, pure (gate r1 I-1): only a missing item is `.missing`; a failed read and an
    /// item whose data does not decode are `.unavailable` -- never "no pin".
    static func result(from read: KeychainItems.ReadResult) -> PinReadResult {
        switch read {
        case .found(let data):
            guard let record = try? decoder.decode(PinRecord.self, from: data) else {
                return .unavailable(status: errSecDecode)
            }
            return .found(record)
        case .notFound:
            return .missing
        case .failed(let status):
            return .unavailable(status: status)
        }
    }

    func write(_ record: PinRecord, for host: HostID, displayName: String) throws {
        let data = try Self.encoder.encode(record)
        do {
            try KeychainItems.upsert(service: service, account: host.keychainAccount,
                                     label: KeychainItems.label(displayName: displayName), data: data)
        } catch let error as KeychainItems.WriteError {
            throw PinStoreError.writeFailed(status: error.status)
        }
    }

    func delete(for host: HostID) throws {
        do {
            try KeychainItems.delete(service: service, account: host.keychainAccount)
        } catch let error as KeychainItems.WriteError {
            throw PinStoreError.writeFailed(status: error.status)
        }
    }

    func hostsWithItems() throws -> [HostID] {
        do {
            return try KeychainItems.accounts(service: service).compactMap(HostID.init(keychainAccount:))
        } catch let error as KeychainItems.WriteError {
            throw PinStoreError.unreadable(status: error.status)
        }
    }
}

// MARK: - The rotation operations (ADR-0024 D-3 / D-5 / D-6), store-level and offline-testable

extension PinStore {
    /// The host's current record for a read-modify-write: a missing item is an empty record, a
    /// failed read throws (never write over what could not be read).
    func currentRecord(for host: HostID) throws -> PinRecord {
        switch read(for: host) {
        case .found(let record): return record
        case .missing: return PinRecord()
        case .unavailable(let status): throw PinStoreError.unreadable(status: status)
        }
    }

    /// Trust and Pin (first-use sheet), and the preset match written after a successful handshake
    /// (D-5, `source = preset`). Keeps the preset.
    func pin(_ presented: CertificateFingerprint, source: PinRecord.Source, subject: String?, issuer: String?,
             for host: HostID, displayName: String, now: Date = Date()) throws {
        var record = try currentRecord(for: host)
        record.sha256 = presented
        record.source = source
        record.pinnedAt = now
        record.subject = subject
        record.issuer = issuer
        try write(record, for: host, displayName: displayName)
    }

    /// Replace Pin and Connect (D-6): the new fingerprint, `source = replaced`, the old pin kept as
    /// `previous`. In the pin-lost state the item is missing and this adds it (the preset, if a
    /// readable item still carried one, is kept).
    func replacePin(with presented: CertificateFingerprint, subject: String?, issuer: String?,
                    for host: HostID, displayName: String, now: Date = Date()) throws {
        var record = try currentRecord(for: host)
        record.previous = record.sha256
        record.sha256 = presented
        record.source = .replaced
        record.pinnedAt = now
        record.subject = subject
        record.issuer = issuer
        try write(record, for: host, displayName: displayName)
    }

    /// The Host Editor's preset field (UI-1 spec §5.3: editing the preset never touches the pin).
    /// An item left with neither pin nor preset is deleted.
    func setExpected(_ expected: CertificateFingerprint?, for host: HostID, displayName: String) throws {
        var record = try currentRecord(for: host)
        guard record.expected != expected else { return }
        record.expected = expected
        if record.isEmpty {
            try delete(for: host)
        } else {
            try write(record, for: host, displayName: displayName)
        }
    }

    /// Reset All Pins (D-6, D-6′ = E-a): every pin is cleared and every preset is KEPT; an item left
    /// with nothing in it is deleted. Returns the hosts whose pin was cleared. Stops at the first
    /// item it cannot read or write (nothing is written over an unreadable item).
    func resetAllPins(displayName: (HostID) -> String) throws -> [HostID] {
        let outcome = resetAllPinsKeepingProgress(displayName: displayName)
        if let error = outcome.error { throw error }
        return outcome.cleared
    }

    /// Same walk as `resetAllPins`, but a failure part-way does not lose the hosts already
    /// cleared: they come back in `cleared` next to the error that stopped the walk.
    func resetAllPinsKeepingProgress(displayName: (HostID) -> String) -> (cleared: [HostID], error: Error?) {
        var cleared: [HostID] = []
        do {
            for host in try hostsWithItems() {
                try resetPin(of: host, displayName: displayName, cleared: &cleared)
            }
        } catch {
            return (cleared, error)
        }
        return (cleared, nil)
    }

    private func resetPin(of host: HostID, displayName: (HostID) -> String, cleared: inout [HostID]) throws {
        var record = try currentRecord(for: host)
        let hadPin = record.sha256 != nil
        record.sha256 = nil
        record.previous = nil
        record.source = nil
        record.pinnedAt = nil
        record.subject = nil
        record.issuer = nil
        if record.isEmpty {
            try delete(for: host)
        } else {
            try write(record, for: host, displayName: displayName(host))
        }
        if hadPin { cleared.append(host) }
    }
}
