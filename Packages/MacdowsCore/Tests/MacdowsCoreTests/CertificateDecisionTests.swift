import Testing

@testable import MacdowsCore

/// ADR-0024 D-10 ①: the D-5 decision table and the D-3′ rows, every cell.
@Suite("CertificateDecision (ADR-0024 D-5 / D-3′)")
struct CertificateDecisionTests {
    static let a = CertificateFingerprint(canonical: String(repeating: "a", count: 64))!
    static let b = CertificateFingerprint(canonical: String(repeating: "b", count: 64))!
    static let c = CertificateFingerprint(canonical: String(repeating: "c", count: 64))!

    // MARK: - Pre-start half

    @Test("D-3′: a pin READ failure never connects, whatever the record says")
    func pinUnavailableRefuses() {
        #expect(CertificateDecision.plan(pin: .unavailable, recordSaysPinned: false) == .refusePinUnavailable)
        #expect(CertificateDecision.plan(pin: .unavailable, recordSaysPinned: true) == .refusePinUnavailable)
    }

    @Test("D-3′: a MISSING pin item on a record that says pinned is pin lost, never first use")
    func pinLostIsNotFirstUse() {
        #expect(CertificateDecision.plan(pin: .missing, recordSaysPinned: true) == .connect(.pinLost))
        #expect(CertificateDecision.plan(pin: .found(pinned: nil, expected: Self.a), recordSaysPinned: true) == .connect(.pinLost),
                "a preset does not rescue a lost pin")
        #expect(CertificateDecision.plan(pin: .missing, recordSaysPinned: false) == .connect(.firstUse))
    }

    @Test("D-5: a pin wins over a preset; a preset alone is the preset context; nothing is first use")
    func contexts() {
        #expect(CertificateDecision.plan(pin: .found(pinned: Self.a, expected: Self.b), recordSaysPinned: true) == .connect(.pinned(Self.a)))
        #expect(CertificateDecision.plan(pin: .found(pinned: Self.a, expected: nil), recordSaysPinned: false) == .connect(.pinned(Self.a)))
        #expect(CertificateDecision.plan(pin: .found(pinned: nil, expected: Self.b), recordSaysPinned: false) == .connect(.preset(Self.b)))
        #expect(CertificateDecision.plan(pin: .found(pinned: nil, expected: nil), recordSaysPinned: false) == .connect(.firstUse))
    }

    @Test("the bridge's snapshot: pin, else preset; pin lost and first use accept nothing")
    func acceptedFingerprint() {
        #expect(CertificateDecision.acceptedFingerprint(for: .pinned(Self.a)) == Self.a)
        #expect(CertificateDecision.acceptedFingerprint(for: .preset(Self.b)) == Self.b)
        #expect(CertificateDecision.acceptedFingerprint(for: .pinLost) == nil)
        #expect(CertificateDecision.acceptedFingerprint(for: .firstUse) == nil)
    }

    // MARK: - Post-rejection half

    @Test("D-5 table, every cell")
    func table() {
        typealias D = CertificateDecision
        #expect(D.verdict(for: .pinned(Self.a), presented: Self.a) == .accept(writePresetPin: false))
        #expect(D.verdict(for: .pinned(Self.a), presented: Self.b) == .changed(old: Self.a, oldSource: .pin, presented: Self.b))
        #expect(D.verdict(for: .preset(Self.a), presented: Self.a) == .accept(writePresetPin: true))
        #expect(D.verdict(for: .preset(Self.a), presented: Self.b) == .changed(old: Self.a, oldSource: .preset, presented: Self.b),
                "a preset mismatch is a CHANGE, never first use")
        #expect(D.verdict(for: .pinLost, presented: Self.a) == .changed(old: nil, oldSource: .lost, presented: Self.a))
        #expect(D.verdict(for: .firstUse, presented: Self.c) == .firstUse(presented: Self.c))
        #expect(D.verdict(for: .pinned(Self.a), presented: nil) == .unreadableCertificate)
        #expect(D.verdict(for: .pinned(Self.a), presented: Self.a, unsupportedRoute: true) == .unsupportedRoute,
                "a redirect / gateway route is refused even with a matching fingerprint")
    }

    @Test("the snapshot and the table agree: the bridge accepts exactly when the table says accept")
    func snapshotAgreesWithTable() {
        let contexts: [CertificateDecision.Context] = [.pinned(Self.a), .preset(Self.a), .pinLost, .firstUse]
        for context in contexts {
            for presented in [Self.a, Self.b] {
                let bridgeAccepts = CertificateDecision.acceptedFingerprint(for: context) == presented
                let tableAccepts: Bool
                if case .accept = CertificateDecision.verdict(for: context, presented: presented) { tableAccepts = true } else { tableAccepts = false }
                #expect(bridgeAccepts == tableAccepts, "\(context) \(presented)")
            }
        }
    }
}
