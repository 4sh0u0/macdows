import AppKit
import Foundation
import MacdowsCore
import Testing

// F-5 (owner, in person 2026-10-07): the en reconnect banner's text sat on the banner's top and
// bottom edges. Across a horizontal NSStackView the top / bottom `edgeInsets` are only a
// priority-250 preference, so the stack's hugging pulled the banner down onto a two-line text
// column (inset 0); a one-line column only looked right because of the 44-point minimum. Each
// banner the Hosts window shows is laid out here at 560 points wide, on the glass branch (26+, when
// the machine has it) and on the 14–25 material branch (`GlassStyle.forceLegacyMaterial`), and
// measured: the banner is as tall as its content, every item keeps the 10-point inset from both
// edges, every label is inside the banner, and a wrapping body gets the height of all its lines.

private func bannerHeightRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor
@Suite("F-5 — a banner is as tall as its content (en reconnect banner text on the edges)")
struct BannerHeightTests {
    typealias P = ShellReconnectPresenter
    static let width: CGFloat = 560
    static let host = "workstation.example"

    /// The five connection-banner states plus the input-method banner, in one language.
    static func sessionBanners(_ language: String) throws -> [(String, P.SessionBanner)] {
        let text = try ShellText.catalog(language)
        let states: [(String, ReconnectDriver.State)] = [
            ("waiting", .waiting(attempt: 1, delay: .seconds(2))),
            ("reconnecting", .reconnecting(attempt: 1)),
            ("gaveUp-exhausted", .gaveUp(.policy(.attemptsExhausted))),
            ("gaveUp-refused", .gaveUp(.refusedByBridge(code: -3))),
            ("gaveUp-policyRefused", .gaveUp(.policyRefused(attemptIndex: 2))),
        ]
        var rows: [(String, P.SessionBanner)] = []
        for (name, state) in states {
            let banner = try #require(P.connectionBanner(for: state, hostTitle: host, text: text), "\(name)")
            rows.append(("\(language)/\(name)", banner))
        }
        rows.append(("\(language)/input", P.inputBanner(hostTitle: host, text: text)))
        return rows
    }

    static func model(_ banner: P.SessionBanner) -> BannerView.Model {
        .session(banner, disconnect: {}, dismiss: {}, reconnect: {}, learnMore: {})
    }

    struct Parts {
        let content: NSStackView
        let texts: NSStackView
        let labels: [NSTextField]
    }

    static func parts(of banner: BannerView) throws -> Parts {
        var stacks: [NSStackView] = []
        var labels: [NSTextField] = []
        func walk(_ view: NSView) {
            if let stack = view as? NSStackView { stacks.append(stack) }
            if let label = view as? NSTextField { labels.append(label) }
            view.subviews.forEach(walk)
        }
        walk(banner)
        let content = try #require(stacks.first { $0.orientation == .horizontal && $0.arrangedSubviews.contains { $0 is NSImageView } })
        let texts = try #require(stacks.first { $0.orientation == .vertical && !$0.arrangedSubviews.isEmpty && $0.arrangedSubviews.allSatisfy { $0 is NSTextField } })
        return Parts(content: content, texts: texts, labels: labels)
    }

    /// Lays `model` out in a window's content view, 560 points wide, top-aligned, height free.
    static func layOut(_ model: BannerView.Model) -> BannerView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 40, height: 400))
        window.contentView = root
        let banner = BannerView(model)
        root.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            banner.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        return banner
    }

    /// The height `label` needs to show all its lines at its current width.
    static func neededHeight(_ label: NSTextField) -> CGFloat {
        label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height ?? 0
    }

    static func check(_ name: String, _ banner: BannerView, width expectedWidth: CGFloat = width) throws {
        let parts = try parts(of: banner)
        let bounds = banner.bounds
        #expect(abs(bounds.width - expectedWidth) < 0.5, "\(name): width \(bounds.width)")
        #expect(bounds.height + 0.5 >= parts.content.fittingSize.height,
                "\(name): banner \(bounds.height) shorter than its content's fitting height \(parts.content.fittingSize.height)")
        let texts = banner.convert(parts.texts.bounds, from: parts.texts)
        #expect(texts.minY >= 10 - 0.5, "\(name): text column \(texts.minY) from one edge")
        #expect(bounds.height - texts.maxY >= 10 - 0.5, "\(name): text column \(bounds.height - texts.maxY) from the other edge")
        for item in parts.content.arrangedSubviews {
            let frame = banner.convert(item.bounds, from: item)
            #expect(frame.minY >= 10 - 0.5 && bounds.height - frame.maxY >= 10 - 0.5,
                    "\(name): \(type(of: item)) at \(frame) inside \(bounds) is closer than 10 to an edge")
        }
        #expect(parts.labels.count == 2, "\(name): title and body")
        for label in parts.labels {
            let frame = banner.convert(label.bounds, from: label)
            #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name): label \(frame) outside \(bounds)")
            #expect(label.frame.height + 0.5 >= neededHeight(label),
                    "\(name): label '\(label.stringValue.prefix(24))' \(label.frame.height) high, needs \(neededHeight(label))")
        }
    }

    /// Runs `body` on each banner background branch this machine can build: glass (macOS 26+) and
    /// the 14–25 material. Returns the branches run.
    @discardableResult
    static func onEachBranch(_ body: (String) throws -> Void) rethrows -> [String] {
        var run: [String] = []
        if #available(macOS 26, *) {
            try body("glass")
            run.append("glass")
        }
        GlassStyle.forceLegacyMaterial = true
        defer { GlassStyle.forceLegacyMaterial = false }
        try body("material")
        run.append("material")
        return run
    }

    @Test("every session banner in en / zh-Hans / ja keeps 10 points above and below its content at 560 points",
          arguments: ["en", "zh-Hans", "ja"])
    func sessionBannersFit(language: String) throws {
        let branches = try Self.onEachBranch { branch in
            for (name, banner) in try Self.sessionBanners(language) {
                let view = Self.layOut(Self.model(banner))
                // r1 m-1: the branch really is the one named -- glass only on 26+ with the seam
                // false, the 14–25 material whenever the seam is true.
                let background = try #require(view.subviews.first, "\(branch) \(name): no background")
                if branch == "glass" {
                    #expect(!GlassStyle.forceLegacyMaterial, "\(branch) \(name): the seam is false on the glass branch")
                    if #available(macOS 26, *) {
                        #expect(background is NSGlassEffectView, "\(branch) \(name): background is \(type(of: background))")
                    }
                } else {
                    #expect(background is NSVisualEffectView, "\(branch) \(name): background is \(type(of: background))")
                }
                try Self.check("\(branch) \(name)", view)
            }
        }
        #expect(branches.contains("material"))
        #expect(!GlassStyle.forceLegacyMaterial, "the seam is back to false")
    }

    @Test("the en waiting banner's body wraps to two lines at 560 points and the banner grows by both")
    func enBodyWrapsAndGetsTwoLines() throws {
        let (name, banner) = try #require(try Self.sessionBanners("en").first)
        try Self.onEachBranch { branch in
            let view = Self.layOut(Self.model(banner))
            let parts = try Self.parts(of: view)
            let body = try #require(parts.labels.first { $0.stringValue == banner.body })
            let title = try #require(parts.labels.first { $0.stringValue == banner.title })
            let line = (body.font ?? .systemFont(ofSize: 12)).boundingRectForFont.height
            #expect(Self.neededHeight(body) >= 1.8 * line, "\(branch) \(name): the case is meant to wrap")
            #expect(body.frame.height >= 1.8 * line, "\(branch) \(name): body \(body.frame.height) high, one line is \(line)")
            #expect(view.bounds.height + 0.5 >= title.frame.height + body.frame.height + 2 + 20,
                    "\(branch) \(name): \(view.bounds.height) < title + spacing + body + 2 × 10")
            try Self.check("\(branch) \(name)", view)
        }
    }

    @Test("in the Hosts window's banner area the en reconnect banner keeps its inset too")
    func hostsWindowBannerArea() throws {
        let (name, banner) = try #require(try Self.sessionBanners("en").first)
        try Self.onEachBranch { branch in
            let controller = MainWindowControllerTests.controller(records: [])
            controller.showBanner(Self.model(banner))
            let window = try #require(controller.window)
            // `setBanners` lays the arriving banner out inside its 0.2 s push-in animation; a
            // size change outside any animation context gives the settled frames.
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.layoutIfNeeded()
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.layoutIfNeeded()
            let view = try #require(controller.detail.bannerStack.arrangedSubviews.compactMap { $0 as? BannerView }.first)
            try Self.check("\(branch) hosts-window \(name)", view, width: controller.detail.bannerStack.frame.width)
        }
    }

    /// RE-WRITTEN by ADR-0025 a-1: the start panel's background (`GlassStyle.panelBackground`) reads
    /// the same seam, so the panel's 14–25 branch is testable on 26 too -- declared once, read twice,
    /// still only in GlassStyle.swift and still never set by the App.
    @Test("the App never sets GlassStyle.forceLegacyMaterial: only GlassStyle.swift names it, once declared and read by the banner and the start panel")
    func seamIsTestOnly() throws {
        var hits: [String: Int] = [:]
        for directory in ["App/UI", "App/Macdows", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
            let root = bannerHeightRepoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let code = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
                let count = code.components(separatedBy: "forceLegacyMaterial").count - 1
                if count > 0 { hits[url.lastPathComponent] = count }
            }
        }
        #expect(hits == ["GlassStyle.swift": 3])
        let glass = try String(contentsOf: bannerHeightRepoRoot().appendingPathComponent("App/UI/Style/GlassStyle.swift"), encoding: .utf8)
        #expect(glass.contains("static var forceLegacyMaterial = false"))
        #expect(glass.components(separatedBy: "if #available(macOS 26, *), !forceLegacyMaterial {").count - 1 == 2,
                "the banner's branch and the start panel's")
    }
}
