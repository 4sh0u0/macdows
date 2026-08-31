import Foundation

/// Where this project's maintainer-local configuration files live — one rule, for every
/// caller, in the package `swift test` can reach.
///
/// **Why a type for what looks like two string concatenations.** `~/.config/macdows/host.env`
/// (the credentials, including the host a harness is about to dial) and
/// `~/.config/macdows/lab-boundary.env` (the segments `LabBoundary` judges that host against)
/// are the two halves of a single decision. Until this type existed the two halves located
/// "home" by *different rules*: `host.env` was spelled `NSHomeDirectory() + "/.config/macdows/
/// host.env"` at all three Swift entry points (`Tools/bridge-smoke/GateShim.swift`,
/// `Tools/window-smoke/main.swift`, `App/Macdows/AppDelegate.swift`) while
/// `LabBoundary.defaultBoundaryFilePath` preferred `$HOME`.
///
/// Those are not the same directory whenever `HOME` is redirected and `CFFIXED_USER_HOME` is
/// not set: `NSHomeDirectory()` consults `CFFIXED_USER_HOME` first, then the password
/// database, and only then `HOME`, so a redirected `HOME` moved the *boundary* file while
/// leaving the *credentials* file where it was. A prior review measured that skew, ruled it
/// fail-closed for the case at hand (the overwhelmingly likely outcome of a redirected `HOME`
/// is that no boundary file exists there at all, which refuses) and parked it as this change.
/// Three entry points times two rules is the same divergence shape `EnvFile` exists to remove
/// one layer down, and it does not get to survive at the path layer: a gate that reads its
/// segment list out of one home while the host it judges came out of another is a gate whose
/// two inputs can be made to disagree.
///
/// **The resolution order, decided rather than inherited: `$HOME` when set and non-empty,
/// otherwise `NSHomeDirectory()`.** The two candidate rules were the two that already existed,
/// and this one wins on four counts:
///
/// 1. **The shell side already reads both files through `$HOME`** — `Scripts/lib.sh:57`
///    (`${MACDOWS_LAB_BOUNDARY_FILE:-${HOME:-}/.config/macdows/lab-boundary.env}`),
///    `Scripts/run-window-smoke.command:99` and `Scripts/probe.sh:30`. `lib.sh` is this
///    project's semantic authority for the boundary rule and the launcher is how a real-host
///    run is *supposed* to start, so `$HOME`-preferring is the rule that keeps the launcher's
///    gate and the harness it launches pointed at one file. The opposite choice would have
///    let the launcher validate a host out of one `host.env` while the binary it exec'd read
///    a different one — the "the gate approved one host and the harness dialled another"
///    shape, again.
/// 2. **It is the rule `LabBoundary` already documented and pinned**, so reconciling toward it
///    changes no boundary verdict anywhere: the file the gate reads is the same file before
///    and after this change, in every environment. What moved is `host.env`, onto the rule
///    the gate was already using.
/// 3. **The `NSHomeDirectory()` fallback keeps the case a bare `$HOME` rule gets wrong** — a
///    bundled app whose home is its sandbox container, and any process started with a
///    scrubbed environment (`env -i`), for both of which `HOME` is exactly the variable you
///    cannot rely on. `lib.sh` degrades there to the unusable absolute path
///    `/.config/macdows/...` and therefore refuses; this returns the process's real home.
///    That divergence is pre-existing, deliberate, documented on
///    `LabBoundary.defaultBoundaryFilePath`, and unchanged here.
/// 4. **Nothing changes in the default environment.** With `HOME` set to the process's real
///    home — every configuration in which this repository builds, tests, launches from Finder
///    or runs from a Terminal — `$HOME` and `NSHomeDirectory()` are the same string, so every
///    path this type returns is byte-identical to the expression it replaced. The same holds
///    with `HOME` absent, via the fallback. `MacdowsPathsTests` pins both.
///
/// **`host.env` deliberately has no override of its own.** `lab-boundary.env` has
/// `MACDOWS_LAB_BOUNDARY_FILE` (honoured identically by `lib.sh`, and the reason a test can
/// point the gate at a throwaway fixture without touching the real file); `host.env` gets no
/// Swift-side equivalent, even though `Scripts/probe.sh` carries a shell-only `CRDP_HOST_ENV`.
/// The Swift harnesses already read `WIN_HOST`/`WIN_USER`/`WIN_PASS` from the environment in
/// preference to the file (`EnvFile.value(forKey:in:environment:)`), so a redirect variable
/// would be a second way to do something that already has one — and every new environment
/// variable able to change where a dialled host comes from is new surface on precisely the
/// path the boundary gate guards.
///
/// **Nothing here reads a file or logs anything.** These are pure string functions over an
/// injected environment, which is what makes the whole rule testable offline; the contents of
/// both files are either credentials or the owner's own network shape, and belong to `EnvFile`
/// and `LabBoundary` respectively.
public enum MacdowsPaths {
    /// The one spelling of the configuration directory, relative to home. Both files below are
    /// built from it, so a future move of the directory is a single edit rather than a hunt.
    private static let configurationDirectory = ".config/macdows"

    /// The environment variable that redirects the boundary file, matching `lib.sh`'s own.
    /// Public because it is part of the documented contract a maintainer (and
    /// `LabBoundaryTests`) uses, and spelled once so the string cannot drift between the
    /// resolver and the prose that describes it.
    public static let boundaryFileOverrideKey = "MACDOWS_LAB_BOUNDARY_FILE"

    /// The home directory every path below is built on: `$HOME` when set and non-empty,
    /// otherwise `NSHomeDirectory()`. See this type's own doc comment for why that order and
    /// not the other one.
    ///
    /// **Deliberately `internal`, not `public`.** This type's whole thesis is that no caller
    /// spells one of these paths itself; publishing the *ingredient* of both paths would hand
    /// the next author `MacdowsPaths.home() + "/.config/macdows/host.env"` — a line that looks
    /// like it uses the resolver, would sail through review for exactly that reason, and is
    /// precisely the divergence this type exists to remove. Outside the package there is
    /// `hostEnvPath` and `boundaryFilePath` and nothing else; the tests reach this through
    /// `@testable import`.
    ///
    /// The result is *not* normalised (no trailing-slash collapsing, no symlink resolution,
    /// no tilde expansion). Deliberate: the point of this function is that every caller
    /// produces the same bytes as every other caller and as the shell scripts reading the same
    /// files, and "helpfully" canonicalising here would be one more thing the two sides could
    /// disagree about.
    static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        // `flatMap` on the optional rather than `?? ""` plus an isEmpty test, so that an empty
        // `HOME` and an absent `HOME` take the identical branch — which is what `${HOME:-}`
        // means on the shell side, and what the pinned tests assert.
        environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    /// `~/.config/macdows/host.env`: the untracked file carrying `WIN_HOST`/`WIN_USER`/
    /// `WIN_PASS`, read through `EnvFile` by `Tools/window-smoke`, `Tools/bridge-smoke` (via
    /// its `GateShim`) and the app's Connect button.
    public static func hostEnvPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(environment: environment) + "/" + configurationDirectory + "/host.env"
    }

    /// `$MACDOWS_LAB_BOUNDARY_FILE` when set and non-empty, else
    /// `~/.config/macdows/lab-boundary.env`: the untracked file carrying
    /// `MACDOWS_LAB_ALLOWED_NETS`. `LabBoundary.defaultBoundaryFilePath` is the name callers
    /// use; this is where the rule lives, so that it and `hostEnvPath` cannot come apart.
    public static func boundaryFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[boundaryFileOverrideKey], !override.isEmpty {
            return override
        }
        return home(environment: environment) + "/" + configurationDirectory + "/lab-boundary.env"
    }
}
