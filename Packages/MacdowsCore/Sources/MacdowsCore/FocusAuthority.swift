import Foundation

/// Classifies MS-RDPERP's `MonitoredDesktop.activeWindowId` raw wire value into its three
/// distinct meanings (adr/0012 §3) — shared vocabulary between `FocusAuthority`'s own state
/// machine and any passive recorder of "what the server last said" (e.g.
/// `RemoteWindowRegistry.ServerDesktopState`), so both sides classify the same raw value the
/// same way instead of each re-deriving the two sentinel checks independently.
public enum ServerActiveWindow: Sendable, Equatable {
    /// `0xFFFFFFFF` — no window on the monitored desktop currently has focus (adr/0008 §0).
    /// Distinct from `.desktopFocused`: this means focus isn't on this monitored desktop at
    /// all, not that the desktop itself is what's focused.
    case unmonitored
    /// `0` — the desktop itself has focus (adr/0012 §3): a real, independent state, not "no
    /// answer yet" and not a window. Must never be folded into `.unmonitored`, and must
    /// never be compared as if it were `.window(0)`.
    case desktopFocused
    /// Any other raw value — a window id, whether or not this client happens to know about
    /// (i.e. render) that window (adr/0012 §3's "no fifth state" clause: an id absent from
    /// the registry is still `.window`, not some other case — the *consumer* decides
    /// key/no-key, this type just reports what the wire said).
    case window(UInt32)

    public init(rawActiveWindowId raw: UInt32) {
        switch raw {
        case 0xFFFF_FFFF: self = .unmonitored
        case 0: self = .desktopFocused
        default: self = .window(raw)
        }
    }
}

/// One physical keyboard event, in the shape `FocusAuthority`'s session-level FIFO buffers
/// them (adr/0012 §2: "闸的粒度是整条键盘车道（会话级FIFO），不是单个按键"). Mirrors
/// `RemoteWindowInputEvent`'s keyDown/keyUp/flagsChanged cases (App-side, AppKit-dependent)
/// without importing AppKit — `.modifierKey` is a single already-diffed transition (one
/// `KeyboardLaneEvent` per bit that actually flipped), matching what
/// `ModifierKeyTracker.transitions(from:to:)` already produces and what
/// `CRSession.send(_:down:)`'s wire protocol itself sends one message per. The caller (
/// `RemoteWindowRegistry`) computes that diff against its own session-level held-modifiers
/// state at capture time, before ever calling into `FocusAuthority` — this type doesn't need
/// to know AppKit's `NSEvent.ModifierFlags` shape, only `MacdowsCore.ModifierKeySet`.
public enum KeyboardLaneEvent: Sendable, Equatable {
    case keyDown(macKeyCode: UInt16)
    case keyUp(macKeyCode: UInt16)
    case modifierKey(ModifierKeySet, down: Bool)
    /// adr/0011 §1: an already-fully-composed IME commit string (an `NSTextInputClient
    /// -insertText:` result), carried whole rather than as individual code-unit events --
    /// deliberate, not a shortcut: adr/0012 §2's 64-event buffer cap stays meaningful this
    /// way (a 50-character commit costs 1 slot, not 50), and a single commit either lands
    /// on the wire atomically or is dropped atomically, never half-sent. Per-UTF-16-code-
    /// unit expansion happens at the single point this whole lane actually goes out the
    /// door (`RemoteWindowRegistry.sendKeyboardLaneEvent` -> `CRSession.sendUnicodeText:`),
    /// not here and not at capture time. Flows through this same FIFO -- same gate, same
    /// buffer, same drop/flush semantics as the other three cases; `FocusAuthority` itself
    /// needs no special-casing for it (adr/0011 §1: "与既有三个case同队列、同闸门、同缓冲上限").
    case unicodeText(String)
}

/// `FocusAuthority`'s four states (adr/0012 §3, exactly — "不新增第五态"). A server value
/// naming a window unknown to the consumer's registry is still `.converged` — the consumer
/// decides whether it has a local window to actually make key; this type just reports the
/// authoritative truth.
public enum FocusState: Sendable, Equatable {
    /// The server's `activeWindowId` and the local optimistic target agree. The keyboard
    /// lane gate is open in this state, and *only* this state.
    case converged(windowId: UInt32)
    /// A local activation (`localActivate`) is in flight toward `target`, not yet confirmed
    /// by a matching `serverDesktopUpdate`. `epochStart`/`hardDeadline` are absolute times on
    /// the same clock `at:`/`now:` parameters use. `reArmCount` is how many periodic
    /// `sendActivate` re-arms have already fired for this epoch (0 until the first one) —
    /// re-arms are periodic, not single-shot (2026-08-23 real-host soak follow-up: healthy-
    /// host reconnect churn still saw close-legs converge *after* a single 500ms re-arm but
    /// *before* the old 5000ms hard deadline, just later than one re-arm alone could recover
    /// from — periodic re-arm at the same 500ms cadence keeps nudging `-activateWindow:`
    /// throughout the whole window instead of giving up on retrying after the first miss).
    /// `coldStart` is `true` when this is the first epoch since `generationReset()` to reach
    /// `.converging` without any real window convergence yet observed — see `hardDeadline`'s
    /// own two possible values on `FocusAuthority` (`hardDeadlineInterval` /
    /// `coldStartHardDeadlineInterval`) for why that epoch alone gets a longer fuse.
    case converging(target: UInt32, epochStart: TimeInterval, hardDeadline: TimeInterval, coldStart: Bool, reArmCount: Int)
    /// The server's `activeWindowId` is `0` — the desktop itself has focus. Gate closed (no
    /// legitimate remote window target to address keyboard input to).
    case desktopFocused
    /// The server's `activeWindowId` is `0xFFFFFFFF`, or no server truth has ever been
    /// observed yet (the initial state — adr/0012 §2: before any real `MonitoredDesktop`
    /// order arrives, nothing should be assumed converged). Gate closed. The *only* way out
    /// of this state is a real `serverDesktopUpdate` call — `tick(now:)` alone can never
    /// open the gate (adr/0012 §2's reconnect discipline: "超时兜底不得替代服务端真相").
    case unmonitored
}

/// What `FocusAuthority` wants its consumer to do, in the order returned. `RemoteWindowRegistry`
/// executes these against `CRSession`/AppKit; `FocusAuthority` itself touches neither (adr/0012
/// §4: "纯状态机进Packages/MacdowsCore/，RemoteWindowRegistry只做消费与副作用").
public enum FocusAuthorityEffect: Sendable, Equatable {
    /// Re-send `-activateWindow:` for `windowId`. Fired once immediately when
    /// `localActivate` starts converging toward it, then again periodically every
    /// `FocusAuthority.softDeadlineInterval` (500ms) while still converging — up to ~9 more
    /// times in a steady-state 5000ms window, ~19 more in a cold-start 10000ms one — until
    /// either convergence or the hard deadline (2026-08-23 soak follow-up: a single re-arm
    /// wasn't enough for closes that converged after 500ms but before the old 5000ms
    /// deadline; periodic re-arm keeps nudging the whole way instead of firing once and
    /// waiting).
    case sendActivate(windowId: UInt32)
    /// Give `windowId` local key/main status — maps to `RemoteWindow.activateLocally()`.
    case makeKey(windowId: UInt32)
    /// `windowId` should no longer be treated as locally key/authoritative. Best-effort on
    /// the AppKit side (there is no clean "force resign while staying visible" primitive);
    /// see `RemoteWindowRegistry`'s own doc comment on how this maps.
    case resignKey(windowId: UInt32)
    /// The gate is open (or just opened): replay these buffered events, in order, exactly as
    /// if they had never been gated. Always non-empty when this case is returned.
    case flushBufferedInput([KeyboardLaneEvent])
    /// Discard whatever was buffered for the epoch that just ended abnormally (`count` for
    /// observability — 0 is valid: an epoch can end with nothing ever having been typed).
    /// When `withModifierRelease` is true, the consumer must *also* run its own
    /// physical-modifier release-all flow (mirrors the `.focusLost` handling
    /// `RemoteWindowRegistry` already has for the same reason: `FocusAuthority` doesn't
    /// track *which* physical modifiers are currently held on the real keyboard — that
    /// bookkeeping intentionally stays with the consumer, matching how
    /// `ModifierKeyTracker.releaseAll(_:)` already needs an externally-tracked held-set
    /// rather than owning one itself). `withModifierRelease` is `true` for both triggers
    /// that can produce this effect (epoch supersede, hard rollback) — never for the
    /// "no legitimate target, drop a single orphaned keystroke" path, which never had
    /// anything meaningfully "in flight" to begin with.
    case dropBufferedInput(count: Int, withModifierRelease: Bool)
    case warn(FocusAuthorityWarning)
}

public enum FocusAuthorityWarning: Sendable, Equatable {
    /// The FIRST 500ms re-arm mark elapsed before converging on `target`. Fired once per
    /// epoch, on the first periodic re-arm only — every subsequent 500ms re-arm in the same
    /// epoch still fires its own `sendActivate` effect, but deliberately does *not* repeat
    /// this warning (2026-08-23 soak follow-up: periodic re-arm can fire up to ~19 times in
    /// a cold-start epoch; a warn on every single one would be log spam for what's already
    /// known to be a slow-but-recovering epoch after the first miss). `totalMisses` is a
    /// lifetime (not per-epoch) counter of *epochs* that missed their first re-arm mark —
    /// useful for a harness to report an aggregate rate without `FocusAuthority` itself
    /// needing a separate "reset stats" API.
    case softDeadlineMissed(target: UInt32, totalMisses: Int)
    /// The hard deadline (`FocusAuthority.hardDeadlineInterval` or
    /// `coldStartHardDeadlineInterval`, whichever this epoch used) elapsed before converging
    /// on `target` — the safety-valve case adr/0012 §1 calls out as "触发率本身即bug信号
    /// （稳态目标0次）": a real occurrence of this is worth surfacing loudly, not silently
    /// absorbing.
    case hardRollback(target: UInt32)
    /// The 64-event keyboard-lane buffer was already full; this incoming event was refused
    /// (the newest, per adr/0012 §2 — the already-buffered prefix is kept intact).
    /// `totalDropped` is scoped to the current converging epoch, resetting when that epoch
    /// ends (converge, supersede, or hard rollback).
    case bufferOverflow(totalDropped: Int)
}

/// Server-authoritative + local-optimistic-prediction focus state machine (adr/0012). Pure:
/// no AppKit, no `CRSession`, no `Date()` — every method that needs "now" takes it as a
/// parameter, mirroring `ModifierKeyTracker`'s own no-AppKit precedent, so this is directly
/// unit-testable and replayable offline. Unlike `ModifierKeyTracker` (stateless, pure static
/// functions over caller-owned state), this type owns real persistent state itself — the
/// current `FocusState`, the gated keyboard-lane FIFO, and the last-observed server truth —
/// because adr/0012 §4 calls this out explicitly as "纯状态机", not a stateless diff utility.
///
/// `RemoteWindowRegistry` (adr/0012 §4: "只做消费与副作用") is the only consumer: it owns one
/// `FocusAuthority` instance for the session's lifetime, feeds it `serverDesktopUpdate`/
/// `localActivate`/`enqueueKeyboardEvent`/`tick`/`generationReset` calls, and executes every
/// returned `FocusAuthorityEffect` against `CRSession`/AppKit. `FocusAuthority` itself makes
/// no assumption about *when* `tick(now:)` gets called beyond "at some point after each
/// deadline elapses" — a caller silent for the whole window and one that calls `tick` on
/// every drained event produce identical outcomes, just observed at different granularities.
public final class FocusAuthority {
    /// Input-gate + periodic-re-arm cadence (adr/0012 §1): covers the observed p95 (329ms).
    public static let softDeadlineInterval: TimeInterval = 0.5
    /// Steady-state safety-valve rollback window (adr/0012 §1): ~1.3x the observed max
    /// (3754ms). Used for every converging epoch except the cold-start one below.
    public static let hardDeadlineInterval: TimeInterval = 5.0
    /// Cold-start safety-valve rollback window — 2x `hardDeadlineInterval`. 2026-08-23
    /// real-host soak evidence (two healthy-host reconnect-churn soaks, all close-leg
    /// failures in C-mode/reconnect cycles, zero from the close-probe A/B experiment):
    /// immediately post-reconnect the server's own `MonitoredDesktop.activeWindowId` flaps
    /// desktop&lt;-&gt;unmonitored for several seconds — it eats the very first `ClientActivate`
    /// sent during session setup — and convergence, when it happens at all, lands *after*
    /// the steady-state 5000ms deadline but comfortably before 10000ms. Applied only to the
    /// first converging epoch since the last `generationReset()` that hasn't yet reached a
    /// real window convergence (`FocusState.converging`'s own `coldStart` flag) — once any
    /// epoch has actually converged on a window, the server's MonitoredDesktop channel has
    /// proven itself settled, and every later epoch in the same connection goes back to the
    /// tighter steady-state window.
    public static let coldStartHardDeadlineInterval: TimeInterval = 10.0
    /// adr/0012 §2: "缓冲上限64事件".
    private static let bufferCap = 64

    public private(set) var state: FocusState = .unmonitored

    /// The most recently classified server truth, tracked independently of `state` — needed
    /// because a hard rollback must realign to whatever the server *most recently* said
    /// (which, per adr/0012 §1's `nil -> 0 -> 66128` real-capture example, can differ from
    /// both the converging target *and* whatever `state` was immediately before this epoch
    /// started — every transitional report along the way updates this, even though none of
    /// them touch `state` while converging). Reset to `.unmonitored` by `generationReset()`
    /// in lockstep with `state`, so a hard rollback that fires *before* any fresh post-
    /// reconnect server truth arrives lands on `.unmonitored`, never on stale pre-reconnect
    /// data (adr/0012 §2: "超时兜底不得替代服务端真相").
    private var lastServerTruth: ServerActiveWindow = .unmonitored

    /// The gated keyboard-lane FIFO for the current `.converging` epoch. Always empty
    /// outside `.converging` (`.converged` never buffers — see `enqueueKeyboardEvent`;
    /// `.desktopFocused`/`.unmonitored` drop on arrival rather than accumulate — same
    /// method).
    private var buffer: [KeyboardLaneEvent] = []
    /// Overflow count for the *current* epoch only — reset whenever `buffer` is cleared
    /// (converge, supersede, or hard rollback all clear both together).
    private var currentEpochDroppedCount = 0
    /// Lifetime (not per-epoch) soft-deadline-miss counter — see
    /// `FocusAuthorityWarning.softDeadlineMissed`'s own doc comment for why this doesn't
    /// reset per epoch.
    private var lifetimeSoftMissCount = 0
    /// Whether `state` has reached `.converged(windowId:)` (a genuine window convergence —
    /// NOT `.desktopFocused`/`.unmonitored`, which are exactly the flapping reports
    /// cold-start exists to stay patient through) at any point since the last
    /// `generationReset()`. Drives `coldStartHardDeadlineInterval` vs `hardDeadlineInterval`
    /// selection in `localActivate` — see `FocusState.converging`'s `coldStart` doc comment.
    private var hasConvergedSinceReset = false

    public init() {}

    /// The window currently holding (or about to hold, optimistically) local key/main
    /// status, if any — `.converged`'s and `.converging`'s target, `nil` for the two
    /// no-window states. Shared by `localActivate` (to know what to `resignKey` when a new
    /// target supersedes) and `serverDesktopUpdate` (same question, for a server-initiated
    /// follow with nothing in flight).
    private var currentlyKeyedWindow: UInt32? {
        switch state {
        case .converged(let id): return id
        case .converging(let target, _, _, _, _): return target
        case .desktopFocused, .unmonitored: return nil
        }
    }

    // MARK: - Inputs

    /// One `MonitoredDesktop` order's `activeWindowId`, decoded to the raw wire value (the
    /// caller does *not* pre-classify it — `ServerActiveWindow.init(rawActiveWindowId:)`
    /// happens here, once, so every call site agrees on the 0/0xFFFFFFFF/window split).
    public func serverDesktopUpdate(rawActiveWindowId raw: UInt32, at now: TimeInterval) -> [FocusAuthorityEffect] {
        let truth = ServerActiveWindow(rawActiveWindowId: raw)
        lastServerTruth = truth

        if case .converging(let target, _, _, _, _) = state {
            guard case .window(let id) = truth, id == target else {
                // Transitional (adr/0012 §1 row 2): a local activation is in flight and the
                // server reported something other than its target. Neither a rollback nor a
                // target change — only a genuine timeout (tick(_:)'s hard-deadline branch)
                // can end this epoch abnormally. `lastServerTruth` above is still updated,
                // so a *later* hard rollback realigns to this value if nothing better
                // arrives before then.
                return []
            }
            state = .converged(windowId: target)
            hasConvergedSinceReset = true
            let flushed = buffer
            buffer.removeAll()
            currentEpochDroppedCount = 0
            return flushed.isEmpty ? [] : [.flushBufferedInput(flushed)]
        }

        // No local activation in flight (adr/0012 §1 row 1): follow the server's own truth
        // immediately, whatever it now says — this is not a conflict (e.g. a modal dialog
        // stealing focus on the remote side), so local key state re-syncs to match.
        let previouslyKeyed = currentlyKeyedWindow
        switch truth {
        case .window(let id):
            guard previouslyKeyed != id else { return [] }
            state = .converged(windowId: id)
            hasConvergedSinceReset = true
            return (previouslyKeyed.map { [FocusAuthorityEffect.resignKey(windowId: $0)] } ?? []) + [.makeKey(windowId: id)]
        case .desktopFocused:
            guard case .desktopFocused = state else {
                state = .desktopFocused
                return previouslyKeyed.map { [.resignKey(windowId: $0)] } ?? []
            }
            return []
        case .unmonitored:
            guard case .unmonitored = state else {
                state = .unmonitored
                return previouslyKeyed.map { [.resignKey(windowId: $0)] } ?? []
            }
            return []
        }
    }

    /// A local optimistic activation (adr/0012 §0: "本地乐观预测今天已经存在" — mouseDown's
    /// unconditional `session.activateWindow` + `activateLocally()`; this ADR doesn't
    /// introduce that prediction, it puts authority and rollback around it). Always emits at
    /// least `.sendActivate`; emits `.makeKey` too except for the same-target-already-
    /// converging nudge case below.
    public func localActivate(windowId: UInt32, at now: TimeInterval) -> [FocusAuthorityEffect] {
        switch state {
        case .converged(let current) where current == windowId:
            // Redundant activation on an already-focused window (matches the existing
            // mouseDown precedent: "a redundant Activate/makeKey ... is a fire-and-forget
            // no-op cost, not a correctness risk") — reaffirm without touching the gate.
            return [.sendActivate(windowId: windowId), .makeKey(windowId: windowId)]

        case .converging(let target, _, _, _, _) where target == windowId:
            // A second click on a window that's merely slow to converge, not a new intent —
            // a courtesy re-nudge, not a new epoch: doesn't reset the buffer or deadlines
            // (dropping interim keystrokes and restarting the hard-rollback clock over a
            // redundant click on the SAME target would be needless data loss). Deliberate
            // design choice; adr/0012 is silent on this exact sub-case.
            return [.sendActivate(windowId: windowId)]

        default:
            var effects: [FocusAuthorityEffect] = []
            if case .converging = state {
                // adr/0012 §1 row 3: a newer local activation supersedes the in-flight one —
                // the old epoch's buffer is discarded (with a modifier release, same as hard
                // rollback: adr/0012 §2's "宁可丢字...更不可留下卡死的修饰键" applies here too).
                effects.append(dropBufferAndReleaseModifiers())
            }
            if let previouslyKeyed = currentlyKeyedWindow {
                effects.append(.resignKey(windowId: previouslyKeyed))
            }
            buffer.removeAll()
            currentEpochDroppedCount = 0
            // 2026-08-23 soak follow-up: cold-start gets the longer fuse -- see
            // `coldStartHardDeadlineInterval`'s own doc comment for the evidence.
            let coldStart = !hasConvergedSinceReset
            state = .converging(
                target: windowId,
                epochStart: now,
                hardDeadline: now + (coldStart ? Self.coldStartHardDeadlineInterval : Self.hardDeadlineInterval),
                coldStart: coldStart,
                reArmCount: 0
            )
            effects.append(.sendActivate(windowId: windowId))
            effects.append(.makeKey(windowId: windowId))
            return effects
        }
    }

    /// One captured keyboard-lane event. Gate open (`.converged`) passes it straight
    /// through, one at a time, in arrival order — "收敛后立即按序排干... 稳态下闸门零额外延迟"
    /// (adr/0012 §2). Every other state buffers or drops it; see each case below.
    public func enqueueKeyboardEvent(_ event: KeyboardLaneEvent, at now: TimeInterval) -> [FocusAuthorityEffect] {
        switch state {
        case .converged:
            return [.flushBufferedInput([event])]

        case .converging:
            guard buffer.count < Self.bufferCap else {
                // adr/0012 §2: "超出丢弃最新的（保住已录入的前缀）并计数" — the incoming event
                // is the one dropped; the already-buffered prefix is untouched.
                currentEpochDroppedCount += 1
                return [.warn(.bufferOverflow(totalDropped: currentEpochDroppedCount))]
            }
            buffer.append(event)
            return []

        case .desktopFocused, .unmonitored:
            // No local activation in flight and no legitimate remote target to buffer
            // toward — nothing will ever cause this to flush (unlike `.converging`, these
            // two states have no deadline/expiry concept at all). A keystroke captured here
            // can only be stale/orphaned input from a window that happens to still be
            // locally key even though the true remote focus has moved elsewhere (adr/0012
            // §3's own "不抢本地macOS应用的焦点" note — FocusAuthority deliberately never
            // forces local resignation, so this is a real, expected edge case, not a bug).
            // Drop immediately rather than accumulating with no expiry.
            return [.dropBufferedInput(count: 1, withModifierRelease: false)]
        }
    }

    /// Must be called at some point after each periodic re-arm mark and the hard deadline
    /// elapse — no assumption is made about cadence (see this type's own doc comment). A
    /// no-op whenever `state` isn't `.converging`, so calling this speculatively/redundantly
    /// (e.g. once per drained event, "just in case", or from more than one still-pending
    /// scheduled timer at once) is always safe. If called late enough to have skipped
    /// several re-arm marks at once (a genuinely quiet server, or an infrequent caller), all
    /// the skipped `sendActivate` effects are emitted together, in order, in one call — this
    /// keeps re-arm marks anchored to the epoch's own fixed schedule (`epochStart + N *
    /// softDeadlineInterval`) rather than drifting to "500ms after whenever tick() actually
    /// got called".
    public func tick(now: TimeInterval) -> [FocusAuthorityEffect] {
        guard case .converging(let target, let epochStart, let hard, let coldStart, let reArmCount) = state
        else { return [] }

        if now >= hard {
            return hardRollback(target: target)
        }

        var newReArmCount = reArmCount
        var effects: [FocusAuthorityEffect] = []
        while now >= epochStart + Self.softDeadlineInterval * TimeInterval(newReArmCount + 1) {
            newReArmCount += 1
            effects.append(.sendActivate(windowId: target))
            if newReArmCount == 1 {
                // adr/0012 §1 + 2026-08-23 follow-up: warn once per epoch, on the FIRST
                // re-arm only -- see FocusAuthorityWarning.softDeadlineMissed's own doc
                // comment for why every later periodic re-arm stays silent.
                lifetimeSoftMissCount += 1
                effects.append(.warn(.softDeadlineMissed(target: target, totalMisses: lifetimeSoftMissCount)))
            }
        }
        if newReArmCount != reArmCount {
            state = .converging(target: target, epochStart: epochStart, hardDeadline: hard, coldStart: coldStart, reArmCount: newReArmCount)
        }
        return effects
    }

    /// A session generation bump (adr/0005 §4) — resets to `.unmonitored` unconditionally,
    /// discarding any in-flight epoch (adr/0012 §2's reconnect discipline: the gate reopens
    /// *only* on a subsequent real `serverDesktopUpdate`, never by any timeout, and
    /// `lastServerTruth` is reset in lockstep so a hard rollback racing a not-yet-arrived
    /// post-reconnect server truth can never land on stale pre-reconnect data).
    public func generationReset() -> [FocusAuthorityEffect] {
        var effects: [FocusAuthorityEffect] = []
        if case .converging(let target, _, _, _, _) = state {
            effects.append(.resignKey(windowId: target))
            effects.append(dropBufferAndReleaseModifiers())
        }
        state = .unmonitored
        lastServerTruth = .unmonitored
        // 2026-08-23 follow-up: a fresh connection gets to be cold-start again -- whatever
        // convergence this instance saw before the reset says nothing about the NEW
        // connection's own MonitoredDesktop channel settling behavior.
        hasConvergedSinceReset = false
        return effects
    }

    // MARK: - Internals

    private func dropBufferAndReleaseModifiers() -> FocusAuthorityEffect {
        let count = buffer.count
        buffer.removeAll()
        currentEpochDroppedCount = 0
        return .dropBufferedInput(count: count, withModifierRelease: true)
    }

    /// adr/0012 §1: "回滚：本地key状态重新对齐服务端当前真相（§3各态对应的本地表现）" — `target`
    /// can never equal `lastServerTruth`'s window id here (if it did, `serverDesktopUpdate`
    /// would already have converged this epoch before `tick` ever saw a hard-deadline
    /// crossing), so this always lands on a *different* window, `.desktopFocused`, or
    /// `.unmonitored` than whatever was optimistically keyed.
    private func hardRollback(target: UInt32) -> [FocusAuthorityEffect] {
        var effects: [FocusAuthorityEffect] = [.resignKey(windowId: target)]
        switch lastServerTruth {
        case .window(let id):
            state = .converged(windowId: id)
            hasConvergedSinceReset = true
            effects.append(.makeKey(windowId: id))
        case .desktopFocused:
            state = .desktopFocused
        case .unmonitored:
            state = .unmonitored
        }
        effects.append(dropBufferAndReleaseModifiers())
        effects.append(.warn(.hardRollback(target: target)))
        return effects
    }
}
