import Foundation
import Testing

@testable import MacdowsCore

/// `MacdowsPaths` exists because `host.env` and `lab-boundary.env` — the host a harness dials
/// and the segments that host is judged against — used to be located by two different rules,
/// so a redirected `HOME` could send the two halves of one gate decision to two different
/// homes. These cases are therefore not "does a string come back": they pin the *reconciled
/// order*, the fact that the two halves can no longer come apart, and the fact that nothing
/// moved in the environment everything actually runs in.
///
/// Every path here is a fabricated `/Users/...` or `/private/tmp/...` fixture. Nothing touches
/// the filesystem, nothing reads or writes the maintainer's real configuration files, and
/// nothing mutates this process's own environment — the environment is a parameter precisely so
/// that it does not have to be.
@Suite("MacdowsPaths")
struct MacdowsPathsTests {
    /// The two spellings this test compares against are the *literal expressions* the three
    /// call sites carried before this type existed, kept here rather than derived from
    /// `MacdowsPaths` itself: a pin that reproduces the implementation is not a pin.
    private static let previousHostEnvExpression = NSHomeDirectory() + "/.config/macdows/host.env"
    private static let previousBoundaryFileSuffix = "/.config/macdows/lab-boundary.env"

    @Test("home prefers a set, non-empty HOME and otherwise falls back to NSHomeDirectory()")
    func homeResolution() {
        #expect(MacdowsPaths.home(environment: ["HOME": "/Users/someone"]) == "/Users/someone")
        // Absent and empty take the identical branch, which is what `${HOME:-}` means on the
        // shell side; the fallback is the process's real home, not the shell's unusable "".
        #expect(MacdowsPaths.home(environment: [:]) == NSHomeDirectory())
        #expect(MacdowsPaths.home(environment: ["HOME": ""]) == NSHomeDirectory())
    }

    @Test("host.env and lab-boundary.env hang off that one home")
    func filePathsAreBuiltOnHome() {
        let environment = ["HOME": "/Users/someone"]
        #expect(MacdowsPaths.hostEnvPath(environment: environment) == "/Users/someone/.config/macdows/host.env")
        #expect(
            MacdowsPaths.boundaryFilePath(environment: environment)
                == "/Users/someone/.config/macdows/lab-boundary.env")
    }

    /// The whole point of the type, stated as an assertion: whatever the environment does to
    /// "home", the file the boundary gate reads and the file the dialled host comes out of are
    /// siblings in one directory. Before this type they were not — `host.env` went through
    /// `NSHomeDirectory()` (which consults `CFFIXED_USER_HOME`, then the password database,
    /// and only then `HOME`) while the boundary file went through `$HOME`.
    ///
    /// The `MACDOWS_LAB_BOUNDARY_FILE` case is deliberately absent from this matrix: that
    /// override is a documented, intentional way to point the gate at a fixture, and it is
    /// *supposed* to move one file and not the other. It gets its own case below.
    @Test("the two halves of the gate always resolve under a single home")
    func bothHalvesShareOneHome() {
        let environments: [[String: String]] = [
            ["HOME": "/Users/someone"],
            ["HOME": "/Users/redirected/elsewhere"],
            ["HOME": "/"],
            ["HOME": ""],
            [:],
            // A `CFFIXED_USER_HOME` in the dictionary changes nothing here, because this
            // resolver never consults it — which is exactly the asymmetry that used to exist
            // between the two halves, since `NSHomeDirectory()` does.
            ["HOME": "/Users/someone", "CFFIXED_USER_HOME": "/Users/container"],
        ]
        for environment in environments {
            let hostEnv = MacdowsPaths.hostEnvPath(environment: environment)
            let boundaryFile = MacdowsPaths.boundaryFilePath(environment: environment)
            let hostEnvDirectory = URL(fileURLWithPath: hostEnv).deletingLastPathComponent().path
            let boundaryDirectory = URL(fileURLWithPath: boundaryFile).deletingLastPathComponent().path
            #expect(
                hostEnvDirectory == boundaryDirectory,
                "the credentials file and the boundary file must never come out of two homes")
            #expect(URL(fileURLWithPath: hostEnv).lastPathComponent == "host.env")
            #expect(URL(fileURLWithPath: boundaryFile).lastPathComponent == "lab-boundary.env")
        }
    }

    /// The binding no-behaviour-change constraint on this change, pinned rather than asserted
    /// in prose: in the environment everything actually runs in — `HOME` set to the process's
    /// real home — the unified resolver returns the exact string the three call sites used to
    /// build for themselves, and so does the `HOME`-absent fallback.
    @Test("in the default environment the resolver reproduces the replaced expression byte for byte")
    func defaultEnvironmentIsUnchanged() {
        let realHome = NSHomeDirectory()
        #expect(MacdowsPaths.hostEnvPath(environment: ["HOME": realHome]) == Self.previousHostEnvExpression)
        #expect(MacdowsPaths.hostEnvPath(environment: [:]) == Self.previousHostEnvExpression)
        #expect(MacdowsPaths.hostEnvPath(environment: ["HOME": ""]) == Self.previousHostEnvExpression)
        // And the boundary half, whose rule is the one that did not move: same three cases,
        // same strings `LabBoundary.defaultBoundaryFilePath` produced before it became a
        // forwarder.
        #expect(
            MacdowsPaths.boundaryFilePath(environment: ["HOME": realHome])
                == realHome + Self.previousBoundaryFileSuffix)
        #expect(MacdowsPaths.boundaryFilePath(environment: [:]) == realHome + Self.previousBoundaryFileSuffix)
    }

    @Test("the boundary-file override wins over HOME, and an empty override is treated as unset")
    func boundaryFileOverride() {
        #expect(
            MacdowsPaths.boundaryFilePath(environment: [
                MacdowsPaths.boundaryFileOverrideKey: "/private/tmp/override.env", "HOME": "/Users/someone",
            ]) == "/private/tmp/override.env")
        #expect(
            MacdowsPaths.boundaryFilePath(environment: [
                MacdowsPaths.boundaryFileOverrideKey: "", "HOME": "/Users/someone",
            ]) == "/Users/someone/.config/macdows/lab-boundary.env")
        #expect(MacdowsPaths.boundaryFileOverrideKey == "MACDOWS_LAB_BOUNDARY_FILE", "lib.sh reads this exact name")
    }

    /// Pointing the gate at a fixture boundary file must not also relocate the credentials
    /// file. This is the one place the two paths are *meant* to diverge, and it is a test
    /// rather than a comment because the tempting "simplification" — one override for the whole
    /// configuration directory — would silently make a fixture run read fixture credentials.
    @Test("the boundary-file override does not move host.env")
    func overrideDoesNotMoveHostEnv() {
        let environment = [
            MacdowsPaths.boundaryFileOverrideKey: "/private/tmp/fixture-lab-boundary.env",
            "HOME": "/Users/someone",
        ]
        #expect(MacdowsPaths.hostEnvPath(environment: environment) == "/Users/someone/.config/macdows/host.env")
    }

    /// `host.env` has no Swift-side redirect variable, deliberately (see `MacdowsPaths`' doc
    /// comment: the `WIN_*` variables already are the fixture mechanism, and a second one would
    /// be new surface on the path the boundary gate guards). `CRDP_HOST_ENV` is real, but it is
    /// `Scripts/probe.sh`'s alone; if a future edit teaches this resolver to honour it, this
    /// case goes red and the decision gets made on purpose.
    @Test("host.env honours no redirect variable of its own")
    func hostEnvHasNoOverride() {
        let environment = [
            "HOME": "/Users/someone",
            "CRDP_HOST_ENV": "/private/tmp/fixture-host.env",
            "MACDOWS_HOST_ENV_FILE": "/private/tmp/other-fixture-host.env",
            MacdowsPaths.boundaryFileOverrideKey: "/private/tmp/fixture-lab-boundary.env",
        ]
        #expect(MacdowsPaths.hostEnvPath(environment: environment) == "/Users/someone/.config/macdows/host.env")
    }

    /// The default arguments are the whole reason the call sites are one-liners, so they are
    /// wired to `ProcessInfo` rather than to some snapshot taken at load time. Asserted against
    /// an explicit pass of the same dictionary, which keeps the case deterministic regardless of
    /// what the surrounding environment happens to contain.
    @Test("the zero-argument overloads read this process's environment")
    func defaultArgumentsUseProcessInfo() {
        let live = ProcessInfo.processInfo.environment
        #expect(MacdowsPaths.home() == MacdowsPaths.home(environment: live))
        #expect(MacdowsPaths.hostEnvPath() == MacdowsPaths.hostEnvPath(environment: live))
        #expect(MacdowsPaths.boundaryFilePath() == MacdowsPaths.boundaryFilePath(environment: live))
        #expect(LabBoundary.defaultBoundaryFilePath() == MacdowsPaths.boundaryFilePath(environment: live))
    }

    /// `LabBoundary.defaultBoundaryFilePath` stayed as the name every caller and every existing
    /// test uses; it forwards here. Pinned across the whole environment matrix so that the
    /// forwarder cannot quietly grow a rule of its own — which would recreate exactly the
    /// two-rules-for-one-file defect this change removes, one level up.
    @Test("LabBoundary.defaultBoundaryFilePath is a forwarder, in every environment")
    func labBoundaryForwardsToTheResolver() {
        let environments: [[String: String]] = [
            ["HOME": "/Users/someone"],
            ["HOME": ""],
            [:],
            [MacdowsPaths.boundaryFileOverrideKey: "/private/tmp/override.env", "HOME": "/Users/someone"],
            [MacdowsPaths.boundaryFileOverrideKey: "", "HOME": "/Users/someone"],
        ]
        for environment in environments {
            #expect(
                LabBoundary.defaultBoundaryFilePath(environment: environment)
                    == MacdowsPaths.boundaryFilePath(environment: environment))
        }
    }

    /// Not normalising is a decision, not an oversight: the shell scripts reading the same two
    /// files build their paths by plain concatenation too, and a resolver that canonicalised
    /// would be one more thing the Swift and shell sides could disagree about.
    @Test("the resolved path is plain concatenation -- no trailing-slash repair, no tilde expansion")
    func noNormalisation() {
        #expect(
            MacdowsPaths.hostEnvPath(environment: ["HOME": "/Users/someone/"])
                == "/Users/someone//.config/macdows/host.env")
        #expect(MacdowsPaths.hostEnvPath(environment: ["HOME": "~"]) == "~/.config/macdows/host.env")
    }
}
