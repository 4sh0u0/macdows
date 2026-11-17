/// The App's clipboard state machine for one session object (S0: every T1 decision is made on
/// the main thread, T_main). One value, owned by whoever owns the session, every method called
/// on the main thread in the order the triggers happen -- the order the control lane delivers
/// the four `CRDPQ_EVENT_CLIP_*` kinds, interleaved with the App's own pasteboard observations.
/// A value type with no clock, no lock and no global state: time and the pasteboard's change
/// count are passed in, the pasteboard's types and text are read through closures the caller
/// supplies, and the caller does all I/O (pasteboard, store, lanes) as the results say.
///
/// Why one type for both directions: every announcement (S2) must advance the clipboard
/// generation that decides whether a Windows answer is still current (S5), and must update
/// the Mac's clipboard ownership that S3 rule 3 reads. Keeping both directions in one value
/// means the caller cannot announce without doing both, and cannot answer a data request
/// without the ownership -- there is no separate call to forget and no parameter to get wrong.
///
/// One round each way:
/// - Windows -> Mac: `CLIP_REMOTE_FORMATS` -> `remoteFormatsReceived` (with the pasteboard's
///   change count now) -> a `.send` result -> post `CRDPQ_CMD_CLIP_REQUEST`; later
///   `CLIP_REMOTE_DATA` -> take (or discard, see `expectsRemoteData`) the store entry ->
///   `remoteDataReceived` (with the change count now) -> `.write` -> write the text plus the
///   marker type (plus the concealed type when `sensitive`), then `recordOwnWrite(changeCount:)`;
///   post its `request`, if any.
/// - Mac -> Windows: `CLIP_READY` -> `clipboardReady`, and every change count observed while
///   active, the one read in the activation notification included (the session, not the
///   caller, decides whether it is a change) -> `pasteboardChanged` -> an `.announce` result
///   -> post `CRDPQ_CMD_CLIP_ANNOUNCE`;
///   `CLIP_DATA_REQUEST` -> `dataRequested`, which reads the pasteboard through the caller's
///   closures only as far as its rules need -> respond / fail / no answer.
/// - Disconnect: `reset()`.
///
/// Outbound state (S2): whether this connection is ready, and the change count judged last.
/// Inbound state (S4): the clipboard generation (only ever increases); whether the Mac owns
/// the clipboard; the request in flight (none, or the generation and instant it was sent in,
/// the Mac change count taken as its baseline, and whether Windows marked it excluded); and
/// the pending offer (none, or the generation in which Windows offered text that has not been
/// requested yet, with its baseline and exclusion mark). Only an answer to a request sent in
/// the CURRENT generation, arriving while the Mac change count is still that request's
/// baseline, is ever written, and at most one request is on the wire at any time: the wire's
/// answers carry no identifier, so order is the only pairing there is.
public struct ClipboardSession: Equatable, Sendable {
    /// S5: a request unanswered for MORE than this is counted once as a slow answer -- and
    /// nothing else happens to it. FreeRDP's own `TcpAckTimeout` default, which its SDL client
    /// uses for the same wait. Not a timeout: giving up on the request and sending another
    /// would pair the late answer to the old request with the new one, writing older text.
    public static let slowAnswerThreshold: Duration = .seconds(9)

    /// What S4 remembers about one Windows offer, from the list's arrival until its answer
    /// is judged: the baseline is the Mac change count AT THE LIST'S ARRIVAL -- not when the
    /// request is finally sent, by which time the user may have copied something new.
    private struct Offer: Equatable, Sendable {
        let generation: UInt64
        let baselineChangeCount: Int
        let isRemoteExcluded: Bool
    }

    private struct InFlightRequest: Equatable, Sendable {
        let offer: Offer
        let issuedAt: ContinuousClock.Instant
        var countedSlow: Bool
    }

    public let policy: ClipboardPolicy
    public let initialList: ClipboardInitialListPolicy
    public let ownerCheck: ClipboardOwnerCheckPolicy
    /// The anti-loop memory (S2 rule 2). Survives `reset()` (S8). Not to be confused with
    /// `macOwnsClipboard`: this one remembers which pasteboard contents came from Windows.
    public private(set) var ownership: PasteboardOwnership
    /// Cumulative; survives `reset()`.
    public private(set) var counters = ClipboardCounters()
    /// Whether this connection's ready trigger has been handled (S2 rule 0; reset by S8).
    /// Under `.always` that is exactly "the initial list has been sent". Under `.onlyIfText` it
    /// is also true after a ready that sent nothing: the condition rule 0 guards -- Client
    /// Capabilities before any Format List -- holds once ready has happened either way.
    public private(set) var isReady = false
    /// S3 rule 3 / S4: the Mac is the clipboard's owner -- this connection's latest
    /// announcement named 13, and since then no Windows list has arrived and no ready has
    /// happened. Tracked whatever `ownerCheck` says; only the refusal is gated by it.
    public private(set) var macOwnsClipboard = false

    private var generation: UInt64 = 0
    private var inFlight: InFlightRequest?
    private var pending: Offer?
    /// S2 (b), v3 patch: the change count the session judged last -- recorded at every ready
    /// trigger and at every observation that got past rule 0. An observation carrying the
    /// same count is not a change and is not judged again. Kept by the session rather than
    /// the caller so that "did it change?" has one answer: the App hands over every count it
    /// sees and cannot get the comparison wrong (comparing against a count its own background
    /// polling updated, say, which would lose a background copy at activation). Like the
    /// anti-loop memory it survives `reset()` (S8); nothing can observe the difference, since
    /// rule 0 skips every observation until the next ready records a fresh count anyway.
    private var lastJudgedChangeCount: Int?

    public init(policy: ClipboardPolicy, initialList: ClipboardInitialListPolicy = .default,
                ownerCheck: ClipboardOwnerCheckPolicy = .default,
                ownership: PasteboardOwnership = PasteboardOwnership()) {
        self.policy = policy
        self.initialList = initialList
        self.ownerCheck = ownerCheck
        self.ownership = ownership
    }

    /// Whether a request is on the wire right now (diagnostics).
    public var isRequestInFlight: Bool { inFlight != nil }

    /// Whether a `CLIP_REMOTE_DATA` drained right now could still be written: a request is in
    /// flight and it was sent in the current generation. When false, the response is dropped
    /// whatever it holds, so the caller may DISCARD its store entry instead of taking it -- the
    /// bytes then never reach Swift memory, which cannot be wiped (S9) -- and pass
    /// `.successWithoutBytes(byteCount:)`: the result is the same. Either way the entry leaves
    /// the store (crdpq.h, "lifecycle of an entry"). When true the answer may still be dropped
    /// later (the change count, the payload rules). Nothing may happen between reading this
    /// and calling `remoteDataReceived`.
    public var expectsRemoteData: Bool {
        guard let request = inFlight else { return false }
        return request.offer.generation == generation
    }

    // MARK: Mac -> Windows

    /// S4 rule 5, then S2 (a): `CLIP_READY` was drained -- the connection's first, or a later
    /// one in the same connection (the server's clipboard process restarted, or the session
    /// was redirected). Whatever was in flight or pending will never be answered: both are
    /// forgotten, a new generation begins and the Mac is no longer the owner. Then the
    /// connection is marked ready, the snapshot's change count is recorded as judged (S2 (b):
    /// what the initial list was decided on is not a change afterwards) and the initial list
    /// decided; an `.announce` result has already been applied (S4 rule 2) -- the caller posts
    /// one `CRDPQ_CMD_CLIP_ANNOUNCE`.
    public mutating func clipboardReady(snapshot: PasteboardSnapshot) -> ClipboardAnnounceDecision {
        inFlight = nil
        pending = nil
        generation &+= 1
        macOwnsClipboard = false
        isReady = true
        lastJudgedChangeCount = snapshot.changeCount
        return settle(ClipboardOutbound.readyDecision(for: snapshot, policy: policy, initialList: initialList))
    }

    /// S2 (b): the change trigger. The caller hands over EVERY change count it observes while
    /// Macdows is active, and in the activation notification the count read at that moment,
    /// whether or not it looks new -- the session decides whether it changed: a count equal
    /// to the one it judged last (at the ready trigger or at the previous call) is skipped as
    /// `.unchanged`, so switching away and back never re-announces old Mac text over what
    /// Windows copied meanwhile. Counts observed while Macdows is NOT active must not be
    /// handed over (there is no "active" parameter: a count handed over is announced if its
    /// content qualifies); a copy made in the background is caught by the activation call,
    /// whose count then differs. Order: rule 0 (before ready), then unchanged, then rules
    /// 1-5; every call that gets past rule 0 records its count. An `.announce` result has
    /// already been applied (S4 rule 2); the caller posts one `CRDPQ_CMD_CLIP_ANNOUNCE` for it.
    public mutating func pasteboardChanged(snapshot: PasteboardSnapshot) -> ClipboardAnnounceDecision {
        let decision = ClipboardOutbound.changeDecision(for: snapshot, policy: policy, ownership: ownership,
                                                        isReady: isReady, lastJudgedChangeCount: lastJudgedChangeCount)
        // Rule 0 judged nothing; the next ready records a fresh count anyway.
        if isReady { lastJudgedChangeCount = snapshot.changeCount }
        return settle(decision)
    }

    /// S3: `CLIP_DATA_REQUEST` was drained. `isAppActive` is whether Macdows is the active App
    /// right now. The pasteboard is read through the two closures, each called at most once,
    /// on this thread, before this returns, and only if the rules get that far: `readTypes`
    /// (the type identifiers, for rule 4) only after rules 0-3 pass, `readText` (the plain
    /// text, nil if none, for rule 5) only after rule 4 passes. A refused request therefore
    /// never reads the Mac's clipboard content.
    public mutating func dataRequested(formatId: UInt32, isAppActive: Bool,
                                       readTypes: () -> [String], readText: () -> String?) -> ClipboardRespondDecision {
        let decision = ClipboardOutbound.respondDecision(requestedFormatId: formatId, isAppActive: isAppActive,
                                                         policy: policy, ownerCheck: ownerCheck,
                                                         macOwnsClipboard: macOwnsClipboard,
                                                         readTypes: readTypes, readText: readText)
        counters.record(decision)
        return decision
    }

    /// S2 rule 2 support: the App wrote remote text and the pasteboard reported this change count.
    public mutating func recordOwnWrite(changeCount: Int) {
        ownership.recordOwnWrite(changeCount: changeCount)
    }

    // MARK: Windows -> Mac

    /// S4 rule 1: `CLIP_REMOTE_FORMATS` was drained (`formats` decoded from its `flags`).
    /// `changeCount` is the Mac pasteboard's change count read NOW, when the event is handled
    /// -- it becomes the baseline an answer to this list is checked against. A new generation
    /// begins and the Mac is no longer the owner; if the list offers text Windows -> Mac may
    /// take, it becomes the pending offer; then the follow-up check (S4 rule 4) decides
    /// whether a request goes out now.
    public mutating func remoteFormatsReceived(_ formats: ClipboardRemoteFormats, changeCount: Int,
                                               now: ContinuousClock.Instant) -> ClipboardRequestDecision {
        noteSlowAnswer(now: now)
        generation &+= 1
        macOwnsClipboard = false
        let reason: ClipboardNoRequestReason
        if !policy.allowsRemoteToLocal {
            pending = nil
            reason = .directionNotAllowed
        } else if !formats.offersUnicodeText {
            pending = nil
            reason = .noUnicodeText
        } else {
            pending = Offer(generation: generation, baselineChangeCount: changeCount,
                            isRemoteExcluded: formats.isRemoteExcluded)
            // If the follow-up check does not send, the one thing in its way is the request in flight.
            reason = .requestInFlight
        }
        if let request = sendIfPending(now: now) { return .send(request) }
        counters.record(reason)
        return .noRequest(reason)
    }

    /// S4 rule 3: `CLIP_REMOTE_DATA` was drained and its store entry already taken or
    /// discarded (`response` is what that gave). `changeCount` is the Mac pasteboard's change
    /// count read NOW. With no request in flight the response is unexpected; otherwise the
    /// request is cleared and the response is stale unless that request was sent in the
    /// current generation; a current response is judged by `ClipboardInboundPayload` against
    /// the request's baseline and exclusion mark. Then the follow-up check (S4 rule 4).
    public mutating func remoteDataReceived(_ response: ClipboardDataResponse, changeCount: Int,
                                            now: ContinuousClock.Instant) -> ClipboardRemoteDataResult {
        noteSlowAnswer(now: now)
        let outcome: ClipboardInboundOutcome
        if let request = inFlight {
            inFlight = nil
            if request.offer.generation != generation {
                outcome = .drop(.staleAnswer)
            } else {
                outcome = ClipboardInboundPayload.evaluate(response, changeCount: changeCount,
                                                           baselineChangeCount: request.offer.baselineChangeCount,
                                                           sensitive: request.offer.isRemoteExcluded,
                                                           limits: policy.limits)
            }
        } else {
            outcome = .drop(.unexpectedAnswer)
        }
        if case .drop(let reason) = outcome { counters.record(reason) }
        return ClipboardRemoteDataResult(outcome: outcome, request: sendIfPending(now: now))
    }

    /// S5: time passed. Counts the request in flight as slow, once, when strictly more than
    /// `slowAnswerThreshold` has passed since it was sent; changes nothing else. Returns
    /// whether it counted now. Every other Windows -> Mac entry runs the same check first, so
    /// the count does not depend on how often the caller ticks. A `now` before the request (a
    /// caller clock going backwards) never counts.
    @discardableResult
    public mutating func tick(now: ContinuousClock.Instant) -> Bool {
        noteSlowAnswer(now: now)
    }

    // MARK: Disconnect

    /// S8: disconnect or reconnect. The request in flight and the pending offer are forgotten,
    /// the connection is no longer ready and the Mac no longer owns the clipboard; the
    /// generation keeps counting up, and the anti-loop memory, the change count judged last
    /// and the counters stay. The Mac pasteboard is not touched (text already written there
    /// is real data).
    public mutating func reset() {
        inFlight = nil
        pending = nil
        isReady = false
        macOwnsClipboard = false
    }

    // MARK: Private

    /// Counts a skip; for an announcement, applies S4 rule 2: a new generation begins and
    /// nothing Windows offered earlier is pending any more; a list naming 13 makes the Mac the
    /// clipboard's owner, an empty list does not. A request in flight stays in flight -- its
    /// answer will be stale.
    private mutating func settle(_ decision: ClipboardAnnounceDecision) -> ClipboardAnnounceDecision {
        switch decision {
        case .announce(let list):
            generation &+= 1
            pending = nil
            macOwnsClipboard = list == .unicodeText
        case .skip(let reason):
            counters.record(reason)
        }
        return decision
    }

    /// S4 rule 4, the follow-up check: nothing in flight and Windows' text of the current
    /// generation not yet requested -> request it now, carrying the offer's baseline and mark.
    private mutating func sendIfPending(now: ContinuousClock.Instant) -> ClipboardDataRequest? {
        guard inFlight == nil, let offer = pending, offer.generation == generation else { return nil }
        inFlight = InFlightRequest(offer: offer, issuedAt: now, countedSlow: false)
        pending = nil
        return ClipboardDataRequest(formatId: ClipboardFormat.unicodeText)
    }

    @discardableResult
    private mutating func noteSlowAnswer(now: ContinuousClock.Instant) -> Bool {
        guard var request = inFlight, !request.countedSlow,
              request.issuedAt.duration(to: now) > Self.slowAnswerThreshold else { return false }
        request.countedSlow = true
        inFlight = request
        counters.record(.slowAnswer)
        return true
    }
}
