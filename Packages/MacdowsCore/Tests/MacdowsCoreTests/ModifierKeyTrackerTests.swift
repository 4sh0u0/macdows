import Testing
@testable import MacdowsCore

@Suite("ModifierKeyTracker")
struct ModifierKeyTrackerTests {
    // MARK: - transitions(from:to:)

    @Test("no change produces no transitions")
    func noChangeIsEmpty() {
        let held: ModifierKeySet = [.shift, .command]
        #expect(ModifierKeyTracker.transitions(from: held, to: held).isEmpty)
    }

    @Test("a single bit going from unset to set is reported as one DOWN transition")
    func singleBitDown() {
        let transitions = ModifierKeyTracker.transitions(from: [], to: [.shift])
        #expect(transitions == [.init(key: .shift, down: true)])
    }

    @Test("a single bit going from set to unset is reported as one RELEASE transition")
    func singleBitUp() {
        let transitions = ModifierKeyTracker.transitions(from: [.shift], to: [])
        #expect(transitions == [.init(key: .shift, down: false)])
    }

    @Test("multiple simultaneous bit changes are all reported, in ModifierKeySet.allKeys order")
    func multipleBitsChangeTogether() {
        // capsLock and command go down, shift goes up -- allKeys orders capsLock before
        // shift before command, so that's the order transitions() must report them in,
        // regardless of the order the two ModifierKeySets happen to have been built in.
        let previous: ModifierKeySet = [.shift]
        let current: ModifierKeySet = [.capsLock, .command]

        let transitions = ModifierKeyTracker.transitions(from: previous, to: current)
        #expect(transitions == [
            .init(key: .capsLock, down: true),
            .init(key: .shift, down: false),
            .init(key: .command, down: true),
        ])
    }

    @Test("unrelated bits already held on both sides produce no spurious transitions")
    func unrelatedHeldBitsAreIgnored() {
        // control is held throughout; only option changes.
        let previous: ModifierKeySet = [.control]
        let current: ModifierKeySet = [.control, .option]

        let transitions = ModifierKeyTracker.transitions(from: previous, to: current)
        #expect(transitions == [.init(key: .option, down: true)])
    }

    @Test("Help and Function are distinct bits, each independently diffable")
    func helpAndFunctionAreDistinct() {
        let transitions = ModifierKeyTracker.transitions(from: [.help], to: [.function])
        #expect(transitions == [
            .init(key: .help, down: false),
            .init(key: .function, down: true),
        ])
    }

    // MARK: - releaseAll(_:) -- W4c H1's own "RELEASE-reissue sequence" assertion

    @Test("releaseAll on an empty set (nothing held) produces no transitions")
    func releaseAllNothingHeld() {
        #expect(ModifierKeyTracker.releaseAll([]).isEmpty)
    }

    @Test("releaseAll on a single held key reissues exactly one RELEASE for it")
    func releaseAllSingleKey() {
        #expect(ModifierKeyTracker.releaseAll([.command]) == [.init(key: .command, down: false)])
    }

    @Test("releaseAll reissues one RELEASE per held key, in canonical ModifierKeySet.allKeys order")
    func releaseAllMultipleKeysCanonicalOrder() {
        // Built with command and shift first, capsLock last -- the output order must still
        // follow allKeys (capsLock, shift, ..., command, ...), not construction order, since
        // that's the order this sequence gets posted to CRSession in.
        let held: ModifierKeySet = [.command, .shift, .capsLock]

        let released = ModifierKeyTracker.releaseAll(held)
        #expect(released == [
            .init(key: .capsLock, down: false),
            .init(key: .shift, down: false),
            .init(key: .command, down: false),
        ])
        // Every single transition in a release-all sequence must be `down: false` --
        // this is the whole point of the sequence (there is no "release-all except this
        // one stays down" case).
        #expect(released.allSatisfy { $0.down == false })
    }

    @Test("releaseAll on every key held at once reissues all eight, in canonical order")
    func releaseAllEveryKey() {
        let everyKey = ModifierKeySet(rawValue: ModifierKeySet.allKeys.map(\.rawValue).reduce(0, |))
        let released = ModifierKeyTracker.releaseAll(everyKey)
        #expect(released.map(\.key) == ModifierKeySet.allKeys)
        #expect(released.allSatisfy { $0.down == false })
    }

    @Test("diffing an already-cleared session ([] to []) after a releaseAll produces nothing further")
    func releaseAllThenDiffAgainstEmptyIsStable() {
        let held: ModifierKeySet = [.option, .control]
        _ = ModifierKeyTracker.releaseAll(held) // what would actually be sent
        // After a release-all, RemoteWindowRegistry's own tracked state resets to [] --
        // diffing [] against [] (the next flagsChanged observed with nothing held) must
        // produce nothing further, not a spurious re-release.
        #expect(ModifierKeyTracker.transitions(from: [], to: []).isEmpty)
    }
}
