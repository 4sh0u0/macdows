import Foundation
import Testing

// UI-1 spec §8 general rule (deployment-target ruling B): every Liquid Glass API in `App/UI` is
// named in `GlassStyle.swift` only, and there only inside an `if #available(macOS 26, *)` branch
// that has an `else` (the 14–25 fallback). Source pin.

private func glassRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Suite("UI-1 §8 — Liquid Glass only behind #available(macOS 26, *), with a 14–25 fallback")
struct GlassStyleTests {
    static let glassTokens = ["NSGlassEffect", ".glass", "tintProminence", "glassEffect", "glassProminent"]

    @Test("no App source outside GlassStyle.swift names a glass API")
    func onlyGlassStyleNamesGlass() throws {
        var scanned = 0
        for directory in ["App/UI", "App/Macdows", "App/Security", "App/SessionControl", "App/RemoteWindowRendering"] {
            let root = glassRepoRoot().appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "GlassStyle.swift" {
                scanned += 1
                let code = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
                for token in Self.glassTokens {
                    #expect(!code.contains(token), "\(url.lastPathComponent) names \(token)")
                }
            }
        }
        #expect(scanned > 10)
    }

    @Test("inside GlassStyle.swift every glass line is in an #available(macOS 26, *) branch that has an else")
    func everyGlassLineIsGuarded() throws {
        let text = try String(contentsOf: glassRepoRoot().appendingPathComponent("App/UI/Style/GlassStyle.swift"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var depthStack: [Bool] = []  // true = inside an #available(macOS 26, *) block
        var guardedLines = 0
        var availableBlocks = 0
        var elseAfterAvailable = 0
        var pendingAvailable = false
        for raw in lines {
            let line = raw.components(separatedBy: "//").first ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("if #available(macOS 26, *)") {
                pendingAvailable = true
                availableBlocks += 1
            }
            if trimmed.hasPrefix("} else {"), depthStack.last == true {
                elseAfterAvailable += 1
            }
            let inside = depthStack.contains(true)
            if Self.glassTokens.contains(where: { line.contains($0) }) && !trimmed.hasPrefix("///") {
                #expect(inside, "unguarded glass line: \(trimmed)")
                if inside { guardedLines += 1 }
            }
            for character in line {
                if character == "{" {
                    depthStack.append(pendingAvailable)
                    pendingAvailable = false
                } else if character == "}" {
                    _ = depthStack.popLast()
                }
            }
        }
        #expect(guardedLines >= 5)
        #expect(availableBlocks >= 4)
        #expect(elseAfterAvailable == availableBlocks, "every #available branch has a 14–25 else")
    }

    @Test("the deployment target stays 14.0")
    func deploymentTarget() throws {
        let yml = try String(contentsOf: glassRepoRoot().appendingPathComponent("App/project.yml"), encoding: .utf8)
        #expect(yml.contains("MACOSX_DEPLOYMENT_TARGET: \"14.0\""))
        #expect(!yml.contains("deploymentTarget: \"26"))
    }
}
