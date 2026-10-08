import Foundation
import MacdowsCore
import Testing

// ADR-0025 §3.1 item 8 / R-6: the start panel's lists, offline -- in memory, or in a temporary
// folder that is removed after each test. Placeholder programs only.

@MainActor
@Suite("LaunchItemStore (ADR-0025 R-6 / §3.1 item 8)", .serialized)
struct LaunchItemStoreTests {
    private static let notepad = RunCommand(program: #"C:\Windows\System32\notepad.exe"#, arguments: "")
    private static let example = RunCommand(program: #"C:\Tools\Example.exe"#, arguments: "/open")
    private static let calc = RunCommand(program: "calc.exe", arguments: "")
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func temporaryFile() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launch-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder.appendingPathComponent(LaunchItemStore.fileName), { try? FileManager.default.removeItem(at: folder) })
    }

    private static func record(_ store: LaunchItemStore, _ command: RunCommand, _ host: HostID, _ offset: TimeInterval = 0) {
        store.recordLaunch(command, displayName: LaunchCatalog.displayName(of: command.program), for: host, at: t0.addingTimeInterval(offset))
    }

    @Test("1. every host has its own lists")
    func perHost() {
        let store = LaunchItemStore(fileURL: nil)
        let a = HostID(), b = HostID()
        Self.record(store, Self.notepad, a)
        Self.record(store, Self.calc, b)
        #expect(store.items(for: a).recent.map(\.program) == [Self.notepad.program])
        #expect(store.items(for: b).recent.map(\.program) == ["calc.exe"])
        #expect(store.items(for: HostID()) == HostLaunchItems())
    }

    @Test("2. a launch moves its command to the top, one entry per command (path case ignored), keeping the entry's id")
    func dedupeToTop() throws {
        let store = LaunchItemStore(fileURL: nil)
        let host = HostID()
        Self.record(store, Self.notepad, host, 0)
        Self.record(store, Self.calc, host, 1)
        let id = try #require(store.items(for: host).recent.last?.id)
        Self.record(store, RunCommand(program: Self.notepad.program.uppercased(), arguments: ""), host, 2)
        let recent = store.items(for: host).recent
        #expect(recent.map(\.displayName) == ["notepad.exe", "calc.exe"])
        #expect(recent.first?.id == id && recent.first?.date == Self.t0.addingTimeInterval(2))
        // Different arguments are a different command.
        Self.record(store, RunCommand(program: Self.notepad.program, arguments: "a.txt"), host, 3)
        #expect(store.items(for: host).recent.count == 3)
    }

    @Test("3. Recent keeps at most recentLimit (8) entries")
    func limit() {
        let store = LaunchItemStore(fileURL: nil)
        let host = HostID()
        for index in 0..<10 {
            Self.record(store, RunCommand(program: "p\(index).exe", arguments: ""), host, TimeInterval(index))
        }
        #expect(store.recentLimit == StartPanelPolicy.recentLimit && store.recentLimit == 8)
        #expect(store.items(for: host).recent.map(\.program) == (2..<10).reversed().map { "p\($0).exe" })
    }

    @Test("4. Pinned keeps pin order, whatever is launched later")
    func pinnedOrderIsStable() throws {
        let store = LaunchItemStore(fileURL: nil)
        let host = HostID()
        for (index, command) in [Self.notepad, Self.example, Self.calc].enumerated() {
            Self.record(store, command, host, TimeInterval(index))
        }
        for program in [Self.calc.program, Self.notepad.program, Self.example.program] {
            let item = try #require(store.items(for: host).recent.first { $0.program == program })
            store.pin(item, for: host, at: Self.t0)
        }
        Self.record(store, Self.example, host, 10)
        #expect(store.items(for: host).pinned.map(\.program) == [Self.calc.program, Self.notepad.program, Self.example.program])
        // Pinning twice adds nothing.
        store.pin(try #require(store.items(for: host).pinned.first), for: host, at: Self.t0)
        #expect(store.items(for: host).pinned.count == 3)
    }

    @Test("5. pinning hides an entry from Recent, unpinning shows it again while it is recorded; Forget removes it")
    func pinHidesFromRecent() throws {
        let store = LaunchItemStore(fileURL: nil)
        let host = HostID()
        Self.record(store, Self.notepad, host, 0)
        Self.record(store, Self.calc, host, 1)
        let notepad = try #require(store.items(for: host).recent.first { $0.program == Self.notepad.program })
        store.pin(notepad, for: host, at: Self.t0)
        var sections = LaunchCatalog.sections(for: store.items(for: host))
        #expect(sections.pinned.map(\.title) == ["notepad.exe"] && sections.recent.map(\.title) == ["calc.exe"])
        store.unpin(notepad, for: host)
        sections = LaunchCatalog.sections(for: store.items(for: host))
        #expect(sections.pinned.isEmpty && sections.recent.map(\.title) == ["calc.exe", "notepad.exe"])
        store.forget(notepad, for: host)
        #expect(LaunchCatalog.sections(for: store.items(for: host)).recent.map(\.title) == ["calc.exe"])
        // The limit counts unpinned entries only: eight unpinned ones fit beside a pinned one.
        store.pin(try #require(store.items(for: host).recent.first), for: host, at: Self.t0)
        for index in 0..<8 {
            Self.record(store, RunCommand(program: "p\(index).exe", arguments: ""), host, TimeInterval(10 + index))
        }
        #expect(LaunchCatalog.sections(for: store.items(for: host)).recent.count == 8)
        #expect(store.items(for: host).recent.contains { $0.program == "calc.exe" }, "the pinned command is still recorded")
    }

    @Test("6. removing a host removes its lists")
    func removedHostTakesItsLists() throws {
        let (url, cleanUp) = try Self.temporaryFile()
        defer { cleanUp() }
        let store = LaunchItemStore(fileURL: url)
        let kept = HostID(), gone = HostID()
        Self.record(store, Self.notepad, kept)
        Self.record(store, Self.calc, gone)
        store.retainHosts([kept])
        #expect(store.items(for: gone) == HostLaunchItems())
        #expect(LaunchItemStore(fileURL: url).hosts.keys.sorted { $0.description < $1.description } == [kept])
    }

    @Test("7. a file that does not decode is ignored -- empty lists, no crash -- and the next write replaces it")
    func badJSON() throws {
        let (url, cleanUp) = try Self.temporaryFile()
        defer { cleanUp() }
        try Data("{ not json".utf8).write(to: url)
        let store = LaunchItemStore(fileURL: url)
        #expect(store.hosts.isEmpty)
        let host = HostID()
        Self.record(store, Self.notepad, host)
        #expect(LaunchItemStore(fileURL: url).items(for: host).recent.map(\.program) == [Self.notepad.program])
    }

    @Test("8. written atomically next to hosts.json, round-trips, and stores only name, program, arguments, time (and an id)")
    func roundTripAndShape() throws {
        let (url, cleanUp) = try Self.temporaryFile()
        defer { cleanUp() }
        let store = LaunchItemStore(fileURL: url)
        let host = HostID()
        Self.record(store, Self.example, host)
        store.pin(try #require(store.items(for: host).recent.first), for: host, at: Self.t0)
        let reloaded = LaunchItemStore(fileURL: url)
        #expect(reloaded.items(for: host) == store.items(for: host))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let hosts = try #require(json["hosts"] as? [String: Any])
        let lists = try #require(hosts[host.keychainAccount] as? [String: Any])
        let entry = try #require((lists["recent"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["id", "displayName", "program", "arguments", "date"])
        #expect(LaunchItemStore.defaultFileURL()?.lastPathComponent == "launch-items.json")
        #expect(LaunchItemStore.defaultFileURL()?.deletingLastPathComponent() == HostRecordStore.defaultFileURL()?.deletingLastPathComponent())
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UI/StartPanel/LaunchItemStore.swift"), encoding: .utf8)
        #expect(source.contains("try data.write(to: fileURL, options: [.atomic])"))
    }

    @Test("ruling R-a1-1 (ii): stored entries with a NUL in the program or arguments, or an empty program, are dropped on load")
    func invalidEntriesAreDropped() throws {
        let (url, cleanUp) = try Self.temporaryFile()
        defer { cleanUp() }
        let host = HostID()
        func entry(_ program: String, _ arguments: String) -> String {
            #"{ "id" : "\#(UUID().uuidString)", "displayName" : "x", "program" : "\#(program)", "arguments" : "\#(arguments)", "date" : "2027-01-15T08:00:00Z" }"#
        }
        let file = """
        { "version" : 1, "hosts" : { "\(host.keychainAccount)" : {
          "pinned" : [ \(entry("pin\\u0000ned.exe", "")), \(entry("kept-pinned.exe", "")) ],
          "recent" : [ \(entry("ok.exe", "a")), \(entry("args.exe", "a\\u0000b")), \(entry("", "x")) ] } } }
        """
        try Data(file.utf8).write(to: url)
        let store = LaunchItemStore(fileURL: url)
        #expect(store.items(for: host).pinned.map(\.program) == ["kept-pinned.exe"])
        #expect(store.items(for: host).recent.map(\.program) == ["ok.exe"])
        #expect(!LaunchItemStore.isValid(LaunchItem(displayName: "", program: "a\u{0}", arguments: "", date: Self.t0)))
        #expect(LaunchItemStore.isValid(LaunchItem(displayName: "", program: "a", arguments: "b c", date: Self.t0)))
    }
}

@MainActor
@Suite("LaunchCatalog (design note §2)")
struct LaunchCatalogTests {
    @Test("display name is the last path component, original case; bare names and ||alias as typed")
    func displayName() {
        #expect(LaunchCatalog.displayName(of: #"C:\Windows\System32\NOTEPAD.EXE"#) == "NOTEPAD.EXE")
        #expect(LaunchCatalog.displayName(of: "notepad") == "notepad")
        #expect(LaunchCatalog.displayName(of: "||Example") == "||Example")
        #expect(LaunchCatalog.parentFolder(of: #"C:\Tools\Example.exe"#) == "Tools")
        #expect(LaunchCatalog.parentFolder(of: "notepad") == nil)
        #expect(LaunchCatalog.fullCommand(program: #"C:\Program Files\Example\Example.exe"#, arguments: "/x")
                == #""C:\Program Files\Example\Example.exe" /x"#)
    }

    @Test("same title twice in a section: both get their parent folder; arguments follow; the full command is the help")
    func duplicateTitlesGetTheirFolder() {
        let now = Date(timeIntervalSince1970: 0)
        let lists = HostLaunchItems(pinned: [], recent: [
            LaunchItem(displayName: "Example.exe", program: #"C:\Tools\Example.exe"#, arguments: "", date: now),
            LaunchItem(displayName: "Example.exe", program: #"D:\Other\Example.exe"#, arguments: "/a", date: now),
            LaunchItem(displayName: "calc.exe", program: "calc.exe", arguments: "", date: now),
        ])
        let recent = LaunchCatalog.sections(for: lists).recent
        #expect(recent.map(\.qualifier) == ["Tools", "Other", nil])
        #expect(recent[1].arguments == "/a" && recent[1].fullCommand == #"D:\Other\Example.exe /a"#)
    }
}
