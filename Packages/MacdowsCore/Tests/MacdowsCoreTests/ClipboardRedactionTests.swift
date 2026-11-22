import Foundation
@testable import MacdowsCore
import Testing

// S9: clipboard content must not leave through any of Swift's rendering paths. The canary is
// invented; its pieces (an ASCII run, a number, CJK, an emoji) are each searched for on their
// own, so a renderer that escaped or split the text would still be caught. `@testable`: one
// fixture goes through the internal inbound payload rules directly.

enum ClipboardRedactionFixtures {
    static let canary = "zq-canary-Fixture 测试 🧪 7731"
    static let needles = ["zq-canary", "Fixture", "测试", "🧪", "7731"]
    static let canaryBytes = ClipboardTextCodec.encodeUnicodeText(canary)
    /// The first bytes of the canary rendered the way `[UInt8]` renders itself ('z' 0 'q' 0),
    /// so a leak of the raw byte array is caught too.
    static let byteNeedle = "122, 0, 113, 0"
    static let typeCanary = "dev.fixture.zq-canary-type"

    /// A remote-data result that writes the canary: one request, its current answer. From a
    /// list marked excluded, so the sensitive write's rendering is checked too.
    static func writtenCanary() -> ClipboardRemoteDataResult {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: ClipboardPolicy(mode: .bidirectional))
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: true),
                                          changeCount: 1, now: t0)
        return session.remoteDataReceived(.success(canaryBytes), changeCount: 1, now: t0)
    }

    /// S3 through the session (the only way in): the pasteboard holds the canary.
    static func respondCanary() -> ClipboardRespondDecision {
        var session = ClipboardSession(policy: ClipboardPolicy(mode: .bidirectional))
        return session.dataRequested(formatId: 13, isAppActive: true,
                                     readTypes: { ["public.utf8-plain-text"] }, readText: { canary })
    }

    static func evaluateCanary() -> ClipboardInboundOutcome {
        ClipboardInboundPayload.evaluate(.success(canaryBytes), changeCount: 1, baselineChangeCount: 1,
                                         sensitive: false, limits: .standard)
    }

    /// Everything a value can be turned into by the standard rendering paths.
    static func renderings(of value: Any) -> [String: String] {
        var dumped = ""
        dump(value, to: &dumped)
        var mirrored = ""
        for child in Mirror(reflecting: value).children {
            mirrored += "\(child.label ?? "_")=\(String(describing: child.value));"
        }
        return [
            "describing": String(describing: value),
            "reflecting": String(reflecting: value),
            "interpolation": "\(value)",
            "dump": dumped,
            "mirror": mirrored,
        ]
    }

    static func leaks(in value: Any, needles: [String]) -> [String] {
        var found: [String] = []
        for (path, rendered) in renderings(of: value) {
            for needle in needles where rendered.contains(needle) {
                found.append("\(path) contains a fixture piece")
            }
        }
        return found.sorted()
    }
}

@Suite("Clipboard S9: content-holding types render only lengths and state")
struct ClipboardRedactionTests {
    typealias F = ClipboardRedactionFixtures

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let make: @Sendable () -> any Sendable
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "ClipboardText") { ClipboardText(F.canary) },
        Case(name: "ClipboardBytes") { F.canaryBytes },
        Case(name: "ClipboardDecodeResult.text") { ClipboardTextCodec.decodeUnicodeText(F.canaryBytes.bytes) },
        Case(name: "ClipboardRespondDecision.respond") { F.respondCanary() },
        Case(name: "ClipboardDataResponse.success") { ClipboardDataResponse.success(F.canaryBytes) },
        Case(name: "ClipboardInboundOutcome.write") { F.evaluateCanary() },
        Case(name: "ClipboardInboundOutcome.write, sensitive") { ClipboardInboundOutcome.write(ClipboardText(F.canary), sensitive: true) },
        Case(name: "ClipboardRemoteDataResult.write") { F.writtenCanary() },
        Case(name: "Optional<ClipboardText>") { Optional(ClipboardText(F.canary)) },
        Case(name: "[ClipboardText]") { [ClipboardText(F.canary), ClipboardText(F.canary)] },
        Case(name: "[ClipboardBytes]") { [F.canaryBytes] },
    ]

    @Test("no rendering path carries the text or its bytes", arguments: Self.cases)
    func noContentInRenderings(_ testCase: Case) {
        let value = testCase.make()
        let leaks = F.leaks(in: value, needles: F.needles + [F.byteNeedle])
        #expect(leaks.isEmpty, "\(testCase.name): \(leaks)")
    }

    @Test("the fixtures really are the content (the cases above are not vacuous)")
    func casesHoldTheCanary() {
        if case .respond(let bytes) = F.respondCanary() {
            #expect(bytes == F.canaryBytes)
        } else {
            Issue.record("the respond fixture must hold the canary's bytes")
        }
        #expect(F.evaluateCanary() == .write(ClipboardText(F.canary), sensitive: false))
        #expect(F.writtenCanary().outcome == .write(ClipboardText(F.canary), sensitive: true))
        #expect(String(describing: F.canaryBytes.bytes).contains(F.byteNeedle), "the byte needle must match how [UInt8] renders")
        // And the renderings still say something useful: the size.
        #expect(String(describing: ClipboardText(F.canary)) == "ClipboardText(utf16Count: \(F.canary.utf16.count))")
        #expect(String(describing: F.canaryBytes) == "ClipboardBytes(count: \(F.canaryBytes.count))")
    }

    @Test("a pasteboard snapshot renders its change count and type count, not the type names")
    func snapshotHidesTypeNames() {
        let snapshot = PasteboardSnapshot(changeCount: 7, types: [F.typeCanary, "public.utf8-plain-text"])
        #expect(F.leaks(in: snapshot, needles: [F.typeCanary, "public.utf8"]).isEmpty)
        #expect(String(describing: snapshot) == "PasteboardSnapshot(changeCount: 7, typeCount: 2)")
    }

    @Test("counters and the session state carry no content after content went through them, both ways")
    func stateHoldsNoContent() {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: ClipboardPolicy(mode: .bidirectional))
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: true),
                                          changeCount: 1, now: t0)
        let result = session.remoteDataReceived(.success(F.canaryBytes), changeCount: 1, now: t0)
        #expect(result.outcome == .write(ClipboardText(F.canary), sensitive: true))
        let answer = session.dataRequested(formatId: 13, isAppActive: true,
                                           readTypes: { [F.typeCanary] }, readText: { F.canary })
        #expect(answer == .respond(F.canaryBytes))
        #expect(F.leaks(in: session, needles: F.needles + [F.byteNeedle, F.typeCanary]).isEmpty)
        #expect(F.leaks(in: session.counters, needles: F.needles).isEmpty)
    }
}

@Suite("Clipboard S9: the Clipboard sources neither log nor depend on AppKit or FreeRDP")
struct ClipboardSourcePinTests {
    static func clipboardSources() throws -> [(name: String, text: String)] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MacdowsCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/MacdowsCore/Clipboard")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test("every Clipboard source file is free of print/log calls and of AppKit/FreeRDP imports")
    func noLoggingNoAppKit() throws {
        let sources = try Self.clipboardSources()
        #expect(sources.count >= 8, "the Clipboard directory must be found relative to #filePath")
        // Call shapes, not bare names: "print(" and friends with an opening parenthesis, and
        // whole import lines.
        let forbidden = ["print(", "debugPrint(", "dump(", "NSLog(", "os_log(", "Logger(", "import os",
                         "import AppKit", "import Cocoa", "import CRDPQueue", "freerdp"]
        for (name, text) in sources {
            for needle in forbidden {
                #expect(!text.contains(needle), "\(name) contains \(needle)")
            }
        }
    }

    /// Gate r1, m-4: the rule functions take state only the session holds, so a public one
    /// would let the App bypass the session's bookkeeping. Access levels are not observable
    /// from behaviour (the tests themselves use `@testable`), so the declarations are pinned
    /// on the source: each must exist exactly once, with no public/open/package modifier.
    @Test("the three pure decisions and their enums are internal: declared once each, never public")
    func pureDecisionsAreInternal() throws {
        let sources = try Self.clipboardSources()
        let declarations = ["enum ClipboardOutbound", "func readyDecision", "func changeDecision", "func respondDecision",
                            "enum ClipboardInboundPayload", "func evaluate"]
        // A declaration line: indentation, any run of lowercase modifier words, the declaration.
        let alternatives = declarations.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: #"(?m)^[ \t]*((?:[a-z]+[ \t]+)*)("# + alternatives + #")\b"#)
        var found: [String: [String]] = [:]
        for (_, text) in sources {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let modifiers = Range(match.range(at: 1), in: text),
                      let declaration = Range(match.range(at: 2), in: text) else { continue }
                found[String(text[declaration]), default: []].append(String(text[modifiers]))
            }
        }
        for declaration in declarations {
            let modifiers = found[declaration] ?? []
            #expect(modifiers.count == 1, "\(declaration): \(modifiers.count) declarations")
            for words in modifiers {
                let set = Set(words.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
                #expect(set.isDisjoint(with: ["public", "open", "package"]), "\(declaration) is declared '\(words)'")
            }
        }
    }
}
