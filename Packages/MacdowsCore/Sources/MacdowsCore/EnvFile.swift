import Foundation

/// The single parser for this project's `KEY=VALUE` maintainer-local configuration files:
/// `~/.config/macdows/host.env` (`WIN_HOST`/`WIN_USER`/`WIN_PASS`) and
/// `~/.config/macdows/lab-boundary.env` (`MACDOWS_LAB_ALLOWED_NETS`). Both are untracked
/// files a human writes by hand, in whatever shell-ish dialect comes naturally, and both are
/// read by more than one process.
///
/// **Why one parser, as a type, in the testable package.** Three separate ad-hoc parsers used
/// to read these files and they disagreed with each other:
///
/// - `Tools/window-smoke/main.swift` and `App/Macdows/AppDelegate.swift` each keyed a line on
///   *everything* left of the first `=`, so the perfectly ordinary line `export WIN_HOST=x`
///   was filed under the key `"export WIN_HOST"` and was invisible to every `WIN_HOST`
///   lookup. Neither stripped quotes.
/// - `Scripts/run-window-smoke.command` (which extracts `WIN_HOST` textually so that sourcing
///   the file cannot drag `WIN_PASS` into the launcher's environment) accepted the optional
///   `export ` prefix, stripped one layer of surrounding quotes, and took the last match.
///
/// A prior review *measured* that disagreement fail-open: on a `host.env` carrying a bare
/// out-of-boundary `WIN_HOST=` line followed by an in-boundary `export WIN_HOST=` line, the
/// launcher's boundary gate approved one host while `window-smoke` would have dialled the
/// other. A gate that validates a different string from the one that gets dialled is not a
/// gate. So the parsing rule became one piece of code, in `MacdowsCore` (which `swift test`
/// can reach, unlike the App target, which has no test bundle at all), and every Swift caller
/// now asks *this* what the file says.
///
/// **The rule** (`Scripts/run-window-smoke.command`'s own `grep`/`sed` pair is the shell-side
/// statement of the same thing, and `EnvFileTests` pins every clause):
///
/// - lines are split on any newline form (`\n`, `\r\n`, `\r`) and each is trimmed of
///   surrounding whitespace before anything else looks at it;
/// - blank lines, and lines whose first non-blank character is `#`, are skipped;
/// - an optional leading `export` token — exactly the word `export` followed by at least one
///   space or tab — is dropped, so `export WIN_HOST=x` and `WIN_HOST=x` mean the same thing;
/// - the key is everything left of the first `=`, trimmed; a line with no `=`, or with an
///   empty key, is skipped;
/// - the value is everything right of that first `=`, with **one** layer of *matching*
///   surrounding single or double quotes removed (`"x"` and `'x'` both yield `x`; `"x'` and a
///   lone `"` are left exactly as written);
/// - the value is **not** trimmed on its left, so `KEY = v` yields `" v"` (the whole-line trim
///   above still removes trailing whitespace). The asymmetry with the key is deliberate: `sh`
///   would not accept `KEY = v` as an assignment at all, and silently repairing it here would
///   make this parser *more* permissive than the shell reading the same file. Left as written,
///   the malformed value is not a valid host literal, fails to resolve, and the boundary gate
///   refuses — the mis-typed line is caught rather than papered over;
/// - a later occurrence of a key wins, matching both `sh`'s own assignment semantics and the
///   launcher's `tail -1`.
///
/// **Deliberately not supported**, because the launcher's `sed` does not support it either
/// and matching it is worth more than being clever: a trailing `# comment` after a value is
/// part of the value, and `$VAR`/backtick/`$( )` expansion is *not* performed (this reads the
/// file as data, it does not execute it — which is the point, for a file whose whole reason to
/// be untracked is that its contents are sensitive).
///
/// **The env-var-vs-file precedence rule lives here too**, as
/// `value(forKey:in:environment:)`, for the same reason the parsing rule does: it used to be a
/// four-line copy in each harness. `MacdowsPaths` owns the third piece of the same story —
/// *where* these two files are — so that a caller needs no local spelling of any of the three.
///
/// **Never log a parsed value.** Every value these files carry is either a credential or the
/// owner's own network shape. This type has no logging of its own, and callers must keep it
/// that way — `window-smoke` prints credential *lengths* for exactly this reason.
public enum EnvFile {
    /// Why reading the file failed. Deliberately carries the path and nothing else: the
    /// underlying `Foundation` error is dropped rather than forwarded, because it is the kind
    /// of string that ends up in a status label or a CI transcript and there is no reason for
    /// it to be able to quote file *contents* from some future Foundation version.
    public enum ReadError: Error, Equatable, Sendable {
        /// The path does not exist, is a directory, or this process may not read it.
        case unreadable(path: String)
        /// The bytes are not valid UTF-8. Not silently lossy-decoded: a config file that is
        /// not text is a misconfiguration the caller should see, not guess at.
        case notUTF8(path: String)
    }

    /// Parses already-loaded file contents. Pure, so every clause of the rule above is
    /// testable with no filesystem at all.
    public static func parse(contents: String) -> [String: String] {
        var values: [String: String] = [:]
        // `isNewline` rather than a literal "\n": in a Swift `String` a CRLF pair is a single
        // `Character`, so this handles a file written on Windows (or pasted through one)
        // without leaving a stray carriage return glued to the last value on every line.
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let withoutExport = strippingExportPrefix(line) {
                line = withoutExport
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = strippingOneQuoteLayer(String(line[line.index(after: equals)...]))
        }
        return values
    }

    /// Reads and parses the file at `path`.
    ///
    /// Throws rather than returning `[:]` on a read failure, because the two callers need to
    /// tell those apart: `LabBoundary` must refuse when its boundary file is unreadable (an
    /// empty dictionary would look identical to a file that simply lists no segments, and the
    /// two are different refusal reasons), and the App shows the user a different message for
    /// "no config file" than for "config file missing a key".
    public static func parse(path: String) throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ReadError.unreadable(path: path)
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw ReadError.notUTF8(path: path)
        }
        return parse(contents: contents)
    }

    /// The other half of "read a value out of one of these files": which of the two sources
    /// wins when both have the key. An environment variable that is present **and non-empty**
    /// takes precedence over the file; otherwise the file's value is returned, `nil` when it
    /// has none either.
    ///
    /// **Why this lives here and not at the call sites.** `Tools/window-smoke/main.swift` and
    /// `Tools/bridge-smoke/GateShim.swift` each carried their own four-line copy of exactly
    /// this rule, sitting directly on top of the parser this type unified — the same
    /// two-implementations-of-one-rule shape at one-tenth the size, and on the same values
    /// (`WIN_HOST` above all) whose two readings a boundary gate is supposed to keep identical.
    /// A review parked it as a follow-up rather than let a third copy appear; this is that
    /// follow-up. `Scripts/run-window-smoke.command` states the same precedence on the shell
    /// side (`SMOKE_HOST="${WIN_HOST:-}"`, consulting `host.env` only when that is empty), and
    /// it is what lets the launcher hand a child the exact host its own gate cleared.
    ///
    /// **Empty is treated as absent, on the environment side only.** `${VAR:-}` semantics: an
    /// exported-but-empty `WIN_HOST` means "I did not supply one", because that is what an
    /// unset variable looks like after a shell has expanded it into a child's environment. The
    /// *file* side gets no such repair — an empty value in `host.env` comes back as the empty
    /// string, not `nil`, so the caller's own "missing credentials" guard keeps deciding what
    /// emptiness means (`window-smoke` exits 2 on it, `bridge-smoke`'s `main.mm` prints
    /// `present (len=0)` and then exits 2 on its own guard). Collapsing the two here would
    /// silently change both of those messages.
    ///
    /// **One key, not two.** The rule this replaces took an environment-variable name and a
    /// file key separately, and every call site in the repository passed the same string for
    /// both. A single parameter makes that a property of the API instead of a coincidence
    /// three call sites happened to share.
    ///
    /// The environment is a parameter so the rule is testable without mutating the test
    /// process's own environment (which no test in this package does, and which would not be
    /// safe to do concurrently in any case).
    public static func value(
        forKey key: String,
        in fileValues: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let fromEnvironment = environment[key], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return fileValues[key]
    }

    /// Returns `line` with a leading `export` token removed, or `nil` when there is no such
    /// token. `exportWIN_HOST=x` is *not* an export line — the token has to be followed by
    /// whitespace, exactly as `sh` requires — and neither is `export=x`, which assigns to a
    /// variable that happens to be called `export`.
    private static func strippingExportPrefix(_ line: String) -> String? {
        let token = "export"
        guard line.hasPrefix(token) else { return nil }
        var cursor = line.index(line.startIndex, offsetBy: token.count)
        guard cursor < line.endIndex, line[cursor].isWhitespace else { return nil }
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return String(line[cursor...])
    }

    /// Removes one layer of matching surrounding quotes. Matching is required on purpose: an
    /// unbalanced quote is far more likely to be a typo the human should see reflected back
    /// than an intentional delimiter, and silently eating half of it would produce a value
    /// that differs from what any shell reading the same file would produce.
    private static func strippingOneQuoteLayer(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        guard first == last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
