import AppKit
import MacdowsCore

// adr/0019 §2 lane C (owner ruling R-3 = K). The product half of "a reconnect is a new session,
// so it gets a new snapshot" -- the three assignments the App's connect path already makes from
// one `NSScreen` read, lifted out of `AppDelegate.connect()`'s inline body into a named function
// a reconnect can call too.
//
// WHY THIS EXISTS AS A SEPARATE FILE RATHER THAN AS A METHOD ON `AppDelegate`. The caller that
// needs it on a reconnect is `ReconnectDriver` (lane B), which holds a `CRSession` and a
// `RemoteWindowRegistry` and deliberately holds NO topology provider: adr/0015 §5.A.5 confines
// every `NSScreen` read in the project to the single App-side `DisplayTopologyProvider`, and a
// driver that owned one would be a second reader in everything but name. So the driver is handed
// a closure, lane D builds that closure out of the App's resident provider and this function, and
// this function is the only place where the three assignments are written down.
//
// WHAT IT IS NOT. It does not reconnect, it does not start or stop anything, and it does not talk
// to the registry -- it returns a provider and lets
// `RemoteWindowRegistry.prepareForReconnect(refreezingTopologyWith:)` install it, which is what
// keeps the ORDER (re-take, then tear down) a property of that method's call shape instead of a
// rule this file would have to ask its callers to remember. It prints nothing: `[topology]` and
// `[config]` are `Tools/window-smoke`'s fixture lines (a knob's evidence and a soak's decoration),
// the product's equivalent is the `os_log` line `freezeSessionSnapshot()` already emits, and
// lifting a fixture line into the product would change the fixture's frozen output.

/// The connect-moment display re-take, as one named step.
///
/// One `NSScreen` read fixes three things at once: the session's frozen topology snapshot, the
/// desktop size the server is told about, and the advertised scale pair. adr/0015 §5.A.4 requires
/// all three to come from the SAME read -- that is the whole invariant, and it is why this is one
/// function with one freeze in it rather than three call sites that each look up what they need.
@MainActor
enum ReconnectTopologyRefresh {

    /// Freezes a new session snapshot, assigns what the next `-start` will send from it, and hands
    /// back the provider the registry should read for the connection about to begin.
    ///
    /// Line for line the same work as the App's connect path (`AppDelegate.connect()`), with one
    /// addition that only a REUSED `CRSession` needs -- see `advertisedDesktopScaleFactor` below.
    ///
    /// ## What each step is, and which rule owns it
    ///
    /// 1. `freezeSessionSnapshot()` — the read. It is the only `NSScreen` access in the project
    ///    (§5.A.5) and it both stores the snapshot and returns the desktop size derived from it,
    ///    so the pairing of the two is structural rather than an ordering the caller maintains.
    ///    `nil` means no usable display.
    /// 2. The desktop pair — §3 rule 3's `desktopSizePx`, in remote pixels. NOTHING is assigned
    ///    when there is no usable display (§5.A.6): `0 x 0` makes FreeRDP fall back to a 1024x768
    ///    desktop (`CRSession.h:285-286`), which is the original invisible-wall fault under a new
    ///    name. On a reconnect that means the connection keeps the size the previous freeze gave
    ///    it — stale, and reported as such by the provider's own log line, rather than silently
    ///    wrong. `UInt32(clamping:)` cannot actually clamp (`DisplayTopology` guarantees
    ///    `0 < value <= 65535`) and is written that way so a relaxed bound degrades instead of
    ///    trapping, exactly as the connect path spells it.
    /// 3. The advertised scale pair — ADR-0018 U-1 (owner ruled D), resolved from the SAME frozen
    ///    snapshot the desktop size came from. Both fields are assigned together because
    ///    `CRSession` sets neither setting unless both are non-zero.
    ///
    /// THE ONE ADDITION OVER THE CONNECT PATH, and the reason it is not a divergence: the `else`
    /// arm ZEROES the advertised pair. A fresh connect builds a fresh `CRSession`, so "assign
    /// nothing" and "assign zero" are the same state there. A reconnect reuses one
    /// (`-restartForReconnectPreparing:` restarts the session it is called on), so a pair left
    /// over from an earlier freeze would be read by the next `-start` while the current layout
    /// resolves to nothing at all. `Tools/window-smoke` registered exactly this on its own cycle
    /// path (gate w3-lane-e r1 m-1) and zeroes for the same reason. The desktop pair is
    /// deliberately NOT zeroed alongside it — §5.A.6 forbids sending `0 x 0`, and zeroing the two
    /// is what sending `0 x 0` looks like from here.
    ///
    /// - Parameter session: the session about to be restarted. Only the three settings the connect
    ///   path assigns are touched; nothing is started, stopped or sent.
    /// - Parameter topology: the App's resident provider — the project's single `NSScreen` reader.
    /// - Returns: `StaticDisplayTopologyProvider` over the snapshot just frozen, for
    ///   `RemoteWindowRegistry.prepareForReconnect(refreezingTopologyWith:)` to install. A static
    ///   snapshot rather than `topology` itself, for the reason the connect path states at its own
    ///   registry construction: handing over the live provider would leave §5.A.4 resting on two
    ///   statements running in the same turn, and would let a later re-take inside the registry
    ///   pick up a layout the (never re-sent) desktop size no longer matches.
    ///
    ///   GATE r1 m-2, registered rather than acted on: because Swift promotes `T` to `T?` in a
    ///   `() -> T?` return position, this could be declared non-optional and would still feed
    ///   `refreezingTopologyWith:` — and the type would then say "never nil" by itself. The
    ///   optional stays because the blueprint froze this signature as the closure's own type, and
    ///   because one type spelled two ways at the two ends of the same seam is harder to read than
    ///   one spelled once. What the type does not say, the sentence below and C-8's pin do.
    ///
    ///   Non-`nil` even when there is no usable display, where it wraps `nil` and therefore
    ///   reports "no usable display" to the registry. That is deliberate and is the connect path's
    ///   own behaviour verbatim: a connect made in this state hands the registry
    ///   `StaticDisplayTopologyProvider(nil)` too. Returning `nil` here instead would leave the
    ///   registry anchored on the PREVIOUS session's layout — a state a fresh connect can never
    ///   produce, and one no rule asks for. The optional is in the signature only because the
    ///   `refreezingTopologyWith:` closure it feeds uses `nil` for "keep what you have", which is
    ///   the *fixture's* answer (it hands the registry a live provider), not this function's.
    ///
    ///   The result is not marked `@discardableResult` on purpose: discarding it is precisely the
    ///   defect this lane exists to remove — a caller that freezes a new layout and never hands it
    ///   over bumps the registry's freeze count while the registry keeps reading the old one.
    static func refreeze(
        session: CRSession,
        topology: DisplayTopologyProvider
    ) -> (any DisplayTopologyProviding)? {
        let desktop = topology.freezeSessionSnapshot()
        if let desktop {
            session.desktopWidth = UInt32(clamping: desktop.width)
            session.desktopHeight = UInt32(clamping: desktop.height)
        }
        if let scale = topology.sessionSnapshot?.rasterScale,
           let advertised = ScaleAdvertisement.productDefault(rasterScale: scale) {
            session.advertisedDesktopScaleFactor = advertised.desktopScaleFactor
            session.advertisedDeviceScaleFactor = advertised.deviceScaleFactor
        } else {
            session.advertisedDesktopScaleFactor = 0
            session.advertisedDeviceScaleFactor = 0
        }
        return StaticDisplayTopologyProvider(topology.sessionSnapshot)
    }
}
