import Foundation
import MacdowsCore
import Testing

// ADR-0024 D-10 ⑤: the chain rules of a Connect press, with the store doubles -- one credential
// read per press, none for a refused address or an unreadable pin, none after a certificate
// confirmation (D-2′ Q-a), and D-3′'s two refusals never reaching the first-use sheet.

@Suite("ADR-0024 D-10 ⑤ — ConnectFlow")
struct ConnectFlowTests {
    let host = HostID()
    static let allowed: @Sendable (String) -> LabBoundary.Verdict = { _ in .allowed }

    func preflight(credentials: InMemoryCredentialStore, pins: InMemoryPinStore, pinned: Bool = false,
                   remembers: Bool = true, boundary: (String) -> LabBoundary.Verdict = Self.allowed) -> ConnectFlow.Preflight {
        ConnectFlow.preflight(host: host, address: "192.0.2.10", recordSaysPinned: pinned, remembersPassword: remembers,
                              credentials: credentials, pins: pins, boundary: boundary)
    }

    @Test("a refused address reads nothing from the keychain")
    func boundaryFirst() {
        let credentials = InMemoryCredentialStore(), pins = InMemoryPinStore()
        let result = preflight(credentials: credentials, pins: pins, boundary: { _ in .refused(.emptyHost) })
        guard case .refusedByBoundary = result else { Issue.record("\(result)"); return }
        #expect(credentials.readCount == 0)
    }

    @Test("D-3′: an unreadable pin item stops before the password is read, and never becomes first use")
    func pinUnavailable() {
        let credentials = InMemoryCredentialStore(), pins = InMemoryPinStore()
        pins.unreadable = [host]
        let result = preflight(credentials: credentials, pins: pins)
        guard case .pinUnavailable = result else { Issue.record("\(result)"); return }
        #expect(credentials.readCount == 0)
    }

    @Test("D-3′: a missing pin item on a pinned record is pin lost (the snapshot accepts nothing)")
    func pinLost() {
        let result = preflight(credentials: InMemoryCredentialStore(), pins: InMemoryPinStore(), pinned: true)
        guard case .ready(let context, _, _) = result else { Issue.record("\(result)"); return }
        #expect(context == .pinLost)
        #expect(ConnectFlow.trustSnapshot(for: context) == nil)
    }

    @Test("one press reads the credential exactly once; a host that does not remember never reads it")
    func oneReadPerPress() {
        let credentials = InMemoryCredentialStore(), pins = InMemoryPinStore()
        try? credentials.save(SessionSecret(bytes: [7]), for: host, displayName: "PC")
        guard case .ready(_, let secret?, nil) = preflight(credentials: credentials, pins: pins) else { Issue.record("no secret"); return }
        #expect(secret.count == 1)
        #expect(credentials.readCount == 1)
        _ = preflight(credentials: credentials, pins: pins, remembers: false)
        #expect(credentials.readCount == 1)
    }

    @Test("D-1: a keychain read failure is 'not saved' with its status -- the Password sheet, never a file")
    func credentialFailureIsNotSaved() {
        let credentials = InMemoryCredentialStore()
        credentials.readFailure = -25308
        guard case .ready(_, nil, -25308) = preflight(credentials: credentials, pins: InMemoryPinStore()) else {
            Issue.record("expected no credential with status"); return
        }
    }

    @Test("D-2′ Q-a: confirming the certificate writes the pin and re-uses the chain -- zero further credential reads")
    func confirmationDoesNotRefetch() throws {
        let credentials = InMemoryCredentialStore(), pins = InMemoryPinStore()
        try credentials.save(SessionSecret(bytes: [7]), for: host, displayName: "PC")
        guard case .ready(let context, _, _) = preflight(credentials: credentials, pins: pins) else { Issue.record("not ready"); return }
        #expect(context == .firstUse)
        let verdict = CertificateDecision.verdict(for: context, presented: TestFingerprints.a)
        let (next, confirmation) = try ConnectFlow.confirm(verdict, subject: "CN=x", issuer: "CN=x", host: host, displayName: "PC", pins: pins).get()
        #expect(next == .pinned(TestFingerprints.a))
        #expect(confirmation == .trusted(TestFingerprints.a))
        #expect(pins.records[host]?.source == .trusted)
        #expect(credentials.readCount == 1, "the confirmation path has no credential store at all")
    }

    @Test("a changed certificate (pin, preset or lost) is confirmed as a Replace")
    func replace() throws {
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(sha256: TestFingerprints.a), for: host)
        let verdict = CertificateDecision.verdict(for: .pinned(TestFingerprints.a), presented: TestFingerprints.b)
        let (next, confirmation) = try ConnectFlow.confirm(verdict, subject: nil, issuer: nil, host: host, displayName: "PC", pins: pins).get()
        #expect(next == .pinned(TestFingerprints.b))
        #expect(confirmation == .replaced(old: TestFingerprints.a, new: TestFingerprints.b))
        #expect(pins.records[host]?.previous == TestFingerprints.a)
        guard case .failure(.notConfirmable) = ConnectFlow.confirm(.unsupportedRoute, subject: nil, issuer: nil, host: host, displayName: "PC", pins: pins) else {
            Issue.record("a route refusal is not confirmable"); return
        }
    }

    @Test("a matching preset is written as the pin after the handshake (source preset)")
    func presetWrite() {
        let pins = InMemoryPinStore()
        pins.seed(PinRecord(expected: TestFingerprints.a), for: host)
        #expect(ConnectFlow.writePresetPin(TestFingerprints.a, host: host, displayName: "PC", pins: pins))
        #expect(pins.records[host]?.sha256 == TestFingerprints.a)
        #expect(pins.records[host]?.source == .preset)
        #expect(pins.records[host]?.expected == TestFingerprints.a)
    }

    @Test("first-connect failure classes: certificate rejection wins over the code; DNS / TCP unreachable; NLA sign-in")
    func failureKinds() {
        let connect = 0x0002_0000
        #expect(ConnectFlow.failureKind(errorCode: connect | 0x08, certificateRejected: true) == .certificate)
        #expect(ConnectFlow.failureKind(errorCode: connect | 0x08, certificateRejected: false) == .other)
        for code in [0x04, 0x05, 0x06, 0x0D] {
            #expect(ConnectFlow.failureKind(errorCode: connect | code, certificateRejected: false) == .unreachable)
        }
        for code in [0x09, 0x14, 0x15, 0x16] {
            #expect(ConnectFlow.failureKind(errorCode: connect | code, certificateRejected: false) == .signIn)
        }
        #expect(ConnectFlow.failureKind(errorCode: -5, certificateRejected: false) == .other)
    }
}
