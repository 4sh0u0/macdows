import AppKit
import Foundation
import MacdowsCore
import Testing

// UI slice ④ commit 2 (UI-1 spec §4.2 / §4.3 / §7.1): the session banners -- the connection banner
// (waiting / reconnecting / gave up) and the input-method banner -- and the Remote windows note.
// The decisions are offline here (`ShellReconnectPresenter`'s banner models, `InputCapabilityNotice`,
// the Hosts window's banner area); the App's wiring of them is pinned as source at the end, the
// bundle cannot compile `AppDelegate` (see `AppDelegateSessionEndPinTests`).

private func bannerAppDelegateCode() throws -> String {
    let raw = try String(contentsOf: shellCatalogRepoRoot().appendingPathComponent("App/Macdows/AppDelegate.swift"), encoding: .utf8)
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let marker = line.range(of: "//") else { return line }
        return line[line.startIndex..<marker.lowerBound]
    }
    return lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func bannerOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@MainActor
@Suite("UI slice ④ — the connection banner, the input-method banner and the Remote windows note (UI-1 §4.2 / §4.3)")
struct SessionBannerTests {
    private typealias P = ShellReconnectPresenter
    private static let host = "workstation.example"

    private static func banner(_ state: ReconnectDriver.State, _ language: String = "en") throws -> P.SessionBanner? {
        P.connectionBanner(for: state, hostTitle: host, text: try .catalog(language))
    }

    // MARK: - the model table

    @Test("connection banner: one id, warning while retrying, error after giving up, none when idle / live / certificate")
    func connectionBannerTable() throws {
        #expect(try Self.banner(.idle) == nil)
        #expect(try Self.banner(.live) == nil)
        #expect(try Self.banner(.gaveUp(.certificateRejected(unsupportedRoute: false))) == nil, "ADR-0024 D-5: the certificate path's banner")
        #expect(try Self.banner(.gaveUp(.certificateRejected(unsupportedRoute: true))) == nil)
        let rows: [(ReconnectDriver.State, P.SessionBanner.Tone, [P.SessionBanner.Action])] = [
            (.waiting(attempt: 1, delay: .seconds(2)), .warning, [.disconnect]),
            (.reconnecting(attempt: 1), .warning, [.disconnect]),
            (.gaveUp(.policy(.attemptsExhausted)), .error, [.dismiss, .reconnect]),
            (.gaveUp(.refusedByBridge(code: -3)), .error, [.dismiss, .reconnect]),
            (.gaveUp(.policyRefused(attemptIndex: 2)), .error, [.dismiss, .reconnect]),
        ]
        for (state, tone, actions) in rows {
            let banner = try #require(try Self.banner(state), "\(state)")
            #expect(banner.id == P.connectionBannerID, "\(state)")
            #expect(banner.tone == tone, "\(state)")
            #expect(banner.actions == actions, "UI-1 §4.2: waiting / reconnecting = Disconnect; gaveUp = Dismiss / Reconnect (\(state))")
        }
    }

    /// The artboard (Session-Disconnected): while retrying the title is the state's own status text
    /// over `d_retry_b`; after giving up, `d_gx_*` / `d_gr_*` with the host name filled in. Each
    /// cell below is the UI-1 table's, in three languages.
    @Test("connection banner texts reproduce the UI-1 table in en / zh-Hans / ja")
    func connectionBannerTexts() throws {
        let rows: [(ReconnectDriver.State, [(String, String)])] = [
            (.waiting(attempt: 1, delay: .seconds(2)), [
                ("Connection lost · Reconnecting (attempt 2 of 4) in 2.0 s",
                 "Remote windows come back when the connection does. Your Windows session should still be running on the host."),
                ("连接中断 · 2.0 秒后第 2 次重连（共 4 次）", "连接恢复后，远程窗口也会回来。你的 Windows 会话应仍在主机上运行。"),
                ("接続が切れました · 2.0 秒後に再接続（4 回中 2 回目）", "接続が戻るとリモートウインドウも戻ります。Windows のセッションはホスト上でまだ実行中のはずです。"),
            ]),
            (.gaveUp(.policy(.attemptsExhausted)), [
                ("Couldn’t reconnect after 4 attempts",
                 "workstation.example didn’t answer 4 reconnect attempts. The Windows session should still be running on the host; Reconnect starts a new connection to it."),
                ("4 次重连均未成功", "workstation.example 没有响应 4 次重连。Windows 会话应仍在主机上运行；“重新连接”会新建一个到它的连接。"),
                ("4 回再接続できませんでした", "workstation.example は 4 回の再接続に応答しませんでした。Windows のセッションはホスト上でまだ実行中のはずです。「再接続」で新しく接続します。"),
            ]),
            (.gaveUp(.refusedByBridge(code: -3)), [
                ("The host refused the connection",
                 "workstation.example refused the reconnect, so Macdows stopped without trying again. The Windows session should still be running on the host; Reconnect tries once more."),
                ("主机拒绝了连接", "workstation.example 拒绝了重连，因此 Macdows 未再重试就停止了。Windows 会话应仍在主机上运行；“重新连接”会再试一次。"),
                ("ホストが接続を拒否しました", "workstation.example が再接続を拒否したため、Macdows は再試行せずに停止しました。Windows のセッションはホスト上でまだ実行中のはずです。「再接続」でもう一度試します。"),
            ]),
        ]
        for (state, cells) in rows {
            for (language, cell) in zip(["en", "zh-Hans", "ja"], cells) {
                let banner = try #require(try Self.banner(state, language))
                #expect(banner.title == cell.0, "\(state) \(language)")
                #expect(banner.body == cell.1, "\(state) \(language)")
            }
        }
        let re = try #require(try Self.banner(.reconnecting(attempt: 1), "ja"))
        #expect(re.title == "接続が切れました · 再接続中（4 回中 2 回目）…")
        for language in ["en", "zh-Hans", "ja"] {
            for state: ReconnectDriver.State in [.waiting(attempt: 0, delay: .seconds(1)), .gaveUp(.policy(.attemptsExhausted)), .gaveUp(.policyRefused(attemptIndex: 1))] {
                let banner = try #require(try Self.banner(state, language))
                for token in ["exhausted", "refused-by-bridge", "policy-refused", "<missing:"] {
                    #expect(!banner.title.contains(token) && !banner.body.contains(token), "\(state) \(language) \(token)")
                }
            }
        }
    }

    @Test("input-method banner: dg_u_t / dg_u_b with the host, information tone, Learn More and Dismiss (named dg_u_x), in three languages")
    func inputBanner() throws {
        let names = ["Dismiss input method notice", "关闭输入法提示", "入力メソッドの通知を閉じる"]
        let cells = [
            ("Input method text can’t be sent to this host",
             "workstation.example didn’t accept Unicode input, so text from input methods (for example Chinese or Japanese) and the Character Viewer is not sent. Typing with your keyboard layout still works."),
            ("无法向此主机发送输入法文本",
             "workstation.example 未接受 Unicode 输入，因此输入法（例如中文或日文）与字符检视器中的文本不会发送。按键盘布局直接键入仍然可用。"),
            ("このホストには入力メソッドのテキストを送信できません",
             "workstation.example が Unicode 入力を受け付けなかったため、入力メソッド（中国語や日本語など）と文字ビューアのテキストは送信されません。キーボード配列での入力は引き続き使えます。"),
        ]
        for (index, (language, cell)) in zip(["en", "zh-Hans", "ja"], cells).enumerated() {
            let banner = P.inputBanner(hostTitle: Self.host, text: try .catalog(language))
            #expect(banner.id == P.inputBannerID)
            #expect(banner.tone == .information, "the artboard's info-b: information is not tinted (UI-1 §3)")
            #expect(banner.actions == [.learnMore, .dismiss])
            #expect(banner.dismissAccessibilityLabel == names[index], "\(language)")
            #expect(banner.title == cell.0 && banner.body == cell.1, "\(language)")
        }
        #expect(P.inputBannerID != P.connectionBannerID)
        for state: ReconnectDriver.State in [.waiting(attempt: 0, delay: .seconds(1)), .gaveUp(.policy(.attemptsExhausted))] {
            #expect(try Self.banner(state)?.dismissAccessibilityLabel == nil, "only the input-method banner names its Dismiss")
        }
    }

    @Test("Remote windows note: wn_retry while retrying, wn_gx / wn_gr after giving up, hidden otherwise")
    func remoteWindowsNote() throws {
        let text = try ShellText.catalog("zh-Hans")
        #expect(P.remoteWindowsNote(for: .waiting(attempt: 0, delay: .seconds(1)), text: text) == "连接中断期间远程窗口会关闭；重新连接后，主机再次发送时它们会重新出现。")
        #expect(P.remoteWindowsNote(for: .reconnecting(attempt: 0), text: text) == P.remoteWindowsNote(for: .waiting(attempt: 3, delay: .seconds(8)), text: text))
        #expect(P.remoteWindowsNote(for: .gaveUp(.policy(.attemptsExhausted)), text: text) == "没有远程窗口。Windows 会话应仍在主机上运行；“连接”会新建一个到它的连接。")
        #expect(P.remoteWindowsNote(for: .gaveUp(.refusedByBridge(code: -1)), text: text) == "没有远程窗口。主机拒绝了连接，因此 Macdows 没有重试。“连接”会再试一次。")
        for state: ReconnectDriver.State? in [nil, .idle, .live, .gaveUp(.certificateRejected(unsupportedRoute: false))] {
            #expect(P.remoteWindowsNote(for: state, text: text) == nil, "\(String(describing: state))")
        }
    }

    @Test("every banner / note key the presenter names is in the catalog in three languages, its fallback the en value")
    func bannerKeysInCatalog() throws {
        let strings = try shellCatalogStrings()
        for key in ["d_retry_b", "d_gx_t", "d_gx_b", "d_gr_t", "d_gr_b", "wn_retry", "wn_gx", "wn_gr", "dg_u_t", "dg_u_b", "dg_u_x", "learn_more", "reconnect", "rw_h"] {
            for language in ["en", "zh-Hans", "ja"] {
                #expect(!(shellCatalogValue(strings, key, language) ?? "").isEmpty, "\(key) \(language)")
            }
        }
        // Every key resolved in a fallback-carrying call is in the catalog with that en value
        // (`MainMenuTests.stringCatalogCoversEveryTitle` checks the same over every App source).
        #expect(P.connectionBanner(for: .gaveUp(.policy(.attemptsExhausted)), hostTitle: "H")?.title == "Couldn’t reconnect after 4 attempts",
                "the test bundle has no compiled catalog, so .main shows the en fallback")
    }

    // MARK: - the buttons

    @Test("the banner buttons: Disconnect / Dismiss / Reconnect / Learn More titles, in order, each calling its own handler")
    func bannerButtons() throws {
        var calls: [String] = []
        func model(_ banner: P.SessionBanner) -> BannerView.Model {
            .session(banner,
                     disconnect: { calls.append("disconnect") }, dismiss: { calls.append("dismiss") }, reconnect: { calls.append("reconnect") },
                     learnMore: { calls.append("learnMore") })
        }
        func model(_ state: ReconnectDriver.State) throws -> BannerView.Model {
            model(try #require(P.connectionBanner(for: state, hostTitle: "H")))
        }
        let retrying = BannerView(try model(.reconnecting(attempt: 0)))
        #expect(retrying.buttons.map(\.title) == [UIStrings.disconnect])
        #expect(retrying.model.tone == .warning)
        retrying.buttons.forEach { $0.performClick(nil) }
        #expect(calls == ["disconnect"])

        calls = []
        let gaveUp = BannerView(try model(.gaveUp(.refusedByBridge(code: -3))))
        #expect(gaveUp.buttons.map(\.title) == [UIStrings.dismiss, UIStrings.reconnect])
        #expect(gaveUp.model.tone == .error)
        gaveUp.buttons.forEach { $0.performClick(nil) }
        #expect(calls == ["dismiss", "reconnect"])
        #expect(!gaveUp.buttons.map(\.title).contains(UIStrings.disconnect), "the session is gone after a give-up")
        #expect(UIStrings.reconnect == "Reconnect")
        #expect(gaveUp.buttons.first?.accessibilityLabel() != "Dismiss input method notice")

        calls = []
        let input = BannerView(model(P.inputBanner(hostTitle: "H")))
        #expect(input.buttons.map(\.title) == [UIStrings.learnMore, UIStrings.dismiss])
        #expect(input.model.tone == .information)
        #expect(input.buttons.last?.accessibilityLabel() == "Dismiss input method notice", "dg_u_x (the test bundle shows the en fallback)")
        input.buttons.forEach { $0.performClick(nil) }
        #expect(calls == ["learnMore", "dismiss"])
        #expect(UIStrings.learnMore == "Learn More")
    }

    @Test("Learn More's path: the Hosts window controller shows Settings on its Keyboard page")
    func learnMoreOpensKeyboardSettings() throws {
        _ = NSApplication.shared
        let (controller, _, _) = Self.controller()
        defer { controller.window?.orderOut(nil); controller.settings.window?.orderOut(nil) }
        controller.settings.select(.general)
        controller.showKeyboardPage()
        #expect(controller.settings.selectedPage == .keyboard)
        #expect(controller.settings.window?.isVisible == true)
    }

    // MARK: - the banner area

    private static func controller() -> (MainWindowController, NSButton, NSButton) {
        let controller = MainWindowControllerTests.controller(records: [HostRecord(displayName: "A", address: "a.example", userName: "u")])
        let connect = NSButton(title: "Connect", target: nil, action: nil)
        let disconnect = NSButton(title: "Disconnect", target: nil, action: nil)
        let title = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
        controller.installSessionControls(NSStackView(views: [title, status, connect, disconnect]), title: title, status: status,
                                          connect: connect, disconnect: disconnect)
        return (controller, connect, disconnect)
    }

    @Test("the same id replaces the banner instead of stacking a second one; another id stacks")
    func sameIDReplaces() throws {
        let (controller, _, _) = Self.controller()
        let noop: () -> Void = {}
        for state: ReconnectDriver.State in [.waiting(attempt: 0, delay: .seconds(1)), .reconnecting(attempt: 0), .gaveUp(.policy(.attemptsExhausted))] {
            controller.showBanner(.session(try #require(P.connectionBanner(for: state, hostTitle: "A")), disconnect: noop, dismiss: noop, reconnect: noop, learnMore: noop))
        }
        #expect(controller.bannerIDs == [P.connectionBannerID])
        #expect(controller.detail.bannerStack.arrangedSubviews.count == 1)
        let shown = try #require(controller.detail.bannerStack.arrangedSubviews.first as? BannerView)
        #expect(shown.model.title == "Couldn’t reconnect after 4 attempts")
        controller.showBanner(.session(P.inputBanner(hostTitle: "A"), disconnect: noop, dismiss: noop, reconnect: noop, learnMore: noop))
        #expect(controller.bannerIDs == [P.connectionBannerID, P.inputBannerID])
        controller.removeBanner(id: P.connectionBannerID)
        #expect(controller.bannerIDs == [P.inputBannerID], "live removes the connection banner and leaves the others")
    }

    @Test("the banner's Disconnect presses the App's Disconnect button only while it is enabled")
    func disconnectPressesTheButton() {
        final class Target: NSObject {
            var presses = 0
            @objc func press(_ sender: Any?) { presses += 1 }
        }
        let (controller, _, disconnect) = Self.controller()
        let target = Target()
        disconnect.target = target
        disconnect.action = #selector(Target.press(_:))
        disconnect.isEnabled = false
        controller.disconnectSession()
        #expect(target.presses == 0, "no session to end")
        disconnect.isEnabled = true
        controller.disconnectSession()
        #expect(target.presses == 1)
    }

    @Test("the Remote windows card shows only with a note, above Edit / Remove")
    func remoteWindowsCard() {
        let (controller, _, _) = Self.controller()
        #expect(controller.detail.remoteWindowsCard.isHidden)
        controller.setRemoteWindowsNote("note")
        #expect(!controller.detail.remoteWindowsCard.isHidden)
        #expect(controller.detail.remoteWindowsNote.stringValue == "note")
        let order = controller.detail.detailStack.arrangedSubviews
        let card = order.firstIndex { $0 === controller.detail.remoteWindowsCard }
        #expect(card == 1, "after the session controls (index 0)")
        controller.setRemoteWindowsNote(nil)
        #expect(controller.detail.remoteWindowsCard.isHidden)
    }

    @Test("§7.1: only a newly arriving banner is pushed in, over 0.2 s, and Reduce Motion turns it off")
    func pushTransition() throws {
        #expect(HostDetailViewController.bannerPushDuration == 0.2)
        #expect(HostDetailViewController.arrivingBannerIDs(now: ["a", "b"], before: ["a"]) == ["b"])
        #expect(HostDetailViewController.arrivingBannerIDs(now: ["a"], before: ["a"]).isEmpty, "a replacement under the same id does not move")
        #expect(HostDetailViewController.arrivingBannerIDs(now: [], before: ["a"]).isEmpty)
        let code = try String(contentsOf: shellCatalogRepoRoot().appendingPathComponent("App/UI/Main/HostDetailViewController.swift"), encoding: .utf8)
        #expect(code.contains("!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }"))
        #expect(code.contains("context.duration = Self.bannerPushDuration"))
    }
}

// MARK: - the input capability, read once per leg

@MainActor
@Suite("UI slice ④ — the input-method notice shows once per connection leg (adr/0011 §2, UI-1 §4.3)")
struct InputCapabilityNoticeTests {
    @Test("a degraded leg shows once, reads the capability once, and a Dismiss is final for the leg")
    func oncePerLeg() {
        var notice = InputCapabilityNotice()
        var reads = 0
        let unsupported: () -> Bool = { reads += 1; return false }
        let first = notice.observe(.live, unicodeInputSupported: unsupported)
        #expect(first == true)
        #expect(notice.degraded)
        let again = notice.observe(.live, unicodeInputSupported: unsupported)
        #expect(again == false, "the same leg does not show it again")
        #expect(reads == 1, "the capability is read once per leg")
        #expect(notice.degraded, "the status bar keeps dg_bar for the leg")
    }

    @Test("the next leg (a reconnect) and the next connection read again; a supporting connection shows nothing")
    func nextLegReadsAgain() {
        var notice = InputCapabilityNotice()
        var supported = false
        var reads = 0
        let read: () -> Bool = { reads += 1; return supported }
        var shown: [Bool] = []
        shown.append(notice.observe(.live, unicodeInputSupported: read))
        shown.append(notice.observe(.waiting(attempt: 0, delay: .seconds(1)), unicodeInputSupported: read))
        #expect(!notice.degraded, "a dropped leg is not degraded any more")
        shown.append(notice.observe(.reconnecting(attempt: 0), unicodeInputSupported: read))
        shown.append(notice.observe(.live, unicodeInputSupported: read))
        #expect(shown == [true, false, false, true], "the reconnect leg reads again and shows again")
        notice.reset()
        supported = true
        let supporting = notice.observe(.live, unicodeInputSupported: read)
        #expect(!supporting, "true: nothing to show")
        #expect(!notice.degraded)
        #expect(reads == 3, "only .live reads; waiting / reconnecting never do")
        for state: ReconnectDriver.State in [.idle, .gaveUp(.policy(.attemptsExhausted))] {
            var fresh = InputCapabilityNotice()
            let result = fresh.observe(state, unicodeInputSupported: { Issue.record("read in \(state)"); return false })
            #expect(!result)
        }
    }
}

// MARK: - the App's wiring, pinned as source

@Suite("UI slice ④ — the session banners' wiring in AppDelegate, pinned as source")
struct SessionBannerWiringPinTests {
    /// The banners are written from the driver's state handler, after the Hosts window, in one
    /// place; the input capability is read once, there, through the session's property.
    ///
    /// MUST-RED for: a second banner writer, the capability read anywhere else (or the registry's
    /// gate reached from the App), a banner written before the shell, and a missing call.
    @Test("one banner writer, called from the state handler after the Hosts window; the capability read once")
    func oneWriter() throws {
        let code = try bannerAppDelegateCode()
        #expect(bannerOccurrences(of: "applySessionBanners(", in: code) == 2, "declaration and the state handler")
        #expect(bannerOccurrences(
            of: "let showInputBanner = inputNotice.observe(state) { session?.unicodeInputSupported ?? true } "
                + "if case .live = state { if liveSince == nil { liveSince = Date() } } else { liveSince = nil } applyShell(for: state)",
            in: code) == 1)
        #expect(bannerOccurrences(
            of: "applyHostsWindow(state: state, host: chainHost) applySessionBanners(for: state, showInputBanner: showInputBanner)",
            in: code) == 1)
        #expect(bannerOccurrences(of: "unicodeInputSupported", in: code) == 1)
        #expect(bannerOccurrences(of: "inputNotice.observe(", in: code) == 1)
        #expect(bannerOccurrences(of: "inputNotice.reset()", in: code) == 1, "the chain's end")
        #expect(bannerOccurrences(of: "inputDegraded: inputNotice.degraded", in: code) == 1, "the status bar's dg_bar")
    }

    /// The buttons reach paths that already exist, and the App gains no action method (adr/0020
    /// S-5): Disconnect presses the Hosts window's Disconnect button, Reconnect its Connect button
    /// for the chain's host, Dismiss removes the banner, Learn More opens Settings > Keyboard.
    @Test("the banner buttons reach existing paths; still two @objc actions and no new endSessionTapped() call")
    func buttonsReachExistingPaths() throws {
        let code = try bannerAppDelegateCode()
        #expect(bannerOccurrences(of: "disconnect: { [weak self] in self?.mainWindow.disconnectSession() }", in: code) == 1)
        #expect(bannerOccurrences(of: "dismiss: { [weak self] in self?.mainWindow.removeBanner(id: id) }", in: code) == 1)
        #expect(bannerOccurrences(of: "reconnect: { [weak self] in guard let host else { return } self?.mainWindow.connect(to: host) }", in: code) == 1)
        #expect(bannerOccurrences(of: "learnMore: { [weak self] in self?.mainWindow.showKeyboardPage() }", in: code) == 1)
        #expect(bannerOccurrences(of: "@objc", in: code) == 2)
        #expect(bannerOccurrences(of: "#selector(", in: code) == 2)
        #expect(bannerOccurrences(of: "endSessionTapped()", in: code) == 2, "the declaration and the disconnect knob only")
    }

    /// The live state removes the connection banner (the presenter returns none), the chain's end
    /// removes the input banner and -- unless it gave up -- the connection banner.
    @Test("live clears the connection banner; the chain's end clears what belonged to the connection")
    func clearing() throws {
        let code = try bannerAppDelegateCode()
        #expect(bannerOccurrences(
            of: "if let banner = ShellReconnectPresenter.connectionBanner(for: state, hostTitle: title) { "
                + "mainWindow.showBanner(sessionBannerModel(banner, host: host)) } else { "
                + "mainWindow.removeBanner(id: ShellReconnectPresenter.connectionBannerID) }",
            in: code) == 1)
        #expect(bannerOccurrences(
            of: "inputNotice.reset() mainWindow.removeBanner(id: ShellReconnectPresenter.inputBannerID) "
                + "if !gaveUp { mainWindow.removeBanner(id: ShellReconnectPresenter.connectionBannerID) }",
            in: code) == 1)
    }

    /// adr/0011 B17 (the registry's warn-once and drop counters, which the window-smoke self-test
    /// reads) is not the App's to touch: no App-side source names the registry's gate type.
    @Test("no App-side source names UnicodeInputDegradationGate")
    func theGateIsNotReached() throws {
        var scanned = 0
        for directory in ["App/Macdows", "App/UI", "App/SessionControl"] {
            let root = shellCatalogRepoRoot().appendingPathComponent(directory)
            let walker = try #require(FileManager.default.enumerator(atPath: root.path))
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                scanned += 1
                let code = try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8)
                #expect(!code.contains("UnicodeInputDegradationGate"), "\(directory)/\(entry)")
            }
        }
        #expect(scanned > 20)
    }
}
