/// What one Format List names: the two shapes `CRDPQ_CMD_CLIP_ANNOUNCE` can ask for.
public enum ClipboardFormatList: Equatable, Sendable {
    /// Exactly one format, 13 (CF_UNICODETEXT).
    case unicodeText
    /// No format at all. Only ever sent as a connection's initial list (S2 (a)): a later empty
    /// list would wipe Windows' own clipboard, and the channel drops one anyway.
    case empty

    /// The value for the announce command's `formatId` field: 13, or 0 for the empty list
    /// (`CRDPQ_CLIP_NO_FORMAT` in crdpq.h; this package does not import the C module, so the
    /// two are tied together by a test instead).
    public var announcedFormatId: UInt32 {
        switch self {
        case .unicodeText: ClipboardFormat.unicodeText
        case .empty: 0
        }
    }
}

// The two named policy values that wait on a live-host observation live here, side by side,
// each with its `default`; `ClipboardSession` takes both at creation. Changing either default
// is the owner's call once the live host has answered the open question it names.

/// S2 (a): what the initial list is when the pasteboard has nothing to offer. The one place
/// that choice lives, so a live-host observation can change it without touching the rules.
public enum ClipboardInitialListPolicy: Equatable, Sendable {
    /// Send an empty list (the default): the three reference clients send an initial list
    /// after Monitor Ready, and the channel admits a first empty one.
    case always
    /// Send nothing.
    case onlyIfText

    public static let `default`: ClipboardInitialListPolicy = .always
}

/// S3 rule 3: whether a Windows data request is refused while the Mac is not the clipboard's
/// owner (`ClipboardSession.macOwnsClipboard`: this connection's latest announcement named 13
/// and no Windows list or ready has come since). Neither the channel nor S3's other rules
/// check that the Mac ever offered anything, so a compromised host could read the Mac
/// pasteboard whenever Macdows is active; requiring ownership narrows that.
///
/// OFF BY DEFAULT, deliberately: if the server echoes a client's announcement back as a Format
/// List of its own (unverified), every echo ends the Mac's ownership and requiring it would
/// make every Mac -> Windows paste fail. The session tracks ownership either way; only the
/// refusal is gated.
public enum ClipboardOwnerCheckPolicy: Equatable, Sendable {
    /// Do not refuse on ownership (the default).
    case off
    /// Refuse a request with a failure answer while the Mac is not the owner.
    case requireMacOwner

    public static let `default`: ClipboardOwnerCheckPolicy = .off
}

/// S2's verdict on one trigger (ready, or one observed pasteboard change).
public enum ClipboardAnnounceDecision: Equatable, Sendable {
    /// Send a Format List of this shape. The caller posts exactly one `CRDPQ_CMD_CLIP_ANNOUNCE`
    /// with `list.announcedFormatId`.
    case announce(ClipboardFormatList)
    /// Send nothing. T1 never "un-announces": a change skipped for rules 3 and 4 does NOT send
    /// an empty format list, which would wipe Windows' own clipboard for content that could
    /// not have crossed anyway (S2 (b), last paragraph).
    case skip(ClipboardAnnounceSkipReason)
}

/// S3's verdict on one Windows data request: one of three, and the third is not a variant of
/// the second.
public enum ClipboardRespondDecision: Equatable, Sendable {
    /// Answer with these bytes (`CF_UNICODETEXT`, NUL included, within the limit): put them in
    /// the store, then post `CRDPQ_CMD_CLIP_RESPOND` with status OK.
    case respond(ClipboardBytes)
    /// Answer with a failure and no data: post `CRDPQ_CMD_CLIP_RESPOND` with status FAILED.
    case fail(ClipboardRespondFailureReason)
    /// Do NOT answer -- post no `CRDPQ_CMD_CLIP_RESPOND` and never call the channel's response
    /// function. Only for Mac -> Windows not allowed (S3 rule 0). In that mode the channel
    /// itself has already answered the server with a failure (it normally never even hands
    /// the request up); a second answer would hit the upstream channel's assertion, which
    /// aborts the process.
    case noAnswer(ClipboardNoAnswerReason)
}

extension ClipboardRespondDecision: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .respond(let bytes): "ClipboardRespondDecision.respond(count: \(bytes.count))"
        case .fail(let reason): "ClipboardRespondDecision.fail(\(reason.rawValue))"
        case .noAnswer(let reason): "ClipboardRespondDecision.noAnswer(\(reason.rawValue))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        switch self {
        case .respond(let bytes): Mirror(self, children: ["respond.count": bytes.count], displayStyle: .enum)
        case .fail(let reason): Mirror(self, children: ["fail": reason.rawValue], displayStyle: .enum)
        case .noAnswer(let reason): Mirror(self, children: ["noAnswer": reason.rawValue], displayStyle: .enum)
        }
    }
}

/// Mac -> Windows (S2, S3): pure functions of their parameters, so each rule can be read, and
/// tested, in one place. INTERNAL, all three: each takes state only the session holds (whether
/// the connection is ready, the change count judged last, the Mac's clipboard ownership), and
/// a caller that used one directly would skip the session's bookkeeping -- an announcement
/// that does not advance the clipboard generation or record ownership, an answer judged
/// without the owner check. `ClipboardSession` is the one way in; the tests reach these
/// through `@testable import`.
enum ClipboardOutbound {
    /// S2 (a), the ready trigger: the session's clipboard has just become ready (Monitor Ready;
    /// again after every reconnect). An initial list is (almost) always sent:
    /// - Mac -> Windows allowed, no sensitive marker, a text type -> the list names 13. The
    ///   anti-loop rule is deliberately NOT applied: a list goes out either way, and offering
    ///   the text -- even text that came from Windows -- beats an empty list, which would clear
    ///   Windows' clipboard;
    /// - anything else -> an empty list, or, under `.onlyIfText`, nothing.
    static func readyDecision(for snapshot: PasteboardSnapshot, policy: ClipboardPolicy,
                              initialList: ClipboardInitialListPolicy) -> ClipboardAnnounceDecision {
        if policy.allowsLocalToRemote, !snapshot.hasSensitiveType, snapshot.hasPlainTextType {
            return .announce(.unicodeText)
        }
        switch initialList {
        case .always: return .announce(.empty)
        case .onlyIfText: return .skip(.initialListWithheld)
        }
    }

    /// S2 (b), the change trigger: called for every change count the App observes while it is
    /// active (activation included). The rules, first match wins:
    /// 0. this connection's ready trigger has not been handled yet -> skip;
    /// then (v3 patch) the change count is the one judged last -> skip as unchanged: the
    ///    observation is not a change at all (an activation after merely switching away);
    /// 1. Mac -> Windows not allowed -> skip;
    /// 2. the change count is the App's own last write, or the marker type is present -> skip
    ///    (remote text coming back around);
    /// 3. a sensitive marker type is present -> skip;
    /// 4. no text type -> skip;
    /// 5. otherwise announce format 13 only.
    /// `lastJudgedChangeCount` is nil only before the first ready, when rule 0 decides anyway.
    static func changeDecision(for snapshot: PasteboardSnapshot, policy: ClipboardPolicy,
                               ownership: PasteboardOwnership, isReady: Bool,
                               lastJudgedChangeCount: Int?) -> ClipboardAnnounceDecision {
        guard isReady else { return .skip(.beforeReady) }
        guard snapshot.changeCount != lastJudgedChangeCount else { return .skip(.unchanged) }
        guard policy.allowsLocalToRemote else { return .skip(.directionNotAllowed) }
        if ownership.isOwnWrite(snapshot) { return .skip(.ownWrite) }
        if ownership.carriesMarker(snapshot) { return .skip(.remoteMarker) }
        if snapshot.hasSensitiveType { return .skip(.sensitiveType) }
        guard snapshot.hasPlainTextType else { return .skip(.noTextType) }
        return .announce(.unicodeText)
    }

    /// S3. Called when a Windows data request is handled, with the pasteboard as it is AT THAT
    /// MOMENT -- what was announced earlier does not matter. The rules, first match wins:
    /// 0. Mac -> Windows not allowed -> no answer at all (see `.noAnswer`);
    /// 1. Macdows is not the active App -> fail;
    /// 2. a format other than 13 -> fail;
    /// 3. under `.requireMacOwner` only: the Mac is not the clipboard's owner -> fail;
    /// 4. a sensitive marker type is present -> fail;
    /// 5. no text -> fail. "No text" includes text that encodes to nothing but the terminating
    ///    NUL -- the empty string, or text starting with U+0000 -- an interpretation S3 leaves
    ///    open and this takes from S4's "an empty text is not written";
    /// 6. the encoded bytes are over the Mac -> Windows limit -> fail (never truncated);
    /// otherwise respond with the S7 encoding. The App's marker type is NOT a reason to fail:
    /// that text came from Windows, and handing it back is harmless.
    ///
    /// Staged reads: rules 0-3 need nothing from the pasteboard, rule 4 needs only its type
    /// list, and only rule 5 needs its content. So the pasteboard is read through the two
    /// closures, each called at most once and only when the rules get that far: a request
    /// refused early never causes a read of the Mac's clipboard content (S3, last sentence).
    ///
    /// Rule 6 is judged twice, the cheap way first: the Mac pasteboard has no size limit (a
    /// log of a few hundred MB is an ordinary copy), and encoding all of it on the main thread
    /// only to refuse it would allocate two to four times its size. So before encoding, the
    /// encoding's FLOOR -- two bytes per UTF-16 unit before the first U+0000, plus the NUL;
    /// the LF -> CR LF rule only adds to it -- is checked against the limit without
    /// allocating (`ClipboardTextCodec.encodedByteCountFloor`, which also stops counting once
    /// past the limit); a text over it is refused without `encode` ever being called. The
    /// exact check on the encoded bytes still follows, for the text the expansion takes over.
    /// `encode` is a parameter only so a test can see whether it was reached.
    static func respondDecision(requestedFormatId: UInt32, isAppActive: Bool, policy: ClipboardPolicy,
                                ownerCheck: ClipboardOwnerCheckPolicy, macOwnsClipboard: Bool,
                                readTypes: () -> [String], readText: () -> String?,
                                encode: (String) -> ClipboardBytes = ClipboardTextCodec.encodeUnicodeText)
        -> ClipboardRespondDecision {
        guard policy.allowsLocalToRemote else { return .noAnswer(.directionNotAllowed) }
        guard isAppActive else { return .fail(.appInactive) }
        guard requestedFormatId == ClipboardFormat.unicodeText else { return .fail(.unsupportedFormat) }
        if ownerCheck == .requireMacOwner, !macOwnsClipboard { return .fail(.macNotOwner) }
        if PasteboardTypes.containsSensitive(readTypes()) { return .fail(.sensitiveType) }
        guard let text = readText() else { return .fail(.noText) }
        let limit = policy.limits.localToRemoteMaxBytes
        let floor = ClipboardTextCodec.encodedByteCountFloor(text, stoppingAbove: limit)
        // A floor of two bytes is the terminating NUL alone: nothing before it (rule 5, which
        // comes before rule 6). The floor is exact whenever it is at most the limit, and more
        // than two whenever any unit precedes the NUL, so this reads the same either way.
        guard floor > 2 else { return .fail(.noText) }
        guard policy.limits.admitsLocalToRemote(byteCount: floor) else { return .fail(.tooLarge) }
        let encoded = encode(text)
        guard policy.limits.admitsLocalToRemote(byteCount: encoded.count) else { return .fail(.tooLarge) }
        return .respond(encoded)
    }
}
