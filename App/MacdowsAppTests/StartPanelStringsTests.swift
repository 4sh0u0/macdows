import Foundation
import MacdowsCore
import Testing

// ADR-0025 §3.1 items 6 and 10, §5.1 as amended by owner ruling ㋯: the start panel's 25 `sp_*`
// keys in three languages, the reason-key mapping, and no English literal in the sources that
// show them (the `DisplayChangeNoteCatalogTests` shape). The whole-catalog pin
// (`MainMenuTests.stringCatalogCoversEveryTitle`) also covers these keys: resolved, translated,
// no orphan.

private func startPanelSource(_ relative: String) throws -> String {
    try String(contentsOf: shellCatalogRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded.
private func startPanelCodeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex..<marker.lowerBound]
        }
        .joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

@MainActor
@Suite("ADR-0025 — the start panel's strings, in three languages")
struct StartPanelStringsTests {

    /// The 25 keys and the English each must read (design note §4, plus the two ruling ㋯ keys).
    static let english: [(key: String, text: String)] = [
        ("sp_title", "Start panel"), ("sp_pinned", "Pinned"), ("sp_recent", "Recent"), ("sp_run", "Run…"),
        ("sp_run_ph", "Program path or name"), ("sp_pin", "Pin"), ("sp_unpin", "Unpin"), ("sp_forget", "Remove from Recent"),
        ("sp_empty", "Programs you run appear here."), ("sp_wait", "Reconnecting. You can launch programs once connected."),
        ("sp_last_fail", "The last launch did not succeed: %@"),
        ("sp_r_hook", "Windows is not ready to start programs yet. Try again in a moment."),
        ("sp_r_decode", "Windows could not read the program name."), ("sp_r_allow", "This program is not allowed on the remote PC."),
        ("sp_r_nf", "The program was not found on the remote PC. Check the path."), ("sp_r_fail", "Windows could not start the program."),
        ("sp_r_locked", "The remote session is locked."), ("sp_r_unknown", "Windows returned an unknown result."),
        ("sp_r_timeout", "Windows did not reply. If the program doesn’t open, try again."), ("sp_r_long", "The path is too long."),
        ("sp_r_args_long", "The path and arguments are too long together."), ("sp_ax", "Precise Dock positioning"),
        ("sp_ax_d", "Uses Accessibility to find the Macdows icon in the Dock. Without access, the panel opens where you clicked. You can allow access in System Settings > Privacy & Security."),
        ("sp_ax_off", "Accessibility access isn’t allowed yet. Allow Macdows in Privacy & Security to open the panel at its Dock icon."),
        ("sp_ax_open", "Open Privacy & Security…"),
    ]

    @Test("exactly these 25 sp_ keys are in the catalog -- no sp_gaveup (§10-1 (b)) -- each translated in en, zh-Hans and ja")
    func catalogHasTheKeys() throws {
        let strings = try shellCatalogStrings()
        #expect(Self.english.count == 25)
        #expect(Set(strings.keys.filter { $0.hasPrefix("sp_") }) == Set(Self.english.map(\.key)))
        #expect(strings["sp_gaveup"] == nil)
        for (key, text) in Self.english {
            let en = try #require(shellCatalogValue(strings, key, "en"), "\(key)")
            #expect(en == text, "\(key) en")
            for language in ["zh-Hans", "ja"] {
                let value = try #require(shellCatalogValue(strings, key, language), "\(key) \(language)")
                #expect(!value.isEmpty && value != en, "\(key) \(language) is untranslated")
                #expect(value.components(separatedBy: "%@").count == en.components(separatedBy: "%@").count, "\(key) \(language) placeholder")
                if language == "zh-Hans" {
                    #expect(!value.contains("—") && !value.contains("――"), "\(key): zh uses no full-width dash")
                }
            }
            #expect(!en.contains("'"), "\(key): en uses ’")
        }
    }

    @Test("the two new keys: a fact and a next step, at most two sentences, no 'AX', ja split with 。")
    func theTwoNewKeys() throws {
        let strings = try shellCatalogStrings()
        for language in ["en", "zh-Hans", "ja"] {
            let off = try #require(shellCatalogValue(strings, "sp_ax_off", language))
            let open = try #require(shellCatalogValue(strings, "sp_ax_open", language))
            for value in [off, open] {
                #expect(!value.split(whereSeparator: { !$0.isLetter }).contains("AX"), "\(language): no AX term")
            }
            let enders: Set<Character> = language == "en" ? ["."] : ["。"]
            #expect(off.filter { enders.contains($0) }.count == 2, "\(language) sp_ax_off: two sentences")
            #expect(open.hasSuffix("…"), "\(language) sp_ax_open opens a window")
        }
        #expect(try #require(shellCatalogValue(strings, "sp_ax_off", "zh-Hans")).contains("“隐私与安全性”"))
        #expect(try #require(shellCatalogValue(strings, "sp_ax_off", "ja")).contains("「プライバシーとセキュリティ」"))
    }

    /// F-a1-1 (owner ruling (a)): macOS 27.2 renamed the list (it is no longer "Accessibility" in
    /// System Settings), so the description names only System Settings > Privacy & Security; the rest of
    /// each sentence is unchanged.
    @Test("F-a1-1: sp_ax_d points at System Settings > Privacy & Security and names no list below it, in three languages")
    func axDescriptionStopsAtPrivacyAndSecurity() throws {
        let strings = try shellCatalogStrings()
        let en = try #require(shellCatalogValue(strings, "sp_ax_d", "en"))
        let zh = try #require(shellCatalogValue(strings, "sp_ax_d", "zh-Hans"))
        let ja = try #require(shellCatalogValue(strings, "sp_ax_d", "ja"))
        #expect(en.hasSuffix("You can allow access in System Settings > Privacy & Security."))
        #expect(zh.hasSuffix("可在“系统设置 > 隐私与安全性”中授权。"))
        #expect(ja.hasSuffix("「システム設定 > プライバシーとセキュリティ」で許可できます。"))
        for value in [en, zh, ja] {
            #expect(value.components(separatedBy: " > ").count == 2, "one step: \(value)")
        }
        #expect(UIStrings.startPanelPreciseNote == en, "the source's default value matches the catalog")
    }

    @Test("every reason key the launcher and the result codes produce has its own sentence; only unknowns fall back")
    func reasonKeysResolve() {
        let unknown = UIStrings.startPanelUnknownResult
        var keys = ExecResultCode.allCases.compactMap(\.reasonKey)
        keys += RunCommandRejection.allCases.compactMap(AppLauncher.reasonKey(for:))
        keys.append(AppLauncher.timeoutReasonKey)
        for key in Set(keys) {
            let sentence = UIStrings.startPanelReason(forKey: key)
            let english = Self.english.first { $0.key == key }?.text
            #expect(sentence == english, "\(key)")
            #expect(key == "sp_r_unknown" || sentence != unknown, "\(key) fell back to the unknown sentence")
        }
        #expect(UIStrings.startPanelReason(forKey: "not_a_key") == unknown)
        #expect(UIStrings.startPanelLastFailure(UIStrings.startPanelTimedOut)
                == "The last launch did not succeed: Windows did not reply. If the program doesn’t open, try again.")
    }

    @Test("the English is resolved through UIStrings only: no sp_ English literal in the panel, launcher, menus, Settings or the App delegate")
    func noEnglishLiterals() throws {
        var files = ["App/Macdows/AppDelegate.swift", "App/Macdows/StatusMenu/StatusItemController.swift",
                     "App/SessionControl/AppLauncher.swift", "App/UI/Settings/SettingsPages.swift"]
        let folder = shellCatalogRepoRoot().appendingPathComponent("App/UI/StartPanel")
        files += try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.map { "App/UI/StartPanel/\($0)" }
        #expect(files.count >= 11)
        for file in files {
            let code = startPanelCodeOnly(try startPanelSource(file))
            for (key, text) in Self.english {
                #expect(!code.contains("\"\(text)\""), "\(file) spells \(key)'s English")
            }
            // Key NAMES may appear (the launcher maps refusals to them); RESOLVING one is UIStrings' job.
            #expect(!code.contains("localized: \"sp_") && !code.contains("forKey: \"sp_"), "\(file) resolves an sp_ key itself")
        }
        let strings = try startPanelSource("App/UI/UIStrings.swift")
        for (key, _) in Self.english {
            let shapes = strings.components(separatedBy: "\"\(key)\"").count - 1
            #expect(shapes == 1 || (key.hasPrefix("sp_r_") && shapes == 2), "\(key) resolved once in UIStrings (\(shapes))")
        }
    }
}
