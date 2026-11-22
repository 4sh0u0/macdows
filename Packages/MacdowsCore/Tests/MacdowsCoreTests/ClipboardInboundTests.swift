import MacdowsCore
import Testing

// S4 (Windows -> Mac), S5 (one request on the wire, generations, slow answers), S8 (disconnect),
// all through `ClipboardSession`, the one type the App drives. Time is always passed in: one
// instant is read once per test and every other time is an exact offset from it, so "exactly
// 9 s" really is exactly 9 s. Generation numbers are never read: every rule is pinned by what
// happens to an answer. The Mac pasteboard's change count is modelled as a plain number the
// tests move by hand. Fixture strings are invented.

enum ClipboardInboundFixtures {
    static let fixture = "fixture inbound 测试 🧪"
    static let second = "fixture second copy 二"
    static let third = "fixture third copy 三"
    static let textType = "public.utf8-plain-text"

    /// A Windows list naming 13, not marked excluded.
    static let text = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false)
    /// A Windows list naming 13 and marked excluded.
    static let excludedText = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: true)
    /// A Windows list without 13.
    static let noText = ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false)

    static func ok(_ text: String) -> ClipboardDataResponse {
        .success(ClipboardTextCodec.encodeUnicodeText(text))
    }

    /// The outcome that writes `text`, as ordinary or as sensitive content.
    static func write(_ text: String, sensitive: Bool = false) -> ClipboardInboundOutcome {
        .write(ClipboardText(text), sensitive: sensitive)
    }

    static func session(_ mode: ClipboardMode = .bidirectional, limits: ClipboardLimits = .standard,
                        initialList: ClipboardInitialListPolicy = .always) -> ClipboardSession {
        ClipboardSession(policy: ClipboardPolicy(mode: mode, limits: limits), initialList: initialList)
    }

    static func textSnapshot(_ changeCount: Int) -> PasteboardSnapshot {
        PasteboardSnapshot(changeCount: changeCount, types: [textType])
    }
}

/// The bridge, the App and the wire as these tests model them. Every request the session hands
/// out is posted -- the caller's obligation -- and joins the wire; the server answers the
/// oldest request first. `changeCount` is the Mac pasteboard's change count as the App reads
/// it: passed to both Windows -> Mac entries, moved by every write the App makes (which it
/// then records, S2 rule 2) and by `unannouncedMacCopy()`. `maxOnWire` is the most requests
/// that were ever on the wire at once.
struct ClipboardWireModel {
    var session: ClipboardSession
    var onWire = 0
    var maxOnWire = 0
    var requestsSent = 0
    var written: [String] = []
    var writtenSensitive: [Bool] = []
    var changeCount = 100

    init(_ session: ClipboardSession) {
        self.session = session
    }

    mutating func post(_ request: ClipboardDataRequest?) {
        guard let request else { return }
        #expect(request.formatId == 13)
        onWire += 1
        requestsSent += 1
        maxOnWire = max(maxOnWire, onWire)
    }

    @discardableResult
    mutating func formats(_ offersUnicodeText: Bool, excluded: Bool = false,
                          _ now: ContinuousClock.Instant) -> ClipboardRequestDecision {
        let decision = session.remoteFormatsReceived(
            ClipboardRemoteFormats(offersUnicodeText: offersUnicodeText, isRemoteExcluded: excluded),
            changeCount: changeCount, now: now)
        post(decision.request)
        return decision
    }

    /// The server answers the oldest request on the wire.
    @discardableResult
    mutating func answer(_ response: ClipboardDataResponse, _ now: ContinuousClock.Instant) -> ClipboardRemoteDataResult {
        #expect(onWire > 0, "the model's server only answers requests it was sent")
        onWire -= 1
        return deliver(response, now)
    }

    /// A response arrives whether or not anything was asked (an unsolicited one).
    @discardableResult
    mutating func deliver(_ response: ClipboardDataResponse, _ now: ContinuousClock.Instant) -> ClipboardRemoteDataResult {
        let result = session.remoteDataReceived(response, changeCount: changeCount, now: now)
        if case .write(let text, let sensitive) = result.outcome {
            written.append(text.value)
            writtenSensitive.append(sensitive)
            // The App writes; the pasteboard's change count moves; the App records it.
            changeCount += 1
            session.recordOwnWrite(changeCount: changeCount)
        }
        post(result.request)
        return result
    }

    /// The user copies something on the Mac that is NOT announced -- Macdows in the background,
    /// a screenshot to the clipboard, a copy with a sensitive marker: only the change count moves.
    mutating func unannouncedMacCopy() {
        changeCount += 1
    }

    /// A ready from the server (S4 rule 5) with an empty Mac pasteboard. The server that sent
    /// it has restarted its clipboard process: it will never answer what was on the wire.
    @discardableResult
    mutating func ready() -> ClipboardAnnounceDecision {
        onWire = 0
        return session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: changeCount, types: []))
    }
}

@Suite("Clipboard S4/S5: inbound flow")
struct ClipboardInboundFlowTests {
    typealias F = ClipboardInboundFixtures

    @Test("a normal round: a list with 13 requests 13, the answer is written, nothing follows")
    func normalRound() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        let decision = wire.formats(true, t0)
        #expect(decision.request?.formatId == 13)
        #expect(wire.session.isRequestInFlight)
        let result = wire.answer(F.ok(F.fixture), t0 + .milliseconds(30))
        #expect(result.outcome == F.write(F.fixture))
        #expect(result.request == nil)
        #expect(!wire.session.isRequestInFlight)
        #expect(wire.session.counters.nonZeroEntries.isEmpty)
    }

    /// The case version 1 lost: the second copy is no longer missed, and the first answer is
    /// never written over it.
    @Test("two lists with 13 in a row, the first answer after both: it is stale, the follow-up fetches the second")
    func twoListsInARow() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        #expect(wire.formats(true, t0).request != nil)
        #expect(wire.formats(true, t0 + .milliseconds(1)) == .noRequest(.requestInFlight))
        let first = wire.answer(F.ok(F.fixture), t0 + .milliseconds(2))
        #expect(first.outcome == .drop(.staleAnswer))
        #expect(first.request?.formatId == 13, "the follow-up check requests the newer list's text")
        let second = wire.answer(F.ok(F.second), t0 + .milliseconds(3))
        #expect(second.outcome == F.write(F.second))
        #expect(second.request == nil)
        #expect(wire.written == [F.second])
        #expect(wire.maxOnWire == 1, "never more than one request on the wire")
        #expect(wire.requestsSent == 2)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.staleAnswer) == 1)
        #expect(wire.session.counters.count(ClipboardNoRequestReason.requestInFlight) == 1)
    }

    @Test("three lists while one request is out: one follow-up only, for the newest")
    func threeLists() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        wire.formats(true, t0)
        wire.formats(true, t0)
        let first = wire.answer(F.ok(F.fixture), t0)
        #expect(first.outcome == .drop(.staleAnswer))
        let last = wire.answer(F.ok(F.third), t0)
        #expect(last.outcome == F.write(F.third))
        #expect(wire.requestsSent == 2)
        #expect(wire.maxOnWire == 1)
    }

    @Test("a local announcement while a request is out: the answer is dropped, nothing follows, nothing is written")
    func localAnnouncementSupersedes() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        _ = wire.session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 1, types: []))
        wire.formats(true, t0)
        let announced = wire.session.pasteboardChanged(snapshot: F.textSnapshot(2))
        #expect(announced == .announce(.unicodeText))
        let result = wire.answer(F.ok(F.fixture), t0)
        #expect(result.outcome == .drop(.staleAnswer))
        #expect(result.request == nil)
        #expect(wire.written.isEmpty)
    }

    @Test("a local announcement also cancels a list that was waiting behind the request")
    func localAnnouncementCancelsPending() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        _ = wire.session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 1, types: []))
        wire.formats(true, t0)
        wire.formats(true, t0)          // waits behind the request
        _ = wire.session.pasteboardChanged(snapshot: F.textSnapshot(2))
        let result = wire.answer(F.ok(F.fixture), t0)
        #expect(result.outcome == .drop(.staleAnswer))
        #expect(result.request == nil, "the Mac owns the clipboard now: Windows' older text is not fetched")
        #expect(wire.requestsSent == 1)
    }

    @Test("a list without 13 also cancels a list with 13 that was waiting behind the request")
    func listWithoutTextCancelsPending() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        #expect(wire.formats(true, t0) == .noRequest(.requestInFlight))   // waits behind the request
        #expect(wire.formats(false, t0) == .noRequest(.noUnicodeText))    // Windows now holds no text
        let result = wire.answer(F.ok(F.fixture), t0)
        #expect(result.outcome == .drop(.staleAnswer))
        #expect(result.request == nil, "the text that was waiting is gone from Windows: nothing to fetch")
        #expect(wire.requestsSent == 1)
    }

    @Test("a list without 13 while a request is out: the answer is dropped, nothing follows")
    func listWithoutTextSupersedes() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        #expect(wire.formats(false, t0) == .noRequest(.noUnicodeText))
        let result = wire.answer(F.ok(F.fixture), t0)
        #expect(result.outcome == .drop(.staleAnswer))
        #expect(result.request == nil)
        #expect(wire.written.isEmpty)
    }

    @Test("an answer with no request in flight is unexpected: dropped, counted, and the state is undisturbed")
    func unexpectedAnswer() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        let early = wire.deliver(F.ok(F.fixture), t0)
        #expect(early.outcome == .drop(.unexpectedAnswer))
        #expect(early.request == nil)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.unexpectedAnswer) == 1)
        // A normal round afterwards.
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second))
        // A second answer to the same request is unexpected too, and the next round is normal.
        #expect(wire.deliver(F.ok(F.fixture), t0).outcome == .drop(.unexpectedAnswer))
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.third), t0).outcome == F.write(F.third))
        #expect(wire.written == [F.second, F.third])
        #expect(wire.session.counters.count(ClipboardInboundDropReason.unexpectedAnswer) == 2)
    }

    @Test("a failure answer clears the request and is counted; nothing is pending, so nothing follows")
    func failureAnswer() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        let result = wire.answer(.failure, t0)
        #expect(result.outcome == .drop(.remoteFailure))
        #expect(result.request == nil)
        #expect(!wire.session.isRequestInFlight)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.remoteFailure) == 1)
        // Cleared, not stuck: the next list requests at once.
        #expect(wire.formats(true, t0).request != nil)
    }

    /// The only way the pending generation can equal the current one when an answer arrives is
    /// a newer list having come in behind the request -- which makes the answer stale first, so
    /// a failure answer reaching the follow-up check with text pending is counted as stale.
    @Test("a failure answer to a superseded request: counted as stale, and the follow-up fetches the pending text")
    func failureWithTextPending() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        wire.formats(true, t0)
        let failed = wire.answer(.failure, t0)
        #expect(failed.outcome == .drop(.staleAnswer))
        #expect(failed.request != nil)
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second))
        #expect(wire.maxOnWire == 1)
    }

    @Test("a server that never answers: no further request for any number of lists, one slow count, back after a reset")
    func serverNeverAnswers() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        for second in 1...20 {
            #expect(wire.formats(true, t0 + .seconds(second)) == .noRequest(.requestInFlight))
        }
        wire.session.tick(now: t0 + .seconds(30))
        wire.session.tick(now: t0 + .seconds(300))
        #expect(wire.requestsSent == 1)
        #expect(wire.session.counters.count(ClipboardInboundNotice.slowAnswer) == 1)
        #expect(wire.session.isRequestInFlight, "a slow request stays in flight")
        // Reconnect: the dead request is forgotten.
        wire.session.reset()
        wire.onWire = 0
        let decision = wire.formats(true, t0 + .seconds(301))
        #expect(decision.request != nil)
        #expect(wire.answer(F.ok(F.fixture), t0 + .seconds(302)).outcome == F.write(F.fixture))
    }

    @Test("a mode that does not allow Windows -> Mac never requests", arguments: [
        ClipboardMode.unmanaged, .off, .localToRemoteOnly,
    ])
    func directionNotAllowed(_ mode: ClipboardMode) {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session(mode))
        #expect(wire.formats(true, t0) == .noRequest(.directionNotAllowed))
        #expect(wire.formats(true, t0) == .noRequest(.directionNotAllowed))
        #expect(wire.deliver(F.ok(F.fixture), t0).outcome == .drop(.unexpectedAnswer))
        #expect(wire.formats(true, t0) == .noRequest(.directionNotAllowed))
        #expect(wire.requestsSent == 0)
        #expect(wire.written.isEmpty)
    }

    @Test("the Windows -> Mac-only mode requests")
    func remoteToLocalOnlyRequests() {
        var session = F.session(.remoteToLocalOnly)
        #expect(session.remoteFormatsReceived(F.text, changeCount: 1, now: ContinuousClock.now).request?.formatId == 13)
    }

    @Test("list order: direction before content before the request in flight")
    func listOrder() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        // In flight AND no 13: "no text" is the reason.
        #expect(session.remoteFormatsReceived(F.noText, changeCount: 1, now: t0) == .noRequest(.noUnicodeText))
        var off = F.session(.off)
        #expect(off.remoteFormatsReceived(F.noText, changeCount: 1, now: t0) == .noRequest(.directionNotAllowed))
    }
}

@Suite("Clipboard S4: every announcement starts a new generation")
struct ClipboardAnnouncementGenerationTests {
    typealias F = ClipboardInboundFixtures

    @Test("a change announcement does too, every time", arguments: [1, 2, 5])
    func changeAnnouncements(_ count: Int) {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        _ = wire.session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 0, types: []))
        for round in 0..<count {
            wire.formats(true, t0)
            #expect(wire.session.pasteboardChanged(snapshot: F.textSnapshot(10 + round)) == .announce(.unicodeText))
            #expect(wire.answer(F.ok(F.fixture), t0).outcome == .drop(.staleAnswer))
        }
        #expect(wire.written.isEmpty)
    }

    /// Version 2 also listed "a withheld initial list" here. Version 3's ready forgets the
    /// request in flight whatever list it sends (S4 rule 5, pinned in its own suite), so that
    /// case is no longer an announcement question.
    @Test("a skipped change and a change before ready do NOT: the answer is written")
    func skipsDoNotAdvance() {
        let t0 = ContinuousClock.now
        // Before ready.
        var early = ClipboardWireModel(F.session())
        early.formats(true, t0)
        #expect(early.session.pasteboardChanged(snapshot: F.textSnapshot(1)) == .skip(.beforeReady))
        #expect(early.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture))
        // A skipped change after ready (no text type; the App's own write).
        var skipped = ClipboardWireModel(F.session())
        _ = skipped.session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 0, types: []))
        skipped.session.recordOwnWrite(changeCount: 7)
        skipped.formats(true, t0)
        #expect(skipped.session.pasteboardChanged(snapshot: PasteboardSnapshot(changeCount: 6, types: ["public.png"])) == .skip(.noTextType))
        #expect(skipped.session.pasteboardChanged(snapshot: F.textSnapshot(7)) == .skip(.ownWrite))
        // An activation with nothing new (the v3 patch's unchanged count) does not either.
        #expect(skipped.session.pasteboardChanged(snapshot: F.textSnapshot(7)) == .skip(.unchanged))
        #expect(skipped.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture))
    }
}

@Suite("Clipboard S4 rule 5: a ready forgets the request in flight and the pending offer")
struct ClipboardReadyClearsInboundTests {
    typealias F = ClipboardInboundFixtures

    @Test("a ready while a request is out: the request is gone, and its late answer is UNEXPECTED, never written",
          arguments: [ClipboardInitialListPolicy.always, .onlyIfText])
    func lateAnswerIsUnexpected(_ initialList: ClipboardInitialListPolicy) {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session(initialList: initialList))
        wire.formats(true, t0)
        #expect(wire.session.isRequestInFlight)
        let ready = wire.ready()
        #expect(ready == (initialList == .always ? .announce(.empty) : .skip(.initialListWithheld)))
        #expect(!wire.session.isRequestInFlight)
        #expect(!wire.session.expectsRemoteData)
        // The old server, against the model, answers after all.
        let late = wire.deliver(F.ok(F.fixture), t0)
        #expect(late.outcome == .drop(.unexpectedAnswer))
        #expect(late.request == nil)
        #expect(wire.written.isEmpty)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.unexpectedAnswer) == 1)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.staleAnswer) == 0)
    }

    /// Version 2 stalled here for the rest of the connection: the request of the old server
    /// clipboard process is never answered, and nothing new may go out while it is in flight.
    @Test("after a ready, the next Windows list requests at once and its answer is written",
          arguments: [ClipboardInitialListPolicy.always, .onlyIfText])
    func nextListRequestsAtOnce(_ initialList: ClipboardInitialListPolicy) {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session(initialList: initialList))
        wire.formats(true, t0)
        wire.ready()
        let decision = wire.formats(true, t0 + .seconds(1))
        #expect(decision.request?.formatId == 13)
        #expect(wire.answer(F.ok(F.second), t0 + .seconds(2)).outcome == F.write(F.second))
        #expect(wire.maxOnWire == 1)
    }

    @Test("a ready also forgets an offer waiting behind the request: nothing is fetched for it",
          arguments: [ClipboardInitialListPolicy.always, .onlyIfText])
    func forgetsPending(_ initialList: ClipboardInitialListPolicy) {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session(initialList: initialList))
        wire.formats(true, t0)
        #expect(wire.formats(true, t0) == .noRequest(.requestInFlight))
        wire.ready()
        let late = wire.deliver(F.ok(F.fixture), t0)
        #expect(late.outcome == .drop(.unexpectedAnswer))
        #expect(late.request == nil, "the offer was made to the server process that is gone")
        #expect(wire.requestsSent == 1)
    }

    @Test("a connection can be ready any number of times, and works after each")
    func manyReadies() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        for round in 0..<4 {
            wire.formats(true, t0)          // never answered: the server restarts its clipboard
            wire.ready()
            #expect(!wire.session.isRequestInFlight, "round \(round)")
        }
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.third), t0).outcome == F.write(F.third))
        #expect(wire.written == [F.third])
    }

    @Test("the same when the initial list names 13: the late answer is unexpected, and the Mac owns the clipboard")
    func textInitialList() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        wire.onWire = 0
        #expect(wire.session.clipboardReady(snapshot: F.textSnapshot(wire.changeCount)) == .announce(.unicodeText))
        #expect(wire.session.macOwnsClipboard)
        #expect(wire.deliver(F.ok(F.fixture), t0).outcome == .drop(.unexpectedAnswer))
        #expect(wire.written.isEmpty)
    }

    @Test("a ready with nothing in flight changes nothing for the next round")
    func idleReady() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.ready()
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture))
    }
}

@Suite("Clipboard S4 (v3): the Mac change count at the list's arrival is the baseline")
struct ClipboardChangeCountBaselineTests {
    typealias F = ClipboardInboundFixtures

    @Test("an unannounced Mac copy while the request is out: the answer is dropped as local-newer, nothing is written")
    func unannouncedCopyWhileInFlight() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        wire.unannouncedMacCopy()
        let result = wire.answer(F.ok(F.fixture), t0)
        #expect(result.outcome == .drop(.localNewer))
        #expect(result.request == nil)
        #expect(!wire.session.isRequestInFlight)
        #expect(wire.written.isEmpty)
        #expect(wire.session.counters.count(ClipboardInboundDropReason.localNewer) == 1)
    }

    /// L1 is requested at c0; L2 arrives at c0 and waits; the user copies (c1); L1's answer is
    /// stale and L2 is requested only now, at c1. Its baseline is still c0: taken when L2
    /// ARRIVED. A baseline taken when the request went out would be c1 and write over the copy.
    @Test("the baseline is the count when the list arrived, not when its request finally went out")
    func baselineAtArrival() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)                                      // L1, request, baseline c0
        #expect(wire.formats(true, t0) == .noRequest(.requestInFlight))  // L2 at c0, waits
        wire.unannouncedMacCopy()                                   // c1
        let first = wire.answer(F.ok(F.fixture), t0)
        #expect(first.outcome == .drop(.staleAnswer))
        #expect(first.request != nil, "L2 is requested now, at c1")
        let second = wire.answer(F.ok(F.second), t0)
        #expect(second.outcome == .drop(.localNewer))
        #expect(wire.written.isEmpty)
    }

    @Test("a copy BEFORE the list arrived is already in its baseline: the answer is written")
    func copyBeforeTheList() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.unannouncedMacCopy()
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture))
    }

    @Test("after an accepted write the App records its own count; the next list's baseline is that count and its answer is written")
    func baselineAfterOwnWrite() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture))
        #expect(wire.changeCount == 101, "the model's App wrote and recorded the new count")
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second))
        wire.formats(true, t0)
        #expect(wire.answer(F.ok(F.third), t0).outcome == F.write(F.third))
        #expect(wire.written == [F.fixture, F.second, F.third])
        #expect(wire.session.counters.count(ClipboardInboundDropReason.localNewer) == 0)
    }

    @Test("the rule is 'not equal': a count below the baseline is a change too")
    func notEqualBothWays() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 50, now: t0)
        #expect(session.remoteDataReceived(F.ok(F.fixture), changeCount: 49, now: t0).outcome == .drop(.localNewer))
        _ = session.remoteFormatsReceived(F.text, changeCount: 50, now: t0)
        #expect(session.remoteDataReceived(F.ok(F.fixture), changeCount: 51, now: t0).outcome == .drop(.localNewer))
        _ = session.remoteFormatsReceived(F.text, changeCount: 50, now: t0)
        #expect(session.remoteDataReceived(F.ok(F.fixture), changeCount: 50, now: t0).outcome == F.write(F.fixture))
    }

    @Test("order: stale, then failure, then local-newer, then size, unavailable, malformed and empty")
    func order() {
        let t0 = ContinuousClock.now
        let limits = ClipboardLimits(remoteToLocalMaxBytes: 8)
        func judged(_ response: ClipboardDataResponse, moved: Bool) -> ClipboardInboundOutcome {
            var session = F.session(limits: limits)
            _ = session.remoteFormatsReceived(F.text, changeCount: 5, now: t0)
            return session.remoteDataReceived(response, changeCount: moved ? 6 : 5, now: t0).outcome
        }
        #expect(judged(.failure, moved: true) == .drop(.remoteFailure))
        #expect(judged(F.ok("abcd"), moved: true) == .drop(.localNewer))                          // 10 bytes: over
        #expect(judged(F.ok("abcd"), moved: false) == .drop(.tooLarge))
        #expect(judged(.successWithoutBytes(byteCount: 9), moved: true) == .drop(.localNewer))
        #expect(judged(.successWithoutBytes(byteCount: 9), moved: false) == .drop(.tooLarge))
        #expect(judged(.successWithoutBytes(byteCount: 8), moved: true) == .drop(.localNewer))
        #expect(judged(.successWithoutBytes(byteCount: 8), moved: false) == .drop(.bytesUnavailable))
        #expect(judged(.success(ClipboardBytes([0x61, 0x00, 0x62])), moved: true) == .drop(.localNewer))
        #expect(judged(.success(ClipboardBytes([0, 0])), moved: true) == .drop(.localNewer))
        // Stale beats local-newer: L1 is superseded by L2 and the Mac moved; L1's answer is stale.
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 5, now: t0)
        _ = session.remoteFormatsReceived(F.noText, changeCount: 5, now: t0)
        #expect(session.remoteDataReceived(F.ok(F.fixture), changeCount: 6, now: t0).outcome == .drop(.staleAnswer))
    }
}

@Suite("Clipboard S4 (v3): the remote exclusion mark travels with its own list")
struct ClipboardRemoteExclusionTests {
    typealias F = ClipboardInboundFixtures

    @Test("a list marked excluded: its text is written as sensitive; unmarked: as ordinary text")
    func markedAndUnmarked() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, excluded: true, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture, sensitive: true))
        wire.formats(true, excluded: false, t0)
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second, sensitive: false))
        #expect(wire.writtenSensitive == [true, false])
    }

    @Test("L1 marked, L2 not, L1's answer stale: L2's text is written as ordinary -- the mark does not leak forward")
    func markDoesNotLeakForward() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, excluded: true, t0)
        wire.formats(true, excluded: false, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == .drop(.staleAnswer))
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second, sensitive: false))
    }

    @Test("L1 not marked, L2 marked, L1's answer stale: L2's text is written as sensitive -- the mark rides the pending offer")
    func markRidesThePendingOffer() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, excluded: false, t0)
        wire.formats(true, excluded: true, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == .drop(.staleAnswer))
        #expect(wire.answer(F.ok(F.second), t0).outcome == F.write(F.second, sensitive: true))
    }

    @Test("a marked list without 13 requests nothing, and its mark does not reach the next list")
    func markedListWithoutText() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        #expect(wire.formats(false, excluded: true, t0) == .noRequest(.noUnicodeText))
        wire.formats(true, excluded: false, t0)
        #expect(wire.answer(F.ok(F.fixture), t0).outcome == F.write(F.fixture, sensitive: false))
    }

    @Test("the mark survives a slow answer")
    func markSurvivesSlowAnswer() {
        let t0 = ContinuousClock.now
        var wire = ClipboardWireModel(F.session())
        wire.formats(true, excluded: true, t0)
        wire.session.tick(now: t0 + .seconds(20))
        #expect(wire.answer(F.ok(F.fixture), t0 + .seconds(21)).outcome == F.write(F.fixture, sensitive: true))
    }

    @Test("the flags word decodes bit by bit; unknown bits are ignored; encoding is its inverse")
    func flagsDecode() {
        #expect(ClipboardRemoteFormats.offersUnicodeTextFlag == 1)
        #expect(ClipboardRemoteFormats.remoteExcludedFlag == 2)
        #expect(ClipboardRemoteFormats(flags: 0) == ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: false))
        #expect(ClipboardRemoteFormats(flags: 1) == ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false))
        #expect(ClipboardRemoteFormats(flags: 2) == ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: true))
        #expect(ClipboardRemoteFormats(flags: 3) == ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: true))
        #expect(ClipboardRemoteFormats(flags: 0xFFFF_FFFC) == ClipboardRemoteFormats(flags: 0))
        #expect(ClipboardRemoteFormats(flags: 0xFFFF_FFFD) == ClipboardRemoteFormats(flags: 1))
        for flags: UInt32 in 0...3 {
            #expect(ClipboardRemoteFormats(flags: flags).flags == flags)
        }
    }
}

@Suite("Clipboard S4: payload rules on a current answer")
struct ClipboardInboundPayloadFlowTests {
    typealias F = ClipboardInboundFixtures

    static func current(_ response: ClipboardDataResponse, limits: ClipboardLimits = .standard) -> (ClipboardRemoteDataResult, ClipboardSession) {
        let t0 = ContinuousClock.now
        var session = F.session(limits: limits)
        _ = session.remoteFormatsReceived(F.text, changeCount: 3, now: t0)
        let result = session.remoteDataReceived(response, changeCount: 3, now: t0)
        return (result, session)
    }

    @Test("an over-limit answer is dropped, never truncated")
    func overLimit() {
        let limits = ClipboardLimits(remoteToLocalMaxBytes: 8)
        let (over, session) = Self.current(F.ok("abcd"), limits: limits) // 10 bytes
        #expect(over.outcome == .drop(.tooLarge))
        #expect(over.request == nil)
        #expect(session.counters.count(ClipboardInboundDropReason.tooLarge) == 1)
        #expect(Self.current(F.ok("abc"), limits: limits).0.outcome == F.write("abc")) // 8 bytes
    }

    @Test("a malformed answer is dropped with its own reason")
    func malformed() {
        let (result, session) = Self.current(.success(ClipboardBytes([0x61, 0x00, 0x62])))
        #expect(result.outcome == .drop(.malformed))
        #expect(session.counters.count(ClipboardInboundDropReason.malformed) == 1)
    }

    @Test("an empty text is not written", arguments: [[UInt8](), [0, 0], [0, 0, 0x61, 0x00], [0, 0, 0x61]])
    func emptyText(_ bytes: [UInt8]) {
        let (result, session) = Self.current(.success(ClipboardBytes(bytes)))
        #expect(result.outcome == .drop(.emptyText))
        #expect(session.counters.count(ClipboardInboundDropReason.emptyText) == 1)
    }

    @Test("bytes the producer could not hand over: over-limit by their wire length, otherwise unavailable, each counted")
    func withoutBytes() {
        let limits = ClipboardLimits(remoteToLocalMaxBytes: 8)
        let (over, overSession) = Self.current(.successWithoutBytes(byteCount: 9), limits: limits)
        #expect(over.outcome == .drop(.tooLarge))
        #expect(overSession.counters.count(ClipboardInboundDropReason.tooLarge) == 1)
        let (missing, missingSession) = Self.current(.successWithoutBytes(byteCount: 8), limits: limits)
        #expect(missing.outcome == .drop(.bytesUnavailable))
        #expect(missingSession.counters.count(ClipboardInboundDropReason.bytesUnavailable) == 1)
        #expect(missingSession.counters.count(ClipboardInboundDropReason.tooLarge) == 0)
    }

    @Test("expectsRemoteData: true exactly while a current request is in flight")
    func expectsRemoteData() {
        let t0 = ContinuousClock.now
        var session = F.session()
        #expect(!session.expectsRemoteData)
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(session.expectsRemoteData)
        _ = session.remoteFormatsReceived(F.noText, changeCount: 1, now: t0)
        #expect(!session.expectsRemoteData, "superseded by a newer list")
        _ = session.remoteDataReceived(.failure, changeCount: 1, now: t0)
        #expect(!session.expectsRemoteData)
        _ = session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 1, types: []))
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(session.expectsRemoteData)
        _ = session.pasteboardChanged(snapshot: F.textSnapshot(2))
        #expect(!session.expectsRemoteData, "superseded by an announcement")
        _ = session.remoteDataReceived(.failure, changeCount: 2, now: t0)
        _ = session.remoteFormatsReceived(F.text, changeCount: 2, now: t0)
        _ = session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 2, types: []))
        #expect(!session.expectsRemoteData, "forgotten by a ready")
    }

    @Test("when expectsRemoteData is false, skipping the take gives the same result as taking the bytes")
    func skippingTheTakeIsEquivalent() {
        let t0 = ContinuousClock.now
        let bytes = ClipboardTextCodec.encodeUnicodeText(F.fixture)
        // Unexpected.
        var a = F.session()
        var b = F.session()
        #expect(!a.expectsRemoteData)
        #expect(a.remoteDataReceived(.success(bytes), changeCount: 1, now: t0)
                == b.remoteDataReceived(.successWithoutBytes(byteCount: bytes.count), changeCount: 1, now: t0))
        #expect(a == b)
        // Stale, with a follow-up request.
        _ = a.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        _ = a.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        _ = b.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        _ = b.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(!a.expectsRemoteData)
        let taken = a.remoteDataReceived(.success(bytes), changeCount: 1, now: t0)
        let skipped = b.remoteDataReceived(.successWithoutBytes(byteCount: bytes.count), changeCount: 1, now: t0)
        #expect(taken == skipped)
        #expect(taken.outcome == .drop(.staleAnswer))
        #expect(taken.request != nil)
        #expect(a == b)
    }
}

@Suite("Clipboard S5: slow answers are counted, never given up on")
struct ClipboardSlowAnswerTests {
    typealias F = ClipboardInboundFixtures

    @Test("the threshold is 9 seconds")
    func constant() {
        #expect(ClipboardSession.slowAnswerThreshold == .seconds(9))
    }

    @Test("just under 9 s and exactly 9 s count nothing; 1 ns past 9 s counts once; the request stays in flight")
    func boundary() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        // Mutating calls are made outside #expect: the macro passes its subject to a closure as
        // an immutable parameter.
        let justUnder = session.tick(now: t0 + .seconds(9) - .nanoseconds(1))
        #expect(!justUnder)
        let exactly = session.tick(now: t0 + .seconds(9))
        #expect(!exactly)
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 0)
        let justOver = session.tick(now: t0 + .seconds(9) + .nanoseconds(1))
        #expect(justOver)
        let again = session.tick(now: t0 + .seconds(60))
        #expect(!again, "one request is counted once")
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 1)
        #expect(session.isRequestInFlight)
        #expect(session.expectsRemoteData)
    }

    @Test("an answer at exactly 9 s is accepted and not slow")
    func answerAtExactlyNine() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(session.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0 + .seconds(9)).outcome == F.write(F.fixture))
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 0)
    }

    @Test("an answer later than 9 s, same generation, is still accepted -- and counted slow once, ticked or not")
    func lateAnswerAccepted() {
        let t0 = ContinuousClock.now
        var unticked = F.session()
        _ = unticked.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(unticked.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0 + .seconds(9) + .nanoseconds(1)).outcome
                == F.write(F.fixture))
        #expect(unticked.counters.count(ClipboardInboundNotice.slowAnswer) == 1)

        var ticked = F.session()
        _ = ticked.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        ticked.tick(now: t0 + .seconds(20))
        #expect(ticked.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0 + .seconds(40)).outcome == F.write(F.fixture))
        #expect(ticked.counters.count(ClipboardInboundNotice.slowAnswer) == 1)
    }

    @Test("a list arriving past 9 s counts the request slow without a tick, and still does not request")
    func listPastNine() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        #expect(session.remoteFormatsReceived(F.text, changeCount: 1, now: t0 + .seconds(10)) == .noRequest(.requestInFlight))
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 1)
    }

    @Test("each request is counted on its own")
    func perRequest() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        session.tick(now: t0 + .seconds(10))
        _ = session.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0 + .seconds(11))
        _ = session.remoteFormatsReceived(F.text, changeCount: 2, now: t0 + .seconds(12))
        session.tick(now: t0 + .seconds(15))
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 1, "the second request is only 3 s old")
        session.tick(now: t0 + .seconds(22))
        #expect(session.counters.count(ClipboardInboundNotice.slowAnswer) == 2)
    }

    @Test("nothing in flight, nothing to count; a caller clock that goes backwards counts nothing")
    func noRequestOrClockBackwards() {
        let t0 = ContinuousClock.now
        var idle = F.session()
        let idleCounted = idle.tick(now: t0 + .seconds(100))
        #expect(!idleCounted)
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0 + .seconds(100))
        let backwards = session.tick(now: t0)
        #expect(!backwards)
        #expect(session.isRequestInFlight)
    }
}

@Suite("Clipboard S8: disconnect resets the per-connection state")
struct ClipboardSessionResetTests {
    typealias F = ClipboardInboundFixtures

    @Test("reset forgets the request in flight: its late answer is unexpected; counters carry on")
    func forgetsRequest() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0) // one counted drop
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        session.reset()
        #expect(!session.isRequestInFlight)
        #expect(session.counters.count(ClipboardInboundDropReason.unexpectedAnswer) == 1)
        let late = session.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0)
        #expect(late.outcome == .drop(.unexpectedAnswer))
        #expect(session.remoteFormatsReceived(F.text, changeCount: 1, now: t0).request != nil)
    }

    @Test("reset forgets the pending text too: nothing is requested for the old connection's list")
    func forgetsPending() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0) // pending behind the request
        session.reset()
        let late = session.remoteDataReceived(F.ok(F.fixture), changeCount: 1, now: t0)
        #expect(late.outcome == .drop(.unexpectedAnswer))
        #expect(late.request == nil)
        #expect(!session.isRequestInFlight)
    }

    @Test("an answer requested in the old connection cannot be taken for a request of the new one")
    func oldAnswerAfterNewRequest() {
        let t0 = ContinuousClock.now
        var session = F.session()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        session.reset()
        _ = session.remoteFormatsReceived(F.text, changeCount: 1, now: t0)
        // The wire is FIFO per connection; a new connection's first answer is the new text.
        #expect(session.remoteDataReceived(F.ok(F.second), changeCount: 1, now: t0).outcome == F.write(F.second))
    }

    @Test("reset clears ready and the Mac's ownership, and keeps the anti-loop memory")
    func clearsReadyAndOwnership() {
        var session = F.session()
        _ = session.clipboardReady(snapshot: F.textSnapshot(1))
        session.recordOwnWrite(changeCount: 9)
        #expect(session.isReady)
        #expect(session.macOwnsClipboard)
        session.reset()
        #expect(!session.isReady)
        #expect(!session.macOwnsClipboard)
        #expect(session.ownership.lastOwnWriteChangeCount == 9)
    }
}

@Suite("Clipboard S4/S5: random interleavings against a simulated wire")
struct ClipboardInboundSimulationTests {
    typealias F = ClipboardInboundFixtures

    /// The most answers the final drain may take; see the loop.
    static let drainBound = 4

    /// A fixed-seed generator: the same seed walks the same interleaving every run.
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Windows copies text (sometimes marked excluded) or non-text, the Mac copies text with
    /// Macdows active (announced) or in the background (not announced: only the change count
    /// moves), the server answers the oldest request (success with the text it had when the
    /// request reached it, or a failure), the server's clipboard process restarts (a ready:
    /// whatever was on the wire is never answered), and time jumps. Checked after every step:
    /// at most one request on the wire, and the session's view of it agrees with the wire's;
    /// checked on every request: Windows owns the clipboard and offers text right now; checked
    /// on every write: the text is exactly what Windows offers right now, the Mac has not
    /// copied anything since that list arrived, and the write is sensitive exactly when that
    /// list was marked. At the end the server answers everything (a bounded number of
    /// answers): the newest Windows text has landed unless its own answer was a failure or
    /// the Mac copied something after it. On time jumps with no Mac change since the count
    /// the session judged last, the App's activation check is made too: it must be skipped as
    /// unchanged (S2 (b), v3 patch). Every failure message names the seed and the step (or
    /// the drain answer) it happened at.
    @Test("never two requests on the wire; only the current text is written, never over a newer Mac copy; the newest copy lands",
          arguments: [UInt64(1), 2, 3, 5, 8, 13, 21, 34])
    func simulate(_ seed: UInt64) {
        var generator = Generator(state: seed)
        var now = ContinuousClock.now
        var session = F.session()
        var changeCount = 100
        _ = session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: changeCount, types: []))
        var wire: [String] = []             // what the server will answer each request with
        var windowsText: String?            // the text Windows offers now (nil: not text)
        var windowsExcluded = false         // Windows' current list was marked excluded
        var windowsOwns = false             // Windows' last list is newer than the Mac's last announcement
        var currentFailed = false           // the answer for Windows' current text was a failure
        var macMovedSinceList = false       // an unannounced Mac copy came after Windows' current list
        var macText: String?
        var copies = 0
        var writes = 0
        var sensitiveWrites = 0
        var readies = 0
        var activations = 0
        var lastJudged = changeCount        // the change count the session judged last (the ready's)

        // Returns false (and records) if a request goes out for text Windows no longer offers.
        // `at` names the step or the drain answer, for the failure message.
        @discardableResult
        func send(_ request: ClipboardDataRequest?, _ at: String) -> Bool {
            guard request != nil else { return true }
            guard windowsOwns, let text = windowsText else {
                Issue.record("seed \(seed) \(at): a request went out although Windows offers no text now")
                wire.append("")
                return false
            }
            wire.append(text)
            return true
        }
        func answer(failing: Bool, _ at: String) -> Bool {
            let captured = wire.removeFirst()
            let result = session.remoteDataReceived(failing ? .failure : F.ok(captured), changeCount: changeCount, now: now)
            switch result.outcome {
            case .write(let text, let sensitive):
                guard windowsOwns, text.value == windowsText, !macMovedSinceList else {
                    Issue.record("seed \(seed) \(at): wrote text that is not Windows' current offer, or over a newer Mac copy")
                    return false
                }
                guard sensitive == windowsExcluded else {
                    Issue.record("seed \(seed) \(at): the write's sensitive mark is not its list's")
                    return false
                }
                macText = text.value
                writes += 1
                if sensitive { sensitiveWrites += 1 }
                changeCount += 1
                session.recordOwnWrite(changeCount: changeCount)
                // The App then observes its own write; that must not be announced.
                let echo = session.pasteboardChanged(snapshot: PasteboardSnapshot(
                    changeCount: changeCount, types: [F.textType, PasteboardOwnership.defaultMarkerType]))
                lastJudged = changeCount
                guard echo == .skip(.ownWrite) else {
                    Issue.record("seed \(seed) \(at): the App's own write was announced")
                    return false
                }
            case .drop(.remoteFailure):
                currentFailed = true
            case .drop(.localNewer):
                guard macMovedSinceList else {
                    Issue.record("seed \(seed) \(at): dropped as local-newer although the Mac did not move")
                    return false
                }
            case .drop:
                break
            }
            return send(result.request, at)
        }

        for step in 0..<3000 {
            switch generator.next(10) {
            case 0, 1:
                copies += 1
                windowsText = "w\(seed)-\(copies)"
                windowsExcluded = generator.next(4) == 0
                windowsOwns = true
                currentFailed = false
                macMovedSinceList = false
                let formats = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: windowsExcluded)
                guard send(session.remoteFormatsReceived(formats, changeCount: changeCount, now: now).request, "step \(step)") else { return }
            case 2:
                windowsText = nil
                windowsExcluded = false
                windowsOwns = true
                currentFailed = false
                macMovedSinceList = false
                let formats = ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: generator.next(2) == 0)
                guard send(session.remoteFormatsReceived(formats, changeCount: changeCount, now: now).request, "step \(step)") else { return }
            case 3:
                changeCount += 1
                macText = "m\(seed)-\(changeCount)"
                windowsOwns = false
                lastJudged = changeCount
                guard session.pasteboardChanged(snapshot: F.textSnapshot(changeCount)) == .announce(.unicodeText) else {
                    Issue.record("seed \(seed) step \(step): a Mac copy was not announced")
                    return
                }
            case 4:
                // Macdows in the background, or a sensitive copy: nothing is announced.
                changeCount += 1
                macText = "u\(seed)-\(changeCount)"
                macMovedSinceList = true
            case 5, 6:
                guard !wire.isEmpty else { continue }
                guard answer(failing: generator.next(8) == 0, "step \(step)") else { return }
            case 7:
                guard generator.next(4) == 0 else { continue }
                // The server's clipboard process restarts: it forgets the wire and says ready.
                readies += 1
                wire.removeAll()
                windowsOwns = false
                lastJudged = changeCount
                guard session.clipboardReady(snapshot: F.textSnapshot(changeCount)) == .announce(.unicodeText) else {
                    Issue.record("seed \(seed) step \(step): the initial list after a ready did not name 13")
                    return
                }
            default:
                now += .seconds(generator.next(12))
                session.tick(now: now)
                // The user switches away and back with nothing new on the Mac: the activation
                // check hands over the same count, which must change nothing at all. (With a
                // background copy pending the count differs; the walk then leaves it to case 3.)
                if changeCount == lastJudged {
                    activations += 1
                    let check = session.pasteboardChanged(snapshot: F.textSnapshot(changeCount))
                    guard check == .skip(.unchanged) else {
                        Issue.record("seed \(seed) step \(step): an activation with no Mac change gave \(check)")
                        return
                    }
                }
            }
            guard wire.count <= 1, session.isRequestInFlight == !wire.isEmpty else {
                Issue.record("seed \(seed) step \(step): \(wire.count) requests on the wire, session thinks \(session.isRequestInFlight)")
                return
            }
        }
        // Bounded on purpose: a correct session needs at most two answers here (the one in
        // flight, then one follow-up for the newest list). A session that re-requests after
        // every answer would keep the wire busy forever; an unbounded loop would then hang
        // the whole test bundle instead of failing this one test.
        var drained = 0
        while !wire.isEmpty {
            drained += 1
            guard drained <= Self.drainBound else {
                Issue.record("seed \(seed) drain \(drained): the wire did not drain within \(Self.drainBound) answers")
                return
            }
            guard answer(failing: false, "drain \(drained)") else { return }
            guard wire.count <= 1 else {
                Issue.record("seed \(seed) drain \(drained): two requests on the wire while draining")
                return
            }
        }
        if windowsOwns, let text = windowsText, !currentFailed, !macMovedSinceList {
            #expect(macText == text, "seed \(seed) after the drain: the newest Windows copy did not land")
        }
        #expect(writes > 0, "seed \(seed) after the drain: the walk must exercise writes")
        #expect(sensitiveWrites > 0, "seed \(seed) after the drain: and sensitive writes")
        #expect(readies > 0, "seed \(seed) after the drain: and readies")
        #expect(activations > 0, "seed \(seed) after the drain: and activations with nothing new")
        #expect(session.counters.count(ClipboardAnnounceSkipReason.unchanged) == activations,
                "seed \(seed) after the drain: every activation with nothing new, and nothing else, is unchanged")
        #expect(session.counters.count(ClipboardInboundDropReason.staleAnswer) > 0, "seed \(seed) after the drain: and stale answers")
        #expect(session.counters.count(ClipboardInboundDropReason.localNewer) > 0, "seed \(seed) after the drain: and local-newer drops")
    }
}

@Suite("Clipboard: counters")
struct ClipboardCountersTests {
    @Test("every reason starts at 0 and counts on its own")
    func independentCounts() {
        var counters = ClipboardCounters()
        #expect(counters.nonZeroEntries.isEmpty)
        counters.record(ClipboardInboundDropReason.tooLarge)
        counters.record(ClipboardInboundDropReason.tooLarge)
        counters.record(ClipboardInboundDropReason.localNewer)
        counters.record(ClipboardNoRequestReason.noUnicodeText)
        counters.record(ClipboardRespondFailureReason.noText)
        counters.record(ClipboardRespondFailureReason.macNotOwner)
        counters.record(ClipboardAnnounceSkipReason.sensitiveType)
        counters.record(ClipboardNoAnswerReason.directionNotAllowed)
        counters.record(ClipboardInboundNotice.slowAnswer)
        #expect(counters.count(ClipboardInboundDropReason.tooLarge) == 2)
        #expect(counters.count(ClipboardInboundDropReason.malformed) == 0)
        #expect(counters.nonZeroEntries.map(\.token) == [
            "announce.sensitive", "inbound.local-newer", "inbound.slow", "inbound.too-large", "list.no-text",
            "respond.direction", "respond.no-text", "respond.not-owner",
        ])
        #expect(counters.nonZeroEntries.map(\.count) == [1, 1, 1, 2, 1, 1, 1, 1])
    }

    @Test("tokens are unique across all six reason enums")
    func uniqueTokens() {
        let tokens = ClipboardAnnounceSkipReason.allCases.map(\.rawValue)
            + ClipboardNoAnswerReason.allCases.map(\.rawValue)
            + ClipboardRespondFailureReason.allCases.map(\.rawValue)
            + ClipboardNoRequestReason.allCases.map(\.rawValue)
            + ClipboardInboundDropReason.allCases.map(\.rawValue)
            + ClipboardInboundNotice.allCases.map(\.rawValue)
        #expect(Set(tokens).count == tokens.count)
    }

    @Test("version 3's reasons exist, version 1's give-up reason does not")
    func reasonSet() {
        let tokens = Set(ClipboardAnnounceSkipReason.allCases.map(\.rawValue)
            + ClipboardRespondFailureReason.allCases.map(\.rawValue)
            + ClipboardInboundDropReason.allCases.map(\.rawValue)
            + ClipboardInboundNotice.allCases.map(\.rawValue))
        for token in ["announce.before-ready", "announce.unchanged", "respond.inactive", "respond.not-owner", "inbound.stale",
                      "inbound.unexpected", "inbound.local-newer", "inbound.unavailable", "inbound.slow"] {
            #expect(tokens.contains(token), "\(token)")
        }
        #expect(!tokens.contains("inbound.watchdog"))
        #expect(!tokens.contains("inbound.no-pending"))
    }

    @Test("S3's failure reasons are in rule order, the owner check third")
    func respondReasonOrder() {
        #expect(ClipboardRespondFailureReason.allCases == [
            .appInactive, .unsupportedFormat, .macNotOwner, .sensitiveType, .noText, .tooLarge,
        ])
    }

    @Test("a scripted session leaves exactly the expected counts")
    func scriptedSession() {
        let t0 = ContinuousClock.now
        var session = ClipboardSession(policy: ClipboardPolicy(mode: .bidirectional), ownerCheck: .requireMacOwner)
        let text = ClipboardRemoteFormats(offersUnicodeText: true, isRemoteExcluded: false)
        _ = session.pasteboardChanged(snapshot: PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"])) // announce.before-ready
        _ = session.clipboardReady(snapshot: PasteboardSnapshot(changeCount: 1, types: []))     // empty list: counts nothing
        _ = session.pasteboardChanged(snapshot: PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"])) // announce.unchanged
        _ = session.remoteFormatsReceived(ClipboardRemoteFormats(offersUnicodeText: false, isRemoteExcluded: true),
                                          changeCount: 1, now: t0)                              // list.no-text
        _ = session.remoteFormatsReceived(text, changeCount: 1, now: t0)                        // request
        _ = session.remoteFormatsReceived(text, changeCount: 1, now: t0)                        // list.in-flight
        _ = session.remoteDataReceived(.success(ClipboardBytes([0, 0])), changeCount: 1, now: t0) // inbound.stale (+ follow-up)
        _ = session.remoteDataReceived(.success(ClipboardBytes([0, 0])), changeCount: 1, now: t0) // inbound.empty
        _ = session.remoteDataReceived(.success(ClipboardBytes([0, 0])), changeCount: 1, now: t0) // inbound.unexpected
        _ = session.remoteFormatsReceived(text, changeCount: 1, now: t0)                        // request
        _ = session.remoteDataReceived(.successWithoutBytes(byteCount: 4), changeCount: 2, now: t0) // inbound.local-newer
        _ = session.remoteFormatsReceived(text, changeCount: 2, now: t0)                        // request
        _ = session.remoteDataReceived(.successWithoutBytes(byteCount: 4), changeCount: 2, now: t0) // inbound.unavailable
        _ = session.remoteFormatsReceived(text, changeCount: 2, now: t0)                        // request
        session.tick(now: t0 + .seconds(10))                                                    // inbound.slow
        _ = session.dataRequested(formatId: 13, isAppActive: false,
                                  readTypes: { [] }, readText: { "fixture" })                   // respond.inactive
        _ = session.dataRequested(formatId: 13, isAppActive: true,
                                  readTypes: { [] }, readText: { "fixture" })                   // respond.not-owner
        #expect(session.counters.nonZeroEntries.map(\.token) == [
            "announce.before-ready", "announce.unchanged", "inbound.empty", "inbound.local-newer", "inbound.slow",
            "inbound.stale", "inbound.unavailable", "inbound.unexpected", "list.in-flight", "list.no-text",
            "respond.inactive", "respond.not-owner",
        ])
        #expect(session.counters.nonZeroEntries.allSatisfy { $0.count == 1 })
    }
}
