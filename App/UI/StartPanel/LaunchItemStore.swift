import Foundation
import MacdowsCore

/// One program the start panel can launch again: what it shows, what it sends, and when. ADR-0025
/// R-6 / §1.7: these four fields and nothing else -- no credential, no host address, no result.
struct LaunchItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// The program's file name as it was first shown (`LaunchCatalog.displayName(of:)`).
    var displayName: String
    var program: String
    /// Empty when the command had none.
    var arguments: String
    /// When it was last launched (Recent) or pinned (Pinned).
    var date: Date

    init(id: UUID = UUID(), displayName: String, program: String, arguments: String, date: Date) {
        self.id = id
        self.displayName = displayName
        self.program = program
        self.arguments = arguments
        self.date = date
    }

    /// The same command, whatever its id: Windows paths compare without case, arguments exactly.
    var key: String { program.lowercased() + "\u{1}" + arguments }

    var command: RunCommand { RunCommand(program: program, arguments: arguments) }
}

/// One host's lists. `recent` is newest first and may hold entries that are also pinned: the
/// Recent section hides those (design note §2), and unpinning one shows it again while it is still
/// in this record.
struct HostLaunchItems: Codable, Equatable, Sendable {
    var pinned: [LaunchItem] = []
    var recent: [LaunchItem] = []

    func isPinned(_ item: LaunchItem) -> Bool {
        pinned.contains { $0.key == item.key }
    }
}

/// ADR-0025 R-6: the start panel's pinned and recent programs, per host, in `launch-items.json`
/// beside the host records (`HostRecordStore`'s folder), written atomically on the main actor.
///
/// Rules (ADR-0025 §3.1 item 8):
///  - Every host has its own lists; removing a host removes its lists (`retainHosts(_:)`).
///  - A successful launch puts the command at the top of Recent (one entry per command); Recent
///    keeps at most `recentLimit` entries that are not pinned.
///  - Pinned keeps the order things were pinned in; pinning hides the entry from Recent.
///  - A file that does not decode is ignored (empty lists), never a crash; an entry with an empty
///    program or a NUL in its program or arguments is dropped on load (controller ruling R-a1-1:
///    invalid entries are discarded like a bad file is) -- a NUL would read as the shared execute
///    buffer's separator.
///  - Nothing else reads or writes the file.
@MainActor
final class LaunchItemStore {
    static let fileName = "launch-items.json"

    /// `~/Library/Application Support/<bundle-id>/launch-items.json`, next to `hosts.json`.
    static func defaultFileURL() -> URL? {
        HostRecordStore.defaultFileURL()?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    let fileURL: URL?
    let recentLimit: Int
    private(set) var hosts: [HostID: HostLaunchItems] = [:]
    /// Count of failed writes, for tests and diagnostics.
    private(set) var failedWrites = 0

    /// `fileURL == nil` keeps the lists in memory only (tests).
    init(fileURL: URL?, recentLimit: Int = StartPanelPolicy.recentLimit) {
        self.fileURL = fileURL
        self.recentLimit = recentLimit
        load()
    }

    private struct FileShape: Codable {
        var version: Int
        var hosts: [String: HostLaunchItems]
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

    /// R-a1-1 (ii): what a stored entry must be to be kept.
    static func isValid(_ item: LaunchItem) -> Bool {
        !item.program.isEmpty && !item.program.unicodeScalars.contains("\0") && !item.arguments.unicodeScalars.contains("\0")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let file = try? Self.decoder.decode(FileShape.self, from: data)
        else { return }
        for (account, lists) in file.hosts {
            guard let host = HostID(keychainAccount: account) else { continue }
            hosts[host] = HostLaunchItems(pinned: lists.pinned.filter(Self.isValid), recent: lists.recent.filter(Self.isValid))
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let shape = FileShape(version: 1, hosts: Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.keychainAccount, $0.value) }))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(shape)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            failedWrites += 1
        }
    }

    /// The lists of `host` (empty when it has none).
    func items(for host: HostID) -> HostLaunchItems {
        hosts[host] ?? HostLaunchItems()
    }

    /// A launch succeeded (ADR-0025 R-7: only `S_OK` writes here): the command moves to the top of
    /// Recent, keeping the entry's id when it was already there.
    func recordLaunch(_ command: RunCommand, displayName: String, for host: HostID, at date: Date) {
        var lists = items(for: host)
        let fresh = LaunchItem(displayName: displayName, program: command.program, arguments: command.arguments, date: date)
        var entry = fresh
        if let index = lists.recent.firstIndex(where: { $0.key == fresh.key }) {
            entry = lists.recent.remove(at: index)
            entry.date = date
        }
        lists.recent.insert(entry, at: 0)
        lists.recent = trimmed(lists)
        hosts[host] = lists
        persist()
    }

    /// Pins `item` at the end of Pinned (once per command).
    func pin(_ item: LaunchItem, for host: HostID, at date: Date) {
        var lists = items(for: host)
        guard !lists.isPinned(item) else { return }
        var pinned = item
        pinned.date = date
        lists.pinned.append(pinned)
        lists.recent = trimmed(lists)
        hosts[host] = lists
        persist()
    }

    /// Takes the command out of Pinned; it shows in Recent again if Recent still records it.
    func unpin(_ item: LaunchItem, for host: HostID) {
        var lists = items(for: host)
        lists.pinned.removeAll { $0.key == item.key }
        lists.recent = trimmed(lists)
        hosts[host] = lists
        persist()
    }

    /// "Remove from Recent".
    func forget(_ item: LaunchItem, for host: HostID) {
        var lists = items(for: host)
        lists.recent.removeAll { $0.key == item.key }
        hosts[host] = lists
        persist()
    }

    /// Drops the lists of every host not in `existing` (a removed host takes its programs along).
    func retainHosts(_ existing: Set<HostID>) {
        let gone = hosts.keys.filter { !existing.contains($0) }
        guard !gone.isEmpty else { return }
        for host in gone {
            hosts[host] = nil
        }
        persist()
    }

    /// Recent with at most `recentLimit` entries that are not pinned (pinned ones stay recorded).
    private func trimmed(_ lists: HostLaunchItems) -> [LaunchItem] {
        var kept: [LaunchItem] = []
        var unpinned = 0
        for item in lists.recent {
            if lists.isPinned(item) {
                kept.append(item)
            } else if unpinned < recentLimit {
                kept.append(item)
                unpinned += 1
            }
        }
        return kept
    }
}
