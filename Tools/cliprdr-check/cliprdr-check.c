/**
 * cliprdr-check: an offline check of the clipboard bridge (App/CRBridge/crclip_bridge.c, adr/0026
 * lane L3) against the built-in cliprdr channel of the FreeRDP prefix it is linked with. No
 * socket, no host, no credentials, nothing read from any host configuration: the channel is
 * loaded from the prefix through fake channel-manager entry points, its message thread (T_clip)
 * is the real one the channel creates for itself, and the server's PDUs are fed in at the
 * channel's open-event entry point.
 *
 * Where the server's bytes come from: every server PDU this check feeds is produced by FreeRDP's
 * OWN server-side cliprdr encoder -- channels/cliprdr/server/cliprdr_main.c and
 * channels/cliprdr/cliprdr_common.c of the vendored source, compiled into this binary unchanged
 * (Tools/cliprdr-check/CMakeLists.txt). Their write goes through WinPR's WTSVirtualChannelWrite,
 * which this check routes to a capture with WTSRegisterWtsApiFunctionTable. No server PDU is
 * written by hand here. What the client side sends is captured at the channel's write entry
 * point (pVirtualChannelWriteEx), so the channel's own client serializers run.
 *
 * What is checked (each case prints one line; the last line is the verdict):
 *   - every bridge callback returns CHANNEL_RC_OK, the channel raises no error, and T_clip keeps
 *     processing (a server Format List Response is the barrier after each step: the channel calls
 *     a harness callback for it on T_clip, after everything fed before it);
 *   - T_clip sends only Client Capabilities and Format List Responses (plus, under a mode without
 *     Mac -> Windows, the channel's own failure answer), never a data request, a format list or a
 *     data response; those three leave only from the outbound dispatch, on the driver thread that
 *     plays T_rdp;
 *   - the events, the store entries and the counters of every path: capabilities and ready,
 *     format lists with and without CF_UNICODETEXT, the exclusion names with and without long
 *     format names, empty lists, data requests and OK / FAIL / at-limit / over-limit / repeated
 *     over-limit responses, send failures, a second ready, a channel reload, the three directed
 *     modes and Unmanaged, the commands while the channel is gone, and RAIL commands left alone;
 *   - nothing logged at INFO and above (the App's root level) contains the fixture text, in UTF-8
 *     or UTF-16LE, or a format name.
 * Self-checks (so a green run is evidence): the assertion in the channel's data-response function
 * aborts the process under a mode without Mac -> Windows (a forked child); the log capture sees
 * the channel's own DEBUG lines that print format names; a callback that returns non-zero is
 * caught; a data request sent from T_clip is caught.
 *
 * Usage: cliprdr-check <freerdp-prefix> <limit-bytes>   (Scripts/test-cliprdr.sh runs it and
 *        passes the limit it reads from MacdowsCore's ClipboardLimits.defaultMaxBytes)
 * Exit:  0 PASS; 1 FAIL (the bridge or the channel does not behave as required); 2 ERROR (the
 *        check could not judge: a harness fault, a premise that no longer holds, a short count).
 */

#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <winpr/crt.h>
#include <winpr/stream.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <winpr/wlog.h>
#include <winpr/wtsapi.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/freerdp.h>
#include <freerdp/server/cliprdr.h>
#include <freerdp/settings.h>
#include <freerdp/svc.h>

#include "crclip_bridge.h"
#include "crdpq.h"
/* FreeRDP's shared cliprdr encoder (vendored source, compiled into this binary): the one ASCII
 * short-name format list below is built with it. */
#include "cliprdr_common.h"

/* ThreadSanitizer builds only (CLIPRDR_CHECK_SANITIZER=thread). Two hand-offs between this
 * driver thread and T_clip go through synchronisation inside the uninstrumented prefix that TSan
 * cannot see: the channel's message queue (WinPR's critical section is built on Mach semaphores on
 * this platform, winpr/libwinpr/synch/critical.c) and the join of T_clip on CHANNEL_EVENT_DISCONNECTED.
 * edge_release / edge_acquire tell TSan about exactly those two edges and nothing else. */
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
#include <sanitizer/tsan_interface.h>
#define CC_TSAN_EDGES 1
#endif
#endif
#ifndef CC_TSAN_EDGES
#define CC_TSAN_EDGES 0
#endif
static char g_queueEdge;
static char g_joinEdge;

static void edge_release(void* edge)
{
#if CC_TSAN_EDGES
	__tsan_release(edge);
#else
	(void)edge;
#endif
}

static void edge_acquire(void* edge)
{
#if CC_TSAN_EDGES
	__tsan_acquire(edge);
#else
	(void)edge;
#endif
}

#define CHECK_PASS 0
#define CHECK_FAIL 1
#define CHECK_ERROR 2

#define EXPECTED_CASES 40u
#define EXPECTED_SELF_CHECKS 4u
#define MAX_PDUS 256
#define MAX_CALLS 512
#define MAX_EVENTS 128
#define BODY_MAX 512
#define BARRIER_SECONDS 5
#define INJECTED_ERROR ERROR_INTERNAL_ERROR
#define FIXTURE_FORMAT_ID 0xC123u

/* ==================================================================================== *
 * Fixtures. Made up: a plain English phrase with four non-ASCII characters, so the text
 * travels as multi-byte UTF-8 and as UTF-16LE code units above 0xFF.
 * ==================================================================================== */

static const char g_fixtureUtf8[] =
    "A pretend paste about a purple teapot \xE7\xB4\xAB\xE8\x89\xB2\xE8\x8C\xB6\xE5\xA3\xB6";
static const char g_fixtureTailUtf8[] = "\xE7\xB4\xAB\xE8\x89\xB2\xE8\x8C\xB6\xE5\xA3\xB6";
static const UINT16 g_fixtureTailUnits[] = { 0x7D2B, 0x8272, 0x8336, 0x58F6 };
static const char g_fixtureFormatName[] = "Pretend Fixture Format";
static const char* const g_exclusionNames[] = {
	"ExcludeClipboardContentFromMonitorProcessing",
	"CanIncludeInClipboardHistory",
	"CanUploadToCloudClipboard",
	"Clipboard Viewer Ignore",
};

static BYTE g_fixtureWire[256];   /* CF_UNICODETEXT: UTF-16LE with its terminating NUL */
static size_t g_fixtureWireLen = 0;
static BYTE g_fixtureTailWire[16]; /* UTF-16LE of the four non-ASCII characters, no NUL */

static BOOL build_fixtures(void)
{
	size_t n = 0;
	const size_t asciiLen = strlen(g_fixtureUtf8) - strlen(g_fixtureTailUtf8);
	for (size_t i = 0; i < asciiLen; i++)
	{
		g_fixtureWire[n++] = (BYTE)g_fixtureUtf8[i];
		g_fixtureWire[n++] = 0;
	}
	for (size_t i = 0; i < ARRAYSIZE(g_fixtureTailUnits); i++)
	{
		const BYTE lo = (BYTE)(g_fixtureTailUnits[i] & 0xFF);
		const BYTE hi = (BYTE)(g_fixtureTailUnits[i] >> 8);
		g_fixtureWire[n++] = lo;
		g_fixtureWire[n++] = hi;
		g_fixtureTailWire[2 * i] = lo;
		g_fixtureTailWire[2 * i + 1] = hi;
		if (lo == 0 || hi == 0)
			return FALSE; /* the tail needle must be searchable inside a C string */
	}
	g_fixtureWire[n++] = 0;
	g_fixtureWire[n++] = 0;
	g_fixtureWireLen = n;
	/* Self-consistency: the UTF-16LE form decodes to exactly the UTF-8 literal. */
	size_t utf8Len = 0;
	char* back = ConvertWCharNToUtf8Alloc((const WCHAR*)(const void*)g_fixtureWire, n / 2 - 1, &utf8Len);
	const BOOL same = back && (strcmp(back, g_fixtureUtf8) == 0);
	free(back);
	return same;
}

/* ==================================================================================== *
 * Log capture: the root logger's CALLBACK appender, at the App's level (INFO).
 * ==================================================================================== */

static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;
static char* g_log = NULL;
static size_t g_logLen = 0;
static size_t g_logCap = 0;
static size_t g_logLines = 0;

/* The message texts alone, one per line, without the prefixes (which carry the time): what the
 * log-invariance case compares. Same lock as the full capture. */
static char* g_text = NULL;
static size_t g_textLen = 0;
static size_t g_textCap = 0;

static void text_append(const char* text)
{
	const size_t len = text ? strlen(text) : 0;
	if (g_textLen + len + 2 > g_textCap)
	{
		size_t cap = g_textCap ? g_textCap : 65536;
		while (g_textLen + len + 2 > cap)
			cap *= 2;
		char* grown = realloc(g_text, cap);
		if (!grown)
			return;
		g_text = grown;
		g_textCap = cap;
	}
	if (len)
		memcpy(g_text + g_textLen, text, len);
	g_textLen += len;
	g_text[g_textLen++] = '\n';
	g_text[g_textLen] = '\0';
}

static void log_append(const char* text)
{
	const size_t len = text ? strlen(text) : 0;
	if (g_logLen + len + 2 > g_logCap)
	{
		size_t cap = g_logCap ? g_logCap : 65536;
		while (g_logLen + len + 2 > cap)
			cap *= 2;
		char* grown = realloc(g_log, cap);
		if (!grown)
			return;
		g_log = grown;
		g_logCap = cap;
	}
	if (len)
		memcpy(g_log + g_logLen, text, len);
	g_logLen += len;
	g_log[g_logLen++] = '\n';
	g_log[g_logLen] = '\0';
}

static BOOL capture_message(const wLogMessage* msg)
{
	if (!msg)
		return FALSE;
	pthread_mutex_lock(&g_logLock);
	log_append(msg->PrefixString);
	log_append(msg->TextString);
	text_append(msg->TextString);
	g_logLines++;
	pthread_mutex_unlock(&g_logLock);
	return TRUE;
}

static BOOL capture_drop(const wLogMessage* msg)
{
	(void)msg;
	return TRUE;
}

static void log_reset(void)
{
	pthread_mutex_lock(&g_logLock);
	g_logLen = 0;
	g_logLines = 0;
	if (g_log)
		g_log[0] = '\0';
	g_textLen = 0;
	if (g_text)
		g_text[0] = '\0';
	pthread_mutex_unlock(&g_logLock);
}

static size_t text_offset(void)
{
	pthread_mutex_lock(&g_logLock);
	const size_t offset = g_textLen;
	pthread_mutex_unlock(&g_logLock);
	return offset;
}

/* The message texts logged since `from`, with the digits after every "count=" dropped (a running
 * count differs between two rounds by construction). NULL on allocation failure. */
static char* text_since_without_counts(size_t from)
{
	static const char key[] = "count=";
	pthread_mutex_lock(&g_logLock);
	const size_t end = g_textLen;
	const size_t start = from < end ? from : end;
	char* out = malloc(end - start + 1);
	size_t n = 0;
	for (size_t i = start; out && i < end;)
	{
		if (end - i >= sizeof(key) - 1 && memcmp(g_text + i, key, sizeof(key) - 1) == 0)
		{
			memcpy(out + n, key, sizeof(key) - 1);
			n += sizeof(key) - 1;
			i += sizeof(key) - 1;
			while (i < end && g_text[i] >= '0' && g_text[i] <= '9')
				i++;
			continue;
		}
		out[n++] = g_text[i++];
	}
	if (out)
		out[n] = '\0';
	pthread_mutex_unlock(&g_logLock);
	return out;
}

/* How often `needle` occurs in the message texts logged since `from`. */
static size_t text_count_since(size_t from, const char* needle)
{
	size_t count = 0;
	const size_t needleLen = strlen(needle);
	pthread_mutex_lock(&g_logLock);
	const char* at = (g_text && from < g_textLen) ? g_text + from : NULL;
	const char* end = g_text ? g_text + g_textLen : NULL;
	while (at && needleLen > 0 && (size_t)(end - at) >= needleLen)
	{
		const char* hit = memmem(at, (size_t)(end - at), needle, needleLen);
		if (!hit)
			break;
		count++;
		at = hit + needleLen;
	}
	pthread_mutex_unlock(&g_logLock);
	return count;
}

static BOOL log_contains(const void* needle, size_t needleLen)
{
	BOOL found = FALSE;
	pthread_mutex_lock(&g_logLock);
	if (g_log && needleLen > 0 && g_logLen >= needleLen)
		found = memmem(g_log, g_logLen, needle, needleLen) != NULL;
	pthread_mutex_unlock(&g_logLock);
	return found;
}

/* Whether `needle` (ASCII) occurs in the full capture with ASCII case ignored. */
static BOOL log_contains_folded(const char* needle)
{
	const size_t needleLen = strlen(needle);
	BOOL found = FALSE;
	pthread_mutex_lock(&g_logLock);
	for (size_t at = 0; g_log && needleLen > 0 && at + needleLen <= g_logLen && !found; at++)
	{
		size_t i = 0;
		while (i < needleLen && tolower((unsigned char)g_log[at + i]) == tolower((unsigned char)needle[i]))
			i++;
		found = (i == needleLen);
	}
	pthread_mutex_unlock(&g_logLock);
	return found;
}

static BOOL install_log_capture(void)
{
	static const char* const ignored[] = { "WLOG_APPENDER", "WLOG_LEVEL", "WLOG_FILTER", "WLOG_PREFIX" };
	for (size_t i = 0; i < ARRAYSIZE(ignored); i++)
		unsetenv(ignored[i]);
	wLog* root = WLog_GetRoot();
	if (!root || !WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK))
		return FALSE;
	wLogCallbacks callbacks = { 0 };
	callbacks.message = capture_message;
	callbacks.data = capture_drop;
	callbacks.image = capture_drop;
	callbacks.package = capture_drop;
	wLogAppender* appender = WLog_GetLogAppender(root);
	return appender && WLog_ConfigureAppender(appender, "callbacks", &callbacks) &&
	       WLog_SetLogLevel(root, WLOG_INFO);
}

/* ==================================================================================== *
 * The server side: FreeRDP's server encoder, its writes captured through the WTS API table.
 * ==================================================================================== */

static CliprdrServerContext* g_server = NULL;
static BYTE* g_serverOut = NULL;
static size_t g_serverOutLen = 0;
static size_t g_serverOutCap = 0;

static BOOL WINAPI fake_wts_write(HANDLE channel, PCHAR buffer, ULONG length, PULONG written)
{
	(void)channel;
	if (g_serverOutLen + length > g_serverOutCap)
	{
		size_t cap = g_serverOutCap ? g_serverOutCap : 4096;
		while (g_serverOutLen + length > cap)
			cap *= 2;
		BYTE* grown = realloc(g_serverOut, cap);
		if (!grown)
			return FALSE;
		g_serverOut = grown;
		g_serverOutCap = cap;
	}
	memcpy(g_serverOut + g_serverOutLen, buffer, length);
	g_serverOutLen += length;
	if (written)
		*written = length;
	return TRUE;
}

static WtsApiFunctionTable g_wts;

/* ==================================================================================== *
 * The client side: one channel instance at a time, loaded from the prefix.
 * ==================================================================================== */

typedef struct
{
	int initHandle; /* its address is the init handle */
	LPVOID userParam;
	PCHANNEL_INIT_EVENT_EX_FN initEvent;
	PCHANNEL_OPEN_EVENT_EX_FN openEvent;
	DWORD openHandle;
	CliprdrClientContext* channel;
	uint32_t mode;
	BOOL connected;
	BOOL live; /* entry point ran, not terminated */
	BOOL attached;
	pcCliprdrServerCapabilities bridgeCaps;
	pcCliprdrMonitorReady bridgeReady;
	pcCliprdrServerFormatList bridgeList;
	pcCliprdrServerFormatDataRequest bridgeRequest;
	pcCliprdrServerFormatDataResponse bridgeResponse;
	pcCliprdrClientFormatDataResponse realDataResponse;
} Instance;

static Instance g_inst;
static rdpContext* g_context = NULL;
static crdpq_control_t* g_control = NULL;
static crdpq_outbound_t* g_outbound = NULL;
static crdpq_clip_store_t* g_store = NULL;
static crclip_counters_t* g_counters = NULL;
static crclip_bridge_t g_bridge;
static size_t g_limit = 0;
static pthread_t g_driver;
static BOOL g_foreignHandle = FALSE;
static _Thread_local BOOL t_inDispatch = FALSE;

typedef struct
{
	UINT16 msgType;
	UINT16 msgFlags;
	UINT32 dataLen;
	size_t bodyLen;
	BYTE body[BODY_MAX];
	BOOL onDriver;
	BOOL inDispatch;
	BOOL failed;
} ClientPdu;

typedef enum
{
	CB_CAPS = 0,
	CB_READY,
	CB_LIST,
	CB_REQUEST,
	CB_RESPONSE
} CallbackId;

typedef struct
{
	CallbackId which;
	UINT rc;
	pthread_t thread;
	BOOL onDriver;
} CallbackCall;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static ClientPdu g_pdus[MAX_PDUS];
static size_t g_pduCount = 0; /* counts beyond MAX_PDUS too */
static CallbackCall g_calls[MAX_CALLS];
static size_t g_callCount = 0;
static UINT16 g_failType = 0; /* fail the next write of this msgType once */
static unsigned g_barrierSeen = 0;
static size_t g_dataResponseCalls = 0;
static size_t g_dataResponseWouldAbort = 0;
/* Self-check hooks: a broken callback in place of a bridge callback. */
static BOOL g_brokenList = FALSE;
static BOOL g_brokenReadySendsRequest = FALSE;

static UINT VCAPITYPE fake_init_ex(LPVOID userParam, LPVOID clientContext, LPVOID initHandle,
                                   WINPR_ATTR_UNUSED PCHANNEL_DEF channel,
                                   WINPR_ATTR_UNUSED INT channelCount,
                                   WINPR_ATTR_UNUSED ULONG version, PCHANNEL_INIT_EVENT_EX_FN initEvent)
{
	if (initHandle != (LPVOID)&g_inst.initHandle)
		g_foreignHandle = TRUE;
	g_inst.userParam = userParam;
	g_inst.channel = clientContext;
	g_inst.initEvent = initEvent;
	return CHANNEL_RC_OK;
}

static UINT VCAPITYPE fake_open_ex(LPVOID initHandle, LPDWORD openHandle, WINPR_ATTR_UNUSED PCHAR name,
                                   PCHANNEL_OPEN_EVENT_EX_FN openEvent)
{
	if (initHandle != (LPVOID)&g_inst.initHandle)
		g_foreignHandle = TRUE;
	*openHandle = 0x51;
	g_inst.openHandle = 0x51;
	g_inst.openEvent = openEvent;
	return CHANNEL_RC_OK;
}

static UINT VCAPITYPE fake_close_ex(LPVOID initHandle, WINPR_ATTR_UNUSED DWORD openHandle)
{
	if (initHandle != (LPVOID)&g_inst.initHandle)
		g_foreignHandle = TRUE;
	return CHANNEL_RC_OK;
}

static UINT16 le16(const BYTE* p)
{
	return (UINT16)(p[0] | (p[1] << 8));
}

static UINT32 le32(const BYTE* p)
{
	return (UINT32)p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}

/* The channel manager's write: records the PDU (header and the first BODY_MAX body bytes), the
 * thread it came from and whether the outbound dispatch was running there. A real manager queues
 * the data and frees the stream on WRITE_COMPLETE; this one frees it at once. On a failed write
 * the channel frees the stream itself. */
static UINT VCAPITYPE fake_write_ex(LPVOID initHandle, WINPR_ATTR_UNUSED DWORD openHandle, LPVOID data,
                                    ULONG length, LPVOID userData)
{
	const BYTE* bytes = (const BYTE*)data;
	BOOL fail = FALSE;
	pthread_mutex_lock(&g_lock);
	if (initHandle != (LPVOID)&g_inst.initHandle)
		g_foreignHandle = TRUE;
	const size_t index = g_pduCount++;
	ClientPdu pdu;
	memset(&pdu, 0, sizeof(pdu));
	if (bytes && length >= 8)
	{
		pdu.msgType = le16(bytes);
		pdu.msgFlags = le16(bytes + 2);
		pdu.dataLen = le32(bytes + 4);
		pdu.bodyLen = (length - 8 < BODY_MAX) ? (length - 8) : BODY_MAX;
		memcpy(pdu.body, bytes + 8, pdu.bodyLen);
	}
	pdu.onDriver = pthread_equal(pthread_self(), g_driver);
	pdu.inDispatch = t_inDispatch;
	if (g_failType != 0 && pdu.msgType == g_failType)
	{
		fail = TRUE;
		g_failType = 0;
	}
	pdu.failed = fail;
	if (index < MAX_PDUS)
		g_pdus[index] = pdu;
	pthread_mutex_unlock(&g_lock);
	if (fail)
		return INJECTED_ERROR;
	if (userData)
		Stream_Free((wStream*)userData, TRUE);
	return CHANNEL_RC_OK;
}

static void record_call(CallbackId which, UINT rc)
{
	edge_release(&g_joinEdge); /* whatever this callback wrote, before T_clip is joined */
	pthread_mutex_lock(&g_lock);
	if (g_callCount < MAX_CALLS)
	{
		CallbackCall* call = &g_calls[g_callCount];
		call->which = which;
		call->rc = rc;
		call->thread = pthread_self();
		call->onDriver = pthread_equal(call->thread, g_driver);
	}
	g_callCount++;
	pthread_mutex_unlock(&g_lock);
}

/* Shims in front of the bridge's five callbacks: forward, record the return value and thread. */
static UINT shim_caps(CliprdrClientContext* context, const CLIPRDR_CAPABILITIES* caps)
{
	edge_acquire(&g_queueEdge);
	const UINT rc = g_inst.bridgeCaps(context, caps);
	record_call(CB_CAPS, rc);
	return rc;
}

static UINT shim_ready(CliprdrClientContext* context, const CLIPRDR_MONITOR_READY* ready)
{
	edge_acquire(&g_queueEdge);
	UINT rc = g_inst.bridgeReady(context, ready);
	if (g_brokenReadySendsRequest)
	{
		/* Self-check 4: the object under test made "bad" -- a data request from T_clip. */
		CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
		request.common.msgType = CB_FORMAT_DATA_REQUEST;
		request.requestedFormatId = CF_UNICODETEXT;
		(void)context->ClientFormatDataRequest(context, &request);
	}
	record_call(CB_READY, rc);
	return rc;
}

static UINT shim_list(CliprdrClientContext* context, const CLIPRDR_FORMAT_LIST* list)
{
	edge_acquire(&g_queueEdge);
	UINT rc = g_inst.bridgeList(context, list);
	if (g_brokenList)
		rc = ERROR_INTERNAL_ERROR; /* self-check 3: a callback made "bad" */
	record_call(CB_LIST, rc);
	return rc;
}

static UINT shim_request(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	edge_acquire(&g_queueEdge);
	const UINT rc = g_inst.bridgeRequest(context, request);
	record_call(CB_REQUEST, rc);
	return rc;
}

static UINT shim_response(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	edge_acquire(&g_queueEdge);
	const UINT rc = g_inst.bridgeResponse(context, response);
	record_call(CB_RESPONSE, rc);
	return rc;
}

/* In front of the channel's own data-response function: counts every call. When the live mask
 * carries no Mac -> Windows bit the real function would abort the process (self-check 1 proves
 * it), so such a call is recorded and NOT forwarded -- the run reports it instead of dying. */
static UINT shim_data_response(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	const UINT32 mask = freerdp_settings_get_uint32(g_context->settings, FreeRDP_ClipboardFeatureMask);
	pthread_mutex_lock(&g_lock);
	g_dataResponseCalls++;
	const BOOL wouldAbort = (mask & (CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES)) == 0;
	if (wouldAbort)
		g_dataResponseWouldAbort++;
	pthread_mutex_unlock(&g_lock);
	if (wouldAbort)
		return CHANNEL_RC_OK;
	return g_inst.realDataResponse(context, response);
}

/* The barrier: the channel calls this for a server Format List Response, on T_clip, after every
 * PDU fed before it. The bridge installs nothing for that PDU. */
static UINT barrier_cb(WINPR_ATTR_UNUSED CliprdrClientContext* context,
                       WINPR_ATTR_UNUSED const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	edge_acquire(&g_queueEdge);
	pthread_mutex_lock(&g_lock);
	g_barrierSeen++;
	pthread_cond_broadcast(&g_cond);
	pthread_mutex_unlock(&g_lock);
	return CHANNEL_RC_OK;
}

/* Feeds what the server encoder wrote to the channel, as one complete chunk. */
static BOOL feed_server_out(void)
{
	if (g_serverOutLen == 0 || !g_inst.openEvent)
		return FALSE;
	edge_release(&g_queueEdge); /* everything the driver did before this PDU, for T_clip */
	g_inst.openEvent(g_inst.userParam, g_inst.openHandle, CHANNEL_EVENT_DATA_RECEIVED, g_serverOut,
	                 (UINT32)g_serverOutLen, (UINT32)g_serverOutLen, CHANNEL_FLAG_FIRST | CHANNEL_FLAG_LAST);
	g_serverOutLen = 0;
	return TRUE;
}

static BOOL srv_caps(UINT32 generalFlags)
{
	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = generalFlags;
	CLIPRDR_CAPABILITIES caps = { 0 };
	caps.common.msgType = CB_CLIP_CAPS;
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)(void*)&general;
	g_serverOutLen = 0;
	return g_server->ServerCapabilities(g_server, &caps) == CHANNEL_RC_OK && feed_server_out();
}

static BOOL srv_ready(void)
{
	CLIPRDR_MONITOR_READY ready = { 0 };
	ready.common.msgType = CB_MONITOR_READY;
	g_serverOutLen = 0;
	return g_server->MonitorReady(g_server, &ready) == CHANNEL_RC_OK && feed_server_out();
}

static BOOL srv_list(const CLIPRDR_FORMAT* formats, UINT32 count, BOOL longNames)
{
	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = count;
	list.formats = (CLIPRDR_FORMAT*)formats;
	g_server->useLongFormatNames = longNames;
	g_serverOutLen = 0;
	return g_server->ServerFormatList(g_server, &list) == CHANNEL_RC_OK && feed_server_out();
}

static BOOL srv_request(UINT32 formatId)
{
	CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
	request.common.msgType = CB_FORMAT_DATA_REQUEST;
	request.requestedFormatId = formatId;
	g_serverOutLen = 0;
	return g_server->ServerFormatDataRequest(g_server, &request) == CHANNEL_RC_OK && feed_server_out();
}

static BOOL srv_response(UINT16 msgFlags, const BYTE* data, UINT32 length)
{
	CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	response.common.msgFlags = msgFlags;
	response.common.dataLen = length;
	response.requestedFormatData = data;
	g_serverOutLen = 0;
	return g_server->ServerFormatDataResponse(g_server, &response) == CHANNEL_RC_OK && feed_server_out();
}

/* Sends the barrier PDU and waits until T_clip has called back for it. FALSE: T_clip did not get
 * there within BARRIER_SECONDS (it stopped, or never ran). */
static BOOL barrier(void)
{
	pthread_mutex_lock(&g_lock);
	const unsigned target = g_barrierSeen + 1;
	pthread_mutex_unlock(&g_lock);
	CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	g_serverOutLen = 0;
	if (g_server->ServerFormatListResponse(g_server, &response) != CHANNEL_RC_OK || !feed_server_out())
		return FALSE;
	struct timespec deadline;
	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += BARRIER_SECONDS;
	pthread_mutex_lock(&g_lock);
	int rc = 0;
	while (g_barrierSeen < target && rc != ETIMEDOUT)
		rc = pthread_cond_timedwait(&g_cond, &g_lock, &deadline);
	const BOOL reached = g_barrierSeen >= target;
	pthread_mutex_unlock(&g_lock);
	return reached;
}

/* Loads a fresh channel instance for `mode`: the bridge's own settings step on the shared settings,
 * the entry point, CHANNEL_EVENT_CONNECTED (T_clip starts), then -- as CRSession.mm's
 * channel-connected branch does -- the bridge attaches when the mode installs callbacks. */
static const char* inst_open(uint32_t mode)
{
	/* A channel error left by an earlier channel instance (a case that already FAILed because a
	 * callback stopped T_clip) belongs to that instance: clear it, so the next instance is judged
	 * on its own and the run ends as FAIL (1), not as a harness ERROR (2). */
	if (getChannelError(g_context) != CHANNEL_RC_OK)
	{
		setChannelError(g_context, CHANNEL_RC_OK, "%s", "");
		(void)ResetEvent(getChannelErrorEventHandle(g_context));
	}
	memset(&g_inst, 0, sizeof(g_inst));
	g_inst.mode = mode;
	if (!crclip_apply_mode(g_context->settings, mode))
		return "the bridge's settings step refused the mode";
	PVIRTUALCHANNELENTRYEX entryEx = WINPR_FUNC_PTR_CAST(
	    freerdp_channels_load_static_addin_entry(CLIPRDR_SVC_CHANNEL_NAME, NULL, NULL,
	                                             FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX),
	    PVIRTUALCHANNELENTRYEX);
	if (!entryEx)
		return "the prefix has no built-in cliprdr channel entry (VirtualChannelEntryEx)";
	CHANNEL_ENTRY_POINTS_FREERDP_EX entry = { 0 };
	entry.cbSize = sizeof(entry);
	entry.protocolVersion = VIRTUAL_CHANNEL_VERSION_WIN2000;
	entry.pVirtualChannelInitEx = fake_init_ex;
	entry.pVirtualChannelOpenEx = fake_open_ex;
	entry.pVirtualChannelCloseEx = fake_close_ex;
	entry.pVirtualChannelWriteEx = fake_write_ex;
	entry.MagicNumber = FREERDP_CHANNEL_MAGIC_NUMBER;
	entry.context = g_context;
	if (!entryEx((PCHANNEL_ENTRY_POINTS_EX)&entry, &g_inst.initHandle) || !g_inst.channel || !g_inst.initEvent)
		return "the cliprdr channel's VirtualChannelEntryEx failed or registered no client context";
	g_inst.live = TRUE;
	return NULL;
}

static const char* inst_connect(void)
{
	g_inst.initEvent(g_inst.userParam, &g_inst.initHandle, CHANNEL_EVENT_CONNECTED, NULL, 0);
	if (!g_inst.openEvent || getChannelError(g_context) != CHANNEL_RC_OK)
		return "CHANNEL_EVENT_CONNECTED did not open the channel";
	g_inst.connected = TRUE;
	if (!crclip_bridge_init(&g_bridge, g_inst.mode, g_control, g_store, g_counters))
		return "crclip_bridge_init refused a complete set of lanes";
	CliprdrClientContext* channel = g_inst.channel;
	if (crclip_mode_installs_callbacks(g_inst.mode) && crclip_bridge_attach(&g_bridge, channel))
	{
		g_inst.attached = TRUE;
		g_inst.bridgeCaps = channel->ServerCapabilities;
		g_inst.bridgeReady = channel->MonitorReady;
		g_inst.bridgeList = channel->ServerFormatList;
		g_inst.bridgeRequest = channel->ServerFormatDataRequest;
		g_inst.bridgeResponse = channel->ServerFormatDataResponse;
		if (!g_inst.bridgeCaps || !g_inst.bridgeReady || !g_inst.bridgeList || !g_inst.bridgeRequest ||
		    !g_inst.bridgeResponse)
			return "the bridge attached without installing its five server callbacks";
		channel->ServerCapabilities = shim_caps;
		channel->MonitorReady = shim_ready;
		channel->ServerFormatList = shim_list;
		channel->ServerFormatDataRequest = shim_request;
		channel->ServerFormatDataResponse = shim_response;
	}
	g_inst.realDataResponse = channel->ClientFormatDataResponse;
	channel->ClientFormatDataResponse = shim_data_response;
	channel->ServerFormatListResponse = barrier_cb;
	return NULL;
}

/* The disconnect order FreeRDP uses: CHANNEL_EVENT_DISCONNECTED (T_clip is joined), then the
 * PubSub channel-disconnected callback, where CRSession.mm detaches the bridge. */
static void inst_disconnect(void)
{
	if (g_inst.connected)
	{
		g_inst.initEvent(g_inst.userParam, &g_inst.initHandle, CHANNEL_EVENT_DISCONNECTED, NULL, 0);
		edge_acquire(&g_joinEdge); /* T_clip has been joined */
	}
	g_inst.connected = FALSE;
	if (g_inst.attached)
		crclip_bridge_detach(&g_bridge, g_inst.channel);
	g_inst.attached = FALSE;
}

static void inst_terminate(void)
{
	inst_disconnect();
	if (g_inst.live)
		g_inst.initEvent(g_inst.userParam, &g_inst.initHandle, CHANNEL_EVENT_TERMINATED, NULL, 0);
	g_inst.live = FALSE;
}

/* ==================================================================================== *
 * T_main and T_rdp, played by the driver thread.
 * ==================================================================================== */

typedef struct
{
	CrdpEvent events[MAX_EVENTS];
	size_t count;
} Drained;

static void collect_event(const CrdpEvent* ev, void* vctx)
{
	Drained* d = vctx;
	if (d->count < MAX_EVENTS)
		d->events[d->count] = *ev;
	d->count++;
}

static size_t drain_events(Drained* d)
{
	memset(d, 0, sizeof(*d));
	(void)crdpq_drain(g_control, collect_event, d);
	return d->count;
}

static void dispatch_visitor(const CrdpCommand* command, WINPR_ATTR_UNUSED void* vctx)
{
	t_inDispatch = TRUE;
	(void)crclip_outbound_dispatch(&g_bridge, command);
	t_inDispatch = FALSE;
}

static void drain_outbound(void)
{
	(void)crdpq_outbound_drain(g_outbound, dispatch_visitor, NULL);
}

static BOOL dispatch_one(const CrdpCommand* command)
{
	t_inDispatch = TRUE;
	const BOOL handled = crclip_outbound_dispatch(&g_bridge, command) ? TRUE : FALSE;
	t_inDispatch = FALSE;
	return handled;
}

static CrdpCommand clip_command(crdpq_command_type_t type, uint32_t generation, uint32_t key, uint32_t formatId,
                                uint32_t byteCount, uint32_t status)
{
	CrdpCommand command;
	memset(&command, 0, sizeof(command));
	command.type = type;
	command.payload.clip.storeGeneration = generation;
	command.payload.clip.sequence = key;
	command.payload.clip.formatId = formatId;
	command.payload.clip.byteCount = byteCount;
	command.payload.clip.status = status;
	return command;
}

/* T_main's answer, through the bridge's own T_main function (what CRSession.mm forwards to): the
 * bytes into the store under a fresh key, then the RESPOND on the outbound lane. */
static uint32_t g_answerKey = 1000;
static crclip_respond_result_t answer(uint32_t generation, BOOL withBytes, const BYTE* bytes, size_t length)
{
	crdpq_clip_ref_t request;
	memset(&request, 0, sizeof(request));
	request.storeGeneration = generation;
	request.formatId = CF_UNICODETEXT;
	return crclip_respond(g_outbound, g_store, g_counters, ++g_answerKey, &request, withBytes ? true : false, bytes,
	                      length);
}

/* The commands queued on the outbound lane, taken off it without dispatching, so a case can hand
 * them to the dispatch one at a time (T_rdp handles one, then something happens, then the next). */
typedef struct
{
	CrdpCommand commands[8];
	size_t count;
} Held;

static void hold_command(const CrdpCommand* command, void* vctx)
{
	Held* held = vctx;
	if (held->count < ARRAYSIZE(held->commands))
		held->commands[held->count] = *command;
	held->count++;
}

typedef struct
{
	BYTE* out;
	size_t capacity;
	size_t length;
	BOOL called;
} Reader;

static void read_into(const uint8_t* bytes, size_t length, void* context)
{
	Reader* r = context;
	r->called = TRUE;
	r->length = length;
	if (length <= r->capacity && bytes)
		memcpy(r->out, bytes, length);
}

/* T_main's take, through the bridge's crclip_take_remote. */
static BOOL take_remote(const CrdpEvent* ev, BYTE* out, size_t capacity, size_t* length)
{
	Reader r = { out, capacity, 0, FALSE };
	const BOOL taken = crclip_take_remote(g_store, &ev->payload.clip, read_into, &r) ? TRUE : FALSE;
	*length = r.length;
	return taken && r.called && r.length <= capacity;
}

/* ==================================================================================== *
 * Cases
 * ==================================================================================== */

typedef struct
{
	size_t pdu;
	size_t call;
	size_t dataResponseCalls;
	size_t dataResponseWouldAbort;
	uint64_t counters[CRCLIP_COUNTER_COUNT];
} Mark;

static size_t g_casesRun = 0;
static size_t g_casesFailed = 0;
static size_t g_harnessErrors = 0;
static Mark g_mark;
static char g_why[512];
static pthread_t g_clipThread;
static BOOL g_clipThreadKnown = FALSE;

static void mark(void)
{
	pthread_mutex_lock(&g_lock);
	g_mark.pdu = g_pduCount;
	g_mark.call = g_callCount;
	g_mark.dataResponseCalls = g_dataResponseCalls;
	g_mark.dataResponseWouldAbort = g_dataResponseWouldAbort;
	pthread_mutex_unlock(&g_lock);
	for (size_t i = 0; i < CRCLIP_COUNTER_COUNT; i++)
		g_mark.counters[i] = crclip_counters_get(g_counters, (crclip_counter_t)i);
	g_why[0] = '\0';
}

static uint64_t counter_delta(crclip_counter_t counter)
{
	return crclip_counters_get(g_counters, counter) - g_mark.counters[counter];
}

static BOOL counters_unchanged_except(crclip_counter_t allowed, uint64_t expected)
{
	for (size_t i = 0; i < CRCLIP_COUNTER_COUNT; i++)
	{
		const uint64_t delta = counter_delta((crclip_counter_t)i);
		if ((crclip_counter_t)i == allowed ? delta != expected : delta != 0)
			return FALSE;
	}
	return TRUE;
}

static void why(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void why(const char* fmt, ...)
{
	if (g_why[0] != '\0')
		return; /* the first reason wins */
	va_list ap;
	va_start(ap, fmt);
	(void)vsnprintf(g_why, sizeof(g_why), fmt, ap);
	va_end(ap);
}

/* The PDUs written since the mark, as a view. */
static size_t pdus_since(const ClientPdu** out)
{
	pthread_mutex_lock(&g_lock);
	const size_t end = g_pduCount < MAX_PDUS ? g_pduCount : MAX_PDUS;
	const size_t start = g_mark.pdu < end ? g_mark.pdu : end;
	pthread_mutex_unlock(&g_lock);
	*out = &g_pdus[start];
	return end - start;
}

/* The checks every case makes (adr/0026 H-1, H-2, H-10, the real T_clip). */
static void common_checks(void)
{
	pthread_mutex_lock(&g_lock);
	const size_t callEnd = g_callCount < MAX_CALLS ? g_callCount : MAX_CALLS;
	for (size_t i = g_mark.call; i < callEnd; i++)
	{
		const CallbackCall* call = &g_calls[i];
		if (call->rc != CHANNEL_RC_OK)
			why("a bridge callback returned 0x%08X (H-1)", call->rc);
		if (call->onDriver)
			why("a bridge callback ran on the driver thread, not on the channel's own thread");
		if (!g_clipThreadKnown)
		{
			g_clipThread = call->thread;
			g_clipThreadKnown = TRUE;
		}
		else if (!pthread_equal(g_clipThread, call->thread))
			why("two bridge callbacks of one channel instance ran on different threads");
	}
	if (g_callCount > MAX_CALLS || g_pduCount > MAX_PDUS)
		why("the capture overflowed");
	if (g_dataResponseWouldAbort != g_mark.dataResponseWouldAbort)
		why("the data-response function was called under a mask without Mac -> Windows (it would abort) (H-2)");
	pthread_mutex_unlock(&g_lock);
	if (getChannelError(g_context) != CHANNEL_RC_OK)
		why("the channel raised error 0x%08X", getChannelError(g_context));
	if (g_foreignHandle)
		why("a channel call carried an init handle that is not the instance's (a harness fault)");
	const ClientPdu* pdus = NULL;
	const size_t n = pdus_since(&pdus);
	for (size_t i = 0; i < n; i++)
	{
		const ClientPdu* p = &pdus[i];
		if (!p->onDriver)
		{
			const BOOL ownFailure = !crclip_mode_allows_local_to_remote(g_inst.mode) &&
			                        p->msgType == CB_FORMAT_DATA_RESPONSE && p->msgFlags == CB_RESPONSE_FAIL &&
			                        p->dataLen == 0;
			if (p->msgType != CB_CLIP_CAPS && p->msgType != CB_FORMAT_LIST_RESPONSE && !ownFailure)
				why("T_clip sent msgType 0x%04X (only capabilities and format list responses may leave T_clip, H-10)",
				    p->msgType);
		}
		else if (!p->inDispatch)
			why("the driver thread sent msgType 0x%04X outside the outbound dispatch", p->msgType);
	}
}

static BOOL g_harnessFault = FALSE;

/* A checkpoint inside a case: the common checks over what happened since the last mark, then a
 * new mark -- unless a reason is already recorded, which then stays the case's verdict. */
static void remark(void)
{
	common_checks();
	if (g_why[0] == '\0')
		mark();
}

static size_t calls_since_mark(void)
{
	pthread_mutex_lock(&g_lock);
	const size_t calls = g_callCount - g_mark.call;
	pthread_mutex_unlock(&g_lock);
	return calls;
}

static size_t data_response_calls_since_mark(void)
{
	pthread_mutex_lock(&g_lock);
	const size_t calls = g_dataResponseCalls - g_mark.dataResponseCalls;
	pthread_mutex_unlock(&g_lock);
	return calls;
}

static void finish(size_t n, const char* name)
{
	common_checks();
	g_casesRun++;
	const char* word = "ok";
	if (g_harnessFault)
	{
		word = "ERROR: ";
		g_harnessErrors++;
	}
	else if (g_why[0] != '\0')
	{
		word = "FAIL: ";
		g_casesFailed++;
	}
	(void)printf("case %02zu: %-58s -> %s%s\n", n, name, word, g_why);
	g_harnessFault = FALSE;
}

static void harness(BOOL ok, const char* what)
{
	if (!ok)
	{
		g_harnessFault = TRUE;
		why("%s", what);
	}
}

/* One server step: the encoder must have produced its PDU (else the harness is at fault), and
 * T_clip must get through the barrier after it (else the bridge stopped or hung the channel's
 * thread -- what a non-zero callback return does -- which is a failure of the object under test). */
static void fed(BOOL produced, const char* what)
{
	if (!produced)
		harness(FALSE, what);
	else if (!barrier())
		why("T_clip stopped or hung after: %s (a callback that returns non-zero ends the channel thread, H-1)", what);
}

/* A T_main call of the bridge (crclip_announce / crclip_request / crclip_respond) that should have
 * succeeded: these functions are part of the object under test, so a failure is a FAIL, never a
 * harness fault. */
static void bridge_ok(BOOL ok, const char* what)
{
	if (!ok)
		why("a T_main call of the bridge failed: %s", what);
}

static const ClientPdu* only_pdu(UINT16 msgType, BOOL fromClipThread)
{
	const ClientPdu* pdus = NULL;
	const size_t n = pdus_since(&pdus);
	if (n != 1)
	{
		why("expected exactly one client PDU 0x%04X, got %zu", msgType, n);
		return NULL;
	}
	if (pdus[0].msgType != msgType)
	{
		why("expected client PDU 0x%04X, got 0x%04X", msgType, pdus[0].msgType);
		return NULL;
	}
	if (fromClipThread == pdus[0].onDriver)
	{
		why("client PDU 0x%04X left from the wrong thread", msgType);
		return NULL;
	}
	return &pdus[0];
}

static const CrdpEvent* only_event(Drained* d, crdpq_event_type_t type)
{
	drain_events(d);
	if (d->count != 1 || d->events[0].type != type)
	{
		why("expected exactly one event %d, got %zu (first %d)", (int)type, d->count,
		    d->count ? (int)d->events[0].type : -1);
		return NULL;
	}
	if (d->events[0].payload.clip.storeGeneration != g_bridge.storeGeneration)
		why("the event's store generation %u is not the channel's %u", d->events[0].payload.clip.storeGeneration,
		    g_bridge.storeGeneration);
	return &d->events[0];
}

static void expect_no_pdu(void)
{
	const ClientPdu* pdus = NULL;
	const size_t n = pdus_since(&pdus);
	if (n != 0)
		why("expected no client PDU, got %zu (first 0x%04X)", n, pdus[0].msgType);
}

static void expect_no_event(void)
{
	Drained d;
	if (drain_events(&d) != 0)
		why("expected no event, got %zu (first %d)", d.count, (int)d.events[0].type);
}

static void expect_store_empty(void)
{
	if (crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_REMOTE_TO_LOCAL) != 0 ||
	    crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_LOCAL_TO_REMOTE) != 0)
		why("the store still holds %zu inbound and %zu outbound blocks",
		    crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_REMOTE_TO_LOCAL),
		    crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_LOCAL_TO_REMOTE));
}

static void expect_format_list_flags(const CLIPRDR_FORMAT* formats, UINT32 count, BOOL longNames, uint32_t flags)
{
	fed(srv_list(formats, count, longNames), "the server format list did not reach T_clip");
	const ClientPdu* flr = only_pdu(CB_FORMAT_LIST_RESPONSE, TRUE);
	if (flr && (flr->msgFlags != CB_RESPONSE_OK || flr->dataLen != 0))
		why("the format list response is not a bare OK (flags 0x%04X, %u bytes)", flr->msgFlags, flr->dataLen);
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_FORMATS);
	if (ev && ev->payload.clip.flags != flags)
		why("REMOTE_FORMATS flags 0x%X, expected 0x%X", ev->payload.clip.flags, flags);
	if (ev && (ev->payload.clip.formatId != 0 || ev->payload.clip.byteCount != 0 || ev->payload.clip.status != 0))
		why("REMOTE_FORMATS carries more than its flags");
}

/* ---- the cases ---- */

static const CLIPRDR_FORMAT g_withText[] = { { CF_UNICODETEXT, NULL }, { FIXTURE_FORMAT_ID, (char*)g_fixtureFormatName } };
static const CLIPRDR_FORMAT g_withoutText[] = { { CF_TEXT, NULL }, { FIXTURE_FORMAT_ID, (char*)g_fixtureFormatName } };

static void case_caps_and_ready(size_t n)
{
	mark();
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
	                 CB_CAN_LOCK_CLIPDATA) &&
	            srv_ready(), "the server's capabilities and monitor ready did not reach T_clip");
	const ClientPdu* caps = only_pdu(CB_CLIP_CAPS, TRUE);
	if (caps && (caps->bodyLen != 16 || le16(caps->body) != 1 || le16(caps->body + 4) != CB_CAPSTYPE_GENERAL ||
	             le16(caps->body + 6) != CB_CAPSTYPE_GENERAL_LEN || le32(caps->body + 8) != CB_CAPS_VERSION_2 ||
	             le32(caps->body + 12) != CB_USE_LONG_FORMAT_NAMES))
		why("the client capabilities are not one general set, version 2, long format names only (flags 0x%X)",
		    caps->bodyLen >= 16 ? le32(caps->body + 12) : 0);
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_READY);
	if (ev && (ev->payload.clip.flags != 0 || ev->payload.clip.byteCount != 0))
		why("READY carries more than its store generation");
	if (calls_since_mark() != 2)
		why("expected the capabilities and monitor-ready callbacks, got %zu calls", calls_since_mark());
	common_checks(); /* records the channel thread from the first callback */
	if (!g_clipThreadKnown || pthread_equal(g_clipThread, g_driver))
		why("the callbacks did not run on a thread of their own");
	finish(n, "capabilities, then ready (Bidirectional, long names)");
}

static void case_list_with_text(size_t n)
{
	mark();
	expect_format_list_flags(g_withText, ARRAYSIZE(g_withText), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	finish(n, "format list naming CF_UNICODETEXT");
}

static void case_list_without_text(size_t n)
{
	mark();
	expect_format_list_flags(g_withoutText, ARRAYSIZE(g_withoutText), TRUE, 0);
	finish(n, "format list without CF_UNICODETEXT");
}

static void case_exclusion_names(size_t n)
{
	mark();
	for (size_t i = 0; i < ARRAYSIZE(g_exclusionNames) && g_why[0] == '\0'; i++)
	{
		const CLIPRDR_FORMAT list[] = { { CF_UNICODETEXT, NULL }, { 0xC200u + (UINT32)i, (char*)g_exclusionNames[i] } };
		if (i > 0)
			remark();
		expect_format_list_flags(list, ARRAYSIZE(list), TRUE,
		                         CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED);
	}
	finish(n, "each exclusion name with CF_UNICODETEXT (long names)");
}

static void case_exclusion_without_text(size_t n)
{
	mark();
	const CLIPRDR_FORMAT list[] = { { 0xC210u, (char*)g_exclusionNames[2] } };
	expect_format_list_flags(list, ARRAYSIZE(list), TRUE, CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED);
	finish(n, "an exclusion name without CF_UNICODETEXT");
}

static void case_empty_list(size_t n)
{
	mark();
	expect_format_list_flags(NULL, 0, TRUE, 0);
	finish(n, "empty format list");
}

static void case_request_then_answer(size_t n)
{
	mark();
	fed(srv_request(CF_UNICODETEXT), "the server data request did not reach T_clip");
	expect_no_pdu(); /* T_clip answers nothing */
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_DATA_REQUEST);
	if (ev && ev->payload.clip.formatId != CF_UNICODETEXT)
		why("DATA_REQUEST formatId %u", ev->payload.clip.formatId);
	if (ev)
	{
		if (answer(ev->payload.clip.storeGeneration, TRUE, g_fixtureWire, g_fixtureWireLen) != CRCLIP_RESPOND_POSTED)
			why("the answer was not stored and posted");
		drain_outbound();
		const ClientPdu* resp = only_pdu(CB_FORMAT_DATA_RESPONSE, FALSE);
		if (resp && (resp->msgFlags != CB_RESPONSE_OK || resp->dataLen != g_fixtureWireLen ||
		             resp->bodyLen != g_fixtureWireLen || memcmp(resp->body, g_fixtureWire, g_fixtureWireLen) != 0))
			why("the data response does not carry the answer's bytes with OK");
		if (data_response_calls_since_mark() != 1)
			why("the data-response function was called %zu times", data_response_calls_since_mark());
	}
	expect_store_empty();
	finish(n, "server data request: no answer on T_clip, OK answer from dispatch");
}

static void case_request_failure_answer(size_t n)
{
	mark();
	fed(srv_request(CF_UNICODETEXT), "the server data request did not reach T_clip");
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_DATA_REQUEST);
	if (ev)
	{
		if (answer(ev->payload.clip.storeGeneration, FALSE, NULL, 0) != CRCLIP_RESPOND_POSTED)
			why("the failure answer was not posted");
		drain_outbound();
		const ClientPdu* resp = only_pdu(CB_FORMAT_DATA_RESPONSE, FALSE);
		if (resp && (resp->msgFlags != CB_RESPONSE_FAIL || resp->dataLen != 0))
			why("the failure answer is not FAIL with no data");
	}
	finish(n, "server data request answered with a failure");
}

static void case_request_other_format(size_t n)
{
	mark();
	fed(srv_request(CF_TEXT), "the server data request did not reach T_clip");
	expect_no_pdu();
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_DATA_REQUEST);
	if (ev && ev->payload.clip.formatId != CF_TEXT)
		why("DATA_REQUEST formatId %u, expected the format asked for", ev->payload.clip.formatId);
	finish(n, "server data request for another format is handed on as is");
}

static void case_response_ok(size_t n)
{
	mark();
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "the server data response did not reach T_clip");
	expect_no_pdu();
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev)
	{
		if (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || ev->payload.clip.byteCount != g_fixtureWireLen)
			why("REMOTE_DATA status %u byteCount %u", ev->payload.clip.status, ev->payload.clip.byteCount);
		BYTE out[256];
		size_t length = 0;
		if (!take_remote(ev, out, sizeof(out), &length) || length != g_fixtureWireLen ||
		    memcmp(out, g_fixtureWire, length) != 0)
			why("the stored bytes are not the response's bytes");
	}
	expect_store_empty();
	finish(n, "server data response OK: copied into the store, taken");
}

static void case_response_fail(size_t n)
{
	mark();
	fed(srv_response(CB_RESPONSE_FAIL, NULL, 0), "the server data response did not reach T_clip");
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_FAILED || ev->payload.clip.byteCount != 0))
		why("REMOTE_DATA status %u byteCount %u for a FAIL", ev->payload.clip.status, ev->payload.clip.byteCount);
	expect_store_empty();
	finish(n, "server data response FAIL");
}

static void case_limits(size_t n, BYTE* big)
{
	mark();
	fed(srv_response(CB_RESPONSE_OK, big, (UINT32)g_limit), "the at-limit response did not reach T_clip");
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev)
	{
		if (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || ev->payload.clip.byteCount != g_limit)
			why("an at-limit response was not stored (status %u)", ev->payload.clip.status);
		BYTE* out = malloc(g_limit);
		size_t length = 0;
		if (!out || !take_remote(ev, out, g_limit, &length) || length != g_limit || memcmp(out, big, g_limit) != 0)
			why("the at-limit bytes did not come back whole");
		free(out);
	}
	const size_t before = crdpq_clip_store_refusal_count(g_store, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE);
	fed(srv_response(CB_RESPONSE_OK, big, (UINT32)g_limit + 1), "the over-limit response did not reach T_clip");
	ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_NOT_STORED || ev->payload.clip.byteCount != g_limit + 1))
		why("an over-limit response: status %u byteCount %u", ev->payload.clip.status, ev->payload.clip.byteCount);
	if (crdpq_clip_store_refusal_count(g_store, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE) != before + 1)
		why("the over-limit refusal was not the block limit's");
	if (!counters_unchanged_except(CRCLIP_COUNTER_REMOTE_DATA_NOT_STORED, 1))
		why("counters: expected exactly one not-stored");
	expect_store_empty();
	finish(n, "responses at the limit (stored) and one byte over (not copied)");
}

static void case_repeated_over_limit(size_t n, BYTE* big)
{
	mark();
	Drained d;
	for (int i = 0; i < 3; i++)
	{
		fed(srv_response(CB_RESPONSE_OK, big, (UINT32)g_limit + 1 + (UINT32)i), "an over-limit response did not reach T_clip");
		const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
		if (ev && ev->payload.clip.status != CRDPQ_CLIP_STATUS_NOT_STORED)
			why("over-limit response %d was stored", i);
	}
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "the next response did not reach T_clip");
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	BYTE out[256];
	size_t length = 0;
	if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || !take_remote(ev, out, sizeof(out), &length) ||
	           length != g_fixtureWireLen))
		why("the response after three over-limit ones was not stored and taken");
	if (!counters_unchanged_except(CRCLIP_COUNTER_REMOTE_DATA_NOT_STORED, 3))
		why("counters: expected exactly three not-stored");
	expect_store_empty();
	finish(n, "three over-limit responses, then the next is still stored");
}

static void case_unexpected_flags(size_t n)
{
	mark();
	static const BYTE four[4] = { 1, 2, 3, 4 };
	Drained d;
	fed(srv_response(0, four, sizeof(four)), "the response did not reach T_clip");
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev && ev->payload.clip.status != CRDPQ_CLIP_STATUS_FAILED)
		why("a response with neither flag was not a failure");
	fed(srv_response(CB_RESPONSE_OK | CB_RESPONSE_FAIL, four, sizeof(four)), "the response did not reach T_clip");
	ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev && ev->payload.clip.status != CRDPQ_CLIP_STATUS_FAILED)
		why("a response with both flags was not a failure");
	if (!counters_unchanged_except(CRCLIP_COUNTER_REMOTE_DATA_FLAGS_UNEXPECTED, 2))
		why("counters: expected two unexpected-flags");
	expect_store_empty();
	finish(n, "responses with neither or both OK / FAIL flags are failures");
}

static void case_announce(size_t n)
{
	mark();
	bridge_ok(crclip_announce(g_outbound, g_counters, CRDPQ_CLIP_NO_FORMAT) &&
	            crclip_announce(g_outbound, g_counters, CF_UNICODETEXT) &&
	            crclip_announce(g_outbound, g_counters, CRDPQ_CLIP_NO_FORMAT),
	        "could not queue the announcements");
	drain_outbound();
	const ClientPdu* pdus = NULL;
	const size_t count = pdus_since(&pdus);
	if (count != 2 || pdus[0].msgType != CB_FORMAT_LIST || pdus[1].msgType != CB_FORMAT_LIST)
		why("expected two format lists (the later empty one is the channel's to drop), got %zu", count);
	else
	{
		if (pdus[0].dataLen != 0)
			why("the initial empty announcement is not an empty list");
		if (pdus[1].dataLen < 6 || le32(pdus[1].body) != CF_UNICODETEXT || pdus[1].dataLen != 6)
			why("the text announcement is not one entry naming CF_UNICODETEXT with no name");
		if (!pdus[0].onDriver || !pdus[1].onDriver)
			why("an announcement left from T_clip");
	}
	finish(n, "announcements: empty (initial), CF_UNICODETEXT");
}

static void case_request_command(size_t n)
{
	mark();
	bridge_ok(crclip_request(g_outbound, g_counters, CF_UNICODETEXT), "could not queue the request");
	drain_outbound();
	const ClientPdu* p = only_pdu(CB_FORMAT_DATA_REQUEST, FALSE);
	if (p && (p->dataLen != 4 || le32(p->body) != CF_UNICODETEXT))
		why("the data request does not ask for CF_UNICODETEXT");
	finish(n, "data request command");
}

static void fail_next(UINT16 msgType)
{
	pthread_mutex_lock(&g_lock);
	g_failType = msgType;
	pthread_mutex_unlock(&g_lock);
}

static void case_send_failures(size_t n)
{
	mark();
	Drained d;
	fail_next(CB_CLIP_CAPS);
	fed(srv_ready(), "T_clip stopped after a failed capabilities write");
	(void)only_event(&d, CRDPQ_EVENT_CLIP_READY);
	fail_next(CB_FORMAT_LIST_RESPONSE);
	fed(srv_list(g_withText, ARRAYSIZE(g_withText), TRUE), "T_clip stopped after a failed format list response write");
	/* The client's capabilities did not go out, so the server was never told the client reads long
	 * names: the list is read in crdpq.h's conservative direction (gate r1 m-3), and counted. */
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_FORMATS);
	if (ev && ev->payload.clip.flags != (CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED))
		why("the list after a failed capabilities write: flags 0x%X, expected 0x3 (no long names negotiated)",
		    ev->payload.clip.flags);
	fail_next(CB_FORMAT_LIST);
	CrdpCommand text = clip_command(CRDPQ_CMD_CLIP_ANNOUNCE, 0, 0, CF_UNICODETEXT, 0, 0);
	(void)dispatch_one(&text);
	fail_next(CB_FORMAT_DATA_REQUEST);
	CrdpCommand request = clip_command(CRDPQ_CMD_CLIP_REQUEST, 0, 0, CF_UNICODETEXT, 0, 0);
	(void)dispatch_one(&request);
	fail_next(CB_FORMAT_DATA_RESPONSE);
	bridge_ok(answer(g_bridge.storeGeneration, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED,
	        "could not store and post the answer");
	drain_outbound();
	if (counter_delta(CRCLIP_COUNTER_CAPABILITIES_SEND_FAILED) != 1 ||
	    counter_delta(CRCLIP_COUNTER_FORMAT_LIST_RESPONSE_SEND_FAILED) != 1 ||
	    counter_delta(CRCLIP_COUNTER_COMMAND_SEND_FAILED) != 3 ||
	    counter_delta(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES) != 1)
		why("counters: capabilities %llu, list response %llu, commands %llu, judged excluded %llu (expected 1, 1, 3, 1)",
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_CAPABILITIES_SEND_FAILED),
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_FORMAT_LIST_RESPONSE_SEND_FAILED),
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_COMMAND_SEND_FAILED),
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES));
	const ClientPdu* pdus = NULL;
	const size_t count = pdus_since(&pdus);
	size_t failed = 0;
	for (size_t i = 0; i < count; i++)
		failed += pdus[i].failed ? 1 : 0;
	if (failed != 5)
		why("%zu of the five injected write failures happened", failed);
	expect_store_empty();
	finish(n, "every send fails once: counted, T_clip goes on, entry wiped");
	/* The next case's Monitor Ready sends the capabilities again: long names are negotiated anew. */
}

static void case_ready_again(size_t n)
{
	mark();
	const uint32_t generation = g_bridge.storeGeneration;
	fed(srv_ready(), "the second monitor ready did not reach T_clip");
	(void)only_pdu(CB_CLIP_CAPS, TRUE);
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_READY);
	if (ev && ev->payload.clip.storeGeneration != generation)
		why("a second ready on the same channel changed the store generation");
	finish(n, "monitor ready again on the same channel");
}

static void case_rail_independent(size_t n)
{
	mark();
	const crdpq_command_type_t others[] = { CRDPQ_CMD_EXECUTE,     CRDPQ_CMD_ACTIVATE, CRDPQ_CMD_WINDOW_MOVE,
		                                    CRDPQ_CMD_SYS_COMMAND, CRDPQ_CMD_INPUT,    CRDPQ_CMD_NOTIFY_EVENT };
	for (size_t i = 0; i < ARRAYSIZE(others); i++)
	{
		CrdpCommand command;
		memset(&command, 0, sizeof(command));
		command.type = others[i];
		if (dispatch_one(&command))
			why("the clipboard dispatch took command type %d, which belongs to RAIL", (int)others[i]);
	}
	expect_no_pdu();
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("a RAIL command moved a clipboard counter");
	CrdpCommand request = clip_command(CRDPQ_CMD_CLIP_REQUEST, 0, 0, CF_UNICODETEXT, 0, 0);
	if (!dispatch_one(&request))
		why("the clipboard dispatch did not take a clipboard command (there is no RAIL here at all)");
	(void)only_pdu(CB_FORMAT_DATA_REQUEST, FALSE);
	finish(n, "RAIL commands untouched; clipboard sent without any RAIL");
}

/* The store refuses for want of a slot, not only for size: a fifth response while four wait is not
 * copied; once one is taken the next is stored again (crdpq.h, CRDPQ_CLIP_SLOTS_PER_DIRECTION). */
static void case_slots_full(size_t n)
{
	mark();
	static const BYTE small[] = { 'z', 0, 0, 0 };
	Drained d;
	CrdpEvent kept[CRDPQ_CLIP_SLOTS_PER_DIRECTION];
	size_t keptCount = 0;
	const size_t refusedBefore = crdpq_clip_store_refusal_count(g_store, CRDPQ_CLIP_ERR_SLOTS_FULL);
	for (size_t i = 0; i <= CRDPQ_CLIP_SLOTS_PER_DIRECTION; i++)
	{
		fed(srv_response(CB_RESPONSE_OK, small, sizeof(small)), "a response did not reach T_clip");
		const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
		if (!ev)
			break;
		if (i < CRDPQ_CLIP_SLOTS_PER_DIRECTION)
		{
			if (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK)
				why("response %zu was not stored while a slot was free", i);
			else
				kept[keptCount++] = *ev;
		}
		else if (ev->payload.clip.status != CRDPQ_CLIP_STATUS_NOT_STORED || ev->payload.clip.byteCount != sizeof(small))
			why("the response past the last free slot was not refused with its length");
	}
	if (crdpq_clip_store_refusal_count(g_store, CRDPQ_CLIP_ERR_SLOTS_FULL) != refusedBefore + 1)
		why("the refusal was not the slot table's");
	BYTE out[16];
	size_t length = 0;
	if (keptCount == 0 || !take_remote(&kept[0], out, sizeof(out), &length))
		why("the first stored response could not be taken");
	fed(srv_response(CB_RESPONSE_OK, small, sizeof(small)), "a response did not reach T_clip");
	const CrdpEvent* again = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (again && (again->payload.clip.status != CRDPQ_CLIP_STATUS_OK || !take_remote(again, out, sizeof(out), &length)))
		why("with a slot free again the next response was not stored");
	for (size_t i = 1; i < keptCount; i++)
	{
		if (!take_remote(&kept[i], out, sizeof(out), &length))
			why("a waiting response could not be taken");
	}
	if (!counters_unchanged_except(CRCLIP_COUNTER_REMOTE_DATA_NOT_STORED, 1))
		why("counters: expected exactly one not-stored");
	expect_store_empty();
	finish(n, "slots full: the fifth response not copied, the next stored again");
}

/* An event T_clip cannot post (the control lane sealed or full): the stored bytes are discarded
 * at once -- nobody would ever be told they exist -- and the loss is counted as a stalling drop. */
static void case_event_post_failure(size_t n)
{
	mark();
	crdpq_control_t* sealed = crdpq_control_create(NULL, NULL);
	harness(sealed != NULL, "could not create a second control lane");
	if (!sealed)
	{
		finish(n, "an event that cannot be posted");
		return;
	}
	crdpq_seal(sealed);
	crdpq_control_t* live = g_bridge.control;
	g_bridge.control = sealed;
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	g_bridge.control = live;
	expect_no_event();
	expect_store_empty();
	if (counter_delta(CRCLIP_COUNTER_EVENT_POST_FAILED) != 1 || counter_delta(CRCLIP_COUNTER_STALL_REMOTE_DATA_POST_FAILED) != 1)
		why("the lost event was not counted, and as a stalling drop");
	crdpq_control_destroy(sealed);
	finish(n, "an event that cannot be posted: its bytes discarded, a stalling drop");
}

/* T_main's answer, every way it can go (crclip_respond, what -respondToClipboardDataRequest:bytes:
 * forwards to): bytes that cannot be stored become a failure answer (one answer per request); a
 * request of a store generation that is gone gets none; a lane that refuses the post leaves no
 * block behind. */
static void case_respond_paths(size_t n, BYTE* big)
{
	mark();
	const uint32_t generation = g_bridge.storeGeneration;
	if (answer(generation, TRUE, big, g_limit + 1) != CRCLIP_RESPOND_POSTED_AS_FAILURE)
		why("an answer over the limit was not turned into a failure answer");
	drain_outbound();
	const ClientPdu* resp = only_pdu(CB_FORMAT_DATA_RESPONSE, FALSE);
	if (resp && (resp->msgFlags != CB_RESPONSE_FAIL || resp->dataLen != 0))
		why("the answer that could not be stored did not go out as a failure");
	if (!counters_unchanged_except(CRCLIP_COUNTER_RESPOND_STORED_AS_FAILURE, 1))
		why("the answer that could not be stored was not counted once");
	remark();
	if (answer(generation + 100, TRUE, g_fixtureWire, g_fixtureWireLen) != CRCLIP_RESPOND_STALE)
		why("an answer for another store generation was not refused as stale");
	Held held = { 0 };
	(void)crdpq_outbound_drain(g_outbound, hold_command, &held);
	if (held.count != 0)
		why("a stale answer posted a command");
	crdpq_outbound_t* sealed = crdpq_outbound_create(NULL, NULL);
	harness(sealed != NULL, "could not create a second outbound lane");
	if (sealed)
	{
		crdpq_outbound_seal(sealed);
		crdpq_clip_ref_t request;
		memset(&request, 0, sizeof(request));
		request.storeGeneration = generation;
		request.formatId = CF_UNICODETEXT;
		if (crclip_respond(sealed, g_store, g_counters, ++g_answerKey, &request, true, g_fixtureWire, g_fixtureWireLen) !=
		    CRCLIP_RESPOND_NOT_POSTED)
			why("an answer on a sealed lane was not reported unposted");
		if (crclip_request(sealed, g_counters, CF_UNICODETEXT))
			why("a request on a sealed lane was reported posted");
		crdpq_outbound_destroy(sealed);
	}
	expect_store_empty();
	expect_no_pdu();
	/* An answer whose bytes are no longer in the store (taken already, say): one failure answer
	 * goes out instead -- the server still gets its one answer -- and it is counted. */
	const CrdpCommand ghost = clip_command(CRDPQ_CMD_CLIP_RESPOND, generation, 999999u, CF_UNICODETEXT, 8,
	                                       CRDPQ_CLIP_STATUS_OK);
	(void)dispatch_one(&ghost);
	const ClientPdu* fallback = only_pdu(CB_FORMAT_DATA_RESPONSE, FALSE);
	if (fallback && (fallback->msgFlags != CB_RESPONSE_FAIL || fallback->dataLen != 0))
		why("an answer without bytes in the store did not go out as a failure");
	if (counter_delta(CRCLIP_COUNTER_RESPONSE_BYTES_UNAVAILABLE) != 1)
		why("the missing answer bytes were not counted");
	if (counter_delta(CRCLIP_COUNTER_RESPOND_STORED_AS_FAILURE) != 0 || counter_delta(CRCLIP_COUNTER_COMMAND_POST_FAILED) != 2 ||
	    counter_delta(CRCLIP_COUNTER_STALL_REQUEST_POST_FAILED) != 1)
		why("counters: stored-as-failure %llu, post failed %llu, stalling request %llu (expected 0, 2, 1)",
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_RESPOND_STORED_AS_FAILURE),
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_COMMAND_POST_FAILED),
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_STALL_REQUEST_POST_FAILED));
	finish(n, "T_main answers: over the limit, stale, unposted");
}

/* T_main's other three: a discarded response, a response nobody settles (the drain's fallback
 * removes and counts it), and the plain-text boundary of the two senders. */
static void case_take_paths(size_t n)
{
	mark();
	Drained d;
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev)
		crclip_discard_remote(g_store, &ev->payload.clip);
	expect_store_empty();
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	if (ev)
	{
		crclip_settle_unconsumed(g_store, g_counters, &ev->payload.clip);
		BYTE out[256];
		size_t length = 0;
		if (take_remote(ev, out, sizeof(out), &length))
			why("a settled entry could still be taken");
	}
	expect_store_empty();
	if (crclip_announce(g_outbound, g_counters, CF_TEXT) || crclip_announce(g_outbound, g_counters, FIXTURE_FORMAT_ID) ||
	    crclip_request(g_outbound, g_counters, CRDPQ_CLIP_NO_FORMAT) || crclip_request(g_outbound, g_counters, CF_TEXT))
		why("a format outside T1 was accepted by a sender");
	Held held = { 0 };
	(void)crdpq_outbound_drain(g_outbound, hold_command, &held);
	if (held.count != 0)
		why("a refused format posted a command");
	if (!counters_unchanged_except(CRCLIP_COUNTER_REMOTE_DATA_UNCONSUMED, 1))
		why("counters: expected exactly one unconsumed, and nothing for the refused formats");
	finish(n, "T_main takes: discard, settle an unconsumed entry, T1 formats only");
}

static void case_in_flight_and_cleanup(size_t n)
{
	mark();
	static const BYTE first[] = { 'a', 0, 0, 0 };
	static const BYTE second[] = { 'b', 0, 0, 0 };
	Drained d;
	/* Two Windows -> Mac responses in the store. */
	fed(srv_response(CB_RESPONSE_OK, first, sizeof(first)) && srv_response(CB_RESPONSE_OK, second, sizeof(second)),
	    "the responses did not reach T_clip");
	drain_events(&d);
	CrdpEvent in1 = d.count > 0 ? d.events[0] : (CrdpEvent){ 0 };
	CrdpEvent in2 = d.count > 1 ? d.events[1] : (CrdpEvent){ 0 };
	if (d.count != 2 || in1.payload.clip.status != CRDPQ_CLIP_STATUS_OK || in2.payload.clip.status != CRDPQ_CLIP_STATUS_OK ||
	    in1.payload.clip.sequence == in2.payload.clip.sequence)
		why("two responses did not become two stored entries under two keys");
	/* Three Mac -> Windows answers: two taken off the lane to be handed to the dispatch one at a
	 * time, one left queued on the lane. */
	const uint32_t generation = g_bridge.storeGeneration;
	Held held = { 0 };
	bridge_ok(answer(generation, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED &&
	            answer(generation, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED,
	        "could not post the answers");
	(void)crdpq_outbound_drain(g_outbound, hold_command, &held);
	bridge_ok(held.count == 2 && answer(generation, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED,
	          "could not hold the answers");
	const CrdpCommand a1 = held.commands[0];
	const CrdpCommand a2 = held.commands[1];
	if (crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_REMOTE_TO_LOCAL) != 2 ||
	    crdpq_clip_store_live_count(g_store, CRDPQ_CLIP_LOCAL_TO_REMOTE) != 3)
		why("the store does not hold the five blocks in flight");
	/* One of each is handled. */
	BYTE out[16];
	size_t length = 0;
	if (!take_remote(&in1, out, sizeof(out), &length))
		why("the first response could not be taken");
	(void)dispatch_one(&a1);
	const ClientPdu* pdus = NULL;
	if (pdus_since(&pdus) != 1)
		why("the first answer was not sent");
	/* Then the channel goes: DISCONNECTED, then the bridge detaches. */
	inst_disconnect();
	if (take_remote(&in2, out, sizeof(out), &length))
		why("an entry of the gone channel could still be taken");
	(void)dispatch_one(&a2);
	drain_outbound(); /* a3, queued before the disconnect */
	if (pdus_since(&pdus) != 1)
		why("an answer left after the channel was gone");
	expect_store_empty();
	if (counter_delta(CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL) != 2)
		why("expected two answers dropped for no channel, got %llu",
		    (unsigned long long)counter_delta(CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL));
	/* The same cleanup again: same outcome. */
	crclip_bridge_detach(&g_bridge, g_inst.channel);
	(void)dispatch_one(&a2);
	if (pdus_since(&pdus) != 1)
		why("an answer left after a second cleanup");
	expect_store_empty();
	if (counter_delta(CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL) != 3)
		why("the second cleanup changed what a drop does");
	finish(n, "in flight both ways, one handled, channel gone, cleanup twice");
}

static void case_no_channel(size_t n)
{
	mark();
	bridge_ok(crclip_announce(g_outbound, g_counters, CF_UNICODETEXT) && crclip_request(g_outbound, g_counters, CF_UNICODETEXT) &&
	            answer(crdpq_clip_store_generation(g_store), TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED,
	        "could not queue the three commands");
	drain_outbound();
	expect_no_pdu();
	expect_store_empty();
	if (counter_delta(CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL) != 3 || counter_delta(CRCLIP_COUNTER_STALL_REQUEST_DROPPED) != 1)
		why("expected three drops for no channel, the request also as a stalling drop");
	/* The other half of "neither depends on the other": with the clipboard channel gone, RAIL
	 * commands are still passed on untouched. */
	remark();
	const crdpq_command_type_t rail[] = { CRDPQ_CMD_EXECUTE,     CRDPQ_CMD_ACTIVATE, CRDPQ_CMD_WINDOW_MOVE,
		                                  CRDPQ_CMD_SYS_COMMAND, CRDPQ_CMD_INPUT,    CRDPQ_CMD_NOTIFY_EVENT };
	for (size_t i = 0; i < ARRAYSIZE(rail); i++)
	{
		CrdpCommand command;
		memset(&command, 0, sizeof(command));
		command.type = rail[i];
		if (dispatch_one(&command))
			why("with no clipboard channel the dispatch took RAIL command type %d", (int)rail[i]);
	}
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("a RAIL command moved a clipboard counter while the clipboard channel was gone");
	finish(n, "no channel: three commands dropped, entry removed, RAIL untouched");
}

static const char* reopen(uint32_t mode)
{
	inst_terminate();
	g_clipThreadKnown = FALSE;
	const char* err = inst_open(mode);
	return err ? err : inst_connect();
}

static void case_reload(size_t n)
{
	mark();
	const uint32_t oldGeneration = g_bridge.storeGeneration;
	/* An answer T_main built for a request of the old instance, with no bytes left to store. */
	const CrdpCommand stale = clip_command(CRDPQ_CMD_CLIP_RESPOND, oldGeneration, 0, CF_UNICODETEXT, 0,
	                                       CRDPQ_CLIP_STATUS_FAILED);
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	remark();
	if (g_bridge.storeGeneration == oldGeneration)
		why("the reloaded channel kept the old store generation");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "the new instance's ready did not arrive");
	(void)only_pdu(CB_CLIP_CAPS, TRUE);
	Drained d;
	(void)only_event(&d, CRDPQ_EVENT_CLIP_READY);
	remark();
	(void)dispatch_one(&stale);
	expect_no_pdu();
	if (!counters_unchanged_except(CRCLIP_COUNTER_COMMAND_DROPPED_STALE, 1))
		why("the old instance's answer was not dropped as stale");
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	BYTE out[256];
	size_t length = 0;
	if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || !take_remote(ev, out, sizeof(out), &length)))
		why("the reloaded channel does not store and hand over responses");
	expect_store_empty();
	finish(n, "channel reload: new generation, old answer dropped, new ready");
}

/* An ASCII short-name format list (MS-RDPECLIP 2.2.3.1.1.1: 32 bytes of ASCII per name, flagged with
 * CB_ASCII_NAMES in the header). Built by FreeRDP's shared encoder, cliprdr_packet_format_list_new
 * with useAsciiNames (channels/cliprdr/cliprdr_common.c), whose output the server encoder never
 * asks for (cliprdr_server_format_list passes FALSE). Two header fields are then set the way the
 * server's cliprdr_server_packet_send sets dataLen (channels/cliprdr/server/cliprdr_main.c, the
 * Stream_SetPosition(s, 4) / Stream_Write_UINT32 pair), plus msgFlags = CB_ASCII_NAMES, which the
 * client's reader checks (cliprdr_common.c cliprdr_read_format_list, `asciiNames`). In ASCII form an
 * exclusion name fits (31 characters), so a comparison that ran without long names would match. */
static BOOL srv_ascii_list(const CLIPRDR_FORMAT* formats, UINT32 count)
{
	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = count;
	list.formats = (CLIPRDR_FORMAT*)formats;
	wStream* s = cliprdr_packet_format_list_new(&list, FALSE, TRUE);
	if (!s)
		return FALSE;
	const size_t pos = Stream_GetPosition(s);
	BOOL ok = pos >= 8 && Stream_SetPosition(s, 2);
	if (ok)
	{
		Stream_Write_UINT16(s, CB_ASCII_NAMES);
		Stream_Write_UINT32(s, (UINT32)(pos - 8));
		ok = Stream_SetPosition(s, pos);
	}
	g_serverOutLen = 0;
	ok = ok && fake_wts_write(NULL, Stream_BufferAs(s, char), (ULONG)pos, NULL);
	Stream_Free(s, TRUE);
	return ok && feed_server_out();
}

/* One short-name list in its ASCII form: the FLR, then the REMOTE_FORMATS event's flags. */
static void expect_ascii_flags(const CLIPRDR_FORMAT* formats, UINT32 count, uint32_t flags)
{
	fed(srv_ascii_list(formats, count), "the ASCII list did not reach T_clip");
	(void)only_pdu(CB_FORMAT_LIST_RESPONSE, TRUE);
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_FORMATS);
	if (ev && ev->payload.clip.flags != flags)
		why("an ASCII short-name list: REMOTE_FORMATS flags 0x%X, expected 0x%X", ev->payload.clip.flags, flags);
}

/* Without long format names (crdpq.h CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED, "FULL NAMES ONLY WITH LONG
 * FORMAT NAMES"): no name is compared, and every list that names CF_UNICODETEXT is judged excluded
 * (both flags) and counted once; a list without it gets neither flag and is not counted. Both
 * short forms (UTF-16, where every exclusion name arrives cut, and ASCII, where three arrive
 * whole), with and without an exclusion name, and an empty list; then once more with no
 * capabilities PDU at all. The long-name side of the same rule -- a list naming CF_UNICODETEXT
 * and no exclusion name gets OFFERS only -- is case 2. */
static void case_without_long_names(size_t n)
{
	mark();
	const uint32_t both = CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
	const CLIPRDR_FORMAT textAndExclusion[] = { { CF_UNICODETEXT, NULL }, { 0xC220u, (char*)g_exclusionNames[1] } };
	const CLIPRDR_FORMAT textOnly[] = { { CF_UNICODETEXT, NULL }, { FIXTURE_FORMAT_ID, (char*)g_fixtureFormatName } };
	const CLIPRDR_FORMAT exclusionNoText[] = { { CF_TEXT, NULL }, { 0xC221u, (char*)g_exclusionNames[2] } };
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	remark();
	/* The server's capabilities without long names: the client's are cut down to none. */
	fed(srv_caps(0) && srv_ready(), "ready did not arrive");
	const ClientPdu* caps = only_pdu(CB_CLIP_CAPS, TRUE);
	if (caps && caps->bodyLen >= 16 && le32(caps->body + 12) != 0)
		why("the client capabilities kept long names the server did not offer");
	Drained d;
	(void)only_event(&d, CRDPQ_EVENT_CLIP_READY);
	/* Lists that name CF_UNICODETEXT: both flags, one count each -- whatever the names say. */
	for (int form = 0; form < 4; form++)
	{
		remark();
		const CLIPRDR_FORMAT* list = (form % 2 == 0) ? textAndExclusion : textOnly;
		const UINT32 count = (form % 2 == 0) ? ARRAYSIZE(textAndExclusion) : ARRAYSIZE(textOnly);
		if (form < 2)
			expect_format_list_flags(list, count, FALSE, both);
		else
			expect_ascii_flags(list, count, both);
		if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
			why("short-name list %d judged excluded was not counted exactly once", form);
	}
	/* Lists that do not name it: no flag, no count -- an exclusion name that arrives whole in
	 * ASCII included, and an empty list. */
	remark();
	expect_format_list_flags(exclusionNoText, ARRAYSIZE(exclusionNoText), FALSE, 0);
	remark();
	expect_ascii_flags(exclusionNoText, ARRAYSIZE(exclusionNoText), 0);
	remark();
	expect_format_list_flags(NULL, 0, FALSE, 0);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("a list without CF_UNICODETEXT moved a counter");
	/* No capabilities PDU at all: the channel assumes general flags zero, so the same rule. */
	remark();
	err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	remark();
	fed(srv_ready(), "ready did not arrive");
	(void)drain_events(&d);
	remark();
	expect_ascii_flags(textOnly, ARRAYSIZE(textOnly), both);
	if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
		why("with no capabilities PDU the list was not counted exactly once");
	remark();
	expect_format_list_flags(exclusionNoText, ARRAYSIZE(exclusionNoText), FALSE, 0);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("with no capabilities PDU a list without CF_UNICODETEXT moved a counter");
	finish(n, "no long format names: every text list judged excluded, counted");
}

static void case_remote_to_local_only_answers(size_t n)
{
	mark();
	const char* err = reopen(CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY);
	harness(err == NULL, err ? err : "");
	remark();
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	remark();
	fed(srv_request(CF_UNICODETEXT), "the server data request did not reach T_clip");
	const ClientPdu* own = only_pdu(CB_FORMAT_DATA_RESPONSE, TRUE);
	if (own && own->msgFlags != CB_RESPONSE_FAIL)
		why("the channel's own answer under RemoteToLocalOnly is not a failure");
	expect_no_event();
	if (calls_since_mark() != 0)
		why("a bridge callback ran for a request the channel answers itself");
	remark();
	bridge_ok(answer(g_bridge.storeGeneration, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED &&
	            answer(g_bridge.storeGeneration, FALSE, NULL, 0) == CRCLIP_RESPOND_POSTED,
	        "could not queue the answers");
	drain_outbound();
	expect_no_pdu();
	if (data_response_calls_since_mark() != 0)
		why("the data-response function was called %zu times under RemoteToLocalOnly (H-2)",
		    data_response_calls_since_mark());
	if (!counters_unchanged_except(CRCLIP_COUNTER_RESPONSE_WITHHELD_BY_MODE, 2))
		why("the two answers were not withheld and counted");
	expect_store_empty();
	finish(n, "RemoteToLocalOnly: channel answers itself, bridge never calls the response");
}

static void case_remote_to_local_only_inbound(size_t n)
{
	mark();
	expect_format_list_flags(g_withText, ARRAYSIZE(g_withText), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	remark();
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	Drained d;
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
	BYTE out[256];
	size_t length = 0;
	if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || !take_remote(ev, out, sizeof(out), &length)))
		why("RemoteToLocalOnly does not store responses");
	remark();
	CrdpCommand text = clip_command(CRDPQ_CMD_CLIP_ANNOUNCE, 0, 0, CF_UNICODETEXT, 0, 0);
	(void)dispatch_one(&text);
	const ClientPdu* pdus = NULL;
	const size_t count = pdus_since(&pdus);
	for (size_t i = 0; i < count; i++)
	{
		if (pdus[i].msgType == CB_FORMAT_LIST && pdus[i].dataLen != 0)
			why("a format list naming a format left under RemoteToLocalOnly");
	}
	expect_store_empty();
	finish(n, "RemoteToLocalOnly: lists and responses in, no format out");
}

static void case_local_to_remote_only(size_t n)
{
	mark();
	const char* err = reopen(CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY);
	harness(err == NULL, err ? err : "");
	remark();
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	remark();
	expect_format_list_flags(g_withText, ARRAYSIZE(g_withText), TRUE, 0); /* filtered to empty by the channel */
	remark();
	fed(srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen), "no response");
	expect_no_event(); /* the channel drops it */
	if (calls_since_mark() != 0)
		why("a bridge callback ran for a response the channel drops");
	CrdpCommand request = clip_command(CRDPQ_CMD_CLIP_REQUEST, 0, 0, CF_UNICODETEXT, 0, 0);
	(void)dispatch_one(&request);
	expect_no_pdu(); /* the channel drops it too */
	remark();
	fed(srv_request(CF_UNICODETEXT), "no request");
	const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_DATA_REQUEST);
	if (ev)
	{
		bridge_ok(answer(ev->payload.clip.storeGeneration, TRUE, g_fixtureWire, g_fixtureWireLen) == CRCLIP_RESPOND_POSTED,
		        "could not post the answer");
		drain_outbound();
		const ClientPdu* resp = only_pdu(CB_FORMAT_DATA_RESPONSE, FALSE);
		if (resp && (resp->msgFlags != CB_RESPONSE_OK || resp->dataLen != g_fixtureWireLen))
			why("LocalToRemoteOnly did not send the answer");
	}
	expect_store_empty();
	finish(n, "LocalToRemoteOnly: nothing in, answers out");
}

static void case_unmanaged(size_t n)
{
	mark();
	inst_terminate();
	g_clipThreadKnown = FALSE;
	/* A fresh connection's clipboard settings, then the bridge's step for Unmanaged: nothing. */
	harness(freerdp_settings_set_bool(g_context->settings, FreeRDP_RedirectClipboard, TRUE) &&
	            freerdp_settings_set_uint32(g_context->settings, FreeRDP_ClipboardFeatureMask, CLIPRDR_FLAG_DEFAULT_MASK),
	        "could not reset the settings");
	remark();
	const char* err = inst_open(CRCLIP_MODE_UNMANAGED);
	harness(err == NULL, err ? err : "");
	if (!freerdp_settings_get_bool(g_context->settings, FreeRDP_RedirectClipboard) ||
	    freerdp_settings_get_uint32(g_context->settings, FreeRDP_ClipboardFeatureMask) != CLIPRDR_FLAG_DEFAULT_MASK)
		why("Unmanaged wrote a clipboard setting");
	err = inst_connect();
	harness(err == NULL, err ? err : "");
	CliprdrClientContext* channel = g_inst.channel;
	if (g_inst.attached || channel->custom || channel->MonitorReady || channel->ServerCapabilities ||
	    channel->ServerFormatList || channel->ServerFormatDataRequest || channel->ServerFormatDataResponse)
		why("something was installed on the channel under Unmanaged");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready() && srv_list(g_withText, ARRAYSIZE(g_withText), TRUE) &&
	        srv_request(CF_UNICODETEXT) && srv_response(CB_RESPONSE_OK, g_fixtureWire, (UINT32)g_fixtureWireLen),
	    "the server PDUs did not reach T_clip");
	expect_no_pdu(); /* nobody answers, as before this lane */
	expect_no_event();
	/* crclip_bridge_init: a directed mode without a lane, a store or counters is refused (the
	 * pre-connect step then refuses the connection); Unmanaged and Off need none of them. */
	crclip_bridge_t scratch;
	if (crclip_bridge_init(&scratch, CRCLIP_MODE_BIDIRECTIONAL, g_control, NULL, g_counters) ||
	    crclip_bridge_init(&scratch, CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY, NULL, g_store, g_counters) ||
	    crclip_bridge_init(&scratch, CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY, g_control, g_store, NULL))
		why("crclip_bridge_init accepted a directed mode without its lanes");
	if (!crclip_bridge_init(&scratch, CRCLIP_MODE_UNMANAGED, NULL, NULL, NULL) ||
	    !crclip_bridge_init(&scratch, CRCLIP_MODE_OFF, NULL, NULL, NULL) ||
	    !crclip_bridge_init(&scratch, CRCLIP_MODE_BIDIRECTIONAL, g_control, g_store, g_counters))
		why("crclip_bridge_init refused a mode that has what it needs");
	CrdpCommand text = clip_command(CRDPQ_CMD_CLIP_ANNOUNCE, 0, 0, CF_UNICODETEXT, 0, 0);
	(void)dispatch_one(&text);
	expect_no_pdu();
	expect_store_empty();
	finish(n, "Unmanaged: no setting written, nothing installed, nothing sent");
}

/* ---- gate r1 (fold r1): list shapes, name case, negotiation, the store's limit, attach refusals,
 * counter range, and a log that must not change with the content ---- */

/* Windows gives the formats in no fixed order (gate r1 I-2): CF_UNICODETEXT not first, an exclusion
 * name before it, and CF_UNICODETEXT alone. */
static const CLIPRDR_FORMAT g_textNotFirst[] = { { FIXTURE_FORMAT_ID, (char*)g_fixtureFormatName },
	                                             { CF_TEXT, NULL },
	                                             { CF_UNICODETEXT, NULL } };
static const CLIPRDR_FORMAT g_exclusionBeforeText[] = { { 0xC230u, (char*)g_exclusionNames[3] }, { CF_UNICODETEXT, NULL } };
static const CLIPRDR_FORMAT g_textAlone[] = { { CF_UNICODETEXT, NULL } };

static void case_list_shapes_long_names(size_t n)
{
	mark();
	const uint32_t both = CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	remark();
	expect_format_list_flags(g_textNotFirst, ARRAYSIZE(g_textNotFirst), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("long names, CF_UNICODETEXT last: a counter moved");
	remark();
	expect_format_list_flags(g_exclusionBeforeText, ARRAYSIZE(g_exclusionBeforeText), TRUE, both);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("long names, the exclusion name first: a counter moved");
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("long names, CF_UNICODETEXT alone: a counter moved");
	finish(n, "long names: text not first, exclusion name first, text alone");
}

static void case_list_shapes_short_names(size_t n)
{
	mark();
	const uint32_t both = CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
	const struct
	{
		const CLIPRDR_FORMAT* formats;
		UINT32 count;
	} lists[] = { { g_textNotFirst, ARRAYSIZE(g_textNotFirst) },
		          { g_exclusionBeforeText, ARRAYSIZE(g_exclusionBeforeText) },
		          { g_textAlone, ARRAYSIZE(g_textAlone) } };
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	fed(srv_caps(0) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	for (size_t i = 0; i < ARRAYSIZE(lists); i++)
	{
		for (int ascii = 0; ascii < 2; ascii++)
		{
			remark();
			if (ascii)
				expect_ascii_flags(lists[i].formats, lists[i].count, both);
			else
				expect_format_list_flags(lists[i].formats, lists[i].count, FALSE, both);
			if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
				why("short-name list shape %zu (%s) judged excluded was not counted exactly once", i,
				    ascii ? "ASCII" : "UTF-16");
		}
	}
	finish(n, "short names, UTF-16 and ASCII: the same shapes, all excluded");
}

/* gate r1 I-1: Windows compares registered format names without regard to case, so an exclusion
 * name in another case is that exclusion name; a prefix of one, or one with a character more, is
 * another name. Long names (the only path that compares names). */
static void case_exclusion_name_case(size_t n)
{
	mark();
	const uint32_t both = CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
	static const char lower[] = "canincludeinclipboardhistory";
	static const char upper[] = "CANINCLUDEINCLIPBOARDHISTORY";
	static const char mixed[] = "clipboard VIEWER iGNORE";
	static const char prefix[] = "CanIncludeInClipboardHistor";
	static const char longer[] = "CanIncludeInClipboardHistoryX";
	const struct
	{
		const char* name;
		BOOL withText;
		uint32_t flags;
		const char* what;
	} rows[] = {
		{ lower, TRUE, both, "all lower case" },
		{ upper, FALSE, CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED, "all upper case, without CF_UNICODETEXT" },
		{ mixed, TRUE, both, "mixed case" },
		{ prefix, TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT, "one character short" },
		{ longer, TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT, "one character more" },
	};
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	for (size_t i = 0; i < ARRAYSIZE(rows); i++)
	{
		remark();
		const CLIPRDR_FORMAT withText[] = { { CF_UNICODETEXT, NULL }, { 0xC240u + (UINT32)i, (char*)rows[i].name } };
		const CLIPRDR_FORMAT alone[] = { { 0xC240u + (UINT32)i, (char*)rows[i].name } };
		const uint32_t before = (uint32_t)strlen(g_why);
		if (rows[i].withText)
			expect_format_list_flags(withText, ARRAYSIZE(withText), TRUE, rows[i].flags);
		else
			expect_format_list_flags(alone, ARRAYSIZE(alone), TRUE, rows[i].flags);
		if (before == 0 && g_why[0] != '\0')
		{
			char reason[sizeof(g_why)];
			(void)snprintf(reason, sizeof(reason), "%s", g_why);
			g_why[0] = '\0';
			why("exclusion name %s: %s", rows[i].what, reason);
		}
		if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
			why("exclusion name %s: a counter moved", rows[i].what);
	}
	finish(n, "exclusion names: ASCII case ignored, prefix and longer differ");
}

/* gate r1 m-3: the channel reads every list by the newest capabilities at once, so "negotiated"
 * goes down the moment capabilities without long names arrive; it goes up only at Monitor Ready,
 * once the client's capabilities went out -- not on capabilities alone, not after a failed write. */
static void case_negotiation_only_downgrades(size_t n)
{
	mark();
	const uint32_t both = CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT | CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED;
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	(void)only_pdu(CB_CLIP_CAPS, TRUE);
	Drained d;
	(void)drain_events(&d);
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("negotiated: a counter moved");
	remark();
	fed(srv_caps(0), "capabilities without long names did not reach T_clip");
	expect_no_pdu();
	expect_no_event();
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), FALSE, both);
	if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
		why("after capabilities without long names (no Monitor Ready) the list was not judged excluded and counted");
	remark();
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES), "capabilities with long names did not reach T_clip");
	expect_no_pdu();
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), TRUE, both);
	if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
		why("capabilities with long names upgraded without a Monitor Ready");
	remark();
	fed(srv_ready(), "Monitor Ready did not reach T_clip");
	(void)only_pdu(CB_CLIP_CAPS, TRUE);
	(void)drain_events(&d);
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), TRUE, CRDPQ_CLIP_FLAG_OFFERS_UNICODETEXT);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("Monitor Ready did not negotiate long names again");
	remark();
	fail_next(CB_CLIP_CAPS);
	fed(srv_ready(), "Monitor Ready with a failing capabilities write did not reach T_clip");
	(void)drain_events(&d);
	if (!counters_unchanged_except(CRCLIP_COUNTER_CAPABILITIES_SEND_FAILED, 1))
		why("the failed capabilities write was not counted once");
	remark();
	expect_format_list_flags(g_textAlone, ARRAYSIZE(g_textAlone), TRUE, both);
	if (!counters_unchanged_except(CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES, 1))
		why("after a failed client capabilities write the list was not judged excluded and counted");
	finish(n, "negotiation: down at once, up only at Monitor Ready");
}

/* gate r1 m-1: what CRSession's -start does with clipboardByteLimit (crclip_store_for_limit). */
static void case_store_follows_limit(size_t n, const BYTE* big)
{
	mark();
	crdpq_clip_store_t* store = NULL;
	size_t limit = crclip_store_for_limit(&store, 0, 0);
	if (store || limit != 0)
		why("limit 0 created a store");
	limit = crclip_store_for_limit(&store, limit, 64);
	crdpq_clip_store_t* const first = store;
	if (!store || limit != 64)
		why("limit 64 created no store");
	/* The keep branch (gate r2 m-r2-1): a pointer compare alone cannot tell "kept" from "destroyed
	 * and created again" -- the allocator often hands back the same address. So the store gets a
	 * generation of its own (one clear) and a block before the call with the same limit; after it
	 * the block must still be there under that generation. */
	const uint32_t keptGeneration = store ? crdpq_clip_store_clear(store) : 0;
	const BOOL heldBlock = store && crdpq_clip_store_put(store, keptGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, 7, big, 16) ==
	                                    CRDPQ_CLIP_OK;
	harness(heldBlock, "could not put a block into a fresh store");
	limit = crclip_store_for_limit(&store, limit, 64);
	if (store != first || limit != 64)
		why("an unchanged limit did not keep the store");
	if (store && crdpq_clip_store_generation(store) != keptGeneration)
		why("an unchanged limit changed the store's generation (%u, was %u): the store was made anew",
		    crdpq_clip_store_generation(store), keptGeneration);
	{
		BYTE kept[16];
		size_t keptLength = 0;
		if (heldBlock && (!store ||
		                  crdpq_clip_store_take(store, keptGeneration, CRDPQ_CLIP_REMOTE_TO_LOCAL, 7, kept, sizeof(kept),
		                                        &keptLength) != CRDPQ_CLIP_OK ||
		                  keptLength != 16 || memcmp(kept, big, 16) != 0))
			why("an unchanged limit lost the block the store held: the store was made anew");
	}
	if (store && (crdpq_clip_store_put(store, crdpq_clip_store_generation(store), CRDPQ_CLIP_REMOTE_TO_LOCAL, 1, big,
	                                   64) != CRDPQ_CLIP_OK ||
	              crdpq_clip_store_put(store, crdpq_clip_store_generation(store), CRDPQ_CLIP_REMOTE_TO_LOCAL, 2, big,
	                                   65) != CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE))
		why("the store for limit 64 does not have block limit 64");
	limit = crclip_store_for_limit(&store, limit, 128);
	if (!store || limit != 128 ||
	    crdpq_clip_store_put(store, crdpq_clip_store_generation(store), CRDPQ_CLIP_REMOTE_TO_LOCAL, 3, big, 128) !=
	        CRDPQ_CLIP_OK)
		why("a changed limit did not give a store with the new block limit");
	limit = crclip_store_for_limit(&store, limit, 0);
	if (store || limit != 0)
		why("a limit set back to 0 left a store in place");
	limit = crclip_store_for_limit(&store, limit, 64);
	limit = crclip_store_for_limit(&store, limit, SIZE_MAX / 2 + 1);
	if (store || limit != 0)
		why("a limit past SIZE_MAX / 2 left a store in place");
	if (crclip_store_for_limit(NULL, 64, 64) != 0)
		why("no store pointer: not 0");
	crdpq_clip_store_destroy(store);
	crclip_bridge_t scratch;
	if (crclip_bridge_init(&scratch, CRCLIP_MODE_BIDIRECTIONAL, g_control, store, g_counters))
		why("a directed mode was accepted without a store");
	finish(n, "store follows the limit: create, keep, replace, none at 0");
}

/* gate r1 m-2: a refused attach leaves one ERR line, the mode number only, and touches nothing. */
static void case_attach_refusals(size_t n)
{
	mark();
	const size_t from = text_offset();
	CliprdrClientContext untouched;
	memset(&untouched, 0, sizeof(untouched));
	crclip_bridge_t scratch;
	harness(crclip_bridge_init(&scratch, CRCLIP_MODE_BIDIRECTIONAL, g_control, g_store, g_counters),
	        "init refused a complete bridge");
	if (crclip_bridge_attach(&scratch, NULL))
		why("attach accepted no channel");
	if (crclip_bridge_attach(NULL, &untouched))
		why("attach accepted no bridge");
	harness(crclip_bridge_init(&scratch, CRCLIP_MODE_OFF, NULL, NULL, NULL), "init refused Off");
	if (crclip_bridge_attach(&scratch, &untouched))
		why("attach accepted Off");
	harness(crclip_bridge_init(&scratch, CRCLIP_MODE_UNMANAGED, NULL, NULL, NULL), "init refused Unmanaged");
	if (crclip_bridge_attach(&scratch, &untouched))
		why("attach accepted Unmanaged");
	if (untouched.custom || untouched.ServerCapabilities || untouched.MonitorReady || untouched.ServerFormatList ||
	    untouched.ServerFormatDataRequest || untouched.ServerFormatDataResponse)
		why("a refused attach changed the channel");
	const size_t lines = text_count_since(from, "[clipboard] mode=");
	if (lines != 4 || text_count_since(from, "[clipboard] mode=2 not attached") != 1 ||
	    text_count_since(from, "[clipboard] mode=1 not attached") != 1 ||
	    text_count_since(from, "[clipboard] mode=0 not attached") != 2)
		why("expected one line per refused attach (mode 2, none, 1, 0), got %zu lines", lines);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("a refused attach moved a counter");
	finish(n, "attach refused: no channel, no bridge, Off, Unmanaged");
}

/* gate r1 m-5: values outside the table, on both sides. */
static void case_counters_out_of_range(size_t n)
{
	mark();
	const crclip_counter_t past = (crclip_counter_t)CRCLIP_COUNTER_COUNT;
	const crclip_counter_t below = (crclip_counter_t)-1;
	if (crclip_counters_get(g_counters, past) != 0 || crclip_counters_get(g_counters, below) != 0)
		why("a counter outside 0..%d read non-zero", (int)CRCLIP_COUNTER_COUNT - 1);
	if (crclip_counters_bump(g_counters, past) != 0 || crclip_counters_bump(g_counters, below) != 0)
		why("a bump outside 0..%d returned non-zero", (int)CRCLIP_COUNTER_COUNT - 1);
	if (!counters_unchanged_except(CRCLIP_COUNTER_COUNT, 0))
		why("a bump outside the table moved a counter");
	finish(n, "counters 18 and -1: read 0, bump nothing");
}

/* gate r1 m-4: a log line can carry content as a number as well as a string. The same steps twice,
 * with the same lengths and different bytes (every byte inverted): every logging path that sees
 * clipboard bytes -- a response over the limit, one stored and taken, an answer over the limit, one
 * sent -- must log the very same text, the running counts aside. */
static void case_log_invariant_under_content(size_t n, const BYTE* big)
{
	mark();
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	harness(err == NULL, err ? err : "");
	fed(srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready(), "ready did not arrive");
	Drained d;
	(void)drain_events(&d);
	remark();
	BYTE* other = malloc(g_limit + 8);
	harness(other != NULL, "no memory for the second content");
	char* seen[2] = { NULL, NULL };
	for (int round = 0; round < 2 && other; round++)
	{
		if (round == 1)
		{
			for (size_t i = 0; i < g_limit + 8; i++)
				other[i] = (BYTE)~big[i];
		}
		const BYTE* bytes = (round == 0) ? big : other;
		const size_t from = text_offset();
		fed(srv_response(CB_RESPONSE_OK, bytes, (UINT32)g_limit + 1), "the over-limit response did not reach T_clip");
		const CrdpEvent* ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
		if (ev && ev->payload.clip.status != CRDPQ_CLIP_STATUS_NOT_STORED)
			why("round %d: the over-limit response was stored", round);
		fed(srv_response(CB_RESPONSE_OK, bytes, 64), "the response did not reach T_clip");
		ev = only_event(&d, CRDPQ_EVENT_CLIP_REMOTE_DATA);
		BYTE out[64];
		size_t length = 0;
		if (ev && (ev->payload.clip.status != CRDPQ_CLIP_STATUS_OK || !take_remote(ev, out, sizeof(out), &length) ||
		           length != 64 || memcmp(out, bytes, 64) != 0))
			why("round %d: the response was not stored and taken whole", round);
		bridge_ok(answer(g_bridge.storeGeneration, TRUE, bytes, g_limit + 1) == CRCLIP_RESPOND_POSTED_AS_FAILURE,
		          "an over-limit answer was not posted as a failure");
		bridge_ok(answer(g_bridge.storeGeneration, TRUE, bytes, 64) == CRCLIP_RESPOND_POSTED, "an answer was not posted");
		drain_outbound();
		seen[round] = text_since_without_counts(from);
		harness(seen[round] != NULL, "no memory for the log text");
	}
	if (seen[0] && seen[1])
	{
		if (!strstr(seen[0], "[clipboard] data response not stored") ||
		    !strstr(seen[0], "[clipboard] answer not stored"))
			why("the two not-stored paths logged nothing (nothing to compare)");
		if (strcmp(seen[0], seen[1]) != 0)
			why("the log changed when only the clipboard bytes changed (content reached a log line)");
	}
	free(seen[0]);
	free(seen[1]);
	free(other);
	expect_store_empty();
	finish(n, "the log is the same for other bytes of the same length");
}

/* ==================================================================================== *
 * Self-checks
 * ==================================================================================== */

/* 1: the premise of H-2. In a forked child, under a mask without Mac -> Windows, the channel's own
 * data-response function must end the process with SIGABRT (verbose WinPR asserts). */
static BOOL selfcheck_assert_aborts(void)
{
	const char* err = inst_open(CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY);
	if (err)
		return FALSE;
	(void)fflush(stdout);
	(void)fflush(stderr);
	const pid_t child = fork();
	if (child == 0)
	{
		CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
		response.common.msgType = CB_FORMAT_DATA_RESPONSE;
		response.common.msgFlags = CB_RESPONSE_FAIL;
		(void)g_inst.channel->ClientFormatDataResponse(g_inst.channel, &response);
		_exit(0);
	}
	int status = 0;
	const BOOL waited = child > 0 && waitpid(child, &status, 0) == child;
	inst_terminate();
	const BOOL aborted = waited && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
	(void)printf("self-check 1: data-response function under RemoteToLocalOnly in a child -> %s\n",
	             aborted ? "SIGABRT, ok" : "FAIL: the child did not abort (the H-2 premise changed)");
	return aborted;
}

/* 2: the log capture sees the channel's own DEBUG lines, which print format names -- so a clean
 * INFO capture later is evidence, not silence. */
static BOOL selfcheck_log_capture(void)
{
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	if (err)
		return FALSE;
	BOOL ok = srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready() && barrier();
	wLog* root = WLog_GetRoot();
	ok = ok && WLog_SetLogLevel(root, WLOG_DEBUG);
	ok = ok && srv_list(g_withText, ARRAYSIZE(g_withText), TRUE) && barrier();
	(void)WLog_SetLogLevel(root, WLOG_INFO);
	Drained d;
	(void)drain_events(&d);
	const BOOL seen = log_contains(g_fixtureFormatName, strlen(g_fixtureFormatName));
	(void)printf("self-check 2: at DEBUG the capture sees the channel print a format name -> %s\n",
	             (ok && seen) ? "ok" : "FAIL: the capture did not see it");
	log_reset();
	return ok && seen;
}

/* 3: a callback that returns non-zero is caught (and stops T_clip, as in a real session). */
static BOOL selfcheck_return_value(void)
{
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	if (err)
		return FALSE;
	BOOL ok = srv_caps(CB_USE_LONG_FORMAT_NAMES) && srv_ready() && barrier();
	Drained d;
	(void)drain_events(&d);
	mark();
	g_brokenList = TRUE;
	ok = ok && srv_list(g_withText, ARRAYSIZE(g_withText), TRUE);
	const BOOL reached = barrier();
	g_brokenList = FALSE;
	common_checks();
	const BOOL caught = ok && !reached && g_why[0] != '\0' && getChannelError(g_context) != CHANNEL_RC_OK;
	(void)printf("self-check 3: a callback returning non-zero -> %s%s\n", caught ? "caught, ok" : "FAIL: not caught",
	             caught ? "" : g_why);
	(void)drain_events(&d);
	inst_terminate();
	setChannelError(g_context, CHANNEL_RC_OK, "%s", "");
	(void)ResetEvent(getChannelErrorEventHandle(g_context));
	g_why[0] = '\0';
	return caught;
}

/* 4: a data request sent from T_clip is caught. */
static BOOL selfcheck_send_from_clip_thread(void)
{
	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	if (err)
		return FALSE;
	BOOL ok = srv_caps(CB_USE_LONG_FORMAT_NAMES);
	mark();
	g_brokenReadySendsRequest = TRUE;
	ok = ok && srv_ready() && barrier();
	g_brokenReadySendsRequest = FALSE;
	common_checks();
	const BOOL caught = ok && strstr(g_why, "T_clip sent msgType") != NULL;
	(void)printf("self-check 4: a data request sent from T_clip -> %s\n", caught ? "caught, ok" : "FAIL: not caught");
	Drained d;
	(void)drain_events(&d);
	g_why[0] = '\0';
	inst_terminate();
	return caught;
}

/* ==================================================================================== *
 * main
 * ==================================================================================== */

static BOOL loaded_from_prefix(const char* prefix, char* loaded, size_t loadedSize)
{
	Dl_info info = { 0 };
	if (!dladdr((const void*)(uintptr_t)freerdp_client_context_new, &info) || !info.dli_fname)
		return FALSE;
	char realLib[PATH_MAX];
	char prefixLib[PATH_MAX];
	char realPrefixLib[PATH_MAX];
	if (!realpath(info.dli_fname, realLib))
		return FALSE;
	(void)snprintf(loaded, loadedSize, "%s", realLib);
	if (snprintf(prefixLib, sizeof(prefixLib), "%s/lib", prefix) >= (int)sizeof(prefixLib))
		return FALSE;
	if (!realpath(prefixLib, realPrefixLib))
		return FALSE;
	const size_t len = strlen(realPrefixLib);
	return (strncmp(realLib, realPrefixLib, len) == 0) && (realLib[len] == '/');
}

static int verdict_error(const char* what)
{
	(void)printf("cliprdr-check: ERROR %s -- this run cannot judge the bridge\n", what);
	return CHECK_ERROR;
}

int main(int argc, char* argv[])
{
	if (argc != 3)
		return verdict_error("usage: cliprdr-check <freerdp-prefix> <limit-bytes>");
	char* end = NULL;
	const unsigned long long limit = strtoull(argv[2], &end, 10);
	if (!end || *end != '\0' || limit < 64 || limit > 64ull * 1024 * 1024)
		return verdict_error("the limit must be a decimal byte count between 64 and 64 MiB");
	g_limit = (size_t)limit;
	char loaded[PATH_MAX] = "";
	if (!loaded_from_prefix(argv[1], loaded, sizeof(loaded)))
	{
		(void)printf("cliprdr-check: ERROR libfreerdp-client3 was loaded from '%s', not from %s/lib -- this run "
		             "cannot judge that prefix\n",
		             loaded, argv[1]);
		return CHECK_ERROR;
	}
	(void)printf("cliprdr-check: FreeRDP %s, libfreerdp-client3 loaded from %s, limit %zu bytes\n",
	             freerdp_get_version_string(), loaded, g_limit);

	g_driver = pthread_self();
	if (!build_fixtures())
		return verdict_error("the fixture's UTF-16LE and UTF-8 forms disagree");
	if (!install_log_capture())
		return verdict_error("could not install the log capture on the root logger");
	memset(&g_wts, 0, sizeof(g_wts));
	g_wts.pVirtualChannelWrite = fake_wts_write;
	if (!WTSRegisterWtsApiFunctionTable(&g_wts))
		return verdict_error("could not register the WTS API table the server encoder writes through");

	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(rdpClientContext);
	g_context = freerdp_client_context_new(&entry);
	g_control = crdpq_control_create(NULL, NULL);
	g_outbound = crdpq_outbound_create(NULL, NULL);
	g_store = crdpq_clip_store_create(g_limit, g_limit * 2);
	g_counters = crclip_counters_create();
	g_server = cliprdr_server_context_new(NULL);
	BYTE* big = malloc(g_limit + 8);
	if (!g_context || !g_control || !g_outbound || !g_store || !g_counters || !g_server || !big)
		return verdict_error("could not create the context, the lanes, the store or the server encoder");
	for (size_t i = 0; i < g_limit + 8; i++)
		big[i] = (BYTE)(i * 7u + 3u);

	/* Self-check 1 runs first: the fork happens while this is the only thread. */
	size_t selfPassed = 0;
	size_t selfRan = 0;
	selfRan++;
	selfPassed += selfcheck_assert_aborts() ? 1 : 0;
	selfRan++;
	selfPassed += selfcheck_log_capture() ? 1 : 0;

	const char* err = reopen(CRCLIP_MODE_BIDIRECTIONAL);
	if (err)
		return verdict_error(err);
	size_t n = 0;
	case_caps_and_ready(++n);
	case_list_with_text(++n);
	case_list_without_text(++n);
	case_exclusion_names(++n);
	case_exclusion_without_text(++n);
	case_empty_list(++n);
	case_request_then_answer(++n);
	case_request_failure_answer(++n);
	case_request_other_format(++n);
	case_response_ok(++n);
	case_response_fail(++n);
	case_limits(++n, big);
	case_repeated_over_limit(++n, big);
	case_unexpected_flags(++n);
	case_announce(++n);
	case_request_command(++n);
	case_send_failures(++n);
	case_ready_again(++n);
	case_rail_independent(++n);
	case_slots_full(++n);
	case_event_post_failure(++n);
	case_respond_paths(++n, big);
	case_take_paths(++n);
	case_in_flight_and_cleanup(++n);
	case_no_channel(++n);
	case_reload(++n);
	case_without_long_names(++n);
	case_remote_to_local_only_answers(++n);
	case_remote_to_local_only_inbound(++n);
	case_local_to_remote_only(++n);
	case_unmanaged(++n);
	case_list_shapes_long_names(++n);
	case_list_shapes_short_names(++n);
	case_exclusion_name_case(++n);
	case_negotiation_only_downgrades(++n);
	case_store_follows_limit(++n, big);
	case_attach_refusals(++n);
	case_counters_out_of_range(++n);
	case_log_invariant_under_content(++n, big);
	inst_terminate();

	selfRan++;
	selfPassed += selfcheck_return_value() ? 1 : 0;
	selfRan++;
	selfPassed += selfcheck_send_from_clip_thread() ? 1 : 0;

	/* The last case: what everything above logged at INFO and above. */
	mark();
	{
		size_t lines = 0;
		pthread_mutex_lock(&g_logLock);
		lines = g_logLines;
		pthread_mutex_unlock(&g_logLock);
		static const char attached[] = "[clipboard] channel cliprdr attached";
		if (!log_contains(attached, strlen(attached)))
			why("the capture holds none of the bridge's own lines (%zu lines captured)", lines);
		if (log_contains(g_fixtureUtf8, strlen(g_fixtureUtf8)) || log_contains(g_fixtureTailUtf8, strlen(g_fixtureTailUtf8)))
			why("the fixture text was logged (UTF-8)");
		if (log_contains(g_fixtureWire, g_fixtureWireLen - 2) || log_contains(g_fixtureTailWire, sizeof(g_fixtureTailWire)))
			why("the fixture text was logged (UTF-16LE)");
		/* Short needles (gate r1 m-4): the fixture's first eight bytes, as text and as hex, in both
		 * encodings -- a truncated or hex-dumped piece of content. A number derived from content is
		 * the log-invariance case's to catch. */
		{
			char hex[4][40];
			static const char digitsLower[] = "0123456789abcdef";
			static const char digitsUpper[] = "0123456789ABCDEF";
			const BYTE* sources[2] = { (const BYTE*)g_fixtureUtf8, g_fixtureWire };
			for (size_t form = 0; form < 4; form++)
			{
				const BYTE* src = sources[form / 2];
				const char* digits = (form % 2 == 0) ? digitsLower : digitsUpper;
				for (size_t i = 0; i < 8; i++)
				{
					hex[form][2 * i] = digits[src[i] >> 4];
					hex[form][2 * i + 1] = digits[src[i] & 0x0F];
				}
				hex[form][16] = '\0';
				if (log_contains(hex[form], 16))
					why("the fixture's first bytes were logged in hex");
			}
			if (log_contains(g_fixtureUtf8, 8) || log_contains(g_fixtureWire, 16))
				why("the fixture's first bytes were logged");
		}
		if (log_contains(g_fixtureFormatName, strlen(g_fixtureFormatName)))
			why("a format name was logged");
		for (size_t i = 0; i < ARRAYSIZE(g_exclusionNames); i++)
		{
			if (log_contains_folded(g_exclusionNames[i]))
				why("an exclusion format name was logged (in some case)");
		}
		/* Not through finish(): no channel instance is live any more. */
		g_casesRun++;
		const BOOL failed = g_why[0] != '\0';
		if (failed)
			g_casesFailed++;
		(void)printf("case %02zu: %-58s -> %s%s (%zu lines at INFO and above)\n", ++n,
		             "no fixture text and no format name in any log line", failed ? "FAIL: " : "ok", g_why, lines);
		/* CLIPRDR_CHECK_DUMP_LOG=1: the captured lines on stderr, for reading what the channel and
		 * the bridge print at INFO and above. Never in CI: the case above is the judgement. */
		const char* dump = getenv("CLIPRDR_CHECK_DUMP_LOG");
		if (dump && strcmp(dump, "1") == 0)
		{
			pthread_mutex_lock(&g_logLock);
			(void)fprintf(stderr, "%s", g_log ? g_log : "");
			pthread_mutex_unlock(&g_logLock);
		}
	}

	free(big);
	cliprdr_server_context_free(g_server);
	crdpq_outbound_destroy(g_outbound);
	crdpq_control_destroy(g_control);
	crdpq_clip_store_destroy(g_store);
	crclip_counters_destroy(g_counters);
	freerdp_client_context_free(g_context);

	if (g_harnessErrors != 0)
	{
		char buf[128];
		(void)snprintf(buf, sizeof(buf), "%zu case(s) hit a harness fault (see the case lines)", g_harnessErrors);
		return verdict_error(buf);
	}
	if (g_casesRun != EXPECTED_CASES || selfRan != EXPECTED_SELF_CHECKS)
	{
		char buf[160];
		(void)snprintf(buf, sizeof(buf), "ran %zu cases and %zu self-checks, expected %u and %u", g_casesRun, selfRan,
		               EXPECTED_CASES, EXPECTED_SELF_CHECKS);
		return verdict_error(buf);
	}
	if (selfPassed != selfRan)
	{
		char buf[160];
		(void)snprintf(buf, sizeof(buf), "%zu of %zu self-checks failed, so the cases would not be evidence",
		               selfRan - selfPassed, selfRan);
		return verdict_error(buf);
	}
	if (g_casesFailed != 0)
	{
		(void)printf("cliprdr-check: FAIL %zu/%zu cases (see the case lines) -- the clipboard bridge does not behave "
		             "as adr/0026 H-1 / H-2 / H-3 / H-5 / H-10 require; self-checks %zu/%zu ok\n",
		             g_casesFailed, g_casesRun, selfPassed, selfRan);
		return CHECK_FAIL;
	}
	(void)printf("cliprdr-check: PASS %zu/%zu cases (every callback returned 0, T_clip sent only capabilities and "
	             "format list responses, no response under RemoteToLocalOnly, no content in the log), self-checks "
	             "%zu/%zu ok\n",
	             g_casesRun - g_casesFailed, g_casesRun, selfPassed, selfRan);
	return CHECK_PASS;
}
