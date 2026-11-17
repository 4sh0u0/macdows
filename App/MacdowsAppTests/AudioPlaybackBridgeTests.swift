import Foundation
import Testing

// adr/0026 (proposed) lane L1: the bridge half of basic audio playback. `CRSession.audioPlaybackMode`
// is read once by the pre-connect step, which hands it to `crb_apply_audio_playback_mode` -- a
// function of the mode and an `rdpSettings *` only. Two suites and the name checks they share:
//
//  * behaviour: `+[CRSession audioPlaybackSettingsProbeForMode:setup:]` runs that very function on
//    a fresh client settings object of FreeRDP's (the linked prefix, offline, no connection) and
//    reads the three audio flags and both channel collections back, for each mode, with seeds that
//    tell "writes FreeRDP's default" from "writes nothing" and put an earlier writer's rdpsnd entry
//    in place, and with two replays of what FreeRDP's default channel loading does after the
//    pre-connect step: its rdpsnd add calls made unconditionally, and its rdpsnd handling under its
//    own conditions (step 2 included, which turns playback on for any rdpsnd entry it finds);
//  * source: what a settings object cannot show -- that the step is called from the pre-connect
//    path, once, before the frozen subscription block; that the two privacy writes come first and
//    fail closed on both managed paths; that Off removes earlier entries or refuses; the On
//    arguments as literals; the two probes' bodies; that the App never calls the test probes and
//    that nothing but that one call names the mode in the bridge, in any spelling, and no harness
//    under `Tools/` names it at all;
//  * the name checks themselves, run on fixture strings in the spellings a harness or the bridge
//    could use (gate r1 I-1: a case-sensitive `audioPlaybackMode` substring missed the ObjC
//    message send `[session setAudioPlaybackMode:]`).
//
// What neither suite reaches (left to the in-person acceptance batch): what the host does with the
// offer -- whether it opens the static channel or AUDIO_PLAYBACK_DVC, which PCM format it picks --
// and whether the mac backend actually plays.

private let onEntry = ["rdpsnd", "sys:mac", "format:1", "channel:2"]
private let oneChannelEntry = ["rdpsnd", "sys:mac", "format:1", "channel:1"]
private let fakeEntry = ["rdpsnd", "sys:fake"]

@Suite("adr/0026 L1 — the connect path's audio step, run on a fresh FreeRDP settings object")
struct AudioPlaybackSettingsTests {
    private static func probe(_ mode: CRAudioPlaybackMode, _ setup: CRAudioPlaybackProbeSetup = []) throws
        -> CRAudioPlaybackSettingsProbe {
        try #require(CRSession.audioPlaybackSettingsProbe(mode: mode, setup: setup), "the probe could not build its settings")
    }

    @Test("the mode's raw values and a new session's default: Unmanaged is 0 and is what a CRSession starts with")
    func theDefaultIsUnmanaged() {
        #expect(CRAudioPlaybackMode.unmanaged.rawValue == 0)
        #expect(CRAudioPlaybackMode.off.rawValue == 1)
        #expect(CRAudioPlaybackMode.on.rawValue == 2)
        let session = CRSession(host: "", user: "", passwordBytes: Data(), program: "")
        #expect(session.audioPlaybackMode == .unmanaged)
    }

    @Test("Unmanaged writes nothing: FreeRDP's defaults stay, seeded flags stay, a seeded channel stays, nothing is added")
    func unmanagedWritesNothing() throws {
        let fresh = try Self.probe(.unmanaged)
        #expect(fresh.applied)
        #expect(!fresh.audioPlayback && !fresh.audioCapture && !fresh.remoteConsoleAudio, "FreeRDP's client defaults")
        #expect(fresh.staticChannels.isEmpty && fresh.dynamicChannels.isEmpty)

        let seeded = try Self.probe(.unmanaged, .seedAudioFlags)
        #expect(seeded.applied)
        #expect(seeded.audioPlayback && seeded.audioCapture && seeded.remoteConsoleAudio, "not one of the three was written")
        #expect(seeded.staticChannels.isEmpty && seeded.dynamicChannels.isEmpty)

        let withFake = try Self.probe(.unmanaged, .seedFakeRdpsnd)
        #expect(withFake.applied)
        #expect(withFake.staticChannels == [fakeEntry] && withFake.dynamicChannels == [fakeEntry], "an existing entry is left alone")
        #expect(!withFake.audioPlayback)
    }

    /// Gate r1 m-6: FreeRDP's step 2 of `load_addins` sets `AudioPlayback` TRUE whenever either
    /// collection holds an rdpsnd entry, so an entry Off left in place would overturn it.
    @Test("Off writes AudioPlayback, AudioCapture and RemoteConsoleAudio FALSE, removes every rdpsnd entry and adds none")
    func offWritesTheThreeFlagsFalse() throws {
        let fresh = try Self.probe(.off)
        #expect(fresh.applied)
        #expect(!fresh.audioPlayback && !fresh.audioCapture && !fresh.remoteConsoleAudio)
        #expect(fresh.staticChannels.isEmpty && fresh.dynamicChannels.isEmpty)

        let seeded = try Self.probe(.off, .seedAudioFlags)
        #expect(seeded.applied)
        #expect(!seeded.audioPlayback, "Off writes the playback flag")
        #expect(!seeded.audioCapture, "Off writes the capture flag (privacy)")
        #expect(!seeded.remoteConsoleAudio, "Off writes the remote-console flag (privacy)")
        #expect(seeded.staticChannels.isEmpty && seeded.dynamicChannels.isEmpty)

        for seed: CRAudioPlaybackProbeSetup in [.seedFakeRdpsnd, .seedOneChannelRdpsnd, [.seedFakeRdpsnd, .seedAudioFlags]] {
            let earlier = try Self.probe(.off, seed)
            #expect(earlier.applied, "seed \(seed.rawValue): removing an entry does not refuse the connection")
            #expect(!earlier.audioPlayback, "seed \(seed.rawValue)")
            #expect(earlier.staticChannels.isEmpty, "seed \(seed.rawValue): no rdpsnd entry is left: \(earlier.staticChannels)")
            #expect(earlier.dynamicChannels.isEmpty, "seed \(seed.rawValue): no rdpsnd entry is left: \(earlier.dynamicChannels)")
        }
    }

    /// Gate r1 m-6, the outcome. `.replayUpstreamLoad` plays FreeRDP's rdpsnd handling after the
    /// step under its own conditions: step 1 `{rdpsnd}` dynamic if playback is on; step 2 playback
    /// TRUE if either collection holds rdpsnd; the rdpdr step's `rdpsnd sys:fake` in both if neither
    /// does; step 3 `{rdpsnd}` static if playback is on. The Unmanaged control over a seeded entry
    /// shows step 2 is live in the replay -- that is the overturned Off this fold closes -- so the
    /// Off results are not a replay that did nothing.
    @Test("Off over an earlier rdpsnd entry, then FreeRDP's own loading: playback stays off and the channels are a fresh Off's")
    func offStaysOffThroughFreeRDPsLoading() throws {
        let today = try Self.probe(.unmanaged, .replayUpstreamLoad)
        #expect(!today.audioPlayback)
        #expect(today.staticChannels == [fakeEntry] && today.dynamicChannels == [fakeEntry], "what a connection loads without this lane")

        let fresh = try Self.probe(.off, .replayUpstreamLoad)
        #expect(fresh.applied && !fresh.audioPlayback)
        #expect(fresh.staticChannels == today.staticChannels && fresh.dynamicChannels == today.dynamicChannels, "Off loads what it always has")

        for seed: CRAudioPlaybackProbeSetup in [.seedFakeRdpsnd, .seedOneChannelRdpsnd] {
            let earlier = try Self.probe(.off, [seed, .replayUpstreamLoad])
            #expect(earlier.applied, "seed \(seed.rawValue)")
            #expect(!earlier.audioPlayback, "seed \(seed.rawValue): step 2 found no rdpsnd entry to turn playback back on for")
            #expect(earlier.staticChannels == [fakeEntry], "seed \(seed.rawValue): \(earlier.staticChannels)")
            #expect(earlier.dynamicChannels == [fakeEntry], "seed \(seed.rawValue): \(earlier.dynamicChannels)")
        }

        let control = try Self.probe(.unmanaged, [.seedOneChannelRdpsnd, .replayUpstreamLoad])
        #expect(control.audioPlayback, "an rdpsnd entry left in place turns playback on in step 2")
        #expect(control.staticChannels == [oneChannelEntry] && control.dynamicChannels == [oneChannelEntry])

        // The unconditional add replay over the same seed: with the collections emptied by Off it
        // adds what it adds to a fresh settings object (compare the Off control below).
        let adds = try Self.probe(.off, [.seedFakeRdpsnd, .replayUpstreamAdds])
        #expect(adds.applied && !adds.audioPlayback)
        #expect(adds.staticChannels == [fakeEntry] && adds.dynamicChannels == [["rdpsnd"]], "\(adds.staticChannels) \(adds.dynamicChannels)")
    }

    @Test("On: AudioPlayback TRUE, capture and remote console FALSE, rdpsnd sys:mac format:1 channel:2 in both collections and nothing else")
    func onAddsTheEntryToBothCollections() throws {
        let fresh = try Self.probe(.on)
        #expect(fresh.applied)
        #expect(fresh.audioPlayback)
        #expect(!fresh.audioCapture && !fresh.remoteConsoleAudio)
        #expect(fresh.staticChannels == [onEntry], "\(fresh.staticChannels)")
        #expect(fresh.dynamicChannels == [onEntry], "\(fresh.dynamicChannels)")

        let seeded = try Self.probe(.on, .seedAudioFlags)
        #expect(seeded.applied && seeded.audioPlayback)
        #expect(!seeded.audioCapture, "On writes the capture flag (privacy)")
        #expect(!seeded.remoteConsoleAudio, "On writes the remote-console flag (privacy)")
        #expect(seeded.staticChannels == [onEntry] && seeded.dynamicChannels == [onEntry])
    }

    /// FreeRDP's default channel loading runs after the pre-connect step and adds `{rdpsnd}` (dynamic,
    /// step 1), `{rdpsnd, sys:fake}` (static and dynamic, next to rdpdr) and `{rdpsnd}` (static, step 3)
    /// through the two add functions, which return TRUE without adding when an entry of that name
    /// exists (cmdline.c). The replay makes those calls unconditionally; the Off control shows that the
    /// same replay does add when no rdpsnd entry is there, so the On result is not a replay that did
    /// nothing. The conditional replay (`.replayUpstreamLoad`) gives the same On result.
    @Test("On survives FreeRDP's default rdpsnd adds unchanged: same-name entries are not added twice, sys:fake never lands")
    func onSurvivesTheDefaultAdds() throws {
        let on = try Self.probe(.on, .replayUpstreamAdds)
        #expect(on.applied && on.audioPlayback)
        #expect(on.staticChannels == [onEntry], "\(on.staticChannels)")
        #expect(on.dynamicChannels == [onEntry], "\(on.dynamicChannels)")

        let control = try Self.probe(.off, .replayUpstreamAdds)
        #expect(control.staticChannels == [fakeEntry], "the replay adds when nothing is there: \(control.staticChannels)")
        #expect(control.dynamicChannels == [["rdpsnd"]], "the replay adds when nothing is there: \(control.dynamicChannels)")

        let loaded = try Self.probe(.on, .replayUpstreamLoad)
        #expect(loaded.applied && loaded.audioPlayback)
        #expect(loaded.staticChannels == [onEntry] && loaded.dynamicChannels == [onEntry], "\(loaded.staticChannels) \(loaded.dynamicChannels)")
    }

    @Test("On over an rdpsnd entry that is not its own: no playback, every rdpsnd entry removed, the connection goes on")
    func onFallsBackToNoPlayback() throws {
        let fallback = try Self.probe(.on, .seedFakeRdpsnd)
        #expect(fallback.applied, "an audio problem does not refuse the connection")
        #expect(!fallback.audioPlayback, "no playback: the host is told not to send audio")
        #expect(!fallback.audioCapture && !fallback.remoteConsoleAudio)
        #expect(fallback.staticChannels.isEmpty, "\(fallback.staticChannels)")
        #expect(fallback.dynamicChannels.isEmpty, "\(fallback.dynamicChannels)")

        let seeded = try Self.probe(.on, [.seedFakeRdpsnd, .seedAudioFlags])
        #expect(seeded.applied)
        #expect(!seeded.audioPlayback, "the fallback writes the playback flag FALSE")
        #expect(!seeded.audioCapture && !seeded.remoteConsoleAudio, "the privacy writes came first")
        #expect(seeded.staticChannels.isEmpty && seeded.dynamicChannels.isEmpty)

        // What the connection then loads is what Off loads (CRSession.h: "exactly as under Off").
        let loaded = try Self.probe(.on, [.seedFakeRdpsnd, .replayUpstreamLoad])
        #expect(loaded.applied && !loaded.audioPlayback)
        #expect(loaded.staticChannels == [fakeEntry] && loaded.dynamicChannels == [fakeEntry], "\(loaded.staticChannels) \(loaded.dynamicChannels)")
    }

    /// Gate r1 m-1: the entry check must compare EVERY argument. The seed is the On entry with only
    /// its last argument changed -- `channel:1`, which would offer one-channel PCM, the format the
    /// mac backend cannot play without an uncaught exception (see the comment on the On arguments).
    @Test("On over an entry that differs from its own only in the last argument (channel:1): refused like any other, no playback")
    func onRefusesAnEntryThatDiffersOnlyInItsLastArgument() throws {
        let seedShape = try Self.probe(.unmanaged, .seedOneChannelRdpsnd)
        #expect(seedShape.staticChannels == [oneChannelEntry] && seedShape.dynamicChannels == [oneChannelEntry], "the seed is what it says")
        #expect(Array(oneChannelEntry.dropLast()) == Array(onEntry.dropLast()) && oneChannelEntry.last != onEntry.last)

        let fallback = try Self.probe(.on, .seedOneChannelRdpsnd)
        #expect(fallback.applied, "an audio problem does not refuse the connection")
        #expect(!fallback.audioPlayback, "channel:1 is not the On entry")
        #expect(fallback.staticChannels.isEmpty, "\(fallback.staticChannels)")
        #expect(fallback.dynamicChannels.isEmpty, "\(fallback.dynamicChannels)")
        #expect(!fallback.audioCapture && !fallback.remoteConsoleAudio)
    }

    @Test("a value outside the three is treated as Off")
    func anUnknownModeIsOff() throws {
        let mode = try #require(CRAudioPlaybackMode(rawValue: 7))
        let unknown = try Self.probe(mode, .seedAudioFlags)
        #expect(unknown.applied)
        #expect(!unknown.audioPlayback && !unknown.audioCapture && !unknown.remoteConsoleAudio)
        #expect(unknown.staticChannels.isEmpty && unknown.dynamicChannels.isEmpty)

        let withFake = try Self.probe(mode, .seedFakeRdpsnd)
        #expect(withFake.applied && !withFake.audioPlayback)
        #expect(withFake.staticChannels.isEmpty && withFake.dynamicChannels.isEmpty, "Off's removal too")
    }

    @Test("the linked FreeRDP has the mac playback backend for the static and the dynamic rdpsnd; the lookup says no to a name it lacks")
    func theMacBackendIsLinked() {
        for dynamic in [false, true] {
            #expect(CRSession.rdpsndPlaybackBackendIsLinked("mac", dynamic: dynamic), "mac, dynamic=\(dynamic)")
            #expect(CRSession.rdpsndPlaybackBackendIsLinked("fake", dynamic: dynamic), "fake, dynamic=\(dynamic)")
            #expect(!CRSession.rdpsndPlaybackBackendIsLinked("no-such-backend", dynamic: dynamic), "a bogus name, dynamic=\(dynamic)")
        }
    }
}

// MARK: - Name checks shared with AudioPlaybackPreferencesTests (gate r1 I-1)

/// Comments removed -- `/* ... */` and `//` to the end of the line -- by one scan that steps over
/// string and character literals, so a `//` inside a quoted URL is not taken for a comment. One
/// line's string never runs into the next (an unclosed quote ends at the newline).
func audioPlaybackCodeWithoutComments(_ text: String) -> String {
    let bytes = Array(text.utf8)
    let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), newline = UInt8(ascii: "\n")
    let backslash = UInt8(ascii: "\\"), quote = UInt8(ascii: "\""), apostrophe = UInt8(ascii: "'")
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        let next: UInt8? = index + 1 < bytes.count ? bytes[index + 1] : nil
        if byte == slash && next == star {
            var end = index + 2
            while end + 1 < bytes.count && !(bytes[end] == star && bytes[end + 1] == slash) { end += 1 }
            out.append(UInt8(ascii: " "))
            index = min(end + 2, bytes.count)
        } else if byte == slash && next == slash {
            while index < bytes.count && bytes[index] != newline { index += 1 }
        } else if byte == quote || byte == apostrophe {
            out.append(byte)
            index += 1
            while index < bytes.count && bytes[index] != byte && bytes[index] != newline {
                if bytes[index] == backslash && index + 1 < bytes.count && bytes[index + 1] != newline {
                    out.append(bytes[index])
                    index += 1
                }
                out.append(bytes[index])
                index += 1
            }
            if index < bytes.count && bytes[index] == byte {
                out.append(byte)
                index += 1
            }
        } else {
            out.append(byte)
            index += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// How often `code` names the `audioPlaybackMode` PROPERTY, in any spelling and any case: the
/// getter or a Swift setter (with or without spaces around `=`), the ObjC message
/// `setAudioPlaybackMode:`, the synthesized ivar `_audioPlaybackMode`, a KVC key or a selector
/// string. The type `CRAudioPlaybackMode` and its constants contain the same letters and are not
/// counted. Callers pass code with comments removed.
func audioPlaybackModePropertyMentions(in code: String) -> Int {
    let anySpelling = code.lowercased().components(separatedBy: "audioplaybackmode").count - 1
    let theType = code.components(separatedBy: "CRAudioPlaybackMode").count - 1
    return anySpelling - theType
}

/// Whether `text` names the mode at all, the type included, in any case -- the rule for the
/// harnesses under `Tools/`, which stay Unmanaged by never touching it.
func audioPlaybackModeIsNamed(in text: String) -> Bool {
    text.range(of: "audioplaybackmode", options: .caseInsensitive) != nil
}

/// The walks skip build products and generated projects: `build/` (xcodebuild's derived data under
/// `App/`), `.build/` (SwiftPM's, e.g. under `Tools/replay-diff/`) and `*.xcodeproj/`. `path` is
/// relative to the repository root.
func audioPlaybackWalkSkips(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0 == "build" || $0 == ".build" || $0.hasSuffix(".xcodeproj") }
}

/// The C, Objective-C and Swift sources under `relative` (repository-relative paths, sorted),
/// minus what `audioPlaybackWalkSkips` skips.
func audioPlaybackSourceFiles(under relative: String) throws -> [String] {
    let root = audioRepoRoot()
    let walker = try #require(FileManager.default.enumerator(atPath: root.appendingPathComponent(relative).path))
    var files: [String] = []
    for case let entry as String in walker {
        let path = "\(relative)/\(entry)"
        if audioPlaybackWalkSkips(path) {
            walker.skipDescendants()
            continue
        }
        if ["swift", "m", "mm", "c", "h"].contains((entry as NSString).pathExtension) { files.append(path) }
    }
    return files.sorted()
}

// MARK: - Source

func audioRepoRoot() -> URL {
    // <repo>/App/MacdowsAppTests/<this file>
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func audioSource(_ relative: String) throws -> String {
    try String(contentsOf: audioRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func audioOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private func audioFolded(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `/* ... */` comments removed (the bridge's explanations are block comments), then folded.
private func audioBridgeCode(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "/*") {
        out += rest[rest.startIndex..<open.lowerBound]
        out += " "
        guard let close = rest[open.upperBound...].range(of: "*/") else { return audioFolded(out) }
        rest = rest[close.upperBound...]
    }
    out += rest
    return audioFolded(out)
}

/// From `signature` to the first `\n}\n` after it (the bridge's functions close at column 0).
private func audioBody(_ signature: String, in raw: String) throws -> String {
    let start = try #require(raw.range(of: signature), "not found: \(signature)").lowerBound
    let end = try #require(raw[start...].range(of: "\n}\n"), "no closing brace after \(signature)")
    return String(raw[start..<end.upperBound])
}

@Suite("adr/0026 L1 — the audio step and its call site, pinned as source")
struct AudioPlaybackBridgePinTests {
    static let bridge = "App/CRBridge/CRSession.mm"
    static let stepSignature = "static BOOL crb_apply_audio_playback_mode(rdpSettings *settings, CRAudioPlaybackMode mode)"
    static let probeSignature = "+ (nullable CRAudioPlaybackSettingsProbe *)audioPlaybackSettingsProbeForMode:"
    static let probeInitSignature = "- (instancetype)initWithApplied:(BOOL)applied settings:(const rdpSettings *)settings\n{"
    static let backendProbeSignature = "+ (BOOL)rdpsndPlaybackBackendIsLinked:(NSString *)subsystem dynamic:(BOOL)dynamic"
    static let call = "if (!crb_apply_audio_playback_mode(settings, session.audioPlaybackMode)) return FALSE;"
    static let onArguments =
        "static const char *const crb_rdpsnd_playback_args[] = {RDPSND_CHANNEL_NAME, \"sys:mac\", \"format:1\", \"channel:2\"};"

    @Test("the step opens with Unmanaged's return, then the two privacy writes, fail-closed, before the Off / On branch")
    func privacyWritesComeFirstOnBothManagedPaths() throws {
        let raw = try audioSource(Self.bridge)
        let step = audioBridgeCode(try audioBody(Self.stepSignature, in: raw))
        // One text: Unmanaged leaves before any write; every other value -- Off, On, unknown -- passes
        // both privacy writes, each refusing the connection on failure, before the first branch on it.
        let opening: String = [
            Self.stepSignature, " { ",
            "if (mode == CRAudioPlaybackModeUnmanaged) return TRUE; ",
            "if (!freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE)) return FALSE; ",
            "if (!freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, FALSE)) return FALSE; ",
            "if (mode != CRAudioPlaybackModeOn) { ",
        ].joined()
        #expect(step.hasPrefix(opening), "\(step.prefix(400))")
        // Each privacy setting is written exactly once in the step, and only to FALSE.
        #expect(audioOccurrences(of: "FreeRDP_AudioCapture", in: step) == 1)
        #expect(audioOccurrences(of: "FreeRDP_RemoteConsoleAudio", in: step) == 1)
        #expect(audioOccurrences(of: "return TRUE;", in: step) == 4, "Unmanaged, Off, On, the fallback")
        #expect(audioOccurrences(of: "CRAudioPlaybackModeUnmanaged", in: step) == 1)
        // The playback flag: FALSE for Off (refusing if that fails), TRUE as On's last step, FALSE in the fallback.
        let offTail: String = [
            "if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE)) return FALSE; ",
            "WLog_INFO(TAG, \"[audio] playback mode=off\"); return TRUE; }",
        ].joined()
        #expect(step.contains(offTail))
        #expect(step.contains("else if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE)) failedStep = 5;"))
        #expect(audioOccurrences(of: "FreeRDP_AudioPlayback", in: step) == 3)
    }

    /// Gate r1 m-6: the Off branch, whole -- the unknown-value WARN, the removal of every earlier
    /// rdpsnd entry that refuses the connection (one ERR of numbers) when an entry stays, then the
    /// flag. Removal is called from exactly two places in the step: Off and On's fallback.
    @Test("Off removes every earlier rdpsnd entry or refuses the connection, then writes its flag")
    func offRemovesEarlierEntriesOrRefuses() throws {
        let raw = try audioSource(Self.bridge)
        let step = audioBridgeCode(try audioBody(Self.stepSignature, in: raw))
        let offBranch: String = [
            "if (mode != CRAudioPlaybackModeOn) { ",
            "if (mode != CRAudioPlaybackModeOff) WLog_WARN(TAG, \"[audio] playback mode=%ld is not a known mode -- treated as off\", (long)mode); ",
            "if (!crb_remove_rdpsnd_entries(settings)) { ",
            "WLog_ERR(TAG, \"[audio] playback mode=%ld could not remove an rdpsnd entry -- refusing the connection\", (long)mode); ",
            "return FALSE; } ",
            "if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE)) return FALSE; ",
            "WLog_INFO(TAG, \"[audio] playback mode=off\"); return TRUE; } ",
            "int failedStep = 0; ",
        ].joined()
        #expect(audioOccurrences(of: offBranch, in: step) == 1, "the Off branch, followed by On's first line")
        #expect(audioOccurrences(of: "crb_remove_rdpsnd_entries(settings)", in: step) == 2, "Off and On's fallback")
    }

    @Test("On: the backend check, then both adds with the four literal arguments, the entry check, the flag; the fallback removes and logs numbers")
    func theOnPathAndItsFallback() throws {
        let raw = try audioSource(Self.bridge)
        let code = audioBridgeCode(raw)
        let step = audioBridgeCode(try audioBody(Self.stepSignature, in: raw))
        #expect(audioOccurrences(of: Self.onArguments, in: code) == 1)
        for literal in ["\"sys:mac\"", "\"format:1\"", "\"channel:2\""] {
            #expect(audioOccurrences(of: literal, in: raw) == 1, "\(literal) is spelled once")
        }
        #expect(audioOccurrences(of: "static const char *const crb_rdpsnd_playback_backend = \"mac\";", in: code) == 1)
        let onSequence: String = [
            "int failedStep = 0; ",
            "if (!crb_rdpsnd_backend_linked(crb_rdpsnd_playback_backend, FALSE) || ",
            "!crb_rdpsnd_backend_linked(crb_rdpsnd_playback_backend, TRUE)) failedStep = 1; ",
            "else if (!freerdp_client_add_static_channel(settings, ARRAYSIZE(crb_rdpsnd_playback_args), crb_rdpsnd_playback_args)) failedStep = 2; ",
            "else if (!freerdp_client_add_dynamic_channel(settings, ARRAYSIZE(crb_rdpsnd_playback_args), crb_rdpsnd_playback_args)) failedStep = 3; ",
            "else if (!crb_rdpsnd_entry_is_playback(freerdp_static_channel_collection_find(settings, RDPSND_CHANNEL_NAME)) || ",
            "!crb_rdpsnd_entry_is_playback(freerdp_dynamic_channel_collection_find(settings, RDPSND_CHANNEL_NAME))) failedStep = 4; ",
            "else if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, TRUE)) failedStep = 5; ",
            "if (failedStep == 0) { WLog_INFO(TAG, \"[audio] playback mode=on\"); return TRUE; } ",
            "if (!crb_remove_rdpsnd_entries(settings) || !freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE)) { ",
            "WLog_ERR(TAG, ",
        ].joined()
        let linked = try #require(step.range(of: onSequence), "the On sequence")
        let fallbackEnd: String = [
            "failedStep); return FALSE; } ",
            "WLog_WARN(TAG, \"[audio] playback mode=on failed at step %d -- this connection plays no sound\", failedStep); ",
            "return TRUE; }",
        ].joined()
        #expect(step[linked.upperBound...].hasSuffix(fallbackEnd), "the fallback's end")
        // Neither add appears anywhere else in the step.
        #expect(audioOccurrences(of: "freerdp_client_add_", in: step) == 2)
        // The step's log lines carry numbers and fixed words only.
        for statement in step.components(separatedBy: "WLog_").dropFirst() {
            let call = statement.prefix { $0 != ";" }
            #expect(!call.contains("%s"), "a WLog in the audio step prints a string: \(call)")
        }
        // Gate r1 m-1: the entry check, whole -- the argument count, then a loop over EVERY argument
        // (its header is part of the text: `index + 1 < count` would let the last one through).
        let check = audioBridgeCode(try audioBody("static BOOL crb_rdpsnd_entry_is_playback(const ADDIN_ARGV *found)", in: raw))
        #expect(check.contains("for (size_t index = 0; index < count; index++) { "), "the loop header")
        let wholeCheck: String = [
            "static BOOL crb_rdpsnd_entry_is_playback(const ADDIN_ARGV *found) { ",
            "const size_t count = ARRAYSIZE(crb_rdpsnd_playback_args); ",
            "if (!found || !found->argv || found->argc < 0 || (size_t)found->argc != count) return FALSE; ",
            "for (size_t index = 0; index < count; index++) { ",
            "if (!found->argv[index] || strcmp(found->argv[index], crb_rdpsnd_playback_args[index]) != 0) return FALSE; } ",
            "return TRUE; }",
        ].joined()
        #expect(check == wholeCheck, "\(check)")
        let removal = audioBridgeCode(try audioBody("static BOOL crb_remove_rdpsnd_entries(rdpSettings *settings)", in: raw))
        #expect(removal.hasSuffix("return !freerdp_static_channel_collection_find(settings, RDPSND_CHANNEL_NAME) && "
            + "!freerdp_dynamic_channel_collection_find(settings, RDPSND_CHANNEL_NAME); }"))
        let lookup = audioBridgeCode(try audioBody("static BOOL crb_rdpsnd_backend_linked(const char *subsystem, BOOL dynamic)", in: raw))
        #expect(lookup.contains("dynamic ? FREERDP_ADDIN_CHANNEL_DYNAMIC : (FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX)"),
                "the flags rdpsnd_load_device_plugin uses for each instance")
        #expect(lookup.contains("freerdp_channels_load_static_addin_entry(RDPSND_CHANNEL_NAME, subsystem, NULL, flags) != NULL"))
    }

    /// Gate r1 I-1: the read in `crb_pre_connect` is the ONLY place the bridge names the property,
    /// in any spelling -- the getter, the ObjC message `setAudioPlaybackMode:` (which a
    /// case-sensitive `audioPlaybackMode` substring does not contain), the synthesized ivar, a KVC
    /// key. A write anywhere in the bridge -- in `-start`, or in the pre-connect step right before
    /// the read -- would turn every harness's Unmanaged and the App's Off into something else.
    @Test("the pre-connect step reads the mode once and calls the step once, before the frozen subscription block; nothing else in the bridge names the property")
    func theCallSiteIsBeforeTheSubscriptions() throws {
        let raw = try audioSource(Self.bridge)
        let code = audioBridgeCode(raw)
        let preConnect = audioBridgeCode(try audioBody("static BOOL crb_pre_connect(freerdp *instance)", in: raw))
        #expect(audioOccurrences(of: Self.call, in: preConnect) == 1)
        #expect(audioOccurrences(of: "crb_apply_audio_playback_mode(", in: code) == 3, "definition, the pre-connect call, the probe")
        let call = try #require(preConnect.range(of: Self.call))
        let subscribe = try #require(preConnect.range(of: "if (PubSub_SubscribeChannelConnected("))
        #expect(call.upperBound <= subscribe.lowerBound, "the audio step runs before the subscriptions")
        // Nothing but the blank between the step and the subscriptions, which stay the function's tail.
        #expect(preConnect.contains(Self.call + " if (PubSub_SubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected) < 0)"))
        let probe = audioBridgeCode(try audioBody(Self.probeSignature, in: raw))
        #expect(audioOccurrences(of: "crb_apply_audio_playback_mode(settings, mode)", in: probe) == 1)

        // The property's every spelling, in the bridge's code without its comments.
        let bare = audioPlaybackCodeWithoutComments(raw)
        #expect(audioPlaybackModePropertyMentions(in: bare) == 1, "the one read in crb_pre_connect, and no other spelling")
        #expect(audioOccurrences(of: "session.audioPlaybackMode", in: bare) == 1)
        #expect(audioOccurrences(of: "setAudioPlaybackMode", in: bare) == 0, "no message send to the setter")
        #expect(audioOccurrences(of: "_audioPlaybackMode", in: bare) == 0, "the synthesized ivar is never touched")
        // The header declares it once and the bridge's other files never name it.
        let header = audioPlaybackCodeWithoutComments(try audioSource("App/CRBridge/CRSession.h"))
        #expect(audioPlaybackModePropertyMentions(in: header) == 1, "the @property, and no setter or accessor declared beside it")
        let others = try audioPlaybackSourceFiles(under: "App/CRBridge").filter { !$0.hasPrefix("App/CRBridge/CRSession.") }
        #expect(!others.isEmpty)
        for file in others {
            #expect(!audioPlaybackModeIsNamed(in: try audioSource(file)), "\(file) names the mode")
        }
    }

    /// Gate r1 m-2: the backend probe answers with the very function the On step checks, nothing else.
    @Test("the two probes' bodies: the settings probe runs the step itself, the backend probe is the step's own lookup")
    func theProbesRunTheProductFunctions() throws {
        let raw = try audioSource(Self.bridge)
        let backend = audioBridgeCode(try audioBody(Self.backendProbeSignature, in: raw))
        #expect(backend == Self.backendProbeSignature + " { return crb_rdpsnd_backend_linked(subsystem.UTF8String, dynamic); }", "\(backend)")
        #expect(audioOccurrences(of: "crb_rdpsnd_backend_linked(", in: audioBridgeCode(raw)) == 4,
                "definition, On's static and dynamic checks, the backend probe")
        let probe = audioBridgeCode(try audioBody(Self.probeSignature, in: raw))
        #expect(audioOccurrences(of: "const BOOL applied = crb_apply_audio_playback_mode(settings, mode);", in: probe) == 1)
    }

    @Test("outside the step and the two probe bodies, the bridge names none of the three audio settings")
    func noOtherAudioSettingWriter() throws {
        let raw = try audioSource(Self.bridge)
        var rest = raw
        for signature in [Self.stepSignature, Self.probeSignature, Self.probeInitSignature] {
            let body = try audioBody(signature, in: rest)
            rest = rest.replacingOccurrences(of: body, with: "")
        }
        let code = audioBridgeCode(rest)
        for key in ["FreeRDP_AudioPlayback", "FreeRDP_AudioCapture", "FreeRDP_RemoteConsoleAudio", "FreeRDP_DeviceRedirection"] {
            #expect(audioOccurrences(of: key, in: code) == 0, "\(key) outside the audio step")
        }
    }

    /// Gate r1 I-1: `Tools/` must not name the mode in ANY spelling or case (the ObjC++ harnesses
    /// would set it by message send), and the walk skips SwiftPM's `.build/` as well as `build/`.
    @Test("the App never calls the two test probes, and no harness under Tools/ names the mode in any spelling")
    func probesAndHarnesses() throws {
        var productFiles = 0
        for directory in ["App/Macdows", "App/UI", "App/SessionControl", "App/Security", "App/RemoteWindowRendering", "Tools"] {
            for file in try audioPlaybackSourceFiles(under: directory) {
                productFiles += 1
                let text = try audioSource(file)
                for needle in ["audioPlaybackSettingsProbe", "rdpsndPlaybackBackendIsLinked", "CRAudioPlaybackProbeSetup"] {
                    #expect(!text.contains(needle), "\(file) names \(needle)")
                }
                if directory == "Tools" {
                    #expect(!audioPlaybackModeIsNamed(in: text), "\(file): a harness names the audio mode")
                }
            }
        }
        #expect(productFiles > 50, "the walk found the sources")
        let tools = try audioPlaybackSourceFiles(under: "Tools")
        #expect(tools.filter { $0.hasSuffix(".mm") }.count >= 2, "the ObjC++ harnesses are walked: \(tools.filter { $0.hasSuffix(".mm") })")
        #expect(tools.allSatisfy { !audioPlaybackWalkSkips($0) })
    }

    /// Gate r1 I-1, the equivalence the walks rest on: the checks above and in
    /// `AudioPlaybackPreferencesTests` see the spellings a harness under `Tools/` (ObjC++), the
    /// bridge or the App's Swift could use, shown on fixture strings rather than on `Tools/` itself.
    @Test("the name checks catch every spelling: ObjC++ message sends, the ivar, KVC, selectors, Swift without spaces")
    func theNameChecksSeeEverySpelling() {
        let writes = [
            // ObjC / ObjC++ -- what Tools/bridge-smoke or Tools/window-smoke would write
            "[session setAudioPlaybackMode:CRAudioPlaybackModeOn];",
            "[session setAudioPlaybackMode:2];",
            "session.audioPlaybackMode = CRAudioPlaybackModeOn;",
            "session.audioPlaybackMode=(CRAudioPlaybackMode)2;",
            "self->_audioPlaybackMode = CRAudioPlaybackModeOn;",
            "[session setValue:@2 forKey:@\"audioPlaybackMode\"];",
            "[session performSelector:@selector(setAudioPlaybackMode:) withObject:nil];",
            // Swift -- what the App could write (`x=.on` does not compile: an operator with no space
            // on its left and a dot on its right is read as postfix, so the no-space write names the type)
            "newSession.audioPlaybackMode=CRAudioPlaybackMode.on",
            "newSession.setValue(2, forKey: \"audioPlaybackMode\")",
            "newSession.perform(NSSelectorFromString(\"setAudioPlaybackMode:\"), with: nil)",
        ]
        for line in writes {
            #expect(audioPlaybackModeIsNamed(in: line), "Tools rule: \(line)")
            #expect(audioPlaybackModePropertyMentions(in: line) == 1, "bridge / App rule: \(line)")
            #expect(audioPlaybackModePropertyMentions(in: audioPlaybackCodeWithoutComments(line)) == 1, "still there without comments: \(line)")
        }
        // The hole this closes: the old case-sensitive needles missed the setter.
        #expect(!"[session setAudioPlaybackMode:2];".contains("audioPlaybackMode"))
        #expect(!"[session setAudioPlaybackMode:2];".contains("CRAudioPlaybackMode"))
        // Not counted by the property rule: the type and its constants; the step's own name.
        #expect(audioPlaybackModePropertyMentions(in: "static BOOL f(CRAudioPlaybackMode mode) { return mode == CRAudioPlaybackModeOn; }") == 0)
        #expect(audioPlaybackModePropertyMentions(in: "crb_apply_audio_playback_mode(settings, mode)") == 0)
        #expect(!audioPlaybackModeIsNamed(in: "[session setDesktopWidth:1920];"))
        // Comments do not count; a `//` inside a string is not a comment.
        #expect(audioPlaybackModePropertyMentions(in: audioPlaybackCodeWithoutComments("/* session.audioPlaybackMode */ x = 1; // setAudioPlaybackMode:")) == 0)
        #expect(audioPlaybackCodeWithoutComments("let u = \"https://example.invalid\"; y = 2 // note") == "let u = \"https://example.invalid\"; y = 2 ")
        #expect(audioPlaybackModePropertyMentions(in: audioPlaybackCodeWithoutComments("f(\"a//b\"); [s setAudioPlaybackMode:1];")) == 1)
        // The walk's exclusions.
        #expect(audioPlaybackWalkSkips("Tools/replay-diff/.build/arm64-apple-macosx/debug/MacdowsCore.build/MacdowsCore-Swift.h"))
        #expect(audioPlaybackWalkSkips("App/build/Build/Products/Debug/Macdows.app/Contents/Info.h"))
        #expect(audioPlaybackWalkSkips("App/Macdows.xcodeproj/project.pbxproj"))
        #expect(!audioPlaybackWalkSkips("Tools/bridge-smoke/main.mm"))
        #expect(!audioPlaybackWalkSkips("App/CRBridge/CRSession.mm"))
    }

    @Test("the header: the property, its enum with Unmanaged = 0, the probe options, and the two probes declared once each")
    func theHeader() throws {
        let header = audioFolded(try audioSource("App/CRBridge/CRSession.h"))
        #expect(audioOccurrences(of: "@property (nonatomic) CRAudioPlaybackMode audioPlaybackMode;", in: header) == 1)
        #expect(audioOccurrences(of: "CRAudioPlaybackModeUnmanaged = 0,", in: header) == 1)
        #expect(audioOccurrences(of: "CRAudioPlaybackProbeSetupSeedOneChannelRdpsnd = 1 << 3,", in: header) == 1)
        #expect(audioOccurrences(of: "CRAudioPlaybackProbeSetupReplayUpstreamLoad = 1 << 4,", in: header) == 1)
        #expect(audioOccurrences(of: "+ (nullable CRAudioPlaybackSettingsProbe *)audioPlaybackSettingsProbeForMode:", in: header) == 1)
        #expect(audioOccurrences(of: "+ (BOOL)rdpsndPlaybackBackendIsLinked:(NSString *)subsystem dynamic:(BOOL)dynamic", in: header) == 1)
    }
}
