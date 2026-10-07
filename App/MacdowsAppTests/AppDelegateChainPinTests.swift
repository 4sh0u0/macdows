import Foundation
import Testing

// UI slice ① (ADR-0024 D-2 / D-2′ / D-4 / D-5): the App's connection chain, pinned as source --
// the bundle cannot compile `AppDelegate` (see `AppDelegateSessionEndPinTests`). The decisions
// themselves are offline-tested in `ConnectFlowTests` / `CertificateDecisionTests`; what is held
// here is that the App wires them the way the ADR says.

private func chainRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Line comments removed, whitespace folded (the stripping the other AppDelegate pins use).
private func chainCodeOnly(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func chainOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("UI slice ① — the connection chain in AppDelegate (ADR-0024 D-2 / D-2′ / D-4 / D-5), pinned as source")
struct AppDelegateChainPinTests {
    static func code() throws -> String {
        chainCodeOnly(try String(contentsOf: chainRepoRoot().appendingPathComponent("App/Macdows/AppDelegate.swift"), encoding: .utf8))
    }

    static func body(of declaration: String, endingAt end: String, in code: String) throws -> String {
        let start = try #require(code.range(of: declaration), "\(declaration)")
        let stop = try #require(code.range(of: end, range: start.upperBound..<code.endIndex), "\(end)")
        return String(code[start.lowerBound..<stop.lowerBound])
    }

    @Test("D-4 Y-b: every -start is preceded by the trust snapshot of its context")
    func trustSnapshotBeforeStart() throws {
        let code = try Self.code()
        #expect(chainOccurrences(of: "newSession.acceptedCertificateFingerprint = ConnectFlow.trustSnapshot(for: context)", in: code) == 1)
        let snapshot = try #require(code.range(of: "newSession.acceptedCertificateFingerprint ="))
        let start = try #require(code.range(of: "newSession.start()"))
        #expect(snapshot.lowerBound < start.lowerBound)
        #expect(chainOccurrences(of: "acceptedCertificateFingerprint =", in: code) == 1, "one writer")
    }

    @Test("D-2: a chain's password is handed to its CRSession as bytes and wiped at once; the session is built in one place")
    func passwordBytes() throws {
        let code = try Self.code()
        #expect(chainOccurrences(of: "CRSession(", in: code) == 1)
        #expect(chainOccurrences(
            of: "let chainSession = secret.withUnsafeData { bytes in CRSession(host: record.address, user: record.userName, passwordBytes: bytes, ",
            in: code) == 1)
        let body = try Self.body(of: "private func beginChain(", endingAt: "private func beginSession(", in: code)
        let construct = try #require(body.range(of: "CRSession("))
        let wipe = try #require(body.range(of: "secret.wipe()"))
        #expect(construct.lowerBound < wipe.lowerBound)
        #expect(chainOccurrences(of: "beginSession(", in: code) == 3, "declaration, a new chain, and the re-start after a confirmation")
    }

    @Test("D-2′ (Q-a): the confirmation re-starts the SAME session and reads no credential")
    func confirmationReusesTheChain() throws {
        let code = try Self.code()
        let body = try Self.body(of: "private func answerCertificateQuestion(", endingAt: "func applicationShouldTerminateAfterLastWindowClosed(", in: code)
        #expect(body.contains("self.beginSession(review.session, record: current, context: context)"))
        for credentialRoute in ["credentialStore", "askForPassword", "ConnectFlow.preflight(", "beginChain(", "CRSession("] {
            #expect(!body.contains(credentialRoute), "the confirmation path reaches \(credentialRoute)")
        }
        #expect(body.contains("guard confirmed else { pendingReview = nil"), "Cancel drops the review, and with it the chain's session")
    }

    @Test("the drain hooks keep the ended session for the review, and the review asks about the certificate first")
    func drainThenReview() throws {
        let code = try Self.code()
        #expect(chainOccurrences(of: "self?.drainThenReview()", in: code) == 2, "the push hook and the backstop timer")
        #expect(chainOccurrences(of: "self?.drainTick()", in: code) == 0)
        #expect(chainOccurrences(
            of: "private func drainThenReview() { let ended = session isDraining = true drainTick() isDraining = false "
                + "if let ended, session == nil { reviewSessionEnd(of: ended) } }",
            in: code) == 1)
        let body = try Self.body(of: "private func reviewSessionEnd(", endingAt: "private func sessionPresenceChanged(", in: code)
        let certificate = try #require(body.range(of: "ended.lastCertificateRejection"))
        let error = try #require(body.range(of: "ended.lastConnectError"))
        #expect(certificate.lowerBound < error.lowerBound, "D-5 step 0 on the App side too")
    }

    @Test("D-3′: pin unavailable never opens a sheet and never connects")
    func pinUnavailable() throws {
        let code = try Self.code()
        let body = try Self.body(of: "private func showPinUnavailable(", endingAt: "private func showConnectFailure(", in: code)
        for route in ["presentCertificateSheet", "beginSession(", "beginChain(", "connectTapped("] {
            #expect(!body.contains(route), "\(route)")
        }
    }

    // MARK: - UI-6 gate r1 folds

    @Test("gate r1 I-2: the last window closing does not quit the App; Show Hosts, Open Macdows and a reopen bring the Hosts window back")
    func hostsWindowLifecycle() throws {
        let code = try Self.code()
        #expect(chainOccurrences(
            of: "func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }", in: code) == 1)
        #expect(chainOccurrences(
            of: "func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { "
                + "if !flag { mainWindow.showHosts(nil) } return true }", in: code) == 1)
        #expect(chainOccurrences(of: "MainMenu.bindShowHosts(in: NSApp.mainMenu, to: mainWindow)", in: code) == 1)
        #expect(chainOccurrences(of: "statusItemController.onOpenMacdows = { [weak self] in self?.mainWindow.showHosts(nil) }", in: code) == 1)
        let created = try #require(code.range(of: "mainWindow = MainWindowController("))
        let bound = try #require(code.range(of: "MainMenu.bindShowHosts("))
        #expect(created.lowerBound < bound.lowerBound, "bound once the controller exists")
        #expect(chainOccurrences(of: "@objc", in: code) == 2, "S-5: still connectTapped and endSessionTapped only")
    }

    @Test("gate r1 m-11: a Password-sheet password is recorded as remembered only when it was saved")
    func rememberFollowsTheSave() throws {
        let code = try Self.code()
        let body = try Self.body(of: "private func askForPassword(", endingAt: "private func beginChain(", in: code)
        #expect(body.contains("let saved = await ConnectChain.savePassword("))
        #expect(body.contains("if saved { current.remembersPassword = true self.hostStore.upsert(current) }"))
        #expect(chainOccurrences(of: "remembersPassword = true", in: body) == 1)
    }

    @Test("gate r1 m-13: the certificate question ends its chain's give-up flag")
    func certificateQuestionClearsGiveUp() throws {
        let code = try Self.code()
        let body = try Self.body(of: "private func presentCertificateQuestion(", endingAt: "private func answerCertificateQuestion(", in: code)
        let cleared = try #require(body.range(of: "endingByGiveUp = false"))
        let variant = try #require(body.range(of: "let variant: CertificateSheet.Variant"))
        #expect(cleared.lowerBound < variant.lowerBound, "cleared before any early return")
    }

    @Test("gate r1 m-5: no keychain work runs in a detached task; the App's keychain calls go through KeychainQueue")
    func keychainOnItsQueue() throws {
        var scanned = 0
        var queued = 0
        for directory in ["App/Macdows", "App/UI", "App/Security", "App/SessionControl"] {
            let root = chainRepoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                scanned += 1
                let code = chainCodeOnly(try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8))
                #expect(chainOccurrences(of: "Task.detached", in: code) == 0, "\(directory)/\(entry)")
                queued += chainOccurrences(of: "KeychainQueue.run", in: code)
            }
        }
        #expect(scanned > 20)
        // AppDelegate's preflight 1, ConnectChain 3, MainWindowController 3, HostOperations 2 (one
        // of them `runThrowing`).
        #expect(queued == 9, "\(queued)")
    }
}
