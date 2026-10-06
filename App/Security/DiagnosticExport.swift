import Foundation
import MacdowsCore

/// UI slice ③ (ADR-0024 D-8, X-b; UI-1 spec §5.5): the diagnostics export pipeline -- ring buffer
/// -> `DiagnosticExportFilter` (default-deny line grammar) -> a text file. The Settings window's
/// Export Diagnostics… is its only caller; this type has no UI and makes no decision of its own
/// about which line may leave: every line goes through the filter, one at a time, and a line the
/// filter withholds is only counted.
///
/// File shape (plain UTF-8 text, owner-only permissions):
///
///     # Macdows diagnostics
///     # Exported: <ISO 8601 time>
///     # Log detail: Standard
///     # Account names and key-witness lines: left out | included
///     # Buffer: <n> lines kept, <m> older lines dropped
///     <ISO 8601 time> <source> <tag> <message>      one per exported line, oldest first
///     # <k> lines not exported                      always the last line (ADR-0024 D-8)
///
/// `includeAccountAndKeyWitness` is the Settings checkbox `a_include`, for this one export only.
/// It lets account segments and `[key-witness]` lines through; it cannot let through anything the
/// filter has no shape for (passwords, keychain attributes, launch-knob names / values) or PEM text.
enum DiagnosticExport {
    struct Output: Equatable, Sendable {
        let text: String
        let exportedCount: Int
        let withheldCount: Int
    }

    /// Builds the file text from `entries` (oldest first).
    static func render(_ entries: [DiagnosticLogBuffer.Entry], evicted: Int, includeAccountAndKeyWitness: Bool,
                       homeDirectory: String?, exportedAt: Date, timeZone: TimeZone = .current) -> Output {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        var lines = [
            "# Macdows diagnostics",
            "# Exported: \(formatter.string(from: exportedAt))",
            "# Log detail: Standard",
            "# Account names and key-witness lines: \(includeAccountAndKeyWitness ? "included" : "left out")",
            "# Buffer: \(entries.count) lines kept, \(evicted) older lines dropped",
        ]
        var exported = 0
        var withheld = 0
        for entry in entries {
            let result = DiagnosticExportFilter.export(
                [entry.line], includeAccountAndKeyWitness: includeAccountAndKeyWitness, homeDirectory: homeDirectory)
            withheld += result.withheld
            for line in result.exported {
                lines.append("\(formatter.string(from: entry.date)) \(line)")
                exported += 1
            }
        }
        lines.append("# \(withheld) lines not exported")
        return Output(text: lines.joined(separator: "\n") + "\n", exportedCount: exported, withheldCount: withheld)
    }

    /// Renders `buffer`'s current contents.
    static func render(_ buffer: DiagnosticLogBuffer, includeAccountAndKeyWitness: Bool,
                       homeDirectory: String? = NSHomeDirectory(), exportedAt: Date = Date()) -> Output {
        render(buffer.snapshot(), evicted: buffer.evictedCount, includeAccountAndKeyWitness: includeAccountAndKeyWitness,
               homeDirectory: homeDirectory, exportedAt: exportedAt)
    }

    /// Writes `output` to `url`: the text goes into a new file in the same folder created with
    /// owner-only permissions (0600), which is then renamed over `url` -- so the file is never
    /// readable by others, not even for a moment, and a failed write leaves `url` as it was.
    static func write(_ output: Output, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".macdows-diagnostics-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // write(2) in a loop, then close(2): this file only ever writes (ADR-0024 D-9's source pin
        // counts file-reading call shapes across the App, and a writer must not look like one).
        let bytes = Array(output.text.utf8)
        var written = 0
        var failure: Int32 = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
            }
            if count < 0 {
                if errno == EINTR { continue }
                failure = errno
                break
            }
            written += count
        }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        guard failure == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
