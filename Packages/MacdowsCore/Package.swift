// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacdowsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacdowsCore", targets: ["MacdowsCore"]),
        // Separate product from MacdowsCore, deliberately, not folded into it — see
        // the W3 report for the full rationale. Short version: MacdowsCore is "pure
        // Swift business logic, zero FreeRDP/AppKit/C dependencies, testable without a
        // display" (its own doc comment above says as much); CRDPQueue is a C-ABI queue
        // meant to be linked directly into the ObjC++ CRBridge target, a fundamentally
        // different consumer with a fundamentally different constraint (link the C
        // symbols, not the Swift runtime). Bundling them into one product would force
        // every MacdowsCore consumer to also drag in C queue internals it doesn't
        // need, and blur a boundary adr/0006 §2 already drew on purpose.
        .library(name: "CRDPQueue", targets: ["CRDPQueue"]),
    ],
    targets: [
        // Pure logic only — no FreeRDP, no AppKit. Anything in this package must be able
        // to run under `swift test` without a display, a signing identity, or a vendored
        // C dependency. See adr/0006 §2's directory-layout rationale.
        .target(name: "MacdowsCore"),
        // adr/0005 §1/§3's event-queue layer: C11, zero FreeRDP/AppKit dependencies,
        // meant to be linked directly by the (ObjC++) CRBridge Xcode target once that
        // exists. Kept as its own target/product for the same reason it's a separate
        // product from MacdowsCore above. The C11 requirement itself is expressed via
        // the package-level `cLanguageStandard` below, not `.unsafeFlags` here (M3 in the
        // W3 review) — `.unsafeFlags` makes a target ineligible to be used as a versioned
        // dependency by any consumer that pulls this package in via SwiftPM, which this
        // library is meant to be eventually (CRBridge links it directly today, but nothing
        // rules out a future SwiftPM consumer).
        .target(name: "CRDPQueue"),
        .testTarget(
            name: "MacdowsCoreTests",
            dependencies: ["MacdowsCore", "CRDPQueue"]
        ),
    ],
    cLanguageStandard: .c11
)
