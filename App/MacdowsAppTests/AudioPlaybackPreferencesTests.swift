import Foundation
import Testing

// adr/0026 (proposed) lane L1: the App half of basic audio playback -- the one global preference
// (on by default, owner rulings D3 = A, D4 = A of 2026-11-17), its checkbox on the General page,
// the mapping to `CRAudioPlaybackMode` and the two places `AppDelegate` hands it to a session: at
// every session start and, since the gate r1 fold (m-5 (a)), in the reconnect hook before every
// automatic reconnect. The preference runs on a defaults suite of its own; `.shared` is only READ
// here (no test writes the standard defaults). `AppDelegate` is not in this bundle, so its two
// lines are pinned as source and the mapping they call is driven here. The checkbox itself is
// pinned as source only, like the start panel's beside it: SwiftUI draws a `Toggle(.checkbox)`
// without an `NSButton` on this SDK, and offline its accessibility tree holds no check box to find
// (both were tried when this lane was written).

private func prefsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func prefsSource(_ relative: String) throws -> String {
    try String(contentsOf: prefsRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// `//` comments removed line by line, whitespace folded.
private func prefsCode(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.components(separatedBy: "//").first ?? "" }
        .joined(separator: " ")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// `/* ... */` comments removed, whitespace folded (the bridge's style).
private func prefsBridgeCode(_ text: String) -> String {
    audioPlaybackCodeWithoutComments(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func prefsOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private let prefsAssignment = "newSession.audioPlaybackMode = AudioPlaybackPreferences.shared.sessionMode"

@MainActor
@Suite("adr/0026 L1 — AudioPlaybackPreferences: one key, on by default, read at every session start and before every reconnect", .serialized)
struct AudioPlaybackPreferencesTests {
    /// A fresh, empty suite and a cleanup for it.
    private static func suite() -> (UserDefaults, String) {
        let name = "macdows.tests.audio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test("one key; a domain without it -- every install from before this preference -- reads ON")
    func defaultIsOnWhenTheKeyIsMissing() {
        let (defaults, name) = Self.suite()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AudioPlaybackPreferences.playOnThisMacKey == "audioPlayback.playOnThisMac")
        #expect(AudioPlaybackPreferences.playOnThisMacDefault)
        #expect(defaults.object(forKey: AudioPlaybackPreferences.playOnThisMacKey) == nil)
        let preferences = AudioPlaybackPreferences(defaults: defaults)
        #expect(preferences.playOnThisMac)
        #expect(preferences.sessionMode == .on)
        #expect(defaults.object(forKey: AudioPlaybackPreferences.playOnThisMacKey) == nil, "reading writes nothing")
        // Unrelated keys do not count as the preference.
        defaults.set(false, forKey: "startPanel.preciseDockPositioning")
        #expect(AudioPlaybackPreferences.storedValue(in: defaults))
    }

    @Test("the checkbox writes the key; a new instance on the same domain reads it back, both ways")
    func writeAndReadBack() {
        let (defaults, name) = Self.suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AudioPlaybackPreferences(defaults: defaults)
        preferences.setPlayOnThisMac(false)
        #expect(!preferences.playOnThisMac && preferences.sessionMode == .off)
        #expect(defaults.object(forKey: AudioPlaybackPreferences.playOnThisMacKey) as? Bool == false)
        #expect(!AudioPlaybackPreferences(defaults: defaults).playOnThisMac, "OFF survives a relaunch")
        preferences.setPlayOnThisMac(true)
        #expect(preferences.playOnThisMac && preferences.sessionMode == .on)
        #expect(defaults.object(forKey: AudioPlaybackPreferences.playOnThisMacKey) as? Bool == true)
        #expect(AudioPlaybackPreferences(defaults: defaults).playOnThisMac, "ON survives a relaunch")
    }

    @Test("a stored value is read the way UserDefaults reads a Boolean")
    func storedValues() {
        let (defaults, name) = Self.suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let key = AudioPlaybackPreferences.playOnThisMacKey
        defaults.set(false, forKey: key)
        #expect(!AudioPlaybackPreferences.storedValue(in: defaults))
        defaults.set(true, forKey: key)
        #expect(AudioPlaybackPreferences.storedValue(in: defaults))
        defaults.set("NO", forKey: key)
        #expect(!AudioPlaybackPreferences.storedValue(in: defaults), "a string written by `defaults write` counts as UserDefaults says")
        defaults.removeObject(forKey: key)
        #expect(AudioPlaybackPreferences.storedValue(in: defaults), "removed again: back to the default")
    }

    @Test("the mapping AppDelegate uses: ON -> .on, OFF -> .off, never .unmanaged")
    func mapping() {
        #expect(AudioPlaybackPreferences.sessionMode(playOnThisMac: true) == .on)
        #expect(AudioPlaybackPreferences.sessionMode(playOnThisMac: false) == .off)
        for value in [true, false] {
            #expect(AudioPlaybackPreferences.sessionMode(playOnThisMac: value) != .unmanaged)
        }
    }

    /// Gate r1 m-3: `.shared` is the object `AppDelegate` and the Settings window both use, and the
    /// fixtures above never touch it. Read-only: the standard defaults are read, never written.
    @Test("`.shared` holds what the standard defaults hold, is built by the one initializer, and is what the Settings window gets")
    func sharedIsTheStandardDefaults() throws {
        let stored = AudioPlaybackPreferences.storedValue(in: .standard)
        #expect(AudioPlaybackPreferences.shared.playOnThisMac == stored, "`.shared` reads the standard defaults as they are")
        #expect(AudioPlaybackPreferences.shared.sessionMode == AudioPlaybackPreferences.sessionMode(playOnThisMac: stored))
        #expect(AudioPlaybackPreferences.shared === AudioPlaybackPreferences.shared)
        let type = prefsCode(try prefsSource("App/UI/Audio/AudioPlaybackPreferences.swift"))
        #expect(prefsOccurrences(of: "static let shared = AudioPlaybackPreferences()", in: type) == 1)
        #expect(prefsOccurrences(of: "static let shared", in: type) == 1)
        #expect(prefsOccurrences(of: "init(defaults: UserDefaults = .standard) { self.defaults = defaults playOnThisMac = Self.storedValue(in: defaults) }", in: type) == 1)
        #expect(prefsOccurrences(of: "init(", in: type) == 1, "one initializer")
        // The Settings window is built once in the product, and is given no preference object of its
        // own: its `audioPlayback:` parameter keeps its `.shared` default.
        var constructions: [String: Int] = [:]
        for file in try audioPlaybackSourceFiles(under: "App") where file.hasSuffix(".swift") && !file.hasPrefix("App/MacdowsAppTests/") {
            let count = prefsOccurrences(of: "SettingsWindowController(", in: prefsCode(try prefsSource(file)))
            if count > 0 { constructions[file] = count }
        }
        #expect(constructions == ["App/UI/Main/MainWindowController.swift": 1])
        let main = prefsCode(try prefsSource("App/UI/Main/MainWindowController.swift"))
        #expect(main.contains("private(set) lazy var settings = SettingsWindowController(actions: actions, store: store)"))
    }

    /// Gate r1 m-5 (a): the reconnect hook writes the mode too, so "Applies at the next connection."
    /// holds for a reconnect as it does for the display values the same hook re-takes.
    @Test("AppDelegate hands the preference to the session in exactly two places: at the session start and in the reconnect hook, both before a -start")
    func appDelegateAssignsTheModeBeforeStart() throws {
        let code = prefsCode(try prefsSource("App/Macdows/AppDelegate.swift"))
        #expect(prefsOccurrences(of: prefsAssignment, in: code) == 2, "the session start and the reconnect hook")
        // 1. beginSession: right after the display-change note is cleared, before the session is kept.
        let atStart = "lastDisplayChangeNote = nil " + prefsAssignment + " session = newSession"
        #expect(prefsOccurrences(of: atStart, in: code) == 1)
        // 2. The reconnect hook: after its guard, before the re-take it returns.
        let hook = "driver.topologyRefresh = { [weak self, unowned newSession] in guard let self else { return nil } "
            + prefsAssignment + " return ReconnectTopologyRefresh.refreeze(session: newSession, topology: self.displayTopology) }"
        #expect(prefsOccurrences(of: hook, in: code) == 1)
        let begin = try #require(code.range(of: "private func beginSession("))
        let first = try #require(code.range(of: atStart))
        let driver = try #require(code.range(of: "let driver = ReconnectDriver("))
        let second = try #require(code.range(of: hook))
        let start = try #require(code.range(of: "newSession.start()"))
        #expect(begin.upperBound <= first.lowerBound && first.upperBound <= driver.lowerBound, "inside beginSession, before the driver")
        #expect(driver.upperBound <= second.lowerBound && second.upperBound <= start.lowerBound, "the driver's hook, armed before -start")
    }

    /// Gate r1 m-5 (a), the path: the hook above is the `prepare` of the driver's one reconnect step,
    /// which the registry calls before it tears its table down, and the bridge runs `prepare`
    /// between the shutdown and the `-start` whose pre-connect step reads the mode
    /// (`AudioPlaybackBridgePinTests` pins that read).
    @Test("the reconnect path re-reads the preference: driver -> registry -> hook, inside restartForReconnect, before its -start")
    func theReconnectPathReadsThePreferenceAgain() throws {
        let driver = prefsCode(try prefsSource("App/SessionControl/ReconnectDriver.swift"))
        #expect(prefsOccurrences(of: "let restarted = session.restartForReconnect { "
            + "self.registry.prepareForReconnect(refreezingTopologyWith: { self.topologyRefresh?() ?? nil }) }", in: driver) == 1)
        #expect(prefsOccurrences(of: "restartForReconnect", in: driver) == 1, "one reconnect step")
        let registry = prefsCode(try prefsSource("App/RemoteWindowRendering/RemoteWindowRegistry.swift"))
        #expect(prefsOccurrences(of: "func prepareForReconnect( refreezingTopologyWith refreeze: () -> (any DisplayTopologyProviding)? ) -> Bool { "
            + "let replaced: Bool if let fresh = refreeze() {", in: registry) == 1, "the hook is called, first, every time")
        let bridge = prefsBridgeCode(try prefsSource("App/CRBridge/CRSession.mm"))
        let restart = try #require(bridge.range(of: "- (BOOL)restartForReconnectPreparing:(NS_NOESCAPE void (^)(void))prepare {"))
        let tail = try #require(bridge[restart.upperBound...].range(of: "if (prepare) prepare(); [self start]; return clean && _state == CRSessionStateConnected; }"))
        #expect(!bridge[restart.upperBound..<tail.lowerBound].contains("- ("), "the same method")
    }

    /// Gate r1 I-1: the property, in any spelling and any case (`audioPlaybackModePropertyMentions`:
    /// the getter, `=` without spaces, `setValue(_:forKey:)`, a selector string, the ObjC setter), is
    /// named in the App's sources -- every directory under `App/` but the tests and the bridge, which
    /// `AudioPlaybackBridgePinTests` holds -- only by those two assignments.
    @Test("nothing else in the App names the session's audio mode, in any spelling")
    func theOnlyWriters() throws {
        var mentions: [String: Int] = [:]
        var walked = 0
        for file in try audioPlaybackSourceFiles(under: "App")
        where !file.hasPrefix("App/MacdowsAppTests/") && !file.hasPrefix("App/CRBridge/") {
            walked += 1
            let count = audioPlaybackModePropertyMentions(in: audioPlaybackCodeWithoutComments(try prefsSource(file)))
            if count != 0 { mentions[file] = count }
        }
        #expect(walked > 50, "the walk found the sources")
        #expect(mentions == ["App/Macdows/AppDelegate.swift": 2], "\(mentions)")
    }

    @Test("the General page renders the preference's own checkbox and note, handing the value back to it")
    func thePageRendersThePreference() throws {
        let pages = prefsCode(try prefsSource("App/UI/Settings/SettingsPages.swift"))
        #expect(prefsOccurrences(of: "Toggle(isOn: Binding(get: { audioPlayback.playOnThisMac }, set: { audioPlayback.setPlayOnThisMac($0) })) "
                                 + "{ Text(verbatim: SettingsStrings.soundPlayOnThisMac) } .toggleStyle(.checkbox) "
                                 + "SettingsNote(text: SettingsStrings.soundNote)", in: pages) == 1)
        #expect(prefsOccurrences(of: "SettingsRow(SettingsStrings.sound)", in: pages) == 1)
        #expect(pages.contains("@ObservedObject var audioPlayback: AudioPlaybackPreferences"))
        let controller = prefsCode(try prefsSource("App/UI/Settings/SettingsWindowController.swift"))
        #expect(controller.contains("audioPlayback: AudioPlaybackPreferences = .shared"))
        #expect(controller.contains("SettingsGeneralPage(startPanel: startPanel, audioPlayback: audioPlayback)"))
    }

    @Test("the three new strings: en is the default value, zh-Hans and ja are translated, and the en note says when it applies")
    func strings() throws {
        let data = try Data(contentsOf: prefsRepoRoot().appendingPathComponent("App/Macdows/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            return unit?["value"] as? String
        }
        let expected: [String: [String: String]] = [
            "g_sound": ["en": "Sound", "zh-Hans": "声音", "ja": "サウンド"],
            "g_sound_v": ["en": "Play remote audio on this Mac", "zh-Hans": "在这台 Mac 上播放远程音频", "ja": "この Mac でリモートの音声を再生する"],
            "g_sound_n": ["en": "Applies at the next connection.", "zh-Hans": "下次连接时生效。", "ja": "次回の接続から適用されます。"],
        ]
        for (key, languages) in expected {
            for (language, text) in languages {
                #expect(value(key, language) == text, "\(key) \(language)")
            }
        }
        // The note says the setting waits for the next connection, in the words the Display page uses
        // -- and, since the reconnect hook re-reads it, with the same meaning (a reconnect included).
        #expect(value("d_scale_n", "en")?.hasPrefix(try #require(value("g_sound_n", "en"))) == true)
        #expect(value("d_scale_n", "zh-Hans")?.hasPrefix(try #require(value("g_sound_n", "zh-Hans"))) == true)
        #expect(value("d_scale_n", "ja")?.hasPrefix(try #require(value("g_sound_n", "ja"))) == true)
    }
}
