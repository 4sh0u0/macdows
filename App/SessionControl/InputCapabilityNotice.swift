import Foundation

/// UI slice ④ (adr/0011 §2 "告警一次并对用户可见"; UI-1 spec §4.3): when the input-method banner
/// shows. The registry already logs the degradation once per connection and drops the IME lane
/// (`RemoteWindowRegistry`'s own gate, untouched); this is only the user-visible half, and it only
/// READS the session's capability, through the closure it is handed.
///
/// The rule: on the first `.live` of a connection leg the capability is read ONCE. If the
/// connection did not accept Unicode input, the banner shows (`observe` returns true) and the
/// status bar reads `dg_bar` (`degraded`). Nothing else on that leg shows it again -- a Dismiss is
/// final for the leg. Any other state ends the leg, so the next leg (a reconnect) or the next
/// connection reads again; `reset()` is the chain's end.
struct InputCapabilityNotice: Equatable {
    /// Whether this leg's capability has been read.
    private(set) var checkedThisLeg = false
    /// Whether this leg's connection refused Unicode input.
    private(set) var degraded = false

    /// Returns true exactly when the banner should be shown now.
    mutating func observe(_ state: ReconnectDriver.State, unicodeInputSupported: () -> Bool) -> Bool {
        guard case .live = state else {
            reset()
            return false
        }
        guard !checkedThisLeg else { return false }
        checkedThisLeg = true
        degraded = !unicodeInputSupported()
        return degraded
    }

    /// The chain ended: the next connection reads again.
    mutating func reset() {
        checkedThisLeg = false
        degraded = false
    }
}
