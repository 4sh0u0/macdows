import Testing
@testable import MacdowsCore

@Suite("FocusAuthority")
struct FocusAuthorityTests {
    /// A `FocusAuthority` that has already converged on some earlier, unrelated window --
    /// i.e. no longer cold-start (2026-08-23 follow-up: `hasConvergedSinceReset`) -- for
    /// tests whose assertions are specifically about STEADY-STATE (`hardDeadlineInterval`,
    /// 5s) deadline behavior, not the cold-start (`coldStartHardDeadlineInterval`, 10s)
    /// tier. `warmupTarget` defaults to a windowId no test in this suite otherwise uses, so
    /// it can never collide with a test's own target. Leaves the authority back at
    /// `.unmonitored` (not still `.converged(warmupTarget)`) so a test's own assertions
    /// never trip over a stray warmup window.
    private func steadyStateAuthority(warmupTarget: UInt32 = 999_999) -> FocusAuthority {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: warmupTarget, at: -1000)
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0xFFFF_FFFF, at: -999)
        return authority
    }

    // MARK: - Initial state / sentinel classification (adr/0012 §3)

    @Test("starts unmonitored -- the gate must never be open before any real server truth arrives")
    func startsUnmonitored() {
        let authority = FocusAuthority()
        #expect(authority.state == .unmonitored)
    }

    @Test("0xFFFFFFFF classifies as unmonitored")
    func sentinelUnmonitored() {
        #expect(ServerActiveWindow(rawActiveWindowId: 0xFFFF_FFFF) == .unmonitored)
    }

    @Test("0 classifies as desktopFocused, distinct from unmonitored and from any window")
    func sentinelDesktopFocused() {
        let truth = ServerActiveWindow(rawActiveWindowId: 0)
        #expect(truth == .desktopFocused)
        #expect(truth != .unmonitored)
        #expect(truth != .window(0))
    }

    @Test("any other raw value classifies as that window id")
    func sentinelWindow() {
        #expect(ServerActiveWindow(rawActiveWindowId: 66128) == .window(66128))
    }

    @Test("0 vs 0xFFFFFFFF drive FocusAuthority into two different, distinguishable states")
    func zeroAndSentinelAreDistinctStates() {
        let unmonitoredAuthority = FocusAuthority()
        _ = unmonitoredAuthority.serverDesktopUpdate(rawActiveWindowId: 0xFFFF_FFFF, at: 0)
        #expect(unmonitoredAuthority.state == .unmonitored)

        let desktopAuthority = FocusAuthority()
        _ = desktopAuthority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0)
        #expect(desktopAuthority.state == .desktopFocused)

        #expect(unmonitoredAuthority.state != desktopAuthority.state)
    }

    // MARK: - serverDesktopUpdate with nothing in flight (adr/0012 §1 row 1: "立即跟随")

    @Test("a window report with nothing in flight follows immediately into converged, makeKey only")
    func followIntoConvergedFromUnmonitored() {
        let authority = FocusAuthority()
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 42, at: 0)
        #expect(authority.state == .converged(windowId: 42))
        #expect(effects == [.makeKey(windowId: 42)])
    }

    @Test("server moving focus off an already-converged window (nothing in flight) resigns the old and makes the new key")
    func followFromOneConvergedWindowToAnother() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 2, at: 1)
        #expect(authority.state == .converged(windowId: 2))
        #expect(effects == [.resignKey(windowId: 1), .makeKey(windowId: 2)])
    }

    @Test("server moving to desktop focus (nothing in flight) resigns the previously converged window")
    func followFromConvergedToDesktopFocused() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 1)
        #expect(authority.state == .desktopFocused)
        #expect(effects == [.resignKey(windowId: 1)])
    }

    @Test("server moving to unmonitored (nothing in flight) resigns the previously converged window")
    func followFromConvergedToUnmonitored() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 0xFFFF_FFFF, at: 1)
        #expect(authority.state == .unmonitored)
        #expect(effects == [.resignKey(windowId: 1)])
    }

    @Test("repeating the same server truth is a no-op (no spurious resign/makeKey)")
    func repeatedServerTruthIsANoOp() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 1)
        #expect(effects.isEmpty)
        #expect(authority.state == .converged(windowId: 1))
    }

    @Test("desktopFocused observed again is a no-op")
    func repeatedDesktopFocusedIsANoOp() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 1)
        #expect(effects.isEmpty)
    }

    // MARK: - localActivate starts a converging epoch

    @Test("localActivate on a fresh target enters converging (cold-start: no prior convergence yet) and emits sendActivate + makeKey")
    func localActivateEntersConverging() {
        let authority = FocusAuthority()
        let effects = authority.localActivate(windowId: 7, at: 0)
        #expect(effects == [.sendActivate(windowId: 7), .makeKey(windowId: 7)])
        guard case .converging(let target, let epochStart, let hard, let coldStart, let reArmCount) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(target == 7)
        #expect(epochStart == 0)
        // A brand-new FocusAuthority has never converged on a window -- this is
        // necessarily the cold-start tier (2026-08-23 follow-up).
        #expect(coldStart == true)
        #expect(hard == FocusAuthority.coldStartHardDeadlineInterval)
        #expect(reArmCount == 0)
    }

    @Test("localActivate on the window already converged is a redundant reaffirm -- no epoch, no resign")
    func localActivateRedundantOnConverged() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 5, at: 0)
        let effects = authority.localActivate(windowId: 5, at: 1)
        #expect(effects == [.sendActivate(windowId: 5), .makeKey(windowId: 5)])
        #expect(authority.state == .converged(windowId: 5))
    }

    @Test("localActivate on the SAME target already converging is a nudge: sendActivate only, epoch/deadlines untouched")
    func localActivateNudgeSameTarget() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 9, at: 0)
        // Buffer something so we can prove the nudge doesn't touch it.
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.1)
        let effects = authority.localActivate(windowId: 9, at: 0.2)
        #expect(effects == [.sendActivate(windowId: 9)])
        guard case .converging(let target, let epochStart, let hard, let coldStart, let reArmCount) = authority.state else {
            Issue.record("expected still .converging")
            return
        }
        #expect(target == 9)
        #expect(epochStart == 0) // unchanged from the ORIGINAL epoch's `at: 0`, not the nudge's `at: 0.2`
        #expect(coldStart == true)
        #expect(hard == FocusAuthority.coldStartHardDeadlineInterval)
        #expect(reArmCount == 0)
        // The buffered event from before the nudge must survive -- prove via flush.
        let flush = authority.serverDesktopUpdate(rawActiveWindowId: 9, at: 0.3)
        #expect(flush == [.flushBufferedInput([.keyDown(macKeyCode: 1)])])
    }

    // MARK: - Convergence via serverDesktopUpdate while converging

    @Test("serverDesktopUpdate matching the converging target converges and flushes the buffer in order")
    func convergesAndFlushesInOrder() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 3, at: 0)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 10), at: 0.05)
        _ = authority.enqueueKeyboardEvent(.modifierKey(.shift, down: true), at: 0.06)
        _ = authority.enqueueKeyboardEvent(.keyUp(macKeyCode: 10), at: 0.07)

        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 3, at: 0.1)
        #expect(authority.state == .converged(windowId: 3))
        #expect(effects == [.flushBufferedInput([
            .keyDown(macKeyCode: 10),
            .modifierKey(.shift, down: true),
            .keyUp(macKeyCode: 10),
        ])])
    }

    @Test("converging with an empty buffer converges with no flush effect at all")
    func convergesWithEmptyBufferEmitsNoFlush() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 3, at: 0)
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 3, at: 0.1)
        #expect(effects.isEmpty)
    }

    @Test("a transitional off-target report within the soft window neither rolls back nor changes the target (adr/0012 §1 row 2)")
    func transitionalOffTargetDoesNotRollback() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 66128, at: 0)

        // Real-capture example from adr/0012 §1: nil -> 0 -> 66128.
        let e1 = authority.serverDesktopUpdate(rawActiveWindowId: 0xFFFF_FFFF, at: 0.05)
        #expect(e1.isEmpty)
        guard case .converging(let t1, _, _, _, _) = authority.state else { Issue.record("still converging"); return }
        #expect(t1 == 66128)

        let e2 = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0.1)
        #expect(e2.isEmpty)
        guard case .converging(let t2, _, _, _, _) = authority.state else { Issue.record("still converging"); return }
        #expect(t2 == 66128)

        let e3 = authority.serverDesktopUpdate(rawActiveWindowId: 66128, at: 0.15)
        #expect(authority.state == .converged(windowId: 66128))
        #expect(e3.isEmpty) // nothing was ever buffered in this test
    }

    @Test("a transitional off-target report arriving after the first re-arm still doesn't rollback")
    func transitionalOffTargetAfterReArmStillDoesNotRollback() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.tick(now: FocusAuthority.softDeadlineInterval) // first periodic re-arm fires
        let effects = authority.serverDesktopUpdate(rawActiveWindowId: 2, at: FocusAuthority.softDeadlineInterval + 0.1)
        #expect(effects.isEmpty)
        guard case .converging(let target, _, _, _, _) = authority.state else { Issue.record("still converging"); return }
        #expect(target == 1)
    }

    // MARK: - Keyboard-lane gating: zero focus-addressed output while not converged-on-target

    @Test("enqueue while unmonitored never returns flushBufferedInput")
    func enqueueWhileUnmonitoredNeverFlushes() {
        let authority = FocusAuthority()
        let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0)
        #expect(!effects.contains { if case .flushBufferedInput = $0 { return true }; return false })
    }

    @Test("enqueue while desktopFocused never returns flushBufferedInput")
    func enqueueWhileDesktopFocusedNeverFlushes() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0)
        let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.1)
        #expect(!effects.contains { if case .flushBufferedInput = $0 { return true }; return false })
    }

    @Test("enqueue while converging never returns flushBufferedInput")
    func enqueueWhileConvergingNeverFlushes() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.1)
        #expect(!effects.contains { if case .flushBufferedInput = $0 { return true }; return false })
    }

    @Test("enqueue while converged passes straight through immediately, one event at a time")
    func enqueueWhileConvergedPassesThrough() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 5), at: 0.1)
        #expect(effects == [.flushBufferedInput([.keyDown(macKeyCode: 5)])])
    }

    @Test("desktopFocused/unmonitored drop an orphaned keystroke immediately (count 1, no modifier release)")
    func orphanedKeystrokeDroppedImmediately() {
        let authority = FocusAuthority()
        let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0)
        #expect(effects == [.dropBufferedInput(count: 1, withModifierRelease: false)])
    }

    // MARK: - Buffer overflow: drops the NEWEST, keeps the prefix

    @Test("buffer overflow at the 64-event cap drops the newest event and keeps the already-buffered prefix")
    func overflowDropsNewestKeepsPrefix() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)

        for i in 0..<64 {
            let effects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: UInt16(i)), at: 0.001 * Double(i))
            #expect(effects.isEmpty, "the first 64 events must all be accepted without warning")
        }

        // The 65th event overflows.
        let overflowEffects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 999), at: 1)
        #expect(overflowEffects == [.warn(.bufferOverflow(totalDropped: 1))])

        // A second overflowing event increments the running count.
        let secondOverflow = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 998), at: 1.1)
        #expect(secondOverflow == [.warn(.bufferOverflow(totalDropped: 2))])

        // Converging now: the flush must contain exactly the first 64 (0...63), in order --
        // neither 999 nor 998 (the dropped/refused newest events) may appear anywhere.
        let flush = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 2)
        guard case .flushBufferedInput(let events) = flush.first else {
            Issue.record("expected a flush")
            return
        }
        #expect(events.count == 64)
        #expect(events == (0..<64).map { .keyDown(macKeyCode: UInt16($0)) })
    }

    // MARK: - Periodic re-arm (2026-08-23 follow-up)

    @Test("tick before the first re-arm mark is a complete no-op")
    func tickBeforeFirstReArmMarkIsNoOp() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.softDeadlineInterval - 0.01)
        #expect(effects.isEmpty)
        guard case .converging(_, _, _, _, let reArmCount) = authority.state else { Issue.record("still converging"); return }
        #expect(reArmCount == 0)
    }

    @Test("tick crossing the first re-arm mark fires sendActivate + warn (totalMisses: 1)")
    func tickCrossingFirstReArmMarkFires() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.softDeadlineInterval)
        #expect(effects == [.sendActivate(windowId: 1), .warn(.softDeadlineMissed(target: 1, totalMisses: 1))])
        guard case .converging(_, _, _, _, let reArmCount) = authority.state else { Issue.record("still converging"); return }
        #expect(reArmCount == 1)
    }

    @Test("a SECOND periodic re-arm mark fires ANOTHER sendActivate, with no warn this time (warn-once semantics)")
    func secondPeriodicReArmFiresAgainWithoutWarn() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let first = authority.tick(now: FocusAuthority.softDeadlineInterval)
        #expect(first == [.sendActivate(windowId: 1), .warn(.softDeadlineMissed(target: 1, totalMisses: 1))])

        let second = authority.tick(now: FocusAuthority.softDeadlineInterval * 2)
        #expect(second == [.sendActivate(windowId: 1)])
        #expect(!second.contains { if case .warn = $0 { return true }; return false })
        guard case .converging(_, _, _, _, let reArmCount) = authority.state else { Issue.record("still converging"); return }
        #expect(reArmCount == 2)
    }

    @Test("periodic re-arm keeps firing every 500ms until convergence, warning only on the first mark (cadence + warn-once)")
    func periodicReArmCadenceAndWarnOnce() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)

        var allEffects: [FocusAuthorityEffect] = []
        for mark in 1...4 {
            allEffects.append(contentsOf: authority.tick(now: FocusAuthority.softDeadlineInterval * Double(mark)))
        }

        let activateEffects = allEffects.filter { if case .sendActivate = $0 { return true }; return false }
        let warnEffects = allEffects.filter { if case .warn = $0 { return true }; return false }
        #expect(activateEffects.count == 4, "one sendActivate per 500ms mark ticked")
        #expect(warnEffects == [.warn(.softDeadlineMissed(target: 1, totalMisses: 1))], "exactly one warn, from the first mark only")
        guard case .converging(_, _, _, _, let reArmCount) = authority.state else { Issue.record("still converging"); return }
        #expect(reArmCount == 4)
    }

    @Test("a tick call that skips several re-arm marks at once catches up on all of them in order, warning only for the first")
    func tickCatchesUpOnSkippedMarks() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        // Nothing ticked this epoch at all until now -- a genuinely quiet server (or an
        // infrequent caller) skipping straight to the 4th re-arm mark's worth of elapsed
        // time in one call.
        let effects = authority.tick(now: FocusAuthority.softDeadlineInterval * 4)
        let activateEffects = effects.filter { if case .sendActivate = $0 { return true }; return false }
        #expect(activateEffects.count == 4)
        #expect(effects.filter { if case .warn = $0 { return true }; return false }
            == [.warn(.softDeadlineMissed(target: 1, totalMisses: 1))])
        guard case .converging(_, _, _, _, let reArmCount) = authority.state else { Issue.record("still converging"); return }
        #expect(reArmCount == 4)
    }

    @Test("a single tick call that crosses the hard deadline goes straight to hard rollback, no re-arm/warn at all")
    func tickCrossingHardDeadlineGoesStraightToHardRollbackNoReArm() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        // Fresh instance -- cold-start (10s) tier; this must clear it entirely.
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval + 1)
        #expect(!effects.contains { if case .warn(.softDeadlineMissed) = $0 { return true }; return false })
        #expect(effects.contains { if case .warn(.hardRollback(target: 1)) = $0 { return true }; return false })
        // Not a single periodic-re-arm sendActivate should have snuck in before the
        // hard-deadline check short-circuits the whole tick call.
        #expect(effects.filter { if case .sendActivate = $0 { return true }; return false }.isEmpty)
    }

    // MARK: - Cold-start vs steady-state deadline selection (2026-08-23 follow-up)

    @Test("the first converging epoch after a fresh FocusAuthority (never converged) is cold-start: 10s hard deadline")
    func freshAuthorityFirstEpochIsColdStart() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        guard case .converging(_, _, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(coldStart == true)
        #expect(hard == FocusAuthority.coldStartHardDeadlineInterval)
    }

    @Test("once a real window convergence has happened, the NEXT converging epoch is steady-state: 5s hard deadline")
    func afterRealConvergenceNextEpochIsSteadyState() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 999, at: 0) // real window convergence
        let effects = authority.localActivate(windowId: 1, at: 1)
        guard case .converging(_, let epochStart, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(coldStart == false)
        #expect(epochStart == 1)
        #expect(hard == 1 + FocusAuthority.hardDeadlineInterval)
        // Sanity: this epoch also correctly resigns the previously-converged window.
        #expect(effects.contains(.resignKey(windowId: 999)))
    }

    @Test("converging to desktopFocused/unmonitored (never an actual window) does NOT clear cold-start")
    func desktopOrUnmonitoredTruthNeverClearsColdStart() {
        let authority = FocusAuthority()
        // These are exactly the flapping reports cold-start exists to stay patient
        // through -- they must not themselves count as "the server has settled".
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0) // desktopFocused
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0xFFFF_FFFF, at: 0.1) // unmonitored
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: 0.2) // desktopFocused again
        _ = authority.localActivate(windowId: 1, at: 1)
        guard case .converging(_, _, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(coldStart == true)
        #expect(hard == 1 + FocusAuthority.coldStartHardDeadlineInterval)
    }

    @Test("a hard rollback that lands on a real window also clears cold-start for the NEXT epoch")
    func hardRollbackLandingOnWindowClearsColdStart() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        // Server independently reports window 2 mid-flight (transitional -- doesn't
        // converge THIS epoch, but does update lastServerTruth to a real window).
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 2, at: 0.2)
        _ = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval) // hard rollback -> converged(2)
        #expect(authority.state == .converged(windowId: 2))

        // The NEXT epoch, for a different target, should now see steady-state.
        _ = authority.localActivate(windowId: 3, at: 100)
        guard case .converging(_, _, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(coldStart == false)
        #expect(hard == 100 + FocusAuthority.hardDeadlineInterval)
    }

    @Test("steadyStateAuthority helper itself produces a steady-state (5s) first epoch, not cold-start")
    func steadyStateAuthorityHelperProducesSteadyStateEpoch() {
        let authority = steadyStateAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        guard case .converging(_, _, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected .converging")
            return
        }
        #expect(coldStart == false)
        #expect(hard == FocusAuthority.hardDeadlineInterval)
    }

    // MARK: - Hard deadline: rollback to server truth

    @Test("hard rollback with no fresh server truth (still unmonitored) resigns the target, no makeKey")
    func hardRollbackToUnmonitored() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(authority.state == .unmonitored)
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(!effects.contains { if case .makeKey = $0 { return true }; return false })
        #expect(effects.contains { if case .warn(.hardRollback(target: 1)) = $0 { return true }; return false })
    }

    @Test("hard rollback to desktopFocused resigns the target, no makeKey")
    func hardRollbackToDesktopFocused() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 0, at: -1) // establish lastServerTruth = desktop
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(authority.state == .desktopFocused)
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(!effects.contains { if case .makeKey = $0 { return true }; return false })
    }

    @Test("hard rollback landing on a DIFFERENT window (server independently converged elsewhere) resigns old, makeKeys new")
    func hardRollbackToADifferentWindow() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        // The server, independently, reported a DIFFERENT window mid-flight -- transitional,
        // no rollback yet, but lastServerTruth is now window 2.
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 2, at: 0.1)
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(authority.state == .converged(windowId: 2))
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(effects.contains(.makeKey(windowId: 2)))
    }

    @Test("hard rollback always drops the buffer WITH modifier release, even when the buffer happens to be empty")
    func hardRollbackAlwaysSignalsModifierRelease() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(effects.contains(.dropBufferedInput(count: 0, withModifierRelease: true)))
    }

    @Test("hard rollback drops buffered events and reports their count")
    func hardRollbackReportsDroppedCount() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.1)
        _ = authority.enqueueKeyboardEvent(.keyUp(macKeyCode: 1), at: 0.2)
        let effects = authority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(effects.contains(.dropBufferedInput(count: 2, withModifierRelease: true)))
    }

    @Test("hard rollback at the steady-state (5s) deadline behaves identically to the cold-start (10s) one")
    func hardRollbackAtSteadyStateDeadline() {
        let authority = steadyStateAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        let effects = authority.tick(now: FocusAuthority.hardDeadlineInterval)
        #expect(authority.state == .unmonitored)
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(effects.contains { if case .warn(.hardRollback(target: 1)) = $0 { return true }; return false })
    }

    // MARK: - Epoch supersede

    @Test("a new localActivate to a DIFFERENT target while converging drops the old epoch's buffer with modifier release")
    func supersedeDropsOldBufferWithModifierRelease() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.05)

        let effects = authority.localActivate(windowId: 2, at: 0.1)
        #expect(effects.contains(.dropBufferedInput(count: 1, withModifierRelease: true)))
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(effects.contains(.sendActivate(windowId: 2)))
        #expect(effects.contains(.makeKey(windowId: 2)))
        guard case .converging(let target, _, _, _, _) = authority.state else { Issue.record("expected converging"); return }
        #expect(target == 2)
    }

    @Test("supersede establishes a fresh epoch: the old buffer's contents never appear in the new epoch's flush")
    func supersedeStartsWithAnEmptyBuffer() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 111), at: 0.05)
        _ = authority.localActivate(windowId: 2, at: 0.1)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 222), at: 0.15)

        let flush = authority.serverDesktopUpdate(rawActiveWindowId: 2, at: 0.2)
        #expect(flush == [.flushBufferedInput([.keyDown(macKeyCode: 222)])])
    }

    @Test("supersede from a converged window (no converging epoch) still resigns the old window, no buffer drop needed")
    func supersedeFromConvergedNoBufferDrop() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        let effects = authority.localActivate(windowId: 2, at: 0.1)
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(!effects.contains { if case .dropBufferedInput = $0 { return true }; return false })
    }

    @Test("supersede also resets the re-arm count -- the new epoch's first re-arm mark is fresh, not inherited")
    func supersedeResetsReArmCount() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.tick(now: FocusAuthority.softDeadlineInterval) // reArmCount -> 1 for epoch 1
        _ = authority.localActivate(windowId: 2, at: 0.6) // supersede into a fresh epoch
        guard case .converging(let target, let epochStart, _, _, let reArmCount) = authority.state else {
            Issue.record("expected converging")
            return
        }
        #expect(target == 2)
        #expect(epochStart == 0.6)
        #expect(reArmCount == 0)
    }

    // MARK: - No stuck modifiers: both abandon paths always signal a release

    @Test("no stuck modifiers: hard rollback and epoch supersede both always include dropBufferedInput(withModifierRelease: true)")
    func noStuckModifiersAfterEitherAbandonPath() {
        let hardRollbackAuthority = FocusAuthority()
        _ = hardRollbackAuthority.localActivate(windowId: 1, at: 0)
        let hardEffects = hardRollbackAuthority.tick(now: FocusAuthority.coldStartHardDeadlineInterval)
        #expect(hardEffects.contains { if case .dropBufferedInput(_, let release) = $0 { return release }; return false })

        let supersedeAuthority = FocusAuthority()
        _ = supersedeAuthority.localActivate(windowId: 1, at: 0)
        let supersedeEffects = supersedeAuthority.localActivate(windowId: 2, at: 0.1)
        #expect(supersedeEffects.contains { if case .dropBufferedInput(_, let release) = $0 { return release }; return false })
    }

    // MARK: - Reconnect discipline (adr/0012 §2)

    @Test("generationReset always resets to unmonitored, regardless of prior state")
    func generationResetAlwaysLandsOnUnmonitored() {
        let fromConverged = FocusAuthority()
        _ = fromConverged.serverDesktopUpdate(rawActiveWindowId: 1, at: 0)
        _ = fromConverged.generationReset()
        #expect(fromConverged.state == .unmonitored)

        let fromConverging = FocusAuthority()
        _ = fromConverging.localActivate(windowId: 1, at: 0)
        _ = fromConverging.generationReset()
        #expect(fromConverging.state == .unmonitored)

        let fromDesktopFocused = FocusAuthority()
        _ = fromDesktopFocused.serverDesktopUpdate(rawActiveWindowId: 0, at: 0)
        _ = fromDesktopFocused.generationReset()
        #expect(fromDesktopFocused.state == .unmonitored)
    }

    @Test("generationReset from converging resigns the target and drops the buffer with modifier release")
    func generationResetFromConvergingDropsBuffer() {
        let authority = FocusAuthority()
        _ = authority.localActivate(windowId: 1, at: 0)
        _ = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 0.1)
        let effects = authority.generationReset()
        #expect(effects.contains(.resignKey(windowId: 1)))
        #expect(effects.contains(.dropBufferedInput(count: 1, withModifierRelease: true)))
    }

    @Test("generationReset clears cold-start status too -- a fresh connection is cold-start again even after a prior connection converged")
    func generationResetClearsColdStart() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0) // real convergence -- no longer cold
        _ = authority.generationReset()
        _ = authority.localActivate(windowId: 2, at: 10)
        guard case .converging(_, _, let hard, let coldStart, _) = authority.state else {
            Issue.record("expected converging")
            return
        }
        #expect(coldStart == true, "the post-reset connection's own MonitoredDesktop channel hasn't proven itself settled yet")
        #expect(hard == 10 + FocusAuthority.coldStartHardDeadlineInterval)
    }

    @Test("after generationReset, tick() alone can never open the gate -- only a real serverDesktopUpdate can")
    func reconnectGateNeedsRealServerUpdate() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 0) // pre-reconnect: converged
        _ = authority.generationReset()
        #expect(authority.state == .unmonitored)

        // No amount of ticking, by itself, can converge or open the gate.
        _ = authority.tick(now: 1000)
        #expect(authority.state == .unmonitored)
        let enqueueEffects = authority.enqueueKeyboardEvent(.keyDown(macKeyCode: 1), at: 1000)
        #expect(!enqueueEffects.contains { if case .flushBufferedInput = $0 { return true }; return false })

        // Only a genuine serverDesktopUpdate reopens it.
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 1, at: 1001)
        #expect(authority.state == .converged(windowId: 1))
    }

    @Test("a hard rollback that fires before any post-reconnect server truth lands on unmonitored, never on stale pre-reset data")
    func hardRollbackAfterResetNeverUsesStaleTruth() {
        let authority = FocusAuthority()
        _ = authority.serverDesktopUpdate(rawActiveWindowId: 999, at: 0) // stale pre-reconnect truth
        _ = authority.generationReset()

        // Post-reconnect: user clicks a window before any fresh MonitoredDesktop arrives.
        // This epoch is (correctly) cold-start -- generationReset cleared that status too --
        // so the hard deadline to test against is the 10s cold-start one, not the old 5s.
        _ = authority.localActivate(windowId: 1, at: 10)
        let effects = authority.tick(now: 10 + FocusAuthority.coldStartHardDeadlineInterval)

        // Must land on .unmonitored (the reset value), NOT .converged(windowId: 999).
        #expect(authority.state == .unmonitored)
        #expect(!effects.contains { if case .makeKey(let id) = $0 { return id == 999 }; return false })
    }
}
