@testable import MacdowsCore
import Testing

// S2 (when to announce: the ready trigger and the change trigger) and S3 (how to answer a data
// request, through `ClipboardSession.dataRequested`, the only way in for the App). The pure
// rule functions are internal; `@testable` lets the rule tables below read them directly.
// Fixture strings are invented; the type identifiers are the real public ones plus invented
// private ones.

enum ClipboardOutboundFixtures {
    static let text = "public.utf8-plain-text"
    static let png = "public.png"
    static let marker = PasteboardOwnership.defaultMarkerType
    static let concealed = "org.nspasteboard.ConcealedType"

    static func snapshot(_ changeCount: Int, _ types: [String]) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: changeCount, types: types)
    }

    static func snapshot(_ types: [String]) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: 10, types: types)
    }

    static let bidirectional = ClipboardPolicy(mode: .bidirectional)

    /// S2 (b) on a connection whose ready trigger has been handled, with a count that differs
    /// from the one judged last: rules 1-5.
    static func change(_ snapshot: PasteboardSnapshot, _ policy: ClipboardPolicy = bidirectional,
                       _ ownership: PasteboardOwnership = PasteboardOwnership()) -> ClipboardAnnounceDecision {
        ClipboardOutbound.changeDecision(for: snapshot, policy: policy, ownership: ownership, isReady: true,
                                         lastJudgedChangeCount: snapshot.changeCount - 1)
    }

    static func ready(_ snapshot: PasteboardSnapshot, _ policy: ClipboardPolicy = bidirectional,
                      _ initialList: ClipboardInitialListPolicy = .always) -> ClipboardAnnounceDecision {
        ClipboardOutbound.readyDecision(for: snapshot, policy: policy, initialList: initialList)
    }

    /// S3 on a fresh session (owner check at its default, off): the pasteboard holds
    /// `snapshot`'s types and `content`.
    static func respond(_ content: String?, format: UInt32 = 13,
                        snapshot: PasteboardSnapshot = PasteboardSnapshot(changeCount: 10, types: [ClipboardOutboundFixtures.text]),
                        active: Bool = true, policy: ClipboardPolicy = bidirectional) -> ClipboardRespondDecision {
        var session = ClipboardSession(policy: policy)
        return session.dataRequested(formatId: format, isAppActive: active,
                                     readTypes: { snapshot.types }, readText: { content })
    }

    /// S3 on an existing session, counting how often each closure was called.
    struct Reads: Equatable {
        var types = 0
        var text = 0
    }

    static func ask(_ session: inout ClipboardSession, format: UInt32 = 13, active: Bool = true,
                    types: [String] = [ClipboardOutboundFixtures.text], text: String? = "fixture answer",
                    reads: inout Reads) -> ClipboardRespondDecision {
        session.dataRequested(formatId: format, isAppActive: active,
                              readTypes: { reads.types += 1; return types },
                              readText: { reads.text += 1; return text })
    }

    static func ask(_ session: inout ClipboardSession, format: UInt32 = 13, active: Bool = true,
                    types: [String] = [ClipboardOutboundFixtures.text], text: String? = "fixture answer") -> ClipboardRespondDecision {
        var reads = Reads()
        return ask(&session, format: format, active: active, types: types, text: text, reads: &reads)
    }
}

@Suite("Clipboard S2 (a): the ready trigger and the initial list")
struct ClipboardReadyTests {
    typealias F = ClipboardOutboundFixtures

    @Test("a text type, direction allowed, no sensitive marker: the initial list names 13",
          arguments: Array(PasteboardTypes.plainText).sorted())
    func textAnnounces(_ textType: String) {
        #expect(F.ready(F.snapshot([F.png, textType])) == .announce(.unicodeText))
        // The initial-list policy only matters when there is nothing to offer.
        #expect(F.ready(F.snapshot([textType]), F.bidirectional, .onlyIfText) == .announce(.unicodeText))
    }

    @Test("nothing to offer: an empty list under .always, nothing under .onlyIfText -- no text type",
          arguments: [[F.png], []])
    func noTextType(_ types: [String]) {
        #expect(F.ready(F.snapshot(types)) == .announce(.empty))
        #expect(F.ready(F.snapshot(types), F.bidirectional, .onlyIfText) == .skip(.initialListWithheld))
    }

    @Test("nothing to offer: a sensitive marker", arguments: Array(PasteboardTypes.sensitive).sorted())
    func sensitive(_ sensitiveType: String) {
        #expect(F.ready(F.snapshot([F.text, sensitiveType])) == .announce(.empty))
        #expect(F.ready(F.snapshot([F.text, sensitiveType]), F.bidirectional, .onlyIfText) == .skip(.initialListWithheld))
    }

    @Test("nothing to offer: Mac -> Windows not allowed", arguments: [ClipboardMode.unmanaged, .off, .remoteToLocalOnly])
    func directionNotAllowed(_ mode: ClipboardMode) {
        #expect(F.ready(F.snapshot([F.text]), ClipboardPolicy(mode: mode)) == .announce(.empty))
        #expect(F.ready(F.snapshot([F.text]), ClipboardPolicy(mode: mode), .onlyIfText) == .skip(.initialListWithheld))
    }

    @Test("the Mac -> Windows-only mode offers its text too")
    func localToRemoteOnly() {
        #expect(F.ready(F.snapshot([F.text]), ClipboardPolicy(mode: .localToRemoteOnly)) == .announce(.unicodeText))
    }

    @Test("the anti-loop rule is NOT applied at ready: text from Windows, by marker or by change count, is still offered")
    func noAntiLoopAtReady() {
        #expect(F.ready(F.snapshot([F.text, F.marker])) == .announce(.unicodeText))
        var session = ClipboardSession(policy: F.bidirectional)
        session.recordOwnWrite(changeCount: 10)
        let decision = session.clipboardReady(snapshot: F.snapshot(10, [F.text, F.marker]))
        #expect(decision == .announce(.unicodeText))
    }

    @Test("the policy is one named value; .always is the default, also the session's")
    func defaultPolicy() {
        #expect(ClipboardInitialListPolicy.default == .always)
        #expect(ClipboardSession(policy: F.bidirectional).initialList == .always)
    }

    @Test("the announce command's formatId: 13 for the text list, 0 for the empty one")
    func announcedFormatIds() {
        #expect(ClipboardFormatList.unicodeText.announcedFormatId == 13)
        #expect(ClipboardFormatList.empty.announcedFormatId == 0)
    }

    @Test("the session counts a withheld initial list, and nothing for a sent one")
    func sessionCounts() {
        var withheld = ClipboardSession(policy: F.bidirectional, initialList: .onlyIfText)
        let skipped = withheld.clipboardReady(snapshot: F.snapshot([F.png]))
        #expect(skipped == .skip(.initialListWithheld))
        #expect(withheld.counters.count(ClipboardAnnounceSkipReason.initialListWithheld) == 1)
        var sent = ClipboardSession(policy: F.bidirectional)
        let empty = sent.clipboardReady(snapshot: F.snapshot([F.png]))
        #expect(empty == .announce(.empty))
        #expect(sent.counters.nonZeroEntries.isEmpty)
    }
}

@Suite("Clipboard S2 (b): rule 0, a change before ready")
struct ClipboardBeforeReadyTests {
    typealias F = ClipboardOutboundFixtures

    @Test("rule 0: not ready -> skip, ahead of every other rule (the unchanged check included)")
    func pureRuleZero() {
        #expect(ClipboardOutbound.changeDecision(for: F.snapshot([F.text]), policy: F.bidirectional,
                                                 ownership: PasteboardOwnership(), isReady: false,
                                                 lastJudgedChangeCount: nil) == .skip(.beforeReady))
        var ownership = PasteboardOwnership()
        ownership.recordOwnWrite(changeCount: 10)
        #expect(ClipboardOutbound.changeDecision(for: F.snapshot(10, [F.marker, F.concealed]), policy: ClipboardPolicy(mode: .off),
                                                 ownership: ownership, isReady: false,
                                                 lastJudgedChangeCount: 10) == .skip(.beforeReady))
    }

    @Test("a change before ready is skipped and counted; after ready a new count goes through rules 1-5")
    func beforeThenAfterReady() {
        var session = ClipboardSession(policy: F.bidirectional)
        #expect(!session.isReady)
        let before = session.pasteboardChanged(snapshot: F.snapshot(10, [F.text]))
        #expect(before == .skip(.beforeReady))
        #expect(session.counters.count(ClipboardAnnounceSkipReason.beforeReady) == 1)
        _ = session.clipboardReady(snapshot: F.snapshot(10, [F.text]))
        #expect(session.isReady)
        let after = session.pasteboardChanged(snapshot: F.snapshot(11, [F.text]))
        #expect(after == .announce(.unicodeText))
        let afterNoText = session.pasteboardChanged(snapshot: F.snapshot(12, [F.png]))
        #expect(afterNoText == .skip(.noTextType))
        #expect(session.counters.count(ClipboardAnnounceSkipReason.beforeReady) == 1)
    }

    @Test("a disconnect makes the connection not-ready again; the next ready clears it")
    func resetReturnsToBeforeReady() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(10, [F.text]))
        session.reset()
        #expect(!session.isReady)
        let afterReset = session.pasteboardChanged(snapshot: F.snapshot(11, [F.text]))
        #expect(afterReset == .skip(.beforeReady))
        _ = session.clipboardReady(snapshot: F.snapshot(11, [F.png]))
        let afterReady = session.pasteboardChanged(snapshot: F.snapshot(12, [F.text]))
        #expect(afterReady == .announce(.unicodeText))
    }

    /// Under .onlyIfText a ready with nothing to offer sends no list. Rule 0 guards "Client
    /// Capabilities before any Format List", which holds once ready has happened, so later
    /// changes are announced; reading rule 0 as "the initial list was sent" would block every
    /// announcement of the connection instead.
    @Test("under .onlyIfText, a ready that sent nothing still ends rule 0")
    func onlyIfTextReadyEndsRuleZero() {
        var session = ClipboardSession(policy: F.bidirectional, initialList: .onlyIfText)
        let ready = session.clipboardReady(snapshot: F.snapshot([F.png]))
        #expect(ready == .skip(.initialListWithheld))
        let change = session.pasteboardChanged(snapshot: F.snapshot(11, [F.text]))
        #expect(change == .announce(.unicodeText))
    }

    @Test("the anti-loop memory is not part of the reset (S8)")
    func ownershipSurvivesReset() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot([F.text]))
        session.recordOwnWrite(changeCount: 42)
        session.reset()
        #expect(session.ownership.lastOwnWriteChangeCount == 42)
        _ = session.clipboardReady(snapshot: F.snapshot([F.png]))
        let decision = session.pasteboardChanged(snapshot: F.snapshot(42, [F.text]))
        #expect(decision == .skip(.ownWrite))
    }
}

@Suite("Clipboard S2 (b): rules 1-5 of the change trigger")
struct ClipboardAnnounceTests {
    typealias F = ClipboardOutboundFixtures

    @Test("rule 1: a mode that does not allow Mac -> Windows never announces",
          arguments: [ClipboardMode.unmanaged, .off, .remoteToLocalOnly])
    func directionNotAllowed(_ mode: ClipboardMode) {
        #expect(F.change(F.snapshot([F.text]), ClipboardPolicy(mode: mode)) == .skip(.directionNotAllowed))
    }

    @Test("rule 2: the App's own last write, by change count, even without the marker")
    func ownWriteByChangeCount() {
        var ownership = PasteboardOwnership()
        ownership.recordOwnWrite(changeCount: 10)
        #expect(F.change(F.snapshot(10, [F.text]), F.bidirectional, ownership) == .skip(.ownWrite))
        // Any later change is someone else's copy again.
        #expect(F.change(F.snapshot(11, [F.text]), F.bidirectional, ownership) == .announce(.unicodeText))
    }

    @Test("rule 2: the marker type, with an unrelated change count")
    func markerPresent() {
        var ownership = PasteboardOwnership()
        ownership.recordOwnWrite(changeCount: 3)
        #expect(F.change(F.snapshot(10, [F.text, F.marker]), F.bidirectional, ownership) == .skip(.remoteMarker))
    }

    @Test("rule 2: the marker the App chose, not the default one, is what counts")
    func customMarker() {
        let ownership = PasteboardOwnership(markerType: "dev.fixture.private-marker")
        #expect(F.change(F.snapshot([F.text, "dev.fixture.private-marker"]), F.bidirectional, ownership) == .skip(.remoteMarker))
        #expect(F.change(F.snapshot([F.text, F.marker]), F.bidirectional, ownership) == .announce(.unicodeText))
    }

    @Test("rule 2: no own write recorded yet means no change count is the App's")
    func noOwnWriteYet() {
        #expect(PasteboardOwnership().lastOwnWriteChangeCount == nil)
        #expect(F.change(F.snapshot(0, [F.text])) == .announce(.unicodeText))
    }

    @Test("rule 3: any one of the three sensitive markers stops the announcement",
          arguments: Array(PasteboardTypes.sensitive).sorted())
    func sensitive(_ sensitiveType: String) {
        #expect(F.change(F.snapshot([F.text, sensitiveType])) == .skip(.sensitiveType))
    }

    @Test("the three sensitive markers are exactly the nspasteboard.org ones")
    func sensitiveSet() {
        #expect(PasteboardTypes.sensitive == [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        ])
    }

    @Test("rule 4: no text type, including no types at all -- and no empty list either", arguments: [[F.png], []])
    func noText(_ types: [String]) {
        #expect(F.change(F.snapshot(types)) == .skip(.noTextType))
    }

    @Test("rule 5: any text type announces format 13 and only 13",
          arguments: Array(PasteboardTypes.plainText).sorted())
    func announces(_ textType: String) {
        #expect(F.change(F.snapshot([F.png, textType])) == .announce(.unicodeText))
    }

    @Test("rule 5 holds for the Mac -> Windows-only mode too")
    func announcesLocalToRemoteOnly() {
        #expect(F.change(F.snapshot([F.text]), ClipboardPolicy(mode: .localToRemoteOnly)) == .announce(.unicodeText))
    }

    @Test("order: the direction rule beats every reason after it")
    func orderDirectionFirst() {
        var ownership = PasteboardOwnership()
        ownership.recordOwnWrite(changeCount: 10)
        #expect(F.change(F.snapshot(10, [F.marker, F.concealed]), ClipboardPolicy(mode: .off), ownership)
                == .skip(.directionNotAllowed))
    }

    @Test("order: own write beats the marker, the marker beats a sensitive type, a sensitive type beats no text")
    func orderWithinRules() {
        var ownership = PasteboardOwnership()
        ownership.recordOwnWrite(changeCount: 10)
        #expect(F.change(F.snapshot(10, [F.text, F.marker]), F.bidirectional, ownership) == .skip(.ownWrite))
        // "marker AND sensitive marker": rule 2 decides.
        #expect(F.change(F.snapshot(11, [F.text, F.marker, F.concealed]), F.bidirectional, ownership) == .skip(.remoteMarker))
        #expect(F.change(F.snapshot(11, [F.png, F.concealed]), F.bidirectional, ownership) == .skip(.sensitiveType))
    }

    @Test("counters: each skip is counted under its own reason, an announcement under none")
    func counted() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(10, [F.text]))
        _ = session.pasteboardChanged(snapshot: F.snapshot(11, [F.png]))
        _ = session.pasteboardChanged(snapshot: F.snapshot(12, [F.text]))
        #expect(session.counters.count(ClipboardAnnounceSkipReason.noTextType) == 1)
        for reason in ClipboardAnnounceSkipReason.allCases where reason != .noTextType {
            #expect(session.counters.count(reason) == 0)
        }
    }
}

/// S2 (b), v3 patch (gate r1, I-1): the session itself remembers the change count it judged
/// last, and a count equal to it is not a change. The App hands over every count it observes
/// while active, the one read in the activation notification included.
@Suite("Clipboard S2 (b): an unchanged change count is not a change")
struct ClipboardUnchangedCountTests {
    typealias F = ClipboardOutboundFixtures
    static let windowsText = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false)
    static let windowsImage = ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false)

    @Test("SPEC (gate r1): an activation with an unchanged change count does not announce again -- Windows copied an image meanwhile")
    func activationAfterWindowsImage() {
        var session = ClipboardSession(policy: F.bidirectional)
        #expect(session.clipboardReady(snapshot: F.snapshot(1, [F.text])) == .announce(.unicodeText))
        // Windows copies an image: Windows owns the clipboard, the Mac pasteboard is untouched.
        _ = session.remoteFormatsReceived(Self.windowsImage, changeCount: 1, now: ContinuousClock.now)
        // The user switches away and back: the activation check, same change count.
        #expect(session.pasteboardChanged(snapshot: F.snapshot(1, [F.text])) == .skip(.unchanged),
                "re-announcing would replace Windows' image with the Mac's OLD text")
        #expect(!session.macOwnsClipboard, "a skip announces nothing, so Windows stays the owner")
        #expect(session.counters.count(ClipboardAnnounceSkipReason.unchanged) == 1)
    }

    @Test("SPEC (gate r1): an activation with an unchanged change count does not kill the Windows text in flight")
    func activationKeepsInFlight() {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        #expect(session.remoteFormatsReceived(Self.windowsText, changeCount: 1, now: t0).request != nil)
        #expect(session.pasteboardChanged(snapshot: F.snapshot(1, [F.text])) == .skip(.unchanged))
        let answer = session.remoteDataReceived(.success(ClipboardTextCodec.encodeUnicodeText("fixture w")),
                                                changeCount: 1, now: t0 + .milliseconds(20))
        #expect(answer.outcome == .write(ClipboardText("fixture w"), sensitive: false),
                "the Windows copy must land; actual: \(answer.outcome)")
    }

    @Test("the ready records its count: the same count right after a ready is unchanged, the next one is judged",
          arguments: [ClipboardInitialListPolicy.always, .onlyIfText])
    func readyRecords(_ initialList: ClipboardInitialListPolicy) {
        var session = ClipboardSession(policy: F.bidirectional, initialList: initialList)
        _ = session.clipboardReady(snapshot: F.snapshot(5, [F.png]))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(5, [F.text])) == .skip(.unchanged))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(6, [F.text])) == .announce(.unicodeText))
    }

    @Test("every judged observation records its count, whatever the rules decided for it")
    func everyObservationRecords() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(1, []))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .announce(.unicodeText))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .skip(.unchanged))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(3, [F.png])) == .skip(.noTextType))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(3, [F.png])) == .skip(.unchanged))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(4, [F.text, F.concealed])) == .skip(.sensitiveType))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(4, [F.text, F.concealed])) == .skip(.unchanged))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(5, [F.text])) == .announce(.unicodeText))
        #expect(session.counters.count(ClipboardAnnounceSkipReason.unchanged) == 3)
    }

    @Test("a copy made in the background is caught by the activation check: its count differs")
    func backgroundCopyAtActivation() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        // Counts 2 and 3 happened while Macdows was in the background: not handed over.
        #expect(session.pasteboardChanged(snapshot: F.snapshot(3, [F.text])) == .announce(.unicodeText))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(3, [F.text])) == .skip(.unchanged))
    }

    @Test("'unchanged' is 'equal', not 'not greater': a count below the last one is a change")
    func equalityNotOrder() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(7, []))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(6, [F.text])) == .announce(.unicodeText))
    }

    @Test("order: rule 0 first, then unchanged, then rule 1 (direction) and rule 2 (own write, marker)")
    func order() {
        var session = ClipboardSession(policy: F.bidirectional)
        // Rule 0 before unchanged: after a reset the session still remembers 4, but rule 0 decides.
        _ = session.clipboardReady(snapshot: F.snapshot(4, []))
        session.reset()
        #expect(session.pasteboardChanged(snapshot: F.snapshot(4, [F.text])) == .skip(.beforeReady))
        // Unchanged before the direction rule.
        var off = ClipboardSession(policy: ClipboardPolicy(mode: .off))
        _ = off.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        #expect(off.pasteboardChanged(snapshot: F.snapshot(1, [F.text])) == .skip(.unchanged))
        #expect(off.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .skip(.directionNotAllowed))
        // Unchanged before the own-write rule: the App's own write is judged once, as its own.
        var own = ClipboardSession(policy: F.bidirectional)
        _ = own.clipboardReady(snapshot: F.snapshot(1, []))
        own.recordOwnWrite(changeCount: 2)
        #expect(own.pasteboardChanged(snapshot: F.snapshot(2, [F.text, F.marker])) == .skip(.ownWrite))
        #expect(own.pasteboardChanged(snapshot: F.snapshot(2, [F.text, F.marker])) == .skip(.unchanged))
        #expect(own.counters.count(ClipboardAnnounceSkipReason.ownWrite) == 1)
    }

    @Test("a ready after a disconnect records the new connection's count")
    func readyAfterReset() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = session.clipboardReady(snapshot: F.snapshot(1, []))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .announce(.unicodeText))
        session.reset()
        _ = session.clipboardReady(snapshot: F.snapshot(9, [F.text]))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(9, [F.text])) == .skip(.unchanged))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .announce(.unicodeText))
    }

    @Test("the reason is its own token, listed right after before-ready")
    func reasonToken() {
        #expect(ClipboardAnnounceSkipReason.unchanged.rawValue == "announce.unchanged")
        #expect(Array(ClipboardAnnounceSkipReason.allCases.prefix(3)) == [.beforeReady, .unchanged, .directionNotAllowed])
    }
}

@Suite("Clipboard S3: data-request answer")
struct ClipboardRespondTests {
    typealias F = ClipboardOutboundFixtures
    static let fixture = "fixture answer 测试 🧪"

    @Test("rule 0: a mode that does not allow Mac -> Windows gives NO answer -- not a failure answer",
          arguments: [ClipboardMode.unmanaged, .off, .remoteToLocalOnly])
    func directionNotAllowed(_ mode: ClipboardMode) {
        #expect(F.respond(Self.fixture, policy: ClipboardPolicy(mode: mode)) == .noAnswer(.directionNotAllowed))
    }

    @Test("rule 0 beats rule 1: not allowed AND inactive is still no answer")
    func ruleZeroBeatsInactive() {
        #expect(F.respond(Self.fixture, active: false, policy: ClipboardPolicy(mode: .off)) == .noAnswer(.directionNotAllowed))
        #expect(F.respond(nil, format: 1, snapshot: F.snapshot([F.concealed]), active: false, policy: ClipboardPolicy(mode: .remoteToLocalOnly))
                == .noAnswer(.directionNotAllowed))
    }

    @Test("rule 1: Macdows not active -> a failure answer, even for a request that would otherwise succeed")
    func inactive() {
        #expect(F.respond(Self.fixture, active: false) == .fail(.appInactive))
        #expect(F.respond(Self.fixture, active: false, policy: ClipboardPolicy(mode: .localToRemoteOnly)) == .fail(.appInactive))
        #expect(F.respond(Self.fixture, active: true) == .respond(ClipboardTextCodec.encodeUnicodeText(Self.fixture)))
    }

    @Test("rule 2: any format but 13 fails", arguments: [UInt32(0), 1, 7, 12, 14, 0xC0FF])
    func unsupportedFormat(_ formatId: UInt32) {
        #expect(F.respond(Self.fixture, format: formatId) == .fail(.unsupportedFormat))
    }

    @Test("rule 4: a sensitive marker at request time fails", arguments: Array(PasteboardTypes.sensitive).sorted())
    func sensitive(_ sensitiveType: String) {
        #expect(F.respond(Self.fixture, snapshot: F.snapshot([F.text, sensitiveType])) == .fail(.sensitiveType))
    }

    @Test("rule 5: no text -- nil, empty, or text that ends before it starts", arguments: [nil, "", "\u{0}fixture"] as [String?])
    func noText(_ text: String?) {
        #expect(F.respond(text) == .fail(.noText))
    }

    @Test("rule 6: over the Mac -> Windows limit fails; exactly at it is sent")
    func tooLarge() {
        let policy = ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: 10))
        if case .respond(let bytes) = F.respond("abcd", policy: policy) {
            #expect(bytes.count == 10)
        } else {
            Issue.record("exactly at the limit must be sent")
        }
        #expect(F.respond("abcde", policy: policy) == .fail(.tooLarge))
    }

    @Test("otherwise: respond with exactly the S7 encoding")
    func responds() {
        #expect(F.respond(Self.fixture) == .respond(ClipboardTextCodec.encodeUnicodeText(Self.fixture)))
    }

    @Test("the App's marker is NOT a reason to refuse: that text came from Windows")
    func markerDoesNotRefuse() {
        #expect(F.respond(Self.fixture, snapshot: F.snapshot(10, [F.text, F.marker]))
                == .respond(ClipboardTextCodec.encodeUnicodeText(Self.fixture)))
    }

    @Test("the snapshot's types do not need a text type: the text read at request time decides")
    func textDecidesNotTypes() {
        #expect(F.respond(Self.fixture, snapshot: F.snapshot([F.png])) == .respond(ClipboardTextCodec.encodeUnicodeText(Self.fixture)))
    }

    @Test("order: direction, then inactive, then format, then sensitive, then no text, then size")
    func order() {
        let tiny = ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: 2))
        #expect(F.respond(nil, format: 1, snapshot: F.snapshot([F.concealed]), active: false, policy: ClipboardPolicy(mode: .off)) == .noAnswer(.directionNotAllowed))
        #expect(F.respond(nil, format: 1, snapshot: F.snapshot([F.concealed]), active: false, policy: tiny) == .fail(.appInactive))
        #expect(F.respond(nil, format: 1, snapshot: F.snapshot([F.concealed]), policy: tiny) == .fail(.unsupportedFormat))
        #expect(F.respond(nil, snapshot: F.snapshot([F.concealed]), policy: tiny) == .fail(.sensitiveType))
        #expect(F.respond(nil, policy: tiny) == .fail(.noText))
        #expect(F.respond("a", policy: tiny) == .fail(.tooLarge))
    }

    @Test("counters: no answer, each failure and a response are each counted where they belong")
    func counted() {
        var session = ClipboardSession(policy: F.bidirectional)
        _ = F.ask(&session, format: 1, text: Self.fixture)
        _ = F.ask(&session, active: false, text: Self.fixture)
        _ = F.ask(&session, text: Self.fixture)
        #expect(session.counters.count(ClipboardRespondFailureReason.unsupportedFormat) == 1)
        #expect(session.counters.count(ClipboardRespondFailureReason.appInactive) == 1)
        #expect(session.counters.count(ClipboardNoAnswerReason.directionNotAllowed) == 0)
        var off = ClipboardSession(policy: ClipboardPolicy(mode: .remoteToLocalOnly))
        let none = F.ask(&off, text: Self.fixture)
        #expect(none == .noAnswer(.directionNotAllowed))
        #expect(off.counters.count(ClipboardNoAnswerReason.directionNotAllowed) == 1)
        #expect(off.counters.nonZeroEntries.map(\.token) == ["respond.direction"])
        var owned = ClipboardSession(policy: F.bidirectional, ownerCheck: .requireMacOwner)
        #expect(F.ask(&owned, text: Self.fixture) == .fail(.macNotOwner))
        #expect(owned.counters.nonZeroEntries.map(\.token) == ["respond.not-owner"])
    }
}

@Suite("Clipboard S3 rule 3: the owner check, when the policy requires it")
struct ClipboardOwnerCheckRequiredTests {
    typealias F = ClipboardOutboundFixtures
    static let fixture = "fixture owner 测试"
    static var answer: ClipboardRespondDecision { .respond(ClipboardTextCodec.encodeUnicodeText(fixture)) }

    static func ask(_ session: inout ClipboardSession, types: [String] = [ClipboardOutboundFixtures.text]) -> ClipboardRespondDecision {
        F.ask(&session, types: types, text: fixture)
    }

    @Test("never announced -> fail; a list naming 13 -> answered; a Windows list -> fail; a change naming 13 -> answered; an empty list -> fail; ready with text -> answered; disconnect -> fail")
    func lifecycle() {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: F.bidirectional, ownerCheck: .requireMacOwner)
        #expect(Self.ask(&session) == .fail(.macNotOwner), "never announced (not even ready)")
        #expect(session.clipboardReady(snapshot: F.snapshot(1, [F.text])) == .announce(.unicodeText))
        #expect(Self.ask(&session) == Self.answer, "the initial list named 13")
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false),
                                          changeCount: 1, now: t0)
        #expect(Self.ask(&session) == .fail(.macNotOwner), "a Windows list ended the ownership")
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.text])) == .announce(.unicodeText))
        #expect(Self.ask(&session) == Self.answer, "a change announcement naming 13")
        #expect(session.clipboardReady(snapshot: F.snapshot(3, [F.png])) == .announce(.empty))
        #expect(Self.ask(&session) == .fail(.macNotOwner), "an empty list (a ready with nothing to offer)")
        #expect(session.clipboardReady(snapshot: F.snapshot(4, [F.text])) == .announce(.unicodeText))
        #expect(Self.ask(&session) == Self.answer, "a later ready whose initial list names 13")
        session.reset()
        #expect(Self.ask(&session) == .fail(.macNotOwner), "a disconnect")
        #expect(session.counters.count(ClipboardRespondFailureReason.macNotOwner) == 4)
    }

    @Test("a Windows list with 13, or one Windows -> Mac does not even take, ends the ownership too",
          arguments: [ClipboardMode.bidirectional, .localToRemoteOnly])
    func anyWindowsList(_ mode: ClipboardMode) {
        var session = ClipboardSession(policy: ClipboardPolicy(mode: mode), ownerCheck: .requireMacOwner)
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        #expect(Self.ask(&session) == Self.answer)
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false),
                                          changeCount: 1, now: ContinuousClock.now)
        #expect(Self.ask(&session) == .fail(.macNotOwner))
    }

    @Test("a ready that withholds its list (.onlyIfText) ends the ownership by itself")
    func withheldReady() {
        var session = ClipboardSession(policy: F.bidirectional, initialList: .onlyIfText, ownerCheck: .requireMacOwner)
        #expect(session.clipboardReady(snapshot: F.snapshot(1, [F.text])) == .announce(.unicodeText))
        #expect(Self.ask(&session) == Self.answer)
        #expect(session.clipboardReady(snapshot: F.snapshot(2, [F.png])) == .skip(.initialListWithheld))
        #expect(!session.macOwnsClipboard)
        #expect(Self.ask(&session) == .fail(.macNotOwner))
    }

    @Test("a skipped change sends nothing, so it leaves the ownership as it was")
    func skippedChange() {
        var session = ClipboardSession(policy: F.bidirectional, ownerCheck: .requireMacOwner)
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        #expect(session.pasteboardChanged(snapshot: F.snapshot(2, [F.png])) == .skip(.noTextType))
        #expect(session.macOwnsClipboard)
        #expect(Self.ask(&session) == Self.answer)
    }

    @Test("order: format and inactive come before it; it comes before sensitive, no text and size; no answer beats all")
    func order() {
        let tiny = ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: 2))
        var session = ClipboardSession(policy: tiny, ownerCheck: .requireMacOwner)
        #expect(F.ask(&session, format: 1, types: [F.concealed], text: nil) == .fail(.unsupportedFormat))
        #expect(F.ask(&session, active: false, types: [F.concealed], text: nil) == .fail(.appInactive))
        #expect(F.ask(&session, types: [F.concealed], text: nil) == .fail(.macNotOwner))
        #expect(F.ask(&session, text: nil) == .fail(.macNotOwner))
        #expect(F.ask(&session, text: "a") == .fail(.macNotOwner))
        var off = ClipboardSession(policy: ClipboardPolicy(mode: .remoteToLocalOnly), ownerCheck: .requireMacOwner)
        #expect(F.ask(&off, text: Self.fixture) == .noAnswer(.directionNotAllowed))
        // Once the Mac owns the clipboard, the rules after it decide again.
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        #expect(F.ask(&session, types: [F.concealed], text: nil) == .fail(.sensitiveType))
        #expect(F.ask(&session, text: nil) == .fail(.noText))
        #expect(F.ask(&session, text: "a") == .fail(.tooLarge))
    }
}

@Suite("Clipboard S3 rule 3: off by default, and off means the other rules decide")
struct ClipboardOwnerCheckOffTests {
    typealias F = ClipboardOutboundFixtures
    static let fixture = "fixture owner off 测试"
    static var answer: ClipboardRespondDecision { .respond(ClipboardTextCodec.encodeUnicodeText(fixture)) }

    @Test("the policy is one named value; .off is the default, also the session's")
    func defaultIsOff() {
        #expect(ClipboardOwnerCheckPolicy.default == .off)
        #expect(ClipboardSession(policy: F.bidirectional).ownerCheck == .off)
    }

    @Test("every not-owner moment of the required lifecycle is answered normally", arguments: [
        ClipboardOwnerCheckPolicy.off, ClipboardOwnerCheckPolicy.default,
    ])
    func lifecycle(_ policy: ClipboardOwnerCheckPolicy) {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: F.bidirectional, ownerCheck: policy)
        #expect(F.ask(&session, text: Self.fixture) == Self.answer, "never announced")
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false),
                                          changeCount: 1, now: t0)
        #expect(F.ask(&session, text: Self.fixture) == Self.answer, "after a Windows list")
        _ = session.clipboardReady(snapshot: F.snapshot(2, [F.png]))
        #expect(F.ask(&session, text: Self.fixture) == Self.answer, "after an empty list")
        session.reset()
        #expect(F.ask(&session, text: Self.fixture) == Self.answer, "after a disconnect")
        #expect(session.counters.count(ClipboardRespondFailureReason.macNotOwner) == 0)
    }

    @Test("not the owner, and a sensitive marker or no text: those rules decide, not this one")
    func otherRulesDecide() {
        var session = ClipboardSession(policy: F.bidirectional)
        #expect(!session.macOwnsClipboard)
        #expect(F.ask(&session, types: [F.text, F.concealed], text: Self.fixture) == .fail(.sensitiveType))
        #expect(F.ask(&session, text: nil) == .fail(.noText))
    }

    @Test("ownership is tracked identically whichever way the policy is set", arguments: [
        ClipboardOwnerCheckPolicy.off, .requireMacOwner,
    ])
    func trackedEitherWay(_ policy: ClipboardOwnerCheckPolicy) {
        var session = ClipboardSession(policy: F.bidirectional, ownerCheck: policy)
        var seen: [Bool] = [session.macOwnsClipboard]
        _ = session.clipboardReady(snapshot: F.snapshot(1, [F.text]))
        seen.append(session.macOwnsClipboard)
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false),
                                          changeCount: 1, now: ContinuousClock.now)
        seen.append(session.macOwnsClipboard)
        _ = session.pasteboardChanged(snapshot: F.snapshot(2, [F.text]))
        seen.append(session.macOwnsClipboard)
        _ = session.clipboardReady(snapshot: F.snapshot(3, []))
        seen.append(session.macOwnsClipboard)
        _ = session.pasteboardChanged(snapshot: F.snapshot(4, [F.text]))
        seen.append(session.macOwnsClipboard)
        session.reset()
        seen.append(session.macOwnsClipboard)
        #expect(seen == [false, true, false, true, false, true, false])
    }
}

@Suite("Clipboard S3: a refused request reads no more of the pasteboard than its rule needs")
struct ClipboardStagedReadTests {
    typealias F = ClipboardOutboundFixtures
    typealias Reads = ClipboardOutboundFixtures.Reads

    static func reads(_ session: ClipboardSession, format: UInt32 = 13, active: Bool = true,
                      types: [String] = [ClipboardOutboundFixtures.text],
                      text: String? = "fixture staged") -> (ClipboardRespondDecision, Reads) {
        var session = session
        var reads = Reads()
        let decision = F.ask(&session, format: format, active: active, types: types, text: text, reads: &reads)
        return (decision, reads)
    }

    @Test("rules 0-3 read neither the types nor the text")
    func earlyRulesReadNothing() {
        let off = Self.reads(ClipboardSession(policy: ClipboardPolicy(mode: .off)))
        #expect(off.0 == .noAnswer(.directionNotAllowed))
        #expect(off.1 == Reads(types: 0, text: 0))
        let inactive = Self.reads(ClipboardSession(policy: F.bidirectional), active: false)
        #expect(inactive.0 == .fail(.appInactive))
        #expect(inactive.1 == Reads(types: 0, text: 0))
        let format = Self.reads(ClipboardSession(policy: F.bidirectional), format: 1)
        #expect(format.0 == .fail(.unsupportedFormat))
        #expect(format.1 == Reads(types: 0, text: 0))
        let notOwner = Self.reads(ClipboardSession(policy: F.bidirectional, ownerCheck: .requireMacOwner))
        #expect(notOwner.0 == .fail(.macNotOwner))
        #expect(notOwner.1 == Reads(types: 0, text: 0))
    }

    @Test("rule 4 reads the types once and never the text")
    func sensitiveReadsTypesOnly() {
        let sensitive = Self.reads(ClipboardSession(policy: F.bidirectional), types: [F.text, F.concealed])
        #expect(sensitive.0 == .fail(.sensitiveType))
        #expect(sensitive.1 == Reads(types: 1, text: 0))
    }

    @Test("rules 5 and 6 and an answer read each exactly once")
    func laterRulesReadBoth() {
        let none = Self.reads(ClipboardSession(policy: F.bidirectional), text: nil)
        #expect(none.0 == .fail(.noText))
        #expect(none.1 == Reads(types: 1, text: 1))
        let tiny = ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: 2))
        let large = Self.reads(ClipboardSession(policy: tiny), text: "a")
        #expect(large.0 == .fail(.tooLarge))
        #expect(large.1 == Reads(types: 1, text: 1))
        let answered = Self.reads(ClipboardSession(policy: F.bidirectional))
        #expect(answered.0 == .respond(ClipboardTextCodec.encodeUnicodeText("fixture staged")))
        #expect(answered.1 == Reads(types: 1, text: 1))
    }
}

/// S3 rule 6 (gate r1, m-5): the Mac pasteboard has no size limit, so an over-limit text must
/// be refused without first being encoded -- encoding allocates two to four times the text.
/// What is pinned is that the encoder is not reached (a spy passed to the internal decision),
/// and that the floor the decision checks first stops counting once it is past the limit.
@Suite("Clipboard S3 rule 6: an over-limit text is refused before it is encoded")
struct ClipboardRespondFloorTests {
    static func policy(_ limit: Int) -> ClipboardPolicy {
        ClipboardPolicy(mode: .bidirectional, limits: ClipboardLimits(localToRemoteMaxBytes: limit))
    }

    /// S3 through the internal decision, counting how often the encoder is called.
    static func decide(_ text: String?, limit: Int) -> (decision: ClipboardRespondDecision, encodes: Int) {
        var encodes = 0
        let decision = ClipboardOutbound.respondDecision(
            requestedFormatId: 13, isAppActive: true, policy: policy(limit), ownerCheck: .off, macOwnsClipboard: false,
            readTypes: { [] }, readText: { text },
            encode: { encodes += 1; return ClipboardTextCodec.encodeUnicodeText($0) })
        return (decision, encodes)
    }

    @Test("the floor: two bytes per unit before the first U+0000, plus the NUL; expansion not counted")
    func floorValues() {
        let unbounded = Int.max
        #expect(ClipboardTextCodec.encodedByteCountFloor("", stoppingAbove: unbounded) == 2)
        #expect(ClipboardTextCodec.encodedByteCountFloor("abc", stoppingAbove: unbounded) == 8)
        #expect(ClipboardTextCodec.encodedByteCountFloor("a\nb", stoppingAbove: unbounded) == 8)
        #expect(ClipboardTextCodec.encodedByteCountFloor("ab\u{0}cd", stoppingAbove: unbounded) == 6)
        #expect(ClipboardTextCodec.encodedByteCountFloor("\u{0}fixture", stoppingAbove: unbounded) == 2)
        #expect(ClipboardTextCodec.encodedByteCountFloor("🧪测", stoppingAbove: unbounded) == 8)
        // Exact while at most the ceiling...
        #expect(ClipboardTextCodec.encodedByteCountFloor("abcd", stoppingAbove: 10) == 10)
        // ...and it stops at the first count past it: a long text costs ceiling / 2 steps.
        #expect(ClipboardTextCodec.encodedByteCountFloor(String(repeating: "x", count: 1000), stoppingAbove: 10) == 12)
        // A ceiling below two still counts the first unit, so "any text" stays more than two.
        #expect(ClipboardTextCodec.encodedByteCountFloor("a", stoppingAbove: 0) == 4)
    }

    @Test("a floor over the limit is refused and the encoder is never reached -- a short text and a huge one")
    func refusedWithoutEncoding() {
        let short = Self.decide("abcde", limit: 10) // floor 12
        #expect(short.decision == .fail(.tooLarge))
        #expect(short.encodes == 0)
        let huge = Self.decide(String(repeating: "x", count: 1_000_000), limit: 64)
        #expect(huge.decision == .fail(.tooLarge))
        #expect(huge.encodes == 0)
    }

    @Test("a floor exactly at the limit is encoded and sent")
    func floorAtLimit() {
        let at = Self.decide("abcd", limit: 10)
        #expect(at.decision == .respond(ClipboardTextCodec.encodeUnicodeText("abcd")))
        #expect(at.encodes == 1)
    }

    @Test("within the floor but over after LF expansion: encoded once, then refused by the exact check")
    func expansionStillChecked() {
        let expanded = Self.decide("ab\n\n", limit: 10) // floor 10, encoded a b CR LF CR LF NUL = 14
        #expect(expanded.decision == .fail(.tooLarge))
        #expect(expanded.encodes == 1)
    }

    @Test("the floor stops at the first U+0000: a short text with a long tail after it is sent")
    func tailAfterNulIgnored() {
        let tailed = Self.decide("ab\u{0}" + String(repeating: "x", count: 1000), limit: 10)
        #expect(tailed.decision == .respond(ClipboardTextCodec.encodeUnicodeText("ab")))
        #expect(tailed.encodes == 1)
    }

    @Test("no text is still rule 5, before rule 6, and reaches no encoder", arguments: ["", "\u{0}fixture"])
    func noTextFirst(_ text: String) {
        for limit in [0, 1, 2, 10] {
            let empty = Self.decide(text, limit: limit)
            #expect(empty.decision == .fail(.noText), "limit \(limit)")
            #expect(empty.encodes == 0)
        }
        let one = Self.decide("a", limit: 1)
        #expect(one.decision == .fail(.tooLarge))
        #expect(one.encodes == 0)
    }

    @Test("through the session: a text far over the limit is refused, counted as too large")
    func throughTheSession() {
        var session = ClipboardSession(policy: Self.policy(64))
        let decision = session.dataRequested(formatId: 13, isAppActive: true, readTypes: { [] },
                                             readText: { String(repeating: "y", count: 3_000_000) })
        #expect(decision == .fail(.tooLarge))
        #expect(session.counters.count(ClipboardRespondFailureReason.tooLarge) == 1)
    }
}
