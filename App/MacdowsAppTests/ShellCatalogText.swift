import Foundation
import Testing

// UI slice ④: the String Catalog, read straight from `App/Macdows/Localizable.xcstrings`, as a
// `ShellText` for one language. The test bundle does not carry the App's compiled catalog (its
// `Bundle.main` is the test runner), so this is how `ShellReconnectPresenter` is checked in all
// three languages: the same keys, the same positional arguments, the en plural variants resolved
// the way the compiled stringsdict resolves them (`one` for 1, `other` otherwise -- the only two
// en categories). A runtime probe against the built App's compiled catalog is part of the lane's
// local verification; this file keeps the offline half.

func shellCatalogRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// The catalog's `strings` table.
func shellCatalogStrings() throws -> [String: Any] {
    let data = try Data(contentsOf: shellCatalogRepoRoot().appendingPathComponent("App/Macdows/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(catalog["strings"] as? [String: Any])
}

/// The value of `key` in `language`: the string unit, or for a plural entry the variant `count`
/// selects. `nil` when the catalog has no such value.
func shellCatalogValue(_ strings: [String: Any], _ key: String, _ language: String, count: Int64? = nil) -> String? {
    let entry = strings[key] as? [String: Any]
    let localization = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
    if let unit = localization?["stringUnit"] as? [String: Any] {
        return unit["value"] as? String
    }
    guard let plural = (localization?["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return nil }
    let category = count == 1 ? "one" : "other"
    let variant = (plural[category] ?? plural["other"]) as? [String: Any]
    return (variant?["stringUnit"] as? [String: Any])?["value"] as? String
}

extension ShellText {
    /// One language of the catalog file, with a fixed clock time for "since 12:03". A key the
    /// catalog lacks renders as `<missing:key>`, so a test comparing against the UI-1 table goes
    /// red instead of silently reading the code's English fallback.
    static func catalog(_ language: String, time: String = "12:03") throws -> ShellText {
        let strings = try shellCatalogStrings()
        return ShellText(
            resolve: { key, _, arguments in
                let count = arguments.first as? Int64
                guard let format = shellCatalogValue(strings, key, language, count: count) else { return "<missing:\(key)>" }
                return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: arguments)
            },
            time: { _ in time }
        )
    }
}
