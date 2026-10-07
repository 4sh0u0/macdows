import Foundation
import Testing

// UI-11 (UI-8 gate m-8, ruling R-4): adr/0015 §5.A.3's display-change note in three languages.
// The four sentences `AppDelegate`'s screen-parameter closure writes to the status line used to be
// English literals in that closure; they are now the catalog keys `dn_none` / `dn_nosess` /
// `dn_stale` / `dn_ok`, resolved by `UIStrings`. The behaviour is unchanged (a display change sets
// one string, nothing else) and is pinned elsewhere; this suite pins the wording's move only:
// the catalog has the four keys in en / zh-Hans / ja, the code's English fallback is the old
// sentence word for word, and `AppDelegate` no longer carries the English literals.

private func displayNoteSource(_ relative: String) throws -> String {
    try String(contentsOf: shellCatalogRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Line comments removed, whitespace folded (the stripping `MainMenuTests` uses).
private func displayNoteCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func displayNoteOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@MainActor
@Suite("UI-11 — adr/0015 §5.A.3's display-change note, in three languages")
struct DisplayChangeNoteCatalogTests {

    /// The four sentences as they were in `AppDelegate` before UI-11, in the closure's order.
    private static let english: [(key: String, text: String)] = [
        ("dn_none", "Display change: no usable display right now."),
        ("dn_nosess", "Display change: no session yet -- the desktop size is taken at connect."),
        ("dn_stale", "Display change: this session's desktop size is now out of date -- reconnect to re-negotiate."),
        ("dn_ok", "Display change: this session's desktop size is unaffected."),
    ]

    @Test("the four keys are in the catalog, non-empty and distinct in en, zh-Hans and ja, en word for word")
    func theCatalogHasTheFourKeys() throws {
        let strings = try shellCatalogStrings()
        for language in ["en", "zh-Hans", "ja"] {
            var seen: Set<String> = []
            for (key, text) in Self.english {
                let value = try #require(shellCatalogValue(strings, key, language), "\(key) \(language)")
                #expect(!value.isEmpty, "\(key) \(language)")
                #expect(seen.insert(value).inserted, "\(key) \(language) repeats another note")
                if language == "en" {
                    #expect(value == text, "\(key) en")
                } else {
                    #expect(value != text, "\(key) \(language) is the English sentence")
                    // Translated, not English: no ASCII letter at all (ASCII punctuation is allowed;
                    // none of the four sentences carries a product name or a token).
                    #expect(!value.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) },
                            "\(key) \(language) still contains English: \(value)")
                }
            }
        }
    }

    /// In the test bundle `Bundle.main` is the test runner, so `String(localized:defaultValue:)`
    /// returns the default value -- the code's English fallback.
    @Test("UIStrings' four resolution points fall back to the old English sentences")
    func theResolutionPointsFallBackToTheOldSentences() {
        let resolved = [UIStrings.displayNoteNoDisplay, UIStrings.displayNoteNoSession,
                        UIStrings.displayNoteStale, UIStrings.displayNoteUnaffected]
        #expect(resolved == Self.english.map(\.text))
    }

    @Test("AppDelegate writes the note through UIStrings, four times, with no English literal left")
    func appDelegateHasNoEnglishLiteral() throws {
        let code = displayNoteCodeOnly(try displayNoteSource("App/Macdows/AppDelegate.swift"))
        for (key, text) in Self.english {
            #expect(displayNoteOccurrences(of: text, in: code) == 0, "\(key) literal")
        }
        #expect(displayNoteOccurrences(of: "Display change:", in: code) == 0)
        #expect(displayNoteOccurrences(of: "UIStrings.displayNote", in: code) == 4)
        for name in ["displayNoteNoDisplay", "displayNoteNoSession", "displayNoteStale", "displayNoteUnaffected"] {
            #expect(displayNoteOccurrences(of: "note = UIStrings.\(name)", in: code) == 1, "\(name)")
        }
    }

    @Test("each key has exactly one resolution point, in UIStrings")
    func eachKeyIsResolvedOnceInUIStrings() throws {
        let code = displayNoteCodeOnly(try displayNoteSource("App/UI/UIStrings.swift"))
        for (key, text) in Self.english {
            #expect(displayNoteOccurrences(of: "String(localized: \"\(key)\", defaultValue: \"\(text)\"", in: code) == 1, "\(key)")
        }
    }
}
