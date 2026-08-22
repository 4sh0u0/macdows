#import "CRSession.h"

#include <freerdp/config.h>

#include <dispatch/dispatch.h> /* dispatch_async(dispatch_get_main_queue(), ...) -- W4c review's push-drain fix */
#include <float.h> /* FLT_EPSILON -- W4c review L1's wheel-delta epsilon check */
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/freerdp.h>
#include <freerdp/constants.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/codec/region.h>
#include <freerdp/codec/color.h>
#include <freerdp/log.h>
#include <freerdp/utils/signal.h>
#include <freerdp/client/rail.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/channels.h>
#include <freerdp/rail.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>

/* W4c: keyboard scancode translation -- WINPR_KEYCODE_TYPE_APPLE/GetVirtualKeyCodeFromKeycode/
 * GetVirtualScanCodeFromVirtualKeyCode are public, WINPR_API-exported functions (confirmed
 * against .build/freerdp/current/prefix/include/winpr3/winpr/input.h) already linked into
 * this target via winpr3 -- no keycode table needed porting from
 * ThirdParty/FreeRDP/client/Mac/MRDPView.m, just these two calls, mirroring its own usage. */
#include <winpr/input.h>

#include <openssl/provider.h>

#include <winpr/crt.h>
#include <winpr/assert.h>
#include <winpr/synch.h>
#include <winpr/string.h>
#include <winpr/wlog.h>

#include "crdpq.h"
#include "CRSurfaceSlots.h"

/* W4a review M4: callback-body logging goes through WLog (FreeRDP's own logging
 * facility, which real client code -- e.g. client/X11/xf_client.c -- uses uniformly)
 * rather than NSLog, so it's captured consistently with everything else FreeRDP itself
 * logs (same WLog_* verbosity controls, same output stream) instead of a second,
 * differently-configured logging path. */
#define TAG CLIENT_TAG("macdows")

/* ==================================================================================== *
 * CRDPEvent
 * ==================================================================================== */

@interface CRDPEvent ()
@property (nonatomic) CRDPEventKind kind;
@property (nonatomic) uint32_t generation;
@property (nonatomic) uint32_t windowId;
@property (nonatomic) uint32_t notifyIconId;
@property (nonatomic) uint32_t fieldFlags;
@property (nonatomic) NSString *title;
@property (nonatomic) int32_t offsetX;
@property (nonatomic) int32_t offsetY;
@property (nonatomic) uint32_t windowWidth;
@property (nonatomic) uint32_t windowHeight;
@property (nonatomic) uint32_t show;
@property (nonatomic) uint32_t style;
@property (nonatomic) uint32_t styleEx;
@property (nonatomic) uint32_t ownerWindowId;
@property (nonatomic) NSArray<NSNumber *> *visibilityRects;
@property (nonatomic) uint32_t numVisibilityRects;
@property (nonatomic) BOOL visibilityRectsTruncated;
@property (nonatomic) uint32_t execResult;
@property (nonatomic) uint32_t rawResult;
@property (nonatomic) NSString *program;
@property (nonatomic) uint32_t buildNumber;
@property (nonatomic) uint32_t railHandshakeFlags;
@property (nonatomic) uint32_t surfaceId;
@property (nonatomic) uint64_t mappedWindowId;
@property (nonatomic) uint32_t mappedWidth;
@property (nonatomic) uint32_t mappedHeight;
@property (nonatomic) NSArray<NSNumber *> *windowIds;
@property (nonatomic) uint32_t numWindowIds;
@property (nonatomic) BOOL windowIdsTruncated;
@property (nonatomic) BOOL isMoveSizeStart;
@property (nonatomic) uint16_t moveSizeType;
@property (nonatomic) int32_t moveSizePosX;
@property (nonatomic) int32_t moveSizePosY;
@property (nonatomic) int32_t maxWidth;
@property (nonatomic) int32_t maxHeight;
@property (nonatomic) int32_t maxPosX;
@property (nonatomic) int32_t maxPosY;
@property (nonatomic) int32_t minTrackWidth;
@property (nonatomic) int32_t minTrackHeight;
@property (nonatomic) int32_t maxTrackWidth;
@property (nonatomic) int32_t maxTrackHeight;
@end

@implementation CRDPEvent

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _title = @"";
        _program = @"";
        _visibilityRects = @[];
        _windowIds = @[];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<CRDPEvent kind=%ld gen=%u windowId=%u title=%@>",
                                       (long)self.kind, self.generation, self.windowId, self.title];
}

@end

/// Builds a CRDPEvent from one drained (already generation-checked) CrdpEvent. This is
/// the only place a C struct's fields get read across the CRSession.h boundary — the
/// entire reason CRDPEvent exists (adr/0005 §5: no C/C++ types cross the public header).
/// Returns nil for a `type` this file doesn't recognize (W4a review M7) — the caller
/// (`-drainEventsWithHandler:`) skips a nil result and counts it into
/// `-unknownEventCount` rather than delivering a fabricated event to the drain handler.
static CRDPEvent *CRDPEventFromCrdpEvent(const CrdpEvent *ev)
{
    CRDPEvent *out = [CRDPEvent new];
    out.generation = ev->generation;

    switch (ev->type)
    {
        case CRDPQ_EVENT_WINDOW_CREATE:
        case CRDPQ_EVENT_WINDOW_UPDATE:
        {
            out.kind = (ev->type == CRDPQ_EVENT_WINDOW_CREATE) ? CRDPEventKindWindowCreate
                                                                : CRDPEventKindWindowUpdate;
            const crdpq_window_order_t *wo = &ev->payload.windowOrder;
            out.windowId = wo->windowId;
            out.fieldFlags = wo->fieldFlags;
            out.title = [NSString stringWithUTF8String:wo->title.bytes] ?: @"";
            out.offsetX = wo->offsetX;
            out.offsetY = wo->offsetY;
            out.windowWidth = wo->width;
            out.windowHeight = wo->height;
            out.show = wo->show;
            out.style = wo->style;
            out.styleEx = wo->styleEx;
            out.ownerWindowId = wo->ownerWindowId;
            out.numVisibilityRects = wo->numVisibilityRects;
            out.visibilityRectsTruncated = wo->visibilityRectsTruncated;
            if (wo->numVisibilityRects > 0)
            {
                const uint32_t stored =
                    (wo->numVisibilityRects > CRDPQ_MAX_VISIBILITY_RECTS) ? CRDPQ_MAX_VISIBILITY_RECTS
                                                                           : wo->numVisibilityRects;
                NSMutableArray<NSNumber *> *rects = [NSMutableArray arrayWithCapacity:stored * 4];
                for (uint32_t i = 0; i < stored; i++)
                {
                    [rects addObject:@(wo->visibilityRects[i].left)];
                    [rects addObject:@(wo->visibilityRects[i].top)];
                    [rects addObject:@(wo->visibilityRects[i].right)];
                    [rects addObject:@(wo->visibilityRects[i].bottom)];
                }
                out.visibilityRects = rects;
            }
            break;
        }
        case CRDPQ_EVENT_WINDOW_DELETE:
            out.kind = CRDPEventKindWindowDelete;
            out.windowId = ev->payload.windowId.windowId;
            break;
        case CRDPQ_EVENT_WINDOW_ICON:
            out.kind = CRDPEventKindWindowIcon;
            out.windowId = ev->payload.windowId.windowId;
            break;
        case CRDPQ_EVENT_NOTIFY_ICON_CREATE:
        case CRDPQ_EVENT_NOTIFY_ICON_UPDATE:
        case CRDPQ_EVENT_NOTIFY_ICON_DELETE:
            out.kind = (ev->type == CRDPQ_EVENT_NOTIFY_ICON_CREATE)   ? CRDPEventKindNotifyIconCreate
                       : (ev->type == CRDPQ_EVENT_NOTIFY_ICON_UPDATE) ? CRDPEventKindNotifyIconUpdate
                                                                       : CRDPEventKindNotifyIconDelete;
            out.windowId = ev->payload.notifyIcon.windowId;
            out.notifyIconId = ev->payload.notifyIcon.notifyIconId;
            break;
        case CRDPQ_EVENT_MONITORED_DESKTOP:
        {
            out.kind = CRDPEventKindMonitoredDesktop;
            const crdpq_monitored_desktop_t *md = &ev->payload.monitoredDesktop;
            out.fieldFlags = md->fieldFlags;
            out.windowId = md->activeWindowId;
            out.numWindowIds = md->numWindowIds;
            out.windowIdsTruncated = md->windowIdsTruncated;
            if (md->numWindowIds > 0)
            {
                const uint32_t stored =
                    (md->numWindowIds > CRDPQ_MAX_WINDOW_IDS) ? CRDPQ_MAX_WINDOW_IDS : md->numWindowIds;
                NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:stored];
                for (uint32_t i = 0; i < stored; i++)
                    [ids addObject:@(md->windowIds[i])];
                out.windowIds = ids;
            }
            break;
        }
        case CRDPQ_EVENT_EXEC_RESULT:
            out.kind = CRDPEventKindExecResult;
            out.execResult = ev->payload.execResult.execResult;
            out.rawResult = ev->payload.execResult.rawResult;
            out.program = [NSString stringWithUTF8String:ev->payload.execResult.exeOrFile.bytes] ?: @"";
            break;
        case CRDPQ_EVENT_HANDSHAKE_FLAGS:
            out.kind = CRDPEventKindHandshakeFlags;
            out.buildNumber = ev->payload.handshakeFlags.buildNumber;
            out.railHandshakeFlags = ev->payload.handshakeFlags.railHandshakeFlags;
            break;
        case CRDPQ_EVENT_SURFACE_MAPPED:
            out.kind = CRDPEventKindSurfaceMapped;
            out.surfaceId = ev->payload.surfaceMapped.surfaceId;
            out.mappedWindowId = ev->payload.surfaceMapped.windowId;
            out.mappedWidth = ev->payload.surfaceMapped.mappedWidth;
            out.mappedHeight = ev->payload.surfaceMapped.mappedHeight;
            break;
        case CRDPQ_EVENT_DISCONNECTED:
            out.kind = CRDPEventKindDisconnected;
            break;
        case CRDPQ_EVENT_FRAME_READY:
            out.kind = CRDPEventKindFrameReady;
            out.surfaceId = ev->payload.frameReady.surfaceId;
            break;
        case CRDPQ_EVENT_LOCAL_MOVE_SIZE:
            out.kind = CRDPEventKindLocalMoveSize;
            out.windowId = ev->payload.localMoveSize.windowId;
            out.isMoveSizeStart = ev->payload.localMoveSize.isMoveSizeStart;
            out.moveSizeType = ev->payload.localMoveSize.moveSizeType;
            out.moveSizePosX = ev->payload.localMoveSize.posX;
            out.moveSizePosY = ev->payload.localMoveSize.posY;
            break;
        case CRDPQ_EVENT_MIN_MAX_INFO:
            out.kind = CRDPEventKindMinMaxInfo;
            out.windowId = ev->payload.minMaxInfo.windowId;
            out.maxWidth = ev->payload.minMaxInfo.maxWidth;
            out.maxHeight = ev->payload.minMaxInfo.maxHeight;
            out.maxPosX = ev->payload.minMaxInfo.maxPosX;
            out.maxPosY = ev->payload.minMaxInfo.maxPosY;
            out.minTrackWidth = ev->payload.minMaxInfo.minTrackWidth;
            out.minTrackHeight = ev->payload.minMaxInfo.minTrackHeight;
            out.maxTrackWidth = ev->payload.minMaxInfo.maxTrackWidth;
            out.maxTrackHeight = ev->payload.minMaxInfo.maxTrackHeight;
            break;
        case CRDPQ_EVENT_ZORDER_SYNC:
            out.kind = CRDPEventKindZOrderSync;
            out.windowId = ev->payload.zorderSync.windowIdMarker;
            break;
        default:
            /* Landing here defensively for any future addition to crdpq_event_type_t this
             * file doesn't yet know about, rather than crashing. Previously fabricated a
             * fake CRDPEventKindWindowCreate(windowId=0) here (W4a review M7) —
             * indistinguishable from a real event to any caller, silently corrupting event
             * counts/tallies. Return nil instead; the caller counts and skips it. */
            return nil;
    }
    return out;
}

/* ==================================================================================== *
 * CRBridgeContext -- the C struct FreeRDP allocates/casts (rdpClientContext-derived, per
 * FreeRDP's own convention -- rdpClientContext's first member is itself an embedded
 * rdpContext, so a CRBridgeContext*, an rdpClientContext*, and an rdpContext* to the same
 * object all share the same address; every FreeRDP callback below relies on that). Never
 * exposed past this file.
 * ==================================================================================== */

typedef struct
{
    /* MUST be first member. */
    rdpClientContext common;

    void *bridgeSelf; /* __bridge void*, back to the owning CRSession -- see CRSession's
                        * class extension below for the ownership/lifetime argument. */

    RailClientContext *rail;
    pcRailServerHandshake orig_ServerHandshake;
    pcRailServerHandshakeEx orig_ServerHandshakeEx;

    pcRdpgfxMapSurfaceToWindow orig_MapSurfaceToWindow;
    pcRdpgfxMapSurfaceToScaledWindow orig_MapSurfaceToScaledWindow;
    pcRdpgfxResetGraphics orig_ResetGraphics;
    /* W4b: saved/forwarded exactly like the three above, even though neither is expected
     * to carry a real prior value in practice (gdi_graphics_pipeline_init's plain,
     * non-`_ex` variant this file relies on -- see crb_on_channel_connected's own comment
     * -- doesn't take UpdateWindowFromSurface as a parameter at all, and MapWindowForSurface/
     * UnmapWindowForSurface/UpdateSurfaceArea are the trio `_init_ex` exists specifically to
     * let a caller override, which this file doesn't call). Saved anyway, on the same
     * "never assume a NULL prior value" discipline as the rest of this struct. */
    pcRdpgfxUpdateWindowFromSurface orig_UpdateWindowFromSurface;
    pcRdpgfxUnmapWindowForSurface orig_UnmapWindowForSurface;
} CRBridgeContext;

/* Only the RDPGFX wrappers need this: gdi_graphics_pipeline_init() claims
 * RdpgfxClientContext::custom for its own rdpGdi*, so our context can't ride through
 * there (same constraint rail-probe.c documents on its own g_probe). One CRSession
 * connects at a time from any given process in W4a's scope (Tools/bridge-smoke and the
 * app's own minimal drain each own exactly one), so a global is an acceptable, explicitly
 * scoped simplification here -- NOT a general multi-session assumption for later phases.
 * W4a review L2: this plain global is written from T_dvc's ChannelConnected/
 * ChannelDisconnected callbacks, which is only race-free because those two events for a
 * *given* RDPGFX channel instance are themselves serialized (one connects, that same
 * instance later disconnects, never two live instances at once) -- not because the
 * pointer write itself is atomic. Rather than papering over a hypothetical concurrent-
 * write race with `_Atomic` (which wouldn't be the real fix if the single-session
 * assumption were ever actually violated), crb_on_channel_connected's RDPGFX branch
 * below asserts the invariant this comment already documents: g_crbGfxContext must be
 * NULL when a new one claims it. If that assertion ever fires, the single-session
 * assumption itself has been violated and needs revisiting, not just this variable's
 * type. */
static CRBridgeContext *g_crbGfxContext = NULL;

/* ==================================================================================== *
 * CRSession
 * ==================================================================================== */

typedef NS_ENUM(NSInteger, CRSessionState) {
    CRSessionStateIdle,
    CRSessionStateConnecting,
    CRSessionStateConnected,
    CRSessionStateDraining,
};

@interface CRSession ()
{
@public
    /* @public: the static C callback functions below (window vtable, RAIL/GFX handlers,
     * the T_rdp thread proc) reach these directly via `(__bridge CRSession *)ctx->bridgeSelf`
     * -- see the ownership note on CRBridgeContext::bridgeSelf. Never exposed outside this
     * file; CRSession.h stays pure Objective-C either way. */
    crdpq_control_t *_controlQueue;   /* created once in -init; persists across reconnects */
    crdpq_outbound_t *_outboundQueue; /* recreated every connection cycle */
    /* W4b: also created once in -init and persist across reconnects, exactly like
     * _controlQueue -- crdpq_frames_t has no generation concept of its own to make stale
     * (crsurface_table_write/crdpq_frame_publish are always called together, stamped with
     * whatever _controlQueue->currentGeneration was at that moment; a consumer comparing
     * that stamped value against -currentGeneration, same as any control-lane event, is
     * what actually rejects a stale frame -- see -copyPublishedSurface:). _surfaceSlots
     * DOES own live resources (IOSurface buffers) that must not survive a reconnect
     * unmodified, so -shutdownAndWait explicitly calls crsurface_table_clear on it (see
     * that method's own comment) even though the table object itself isn't recreated. */
    crdpq_frames_t *_framesQueue;
    CRSurfaceSlotTable *_surfaceSlots;
    /* Manual-reset (W4a review H2) -- WinPR's POSIX event backend on this platform never
     * actually implements auto-reset (winpr/libwinpr/synch/event.c:279-280 logs "auto-reset
     * events not yet implemented" and creates a plain, never-auto-cleared event regardless
     * of the bManualReset argument, confirmed by that exact warning appearing in this
     * project's own logs when this was still created auto-reset). An event that silently
     * doesn't auto-reset, combined with code that assumes it does, is a real lost/duplicated-
     * wakeup hazard, not just a naming mismatch -- creating it explicitly manual-reset,
     * paired with an explicit ResetEvent() immediately before every drain in
     * crb_rdp_thread_main's loop (see that function's comment), makes the actual behavior
     * match what the code assumes, on this platform as built today. */
    HANDLE _outboundWakeupEvent;
    freerdp *_instance;
    pthread_t _rdpThread;
    BOOL _rdpThreadJoinable;
    atomic_ullong _staleEventsDiscardedCount;
    atomic_ullong _unknownEventCount;
    atomic_ullong _outboundDroppedNoRailCount; /* W4a review M3: crb_outbound_visitor
                                                 * increments this (and WLog_WARNs) instead
                                                 * of silently swallowing a command when RAIL
                                                 * isn't connected yet. */
    CRSessionState _state;
}
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *user;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *program;
/* Deliberately NOT nonatomic (W4a review M5): written from T_rdp
 * (crb_rdp_thread_main's connect-failure path) and read from T_main (a caller polling
 * after -start), with no other synchronization between those two accesses. A plain
 * `nonatomic` NSObject-typed property has no cross-thread publication guarantee -- the
 * pointer swap itself isn't guaranteed visible to another thread without one. Objective-C
 * `atomic` property synthesis (the default, this project just makes it explicit here)
 * uses a lock internally around the generated getter/setter, which is exactly the "or
 * internal lock" the review offered as the alternative -- cheap enough for a
 * once-per-connect-attempt property that it isn't worth hand-rolling. */
@property (nullable) NSError *lastConnectError;
@end

/* ------------------------------------------------------------------------------------ */
/* Small accessors: CRBridgeContext* -> the owning CRSession's queues. Every FreeRDP      */
/* callback below goes through these rather than touching `bridgeSelf` directly, so the   */
/* __bridge cast lives in exactly one place.                                              */
/* ------------------------------------------------------------------------------------ */

static CRSession *crb_session(CRBridgeContext *p)
{
    return (__bridge CRSession *)p->bridgeSelf;
}

static crdpq_control_t *crb_control(CRBridgeContext *p)
{
    return crb_session(p)->_controlQueue;
}

static crdpq_frames_t *crb_frames(CRBridgeContext *p)
{
    return crb_session(p)->_framesQueue;
}

static CRSurfaceSlotTable *crb_surface_slots(CRBridgeContext *p)
{
    return crb_session(p)->_surfaceSlots;
}

/* ==================================================================================== *
 * Window order vtable (context->update->window->*), T_rdp. No default implementation
 * exists upstream for these -- our handler *is* the whole handler. Wiring mirrors
 * Tools/rail-probe/rail-probe.c's probe_window_* functions exactly (down to the
 * WINDOW_ORDER_STATE_NEW test for create-vs-update), translated to crdpq_post instead of
 * JSONL logging.
 * ==================================================================================== */

static BOOL crb_window_common(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                               const WINDOW_STATE_ORDER *windowState)
{
    CRBridgeContext *p = (CRBridgeContext *)context;

    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    const bool isNew = (orderInfo->fieldFlags & WINDOW_ORDER_STATE_NEW) != 0;
    ev.type = isNew ? CRDPQ_EVENT_WINDOW_CREATE : CRDPQ_EVENT_WINDOW_UPDATE;
    ev.payload.windowOrder.windowId = orderInfo->windowId;
    ev.payload.windowOrder.fieldFlags = orderInfo->fieldFlags;
    ev.payload.windowOrder.offsetX = windowState->windowOffsetX;
    ev.payload.windowOrder.offsetY = windowState->windowOffsetY;
    /* windowWidth/windowHeight are UINT32 on the wire (window.c's own parser reads them
     * via Stream_Read_UINT32, unlike the signed Stream_Read_INT32 used for the offsets
     * above) -- the same fact MacdowsCore's W2 fix batch established for the Swift-side
     * WindowOrderPayload (see RailEvent.swift). crdpq_window_order_t's width/height fields
     * were still declared int32_t through W4a, requiring a narrowing cast through uint32_t
     * here; the int32_t->uint32_t migration (crdpq.h + this assignment site + CRSession.h's
     * CRDPEvent properties + every downstream consumer + tests) landed as a dedicated pass,
     * so this is now a direct, unsigned-to-unsigned assignment -- DONE, not deferred. */
    ev.payload.windowOrder.width = windowState->windowWidth;
    ev.payload.windowOrder.height = windowState->windowHeight;
    ev.payload.windowOrder.style = windowState->style;
    ev.payload.windowOrder.styleEx = windowState->extendedStyle;
    ev.payload.windowOrder.show = windowState->showState;
    /* adr/0008 §3: bit-gated, NOT unconditional like style/styleEx/show above. Sample
     * evidence (adr/0008 §0) is explicit that the OWNER bit is set on every WindowCreate
     * but absent on every WindowUpdate in six real captures -- an unconditional copy here
     * would zero out the already-known owner on every single WindowUpdate a real session
     * ever sees, not just a theoretical edge case. `ev.payload` was already
     * memset-to-zero above, so the else case (bit absent) is simply "leave it at 0",
     * matching this transport layer's existing convention for every other conditional
     * sub-field on this struct. */
    if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_OWNER)
        ev.payload.windowOrder.ownerWindowId = windowState->ownerWindowId;

    /* adr/0008 §2b: the visibilityRects array's existence (not just its length) is gated
     * on WINDOW_ORDER_FIELD_VISIBILITY (0x0200) -- same discipline as the OWNER bit above,
     * and confirmed against FreeRDP's own parser (window.c's update_read_window_state_order
     * only touches numVisibilityRects/visibilityRects inside that bit's `if`, leaving both
     * at WINPR_C_ARRAY_INIT's zero default otherwise). `numVisibilityRects` stores the WIRE
     * value even when truncated (crdpq.h's own doc comment on this field explains why);
     * `crdpq_dropped_count`-style shape for the truncation warning, per adr/0008 §4. */
    if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_VISIBILITY)
    {
        ev.payload.windowOrder.numVisibilityRects = windowState->numVisibilityRects;
        const uint32_t toCopy = (windowState->numVisibilityRects > CRDPQ_MAX_VISIBILITY_RECTS)
                                     ? CRDPQ_MAX_VISIBILITY_RECTS
                                     : windowState->numVisibilityRects;
        ev.payload.windowOrder.visibilityRectsTruncated =
            (windowState->numVisibilityRects > CRDPQ_MAX_VISIBILITY_RECTS);
        for (uint32_t i = 0; i < toCopy; i++)
        {
            ev.payload.windowOrder.visibilityRects[i].left = windowState->visibilityRects[i].left;
            ev.payload.windowOrder.visibilityRects[i].top = windowState->visibilityRects[i].top;
            ev.payload.windowOrder.visibilityRects[i].right = windowState->visibilityRects[i].right;
            ev.payload.windowOrder.visibilityRects[i].bottom = windowState->visibilityRects[i].bottom;
        }
        if (ev.payload.windowOrder.visibilityRectsTruncated)
        {
            WLog_WARN(TAG,
                      "WindowOrder windowId=%" PRIu32 ": visibilityRects truncated (%" PRIu32
                      " > %d) -- adr/0008 §4 fail-open applies (degrade to full window rect, "
                      "never fabricate a smaller one)",
                      orderInfo->windowId, windowState->numVisibilityRects, CRDPQ_MAX_VISIBILITY_RECTS);
        }
    }

    if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_TITLE)
    {
        char *title = rail_string_to_utf8_string(&windowState->titleInfo);
        if (title)
        {
            crdpq_text_set(&ev.payload.windowOrder.title, title, strlen(title));
            free(title);
        }
    }

    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_window_delete(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo)
{
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_WINDOW_DELETE;
    ev.payload.windowId.windowId = orderInfo->windowId;
    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_window_icon(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                             const WINDOW_ICON_ORDER *windowIcon)
{
    (void)windowIcon;
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_WINDOW_ICON;
    ev.payload.windowId.windowId = orderInfo->windowId;
    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_window_cached_icon(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                                    const WINDOW_CACHED_ICON_ORDER *windowCachedIcon)
{
    /* crdpq_event_type_t curates a single CRDPQ_EVENT_WINDOW_ICON case for both
     * WindowIcon and WindowCachedIcon (unlike MacdowsCore's Swift-side RailEventKind,
     * which keeps them distinct) -- both just mean "this window has/updated an icon" at
     * this transport layer; the distinction isn't consumed anywhere downstream yet. */
    (void)windowCachedIcon;
    return crb_window_icon(context, orderInfo, NULL);
}

static BOOL crb_notify_icon_create(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                                    const NOTIFY_ICON_STATE_ORDER *notifyIconState)
{
    (void)notifyIconState;
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_NOTIFY_ICON_CREATE;
    ev.payload.notifyIcon.windowId = orderInfo->windowId;
    ev.payload.notifyIcon.notifyIconId = orderInfo->notifyIconId;
    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_notify_icon_update(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                                    const NOTIFY_ICON_STATE_ORDER *notifyIconState)
{
    (void)notifyIconState;
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_NOTIFY_ICON_UPDATE;
    ev.payload.notifyIcon.windowId = orderInfo->windowId;
    ev.payload.notifyIcon.notifyIconId = orderInfo->notifyIconId;
    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_notify_icon_delete(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo)
{
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_NOTIFY_ICON_DELETE;
    ev.payload.notifyIcon.windowId = orderInfo->windowId;
    ev.payload.notifyIcon.notifyIconId = orderInfo->notifyIconId;
    crdpq_post(crb_control(p), &ev);
    return TRUE;
}

static BOOL crb_monitored_desktop(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo,
                                   const MONITORED_DESKTOP_ORDER *monitoredDesktop)
{
    CRBridgeContext *p = (CRBridgeContext *)context;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_MONITORED_DESKTOP;
    ev.payload.monitoredDesktop.fieldFlags = orderInfo->fieldFlags;
    /* activeWindowId is 0xFFFFFFFF ("no active window") in the large majority of samples
     * (adr/0008 §0) -- passed through unchanged, sentinel and all; interpreting it is the
     * consumer's job (adr/0008 §0/§6), not this transport layer's. */
    ev.payload.monitoredDesktop.activeWindowId = monitoredDesktop->activeWindowId;
    ev.payload.monitoredDesktop.numWindowIds = monitoredDesktop->numWindowIds;
    /* adr/0008 §2a: the windowIds array's existence (not just its length) is gated on
     * WINDOW_ORDER_FIELD_DESKTOP_ZORDER (0x10) -- confirmed both by sample evidence (§0:
     * every numWindowIds>0 record carries this bit, every numWindowIds==0 record doesn't)
     * and by FreeRDP's own parser (window.c's update_read_desktop_actively_monitored_order
     * only touches numWindowIds/windowIds inside that bit's `if`, leaving both at
     * WINPR_C_ARRAY_INIT's zero default otherwise). */
    if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER)
    {
        const uint32_t toCopy = (monitoredDesktop->numWindowIds > CRDPQ_MAX_WINDOW_IDS)
                                     ? CRDPQ_MAX_WINDOW_IDS
                                     : monitoredDesktop->numWindowIds;
        ev.payload.monitoredDesktop.windowIdsTruncated =
            (monitoredDesktop->numWindowIds > CRDPQ_MAX_WINDOW_IDS);
        for (uint32_t i = 0; i < toCopy; i++)
            ev.payload.monitoredDesktop.windowIds[i] = monitoredDesktop->windowIds[i];
        if (ev.payload.monitoredDesktop.windowIdsTruncated)
        {
            WLog_WARN(TAG,
                      "MonitoredDesktop: windowIds truncated (%" PRIu32 " > %d) -- adr/0008 §4 "
                      "fail-open applies (leave out-of-array windows' relative order untouched, "
                      "never infer they belong at the bottom)",
                      monitoredDesktop->numWindowIds, CRDPQ_MAX_WINDOW_IDS);
        }
    }
    crdpq_post(crb_control(p), &ev);

    /* Mirrors xf_rail_monitored_desktop()/rail-probe.c's probe_monitored_desktop(): once
     * the remote desktop composition has finished (ARC_COMPLETED), send
     * ClientInformation/ClientSystemParam/ClientExecute for the configured RemoteApp
     * program. Without this call the remote program never actually launches. */
    if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && p->rail)
    {
        client_rail_server_start_cmd(p->rail);
    }
    return TRUE;
}

static BOOL crb_non_monitored_desktop(rdpContext *context, const WINDOW_ORDER_INFO *orderInfo)
{
    /* No crdpq_event_type_t case models "composition lost" -- out of scope for W4a's
     * event-stream+generation-protocol goal (see the CRSession.mm header comment). */
    (void)context;
    (void)orderInfo;
    WLog_INFO(TAG, "NonMonitoredDesktop (not posted -- no crdpq event type for this yet)");
    return TRUE;
}

/* ==================================================================================== *
 * RAIL channel Server* handlers, T_rdp. ServerHandshake/ServerHandshakeEx have a real
 * upstream default (wired by the rail channel plugin at load time) that must be
 * forwarded to; ServerExecuteResult/ServerLocalMoveSize/ServerMinMaxInfo/ServerZOrderSync
 * have none (client/rail.h carries no "a default implementation exists" doc comment for
 * any of the three, unlike ServerHandshake/ServerHandshakeEx above -- same no-forwarding
 * shape as ServerExecuteResult already had). adr/0008 §1 wires the three of these that were
 * previously left unwired ("no curated crdpq event type exists for any of them yet").
 * ServerSystemParam/ServerGetAppIdResponse remain intentionally unwired -- still no curated
 * crdpq event type for either, and neither is part of adr/0008's scope (§6: "仍不接线").
 * ==================================================================================== */

static UINT crb_rail_server_handshake(RailClientContext *context, const RAIL_HANDSHAKE_ORDER *handshake)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_HANDSHAKE_FLAGS;
    ev.payload.handshakeFlags.buildNumber = handshake->buildNumber;
    crdpq_post(crb_control(p), &ev);
    if (p->orig_ServerHandshake)
        return p->orig_ServerHandshake(context, handshake);
    return CHANNEL_RC_OK;
}

static UINT crb_rail_server_handshake_ex(RailClientContext *context,
                                          const RAIL_HANDSHAKE_EX_ORDER *handshakeEx)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_HANDSHAKE_FLAGS;
    ev.payload.handshakeFlags.buildNumber = handshakeEx->buildNumber;
    ev.payload.handshakeFlags.railHandshakeFlags = handshakeEx->railHandshakeFlags;
    crdpq_post(crb_control(p), &ev);
    if (p->orig_ServerHandshakeEx)
        return p->orig_ServerHandshakeEx(context, handshakeEx);
    return CHANNEL_RC_OK;
}

static UINT crb_rail_server_execute_result(RailClientContext *context,
                                            const RAIL_EXEC_RESULT_ORDER *execResult)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_EXEC_RESULT;
    ev.payload.execResult.flags = execResult->flags;
    ev.payload.execResult.execResult = execResult->execResult;
    ev.payload.execResult.rawResult = execResult->rawResult;
    char *exe = rail_string_to_utf8_string(&execResult->exeOrFile);
    if (exe)
    {
        crdpq_text_set(&ev.payload.execResult.exeOrFile, exe, strlen(exe));
        free(exe);
    }
    crdpq_post(crb_control(p), &ev);
    return CHANNEL_RC_OK;
}

/* adr/0008 §0's caveat: ServerLocalMoveSize was NEVER observed in any of the six
 * samples/phase05-rail-events-2026-08-19 captures (the probe never dragged/resized a
 * window) -- this handler's shape is verified only against client/rail.h and MS-RDPERP,
 * not real wire bytes. W3's first live LocalMoveSize is a verification event for this
 * struct, not an already-proven assumption. */
static UINT crb_rail_server_local_move_size(RailClientContext *context,
                                             const RAIL_LOCALMOVESIZE_ORDER *localMoveSize)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_LOCAL_MOVE_SIZE;
    ev.payload.localMoveSize.windowId = localMoveSize->windowId;
    /* isMoveSizeStart is upstream BOOL (a typedef for int) -- normalize to a real bool with
     * `!= 0` per adr/0008 §1; never memcpy/assign the raw int bit pattern into this bool
     * field. */
    ev.payload.localMoveSize.isMoveSizeStart = (localMoveSize->isMoveSizeStart != 0);
    ev.payload.localMoveSize.moveSizeType = localMoveSize->moveSizeType;
    ev.payload.localMoveSize.posX = localMoveSize->posX;
    ev.payload.localMoveSize.posY = localMoveSize->posY;
    crdpq_post(crb_control(p), &ev);
    return CHANNEL_RC_OK;
}

static UINT crb_rail_server_min_max_info(RailClientContext *context,
                                          const RAIL_MINMAXINFO_ORDER *minMaxInfo)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_MIN_MAX_INFO;
    ev.payload.minMaxInfo.windowId = minMaxInfo->windowId;
    ev.payload.minMaxInfo.maxWidth = minMaxInfo->maxWidth;
    ev.payload.minMaxInfo.maxHeight = minMaxInfo->maxHeight;
    ev.payload.minMaxInfo.maxPosX = minMaxInfo->maxPosX;
    ev.payload.minMaxInfo.maxPosY = minMaxInfo->maxPosY;
    ev.payload.minMaxInfo.minTrackWidth = minMaxInfo->minTrackWidth;
    ev.payload.minMaxInfo.minTrackHeight = minMaxInfo->minTrackHeight;
    ev.payload.minMaxInfo.maxTrackWidth = minMaxInfo->maxTrackWidth;
    ev.payload.minMaxInfo.maxTrackHeight = minMaxInfo->maxTrackHeight;
    crdpq_post(crb_control(p), &ev);
    return CHANNEL_RC_OK;
}

/* adr/0008 §1: despite the name, RAIL_ZORDER_SYNC carries no Z-order array -- just a
 * boundary marker. The ordered array a consumer actually wants lives on the most recent
 * CRDPQ_EVENT_MONITORED_DESKTOP's windowIds (§2a), not here. */
static UINT crb_rail_server_zorder_sync(RailClientContext *context, const RAIL_ZORDER_SYNC *zorderSync)
{
    CRBridgeContext *p = (CRBridgeContext *)context->custom;
    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_ZORDER_SYNC;
    ev.payload.zorderSync.windowIdMarker = zorderSync->windowIdMarker;
    crdpq_post(crb_control(p), &ev);
    return CHANNEL_RC_OK;
}

/* ==================================================================================== *
 * RDPGFX wrapped callbacks, T_dvc. gdi_graphics_pipeline_init() (invoked via
 * freerdp_client_OnChannelConnectedEventHandler) installs real gdi_MapSurfaceToWindow/
 * gdi_MapSurfaceToScaledWindow/gdi_ResetGraphics handlers *and* claims
 * RdpgfxClientContext::custom for its own rdpGdi* -- we save those function pointers,
 * install our wrapper, and forward to the saved original; we must NOT touch ::custom
 * (adr/0005 §2: "no conflict exists over RdpgfxClientContext::custom -- i.e. our
 * rdpContext-derived struct").
 * W4a: MapSurfaceToWindow posts SURFACE_MAPPED (the only GFX event this phase curates a
 * type for); MapSurfaceToScaledWindow/ResetGraphics are forwarded but not posted (no
 * crdpq event type covers either yet -- adr/0005 §7 explicitly flags
 * MapSurfaceToScaledWindow as "not yet observed, add a scaling branch if it appears").
 * No pixel data is ever touched here -- that's W4b's UpdateWindowFromSurface job.
 * ==================================================================================== */

static UINT crb_gfx_map_surface_to_window(RdpgfxClientContext *context,
                                           const RDPGFX_MAP_SURFACE_TO_WINDOW_PDU *pdu)
{
    /* T_dvc (W4a review M4): this is a thread FreeRDP owns entirely, not one this file's
     * own loop drives -- wrapping each callback entry point individually (rather than
     * "per iteration" the way crb_rdp_thread_main does for T_rdp) is the right
     * granularity, and is defensive against any future addition here that does create
     * autoreleased objects, even though the current body doesn't. */
    @autoreleasepool
    {
        CRBridgeContext *p = g_crbGfxContext;
        if (p)
        {
            /* W4b: SurfaceSlot creation rides on this callback -- the actual wire-level
             * "a surface got mapped to a window" notification -- rather than the
             * internal-to-gdi_graphics_pipeline_init `MapWindowForSurface` hook adr/0005
             * §2's prose loosely names; see CRSurfaceSlots.h's own comment and
             * crb_on_channel_connected's comment for the full reasoning. */
            crsurface_table_map(crb_surface_slots(p), pdu->surfaceId, pdu->windowId);

            CrdpEvent ev;
            memset(&ev, 0, sizeof(ev));
            ev.type = CRDPQ_EVENT_SURFACE_MAPPED;
            ev.payload.surfaceMapped.surfaceId = pdu->surfaceId;
            ev.payload.surfaceMapped.windowId = pdu->windowId;
            ev.payload.surfaceMapped.mappedWidth = pdu->mappedWidth;
            ev.payload.surfaceMapped.mappedHeight = pdu->mappedHeight;
            crdpq_post(crb_control(p), &ev);
        }
        if (p && p->orig_MapSurfaceToWindow)
            return p->orig_MapSurfaceToWindow(context, pdu);
        return CHANNEL_RC_OK;
    }
}

static UINT crb_gfx_map_surface_to_scaled_window(RdpgfxClientContext *context,
                                                  const RDPGFX_MAP_SURFACE_TO_SCALED_WINDOW_PDU *pdu)
{
    @autoreleasepool
    {
        CRBridgeContext *p = g_crbGfxContext;
        /* Observed in practice after all (2026-08-21, real Win11 25H2 host): the server
         * uses the scaled variant whenever the client's GFX caps don't carry
         * AVC_DISABLED (e.g. H264-enabled builds). Treated identically to the plain
         * variant for mapping purposes: mappedWidth/Height name the surface sub-rect the
         * window shows (RemoteWindow crops its layer to it); targetWidth/Height (the
         * display-scale hint) is logged but not yet applied -- the NSWindow's own frame
         * already defines the on-screen size, and to date target has only ever been the
         * 64-aligned allocation size. Revisit if a target != window-rect case appears. */
        if (p)
        {
            WLog_INFO(TAG,
                      "GfxMapSurfaceToScaledWindow surfaceId=%" PRIu32 " windowId=%" PRIu64
                      " mapped=%" PRIu32 "x%" PRIu32 " target=%" PRIu32 "x%" PRIu32,
                      pdu->surfaceId, pdu->windowId, pdu->mappedWidth, pdu->mappedHeight,
                      pdu->targetWidth, pdu->targetHeight);
            crsurface_table_map(crb_surface_slots(p), pdu->surfaceId, pdu->windowId);

            CrdpEvent ev;
            memset(&ev, 0, sizeof(ev));
            ev.type = CRDPQ_EVENT_SURFACE_MAPPED;
            ev.payload.surfaceMapped.surfaceId = pdu->surfaceId;
            ev.payload.surfaceMapped.windowId = pdu->windowId;
            ev.payload.surfaceMapped.mappedWidth = pdu->mappedWidth;
            ev.payload.surfaceMapped.mappedHeight = pdu->mappedHeight;
            crdpq_post(crb_control(p), &ev);
        }
        if (p && p->orig_MapSurfaceToScaledWindow)
            return p->orig_MapSurfaceToScaledWindow(context, pdu);
        return CHANNEL_RC_OK;
    }
}

static UINT crb_gfx_reset_graphics(RdpgfxClientContext *context, const RDPGFX_RESET_GRAPHICS_PDU *pdu)
{
    @autoreleasepool
    {
        CRBridgeContext *p = g_crbGfxContext;
        WLog_INFO(TAG, "GfxResetGraphics %" PRIu32 "x%" PRIu32, pdu->width, pdu->height);
        if (p && p->orig_ResetGraphics)
            return p->orig_ResetGraphics(context, pdu);
        return CHANNEL_RC_OK;
    }
}

/* ==================================================================================== *
 * W4b frame pathway: gfx->UpdateWindowFromSurface / gfx->UnmapWindowForSurface, installed
 * post-hoc after gdi_graphics_pipeline_init runs (same "override after the fact" approach
 * client/X11 takes, per adr/0005 §2), T_dvc. UpdateSurfaceArea is deliberately left
 * untouched -- installing a handler for it degrades merge granularity to per-command
 * (adr/0005 §2's own explicit warning).
 * ==================================================================================== */

static UINT crb_gfx_update_window_from_surface(RdpgfxClientContext *context, gdiGfxSurface *surface)
{
    /* adr/0005 §2: "the copy must finish inside the callback -- never expose
     * surface->data... to AppKit" -- every
     * byte of this function runs synchronously inside FreeRDP's mux critical section, on
     * T_dvc, and returns before touching anything AppKit-visible. No autoreleasepool here
     * deliberately: this path allocates no Objective-C objects at all (crsurface_table_write
     * is a plain C++ call), unlike the other GFX wrappers in this file that do construct
     * NSStrings/etc. -- adding one would just be an unused-but-harmless no-op, so it's
     * omitted rather than copy-pasted out of habit.
     */
    CRBridgeContext *p = g_crbGfxContext;
    if (p && surface && surface->data && surface->width > 0 && surface->height > 0)
    {
        /* adr/0005 §2 / W4b task spec: "is the gdi surface BGRA? measure surface->format
         * empirically and convert or assert". Empirically measured against a real host (W4b verification run):
         * surface->format is PIXEL_FORMAT_BGRX32 (0x20040888 -- FREERDP_PIXEL_FORMAT(32,
         * BGRA-type, a=0, r=8, g=8, b=8)), not PIXEL_FORMAT_BGRA32 (a=8) as first assumed --
         * RAIL/RemoteApp window content is inherently opaque, so the decoder producing
         * this surface reasonably emits a real-alpha-free BGRX buffer. Byte-for-byte, this
         * is IDENTICAL memory layout to BGRA32/ARGB32/XRGB32 on this little-endian
         * platform (B,G,R,{ignored-or-real 4th byte}); CRSurfaceSlots.h's write() always
         * treats the source as packed 32bpp regardless, so no actual conversion is needed
         * for any of these four -- only a genuinely different bit depth or channel order
         * (16bpp, planar, etc.) would require one, and none has ever been observed here.
         * RemoteWindow.swift additionally sets contentLayer.isOpaque = true so this format
         * family's "ignored" 4th byte can never be misread as a real (possibly
         * fully-transparent) alpha value by CoreAnimation regardless of its actual stored
         * value. Anything outside this four-format family is still logged loudly once
         * rather than silently miscoloring or crashing -- adr/0005's own allowance:
         * "record it faithfully and accept 'it renders on screen but the defect is noted' as
         * an acceptable outcome". */
        if (surface->format != PIXEL_FORMAT_BGRA32 && surface->format != PIXEL_FORMAT_BGRX32 &&
            surface->format != PIXEL_FORMAT_XRGB32 && surface->format != PIXEL_FORMAT_ARGB32)
        {
            static BOOL warnedBadFormat = FALSE;
            if (!warnedBadFormat)
            {
                warnedBadFormat = TRUE;
                WLog_WARN(TAG,
                          "GfxUpdateWindowFromSurface: surface->format=0x%08" PRIX32
                          " is not BGRA32/BGRX32/XRGB32/ARGB32 -- copying raw bytes as packed "
                          "BGRA32 anyway; colors may be wrong (W4b known-risk item, see report)",
                          surface->format);
            }
        }

        /* M5 (W4b review): read the generation counter directly through the C API rather
         * than via `session.currentGeneration` -- the ObjC property getter compiles to an
         * objc_msgSend, a dynamic dispatch this must-be-fast, T_dvc/mux-critical-section
         * path has no reason to pay for when crb_control(p) already gets to the same
         * crdpq_control_t* through a plain bridged-pointer ivar read (see crb_control's own
         * definition). Functionally identical -- -[CRSession currentGeneration] does
         * exactly this call internally. */
        const uint32_t generation = crdpq_current_generation(crb_control(p));

        /* Translate REGION16's RECTANGLE_16 rects into CRSurfaceSlots.h's own CRSurfaceRect
         * -- kept as a distinct type (rather than reusing RECTANGLE_16 directly) so that
         * header never has to #include a FreeRDP header, mirroring crdpq.h's own
         * dependency boundary. Bounded stack buffer, no allocation on this must-be-fast
         * path; a surface with a pathologically fragmented invalidRegion (more than 64
         * disjoint rects) just falls back to a full-frame copy, which is always correct
         * regardless (see CRSurfaceSlots.mm's own comment on crsurface_table_write). */
        enum
        {
            kMaxStackRects = 64
        };
        CRSurfaceRect stackRects[kMaxStackRects];
        const CRSurfaceRect *rectsToPass = NULL;
        uint32_t rectCountToPass = 0;

        UINT32 nbRects = 0;
        const RECTANGLE_16 *wireRects = region16_rects(&surface->invalidRegion, &nbRects);
        if (nbRects > 0 && nbRects <= kMaxStackRects)
        {
            for (UINT32 i = 0; i < nbRects; i++)
            {
                stackRects[i].left = wireRects[i].left;
                stackRects[i].top = wireRects[i].top;
                stackRects[i].right = wireRects[i].right;
                stackRects[i].bottom = wireRects[i].bottom;
            }
            rectsToPass = stackRects;
            rectCountToPass = nbRects;
        }
        /* else: rectCountToPass stays 0 -> crsurface_table_write does a full-frame copy. */

        crsurface_table_write(crb_surface_slots(p), surface->surfaceId, surface->data, surface->width,
                               surface->height, surface->scanline, generation, rectsToPass, rectCountToPass);

        /* ROOT CAUSE FIX (regedit white-block bug): gdi/gfx.c's own gdi_UpdateSurfaces
         * dispatches per-surface to one of two paths depending on outputMapped vs
         * windowMapped (gfx.c:292-295). The outputMapped path (gdi_OutputUpdate,
         * gfx.c:174-250) clears surface->invalidRegion itself once it's done consuming it
         * (gfx.c:248). The windowMapped path we're actually on (gdi_WindowUpdate,
         * gfx.c:252-257) does nothing but forward to context->UpdateWindowFromSurface --
         * it hands the *entire* responsibility for consuming (and clearing)
         * invalidRegion to the callback, exactly the way gdi_OutputUpdate handles its own.
         * This file never did that: invalidRegion only ever grew (every codec/command
         * handler unions new dirty rects into it via region16_union_rect, with nothing
         * upstream of here ever clearing it for a windowMapped surface), so beyond the
         * first few frames it stopped meaningfully representing "what changed since this
         * was last consumed" -- confirmed empirically (W4b regedit bug hunt): a live
         * surface's invalidRegion reported the exact same rect count and extents across
         * 5+ real, several-seconds-apart updates. Clearing it here, immediately after
         * crsurface_table_write has copied everything it currently describes, is what
         * gdi_OutputUpdate's own contract already implies a windowMapped consumer must do. */
        region16_clear(&surface->invalidRegion);

        /* Frame lane (state, last-writer-wins) plus the lightweight control-lane doorbell
         * so a consumer draining window orders in FIFO order also observes frame-readiness
         * without separately polling crdpq_frames every cycle -- crdpq.h's own documented
         * purpose for CRDPQ_EVENT_FRAME_READY. */
        crdpq_frame_publish(crb_frames(p), surface->surfaceId, generation);

        CrdpEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = CRDPQ_EVENT_FRAME_READY;
        ev.payload.frameReady.surfaceId = surface->surfaceId;
        crdpq_post(crb_control(p), &ev);
    }

    if (p && p->orig_UpdateWindowFromSurface)
        return p->orig_UpdateWindowFromSurface(context, surface);
    return CHANNEL_RC_OK;
}

static UINT crb_gfx_unmap_window_for_surface(RdpgfxClientContext *context, UINT64 windowId)
{
    @autoreleasepool
    {
        CRBridgeContext *p = g_crbGfxContext;
        if (p)
        {
            crsurface_table_unmap_window(crb_surface_slots(p), windowId);
        }
        if (p && p->orig_UnmapWindowForSurface)
            return p->orig_UnmapWindowForSurface(context, windowId);
        return CHANNEL_RC_OK;
    }
}

/* ==================================================================================== */

static void crb_on_channel_connected(void *context, const ChannelConnectedEventArgs *e)
{
    CRBridgeContext *p = (CRBridgeContext *)context;

    if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
    {
        RailClientContext *rail = (RailClientContext *)e->pInterface;
        p->rail = rail;
        rail->custom = p;

        rdpWindowUpdate *window = p->common.context.update->window;
        window->WindowCreate = crb_window_common;
        window->WindowUpdate = crb_window_common;
        window->WindowDelete = crb_window_delete;
        window->WindowIcon = crb_window_icon;
        window->WindowCachedIcon = crb_window_cached_icon;
        window->NotifyIconCreate = crb_notify_icon_create;
        window->NotifyIconUpdate = crb_notify_icon_update;
        window->NotifyIconDelete = crb_notify_icon_delete;
        window->MonitoredDesktop = crb_monitored_desktop;
        window->NonMonitoredDesktop = crb_non_monitored_desktop;

        p->orig_ServerHandshake = rail->ServerHandshake;
        p->orig_ServerHandshakeEx = rail->ServerHandshakeEx;
        rail->ServerHandshake = crb_rail_server_handshake;
        rail->ServerHandshakeEx = crb_rail_server_handshake_ex;
        rail->ServerExecuteResult = crb_rail_server_execute_result;
        /* adr/0008 §1: previously-unwired callbacks -- see this file's own comment above
         * crb_rail_server_local_move_size for why none of the three need an orig_* saved
         * pointer (no upstream default exists for any of them, same shape as
         * ServerExecuteResult just above). */
        rail->ServerLocalMoveSize = crb_rail_server_local_move_size;
        rail->ServerMinMaxInfo = crb_rail_server_min_max_info;
        rail->ServerZOrderSync = crb_rail_server_zorder_sync;
    }
    else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
    {
        /* Installs gdi_MapSurfaceToWindow/gdi_MapSurfaceToScaledWindow/gdi_ResetGraphics
         * and (since DeactivateClientDecoding is FALSE per adr/0005 §2) the real
         * gdi_SurfaceCommand/gdi_UpdateSurfaces decode path too, even though W4a never
         * calls into it. */
        freerdp_client_OnChannelConnectedEventHandler(&p->common, e);

        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;

        /* adr/0005 §2's startup invariant: a silent upstream change that nulls these
         * (gfx.c:2052-2057, triggered by DeactivateClientDecoding=TRUE) means "black
         * window, zero errors" -- assert loudly instead. */
        WINPR_ASSERT(gfx->SurfaceCommand != NULL);
        WINPR_ASSERT(gfx->UpdateSurfaces != NULL);

        /* L2: enforce the single-session assumption g_crbGfxContext's own comment
         * documents, rather than silently letting a second live session clobber the
         * first's pointer. */
        WINPR_ASSERT(g_crbGfxContext == NULL);
        g_crbGfxContext = p;
        p->orig_MapSurfaceToWindow = gfx->MapSurfaceToWindow;
        p->orig_MapSurfaceToScaledWindow = gfx->MapSurfaceToScaledWindow;
        p->orig_ResetGraphics = gfx->ResetGraphics;
        gfx->MapSurfaceToWindow = crb_gfx_map_surface_to_window;
        gfx->MapSurfaceToScaledWindow = crb_gfx_map_surface_to_scaled_window;
        gfx->ResetGraphics = crb_gfx_reset_graphics;

        /* W4b: adr/0005 §2's frame pathway -- "override UpdateWindowFromSurface /
         * UnmapWindowForSurface after gdi init" (X11-client style post-hoc override, not
         * gdi_graphics_pipeline_init_ex's at-init-time parameters -- see this file's own
         * comment above crb_gfx_update_window_from_surface). UpdateSurfaceArea is
         * deliberately never touched. */
        p->orig_UpdateWindowFromSurface = gfx->UpdateWindowFromSurface;
        p->orig_UnmapWindowForSurface = gfx->UnmapWindowForSurface;
        gfx->UpdateWindowFromSurface = crb_gfx_update_window_from_surface;
        gfx->UnmapWindowForSurface = crb_gfx_unmap_window_for_surface;
    }
    else
    {
        freerdp_client_OnChannelConnectedEventHandler(&p->common, e);
    }
}

static void crb_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    CRBridgeContext *p = (CRBridgeContext *)context;

    if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
    {
        if (p->rail)
            p->rail->custom = NULL;
        p->rail = NULL;
    }
    else
    {
        if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0 && g_crbGfxContext == p)
            g_crbGfxContext = NULL;
        freerdp_client_OnChannelDisconnectedEventHandler(&p->common, e);
    }
}

/* ==================================================================================== *
 * Certificate / logon callbacks
 * ==================================================================================== */

/* W4a review H3: real certificate-pin UX (a Phase 1 follow-on ADR) doesn't exist yet.
 * Accepting every certificate unconditionally in the meantime is a real security hole if
 * it ever leaked into a non-Debug build, so it's gated on CRB_ALLOW_INSECURE_CERT --
 * defined only for the Debug configuration (App/project.yml's CRBridge target). Without
 * it (Release, or any config that doesn't define it), every certificate is rejected
 * outright: a loud, immediate connection failure instead of a silent insecure accept. */
static DWORD crb_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                        const char *common_name, const char *subject,
                                        const char *issuer, const char *fingerprint, DWORD flags)
{
    (void)instance;
    (void)flags;
#if CRB_ALLOW_INSECURE_CERT
    WLog_WARN(TAG,
              "VerifyCertificateEx: INSECURE ACCEPT (CRB_ALLOW_INSECURE_CERT) host=%s:%u "
              "commonName=%s subject=%s issuer=%s fingerprint=%s",
              host, (unsigned)port, common_name ? common_name : "", subject ? subject : "",
              issuer ? issuer : "", fingerprint ? fingerprint : "");
    /* Accept unconditionally, for this session only -- never touches an on-disk
     * known-hosts store. */
    return 2;
#else
    (void)host;
    (void)port;
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)fingerprint;
    WLog_ERR(TAG, "VerifyCertificateEx: REJECTED -- certificate pin UX not implemented yet "
                  "(CRB_ALLOW_INSECURE_CERT not defined in this build configuration)");
    return 0;
#endif
}

static int crb_logon_error_info(freerdp *instance, UINT32 data, UINT32 type)
{
    (void)instance;
    const char *sd = freerdp_get_logon_error_info_data(data);
    const char *st = freerdp_get_logon_error_info_type(type);
    WLog_INFO(TAG, "LogonErrorInfo data=%s type=%s", sd ? sd : "", st ? st : "");
    return 1;
}

/* ==================================================================================== *
 * No-op GDI update callbacks -- W4a is headless (no pixel path), but gdi_init still needs
 * to run for gdi_graphics_pipeline_init to have anything to hang off ::custom later, and
 * the update vtable requires *something* here or FreeRDP's own default no-ops would be
 * silently skipped for a subtly different reason. Mirrors rail-probe.c exactly.
 * ==================================================================================== */

static BOOL crb_begin_paint(rdpContext *context)
{
    (void)context;
    return TRUE;
}

static BOOL crb_end_paint(rdpContext *context)
{
    (void)context;
    return TRUE;
}

static BOOL crb_play_sound(rdpContext *context, const PLAY_SOUND_UPDATE *play_sound)
{
    (void)context;
    (void)play_sound;
    return TRUE;
}

static BOOL crb_desktop_resize(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    rdpSettings *settings = context->settings;
    return gdi_resize(gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                       freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

static BOOL crb_keyboard_set_indicators(rdpContext *context, UINT16 led_flags)
{
    (void)context;
    (void)led_flags;
    return TRUE;
}

static BOOL crb_keyboard_set_ime_status(rdpContext *context, UINT16 imeId, UINT32 imeState,
                                         UINT32 imeConvMode)
{
    (void)context;
    (void)imeId;
    (void)imeState;
    (void)imeConvMode;
    return TRUE;
}

/* ==================================================================================== *
 * Connect lifecycle
 * ==================================================================================== */

static BOOL crb_pre_connect(freerdp *instance)
{
    CRBridgeContext *p = (CRBridgeContext *)instance->context;
    CRSession *session = crb_session(p);
    rdpSettings *settings = instance->context->settings;

    /* ServerHostname/Username/Password are deliberately NOT set here -- they're set once,
     * directly on context->settings, right after freerdp_client_context_new() and before
     * freerdp_client_start(), in -[CRSession start]. Mirrors
     * Tools/rail-probe/rail-probe.c's main() exactly (it sets these in main(), not inside
     * probe_pre_connect either) -- no functional requirement forces this split, it's just
     * kept consistent with the wiring reference. */

    if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE))
        return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_UNIX))
        return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_NATIVE_XSERVER))
        return FALSE;

    if (!freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, TRUE))
        return FALSE;
    /* Remote desktop sized to the caller's screen (see CRSession.h's desktopWidth doc:
     * the RAIL server clamps window positions to this desktop, so leaving FreeRDP's
     * 1024x768 default put an un-drag-past-able wall at a 2560pt display's midpoint). */
    if (session.desktopWidth > 0 && session.desktopHeight > 0)
    {
        if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, session.desktopWidth) ||
            !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, session.desktopHeight))
            return FALSE;
    }
    if (!freerdp_settings_set_string(settings, FreeRDP_RemoteApplicationProgram, session.program.UTF8String))
        return FALSE;
    if (!freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE))
        return FALSE;
    /* adr/0005 §2/task spec: HiDef on by default. */
    if (!freerdp_settings_set_bool(settings, FreeRDP_HiDefRemoteApp, TRUE))
        return FALSE;
    /* adr/0005 §2: must be FALSE (the library default -- set explicitly here so this
     * invariant is self-documenting rather than relying on an unstated default). */
    if (!freerdp_settings_set_bool(settings, FreeRDP_DeactivateClientDecoding, FALSE))
        return FALSE;
    if (!freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE))
        return FALSE;

    if (PubSub_SubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected) < 0)
        return FALSE;
    if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, crb_on_channel_disconnected) < 0)
        return FALSE;

    return TRUE;
}

static BOOL crb_post_connect(freerdp *instance)
{
    if (!gdi_init(instance, PIXEL_FORMAT_XRGB32))
        return FALSE;

    rdpContext *context = instance->context;
    context->update->BeginPaint = crb_begin_paint;
    context->update->EndPaint = crb_end_paint;
    context->update->PlaySound = crb_play_sound;
    context->update->DesktopResize = crb_desktop_resize;
    context->update->SetKeyboardIndicators = crb_keyboard_set_indicators;
    context->update->SetKeyboardImeStatus = crb_keyboard_set_ime_status;
    return TRUE;
}

static void crb_post_disconnect(freerdp *instance)
{
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, crb_on_channel_connected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, crb_on_channel_disconnected);
    gdi_free(instance);
}

static void crb_post_final_disconnect(freerdp *instance)
{
    (void)instance;
}

static BOOL crb_client_new(freerdp *instance, rdpContext *context)
{
    if (!instance || !context)
        return FALSE;
    instance->PreConnect = crb_pre_connect;
    instance->PostConnect = crb_post_connect;
    instance->PostDisconnect = crb_post_disconnect;
    instance->PostFinalDisconnect = crb_post_final_disconnect;
    instance->LogonErrorInfo = crb_logon_error_info;
    instance->VerifyCertificateEx = crb_verify_certificate_ex;
    return TRUE;
}

static void crb_client_free(freerdp *instance, rdpContext *context)
{
    (void)instance;
    (void)context;
}

static int crb_client_start(rdpContext *context)
{
    (void)context;
    return 0;
}

static int crb_client_stop(rdpContext *context)
{
    (void)context;
    return 0;
}

static BOOL crb_global_init(void)
{
    /* Matches Tools/rail-probe/rail-probe.c's probe_global_init exactly -- diagnostic
     * experiment for a real-host NLA failure (SEC_E_NO_CREDENTIALS) that reproduces with
     * every other setting/thread-structure/signing difference already ruled out. */
    return freerdp_handle_signals() == 0;
}

static void crb_global_uninit(void)
{
}

/* ==================================================================================== *
 * Outbound command lane, T_rdp: drained at the top of every main-loop iteration
 * (adr/0005 §3's "the reverse command queue is drained by T_rdp at the top of every
 * freerdp_check_event_handles round").
 * ==================================================================================== */

static void crb_outbound_wakeup(void *ctx)
{
    HANDLE ev = (HANDLE)ctx;
    if (ev)
        SetEvent(ev);
}

static void crb_outbound_visitor(const CrdpCommand *cmd, void *vctx)
{
    /* vctx is the CRBridgeContext* (W4a review M2/M3), not a cached RailClientContext* --
     * read p->rail fresh on every single invocation rather than once per drain call
     * (still less than once per loop iteration, which was the prior design's actual
     * staleness window): a mid-session RAIL channel disconnect/reconnect could otherwise
     * leave a cached pointer pointing at a torn-down context. */
    CRBridgeContext *p = (CRBridgeContext *)vctx;
    RailClientContext *rail = p ? p->rail : NULL;
    if (!rail)
    {
        /* M3: don't silently swallow -- count and log. A whole batch arriving before RAIL
         * has connected (e.g. very early ClientExecute calls) drops every command in it,
         * which is real, visible data loss; W4b should consider buffering/replaying
         * instead once there's a registry to make that safe against staleness. */
        CRSession *session = p ? crb_session(p) : nil;
        if (session)
        {
            unsigned long long dropped = atomic_fetch_add(&session->_outboundDroppedNoRailCount, 1ULL) + 1;
            WLog_WARN(TAG,
                      "outbound command type=%d dropped -- RAIL channel not connected yet "
                      "(dropped so far: %llu)",
                      (int)cmd->type, dropped);
        }
        return;
    }

    switch (cmd->type)
    {
        case CRDPQ_CMD_EXECUTE:
        {
            RAIL_EXEC_ORDER exec;
            memset(&exec, 0, sizeof(exec));
            /* L3: don't cast away const on cmd->payload.execute.program.bytes -- copy to a
             * stack buffer instead, so RAIL_EXEC_ORDER::RemoteApplicationProgram (upstream's
             * non-const char*) can never, even in principle, end up mutating the CrdpCommand
             * this visitor was only handed a const pointer to. */
            char programBuf[CRDPQ_TEXT_BUF_SIZE];
            memcpy(programBuf, cmd->payload.execute.program.bytes, sizeof(programBuf));
            exec.RemoteApplicationProgram = programBuf;
            if (rail->ClientExecute)
                rail->ClientExecute(rail, &exec);
            break;
        }
        case CRDPQ_CMD_ACTIVATE:
        {
            RAIL_ACTIVATE_ORDER activate;
            memset(&activate, 0, sizeof(activate));
            activate.windowId = cmd->payload.activate.windowId;
            activate.enabled = cmd->payload.activate.enabled;
            if (rail->ClientActivate)
                rail->ClientActivate(rail, &activate);
            break;
        }
        case CRDPQ_CMD_WINDOW_MOVE:
        {
            RAIL_WINDOW_MOVE_ORDER move;
            memset(&move, 0, sizeof(move));
            move.windowId = cmd->payload.windowMove.windowId;
            move.left = (INT16)cmd->payload.windowMove.left;
            move.top = (INT16)cmd->payload.windowMove.top;
            move.right = (INT16)cmd->payload.windowMove.right;
            move.bottom = (INT16)cmd->payload.windowMove.bottom;
            if (rail->ClientWindowMove)
                rail->ClientWindowMove(rail, &move);
            break;
        }
        case CRDPQ_CMD_SYS_COMMAND:
        {
            RAIL_SYSCOMMAND_ORDER sc;
            memset(&sc, 0, sizeof(sc));
            sc.windowId = cmd->payload.sysCommand.windowId;
            sc.command = cmd->payload.sysCommand.command;
            if (rail->ClientSystemCommand)
                rail->ClientSystemCommand(rail, &sc);
            break;
        }
        case CRDPQ_CMD_INPUT:
        {
            rdpContext *context = (rdpContext *)rail->custom;
            if (!context || !context->input)
                break;
            if (cmd->payload.input.kind == CRDPQ_INPUT_KEYBOARD)
            {
                freerdp_input_send_keyboard_event(context->input, cmd->payload.input.flags,
                                                   (UINT8)cmd->payload.input.code);
            }
            else
            {
                freerdp_input_send_mouse_event(context->input, cmd->payload.input.flags,
                                                (UINT16)cmd->payload.input.x,
                                                (UINT16)cmd->payload.input.y);
            }
            break;
        }
        default:
            break;
    }
}

/* ==================================================================================== *
 * T_rdp: the main loop. Mirrors Tools/rail-probe/rail-probe.c's probe_main_loop(), plus
 * the outbound-drain-at-top-of-loop and wakeup-handle-merge adr/0005 §3 calls for.
 * ==================================================================================== */

typedef struct
{
    void *session; /* a __bridge_retained CRSession* (via CFBridgingRetain), released at
                     * the very end of crb_rdp_thread_main via __bridge_transfer, so the
                     * CRSession this pthread is working for cannot be deallocated out
                     * from under it, independent of what happens to the caller's own
                     * reference. Typed void* (not CRSession*) so this plain C struct
                     * never needs ARC to manage it -- the retain/release is entirely
                     * manual, bracketing the raw pointer's lifetime across the thread. */
} CRBThreadArgs;

/* T_rdp: connects (blocking, on this thread -- never the caller's) and then runs the
 * post-connect event loop until told to stop. */
static void *crb_rdp_thread_main(void *arg)
{
    CRBThreadArgs *args = (CRBThreadArgs *)arg;
    CRSession *session = (__bridge_transfer CRSession *)args->session;
    free(args);

    freerdp *instance = session->_instance;

    if (!freerdp_connect(instance))
    {
        UINT32 code = freerdp_get_last_error(instance->context);
        const char *codeString = freerdp_get_last_error_string(code);
        NSString *desc = [NSString stringWithFormat:@"freerdp_connect failed: %s (0x%08X)",
                                                      codeString ? codeString : "?", code];
        session.lastConnectError = [NSError errorWithDomain:@"Macdows.CRSession"
                                                         code:(NSInteger)code
                                                     userInfo:@{NSLocalizedDescriptionKey : desc}];
        freerdp_disconnect(instance);

        /* H1 (W4a review): post DISCONNECTED even on a connect *failure*, not just a
         * clean-connect-then-later-disconnect. Without this, -shutdownAndWait's step-4
         * poll loop (waiting up to 100 * 50ms = 5s for the sentinel) never sees it and
         * always burns the full timeout before falling through to the pthread_join safety
         * net -- a real, measured ~5.7s stall, and -shutdownAndWait's return value
         * (cleanShutdown) reports NO even though nothing is actually stuck; there was
         * simply never going to be a sentinel to observe. Posting it here for the
         * failure path too makes both symptoms disappear: shutdownAndWait returns in
         * well under 100ms, and its return value means what it says. */
        CrdpEvent failEv;
        memset(&failEv, 0, sizeof(failEv));
        failEv.type = CRDPQ_EVENT_DISCONNECTED;
        crdpq_post(session->_controlQueue, &failEv);

        return NULL;
    }

    while (!freerdp_shall_disconnect_context(instance->context))
    {
        @autoreleasepool /* M4: one inner pool per loop iteration, not one for the whole
                           * thread's lifetime -- autoreleased objects from a single
                           * iteration (NSString/NSError construction, etc.) get drained
                           * promptly instead of accumulating for the whole connection's
                           * duration on a thread with no runloop of its own to do it. */
        {
            HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
            DWORD nCount = freerdp_get_event_handles(instance->context, handles, ARRAYSIZE(handles) - 1);
            if (nCount == 0)
                break;
            handles[nCount++] = session->_outboundWakeupEvent;

            DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 200);
            if (status == WAIT_FAILED)
                break;

            /* H2: Reset before drain, unconditionally, every iteration -- not "only if
             * this handle was the one that woke us". WinPR's POSIX event backend on this
             * platform doesn't actually implement auto-reset at all
             * (winpr/libwinpr/synch/event.c:279-280 logs "auto-reset events not yet
             * implemented" and creates a plain event regardless of bManualReset; confirmed
             * live by that exact warning appearing when this event used to be created
             * auto-reset), so _outboundWakeupEvent is now created manual-reset
             * (CreateEvent(..., TRUE, ...) in -start) and this call is what actually clears
             * it. Ordering is the entire race-freedom argument: crdpq_outbound_post
             * (crdpq_outbound.c) always calls SetEvent strictly *after* the item is already
             * enqueued under its internal lock, and this Reset always happens strictly
             * *before* the drain call below that authoritatively empties the queue. Given
             * that ordering, there is no interleaving of a concurrent post() against this
             * Reset+drain pair that can leave an enqueued item both undrained *and*
             * unsignaled: either the post's enqueue+Set happens entirely before this
             * Reset (drain still picks the item up, and this Reset simply clears a flag
             * for work about to be re-collected anyway), or it happens concurrently with
             * or after this Reset but strictly before the drain call actually runs
             * (drain's own internal lock serializes with post's, so the item is fully
             * visible to this drain either way), or it happens strictly after this
             * iteration's drain call returns (in which case the Set that follows makes
             * the *next* WaitForMultipleObjects return immediately rather than sitting
             * out the 200ms timeout -- a spurious-looking but harmless extra wakeup, not
             * a lost one). */
            ResetEvent(session->_outboundWakeupEvent);

            /* Drain outbound at the top of every iteration, unconditionally -- regardless
             * of which handle (if any) actually signaled. A spurious/coincidental wakeup
             * still opportunistically drains real outbound work, which is harmless and
             * correct. vctx is the CRBridgeContext itself (M2) -- see
             * crb_outbound_visitor's own comment for why a cached RailClientContext* was
             * wrong. */
            crdpq_outbound_drain(session->_outboundQueue, crb_outbound_visitor, (void *)instance->context);

            if (status != WAIT_TIMEOUT)
            {
                if (!freerdp_check_event_handles(instance->context))
                {
                    if (freerdp_get_last_error(instance->context) == FREERDP_ERROR_SUCCESS)
                        break; /* clean shutdown request (freerdp_abort_connect_context) */
                    break;     /* protocol/transport error */
                }
            }
        }
    }

    freerdp_disconnect(instance);

    CrdpEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = CRDPQ_EVENT_DISCONNECTED;
    crdpq_post(session->_controlQueue, &ev);

    return NULL;
}

/* ==================================================================================== *
 * OpenSSL legacy-provider startup self-check.
 *
 * Real-host NLA/CredSSP authentication depends on MD4 (classic NTLM's NT-hash step,
 * which NTLMv2 responses still depend on), which lives in OpenSSL's legacy provider
 * (WinPR's winpr_openssl_initialize loads it specifically "needed for MD4" --
 * winpr/libwinpr/utils/ssl.c). Scripts/build-openssl.sh now builds that provider directly
 * into libcrypto (`no-module`, per providers/build.info's STATIC_LEGACY branch) rather
 * than as a separately loadable module, specifically so this can never again fail the way
 * it did during W4a's root-cause hunt: a placeholder-build-prefix relocation (an earlier,
 * legitimate W1 fix to keep $HOME out of shipped-binary constants) left the dynamic
 * module's MODULESDIR pointing nowhere, and OSSL_PROVIDER_load(NULL, "legacy") silently
 * found nothing -- manifesting many steps downstream as NLA failing with
 * SEC_E_NO_CREDENTIALS, a symptom with no obvious link back to its actual cause.
 *
 * This check exists so that IF a future build regresses (someone drops `no-module` from
 * build-openssl.sh, or links a differently-built OpenSSL), the failure is loud and
 * immediate -- rejected before ever attempting a real connection, with a message that
 * names the actual root cause -- rather than a real-host connection silently failing deep
 * inside CredSSP with an error code that gives no hint why. */
static BOOL crb_openssl_legacy_provider_available(void)
{
    if (OSSL_PROVIDER_available(NULL, "legacy"))
        return TRUE;
    /* Not loaded yet -- try loading it explicitly, mirroring what
     * winpr_openssl_initialize does internally. With `no-module`, this resolves the
     * built-in provider from an in-process table and never touches the filesystem. */
    OSSL_PROVIDER *p = OSSL_PROVIDER_load(NULL, "legacy");
    return p != NULL;
}

/* ==================================================================================== *
 * CRSession
 * ==================================================================================== */

@implementation CRSession

+ (void)logFreeRDPVersion
{
    const char *version = freerdp_get_version_string();
    NSLog(@"Macdows: linked against FreeRDP %s", version ? version : "(null)");
}

/* W4c review: push-style drain notification -- passed as crdpq_control_t's own
 * schedule_drain callback below, so it fires (coalesced, "at most once per drain cycle")
 * whenever a new control-lane event is posted, from whatever thread posted it (T_rdp, for
 * every real production caller of crdpq_post in this file). Always hops to the main queue
 * before touching -onEventsAvailable so callers of that property never have to think about
 * which thread this fires from -- exactly "hook schedule_drain to a dispatch_async(main)
 * initialization path", per this review round's own wording. `ctx` is `self`, bridged
 * without a retain: _controlQueue is created once in -init and destroyed only in -dealloc
 * (see the ivar's own comment), so its lifetime is a strict subset of self's -- this
 * callback can never fire with a dangling `ctx`. */
static void crb_schedule_drain(void *ctx)
{
    CRSession *session = (__bridge CRSession *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session.onEventsAvailable)
        {
            session.onEventsAvailable();
        }
    });
}

- (instancetype)initWithHost:(NSString *)host
                         user:(NSString *)user
                     password:(NSString *)password
                      program:(NSString *)program
{
    self = [super init];
    if (self)
    {
        _host = [host copy];
        _user = [user copy];
        _password = [password copy];
        _program = [program copy];
        _state = CRSessionStateIdle;
        atomic_init(&_staleEventsDiscardedCount, 0ULL);
        atomic_init(&_unknownEventCount, 0ULL);
        atomic_init(&_outboundDroppedNoRailCount, 0ULL);

        /* Persists across every reconnect this instance ever does -- adr/0005 §3/§4: the
         * generation counter this queue owns internally is the one and only thing a
         * reconnect bumps, never reset by recreating this queue. */
        _controlQueue = crdpq_control_create(crb_schedule_drain, (__bridge void *)self);
        /* W4b: also created once, persisting across reconnects -- see this class's ivar
         * block comment for why that's correct despite _surfaceSlots owning real
         * per-connection resources (crsurface_table_clear in -shutdownAndWait is what
         * actually tears those down each disconnect; the table object itself lives on). */
        _framesQueue = crdpq_frames_create(NULL, NULL);
        _surfaceSlots = crsurface_table_create();
    }
    return self;
}

- (void)dealloc
{
    /* L4: calling an instance method (which blocks, joins a thread, and mutates ivars)
     * from -dealloc is unusual enough to deserve an explicit safety argument rather than
     * just doing it. It's safe here specifically because: `self` is still a fully valid,
     * non-deallocated object for the entire duration of -dealloc's own body (ARC only
     * finishes tearing the object down *after* -dealloc returns) -- calling ordinary
     * instance methods on it, reading/writing its own ivars/properties, is unremarkable.
     * -shutdownAndWait doesn't retain `self` anywhere that would outlive this call (no
     * escaping block captures it strongly, no new strong reference gets stored anywhere),
     * so it can't resurrect an object mid-deallocation. The only real risk with a
     * dealloc-time method call is doing something that expects other parts of the object
     * graph (delegates, KVO observers, etc.) to still be wired up; -shutdownAndWait
     * touches only this instance's own C-level resources (crdpq_outbound_t, the WinPR
     * event handle, the FreeRDP context, the T_rdp pthread), none of which depend on
     * anything outside this object still being alive. */
    if (_state != CRSessionStateIdle)
    {
        [self shutdownAndWait];
        NSAssert(_state == CRSessionStateIdle, @"shutdownAndWait must always leave _state == Idle");
    }
    if (_controlQueue)
    {
        crdpq_control_destroy(_controlQueue);
        _controlQueue = NULL;
    }
    if (_surfaceSlots)
    {
        /* crsurface_table_destroy itself calls crsurface_table_clear first (see
         * CRSurfaceSlots.mm), so this correctly frees every buffer not currently leased
         * out even if -shutdownAndWait's own clear (above, via -shutdownAndWait having
         * already run) somehow didn't run first -- defensive, not required by any correct
         * call sequence, since -shutdownAndWait is guaranteed to have already run above. */
        crsurface_table_destroy(_surfaceSlots);
        _surfaceSlots = NULL;
    }
    if (_framesQueue)
    {
        crdpq_frames_destroy(_framesQueue);
        _framesQueue = NULL;
    }
}

- (void)start
{
    if (_state != CRSessionStateIdle)
    {
        NSLog(@"Macdows: -start called while not idle (state=%ld) -- ignored", (long)_state);
        return;
    }
    self.lastConnectError = nil;
    _state = CRSessionStateConnecting;

    if (!crb_openssl_legacy_provider_available())
    {
        self.lastConnectError = [NSError
            errorWithDomain:@"Macdows.CRSession"
                       code:-4
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"OpenSSL legacy provider unavailable (no MD4 -> NTLM/NLA authentication "
                           @"cannot work). Root cause is almost certainly Scripts/build-openssl.sh's "
                           @"OpenSSL Configure invocation losing its `no-module` flag, or a stale/"
                           @".build/deps/prefix built before that flag existed -- rebuild OpenSSL "
                           @"with `bash Scripts/build-openssl.sh --force` and then FreeRDP, and "
                           @"confirm .build/deps/prefix/lib/libcrypto.a contains legacy_md4.o "
                           @"before retrying."
                   }];
        _state = CRSessionStateIdle;
        return; /* nothing allocated yet at this point -- nothing to clean up */
    }

#if CRB_ALLOW_INSECURE_CERT
    /* H3: an explicit, unmissable startup warning every time a session starts with this
     * Debug-only escape hatch enabled -- not just the per-connection log line inside
     * crb_verify_certificate_ex itself, which someone scanning startup logs for "is this
     * build secure" could plausibly miss among everything else FreeRDP logs. */
    WLog_WARN(TAG, "CRB_ALLOW_INSECURE_CERT is defined -- this build accepts ANY TLS "
                   "certificate unconditionally. Debug-only; must never be defined for a "
                   "Release/distributed build (see App/project.yml's CRBridge target).");
#endif

    /* M1: every early-return below this point goes through `cleanup` so the outbound
     * queue/wakeup event (already created) and the FreeRDP context (once it exists)
     * always get torn down uniformly, regardless of which of the four failure points is
     * hit -- previously each of the four paths repeated (and, in three of the four
     * cases, forgot part of) this teardown by hand, leaking `_outboundQueue`/
     * `_outboundWakeupEvent` on every one of them. All locals `cleanup` might touch are
     * declared here, before any `goto`, since they're all plain C/POD types (a goto
     * skipping a declaration with non-trivial/ARC-managed initialization would be a
     * compile error; none of these are that). */
    rdpContext *context = NULL;
    CRBThreadArgs *args = NULL;

    _outboundWakeupEvent = CreateEvent(NULL, TRUE, FALSE, NULL); /* manual-reset -- see H2's
     * extensive comment on crb_rdp_thread_main's ResetEvent call for why. */
    _outboundQueue = crdpq_outbound_create(crb_outbound_wakeup, (void *)_outboundWakeupEvent);

    RDP_CLIENT_ENTRY_POINTS entryPoints;
    memset(&entryPoints, 0, sizeof(entryPoints));
    entryPoints.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
    entryPoints.GlobalInit = crb_global_init;
    entryPoints.GlobalUninit = crb_global_uninit;
    entryPoints.ContextSize = sizeof(CRBridgeContext);
    entryPoints.ClientNew = crb_client_new;
    entryPoints.ClientFree = crb_client_free;
    entryPoints.ClientStart = crb_client_start;
    entryPoints.ClientStop = crb_client_stop;

    context = freerdp_client_context_new(&entryPoints);
    if (!context)
    {
        self.lastConnectError = [NSError errorWithDomain:@"Macdows.CRSession"
                                                      code:-1
                                                  userInfo:@{
                                                      NSLocalizedDescriptionKey : @"freerdp_client_context_new failed"
                                                  }];
        goto cleanup;
    }

    ((CRBridgeContext *)context)->bridgeSelf = (__bridge void *)self;
    _instance = context->instance;

    /* Set directly here, before freerdp_client_start -- NOT inside PreConnect. Mirrors
     * Tools/rail-probe/rail-probe.c's main(), the wiring reference for this file. */
    if (!freerdp_settings_set_string(context->settings, FreeRDP_ServerHostname, self.host.UTF8String) ||
        !freerdp_settings_set_string(context->settings, FreeRDP_Username, self.user.UTF8String) ||
        !freerdp_settings_set_string(context->settings, FreeRDP_Password, self.password.UTF8String))
    {
        self.lastConnectError = [NSError errorWithDomain:@"Macdows.CRSession"
                                                      code:-3
                                                  userInfo:@{
                                                      NSLocalizedDescriptionKey : @"failed to apply host/user/password settings"
                                                  }];
        goto cleanup;
    }

    if (freerdp_client_start(context) != 0)
    {
        self.lastConnectError = [NSError errorWithDomain:@"Macdows.CRSession"
                                                      code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey : @"freerdp_client_start failed"}];
        goto cleanup;
    }

    /* T_rdp does the actual freerdp_connect (blocking on its own thread, never the
     * caller's) plus the whole post-connect event loop -- -start itself returns as soon
     * as the thread is spawned. Connection progress/failure surfaces asynchronously via
     * drained events and -lastConnectError, per CRSession.h's doc comment. */
    args = (CRBThreadArgs *)malloc(sizeof(CRBThreadArgs));
    args->session = (void *)CFBridgingRetain(self); /* __bridge_retained, paired with the
                                                       * __bridge_transfer release inside
                                                       * crb_rdp_thread_main */
    {
        int rc = pthread_create(&_rdpThread, NULL, crb_rdp_thread_main, args);
        if (rc != 0)
        {
            CFBridgingRelease(args->session);
            free(args);
            self.lastConnectError = [NSError errorWithDomain:@"Macdows.CRSession"
                                                          code:rc
                                                      userInfo:@{NSLocalizedDescriptionKey : @"pthread_create failed"}];
            goto cleanup;
        }
    }
    _rdpThreadJoinable = YES;
    _state = CRSessionStateConnected;
    return;

cleanup:
    if (context)
    {
        /* crb_client_stop/crb_client_start are both no-ops either way, so calling stop
         * here unconditionally (even on a path where start was never reached) is
         * harmless and keeps this one block correct for all three context-bearing
         * failure points instead of needing to track which of them actually reached
         * freerdp_client_start. freerdp_connect itself is never called on any of these
         * paths, so there's nothing to freerdp_disconnect from. */
        freerdp_client_stop(context);
        freerdp_client_context_free(context);
        _instance = NULL;
    }
    if (_outboundQueue)
    {
        crdpq_outbound_destroy(_outboundQueue);
        _outboundQueue = NULL;
    }
    if (_outboundWakeupEvent)
    {
        CloseHandle(_outboundWakeupEvent);
        _outboundWakeupEvent = NULL;
    }
    _state = CRSessionStateIdle;
}

- (BOOL)shutdownAndWait
{
    if (_state == CRSessionStateIdle)
        return YES;
    _state = CRSessionStateDraining;

    /* Step 1: reject new outbound, signal T_rdp. */
    if (_outboundQueue)
        crdpq_outbound_seal(_outboundQueue);
    if (_instance && _instance->context)
        freerdp_abort_connect_context(_instance->context);

    /* Step 4 (drain first, matching adr/0005 §4's literal ordering): poll for
     * DISCONNECTED with a bounded timeout -- pthread_join below is the real safety net,
     * this loop only exists to observe the sentinel and report a clean-vs-forced
     * shutdown, since W4a has no RemoteWindow registry to clean up yet. */
    __block BOOL sawDisconnected = NO;
    for (int i = 0; i < 100 && !sawDisconnected; i++)
    {
        [self drainEventsWithHandler:^(CRDPEvent *event) {
          if (event.kind == CRDPEventKindDisconnected)
              sawDisconnected = YES;
        }];
        if (!sawDisconnected)
            usleep(50 * 1000);
    }

    /* Step 5: join, free, bump generation. */
    if (_rdpThreadJoinable)
    {
        pthread_join(_rdpThread, NULL);
        _rdpThreadJoinable = NO;
    }
    if (_instance)
    {
        freerdp_client_context_free(_instance->context);
        _instance = NULL;
    }
    if (_outboundQueue)
    {
        crdpq_outbound_destroy(_outboundQueue);
        _outboundQueue = NULL;
    }
    if (_outboundWakeupEvent)
    {
        CloseHandle(_outboundWakeupEvent);
        _outboundWakeupEvent = NULL;
    }
    /* W4b, adr/0005 §2: "after disconnect the pool stops leasing; destroy once every lease
     * has been returned" -- T_dvc (the only writer
     * into _surfaceSlots) has definitely stopped by this point (pthread_join above already
     * returned), so there is no concurrent crsurface_table_write to race with. This frees
     * every buffer not currently leased out to T_main immediately; a buffer still leased
     * (an outstanding IOSurfaceRef some CALayer might still reference) is released
     * correctly whenever its eventual -recycleSurface: call arrives, exactly as
     * CRSurfaceSlots.h documents -- it does not need to happen before this call, and this
     * call does not block waiting for it. */
    if (_surfaceSlots)
        crsurface_table_clear(_surfaceSlots);
    crdpq_generation_bump(_controlQueue);
    _state = CRSessionStateIdle;
    return sawDisconnected;
}

- (NSUInteger)drainEventsWithHandler:(void (^)(CRDPEvent *event))handler
{
    if (!_controlQueue)
        return 0;

    __block NSUInteger delivered = 0;
    __block NSUInteger discarded = 0;
    __block NSUInteger unknown = 0;
    uint32_t expectedGeneration = crdpq_current_generation(_controlQueue);

    typedef struct
    {
        void (^handler)(CRDPEvent *event);
        uint32_t expectedGeneration;
        NSUInteger *delivered;
        NSUInteger *discarded;
        NSUInteger *unknown;
    } DrainCtx;
    DrainCtx dctx = {handler, expectedGeneration, &delivered, &discarded, &unknown};

    crdpq_drain(
        _controlQueue,
        [](const CrdpEvent *ev, void *vctx) {
          DrainCtx *dctx = (DrainCtx *)vctx;
          if (ev->generation != dctx->expectedGeneration)
          {
              (*dctx->discarded)++;
              return;
          }
          CRDPEvent *event = CRDPEventFromCrdpEvent(ev);
          if (!event)
          {
              (*dctx->unknown)++;
              return;
          }
          (*dctx->delivered)++;
          dctx->handler(event);
        },
        &dctx);

    if (discarded > 0)
        atomic_fetch_add(&_staleEventsDiscardedCount, (unsigned long long)discarded);
    if (unknown > 0)
        atomic_fetch_add(&_unknownEventCount, (unsigned long long)unknown);

    return delivered;
}

- (uint32_t)currentGeneration
{
    return _controlQueue ? crdpq_current_generation(_controlQueue) : 0;
}

- (uint64_t)staleEventsDiscardedCount
{
    return atomic_load(&_staleEventsDiscardedCount);
}

- (uint64_t)unknownEventCount
{
    return atomic_load(&_unknownEventCount);
}

- (uint64_t)droppedEventsCount
{
    return _controlQueue ? crdpq_dropped_count(_controlQueue) : 0;
}

- (nullable IOSurfaceRef)copyPublishedSurface:(uint32_t)surfaceId
{
    if (!_surfaceSlots)
        return NULL;

    uint32_t publishedGeneration = 0;
    IOSurfaceRef surface = crsurface_table_lease_published(_surfaceSlots, surfaceId, &publishedGeneration);
    if (!surface)
        return NULL;

    /* adr/0005 §4's generation protocol, applied to frames exactly as it is to control-lane
     * events (see this class's ivar block comment on _framesQueue/_surfaceSlots): a lease
     * whose publish predates the current connection generation is stale -- release it back
     * immediately (crsurface_table_release_lease, not a bare CFRelease, so pool bookkeeping
     * stays consistent) rather than handing it to a caller who'd display a dead
     * connection's last frame. */
    if (publishedGeneration != self.currentGeneration)
    {
        crsurface_table_release_lease(_surfaceSlots, surface);
        return NULL;
    }

    return surface;
}

- (void)recycleSurface:(IOSurfaceRef)surface
{
    if (!surface)
        return;
    if (!_surfaceSlots)
    {
        /* Table already torn down (-dealloc ran) -- still honor the +1-in contract rather
         * than leaking the caller's reference. */
        CFRelease(surface);
        return;
    }
    crsurface_table_release_lease(_surfaceSlots, surface);
}

- (void)activateWindow:(uint32_t)windowId
{
    if (!_outboundQueue)
        return;
    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_ACTIVATE;
    cmd.payload.activate.windowId = windowId;
    cmd.payload.activate.enabled = true;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

- (void)sendSysCommand:(uint32_t)windowId command:(uint16_t)command
{
    if (!_outboundQueue)
        return;
    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_SYS_COMMAND;
    cmd.payload.sysCommand.windowId = windowId;
    cmd.payload.sysCommand.command = command;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

- (void)sendWindowMove:(uint32_t)windowId left:(int32_t)left top:(int32_t)top right:(int32_t)right bottom:(int32_t)bottom
{
    if (!_outboundQueue)
        return;
    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_WINDOW_MOVE;
    cmd.payload.windowMove.windowId = windowId;
    cmd.payload.windowMove.left = left;
    cmd.payload.windowMove.top = top;
    cmd.payload.windowMove.right = right;
    cmd.payload.windowMove.bottom = bottom;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

- (void)executeProgram:(NSString *)program
{
    if (!_outboundQueue)
        return;
    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_EXECUTE;
    const char *utf8 = program.UTF8String;
    if (!utf8 || utf8[0] == '\0')
        return;
    crdpq_text_set(&cmd.payload.execute.program, utf8, strlen(utf8));
    /* A path that doesn't fit crdpq's 255-byte text buffer would exec a TRUNCATED (i.e.
     * different) path on the server, whose failure result nothing may be watching --
     * refuse loudly instead of silently launching the wrong thing (2026-08-22 review). */
    if (cmd.payload.execute.program.truncated)
    {
        WLog_WARN(TAG, "executeProgram: path exceeds %d bytes and would be truncated -- refusing to send",
                  CRDPQ_TEXT_BUF_SIZE - 1);
        return;
    }
    crdpq_outbound_post(_outboundQueue, &cmd);
}

/* ==================================================================================== *
 * W4c: mouse/keyboard input forwarding
 * ==================================================================================== */

- (void)sendMouseMoveToX:(int32_t)x y:(int32_t)y
{
    if (!_outboundQueue)
        return;
    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_INPUT;
    cmd.payload.input.kind = CRDPQ_INPUT_MOUSE;
    cmd.payload.input.flags = PTR_FLAGS_MOVE;
    cmd.payload.input.x = x;
    cmd.payload.input.y = y;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

- (void)sendMouseButton:(CRMouseButton)button down:(BOOL)down atX:(int32_t)x y:(int32_t)y
{
    if (!_outboundQueue)
        return;
    UINT16 flags = 0;
    switch (button)
    {
        case CRMouseButtonLeft:
            flags = PTR_FLAGS_BUTTON1;
            break;
        case CRMouseButtonRight:
            flags = PTR_FLAGS_BUTTON2;
            break;
        case CRMouseButtonMiddle:
            flags = PTR_FLAGS_BUTTON3;
            break;
        default:
            /* Extended/side buttons: documented W4c gap, see CRSession.h's CRMouseButton
             * doc comment -- nothing else constructs a CRMouseButton outside that enum, so
             * this default is unreachable in practice, not a real runtime input path. */
            return;
    }
    if (down)
        flags |= PTR_FLAGS_DOWN;

    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_INPUT;
    cmd.payload.input.kind = CRDPQ_INPUT_MOUSE;
    cmd.payload.input.flags = flags;
    cmd.payload.input.x = x;
    cmd.payload.input.y = y;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

/* MS-RDPBCGR's wheel-rotation encoding (also ThirdParty/FreeRDP/client/Mac/MRDPView.m's
 * -scrollWheel:) packs the notch count into the low 8 bits of `flags` as a 9-bit
 * two's-complement-style signed value together with PTR_FLAGS_WHEEL_NEGATIVE (bit 8): the
 * positive range 0x00-0xFF means slow-to-fast, and the negative range -- PTR_FLAGS_WHEEL_
 * NEGATIVE set, step replaced by (0x100 - step) -- means fast-to-slow, not a separate sign
 * bit sitting next to an unsigned magnitude. */
static UINT16 crb_wheel_step(double delta)
{
    double units = fabs(delta) * 120.0;
    if (units > 0xFF)
        units = 0xFF;
    return (UINT16)units;
}

- (void)sendMouseVerticalWheelDelta:(double)deltaY atX:(int32_t)x y:(int32_t)y
{
    /* W4c review L1: FLT_EPSILON, not a bare "== 0" -- matches
     * ThirdParty/FreeRDP/client/Mac/MRDPView.m's own -scrollWheel: (fabsf(dy) >
     * FLT_EPSILON). Redundant with the caller's own (also epsilon-based, since this fix)
     * branch selection in RemoteWindowRegistry.handleInput, but this method has no other
     * caller it can assume away -- a technically-nonzero-but-negligible delta reaching this
     * method directly should still be a no-op, not a wasted wheel event with a step that
     * rounds down to 0 anyway. */
    if (!_outboundQueue || fabs(deltaY) <= FLT_EPSILON)
        return;
    UINT16 step = crb_wheel_step(deltaY);
    UINT16 flags = PTR_FLAGS_WHEEL;
    if (deltaY < 0)
    {
        flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        step = (UINT16)(0x100 - step);
    }

    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_INPUT;
    cmd.payload.input.kind = CRDPQ_INPUT_MOUSE;
    cmd.payload.input.flags = (UINT16)(flags | (step & 0xFF));
    cmd.payload.input.x = x;
    cmd.payload.input.y = y;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

- (void)sendMouseHorizontalWheelDelta:(double)deltaX atX:(int32_t)x y:(int32_t)y
{
    /* W4c review L1: same FLT_EPSILON reasoning as -sendMouseVerticalWheelDelta:atX:y: above. */
    if (!_outboundQueue || fabs(deltaX) <= FLT_EPSILON)
        return;
    UINT16 step = crb_wheel_step(deltaX);
    UINT16 flags = PTR_FLAGS_HWHEEL;
    /* MRDPView.m's -scrollWheel: flags PTR_FLAGS_WHEEL_NEGATIVE for a *positive* deltaX on
     * the horizontal axis -- confirmed directly from its source, not a guess; the
     * horizontal axis's sign convention is inverted relative to the vertical one. */
    if (deltaX > 0)
    {
        flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        step = (UINT16)(0x100 - step);
    }

    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_INPUT;
    cmd.payload.input.kind = CRDPQ_INPUT_MOUSE;
    cmd.payload.input.flags = (UINT16)(flags | (step & 0xFF));
    cmd.payload.input.x = x;
    cmd.payload.input.y = y;
    crdpq_outbound_post(_outboundQueue, &cmd);
}

/* Shared by -sendKeyDown:/-sendKeyUp: -- the keyFlags argument is only KBD_FLAGS_DOWN or
 * KBD_FLAGS_RELEASE, everything else (translation, KBDEXT bit, posting) is identical, so
 * factoring this out is what MRDPView.m's own keyDown:/keyUp: (near-duplicate bodies) does
 * NOT do, but there is no reason to duplicate it here too. */
static void crb_send_key(crdpq_outbound_t *queue, uint16_t macKeyCode, DWORD keyFlags)
{
    if (!queue)
        return;
    DWORD vkcode = GetVirtualKeyCodeFromKeycode(macKeyCode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, 4);
    keyFlags |= (scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0;
    scancode &= 0xFF;

    CrdpCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type = CRDPQ_CMD_INPUT;
    cmd.payload.input.kind = CRDPQ_INPUT_KEYBOARD;
    cmd.payload.input.flags = (uint16_t)keyFlags;
    cmd.payload.input.code = (uint16_t)scancode;
    crdpq_outbound_post(queue, &cmd);
}

- (void)sendKeyDown:(uint16_t)macKeyCode
{
    crb_send_key(_outboundQueue, macKeyCode, KBD_FLAGS_DOWN);
}

- (void)sendKeyUp:(uint16_t)macKeyCode
{
    crb_send_key(_outboundQueue, macKeyCode, KBD_FLAGS_RELEASE);
}

- (void)sendModifierKey:(CRModifierKey)key down:(BOOL)down
{
    if (!_outboundQueue)
        return;

    /* Direct port of ThirdParty/FreeRDP/client/Mac/MRDPView.m's updateFlagState: hardcoded
     * RDP_SCANCODE_* per modifier, not routed through GetVirtualKeyCodeFromKeycode/
     * GetVirtualScanCodeFromVirtualKeyCode -- flagsChanged: doesn't carry a distinguishing
     * keyCode the same clean way keyDown:/keyUp: do, and the reference client avoids that
     * route for exactly this case. */
    DWORD scancode = 0;
    BOOL isToggle = NO; // CapsLock/NumLock: always send DOWN+RELEASE, matching updateFlagState.
    switch (key)
    {
        case CRModifierKeyCapsLock:
            scancode = RDP_SCANCODE_CAPSLOCK;
            isToggle = YES;
            break;
        case CRModifierKeyShift:
            scancode = RDP_SCANCODE_LSHIFT;
            break;
        case CRModifierKeyControl:
            scancode = RDP_SCANCODE_LCONTROL;
            break;
        case CRModifierKeyOption:
            scancode = RDP_SCANCODE_LMENU;
            break;
        case CRModifierKeyCommand:
            scancode = RDP_SCANCODE_LWIN;
            break;
        case CRModifierKeyNumericPad:
            scancode = RDP_SCANCODE_NUMLOCK;
            isToggle = YES;
            break;
        case CRModifierKeyHelp:
        case CRModifierKeyFunction:
            /* MRDPView.m:624-631: both NSEventModifierFlagHelp and NSEventModifierFlagFunction
             * map to the same RDP_SCANCODE_HELP -- not a toggle, matches the reference
             * implementation (neither case sets release = press = TRUE). */
            scancode = RDP_SCANCODE_HELP;
            break;
    }

    DWORD keyFlags = (scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0;
    scancode &= 0xFF;

    if (down || isToggle)
    {
        CrdpCommand cmd;
        memset(&cmd, 0, sizeof(cmd));
        cmd.type = CRDPQ_CMD_INPUT;
        cmd.payload.input.kind = CRDPQ_INPUT_KEYBOARD;
        cmd.payload.input.flags = (uint16_t)(keyFlags | KBD_FLAGS_DOWN);
        cmd.payload.input.code = (uint16_t)scancode;
        crdpq_outbound_post(_outboundQueue, &cmd);
    }
    if (!down || isToggle)
    {
        CrdpCommand cmd;
        memset(&cmd, 0, sizeof(cmd));
        cmd.type = CRDPQ_CMD_INPUT;
        cmd.payload.input.kind = CRDPQ_INPUT_KEYBOARD;
        cmd.payload.input.flags = (uint16_t)(keyFlags | KBD_FLAGS_RELEASE);
        cmd.payload.input.code = (uint16_t)scancode;
        crdpq_outbound_post(_outboundQueue, &cmd);
    }
}

@end
