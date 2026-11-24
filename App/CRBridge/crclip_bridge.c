/*
 * crclip_bridge.c -- see crclip_bridge.h for the contract. adr/0026 (S0, H-1 ... H-10) and the
 * adr/0005 addendum (T_clip) are the design this file implements; comments here say why a line is
 * the way it is, not what the ADR already says.
 *
 * Logging rule (adr/0026 S9, section 10): every line this file logs carries counts, byte counts,
 * format ids, generations, status words, mode numbers or the fixed channel name -- never clipboard
 * text, never a format name, never anything derived from content. That holds at every level:
 * WARN and above under a `com.` tag reach the diagnostic export unfiltered.
 */
#include "crclip_bridge.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/user.h>
#include <winpr/wlog.h>

#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>

/* The bridge's own tag, the same one CRSession.mm logs under (CLIENT_TAG("macdows")). */
static const char crclip_tag[] = "com.freerdp.client.macdows";

/* The registered format names a Windows program adds to say "keep this out of clipboard history /
 * cloud sync" (crdpq.h CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED, adr/0026 section 4.2). Protocol constants;
 * compared on T_clip only (crclip_name_equals_folded: ASCII case folded, as Windows compares
 * registered format names), never logged, never put into an event. */
static const char* const crclip_exclusion_names[] = {
    "ExcludeClipboardContentFromMonitorProcessing",
    "CanIncludeInClipboardHistory",
    "CanUploadToCloudClipboard",
    "Clipboard Viewer Ignore",
};

/* ==================================================================================== *
 * Counters
 * ==================================================================================== */

struct crclip_counters {
    _Atomic uint64_t values[CRCLIP_COUNTER_COUNT];
};

crclip_counters_t* crclip_counters_create(void)
{
    crclip_counters_t* counters = calloc(1, sizeof(crclip_counters_t));
    if (!counters)
        return NULL;
    for (size_t index = 0; index < CRCLIP_COUNTER_COUNT; index++)
        atomic_init(&counters->values[index], 0);
    return counters;
}

void crclip_counters_destroy(crclip_counters_t* counters)
{
    free(counters);
}

uint64_t crclip_counters_bump(crclip_counters_t* counters, crclip_counter_t counter)
{
    if (!counters || (int)counter < 0 || (int)counter >= (int)CRCLIP_COUNTER_COUNT)
        return 0;
    return atomic_fetch_add(&counters->values[counter], 1) + 1;
}

uint64_t crclip_counters_get(const crclip_counters_t* counters, crclip_counter_t counter)
{
    if (!counters || (int)counter < 0 || (int)counter >= (int)CRCLIP_COUNTER_COUNT)
        return 0;
    /* atomic_load takes a non-const pointer under C11; reading is still a read. */
    crclip_counters_t* readable = (crclip_counters_t*)counters;
    return atomic_load(&readable->values[counter]);
}

/* ==================================================================================== *
 * Modes and the connect path's settings step
 * ==================================================================================== */

static bool crclip_mode_is_known(uint32_t mode)
{
    return mode <= CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY;
}

UINT32 crclip_mode_feature_mask(uint32_t mode)
{
    switch (mode)
    {
        case CRCLIP_MODE_BIDIRECTIONAL:
            return CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL;
        case CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY:
            return CLIPRDR_FLAG_REMOTE_TO_LOCAL;
        case CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY:
            return CLIPRDR_FLAG_LOCAL_TO_REMOTE;
        default:
            return 0;
    }
}

bool crclip_mode_installs_callbacks(uint32_t mode)
{
    return crclip_mode_feature_mask(mode) != 0;
}

bool crclip_mode_allows_local_to_remote(uint32_t mode)
{
    return (crclip_mode_feature_mask(mode) & CLIPRDR_FLAG_LOCAL_TO_REMOTE) != 0;
}

/* Removes every `cliprdr` entry from the static channel collection (a del call removes the first
 * match only) and says whether none is left. */
static BOOL crclip_remove_cliprdr_entries(rdpSettings* settings)
{
    for (UINT32 left = freerdp_settings_get_uint32(settings, FreeRDP_StaticChannelCount); left > 0; left--)
    {
        if (!freerdp_static_channel_collection_find(settings, CLIPRDR_SVC_CHANNEL_NAME) ||
            !freerdp_client_del_static_channel(settings, CLIPRDR_SVC_CHANNEL_NAME))
            break;
    }
    return freerdp_static_channel_collection_find(settings, CLIPRDR_SVC_CHANNEL_NAME) == NULL;
}

BOOL crclip_apply_mode(rdpSettings* settings, uint32_t mode)
{
    if (mode == CRCLIP_MODE_UNMANAGED)
        return TRUE;

    uint32_t effective = mode;
    if (!crclip_mode_is_known(mode))
    {
        WLog_WARN(crclip_tag, "[clipboard] mode=%u is not a known mode -- treated as off", (unsigned)mode);
        effective = CRCLIP_MODE_OFF;
    }
    const UINT32 mask = crclip_mode_feature_mask(effective);
    if (!freerdp_settings_set_uint32(settings, FreeRDP_ClipboardFeatureMask, mask) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, mask != 0))
    {
        WLog_ERR(crclip_tag, "[clipboard] mode=%u could not write the clipboard settings -- refusing the connection",
                 (unsigned)effective);
        return FALSE;
    }
    if (mask == 0 && !crclip_remove_cliprdr_entries(settings))
    {
        WLog_ERR(crclip_tag, "[clipboard] mode=%u could not remove a cliprdr entry -- refusing the connection",
                 (unsigned)effective);
        return FALSE;
    }
    WLog_INFO(crclip_tag, "[clipboard] mode=%u mask=0x%02x", (unsigned)effective, (unsigned)mask);
    return TRUE;
}

bool crclip_bridge_init(crclip_bridge_t* bridge, uint32_t mode, crdpq_control_t* control,
                        crdpq_clip_store_t* store, crclip_counters_t* counters)
{
    if (!bridge)
        return false;
    memset(bridge, 0, sizeof(*bridge));
    bridge->mode = mode;
    bridge->control = control;
    bridge->store = store;
    bridge->counters = counters;
    if (crclip_mode_installs_callbacks(mode) && (!control || !store || !counters))
    {
        WLog_ERR(crclip_tag,
                 "[clipboard] mode=%u has no control lane (%d), byte store (%d) or counters (%d) -- refusing the connection",
                 (unsigned)mode, control ? 1 : 0, store ? 1 : 0, counters ? 1 : 0);
        return false;
    }
    return true;
}

/* ==================================================================================== *
 * T_clip: the server callbacks
 *
 * Every one of them returns CHANNEL_RC_OK on every path (adr/0026 H-1): cliprdr_order_recv hands
 * a non-zero value to the channel thread, which stops and raises a channel error that ends the
 * whole session. So none of them has an early return; each ends in its one `return CHANNEL_RC_OK;`.
 * They send exactly two things, both protocol-mandated on-the-spot replies (adr/0026 H-10, the
 * adr/0005 addendum): Client Capabilities on Monitor Ready, a successful Format List Response on a
 * server Format List. No data request, no format list, no data response is ever sent from here.
 * ==================================================================================== */

static crclip_bridge_t* crclip_bridge_of(const CliprdrClientContext* context)
{
    return context ? (crclip_bridge_t*)context->custom : NULL;
}

/* Counts, then logs the running count. `what` is always a string literal at the call site; the
 * line carries it, a number and the count -- nothing else. */
static void crclip_note(crclip_counters_t* counters, crclip_counter_t counter, const char* what, unsigned detail)
{
    const uint64_t count = crclip_counters_bump(counters, counter);
    WLog_WARN(crclip_tag, "[clipboard] %s (detail=%u, count=%llu)", what, detail, (unsigned long long)count);
}

/* Posts one clipboard event; counts a refusal (lane sealed or full). */
static bool crclip_post(crclip_bridge_t* bridge, crdpq_event_type_t type, const crdpq_clip_ref_t* ref)
{
    CrdpEvent event;
    memset(&event, 0, sizeof(event));
    event.type = type;
    event.payload.clip = *ref;
    const bool posted = crdpq_post(bridge->control, &event);
    if (!posted)
    {
        crclip_note(bridge->counters, CRCLIP_COUNTER_EVENT_POST_FAILED, "event post refused", (unsigned)type);
        if (type == CRDPQ_EVENT_CLIP_REMOTE_DATA)
            crclip_note(bridge->counters, CRCLIP_COUNTER_STALL_REMOTE_DATA_POST_FAILED,
                        "remote data event lost, windows-to-mac waits for the next ready", (unsigned)type);
    }
    return posted;
}

/* Whether a format name the server sent is `constant`: the same length and the same bytes once
 * ASCII 'A'-'Z' are folded to 'a'-'z' on both sides. Windows compares registered clipboard format
 * names without regard to case (RegisterClipboardFormat), and which spelling the server forwards is
 * not known, so an exact comparison could miss an exclusion name -- the direction crdpq.h rules out.
 * No locale, nothing folded beyond ASCII. T_clip only; neither name is logged. */
static bool crclip_name_equals_folded(const char* name, const char* constant)
{
    for (size_t index = 0;; index++)
    {
        unsigned char a = (unsigned char)name[index];
        unsigned char b = (unsigned char)constant[index];
        if (a >= 'A' && a <= 'Z')
            a = (unsigned char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z')
            b = (unsigned char)(b - 'A' + 'a');
        if (a != b)
            return false;
        if (a == '\0')
            return true;
    }
}

uint32_t crclip_format_list_flags(const CLIPRDR_FORMAT_LIST* formatList, bool longNamesNegotiated)
{
    uint32_t flags = 0;
    if (!formatList || !formatList->formats)
        return flags;
    for (UINT32 index = 0; index < formatList->numFormats; index++)
    {
        const CLIPRDR_FORMAT* format = &formatList->formats[index];
        if (format->formatId == CF_UNICODETEXT)
            flags |= CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT;
        if (longNamesNegotiated && format->formatName)
        {
            for (size_t name = 0; name < ARRAYSIZE(crclip_exclusion_names); name++)
            {
                if (crclip_name_equals_folded(format->formatName, crclip_exclusion_names[name]))
                    flags |= CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
            }
        }
    }
    /* Without long format names a name proves nothing either way: in the UTF-16 short form all
     * four exclusion names arrive cut to 16 units, in the ASCII short form the first one does not
     * fit and the other three may arrive whole. So no name is compared, and crdpq.h's conservative
     * direction applies instead (CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED, "must"): every list that offers
     * text is judged excluded. The caller counts each list judged that way (from these flags). */
    if (!longNamesNegotiated && (flags & CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT) != 0)
        flags |= CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
    return flags;
}

/* What the server's Clipboard Capabilities PDU said about long format names. The channel keeps the
 * same fact in its private state (cliprdr_main.c, process_general_capability) and intersects it
 * with what the client offers when the client capabilities go out; the client always offers long
 * names, so "negotiated" is exactly "the server offered them and the client's capabilities went
 * out". It decides only how a server Format List is read for the exclusion flag: by name with long
 * names, in crdpq.h's conservative direction without them (crdpq.h, FULL NAMES ONLY WITH LONG
 * FORMAT NAMES; crclip_format_list_flags).
 *
 * Negotiation only ever goes down outside Monitor Ready: the channel reads every later Format List
 * by the newest capabilities at once, so a capabilities PDU without long names ends "negotiated"
 * here and now, with no Monitor Ready in between; one with long names waits for the next Monitor
 * Ready, where the client's capabilities go out again. */
static UINT crclip_on_server_capabilities(CliprdrClientContext* context, const CLIPRDR_CAPABILITIES* capabilities)
{
    crclip_bridge_t* bridge = crclip_bridge_of(context);
    if (bridge && capabilities && capabilities->capabilitySets)
    {
        const CLIPRDR_CAPABILITY_SET* set = capabilities->capabilitySets;
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL && set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN)
        {
            const CLIPRDR_GENERAL_CAPABILITY_SET* general = (const CLIPRDR_GENERAL_CAPABILITY_SET*)(const void*)set;
            bridge->serverCapabilitiesSeen = true;
            bridge->serverOffersLongNames = (general->generalFlags & CB_USE_LONG_FORMAT_NAMES) != 0;
            if (!bridge->serverOffersLongNames)
                bridge->longNamesNegotiated = false;
        }
    }
    else if (bridge)
        crclip_note(bridge->counters, CRCLIP_COUNTER_CALLBACK_ARGUMENT_MISSING, "server capabilities without a set", 1);
    return CHANNEL_RC_OK;
}

/* Monitor Ready: Client Capabilities (version 2, long format names only -- no file streams, no
 * locking, no huge files; adr/0026 S0), then the READY event. Sent again on a later Monitor Ready
 * of the same channel (adr/0026 section 8). Long names count as negotiated only once the client's
 * capabilities went out: if they did not, the server was never told the client reads long names. */
static UINT crclip_on_monitor_ready(CliprdrClientContext* context, const CLIPRDR_MONITOR_READY* monitorReady)
{
    (void)monitorReady;
    crclip_bridge_t* bridge = crclip_bridge_of(context);
    if (bridge)
    {
        CLIPRDR_GENERAL_CAPABILITY_SET general;
        memset(&general, 0, sizeof(general));
        general.capabilitySetType = CB_CAPSTYPE_GENERAL;
        general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
        general.version = CB_CAPS_VERSION_2;
        general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
        CLIPRDR_CAPABILITIES capabilities;
        memset(&capabilities, 0, sizeof(capabilities));
        capabilities.common.msgType = CB_CLIP_CAPS;
        capabilities.cCapabilitiesSets = 1;
        capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET*)(void*)&general;
        const UINT sent = context->ClientCapabilities ? context->ClientCapabilities(context, &capabilities)
                                                      : CHANNEL_RC_NOT_INITIALIZED;
        if (sent != CHANNEL_RC_OK)
            crclip_note(bridge->counters, CRCLIP_COUNTER_CAPABILITIES_SEND_FAILED, "client capabilities not sent", sent);
        bridge->longNamesNegotiated =
            sent == CHANNEL_RC_OK && bridge->serverCapabilitiesSeen && bridge->serverOffersLongNames;

        crdpq_clip_ref_t ref;
        memset(&ref, 0, sizeof(ref));
        ref.storeGeneration = bridge->storeGeneration;
        (void)crclip_post(bridge, CRDPQ_EVENT_CLIP_READY, &ref);
    }
    return CHANNEL_RC_OK;
}

/* A server Format List (already filtered by the channel's feature-mask gate): the successful
 * Format List Response, then the two facts as the REMOTE_FORMATS event's flags. */
static UINT crclip_on_server_format_list(CliprdrClientContext* context, const CLIPRDR_FORMAT_LIST* formatList)
{
    crclip_bridge_t* bridge = crclip_bridge_of(context);
    if (bridge)
    {
        CLIPRDR_FORMAT_LIST_RESPONSE response;
        memset(&response, 0, sizeof(response));
        response.common.msgType = CB_FORMAT_LIST_RESPONSE;
        response.common.msgFlags = CB_RESPONSE_OK;
        const UINT sent = context->ClientFormatListResponse ? context->ClientFormatListResponse(context, &response)
                                                            : CHANNEL_RC_NOT_INITIALIZED;
        if (sent != CHANNEL_RC_OK)
            crclip_note(bridge->counters, CRCLIP_COUNTER_FORMAT_LIST_RESPONSE_SEND_FAILED, "format list response not sent", sent);

        if (!formatList)
            crclip_note(bridge->counters, CRCLIP_COUNTER_CALLBACK_ARGUMENT_MISSING, "server format list missing", 2);

        crdpq_clip_ref_t ref;
        memset(&ref, 0, sizeof(ref));
        ref.storeGeneration = bridge->storeGeneration;
        ref.flags = crclip_format_list_flags(formatList, bridge->longNamesNegotiated);
        if (!bridge->longNamesNegotiated && (ref.flags & CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED) != 0)
            crclip_note(bridge->counters, CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES,
                        "format list without long format names, judged excluded",
                        formatList ? (unsigned)formatList->numFormats : 0);
        (void)crclip_post(bridge, CRDPQ_EVENT_CLIP_REMOTE_FORMATS, &ref);
    }
    return CHANNEL_RC_OK;
}

/* A server Format Data Request: handed to T_main, which alone decides the answer. Nothing is sent
 * from here, not even a failure (adr/0026 H-10). */
static UINT crclip_on_server_format_data_request(CliprdrClientContext* context,
                                                 const CLIPRDR_FORMAT_DATA_REQUEST* formatDataRequest)
{
    crclip_bridge_t* bridge = crclip_bridge_of(context);
    if (bridge)
    {
        crdpq_clip_ref_t ref;
        memset(&ref, 0, sizeof(ref));
        ref.storeGeneration = bridge->storeGeneration;
        if (formatDataRequest)
            ref.formatId = formatDataRequest->requestedFormatId;
        else
            crclip_note(bridge->counters, CRCLIP_COUNTER_CALLBACK_ARGUMENT_MISSING, "server data request missing", 3);
        (void)crclip_post(bridge, CRDPQ_EVENT_CLIP_DATA_REQUEST, &ref);
    }
    return CHANNEL_RC_OK;
}

/* A server Format Data Response. Its bytes point into the channel's stream, freed when this
 * callback returns (adr/0026 section 2(e)), so they are copied into the store here or not at all.
 * The store's block limit is the S6 limit (the store is created from the Swift layer's constant):
 * a refused put -- over the limit, no slot, the total limit -- copies nothing and the event says
 * NOT_STORED with the length on the wire. */
static UINT crclip_on_server_format_data_response(CliprdrClientContext* context,
                                                  const CLIPRDR_FORMAT_DATA_RESPONSE* formatDataResponse)
{
    crclip_bridge_t* bridge = crclip_bridge_of(context);
    if (bridge)
    {
        crdpq_clip_ref_t ref;
        memset(&ref, 0, sizeof(ref));
        ref.storeGeneration = bridge->storeGeneration;
        const UINT16 msgFlags = formatDataResponse ? formatDataResponse->common.msgFlags : 0;
        const bool ok = (msgFlags & CB_RESPONSE_OK) != 0 && (msgFlags & CB_RESPONSE_FAIL) == 0;
        if (!formatDataResponse)
            crclip_note(bridge->counters, CRCLIP_COUNTER_CALLBACK_ARGUMENT_MISSING, "server data response missing", 4);
        else if ((msgFlags & (CB_RESPONSE_OK | CB_RESPONSE_FAIL)) != CB_RESPONSE_OK &&
                 (msgFlags & (CB_RESPONSE_OK | CB_RESPONSE_FAIL)) != CB_RESPONSE_FAIL)
            crclip_note(bridge->counters, CRCLIP_COUNTER_REMOTE_DATA_FLAGS_UNEXPECTED, "data response flags neither OK nor FAIL",
                        (unsigned)msgFlags);

        if (ok)
        {
            const uint32_t key = bridge->nextResponseNumber++;
            const UINT32 length = formatDataResponse->common.dataLen;
            const crdpq_clip_result_t put = crdpq_clip_store_put(bridge->store, bridge->storeGeneration,
                                                                 CRDPQ_CLIP_REMOTE_TO_LOCAL, key,
                                                                 formatDataResponse->requestedFormatData, length);
            ref.sequence = key;
            ref.byteCount = length;
            if (put == CRDPQ_CLIP_OK)
                ref.status = CRDPQ_CLIP_STATUS_OK;
            else
            {
                ref.status = CRDPQ_CLIP_STATUS_NOT_STORED;
                crclip_note(bridge->counters, CRCLIP_COUNTER_REMOTE_DATA_NOT_STORED, "data response not stored", (unsigned)put);
            }
            if (!crclip_post(bridge, CRDPQ_EVENT_CLIP_REMOTE_DATA, &ref) && put == CRDPQ_CLIP_OK)
                (void)crdpq_clip_store_discard(bridge->store, bridge->storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, key);
        }
        else
        {
            ref.status = CRDPQ_CLIP_STATUS_FAILED;
            (void)crclip_post(bridge, CRDPQ_EVENT_CLIP_REMOTE_DATA, &ref);
        }
    }
    return CHANNEL_RC_OK;
}

/* ==================================================================================== *
 * T_rdp: attach / detach
 * ==================================================================================== */

bool crclip_bridge_attach(crclip_bridge_t* bridge, CliprdrClientContext* channel)
{
    if (!bridge || !channel || !crclip_mode_installs_callbacks(bridge->mode))
    {
        /* The mode number only (0 without a bridge). CRSession.mm calls this only for a directed
         * mode, so in the App the one way here is a channel without a client interface. */
        WLog_ERR(crclip_tag, "[clipboard] mode=%u not attached to the channel -- nothing answers it",
                 bridge ? (unsigned)bridge->mode : 0u);
        return false;
    }
    bridge->storeGeneration = crdpq_clip_store_clear(bridge->store);
    bridge->nextResponseNumber = 0;
    bridge->serverCapabilitiesSeen = false;
    bridge->serverOffersLongNames = false;
    bridge->longNamesNegotiated = false;
    channel->custom = bridge;
    channel->ServerCapabilities = crclip_on_server_capabilities;
    channel->MonitorReady = crclip_on_monitor_ready;
    channel->ServerFormatList = crclip_on_server_format_list;
    channel->ServerFormatDataRequest = crclip_on_server_format_data_request;
    channel->ServerFormatDataResponse = crclip_on_server_format_data_response;
    bridge->channel = channel;
    WLog_INFO(crclip_tag, "[clipboard] channel %s attached mode=%u storeGeneration=%u", CLIPRDR_SVC_CHANNEL_NAME,
              (unsigned)bridge->mode, (unsigned)bridge->storeGeneration);
    return true;
}

void crclip_bridge_detach(crclip_bridge_t* bridge, CliprdrClientContext* channel)
{
    if (!bridge)
        return;
    if (channel && channel->custom == bridge)
        channel->custom = NULL;
    bridge->channel = NULL;
    const uint32_t generation = crdpq_clip_store_clear(bridge->store);
    WLog_INFO(crclip_tag, "[clipboard] channel %s detached storeGeneration=%u", CLIPRDR_SVC_CHANNEL_NAME,
              (unsigned)generation);
}

/* ==================================================================================== *
 * T_rdp: the outbound dispatch
 * ==================================================================================== */

/* The channel's own condition for its data-response function (cliprdr_main.c asserts the mask
 * carries a Mac -> Windows bit; under this build's verbose asserts a failed assertion aborts the
 * process). Checked against the live settings as well as the mode: the bridge never writes a
 * FILES bit, so the plain bit is the one it can rely on. */
static bool crclip_channel_allows_response(const CliprdrClientContext* channel)
{
    if (!channel || !channel->rdpcontext || !channel->rdpcontext->settings)
        return false;
    const UINT32 mask = freerdp_settings_get_uint32(channel->rdpcontext->settings, FreeRDP_ClipboardFeatureMask);
    return (mask & CLIPRDR_FLAG_LOCAL_TO_REMOTE) != 0;
}

/* The ONE call to the channel's data-response function in the App (adr/0026 H-2). It is
 * never reached under a mode without Mac -> Windows: the guard right in front of the call is the
 * mode, then the live mask. */
static UINT crclip_send_data_response(const crclip_bridge_t* bridge, CliprdrClientContext* channel, UINT16 msgFlags,
                                      const BYTE* data, UINT32 length)
{
    if (!crclip_mode_allows_local_to_remote(bridge->mode) || !crclip_channel_allows_response(channel) ||
        !channel->ClientFormatDataResponse)
        return CHANNEL_RC_NOT_INITIALIZED;
    CLIPRDR_FORMAT_DATA_RESPONSE response;
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = msgFlags;
    response.common.dataLen = length;
    response.requestedFormatData = data;
    return channel->ClientFormatDataResponse(channel, &response);
}

static void crclip_dispatch_announce(crclip_bridge_t* bridge, CliprdrClientContext* channel, const crdpq_clip_ref_t* ref)
{
    CLIPRDR_FORMAT format;
    memset(&format, 0, sizeof(format));
    format.formatId = ref->formatId;
    CLIPRDR_FORMAT_LIST list;
    memset(&list, 0, sizeof(list));
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = (ref->formatId == CRDPQ_CLIP_NO_FORMAT) ? 0 : 1;
    list.formats = (list.numFormats > 0) ? &format : NULL;
    const UINT sent = channel->ClientFormatList ? channel->ClientFormatList(channel, &list) : CHANNEL_RC_NOT_INITIALIZED;
    if (sent != CHANNEL_RC_OK)
        crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_SEND_FAILED, "format list not sent", sent);
}

static void crclip_dispatch_request(crclip_bridge_t* bridge, CliprdrClientContext* channel, const crdpq_clip_ref_t* ref)
{
    CLIPRDR_FORMAT_DATA_REQUEST request;
    memset(&request, 0, sizeof(request));
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = ref->formatId;
    const UINT sent = channel->ClientFormatDataRequest ? channel->ClientFormatDataRequest(channel, &request)
                                                       : CHANNEL_RC_NOT_INITIALIZED;
    if (sent != CHANNEL_RC_OK)
        crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_SEND_FAILED, "data request not sent", sent);
}

/* Removes an answer's store entry without sending it (a dropped RESPOND). */
static void crclip_discard_answer(crclip_bridge_t* bridge, const crdpq_clip_ref_t* ref)
{
    if (ref->status == CRDPQ_CLIP_STATUS_OK)
        (void)crdpq_clip_store_discard(bridge->store, ref->storeGeneration, CRDPQ_CLIP_LOCAL_TO_REMOTE, ref->sequence);
}

static void crclip_dispatch_respond(crclip_bridge_t* bridge, CliprdrClientContext* channel, const crdpq_clip_ref_t* ref)
{
    if (!crclip_mode_allows_local_to_remote(bridge->mode))
    {
        /* adr/0026 H-2: the channel has already answered the server itself; a second answer would
         * trip its assertion. The entry goes, nothing is sent. */
        crclip_discard_answer(bridge, ref);
        crclip_note(bridge->counters, CRCLIP_COUNTER_RESPONSE_WITHHELD_BY_MODE, "answer withheld, mode has no mac-to-windows",
                    (unsigned)bridge->mode);
        return;
    }
    if (ref->storeGeneration != bridge->storeGeneration)
    {
        /* An answer to a request an earlier channel instance carried: that server request died with
         * the instance, and the wire pairs answers by order, so it must not go out on this one. */
        crclip_discard_answer(bridge, ref);
        crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_DROPPED_STALE, "answer for an earlier channel instance dropped",
                    (unsigned)ref->storeGeneration);
        return;
    }

    UINT sent = CHANNEL_RC_OK;
    if (ref->status == CRDPQ_CLIP_STATUS_OK)
    {
        const size_t capacity = ref->byteCount;
        uint8_t* bytes = (capacity > 0) ? malloc(capacity) : NULL;
        size_t length = 0;
        const crdpq_clip_result_t taken =
            (capacity > 0 && !bytes) ? CRDPQ_CLIP_ERR_NO_MEMORY
                                     : crdpq_clip_store_take(bridge->store, ref->storeGeneration,
                                                             CRDPQ_CLIP_LOCAL_TO_REMOTE, ref->sequence, bytes,
                                                             capacity, &length);
        if (taken == CRDPQ_CLIP_OK)
            sent = crclip_send_data_response(bridge, channel, CB_RESPONSE_OK, bytes, (UINT32)length);
        else
        {
            /* One answer per request, always: without the bytes it is a failure. Whatever is left
             * under the key (a too-small buffer leaves it in place) goes too. */
            crclip_discard_answer(bridge, ref);
            crclip_note(bridge->counters, CRCLIP_COUNTER_RESPONSE_BYTES_UNAVAILABLE, "answer bytes unavailable, failure sent",
                        (unsigned)taken);
            sent = crclip_send_data_response(bridge, channel, CB_RESPONSE_FAIL, NULL, 0);
        }
        crdpq_clip_wipe(bytes, capacity);
        free(bytes);
    }
    else
        sent = crclip_send_data_response(bridge, channel, CB_RESPONSE_FAIL, NULL, 0);
    if (sent != CHANNEL_RC_OK)
        crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_SEND_FAILED, "data response not sent", sent);
}

bool crclip_outbound_dispatch(crclip_bridge_t* bridge, const CrdpCommand* command)
{
    if (!command || (command->type != CRDPQ_CMD_CLIP_ANNOUNCE && command->type != CRDPQ_CMD_CLIP_REQUEST &&
                     command->type != CRDPQ_CMD_CLIP_RESPOND))
        return false;
    if (!bridge)
        return true;
    const crdpq_clip_ref_t* ref = &command->payload.clip;
    CliprdrClientContext* channel = bridge->channel;
    if (!channel)
    {
        if (command->type == CRDPQ_CMD_CLIP_RESPOND)
            crclip_discard_answer(bridge, ref);
        crclip_note(bridge->counters, CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL, "command dropped, channel not connected",
                    (unsigned)command->type);
        if (command->type == CRDPQ_CMD_CLIP_REQUEST)
            crclip_note(bridge->counters, CRCLIP_COUNTER_STALL_REQUEST_DROPPED,
                        "data request dropped, windows-to-mac waits for the next ready", (unsigned)command->type);
        return true;
    }
    switch (command->type)
    {
        case CRDPQ_CMD_CLIP_ANNOUNCE:
            crclip_dispatch_announce(bridge, channel, ref);
            break;
        case CRDPQ_CMD_CLIP_REQUEST:
            crclip_dispatch_request(bridge, channel, ref);
            break;
        default:
            crclip_dispatch_respond(bridge, channel, ref);
            break;
    }
    return true;
}

/* ==================================================================================== *
 * T_main: the owner thread's side of the lanes and the store
 * ==================================================================================== */

bool crclip_post_command(crdpq_outbound_t* outbound, crclip_counters_t* counters, crdpq_command_type_t type,
                         const crdpq_clip_ref_t* ref)
{
    CrdpCommand command;
    memset(&command, 0, sizeof(command));
    command.type = type;
    if (ref)
        command.payload.clip = *ref;
    if (outbound && crdpq_outbound_post(outbound, &command))
        return true;
    crclip_note(counters, CRCLIP_COUNTER_COMMAND_POST_FAILED, "command not posted", (unsigned)type);
    if (type == CRDPQ_CMD_CLIP_REQUEST)
        crclip_note(counters, CRCLIP_COUNTER_STALL_REQUEST_POST_FAILED,
                    "data request not posted, windows-to-mac waits for the next ready", (unsigned)type);
    return false;
}

bool crclip_announce(crdpq_outbound_t* outbound, crclip_counters_t* counters, uint32_t formatId)
{
    if (formatId != CRDPQ_CLIP_NO_FORMAT && formatId != CF_UNICODETEXT)
        return false;
    crdpq_clip_ref_t ref;
    memset(&ref, 0, sizeof(ref));
    ref.formatId = formatId;
    return crclip_post_command(outbound, counters, CRDPQ_CMD_CLIP_ANNOUNCE, &ref);
}

bool crclip_request(crdpq_outbound_t* outbound, crclip_counters_t* counters, uint32_t formatId)
{
    if (formatId != CF_UNICODETEXT)
        return false;
    crdpq_clip_ref_t ref;
    memset(&ref, 0, sizeof(ref));
    ref.formatId = formatId;
    return crclip_post_command(outbound, counters, CRDPQ_CMD_CLIP_REQUEST, &ref);
}

crclip_respond_result_t crclip_respond(crdpq_outbound_t* outbound, crdpq_clip_store_t* store,
                                       crclip_counters_t* counters, uint32_t key, const crdpq_clip_ref_t* request,
                                       bool withBytes, const uint8_t* bytes, size_t length)
{
    crdpq_clip_ref_t ref;
    memset(&ref, 0, sizeof(ref));
    ref.storeGeneration = request ? request->storeGeneration : 0;
    ref.formatId = request ? request->formatId : 0;
    ref.status = CRDPQ_CLIP_STATUS_FAILED;
    bool stored = false;
    if (withBytes)
    {
        const crdpq_clip_result_t put =
            (length > UINT32_MAX) ? CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE
                                  : crdpq_clip_store_put(store, ref.storeGeneration, CRDPQ_CLIP_LOCAL_TO_REMOTE, key,
                                                         bytes, length);
        if (put == CRDPQ_CLIP_ERR_STALE_GENERATION)
            return CRCLIP_RESPOND_STALE;
        if (put == CRDPQ_CLIP_OK)
        {
            ref.status = CRDPQ_CLIP_STATUS_OK;
            ref.sequence = key;
            ref.byteCount = (uint32_t)length;
            stored = true;
        }
        else
            crclip_note(counters, CRCLIP_COUNTER_RESPOND_STORED_AS_FAILURE, "answer not stored, a failure is posted instead",
                        (unsigned)put);
    }
    if (!crclip_post_command(outbound, counters, CRDPQ_CMD_CLIP_RESPOND, &ref))
    {
        if (stored)
            (void)crdpq_clip_store_discard(store, ref.storeGeneration, CRDPQ_CLIP_LOCAL_TO_REMOTE, key);
        return CRCLIP_RESPOND_NOT_POSTED;
    }
    return (withBytes && !stored) ? CRCLIP_RESPOND_POSTED_AS_FAILURE : CRCLIP_RESPOND_POSTED;
}

bool crclip_take_remote(crdpq_clip_store_t* store, const crdpq_clip_ref_t* event, crclip_reader_fn reader,
                        void* context)
{
    if (!event || event->status != CRDPQ_CLIP_STATUS_OK)
        return false;
    const size_t capacity = event->byteCount;
    uint8_t* buffer = (capacity > 0) ? malloc(capacity) : NULL;
    size_t length = 0;
    const crdpq_clip_result_t taken =
        (capacity > 0 && !buffer) ? CRDPQ_CLIP_ERR_NO_MEMORY
                                  : crdpq_clip_store_take(store, event->storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL,
                                                          event->sequence, buffer, capacity, &length);
    if (taken == CRDPQ_CLIP_OK && reader)
        reader(buffer, length, context);
    if (taken != CRDPQ_CLIP_OK)
        crclip_discard_remote(store, event);
    crdpq_clip_wipe(buffer, capacity);
    free(buffer);
    return taken == CRDPQ_CLIP_OK;
}

void crclip_discard_remote(crdpq_clip_store_t* store, const crdpq_clip_ref_t* event)
{
    if (event && event->status == CRDPQ_CLIP_STATUS_OK)
        (void)crdpq_clip_store_discard(store, event->storeGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, event->sequence);
}

void crclip_settle_unconsumed(crdpq_clip_store_t* store, crclip_counters_t* counters, const crdpq_clip_ref_t* event)
{
    crclip_discard_remote(store, event);
    crclip_note(counters, CRCLIP_COUNTER_REMOTE_DATA_UNCONSUMED, "remote data neither taken nor discarded, discarded",
                event ? (unsigned)event->byteCount : 0);
}

size_t crclip_store_for_limit(crdpq_clip_store_t** store, size_t storeLimit, size_t limit)
{
    if (!store)
        return 0;
    if (limit == 0 || limit > SIZE_MAX / 2)
    {
        /* No limit, or one whose total (twice it) does not fit: no store, whatever was there. */
        crdpq_clip_store_destroy(*store);
        *store = NULL;
        return 0;
    }
    if (*store && storeLimit == limit)
        return limit;
    crdpq_clip_store_destroy(*store);
    *store = crdpq_clip_store_create(limit, limit * 2);
    return *store ? limit : 0;
}
