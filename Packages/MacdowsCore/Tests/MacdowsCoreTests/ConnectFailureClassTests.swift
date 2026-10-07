import Testing

@testable import MacdowsCore

/// adr/0019 supplementary ruling RB-1 D-B: the exhaustive pin on `ConnectFailureClass`. Every
/// value below is spelled out rather than derived from the type's own set, so a change to the
/// transient set, a new CONNECT type after a FreeRDP upgrade, or a change to the domain or
/// low-code rule goes red here (the adr/0017 §4 upgrade checklist reads this suite).
@Suite("ConnectFailureClass: which reconnect-leg connect failures are worth another attempt")
struct ConnectFailureClassTests {

    private static let domain = "Macdows.CRSession"

    /// The thirty CONNECT types of `include/freerdp/error.h:253-284`, each with its expected class.
    /// T = {04, 05, 06, 07, 08, 0D, 1C, 1D} (eight), F = the other twenty-two.
    private static let connectTypes: [(type: Int, name: String, expected: ConnectFailureClass)] = [
        (0x01, "PRE_CONNECT_FAILED", .final),
        (0x02, "CONNECT_UNDEFINED", .final),
        (0x03, "POST_CONNECT_FAILED", .final),
        (0x04, "DNS_ERROR", .transient),
        (0x05, "DNS_NAME_NOT_FOUND", .transient),
        (0x06, "CONNECT_FAILED", .transient),
        (0x07, "MCS_CONNECT_INITIAL_ERROR", .transient),
        (0x08, "TLS_CONNECT_FAILED", .transient),
        (0x09, "AUTHENTICATION_FAILED", .final),
        (0x0A, "INSUFFICIENT_PRIVILEGES", .final),
        (0x0B, "CONNECT_CANCELLED", .final),
        (0x0C, "SECURITY_NEGO_CONNECT_FAILED", .final),
        (0x0D, "CONNECT_TRANSPORT_FAILED", .transient),
        (0x0E, "PASSWORD_EXPIRED", .final),
        (0x0F, "PASSWORD_CERTAINLY_EXPIRED", .final),
        (0x10, "CLIENT_REVOKED", .final),
        (0x11, "KDC_UNREACHABLE", .final),
        (0x12, "ACCOUNT_DISABLED", .final),
        (0x13, "PASSWORD_MUST_CHANGE", .final),
        (0x14, "LOGON_FAILURE", .final),
        (0x15, "WRONG_PASSWORD", .final),
        (0x16, "ACCESS_DENIED", .final),
        (0x17, "ACCOUNT_RESTRICTION", .final),
        (0x18, "ACCOUNT_LOCKED_OUT", .final),
        (0x19, "ACCOUNT_EXPIRED", .final),
        (0x1A, "LOGON_TYPE_NOT_GRANTED", .final),
        (0x1B, "NO_OR_MISSING_CREDENTIALS", .final),
        (0x1C, "ACTIVATION_TIMEOUT", .transient),
        (0x1D, "TARGET_BOOTING", .transient),
        (0x1E, "HYBRID_REQUIRED_BY_SERVER", .final),
    ]

    @Test("the table itself: thirty CONNECT types 0x01...0x1E, eight transient and twenty-two final")
    func theTableCoversEveryType() {
        #expect(Self.connectTypes.map(\.type) == Array(0x01...0x1E))
        #expect(Self.connectTypes.filter { $0.expected == .transient }.count == 8)
        #expect(Self.connectTypes.filter { $0.expected == .final }.count == 22)
    }

    @Test("every CONNECT type classifies as the table says, in the bridge's domain")
    func everyConnectTypeMatchesTheTable() {
        for row in Self.connectTypes {
            let code = 0x0002_0000 | row.type
            #expect(ConnectFailureClass.classify(domain: Self.domain, code: code) == row.expected,
                    "0x\(String(code, radix: 16)) ERRCONNECT_\(row.name)")
        }
    }

    @Test("the named transient set is exactly {04, 05, 06, 07, 08, 0D, 1C, 1D}")
    func theTransientSetIsExact() {
        #expect(ConnectFailureClass.transientConnectTypes == [0x04, 0x05, 0x06, 0x07, 0x08, 0x0D, 0x1C, 0x1D])
        #expect(ConnectFailureClass.connectErrorClass == 0x2_0000)
        #expect(ConnectFailureClass.bridgeErrorDomain == Self.domain)
    }

    @Test("the named ERRINFO transient set is exactly {01 RPC_INITIATED_DISCONNECT, 02 RPC_INITIATED_LOGOFF}")
    func theErrinfoTransientSetIsExact() {
        #expect(ConnectFailureClass.transientErrinfoCodes == [0x01, 0x02])
        #expect(ConnectFailureClass.errinfoErrorClass == 0x1_0000)
    }

    @Test("the code seen on 2026-10-07 (131080, TLS_CONNECT_FAILED) and its neighbours by decimal value")
    func decimalSpellings() {
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 131_080) == .transient)
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 131_078) == .transient, "CONNECT_FAILED")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 131_081) == .final, "AUTHENTICATION_FAILED")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 131_083) == .final, "CONNECT_CANCELLED")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 65_537) == .transient,
                "the host-restart sample, ERRINFO RPC_INITIATED_DISCONNECT")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 65_538) == .transient, "ERRINFO RPC_INITIATED_LOGOFF")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 65_539) == .final, "ERRINFO IDLE_TIMEOUT")
    }

    @Test("the bridge's own negative codes -5...-1 are final")
    func bridgeCodesAreFinal() {
        for code in -5...(-1) {
            #expect(ConnectFailureClass.classify(domain: Self.domain, code: code) == .final, "\(code)")
        }
    }

    @Test("a pthread errno, ERRBASE 0, and the type numbers on their own are final")
    func lowCodesAreFinal() {
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 35) == .final, "EAGAIN from the thread spawn")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0) == .final, "a failure that carried no code")
        for type in [0x04, 0x05, 0x06, 0x07, 0x08, 0x0D, 0x1C, 0x1D] {
            #expect(ConnectFailureClass.classify(domain: Self.domain, code: type) == .final,
                    "a bare \(type) is an errno, not a CONNECT type")
        }
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0xFFFF) == .final)
    }

    @Test("ERRINFO-class codes other than 0x1 and 0x2 are final, including ones whose low half is a transient CONNECT type")
    func errinfoCodesOutsideTheSetAreFinal() {
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0005) == .final)
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0006) == .final)
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0000) == .final, "ERRINFO_SUCCESS")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0003) == .final, "IDLE_TIMEOUT")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0004) == .final, "LOGON_TIMEOUT")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0007) == .final, "SERVER_DENIED_CONNECTION")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_000B) == .final, "RPC_INITIATED_DISCONNECT_BY_USER")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_000C) == .final, "LOGOFF_BY_USER")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_FFFF) == .final)
    }

    /// Owner ruling 2026-10-07 (D-B(iv) reconsidered): a host shutdown / restart or an
    /// administrator's disconnect leaves ERRINFO_RPC_INITIATED_DISCONNECT (0x1) or
    /// ERRINFO_RPC_INITIATED_LOGOFF (0x2) as the last error; the sample 65537 came from a host
    /// restart. Only in the ERRINFO class and only in the bridge's domain.
    @Test("ERRINFO 0x1_0001 / 0x1_0002 are transient; the bare numbers, other classes and other domains are not")
    func errinfoRpcInitiatedCodesAreTransient() {
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0001) == .transient, "RPC_INITIATED_DISCONNECT")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0002) == .transient, "RPC_INITIATED_LOGOFF")
        for bare in [0x01, 0x02] {
            #expect(ConnectFailureClass.classify(domain: Self.domain, code: bare) == .final,
                    "a bare \(bare) carries no class bits")
        }
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x3_0001) == .final, "a different class, same low half")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x3_0002) == .final, "a different class, same low half")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0001_0001) == .final,
                "beyond 32 bits: no aliasing onto the ERRINFO class")
        for domain in ["NSPOSIXErrorDomain", "NSURLErrorDomain", "Macdows.CRSession.other", ""] {
            #expect(ConnectFailureClass.classify(domain: domain, code: 0x1_0001) == .final, "\(domain)")
            #expect(ConnectFailureClass.classify(domain: domain, code: 0x1_0002) == .final, "\(domain)")
        }
    }

    @Test("CONNECT types outside 0x01...0x1E and other classes are final")
    func unknownCodesAreFinal() {
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x2_0000) == .final, "type 0")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x2_001F) == .final, "a type a later FreeRDP might add")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x2_FFFF) == .final)
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x3_0006) == .final, "a different class, same low half")
        #expect(ConnectFailureClass.classify(domain: Self.domain, code: 0x1_0002_0006) == .final,
                "beyond 32 bits: no aliasing onto the CONNECT class")
    }

    @Test("the same codes in another domain are final")
    func otherDomainsAreFinal() {
        for domain in ["NSPOSIXErrorDomain", "NSURLErrorDomain", "Macdows.CRSession.other", ""] {
            #expect(ConnectFailureClass.classify(domain: domain, code: 131_078) == .final, "\(domain)")
            #expect(ConnectFailureClass.classify(domain: domain, code: 131_080) == .final, "\(domain)")
        }
    }
}
