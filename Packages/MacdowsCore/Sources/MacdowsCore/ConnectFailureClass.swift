/// adr/0019 supplementary ruling RB-1 (D-A (b), D-B (i)-(iv)): which connect-time failures on a
/// reconnect leg are worth another attempt.
///
/// A connect that fails on a leg the reconnect driver started either failed for a reason that can
/// go away by itself (the network was down for a moment, the host was restarting, a TLS handshake
/// was cut off) or for a reason the same attempt will meet again (wrong credentials, a refused
/// protocol, a bridge-side setup failure). The first kind is one failed attempt on ADR-0019 A's
/// back-off curve (D-C: the same five-attempt `ReconnectPolicy` sequence a dropped connection
/// uses); the second kind gives up at once. This type is the pure half of that split: a domain and
/// a code in, one of two classes out. No state, no I/O, and no knowledge of the driver.
///
/// The rule, in order (D-B):
///
///  1. a domain other than the bridge's own (`Macdows.CRSession`) is `.final`;
///  2. a code below `0x10000` is `.final` -- the bridge's own negative codes (-1...-5), a positive
///     pthread errno from the thread spawn, and ERRBASE 0 (a failure that carried no code). These
///     share no meaning with FreeRDP's code space even where the numbers overlap, which is why the
///     domain and the code are read together and never the number alone;
///  3. a FreeRDP CONNECT-class code (`MAKE_FREERDP_ERROR(CONNECT, t)` = `0x20000 | t`,
///     `include/freerdp/error.h`) whose type `t` is in `transientConnectTypes` is `.transient`;
///  4. everything else is `.final`: the ERRINFO class (`0x1xxxx`, which a server's Set Error Info
///     can leave as the last error), the CONNECT types outside the transient set (09
///     AUTHENTICATION_FAILED, 0B CONNECT_CANCELLED, the credential and account types, 1E ...), and
///     any CONNECT type a later FreeRDP adds. Unknown is final (D-B(i)): that is today's behaviour,
///     it never retries a credential failure into an account lock-out, and the exhaustive pin on
///     this table goes red when an upgrade adds a type.
public enum ConnectFailureClass: Equatable, Sendable {
    /// One failed attempt: the driver asks `ReconnectPolicy` for the next step.
    case transient
    /// The same attempt would fail the same way: the driver gives up at once.
    case final

    /// The error domain the bridge (`App/CRBridge/CRSession.mm`) gives every `lastConnectError`,
    /// FreeRDP's codes and its own alike.
    public static let bridgeErrorDomain = "Macdows.CRSession"

    /// FreeRDP's CONNECT class shifted into place: `(FREERDP_ERROR_BASE + 2) << 16` with
    /// `FREERDP_ERROR_BASE == 0` (`include/freerdp/error.h:189`, `:197`, `:298`).
    public static let connectErrorClass = 0x0002_0000

    /// The CONNECT types that are one failed attempt rather than a refusal (D-B(ii), D-B(iii)).
    ///
    /// = `ConnectFlow.swift`'s unreachable set {04, 05, 06, 0D, 1D} ∪ {07, 08, 1C}
    /// (adr/0019 RB-1 D-B(iii)). Names from `include/freerdp/error.h:253-284`:
    ///
    ///  - 0x04 `ERRCONNECT_DNS_ERROR`
    ///  - 0x05 `ERRCONNECT_DNS_NAME_NOT_FOUND`
    ///  - 0x06 `ERRCONNECT_CONNECT_FAILED`
    ///  - 0x07 `ERRCONNECT_MCS_CONNECT_INITIAL_ERROR`
    ///  - 0x08 `ERRCONNECT_TLS_CONNECT_FAILED` (D-B(ii): a certificate rejection also lands here,
    ///    but the driver's step 0 reads `lastCertificateRejection` first and owns that case)
    ///  - 0x0D `ERRCONNECT_CONNECT_TRANSPORT_FAILED`
    ///  - 0x1C `ERRCONNECT_ACTIVATION_TIMEOUT`
    ///  - 0x1D `ERRCONNECT_TARGET_BOOTING`
    public static let transientConnectTypes: Set<Int> = [0x04, 0x05, 0x06, 0x07, 0x08, 0x0D, 0x1C, 0x1D]

    /// Classifies one connect error by its domain and code. See the type's documentation for the
    /// rule; this is that rule and nothing else.
    ///
    /// The class test compares every bit above the low sixteen, not just `code & 0xFFFF0000`: the
    /// two agree on every value FreeRDP can produce (a `UINT32`), and the wider one keeps a value
    /// beyond 32 bits from aliasing onto the CONNECT class.
    public static func classify(domain: String, code: Int) -> ConnectFailureClass {
        guard domain == bridgeErrorDomain else { return .final }
        guard code >= 0x1_0000 else { return .final }
        guard code & ~0xFFFF == connectErrorClass else { return .final }
        return transientConnectTypes.contains(code & 0xFFFF) ? .transient : .final
    }
}
