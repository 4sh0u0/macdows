import Foundation
import Testing

// UI slice ④ gate r1 m-1: the shell's plural formats are filled in with the locale of the
// localization the bundle resolved, not the region's `Locale.current`. An en App running in a
// zh_CN region must still say "1 window" (the en `one` variant), and `UIStrings.hostCount`
// follows the same rule for `hosts3`.

private func formattingRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Line comments removed, whitespace folded (the stripping the other source pins use).
private func formattingCodeOnly(_ path: String) throws -> String {
    let text = try String(contentsOf: formattingRepoRoot().appendingPathComponent(path), encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// A throwaway bundle with only an en localization whose `s_live_bar` carries the en plural
/// variants, in the stringsdict form the String Catalog compiles to. The caller removes `root`
/// when it is done (UI-8 gate r2 m-2: the directory used to be left in the temporary directory).
private func englishOnlyBundle() throws -> (bundle: Bundle, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-locale-\(UUID().uuidString).bundle")
    let lproj = root.appendingPathComponent("en.lproj")
    try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
    let plural: [String: Any] = [
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
        "NSStringFormatValueTypeKey": "lld",
        "one": "Connected · %1$lld window · since %2$@",
        "other": "Connected · %1$lld windows · since %2$@",
    ]
    let table: [String: Any] = ["s_live_bar": ["NSStringLocalizedFormatKey": "%#@n@", "n": plural]]
    let data = try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
    try data.write(to: lproj.appendingPathComponent("Localizable.stringsdict"))
    return (try #require(Bundle(url: root)), root)
}

@Suite("Shell plural formats use the resolved localization's locale (UI slice ④, gate r1 m-1)")
struct ShellFormattingLocaleTests {
    @Test("en catalog in a zh_CN region: 1 window, not 1 windows")
    func englishCatalogInChineseRegion() throws {
        let (bundle, root) = try englishOnlyBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(bundle.preferredLocalizations.first == "en")
        let format = bundle.localizedString(forKey: "s_live_bar", value: "missing", table: nil)
        let arguments: [any CVarArg] = [Int64(1), "12:03"]
        let locale = ShellText.formattingLocale(preferredLocalizations: bundle.preferredLocalizations)
        #expect(String(format: format, locale: locale, arguments: arguments) == "Connected · 1 window · since 12:03")
        #expect(String(format: format, locale: locale, arguments: [Int64(2), "12:03"] as [any CVarArg]) == "Connected · 2 windows · since 12:03")
        // The defect this replaces: the region's locale picks the plural category.
        let region = Locale(identifier: "zh_CN")
        #expect(String(format: format, locale: region, arguments: arguments) == "Connected · 1 windows · since 12:03")
        #expect(ShellText.formattingLocale(preferredLocalizations: []).identifier == "en")
        #expect(ShellText.formattingLocale(preferredLocalizations: ["ja", "en"]).identifier == "ja")
    }

    @Test("ShellText.main and UIStrings.hostCount format with formattingLocale, never the region")
    func callShapes() throws {
        let presenter = try formattingCodeOnly("App/SessionControl/ShellReconnectPresenter.swift")
        let strings = try formattingCodeOnly("App/UI/UIStrings.swift")
        let shared = "formattingLocale(preferredLocalizations: Bundle.main.preferredLocalizations)"
        #expect(presenter.contains("String(format: format, locale: \(shared), arguments: arguments)"))
        #expect(strings.contains("locale: ShellText.\(shared), Int32(clamping: count))"))
        for code in [presenter, strings] {
            #expect(!code.contains("Locale.current"))
            #expect(!code.contains("localizedStringWithFormat"))
        }
    }
}
