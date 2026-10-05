import Foundation
import Testing

// adr/0021 lane LC-2 (E1-lite): the three observation-only INFO lines `CRSession.mm` gained so the
// L-C batch can witness the extra ClientExecute from the bridge's side.
//
//  * X-S -- `crb_outbound_visitor`'s EXECUTE branch logs the return code of the ClientExecute it
//    just sent.
//  * X-R -- `crb_rail_server_execute_result` logs the server's three numeric result fields, and
//    NEVER the echoed program name (`exeOrFile` may carry the stimulus path).
//  * X-C -- `crb_monitored_desktop` logs a per-connection count right before it starts the
//    RemoteApp program on ARC_COMPLETED, so one connection's number of ClientExecutes is countable.
//
// The format strings are carrier lines for the L-C preregistration, which greps for them by their
// literal text; these pins hold each one to exactly one occurrence in the exact call shape, at
// the exact place. Pins on source text, because the bridge cannot be driven offline: like the
// other `CRSession.mm` pins in this bundle, they check that the lines are WRITTEN where they must
// be, not that a live connection emits them (the L-C probe run is that evidence).

private func bridgeRepoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func bridgeOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Every run of whitespace collapsed to one space, so re-wrapping is invisible to a pin.
private func bridgeFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `/* ... */` comments removed, then folded. `CRSession.mm`'s explanations are block comments,
/// and a pin on a call must not also count prose quoting it. `//` comments are left alone on
/// purpose: a format string may legitimately contain `//`, and none of the needles below are
/// quoted in a `//` comment (`theStripperKeepsTheCode` guards the stripper itself).
private func bridgeCodeOnly(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "/*") {
        out += rest[rest.startIndex..<open.lowerBound]
        out += " "
        guard let close = rest[open.upperBound...].range(of: "*/") else { return bridgeFolded(out) }
        rest = rest[close.upperBound...]
    }
    out += rest
    return bridgeFolded(out)
}

@Suite("adr/0021 lane LC-2 — the bridge's extra-exec witness lines X-S / X-R / X-C, pinned as source")
struct BridgeExecWitnessPinTests {

    private static let xS = "WLog_INFO(TAG, \"outbound execute sent rc=%u\", (unsigned)rc);"
    private static let xR =
        "WLog_INFO(TAG, \"ServerExecuteResult flags=%u execResult=%u rawResult=%u\", "
        + "(unsigned)execResult->flags, (unsigned)execResult->execResult, (unsigned)execResult->rawResult);"
    private static let xC =
        "WLog_INFO(TAG, \"ClientRailServerStartCmd arc-completed send=%u\", (unsigned)p->arcCompletedStartCmdSends);"

    private static func raw() throws -> String {
        try String(contentsOf: bridgeRepoRoot().appendingPathComponent("App/CRBridge/CRSession.mm"), encoding: .utf8)
    }

    private static func code() throws -> String {
        try bridgeCodeOnly(raw())
    }

    private static func index(of needle: String, in haystack: String) throws -> String.Index {
        try #require(haystack.range(of: needle), "not found: \(needle)").lowerBound
    }

    /// The body of the C function whose definition starts with `signature`: from the signature to
    /// the first `\n}` that closes it (this file's functions all close at column 0).
    private static func functionBody(_ signature: String, in raw: String) throws -> String {
        let start = try index(of: signature, in: raw)
        let end = try #require(raw[start...].range(of: "\n}\n"), "no closing brace after \(signature)")
        return String(raw[start..<end.upperBound])
    }

    @Test("the comment stripper leaves the code it is asked about intact")
    func theStripperKeepsTheCode() throws {
        let code = try Self.code()
        #expect(code.contains("static void crb_outbound_visitor(const CrdpCommand *cmd, void *vctx)"))
        #expect(code.contains("static UINT crb_rail_server_execute_result(RailClientContext *context,"))
        #expect(code.contains("- (void)executeProgram:(NSString *)program"))
        #expect(code.contains("case CRDPQ_CMD_EXECUTE:"))
        // An unterminated comment would swallow everything after it; the file's last statement and
        // a definition near its end must both survive.
        #expect(code.hasSuffix("@end"), "the stripper ate the tail of the file")
        #expect(code.contains("- (void)sendModifierKey:(CRModifierKey)key down:(BOOL)down"))
    }

    // MARK: - each format string exactly once, in its exact call shape

    @Test("each witness format string occurs exactly once, in the raw file and as its exact call")
    func eachFormatStringOnce() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        for literal in [
            "\"outbound execute sent rc=%u\"",
            "\"ServerExecuteResult flags=%u execResult=%u rawResult=%u\"",
            "\"ClientRailServerStartCmd arc-completed send=%u\"",
        ] {
            #expect(bridgeOccurrences(of: literal, in: raw) == 1, "\(literal)")
        }
        for call in [Self.xS, Self.xR, Self.xC] {
            #expect(bridgeOccurrences(of: call, in: code) == 1, "\(call)")
        }
    }

    // MARK: - X-S

    /// X-S sits in the EXECUTE branch, right after the one ClientExecute call whose return code
    /// it reports, and before the next case.
    @Test("X-S follows the EXECUTE branch's ClientExecute call and logs its return code")
    func xSFollowsClientExecute() throws {
        let code = try Self.code()
        #expect(bridgeOccurrences(of: "rail->ClientExecute(", in: code) == 1)
        #expect(code.contains(
            "if (rail->ClientExecute) { const UINT rc = rail->ClientExecute(rail, &exec); " + Self.xS + " } break;"))
        let branch = try Self.index(of: "case CRDPQ_CMD_EXECUTE:", in: code)
        let send = try Self.index(of: "rail->ClientExecute(rail, &exec);", in: code)
        let line = try Self.index(of: Self.xS, in: code)
        let nextCase = try Self.index(of: "case CRDPQ_CMD_ACTIVATE:", in: code)
        #expect(branch < send)
        #expect(send < line)
        #expect(line < nextCase)
    }

    // MARK: - the send path never logs the program (gate r1 I-2, folded in)

    /// The truncation refusal `-executeProgram:` has always had, in its exact call shape: a byte
    /// limit and nothing else.
    private static let executeProgramWarn =
        "WLog_WARN(TAG, \"executeProgram: path exceeds %d bytes and would be truncated -- refusing to send\", "
        + "CRDPQ_TEXT_BUF_SIZE - 1);"

    /// Every `WLog_` statement in `segment` (up to its first `;`) must not print a string or name
    /// the program buffer in any of its spellings.
    private static func expectNoProgramInWLog(_ segment: String, _ label: String,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
        for call in segment.components(separatedBy: "WLog_").dropFirst() {
            let statement = call.prefix { $0 != ";" }
            for banned in ["%s", "utf8", "programBuf", "program"] {
                #expect(!statement.contains(banned), "a WLog call in \(label) contains \(banned)",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// Gate r1 I-2: the two places the program string passes through on its way out -- the
    /// `-executeProgram:` method that queues it and the outbound visitor's EXECUTE branch that
    /// sends it -- each carry exactly one WLog call, and it is the expected one: the existing
    /// truncation WARN in the method, X-S in the branch. No WLog statement in either segment prints
    /// a string or names `utf8`, `programBuf` or `program`. Gate r1's mutants R6 (the method logging
    /// `utf8`) and R7 (the branch logging `programBuf`) are killed here.
    @Test("the send path logs only the truncation WARN and X-S, and never the program string")
    func theSendPathNeverLogsTheProgram() throws {
        let raw = try Self.raw()
        let method = try bridgeCodeOnly(Self.functionBody("- (void)executeProgram:(NSString *)program", in: raw))
        #expect(bridgeOccurrences(of: "WLog_", in: method) == 1)
        #expect(bridgeOccurrences(of: Self.executeProgramWarn, in: method) == 1)
        Self.expectNoProgramInWLog(method, "-executeProgram:")

        let code = try Self.code()
        let branchStart = try Self.index(of: "case CRDPQ_CMD_EXECUTE:", in: code)
        let branchEnd = try Self.index(of: "case CRDPQ_CMD_ACTIVATE:", in: code)
        try #require(branchStart < branchEnd)
        let branch = String(code[branchStart..<branchEnd])
        #expect(bridgeOccurrences(of: "WLog_", in: branch) == 1)
        #expect(bridgeOccurrences(of: Self.xS, in: branch) == 1)
        Self.expectNoProgramInWLog(branch, "the EXECUTE branch")
    }

    // MARK: - X-R

    /// X-R is the ONLY WLog call in the execute-result handler, it is the exact three-field call,
    /// and no WLog call there names `exeOrFile` -- an added `%s` argument, or the converted `exe`
    /// string, changes the exact call shape and fails the first two checks even where the third
    /// cannot see it.
    @Test("X-R is the handler's only WLog call and never logs exeOrFile")
    func xRNeverLogsTheProgram() throws {
        let body = try bridgeCodeOnly(Self.functionBody(
            "static UINT crb_rail_server_execute_result(RailClientContext *context,", in: Self.raw()))
        #expect(bridgeOccurrences(of: "WLog_", in: body) == 1)
        #expect(bridgeOccurrences(of: Self.xR, in: body) == 1)
        for call in body.components(separatedBy: "WLog_").dropFirst() {
            let statement = call.prefix { $0 != ";" }
            #expect(!statement.contains("exeOrFile"), "a WLog call in the execute-result handler names exeOrFile")
            #expect(!statement.contains("%s"), "a WLog call in the execute-result handler prints a string")
        }
        // The handler still forwards exeOrFile to the App's event (behaviour unchanged).
        #expect(body.contains("rail_string_to_utf8_string(&execResult->exeOrFile)"))
    }

    // MARK: - X-C

    /// X-C is the statement right before the one start-command call, preceded by its own counter
    /// increment, and the counter is reset per connection right after `bridgeSelf` is set.
    @Test("X-C immediately precedes the one ARC_COMPLETED start-command call, counted per connection")
    func xCPrecedesTheStartCommand() throws {
        let code = try Self.code()
        #expect(bridgeOccurrences(of: "client_rail_server_start_cmd(", in: code) == 1)
        #expect(code.contains(
            "p->arcCompletedStartCmdSends++; " + Self.xC + " client_rail_server_start_cmd(p->rail); }"))
        // The last WLog_ before the call is X-C.
        let call = try Self.index(of: "client_rail_server_start_cmd(", in: code)
        let lastWLog = try #require(code[..<call].range(of: "WLog_", options: .backwards))
        #expect(code[lastWLog.lowerBound...].hasPrefix(Self.xC))
        // Declared once in the per-connection context struct; reset once, at -start.
        #expect(bridgeOccurrences(of: "uint32_t arcCompletedStartCmdSends;", in: code) == 1)
        #expect(code.contains(
            "((CRBridgeContext *)context)->bridgeSelf = (__bridge void *)self; "
                + "((CRBridgeContext *)context)->arcCompletedStartCmdSends = 0;"))
        #expect(bridgeOccurrences(of: "arcCompletedStartCmdSends", in: code) == 4,
                "declaration, reset, increment, log argument")
    }
}
