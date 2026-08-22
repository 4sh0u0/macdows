import Foundation

/// One parsed line from a `rail-probe` JSONL event log.
///
/// Field authority: `Tools/rail-probe/rail-probe.c`'s `log_event(...)` call sites (one per
/// RAIL/RDPGFX callback), cross-checked against the real captures in
/// `samples/phase05-rail-events-2026-08-19/*.jsonl`. Every event shares a common envelope
/// (`t_ms`, `tid`, `ev`) plus event-specific fields inlined into the same JSON object —
/// there is no nested "data" object in the wire format.
public struct RailEvent: Decodable, Sendable, Equatable {
    /// Monotonic milliseconds since the probe started (`clock_gettime(CLOCK_MONOTONIC)`
    /// relative to connect time) — not a wall-clock timestamp.
    public let tMs: UInt64
    /// Hex-formatted `pthread_self()` of the thread that logged this event (e.g.
    /// `T_rdp`/`T_dvc` per adr/0005's threading model — RAIL-channel events and
    /// RDPGFX-channel events come from different tids).
    public let tid: String
    public let kind: RailEventKind

    /// 1-based line number within the source JSONL file. Not part of the wire format —
    /// left `nil` for hand-constructed events (e.g. in unit tests); set by
    /// ``RailEvent/parseJSONL(_:)`` after a successful decode, so `WindowModel.apply(_:)`
    /// can attach it to any `Anomaly` it reports without needing a separate parameter.
    public var lineNumber: Int?

    private enum EnvelopeKeys: String, CodingKey {
        case tMs = "t_ms"
        case tid
        case ev
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        self.tMs = try container.decode(UInt64.self, forKey: .tMs)
        self.tid = try container.decode(String.self, forKey: .tid)
        let ev = try container.decode(String.self, forKey: .ev)
        self.kind = try RailEventKind(ev: ev, decoder: decoder)
        self.lineNumber = nil
    }

    /// Only used by tests that need to hand-construct an event without going through JSON.
    public init(tMs: UInt64, tid: String, kind: RailEventKind, lineNumber: Int? = nil) {
        self.tMs = tMs
        self.tid = tid
        self.kind = kind
        self.lineNumber = lineNumber
    }
}

/// One line that failed to parse as a `RailEvent`. Kept separate from `RailEvent` itself —
/// a parse failure has no `ev`/`kind` to speak of, only a location and a reason.
public struct RailEventParseFailure: Sendable, Equatable {
    public let lineNumber: Int
    public let line: String
    public let error: String
}

extension RailEvent {
    /// Parses a JSONL event log, one `RailEvent` per non-blank line. A line that isn't
    /// valid UTF-8 or doesn't decode as a `RailEvent` becomes a `RailEventParseFailure`
    /// instead of aborting the whole parse — the caller sees exactly which lines failed
    /// and why, rather than losing the rest of the file to one bad line.
    ///
    /// An unrecognized `ev` name is *not* a parse failure: it decodes successfully as
    /// ``RailEventKind/unknown(_:)`` and lands in `events`. Only a structurally-broken
    /// line (bad JSON, wrong field types, missing envelope fields) is a failure.
    public static func parseJSONL(_ contents: String) -> (events: [RailEvent], failures: [RailEventParseFailure]) {
        var events: [RailEvent] = []
        var failures: [RailEventParseFailure] = []
        let decoder = JSONDecoder()

        var lineNumber = 0
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            guard let data = line.data(using: .utf8) else {
                failures.append(RailEventParseFailure(lineNumber: lineNumber, line: line, error: "not valid UTF-8"))
                continue
            }
            do {
                var event = try decoder.decode(RailEvent.self, from: data)
                event.lineNumber = lineNumber
                events.append(event)
            } catch {
                failures.append(RailEventParseFailure(lineNumber: lineNumber, line: line, error: String(describing: error)))
            }
        }
        return (events, failures)
    }

    /// Convenience over ``parseJSONL(_:)-swift.type.method`` for an on-disk file.
    public static func parseJSONL(fileAt url: URL) throws -> (events: [RailEvent], failures: [RailEventParseFailure]) {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parseJSONL(contents)
    }
}

// MARK: - Event kinds

/// Every `ev` name `rail-probe.c` can emit, plus `.unknown` for anything this package
/// doesn't recognize yet (a future probe build might add events; a replay must not treat
/// that as fatal — see adr/0006 §4's "replay gate" requirement).
///
/// Payload field names match the JSON keys verbatim (the C `log_event` format strings
/// already write camelCase field names), so each payload is a plain `Decodable` struct
/// decoded directly against the same decoder as the envelope — extra keys (`t_ms`, `tid`,
/// `ev`) are simply ignored by Swift's synthesized `Decodable`, no manual key-filtering
/// needed.
///
/// Position/offset/tracking-bound fields (windowOffsetX/Y, posX/Y, maxPosX/Y, etc.) are
/// `Int32`, matching RAIL's wire type where verified signed (offsets can be negative in a
/// multi-monitor layout, see `Packages/MacdowsCore/.../WindowGeometry.swift`).
/// Size fields are `UInt32`: `WindowOrderPayload.windowWidth`/`windowHeight` (FreeRDP's
/// order parser reads them via `Stream_Read_UINT32`, `window.c:409-410`, unlike the signed
/// `Stream_Read_INT32` used for `windowOffsetX`/`windowOffsetY` a few lines above in the
/// same function), and the GFX map payloads' `mappedWidth`/`mappedHeight`/`targetWidth`/
/// `targetHeight` (both `RDPGFX_MAP_SURFACE_TO_WINDOW_PDU` variants declare all four as
/// `UINT32` in `freerdp/channels/rdpgfx.h`; an earlier revision of this comment grouped
/// them under "verified signed" — that classification was wrong, corrected alongside the
/// crdpq-side int32→uint32 migration). Identifier/flag/bitmask fields
/// (windowId, notifyIconId, surfaceId, fieldFlags, style/styleEx, show) stay `UInt32` —
/// real data includes `style` values like `2_147_483_648` (bit 31 set), which would
/// silently fail to decode as `Int32`.
public enum RailEventKind: Sendable, Equatable {
    case windowCreate(WindowOrderPayload)
    case windowUpdate(WindowOrderPayload)
    case windowDelete(windowId: UInt32)
    case windowIcon(windowId: UInt32)
    case windowCachedIcon(windowId: UInt32)
    case notifyIconCreate(windowId: UInt32, notifyIconId: UInt32)
    case notifyIconUpdate(windowId: UInt32, notifyIconId: UInt32)
    case notifyIconDelete(windowId: UInt32, notifyIconId: UInt32)
    case monitoredDesktop(fieldFlags: UInt32, activeWindowId: UInt32, numWindowIds: UInt32)
    case nonMonitoredDesktop
    case clientRailServerStartCmd(rc: UInt32)

    case serverHandshake(buildNumber: UInt32)
    case serverHandshakeEx(buildNumber: UInt32, railHandshakeFlags: UInt32)
    case serverExecuteResult(flags: UInt32, execResult: UInt32, rawResult: UInt32, exeOrFile: String)
    case serverSystemParam(param: UInt32, params: UInt32)
    case serverLocalMoveSize(windowId: UInt32, isMoveSizeStart: Bool, moveSizeType: UInt32, posX: Int32, posY: Int32)
    case serverMinMaxInfo(
        windowId: UInt32, maxWidth: Int32, maxHeight: Int32, maxPosX: Int32, maxPosY: Int32,
        minTrackWidth: Int32, minTrackHeight: Int32, maxTrackWidth: Int32, maxTrackHeight: Int32
    )
    case serverZOrderSync(windowIdMarker: UInt32)
    case serverGetAppIdResponse(windowId: UInt32, applicationId: String)

    /// `windowId` is `UInt64` on the wire (`RDPGFX_MAP_SURFACE_TO_WINDOW_PDU`), unlike
    /// every RAIL-channel windowId (`UInt32`) — real window IDs always fit in 32 bits
    /// (confirmed against every sample), but the type is kept faithful to the struct
    /// FreeRDP actually uses. `WindowModel` does the narrowing when it correlates this
    /// against the RAIL-channel windows dictionary.
    case gfxMapSurfaceToWindow(surfaceId: UInt32, windowId: UInt64, mappedWidth: UInt32, mappedHeight: UInt32)
    case gfxMapSurfaceToScaledWindow(
        surfaceId: UInt32, windowId: UInt64, mappedWidth: UInt32, mappedHeight: UInt32,
        targetWidth: UInt32, targetHeight: UInt32
    )
    case gfxResetGraphics(width: Int32, height: Int32, monitorCount: UInt32)
    /// Only emitted when the probe was run with `--decode`; absent from every sample in
    /// `samples/phase05-rail-events-2026-08-19` (none were captured with that flag).
    case codecStats(counts: [String: UInt64])

    case channelConnected(name: String)
    case channelDisconnected(name: String)
    /// Not observed in any sample — this dev environment's NLA path never triggered the
    /// TLS certificate callback the way an X.509-fallback connection would.
    case verifyCertificateEx(
        host: String, port: UInt32, commonName: String, subject: String, issuer: String,
        fingerprint: String, flags: UInt32
    )
    case logonErrorInfo(data: String, type: String)

    case preConnect
    case postConnect
    case postDisconnect
    case postFinalDisconnect
    case secondExecBegin(program: String)
    case secondExecEnd(program: String, rc: UInt32)
    case connectFailed(error: UInt32, errorString: String)
    case connectSucceeded
    case eventHandlesFailed
    case waitFailed
    case checkEventHandlesFailed
    case durationElapsed(sinceConnectMs: UInt64)

    /// Any `ev` name not listed above. Carries the raw name through rather than dropping
    /// the event — a probe built from a newer `rail-probe.c` (new event type added) must
    /// still replay cleanly against this model; only genuinely malformed JSON is a parse
    /// failure (see ``RailEvent/parseJSONL(_:)``).
    case unknown(String)

    init(ev: String, decoder: Decoder) throws {
        switch ev {
        case "WindowCreate": self = .windowCreate(try WindowOrderPayload(from: decoder))
        case "WindowUpdate": self = .windowUpdate(try WindowOrderPayload(from: decoder))
        case "WindowDelete": self = .windowDelete(windowId: try WindowIdPayload(from: decoder).windowId)
        case "WindowIcon": self = .windowIcon(windowId: try WindowIdPayload(from: decoder).windowId)
        case "WindowCachedIcon": self = .windowCachedIcon(windowId: try WindowIdPayload(from: decoder).windowId)
        case "NotifyIconCreate":
            let p = try NotifyIconPayload(from: decoder)
            self = .notifyIconCreate(windowId: p.windowId, notifyIconId: p.notifyIconId)
        case "NotifyIconUpdate":
            let p = try NotifyIconPayload(from: decoder)
            self = .notifyIconUpdate(windowId: p.windowId, notifyIconId: p.notifyIconId)
        case "NotifyIconDelete":
            let p = try NotifyIconPayload(from: decoder)
            self = .notifyIconDelete(windowId: p.windowId, notifyIconId: p.notifyIconId)
        case "MonitoredDesktop":
            let p = try MonitoredDesktopPayload(from: decoder)
            self = .monitoredDesktop(fieldFlags: p.fieldFlags, activeWindowId: p.activeWindowId, numWindowIds: p.numWindowIds)
        case "NonMonitoredDesktop": self = .nonMonitoredDesktop
        case "ClientRailServerStartCmd": self = .clientRailServerStartCmd(rc: try RcPayload(from: decoder).rc)

        case "ServerHandshake": self = .serverHandshake(buildNumber: try BuildNumberPayload(from: decoder).buildNumber)
        case "ServerHandshakeEx":
            let p = try HandshakeExPayload(from: decoder)
            self = .serverHandshakeEx(buildNumber: p.buildNumber, railHandshakeFlags: p.railHandshakeFlags)
        case "ServerExecuteResult":
            let p = try ExecuteResultPayload(from: decoder)
            self = .serverExecuteResult(flags: p.flags, execResult: p.execResult, rawResult: p.rawResult, exeOrFile: p.exeOrFile)
        case "ServerSystemParam":
            let p = try SystemParamPayload(from: decoder)
            self = .serverSystemParam(param: p.param, params: p.params)
        case "ServerLocalMoveSize":
            let p = try LocalMoveSizePayload(from: decoder)
            self = .serverLocalMoveSize(
                windowId: p.windowId, isMoveSizeStart: p.isMoveSizeStart, moveSizeType: p.moveSizeType,
                posX: p.posX, posY: p.posY
            )
        case "ServerMinMaxInfo":
            let p = try MinMaxInfoPayload(from: decoder)
            self = .serverMinMaxInfo(
                windowId: p.windowId, maxWidth: p.maxWidth, maxHeight: p.maxHeight, maxPosX: p.maxPosX,
                maxPosY: p.maxPosY, minTrackWidth: p.minTrackWidth, minTrackHeight: p.minTrackHeight,
                maxTrackWidth: p.maxTrackWidth, maxTrackHeight: p.maxTrackHeight
            )
        case "ServerZOrderSync": self = .serverZOrderSync(windowIdMarker: try ZOrderSyncPayload(from: decoder).windowIdMarker)
        case "ServerGetAppIdResponse":
            let p = try GetAppIdResponsePayload(from: decoder)
            self = .serverGetAppIdResponse(windowId: p.windowId, applicationId: p.applicationId)

        case "GfxMapSurfaceToWindow":
            let p = try MapSurfaceToWindowPayload(from: decoder)
            self = .gfxMapSurfaceToWindow(surfaceId: p.surfaceId, windowId: p.windowId, mappedWidth: p.mappedWidth, mappedHeight: p.mappedHeight)
        case "GfxMapSurfaceToScaledWindow":
            let p = try MapSurfaceToScaledWindowPayload(from: decoder)
            self = .gfxMapSurfaceToScaledWindow(
                surfaceId: p.surfaceId, windowId: p.windowId, mappedWidth: p.mappedWidth, mappedHeight: p.mappedHeight,
                targetWidth: p.targetWidth, targetHeight: p.targetHeight
            )
        case "GfxResetGraphics":
            let p = try ResetGraphicsPayload(from: decoder)
            self = .gfxResetGraphics(width: p.width, height: p.height, monitorCount: p.monitorCount)
        case "CodecStats": self = .codecStats(counts: try CodecStatsPayload(from: decoder).counts)

        case "ChannelConnected": self = .channelConnected(name: try NamePayload(from: decoder).name)
        case "ChannelDisconnected": self = .channelDisconnected(name: try NamePayload(from: decoder).name)
        case "VerifyCertificateEx":
            let p = try VerifyCertificateExPayload(from: decoder)
            self = .verifyCertificateEx(
                host: p.host, port: p.port, commonName: p.commonName, subject: p.subject, issuer: p.issuer,
                fingerprint: p.fingerprint, flags: p.flags
            )
        case "LogonErrorInfo":
            let p = try LogonErrorInfoPayload(from: decoder)
            self = .logonErrorInfo(data: p.data, type: p.type)

        case "PreConnect": self = .preConnect
        case "PostConnect": self = .postConnect
        case "PostDisconnect": self = .postDisconnect
        case "PostFinalDisconnect": self = .postFinalDisconnect
        case "SecondExecBegin": self = .secondExecBegin(program: try ProgramPayload(from: decoder).program)
        case "SecondExecEnd":
            let p = try SecondExecEndPayload(from: decoder)
            self = .secondExecEnd(program: p.program, rc: p.rc)
        case "ConnectFailed":
            let p = try ConnectFailedPayload(from: decoder)
            self = .connectFailed(error: p.error, errorString: p.errorString)
        case "ConnectSucceeded": self = .connectSucceeded
        case "EventHandlesFailed": self = .eventHandlesFailed
        case "WaitFailed": self = .waitFailed
        case "CheckEventHandlesFailed": self = .checkEventHandlesFailed
        case "DurationElapsed": self = .durationElapsed(sinceConnectMs: try DurationElapsedPayload(from: decoder).sinceConnectMs)

        default:
            self = .unknown(ev)
        }
    }
}

// MARK: - Payload structs (internal decoding helpers)
//
// Each mirrors one `log_event(..., fmt, ...)` call's field list in rail-probe.c exactly.
// Kept as small, single-purpose Decodable structs rather than one big optional-field blob
// so a missing/mistyped field for a *specific* event fails to decode (a real parse
// failure), instead of silently decoding as nil.

public struct WindowOrderPayload: Decodable, Sendable, Equatable {
    public let windowId: UInt32
    public let fieldFlags: UInt32
    public let windowOffsetX: Int32
    public let windowOffsetY: Int32
    /// `UInt32`, not `Int32` — see this file's `RailEventKind` doc comment for why
    /// (`window.c:409-410` reads these via `Stream_Read_UINT32`, unlike the signed
    /// offsets above).
    public let windowWidth: UInt32
    public let windowHeight: UInt32
    public let numVisibilityRects: UInt32
    public let style: UInt32
    public let styleEx: UInt32
    public let show: UInt32
    public let title: String
    /// `TS_WINDOW_STATE_ORDER.ownerWindowId` (adr/0008 §3). Never emitted by
    /// `rail-probe.c`'s current `log_event` calls — verified against every
    /// `samples/phase05-rail-events-2026-08-19/*.jsonl` line: zero matches for this key
    /// (adr/0008 §0) — so this decodes as 0 when the key is absent, per adr/0008 §5's
    /// replay-compat rule ("new fields append; absent means 0/false, never a decode
    /// failure"). A future probe build that does log it decodes the real value normally.
    public let ownerWindowId: UInt32

    private enum CodingKeys: String, CodingKey {
        case windowId, fieldFlags, windowOffsetX, windowOffsetY, windowWidth, windowHeight
        case numVisibilityRects, style, styleEx, show, title, ownerWindowId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowId = try container.decode(UInt32.self, forKey: .windowId)
        fieldFlags = try container.decode(UInt32.self, forKey: .fieldFlags)
        windowOffsetX = try container.decode(Int32.self, forKey: .windowOffsetX)
        windowOffsetY = try container.decode(Int32.self, forKey: .windowOffsetY)
        windowWidth = try container.decode(UInt32.self, forKey: .windowWidth)
        windowHeight = try container.decode(UInt32.self, forKey: .windowHeight)
        numVisibilityRects = try container.decode(UInt32.self, forKey: .numVisibilityRects)
        style = try container.decode(UInt32.self, forKey: .style)
        styleEx = try container.decode(UInt32.self, forKey: .styleEx)
        show = try container.decode(UInt32.self, forKey: .show)
        title = try container.decode(String.self, forKey: .title)
        ownerWindowId = try container.decodeIfPresent(UInt32.self, forKey: .ownerWindowId) ?? 0
    }

    /// Explicit memberwise init — a custom `init(from:)` above suppresses Swift's
    /// synthesized one, and `WindowModelTests`' `@testable`-visible construction helper
    /// relies on calling this directly. `ownerWindowId` defaults to 0, matching this
    /// struct's own decode-when-absent behavior.
    init(
        windowId: UInt32, fieldFlags: UInt32, windowOffsetX: Int32, windowOffsetY: Int32,
        windowWidth: UInt32, windowHeight: UInt32, numVisibilityRects: UInt32, style: UInt32,
        styleEx: UInt32, show: UInt32, title: String, ownerWindowId: UInt32 = 0
    ) {
        self.windowId = windowId
        self.fieldFlags = fieldFlags
        self.windowOffsetX = windowOffsetX
        self.windowOffsetY = windowOffsetY
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.numVisibilityRects = numVisibilityRects
        self.style = style
        self.styleEx = styleEx
        self.show = show
        self.title = title
        self.ownerWindowId = ownerWindowId
    }
}

struct WindowIdPayload: Decodable { let windowId: UInt32 }
struct NotifyIconPayload: Decodable { let windowId: UInt32; let notifyIconId: UInt32 }
struct MonitoredDesktopPayload: Decodable { let fieldFlags: UInt32; let activeWindowId: UInt32; let numWindowIds: UInt32 }
struct RcPayload: Decodable { let rc: UInt32 }
struct BuildNumberPayload: Decodable { let buildNumber: UInt32 }
struct HandshakeExPayload: Decodable { let buildNumber: UInt32; let railHandshakeFlags: UInt32 }
struct ExecuteResultPayload: Decodable { let flags: UInt32; let execResult: UInt32; let rawResult: UInt32; let exeOrFile: String }
struct SystemParamPayload: Decodable { let param: UInt32; let params: UInt32 }
struct LocalMoveSizePayload: Decodable {
    let windowId: UInt32
    let isMoveSizeStart: Bool
    let moveSizeType: UInt32
    let posX: Int32
    let posY: Int32
}
struct MinMaxInfoPayload: Decodable {
    let windowId: UInt32
    let maxWidth: Int32
    let maxHeight: Int32
    let maxPosX: Int32
    let maxPosY: Int32
    let minTrackWidth: Int32
    let minTrackHeight: Int32
    let maxTrackWidth: Int32
    let maxTrackHeight: Int32
}
struct ZOrderSyncPayload: Decodable { let windowIdMarker: UInt32 }
struct GetAppIdResponsePayload: Decodable { let windowId: UInt32; let applicationId: String }
struct MapSurfaceToWindowPayload: Decodable { let surfaceId: UInt32; let windowId: UInt64; let mappedWidth: UInt32; let mappedHeight: UInt32 }
struct MapSurfaceToScaledWindowPayload: Decodable {
    let surfaceId: UInt32
    let windowId: UInt64
    let mappedWidth: UInt32
    let mappedHeight: UInt32
    let targetWidth: UInt32
    let targetHeight: UInt32
}
struct ResetGraphicsPayload: Decodable { let width: Int32; let height: Int32; let monitorCount: UInt32 }
struct CodecStatsPayload: Decodable { let counts: [String: UInt64] }
struct NamePayload: Decodable { let name: String }
struct VerifyCertificateExPayload: Decodable {
    let host: String
    let port: UInt32
    let commonName: String
    let subject: String
    let issuer: String
    let fingerprint: String
    let flags: UInt32
}
struct LogonErrorInfoPayload: Decodable { let data: String; let type: String }
struct ProgramPayload: Decodable { let program: String }
struct SecondExecEndPayload: Decodable { let program: String; let rc: UInt32 }
struct ConnectFailedPayload: Decodable { let error: UInt32; let errorString: String }
struct DurationElapsedPayload: Decodable { let sinceConnectMs: UInt64 }
