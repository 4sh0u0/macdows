/// What one server Format List says, as far as T1 cares: the two facts T_clip extracts from it
/// (S0) and `CRDPQ_EVENT_CLIP_REMOTE_FORMATS` carries in `crdpq_clip_ref_t.flags`. The list
/// itself and its format names never get this far (S9).
public struct ClipboardRemoteFormats: Equatable, Sendable {
    /// `CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT` in crdpq.h. This package does not import the C
    /// module, so the two bit values are tied together by a test instead.
    public static let offersUnicodeTextFlag: UInt32 = 0x0000_0001
    /// `CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED` in crdpq.h (tied by the same test).
    public static let remoteExcludedFlag: UInt32 = 0x0000_0002

    /// The list names format 13 (CF_UNICODETEXT).
    public let offersUnicodeText: Bool
    /// The list names at least one of Windows' exclusion formats -- "keep this out of
    /// clipboard history / cloud sync" (the four names are listed at the C flag). Text taken
    /// from this list is written on the Mac as sensitive content.
    public let isRemoteExcluded: Bool

    /// Both facts are required on purpose: a defaulted `isRemoteExcluded` would let a caller
    /// that forgot it write a password as ordinary text.
    public init(offersUnicodeText: Bool, isRemoteExcluded: Bool) {
        self.offersUnicodeText = offersUnicodeText
        self.isRemoteExcluded = isRemoteExcluded
    }

    /// Decodes the event's `flags` word. Bits this layer does not know are ignored: crdpq.h
    /// reserves them for later facts, and an older consumer must not misread a newer producer.
    public init(flags: UInt32) {
        self.init(offersUnicodeText: flags & Self.offersUnicodeTextFlag != 0,
                  isRemoteExcluded: flags & Self.remoteExcludedFlag != 0)
    }

    /// The `flags` word that encodes these two facts (the inverse of `init(flags:)`).
    public var flags: UInt32 {
        (offersUnicodeText ? Self.offersUnicodeTextFlag : 0) | (isRemoteExcluded ? Self.remoteExcludedFlag : 0)
    }
}

/// One Windows Format Data Response, as the consumer has it. By the time the App builds one of
/// these it has already removed the response's store entry (taken or discarded, crdpq.h's
/// "lifecycle of an entry"), so this is either the bytes it took or the fact that it has none.
public enum ClipboardDataResponse: Equatable, Sendable {
    /// Windows answered OK and these are the bytes (taken from the store).
    case success(ClipboardBytes)
    /// Windows answered OK with `byteCount` bytes on the wire, but the bytes are not available
    /// to the consumer: the producer could not store them (the C store's
    /// `CRDPQ_CLIP_STATUS_NOT_STORED`, e.g. over its block limit or no free slot), the take
    /// failed, or the consumer discarded the entry because `expectsRemoteData` was false.
    /// `byteCount` still decides S6, so an over-limit response is counted as over-limit
    /// whichever side noticed first.
    case successWithoutBytes(byteCount: Int)
    /// Windows answered with a failure (CB_RESPONSE_FAIL).
    case failure
}

extension ClipboardDataResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .success(let bytes): "ClipboardDataResponse.success(count: \(bytes.count))"
        case .successWithoutBytes(let byteCount): "ClipboardDataResponse.successWithoutBytes(byteCount: \(byteCount))"
        case .failure: "ClipboardDataResponse.failure"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        switch self {
        case .success(let bytes): Mirror(self, children: ["success.count": bytes.count], displayStyle: .enum)
        case .successWithoutBytes(let byteCount): Mirror(self, children: ["successWithoutBytes.byteCount": byteCount], displayStyle: .enum)
        case .failure: Mirror(self, children: ["failure": true], displayStyle: .enum)
        }
    }
}

/// One Format Data Request the caller MUST send: post exactly one `CRDPQ_CMD_CLIP_REQUEST` with
/// `formatId` for every value of this type a `ClipboardSession` entry hands out. The session
/// has already recorded the request as in flight when it hands this out, so a value that is
/// not posted leaves the session waiting for an answer that never comes -- Windows -> Mac
/// stops until the next ready or the next connection (S5; crdpq.h counts this as one of the
/// three stalling drops).
public struct ClipboardDataRequest: Equatable, Sendable {
    /// The format to request: always 13 (CF_UNICODETEXT) in T1.
    public let formatId: UInt32

    init(formatId: UInt32) {
        self.formatId = formatId
    }
}

/// S4 rule 1's verdict on one Windows format list: request now, or not (with why).
public enum ClipboardRequestDecision: Equatable, Sendable {
    /// Send this request (see `ClipboardDataRequest` for the obligation).
    case send(ClipboardDataRequest)
    /// Send nothing now. The Mac pasteboard stays exactly as it is.
    case noRequest(ClipboardNoRequestReason)

    /// The request to send, if any -- the same accessor `ClipboardRemoteDataResult.request`
    /// has, so the caller's "post a request" code is one path for both entries.
    public var request: ClipboardDataRequest? {
        if case .send(let request) = self { return request }
        return nil
    }
}

/// What to do with one Windows data response (S4 rule 3).
public enum ClipboardInboundOutcome: Equatable, Sendable {
    /// Write this text to the Mac pasteboard, together with the marker type, then record the
    /// resulting change count with `ClipboardSession.recordOwnWrite(changeCount:)`.
    ///
    /// `sensitive`: the Windows list this text came from was marked excluded
    /// (`ClipboardRemoteFormats.isRemoteExcluded`). Write it as sensitive content -- add
    /// `org.nspasteboard.ConcealedType` too, and keep this item out of cross-device sync. Not
    /// optional to act on, which is why it sits in the case itself: a pattern that binds the
    /// text has to say what it does with this.
    case write(ClipboardText, sensitive: Bool)
    /// Write nothing.
    case drop(ClipboardInboundDropReason)
}

extension ClipboardInboundOutcome: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .write(let text, let sensitive): "ClipboardInboundOutcome.write(utf16Count: \(text.utf16Count), sensitive: \(sensitive))"
        case .drop(let reason): "ClipboardInboundOutcome.drop(\(reason.rawValue))"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        switch self {
        case .write(let text, let sensitive):
            Mirror(self, children: ["write.utf16Count": text.utf16Count, "write.sensitive": sensitive], displayStyle: .enum)
        case .drop(let reason): Mirror(self, children: ["drop": reason.rawValue], displayStyle: .enum)
        }
    }
}

/// S4 rule 3's two parts for one Windows data response: what happens to it, and whether a
/// request must go out right after it (the follow-up check of S4 rule 4).
public struct ClipboardRemoteDataResult: Equatable, Sendable {
    /// Write the text (then record the change count with
    /// `ClipboardSession.recordOwnWrite(changeCount:)`), or drop it.
    public let outcome: ClipboardInboundOutcome
    /// A request to send now, or nil. Not optional to act on: see `ClipboardDataRequest`.
    public let request: ClipboardDataRequest?
}

extension ClipboardRemoteDataResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ClipboardRemoteDataResult(outcome: \(outcome), request: \(request.map { "\($0.formatId)" } ?? "none"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["outcome": outcome.description, "request": request.map { "\($0.formatId)" } ?? "none"],
               displayStyle: .struct)
    }
}

/// S4 rule 3 after the request has been matched and found current (same generation): what the
/// response turns into. Rules, first match wins:
/// 1. a failure -> drop;
/// 2. the Mac change count is not the baseline taken when the Windows list arrived -> drop
///    (the Mac has newer content of its own: a copy made while Macdows was in the background,
///    a screenshot, a sensitive copy -- none of them announced, so none of them moved the
///    generation);
/// 3. over the limit, judged on the length on the wire whether or not the bytes are here -> drop;
/// 4. bytes unavailable (within the limit) -> drop;
/// 5. S7 decode fails -> drop;
/// 6. decodes to the empty string -> drop (never overwrite the Mac pasteboard with nothing);
/// otherwise write, as sensitive content when the list was marked excluded.
/// Kept apart from `ClipboardSession` because it needs nothing but these values. INTERNAL: the
/// session is the only caller that holds a real baseline and exclusion mark, and a caller that
/// used this directly would skip the generation check in front of it -- and could write a
/// stale answer (`ClipboardSession.remoteDataReceived` is the one way in; the tests reach this
/// through `@testable import`).
enum ClipboardInboundPayload {
    static func evaluate(_ response: ClipboardDataResponse, changeCount: Int, baselineChangeCount: Int,
                         sensitive: Bool, limits: ClipboardLimits) -> ClipboardInboundOutcome {
        let wireLength: Int
        switch response {
        case .failure:
            return .drop(.remoteFailure)
        case .successWithoutBytes(let byteCount):
            wireLength = byteCount
        case .success(let bytes):
            wireLength = bytes.count
        }
        guard changeCount == baselineChangeCount else { return .drop(.localNewer) }
        guard limits.admitsRemoteToLocal(byteCount: wireLength) else { return .drop(.tooLarge) }
        guard case .success(let bytes) = response else { return .drop(.bytesUnavailable) }
        switch ClipboardTextCodec.decodeUnicodeText(bytes.bytes) {
        case .failure:
            return .drop(.malformed)
        case .text(let text):
            guard !text.value.isEmpty else { return .drop(.emptyText) }
            return .write(text, sensitive: sensitive)
        }
    }
}
