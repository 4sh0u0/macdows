import Foundation
import Testing

// adr/0019 §2 lane D, the diagnostic-channel half.
//
// THE PROBLEM THIS SOLVES. `[reconnect]` is the judgement unit a live-host acceptance run will
// read, and the only place a reconnect will actually be observed is `Macdows.app` -- which is
// launched by Finder, by Xcode's Run button or by `open`, none of which puts its stdout anywhere a
// later reader can find. The two alternatives were a log-file environment variable (a file-writing
// entry point into the product, landing in `App/Macdows`, which no test bundle compiles) and a
// launcher script that execs the binary under `tee` (`Scripts/**`, a different lane). The unified
// log costs neither: no new file I/O, no new environment variable, and no change to the stdout the
// command-line harnesses already tee.
//
// THE RISK IT INTRODUCES, which is what this file exists to hold: the cheapest way to add a second
// channel is to reword the line for it -- a prefix, a category in the text, an interpolation that
// prints the state instead of the frozen string. Any of those makes the two channels disagree, and
// a prereg that says "the exported line text equals the stdout line text" would then be false
// without anything having failed. So the pin is: one producer, one string, both channels.
//
// WHAT IT CANNOT CHECK, registered rather than implied: that `os.Logger` really emits, and that
// `log show` really exports the same bytes. That is a live-host observation and belongs in the
// acceptance prereg, not here.

private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// The same, with line comments removed first, so a pin on two adjacent STATEMENTS is not also a
/// pin on the paragraph explaining them. `ReconnectDriver.swift` has no `//` inside a string
/// literal, and `theCommentStripperDidNotEatTheCode` is what keeps that true.
private func sourceWithoutComments(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("adr/0019 §2 lane D — the [reconnect] line goes to two channels, as one string")
struct ReconnectLogChannelPinTests {

    private static let driverPath = "App/SessionControl/ReconnectDriver.swift"

    @Test("the comment stripper removes prose and nothing else")
    func theCommentStripperDidNotEatTheCode() throws {
        let stripped = try sourceWithoutComments(Self.driverPath)
        #expect(stripped.contains("print(line)"))
        #expect(stripped.contains("static func logLine(for state: State, failedAttempts: Int)"))
        #expect(!stripped.contains("//"), "a comment marker survived the strip")
    }

    /// The frozen line, byte-for-byte, in the one place that builds it.
    ///
    /// MUST-RED for: any change to the four field names, their order, the separator, or the
    /// `[reconnect]` tag -- the shape a field-position parser and every earlier run's log depend
    /// on.
    @Test("the frozen four-field shape is built in exactly one place")
    func theLineShapeIsFrozenAndHasOneProducer() throws {
        let src = try source(Self.driverPath)
        #expect(occurrences(
            of: "return \"[reconnect] attempt=\\(attempt) delay-ms=\\(delayMS) state=\\(name) cause=\\(cause)\"",
            in: src) == 1)
        #expect(occurrences(of: "static func logLine(for state: State, failedAttempts: Int) -> String?",
                            in: src) == 1)
        #expect(occurrences(of: "Self.logLine(for:", in: src) == 1,
                "one call site, so both channels are handed the same value")
    }

    /// The two channels, adjacent, both given `line` and nothing else.
    ///
    /// MUST-RED for: a `print` that gains a prefix, a logger call that interpolates anything other
    /// than the whole line, a logger call that replaces the `print` instead of joining it, and a
    /// second `print` anywhere in the driver.
    @Test("stdout keeps the line verbatim, and the unified log gets the same string")
    func bothChannelsCarryTheSameUnmodifiedLine() throws {
        let stripped = try sourceWithoutComments(Self.driverPath)
        #expect(occurrences(
            of: "if let line = Self.logLine(for: next, failedAttempts: failedAttempts) { "
                + "print(line) "
                + "Self.logger.info(\"\\(line, privacy: .public)\") }",
            in: stripped) == 1,
            "one guard, two channels, one string -- in that order and with nothing between them")
        #expect(occurrences(of: "print(", in: stripped) == 1,
                "the driver prints exactly once; a second print would be a second line family")
        #expect(occurrences(of: "logger.", in: stripped) == 1,
                "and logs exactly once, for the same reason")
    }

    /// `privacy: .public` is not decoration. Without it `os.Logger` stores `<private>` for a
    /// dynamic string, and the exported line would carry no attempt, no delay and no cause -- the
    /// channel would exist and say nothing, which is worse than not existing, because a prereg
    /// would have been written against it.
    ///
    /// The line is safe to make public by construction: it is a fixed vocabulary of state names, a
    /// policy attempt index, a policy delay in milliseconds and a cause token. No host, no user,
    /// no address.
    @Test("the interpolation is public, or the exported line would be redacted to nothing")
    func theLoggedLineIsNotRedacted() throws {
        let stripped = try sourceWithoutComments(Self.driverPath)
        #expect(occurrences(of: "privacy: .public", in: stripped) == 1)
        #expect(occurrences(of: "Logger(subsystem: \"dev.haru.macdows\", category: \"Reconnect\")",
                            in: stripped) == 1,
                "the predicate a `log show` export will filter on")
    }
}
