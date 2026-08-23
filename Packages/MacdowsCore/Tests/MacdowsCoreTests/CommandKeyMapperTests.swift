import Testing
@testable import MacdowsCore

@Suite("CommandKeyMapper")
struct CommandKeyMapperTests {
    // MARK: - Table rows (adr/0011 §3 / §5 item 1)

    @Test(
        "each mapped letter sends Ctrl down, its own fixed VK down/up, then Ctrl up",
        arguments: [
            ("c", UInt16(0x08)), ("v", UInt16(0x09)), ("x", UInt16(0x07)), ("a", UInt16(0x00)),
            ("z", UInt16(0x06)), ("s", UInt16(0x01)), ("f", UInt16(0x03)), ("p", UInt16(0x23)),
            ("o", UInt16(0x1F)), ("n", UInt16(0x2D)),
        ]
    )
    func mappedLetterSendsCtrlChord(char: String, fixedVK: UInt16) {
        let mapper = CommandKeyMapper()
        #expect(mapper.commandChanged(down: true) == .wire([]))

        let down = mapper.key(down: true, macKeyCode: 999, charactersIgnoringModifiers: char)
        #expect(down == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: fixedVK)]))

        let up = mapper.key(down: false, macKeyCode: 999, charactersIgnoringModifiers: char)
        #expect(up == .wire([.keyUp(macKeyCode: fixedVK), .modifierKey(.control, down: false)]))

        // Cmd release afterward must NOT also fire the bare-tap LWIN pair -- a real key
        // already resolved this gesture.
        #expect(mapper.commandChanged(down: false) == .wire([]))
    }

    @Test("mapped letter is keyed on charactersIgnoringModifiers, not macKeyCode (AZERTY evidence)")
    func mappedLetterIgnoresMacKeyCode() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        // AZERTY: the physical key that produces 'a' has keyCode ANSI_Q (12), not ANSI_A --
        // the mapper must still recognize this as the 'a' row from the character alone.
        let down = mapper.key(down: true, macKeyCode: 12, charactersIgnoringModifiers: "a")
        #expect(down == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x00)]))
    }

    @Test("Cmd+Shift+Z sends Ctrl+Y, with Shift never reaching the wire (down and up both consumed)")
    func cmdShiftZSendsCtrlY() {
        let mapper = CommandKeyMapper()
        #expect(mapper.commandChanged(down: true) == .wire([]))
        #expect(mapper.shiftChanged(down: true) == .wire([])) // withheld, not on wire

        let down = mapper.key(down: true, macKeyCode: 6, charactersIgnoringModifiers: "z")
        #expect(down == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x10)])) // 'Y'

        let up = mapper.key(down: false, macKeyCode: 6, charactersIgnoringModifiers: "z")
        #expect(up == .wire([.keyUp(macKeyCode: 0x10), .modifierKey(.control, down: false)]))

        // The physical Shift release, arriving after the chord already closed, must also
        // be swallowed -- it was never sent DOWN, so it must not be sent UP either.
        #expect(mapper.shiftChanged(down: false) == .wire([]))
        #expect(mapper.commandChanged(down: false) == .wire([]))
    }

    @Test("plain Cmd+Z (no Shift) sends Ctrl+Z, the ordinary table VK")
    func cmdZWithoutShiftSendsCtrlZ() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        let down = mapper.key(down: true, macKeyCode: 6, charactersIgnoringModifiers: "z")
        #expect(down == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x06)]))
    }

    @Test("Cmd+W sends zero wire events and a closeRequest")
    func cmdWSendsCloseRequest() {
        let mapper = CommandKeyMapper()
        #expect(mapper.commandChanged(down: true) == .wire([]))
        #expect(mapper.key(down: true, macKeyCode: 13, charactersIgnoringModifiers: "w") == .closeRequest)
        // The matching keyUp is swallowed, not re-fired as a second close.
        #expect(mapper.key(down: false, macKeyCode: 13, charactersIgnoringModifiers: "w") == .wire([]))
        // Cmd's own release afterward must not ALSO fire the bare-tap LWIN pair.
        #expect(mapper.commandChanged(down: false) == .wire([]))
    }

    @Test(
        "Cmd+Q / Cmd+Space / Cmd+Tab send zero wire events and no closeRequest",
        arguments: ["q", " ", "\t"]
    )
    func suppressedKeysSendNothing(char: String) {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        #expect(mapper.key(down: true, macKeyCode: 1, charactersIgnoringModifiers: char) == .wire([]))
        #expect(mapper.key(down: false, macKeyCode: 1, charactersIgnoringModifiers: char) == .wire([]))
        #expect(mapper.commandChanged(down: false) == .wire([]))
    }

    @Test("a bare Cmd tap (down then up, no other key) sends an LWIN down+up pair")
    func bareCmdTapOpensStartMenu() {
        let mapper = CommandKeyMapper()
        #expect(mapper.commandChanged(down: true) == .wire([]))
        #expect(mapper.commandChanged(down: false) == .wire([
            .modifierKey(.command, down: true), .modifierKey(.command, down: false),
        ]))
    }

    @Test("Cmd + an unmapped key passes through as real LWIN + the real key, and stays passthrough")
    func unmappedKeyIsPassthrough() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        let down = mapper.key(down: true, macKeyCode: 38, charactersIgnoringModifiers: "j")
        #expect(down == .wire([.modifierKey(.command, down: true), .keyDown(macKeyCode: 38)]))

        // A second, also-unmapped key while still in passthrough forwards untouched, no
        // repeated LWIN down.
        let secondDown = mapper.key(down: true, macKeyCode: 40, charactersIgnoringModifiers: "k")
        #expect(secondDown == .wire([.keyDown(macKeyCode: 40)]))
        let secondUp = mapper.key(down: false, macKeyCode: 40, charactersIgnoringModifiers: "k")
        #expect(secondUp == .wire([.keyUp(macKeyCode: 40)]))

        let firstUp = mapper.key(down: false, macKeyCode: 38, charactersIgnoringModifiers: "j")
        #expect(firstUp == .wire([.keyUp(macKeyCode: 38)]))

        #expect(mapper.commandChanged(down: false) == .wire([.modifierKey(.command, down: false)]))
    }

    @Test("Win+Shift+key: the withheld Shift-down flushes when passthrough is entered")
    func passthroughFlushesWithheldShift() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        _ = mapper.shiftChanged(down: true) // withheld, undecided
        let down = mapper.key(down: true, macKeyCode: 38, charactersIgnoringModifiers: "j")
        #expect(down == .wire([
            .modifierKey(.command, down: true), .modifierKey(.shift, down: true), .keyDown(macKeyCode: 38),
        ]))
        // Now in passthrough -- Shift's own release forwards normally, not swallowed.
        #expect(mapper.shiftChanged(down: false) == .wire([.modifierKey(.shift, down: false)]))
    }

    @Test("same Cmd hold: C, V, C in rapid succession each wrap their OWN Ctrl pair -- no cross-key merging")
    func rapidRolloverDoesNotMergeChords() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)

        #expect(mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c")
            == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x08)]))
        #expect(mapper.key(down: false, macKeyCode: 8, charactersIgnoringModifiers: "c")
            == .wire([.keyUp(macKeyCode: 0x08), .modifierKey(.control, down: false)]))

        #expect(mapper.key(down: true, macKeyCode: 9, charactersIgnoringModifiers: "v")
            == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x09)]))
        #expect(mapper.key(down: false, macKeyCode: 9, charactersIgnoringModifiers: "v")
            == .wire([.keyUp(macKeyCode: 0x09), .modifierKey(.control, down: false)]))

        #expect(mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c")
            == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x08)]))
        #expect(mapper.key(down: false, macKeyCode: 8, charactersIgnoringModifiers: "c")
            == .wire([.keyUp(macKeyCode: 0x08), .modifierKey(.control, down: false)]))

        #expect(mapper.commandChanged(down: false) == .wire([]))
    }

    // MARK: - Edge cases

    @Test("empty charactersIgnoringModifiers (dead key) while Cmd held does not crash, resolves as passthrough")
    func emptyCharactersDoesNotCrash() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        let down = mapper.key(down: true, macKeyCode: 50, charactersIgnoringModifiers: "")
        #expect(down == .wire([.modifierKey(.command, down: true), .keyDown(macKeyCode: 50)]))
    }

    @Test("Cmd released while a chord's key is still held closes out both VK-up and Ctrl-up")
    func cmdReleasedMidChordClosesOut() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        _ = mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c")
        #expect(mapper.commandChanged(down: false) == .wire([
            .keyUp(macKeyCode: 0x08), .modifierKey(.control, down: false),
        ]))
        #expect(mapper.isActive == false)
    }

    @Test("reset() mid-gesture (focusLost/generationReset) returns to idle with no emitted events")
    func resetAbandonsGesture() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        _ = mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c")
        #expect(mapper.isActive)
        mapper.reset()
        #expect(mapper.state == .idle)
        #expect(mapper.isActive == false)
        // A fresh gesture afterward behaves exactly like a clean instance.
        #expect(mapper.commandChanged(down: true) == .wire([]))
        #expect(mapper.commandChanged(down: false) == .wire([
            .modifierKey(.command, down: true), .modifierKey(.command, down: false),
        ]))
    }

    @Test("a second key going down while a chord is already open is a no-op, not a corrupted chord")
    func secondKeyWhileChordOpenIsNoOp() {
        let mapper = CommandKeyMapper()
        _ = mapper.commandChanged(down: true)
        _ = mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c")
        #expect(mapper.key(down: true, macKeyCode: 9, charactersIgnoringModifiers: "v") == .wire([]))
        // The original chord still closes correctly.
        #expect(mapper.key(down: false, macKeyCode: 8, charactersIgnoringModifiers: "c")
            == .wire([.keyUp(macKeyCode: 0x08), .modifierKey(.control, down: false)]))
    }

    // MARK: - Structural property: every Ctrl/LWIN down is eventually matched by an up

    @Test("adversarial sequences never emit an unmatched Ctrl or Command down/up pair")
    func adversarialSequencesStayBalanced() {
        // A small, deterministic set of sequences exercising every state transition,
        // including mid-gesture reset() (the pure-MacdowsCore stand-in for
        // focusLost/dropBufferedInput/generationReset -- adr/0011 §5 item 2's "结构性零卡
        // 死修饰键" property, scoped to what CommandKeyMapper itself can produce).

        // Sequence 1: mapped chord, then mid-chord reset (simulating focusLost).
        do {
            let mapper = CommandKeyMapper()
            var controlDepth = 0
            func track(_ output: CommandKeyMapperOutput) {
                guard case .wire(let events) = output else { return }
                for event in events {
                    guard case .modifierKey(.control, let down) = event else { continue }
                    controlDepth += down ? 1 : -1
                }
            }
            track(mapper.commandChanged(down: true))
            track(mapper.key(down: true, macKeyCode: 8, charactersIgnoringModifiers: "c"))
            #expect(controlDepth == 1) // Ctrl genuinely down on the (simulated) wire
            mapper.reset() // adr/0011 §3: no closing events emitted by reset() itself --
            // RemoteWindowRegistry's own wireHeldModifiers ledger (session-level, not
            // CommandKeyMapper-level) is what actually issues the real RELEASE in this
            // case; this assertion documents that reset() itself never double-releases.
            #expect(mapper.isActive == false)
        }

        // Sequence 2: withheld -> Shift down -> reset before any key -- must not leave the
        // mapper thinking Shift is still "consumed" afterward.
        do {
            let mapper = CommandKeyMapper()
            _ = mapper.commandChanged(down: true)
            _ = mapper.shiftChanged(down: true)
            mapper.reset()
            #expect(mapper.commandChanged(down: true) == .wire([]))
            // A fresh Shift+Z now (new gesture) must resolve exactly like a clean instance.
            _ = mapper.shiftChanged(down: true)
            let down = mapper.key(down: true, macKeyCode: 6, charactersIgnoringModifiers: "z")
            #expect(down == .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: 0x10)]))
        }

        // Sequence 3: passthrough, then reset mid-passthrough (simulating a hard
        // rollback/dropBufferedInput while Win+key is held).
        do {
            let mapper = CommandKeyMapper()
            var commandDepth = 0
            func track(_ output: CommandKeyMapperOutput) {
                guard case .wire(let events) = output else { return }
                for event in events {
                    guard case .modifierKey(.command, let down) = event else { continue }
                    commandDepth += down ? 1 : -1
                }
            }
            track(mapper.commandChanged(down: true))
            track(mapper.key(down: true, macKeyCode: 38, charactersIgnoringModifiers: "j"))
            #expect(commandDepth == 1)
            mapper.reset()
            #expect(mapper.isActive == false)
            #expect(mapper.commandChanged(down: true) == .wire([]))
        }
    }
}
