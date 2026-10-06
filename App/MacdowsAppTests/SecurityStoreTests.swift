import Foundation
import MacdowsCore
import Security
import Testing

// ADR-0024 D-10 ⑤ (store half) and ⑧: the pin rotation operations against an in-memory store,
// the chain's password bytes, and -- opt-in, on this Mac only -- the real keychain through a
// per-run `.test` service that never touches the App's own items.

@Suite("ADR-0024 D-2 — SessionSecret")
struct SessionSecretTests {
    @Test("the bytes are handed over without a copy and wiped to nothing")
    func wipe() {
        let secret = SessionSecret(bytes: Array("hunter2".utf8))
        #expect(secret.count == 7)
        let seen = secret.withUnsafeData { String(decoding: $0, as: UTF8.self) }
        #expect(seen == "hunter2")
        secret.wipe()
        #expect(secret.isWiped)
        #expect(secret.isEmpty)
        #expect(secret.withUnsafeData { $0.isEmpty })
        secret.wipe()
    }
}

@Suite("ADR-0024 D-3 / D-6 — pin rotation, store level")
struct PinRotationTests {
    let host = HostID()
    let a = TestFingerprints.a
    let b = TestFingerprints.b

    @Test("Trust and Pin keeps the preset; the record says who pinned it")
    func trustKeepsPreset() throws {
        let store = InMemoryPinStore()
        store.seed(PinRecord(expected: b), for: host)
        try store.pin(a, source: .trusted, subject: "CN=x", issuer: "CN=x", for: host, displayName: "PC")
        let record = try #require(store.records[host])
        #expect(record.sha256 == a)
        #expect(record.expected == b)
        #expect(record.source == .trusted)
        #expect(record.pinnedAt != nil)
    }

    @Test("Replace keeps the superseded pin as previous; on a missing item (pin lost) it adds one")
    func replace() throws {
        let store = InMemoryPinStore()
        store.seed(PinRecord(sha256: a, source: .trusted), for: host)
        try store.replacePin(with: b, subject: nil, issuer: nil, for: host, displayName: "PC")
        #expect(store.records[host]?.sha256 == b)
        #expect(store.records[host]?.previous == a)
        #expect(store.records[host]?.source == .replaced)

        let lost = HostID()
        try store.replacePin(with: a, subject: nil, issuer: nil, for: lost, displayName: "PC")
        #expect(store.records[lost]?.sha256 == a)
        #expect(store.records[lost]?.previous == nil)
    }

    @Test("editing the preset never touches the pin; clearing the last value deletes the item")
    func setExpected() throws {
        let store = InMemoryPinStore()
        store.seed(PinRecord(sha256: a, source: .trusted), for: host)
        try store.setExpected(b, for: host, displayName: "PC")
        #expect(store.records[host]?.sha256 == a)
        #expect(store.records[host]?.expected == b)
        try store.setExpected(nil, for: host, displayName: "PC")
        #expect(store.records[host]?.sha256 == a)

        let presetOnly = HostID()
        store.seed(PinRecord(expected: a), for: presetOnly)
        try store.setExpected(nil, for: presetOnly, displayName: "PC")
        #expect(store.records[presetOnly] == nil)
    }

    @Test("D-3′: a read-modify-write never writes over an item it could not read")
    func unreadableIsNeverOverwritten() throws {
        let store = InMemoryPinStore()
        store.seed(PinRecord(sha256: a), for: host)
        store.unreadable = [host]
        #expect(throws: PinStoreError.self) { try store.setExpected(b, for: host, displayName: "PC") }
        #expect(throws: PinStoreError.self) { try store.pin(b, source: .trusted, subject: nil, issuer: nil, for: host, displayName: "PC") }
        #expect(throws: PinStoreError.self) { _ = try store.resetAllPins(displayName: { _ in "PC" }) }
        #expect(store.writeCount == 0)
        #expect(store.records[host]?.sha256 == a)
    }

    @Test("D-6′ E-a: Reset All Pins clears every pin and keeps every preset")
    func resetKeepsPresets() throws {
        let store = InMemoryPinStore()
        let pinnedWithPreset = HostID(), pinnedOnly = HostID(), presetOnly = HostID()
        store.seed(PinRecord(sha256: a, expected: b, pinnedAt: Date(), source: .preset, previous: b), for: pinnedWithPreset)
        store.seed(PinRecord(sha256: a, source: .trusted), for: pinnedOnly)
        store.seed(PinRecord(expected: b), for: presetOnly)
        let cleared = try store.resetAllPins(displayName: { _ in "PC" })
        #expect(Set(cleared) == [pinnedWithPreset, pinnedOnly])
        #expect(store.records[pinnedWithPreset] == PinRecord(expected: b))
        #expect(store.records[pinnedOnly] == nil, "an item with nothing left is deleted")
        #expect(store.records[presetOnly] == PinRecord(expected: b))
    }

    @Test("the pin read result feeds the decision table without turning a failure into 'no pin'")
    func decisionInput() {
        #expect(PinReadResult.missing.decisionInput == .missing)
        #expect(PinReadResult.unavailable(status: -25308).decisionInput == .unavailable)
        #expect(PinReadResult.found(PinRecord(sha256: a, expected: b)).decisionInput == .found(pinned: a, expected: b))
    }
}

/// The App's own source file, comment lines dropped and whitespace folded (source-shape pins).
private func securitySource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
}

/// Gate r1 I-1: the keychain layer itself, offline -- the status-to-result mapping both stores
/// rely on (D-3′: a failed read is never "missing") and the shape of every query (D-1: no iCloud
/// sync, no data-protection keychain flag, no access-control object).
@Suite("ADR-0024 D-1 / D-3′ — keychain layer: status mapping and query shape")
struct KeychainLayerTests {
    /// errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed, errSecMissingEntitlement,
    /// errSecDecode -- the statuses probe K and the ACL prompt can produce.
    static let failures: [OSStatus] = [-25308, -128, -25293, -34018, errSecDecode]

    @Test("classify: only errSecItemNotFound is notFound; success without Data is a decode failure")
    func classify() {
        #expect(KeychainItems.classify(status: errSecItemNotFound, data: nil) == .notFound)
        #expect(KeychainItems.classify(status: errSecSuccess, data: Data([1, 2]) as CFData) == .found(Data([1, 2])))
        #expect(KeychainItems.classify(status: errSecSuccess, data: nil) == .failed(errSecDecode))
        #expect(KeychainItems.classify(status: errSecSuccess, data: "not data" as CFString) == .failed(errSecDecode))
        for status in Self.failures {
            #expect(KeychainItems.classify(status: status, data: nil) == .failed(status), "\(status)")
        }
    }

    @Test("pin store: a failed read or an undecodable record is unavailable, never missing")
    func pinResult() throws {
        #expect(KeychainPinStore.result(from: .notFound) == .missing)
        for status in Self.failures {
            #expect(KeychainPinStore.result(from: .failed(status)) == .unavailable(status: status), "\(status)")
        }
        #expect(KeychainPinStore.result(from: .found(Data("{not json".utf8))) == .unavailable(status: errSecDecode))
        #expect(KeychainPinStore.result(from: .found(Data(#"{"sha256":"zz"}"#.utf8))) == .unavailable(status: errSecDecode))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = PinRecord(sha256: TestFingerprints.a, expected: TestFingerprints.b, source: .trusted)
        #expect(KeychainPinStore.result(from: .found(try encoder.encode(record))) == .found(record))
    }

    @Test("credential store: a failed read is unavailable (status kept), only a missing item is notSaved")
    func credentialResult() {
        guard case .notSaved = KeychainCredentialStore.result(from: .notFound) else {
            Issue.record("notFound must be notSaved"); return
        }
        for status in Self.failures {
            guard case .unavailable(let kept) = KeychainCredentialStore.result(from: .failed(status)) else {
                Issue.record("\(status) must be unavailable"); continue
            }
            #expect(kept == status)
        }
        guard case .found(let secret) = KeychainCredentialStore.result(from: .found(Data("pw".utf8))) else {
            Issue.record("found must carry the secret"); return
        }
        #expect(secret.withUnsafeData { String(decoding: $0, as: UTF8.self) } == "pw")
    }

    @Test("every query: generic password, the given service / account, never synchronizable, no DP flag, no access control")
    func queryShape() throws {
        let queries = [
            KeychainItems.baseQuery(service: "svc.test", account: "acct"),
            KeychainItems.readQuery(service: "svc.test", account: "acct"),
            KeychainItems.baseQuery(service: "svc.test", account: nil),
        ]
        for query in queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "svc.test")
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecUseDataProtectionKeychain as String] == nil)
            #expect(query[kSecAttrAccessControl as String] == nil)
            #expect(query[kSecAttrAccessible as String] == nil)
        }
        #expect(queries[0][kSecAttrAccount as String] as? String == "acct")
        #expect(queries[2][kSecAttrAccount as String] == nil)
        #expect(queries[1][kSecReturnData as String] as? Bool == true)
        #expect(queries[1][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(queries[0].count == 4 && queries[1].count == 6 && queries[2].count == 3, "nothing else is in any query")

        // Every SecItem call builds on baseQuery: no second dictionary can switch these on.
        let code = try securitySource("App/Security/KeychainItems.swift")
        #expect(code.components(separatedBy: "kSecAttrSynchronizable").count - 1 == 1)
        #expect(!code.contains("kSecUseDataProtectionKeychain"))
        #expect(!code.contains("kSecAttrAccessControl"))
        #expect(code.components(separatedBy: "kSecClass as String").count - 1 == 1)
    }

    @Test("SessionSecret.wipe overwrites through memset_s before it empties the buffer")
    func wipeUsesMemsetS() throws {
        let code = try securitySource("App/Security/SessionSecret.swift")
        let wipe = try #require(code.range(of: "func wipe() {"))
        let memset = try #require(code.range(of: "_ = memset_s(base, raw.count, 0, raw.count)", range: wipe.upperBound..<code.endIndex))
        let removeAll = try #require(code.range(of: "bytes.removeAll()", range: wipe.upperBound..<code.endIndex))
        #expect(memset.lowerBound < removeAll.lowerBound)
        #expect(code.components(separatedBy: "memset_s(").count - 1 == 1)
    }

    @Test("gate r1 m-5: keychain work runs on one serial queue, off the caller's thread")
    func keychainQueue() async throws {
        let onQueue = await KeychainQueue.run { () -> Bool in
            dispatchPrecondition(condition: .onQueue(KeychainQueue.queue))
            return !Thread.isMainThread
        }
        #expect(onQueue)
        await #expect(throws: KeychainItems.WriteError.self) {
            try await KeychainQueue.runThrowing { () -> Int in throw KeychainItems.WriteError(status: -1) }
        }
        // Serial: two bodies started together never overlap.
        let overlap = OverlapProbe()
        async let first: Void = KeychainQueue.run { overlap.enter(); Thread.sleep(forTimeInterval: 0.05); overlap.leave() }
        async let second: Void = KeychainQueue.run { overlap.enter(); Thread.sleep(forTimeInterval: 0.05); overlap.leave() }
        _ = await (first, second)
        #expect(overlap.maximum == 1)
    }
}

private final class OverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0
    func enter() { lock.lock(); current += 1; maximum = max(maximum, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
}

/// ADR-0024 D-10 ⑧: the real keychain, through per-run `.test` services, deleted before the test
/// ends. Opt-in (`TEST_RUNNER_KEYCHAIN_SMOKE=1 xcodebuild test ...`): skipped on CI and by default,
/// because an ad-hoc test bundle is a new binary on every build and the file-based keychain would
/// ask a human about any item a previous build created (probe K).
@Suite("ADR-0024 D-10 ⑧ — real keychain smoke (opt-in, this Mac only)",
       .enabled(if: ProcessInfo.processInfo.environment["KEYCHAIN_SMOKE"] == "1"))
struct KeychainSmokeTests {
    @Test("credential and pin items: write, read, classify a missing item, delete")
    func roundTrip() throws {
        let run = UUID().uuidString
        let credentials = KeychainCredentialStore(service: "dev.haru.macdows.apptests.\(run).rdp.test")
        let pins = KeychainPinStore(service: "dev.haru.macdows.apptests.\(run).cert-pin.test")
        let host = HostID()
        defer {
            try? credentials.delete(for: host)
            try? pins.delete(for: host)
        }
        guard case .notSaved = credentials.read(for: host) else { Issue.record("expected notSaved"); return }
        #expect(pins.read(for: host) == .missing)

        try credentials.save(SessionSecret(bytes: Array("smoke".utf8)), for: host, displayName: "Smoke")
        guard case .found(let secret) = credentials.read(for: host) else { Issue.record("expected found"); return }
        #expect(secret.withUnsafeData { String(decoding: $0, as: UTF8.self) } == "smoke")

        try pins.pin(TestFingerprints.a, source: .trusted, subject: nil, issuer: nil, for: host, displayName: "Smoke")
        try pins.setExpected(TestFingerprints.b, for: host, displayName: "Smoke")
        #expect(pins.read(for: host) == .found(try pins.currentRecord(for: host)))
        #expect(try pins.hostsWithItems() == [host])
        let cleared = try pins.resetAllPins(displayName: { _ in "Smoke" })
        #expect(cleared == [host])
        guard case .found(let record) = pins.read(for: host) else { Issue.record("expected found"); return }
        #expect(record.sha256 == nil && record.expected == TestFingerprints.b)

        try credentials.delete(for: host)
        try pins.delete(for: host)
        guard case .notSaved = credentials.read(for: host) else { Issue.record("expected notSaved after delete"); return }
        #expect(pins.read(for: host) == .missing)
        try credentials.delete(for: host)
    }
}
