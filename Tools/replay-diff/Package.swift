// swift-tools-version: 6.0
import PackageDescription

// Why a standalone SwiftPM package rather than a fifth XcodeGen target in App/project.yml
// (which is how Tools/bridge-smoke and Tools/window-smoke are wired):
//
//  1. Those two are Xcode targets because they *need* to be: they link CRBridge, the
//     vendored FreeRDP/WinPR dylibs and the self-built LGPL ffmpeg prefix, drive a real
//     NSApplication, and carry the whole HEADER_SEARCH_PATHS / LD_RUNPATH_SEARCH_PATHS /
//     hardened-runtime stanza that goes with that (App/project.yml:385-440). replay-diff
//     needs exactly one dependency -- MacdowsCore, which is already a pure-Swift,
//     zero-FreeRDP, zero-AppKit SwiftPM library -- so an Xcode target would buy nothing
//     and cost a `xcodegen generate` (plus the maintainer's MACDOWS_SIGN_LOCAL overlay)
//     on the critical path of an *offline* gate.
//  2. The Xcode project has no test bundle at all (see the App target's own note), and
//     this lane's acceptance is unit tests -- five suites as originally scoped, more after
//     three review rounds. A SwiftPM package gets `swift test --package-path Tools/replay-diff`
//     for free; an Xcode tool target has nowhere to put them.
//  3. `Scripts/upgrade-gate.sh` must run from a bare checkout with nothing generated:
//     `swift build --package-path Tools/replay-diff` needs no .xcodeproj, no signing
//     identity, and no vendored dylib prefix.
//
// Offline by construction: the only dependency is a *path* dependency to the sibling
// package in this same repo. There is deliberately no `url:` dependency anywhere in this
// file -- adding one would make the upgrade gate require the network, which is the one
// thing it must never do (M1 lane L5: "Do not require a live host to run the differ").
// swift-argument-parser is the specific temptation this rules out; the CLI parses argv by
// hand in Sources/ReplayDiffCLI/CommandLineOptions.swift instead.
let package = Package(
    name: "replay-diff",
    platforms: [.macOS(.v14)],
    products: [
        // Product name (not target name) is what names the built binary, so the tool is
        // `replay-diff` on disk while the module stays a legal Swift identifier.
        .executable(name: "replay-diff", targets: ["ReplayDiffCLI"]),
        .library(name: "ReplayDiffKit", targets: ["ReplayDiffKit"]),
    ],
    dependencies: [
        .package(path: "../../Packages/MacdowsCore"),
    ],
    targets: [
        // All diffing logic lives here, not in the executable, so it is unit-testable
        // without spawning a process.
        .target(
            name: "ReplayDiffKit",
            dependencies: [
                .product(name: "MacdowsCore", package: "MacdowsCore"),
            ]
        ),
        .executableTarget(
            name: "ReplayDiffCLI",
            dependencies: ["ReplayDiffKit"]
        ),
        .testTarget(
            name: "ReplayDiffKitTests",
            dependencies: ["ReplayDiffKit"]
        ),
    ]
)
