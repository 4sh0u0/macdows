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

// MARK: - F-ja-4 lane E: the work-area sysparam, in its own block right after X-C's
//
// The vendored start command reports the WHOLE desktop as the RAIL work area; the bridge now sends
// one more sysparam carrying only the real work area, right after it, on every ARC_COMPLETED (the
// upstream X11 client's order since 3.31.0). It must NOT be folded into X-C's block -- the pin above
// holds the start command and that block's closing brace immediately after the frozen carrier line --
// so it is its own block with X-C's condition plus "the four edges are not all zero", placed AFTER
// X-C's. These pins hold the send to one call in that one place (mutants M1: the block deleted, M2:
// the block moved above X-C's), and the work area to one read on the connect path.
extension BridgeExecWitnessPinTests {

    /// X-C's block condition, as far as both blocks share it.
    private static let arcCompletedCondition =
        "if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && p->rail"
    private static let workAreaCondition = arcCompletedCondition
        + " && (p->workArea.left | p->workArea.top | p->workArea.right | p->workArea.bottom) != 0) {"
    /// The one INFO line: the ARC_COMPLETED marker and the four numbers, nothing else.
    private static let workAreaInfo =
        "WLog_INFO(TAG, \"ClientSystemParam work-area arc-completed %u,%u,%u,%u\", "
        + "(unsigned)p->workArea.left, (unsigned)p->workArea.top, "
        + "(unsigned)p->workArea.right, (unsigned)p->workArea.bottom);"
    private static let monitoredDesktopSignature = "static BOOL crb_monitored_desktop(rdpContext *context,"

    @Test("W9 one work-area sysparam, sent from its own ARC_COMPLETED block right after X-C's")
    func theWorkAreaFollowsTheStartCommandBlock() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        // Exactly one send and one work-area mask in the whole file, both inside crb_monitored_desktop.
        #expect(bridgeOccurrences(of: "ClientSystemParam(", in: code) == 1)
        #expect(bridgeOccurrences(of: "ClientSystemParam(", in: raw) == 1, "no comment quotes the call either")
        #expect(bridgeOccurrences(of: "SPI_MASK_SET_WORK_AREA", in: code) == 1)
        let body = try bridgeCodeOnly(Self.functionBody(Self.monitoredDesktopSignature, in: raw))
        #expect(bridgeOccurrences(of: "ClientSystemParam(", in: body) == 1)
        #expect(bridgeOccurrences(of: "SPI_MASK_SET_WORK_AREA", in: body) == 1)

        // Two blocks share X-C's condition: X-C's own, unchanged, and the work area's.
        #expect(bridgeOccurrences(of: Self.arcCompletedCondition, in: body) == 2)
        #expect(bridgeOccurrences(of: Self.arcCompletedCondition + ") {", in: body) == 1, "X-C's block, unchanged")
        #expect(bridgeOccurrences(of: Self.workAreaCondition, in: body) == 1)
        // The work-area block opens immediately after X-C's block closes (comments in between fold
        // to one space).
        #expect(body.contains("client_rail_server_start_cmd(p->rail); } " + Self.workAreaCondition))
        // And in literal order: X-C's block, the work-area condition, the send, the function's end.
        let xCBlock = try Self.index(of: Self.arcCompletedCondition + ") {", in: body)
        let startCommand = try Self.index(of: "client_rail_server_start_cmd(p->rail); }", in: body)
        let condition = try Self.index(of: Self.workAreaCondition, in: body)
        let send = try Self.index(of: "ClientSystemParam(", in: body)
        let end = try Self.index(of: "return TRUE; }", in: body)
        #expect(xCBlock < startCommand)
        #expect(startCommand < condition)
        #expect(condition < send)
        #expect(send < end)

        // The sysparam carries the work-area mask alone, filled from the per-connection copy.
        #expect(body.contains(
            "RAIL_SYSPARAM_ORDER workAreaParam; memset(&workAreaParam, 0, sizeof(workAreaParam)); "
                + "workAreaParam.params = SPI_MASK_SET_WORK_AREA; workAreaParam.workArea = p->workArea; "
                + "const UINT rc = p->rail->ClientSystemParam(p->rail, &workAreaParam);"))
        // One INFO line, four numbers; a failure is a WARN with the return code.
        #expect(bridgeOccurrences(of: Self.workAreaInfo, in: code) == 1)
        #expect(bridgeOccurrences(of: "\"ClientSystemParam work-area arc-completed %u,%u,%u,%u\"", in: raw) == 1)
        #expect(body.contains("if (rc == CHANNEL_RC_OK) " + Self.workAreaInfo + " else WLog_WARN(TAG, "))
        // X-C stays the last WLog before the start command (re-checked here because this block
        // added WLog calls to the same function).
        let lastWLog = try #require(body[..<startCommand].range(of: "WLog_", options: .backwards))
        #expect(body[lastWLog.lowerBound...].hasPrefix(Self.xC))
    }

    @Test("the four work-area properties are read once, at pre-connect, and validated into the context")
    func theWorkAreaIsReadOnceAtPreConnect() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        let preConnect = try bridgeCodeOnly(Self.functionBody("static BOOL crb_pre_connect(freerdp *instance)", in: raw))
        for edge in ["Left", "Top", "Right", "Bottom"] {
            #expect(bridgeOccurrences(of: "session.workArea\(edge)", in: code) == 1, "read once: \(edge)")
            #expect(bridgeOccurrences(of: "session.workArea\(edge)", in: preConnect) == 1, "on the connect path: \(edge)")
        }
        // Declared once in the per-connection context; cleared, then filled only from a non-empty
        // TS_RECTANGLE_16 -- the UINT16 casts come after the range check.
        #expect(bridgeOccurrences(of: "RECTANGLE_16 workArea;", in: code) == 1)
        #expect(preConnect.contains(
            "memset(&p->workArea, 0, sizeof(p->workArea)); if ((left | top | right | bottom) != 0) { "
                + "if (right > UINT16_MAX || bottom > UINT16_MAX || left >= right || top >= bottom) { WLog_WARN(TAG, "))
        #expect(preConnect.contains(
            "else { p->workArea.left = (UINT16)left; p->workArea.top = (UINT16)top; "
                + "p->workArea.right = (UINT16)right; p->workArea.bottom = (UINT16)bottom; }"))
        // The context's copy is written nowhere else.
        #expect(bridgeOccurrences(of: "p->workArea.left =", in: code) == 1)
        #expect(bridgeOccurrences(of: "memset(&p->workArea,", in: code) == 1)
    }

    // MARK: lane E gate r1 m-3 -- the clamp into the advertised desktop
    //
    // `crb_pre_connect` clamps the four edges it read into the desktop it advertised, through the
    // pure class method `WorkAreaClampTests` drives, BEFORE the validated copy the pin above holds.
    // The order is the point: a clamp after the copy would let a rectangle the clamp empties reach
    // the wire, because the non-empty check would have judged the unclamped edges (mutant MB5);
    // and the copy must be fed the CLAMPED edges, not the raw reads (mutant MB1).

    /// The pure function's declaration / definition, whitespace folded.
    private static let clampSignature =
        "+ (CRWorkAreaClamp)clampWorkAreaLeft:(uint32_t)left top:(uint32_t)top right:(uint32_t)right "
        + "bottom:(uint32_t)bottom toDesktopWidth:(uint32_t)width height:(uint32_t)height"
    /// Its one call: the four raw reads in, the advertised desktop pair as the bound. Re-frozen by
    /// lane-jobkeys-desktop (lane-smoke-wa gate r1 O-2): the bound is the local pair
    /// `crb_pre_connect` reads once from the session, the same values it sets as the desktop.
    private static let clampCall =
        "const CRWorkAreaClamp clamped = [CRSession clampWorkAreaLeft:rawLeft top:rawTop right:rawRight "
        + "bottom:rawBottom toDesktopWidth:desktopWidth height:desktopHeight];"
    /// The clamp's WARN: numbers only.
    private static let clampWarnFormat =
        "\"work area %u,%u,%u,%u exceeds the advertised desktop %ux%u -- clamped to %u,%u,%u,%u (F-ja-4 m-3)\""

    @Test("m-3 the work area is clamped into the advertised desktop at pre-connect, before the validated copy")
    func theWorkAreaIsClampedBeforeTheValidatedCopy() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        let header = try String(contentsOf: bridgeRepoRoot().appendingPathComponent("App/CRBridge/CRSession.h"),
                                encoding: .utf8)
        // Declared once in the header, defined once in the bridge, called once -- from the connect
        // path -- and nowhere else.
        #expect(bridgeOccurrences(of: Self.clampSignature + ";", in: bridgeFolded(header)) == 1)
        #expect(bridgeOccurrences(of: Self.clampSignature + " {", in: code) == 1)
        #expect(bridgeOccurrences(of: "[CRSession clampWorkAreaLeft:", in: code) == 1)
        #expect(bridgeOccurrences(of: "clampWorkAreaLeft:", in: code) == 2, "the definition and the one call")
        let preConnect = try bridgeCodeOnly(Self.functionBody("static BOOL crb_pre_connect(freerdp *instance)", in: raw))
        #expect(bridgeOccurrences(of: Self.clampCall, in: preConnect) == 1)

        // In literal order inside crb_pre_connect: the four reads, the call, the WARN, the copy's
        // memset -- and the edges the copy validates are the CLAMPED ones, handed over right before it.
        let call = try Self.index(of: Self.clampCall, in: preConnect)
        let memset = try Self.index(of: "memset(&p->workArea,", in: preConnect)
        for edge in ["Left", "Top", "Right", "Bottom"] {
            let read = try Self.index(of: "const uint32_t raw\(edge) = session.workArea\(edge);", in: preConnect)
            #expect(read < call, "read before the clamp: \(edge)")
        }
        #expect(call < memset, "the clamp comes before the validated copy")
        let warn = try Self.index(of: "if (clamped.changed) { WLog_WARN(TAG, " + Self.clampWarnFormat, in: preConnect)
        #expect(call < warn)
        #expect(warn < memset)
        #expect(preConnect.contains(
            "const uint32_t left = clamped.left; const uint32_t top = clamped.top; "
                + "const uint32_t right = clamped.right; const uint32_t bottom = clamped.bottom; "
                + "memset(&p->workArea, 0, sizeof(p->workArea));"), "the validated copy is fed the clamped edges")

        // The WARN's format string exists once, and its statement prints numbers only.
        #expect(bridgeOccurrences(of: Self.clampWarnFormat, in: raw) == 1)
        let warnStatement = preConnect[warn...].prefix { $0 != ";" }
        #expect(!warnStatement.contains("%s"), "the clamp WARN prints a string")
    }

    @Test("O-2 crb_pre_connect reads the session's desktop pair once and shares it between the setting and the clamp")
    func theDesktopPairIsReadOnce() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        let preConnect = try bridgeCodeOnly(Self.functionBody("static BOOL crb_pre_connect(freerdp *instance)", in: raw))
        #expect(bridgeOccurrences(of: "session.desktopWidth", in: preConnect) == 1)
        #expect(bridgeOccurrences(of: "session.desktopHeight", in: preConnect) == 1)
        let readWidth = "const uint32_t desktopWidth = session.desktopWidth;"
        let readHeight = "const uint32_t desktopHeight = session.desktopHeight;"
        #expect(bridgeOccurrences(of: readWidth, in: preConnect) == 1)
        #expect(bridgeOccurrences(of: readHeight, in: preConnect) == 1)
        let width = try Self.index(of: readWidth, in: preConnect)
        let height = try Self.index(of: readHeight, in: preConnect)
        let setting = try Self.index(of: "FreeRDP_DesktopWidth,", in: preConnect)
        let call = try Self.index(of: Self.clampCall, in: preConnect)
        #expect(width < setting, "the width is read before the desktop is set")
        #expect(height < setting, "the height is read before the desktop is set")
        #expect(setting < call)
        #expect(bridgeOccurrences(of: "freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, desktopWidth)",
                                  in: preConnect) == 1)
        #expect(bridgeOccurrences(of: "freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, desktopHeight)",
                                  in: preConnect) == 1)
        #expect(bridgeOccurrences(of: "toDesktopWidth:session.desktopWidth", in: code) == 0)
        // gate r1 I-1 (lane-jobkeys-desktop): `[session desktopWidth]` is the same getter as the dotted
        // read -- a re-read through it at any site (the WARN's arguments, the setting's gate) passed the
        // pins above. Zero message sends anywhere in the file, exactly one dotted read of each property
        // inside the function, and the two sites that were not spelled out above frozen as well.
        #expect(bridgeOccurrences(of: "session desktopWidth]", in: code) == 0)
        #expect(bridgeOccurrences(of: "session desktopHeight]", in: code) == 0)
        #expect(bridgeOccurrences(of: ".desktopWidth", in: preConnect) == 1)
        #expect(bridgeOccurrences(of: ".desktopHeight", in: preConnect) == 1)
        #expect(bridgeOccurrences(of: "if (desktopWidth > 0 && desktopHeight > 0)", in: preConnect) == 1)
        #expect(bridgeOccurrences(of: "(unsigned)desktopWidth, (unsigned)desktopHeight,", in: preConnect) == 1)
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
        // Gate r1 I-1 (a): WLog_ is not the only way to print. No other logging or printing call
        // shape at all in this body (CRSession.mm uses NSLog elsewhere, so the form is real).
        for shape in ["NSLog(", "printf(", "fprintf(", "os_log(", "syslog("] {
            #expect(bridgeOccurrences(of: shape, in: method) == 0, "-launchProgram:arguments: calls \(shape)")
        }
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

// MARK: - lane-handshake-followups: the bridge forwards the RAIL handshake to FreeRDP's default handlers
extension BridgeExecWitnessPinTests {

    private static let handshakeSignature =
        "static UINT crb_rail_server_handshake(RailClientContext *context, const RAIL_HANDSHAKE_ORDER *handshake)"
    private static let handshakeExSignature = "static UINT crb_rail_server_handshake_ex(RailClientContext *context,"

    /// Both wrappers as they stand, comments stripped and whitespace folded.
    private static let handshakeBodyFolded =
        handshakeSignature + " { CRBridgeContext *p = (CRBridgeContext *)context->custom; CrdpEvent ev; "
        + "memset(&ev, 0, sizeof(ev)); ev.type = CRDPQ_EVENT_HANDSHAKE_FLAGS; "
        + "ev.payload.handshakeFlags.buildNumber = handshake->buildNumber; crdpq_post(crb_control(p), &ev); "
        + "if (p->orig_ServerHandshake) return p->orig_ServerHandshake(context, handshake); return CHANNEL_RC_OK; }"
    private static let handshakeExBodyFolded =
        handshakeExSignature + " const RAIL_HANDSHAKE_EX_ORDER *handshakeEx) { "
        + "CRBridgeContext *p = (CRBridgeContext *)context->custom; CrdpEvent ev; "
        + "memset(&ev, 0, sizeof(ev)); ev.type = CRDPQ_EVENT_HANDSHAKE_FLAGS; "
        + "ev.payload.handshakeFlags.buildNumber = handshakeEx->buildNumber; "
        + "ev.payload.handshakeFlags.railHandshakeFlags = handshakeEx->railHandshakeFlags; "
        + "crdpq_post(crb_control(p), &ev); "
        + "if (p->orig_ServerHandshakeEx) return p->orig_ServerHandshakeEx(context, handshakeEx); return CHANNEL_RC_OK; }"
    /// Save the defaults, then override the slots: one block, in this order.
    private static let handshakeInstallBlock =
        "p->orig_ServerHandshake = rail->ServerHandshake; p->orig_ServerHandshakeEx = rail->ServerHandshakeEx; "
        + "rail->ServerHandshake = crb_rail_server_handshake; rail->ServerHandshakeEx = crb_rail_server_handshake_ex;"
    /// The RAIL branch of the channel-connected callback, from its signature through the install block:
    /// the branch condition, `rail->custom = p;`, the window callbacks, then the install block, contiguous.
    private static let handshakeConnectedHead =
        "static void crb_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) { "
        + "CRBridgeContext *p = (CRBridgeContext *)context; if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0) { "
        + "RailClientContext *rail = (RailClientContext *)e->pInterface; p->rail = rail; rail->custom = p; "
        + "rdpWindowUpdate *window = p->common.context.update->window; window->WindowCreate = crb_window_common; "
        + "window->WindowUpdate = crb_window_common; window->WindowDelete = crb_window_delete; "
        + "window->WindowIcon = crb_window_icon; window->WindowCachedIcon = crb_window_cached_icon; "
        + "window->NotifyIconCreate = crb_notify_icon_create; window->NotifyIconUpdate = crb_notify_icon_update; "
        + "window->NotifyIconDelete = crb_notify_icon_delete; window->MonitoredDesktop = crb_monitored_desktop; "
        + "window->NonMonitoredDesktop = crb_non_monitored_desktop; " + handshakeInstallBlock
    private static let handshakeSubscription =
        "if (PubSub_SubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected) < 0) return FALSE;"

    /// `crb_pre_connect`'s tail: both subscriptions, the function's end and the next function's start.
    private static let handshakePreConnectTail =
        "if (PubSub_SubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected) < 0) return FALSE; "
        + "if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, crb_on_channel_disconnected) < 0) "
        + "return FALSE; return TRUE; } static BOOL crb_post_connect(freerdp *instance) {"
    /// The disconnect callback up to the end of its RAIL branch (the one place `rail->custom` is cleared).
    private static let handshakeDisconnectHead =
        "static void crb_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) { "
        + "CRBridgeContext *p = (CRBridgeContext *)context; if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0) { "
        + "if (p->rail) p->rail->custom = NULL; p->rail = NULL; }"
    /// `crb_post_disconnect` up to the one unsubscribe.
    private static let handshakePostDisconnectHead =
        "static void crb_post_disconnect(freerdp *instance) { "
        + "PubSub_UnsubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected);"
    /// The only `#define` lines the file may carry, verbatim and in order.
    private static let handshakeFrozenDefines = [
        "#define __STDC_WANT_LIB_EXT1__ 1",
        "#define TAG CLIENT_TAG(\"macdows\")",
    ]

    /// What the lexer view reports besides its text.
    private struct HandshakeScan {
        var view = ""
        var rawStringStarts = 0
        /// `'` directly after `[A-Za-z0-9_]` in code: digit separators and prefixed character literals.
        var quotesAfterIdentifier = 0
        /// Preprocessor lines other than `include` / `import` / `define`, and an include whose header name
        /// carries a comment opener or is not a literal `<...>` / `"..."` (a trailing comment is accepted).
        var badDirectives: [String] = []
        var defines: [String] = []
    }

    /// Count of the raw-text shapes the scanner does not model and therefore refuses: CR, FF, VT and NUL
    /// scalars, and a backslash followed by blanks (space, tab, FF, VT) and a newline (LF or CR), which
    /// clang treats as a line splice. The file has none of them today; a future multi-line macro would
    /// have to relax this on purpose and extend the scanner.
    private static func unmodelledByteCount(_ text: String) -> Int {
        let s = Array(text.unicodeScalars)
        var count = s.filter { $0 == "\r" || $0 == "\u{0B}" || $0 == "\u{0C}" || $0 == "\u{00}" }.count
        for k in s.indices where s[k] == "\\" {
            var j = k + 1
            while j < s.count, s[j] == " " || s[j] == "\t" || s[j] == "\u{0B}" || s[j] == "\u{0C}" { j += 1 }
            if j < s.count, s[j] == "\n" || s[j] == "\r" { count += 1 }
        }
        return count
    }

    /// Occurrences compared scalar by scalar (`.literal`): Swift's default string equality is canonical
    /// equivalence, under which U+212A KELVIN SIGN equals `K`, while C identifiers compare by bytes.
    private static func exactOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var from = haystack.startIndex
        while let hit = haystack.range(of: needle, options: .literal, range: from..<haystack.endIndex) {
            count += 1
            from = hit.upperBound
        }
        return count
    }

    /// The file's text as the compiler's lexer sees it, for text without CR / FF / VT / NUL and without
    /// backslash line splices (`unmodelledByteCount` refuses those first). One scan over Unicode scalars
    /// (C's lexer does not know grapheme clusters; a quote followed by a combining mark is still a quote)
    /// with five states: code, `//` comment (to the end of the line), `/* */` comment (to the first
    /// `*/`; an unterminated one drops the rest), string literal and character literal (backslash
    /// escapes honoured). Comments become one space; the CONTENT of string and character literals is
    /// dropped (the quotes stay), so a string can neither open a comment nor stand in for a statement.
    /// Whitespace is then folded. Comment openers are recognised only in the code state. Also reported:
    /// raw string starts (`R"`, with an `u8` / `u` / `U` / `L` prefix or none, seen in the code state),
    /// `'` directly after an identifier character (digit separators), and preprocessor lines (a `#` that
    /// is the first thing on a line, comments counting as blanks, as in clang) other than `include`,
    /// `import` and `define`. The scanner models none of raw strings, digit separators, trigraphs,
    /// digraphs or directive-specific lexing; the test forbids the first three outright and refuses
    /// every directive except `include` / `import` / the two frozen `#define`s.
    private static func scanHandshakeView(_ text: String) -> HandshakeScan {
        var result = HandshakeScan()
        let s = Array(text.unicodeScalars)
        func isIdentifierScalar(_ u: Unicode.Scalar) -> Bool {
            (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || u == "_"
        }
        var out = String.UnicodeScalarView()
        var lineStart = true
        var i = 0
        while i < s.count {
            let c = s[i]
            let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
            if c == "/", next == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                out.append(" ")
            } else if c == "/", next == "*" {
                var j = i + 2
                while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                if j + 1 >= s.count {
                    result.view = bridgeFolded(String(out))
                    return result
                }
                i = j + 2
                out.append(" ")
            } else if c == "\"" || c == "'" {
                if c == "\"", i > 0, s[i - 1] == "R" {
                    var start = i - 1
                    while start > 0, isIdentifierScalar(s[start - 1]) { start -= 1 }
                    var prefix = String.UnicodeScalarView()
                    prefix.append(contentsOf: s[start..<(i - 1)])
                    if ["", "u8", "u", "U", "L"].contains(String(prefix)) { result.rawStringStarts += 1 }
                }
                if c == "'", i > 0, isIdentifierScalar(s[i - 1]) { result.quotesAfterIdentifier += 1 }
                out.append(c)
                i += 1
                while i < s.count, s[i] != c, s[i] != "\n" {
                    if s[i] == "\\", i + 1 < s.count { i += 1 }
                    i += 1
                }
                if i < s.count, s[i] == c { out.append(c); i += 1 }
                lineStart = false
            } else if c == "\n" {
                out.append(c)
                lineStart = true
                i += 1
            } else if c == " " || c == "\t" {
                out.append(c)
                i += 1
            } else if c == "#", lineStart {
                var end = i
                while end < s.count, s[end] != "\n" { end += 1 }
                var line = String.UnicodeScalarView()
                line.append(contentsOf: s[i..<end])
                let directive = String(line).trimmingCharacters(in: .whitespaces)
                var k = 1
                while k < line.count, [" ", "\t"].contains(Array(line)[k]) { k += 1 }
                var name = ""
                while k < line.count, Array(line)[k].properties.isAlphabetic { name.unicodeScalars.append(Array(line)[k]); k += 1 }
                if name == "define" {
                    result.defines.append(directive)
                } else if name == "include" || name == "import" {
                    // The header name between <> or "" is lexed as one token, so a comment opener inside
                    // it would be wrong for the scan; a trailing comment after it is fine.
                    let after = directive.drop { $0 != "<" && $0 != "\"" }
                    if let open = after.first, let close = after.dropFirst().firstIndex(of: open == "<" ? ">" : "\"") {
                        let header = after[after.index(after.startIndex, offsetBy: 1)..<close]
                        if header.contains("/*") || header.contains("//") { result.badDirectives.append(directive) }
                    } else {
                        result.badDirectives.append(directive)
                    }
                } else {
                    result.badDirectives.append(directive)
                }
                out.append(c)
                lineStart = false
                i += 1
            } else {
                out.append(c)
                lineStart = false
                i += 1
            }
        }
        result.view = bridgeFolded(String(out))
        return result
    }

    /// The bridge replaces the RAIL channel's two handshake callbacks with wrappers that post an event
    /// and then forward to the FreeRDP default handler it saved. That forward is the only path that
    /// sends the client status (CLIENTSTATUS) before the monitored-desktop ARC notification, which the
    /// current host withholds until it has the status (the start command at ARC_COMPLETED sends it
    /// again, too late). FreeRDP's default handshake handler sends it right after the handshake (patch
    /// 0003 / upstream PR 13696). Tier 1 (`check-patch-queue.sh`) and Tier 2 (`rail-handshake-check`)
    /// judge the prefix and cannot see the bridge, so this pin holds the bridge's side.
    ///
    /// The approach is a closed syntax: whatever the small scanner does not model is refused outright
    /// (none of it occurs in `CRSession.mm` today), rather than chasing every corner of clang's lexer.
    /// Refused: CR, FF, VT and NUL, backslash line splices, C++ raw string literals, `'` directly after
    /// an identifier character (digit separators, prefixed character literals), any non-ASCII scalar in
    /// the code (after comments and literal contents are removed), any preprocessor line except
    /// `include` / `import` (with a literal header name that carries no comment opener; a comment after
    /// the header name is accepted) and the two frozen `#define`s. Within what is accepted, the scan
    /// follows the compiler: both comment kinds, string and character literals.
    ///
    /// What it holds (all read in that view, whose string and character literals are emptied, so a
    /// string can neither hide a statement nor stand in for one; the shared helpers `bridgeCodeOnly` /
    /// `functionBody` are not used and were not changed):
    ///  * both wrapper bodies frozen whole, each present exactly once;
    ///  * the premises of the forward, frozen in place: FreeRDP only calls a `Server*` callback when
    ///    `context->custom` is set (`channels/rail/client/rail_orders.c`, `ServerHandshake` at line 372,
    ///    `ServerHandshakeEx` at line 484), and `rail->custom = p;` runs only inside the RAIL branch of
    ///    `crb_on_channel_connected`, which runs only when that callback is subscribed. So the callback
    ///    from its signature through the four-line install block (save before override) is one frozen
    ///    text; the tail of `crb_pre_connect` (both subscriptions, `return TRUE; }`, the next function's
    ///    start), the disconnect callback through the RAIL branch's `custom` clear, and
    ///    `crb_post_disconnect` through its one unsubscribe are frozen too; `->custom = ` is assigned
    ///    exactly twice and there is exactly one unsubscribe;
    ///  * call and assignment shapes of the saved pointers and the callback slots, each exactly one;
    ///  * total mention counts that account for the prefix overlap (`orig_ServerHandshake` is a prefix of
    ///    `orig_ServerHandshakeEx`, `ServerHandshake` of `ServerHandshakeEx`): any spelling that names
    ///    one of these identifiers counts, so an assignment without spaces, a `memset` into a named
    ///    field, a local alias, an extra mention of a wrapper, or an extra `custom` or
    ///    `crb_on_channel_connected` mention changes a number;
    ///  * needles are matched scalar by scalar (`.literal`), and the view must be pure ASCII.
    ///
    /// What it cannot hold (registered, not chased): preprocessing and definitions inside the headers
    /// `CRSession.mm` includes; a write that does not name the field (pointer arithmetic from a
    /// neighbouring field, a `memset` over a range or over a whole `CRBridgeContext` or
    /// `RailClientContext`); the behaviour of functions the frozen text calls (`crb_control`,
    /// `crdpq_post`); trigraphs and digraphs; and a same-named definition supplied from another
    /// translation unit. Frozen text is deliberate: changing a wrapper, one of the frozen regions
    /// (including the ten `window->` assignments in the connected callback) or a counted name on purpose
    /// means re-freezing the needles above.
    @Test("the bridge's RAIL handshake wrappers forward to FreeRDP's default handlers, saved before the override")
    func theHandshakeWrappersForwardToTheDefaults() throws {
        let raw = try Self.raw()

        // Scanner and gate self-checks: fixed inputs, so a broken scanner cannot quietly widen or narrow
        // the pin. The view holds literals emptied, comments gone, whitespace folded.
        func view(_ text: String) -> String { Self.scanHandshakeView(text).view }
        #expect(view("a = \"/*\"; b; c = \"*/\";") == "a = \"\"; b; c = \"\";",
                "scanner: a string literal opened a comment")
        #expect(view("a; // /* b\nc; // */ d\ne;") == "a; c; e;", "scanner: a // line opened a block comment")
        #expect(view("a; /* x\ny */ b; // c\nd;") == "a; b; d;", "scanner: a block comment or a // line ran wrong")
        #expect(view("c = '\"'; d = \"x\"; /* gone */ e;") == "c = ''; d = \"\"; e;",
                "scanner: a character literal holding a quote opened a string")
        #expect(view("c = '\\''; d = \"/*\"; x; e = \"*/\";") == "c = ''; d = \"\"; x; e = \"\";",
                "scanner: an escaped quote ended a character literal")
        #expect(view("s = \"a\\\"b/*\"; t;") == "s = \"\"; t;", "scanner: an escaped quote ended a string")
        #expect(view("a; /* never closed b; c;") == "a;", "scanner: an unterminated block comment kept the rest")
        #expect(view("a = \"\u{301}/*\"; b; c = \"\u{301}*/\"; d;") == "a = \"\"; b; c = \"\"; d;",
                "scanner: a quote followed by a combining mark was not recognised as a string start")
        #expect(view("x = \"p->orig_ServerHandshake(\";") == "x = \"\";",
                "scanner: a string literal's content stayed in the view, so it could stand in for code")
        #expect(Self.exactOccurrences(of: "K", in: "HANDSHA\u{212A}E") == 0,
                "matching: U+212A KELVIN SIGN matched K")
        #expect(Self.scanHandshakeView("x = HANDSHA\u{212A}E;").view.unicodeScalars.contains { !$0.isASCII },
                "scanner: a non-ASCII identifier scalar did not survive into the view")
        for raw in ["s = R\"(a)\";", "s = u8R\"x(b)x\";", "s = uR\"(a)\";", "s = UR\"(a)\";", "s = LR\"(a)\";"] {
            #expect(Self.scanHandshakeView(raw).rawStringStarts == 1, "scanner: raw string start not counted: \(raw)")
        }
        #expect(Self.scanHandshakeView("a = \"WLOG_APPENDER\", \"b\"; PAIR(x);").rawStringStarts == 0,
                "scanner: a string ending in R counted as a raw string start")
        for (text, expected) in [("a = 1'0;", 1), ("b = u8'x';", 1), ("c = 'a'; f('a'); d = '\\'';", 0)] {
            #expect(Self.scanHandshakeView(text).quotesAfterIdentifier == expected,
                    "scanner: ' after an identifier character miscounted in \(text)")
        }
        for text in ["#pragma mark see /* below\n", "  #  undef A\n", "#if 0\n", "#error e\n", "#warning w\n",
                     "# line 5\n", "#ident \"x\"\n", "#include <a/*b.h>\n", "#include <a//b.h>\n", "#elif 1\n",
                     "#include FOO\n"] {
            #expect(Self.scanHandshakeView(text).badDirectives.count == 1, "scanner: directive not refused: \(text)")
        }
        for text in ["#include <a/b.h> /* c */\n", "  # import <c.h>\n", "#include \"d.h\" // e\n",
                     "x; // #pragma q\n", "x; #pragma not-a-directive\n", "/* #if 0 */\nx;\n"] {
            #expect(Self.scanHandshakeView(text).badDirectives.isEmpty, "scanner: a non-directive was refused: \(text)")
        }
        #expect(Self.scanHandshakeView("#define A 1\n/* c */ #define B 2\nx; #define C 3\n").defines
                    == ["#define A 1", "#define B 2"], "scanner: #define lines not collected")
        for bad in ["a\rb", "a\u{0B}b", "a\u{0C}b", "a\u{00}b", "a \\\nb", "a \\ \nb", "a \\\t\nb", "a \\\r\nb",
                    "a \\\u{0C}\nb", "a \\\u{0B}\rb"] {
            #expect(Self.unmodelledByteCount(bad) > 0, "gate: an unmodelled byte shape was not found: \(bad.debugDescription)")
        }
        #expect(Self.unmodelledByteCount("a;\nb \\n; \"\\\\\"\n") == 0, "gate: a clean text was reported")

        // The file itself: none of the refused shapes.
        #expect(Self.unmodelledByteCount(raw) == 0,
                "CRSession.mm holds CR / FF / VT / NUL or a backslash line splice, which the pin's scanner does not model")
        let scan = Self.scanHandshakeView(raw)
        #expect(scan.rawStringStarts == 0,
                "the file holds a raw string literal start (R\"), which the scanner does not model")
        #expect(scan.quotesAfterIdentifier == 0,
                "the file holds a ' right after an identifier character (digit separator or prefixed literal)")
        #expect(scan.badDirectives.isEmpty, "the file holds a preprocessor line other than include / import / define: \(scan.badDirectives)")
        #expect(scan.defines == Self.handshakeFrozenDefines, "the file's #define lines changed: \(scan.defines)")
        let code = scan.view
        #expect(!code.unicodeScalars.contains { !$0.isASCII }, "the code holds a non-ASCII scalar outside comments and literals")
        let why = "the pinned text changed; if the bridge no longer hands the RAIL handshake to FreeRDP's "
            + "default handler, the client status (CLIENTSTATUS) is not sent and the current host sends no "
            + "window events -- re-freeze only after confirming the forward still happens"

        // Frozen texts, each present exactly once in the view (the wrapper bodies are the code's own
        // definitions; the premises are frozen in place).
        let frozen: [(String, String)] = [
            (Self.handshakeBodyFolded, "crb_rail_server_handshake"),
            (Self.handshakeExBodyFolded, "crb_rail_server_handshake_ex"),
            (Self.handshakeInstallBlock, "the save-then-override block"),
            (Self.handshakeConnectedHead, "the RAIL branch of crb_on_channel_connected (condition, rail->custom = p, install block)"),
            (Self.handshakeSubscription, "the channel-connected subscription"),
            (Self.handshakePreConnectTail, "the tail of crb_pre_connect (both subscriptions)"),
            (Self.handshakeDisconnectHead, "the disconnect callback's RAIL branch (rail->custom cleared)"),
            (Self.handshakePostDisconnectHead, "crb_post_disconnect up to the unsubscribe"),
        ]
        for (text, label) in frozen {
            #expect(Self.exactOccurrences(of: text, in: code) == 1, "\(label) is not present exactly once as frozen: \(why)")
        }

        let counted: [(String, String)] = [
            ("p->orig_ServerHandshake(", "forwarding call"),
            ("p->orig_ServerHandshakeEx(", "forwarding call (Ex)"),
            ("orig_ServerHandshake = ", "assignment to the saved pointer"),
            ("orig_ServerHandshakeEx = ", "assignment to the saved pointer (Ex)"),
            ("rail->ServerHandshake = ", "assignment to the callback slot"),
            ("rail->ServerHandshakeEx = ", "assignment to the callback slot (Ex)"),
            ("static UINT crb_rail_server_handshake(", "wrapper definition"),
            ("static UINT crb_rail_server_handshake_ex(", "wrapper definition (Ex)"),
            ("->custom = ", "assignment to a ->custom field (set on connect, cleared on disconnect)"),
            ("PubSub_UnsubscribeChannelConnected(", "unsubscribe from channel-connected"),
        ]
        for (needle, label) in counted {
            let expected = needle == "->custom = " ? 2 : 1
            #expect(Self.exactOccurrences(of: needle, in: code) == expected,
                    "\(label) `\(needle)` is not exactly \(expected): \(why)")
        }

        // Total mentions of these names in the view, whatever the spelling:
        // orig_ServerHandshake: declaration 2 + save 2 + null check 2 + call 2 (the Ex names included);
        // rail->ServerHandshake: slot read while saving 2 + slot write while overriding 2 (the Ex names
        // included); crb_rail_server_handshake: two definitions + two installs (the Ex name included);
        // ServerHandshake: types 2 + fields 2 + wrappers 4 + install block 6;
        // custom: six handlers read it once each + set on connect + cleared on disconnect + one read
        // in the outbound input path; crb_on_channel_connected: definition + subscribe + unsubscribe.
        let mentions: [(String, Int)] = [
            ("orig_ServerHandshake", 8), ("rail->ServerHandshake", 4), ("crb_rail_server_handshake", 4),
            ("ServerHandshake", 14), ("custom", 9), ("crb_on_channel_connected", 3),
        ]
        for (needle, expected) in mentions {
            #expect(Self.exactOccurrences(of: needle, in: code) == expected,
                    "`\(needle)` is not mentioned exactly \(expected) times in the code: \(why)")
        }
    }
}
