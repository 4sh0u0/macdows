import Foundation
import Testing

// adr/0021 lane CA-2 (owner ruling 2026-10-06 on P-CA1-1: "add the observation-only key witness
// first, then check in the field"). The CA-1 offline read found no carrier anywhere that shows a
// keyboard event leaving the client (its §3 Q6, §6 ⑥). This lane adds one, default off:
//
//  * `MACDOWS_KEY_WITNESS=1` (that literal and nothing else) -> `ShellAutolaunch.Plan.keyWitness`
//    -> `AppDelegate` sets `CRSession.keyWitnessEnabled` (held by `AppDelegateAutolaunchPinTests`
//    Pin 9) -> `-start` copies it into the new connection's `CRBridgeContext::keyWitness`.
//  * `crb_outbound_visitor`'s CRDPQ_CMD_INPUT branch then prints one `[key-witness]` INFO line
//    right after each of its two keyboard send calls, on T_rdp, in send order:
//      [key-witness] seq=<n> kind=scancode flags=0x<4 hex> code=0x<2 hex> rc=<0|1>
//      [key-witness] seq=<n> kind=unicode flags=0x<4 hex> rc=<0|1>
//    The Unicode line never carries the code unit (a character the user typed).
//
// The bridge cannot be compiled into this bundle (`App/project.yml` gives it `MacdowsAppTests`,
// `RemoteWindowRendering` and `SessionControl` only), so -- like `BridgeExecWitnessPinTests` --
// the bridge half is pinned as source text, and the knob-off "zero output" claim is a source pin
// too: no stub world here can drive `crb_outbound_visitor`.

// MARK: - (a) the knob's grammar

@Suite("adr/0021 lane CA-2 — MACDOWS_KEY_WITNESS, parsed")
struct KeyWitnessKnobTests {

    @Test("the key name is the one the field run exports")
    func keyName() {
        #expect(ShellAutolaunch.keyWitnessKey == "MACDOWS_KEY_WITNESS")
    }

    @Test("off is off, and an empty environment plans no key witness")
    func defaultIsOff() {
        #expect(ShellAutolaunch.off.keyWitness == false)
        #expect(ShellAutolaunch.plan(environment: [:]).keyWitness == false)
        #expect(ShellAutolaunch.plan(environment: [:]) == ShellAutolaunch.off)
    }

    @Test("exactly \"1\" turns it on")
    func oneIsOn() {
        #expect(ShellAutolaunch.plan(environment: ["MACDOWS_KEY_WITNESS": "1"]).keyWitness == true)
    }

    /// The accepted set is {"1"}. Everything else is off, with no trimming and no truthy synonyms:
    /// the same exact-literal grammar as `MACDOWS_AUTOCONNECT`.
    @Test(
        "every other value is off",
        arguments: [
            "", "0", " 1", "1 ", " 1 ", "\t1", "1\n", "01", "1.0", "+1", "11", "2", "-1",
            "true", "TRUE", "yes", "on", "enabled", "\u{0661}", "\u{FF11}",
        ])
    func everythingElseIsOff(_ value: String) {
        #expect(ShellAutolaunch.plan(environment: ["MACDOWS_KEY_WITNESS": value]).keyWitness == false)
    }

    @Test("near-miss key names are not read")
    func nearMissKeys() {
        for key in ["macdows_key_witness", "MACDOWS_KEYWITNESS", "MACDOWS_KEY_WITNESSES", "KEY_WITNESS", " MACDOWS_KEY_WITNESS"] {
            #expect(ShellAutolaunch.plan(environment: [key: "1"]).keyWitness == false, "\(key)")
        }
    }

    /// Independent in both directions: turning it on changes no other field, and no other knob
    /// (all six set to valid, scheduling values) turns it on.
    @Test("independent of the six launch knobs")
    func independent() {
        let launch: [String: String] = [
            "MACDOWS_AUTOCONNECT": "1",
            "MACDOWS_QUIT_AFTER_SECONDS": "120",
            "MACDOWS_DISCONNECT_AFTER_SECONDS": "60",
            "MACDOWS_RECONNECT_AFTER_SECONDS": "10",
            "MACDOWS_EXTRA_EXEC_AFTER_SECONDS": "30",
            "MACDOWS_EXTRA_EXEC_PROGRAM": "p",
        ]
        let without = ShellAutolaunch.plan(environment: launch)
        #expect(without.keyWitness == false)
        let with = ShellAutolaunch.plan(environment: launch.merging(["MACDOWS_KEY_WITNESS": "1"]) { $1 })
        #expect(with.keyWitness == true)
        #expect(with.autoconnect == without.autoconnect)
        #expect(with.quitAfter == without.quitAfter)
        #expect(with.disconnectAfter == without.disconnectAfter)
        #expect(with.reconnectAfter == without.reconnectAfter)
        #expect(with.extraExecAfter == without.extraExecAfter)
        #expect(with.extraExecProgram == without.extraExecProgram)
        // And alone: on, with every launch knob off.
        let alone = ShellAutolaunch.plan(environment: ["MACDOWS_KEY_WITNESS": "1"])
        #expect(alone == ShellAutolaunch.Plan(
            autoconnect: false, quitAfter: nil, disconnectAfter: nil, reconnectAfter: nil, keyWitness: true))
    }
}

// MARK: - (b) (c) (d) the bridge half, pinned as source

private func keyWitnessRepoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func keyWitnessOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private func keyWitnessFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `/* ... */` comments removed, then folded -- the same stripper `BridgeExecWitnessPinTests`
/// uses, because this lane's own block comments name `[key-witness]` and the fields it pins.
private func keyWitnessCodeOnly(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "/*") {
        out += rest[rest.startIndex..<open.lowerBound]
        out += " "
        guard let close = rest[open.upperBound...].range(of: "*/") else { return keyWitnessFolded(out) }
        rest = rest[close.upperBound...]
    }
    out += rest
    return keyWitnessFolded(out)
}

@Suite("adr/0021 lane CA-2 — the bridge's [key-witness] lines, pinned as source")
struct KeyWitnessBridgePinTests {

    static let scancodeFormat = "[key-witness] seq=%u kind=scancode flags=0x%04x code=0x%02x rc=%d"
    static let unicodeFormat = "[key-witness] seq=%u kind=unicode flags=0x%04x rc=%d"

    static let scancodeSend =
        "const BOOL keyRc = freerdp_input_send_keyboard_event(context->input, cmd->payload.input.flags, "
        + "(UINT8)cmd->payload.input.code);"
    static let scancodeLine =
        "WLog_INFO(TAG, \"" + scancodeFormat + "\", (unsigned)p->keyWitnessSeq, "
        + "(unsigned)(UINT16)cmd->payload.input.flags, (unsigned)(UINT8)cmd->payload.input.code, keyRc ? 1 : 0);"
    static let unicodeSend =
        "const BOOL unicodeRc = freerdp_input_send_unicode_keyboard_event(context->input, cmd->payload.input.flags, "
        + "cmd->payload.input.code);"
    static let unicodeLine =
        "WLog_INFO(TAG, \"" + unicodeFormat + "\", (unsigned)p->keyWitnessSeq, "
        + "(unsigned)(UINT16)cmd->payload.input.flags, unicodeRc ? 1 : 0);"

    private static func raw(_ relative: String = "App/CRBridge/CRSession.mm") throws -> String {
        try String(contentsOf: keyWitnessRepoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private static func code() throws -> String {
        try keyWitnessCodeOnly(raw())
    }

    private static func index(of needle: String, in haystack: String) throws -> String.Index {
        try #require(haystack.range(of: needle), "not found: \(needle)").lowerBound
    }

    /// The CRDPQ_CMD_INPUT branch of `crb_outbound_visitor`, folded and comment-free: from its
    /// `case` label to the visitor's `default:` label that follows it.
    private static func inputBranch() throws -> String {
        let code = try code()
        let start = try index(of: "case CRDPQ_CMD_INPUT:", in: code)
        let end = try #require(code[start...].range(of: "default: break;"), "no default after the INPUT case").lowerBound
        return String(code[start..<end])
    }

    @Test("the comment stripper leaves the code it is asked about intact")
    func theStripperKeepsTheCode() throws {
        let code = try Self.code()
        #expect(code.contains("static void crb_outbound_visitor(const CrdpCommand *cmd, void *vctx)"))
        #expect(code.contains("case CRDPQ_CMD_INPUT:"))
        #expect(code.contains("- (void)start"))
        #expect(code.hasSuffix("@end"), "the stripper ate the tail of the file")
    }

    // MARK: (b) exactly two print points, each right after its own send call

    @Test("exactly two [key-witness] print points in the bridge's code, both in the INPUT branch")
    func exactlyTwoPrintPoints() throws {
        let code = try Self.code()
        #expect(keyWitnessOccurrences(of: "[key-witness]", in: code) == 2)
        let branch = try Self.inputBranch()
        #expect(keyWitnessOccurrences(of: "[key-witness]", in: branch) == 2)
        #expect(keyWitnessOccurrences(of: "WLog_", in: branch) == 2, "the INPUT branch logged nothing before this lane")
        // Each send call is still made exactly once in the whole file.
        #expect(keyWitnessOccurrences(of: "freerdp_input_send_keyboard_event(", in: code) == 1)
        #expect(keyWitnessOccurrences(of: "freerdp_input_send_unicode_keyboard_event(", in: code) == 1)
        #expect(keyWitnessOccurrences(of: "freerdp_input_send_mouse_event(", in: code) == 1)
    }

    /// Each line is the statement right after its send call, inside `if (p->keyWitness) { ... }`
    /// together with the one increment, and nothing else is in that block. The send call itself
    /// is unchanged apart from its return value now being kept: same arguments, same casts.
    @Test("each print point immediately follows its send call, guarded by the switch alone")
    func eachLineFollowsItsSend() throws {
        let branch = try Self.inputBranch()
        let scancode =
            Self.scancodeSend + " if (p->keyWitness) { p->keyWitnessSeq++; " + Self.scancodeLine + " } }"
        let unicode =
            Self.unicodeSend + " if (p->keyWitness) { p->keyWitnessSeq++; " + Self.unicodeLine + " } }"
        #expect(keyWitnessOccurrences(of: scancode, in: branch) == 1)
        #expect(keyWitnessOccurrences(of: unicode, in: branch) == 1)
        // Order inside the branch: scancode send, its line, Unicode send, its line, mouse send.
        let a = try Self.index(of: Self.scancodeSend, in: branch)
        let b = try Self.index(of: Self.scancodeLine, in: branch)
        let c = try Self.index(of: Self.unicodeSend, in: branch)
        let d = try Self.index(of: Self.unicodeLine, in: branch)
        let e = try Self.index(of: "freerdp_input_send_mouse_event(", in: branch)
        #expect(a < b && b < c && c < d && d < e)
    }

    // MARK: (b) the switch is read in exactly those two places

    @Test("the per-connection switch is read only by the two print points")
    func theSwitchIsReadTwice() throws {
        let code = try Self.code()
        // `keyWitness` as a whole identifier: the declaration, the copy in -start, two reads.
        let bare = try Regex("keyWitness(?![A-Za-z0-9_])")
        #expect(code.matches(of: bare).count == 4)
        #expect(keyWitnessOccurrences(of: "BOOL keyWitness;", in: code) == 1)
        #expect(keyWitnessOccurrences(of: "if (p->keyWitness)", in: code) == 2)
        #expect(keyWitnessOccurrences(of: "((CRBridgeContext *)context)->keyWitness = g_crbKeyWitnessEnabled;", in: code) == 1)
        // The sequence: declaration, reset, two increments, two log arguments.
        #expect(keyWitnessOccurrences(of: "keyWitnessSeq", in: code) == 6)
        #expect(keyWitnessOccurrences(of: "uint32_t keyWitnessSeq;", in: code) == 1)
        #expect(keyWitnessOccurrences(of: "p->keyWitnessSeq++;", in: code) == 2)
        #expect(keyWitnessOccurrences(of: "((CRBridgeContext *)context)->keyWitnessSeq = 0;", in: code) == 1)
    }

    /// The copy happens once per connection, in -start, right after X-C's own reset; the process
    /// switch's storage starts at `NO` and has exactly one writer, the class setter.
    @Test("-start copies the switch and resets the sequence; the storage defaults to NO with one writer")
    func startCopiesTheSwitch() throws {
        let code = try Self.code()
        #expect(code.contains(
            "((CRBridgeContext *)context)->arcCompletedStartCmdSends = 0; "
                + "((CRBridgeContext *)context)->keyWitness = g_crbKeyWitnessEnabled; "
                + "((CRBridgeContext *)context)->keyWitnessSeq = 0; "
                + "_instance = context->instance;"))
        #expect(keyWitnessOccurrences(of: "static BOOL g_crbKeyWitnessEnabled = NO;", in: code) == 1)
        #expect(keyWitnessOccurrences(of: "g_crbKeyWitnessEnabled", in: code) == 4,
                "declaration, getter, setter, the copy in -start")
        #expect(keyWitnessOccurrences(of: "g_crbKeyWitnessEnabled = ", in: code) == 2, "the initialiser and the setter")
        #expect(code.contains("+ (void)setKeyWitnessEnabled:(BOOL)keyWitnessEnabled { g_crbKeyWitnessEnabled = keyWitnessEnabled; }"))
        #expect(code.contains("+ (BOOL)keyWitnessEnabled { return g_crbKeyWitnessEnabled; }"))
        let header = try keyWitnessCodeOnly(Self.raw("App/CRBridge/CRSession.h"))
        #expect(keyWitnessOccurrences(of: "@property (class, nonatomic) BOOL keyWitnessEnabled;", in: header) == 1)
    }

    // MARK: (c) the frozen line shapes

    @Test("each format string occurs exactly once in the raw file, in its exact call")
    func formatStringsOnce() throws {
        let raw = try Self.raw()
        let code = try Self.code()
        #expect(keyWitnessOccurrences(of: "\"" + Self.scancodeFormat + "\"", in: raw) == 1)
        #expect(keyWitnessOccurrences(of: "\"" + Self.unicodeFormat + "\"", in: raw) == 1)
        #expect(keyWitnessOccurrences(of: Self.scancodeLine, in: code) == 1)
        #expect(keyWitnessOccurrences(of: Self.unicodeLine, in: code) == 1)
    }

    @Test("the scancode line carries seq, kind, 4-digit flags, 2-digit code and rc; the Unicode line has no code")
    func fieldShapes() {
        for field in ["[key-witness] ", "seq=%u", "kind=scancode", "flags=0x%04x", "code=0x%02x", "rc=%d"] {
            #expect(Self.scancodeFormat.contains(field), "\(field)")
        }
        for field in ["[key-witness] ", "seq=%u", "kind=unicode", "flags=0x%04x", "rc=%d"] {
            #expect(Self.unicodeFormat.contains(field), "\(field)")
        }
        #expect(!Self.unicodeFormat.contains("code="))
        #expect(!Self.unicodeFormat.contains("%c"))
        #expect(!Self.unicodeFormat.contains("%lc"))
        #expect(!Self.unicodeFormat.contains("%s"))
        #expect(!Self.unicodeFormat.contains("%ls"))
    }

    /// Gate (b): the Unicode line's argument list does not name the code unit in any spelling, and
    /// its conversion count matches its three arguments, so no stray `%` can read one either.
    @Test("the Unicode line never prints the code unit")
    func unicodeNeverPrintsTheCodeUnit() throws {
        let branch = try Self.inputBranch()
        let start = try Self.index(of: "\"" + Self.unicodeFormat + "\"", in: branch)
        let statement = String(branch[start...].prefix { $0 != ";" })
        #expect(!statement.contains("payload.input.code"))
        #expect(!statement.contains("input.code"))
        #expect(!statement.contains("WCHAR"))
        #expect(keyWitnessOccurrences(of: "%", in: Self.unicodeFormat) == 3)
        #expect(keyWitnessOccurrences(of: "%", in: Self.scancodeFormat) == 4)
    }

    /// The printed line, rendered from the format strings this file pins against their exact
    /// shapes, with C `printf` semantics (`String(format:)` follows them for `%u` / `%04x` /
    /// `%02x` / `%d`). Values are the ones the CA-1 read predicts for Ctrl+Option+End: LCONTROL
    /// 0x1D, LMENU 0x38, End 0x4F with KBD_FLAGS_EXTENDED (0x0100), released with
    /// KBD_FLAGS_RELEASE (0x8000).
    @Test("the rendered lines match the frozen shapes")
    func renderedLines() throws {
        let scancodeShape = try Regex(#"^\[key-witness\] seq=[1-9][0-9]* kind=scancode flags=0x[0-9a-f]{4} code=0x[0-9a-f]{2} rc=[01]$"#)
        let unicodeShape = try Regex(#"^\[key-witness\] seq=[1-9][0-9]* kind=unicode flags=0x[0-9a-f]{4} rc=[01]$"#)
        let cases: [(UInt32, UInt32, UInt32, Int32, String)] = [
            (1, 0x0000, 0x1D, 1, "[key-witness] seq=1 kind=scancode flags=0x0000 code=0x1d rc=1"),
            (2, 0x0000, 0x38, 1, "[key-witness] seq=2 kind=scancode flags=0x0000 code=0x38 rc=1"),
            (3, 0x0100, 0x4F, 1, "[key-witness] seq=3 kind=scancode flags=0x0100 code=0x4f rc=1"),
            (4, 0x8100, 0x4F, 0, "[key-witness] seq=4 kind=scancode flags=0x8100 code=0x4f rc=0"),
            (4_294_967_295, 0xFFFF, 0xFF, 1, "[key-witness] seq=4294967295 kind=scancode flags=0xffff code=0xff rc=1"),
        ]
        for (seq, flags, code, rc, expected) in cases {
            let line = String(format: Self.scancodeFormat, seq, flags, code, rc)
            #expect(line == expected)
            #expect(line.wholeMatch(of: scancodeShape) != nil, "\(line)")
        }
        let unicode = String(format: Self.unicodeFormat, UInt32(7), UInt32(0x8000), Int32(1))
        #expect(unicode == "[key-witness] seq=7 kind=unicode flags=0x8000 rc=1")
        #expect(unicode.wholeMatch(of: unicodeShape) != nil)
    }
}
