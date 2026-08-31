// GateShim: the Objective-C-visible face of the two MacdowsCore types bridge-smoke's main.mm
// has to go through before it is allowed to dial anything -- `EnvFile` (this project's one
// host.env parser) and `LabBoundary` (the fail-closed live-host boundary gate, the in-process
// mirror of Scripts/lib.sh's crdp_assert_lab_boundary).
//
// Why a Swift file appeared inside an otherwise ObjC++ tool target. main.mm carried the fourth
// hand-rolled copy of the host.env parsing rule in this repository, and no boundary gate at
// all: it read ~/.config/macdows/host.env with its own ParseEnvFile/ResolveCredential pair and
// handed the result straight to -[CRSession initWithHost:user:password:program:]. Both halves
// of that were defective. The parser keyed each line on everything left of the first `=`, so
// the ordinary line `export WIN_HOST=x` was filed under the key "export WIN_HOST" and was
// invisible to the WIN_HOST lookup, and it stripped no quotes, so `WIN_HOST="x"` would have
// dialled a host whose name included the quote characters -- rules that disagree with the ones
// Scripts/run-window-smoke.command applies to the *same file*, a disagreement a prior review
// measured fail-open (see EnvFile's own doc comment). And this binary is directly runnable out
// of DerivedData with WIN_HOST set, exactly like Tools/window-smoke, so on that path nothing
// whatsoever stood between `xcodebuild -scheme bridge-smoke` and a socket to an arbitrary host,
// which is precisely what the owner's live-host testing boundary rule (2026-08-31) forbids.
//
// Re-implementing either rule in ObjC++ would have produced a fifth parser and a second gate --
// and a gate that validates a differently-parsed string from the one that gets dialled is not a
// gate. Calling the Swift ones instead needs one Swift file in this target, and this is it. It
// deliberately contains no rule of its own: every decision below belongs to MacdowsCore, and
// everything here is type adaptation (Swift `Optional`/`enum` into nullable `NSString *` and
// small `@objc` objects) so that main.mm can reach it through the generated
// `bridge_smoke-Swift.h`.
//
// Nothing here logs. Every value it touches is either a credential or the owner's own network
// shape; main.mm prints credential *lengths* for exactly that reason, and `LabBoundary` is built
// so that no refusal can name a boundary segment.

import Foundation
import MacdowsCore

/// The three values `main` needs, resolved from the environment and host.env but *not* judged:
/// `nil` means "neither the environment variable nor host.env supplied this one", which is the
/// same distinction the ObjC `ResolveCredential` used to return and which main.mm still prints
/// as `present`/`MISSING`. Emptiness is likewise left for main.mm's existing guard to decide, so
/// that removing the old parser changed no message and no exit code on this path.
///
/// Explicit `@objc(...)` names on all three classes here: the generated header would expose the
/// Swift names unmangled anyway, but this target's ObjC side should not have to know or care
/// about Swift's naming rules, and pinning the name means a future rename on the Swift side is a
/// compile error in main.mm rather than a silent one.
@objc(BridgeSmokeCredentials)
public final class BridgeSmokeCredentials: NSObject {
    @objc public let host: String?
    @objc public let user: String?
    @objc public let password: String?

    init(host: String?, user: String?, password: String?) {
        self.host = host
        self.user = user
        self.password = password
    }
}

/// One boundary verdict, as an object rather than as "nil means fine".
///
/// The shape is chosen for the fail-closed property, not for ObjC idiom: a nullable
/// `NSString *reasonForRefusal` would read naturally, but it makes *absence of a value* the
/// signal to go ahead and dial, so any future path that forgets to check, or that gets a nil
/// back for a reason nobody anticipated, connects. Here the caller has to see `isAllowed == YES`
/// before it may proceed, which is the same "positively prove the target is inside" discipline
/// `LabBoundary` itself is built on.
@objc(BridgeSmokeBoundaryVerdict)
public final class BridgeSmokeBoundaryVerdict: NSObject {
    /// `YES` only for `LabBoundary.Verdict.allowed`.
    @objc public let isAllowed: Bool
    /// `LabBoundary.Refusal.reasonText` -- a reason *category*, never a segment and never a
    /// resolved address (see `LabBoundary`'s doc comment, and the no-leak test that sweeps the
    /// whole refusal vocabulary). Empty when `isAllowed`.
    @objc public let reasonText: String

    init(isAllowed: Bool, reasonText: String) {
        self.isAllowed = isAllowed
        self.reasonText = reasonText
    }
}

/// The two calls main.mm makes, and nothing else.
@objc(BridgeSmokeGate)
public final class BridgeSmokeGate: NSObject {
    /// The host.env this harness reads, exposed because main.mm names the file in its
    /// "missing host/user/pass" message. Exported rather than recomputed on the ObjC side so
    /// that the path in that message is by construction the path that was actually read --
    /// two spellings of the same path is how they start drifting.
    ///
    /// `NSHomeDirectory()`, matching Tools/window-smoke and App/Macdows/AppDelegate.swift
    /// character for character, and matching what main.mm's own
    /// `stringByAppendingPathComponent:` produced before this replaced it.
    @objc public static var hostEnvPath: String {
        NSHomeDirectory() + "/.config/macdows/host.env"
    }

    /// What `LabBoundary` prints when it lets a target through, so main.mm's allowed-path line
    /// is the same sentence window-smoke and Scripts/lib.sh emit rather than a third wording.
    @objc public static var allowedLine: String {
        LabBoundary.allowedLine
    }

    /// Environment variables first, then host.env -- the precedence Tools/window-smoke and this
    /// harness share, and the reason Scripts/run-window-smoke.command can hand a child the exact
    /// host its own shell gate cleared. (Tools/rail-probe reads only the environment variables;
    /// Scripts/probe.sh sources host.env on its behalf, so rail-probe itself never has a file leg
    /// to prefer the environment over.)
    ///
    /// A missing or unreadable host.env is not fatal here (the `try?` collapses to an empty
    /// dictionary), for the same reason it is not fatal in window-smoke: the environment
    /// variables alone are a complete configuration, and the caller's own "missing
    /// host/user/pass" guard already produces the right message when they are not.
    @objc public static func resolveCredentials() -> BridgeSmokeCredentials {
        let fileValues = (try? EnvFile.parse(path: hostEnvPath)) ?? [:]
        return BridgeSmokeCredentials(
            host: resolve(fileValues, key: "WIN_HOST"),
            user: resolve(fileValues, key: "WIN_USER"),
            password: resolve(fileValues, key: "WIN_PASS")
        )
    }

    /// The live-host boundary gate (owner rule, 2026-08-31) on the host this run would dial.
    ///
    /// `LabBoundary.check` reads the untracked boundary file itself and resolves names through
    /// the system resolver; a numeric literal short-circuits before the resolver is consulted,
    /// so the common case costs nothing and cannot be influenced by anything on the network.
    /// Every path that cannot positively prove the target is inside an allowed segment comes
    /// back refused -- there is no "assume allowed" branch to adapt here.
    @objc(checkBoundaryForHost:)
    public static func checkBoundary(host: String) -> BridgeSmokeBoundaryVerdict {
        switch LabBoundary.check(host: host) {
        case .allowed:
            return BridgeSmokeBoundaryVerdict(isAllowed: true, reasonText: "")
        case .refused(let refusal):
            return BridgeSmokeBoundaryVerdict(isAllowed: false, reasonText: refusal.reasonText)
        }
    }

    /// window-smoke's `resolveCredential`, with its two parameters collapsed into one: every
    /// call site there passes the same string for the environment variable and the host.env
    /// key, and the three keys this harness reads are no exception.
    private static func resolve(_ fileValues: [String: String], key: String) -> String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment[key], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return fileValues[key]
    }
}
