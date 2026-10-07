import Testing

@testable import MacdowsCore

/// ADR-0025 §3.1 item 1: the ExecResult code table, spelled out value by value rather than derived
/// from the type, so a moved or added mapping goes red here.
@Suite("ExecResultCode: RAIL Server Execute Result codes and their start-panel reason keys")
struct ExecResultCodeTests {

    /// `TS_RAIL_EXEC_RESULT` (`ThirdParty/FreeRDP/include/freerdp/rail.h`): seven codes, no 4.
    private static let known: [(code: UInt32, expected: ExecResultCode, key: String?)] = [
        (0, .ok, nil),
        (1, .hookNotLoaded, "sp_r_hook"),
        (2, .decodeFailed, "sp_r_decode"),
        (3, .notInAllowList, "sp_r_allow"),
        (5, .fileNotFound, "sp_r_nf"),
        (6, .fail, "sp_r_fail"),
        (7, .sessionLocked, "sp_r_locked"),
    ]

    @Test("each of the seven RAIL_EXEC_* codes maps to its own case and key")
    func everyKnownCode() {
        for row in Self.known {
            let code = ExecResultCode(execResult: row.code)
            #expect(code == row.expected, "execResult \(row.code)")
            #expect(code.reasonKey == row.key, "execResult \(row.code)")
        }
    }

    @Test("4, 8, 0xFFFF and values above 16 bits are unknown, with the unknown key")
    func everythingElseIsUnknown() {
        for value: UInt32 in [4, 8, 9, 0x10, 0x7FFF, 0xFFFF, 0x1_0000, 0x1_0005, UInt32.max] {
            let code = ExecResultCode(execResult: value)
            #expect(code == .unknown, "execResult \(value)")
            #expect(code.reasonKey == "sp_r_unknown", "execResult \(value)")
        }
    }

    @Test("only 0 is a success")
    func onlyZeroSucceeds() {
        for value in UInt32(0)...UInt32(16) {
            #expect(ExecResultCode(execResult: value).isSuccess == (value == 0), "execResult \(value)")
        }
        #expect(!ExecResultCode(execResult: 0xFFFF).isSuccess)
        #expect(ExecResultCode.allCases.filter(\.isSuccess) == [.ok])
    }

    @Test("every failure has a distinct sp_r_ key and success has none")
    func failureKeysAreDistinct() {
        #expect(ExecResultCode.allCases.count == 8)
        let keys = ExecResultCode.allCases.compactMap(\.reasonKey)
        #expect(keys.count == 7)
        #expect(Set(keys).count == 7)
        #expect(keys.allSatisfy { $0.hasPrefix("sp_r_") })
        #expect(ExecResultCode.ok.reasonKey == nil)
    }
}
