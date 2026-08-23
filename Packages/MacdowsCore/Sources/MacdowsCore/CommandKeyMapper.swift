import Foundation

/// What `CommandKeyMapper` wants its consumer to do (`RemoteWindowRegistry`, adr/0011 §3).
/// Mirrors `FocusAuthorityEffect`'s own "pure state machine, dumb consumer" split.
public enum CommandKeyMapperOutput: Sendable, Equatable {
    /// Zero or more already-on-wire-shape `KeyboardLaneEvent`s, in order, to enqueue into
    /// `FocusAuthority`'s gate (adr/0011 §3: "入闸前映射意味着缓冲里躺的已经是线上形态事件") --
    /// `[]` is a valid, common answer (e.g. Cmd's own down: "withhold", nothing sent yet).
    case wire([KeyboardLaneEvent])
    /// Cmd+W (adr/0011 §3's table): zero wire events for W itself -- route to the existing
    /// SC_CLOSE traffic-light path instead of this lane (`RemoteWindowRegistry`'s own
    /// `handleChromeAction(windowId:action: .close)` already exists for exactly this; this
    /// is a second entry point into it, not a new mechanism).
    case closeRequest
}

/// adr/0011 §3's Cmd<->Ctrl remap -- the load-bearing piece of the input-pipeline-
/// characters ADR. Pure MacdowsCore state machine (no AppKit/CRSession), mirroring
/// `ModifierKeyTracker`'s no-AppKit precedent: `RemoteWindowRegistry` owns one session-
/// level instance (like `heldModifierKeys`/the new `wireHeldModifiers`) and feeds it Cmd/
/// Shift transitions and regular key events BEFORE they ever reach `FocusAuthority`'s gate
/// (adr/0011 §3: "落点：RemoteWindowRegistry的翻译层，入闸之前").
///
/// **The table is keyed on `charactersIgnoringModifiers.lowercased()`, never on
/// `macKeyCode`** (adr/0011 §3's own AZERTY evidence: "产生a的那个键"'s keyCode is
/// ANSI_Q on AZERTY -- keying on keyCode would send Cmd+A as Ctrl+Q). The VK each mapped
/// character sends is likewise a **fixed** Apple virtual keycode for that letter's own
/// ANSI-US physical position (`winpr/include/winpr/input.h`'s `APPLE_VK_ANSI_*` values),
/// reused as a `KeyboardLaneEvent.keyDown(macKeyCode:)` payload precisely because that's
/// exactly what `CRSession.sendKeyDown:`'s existing `GetVirtualKeyCodeFromKeycode(_,
/// WINPR_KEYCODE_TYPE_APPLE)` translation already expects as input -- feeding it a fixed
/// ANSI-US position code, instead of the real event's own (layout-dependent) `macKeyCode`,
/// is what makes the sent VK layout-independent without needing any new CRSession
/// primitive.
///
/// **Shift interception**: the only shift-sensitive row (Cmd+Shift+Z -> Ctrl+Y, "Shift
/// consumed, not on wire") requires knowing whether Shift is held at the moment a mapped
/// key goes down, AND requires that Shift's own independent `flagsChanged` transition
/// never itself reaches the wire while that's still undecided. `RemoteWindowRegistry`
/// therefore routes Shift's transitions through `shiftChanged(down:)` too, but ONLY while
/// a Cmd gesture is active (`isActive`) -- idle-state Shift is untouched, flowing through
/// the ordinary `ModifierKeyTracker` path exactly as before this ADR.
///
/// **Known v1 gap** (undocumented by adr/0011 §3, a deliberate simplification): this
/// machine tracks at most one "currently open" chord/passthrough key at a time. A second
/// key going down before the first's release (fast rollover while Cmd is held) is a no-op
/// rather than a tracked second chord -- realistic Mac-shortcut typing is serial (Cmd+C,
/// release, Cmd+V, release), and the ADR's own worked example ("C、V、C每个和弦各自成对包
/// Ctrl，不做跨键合并") assumes exactly that serial shape.
public final class CommandKeyMapper {
    public enum State: Sendable, Equatable {
        /// No Cmd gesture in flight. Every input passes straight through unchanged
        /// (defensive default; `RemoteWindowRegistry` shouldn't normally route anything
        /// here while idle).
        case idle
        /// Cmd is down, undecided -- "此刻还不知道它是映射和弦还是Windows键" (adr/0011 §3):
        /// nothing has been sent to the wire for Cmd itself yet.
        case withheld
        /// A mapped Ctrl-chord is live on the wire, keyed on the fixed VK currently open.
        /// Transient: reverts to `.withheld` the instant that key's own release closes the
        /// chord (adr/0011 §3: "不做跨键合并" -- each mapped keypress is judged and closed
        /// independently, even though Cmd itself may still be held throughout).
        case mapped(fixedVK: UInt16)
        /// LWIN is live on the wire (genuine Windows-key passthrough) -- unlike `.mapped`,
        /// this persists for the rest of the Cmd-held gesture once entered (adr/0011 §3:
        /// "住Windows键这个真实功能" -- multi-key Windows-key usage, e.g. holding Win while
        /// pressing several keys in sequence, is real and shouldn't re-decide per key).
        case passthrough
    }

    /// c v x a z s f p o n -> `APPLE_VK_ANSI_*`'s fixed keycode for that letter's own
    /// ANSI-US position (adr/0011 §3's exact v1 table; Parallels' keyboard profile
    /// precedent, per the ADR's own citation). Values verified directly against
    /// `winpr/include/winpr/input.h`.
    private static let mappedVK: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "f": 0x03, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "n": 0x2D, "o": 0x1F, "p": 0x23,
    ]
    /// `APPLE_VK_ANSI_Y` -- the fixed VK Cmd+Shift+Z sends instead of Z's own (macOS Redo
    /// <-> Windows Redo's "经典不对称", adr/0011 §3).
    private static let redoVK: UInt16 = 0x10
    /// Keys the ADR's table says never reach the wire at all, beyond the special-cased 'w'
    /// (adr/0009 deferred / local macOS semantics): Cmd+Q, Cmd+Space, Cmd+Tab. String-keyed
    /// (not `Character`-keyed) deliberately -- `charactersIgnoringModifiers` is empty for
    /// dead keys/pure function keys (`RemoteWindowInput.swift`'s own doc comment), and
    /// `Character.init(_:String)` traps on anything but exactly one grapheme cluster; a
    /// plain `String` comparison degrades an empty/multi-char input to "no match" instead
    /// of crashing.
    private static let suppressedNoWireKeys: Set<String> = ["q", " ", "\t"]

    public private(set) var state: State = .idle

    /// Shift's physical hold state, captured independently of the ordinary modifier
    /// pipeline for as long as a Cmd gesture stays undecided/mapped (adr/0011 §3's only
    /// shift-sensitive row). Meaningless once `.passthrough` -- Shift reverts to the
    /// ordinary pipeline at that point (see `shiftChanged(down:)`).
    private var shiftHeld = false
    /// Set the instant a Shift-DOWN is withheld/swallowed while undecided/mapped, so the
    /// eventual matching Shift-UP is swallowed too rather than becoming a stray RELEASE
    /// for a key the wire never saw DOWN -- the same ledger discipline adr/0011 §3's
    /// `wireHeldModifiers` applies session-wide, applied here specifically to Shift's own
    /// down/up pairing across a single Cmd gesture.
    private var shiftConsumed = false
    /// Whether ANY key event has already been resolved (mapped, suppressed, close-
    /// requested, or passthrough) during the current `.withheld` window -- if Cmd releases
    /// with this still `false`, it was a genuine bare tap (LWIN down+up, "Cmd单击=开始菜
    /// 单"); if `true`, Cmd's own release is just closing out a gesture that already did
    /// something else, and must NOT also fire the tap pair.
    private var gestureHadKey = false

    public init() {}

    /// `true` whenever a Cmd gesture is in progress (`.withheld`/`.mapped`/`.passthrough`)
    /// -- `RemoteWindowRegistry` uses this to decide whether a given key/Shift event should
    /// route through this mapper at all, or take the unmodified ordinary path.
    public var isActive: Bool { state != .idle }

    /// Abandons any in-flight gesture without emitting anything (adr/0011 §3 gives no
    /// explicit closing-event guidance for a hard abandon like `.focusLost`/reconnect --
    /// `RemoteWindowRegistry`'s own `wireHeldModifiers` ledger is what actually issues the
    /// matching wire RELEASEs in that case, mirroring how `heldModifierKeys = []` on
    /// `closeAllWindows` also does "no RELEASE flush here", see that method's own comment).
    public func reset() {
        state = .idle
        shiftHeld = false
        shiftConsumed = false
        gestureHadKey = false
    }

    // MARK: - Cmd itself

    public func commandChanged(down: Bool) -> CommandKeyMapperOutput {
        if down {
            guard state == .idle else { return .wire([]) } // defensive; shouldn't recur
            state = .withheld
            shiftHeld = false
            shiftConsumed = false
            gestureHadKey = false
            return .wire([]) // "withhold": undecided, nothing sent yet (adr/0011 §3)
        }

        defer {
            state = .idle
            shiftHeld = false
            shiftConsumed = false
            gestureHadKey = false
        }
        switch state {
        case .idle:
            return .wire([]) // defensive; shouldn't happen (no up without a prior down)
        case .withheld:
            guard !gestureHadKey else {
                // A suppressed/close-requested key already happened this gesture -- Cmd's
                // own release is just closing that out, not a bare tap.
                return .wire([])
            }
            // Bare Cmd tap: macOS's own "Cmd alone = open Start menu" semantic (adr/0011
            // §3) -- a single LWIN down+up pair.
            return .wire([.modifierKey(.command, down: true), .modifierKey(.command, down: false)])
        case .mapped(let fixedVK):
            // Cmd released before the chord's own key -- unusual ordering, but close both
            // out symmetrically: the VK's own release, then Ctrl up.
            return .wire([.keyUp(macKeyCode: fixedVK), .modifierKey(.control, down: false)])
        case .passthrough:
            return .wire([.modifierKey(.command, down: false)])
        }
    }

    // MARK: - Shift (only while a Cmd gesture is active -- see `isActive`)

    public func shiftChanged(down: Bool) -> CommandKeyMapperOutput {
        switch state {
        case .idle, .passthrough:
            // Idle: shouldn't normally be called (RemoteWindowRegistry gates on
            // `isActive`), stay a safe passthrough. Passthrough: committed to real
            // Windows-key usage -- Shift forwards normally from here on (adr/0011 §3).
            return .wire([.modifierKey(.shift, down: down)])
        case .withheld, .mapped:
            if down {
                shiftHeld = true
                shiftConsumed = true
                return .wire([])
            }
            shiftHeld = false
            let wasConsumed = shiftConsumed
            shiftConsumed = false
            // If this Shift press was withheld/consumed, its release must be swallowed
            // too -- otherwise it's a stray RELEASE for a key the wire never saw DOWN.
            return wasConsumed ? .wire([]) : .wire([.modifierKey(.shift, down: false)])
        }
    }

    // MARK: - Regular keys (only while a Cmd gesture is active -- see `isActive`)

    public func key(down: Bool, macKeyCode: UInt16, charactersIgnoringModifiers: String) -> CommandKeyMapperOutput {
        switch state {
        case .idle, .passthrough:
            // Idle: shouldn't normally be called. Passthrough: every key just forwards,
            // untouched, for the rest of this Cmd-held gesture (adr/0011 §3).
            return .wire([down ? .keyDown(macKeyCode: macKeyCode) : .keyUp(macKeyCode: macKeyCode)])

        case .mapped(let fixedVK):
            guard !down else {
                // A second key going down while a chord is already open -- see this type's
                // own doc comment on the accepted v1 rollover gap.
                return .wire([])
            }
            state = .withheld
            return .wire([.keyUp(macKeyCode: fixedVK), .modifierKey(.control, down: false)])

        case .withheld:
            guard down else {
                // The only way a keyUp reaches here is the matching release of a key whose
                // own keyDown was suppressed/close-requested (state never left `.withheld`
                // for it) -- always swallow.
                return .wire([])
            }
            gestureHadKey = true
            let char = charactersIgnoringModifiers.lowercased()
            if char == "w" {
                return .closeRequest
            }
            if Self.suppressedNoWireKeys.contains(char) {
                return .wire([])
            }
            if char == "z", shiftHeld {
                state = .mapped(fixedVK: Self.redoVK)
                return .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: Self.redoVK)])
            }
            if let fixedVK = Self.mappedVK[char] {
                state = .mapped(fixedVK: fixedVK)
                return .wire([.modifierKey(.control, down: true), .keyDown(macKeyCode: fixedVK)])
            }
            // Not in the table -- genuine Windows-key passthrough (adr/0011 §3's catch-all
            // row). Commit LWIN now (it was withheld at Cmd-down time), flush any withheld
            // Shift-down first so Win+Shift+key gestures forward correctly, then forward
            // this key itself untouched.
            state = .passthrough
            var events: [KeyboardLaneEvent] = [.modifierKey(.command, down: true)]
            if shiftHeld {
                events.append(.modifierKey(.shift, down: true))
            }
            shiftConsumed = false // now genuinely on the wire, not "withheld" anymore
            events.append(.keyDown(macKeyCode: macKeyCode)) // `down` is always true here --
            // the `guard down else` above this branch already handled the release case.
            return .wire(events)
        }
    }
}
