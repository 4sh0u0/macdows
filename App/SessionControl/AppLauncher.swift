import Foundation
import MacdowsCore

/// The bridge call `AppLauncher` sends through. `CRSession` in the App; a counting stub in tests.
@MainActor
protocol LaunchSending: AnyObject {
    func launchProgram(_ program: String, arguments: String?)
}

extension CRSession: LaunchSending {}

/// ADR-0025 §1.6 (the charter's `AppLauncher`, `ARCHITECTURE.md:86`): the start panel's launch
/// layer -- gate, local limit, send, and matching each send to its ExecResult or a timeout. The
/// panel, the Dock menu and the status item are its UI clients; it knows nothing about them.
///
/// The order of one launch, and why:
///  1. The gate (`LaunchGate`): a session AND a live connection, read from the App each time. A
///     ClientExecute posted before the RAIL channel is up is dropped by the bridge with no result,
///     so a closed gate sends nothing (ADR-0025 §3.1 item 7: the stub counts).
///  2. The local limit (`RunCommandParser.validate`): the bridge's own 255-byte check, done here so
///     the panel can say which limit was hit. Its reasons map to keys exhaustively (ruling R-a1-1).
///  3. The send: `launchProgram(_:arguments:)` -- never `executeProgram(`, the unattended knob's
///     program-only call (ADR-0025 S-5) -- and a pending entry with an `execTimeout` timer.
///
/// A result is matched by the program the server echoes, case-insensitively (Windows paths), to the
/// OLDEST pending launch of that program. One that matches nothing -- the ARC_COMPLETED re-send of
/// the session's initial program brings one back on every unlock and reconnect (ADR-0025 §0(a)) --
/// is only counted: no row changes, no FIFO fallback (ADR-0025 §1.4, I-2).
///
/// Never logged: the program or the arguments (ADR-0025 §3.2 S-2). The log lines carry a request
/// number, a byte count and a result code. Nothing here activates a window (S-1): the server
/// activates the window it creates.
@MainActor
final class AppLauncher {
    /// Where a launch was asked for, so its outcome can be shown there.
    enum Origin: Equatable, Sendable {
        case row(UUID)
        case runField
        case dockMenu
    }

    /// One send.
    struct Request: Equatable, Sendable {
        let id: Int
        let host: HostID?
        let command: RunCommand
        let origin: Origin
    }

    /// How a send ended.
    enum Outcome: Equatable, Sendable {
        /// `RAIL_EXEC_S_OK`: the only outcome that writes Recent and closes the panel.
        case succeeded
        /// Any other ExecResult; the key is `ExecResultCode.reasonKey`.
        case failed(reasonKey: String)
        /// No ExecResult within `timeout` (`sp_r_timeout`).
        case timedOut
    }

    /// What `launch` did.
    enum Attempt: Equatable, Sendable {
        case sent(Request)
        /// The gate is closed: nothing was sent.
        case notLive
        /// Refused before sending; nil = say nothing (an empty command).
        case refused(reasonKey: String?)
    }

    /// What the gate reads.
    struct Reading: Equatable, Sendable {
        var hasSession: Bool
        var state: ReconnectDriver.State?
        var host: HostID?

        static let noSession = Reading(hasSession: false, state: nil, host: nil)
    }

    static let timeoutReasonKey = "sp_r_timeout"

    private struct Pending {
        let request: Request
        let ticket: any ReconnectClockTicket
    }

    private static let logger = DiagnosticLogger(subsystem: "dev.haru.macdows", category: "Launch")

    /// The App's state, read on every launch.
    var reading: () -> Reading = { .noSession }
    /// The session to send through; nil without one.
    var sender: () -> (any LaunchSending)? = { nil }
    /// Called once per sent request, when it ends.
    var onOutcome: ((Request, Outcome) -> Void)?

    let timeout: Duration
    private let clock: any ReconnectClock
    private var pending: [Pending] = []
    private var lastID = 0
    /// Results that matched no pending launch.
    private(set) var unmatchedResults = 0

    init(timeout: Duration, clock: any ReconnectClock) {
        self.timeout = timeout
        self.clock = clock
    }

    /// The requests still waiting for a result, oldest first.
    var pendingRequests: [Request] { pending.map(\.request) }

    /// ADR-0025 §3.1 item 7: live is the driver's `.live` and nothing else -- `idle` (a first
    /// connect), `waiting`, `reconnecting`, `gaveUp` and no driver are all not live.
    static func isLive(_ state: ReconnectDriver.State?) -> Bool {
        switch state {
        case .live?: true
        case .idle?, .waiting?, .reconnecting?, .gaveUp?, nil: false
        }
    }

    /// Ruling R-a1-1 (iii): a local refusal's key, exhaustively. `.embeddedNul` falls back to the
    /// unknown-result key: the Run field strips U+0000 as it is typed and the store drops stored
    /// entries that carry one, so this arm is unreachable from the UI and only stands guard.
    static func reasonKey(for rejection: RunCommandRejection) -> String? {
        switch rejection {
        case .tooLongPath: "sp_r_long"
        case .tooLongWithArguments: "sp_r_args_long"
        case .empty: nil
        case .embeddedNul: "sp_r_unknown"
        }
    }

    /// The Run field's text: split by `RunCommandParser`, then sent.
    func launch(text: String, origin: Origin) -> Attempt {
        guard let reading = openGate() else { return .notLive }
        switch RunCommandParser.parse(text) {
        case .success(let command): return send(command, reading: reading, origin: origin)
        case .failure(let rejection): return .refused(reasonKey: Self.reasonKey(for: rejection))
        }
    }

    /// A stored item's program and arguments, checked again (the file may have been edited).
    func launch(program: String, arguments: String, origin: Origin) -> Attempt {
        guard let reading = openGate() else { return .notLive }
        switch RunCommandParser.validate(program: program, arguments: arguments) {
        case .success(let command): return send(command, reading: reading, origin: origin)
        case .failure(let rejection): return .refused(reasonKey: Self.reasonKey(for: rejection))
        }
    }

    /// The registry's one ExecResult forward (ADR-0025 S-4).
    func handleExecResult(execResult: UInt32, rawResult: UInt32, program: String) {
        let key = Self.matchKey(program)
        guard let index = pending.firstIndex(where: { Self.matchKey($0.request.command.program) == key }) else {
            unmatchedResults += 1
            Self.logger.notice("[launch] result unmatched code=\(execResult, privacy: .public) count=\(self.unmatchedResults, privacy: .public)")
            return
        }
        let entry = pending.remove(at: index)
        entry.ticket.cancel()
        let code = ExecResultCode(execResult: execResult)
        Self.logger.notice("[launch] result id=\(entry.request.id, privacy: .public) code=\(execResult, privacy: .public) raw=\(rawResult, privacy: .public)")
        onOutcome?(entry.request, code.isSuccess ? .succeeded : .failed(reasonKey: code.reasonKey ?? "sp_r_unknown"))
    }

    /// The session ended: every pending launch is dropped without an outcome (its timer cancelled).
    func cancelAll() {
        for entry in pending {
            entry.ticket.cancel()
        }
        pending = []
    }

    /// Windows paths compare without case.
    static func matchKey(_ program: String) -> String {
        program.lowercased()
    }

    private func openGate() -> Reading? {
        let reading = reading()
        guard LaunchGate.canLaunch(hasSession: reading.hasSession, isLive: Self.isLive(reading.state)) else { return nil }
        return reading
    }

    private func send(_ command: RunCommand, reading: Reading, origin: Origin) -> Attempt {
        guard let session = sender() else { return .notLive }
        lastID += 1
        let request = Request(id: lastID, host: reading.host, command: command, origin: origin)
        session.launchProgram(command.program, arguments: command.arguments.isEmpty ? nil : command.arguments)
        let id = request.id
        let ticket = clock.schedule(after: timeout) { [weak self] in
            self?.expire(id)
        }
        pending.append(Pending(request: request, ticket: ticket))
        let bytes = command.payloadByteCount
        Self.logger.notice("[launch] sent id=\(id, privacy: .public) bytes=\(bytes, privacy: .public)")
        return .sent(request)
    }

    private func expire(_ id: Int) {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else { return }
        let entry = pending.remove(at: index)
        Self.logger.notice("[launch] timeout id=\(id, privacy: .public)")
        onOutcome?(entry.request, .timedOut)
    }
}
