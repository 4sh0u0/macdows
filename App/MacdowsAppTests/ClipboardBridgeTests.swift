import Foundation
import MacdowsCore
import Testing

// adr/0026 lane L3: the clipboard bridge's App-side evidence. Two suites:
//
//  * behaviour: `+[CRSession clipboardSettingsProbe(mode:setup:)]` runs the connect path's clipboard
//    step (`crclip_apply_mode`, the function the pre-connect step calls) on a fresh FreeRDP client
//    settings object of the linked prefix -- offline, no connection -- for each of the five modes,
//    with a seed that tells "writes nothing" from "writes the default", an earlier writer's
//    `cliprdr` entry, and a hand-written model of step 3 of FreeRDP's own channel loading (the
//    step that adds `cliprdr` when `RedirectClipboard` is TRUE; step 4, which loads every entry
//    the collection holds, is known from reading the source, not run here); and the session's
//    clipboard methods where they can be driven without a connection. The mode numbers are tied to
//    MacdowsCore's `ClipboardMode`.
//  * source: what neither a settings object nor Tools/cliprdr-check can show, pinned as call shapes
//    on a closed syntax (a scanner that tells code, comments, strings and character literals apart,
//    and refuses what it does not model): the bridge's callbacks return success on every path
//    (H-1), the one call of the channel's data-response function sits behind the mode check (H-2),
//    clipboard commands are routed before the RAIL check (H-3), the bridge's C files include no
//    AppKit / Foundation (H-4), the mode-to-mask table carries no FILES bit (H-7), Unmanaged writes
//    nothing and the step runs once before the subscriptions (H-8), the callbacks send only the two
//    on-the-spot replies (H-10), the log lines carry numbers only (H-6), and no file under App/ or
//    Tools/ sets the mode.
//
// What neither reaches (left to the in-person acceptance batch): what the host does -- whether the
// RemoteApp session's clipboard process runs, when it is ready, whether it echoes an announcement,
// whether it forwards the exclusion formats.

// MARK: - The closed C scanner

/// The bridge's sources as the compiler's lexer sees them, for text without CR / FF / VT / NUL and
/// without backslash line splices (both refused). One pass over Unicode scalars with five states:
/// code, `//` comment, `/* */` comment, string literal, character literal (backslash escapes kept).
/// Comments become one space; preprocessor lines (a `#` first on a line, comments counting as
/// blanks) are collected verbatim and removed from both views. `blanked` drops the contents of
/// string and character literals (the quotes stay), so a string can neither stand in for code nor
/// hide a statement; `literal` keeps them, for the log-format pins. Both are whitespace-folded.
struct ClipCScan {
    var blanked = ""
    var literal = ""
    var directives: [String] = []
    /// Shapes the scanner does not model, refused outright.
    var refused: [String] = []
}

func clipScan(_ text: String) -> ClipCScan {
    var scan = ClipCScan()
    let s = Array(text.unicodeScalars)
    for (k, u) in s.enumerated() {
        if u == "\r" || u == "\u{0B}" || u == "\u{0C}" || u == "\u{00}" { scan.refused.append("control scalar at \(k)") }
        if u == "\\" {
            var j = k + 1
            while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
            if j < s.count, s[j] == "\n" { scan.refused.append("line splice at \(k)") }
        }
    }
    func isIdentifier(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || u == "_"
    }
    var blank = String.UnicodeScalarView()
    var lit = String.UnicodeScalarView()
    var lineStart = true
    var i = 0
    while i < s.count {
        let c = s[i]
        let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
        if c == "/", next == "/" {
            while i < s.count, s[i] != "\n" { i += 1 }
            blank.append(" "); lit.append(" ")
        } else if c == "/", next == "*" {
            var j = i + 2
            while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
            if j + 1 >= s.count { scan.refused.append("unterminated block comment"); break }
            i = j + 2
            blank.append(" "); lit.append(" ")
        } else if c == "\"" || c == "'" {
            if c == "\"", i > 0, s[i - 1] == "R" { scan.refused.append("raw string literal") }
            if c == "'", i > 0, isIdentifier(s[i - 1]) { scan.refused.append("quote after an identifier character") }
            blank.append(c); lit.append(c)
            i += 1
            while i < s.count, s[i] != c, s[i] != "\n" {
                if s[i] == "\\", i + 1 < s.count { lit.append(s[i]); i += 1 }
                lit.append(s[i])
                i += 1
            }
            if i < s.count, s[i] == c { blank.append(c); lit.append(c); i += 1 }
            lineStart = false
        } else if c == "\n" {
            blank.append(c); lit.append(c)
            lineStart = true
            i += 1
        } else if c == " " || c == "\t" {
            blank.append(c); lit.append(c)
            i += 1
        } else if c == "#", lineStart {
            var end = i
            while end < s.count, s[end] != "\n" { end += 1 }
            var line = String.UnicodeScalarView()
            line.append(contentsOf: s[i..<end])
            scan.directives.append(String(line).trimmingCharacters(in: .whitespaces))
            i = end
        } else {
            blank.append(c); lit.append(c)
            lineStart = false
            i += 1
        }
    }
    func fold(_ v: String.UnicodeScalarView) -> String {
        String(v).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }
    scan.blanked = fold(blank)
    scan.literal = fold(lit)
    if scan.blanked.unicodeScalars.contains(where: { !$0.isASCII }) { scan.refused.append("non-ASCII scalar in code") }
    for digraph in ["??", "<:", ":>", "<%", "%>", "%:"] where scan.blanked.contains(digraph) {
        scan.refused.append("trigraph or digraph \(digraph)")
    }
    return scan
}

/// Occurrences compared scalar by scalar (`.literal`).
func clipCount(_ needle: String, in haystack: String) -> Int {
    var count = 0
    var from = haystack.startIndex
    while let hit = haystack.range(of: needle, options: .literal, range: from..<haystack.endIndex) {
        count += 1
        from = hit.upperBound
    }
    return count
}

/// Occurrences of `token` that do not continue an identifier on their left (so `dispatch_` does
/// not count inside `crclip_dispatch_announce`).
func clipTokenCount(_ token: String, in code: String) -> Int {
    var count = 0
    var from = code.startIndex
    while let hit = code.range(of: token, options: .literal, range: from..<code.endIndex) {
        let before = hit.lowerBound > code.startIndex ? code[code.index(before: hit.lowerBound)] : " "
        if !(before.isLetter || before.isNumber || before == "_") { count += 1 }
        from = hit.upperBound
    }
    return count
}

/// From `signature` (which must occur exactly once) through the brace that closes the first `{`
/// after it, counted in a view whose literals and comments are gone.
func clipBody(_ signature: String, in view: String) throws -> String {
    #expect(clipCount(signature, in: view) == 1, "signature not present exactly once: \(signature)")
    let start = try #require(view.range(of: signature, options: .literal)).lowerBound
    let open = try #require(view[start...].firstIndex(of: "{"), "no body after \(signature)")
    var depth = 0
    var index = open
    while index < view.endIndex {
        let ch = view[index]
        if ch == "{" { depth += 1 }
        if ch == "}" {
            depth -= 1
            if depth == 0 { return String(view[start...index]) }
        }
        index = view.index(after: index)
    }
    throw ClipPinError.unbalanced(signature)
}

enum ClipPinError: Error { case unbalanced(String) }

/// The identifiers called in `code` (`name(` or `->name(`), keywords excluded.
func clipCallees(_ code: String) -> Set<String> {
    let keywords: Set<String> = ["if", "while", "for", "switch", "return", "sizeof", "else"]
    var out = Set<String>()
    for match in code.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\s*\(/) where !keywords.contains(String(match.1)) {
        out.insert(String(match.1))
    }
    return out
}

/// The arguments of every call `name(` in `code` (a `name` that continues an identifier on its left
/// is not a call of it), split at the commas outside parentheses, each whitespace-trimmed.
func clipCallArguments(_ name: String, in code: String) -> [[String]] {
    var calls: [[String]] = []
    var from = code.startIndex
    while let hit = code.range(of: name + "(", options: .literal, range: from..<code.endIndex) {
        from = hit.upperBound
        let before = hit.lowerBound > code.startIndex ? code[code.index(before: hit.lowerBound)] : " "
        if before.isLetter || before.isNumber || before == "_" { continue }
        var depth = 1
        var arguments: [String] = []
        var current = ""
        var index = hit.upperBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            if ch == ",", depth == 1 {
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            index = code.index(after: index)
        }
        arguments.append(current.trimmingCharacters(in: .whitespaces))
        calls.append(arguments)
    }
    return calls
}

/// How often `code` writes `field`: plain or compound assignment (`=`, `|=`, `&=`, `^=`, `+=`, `-=`,
/// `*=`, `/=`, `%=`, `<<=`, `>>=`) or `++` / `--` on either side; a comparison (`==`, `!=`, `<=`,
/// `>=`) is not a write.
func clipWriteCount(_ field: String, in code: String) throws -> Int {
    let assignment = try Regex("\\b\(field)\\s*(?:<<|>>|[-+*/%&|^])?=(?!=)")
    let prefix = try Regex("(?:\\+\\+|--)\\s*(?:[A-Za-z_][A-Za-z0-9_]*\\s*->\\s*)?\(field)\\b")
    let postfix = try Regex("\\b\(field)\\s*(?:\\+\\+|--)")
    return code.matches(of: assignment).count + code.matches(of: prefix).count + code.matches(of: postfix).count
}

func clipRepoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

func clipSource(_ relative: String) throws -> String {
    try String(contentsOf: clipRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// How often `code` names the `clipboardMode` PROPERTY in any spelling and case -- the dot syntax,
/// `[x clipboardMode]`, `[x setClipboardMode:]`, `_clipboardMode`, a KVC key, a selector string.
/// The type `CRClipboardMode` and its constants contain the same letters and are not counted.
func clipboardModePropertyMentions(in code: String) -> Int {
    let anySpelling = code.lowercased().components(separatedBy: "clipboardmode").count - 1
    let theType = code.components(separatedBy: "CRClipboardMode").count - 1
    return anySpelling - theType
}

/// The C, Objective-C and Swift sources under `relative`, skipping build products.
func clipSourceFiles(under relative: String) throws -> [String] {
    let walker = try #require(FileManager.default.enumerator(atPath: clipRepoRoot().appendingPathComponent(relative).path))
    var files: [String] = []
    for case let entry as String in walker {
        let path = "\(relative)/\(entry)"
        if path.split(separator: "/").contains(where: { $0 == "build" || $0 == ".build" || $0.hasSuffix(".xcodeproj") }) {
            walker.skipDescendants()
            continue
        }
        if ["swift", "m", "mm", "c", "h"].contains((entry as NSString).pathExtension) { files.append(path) }
    }
    return files.sorted()
}

// MARK: - Behaviour

private let cliprdrEntry = ["cliprdr"]
private let defaultMask: UInt32 = 0x33 // CLIPRDR_FLAG_DEFAULT_MASK: both plain bits and both FILES bits
private let seededMask: UInt32 = 0x22  // the probe's seed: the two FILES bits, a value no mode writes

@Suite("adr/0026 L3 — the connect path's clipboard step, run on a fresh FreeRDP settings object")
struct ClipboardBridgeSettingsTests {
    private static func probe(_ mode: CRClipboardMode, _ setup: CRClipboardProbeSetup = []) throws -> CRClipboardSettingsProbe {
        try #require(CRSession.clipboardSettingsProbe(mode: mode, setup: setup), "the probe could not build its settings")
    }

    @Test("the mode numbers are MacdowsCore's ClipboardMode raw values, and a new session is Unmanaged with no byte limit")
    func modeNumbersAndDefault() throws {
        let pairs: [(CRClipboardMode, ClipboardMode)] = [
            (.unmanaged, .unmanaged), (.off, .off), (.bidirectional, .bidirectional),
            (.remoteToLocalOnly, .remoteToLocalOnly), (.localToRemoteOnly, .localToRemoteOnly),
        ]
        #expect(pairs.count == ClipboardMode.allCases.count)
        for (bridge, core) in pairs {
            #expect(bridge.rawValue == core.rawValue, "\(core)")
        }
        #expect(CRClipboardMode.unmanaged.rawValue == 0)
        let session = CRSession(host: "", user: "", passwordBytes: Data(), program: "")
        #expect(session.clipboardMode == .unmanaged)
        #expect(session.clipboardByteLimit == 0)
        #expect(session.clipboardEventHandler == nil)
    }

    @Test("Unmanaged writes nothing: FreeRDP's defaults stay, a seeded value stays, an earlier entry stays, nothing installs")
    func unmanagedWritesNothing() throws {
        let fresh = try Self.probe(.unmanaged)
        #expect(fresh.applied)
        #expect(fresh.redirectClipboard, "FreeRDP's client default")
        #expect(fresh.clipboardFeatureMask == defaultMask, "FreeRDP's client default: \(fresh.clipboardFeatureMask)")
        #expect(!fresh.installsCallbacks)
        #expect(fresh.staticChannels.isEmpty)

        let seeded = try Self.probe(.unmanaged, .seedClipboardSettings)
        #expect(seeded.applied)
        #expect(!seeded.redirectClipboard, "the seeded FALSE was not overwritten")
        #expect(seeded.clipboardFeatureMask == seededMask, "the seeded mask was not overwritten")

        let entry = try Self.probe(.unmanaged, .seedCliprdrEntry)
        #expect(entry.staticChannels == [cliprdrEntry], "an existing entry is left alone")
    }

    /// FreeRDP's channel loading after the step, as a hand-written model of its step 3 (add
    /// `cliprdr` when RedirectClipboard is TRUE, no duplicate) plus a reading of its step 4 (load
    /// every entry in the collection) -- not FreeRDP's own loading function, so a change to
    /// upstream's loading condition would not turn this red: today's channel set (cliprdr loaded,
    /// nobody answering it) is what Unmanaged must keep; Off leaves no entry in the collection, even
    /// over one an earlier writer left; the directed modes leave exactly one.
    @Test("after the step, a model of FreeRDP's loading (step 3): Unmanaged and the directed modes end with one cliprdr entry, Off with none even over an earlier entry")
    func channelSetAfterFreeRDPsLoading() throws {
        let today = try Self.probe(.unmanaged, .replayUpstreamLoad)
        #expect(today.staticChannels == [cliprdrEntry], "what a connection loads without this lane: \(today.staticChannels)")
        let off = try Self.probe(.off, .replayUpstreamLoad)
        #expect(off.applied && off.staticChannels.isEmpty, "\(off.staticChannels)")
        let offOverEntry = try Self.probe(.off, [.seedCliprdrEntry, .replayUpstreamLoad])
        #expect(offOverEntry.applied && offOverEntry.staticChannels.isEmpty, "Off removes an earlier entry: \(offOverEntry.staticChannels)")
        let control = try Self.probe(.unmanaged, [.seedClipboardSettings, .replayUpstreamLoad])
        #expect(control.staticChannels.isEmpty, "the replay follows RedirectClipboard (seeded FALSE): \(control.staticChannels)")
        for mode: CRClipboardMode in [.bidirectional, .remoteToLocalOnly, .localToRemoteOnly] {
            let loaded = try Self.probe(mode, .replayUpstreamLoad)
            #expect(loaded.applied && loaded.staticChannels == [cliprdrEntry], "mode \(mode.rawValue): \(loaded.staticChannels)")
            let overEntry = try Self.probe(mode, [.seedCliprdrEntry, .replayUpstreamLoad])
            #expect(overEntry.staticChannels == [cliprdrEntry], "mode \(mode.rawValue): one entry, not two: \(overEntry.staticChannels)")
        }
    }

    @Test("Off: RedirectClipboard FALSE and the mask 0, over FreeRDP's defaults and over a seed; no callbacks")
    func offWritesNotLoaded() throws {
        for setup: CRClipboardProbeSetup in [[], .seedClipboardSettings] {
            let off = try Self.probe(.off, setup)
            #expect(off.applied)
            #expect(!off.redirectClipboard, "setup \(setup.rawValue)")
            #expect(off.clipboardFeatureMask == 0, "setup \(setup.rawValue): \(off.clipboardFeatureMask)")
            #expect(!off.installsCallbacks)
        }
    }

    @Test("the three directed modes: RedirectClipboard TRUE and exactly their plain direction bits, never a FILES bit")
    func directedModesWriteTheirMask() throws {
        let expected: [(CRClipboardMode, UInt32, ClipboardMode)] = [
            (.bidirectional, 0x11, .bidirectional), (.remoteToLocalOnly, 0x10, .remoteToLocalOnly),
            (.localToRemoteOnly, 0x01, .localToRemoteOnly),
        ]
        for (mode, mask, core) in expected {
            for setup: CRClipboardProbeSetup in [[], .seedClipboardSettings] {
                let p = try Self.probe(mode, setup)
                #expect(p.applied, "mode \(mode.rawValue)")
                #expect(p.redirectClipboard, "mode \(mode.rawValue) setup \(setup.rawValue)")
                #expect(p.clipboardFeatureMask == mask, "mode \(mode.rawValue) setup \(setup.rawValue): \(p.clipboardFeatureMask)")
                #expect(p.clipboardFeatureMask & seededMask == 0, "a FILES bit (H-7)")
                #expect(p.installsCallbacks)
            }
            // The mask is what MacdowsCore's policy says each direction may do.
            let policy = ClipboardPolicy(mode: core)
            #expect((mask & 0x01 != 0) == policy.allowsLocalToRemote, "\(core)")
            #expect((mask & 0x10 != 0) == policy.allowsRemoteToLocal, "\(core)")
        }
    }

    @Test("every mode agrees with MacdowsCore's ClipboardPolicy: loading, callbacks, directions")
    func modesAgreeWithThePolicy() throws {
        for core in ClipboardMode.allCases {
            let mode = try #require(CRClipboardMode(rawValue: core.rawValue))
            let p = try Self.probe(mode, .seedClipboardSettings)
            let policy = ClipboardPolicy(mode: core)
            #expect(p.installsCallbacks == policy.installsCallbacks, "\(core)")
            switch policy.channelSetting {
            case .leaveDefault: #expect(!p.redirectClipboard && p.clipboardFeatureMask == seededMask, "\(core): nothing written")
            case .doNotLoad: #expect(!p.redirectClipboard && p.clipboardFeatureMask == 0, "\(core)")
            case .load: #expect(p.redirectClipboard, "\(core)")
            }
            #expect((p.clipboardFeatureMask & 0x01 != 0) == (policy.allowsLocalToRemote && p.redirectClipboard), "\(core)")
            #expect((p.clipboardFeatureMask & 0x10 != 0) == (policy.allowsRemoteToLocal && p.redirectClipboard), "\(core)")
        }
    }

    @Test("a value outside the five is treated as Off")
    func unknownModeIsOff() throws {
        let mode = try #require(CRClipboardMode(rawValue: 9))
        let p = try Self.probe(mode, [.seedClipboardSettings, .seedCliprdrEntry, .replayUpstreamLoad])
        #expect(p.applied)
        #expect(!p.redirectClipboard && p.clipboardFeatureMask == 0)
        #expect(!p.installsCallbacks)
        #expect(p.staticChannels.isEmpty, "\(p.staticChannels)")
    }

    /// Without a connection there is no outbound lane: every sender refuses and counts it; values
    /// outside T1's plain-text boundary are refused before anything is posted or counted.
    @Test("the senders on an idle session: refused and counted; non-T1 formats refused before posting")
    func sendersOnAnIdleSession() throws {
        let session = CRSession(host: "", user: "", passwordBytes: Data(), program: "")
        #expect(session.clipboardCounter(.commandPostFailed) == 0)
        #expect(!session.announceClipboardFormat(13))
        #expect(!session.announceClipboardFormat(0))
        #expect(!session.requestClipboardFormat(13))
        #expect(session.clipboardCounter(.commandPostFailed) == 3, "three posts with no lane")
        #expect(!session.announceClipboardFormat(1), "CF_TEXT is not T1's")
        #expect(!session.requestClipboardFormat(0))
        #expect(!session.requestClipboardFormat(15))
        #expect(session.clipboardCounter(.commandPostFailed) == 3, "a refused format is not a post")
        // Past the last counter (17) and below the first: the method's own range check answers 0
        // (Tools/cliprdr-check drives the C table's range check with the same two values).
        for raw in [18, -1] {
            let outOfRange = try #require(CRClipboardCounter(rawValue: raw))
            #expect(session.clipboardCounter(outOfRange) == 0, "counter value \(raw) is outside 0...17 and reads 0")
        }
        #expect(session.clipboardCounter(.commandPostFailed) == 3, "reading out of range changed nothing")
        #expect(session.clipboardCounter(.remoteDataUnconsumed) == 0)
    }

    @Test("the counter enum covers the bridge's eighteen counters, numbered 0 to 17, the three stalling drops last")
    func counterNumbers() {
        let all: [CRClipboardCounter] = [
            .capabilitiesSendFailed, .formatListResponseSendFailed, .eventPostFailed, .remoteDataNotStored,
            .remoteDataFlagsUnexpected, .formatListWithoutLongNames, .callbackArgumentMissing,
            .commandDroppedNoChannel, .commandDroppedStale, .responseWithheldByMode, .commandSendFailed,
            .responseBytesUnavailable, .remoteDataUnconsumed, .respondStoredAsFailure, .commandPostFailed,
            .stallRemoteDataPostFailed, .stallRequestPostFailed, .stallRequestDropped,
        ]
        #expect(all.map(\.rawValue) == Array(0...17))
    }
}

// MARK: - Source pins

@Suite("adr/0026 L3 — the clipboard bridge, pinned as source on a closed syntax")
struct ClipboardBridgeSourcePinTests {
    static let bridgeC = "App/CRBridge/crclip_bridge.c"
    static let bridgeH = "App/CRBridge/crclip_bridge.h"
    static let session = "App/CRBridge/CRSession.mm"

    static let frozenDirectivesC = [
        "#include \"crclip_bridge.h\"", "#include <stdatomic.h>", "#include <stdlib.h>", "#include <string.h>",
        "#include <winpr/user.h>", "#include <winpr/wlog.h>", "#include <freerdp/channels/cliprdr.h>",
        "#include <freerdp/client/cmdline.h>", "#include <freerdp/freerdp.h>", "#include <freerdp/settings.h>",
    ]
    static let frozenDirectivesH = [
        "#pragma once", "#include <stdbool.h>", "#include <stdint.h>", "#include <freerdp/settings.h>",
        "#include <freerdp/client/cliprdr.h>", "#include \"crdpq.h\"", "#ifdef __cplusplus", "#endif",
        "#ifdef __cplusplus", "#endif",
    ]

    /// The five server callbacks attach installs, by slot, in this order.
    static let callbacks: [(slot: String, name: String, allowed: Set<String>)] = [
        ("ServerCapabilities", "crclip_on_server_capabilities", ["crclip_bridge_of", "crclip_note"]),
        ("MonitorReady", "crclip_on_monitor_ready", ["crclip_bridge_of", "memset", "ClientCapabilities", "crclip_note", "crclip_post"]),
        ("ServerFormatList", "crclip_on_server_format_list",
         ["crclip_bridge_of", "memset", "ClientFormatListResponse", "crclip_note", "crclip_format_list_flags", "crclip_post"]),
        ("ServerFormatDataRequest", "crclip_on_server_format_data_request", ["crclip_bridge_of", "memset", "crclip_note", "crclip_post"]),
        ("ServerFormatDataResponse", "crclip_on_server_format_data_response",
         ["crclip_bridge_of", "memset", "crclip_note", "crdpq_clip_store_put", "crclip_post", "crdpq_clip_store_discard"]),
    ]
    /// What the helpers the callbacks call may call in turn -- a closed set, so no helper can send.
    static let helpers: [(signature: String, allowed: Set<String>)] = [
        ("static crclip_bridge_t* crclip_bridge_of(", []),
        ("static void crclip_note(", ["crclip_counters_bump", "WLog_WARN"]),
        ("static bool crclip_post(", ["memset", "crdpq_post", "crclip_note"]),
        ("uint32_t crclip_format_list_flags(", ["ARRAYSIZE", "crclip_name_equals_folded"]),
        ("static bool crclip_name_equals_folded(", []),
        ("uint64_t crclip_counters_bump(", ["atomic_fetch_add"]),
    ]

    private static func scanned(_ file: String) throws -> ClipCScan {
        let scan = clipScan(try clipSource(file))
        #expect(scan.refused.isEmpty, "\(file) holds shapes the scanner does not model: \(scan.refused)")
        return scan
    }

    @Test("the scanner itself: comments, strings, character literals, directives and the refused shapes")
    func theScannerSeesWhatTheCompilerSees() {
        #expect(clipScan("a = \"/*\"; b; c = \"*/\";").blanked == "a = \"\"; b; c = \"\";")
        #expect(clipScan("a; // /* b\nc; // */ d\ne;").blanked == "a; c; e;")
        #expect(clipScan("c = '\"'; d = \"x\"; /* gone */ e;").blanked == "c = ''; d = \"\"; e;")
        #expect(clipScan("s = \"a\\\"b/*\"; t;").blanked == "s = \"\"; t;")
        #expect(clipScan("x = \"ch->ClientFormatDataResponse(\";").blanked == "x = \"\";", "a string stood in for code")
        #expect(clipScan("w(\"%s\", n);").literal == "w(\"%s\", n);")
        let directives = clipScan("#include <a.h>\n  # pragma once\nx; #define Y\n/* c */ #if Z\n").directives
        #expect(directives == ["#include <a.h>", "# pragma once", "#if Z"], "\(directives)")
        for bad in ["a\rb", "a \\\nb", "s = R\"(x)\";", "a = 1'0;", "x = K\u{212A};", "a ??= b;", "a <: b :>", "a; /* open"] {
            #expect(!clipScan(bad).refused.isEmpty, "not refused: \(bad.debugDescription)")
        }
        #expect(clipScan("a = 'x'; b = \"y\"; c(); // ok\n").refused.isEmpty)
        #expect(clipCallees("if (a) f(x); g ->h(y); return (z); sizeof(q);") == ["f", "h"])
        #expect(clipTokenCount("dispatch_", in: "crclip_dispatch_x(); dispatch_async(q);") == 1)
        #expect(clipCallArguments("f", in: "g(); f(a, (b, c), d ? e : 0); xf(z); f(y);") == [["a", "(b, c)", "d ? e : 0"], ["y"]])
        let writes = try? clipWriteCount("f", in: "a->f = 1; a->f |= b; a->f == c; a->f != d; a->f <= e; a->f >= e; "
            + "a->f >>= 1; a->f &= 0; ++a->f; a->f--; g = a->f; a->ff = 2; if (a->f) h();")
        #expect(writes == 6, "=, |=, >>=, &=, prefix ++, postfix -- and nothing else: \(String(describing: writes))")
        #expect(clipboardModePropertyMentions(in: "[s setClipboardMode:CRClipboardModeOff]; s.clipboardMode = x; [s clipboardMode];") == 3)
        #expect(clipboardModePropertyMentions(in: "CRClipboardMode m = CRClipboardModeUnmanaged;") == 0)
    }

    /// H-4: the bridge's two files are pure C. Their preprocessor lines are exactly these lists, so
    /// no AppKit, Foundation or Objective-C header can come in, and their code names none of it.
    @Test("H-4: the bridge's C files include a closed list of headers and name no AppKit, Foundation or Objective-C")
    func theBridgeIsPureC() throws {
        let c = try Self.scanned(Self.bridgeC)
        let h = try Self.scanned(Self.bridgeH)
        #expect(c.directives == Self.frozenDirectivesC, "\(c.directives)")
        #expect(h.directives == Self.frozenDirectivesH, "\(h.directives)")
        for (file, scan) in [(Self.bridgeC, c), (Self.bridgeH, h)] {
            for token in ["NSPasteboard", "NSObject", "NSString", "@", "dispatch_", "objc_", "__bridge", "CFRetain", "CFRelease", "id<"] {
                #expect(clipTokenCount(token, in: scan.blanked) == 0, "\(file) names \(token)")
            }
        }
        // The App's other C sources do not touch the pasteboard either.
        for file in try clipSourceFiles(under: "App/CRBridge") {
            #expect(!(try clipSource(file)).contains("NSPasteboard"), "\(file) names NSPasteboard")
        }
    }

    /// H-1: attach installs exactly the five callbacks; each is a `static UINT` function whose body
    /// has one `return`, `return CHANNEL_RC_OK;` at its end -- no early return, no other value.
    @Test("H-1: attach installs five callbacks, and each returns CHANNEL_RC_OK as its only return")
    func everyCallbackReturnsSuccess() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        let attach = try clipBody("bool crclip_bridge_attach(crclip_bridge_t* bridge, CliprdrClientContext* channel)", in: code)
        let install = "channel->custom = bridge; " + Self.callbacks.map { "channel->\($0.slot) = \($0.name);" }.joined(separator: " ")
        #expect(clipCount(install, in: attach) == 1, "the install block changed: \(attach)")
        #expect(clipCount("->custom = ", in: code) == 2, "custom: set by attach, cleared by detach")
        // No other function is put into a channel slot anywhere in the file.
        #expect(code.matches(of: /channel->(Server[A-Za-z]*|MonitorReady)\s*=/).count == 5)
        for callback in Self.callbacks {
            let signature = "static UINT \(callback.name)(CliprdrClientContext* context, const "
            let body = try clipBody(signature, in: code)
            #expect(body.matches(of: /\breturn\b/).count == 1, "\(callback.name): more than one return")
            #expect(body.hasSuffix("return CHANNEL_RC_OK; }"), "\(callback.name): does not end in return CHANNEL_RC_OK")
            for forbidden in ["goto", "abort(", "exit(", "longjmp", "WINPR_ASSERT"] {
                #expect(clipCount(forbidden, in: body) == 0, "\(callback.name) holds \(forbidden)")
            }
            #expect(clipCount(callback.name, in: code) == 2, "\(callback.name): its definition and its one install")
        }
    }

    /// H-10: the callbacks send exactly the two on-the-spot replies. Each body calls only from a
    /// closed set, and so does every helper they call; the three other sends occur once each in
    /// the file, in the outbound dispatch. Also here, beside crclip_counters_bump's callee check: the
    /// counter table's two functions frozen whole, range checks included.
    @Test("H-10: callbacks call a closed set -- the two replies, posting, the store -- and never the three outbound sends")
    func callbacksSendOnlyTheTwoReplies() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        for callback in Self.callbacks {
            let body = try clipBody("static UINT \(callback.name)(CliprdrClientContext* context, const ", in: code)
            let callees = clipCallees(body).subtracting([callback.name])
            #expect(callees.isSubset(of: callback.allowed), "\(callback.name) calls \(callees.subtracting(callback.allowed))")
            for send in ["->ClientFormatDataRequest(", "->ClientFormatList(", "->ClientFormatDataResponse(", "crdpq_outbound_post(",
                         "crclip_dispatch_", "crclip_send_data_response("] {
                #expect(clipCount(send, in: body) == 0, "\(callback.name) names \(send)")
            }
        }
        for helper in Self.helpers {
            let body = try clipBody(helper.signature, in: code)
            let callees = clipCallees(body).subtracting([String(helper.signature.split(separator: "(")[0].split(separator: " ").last ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))])
            #expect(callees.isSubset(of: helper.allowed), "\(helper.signature) calls \(callees.subtracting(helper.allowed))")
        }
        // The counter table's two range checks, frozen whole (gate r2 m-r2-2): a check that lets 18 or
        // -1 through reads or writes past the table, which only an ASan build of the offline check
        // would see -- and CI runs the plain build.
        let bump = try clipBody("uint64_t crclip_counters_bump(", in: code)
        #expect(bump == Self.countersBump, "\(bump)")
        let get = try clipBody("uint64_t crclip_counters_get(", in: code)
        #expect(get == Self.countersGet, "\(get)")
        #expect(clipCount("->ClientCapabilities(", in: code) == 1)
        #expect(clipCount("->ClientFormatListResponse(", in: code) == 1)
        let announce = try clipBody("static void crclip_dispatch_announce(", in: code)
        let request = try clipBody("static void crclip_dispatch_request(", in: code)
        #expect(clipCount("->ClientFormatList(", in: code) == 1 && clipCount("->ClientFormatList(", in: announce) == 1)
        #expect(clipCount("->ClientFormatDataRequest(", in: code) == 1 && clipCount("->ClientFormatDataRequest(", in: request) == 1)
    }

    static let countersBump = "uint64_t crclip_counters_bump(crclip_counters_t* counters, crclip_counter_t counter) { "
        + "if (!counters || (int)counter < 0 || (int)counter >= (int)CRCLIP_COUNTER_COUNT) return 0; "
        + "return atomic_fetch_add(&counters->values[counter], 1) + 1; }"
    static let countersGet = "uint64_t crclip_counters_get(const crclip_counters_t* counters, crclip_counter_t counter) { "
        + "if (!counters || (int)counter < 0 || (int)counter >= (int)CRCLIP_COUNTER_COUNT) return 0; "
        + "crclip_counters_t* readable = (crclip_counters_t*)counters; return atomic_load(&readable->values[counter]); }"

    static let sendDataResponse = "static UINT crclip_send_data_response(const crclip_bridge_t* bridge, CliprdrClientContext* channel, "
        + "UINT16 msgFlags, const BYTE* data, UINT32 length) { "
        + "if (!crclip_mode_allows_local_to_remote(bridge->mode) || !crclip_channel_allows_response(channel) || "
        + "!channel->ClientFormatDataResponse) return CHANNEL_RC_NOT_INITIALIZED; "
        + "CLIPRDR_FORMAT_DATA_RESPONSE response; memset(&response, 0, sizeof(response)); "
        + "response.common.msgType = CB_FORMAT_DATA_RESPONSE; response.common.msgFlags = msgFlags; "
        + "response.common.dataLen = length; response.requestedFormatData = data; "
        + "return channel->ClientFormatDataResponse(channel, &response); }"

    /// H-2: one call of the channel's data-response function in the whole App, in one function whose
    /// first statement refuses a mode without Mac -> Windows and a live mask without that bit; the
    /// two premises are frozen too, and the respond path refuses the mode before it touches anything.
    @Test("H-2: the data-response function is called once, behind the mode and mask checks, from the respond path only")
    func theResponseCallSitIsGuarded() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        #expect(clipCount("ClientFormatDataResponse(", in: code) == 1)
        #expect(clipCount(Self.sendDataResponse, in: code) == 1, "the guarded send changed")
        let body1: String = try clipBody("bool crclip_mode_allows_local_to_remote(", in: code)
        let body1Expected: String = "bool crclip_mode_allows_local_to_remote(uint32_t mode) { return (crclip_mode_feature_mask(mode) & CLIPRDR_FLAG_LOCAL_TO_REMOTE) != 0; }"
        #expect(body1 == body1Expected, "\(body1)")
        let body2: String = try clipBody("static bool crclip_channel_allows_response(", in: code)
        let body2Expected: String = "static bool crclip_channel_allows_response(const CliprdrClientContext* channel) { "
                + "if (!channel || !channel->rdpcontext || !channel->rdpcontext->settings) return false; "
                + "const UINT32 mask = freerdp_settings_get_uint32(channel->rdpcontext->settings, FreeRDP_ClipboardFeatureMask); "
                + "return (mask & CLIPRDR_FLAG_LOCAL_TO_REMOTE) != 0; }"
        #expect(body2 == body2Expected, "\(body2)")
        let respond = try clipBody("static void crclip_dispatch_respond(", in: code)
        let expected1: String = "static void crclip_dispatch_respond(crclip_bridge_t* bridge, CliprdrClientContext* channel, "
            + "const crdpq_clip_ref_t* ref) { if (!crclip_mode_allows_local_to_remote(bridge->mode)) { "
            + "crclip_discard_answer(bridge, ref); crclip_note(bridge->counters, CRCLIP_COUNTER_RESPONSE_WITHHELD_BY_MODE, \"\", "
            + "(unsigned)bridge->mode); return; }"
        #expect(respond.hasPrefix(expected1), "\(respond.prefix(300))")
        #expect(clipCount("crclip_send_data_response(", in: code) == 4, "definition and three calls")
        #expect(clipCount("crclip_send_data_response(", in: respond) == 3, "all three calls in the respond path")
        // Nothing else in the App calls it; under Tools/ only the offline check (its counting shim
        // and its forked self-check).
        for file in try clipSourceFiles(under: "App") where file != Self.bridgeC && !file.hasPrefix("App/MacdowsAppTests/") {
            #expect(clipCount("ClientFormatDataResponse(", in: clipScan(try clipSource(file)).blanked) == 0, "\(file)")
        }
        for file in try clipSourceFiles(under: "Tools") where file != "Tools/cliprdr-check/cliprdr-check.c" {
            #expect(clipCount("ClientFormatDataResponse(", in: clipScan(try clipSource(file)).blanked) == 0, "\(file)")
        }
    }

    /// H-7: the table, whole: the two plain bits and nothing else. The bridge's files name no FILES
    /// flag at all; CRSession.mm names them only in the offline probe's seed.
    @Test("H-7: the mode-to-mask table names only the two plain bits; no FILES flag in the bridge")
    func theMaskTableHasNoFilesBit() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        let body3: String = try clipBody("UINT32 crclip_mode_feature_mask(", in: code)
        let body3Expected: String = "UINT32 crclip_mode_feature_mask(uint32_t mode) { switch (mode) { "
                + "case CRCLIP_MODE_BIDIRECTIONAL: return CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL; "
                + "case CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY: return CLIPRDR_FLAG_REMOTE_TO_LOCAL; "
                + "case CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY: return CLIPRDR_FLAG_LOCAL_TO_REMOTE; default: return 0; } }"
        #expect(body3 == body3Expected, "\(body3)")
        #expect(clipCount("_FILES", in: code) == 0)
        #expect(clipCount("_FILES", in: try Self.scanned(Self.bridgeH).blanked) == 0)
        #expect(clipCount("DEFAULT_MASK", in: code) == 0)
        let session = try Self.scanned(Self.session).blanked
        let probe = try clipBody("+ (nullable CRClipboardSettingsProbe *)clipboardSettingsProbeForMode:", in: session)
        #expect(clipCount("_FILES", in: session) == clipCount("_FILES", in: probe) && clipCount("_FILES", in: probe) == 2)
    }

    static let applyMode = "BOOL crclip_apply_mode(rdpSettings* settings, uint32_t mode) { "
        + "if (mode == CRCLIP_MODE_UNMANAGED) return TRUE; uint32_t effective = mode; "
        + "if (!crclip_mode_is_known(mode)) { WLog_WARN(crclip_tag, \"\", (unsigned)mode); effective = CRCLIP_MODE_OFF; } "
        + "const UINT32 mask = crclip_mode_feature_mask(effective); "
        + "if (!freerdp_settings_set_uint32(settings, FreeRDP_ClipboardFeatureMask, mask) || "
        + "!freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, mask != 0)) { "
        + "WLog_ERR(crclip_tag, \"\", (unsigned)effective); return FALSE; } "
        + "if (mask == 0 && !crclip_remove_cliprdr_entries(settings)) { WLog_ERR(crclip_tag, \"\", (unsigned)effective); return FALSE; } "
        + "WLog_INFO(crclip_tag, \"\", (unsigned)effective, (unsigned)mask); return TRUE; }"
    static let preConnectCall = "if (!crclip_bridge_init(&p->clip, (uint32_t)session.clipboardMode, crb_control(p), "
        + "session->_clipStore, session->_clipCounters) || !crclip_apply_mode(settings, p->clip.mode)) return FALSE;"
    static let audioCall = "if (!crb_apply_audio_playback_mode(settings, session.audioPlaybackMode)) return FALSE;"

    /// H-8: the step, whole -- Unmanaged leaves before any write; every write and the removal refuse
    /// the connection on failure -- and its one call in crb_pre_connect, right before the audio step
    /// (whose own pin holds it right before the frozen subscription block).
    @Test("H-8: Unmanaged writes nothing; the step and its failure branches are frozen and called once, before the audio step and the subscriptions")
    func theStepRunsOnceBeforeTheSubscriptions() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        #expect(clipCount(Self.applyMode, in: code) == 1, "the settings step changed")
        #expect(clipCount("FreeRDP_RedirectClipboard", in: code) == 1 && clipCount("FreeRDP_ClipboardFeatureMask", in: code) == 2,
                "one write each (the mask is read once more, by the response guard)")
        let body4: String = try clipBody("bool crclip_bridge_init(", in: code)
        let body4Expected: String = "bool crclip_bridge_init(crclip_bridge_t* bridge, uint32_t mode, crdpq_control_t* control, "
                + "crdpq_clip_store_t* store, crclip_counters_t* counters) { if (!bridge) return false; "
                + "memset(bridge, 0, sizeof(*bridge)); bridge->mode = mode; bridge->control = control; "
                + "bridge->store = store; bridge->counters = counters; "
                + "if (crclip_mode_installs_callbacks(mode) && (!control || !store || !counters)) { "
                + "WLog_ERR(crclip_tag, \"\", (unsigned)mode, control ? 1 : 0, store ? 1 : 0, counters ? 1 : 0); return false; } "
                + "return true; }"
        #expect(body4 == body4Expected, "\(body4)")
        let session = try Self.scanned(Self.session).blanked
        let preConnect = try clipBody("static BOOL crb_pre_connect(freerdp *instance)", in: session)
        #expect(clipCount(Self.preConnectCall, in: preConnect) == 1)
        #expect(clipCount(Self.preConnectCall + " " + Self.audioCall, in: preConnect) == 1, "the clipboard step right before the audio step")
        #expect(clipCount("crclip_apply_mode(", in: session) == 2, "the pre-connect call and the offline probe")
        #expect(clipCount("crclip_bridge_init(", in: session) == 1)
        #expect(clipCount("p->clip.mode", in: session) == 3, "the step, the connected and the disconnected branch")
        #expect(clipCount("clip.mode =", in: session) + clipCount("clip.mode=", in: session) == 0, "only init writes the mode")
    }

    static let connectedBranch = "else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && crclip_mode_installs_callbacks(p->clip.mode)) "
        + "{ (void)crclip_bridge_attach(&p->clip, (CliprdrClientContext *)e->pInterface); } "
        + "else { freerdp_client_OnChannelConnectedEventHandler(&p->common, e); } }"
    static let disconnectedBranch = "p->rail = NULL; } "
        + "else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && crclip_mode_installs_callbacks(p->clip.mode)) "
        + "{ crclip_bridge_detach(&p->clip, (CliprdrClientContext *)e->pInterface); } else {"

    /// The channel callbacks: a directed mode attaches, Unmanaged and Off fall through to FreeRDP's
    /// own handler exactly as before; the disconnect branch comes right after the frozen RAIL branch.
    @Test("the cliprdr branches: attach / detach only for a directed mode, after the RAIL branches; everything else as before")
    func theChannelBranches() throws {
        let session = try Self.scanned(Self.session).blanked
        let connected = try clipBody("static void crb_on_channel_connected(void *context, const ChannelConnectedEventArgs *e)", in: session)
        let disconnected = try clipBody("static void crb_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)", in: session)
        #expect(connected.hasSuffix(Self.connectedBranch), "\(connected.suffix(300))")
        #expect(clipCount(Self.disconnectedBranch, in: disconnected) == 1)
        #expect(clipCount("crclip_bridge_attach(", in: session) == 1 && clipCount("crclip_bridge_detach(", in: session) == 1)
        let bridge = try Self.scanned(Self.bridgeC).blanked
        let expected2: String = "bool crclip_bridge_attach(crclip_bridge_t* bridge, "
            + "CliprdrClientContext* channel) { if (!bridge || !channel || !crclip_mode_installs_callbacks(bridge->mode)) { "
            + "WLog_ERR(crclip_tag, \"\", bridge ? (unsigned)bridge->mode : 0u); return false; } "
            + "bridge->storeGeneration = crdpq_clip_store_clear(bridge->store);"
        #expect(try clipBody("bool crclip_bridge_attach(", in: bridge).hasPrefix(expected2),
                "attach refuses (one ERR line, the mode number only) a missing bridge or channel and a mode that installs nothing, then clears")
        let body5: String = try clipBody("bool crclip_mode_installs_callbacks(", in: bridge)
        let body5Expected: String = "bool crclip_mode_installs_callbacks(uint32_t mode) { return crclip_mode_feature_mask(mode) != 0; }"
        #expect(body5 == body5Expected, "\(body5)")
        #expect(try clipBody("void crclip_bridge_detach(", in: bridge).contains(
            "bridge->channel = NULL; const uint32_t generation = crdpq_clip_store_clear(bridge->store);"))
    }

    /// H-3: the visitor hands every command to the bridge first; the bridge takes exactly the three
    /// clipboard kinds (and returns before touching anything for the others), then the RAIL check runs.
    @Test("H-3: clipboard commands are routed before the RAIL check, and the bridge passes every other command on")
    func clipboardBeforeRail() throws {
        let session = try Self.scanned(Self.session).blanked
        let visitor = try clipBody("static void crb_outbound_visitor(const CrdpCommand *cmd, void *vctx)", in: session)
        let expected3: String = "static void crb_outbound_visitor(const CrdpCommand *cmd, void *vctx) { "
            + "CRBridgeContext *p = (CRBridgeContext *)vctx; if (p && crclip_outbound_dispatch(&p->clip, cmd)) return; "
            + "RailClientContext *rail = p ? p->rail : NULL; if (!rail) {"
        #expect(visitor.hasPrefix(expected3), "\(visitor.prefix(260))")
        #expect(clipCount("crclip_outbound_dispatch(", in: session) == 1)
        let bridge = try Self.scanned(Self.bridgeC).blanked
        let dispatch = try clipBody("bool crclip_outbound_dispatch(", in: bridge)
        let expected4: String = "bool crclip_outbound_dispatch(crclip_bridge_t* bridge, const CrdpCommand* command) { "
            + "if (!command || (command->type != CRDPQ_CMD_CLIP_ANNOUNCE && command->type != CRDPQ_CMD_CLIP_REQUEST && "
            + "command->type != CRDPQ_CMD_CLIP_RESPOND)) return false; if (!bridge) return true;"
        #expect(dispatch.hasPrefix(expected4), "\(dispatch.prefix(300))")
        #expect(clipCount("rail", in: dispatch.lowercased()) == 0, "the clipboard dispatch never looks at RAIL")
        // The no-channel drop removes an answer's entry before it counts.
        let expected5: String = "if (!channel) { if (command->type == CRDPQ_CMD_CLIP_RESPOND) crclip_discard_answer(bridge, ref); "
            + "crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL, \"\", (unsigned)command->type); "
            + "if (command->type == CRDPQ_CMD_CLIP_REQUEST) crclip_note(bridge->counters, CRCLIP_COUNTER_STALL_REQUEST_DROPPED, \"\", "
            + "(unsigned)command->type); return true; }"
        #expect(dispatch.contains(expected5))
    }

    /// H-6: every log line the bridge writes carries numbers, mode values, generations and the fixed
    /// channel name. The one `%s` in the C file's formats is crclip_note's, and every crclip_note call
    /// hands it a string literal; attach / detach print the channel-name constant. Format names
    /// appear in code only in the comparison, never in a log or an event.
    @Test("H-6: log formats print no string but fixed text and the channel name; format names stay in the comparison")
    func logLinesCarryNumbersOnly() throws {
        let scan = try Self.scanned(Self.bridgeC)
        let statements = scan.literal.components(separatedBy: "WLog_").dropFirst().map { $0.prefix { $0 != ";" } }
        #expect(statements.count == 9, "the bridge's WLog statements: \(statements.count)")
        for statement in statements {
            let strings = statement.components(separatedBy: "%s").count - 1
            if statement.hasPrefix("WARN(crclip_tag, \"[clipboard] %s (detail=%u, count=%llu)\"") {
                #expect(strings == 1 && statement.contains(", what, detail,"), "crclip_note's line: \(statement)")
            } else if statement.contains("CLIPRDR_SVC_CHANNEL_NAME") {
                #expect(strings == 1, "\(statement)")
            } else {
                #expect(strings == 0, "a bridge log line prints a string: \(statement)")
            }
            #expect(!statement.contains("formatName") && !statement.contains("requestedFormatData"), "\(statement)")
        }
        // Every crclip_note call's text is a literal (the blanked view shows it as "").
        let blanked = scan.blanked
        let notes = blanked.matches(of: /crclip_note\((?:bridge->counters|counters), CRCLIP_COUNTER_[A-Z_]+, ("")?/)
        #expect(notes.count == clipCount("crclip_note(", in: blanked) - 1, "a crclip_note call not in the known shape (the definition excepted)")
        #expect(notes.allSatisfy { $0.1 != nil }, "a crclip_note call passes something other than a string literal")
        let flags = try clipBody("uint32_t crclip_format_list_flags(", in: blanked)
        #expect(clipCount("formatName", in: blanked) == clipCount("formatName", in: flags), "formatName outside the comparison")
        #expect(clipCount("crclip_exclusion_names", in: blanked) == clipCount("crclip_exclusion_names", in: flags) + 1, "the table and its use")
        // CRSession.mm's clipboard lines: no string argument either.
        let session = try Self.scanned(Self.session).literal
        for statement in session.components(separatedBy: "WLog_").dropFirst().map({ $0.prefix { $0 != ";" } })
        where statement.contains("[clipboard]") {
            #expect(statement.components(separatedBy: "%s").count == 1, "\(statement)")
        }
    }

    /// m-4 (gate r1): a number in a log line can carry content as well as a string can. Every
    /// crclip_note call's detail -- the fourth argument -- is one of a closed set of spellings, each
    /// a count, a status word, a format or message type, a mode, a generation or a byte count; and
    /// the bytes of a server response are named in exactly two places, the store's put and the
    /// outgoing answer's field.
    static let noteDetails: Set<String> = [
        "(unsigned)type", "sent", "1", "2", "3", "4", "(unsigned)msgFlags", "(unsigned)put",
        "formatList ? (unsigned)formatList->numFormats : 0", "(unsigned)bridge->mode", "(unsigned)ref->storeGeneration",
        "(unsigned)taken", "(unsigned)command->type", "event ? (unsigned)event->byteCount : 0",
    ]

    @Test("m-4: every crclip_note detail comes from a closed set, and the response bytes are named only by the store's put and the answer")
    func logDetailsAreNotContent() throws {
        let code = try Self.scanned(Self.bridgeC).blanked
        let calls = clipCallArguments("crclip_note", in: code)
        let definitions = calls.filter { $0.first?.hasPrefix("crclip_counters_t*") == true }
        #expect(definitions.count == 1, "the definition of crclip_note")
        let uses = calls.filter { $0.first?.hasPrefix("crclip_counters_t*") != true }
        #expect(uses.count == clipCount("crclip_note(", in: code) - 1 && uses.count > 20, "crclip_note calls: \(uses.count)")
        for arguments in uses {
            #expect(arguments.count == 4, "a crclip_note call with \(arguments.count) arguments: \(arguments)")
            #expect(arguments.count == 4 && arguments[2] == "\"\"", "a crclip_note text that is not a literal: \(arguments)")
            if arguments.count == 4 {
                #expect(Self.noteDetails.contains(arguments[3]), "a crclip_note detail outside the closed set: \(arguments[3])")
            }
        }
        #expect(clipCount("requestedFormatData", in: code) == 2)
        let put = "crdpq_clip_store_put(bridge->store, bridge->storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, key, "
            + "formatDataResponse->requestedFormatData, length);"
        #expect(clipCount(put, in: code) == 1, "the response bytes go into the store, and only there")
        #expect(clipCount("response.requestedFormatData = data;", in: code) == 1, "the answer's bytes, in the guarded send")
    }

    static let nameEqualsFolded = "static bool crclip_name_equals_folded(const char* name, const char* constant) { "
        + "for (size_t index = 0;; index++) { unsigned char a = (unsigned char)name[index]; "
        + "unsigned char b = (unsigned char)constant[index]; if (a >= 'A' && a <= 'Z') a = (unsigned char)(a - 'A' + 'a'); "
        + "if (b >= 'A' && b <= 'Z') b = (unsigned char)(b - 'A' + 'a'); if (a != b) return false; "
        + "if (a == '\\0') return true; } }"
    static let formatListFlags = "uint32_t crclip_format_list_flags(const CLIPRDR_FORMAT_LIST* formatList, bool longNamesNegotiated) { "
        + "uint32_t flags = 0; if (!formatList || !formatList->formats) return flags; "
        + "for (UINT32 index = 0; index < formatList->numFormats; index++) { "
        + "const CLIPRDR_FORMAT* format = &formatList->formats[index]; "
        + "if (format->formatId == CF_UNICODETEXT) flags |= CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT; "
        + "if (longNamesNegotiated && format->formatName) { "
        + "for (size_t name = 0; name < ARRAYSIZE(crclip_exclusion_names); name++) { "
        + "if (crclip_name_equals_folded(format->formatName, crclip_exclusion_names[name])) "
        + "flags |= CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED; } } } "
        + "if (!longNamesNegotiated && (flags & CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT) != 0) flags |= CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED; "
        + "return flags; }"
    static let exclusionTable = "static const char* const crclip_exclusion_names[] = { \"ExcludeClipboardContentFromMonitorProcessing\", "
        + "\"CanIncludeInClipboardHistory\", \"CanUploadToCloudClipboard\", \"Clipboard Viewer Ignore\", };"
    static let flagsAndCount = "ref.flags = crclip_format_list_flags(formatList, bridge->longNamesNegotiated); "
        + "if (!bridge->longNamesNegotiated && (ref.flags & CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED) != 0) "
        + "crclip_note(bridge->counters, CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, \"\", "
        + "formatList ? (unsigned)formatList->numFormats : 0); (void)crclip_post(bridge, CRDPQ_EVENT_CLIP_REMOTE_FORMATS, &ref);"
    static let capabilitiesInput = "if (set->capabilitySetType == CB_CAPSTYPE_GENERAL && set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) { "
        + "const CLIPRDR_GENERAL_CAPABILITY_SET* general = (const CLIPRDR_GENERAL_CAPABILITY_SET*)(const void*)set; "
        + "bridge->serverCapabilitiesSeen = true; "
        + "bridge->serverOffersLongNames = (general->generalFlags & CB_USE_LONG_FORMAT_NAMES) != 0; "
        + "if (!bridge->serverOffersLongNames) bridge->longNamesNegotiated = false; }"
    static let readyInput = "bridge->longNamesNegotiated = sent == CHANNEL_RC_OK && bridge->serverCapabilitiesSeen && "
        + "bridge->serverOffersLongNames;"
    static let attachReset = "bridge->nextResponseNumber = 0; bridge->serverCapabilitiesSeen = false; "
        + "bridge->serverOffersLongNames = false; bridge->longNamesNegotiated = false;"

    /// I-2 (gate r1): the exclusion flag and fold 0's conservative direction, frozen whole the way
    /// the mode-to-mask table is -- the flag function and its name comparison (in the view that
    /// keeps character literals, so the folded range is part of the text), the name table, the
    /// format-list callback's flag and count statements (the count follows from the flags), and the
    /// three places the negotiation input is written: the capabilities callback (records, and only
    /// ever downgrades), Monitor Ready (the one upgrade, after the client's capabilities went out),
    /// attach (resets). Changing any of them means changing this pin with it.
    @Test("I-2: the flag function, its name comparison, the flag-and-count statements and the negotiation inputs, frozen whole")
    func exclusionFlagAndNegotiationFrozen() throws {
        let scan = try Self.scanned(Self.bridgeC)
        let flags = try clipBody("uint32_t crclip_format_list_flags(", in: scan.literal)
        #expect(flags == Self.formatListFlags, "\(flags)")
        let fold = try clipBody("static bool crclip_name_equals_folded(", in: scan.literal)
        #expect(fold == Self.nameEqualsFolded, "\(fold)")
        #expect(clipCount(Self.exclusionTable, in: scan.literal) == 1, "the exclusion-name table changed")
        let code = scan.blanked
        let list = try clipBody("static UINT crclip_on_server_format_list(CliprdrClientContext* context, const ", in: code)
        #expect(clipCount(Self.flagsAndCount, in: list) == 1, "the flags and the count: \(list)")
        #expect(clipCount("crclip_format_list_flags(", in: code) == 2, "its definition and its one call")
        #expect(clipCount("crclip_name_equals_folded(", in: code) == 2, "its definition and its one call")
        #expect(clipCount("CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES", in: code) == 1)
        #expect(clipCount("ref.flags =", in: code) == 1, "the flags are set in one place")
        let capabilities = try clipBody("static UINT crclip_on_server_capabilities(CliprdrClientContext* context, const ", in: code)
        #expect(clipCount(Self.capabilitiesInput, in: capabilities) == 1, "\(capabilities)")
        let ready = try clipBody("static UINT crclip_on_monitor_ready(CliprdrClientContext* context, const ", in: code)
        #expect(clipCount(Self.readyInput, in: ready) == 1, "\(ready)")
        let sentAt = try #require(ready.range(of: "const UINT sent ="))
        let upgradeAt = try #require(ready.range(of: Self.readyInput))
        #expect(sentAt.lowerBound < upgradeAt.lowerBound, "the upgrade comes after the client's capabilities were sent")
        let attach = try clipBody("bool crclip_bridge_attach(", in: code)
        #expect(clipCount(Self.attachReset, in: attach) == 1, "\(attach)")
        // Nothing else writes the three: exactly the writes frozen above, in the whole file -- a
        // compound assignment or an increment counts as a write too (gate r2 m-r2-3).
        #expect(try clipWriteCount("serverCapabilitiesSeen", in: code) == 2)
        #expect(try clipWriteCount("serverOffersLongNames", in: code) == 2)
        #expect(try clipWriteCount("longNamesNegotiated", in: code) == 3)
    }

    /// Lifecycle (adr/0005 addendum section 5, H-5): created by -start from the caller's limit,
    /// cleared by -shutdownAndWait beside the icon store and before the generation bump, destroyed
    /// in -dealloc; the drain hands clipboard events to the clipboard handler only, and discards and
    /// counts a remote-data entry nobody settled.
    @Test("H-5: the store's lifecycle, and the drain settles every remote-data entry")
    func storeLifecycleAndDrain() throws {
        let session = try Self.scanned(Self.session).blanked
        let shutdown = try clipBody("- (BOOL)shutdownAndWait", in: session)
        let expected6: String = "if (_iconStore) crdpq_icon_store_clear(_iconStore); if (_clipStore) (void)crdpq_clip_store_clear(_clipStore); "
            + "crdpq_generation_bump(_controlQueue);"
        #expect(shutdown.contains(expected6))
        // -start hands the limit to the bridge's crclip_store_for_limit (create, keep, replace or
        // destroy -- Tools/cliprdr-check drives that function), and nothing else creates a store.
        let start = try clipBody("- (void)start", in: session)
        let expected7: String = "_clipStoreLimit = crclip_store_for_limit(&_clipStore, _clipStoreLimit, self.clipboardByteLimit);"
        #expect(clipCount(expected7, in: start) == 1)
        #expect(clipCount("crclip_store_for_limit(", in: session) == 1 && clipCount("_clipStoreLimit =", in: session) == 1)
        #expect(clipCount("crdpq_clip_store_create(", in: session) == 0)
        let bridgeCode = try Self.scanned(Self.bridgeC).blanked
        let storeForLimit = try clipBody("size_t crclip_store_for_limit(", in: bridgeCode)
        #expect(clipCount("crdpq_clip_store_create(", in: bridgeCode) == 1 && clipCount("crdpq_clip_store_create(", in: storeForLimit) == 1)
        let dealloc = try clipBody("- (void)dealloc", in: session)
        #expect(dealloc.contains("crdpq_clip_store_destroy(_clipStore);"))
        let drain = try clipBody("- (NSUInteger)drainEventsWithHandler:", in: session)
        let expected8: String = "if (ev->type == CRDPQ_EVENT_CLIP_READY || ev->type == CRDPQ_EVENT_CLIP_REMOTE_FORMATS || "
            + "ev->type == CRDPQ_EVENT_CLIP_REMOTE_DATA || ev->type == CRDPQ_EVENT_CLIP_DATA_REQUEST) { "
            + "CRClipboardEvent *clipEvent = [[CRClipboardEvent alloc] initFromEvent:ev]; "
            + "if (dctx->clipboardHandler) dctx->clipboardHandler(clipEvent); if (!clipEvent.entrySettled) { "
            + "clipEvent.entrySettled = YES; crclip_settle_unconsumed(dctx->clipStore, dctx->clipCounters, &clipEvent->_ref); } "
            + "return; }"
        #expect(drain.contains(expected8), "the clipboard branch of the drain")
        #expect(clipCount("crclip_settle_unconsumed(", in: session) == 1, "the drain's one fallback")
        // The bridge's own copies of clipboard bytes are wiped before they are freed (the store wipes
        // its blocks itself; these are the two buffers the bridge takes them into).
        let bridge = try Self.scanned(Self.bridgeC).blanked
        #expect(clipCount("crdpq_clip_wipe(bytes, capacity); free(bytes);", in: bridge) == 1, "the answer's copy on T_rdp")
        #expect(clipCount("crdpq_clip_wipe(buffer, capacity); free(buffer);", in: bridge) == 1, "the response's copy on T_main")
        #expect(clipCount("free(", in: bridge) == 3, "those two and the counter table")
        // The branch returns before the ordinary handler could see a clipboard event.
        let branch = try #require(drain.range(of: "CRClipboardEvent *clipEvent"))
        let ordinary = try #require(drain.range(of: "CRDPEvent *event = CRDPEventFromCrdpEvent(ev, dctx->iconStore);"))
        #expect(branch.lowerBound < ordinary.lowerBound)
        #expect(drain[branch.lowerBound..<ordinary.lowerBound].contains("return; }"))
    }

    static let wrappers: [String] = [
        "- (BOOL)announceClipboardFormat:(uint32_t)formatId { return crclip_announce(_outboundQueue, _clipCounters, formatId); }",
        "- (BOOL)requestClipboardFormat:(uint32_t)formatId { return crclip_request(_outboundQueue, _clipCounters, formatId); }",
        "- (BOOL)respondToClipboardDataRequest:(CRClipboardEvent *)request bytes:(nullable NSData *)bytes { "
            + "if (!request || request.kind != CRClipboardEventKindDataRequest || ![self crb_clipboardEventIsCurrent:request]) return NO; "
            + "const crclip_respond_result_t result = crclip_respond(_outboundQueue, _clipStore, _clipCounters, ++_clipAnswerSequence, "
            + "&request->_ref, bytes != nil, (const uint8_t *)bytes.bytes, bytes.length); "
            + "return result == CRCLIP_RESPOND_POSTED || result == CRCLIP_RESPOND_POSTED_AS_FAILURE; }",
        "- (BOOL)takeClipboardRemoteData:(CRClipboardEvent *)event reader:(NS_NOESCAPE void (^)(const uint8_t *_Nullable bytes, "
            + "NSUInteger length))reader { if (!event || event.kind != CRClipboardEventKindRemoteData || event.entrySettled) return NO; "
            + "event.entrySettled = YES; if (![self crb_clipboardEventIsCurrent:event] || !reader) { "
            + "if ([self crb_clipboardEventIsCurrent:event]) crclip_discard_remote(_clipStore, &event->_ref); return NO; } "
            + "return crclip_take_remote(_clipStore, &event->_ref, crb_clipboard_reader, (__bridge void *)reader); }",
        "- (void)discardClipboardRemoteData:(CRClipboardEvent *)event { "
            + "if (!event || event.kind != CRClipboardEventKindRemoteData || event.entrySettled) return; event.entrySettled = YES; "
            + "if ([self crb_clipboardEventIsCurrent:event]) crclip_discard_remote(_clipStore, &event->_ref); }",
        "- (BOOL)crb_clipboardEventIsCurrent:(CRClipboardEvent *)event { "
            + "return _controlQueue && event.generation == crdpq_current_generation(_controlQueue); }",
    ]

    /// The session's clipboard methods are pass-throughs to the bridge's T_main functions, which
    /// Tools/cliprdr-check drives: each body frozen whole -- the event-kind and generation guards
    /// included -- so nothing decides or stores anything on the ObjC side.
    @Test("the session's clipboard methods only forward to the bridge's T_main functions, behind their event guards")
    func theMethodsOnlyForward() throws {
        let session = try Self.scanned(Self.session).blanked
        for wrapper in Self.wrappers {
            #expect(clipCount(wrapper, in: session) == 1, "not frozen: \(wrapper.prefix(80))")
        }
        for function in ["crclip_announce(", "crclip_request(", "crclip_respond(", "crclip_take_remote("] {
            #expect(clipCount(function, in: session) == 1, "\(function) is called once, from its wrapper")
        }
        #expect(clipCount("crclip_post_command(", in: session) == 0, "commands are posted only through the bridge's senders")
        #expect(clipCount("crdpq_clip_store_put(", in: session) == 0 && clipCount("crdpq_clip_store_take(", in: session) == 0,
                "the session never touches the store's blocks itself")
        #expect(clipCount("crclip_discard_remote(", in: session) == 2)
    }

    /// The property, in every spelling: the header declares it, the pre-connect step reads it once,
    /// nothing else in the bridge names it, and no file of the App or under Tools/ sets it -- the
    /// harnesses stay Unmanaged by never touching it (L4 will be the App's one writer).
    @Test("clipboardMode: declared once, read once by the pre-connect step, named by no App or Tools file")
    func theModeIsSetByNoOne() throws {
        let header = try Self.scanned("App/CRBridge/CRSession.h").blanked
        #expect(clipboardModePropertyMentions(in: header) == 1, "the @property and nothing beside it")
        #expect(clipCount("@property (nonatomic) CRClipboardMode clipboardMode;", in: header) == 1)
        let session = try Self.scanned(Self.session).blanked
        #expect(clipboardModePropertyMentions(in: session) == 1, "the one read in crb_pre_connect")
        #expect(clipCount("session.clipboardMode", in: session) == 1)
        for file in [Self.bridgeC, Self.bridgeH] {
            #expect(clipboardModePropertyMentions(in: try Self.scanned(file).blanked) == 0, "\(file)")
        }
        var walked = 0
        for directory in ["App/Macdows", "App/UI", "App/SessionControl", "App/Security", "App/RemoteWindowRendering", "Tools"] {
            for file in try clipSourceFiles(under: directory) {
                walked += 1
                let text = try clipSource(file)
                #expect(text.range(of: "clipboardmode", options: .caseInsensitive) == nil, "\(file) names the clipboard mode")
                for needle in ["clipboardSettingsProbe", "CRClipboardProbeSetup"] {
                    #expect(!text.contains(needle), "\(file) names \(needle)")
                }
            }
        }
        #expect(walked > 50, "the walk found the sources (\(walked))")
        // The spellings the rule must see, on fixture lines (an ObjC++ harness, the bridge, Swift).
        for line in ["[session setClipboardMode:CRClipboardModeBidirectional];", "session.clipboardMode = CRClipboardModeOff;",
                     "x = [session clipboardMode];", "self->_clipboardMode = 2;", "[s setValue:@2 forKey:@\"clipboardMode\"];",
                     "newSession.clipboardMode=CRClipboardMode.off", "[s performSelector:@selector(setClipboardMode:) withObject:nil];"] {
            #expect(clipboardModePropertyMentions(in: line) == 1, "\(line)")
            #expect(line.range(of: "clipboardmode", options: .caseInsensitive) != nil)
        }
    }
}
