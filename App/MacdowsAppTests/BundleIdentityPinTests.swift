import Foundation
import Testing

// Bundle identity pins: which bundle id the App carries per build configuration, where its
// version and build number come from, which constants the code uses in place of the bundle id.
//
// The design these pins hold:
//  - The Release configuration's bundle id is `es.4sh.macdows`; every other configuration
//    (the development build) gets `es.4sh.macdows.dev` from the target's `settings.base`. The
//    configuration set is exactly Debug and Release. The test bundle has its own id,
//    `es.4sh.macdows.dev.apptests`.
//  - The version and the build number have ONE source, `MARKETING_VERSION` and
//    `CURRENT_PROJECT_VERSION` in the App target's `settings.base`; `Macdows/Info.plist`
//    references them (and `$(PRODUCT_BUNDLE_IDENTIFIER)`) instead of carrying literals.
//  - The unified-log subsystem is a constant, `es.4sh.macdows`, for every logger of the App and
//    in both configurations (one `log show` predicate serves both). It is NOT derived from the
//    runtime bundle id.
//  - The keychain queue label is `es.4sh.macdows.keychain`. No target of this repository runs the
//    keychain-service or host-folder code without a bundle id; a process that did would use the
//    DEVELOPMENT id, never the Release one.
//
// Two layers, on purpose. P2 reads `project.yml` as text (a closed grammar, so the text means what
// it says). P7 reads what XcodeGen GENERATED from it (`project.pbxproj`, `Macdows.xcscheme`) and
// is the pin that sees the result however the YAML was spelled. This bundle runs only from a
// generated project, so P7 needs the project on disk: it fails (it does not skip) when the files
// are missing.
//
// What each pin guards, and the edits that must turn it red (MUST-RED):
//  P1 `oldPrefixIsGone`   the previous reverse-DNS prefix, spelled contiguously, occurs in no
//                         UTF-8 file of the closed list of roots (`identityScannedDirectories`,
//                         `identityScannedRootFiles`). MUST-RED: the prefix put back as plain text
//                         in any such file, in a comment too.
//  P2 `projectYmlIdentityShape`  `project.yml` read as text after dropping full-line comments:
//                         three `PRODUCT_BUNDLE_IDENTIFIER` lines at three structural places; the
//                         version settings once each in the App base; `INFOPLIST_FILE` once;
//                         `GENERATE_INFOPLIST_FILE` only in the test bundle; no `INFOPLIST_KEY_`,
//                         `info:`, `bundleIdPrefix` or `configFiles` route; no top-level
//                         `configs:` (a second `release`-type configuration, which archives and
//                         profiles would then use, would get the development id) and one
//                         `Release:` line; the `include:` section exactly the one gated overlay
//                         entry; no post-build or post-compile script key under the App target
//                         in any spelling XcodeGen accepts (case-insensitive, space before the
//                         colon allowed); and a closed syntax so the text means what it says:
//                         no backslash, `<<` or `!!` anywhere and no quoted key; no anchor or
//                         alias token (`&name`, `*name`) and no flow mapping (`{`) at a
//                         structural position (line start, after `: ` or after `- `), so shell
//                         text in a script block (`&&`, `2>&1`, `${VAR}`) is not affected.
//                         MUST-RED: each of those added or moved.
//  P3 `infoPlistReferencesBuildSettings`  the source Info.plist, parsed as a property list, maps
//                         the three keys to exactly the three `$(...)` references, and each key
//                         name occurs once in the raw text. MUST-RED: a literal, a duplicate key
//                         in any tag spelling, a dropped key.
//  P4 `subsystemsAreTheConstant`  every `subsystem` of the product code is the constant, 8 call
//                         sites outside the forwarder, whose whole `init` is pinned (so it cannot
//                         shadow or replace the value) and which holds the only other `Logger(`.
//                         MUST-RED: a subsystem derived from the bundle id or set to another
//                         literal, a ninth logger, an edited forwarder `init`.
//  P5 `queueLabelAndFallbacks`  the keychain queue label; the whole `service(suffix:)` function
//                         and the `defaultFileURL()` host-folder line by full shape; the three
//                         callers that must go through them; the word `bundleIdentifier` exactly
//                         twice in product code and `CFBundleIdentifier` never. MUST-RED: a
//                         fallback set to the Release id, a caller that bypasses the function, a
//                         read of the id spelled `bundleIdentifier` or by the plist key name
//                         `CFBundleIdentifier` beyond the two pinned.
//  P6 `testBundleHasItsOwnId`  at run time, the test bundle's `bundleIdentifier`.
//                         MUST-RED: the test target's id changed in `project.yml`.
//  P7 `generatedProjectIdentity`  the GENERATED project and scheme: configurations exactly Debug
//                         and Release; per configuration the App target's id, version source and
//                         plist file; the test bundle's id; no `baseConfigurationReference` and no
//                         `INFOPLIST_KEY_*` on the App target or the project; no identity keys at
//                         project level; Archive and Profile use Release. MUST-RED: whichever way
//                         the YAML is spelled, a generated difference in any of those.
//
// Inherent limits (registered, not fixed):
//  - Some counts act on a whole file or match substrings: `info:`, `Release:`, the three plist key
//    names (an XML comment that mentions one counts too), `Logger(` (any type name ending in it),
//    and the structure self-check anchored on the `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` line. A
//    legitimate new use elsewhere turns them red; it cannot turn them green.
//  - P5 does not cover CoreFoundation reads of the id (`CFBundleGetIdentifier` and the like).
//  - P1 matches a contiguous spelling only: the prefix written with an escape (`\u{2E}`) or kept in
//    an untracked binary property list is not seen. It skips non-UTF-8 files, symbolic links and
//    the generated or build directories named below, and `App/project-local.yml`.
//  - P4 and P5 read text with `//` comments cut per line: a `//` inside a string literal hides the
//    rest of that line, and a dead `#if` branch that keeps a pinned shape can hide a live
//    different one.
//  - The version values (`0.1.0`, `1`) are not pinned, only their shape and their single source.
//  - P7 asserts the named keys only, not the key set, so a project generated with the maintainer's
//    signing overlay (extra signing keys) should pass; that is inferred, not measured here. P7 sees
//    an overlay's effect only in a project generated with the overlay.
//  - The way XcodeGen matches configuration names was measured on the XcodeGen installed here;
//    another version could differ, and P7 is what would show it.
//  - CI builds Debug only; the Release id is read here from the generated project, not from a
//    Release build product.

// MARK: - Helpers

private func identityRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func identityRaw(_ relative: String) throws -> String {
    try String(contentsOf: identityRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func identityCount(_ needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Occurrences of `word` not touching another identifier character on either side.
private func identityWordCount(_ word: String, in text: String) -> Int {
    func isIdentifierCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    var count = 0
    var searchFrom = text.startIndex
    while let found = text.range(of: word, range: searchFrom..<text.endIndex) {
        let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
        let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
        if !(before.map(isIdentifierCharacter) ?? false) && !(after.map(isIdentifierCharacter) ?? false) { count += 1 }
        searchFrom = found.upperBound
    }
    return count
}

/// Line comments removed, whitespace folded (same stripper the other source pins use).
private func identityCode(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            guard let marker = line.range(of: "//") else { return line }
            return line[line.startIndex..<marker.lowerBound]
        }
        .joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Directories the walks never enter: any directory below a root whose name starts with `.`
/// (`.build`, `.swiftpm`, `.omc`, `.git`, ...) or with `build` (`build`, `build-tsan`,
/// `build-asan`, ...), `DerivedData`, and any `*.xcodeproj` (generated by XcodeGen, not tracked).
private func identitySkipsDirectory(_ name: String) -> Bool {
    name.hasPrefix(".") || name.hasPrefix("build") || name == "DerivedData" || name.hasSuffix(".xcodeproj")
}

/// Every regular file under `roots` (relative to the repository root), skipping the directories
/// above and symbolic links.
private func identityFiles(under roots: [String]) -> [URL] {
    var found: [URL] = []
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    for root in roots {
        let start = identityRoot().appendingPathComponent(root)
        guard let walker = FileManager.default.enumerator(at: start, includingPropertiesForKeys: keys) else { continue }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if identitySkipsDirectory(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true { found.append(url) }
        }
    }
    return found
}

/// Top-level directories P1 walks. Tracked top-level items not listed here: `ThirdParty/` (the
/// vendored FreeRDP submodule and third-party license texts, not this project's text).
/// Not "the repository root": a main checkout carries untracked private directories at its root.
private let identityScannedDirectories = ["App", "Packages", "Tools", "Scripts", ".github", "deps", "samples"]
private let identityScannedRootFiles = ["README.md", "LGPL_RELINK.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
                                        ".gitattributes", ".gitignore", ".gitmodules"]
/// An untracked maintainer file that can sit inside a walked root; never read by P1.
private let identitySkippedFiles: Set<String> = ["App/project-local.yml"]

/// One non-comment, non-blank line of `project.yml` with its indentation and its ancestor keys.
private struct YamlLine {
    let indent: Int
    let text: String
    let path: [String]
}

/// `project.yml` as lines with a structural path: full-line `#` comments and blank lines dropped,
/// the ancestors of a line being the nearest preceding lines with a smaller indent that end in `:`.
private func yamlLines(_ relative: String) throws -> [YamlLine] {
    var stack: [(indent: Int, key: String)] = []
    var lines: [YamlLine] = []
    for raw in try identityRaw(relative).split(separator: "\n", omittingEmptySubsequences: false) {
        let body = raw.drop(while: { $0 == " " })
        if body.isEmpty || body.hasPrefix("#") { continue }
        let indent = raw.count - body.count
        while let top = stack.last, top.indent >= indent { stack.removeLast() }
        let text = String(body)
        lines.append(YamlLine(indent: indent, text: text, path: stack.map(\.key)))
        if text.hasSuffix(":") { stack.append((indent, String(text.dropLast()))) }
    }
    return lines
}

private func yamlValue(_ line: YamlLine) -> String {
    guard let colon = line.text.range(of: ": ") else { return "" }
    var value = String(line.text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
    if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first {
        value = String(value.dropFirst().dropLast())
    }
    return value
}

/// A class defined in the test bundle, so `Bundle(for:)` names that bundle.
private final class TestBundleAnchor {}

/// The generated project, as far as these pins need it.
private struct GeneratedProject {
    struct Configuration {
        let name: String
        let settings: [String: Any]
        let hasBaseConfigurationReference: Bool
    }

    let projectConfigurations: [Configuration]
    private let targetConfigurationsByName: [String: [Configuration]]

    func configurations(ofTarget name: String) -> [Configuration]? { targetConfigurationsByName[name] }

    /// Reads `App/Macdows.xcodeproj/project.pbxproj`. A missing file fails the calling test.
    static func load() throws -> GeneratedProject {
        let url = identityRoot().appendingPathComponent("App/Macdows.xcodeproj/project.pbxproj")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "no generated project: regenerate it first (xcodegen generate --spec App/project.yml --project App)")
        let data = try Data(contentsOf: url)
        let root = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let objects = try #require(root["objects"] as? [String: [String: Any]])
        let rootID = try #require(root["rootObject"] as? String)
        let project = try #require(objects[rootID])

        func configurations(inList id: String?) throws -> [Configuration] {
            let list = try #require(id.flatMap { objects[$0] })
            let ids = try #require(list["buildConfigurations"] as? [String])
            return try ids.map { configID in
                let object = try #require(objects[configID])
                return Configuration(name: object["name"] as? String ?? "",
                                     settings: object["buildSettings"] as? [String: Any] ?? [:],
                                     hasBaseConfigurationReference: object["baseConfigurationReference"] != nil)
            }
        }

        var byName: [String: [Configuration]] = [:]
        for targetID in try #require(project["targets"] as? [String]) {
            let target = try #require(objects[targetID])
            byName[target["name"] as? String ?? ""] = try configurations(inList: target["buildConfigurationList"] as? String)
        }
        return GeneratedProject(projectConfigurations: try configurations(inList: project["buildConfigurationList"] as? String),
                                targetConfigurationsByName: byName)
    }
}

// MARK: - Pins

@Suite("Bundle identity pins: ids, version source, log subsystem, fallbacks, generated project")
struct BundleIdentityPinTests {

    private static let guardHint = "This guard keeps the text counts in this test trustworthy. If the new text is a "
        + "legitimate use (say, characters inside a script block), narrow the guard here instead of rewriting the YAML around it."

    private static let appBase = ["targets", "Macdows", "settings", "base"]
    private static let appRelease = ["targets", "Macdows", "settings", "configs", "Release"]
    private static let testBase = ["targets", "MacdowsAppTests", "settings", "base"]

    private static let developmentID = "es.4sh.macdows.dev"
    private static let releaseID = "es.4sh.macdows"
    private static let testID = "es.4sh.macdows.dev.apptests"

    // P1
    @Test("the previous reverse-DNS prefix occurs in no text file of the closed list of top-level directories and root files")
    func oldPrefixIsGone() throws {
        let literal = "dev." + "haru"
        var files = identityFiles(under: identityScannedDirectories)
        for name in identityScannedRootFiles {
            let url = identityRoot().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { files.append(url) }
        }
        var scanned = 0
        var extensions = Set<String>()
        for url in files {
            let relative = url.path.replacingOccurrences(of: identityRoot().path + "/", with: "")
            if identitySkippedFiles.contains(relative) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            extensions.insert(url.pathExtension)
            #expect(!text.contains(literal), "\(relative)")
        }
        #expect(scanned > 200, "the walk found the files (\(scanned))")
        for needed in ["yml", "plist", "swift", "sh", "py", "md", "command", "xcstrings"] {
            #expect(extensions.contains(needed), "no .\(needed) file was scanned")
        }
    }

    // P2
    @Test("project.yml: three bundle ids at three places, no other way to set one, version settings once in the App base")
    func projectYmlIdentityShape() throws {
        let lines = try yamlLines("App/project.yml")
        let text = lines.map(\.text).joined(separator: "\n")

        // Closed syntax: no spelling that hides a key or a block from the counts below.
        #expect(!text.contains("\\"), "backslash escape. \(Self.guardHint)")
        #expect(!text.contains("<<") && !text.contains("!!"), "merge key or tag. \(Self.guardHint)")
        let structural = #"(^|:\s+|-\s+)"#
        #expect(lines.filter { $0.text.range(of: structural + #"[&*][A-Za-z0-9_]"#, options: .regularExpression) != nil }.isEmpty,
                "anchor or alias. \(Self.guardHint)")
        #expect(lines.filter { $0.text.range(of: #"^(- )?["'][^"']*["']\s*:"#, options: .regularExpression) != nil }.isEmpty,
                "a quoted key. \(Self.guardHint)")
        #expect(lines.filter { $0.text.range(of: structural + #"\{"#, options: .regularExpression) != nil }.isEmpty,
                "a flow mapping. \(Self.guardHint)")

        // Guard against a parser that sees nothing: the Release block exists where the file's own
        // warning says it must, and holds its entitlement setting.
        let guardLine = lines.first { $0.text.hasPrefix("CODE_SIGN_INJECT_BASE_ENTITLEMENTS:") }
        #expect(guardLine?.path == Self.appRelease, "structure parse: \(String(describing: guardLine?.path))")

        #expect(identityCount("PRODUCT_BUNDLE_IDENTIFIER", in: text) == 3, "total mentions")
        let ids = lines.filter { $0.text.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER:") }
        let found = ids.map { "\($0.path.joined(separator: "/")) = \(yamlValue($0))" }.sorted()
        let expected = [
            "\(Self.appBase.joined(separator: "/")) = \(Self.developmentID)",
            "\(Self.appRelease.joined(separator: "/")) = \(Self.releaseID)",
            "\(Self.testBase.joined(separator: "/")) = \(Self.testID)",
        ].sorted()
        #expect(found == expected, "\(found)")

        #expect(identityCount("PRODUCT_BUNDLE_IDENTIFIER[", in: text) == 0, "conditional-setting spelling")
        #expect(identityCount("bundleIdPrefix", in: text) == 0)
        #expect(identityCount("configFiles", in: text) == 0)

        // The plist is the one the target names, and nothing else can supply the keys.
        let plistLines = lines.filter { $0.text.hasPrefix("INFOPLIST_FILE:") }
        #expect(identityCount("INFOPLIST_FILE", in: text) - identityCount("GENERATE_INFOPLIST_FILE", in: text) == 1,
                "INFOPLIST_FILE mentions (GENERATE_INFOPLIST_FILE excluded)")
        #expect(plistLines.count == 1 && plistLines[0].path == Self.appBase && yamlValue(plistLines[0]) == "Macdows/Info.plist",
                "\(plistLines.map(\.path))")
        let generated = lines.filter { $0.text.hasPrefix("GENERATE_INFOPLIST_FILE:") }
        #expect(identityCount("GENERATE_INFOPLIST_FILE", in: text) == 1, "today: one mention, in the test bundle")
        #expect(generated.map(\.path) == [Self.testBase], "\(generated.map(\.path))")
        #expect(identityCount("INFOPLIST_KEY_", in: text) == 0)
        #expect(lines.filter { $0.text == "info:" || $0.text.hasPrefix("info:") }.isEmpty, "no `info:` key")

        // The configurations are the default pair. A top-level `configs:` replaces them: with a
        // second release-type configuration (say Release plus Dist) archives could use the one
        // that does not get the Release id.
        #expect(lines.filter { $0.indent == 0 && $0.text.hasPrefix("configs") }.isEmpty, "top-level configs: renames the configurations")
        let releases = lines.filter { $0.text == "Release:" }
        #expect(releases.map(\.path) == [Array(Self.appRelease.dropLast())], "\(releases.map(\.path))")

        // The only include is the untracked overlay, gated by its environment variable.
        let includes = lines.filter { $0.path == ["include"] }.map(\.text)
        #expect(includes == ["- path: project-local.yml", "enable: ${MACDOWS_SIGN_LOCAL}"], "\(includes)")
        #expect(identityCount("include:", in: text) == 1)

        // Nothing that runs after the App target's build and could rewrite its plist.
        let afterBuild = lines.filter { line in
            guard line.path.starts(with: ["targets", "Macdows"]), let colon = line.text.firstIndex(of: ":") else { return false }
            let key = line.text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return key == "postbuildscripts" || key == "postcompilescripts"
        }
        #expect(afterBuild.isEmpty, "a script phase after the App target's build")

        #expect(identityCount("MARKETING_VERSION", in: text) == 1)
        #expect(identityCount("CURRENT_PROJECT_VERSION", in: text) == 1)
        let marketing = try #require(lines.first { $0.text.hasPrefix("MARKETING_VERSION:") })
        let build = try #require(lines.first { $0.text.hasPrefix("CURRENT_PROJECT_VERSION:") })
        #expect(marketing.path == Self.appBase, "\(marketing.path)")
        #expect(build.path == Self.appBase, "\(build.path)")
        #expect(yamlValue(marketing).wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil, "\(yamlValue(marketing))")
        #expect(yamlValue(build).wholeMatch(of: /[1-9][0-9]*/) != nil, "\(yamlValue(build))")
    }

    // P3
    @Test("Info.plist takes the id, the version and the build number from build settings")
    func infoPlistReferencesBuildSettings() throws {
        let raw = try identityRaw("App/Macdows/Info.plist")
        let parsed = try #require(try PropertyListSerialization.propertyList(from: Data(raw.utf8), options: [], format: nil) as? [String: Any])
        let pairs: [(key: String, value: String)] = [
            ("CFBundleIdentifier", "$(PRODUCT_BUNDLE_IDENTIFIER)"),
            ("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
            ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)"),
        ]
        for pair in pairs {
            #expect(parsed[pair.key] as? String == pair.value, "\(pair.key) value")
            #expect(identityCount(pair.key, in: raw) == 1, "\(pair.key) occurrences in the source text")
        }
    }

    // P4
    @Test("every unified-log subsystem of the product code is the constant, never derived from the bundle id")
    func subsystemsAreTheConstant() throws {
        var perFile: [String: String] = [:]
        var total = 0
        for url in identityFiles(under: ["App"]) where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: identityRoot().path + "/", with: "")
            if relative.hasPrefix("App/MacdowsAppTests/") { continue }
            total += 1
            perFile[relative] = identityCode(try String(contentsOf: url, encoding: .utf8))
        }
        #expect(total > 50, "the walk found the product sources (\(total))")

        // The forwarder takes the subsystem as a parameter and hands it to `Logger`: its whole
        // initializer is pinned, and it holds the only other `Logger(` and `subsystem`.
        let forwarder = try #require(perFile["App/Security/DiagnosticLogger.swift"])
        #expect(identityCount("init(subsystem: String, category: String, buffer: DiagnosticLogBuffer = .shared) { "
                              + "self.category = category "
                              + "self.logger = Logger(subsystem: subsystem, category: category) "
                              + "self.buffer = buffer }", in: forwarder) == 1, "the forwarder's whole init")
        #expect(identityCount("Logger(", in: forwarder) == 1, "the forwarder constructs one Logger")
        #expect(identityCount("subsystem", in: forwarder) == 3, "the forwarder's `subsystem` occurrences")

        let others = perFile.filter { $0.key != "App/Security/DiagnosticLogger.swift" }
        let all = others.values.joined(separator: " ")
        #expect(all.matches(of: /subsystem\s*:/).count == 8, "every `subsystem` label outside the forwarder, any spacing")
        #expect(identityCount("Logger(", in: all) == 8, "every logger construction outside the forwarder")
        #expect(identityCount("subsystem: \"", in: all) == 8, "every one is a string literal")
        #expect(identityCount("subsystem: \"es.4sh.macdows\"", in: all) == 8, "and the constant")

        let shapes: [(file: String, shape: String)] = [
            ("App/RemoteWindowRendering/DisplayTopologyProvider.swift", "Logger(subsystem: \"es.4sh.macdows\", category: \"DisplayTopology\")"),
            ("App/RemoteWindowRendering/RemoteWindow.swift", "Logger(subsystem: \"es.4sh.macdows\", category: \"RemoteWindowRendering\")"),
            ("App/RemoteWindowRendering/RemoteWindowRegistry.swift", "Logger(subsystem: \"es.4sh.macdows\", category: \"RemoteWindowRendering\")"),
            ("App/RemoteWindowRendering/TrayStatusController.swift", "Logger(subsystem: \"es.4sh.macdows\", category: \"TrayStatusController\")"),
        ]
        for pin in shapes {
            let code = try #require(perFile[pin.file], Comment(rawValue: pin.file))
            #expect(identityCount("private static let logger = \(pin.shape)", in: code) == 1, "\(pin.file)")
            #expect(identityCount("Logger(subsystem:", in: code) == 1, "\(pin.file): one Logger call")
        }
    }

    // P5
    @Test("the keychain queue label, the fallbacks and their callers, by full expression shape")
    func queueLabelAndFallbacks() throws {
        let keychain = identityCode(try identityRaw("App/Security/KeychainItems.swift"))
        let hosts = identityCode(try identityRaw("App/UI/Hosts/HostRecord.swift"))
        #expect(identityCount("DispatchQueue(label: \"es.4sh.macdows.keychain\", qos: .userInitiated)", in: keychain) == 1)
        // The whole function, so nothing can be chained after the literal or put before it.
        #expect(identityCount("static func service(suffix: String) -> String { "
                              + "\"\\(Bundle.main.bundleIdentifier ?? \"\(Self.developmentID)\").\\(suffix)\" }", in: keychain) == 1)
        // Through the next statement, so nothing can be chained onto the fallback literal.
        #expect(identityCount("let folder = Bundle.main.bundleIdentifier ?? \"\(Self.developmentID)\" "
                              + "return base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(\"hosts.json\")",
                              in: hosts) == 1)

        // The callers that must go through those two, rather than spell a name of their own.
        let credentials = identityCode(try identityRaw("App/Security/CredentialStore.swift"))
        let pins = identityCode(try identityRaw("App/Security/PinStore.swift"))
        let launchItems = identityCode(try identityRaw("App/UI/StartPanel/LaunchItemStore.swift"))
        #expect(identityCount("init(service: String = KeychainItems.service(suffix: \"rdp\")) {", in: credentials) == 1)
        #expect(identityCount("init(service: String = KeychainItems.service(suffix: \"cert-pin\")) {", in: pins) == 1)
        #expect(identityCount("static func defaultFileURL() -> URL? { "
                              + "HostRecordStore.defaultFileURL()?.deletingLastPathComponent().appendingPathComponent(fileName) }",
                              in: launchItems) == 1)

        // Every read of the bundle id in product code: two, the two above; and no read by plist key.
        var reads = 0
        var byKey = 0
        for url in identityFiles(under: ["App"]) where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: identityRoot().path + "/", with: "")
            if relative.hasPrefix("App/MacdowsAppTests/") { continue }
            let code = identityCode(try String(contentsOf: url, encoding: .utf8))
            reads += identityWordCount("bundleIdentifier", in: code)
            byKey += identityCount("CFBundleIdentifier", in: code)
        }
        #expect(reads == 2, "every read of the bundle id in product code")
        #expect(byKey == 0, "no read of the id by its plist key")
    }

    // P6
    @Test("the test bundle's own identifier, read at run time")
    func testBundleHasItsOwnId() {
        #expect(Bundle(for: TestBundleAnchor.self).bundleIdentifier == Self.testID)
    }

    // P7
    @Test("the generated project and scheme: ids, version source, plist file, configurations, archive configuration")
    func generatedProjectIdentity() throws {
        let project = try GeneratedProject.load()
        #expect(project.projectConfigurations.map(\.name).sorted() == ["Debug", "Release"], "project configurations")

        let app = try #require(project.configurations(ofTarget: "Macdows"), "no Macdows target")
        #expect(app.map(\.name).sorted() == ["Debug", "Release"], "App target configurations")
        let debug = try #require(app.first { $0.name == "Debug" })
        let release = try #require(app.first { $0.name == "Release" })
        #expect(debug.settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == Self.developmentID, "Debug id")
        #expect(release.settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == Self.releaseID, "Release id")
        for key in ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"] {
            let one = debug.settings[key] as? String
            #expect(one != nil && one == release.settings[key] as? String, "\(key) differs between configurations")
        }
        #expect((debug.settings["MARKETING_VERSION"] as? String ?? "").wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil)
        #expect((debug.settings["CURRENT_PROJECT_VERSION"] as? String ?? "").wholeMatch(of: /[1-9][0-9]*/) != nil)
        for configuration in app {
            #expect(configuration.settings["INFOPLIST_FILE"] as? String == "Macdows/Info.plist", "\(configuration.name) plist file")
            #expect(configuration.settings["GENERATE_INFOPLIST_FILE"] as? String != "YES", "\(configuration.name) generates a plist")
        }

        let tests = try #require(project.configurations(ofTarget: "MacdowsAppTests"), "no test target")
        #expect(!tests.isEmpty)
        for configuration in tests {
            #expect(configuration.settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == Self.testID, "test bundle \(configuration.name) id")
        }

        for configuration in app + project.projectConfigurations {
            #expect(!configuration.hasBaseConfigurationReference, "\(configuration.name): a configuration file supplies settings")
            #expect(!configuration.settings.keys.contains { $0.hasPrefix("INFOPLIST_KEY_") }, "\(configuration.name): generated plist keys")
        }
        for configuration in project.projectConfigurations {
            for key in ["PRODUCT_BUNDLE_IDENTIFIER", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "INFOPLIST_FILE"] {
                #expect(configuration.settings[key] == nil, "project-level \(configuration.name) sets \(key)")
            }
        }

        let schemeURL = identityRoot().appendingPathComponent("App/Macdows.xcodeproj/xcshareddata/xcschemes/Macdows.xcscheme")
        try #require(FileManager.default.fileExists(atPath: schemeURL.path), "no generated scheme: regenerate the project first")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)
        for action in ["ArchiveAction", "ProfileAction"] {
            let match = scheme.firstMatch(of: try Regex("<\(action)\\s+buildConfiguration\\s*=\\s*\"([^\"]*)\""))
            #expect(match?.output[1].substring.map(String.init) == "Release", "\(action) configuration")
        }
    }
}
