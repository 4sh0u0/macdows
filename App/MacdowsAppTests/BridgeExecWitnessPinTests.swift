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

// MARK: - ADR-0025 a-1: -launchProgram:arguments: and the EXECUTE branch's argument split
//
// The Dock start panel launches through a NEW bridge method (ADR-0025 §2: a new name, so no pin
// anchored on `-executeProgram:` can ever match it), and the old method stays the unattended
// knob's program-only send. The pins below hold the new method to the old one's discipline -- one
// WLog call, a refusal that reports a byte count and never the program or the arguments (ADR-0025
// §3.2 S-2) -- hold the old body to its exact pre-ADR text, and hold the outbound visitor's split
// to the shared-buffer rule in `crdpq.h` (`crdpq_cmd_execute_t`). The frozen X-S / X-R lines
// (S-3) stay pinned by `eachFormatStringOnce` and `xSFollowsClientExecute` above, unchanged.
extension BridgeExecWitnessPinTests {

    private static let launchSignature =
        "- (void)launchProgram:(NSString *)program arguments:(nullable NSString *)arguments"

    /// The new method's only WLog call, in its exact call shape: a byte count, the limit and a
    /// flag -- no `%s`, no string argument.
    private static let launchProgramWarn =
        "WLog_WARN(TAG, \"launchProgram: refusing to send -- %lu payload bytes (allowed 1 to %d), embedded NUL=%d\", "
        + "byteCount, CRDPQ_TEXT_BUF_SIZE - 1, (int)(packed == CRDPQ_EXECUTE_SET_EMBEDDED_NUL));"

    /// `-executeProgram:` as it stood at main `3b0bdb2`, comments included, whitespace folded.
    private static let executeProgramBodyFolded =
        #"- (void)executeProgram:(NSString *)program { if (!_outboundQueue) return; CrdpCommand cmd; "#
        + #"memset(&cmd, 0, sizeof(cmd)); cmd.type = CRDPQ_CMD_EXECUTE; const char *utf8 = program.UTF8String; "#
        + #"if (!utf8 || utf8[0] == '\0') return; crdpq_text_set(&cmd.payload.execute.program, utf8, strlen(utf8)); "#
        + #"/* A path that doesn't fit crdpq's 255-byte text buffer would exec a TRUNCATED (i.e. * different) "#
        + #"path on the server, whose failure result nothing may be watching -- * refuse loudly instead of "#
        + #"silently launching the wrong thing (2026-08-22 review). */ if (cmd.payload.execute.program.truncated) "#
        + #"{ WLog_WARN(TAG, "executeProgram: path exceeds %d bytes and would be truncated -- refusing to send", "#
        + #"CRDPQ_TEXT_BUF_SIZE - 1); return; } crdpq_outbound_post(_outboundQueue, &cmd); }"#

    @Test("-executeProgram:'s body is exactly its pre-ADR-0025 text, comments included")
    func theOldMethodIsUntouched() throws {
        let body = try bridgeFolded(Self.functionBody("- (void)executeProgram:(NSString *)program", in: Self.raw()))
        #expect(body == Self.executeProgramBodyFolded)
    }

    @Test("the header declares both methods once each, the old declaration unchanged and first")
    func theHeaderDeclaresBoth() throws {
        let header = try String(contentsOf: bridgeRepoRoot().appendingPathComponent("App/CRBridge/CRSession.h"),
                                encoding: .utf8)
        let old = "- (void)executeProgram:(NSString *)program;"
        let new = Self.launchSignature + ";"
        #expect(bridgeOccurrences(of: old, in: header) == 1)
        #expect(bridgeOccurrences(of: new, in: header) == 1)
        // Nothing else takes the old name as a prefix.
        #expect(bridgeOccurrences(of: "- (void)executeProgram", in: header) == 1)
        let oldAt = try Self.index(of: old, in: header)
        let newAt = try Self.index(of: new, in: header)
        #expect(oldAt < newAt)
    }

    /// Mutant P6 (the new method printing the program or the arguments) is killed here: any extra
    /// WLog call, any change to the one WARN's shape, or a WARN naming either string goes red.
    @Test("-launchProgram:arguments: has one WLog, the refusal WARN, which never prints the command")
    func theNewMethodNeverLogsTheCommand() throws {
        let raw = try Self.raw()
        #expect(bridgeOccurrences(of: Self.launchSignature, in: raw) == 1)
        let method = try bridgeCodeOnly(Self.functionBody(Self.launchSignature, in: raw))
        #expect(bridgeOccurrences(of: "WLog_", in: method) == 1)
        #expect(bridgeOccurrences(of: Self.launchProgramWarn, in: method) == 1)
        Self.expectNoProgramInWLog(method, "-launchProgram:arguments:")
        for call in method.components(separatedBy: "WLog_").dropFirst() {
            let statement = call.prefix { $0 != ";" }
            for banned in ["arguments", "Bytes", ".bytes", "%@", ".UTF8String"] {
                #expect(!statement.contains(banned), "a WLog call in -launchProgram:arguments: contains \(banned)")
            }
        }
    }

    @Test("-launchProgram:arguments: packs with crdpq_execute_set, refuses before posting, posts once")
    func theNewMethodPacksAndPosts() throws {
        let method = try bridgeCodeOnly(Self.functionBody(Self.launchSignature, in: Self.raw()))
        // The shared-buffer packer, from NSData byte counts; never crdpq_text_set, which truncates.
        #expect(bridgeOccurrences(of: "crdpq_execute_set(&cmd.payload.execute, ", in: method) == 1)
        #expect(method.contains("NSData *programBytes = [program dataUsingEncoding:NSUTF8StringEncoding];"))
        #expect(method.contains("NSData *argumentsBytes = [arguments dataUsingEncoding:NSUTF8StringEncoding];"))
        #expect(bridgeOccurrences(of: "crdpq_text_set(", in: method) == 0)
        // Matched as the property access: `NSUTF8StringEncoding` contains the bare name.
        #expect(bridgeOccurrences(of: ".UTF8String", in: method) == 0)
        #expect(bridgeOccurrences(of: "crdpq_outbound_post(", in: method) == 1)
        // Any result but OK returns after the WARN; the post is the method's last statement.
        #expect(method.contains(
            "if (packed != CRDPQ_EXECUTE_SET_OK) { const unsigned long byteCount = (unsigned long)(programBytes.length "
                + "+ (argumentsBytes.length > 0 ? 1 + argumentsBytes.length : 0)); "
                + Self.launchProgramWarn + " return; } crdpq_outbound_post(_outboundQueue, &cmd); }"))
    }

    @Test("the EXECUTE branch splits the arguments off its stack copy, once, before the send")
    func theBranchSplitsTheArguments() throws {
        let code = try Self.code()
        let branchStart = try Self.index(of: "case CRDPQ_CMD_EXECUTE:", in: code)
        let branchEnd = try Self.index(of: "case CRDPQ_CMD_ACTIVATE:", in: code)
        try #require(branchStart < branchEnd)
        let branch = String(code[branchStart..<branchEnd])
        // The one place the arguments are wired, in the whole file's code.
        #expect(bridgeOccurrences(of: "RemoteApplicationArguments", in: code) == 1)
        #expect(bridgeOccurrences(of: "RemoteApplicationArguments", in: branch) == 1)
        #expect(bridgeOccurrences(of: "crdpq_execute_arguments_offset(", in: code) == 1)
        #expect(branch.contains(
            "memcpy(programBuf, cmd->payload.execute.program.bytes, sizeof(programBuf)); "
                + "exec.RemoteApplicationProgram = programBuf; "
                + "const size_t argumentsAt = crdpq_execute_arguments_offset(&cmd->payload.execute); "
                + "if (argumentsAt > 0) exec.RemoteApplicationArguments = programBuf + argumentsAt; "
                + "if (rail->ClientExecute) {"))
        // Both halves point into the stack copy, never into the const command; flags stay 0.
        #expect(!branch.contains("= cmd->payload.execute.program.bytes"))
        #expect(!branch.contains("exec.flags"))
    }
}
