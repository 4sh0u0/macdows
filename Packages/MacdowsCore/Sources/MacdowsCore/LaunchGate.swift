/// ADR-0025 §1.6 / §3.1 item 3 / R-7: may the start panel send a launch right now?
///
/// Only when there is a session AND its connection is live. The App supplies both facts from its
/// own state: `hasSession` is `session != nil` (the same test the status item's Disconnect and
/// "Run…" items use), and `isLive` is true only when the reconnect driver's state is `.live` -- the
/// state a connection reaches when its RAIL handshake completes. Every other reading is not live:
/// the driver still `.idle` during a first connect, `.waiting` or `.reconnecting` between legs,
/// `.gaveUp`, or no driver at all. In those states the panel shows its rows disabled with the reason
/// in the header and sends nothing, because a ClientExecute posted before the RAIL channel is up is
/// dropped by the bridge without a result (`CRSession.h`, `-launchProgram:arguments:`).
///
/// Two inputs rather than one so that neither can stand in for the other: a stale `.live` from a
/// driver that outlived its session must not open the gate (ADR-0025 §3.1 item 7 maps every
/// driver state the App can see).
public enum LaunchGate {
    /// `true` only when both are true.
    public static func canLaunch(hasSession: Bool, isLive: Bool) -> Bool {
        hasSession && isLive
    }
}
