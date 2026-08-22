import Foundation

/// MS-RDPERP `TS_WINDOW_STATE_ORDER` field-presence bits actually used here, verified
/// against `ThirdParty/FreeRDP/include/freerdp/window.h` and how
/// `libfreerdp/core/window.c`'s own order parser (`update_read_window_state_order`,
/// window.c:311-332) gates each sub-field's read on the matching bit.
private enum WindowOrderField {
    /// `WINDOW_ORDER_FIELD_OWNER` (window.h:35) — gates `ownerWindowId` (adr/0008 §3).
    static let owner: UInt32 = 0x0000_0002
    static let title: UInt32 = 0x0000_0004
    static let style: UInt32 = 0x0000_0008 // gates BOTH style and extendedStyle together
    static let show: UInt32 = 0x0000_0010
    // 0x0000_0100 is WINDOW_ORDER_FIELD_WND_RECTS, which gates `numWindowRects` (+ the
    // clip-rect array) at window.c:413-418 — a field this probe/payload never captures.
    // The one we *do* capture, `numVisibilityRects`, is gated by WINDOW_ORDER_FIELD_
    // VISIBILITY (0x0000_0200) at window.c:457-462, a completely separate bit. Using
    // 0x100 here was a real bug (M1 in the W2 review) — it happened to never fire on any
    // of the six phase05 samples only because every WindowUpdate that ever set
    // numVisibilityRects in those captures apparently also happened to have bit 0x100
    // set for unrelated reasons, so the wrong-bit gate still let the value through by
    // coincidence, not because the bit was correct.
    static let visibility: UInt32 = 0x0000_0200 // numVisibilityRects (+ rect array we don't capture)
    static let size: UInt32 = 0x0000_0400 // windowWidth/windowHeight together
    static let offset: UInt32 = 0x0000_0800 // windowOffsetX/windowOffsetY together
}

/// Everything RAIL/RDPGFX order-handling needs to know about one remote window.
public struct WindowState: Sendable, Equatable {
    public var windowId: UInt32
    public var offsetX: Int32 = 0
    public var offsetY: Int32 = 0
    /// `UInt32`, not `Int32` — matches `WindowOrderPayload.windowWidth`/`windowHeight`
    /// (see that type's doc comment: FreeRDP's own parser reads these unsigned).
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var numVisibilityRects: UInt32 = 0
    public var style: UInt32 = 0
    public var styleEx: UInt32 = 0
    public var show: UInt32 = 0
    public var title: String = ""
    /// `TS_WINDOW_STATE_ORDER.ownerWindowId` (adr/0008 §3), bit-gated on
    /// `WINDOW_ORDER_FIELD_OWNER` exactly like every other conditional sub-field below —
    /// an absent bit means "unchanged", not "no owner"; 0 is itself a legitimate owner
    /// value ("no owner"/desktop-owned) once actually observed on the wire.
    public var ownerWindowId: UInt32 = 0
    /// Set once a `WindowIcon` or `WindowCachedIcon` order has been seen for this window.
    /// The probe log doesn't carry icon bytes, only that an icon order occurred.
    public var hasIcon: Bool = false

    init(windowId: UInt32) {
        self.windowId = windowId
    }

    /// Applies only the sub-fields flagged present in `payload.fieldFlags`.
    /// `TS_WINDOW_STATE_ORDER` is a *delta* structure — a field with its bit unset means
    /// "unchanged from this window's prior state", not "reset to empty/zero". Getting
    /// this wrong (naively overwriting the whole struct on every order) silently wipes a
    /// window's title back to "" on the next geometry-only update — confirmed against
    /// real capture data: `rail-probe.c`'s `probe_window_common` always logs a `"title"`
    /// key, but it's only ever non-empty when `WINDOW_ORDER_FIELD_TITLE` is actually set
    /// for that specific order (the C source zero-initializes `titleEsc` and only
    /// populates it inside that `if`). s1's "About Windows" window's title arrives on one
    /// `WindowUpdate`; several later updates for the same window carry no title bit and
    /// would otherwise erase it.
    mutating func merge(_ payload: WindowOrderPayload) {
        if payload.fieldFlags & WindowOrderField.owner != 0 {
            ownerWindowId = payload.ownerWindowId
        }
        if payload.fieldFlags & WindowOrderField.offset != 0 {
            offsetX = payload.windowOffsetX
            offsetY = payload.windowOffsetY
        }
        if payload.fieldFlags & WindowOrderField.size != 0 {
            width = payload.windowWidth
            height = payload.windowHeight
        }
        if payload.fieldFlags & WindowOrderField.visibility != 0 {
            numVisibilityRects = payload.numVisibilityRects
        }
        if payload.fieldFlags & WindowOrderField.style != 0 {
            style = payload.style
            styleEx = payload.styleEx
        }
        if payload.fieldFlags & WindowOrderField.show != 0 {
            show = payload.show
        }
        if payload.fieldFlags & WindowOrderField.title != 0 {
            title = payload.title
        }
    }
}

/// A notification-area (systray) icon. Its `windowId` is the RAIL-reported owner window —
/// which, per real capture data, is frequently a window that never receives its own
/// top-level `WindowCreate` (see `WindowModel`'s doc comment on why that's not modeled as
/// an anomaly).
public struct NotifyIconState: Sendable, Equatable, Hashable {
    public var windowId: UInt32
    public var notifyIconId: UInt32
}

public struct ExecResult: Sendable, Equatable {
    public var program: String
    public var execResult: UInt32
    public var rawResult: UInt32
}

/// Something `WindowModel.apply(_:)` saw that violates the create-before-touch invariant
/// it enforces. Carries the source line number (from `RailEvent.lineNumber`, when the
/// event came from `parseJSONL`) so a replay failure can point straight at the offending
/// JSONL line.
public struct Anomaly: Sendable, Equatable {
    public let lineNumber: Int?
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        /// `WindowCreate` for a `windowId` that's already in `windows` — model overwrites
        /// with the new state (matching what the server clearly intends: this windowId
        /// now means something new), but flags it since a well-behaved server shouldn't
        /// double-create without an intervening `WindowDelete`.
        case duplicateWindowCreate(windowId: UInt32)
        /// `WindowUpdate` for a `windowId` never (or no longer) created. Ignored — no
        /// implicit window creation from an update-shaped order.
        case updateUnknownWindow(windowId: UInt32)
        /// `WindowDelete` for a `windowId` never (or no longer) created. Ignored.
        case deleteUnknownWindow(windowId: UInt32)
        /// `WindowIcon`/`WindowCachedIcon` for a `windowId` never (or no longer) created.
        /// Ignored. Not observed in any of the six phase05 samples — every icon order in
        /// the real captures follows its window's `WindowCreate` — but the policy is
        /// implemented for the same reason `WindowUpdate`/`WindowDelete` are: an icon
        /// order is conceptually an update to existing window state, so it gets the same
        /// "never implicitly create a window" treatment.
        case iconUnknownWindow(windowId: UInt32)
    }
}

/// Pure state machine consuming `RailEvent`s into a picture of "what windows/notify icons/
/// surface bindings currently exist" — no AppKit, no FreeRDP, no I/O (adr/0006 §2's
/// no-AppKit boundary; adr/0005 §6's replay-gate requirement that this be a pure function
/// of the event stream).
///
/// ## Anomaly scope (a deliberate, evidence-based choice — see W2 report)
///
/// Exploring all six `samples/phase05-rail-events-2026-08-19/*.jsonl` captures surfaced
/// two very common patterns that are *not* treated as `Anomaly`:
///
/// 1. **`NotifyIconCreate`/`Update`/`Delete` referencing a `windowId` with no
///    `WindowCreate`.** This happens dozens of times in every single sample — real
///    Windows commonly parents a systray icon to a hidden/message-only owner window that
///    is never published as a top-level RAIL window. That's normal MS-RDPERP behavior,
///    not an ordering bug in the server or in this model, so `notifyIcons` is tracked
///    unconditionally by `(windowId, notifyIconId)` with no cross-check against `windows`.
/// 2. **`GfxMapSurfaceToWindow` naming a `windowId` not yet in `windows`.** This is the
///    *designed* case adr/0005 §2's SurfaceSlot/pending-binding mechanism exists for
///    (RAIL and RDPGFX are separate channels/threads with no cross-channel ordering
///    guarantee) — every sample has several of these, and all but two settle within the
///    same session once the matching `WindowCreate` arrives. It is expected control flow,
///    routed through `pendingBindings`, not flagged as an `Anomaly`.
///
/// What *is* flagged (`Anomaly.Kind`, all three cases) never actually occurs in the six
/// phase05 samples — see `ReplayTests` for the explicit "zero anomalies" assertion this
/// implies, and the W2 report for why an empty expected-set is itself a real finding
/// worth pinning down as a regression check.
public struct WindowModel: Sendable {
    public private(set) var windows: [UInt32: WindowState] = [:]
    public private(set) var notifyIcons: Set<NotifyIconState> = []
    public private(set) var monitoredDesktopActive: Bool = false
    public private(set) var activeWindowId: UInt32?

    /// Settled surface -> window bindings (adr/0005 §2 SurfaceSlot).
    public private(set) var surfaceBindings: [UInt32: UInt64] = [:]
    /// Surface -> window bindings still waiting on a `WindowCreate` for their target
    /// window. Settles into `surfaceBindings` the moment that `WindowCreate` arrives;
    /// anything still here at the end of a replay named a window that was never created
    /// in that session (real, reproducible cases: surfaces mapped to windowIds 65548 and
    /// 66174 in every phase05 sample that has any GfxMapSurfaceToWindow traffic at all —
    /// see the W2 report).
    public private(set) var pendingBindings: [UInt32: UInt64] = [:]

    public private(set) var execResults: [ExecResult] = []

    public init() {}

    @discardableResult
    public mutating func apply(_ e: RailEvent) -> [Anomaly] {
        var anomalies: [Anomaly] = []
        func flag(_ kind: Anomaly.Kind) {
            anomalies.append(Anomaly(lineNumber: e.lineNumber, kind: kind))
        }

        switch e.kind {
        case .windowCreate(let payload):
            if windows[payload.windowId] != nil {
                flag(.duplicateWindowCreate(windowId: payload.windowId))
            }
            // Always a fresh WindowState on Create — "a repeated Create -> flag an Anomaly
            // and overwrite" means overwrite, not merge onto whatever the old (about-to-be-replaced)
            // window happened to have. Sub-fields absent from *this* create order still
            // fall back to WindowState's zero/empty defaults, not the prior window's
            // values, matching a real re-Create's intent of establishing a new identity
            // under a reused windowId.
            var state = WindowState(windowId: payload.windowId)
            state.merge(payload)
            windows[payload.windowId] = state
            settlePendingBindings(forWindowId: payload.windowId)

        case .windowUpdate(let payload):
            if var state = windows[payload.windowId] {
                state.merge(payload)
                windows[payload.windowId] = state
            } else {
                flag(.updateUnknownWindow(windowId: payload.windowId))
            }

        case .windowDelete(let windowId):
            if windows[windowId] == nil {
                flag(.deleteUnknownWindow(windowId: windowId))
            } else {
                windows.removeValue(forKey: windowId)
            }

        case .windowIcon(let windowId), .windowCachedIcon(let windowId):
            if windows[windowId] == nil {
                flag(.iconUnknownWindow(windowId: windowId))
            } else {
                windows[windowId]?.hasIcon = true
            }

        case .notifyIconCreate(let windowId, let notifyIconId),
             .notifyIconUpdate(let windowId, let notifyIconId):
            notifyIcons.insert(NotifyIconState(windowId: windowId, notifyIconId: notifyIconId))

        case .notifyIconDelete(let windowId, let notifyIconId):
            notifyIcons.remove(NotifyIconState(windowId: windowId, notifyIconId: notifyIconId))

        case .monitoredDesktop(_, let activeWindowId, _):
            monitoredDesktopActive = true
            self.activeWindowId = activeWindowId

        case .nonMonitoredDesktop:
            monitoredDesktopActive = false
            activeWindowId = nil

        case .gfxMapSurfaceToWindow(let surfaceId, let windowId, _, _):
            bindSurface(surfaceId: surfaceId, windowId: windowId)

        case .gfxMapSurfaceToScaledWindow(let surfaceId, let windowId, _, _, _, _):
            bindSurface(surfaceId: surfaceId, windowId: windowId)

        case .serverExecuteResult(_, let execResult, let rawResult, let exeOrFile):
            execResults.append(ExecResult(program: exeOrFile, execResult: execResult, rawResult: rawResult))

        default:
            break
        }

        return anomalies
    }

    private mutating func bindSurface(surfaceId: UInt32, windowId: UInt64) {
        if let narrowedWindowId = UInt32(exactly: windowId), windows[narrowedWindowId] != nil {
            surfaceBindings[surfaceId] = windowId
            pendingBindings.removeValue(forKey: surfaceId)
        } else {
            pendingBindings[surfaceId] = windowId
            // A surface can legitimately get remapped to a *different* windowId that
            // isn't known yet (surface reuse/rebinding — real, observed behavior, see
            // WindowModel's doc comment). Without clearing the old surfaceBindings entry
            // here, both dictionaries would simultaneously claim authoritative state for
            // the same surfaceId: a stale settled binding alongside a newer pending one.
            surfaceBindings.removeValue(forKey: surfaceId)
        }
    }

    private mutating func settlePendingBindings(forWindowId windowId: UInt32) {
        let target = UInt64(windowId)
        for (surfaceId, pendingWindowId) in pendingBindings where pendingWindowId == target {
            surfaceBindings[surfaceId] = pendingWindowId
            pendingBindings.removeValue(forKey: surfaceId)
        }
    }
}
