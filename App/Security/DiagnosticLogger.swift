import Foundation
import MacdowsCore
import os

/// UI slice ③ (ADR-0024 D-8): an App log entry point that writes each line to two places --
/// its `os.Logger` (subsystem and category exactly as before, the same level, the same text) and
/// the diagnostics ring buffer (`DiagnosticLogBuffer`) as an `.app` line tagged with the category.
///
/// Call sites keep the `os.Logger` spelling: `logger.notice("[x] n=\(n, privacy: .public)")`.
/// The interpolation is `DiagnosticLogMessage`'s, not `OSLogMessage`'s, so the text is built once
/// here and handed to both channels as one string:
///  - every interpolation marked `privacy: .public` is written as is to both channels;
///  - an interpolation that is not marked public is replaced by `<private>` in the buffer copy,
///    and the whole line goes to the unified log with `privacy: .private` (the unified log's own
///    default for dynamic strings) -- a non-public value never reaches the export file.
///
/// Levels map onto WinPR's for the export filter: debug is not buffered at all, info -> DEBUG,
/// notice -> INFO, warning -> WARN, error -> ERROR, fault -> FATAL. ADR-0024 D-8's Standard level
/// ("App `.notice` and above") is then the filter's INFO floor for `.app` shapes.
struct DiagnosticLogger: Sendable {
    let category: String
    private let logger: Logger
    private let buffer: DiagnosticLogBuffer

    init(subsystem: String, category: String, buffer: DiagnosticLogBuffer = .shared) {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
        self.buffer = buffer
    }

    /// Unified log only (never buffered: below every export level).
    func debug(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.debug("\(message.text, privacy: .public)")
        } else {
            logger.debug("\(message.text, privacy: .private)")
        }
    }

    func info(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.info("\(message.text, privacy: .public)")
        } else {
            logger.info("\(message.text, privacy: .private)")
        }
        record(message, level: .debug)
    }

    func notice(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.notice("\(message.text, privacy: .public)")
        } else {
            logger.notice("\(message.text, privacy: .private)")
        }
        record(message, level: .info)
    }

    func warning(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.warning("\(message.text, privacy: .public)")
        } else {
            logger.warning("\(message.text, privacy: .private)")
        }
        record(message, level: .warn)
    }

    func error(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.error("\(message.text, privacy: .public)")
        } else {
            logger.error("\(message.text, privacy: .private)")
        }
        record(message, level: .error)
    }

    func fault(_ message: DiagnosticLogMessage) {
        if message.isPublic {
            logger.fault("\(message.text, privacy: .public)")
        } else {
            logger.fault("\(message.text, privacy: .private)")
        }
        record(message, level: .fatal)
    }

    private func record(_ message: DiagnosticLogMessage, level: DiagnosticExportFilter.Level) {
        buffer.append(DiagnosticExportFilter.Line(source: .app, level: level, tag: category, message: message.bufferText))
    }
}

/// Privacy of one interpolated value (the `os.Logger` spelling, so call sites read the same).
enum DiagnosticLogPrivacy: Sendable {
    case `public`
    case `private`
}

/// A log line built from a string literal with interpolations (see `DiagnosticLogger`).
struct DiagnosticLogMessage: ExpressibleByStringInterpolation, Sendable {
    /// The full text, every value included -- what the unified log gets.
    let text: String
    /// The text with every non-public value replaced by `<private>` -- what the buffer gets.
    let bufferText: String
    /// True when every interpolated value was marked public.
    let isPublic: Bool

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        var bufferText = ""
        var isPublic = true

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
            bufferText.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
            bufferText += literal
        }

        mutating func appendInterpolation<T>(_ value: T, privacy: DiagnosticLogPrivacy = .private) {
            let rendered = String(describing: value)
            text += rendered
            switch privacy {
            case .public:
                bufferText += rendered
            case .private:
                bufferText += "<private>"
                isPublic = false
            }
        }
    }

    init(stringLiteral value: String) {
        text = value
        bufferText = value
        isPublic = true
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
        bufferText = stringInterpolation.bufferText
        isPublic = stringInterpolation.isPublic
    }
}
