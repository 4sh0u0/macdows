/// ADR-0025 §0(a) / §3.1 item 1: what a RAIL Server Execute Result says about a launch, and which
/// start-panel string explains it.
///
/// The server answers every ClientExecute with an ExecResult order whose `execResult` field is one
/// of MS-RDPERP's `RAIL_EXEC_*` codes. The vendored header lists seven, with no 4
/// (`ThirdParty/FreeRDP/include/freerdp/rail.h`, `TS_RAIL_EXEC_RESULT`):
///
///  - 0 `RAIL_EXEC_S_OK`
///  - 1 `RAIL_EXEC_E_HOOK_NOT_LOADED`
///  - 2 `RAIL_EXEC_E_DECODE_FAILED`
///  - 3 `RAIL_EXEC_E_NOT_IN_ALLOWLIST`
///  - 5 `RAIL_EXEC_E_FILE_NOT_FOUND`
///  - 6 `RAIL_EXEC_E_FAIL`
///  - 7 `RAIL_EXEC_E_SESSION_LOCKED`
///
/// Everything else -- 4, the 16-bit field's 0xFFFF, a code a later protocol revision adds -- is
/// `.unknown`: the panel says "unknown result" rather than guessing a nearby meaning. The bridge
/// hands the field over widened to 32 bits (`CRDPEvent.execResult`), so this type takes a
/// `UInt32` and any value above 16 bits is unknown too.
///
/// The `rawResult` field (the Windows error behind a failure) is deliberately NOT read here: the
/// start panel's strings explain the reason and the next step and never show a code (ADR-0025
/// R-9), and `execResult` alone selects the reason.
///
/// Pure value, no AppKit: the String Catalog lives in the App, which looks `reasonKey` up and pins
/// that every key here exists there in all three languages (ADR-0025 §3.1 item 6).
public enum ExecResultCode: Equatable, Sendable, CaseIterable {
    /// 0: the server started the program. No reason string: success closes the panel.
    case ok
    /// 1: the server's RemoteApp hook is not loaded yet.
    case hookNotLoaded
    /// 2: the server could not decode the program name.
    case decodeFailed
    /// 3: the server's allow list does not include the program.
    case notInAllowList
    /// 5: the program path does not exist on the server.
    case fileNotFound
    /// 6: any other server-side failure to start it.
    case fail
    /// 7: the remote session is locked.
    case sessionLocked
    /// Any other value, including 4 and 0xFFFF.
    case unknown

    /// Maps the bridge's `execResult` field to a case. Total: every `UInt32` maps to exactly one.
    public init(execResult: UInt32) {
        switch execResult {
        case 0: self = .ok
        case 1: self = .hookNotLoaded
        case 2: self = .decodeFailed
        case 3: self = .notInAllowList
        case 5: self = .fileNotFound
        case 6: self = .fail
        case 7: self = .sessionLocked
        default: self = .unknown
        }
    }

    /// `true` only for `RAIL_EXEC_S_OK`. ADR-0025 R-7: only a success writes the item to Recent
    /// and closes the panel.
    public var isSuccess: Bool {
        self == .ok
    }

    /// The String Catalog key (`sp_r_*`, ADR-0025 §5.1) that explains this result, or nil for
    /// `.ok`. Each failure has its own key; the catalog pin in the App bundle checks every
    /// non-nil value here has en / zh-Hans / ja.
    public var reasonKey: String? {
        switch self {
        case .ok: nil
        case .hookNotLoaded: "sp_r_hook"
        case .decodeFailed: "sp_r_decode"
        case .notInAllowList: "sp_r_allow"
        case .fileNotFound: "sp_r_nf"
        case .fail: "sp_r_fail"
        case .sessionLocked: "sp_r_locked"
        case .unknown: "sp_r_unknown"
        }
    }
}
