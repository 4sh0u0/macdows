import Foundation
import MacdowsCore
import Testing

// UI slice ①: host records (ADR-0024 D-3′ `pinned`, D-6 recent log) and the keychain-side host
// operations (UI-1 spec §5.1 ④ Remove order, §5.3 preset edits), offline with the store doubles.

@MainActor
@Suite("UI slice ① — HostRecordStore")
struct HostRecordStoreTests {
    static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macdows-hosts-\(UUID().uuidString).json")
    }

    @Test("records round-trip through the JSON file, which carries no password and no fingerprint field")
    func roundTrip() throws {
        let url = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostRecordStore(fileURL: url)
        let record = HostRecord(displayName: "Office PC", address: "workstation.example", userName: "user")
        store.upsert(record)
        store.setPinned(true, for: record.id)
        let reread = HostRecordStore(fileURL: url)
        #expect(reread.records.count == 1)
        #expect(reread.records.first?.id == record.id)
        #expect(reread.records.first?.pinned == true)
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["\"password\"", "sha256", "expected", "fingerprint", "secret"] {
            #expect(!text.lowercased().contains(forbidden), "\(forbidden)")
        }
        #expect(text.contains("\"remembersPassword\""), "only the Remember choice, never the password")
    }

    @Test("the recent log keeps the newest 20 rows per host (ADR-0024 D-6)")
    func recentLimit() {
        let store = HostRecordStore(fileURL: nil)
        let record = HostRecord(displayName: "", address: "192.0.2.10", userName: "user")
        store.upsert(record)
        for index in 0..<25 {
            store.note(.connected, for: record.id, at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let recent = store.record(record.id)?.recent ?? []
        #expect(recent.count == HostRecord.recentLimit)
        #expect(recent.first?.date == Date(timeIntervalSince1970: 24), "newest first")
    }

    @Test("after Reset All Pins every record is unpinned and each pinned one logs the reset (ADR-0024 D-6)")
    func resetUnpinsEveryRecord() {
        let store = HostRecordStore(fileURL: nil)
        let pinned = HostRecord(displayName: "A", address: "a.example", userName: "u", pinned: true)
        let unpinned = HostRecord(displayName: "B", address: "b.example", userName: "u")
        store.upsert(pinned)
        store.upsert(unpinned)
        store.noteAllPinsReset()
        #expect(store.records.allSatisfy { !$0.pinned })
        #expect(store.record(pinned.id)?.recent.first?.event == .allPinsReset)
        #expect(store.record(unpinned.id)?.recent.isEmpty == true)
    }
}

@Suite("UI slice ① — HostActions (keychain side of Remove / Save / Reset)")
struct HostActionsTests {
    @Test("Remove deletes the pin first, then the credential; the record is the caller's last step")
    func removeOrder() {
        let credentials = InMemoryCredentialStore()
        let pins = InMemoryPinStore()
        let host = HostID()
        try? credentials.save(SessionSecret(bytes: [1, 2]), for: host, displayName: "PC")
        pins.seed(PinRecord(sha256: TestFingerprints.a), for: host)
        let actions = HostActions(credentials: credentials, pins: pins)
        #expect((try? actions.removeKeychainItems(for: host).get()) != nil)
        #expect(pins.records[host] == nil)
        #expect(!credentials.has(host))
    }

    @Test("a failed pin delete stops Remove before the credential is touched")
    func removeStopsAtPin() {
        let credentials = InMemoryCredentialStore()
        let pins = InMemoryPinStore()
        pins.deleteFailure = -25293
        let host = HostID()
        try? credentials.save(SessionSecret(bytes: [1]), for: host, displayName: "PC")
        let result = HostActions(credentials: credentials, pins: pins).removeKeychainItems(for: host)
        guard case .failure(.pin(status: -25293)) = result else { Issue.record("\(result)"); return }
        #expect(credentials.deleteCount == 0)
        #expect(credentials.has(host))
    }

    @Test("a failed credential delete is reported (the record then stays)")
    func removeStopsAtCredential() {
        let credentials = InMemoryCredentialStore()
        credentials.deleteFailure = -25293
        let result = HostActions(credentials: credentials, pins: InMemoryPinStore()).removeKeychainItems(for: HostID())
        guard case .failure(.credential(status: -25293)) = result else { Issue.record("\(result)"); return }
    }

    @MainActor
    @Test("HostOperations.remove keeps the record when the keychain half fails, and removes it otherwise")
    func removeRecordOnlyOnSuccess() async {
        let store = HostRecordStore(fileURL: nil)
        let record = HostRecord(displayName: "A", address: "a.example", userName: "u")
        store.upsert(record)
        let failingPins = InMemoryPinStore()
        failingPins.deleteFailure = -1
        let failed = await HostOperations.remove(record.id, actions: HostActions(credentials: InMemoryCredentialStore(), pins: failingPins), store: store)
        #expect(failed != nil)
        #expect(store.record(record.id) != nil)
        let ok = await HostOperations.remove(record.id, actions: HostActions(credentials: InMemoryCredentialStore(), pins: InMemoryPinStore()), store: store)
        #expect(ok == nil)
        #expect(store.record(record.id) == nil)
    }

    @Test("Save: Remember off deletes a saved password; a typed password with Remember on is saved and then wiped")
    func editorCredential() {
        let credentials = InMemoryCredentialStore()
        let pins = InMemoryPinStore()
        let host = HostID()
        let actions = HostActions(credentials: credentials, pins: pins)
        let typed = SessionSecret(bytes: Array("pw".utf8))
        #expect(actions.applyEditorChanges(.init(host: host, displayName: "PC", newPassword: typed, remember: true, expected: nil)).isEmpty)
        #expect(credentials.has(host))
        #expect(typed.isWiped)
        #expect(actions.applyEditorChanges(.init(host: host, displayName: "PC", newPassword: nil, remember: false, expected: nil)).isEmpty)
        #expect(!credentials.has(host))
    }

    @Test("Save: a preset edit goes through setExpected and never touches the pin; an unreadable pin item is reported, not overwritten")
    func editorPreset() {
        let pins = InMemoryPinStore()
        let host = HostID()
        pins.seed(PinRecord(sha256: TestFingerprints.a, source: .trusted), for: host)
        let actions = HostActions(credentials: InMemoryCredentialStore(), pins: pins)
        #expect(actions.applyEditorChanges(.init(host: host, displayName: "PC", newPassword: nil, remember: true, expected: .some(TestFingerprints.b))).isEmpty)
        #expect(pins.records[host]?.sha256 == TestFingerprints.a)
        #expect(pins.records[host]?.expected == TestFingerprints.b)
        pins.unreadable = [host]
        let failures = actions.applyEditorChanges(.init(host: host, displayName: "PC", newPassword: nil, remember: true, expected: .some(nil)))
        #expect(failures.presetStatus != nil)
        pins.unreadable = []
        #expect(pins.records[host]?.expected == TestFingerprints.b)
    }

    @MainActor
    @Test("Reset All Pins: presets kept, pins cleared, records unpinned (ADR-0024 D-6′ E-a)")
    func resetAllPins() async throws {
        let store = HostRecordStore(fileURL: nil)
        let record = HostRecord(displayName: "A", address: "a.example", userName: "u", pinned: true)
        store.upsert(record)
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(sha256: TestFingerprints.a, expected: TestFingerprints.b), for: record.id)
        let outcome = await HostOperations.resetAllPins(actions: HostActions(credentials: InMemoryCredentialStore(), pins: pins), store: store)
        #expect(outcome == PinResetOutcome(cleared: [record.id], failed: false))
        #expect(pins.records[record.id] == PinRecord(expected: TestFingerprints.b))
        #expect(store.record(record.id)?.pinned == false)
    }

    @Test("gate r1 m-11: the Remember bit after Save says Saved in Keychain only when a password is known to be there")
    func rememberBitFollowsTheKeychain() {
        typealias A = HostActions
        #expect(A.remembersPassword(remember: true, typedPassword: true, wasRemembering: false, credentialFailed: false))
        #expect(A.remembersPassword(remember: true, typedPassword: false, wasRemembering: true, credentialFailed: false))
        #expect(!A.remembersPassword(remember: true, typedPassword: false, wasRemembering: false, credentialFailed: false),
                "a new host with Remember ticked but no password is asked each time")
        #expect(!A.remembersPassword(remember: true, typedPassword: true, wasRemembering: true, credentialFailed: true),
                "a failed save is not remembered")
        #expect(!A.remembersPassword(remember: false, typedPassword: true, wasRemembering: true, credentialFailed: false))
    }
}
