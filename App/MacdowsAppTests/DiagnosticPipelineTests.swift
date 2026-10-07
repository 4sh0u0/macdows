import Darwin
import Foundation
import MacdowsCore
import os
import Testing

// UI slice ③ commit 1 (ADR-0024 D-8, X-b): the diagnostics pipeline without its UI -- the ring
// buffer, the App's log entry point, the WLog callback appender that keeps the stdout channel and
// copies each FreeRDP line into the buffer, and the export (buffer -> default-deny filter -> file
// with the "N lines not exported" footer). Offline: the WLog path is driven through a test logger
// of its own (`attachProcessLogCallbacksToLoggerNamed:`), never by swapping this process's root
// appender while other suites may be logging.

private func diagRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func diagSource(_ relative: String) throws -> String {
    try String(contentsOf: diagRepoRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// Block and line comments removed, whitespace folded (the bridge has no `//` inside a string).
private func diagCodeOnly(_ text: String) -> String {
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
        if text[index...].hasPrefix("/*"), let close = text.range(of: "*/", range: index..<text.endIndex) {
            index = close.upperBound
            out.append(" ")
        } else if text[index...].hasPrefix("//") {
            index = text[index...].firstIndex(of: "\n") ?? text.endIndex
        } else {
            out.append(text[index])
            index = text.index(after: index)
        }
    }
    return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func diagOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Runs `body` with file descriptor `fd` (1 = stdout, 2 = stderr) redirected into a pipe and
/// returns what was written. Other suites' output written meanwhile lands here too; callers look
/// for their own unique marker only.
private func diagCapture(fd: Int32, _ body: () -> Void) -> String {
    fflush(nil)
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { return "" }
    let saved = dup(fd)
    dup2(ends[1], fd)
    close(ends[1])
    let reader = ends[0]
    let collected = OSAllocatedUnfairLock(initialState: Data())
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var chunk = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = read(reader, &chunk, chunk.count)
            if count <= 0 { break }
            data.append(chunk, count: count)
        }
        let received = data
        collected.withLock { $0 = received }
        finished.signal()
    }
    body()
    fflush(nil)
    dup2(saved, fd)
    close(saved)
    finished.wait()
    close(reader)
    return String(decoding: collected.withLock { $0 }, as: UTF8.self)
}

/// WinPR entry points, looked up at run time (WinPR's headers are not imported into Swift). The
/// message is passed as the format string itself with no arguments (it must hold no `%`), so the
/// `va_list` parameter -- a plain pointer on arm64 Darwin, the only architecture built -- is
/// never read and is passed as NULL.
private enum DiagWinPR {
    typealias Get = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    typealias PrintVA = @convention(c) (OpaquePointer?, UInt32, Int, UnsafePointer<CChar>, UnsafePointer<CChar>,
                                         UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Int32

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Logs `message` at `level` through the logger named `tag`, from a function named `function`.
    static func log(tag: String, level: UInt32, function: String, message: String) -> Bool {
        guard !message.contains("%"),
              let get = symbol("WLog_Get", as: Get.self),
              let print = symbol("WLog_PrintTextMessageVA", as: PrintVA.self),
              let logger = tag.withCString({ get($0) })
        else { return false }
        return message.withCString { format in
            "DiagnosticPipelineTests.swift".withCString { file in
                function.withCString { function in
                    print(logger, level, 1, file, function, format, nil) != 0
                }
            }
        }
    }
}

private final class DiagSinkLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(Int, String, String)] = []

    func add(_ level: Int, _ tag: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append((level, tag, message))
    }

    func matching(_ marker: String) -> [(Int, String, String)] {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.2.contains(marker) }
    }
}

@Suite("UI slice ③ — the diagnostics pipeline: ring buffer, App log entry, WLog callback, export (ADR-0024 D-8)", .serialized)
struct DiagnosticPipelineTests {
    typealias Line = DiagnosticExportFilter.Line

    // MARK: - Ring buffer

    @Test("the ring buffer keeps the newest `capacity` lines, oldest first, and counts the ones pushed out")
    func ringBufferIsBounded() {
        let buffer = DiagnosticLogBuffer(capacity: 3)
        for index in 0..<5 {
            buffer.append(Line(source: .app, level: .info, tag: "T", message: "m\(index)"))
        }
        #expect(buffer.snapshot().map(\.line.message) == ["m2", "m3", "m4"])
        #expect(buffer.evictedCount == 2)
        buffer.append(Line(source: .app, level: .info, tag: "T", message: "m5"))
        #expect(buffer.snapshot().map(\.line.message) == ["m3", "m4", "m5"])
        buffer.removeAll()
        #expect(buffer.snapshot().isEmpty && buffer.evictedCount == 0)
        #expect(DiagnosticLogBuffer.shared.capacity == 2000)
    }

    @Test("appends from many threads at once are all counted, and the buffer never exceeds its capacity")
    func ringBufferIsThreadSafe() async {
        let buffer = DiagnosticLogBuffer(capacity: 100)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<50 {
                        buffer.append(Line(source: .freerdp, level: .warn, tag: "com.t", message: "w\(worker)-\(index)"))
                    }
                }
            }
        }
        #expect(buffer.snapshot().count == 100)
        #expect(buffer.evictedCount == 300)
    }

    // MARK: - App log entry point

    @Test("DiagnosticLogger copies a line into the buffer as .app, tagged with its category, at the mapped level")
    func appLoggerWritesTheBuffer() {
        let buffer = DiagnosticLogBuffer(capacity: 10)
        let logger = DiagnosticLogger(subsystem: "dev.haru.macdows.tests", category: "Connect", buffer: buffer)
        let count = 3
        logger.notice("[connect] refused: no host selected (host records: \(count, privacy: .public))")
        logger.debug("never buffered")
        logger.info("info \(count, privacy: .public)")
        logger.warning("warning")
        logger.error("error")
        logger.fault("fault")
        let lines = buffer.snapshot().map(\.line)
        #expect(lines.map(\.message) == ["[connect] refused: no host selected (host records: 3)", "info 3", "warning", "error", "fault"])
        #expect(lines.map(\.level) == [.info, .debug, .warn, .error, .fatal], "notice -> INFO, info -> DEBUG (below Standard)")
        #expect(lines.allSatisfy { $0.source == .app && $0.tag == "Connect" })
    }

    @Test("a value not marked public reaches the buffer as <private>, never as itself")
    func privateInterpolationIsRedactedInTheBuffer() {
        let buffer = DiagnosticLogBuffer(capacity: 10)
        let logger = DiagnosticLogger(subsystem: "dev.haru.macdows.tests", category: "Connect", buffer: buffer)
        let secretish = "fixture-value-not-public"
        logger.notice("[connect] a=\(secretish) b=\(7, privacy: .public)")
        let message: DiagnosticLogMessage = "x=\(secretish)"
        #expect(!message.isPublic && message.text == "x=\(secretish)" && message.bufferText == "x=<private>")
        #expect(buffer.snapshot().map(\.line.message) == ["[connect] a=<private> b=7"])
    }

    @Test("the unified-log half: each level forwards the whole line, public only when every value was public")
    func appLoggerForwardsToOSLogger() throws {
        let code = diagCodeOnly(try diagSource("App/Security/DiagnosticLogger.swift"))
        #expect(code.contains("self.logger = Logger(subsystem: subsystem, category: category)"))
        for level in ["debug", "info", "notice", "warning", "error", "fault"] {
            #expect(diagOccurrences(of: "logger.\(level)(\"\\(message.text, privacy: .public)\")", in: code) == 1, "\(level) public")
            #expect(diagOccurrences(of: "logger.\(level)(\"\\(message.text, privacy: .private)\")", in: code) == 1, "\(level) private")
        }
        #expect(diagOccurrences(of: "record(message, level:", in: code) == 5, "every level but debug is buffered")
    }

    @Test("the App's own loggers outside the window code are DiagnosticLoggers, so their lines reach the buffer")
    func appLoggersAreConverted() throws {
        #expect(try diagSource("App/UI/Connect/ConnectChain.swift").contains("static let log = DiagnosticLogger(subsystem: \"dev.haru.macdows\", category: \"Connect\")"))
        #expect(try diagSource("App/SessionControl/ReconnectDriver.swift").contains("private static let logger = DiagnosticLogger(subsystem: \"dev.haru.macdows\", category: \"Reconnect\")"))
        #expect(try diagSource("App/SessionControl/ShellAutolaunch.swift").contains("private static let logger = DiagnosticLogger(subsystem: \"dev.haru.macdows\", category: \"Autolaunch\")"))
        var scanned = 0
        for directory in ["App/UI", "App/SessionControl", "App/Security", "App/Macdows"] {
            let root = diagRepoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "DiagnosticLogger.swift" {
                scanned += 1
                let code = diagCodeOnly(try String(contentsOf: url, encoding: .utf8))
                #expect(!code.contains(" Logger(subsystem:") && !code.contains("=Logger(subsystem:"), "\(url.lastPathComponent) has a bare os.Logger")
            }
        }
        #expect(scanned > 20)
    }

    // MARK: - Export

    private static let home = "/tmp/fixture-home"

    /// One line of every class the D-8 grammar distinguishes.
    private static func fixtureEntries() -> [DiagnosticLogBuffer.Entry] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lines: [Line] = [
            Line(source: .freerdp, level: .info, tag: DiagnosticExportFilter.bridgeTag, message: "[key-witness] seq=1 kind=scancode flags=0x0000 code=0x1e rc=1"),
            Line(source: .freerdp, level: .warn, tag: DiagnosticExportFilter.bridgeTag, message: "[cert] rejected sha256=ab12 flags=0x00000001 route=0"),
            Line(source: .app, level: .info, tag: "Connect", message: "[connect] start user=fixture-account host=pc.example"),
            Line(source: .app, level: .info, tag: "Reconnect", message: "[reconnect] attempt=1 delay-ms=1000 state=waiting cause="),
            Line(source: .freerdp, level: .warn, tag: "com.freerdp.core", message: "could not open \(home)/Library/x.cfg"),
            Line(source: .freerdp, level: .error, tag: "com.freerdp.crypto", message: "-----BEGIN CERTIFICATE----- MIIB"),
            Line(source: .freerdp, level: .info, tag: "com.freerdp.core", message: "below the Standard floor"),
            Line(source: .app, level: .info, tag: "Autolaunch", message: "[autolaunch] press=connect"),
            Line(source: .app, level: .debug, tag: "Connect", message: "[connect] an info-level App line"),
            Line(source: .app, level: .info, tag: "Settings", message: "MACDOWS_FIXTURE_KNOB=fixture-knob-value"),
        ]
        return lines.enumerated().map { DiagnosticLogBuffer.Entry(date: start.addingTimeInterval(Double($0.offset)), line: $0.element) }
    }

    @Test("default export: registered shapes only; key-witness and account left out, PEM never, home -> ~, footer counts the rest")
    func exportDefault() throws {
        let output = DiagnosticExport.render(Self.fixtureEntries(), evicted: 4, includeAccountAndKeyWitness: false,
                                             homeDirectory: Self.home, exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
                                             timeZone: TimeZone(identifier: "UTC")!)
        let lines = output.text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(5) == [
            "# Macdows diagnostics",
            "# Exported: 2027-01-15T08:01:40.000Z",
            "# Log detail: Standard",
            "# Account names and key-witness lines: left out",
            "# Buffer: 10 lines kept, 4 older lines dropped",
        ])
        #expect(Array(lines.dropFirst(5).dropLast()) == [
            "2027-01-15T08:00:01.000Z freerdp com.freerdp.client.macdows [cert] rejected sha256=ab12 flags=0x00000001 route=0",
            "2027-01-15T08:00:02.000Z app Connect [connect] start user=<account> host=pc.example",
            "2027-01-15T08:00:03.000Z app Reconnect [reconnect] attempt=1 delay-ms=1000 state=waiting cause=",
            "2027-01-15T08:00:04.000Z freerdp com.freerdp.core could not open ~/Library/x.cfg",
        ])
        #expect(lines.last == "# 6 lines not exported", "always the last line")
        #expect(output.exportedCount == 4 && output.withheldCount == 6)
        for absent in ["[key-witness]", "fixture-account", "BEGIN CERTIFICATE", Self.home, "MACDOWS_", "fixture-knob-value", "[autolaunch]", "below the Standard floor"] {
            #expect(!output.text.contains(absent), "\(absent)")
        }
    }

    @Test("a_include lets account segments and key-witness lines through for this export -- and nothing else")
    func exportIncludingAccountAndKeyWitness() {
        let output = DiagnosticExport.render(Self.fixtureEntries(), evicted: 0, includeAccountAndKeyWitness: true,
                                             homeDirectory: Self.home, exportedAt: Date(timeIntervalSince1970: 1_800_000_100),
                                             timeZone: TimeZone(identifier: "UTC")!)
        #expect(output.text.contains("# Account names and key-witness lines: included"))
        #expect(output.text.contains("freerdp com.freerdp.client.macdows [key-witness] seq=1 kind=scancode"))
        #expect(output.text.contains("[connect] start user=fixture-account host=pc.example"))
        for absent in ["BEGIN CERTIFICATE", Self.home, "MACDOWS_", "fixture-knob-value", "[autolaunch]", "below the Standard floor", "an info-level App line"] {
            #expect(!output.text.contains(absent), "\(absent)")
        }
        #expect(output.exportedCount == 5 && output.withheldCount == 5)
        #expect(output.text.hasSuffix("# 5 lines not exported\n"))
    }

    @Test("the [key-witness] shape is registered as its own class, so the default export withholds it")
    func keyWitnessIsInTheDefaultWithheldClass() {
        let shape = DiagnosticExportFilter.registered.first { $0.messagePrefix == "[key-witness] " }
        #expect(shape?.lineClass == .keyWitness && shape?.source == .freerdp && shape?.tag == DiagnosticExportFilter.bridgeTag)
        let witness = Line(source: .freerdp, level: .info, tag: DiagnosticExportFilter.bridgeTag, message: "[key-witness] seq=9 kind=unicode flags=0x0000 rc=1")
        let output = DiagnosticExport.render([DiagnosticLogBuffer.Entry(date: Date(), line: witness)], evicted: 0,
                                             includeAccountAndKeyWitness: false, homeDirectory: nil, exportedAt: Date())
        #expect(output.exportedCount == 0 && output.withheldCount == 1)
    }

    @Test("an empty buffer still produces the header and the footer")
    func exportEmpty() {
        let output = DiagnosticExport.render(DiagnosticLogBuffer(capacity: 4), includeAccountAndKeyWitness: false)
        #expect(output.text.hasSuffix("# 0 lines not exported\n"))
        #expect(output.exportedCount == 0)
    }

    @Test("the file is written owner-only, replaces an existing file, and leaves no temporary file behind")
    func exportFileWrite() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macdows-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("diagnostics.txt")
        try Data("old".utf8).write(to: url)
        let output = DiagnosticExport.render(Self.fixtureEntries(), evicted: 0, includeAccountAndKeyWitness: false,
                                             homeDirectory: Self.home, exportedAt: Date())
        try DiagnosticExport.write(output, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == output.text)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["diagnostics.txt"])
        #expect(throws: (any Error).self) {
            try DiagnosticExport.write(output, to: folder.appendingPathComponent("missing/diagnostics.txt"))
        }
    }

    // MARK: - WLog callback appender

    @Test("the callback writes an INFO line to stdout in WinPR's console layout and hands it to the sink")
    func callbackKeepsStdoutAndFeedsTheSink() throws {
        let tag = "com.macdows.test.diag\(UInt32.random(in: 0..<UInt32.max))"
        #expect(CRSession.attachProcessLogCallbacks(toLoggerNamed: tag))
        let sink = DiagSinkLines()
        CRSession.setProcessLogLineSink { level, tag, message in sink.add(level, tag, message) }
        defer { CRSession.setProcessLogLineSink(nil) }

        let infoMarker = "diag-info-\(UUID().uuidString)"
        let stdout = diagCapture(fd: 1) {
            #expect(DiagWinPR.log(tag: tag, level: 2, function: "diagFunction", message: infoMarker))
        }
        let printed = try #require(stdout.split(separator: "\n").map(String.init).first { $0.contains(infoMarker) })
        // WinPR's default layout, "[%hr:%mi:%se:%ml] [%pid:%tid] [%lv][%mn] - [%fn]: " + text.
        let shape = try Regex(#"^\[[0-9:]+\] \[[0-9]+:[0-9a-fA-F]+\] \[INFO\]\[([^\]]+)\] - \[diagFunction\]: (.+)$"#)
        let match = try #require(try shape.wholeMatch(in: printed))
        #expect(match.output[1].substring.map(String.init) == tag)
        #expect(match.output[2].substring.map(String.init) == infoMarker)
        let received = sink.matching(infoMarker)
        #expect(received.count == 1)
        #expect(received.first?.0 == 2 && received.first?.1 == tag && received.first?.2 == infoMarker)

        let warnMarker = "diag-warn-\(UUID().uuidString)"
        var stdoutDuringWarn = ""
        let stderr = diagCapture(fd: 2) {
            stdoutDuringWarn = diagCapture(fd: 1) {
                #expect(DiagWinPR.log(tag: tag, level: 3, function: "diagFunction", message: warnMarker))
            }
        }
        #expect(stderr.contains("[WARN][\(tag)] - [diagFunction]: \(warnMarker)"), "WARN and above go to stderr, as the console appender does")
        #expect(!stdoutDuringWarn.contains(warnMarker))
        #expect(sink.matching(warnMarker).first?.0 == 3)
    }

    @Test("with no sink attached the callback still writes stdout and drops nothing it should print")
    func callbackWithoutSink() throws {
        let tag = "com.macdows.test.nosink\(UInt32.random(in: 0..<UInt32.max))"
        #expect(CRSession.attachProcessLogCallbacks(toLoggerNamed: tag))
        CRSession.setProcessLogLineSink(nil)
        let marker = "diag-nosink-\(UUID().uuidString)"
        let stdout = diagCapture(fd: 1) {
            #expect(DiagWinPR.log(tag: tag, level: 2, function: "f", message: marker))
        }
        #expect(stdout.contains("[INFO][\(tag)] - [f]: \(marker)"))
    }

    @Test("source: the callback's stdout half is the console appender's write, the appender is CALLBACK with a console fallback")
    func callbackSourceShape() throws {
        let code = diagCodeOnly(try diagSource("App/CRBridge/CRSession.mm"))
        let start = try #require(code.range(of: "static BOOL crb_wlog_text_message(const wLogMessage *msg) {"))
        let end = try #require(code.range(of: "return TRUE; }", range: start.upperBound..<code.endIndex))
        let body = String(code[start.lowerBound..<end.upperBound])
        let write = try #require(body.range(of: "FILE *fp = (msg->Level <= WLOG_INFO) ? stdout : stderr; (void)fprintf(fp, \"%s%s\\n\", prefix, msg->TextString);"))
        let sink = try #require(body.range(of: "sink((NSInteger)msg->Level,"))
        #expect(write.upperBound <= sink.lowerBound, "stdout first, then the copy")
        #expect(body.contains("if (msg->Level == WLOG_OFF) return TRUE;"))

        let attachStart = try #require(code.range(of: "static BOOL crb_attach_process_log_callbacks(wLog *log) {"))
        let attachEnd = try #require(code.range(of: "return TRUE; }", range: attachStart.upperBound..<code.endIndex))
        let attach = String(code[attachStart.lowerBound..<attachEnd.upperBound])
        #expect(attach.contains("WLog_SetLogAppenderType(log, WLOG_APPENDER_CALLBACK)"))
        #expect(attach.contains("callbacks.message = crb_wlog_text_message;"))
        #expect(attach.contains("WLog_ConfigureAppender(appender, \"callbacks\", &callbacks)"))
        #expect(attach.contains("(void)WLog_SetLogAppenderType(log, WLOG_APPENDER_CONSOLE); return FALSE;"), "an unconfigured CALLBACK appender would swallow stdout")
        #expect(diagOccurrences(of: "crb_attach_process_log_callbacks(", in: code) == 3, "definition, root, test logger")
    }

    @Test("main.swift attaches the buffer once, right after the WinPR configuration; the CLI harnesses keep WinPR's console default")
    func attachmentAndHarnesses() throws {
        let main = diagCodeOnly(try diagSource("App/Macdows/main.swift"))
        let pin = try #require(main.range(of: "CRSession.pinProcessLogConfiguration()"))
        let attach = try #require(main.range(of: "DiagnosticLogBuffer.shared.attachProcessLog()"))
        let run = try #require(main.range(of: "let app = NSApplication.shared"))
        #expect(pin.upperBound <= attach.lowerBound && attach.upperBound <= run.lowerBound)
        #expect(diagOccurrences(of: "attachProcessLog()", in: main) == 1)
        for tool in ["Tools/window-smoke", "Tools/bridge-smoke"] {
            let root = diagRepoRoot().appendingPathComponent(tool)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where ["swift", "m", "mm"].contains(url.pathExtension) {
                let code = try String(contentsOf: url, encoding: .utf8)
                #expect(!code.contains("pinProcessLogConfiguration") && !code.contains("setProcessLogLineSink"), "\(url.lastPathComponent)")
            }
        }
    }
}
