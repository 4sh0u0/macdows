import Foundation
import MacdowsCore
import os

/// UI slice ③ (ADR-0024 D-8, X-b): the App's own diagnostics ring buffer -- the ONLY source the
/// diagnostics export reads. Two producers write into it:
///  - FreeRDP / WinPR lines, through the WLog callback appender `+[CRSession
///    pinProcessLogConfiguration]` installs on the root logger (`attachProcessLog()`, called once
///    by `main.swift`); the callback writes each line to stdout / stderr first, so the stdout channel
///    is unchanged and this buffer is a copy, not a redirection;
///  - the App's own log entries, through `DiagnosticLogger` (which also forwards every line to its
///    `os.Logger` unchanged).
///
/// Bounded: at most `capacity` lines are kept; the oldest go first and are only counted. Nothing in
/// it ever reaches a file except through `DiagnosticExport`, which runs every line through
/// `DiagnosticExportFilter`'s default-deny grammar. Thread-safe: every access holds one unfair lock,
/// and an append never blocks on anything else (it is called while WinPR holds its appender lock).
final class DiagnosticLogBuffer: Sendable {
    /// One kept line and when it arrived.
    struct Entry: Equatable, Sendable {
        let date: Date
        let line: DiagnosticExportFilter.Line
    }

    /// The process-wide buffer the App's loggers and the WLog callback write into.
    static let shared = DiagnosticLogBuffer(capacity: 2000)

    let capacity: Int

    private struct Ring: Sendable {
        var slots: [Entry] = []
        /// Index of the oldest entry once `slots` is full.
        var head = 0
        /// Lines pushed out by newer ones since launch.
        var evicted = 0
    }

    private let ring = OSAllocatedUnfairLock(initialState: Ring())

    init(capacity: Int) {
        precondition(capacity > 0, "a ring buffer needs at least one slot")
        self.capacity = capacity
    }

    func append(_ line: DiagnosticExportFilter.Line, at date: Date = Date()) {
        let entry = Entry(date: date, line: line)
        let capacity = self.capacity
        ring.withLock { ring in
            if ring.slots.count < capacity {
                ring.slots.append(entry)
            } else {
                ring.slots[ring.head] = entry
                ring.head = (ring.head + 1) % capacity
                ring.evicted += 1
            }
        }
    }

    /// The kept lines, oldest first.
    func snapshot() -> [Entry] {
        ring.withLock { ring in
            Array(ring.slots[ring.head...] + ring.slots[..<ring.head])
        }
    }

    /// How many lines newer ones have pushed out since launch.
    var evictedCount: Int {
        ring.withLock { $0.evicted }
    }

    /// Empties the buffer (tests).
    func removeAll() {
        ring.withLock { $0 = Ring() }
    }

    /// Points the bridge's process log sink at this buffer: every FreeRDP / WinPR text line the
    /// root logger's callback receives is appended as a `.freerdp` line with WinPR's level, the
    /// logger name and the text. Lines whose level is outside WinPR's TRACE … FATAL are dropped.
    func attachProcessLog() {
        CRSession.setProcessLogLineSink { [self] level, tag, message in
            guard let level = DiagnosticExportFilter.Level(rawValue: level) else { return }
            append(DiagnosticExportFilter.Line(source: .freerdp, level: level, tag: tag, message: message))
        }
    }
}
