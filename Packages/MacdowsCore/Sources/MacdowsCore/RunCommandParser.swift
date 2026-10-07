/// ADR-0025 §1.4 / §1.7 / §3.1 item 2: turns the start panel's "Run…" text into the program and
/// arguments a RAIL ClientExecute carries, or into the reason it cannot be sent.
///
/// What it does, and only that:
///
///  - The ends of the text are trimmed (any Unicode whitespace, so a pasted trailing newline or an
///    ideographic space does not become part of a path).
///  - The FIRST segment is the program. If the text starts with `"`, the program is everything up
///    to the next `"`, without the quotes (a path with spaces); with no closing quote it runs to the
///    end, as Windows' own command-line splitting does. Otherwise the program ends at the first
///    space or tab -- the two separators Windows splits on.
///  - Whatever follows, minus the spaces and tabs that separate it from the program, is the
///    arguments, VERBATIM: inner spacing and quotes are kept for the server to parse.
///
/// What it deliberately does not do (ADR-0025 §1.7): no shell or environment expansion -- `%VAR%`,
/// `~` and `$` reach the server as typed, and the execute flags stay 0 so the server does not
/// expand them either; no alias table -- `||name` is passed through for the server's published
/// programs to resolve; no check that the program exists. A bare name (`notepad`) is accepted;
/// whether the server resolves it is the server's answer (ADR-0025 SP-5b).
///
/// The byte limit is the bridge's: program and arguments share one 256-byte text buffer, NUL
/// separated (`crdpq.h`, `crdpq_cmd_execute_t`), so program + 1 + arguments must fit in
/// `sharedByteLimit` UTF-8 bytes, and a NUL inside either part is refused because it would read as
/// the separator. Checking here, before the send, is what lets the panel say which limit was hit;
/// `CRSession.launchProgram(_:arguments:)` refuses the same inputs on its own.
public enum RunCommandParser {
    /// `CRDPQ_TEXT_BUF_SIZE - 1`: the bytes the shared execute buffer holds before its final NUL.
    /// MacdowsCore's tests pin this against the C constant.
    public static let sharedByteLimit = 255

    /// Splits `text` into program and arguments, then applies `validate(program:arguments:)`.
    public static func parse(_ text: String) -> Result<RunCommand, RunCommandRejection> {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, scalars[start].properties.isWhitespace {
            start += 1
        }
        while end > start, scalars[end - 1].properties.isWhitespace {
            end -= 1
        }

        let programRange: Range<Int>
        var rest: Int
        if start < end, scalars[start] == "\"" {
            let open = start + 1
            if let close = scalars[open..<end].firstIndex(of: "\"") {
                programRange = open..<close
                rest = close + 1
            } else {
                programRange = open..<end
                rest = end
            }
        } else {
            let stop = scalars[start..<end].firstIndex(where: isSeparator) ?? end
            programRange = start..<stop
            rest = stop
        }
        while rest < end, isSeparator(scalars[rest]) {
            rest += 1
        }
        return validate(program: string(scalars[programRange]), arguments: string(scalars[rest..<end]))
    }

    /// The checks a parsed (or stored) program and arguments must pass before they are sent, in
    /// this order: an empty program; a NUL in either part; the program alone over the limit
    /// (`.tooLongPath`, whatever the arguments); program + 1 + arguments over the limit
    /// (`.tooLongWithArguments`). Empty arguments mean none: no separator is counted.
    public static func validate(program: String, arguments: String) -> Result<RunCommand, RunCommandRejection> {
        if program.isEmpty {
            return .failure(.empty)
        }
        if program.unicodeScalars.contains("\0") || arguments.unicodeScalars.contains("\0") {
            return .failure(.embeddedNul)
        }
        let command = RunCommand(program: program, arguments: arguments)
        if program.utf8.count > sharedByteLimit {
            return .failure(.tooLongPath)
        }
        if command.payloadByteCount > sharedByteLimit {
            return .failure(.tooLongWithArguments)
        }
        return .success(command)
    }

    /// Windows' command-line separators (space, tab). Other whitespace stays inside a segment.
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}

/// A program and its arguments, as the start panel sends them.
public struct RunCommand: Equatable, Sendable {
    /// The first segment: a full Windows path, a bare name or a `||alias`, never empty once
    /// validated.
    public var program: String
    /// The rest of the command line, verbatim; empty when there is none.
    public var arguments: String

    public init(program: String, arguments: String) {
        self.program = program
        self.arguments = arguments
    }

    /// The shared buffer's byte count for this pair: program, plus one separator and the arguments
    /// when there are any (the `length` the bridge writes, `crdpq.h`).
    public var payloadByteCount: Int {
        program.utf8.count + (arguments.isEmpty ? 0 : 1 + arguments.utf8.count)
    }
}

/// Why a "Run…" text was not sent.
public enum RunCommandRejection: Error, Equatable, Sendable, CaseIterable {
    /// Nothing but whitespace, or an empty quoted program. The panel sends nothing and says
    /// nothing (design note §3: Enter on an empty field sends 0).
    case empty
    /// A NUL inside the program or the arguments; it would read as the shared buffer's separator.
    case embeddedNul
    /// The program alone is over `RunCommandParser.sharedByteLimit` UTF-8 bytes.
    case tooLongPath
    /// The program fits, but program + 1 + arguments does not.
    case tooLongWithArguments

    /// The String Catalog key (ADR-0025 §5.1) the panel shows for this rejection, or nil where the
    /// key table has none: `.empty` by design, and `.embeddedNul`, which typing cannot produce and
    /// the 25-key table does not cover.
    public var reasonKey: String? {
        switch self {
        case .empty, .embeddedNul: nil
        case .tooLongPath: "sp_r_long"
        case .tooLongWithArguments: "sp_r_args_long"
        }
    }
}
