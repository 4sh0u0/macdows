import Foundation
import MacdowsCore
import Testing

// ADR-0025 §3.1 item 7: `AppLauncher` offline -- a counting stub for the session, a hand-cranked
// clock for the timeout. What is pinned: the gate (every driver state but `.live` sends nothing),
// the local limit and its key mapping (ruling R-a1-1), matching by echo without case, unrequested
// results only counted, the timeout, and the session end dropping everything pending.

@MainActor
private final class StubSender: LaunchSending {
    var calls: [(program: String, arguments: String?)] = []

    func launchProgram(_ program: String, arguments: String?) {
        calls.append((program, arguments))
    }
}

@MainActor
private final class HandClock: ReconnectClock {
    final class Ticket: ReconnectClockTicket {
        var cancelled = false
        let body: @MainActor () -> Void
        let delay: Duration

        init(delay: Duration, body: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.body = body
        }

        func cancel() {
            cancelled = true
        }
    }

    var tickets: [Ticket] = []

    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) -> any ReconnectClockTicket {
        let ticket = Ticket(delay: delay, body: body)
        tickets.append(ticket)
        return ticket
    }

    /// Fires every ticket that is still live.
    func fireAll() {
        for ticket in tickets where !ticket.cancelled {
            ticket.cancelled = true
            ticket.body()
        }
    }
}

@MainActor
@Suite("AppLauncher (ADR-0025 §1.6 / §3.1 item 7)")
struct AppLauncherTests {
    private static let host = HostID()
    private static let notepad = #"C:\Windows\System32\notepad.exe"#

    private static func make(state: ReconnectDriver.State? = .live, hasSession: Bool = true)
        -> (AppLauncher, StubSender, HandClock, LaunchTestBox<[(AppLauncher.Request, AppLauncher.Outcome)]>) {
        let clock = HandClock()
        let launcher = AppLauncher(timeout: .seconds(8), clock: clock)
        let sender = StubSender()
        let outcomes = LaunchTestBox<[(AppLauncher.Request, AppLauncher.Outcome)]>([])
        launcher.reading = { AppLauncher.Reading(hasSession: hasSession, state: state, host: Self.host) }
        launcher.sender = { sender }
        launcher.onOutcome = { outcomes.value.append(($0, $1)) }
        return (launcher, sender, clock, outcomes)
    }

    @Test("live is .live only: idle, waiting, reconnecting, gaveUp and no driver are not live")
    func onlyLiveIsLive() {
        #expect(AppLauncher.isLive(.live))
        let notLive: [ReconnectDriver.State?] = [nil, .idle, .waiting(attempt: 0, delay: .seconds(1)), .reconnecting(attempt: 1),
                                                 .gaveUp(.policy(.attemptsExhausted)), .gaveUp(.refusedByBridge(code: -1))]
        for state in notLive {
            #expect(!AppLauncher.isLive(state), "\(String(describing: state))")
        }
    }

    @Test("a closed gate sends nothing: every non-live state, and live without a session")
    func closedGateNeverCallsTheBridge() {
        let cases: [(ReconnectDriver.State?, Bool)] = [
            (nil, true), (.idle, true), (.waiting(attempt: 0, delay: .seconds(1)), true), (.reconnecting(attempt: 0), true),
            (.gaveUp(.policy(.attemptsExhausted)), true), (.live, false), (nil, false),
        ]
        for (state, hasSession) in cases {
            let (launcher, sender, clock, _) = Self.make(state: state, hasSession: hasSession)
            #expect(launcher.launch(text: "notepad.exe", origin: .runField) == .notLive)
            #expect(launcher.launch(program: Self.notepad, arguments: "", origin: .dockMenu) == .notLive)
            #expect(sender.calls.isEmpty, "\(String(describing: state)) session=\(hasSession)")
            #expect(clock.tickets.isEmpty && launcher.pendingRequests.isEmpty)
        }
    }

    @Test("live: one send through launchProgram, arguments nil when there are none, and a timer per send")
    func liveSends() throws {
        let (launcher, sender, clock, _) = Self.make()
        guard case .sent(let first) = launcher.launch(text: #""C:\Tools\Example.exe" /open "a b.txt""#, origin: .runField) else {
            Issue.record("not sent"); return
        }
        #expect(first.host == Self.host && first.origin == .runField)
        #expect(first.command == RunCommand(program: #"C:\Tools\Example.exe"#, arguments: #"/open "a b.txt""#))
        _ = launcher.launch(program: Self.notepad, arguments: "", origin: .row(UUID()))
        #expect(sender.calls.count == 2)
        #expect(sender.calls[0].program == #"C:\Tools\Example.exe"# && sender.calls[0].arguments == #"/open "a b.txt""#)
        #expect(sender.calls[1].program == Self.notepad && sender.calls[1].arguments == nil)
        #expect(clock.tickets.map(\.delay) == [.seconds(8), .seconds(8)])
        #expect(launcher.pendingRequests.count == 2)
    }

    @Test("ruling R-a1-1: local refusals send nothing and map exhaustively to keys")
    func localRefusals() {
        let (launcher, sender, _, _) = Self.make()
        #expect(launcher.launch(text: String(repeating: "a", count: 256), origin: .runField) == .refused(reasonKey: "sp_r_long"))
        #expect(launcher.launch(text: String(repeating: "a", count: 200) + " " + String(repeating: "b", count: 55), origin: .runField)
                == .refused(reasonKey: "sp_r_args_long"))
        #expect(launcher.launch(text: "   ", origin: .runField) == .refused(reasonKey: nil))
        #expect(launcher.launch(program: "a\u{0}b", arguments: "", origin: .dockMenu) == .refused(reasonKey: "sp_r_unknown"))
        #expect(sender.calls.isEmpty)
        #expect(AppLauncher.reasonKey(for: .tooLongPath) == "sp_r_long")
        #expect(AppLauncher.reasonKey(for: .tooLongWithArguments) == "sp_r_args_long")
        #expect(AppLauncher.reasonKey(for: .empty) == nil)
        #expect(AppLauncher.reasonKey(for: .embeddedNul) == "sp_r_unknown")
        #expect(RunCommandRejection.allCases.count == 4, "a new rejection must be mapped here too")
    }

    @Test("a result is matched by the echoed program without case; S_OK succeeds, other codes fail with their key")
    func matchingByEcho() throws {
        let (launcher, _, clock, outcomes) = Self.make()
        guard case .sent(let request) = launcher.launch(program: Self.notepad, arguments: "x.txt", origin: .dockMenu) else {
            Issue.record("not sent"); return
        }
        launcher.handleExecResult(execResult: 0, rawResult: 0, program: #"c:\windows\system32\NOTEPAD.EXE"#)
        #expect(outcomes.value.count == 1)
        #expect(outcomes.value.first?.0 == request && outcomes.value.first?.1 == .succeeded)
        #expect(clock.tickets.first?.cancelled == true, "the result cancels the timeout")
        #expect(launcher.pendingRequests.isEmpty)

        _ = launcher.launch(text: "missing.exe", origin: .runField)
        launcher.handleExecResult(execResult: 5, rawResult: 2, program: "MISSING.exe")
        #expect(outcomes.value.last?.1 == .failed(reasonKey: "sp_r_nf"))
        _ = launcher.launch(text: "odd.exe", origin: .runField)
        launcher.handleExecResult(execResult: 4, rawResult: 0, program: "odd.exe")
        #expect(outcomes.value.last?.1 == .failed(reasonKey: "sp_r_unknown"))
    }

    @Test("an unrequested result (the ARC_COMPLETED re-send) is only counted: no outcome, nothing pending changes")
    func unrequestedResultsAreOnlyCounted() {
        let (launcher, _, clock, outcomes) = Self.make()
        _ = launcher.launch(program: Self.notepad, arguments: "", origin: .row(UUID()))
        let pendingBefore = launcher.pendingRequests
        launcher.handleExecResult(execResult: 0, rawResult: 0, program: #"C:\Windows\System32\winver.exe"#)
        launcher.handleExecResult(execResult: 5, rawResult: 2, program: "other.exe")
        #expect(launcher.unmatchedResults == 2)
        #expect(outcomes.value.isEmpty)
        #expect(launcher.pendingRequests == pendingBefore)
        #expect(clock.tickets.allSatisfy { !$0.cancelled })
    }

    @Test("two pending launches of one program: the oldest is matched first (no FIFO across programs)")
    func oldestOfTheSameProgramFirst() throws {
        let (launcher, _, _, outcomes) = Self.make()
        guard case .sent(let first) = launcher.launch(program: Self.notepad, arguments: "a", origin: .dockMenu),
              case .sent(let second) = launcher.launch(program: Self.notepad, arguments: "b", origin: .dockMenu) else {
            Issue.record("not sent"); return
        }
        launcher.handleExecResult(execResult: 0, rawResult: 0, program: Self.notepad)
        #expect(outcomes.value.map(\.0.id) == [first.id])
        #expect(launcher.pendingRequests.map(\.id) == [second.id])
    }

    @Test("no result within the timeout: timedOut, and a result after that is unrequested")
    func timeout() {
        let (launcher, _, clock, outcomes) = Self.make()
        _ = launcher.launch(program: Self.notepad, arguments: "", origin: .runField)
        clock.fireAll()
        #expect(outcomes.value.map(\.1) == [.timedOut])
        #expect(launcher.pendingRequests.isEmpty)
        launcher.handleExecResult(execResult: 0, rawResult: 0, program: Self.notepad)
        #expect(outcomes.value.count == 1)
        #expect(launcher.unmatchedResults == 1)
        #expect(AppLauncher.timeoutReasonKey == "sp_r_timeout")
    }

    @Test("the session ended: everything pending is dropped, timers cancelled, no outcome")
    func cancelAll() {
        let (launcher, _, clock, outcomes) = Self.make()
        _ = launcher.launch(program: Self.notepad, arguments: "", origin: .runField)
        _ = launcher.launch(program: "calc.exe", arguments: "", origin: .runField)
        launcher.cancelAll()
        #expect(launcher.pendingRequests.isEmpty)
        #expect(clock.tickets.allSatisfy { $0.cancelled })
        clock.fireAll()
        #expect(outcomes.value.isEmpty)
    }

    @Test("no session object: the gate's answer is not live and nothing is pending")
    func noSender() {
        let (launcher, _, clock, _) = Self.make()
        launcher.sender = { nil }
        #expect(launcher.launch(text: "notepad.exe", origin: .runField) == .notLive)
        #expect(clock.tickets.isEmpty && launcher.pendingRequests.isEmpty)
    }
}

/// A reference cell for closures in tests.
@MainActor
final class LaunchTestBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
