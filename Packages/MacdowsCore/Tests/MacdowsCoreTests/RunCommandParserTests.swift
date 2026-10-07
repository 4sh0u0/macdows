import CRDPQueue
import Testing

@testable import MacdowsCore

/// ADR-0025 §3.1 item 2: how the start panel's "Run…" text becomes a program and arguments, and the
/// shared 255-byte limit. Placeholders only: `C:\Tools\Example.exe` and programs Windows ships.
@Suite("RunCommandParser: first segment is the program, the rest verbatim, one shared byte limit")
struct RunCommandParserTests {

    private static func parsed(_ text: String) -> RunCommand? {
        try? RunCommandParser.parse(text).get()
    }

    private static func rejection(_ text: String) -> RunCommandRejection? {
        if case .failure(let reason) = RunCommandParser.parse(text) { return reason }
        return nil
    }

    private static func ascii(_ count: Int, _ fill: Character = "a") -> String {
        String(repeating: String(fill), count: count)
    }

    // MARK: - splitting

    @Test("a bare name is the whole program")
    func bareName() {
        #expect(Self.parsed("notepad") == RunCommand(program: "notepad", arguments: ""))
        #expect(Self.parsed("notepad.exe") == RunCommand(program: "notepad.exe", arguments: ""))
    }

    @Test("an unquoted program ends at the first space or tab; the rest is the arguments")
    func unquotedSplit() {
        #expect(Self.parsed(#"notepad.exe C:\Tools\notes.txt"#)
                == RunCommand(program: "notepad.exe", arguments: #"C:\Tools\notes.txt"#))
        #expect(Self.parsed("notepad.exe\tnotes.txt") == RunCommand(program: "notepad.exe", arguments: "notes.txt"))
        // The whole separator run goes, inner spacing stays.
        #expect(Self.parsed("cmd.exe   /c  echo   hi") == RunCommand(program: "cmd.exe", arguments: "/c  echo   hi"))
    }

    @Test("a quoted program keeps its spaces and loses its quotes; the arguments keep theirs")
    func quotedProgram() {
        #expect(Self.parsed(#""C:\Program Files\Example\Example.exe""#)
                == RunCommand(program: #"C:\Program Files\Example\Example.exe"#, arguments: ""))
        #expect(Self.parsed(#""C:\Program Files\Example\Example.exe"  /open "C:\Tools\a b.txt""#)
                == RunCommand(program: #"C:\Program Files\Example\Example.exe"#, arguments: #"/open "C:\Tools\a b.txt""#))
        // Text right after the closing quote is the arguments.
        #expect(Self.parsed(#""C:\Tools\Example.exe"-n"#) == RunCommand(program: #"C:\Tools\Example.exe"#, arguments: "-n"))
        // A quote that never closes runs to the end, as Windows' own splitting does.
        #expect(Self.parsed(#""C:\Program Files\Example\Example.exe"#)
                == RunCommand(program: #"C:\Program Files\Example\Example.exe"#, arguments: ""))
        // Whitespace inside the quotes is the program's own.
        #expect(Self.parsed(#"" C:\Tools\Example.exe ""#) == RunCommand(program: #" C:\Tools\Example.exe "#, arguments: ""))
    }

    @Test("the ends are trimmed of any whitespace; only space and tab separate")
    func whitespace() {
        #expect(Self.parsed("   notepad.exe   ") == RunCommand(program: "notepad.exe", arguments: ""))
        #expect(Self.parsed("notepad.exe notes.txt \t\n") == RunCommand(program: "notepad.exe", arguments: "notes.txt"))
        #expect(Self.parsed("\u{3000}notepad.exe\u{3000}") == RunCommand(program: "notepad.exe", arguments: ""))
        // An ideographic space inside is not a Windows separator: it stays in the segment.
        #expect(Self.parsed("notepad.exe\u{3000}notes.txt")
                == RunCommand(program: "notepad.exe\u{3000}notes.txt", arguments: ""))
    }

    @Test("nothing is expanded: %VAR%, ~, $ and ||alias reach the server as typed")
    func noExpansion() {
        #expect(Self.parsed(#"%SystemRoot%\system32\notepad.exe ~ $HOME %TEMP%\x.txt"#)
                == RunCommand(program: #"%SystemRoot%\system32\notepad.exe"#, arguments: #"~ $HOME %TEMP%\x.txt"#))
        #expect(Self.parsed("||Example") == RunCommand(program: "||Example", arguments: ""))
        #expect(Self.parsed("~/x.exe $1") == RunCommand(program: "~/x.exe", arguments: "$1"))
    }

    // MARK: - refusals

    @Test("empty, whitespace-only and empty-quoted texts are refused as empty")
    func empty() {
        for text in ["", " ", "   ", "\t\n", "\u{3000}", "\"\"", "\"\" notes.txt", "\""] {
            #expect(Self.rejection(text) == .empty, "\(text.debugDescription)")
        }
    }

    @Test("a NUL in the program or the arguments is refused")
    func embeddedNul() {
        for text in ["note\u{0}pad.exe", "notepad.exe a\u{0}b", "\u{0}", "notepad.exe \u{0}", "\"C:\\a\u{0}b.exe\" x"] {
            #expect(Self.rejection(text) == .embeddedNul, "\(text.debugDescription)")
        }
        #expect(RunCommandParser.validate(program: "a\u{0}", arguments: "") == .failure(.embeddedNul))
        #expect(RunCommandParser.validate(program: "a", arguments: "\u{0}") == .failure(.embeddedNul))
    }

    // MARK: - the shared limit

    @Test("the limit is the C buffer's: CRDPQ_TEXT_BUF_SIZE - 1")
    func limitMatchesTheBuffer() {
        #expect(RunCommandParser.sharedByteLimit == 255)
        #expect(RunCommandParser.sharedByteLimit == Int(CRDPQ_TEXT_BUF_SIZE) - 1)
    }

    @Test("a program alone: 255 bytes is accepted, 256 is too long a path")
    func programAloneBoundary() {
        #expect(Self.parsed(Self.ascii(255))?.payloadByteCount == 255)
        #expect(Self.rejection(Self.ascii(256)) == .tooLongPath)
        #expect(Self.rejection(Self.ascii(1000)) == .tooLongPath)
    }

    @Test("program + 1 + arguments: 255 bytes is accepted, 256 is too long together")
    func sharedBoundary() {
        // 200 + 1 + 54 = 255
        let fits = Self.ascii(200) + " " + Self.ascii(54, "b")
        #expect(Self.parsed(fits) == RunCommand(program: Self.ascii(200), arguments: Self.ascii(54, "b")))
        #expect(Self.parsed(fits)?.payloadByteCount == 255)
        // 200 + 1 + 55 = 256
        #expect(Self.rejection(Self.ascii(200) + " " + Self.ascii(55, "b")) == .tooLongWithArguments)
        // 253 + 1 + 1 = 255 / 254 + 1 + 1 = 256
        #expect(Self.parsed(Self.ascii(253) + " b")?.payloadByteCount == 255)
        #expect(Self.rejection(Self.ascii(254) + " b") == .tooLongWithArguments)
        // A program that fits alone but leaves no room for the separator.
        #expect(Self.rejection(Self.ascii(255) + " b") == .tooLongWithArguments)
        // A program over the limit is a path problem whatever follows.
        #expect(Self.rejection(Self.ascii(256) + " b") == .tooLongPath)
        // Only the separator run between the two is free; the arguments' own spaces count.
        #expect(Self.parsed(Self.ascii(200) + "      " + Self.ascii(54, "b"))?.payloadByteCount == 255)
    }

    @Test("bytes are UTF-8 bytes, not characters")
    func utf8ByteCount() {
        // 85 x 3 bytes = 255; 86 x 3 = 258.
        #expect(Self.parsed(String(repeating: "工", count: 85))?.payloadByteCount == 255)
        #expect(Self.rejection(String(repeating: "工", count: 86)) == .tooLongPath)
        // 127 x 2 bytes = 254 + "a" = 255; one more 2-byte character overflows by one.
        #expect(Self.parsed(String(repeating: "é", count: 127) + "a")?.payloadByteCount == 255)
        #expect(Self.rejection(String(repeating: "é", count: 128)) == .tooLongPath)
        // Shared limit in mixed scripts: 4 x 63 = 252 + 1 + "ab" = 255 / + "abc" = 256.
        #expect(Self.parsed(String(repeating: "😀", count: 63) + " ab")?.payloadByteCount == 255)
        #expect(Self.rejection(String(repeating: "😀", count: 63) + " abc") == .tooLongWithArguments)
        // A combining mark after the quote is still a separate scalar: the quote still closes.
        #expect(Self.parsed("\"C:\\Tools\\Exa\u{301}mple.exe\"") == RunCommand(program: "C:\\Tools\\Exa\u{301}mple.exe", arguments: ""))
    }

    @Test("validate applies the same order without splitting")
    func validateOrder() {
        #expect(RunCommandParser.validate(program: "", arguments: "x") == .failure(.empty))
        #expect(RunCommandParser.validate(program: "", arguments: "\u{0}") == .failure(.empty))
        #expect(RunCommandParser.validate(program: Self.ascii(256), arguments: "\u{0}") == .failure(.embeddedNul))
        #expect(RunCommandParser.validate(program: Self.ascii(256), arguments: "") == .failure(.tooLongPath))
        #expect(RunCommandParser.validate(program: Self.ascii(255), arguments: "") == .success(RunCommand(program: Self.ascii(255), arguments: "")))
        #expect(RunCommandParser.validate(program: Self.ascii(255), arguments: "b") == .failure(.tooLongWithArguments))
        // Arguments are not re-split or trimmed: what was stored is what is sent.
        #expect(RunCommandParser.validate(program: "a b", arguments: " c ") == .success(RunCommand(program: "a b", arguments: " c ")))
    }

    @Test("payloadByteCount counts a separator only when there are arguments")
    func payloadByteCount() {
        #expect(RunCommand(program: "abc", arguments: "").payloadByteCount == 3)
        #expect(RunCommand(program: "abc", arguments: "d").payloadByteCount == 5)
        #expect(RunCommand(program: "工", arguments: "é").payloadByteCount == 6)
    }

    @Test("the two length refusals carry their keys; empty and NUL carry none")
    func reasonKeys() {
        #expect(RunCommandRejection.tooLongPath.reasonKey == "sp_r_long")
        #expect(RunCommandRejection.tooLongWithArguments.reasonKey == "sp_r_args_long")
        #expect(RunCommandRejection.empty.reasonKey == nil)
        #expect(RunCommandRejection.embeddedNul.reasonKey == nil)
        #expect(RunCommandRejection.allCases.count == 4)
    }
}
