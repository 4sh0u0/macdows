import Foundation
import MacdowsCore

/// UI slice ① (UI-1 spec §1, ADR-0024 D-3 / D-6): one host the user added. NOT a secret and NOT
/// an integrity asset: no password and no pin live here. The password is in the keychain
/// (`CredentialStore`), the pin and the preset fingerprint are in their own keychain item
/// (`PinStore`); this record only carries `pinned` (ADR-0024 D-3′: a pin item that is missing while
/// this says true is "pin lost", never first use) and the recent-connections log.
struct HostRecord: Codable, Equatable, Identifiable, Sendable {
    static let defaultPort: UInt16 = 3389
    /// ADR-0024 D-6: the recent-connections log keeps this many rows per host.
    static let recentLimit = 20

    var id: HostID
    var displayName: String
    var address: String
    var port: UInt16
    var userName: String
    /// The Host Editor's "Remember password in Keychain" (default on, UI-1 spec §5.1 ②).
    var remembersPassword: Bool
    /// True once a pin was written for this host; false after Reset All Pins (ADR-0024 D-3′).
    var pinned: Bool
    /// Newest first, at most `recentLimit` rows. Never an account name.
    var recent: [RecentConnection]

    init(id: HostID = HostID(), displayName: String, address: String, port: UInt16 = HostRecord.defaultPort,
         userName: String, remembersPassword: Bool = true, pinned: Bool = false, recent: [RecentConnection] = []) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.userName = userName
        self.remembersPassword = remembersPassword
        self.pinned = pinned
        self.recent = recent
    }

    /// The name shown everywhere: the display name, or the address when it is empty.
    var title: String { displayName.isEmpty ? address : displayName }
}

/// One row of a host's recent-connections log (ADR-0024 D-6). Local only, never an account.
struct RecentConnection: Codable, Equatable, Sendable {
    enum Event: String, Codable, Sendable {
        case connected
        case disconnectedByUser
        case connectionLost
        case connectFailed
        case certificateTrusted
        case certificatePinnedFromPreset
        case certificatePinReplaced
        case allPinsReset
    }

    var date: Date
    var event: Event
    /// For a replaced pin: the first eight bytes of the old and new fingerprints (D-6).
    var detail: String?
}

/// The host records, persisted as one JSON file in Application Support. Main-actor only; the file
/// is small and written atomically.
@MainActor
final class HostRecordStore {
    private(set) var records: [HostRecord] = []
    let fileURL: URL?
    /// Called after every change (the main window and the status item re-read).
    var onChange: (() -> Void)?

    /// `~/Library/Application Support/<bundle-id>/hosts.json`.
    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = Bundle.main.bundleIdentifier ?? "dev.haru.macdows"
        return base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("hosts.json")
    }

    /// `fileURL == nil` keeps the records in memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct FileShape: Codable {
        var version: Int
        var hosts: [HostRecord]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder.decode(FileShape.self, from: data)
        else { return }
        records = file.hosts
    }

    private func persist() {
        defer { onChange?() }
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(FileShape(version: 1, hosts: records))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            HostRecordStore.failedWrites += 1
        }
    }

    /// Count of failed writes, for tests and diagnostics.
    private(set) static var failedWrites = 0

    func record(_ id: HostID) -> HostRecord? {
        records.first { $0.id == id }
    }

    /// Adds or replaces (by id).
    func upsert(_ record: HostRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    func remove(_ id: HostID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func setPinned(_ pinned: Bool, for id: HostID) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].pinned != pinned else { return }
        records[index].pinned = pinned
        persist()
    }

    /// Prepends a row and keeps the newest `HostRecord.recentLimit`.
    func note(_ event: RecentConnection.Event, detail: String? = nil, for id: HostID, at date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].recent.insert(RecentConnection(date: date, event: event, detail: detail), at: 0)
        if records[index].recent.count > HostRecord.recentLimit {
            records[index].recent.removeLast(records[index].recent.count - HostRecord.recentLimit)
        }
        persist()
    }

    /// ADR-0024 D-6: after Reset All Pins every record is unpinned (otherwise every host would
    /// read as pin lost) and each one that was pinned gets an "All pins reset" row.
    func noteAllPinsReset(at date: Date = Date()) {
        for index in records.indices {
            let wasPinned = records[index].pinned
            records[index].pinned = false
            if wasPinned {
                records[index].recent.insert(RecentConnection(date: date, event: .allPinsReset), at: 0)
                if records[index].recent.count > HostRecord.recentLimit {
                    records[index].recent.removeLast(records[index].recent.count - HostRecord.recentLimit)
                }
            }
        }
        persist()
    }
}
