@testable import MacdowsCore
import Testing

// S1 (modes) and S6 (limits). Fixture strings are invented. `@testable`: the inbound payload
// rules (`ClipboardInboundPayload`) are internal to the package.

@Suite("Clipboard S1: modes and the policy table")
struct ClipboardPolicyTableTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let mode: ClipboardMode
        let channel: ClipboardChannelSetting
        let localToRemote: Bool
        let remoteToLocal: Bool
        let callbacks: Bool
        var testDescription: String { "\(mode)" }
    }

    /// S1's table, row by row: five modes x four questions.
    static let table: [Row] = [
        Row(mode: .unmanaged, channel: .leaveDefault, localToRemote: false, remoteToLocal: false, callbacks: false),
        Row(mode: .off, channel: .doNotLoad, localToRemote: false, remoteToLocal: false, callbacks: false),
        Row(mode: .bidirectional, channel: .load, localToRemote: true, remoteToLocal: true, callbacks: true),
        Row(mode: .remoteToLocalOnly, channel: .load, localToRemote: false, remoteToLocal: true, callbacks: true),
        Row(mode: .localToRemoteOnly, channel: .load, localToRemote: true, remoteToLocal: false, callbacks: true),
    ]

    @Test("every mode answers all four questions as S1's table says", arguments: Self.table)
    func row(_ row: Row) {
        let policy = ClipboardPolicy(mode: row.mode)
        #expect(policy.channelSetting == row.channel)
        #expect(policy.allowsLocalToRemote == row.localToRemote)
        #expect(policy.allowsRemoteToLocal == row.remoteToLocal)
        #expect(policy.installsCallbacks == row.callbacks)
    }

    @Test("the table covers every mode exactly once")
    func tableIsComplete() {
        #expect(Self.table.map(\.mode) == ClipboardMode.allCases)
    }

    @Test("raw values are fixed, unmanaged is 0")
    func rawValues() {
        #expect(ClipboardMode.unmanaged.rawValue == 0)
        #expect(ClipboardMode.off.rawValue == 1)
        #expect(ClipboardMode.bidirectional.rawValue == 2)
        #expect(ClipboardMode.remoteToLocalOnly.rawValue == 3)
        #expect(ClipboardMode.localToRemoteOnly.rawValue == 4)
        #expect(ClipboardMode(rawValue: 0) == .unmanaged)
    }

    @Test("the one master switch: on is bidirectional, off is off (D2)")
    func userSetting() {
        #expect(ClipboardMode.forUserSetting(enabled: true) == .bidirectional)
        #expect(ClipboardMode.forUserSetting(enabled: false) == .off)
    }

    @Test("CF_UNICODETEXT is format 13")
    func formatNumber() {
        #expect(ClipboardFormat.unicodeText == 13)
    }
}

@Suite("Clipboard S6: the 4 MiB limits, both directions")
struct ClipboardLimitTests {
    static let limit = 4 * 1024 * 1024

    @Test("the named constant is 4 MiB and both directions default to it")
    func constant() {
        #expect(ClipboardLimits.defaultMaxBytes == 4_194_304)
        #expect(ClipboardLimits.standard.remoteToLocalMaxBytes == Self.limit)
        #expect(ClipboardLimits.standard.localToRemoteMaxBytes == Self.limit)
        #expect(ClipboardPolicy(mode: .bidirectional).limits == .standard)
    }

    @Test("exactly at the limit is admitted, one code unit under is admitted, over is not")
    func admitsBoundaries() {
        let limits = ClipboardLimits.standard
        #expect(limits.admitsRemoteToLocal(byteCount: Self.limit))
        #expect(limits.admitsRemoteToLocal(byteCount: Self.limit - 2))
        #expect(!limits.admitsRemoteToLocal(byteCount: Self.limit + 1))
        #expect(!limits.admitsRemoteToLocal(byteCount: Self.limit + 2))
        #expect(limits.admitsLocalToRemote(byteCount: Self.limit))
        #expect(limits.admitsLocalToRemote(byteCount: Self.limit - 2))
        #expect(!limits.admitsLocalToRemote(byteCount: Self.limit + 1))
        #expect(!limits.admitsLocalToRemote(byteCount: Self.limit + 2))
    }

    @Test("the two directions are judged independently")
    func directionsIndependent() {
        let limits = ClipboardLimits(remoteToLocalMaxBytes: 10, localToRemoteMaxBytes: 20)
        #expect(!limits.admitsRemoteToLocal(byteCount: 12))
        #expect(limits.admitsLocalToRemote(byteCount: 12))
    }

    /// Mac -> Windows at the real limit: the limit counts the encoded bytes, NUL included.
    @Test("Mac -> Windows: exactly 4 MiB encoded is sent, one code unit more is refused, never truncated")
    func outboundAtTheRealLimit() {
        let policy = ClipboardPolicy(mode: .bidirectional)
        let unitsAtLimit = Self.limit / 2 - 1 // plus the NUL unit = exactly the limit

        let atLimit = String(repeating: "a", count: unitsAtLimit)
        guard case .respond(let bytes) = ClipboardOutboundFixtures.respond(atLimit, policy: policy) else {
            Issue.record("a text encoding to exactly the limit must be sent")
            return
        }
        #expect(bytes.count == Self.limit)

        let oneUnder = String(repeating: "a", count: unitsAtLimit - 1)
        if case .respond(let under) = ClipboardOutboundFixtures.respond(oneUnder, policy: policy) {
            #expect(under.count == Self.limit - 2)
        } else {
            Issue.record("one code unit under the limit must be sent")
        }

        let oneOver = String(repeating: "a", count: unitsAtLimit + 1)
        #expect(ClipboardOutboundFixtures.respond(oneOver, policy: policy) == .fail(.tooLarge))
    }

    @Test("Mac -> Windows: the LF -> CR LF expansion counts toward the limit")
    func outboundExpansionCounts() {
        let policy = ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: 10))
        // "abcd" -> 4 units + NUL = 10 bytes: fits. "abc\n" -> a b c CR LF NUL = 12 bytes: does not.
        if case .respond(let bytes) = ClipboardOutboundFixtures.respond("abcd", policy: policy) {
            #expect(bytes.count == 10)
        } else {
            Issue.record("10 bytes against a 10-byte limit must be sent")
        }
        #expect(ClipboardOutboundFixtures.respond("abc\n", policy: policy) == .fail(.tooLarge))
    }

    /// Windows -> Mac at the real limit: the limit counts the bytes as received.
    @Test("Windows -> Mac: exactly 4 MiB is written, one code unit under is written, over is dropped")
    func inboundAtTheRealLimit() {
        let limits = ClipboardLimits.standard
        func payload(byteCount: Int) -> ClipboardDataResponse {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            // 'a' in every complete unit but the last; the last complete unit stays NUL.
            var i = 0
            while i + 3 < byteCount {
                bytes[i] = 0x61
                i += 2
            }
            return .success(ClipboardBytes(bytes))
        }
        func evaluate(_ response: ClipboardDataResponse) -> ClipboardInboundOutcome {
            ClipboardInboundPayload.evaluate(response, changeCount: 1, baselineChangeCount: 1, sensitive: false, limits: limits)
        }
        if case .write(let text, _) = evaluate(payload(byteCount: Self.limit)) {
            #expect(text.utf16Count == Self.limit / 2 - 1)
        } else {
            Issue.record("exactly the limit must be written")
        }
        if case .write = evaluate(payload(byteCount: Self.limit - 2)) {
        } else {
            Issue.record("one code unit under the limit must be written")
        }
        #expect(evaluate(payload(byteCount: Self.limit + 2)) == .drop(.tooLarge))
        // Odd AND over: S4 checks the size first, so this is "too large", not "malformed".
        #expect(evaluate(payload(byteCount: Self.limit + 1)) == .drop(.tooLarge))
    }
}
