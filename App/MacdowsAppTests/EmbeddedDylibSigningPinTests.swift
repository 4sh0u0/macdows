import Foundation
import Testing

// adr/0006 §2 vendoring, this lane's fix (2026-09-23): the first form-1 real-machine trial batch
// failed at dyld time because the seven vendored FreeRDP/FFmpeg dylibs `App/project.yml` embeds
// into the App bundle stayed ad-hoc-signed while the App itself carried the maintainer overlay's
// Team ID, so the App and its own embedded libraries disagreed with each other about who signed
// them ("different Team IDs", `EXIT_STATUS=6`). The root cause was a build-graph shape, not a
// missing flag: the dylibs used to be `sources:` entries with `buildPhase.copyFiles.codeSignOnCopy:
// true`, and XcodeGen 2.46.0 simply never lowers that key into a pbxproj `ATTRIBUTES` at all --
// silently, with no `generate`-time or build-time error. The fix moves the same seven dylibs to
// `dependencies:` (`framework:` + `embed: true` + `codeSign: true` + `link: false`), the one shape
// that XcodeGen 2.46.0 does lower into `CodeSignOnCopy`, so the Embed Frameworks build phase
// re-signs each dylib under the App's own signing identity at build time.
//
// What is being protected, and why source text is (partly) the only thing that can protect it:
//
//  1. The `project.yml` shape itself. `dependencies:` entries are ordinary YAML, so an offline
//     `#expect` on their tokens is a normal test -- but it can only pin what the AUTHOR wrote, not
//     what XcodeGen actually DOES with it. That gap is exactly how this defect shipped in the
//     first place: the old `sources:` + `codeSignOnCopy: true` form read as correct and was never
//     exercised against the generated project by anything, in this repo, ever.
//  2. The generated project, `App/Macdows.xcodeproj/project.pbxproj`, therefore gets its own pin:
//     the `CodeSignOnCopy` attribute XcodeGen actually lowers, once per dylib. This is the half
//     that would have caught the original defect outright -- the old form's generated project has
//     zero `CodeSignOnCopy` occurrences -- and the half no test in this repository held before this
//     lane (gate r1's I-1: the only references to `CodeSignOnCopy` / `Embed Frameworks` /
//     `TeamIdentifier` anywhere in `App` / `Packages` / `Tools` / `Scripts` / `.github` were
//     `project.yml` and its own generated output, watched by nobody).
//
// Deliberately NOT pinned here: that the embedded copies actually carry the App's Team ID at
// runtime, or that the app launches without a dyld error. Both are real-machine, real-signing-
// identity facts (`codesign --verify`, an offline launch under the maintainer overlay) that only a
// gate's live probe can observe; a contributor checkout with no signing identity at all has no Team
// ID for anything to agree or disagree with, on either side. What these pins CAN hold, and do hold,
// is that the build graph continues to ask XcodeGen to re-sign every one of the seven dylibs -- the
// one property that is a fact about `project.yml` and its lowering, true regardless of who is
// signing.
//
// This bundle does not run in Tier 1 (ubuntu-latest has no Xcode); it runs in Tier 2, after
// `Scripts/bootstrap.sh` has already run `xcodegen generate` for the app build step above it.

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// One source file with its lines intact -- for YAML and for the generated `.pbxproj`, both of
/// which are line-oriented formats where a per-line scan says something a whitespace-collapsed
/// blob cannot.
private func rawSource(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// `project.yml` with every full-line `#` comment removed -- a `#` only ever opens a comment here
/// when it is the first non-whitespace character on its line, the only shape every comment in this
/// file has -- and every remaining run of whitespace collapsed to a single space, so a pin is about
/// the declared tokens and not about how a paragraph of prose happens to be wrapped, and cannot be
/// satisfied by a dylib name that only appears inside a comment.
private func yamlWithoutCommentLines(_ relative: String) throws -> String {
    let lines = try rawSource(relative)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { line in !line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The seven SONAME symlink names `App/project.yml` embeds into the App bundle and re-signs under
/// the App's own signing identity. Three FreeRDP, four FFmpeg -- see `Scripts/gen-notices.sh`'s own
/// W8 rationale for why all four FFmpeg components are mandatory, not a menu. Order matches
/// `dependencies:` in `project.yml` today; nothing below depends on that order.
private let embeddedDylibSONAMEs = [
    "libfreerdp3.3.dylib",
    "libfreerdp-client3.3.dylib",
    "libwinpr3.3.dylib",
    "libavcodec.63.dylib",
    "libavutil.61.dylib",
    "libswresample.7.dylib",
    "libswscale.10.dylib",
]

@Suite("embedded dylib codesign: project.yml declares embed+codeSign+link:false for all seven")
struct EmbeddedDylibProjectYAMLShapePinTests {

    @Test("each SONAME is a - framework: dependency with embed: true codeSign: true link: false, exactly once")
    func eachDylibIsEmbeddedAndCodeSigned() throws {
        let yaml = try yamlWithoutCommentLines("App/project.yml")
        for name in embeddedDylibSONAMEs {
            let needle = "\(name) embed: true codeSign: true link: false"
            #expect(
                occurrences(of: needle, in: yaml) == 1,
                "expected exactly one embed+codeSign+non-link dependency entry for \(name)"
            )
        }
        #expect(
            occurrences(of: "- framework:", in: yaml) == 7,
            "expected exactly the seven dylibs above under dependencies:, no more and no fewer"
        )
    }

    @Test("no dylib is declared under sources: as a copyFiles entry any more")
    func noDylibUnderSourcesCopyFiles() throws {
        let yaml = try yamlWithoutCommentLines("App/project.yml")
        #expect(
            occurrences(of: "codeSignOnCopy", in: yaml) == 0,
            "codeSignOnCopy: under sources: is exactly the shape XcodeGen 2.46.0 never lowers -- it must not come back"
        )
        #expect(
            occurrences(of: ".dylib", in: yaml) == 7,
            "the only seven .dylib mentions should be the dependencies: entries pinned above"
        )
    }
}

@Suite("embedded dylib codesign: xcodegen actually lowers all seven into CodeSignOnCopy")
struct EmbeddedDylibGeneratedProjectPinTests {

    @Test("project.pbxproj exists -- run xcodegen generate first")
    func generatedProjectExists() throws {
        let path = repoRoot().appendingPathComponent("App/Macdows.xcodeproj/project.pbxproj").path
        #expect(
            FileManager.default.fileExists(atPath: path),
            "App/Macdows.xcodeproj/project.pbxproj is missing -- run xcodegen generate first"
        )
    }

    @Test("CodeSignOnCopy appears exactly seven times, once per embedded dylib, on a PBXBuildFile line naming it")
    func generatedProjectSignsAllSevenDylibs() throws {
        let path = repoRoot().appendingPathComponent("App/Macdows.xcodeproj/project.pbxproj").path
        try #require(
            FileManager.default.fileExists(atPath: path),
            "project.pbxproj missing -- run xcodegen generate first"
        )
        let pbxproj = try rawSource("App/Macdows.xcodeproj/project.pbxproj")

        #expect(
            occurrences(of: "CodeSignOnCopy", in: pbxproj) == 7,
            "expected exactly seven CodeSignOnCopy attributes, one per embedded dylib"
        )

        let lines = pbxproj.split(separator: "\n", omittingEmptySubsequences: false)
        for name in embeddedDylibSONAMEs {
            let matching = lines.filter { $0.contains(name) && $0.contains("CodeSignOnCopy") }
            #expect(
                matching.count == 1,
                "expected exactly one PBXBuildFile line naming \(name) with CodeSignOnCopy, found \(matching.count)"
            )
        }
    }
}
