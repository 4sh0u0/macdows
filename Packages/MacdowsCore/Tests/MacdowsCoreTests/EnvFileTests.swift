import Foundation
import Testing

@testable import MacdowsCore

/// `EnvFile` is the one parser for `host.env` and `lab-boundary.env`, and it exists because
/// the three ad-hoc parsers it replaced disagreed with each other in a way that was measured
/// fail-open (see the type's own doc comment). The cases below are therefore not "does a
/// dictionary come back" — they are the *contract* the three used to disagree about, clause by
/// clause, with `exportPrefixIsTheFailOpenFixture` reproducing the exact file shape from that
/// finding.
@Suite("EnvFile")
struct EnvFileTests {
    /// The key is trimmed and the value's *left* side deliberately is not, so `KEY = v` yields
    /// `" v"` rather than `"v"` — see the rule list on `EnvFile` for why: `sh` would not accept
    /// that line as an assignment either, and repairing it here would make this parser more
    /// permissive than the shell reading the same file. The second assertion is intent, not a
    /// typo.
    @Test("the key is trimmed; the value keeps its leading whitespace instead of being repaired")
    func plainAssignmentAndTheDeliberateTrimAsymmetry() {
        let values = EnvFile.parse(contents: "WIN_HOST=192.0.2.10\n  WIN_USER = rdpuser  \n")
        #expect(values["WIN_HOST"] == "192.0.2.10")
        #expect(values["WIN_USER"] == " rdpuser")
        // And the fail-closed consequence at the gate: the untrimmed value is not a literal.
        #expect(LabBoundary.Address(literal: " 192.0.2.10") == nil)
    }

    /// The defect that made the old parsers invisible to their own lookups: they keyed on
    /// everything left of the first `=`, so this line landed under `"export WIN_HOST"`.
    @Test("an `export ` prefix is accepted, with any run of spaces or tabs after the token")
    func exportPrefixIsStripped() {
        let values = EnvFile.parse(contents: """
            export WIN_HOST=192.0.2.10
            export\tWIN_USER=rdpuser
            export   WIN_PASS=secret
            """)
        #expect(values["WIN_HOST"] == "192.0.2.10")
        #expect(values["WIN_USER"] == "rdpuser")
        #expect(values["WIN_PASS"] == "secret")
        #expect(values["export WIN_HOST"] == nil)
    }

    /// `export` is a token, not a text prefix. Both of these lines assign to a variable whose
    /// name merely starts with (or is) `export`, and a parser that pattern-matched on the
    /// characters would silently rename the key.
    @Test("`export` without following whitespace is part of the key, not a prefix")
    func exportTokenRequiresWhitespace() {
        let values = EnvFile.parse(contents: "exportWIN_HOST=192.0.2.10\nexport=x\n")
        #expect(values["exportWIN_HOST"] == "192.0.2.10")
        #expect(values["WIN_HOST"] == nil)
        #expect(values["export"] == "x")
    }

    @Test("one layer of matching quotes is removed, and only a matching pair")
    func quoteStripping() {
        let values = EnvFile.parse(contents: """
            DOUBLE="quoted value"
            SINGLE='quoted value'
            NESTED=""inner""
            MISMATCHED="quoted'
            LONE_OPEN="unterminated
            ONE_CHARACTER="
            EMPTY_QUOTED=""
            INNER=a"b
            """)
        #expect(values["DOUBLE"] == "quoted value")
        #expect(values["SINGLE"] == "quoted value")
        // Exactly one layer: the inner pair survives.
        #expect(values["NESTED"] == "\"inner\"")
        #expect(values["MISMATCHED"] == "\"quoted'")
        #expect(values["LONE_OPEN"] == "\"unterminated")
        #expect(values["ONE_CHARACTER"] == "\"")
        #expect(values["EMPTY_QUOTED"] == "")
        #expect(values["INNER"] == "a\"b")
    }

    @Test("comments, blank lines and lines without `=` are skipped; an empty key is skipped")
    func skippedLines() {
        let values = EnvFile.parse(contents: """
            # a comment
              # an indented comment

            \t
            NOT_AN_ASSIGNMENT
            =orphan value
            WIN_HOST=192.0.2.10
            """)
        #expect(values.count == 1)
        #expect(values["WIN_HOST"] == "192.0.2.10")
    }

    /// Deliberate, and matched to `Scripts/run-window-smoke.command`'s own `sed`, which does
    /// not strip trailing comments either. Pinned so that "improving" it into shell-style
    /// comment handling has to be a conscious change to both sides at once.
    @Test("a `#` after a value is part of the value, not a trailing comment")
    func trailingHashIsNotAComment() {
        let values = EnvFile.parse(contents: "WIN_HOST=192.0.2.10 # the lab box\n")
        #expect(values["WIN_HOST"] == "192.0.2.10 # the lab box")
    }

    @Test("a later occurrence of a key wins, matching sh's own assignment semantics")
    func lastOccurrenceWins() {
        let values = EnvFile.parse(contents: """
            WIN_HOST=192.0.2.1
            WIN_HOST=192.0.2.2
            WIN_HOST=192.0.2.3
            """)
        #expect(values["WIN_HOST"] == "192.0.2.3")
    }

    /// The exact file shape from the fail-open finding that produced this type: a bare
    /// out-of-boundary line followed by an in-boundary `export` line. The old Swift parsers
    /// returned the FIRST (out-of-boundary) value, because the `export` line was filed under a
    /// key nothing ever looked up, while the shell launcher's gate validated the second — so
    /// the gate approved one host and the harness would have dialled another.
    ///
    /// The addresses here are RFC 5737 documentation ranges standing in for the real pair.
    @Test("the fail-open fixture: bare line then export line yields the export value")
    func exportPrefixIsTheFailOpenFixture() {
        let values = EnvFile.parse(contents: """
            WIN_HOST=203.0.113.9
            export WIN_HOST=192.0.2.10
            """)
        #expect(values["WIN_HOST"] == "192.0.2.10")
    }

    @Test("CRLF and lone-CR line endings are handled; no carriage return survives into a value")
    func lineEndings() {
        let crlf = EnvFile.parse(contents: "WIN_HOST=192.0.2.10\r\nWIN_USER=rdpuser\r\n")
        #expect(crlf["WIN_HOST"] == "192.0.2.10")
        #expect(crlf["WIN_USER"] == "rdpuser")

        let cr = EnvFile.parse(contents: "WIN_HOST=192.0.2.10\rWIN_USER=rdpuser")
        #expect(cr["WIN_HOST"] == "192.0.2.10")
        #expect(cr["WIN_USER"] == "rdpuser")
    }

    @Test("a value may contain `=`; only the first one splits the line")
    func onlyTheFirstEqualsSplits() {
        let values = EnvFile.parse(contents: "WIN_PASS=a=b=c\n")
        #expect(values["WIN_PASS"] == "a=b=c")
    }

    @Test("reading a real file goes through the same rule as reading a string")
    func parsingFromDisk() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "host.env")
        try """
            # lab box
            export WIN_HOST="192.0.2.10"
            WIN_USER=rdpuser
            """.write(toFile: path, atomically: true, encoding: .utf8)

        let values = try EnvFile.parse(path: path)
        #expect(values["WIN_HOST"] == "192.0.2.10")
        #expect(values["WIN_USER"] == "rdpuser")
    }

    /// A missing file has to be distinguishable from an empty one: `LabBoundary` turns the
    /// first into `boundaryFileUnreadable` and the second into `noAllowedSegments`, and the
    /// App shows the operator different text for each.
    @Test("a missing path throws rather than returning an empty dictionary")
    func missingFileThrows() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "definitely-not-here.env")
        #expect(throws: EnvFile.ReadError.unreadable(path: path)) {
            try EnvFile.parse(path: path)
        }
    }

    @Test("a directory in place of a file throws, on every uid")
    func directoryThrows() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: EnvFile.ReadError.unreadable(path: directory.url.path)) {
            try EnvFile.parse(path: directory.url.path)
        }
    }

    @Test("non-UTF-8 bytes throw rather than being lossily decoded into a plausible-looking value")
    func invalidUTF8Throws() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "binary.env")
        // 0xFF is not a legal UTF-8 byte in any position.
        try Data([0x57, 0x49, 0x4E, 0x5F, 0x48, 0x4F, 0x53, 0x54, 0x3D, 0xFF, 0x0A])
            .write(to: URL(fileURLWithPath: path))
        #expect(throws: EnvFile.ReadError.notUTF8(path: path)) {
            try EnvFile.parse(path: path)
        }
    }
}

/// A throwaway directory that removes itself when the test's reference to it goes away.
///
/// Kept as a class with a `deinit` rather than a `defer` in every test: several cases here and
/// in `LabBoundaryTests` create a file whose *permissions* are the thing under test, and a
/// cleanup that only runs on the success path would leave those behind on a failing run.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macdows-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(for name: String) -> String {
        url.appendingPathComponent(name).path
    }

    deinit {
        // Restore any deliberately-unreadable fixture first, so removal cannot fail on it.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for name in contents {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: url.appendingPathComponent(name).path
                )
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}
