import AppKit
import MacdowsCore
import os

// Phase 3 M1 / W1 deliverables 2 and 3 (`docs/plans/phase3.md:110`): the AppKit half of the
// display-topology contract -- the collector that turns `NSScreen` into `MacdowsCore`'s
// `DisplayTopology`, and the `NSApplicationDidChangeScreenParameters` observer that makes a
// mid-session display change *visible* without acting on it.
//
// CONTRACT: this file implements `docs/adr/0015-display-topology-and-dpi-contract.md` §5 (U8:
// observer lifetime and the frozen session snapshot), §2 rule 1/4 (per-display scale; who emits
// the mixed-scale warning and how often), §3 rules 1-4 (the desktop size actually sent), and the
// L6 row of §9. Where this file and the ADR could drift, the ADR wins.
//
// THE DIVISION OF LABOUR, stated once so no future reader has to infer it: every *computation*
// -- union bounds, the desktop size, the Y-flip anchor, `isUniformScale` -- lives in
// `Packages/MacdowsCore/Sources/MacdowsCore/DisplayTopology.swift` and is covered by that
// package's tests, which run under `swift test` with no display attached
// (`Packages/MacdowsCore/Package.swift:21-24`). This file is deliberately a *thin adapter*: it
// reads screens, maps four fields per screen, and hands the result to a failable initializer.
// That split is not tidiness -- the App target has no test bundle at all
// (`App/project.yml`'s `Macdows` target declares none; closing that gap is `docs/plans/phase3.md`
// decision D7's item, pre-hung on W2, and explicitly not M1 work),
// so anything with a decision in it that lives here is untestable by construction. Hence the
// rule this file is written to: **no branching in the AppKit half**. Every `if` below is a
// diagnostic that mutates nothing and changes no return value, and each one says so.
//
// WHAT THIS FILE MUST NOT DO (ADR §5.A.3, from `docs/plans/phase3.md:110`'s deliverable 2 --
// "observable events only, no renegotiation"), because the whole point of
// the observer is that it is inert: it must not trigger a reconnect, a resize, or a desktop-size
// re-send, and it must not replace the topology snapshot a live session is already using. Grep
// this file for `session` and you will find no reference to `CRSession` at all -- that is the
// enforcement, and it is why the freeze/send seam is shaped as "return the size, let the caller
// send it" rather than "reach into the session".

/// The project's single `NSScreen` reader and the owner of the screen-parameter observer.
///
/// WHY A SINGLE READER (ADR §5.A.5, which enumerates the four pre-M1 read sites this one
/// replaces: the registry's, the App delegate's and `window-smoke`'s two). The registry's was a
/// *computed property*, re-reading `NSScreen.screens.first` on every single call. Two
/// consequences the ADR turns into rulings: two conversions inside one logical operation could
/// silently disagree if the
/// layout changed between them, and the Y-flip anchor tracked the live layout while the desktop
/// size the server was told about did not (it is read once at connect and never re-synced --
/// `App/CRBridge/CRSession.h:284-286`). ADR §5.A.4 makes "the anchor and the desktop size come
/// from the same topology read" a load-bearing invariant; a single reader that caches is how it
/// becomes structural rather than remembered.
///
/// LIFETIME (ADR §5.A.1, the answer to U8): **app-resident**, registered at launch, never torn
/// down, and never registered per connection. The observer exists precisely to make "the desktop
/// size this session negotiated is now out of date" observable, and that staleness window is
/// exactly the connected state -- so registering only while connected would be closing our eyes
/// during the one interval we are trying to watch. Being resident additionally covers the
/// "displays changed before the first connect" path at zero cost.
///
/// FRESHNESS OF `currentTopology`. The stored value is refreshed at exactly three points: this
/// object's construction, every `NSApplicationDidChangeScreenParameters` notification, and
/// `freezeSessionSnapshot()`. AppKit posts that notification for any screen add/remove/reposition/
/// resolution change, so the cache cannot go stale behind our back; and because it is a cache
/// rather than a computed property, two reads within one operation are guaranteed to agree --
/// which is the defect `DisplayTopology.swift:206-213` describes, closed rather than relocated.
@MainActor
final class DisplayTopologyProvider: DisplayTopologyProviding {
    private static let logger = Logger(subsystem: "dev.haru.macdows", category: "DisplayTopology")

    /// The payload of one screen-parameter change (ADR §5.A.2).
    ///
    /// The ADR requires three things in it, and the third is the only one that is not merely
    /// descriptive: the before topology, the after topology, and **a boolean saying whether the
    /// connected session's desktop size no longer matches the layout**. That boolean is required
    /// to be *computed* rather than left for whoever reads the log to work out in their head,
    /// because it is the entire reason this event is worth emitting.
    ///
    /// Contains local screen geometry only -- no host address, hostname or credential -- which is
    /// what makes `description` safe to log at `.public` privacy and safe for redacted evidence
    /// artifacts (project red lines; `DisplayTopology.description` carries the same guarantee).
    struct ScreenParametersChange: Sendable {
        /// The layout as this provider last knew it. `nil` if there was no usable layout then.
        let previous: DisplayTopology?

        /// The layout as of this notification. `nil` means **no usable display** -- see
        /// `currentTopologyIsEmpty`.
        let current: DisplayTopology?

        /// The desktop size the live session was actually given at connect time, or `nil` when no
        /// session has been started since launch (or when the layout was unusable at connect, in
        /// which case ADR §5.A.6 required that nothing be sent at all).
        let sessionDesktopSize: DesktopSizeInRemotePixels?

        /// ADR §5.A.2's required boolean: the connected session's desktop size no longer equals
        /// what the new layout would ask for, i.e. from here until a reconnect, remote window
        /// coordinates are being computed against one layout while the server clamps against
        /// another. `false` when there is no session, and `false` when the new layout is empty --
        /// an unusable layout does not make the negotiated size *wrong*, it makes it unjudgeable,
        /// and that state is reported by `currentTopologyIsEmpty` instead of being folded in here.
        let connectedDesktopSizeIsStale: Bool

        /// ADR §5.A.6's third bullet: the empty-screen-list state must be *recorded* by this
        /// event, never silent. Derived rather than stored so it cannot disagree with `current`.
        var currentTopologyIsEmpty: Bool { current == nil }

        /// One line, geometry only. `DisplayTopology.description` already includes the derived
        /// desktop size, `rasterScale` and a `MIXED-SCALE` marker, so this adds only the two
        /// things it cannot know: what the session was told, and the verdict.
        var description: String {
            let before = previous?.description ?? "<no usable display>"
            let after = current?.description ?? "<no usable display>"
            let session = sessionDesktopSize.map { "\($0.width)x\($0.height)rpx" } ?? "<none>"
            return "screen parameters changed: \(before) -> \(after)"
                + " sessionDesktop=\(session) stale=\(connectedDesktopSizeIsStale)"
        }
    }

    /// The live layout (`DisplayTopologyProviding`), or `nil` when there is no usable one.
    ///
    /// Deliberately NOT what a connected session does geometry against -- see
    /// `sessionSnapshot`. The protocol's own doc comment makes the same point: "consumers doing
    /// geometry for a live session must use the session's frozen snapshot, not re-read this."
    private(set) var currentTopology: DisplayTopology?

    /// The topology frozen for the current session at connect time (ADR §5.A), and the value the
    /// session's own geometry must anchor on.
    ///
    /// It is **not** handed to a session consumer directly: the connect path wraps it in
    /// `StaticDisplayTopologyProvider(sessionSnapshot)` (`AppDelegate.swift`'s registry
    /// construction) so that what the registry holds is a provider whose `currentTopology` can
    /// never change under it. That is what makes §5.A.4 -- the Y-flip anchor and the desktop size
    /// come from one topology read -- a property of the *values* rather than of the order in which
    /// the caller happened to make two calls. It also makes the registry's own re-take on a
    /// generation rollover a no-op that cannot diverge from the size actually sent, which is the
    /// divergence §5.A.4 exists to forbid.
    ///
    /// Replaced only by the next `freezeSessionSnapshot()` -- i.e. by a reconnect, which is a new
    /// session and legitimately a new snapshot (`CRSession.h:305-320`'s generation is the same
    /// boundary) -- and cleared by `endSession()`. A screen-parameter change does **not** touch it
    /// (§5.A.3).
    private(set) var sessionSnapshot: DisplayTopology?

    /// The desktop size derived from `sessionSnapshot` at freeze time -- i.e. exactly the number
    /// `freezeSessionSnapshot()` handed to the connect path (which `AppDelegate` assigns to
    /// `CRSession.desktopWidth/Height` verbatim; that it then reaches the server is the caller's
    /// guarantee, not this property's). Kept so the staleness verdict compares against that number
    /// rather than against a recomputation.
    private(set) var sessionDesktopSize: DesktopSizeInRemotePixels?

    /// The observable event (ADR §5.A.1: "only emits events"). Set by the App so a human can see
    /// the change without reading Console.app; every change is logged regardless of whether
    /// anyone is listening, so the record does not depend on a consumer existing.
    ///
    /// Whatever is on the other end of this closure must not reconnect, resize, or re-send a
    /// desktop size (§5.A.3). It is a notification, not a command.
    var onScreenParametersChange: ((ScreenParametersChange) -> Void)?

    /// The observer token. Never removed: this object is app-resident by contract (§5.A.1), so
    /// there is no teardown point at which removing it would be correct rather than merely tidy.
    /// The closure holds `self` weakly anyway, so even an unexpected deallocation degrades to a
    /// no-op rather than a use-after-free.
    private var observation: (any NSObjectProtocol)?

    /// - Parameter notificationCenter: injectable only so a harness can drive the observer
    ///   without a real screen change; production passes the default.
    init(notificationCenter: NotificationCenter = .default) {
        currentTopology = Self.readTopologyFromScreens(reason: "launch")

        // ADR §5.A.1 names this exact notification, and so does the charter constraint it comes
        // from (`docs/ARCHITECTURE.md:38`). `queue: .main` because every consumer below it --
        // AppKit, the registry, this class -- is main-actor isolated; `MainActor.assumeIsolated`
        // is this project's established idiom for "delivered on the main thread, but the compiler
        // cannot see it" (same shape as `AppDelegate.swift`'s Timer and `onEventsAvailable`
        // callbacks).
        observation = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersDidChange()
            }
        }
    }

    // MARK: - Connect-time freeze (ADR §5.A, §3 rule 3)

    /// Takes this session's topology snapshot and returns **the one desktop size that may be sent
    /// to the server** -- ADR §3 rule 3's `desktopSizePx`, in remote pixels.
    ///
    /// Shaped as "freeze and return the size" rather than "freeze" + "read the size later" on
    /// purpose: the returned size and `sessionSnapshot` come from the same `NSScreen` read, and
    /// the size cannot be obtained without that freeze having happened. §5.A.4's invariant then
    /// holds for any consumer handed `StaticDisplayTopologyProvider(sessionSnapshot)` -- which is
    /// what the connect path does -- because such a consumer cannot observe a layout other than
    /// the one this size was derived from, for the whole session. Precise scope of the claim: what
    /// is structural is the *pairing* of the returned size with the snapshot; a caller that chose
    /// to hand a consumer this provider (live `currentTopology`) instead would be back to an
    /// ordering guarantee. The connect path deliberately does not.
    ///
    /// Returns `nil` when there is no usable display, and that is the whole of the empty-screen
    /// handling (ADR §5.A.6): the caller must then send **nothing**. It must specifically not
    /// substitute `0 x 0` -- `CRSession.h:285-286` records that 0/0 makes FreeRDP fall back to a
    /// 1024x768 desktop, which is the original invisible-wall fault (`:287-292`) restored under a
    /// new name. `nil` is unrepresentable-as-zero here because `DisplayTopology.init(displays:)`
    /// rejects the empty list outright, so `desktopSizeInRemotePixels` is structurally incapable
    /// of being zero in either dimension.
    func freezeSessionSnapshot() -> DesktopSizeInRemotePixels? {
        let topology = Self.readTopologyFromScreens(reason: "connect")
        currentTopology = topology
        sessionSnapshot = topology
        sessionDesktopSize = topology?.desktopSizeInRemotePixels

        // Diagnostics only -- no behaviour hangs off this. ADR §5.A.6's "not silent" requirement
        // applied to the connect path: a session that starts with no usable display sends no
        // desktop size, and that has to be attributable later.
        if let topology, let size = sessionDesktopSize {
            Self.logger.notice(
                "session desktop size frozen at connect: \(size.width, privacy: .public)x\(size.height, privacy: .public) remote px (adr/0015 §3 rule 3) from \(topology.description, privacy: .public)"
            )
        } else {
            Self.logger.warning(
                "no usable display at connect -- desktopWidth/Height deliberately NOT set (adr/0015 §5.A.6: 0x0 would fall back to FreeRDP's 1024x768 desktop, CRSession.h:285-286)"
            )
        }
        return sessionDesktopSize
    }

    /// Drops the frozen session state, so that a later screen-parameter change reports "no
    /// session" rather than a staleness verdict about a session that is gone.
    ///
    /// Without this, a connect that *fails* leaves `sessionDesktopSize` set and every subsequent
    /// display change claims the (never-established) session's desktop size has gone stale and
    /// advises a reconnect. Harmless in the scaffold App, but `window-smoke` has a real
    /// end-of-run, so the state has an explicit end rather than only an implicit replacement at
    /// the next freeze.
    func endSession() {
        sessionSnapshot = nil
        sessionDesktopSize = nil
    }

    // MARK: - The observer (ADR §5.A.1-A.3)

    /// Reads the new layout, computes the staleness verdict, logs, and emits. **Nothing else.**
    ///
    /// In particular it does not touch `sessionSnapshot`: a session keeps the topology it
    /// negotiated with until it reconnects (ADR §5.A, and §5.A.3's MUST NOT).
    /// The failure mode that choice buys us is "windows are offset after a display change until
    /// the next reconnect" -- diagnosable, explicable, and explained by the very event emitted
    /// here -- instead of "the flip anchor moved while the server's desktop did not", which is
    /// the silent one today's computed property produces.
    private func screenParametersDidChange() {
        let previous = currentTopology
        let current = Self.readTopologyFromScreens(reason: "screen-parameters change")
        currentTopology = current

        // THE ONE NON-DIAGNOSTIC DECISION IN THIS FILE, and therefore the one thing here that no
        // test can reach (this target has no test bundle). It stays rather than moving into
        // `MacdowsCore` for a roster reason, not a design one: `DisplayTopology.swift` is L2's
        // file and wave 2 does not own it. The natural home is a ~3-line pure member such as
        // `DisplayTopology.desktopSizeMatches(_:)`, which `swift test` would cover; that is
        // recorded as a cross-lane follow-up in `task-L6-report.md` rather than landed here.
        // What keeps it acceptable in the meantime: it is one `!=` plus a two-optional guard, the
        // whole blast radius of a wrong answer is one status-label string and one log level, and
        // both nil cases are stated (not inferred) at `connectedDesktopSizeIsStale`.
        //
        // `!=` on the whole value: `DesktopSizeInRemotePixels` is a public `Equatable` (only its
        // memberwise initializer is internal, so this compares without being able to forge one).
        // `current == nil` yields `false` -- see `connectedDesktopSizeIsStale`'s doc comment for
        // why an unusable layout is reported as empty rather than as stale.
        let isStale: Bool
        if let sessionDesktopSize, let current {
            isStale = current.desktopSizeInRemotePixels != sessionDesktopSize
        } else {
            isStale = false
        }

        let change = ScreenParametersChange(
            previous: previous,
            current: current,
            sessionDesktopSize: sessionDesktopSize,
            connectedDesktopSizeIsStale: isStale
        )

        // Logged at `.public` privacy: the payload is local display geometry only, with no host
        // identifier anywhere in it (see `ScreenParametersChange`'s own note and the project red
        // lines). `warning` when a live session's negotiated size has gone stale, because that is
        // the state a later "the windows are all offset" report needs to be correlated against.
        if isStale {
            Self.logger.warning(
                "\(change.description, privacy: .public) -- the session keeps its connect-time desktop size (adr/0015 §5.A: no renegotiation, no resize, no re-send); reconnect to re-negotiate"
            )
        } else {
            Self.logger.notice("\(change.description, privacy: .public)")
        }

        onScreenParametersChange?(change)
    }

    // MARK: - The adapter itself

    /// `NSScreen` -> `DisplayTopology`. **The only `NSScreen` read in the project** (ADR §5.A.5);
    /// `reason` exists so the log says which of the three read points this was.
    private static func readTopologyFromScreens(reason: String) -> DisplayTopology? {
        let screens = NSScreen.screens
        let topology = topology(of: screens)

        // Both branches below are diagnostics: they mutate nothing and change no return value.

        // ADR §2 rule 4 pins both the owner and the granularity of this warning: it is emitted by
        // *this* provider (a topology has many consumption points but exactly one construction
        // point) and **once per construction** -- so once per connect and once per reported
        // change, which is why it is here rather than at a call site. Record only: do not
        // degrade, do not refuse, do not change behaviour. M1 is a measurement batch.
        if let topology, !topology.isUniformScale {
            logger.warning(
                "mixed-scale display layout (\(reason, privacy: .public)): \(topology.description, privacy: .public) -- non-primary displays are being requested at the primary's scale, which the wire cannot express otherwise (adr/0015 §2 rule 4, fixture F3). Recorded only; no behaviour change."
            )
        }

        // A non-empty screen list that still yields no topology is a different fault from a
        // headless Mac, and it must not look the same in the log: `DisplayTopology.init(displays:)`
        // rejects a layout whose primary is not at the mac origin (or is non-finite, or
        // non-positive), which AppKit should never produce -- `NSScreen.screens.first` is the
        // menu-bar screen and sits at (0,0). If it ever does, failing loudly here is the point:
        // silently normalising the origin would offset the entire layout invisibly (ADR §3 rule 4
        // forbids exactly that trade).
        if topology == nil, !screens.isEmpty {
            logger.error(
                "\(screens.count, privacy: .public) screen(s) present but no usable topology (\(reason, privacy: .public)) -- DisplayTopology.init rejected the layout (primary not at the mac origin, or a non-finite/non-positive frame). Treating as no usable display; see adr/0015 §5.A.6"
            )
        }
        return topology
    }

    /// The pure shape of the adapter: four fields per screen, then `MacdowsCore`'s failable
    /// initializer. Takes the screen list as a parameter rather than reading it, so that the read
    /// point stays singular and this mapping is inspectable in isolation.
    ///
    /// Three mapping decisions, none of them this lane's to make:
    ///
    /// * **`origin`/`size` are `NSScreen.frame` verbatim, in mac points** -- ADR §2 rule 1's
    ///   `(originPt, sizePt, scale, isPrimary)`. No normalisation, no rounding: AppKit's frames
    ///   are the ground truth for the space `DisplayTopology.Display` is documented to be in
    ///   (mac screen space, bottom-left origin, Y up).
    /// * **`isPrimary` is `index == 0`**, i.e. `NSScreen.screens.first`, which is this project's
    ///   long-standing definition of "the" screen (adr/0005 §2 and the registry's own note on it)
    ///   and the definition ADR §3's derivation is written against. Explicitly not `NSScreen.main`,
    ///   which tracks keyboard focus -- a different concept, and the one that note exists to warn
    ///   against.
    /// * **`remotePixelsPerPoint` is the screen's `backingScaleFactor`**, and this is the one line
    ///   in the App that implements ADR §3's answer to U3 (the milestone's highest-leverage single
    ///   choice). Answer **P** is "the desktop size is the union in remote pixels, where remote px
    ///   == backing px"; §2 rule 1 says the per-display `scale` "is that screen's
    ///   `backingScaleFactor`". **P is the confirmed contract** (M1 wave-2 controller confirmation,
    ///   2026-09-01: the ADR governs, and the ADR is the reason this reads `backingScaleFactor`
    ///   rather than a literal `1`). §10's U3 row remains the documented rollback and names this
    ///   exact line as its whole cost: choosing **T** (points) instead means "the collector fills
    ///   `remotePixelsPerPoint` with 1 rather than `backingScaleFactor`". So: **were T ever
    ///   adopted, change the one expression below to `1`** -- nothing else in the App, and no
    ///   signature anywhere, moves. On the only hardware this project has (a single natively-1x display,
    ///   `docs/plans/phase3.md:219`) the two answers are numerically identical, which is why the
    ///   ADR records the choice as unobservable in M1 and permanently baked in by the end of wave
    ///   2 -- and why it is spelled out here rather than left as an unremarked `screen.` access.
    ///   `backingPixelsPerPoint` carries the same number but means something different (what the
    ///   Mac renders at); M1 records it and applies it nowhere, because applying it is the
    ///   `DesktopScaleFactor` question ADR §8 assigns to W3 and this milestone forbids.
    static func topology(of screens: [NSScreen]) -> DisplayTopology? {
        DisplayTopology(displays: screens.enumerated().map { index, screen in
            DisplayTopology.Display(
                origin: MacPoint(x: Double(screen.frame.origin.x), y: Double(screen.frame.origin.y)),
                size: MacSize(width: Double(screen.frame.width), height: Double(screen.frame.height)),
                scale: DisplayScale(
                    remotePixelsPerPoint: Double(screen.backingScaleFactor),
                    backingPixelsPerPoint: Double(screen.backingScaleFactor)
                ),
                isPrimary: index == 0
            )
        })
    }
}

/// Conformance rather than a bare `description` member, so `"\(change)"` prints the curated
/// one-liner instead of a reflected memberwise dump -- matching `DisplayTopology` and
/// `DisplayTopology.Display`, which both conform (`DisplayTopology.swift:510`, `:521`).
extension DisplayTopologyProvider.ScreenParametersChange: CustomStringConvertible {}
