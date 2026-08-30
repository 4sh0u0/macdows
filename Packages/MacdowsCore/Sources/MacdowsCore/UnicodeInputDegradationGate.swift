import Foundation

/// What `UnicodeInputDegradationGate` wants its consumer to do with one IME commit
/// (`RemoteWindowRegistry`, adr/0011 §2). Mirrors `CommandKeyMapperOutput`'s own "pure
/// state machine decides, dumb consumer performs the side effect" split -- the decision to
/// warn lives here (so "exactly once" is an offline-testable property of a pure type), the
/// actual `Logger` call lives in the registry (which is also the only side holding the
/// committed text, whose LENGTH is all a warning may ever mention).
public enum UnicodeInputDegradationDecision: Sendable, Equatable {
    /// The server negotiated `INPUT_FLAG_UNICODE`: enqueue this commit exactly as if this
    /// gate didn't exist. adr/0011 §2's supported path is a strict no-op -- zero behavior
    /// change relative to the pre-gate pipeline.
    case forward
    /// The server did NOT negotiate it (adr/0011 §0b: `freerdp_input_send_unicode_keyboard_event`
    /// would just `WLog_WARN` and return `FALSE`, i.e. silently lose the text): drop this
    /// commit BEFORE it ever enters the keyboard lane's buffer, and -- iff `warn` -- emit
    /// the one degradation warning this connection gets (adr/0011 §2: "IME通路整体停用、告警
    /// 一次并对用户可见... 不静默丢字").
    case drop(warn: Bool)
}

/// adr/0011 §2's degradation discipline ("降级纪律"), as a pure state machine: read the
/// connection's negotiated `FreeRDP_UnicodeInput` capability exactly once, and when it's
/// false disable the whole IME lane -- warning exactly once, counting every dropped commit,
/// and never letting a single character silently reach (or fail to reach) the wire.
///
/// No AppKit, no `CRSession`, no `Date()` -- same offline-testable shape as
/// `FocusAuthority`/`CommandKeyMapper`/`ModifierKeyTracker`; `RemoteWindowRegistry` owns one
/// session-level instance and performs every side effect the returned decision implies.
///
/// **Why the capability is read through a closure instead of being pushed in**: adr/0011 §2
/// says "连接建立后读一次" -- exactly once per connection, and only if it matters. The
/// consumer's source for that answer (`CRSession.unicodeInputSupported`) is only meaningful
/// after the connect path on T_rdp has set it, so this gate reads it lazily, at the first
/// commit that would actually need it, and caches the answer for the rest of the
/// connection. `readCapability` is therefore called at most once per connection generation
/// (offline-asserted in this type's own tests, by counting calls) -- every later commit in
/// the same connection is decided from `unicodeInputSupported` below without re-reading.
///
/// **Deliberately NOT a fallback mechanism**: adr/0011 §2 rules out synthesizing equivalent
/// characters from scancodes ("不做'用扫描码合成等价字符'的兜底 -- 那需要服务端布局知识, 我们恰恰
/// 没有"), so `.drop` really is a drop. What this type buys is that the loss is *counted and
/// announced* instead of disappearing inside FreeRDP's own per-event `WLog_WARN`.
public final class UnicodeInputDegradationGate {
    /// The capability answer cached for the CURRENT connection: `nil` until the first commit
    /// forces a read (or after `reset()`), then the value `readCapability` returned. Exposed
    /// so the registry's diagnostics can report "not yet read this connection" as a distinct
    /// state from "read, and it was false" -- a harness that never typed anything must not
    /// look like a harness that hit the degradation path.
    public private(set) var unicodeInputSupported: Bool?

    /// Cumulative across this instance's whole lifetime, NOT reset by `reset()` -- mirrors
    /// `RemoteWindowRegistry.zOrderArraysReceivedCount`'s own "how much has this registry
    /// ever done, not per-connection state" precedent. A post-shutdown diagnostics read
    /// (which necessarily happens after the reconnect/teardown that calls `reset()`) must
    /// still see the real totals, otherwise adr/0011 §5 item 7's acceptance ("降级告警恰好一
    /// 次且无静默丢字") has nothing left to assert against.
    public private(set) var warningsEmitted = 0
    /// Cumulative, same lifetime rule as `warningsEmitted` above. Counts IME *commits*
    /// (whole strings, adr/0011 §1's "一次提交要么整体上线要么整体丢弃"), not characters or
    /// UTF-16 code units -- one 50-character commit is one dropped commit, matching the
    /// keyboard lane's own one-slot-per-commit accounting.
    public private(set) var droppedCommits = 0

    /// Per-connection: whether the one warning this connection gets has already been handed
    /// out. Distinct from `warningsEmitted > 0` precisely because that counter survives
    /// `reset()` and this flag must not -- a fresh connection re-reads the capability and,
    /// if it is still unsupported, is entitled to warn again (the user is looking at a new
    /// session; a warning suppressed by the previous one's bookkeeping would be a silent
    /// loss by another name).
    private var hasWarnedThisConnection = false

    public init() {}

    /// One IME commit arriving at the capture site, BEFORE it is enqueued anywhere.
    /// `readCapability` is invoked at most once per connection (see this type's own doc
    /// comment) and must answer with the connection's negotiated `FreeRDP_UnicodeInput`.
    ///
    /// The caller must treat `.drop` as final: nothing may be buffered "just in case",
    /// because anything sitting in the keyboard lane's FIFO can later be flushed to the wire
    /// by a gate-open (adr/0012 §2), which is exactly the silent-loss-or-worse shape
    /// adr/0011 §2 forbids.
    public func evaluateCommit(readCapability: () -> Bool) -> UnicodeInputDegradationDecision {
        let supported: Bool
        if let cached = unicodeInputSupported {
            supported = cached
        } else {
            supported = readCapability()
            unicodeInputSupported = supported
        }
        guard !supported else { return .forward }

        droppedCommits += 1
        guard !hasWarnedThisConnection else { return .drop(warn: false) }
        hasWarnedThisConnection = true
        warningsEmitted += 1
        return .drop(warn: true)
    }

    /// Connection rollover (adr/0005 §4's reconnect / a generation bump): forget the cached
    /// capability and re-arm the one-warning budget, keeping the cumulative counters. The
    /// next commit re-reads the capability, because the next connection genuinely may
    /// negotiate a different answer -- and if it doesn't, the user is owed the warning again
    /// for that new session.
    public func reset() {
        unicodeInputSupported = nil
        hasWarnedThisConnection = false
    }
}
