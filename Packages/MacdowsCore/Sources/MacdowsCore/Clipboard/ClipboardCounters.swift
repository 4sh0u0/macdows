/// S2: why a pasteboard observation, or the ready trigger, did not lead to an announcement.
/// Cases are in the order `ClipboardSession.pasteboardChanged` checks them (rule 0, then the
/// "did it change at all" check, then rules 1-5). Raw values are stable tokens for a future
/// diagnostic line (counts only, never content -- S9).
public enum ClipboardAnnounceSkipReason: String, CaseIterable, Sendable {
    /// Rule 0: a change was observed before this connection's ready trigger was handled -- the
    /// channel may already accept messages, but the protocol wants Client Capabilities (sent
    /// at Monitor Ready) before any Format List.
    case beforeReady = "announce.before-ready"
    /// S2 (b), v3 patch: the change count is the one the session judged last (at the ready
    /// trigger or at the previous observation) -- nothing changed on the Mac. The typical case
    /// is the check the App makes in its activation notification after the user merely
    /// switched away and back: re-announcing then would replace whatever Windows copied in the
    /// meantime with the Mac's OLD text.
    case unchanged = "announce.unchanged"
    /// Rule 1: Mac -> Windows is not allowed by the mode.
    case directionNotAllowed = "announce.direction"
    /// Rule 2, first half: the change count is the one the App's own last write produced.
    case ownWrite = "announce.own-write"
    /// Rule 2, second half: the pasteboard carries the App's marker type.
    case remoteMarker = "announce.marker"
    /// Rule 3: the pasteboard carries an nspasteboard.org sensitive marker.
    case sensitiveType = "announce.sensitive"
    /// Rule 4: the pasteboard has no text type.
    case noTextType = "announce.no-text"
    /// S2 (a) under `ClipboardInitialListPolicy.onlyIfText`: there was nothing to offer when
    /// the clipboard became ready, so no initial list was sent.
    case initialListWithheld = "announce.initial-withheld"
}

/// S3 rule 0: why a Windows data request gets no answer at all from the App. Not a failure
/// answer -- see `ClipboardRespondDecision.noAnswer`.
public enum ClipboardNoAnswerReason: String, CaseIterable, Sendable {
    /// Mac -> Windows is not allowed by the mode. The channel has normally answered the
    /// server with a failure on its own already.
    case directionNotAllowed = "respond.direction"
}

/// S3 rules 1-6: why a Windows data request was answered with a failure. Cases in S3's rule
/// order.
public enum ClipboardRespondFailureReason: String, CaseIterable, Sendable {
    /// Rule 1: Macdows is not the active App. A paste into a remote window always happens
    /// with Macdows active, so this refuses only reads the user did not start on this Mac.
    case appInactive = "respond.inactive"
    /// Rule 2: the requested format is not 13 (CF_UNICODETEXT).
    case unsupportedFormat = "respond.format"
    /// Rule 3, only under `ClipboardOwnerCheckPolicy.requireMacOwner`: the Mac is not the
    /// clipboard's owner (`ClipboardSession.macOwnsClipboard`).
    case macNotOwner = "respond.not-owner"
    /// Rule 4: the pasteboard carries an nspasteboard.org sensitive marker.
    case sensitiveType = "respond.sensitive"
    /// Rule 5: there is no text to send.
    case noText = "respond.no-text"
    /// Rule 6: the encoded text is over the Mac -> Windows limit (S6).
    case tooLarge = "respond.too-large"
}

/// S4 rule 1: why a Windows format list did not lead to a data request right away.
public enum ClipboardNoRequestReason: String, CaseIterable, Sendable {
    /// Windows -> Mac is not allowed by the mode.
    case directionNotAllowed = "list.direction"
    /// The list does not contain format 13. Nothing on the Mac changes.
    case noUnicodeText = "list.no-text"
    /// The list has format 13, but a request is still on the wire (S5: at most one). Not a
    /// loss: the list's text is requested by the follow-up check once that request's answer
    /// is back -- provided nothing newer has replaced the list by then.
    case requestInFlight = "list.in-flight"
}

/// S4 rule 3: why a Windows data response was not written to the Mac pasteboard.
public enum ClipboardInboundDropReason: String, CaseIterable, Sendable {
    /// A response arrived while no request was in flight.
    case unexpectedAnswer = "inbound.unexpected"
    /// The request it answers was issued in an older clipboard generation than the current
    /// one: a newer Windows list, a local announcement, or a ready has superseded it (S5).
    case staleAnswer = "inbound.stale"
    /// Windows answered with a failure.
    case remoteFailure = "inbound.remote-failure"
    /// The Mac pasteboard's change count moved since the Windows list arrived: the Mac has
    /// newer content of its own, which the answer must not overwrite (S4 rule 3, v3).
    case localNewer = "inbound.local-newer"
    /// S6: more bytes than the Windows -> Mac limit, judged on the length on the wire.
    case tooLarge = "inbound.too-large"
    /// S7: the bytes do not decode (no NUL code unit and an odd byte count).
    case malformed = "inbound.malformed"
    /// The text decoded to the empty string; the Mac pasteboard is left as it is.
    case emptyText = "inbound.empty"
    /// A successful response within the limit whose bytes the consumer does not have: the
    /// producer could not store them, or they could not be taken (S4 rule 3's own class).
    case bytesUnavailable = "inbound.unavailable"
}

/// S5: things worth counting about the inbound flow that change nothing.
public enum ClipboardInboundNotice: String, CaseIterable, Sendable {
    /// A request stayed unanswered for more than `ClipboardSession.slowAnswerThreshold`.
    /// Counted once per request; the request stays in flight.
    case slowAnswer = "inbound.slow"
}

/// Per-reason counts for every refusal, skip, drop or notice in the T1 logic (item 7 of the
/// lane: readable counts, keyed by enum, for a later diagnostic line). Counts only -- S9 -- so
/// the default rendering of this type is already safe. Cumulative: nothing here resets them, a
/// reconnect included, matching the "counters survive reconnects" contract of every other
/// diagnostic counter in this project.
public struct ClipboardCounters: Equatable, Sendable {
    private var announceSkips: [ClipboardAnnounceSkipReason: Int] = [:]
    private var noAnswers: [ClipboardNoAnswerReason: Int] = [:]
    private var respondFailures: [ClipboardRespondFailureReason: Int] = [:]
    private var noRequests: [ClipboardNoRequestReason: Int] = [:]
    private var inboundDrops: [ClipboardInboundDropReason: Int] = [:]
    private var inboundNotices: [ClipboardInboundNotice: Int] = [:]

    public init() {}

    public func count(_ reason: ClipboardAnnounceSkipReason) -> Int { announceSkips[reason, default: 0] }
    public func count(_ reason: ClipboardNoAnswerReason) -> Int { noAnswers[reason, default: 0] }
    public func count(_ reason: ClipboardRespondFailureReason) -> Int { respondFailures[reason, default: 0] }
    public func count(_ reason: ClipboardNoRequestReason) -> Int { noRequests[reason, default: 0] }
    public func count(_ reason: ClipboardInboundDropReason) -> Int { inboundDrops[reason, default: 0] }
    public func count(_ notice: ClipboardInboundNotice) -> Int { inboundNotices[notice, default: 0] }

    public mutating func record(_ reason: ClipboardAnnounceSkipReason) { announceSkips[reason, default: 0] += 1 }
    public mutating func record(_ reason: ClipboardNoAnswerReason) { noAnswers[reason, default: 0] += 1 }
    public mutating func record(_ reason: ClipboardRespondFailureReason) { respondFailures[reason, default: 0] += 1 }
    public mutating func record(_ reason: ClipboardNoRequestReason) { noRequests[reason, default: 0] += 1 }
    public mutating func record(_ reason: ClipboardInboundDropReason) { inboundDrops[reason, default: 0] += 1 }
    public mutating func record(_ notice: ClipboardInboundNotice) { inboundNotices[notice, default: 0] += 1 }

    /// Counts the decision if it is a skip; an announcement is not a refusal and counts nothing.
    public mutating func record(_ decision: ClipboardAnnounceDecision) {
        if case .skip(let reason) = decision { record(reason) }
    }

    /// Counts the decision if it is a failure or no answer; a successful answer counts nothing.
    public mutating func record(_ decision: ClipboardRespondDecision) {
        switch decision {
        case .respond: break
        case .fail(let reason): record(reason)
        case .noAnswer(let reason): record(reason)
        }
    }

    /// Every non-zero count as (stable token, count), sorted by token -- the shape a diagnostic
    /// line wants. Built from the reason enums' raw values, never from content.
    public var nonZeroEntries: [(token: String, count: Int)] {
        var entries: [(token: String, count: Int)] = []
        func collect<Reason: RawRepresentable<String> & Hashable>(_ table: [Reason: Int]) {
            for (reason, count) in table where count > 0 {
                entries.append((reason.rawValue, count))
            }
        }
        collect(announceSkips)
        collect(noAnswers)
        collect(respondFailures)
        collect(noRequests)
        collect(inboundDrops)
        collect(inboundNotices)
        return entries.sorted { $0.token < $1.token }
    }
}
