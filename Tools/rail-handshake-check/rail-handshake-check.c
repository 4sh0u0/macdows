/**
 * rail-handshake-check: an offline check that the FreeRDP prefix this binary is linked against
 * answers the server's RAIL handshake with the client status -- TS_RAIL_ORDER_HANDSHAKE, then
 * TS_RAIL_ORDER_CLIENTSTATUS, and no TS_RAIL_ORDER_EXEC -- for both the Handshake and the
 * HandshakeEx server PDU. No socket, no host, no credentials: the built-in RAIL channel is loaded
 * from the prefix and its default handshake handler is called directly.
 *
 * Adapted from FreeRDP's regression test channels/rail/client/test/TestRailHandshake.c, added
 * upstream by commit 91b9a6f56fe86911970ea6da29907a2fbb1013b6 ("fix(rail): initialize client
 * status during the default handshake", FreeRDP PR #13696; text as of tag 3.33.0). The upstream
 * file carries this notice:
 *
 *   FreeRDP: A Remote Desktop Protocol Implementation
 *   Regression test for client-status initialization before RemoteApp execution.
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 * Modified by the Macdows project (2026-11-10), as Apache-2.0 section 4(b) asks to state:
 *   - a standalone program built against an installed prefix (its public headers and exported
 *     symbols only) instead of an in-tree test target, so a prefix this repository already
 *     built can be checked without BUILD_TESTING_INTERNAL;
 *   - orders are captured at the channel's write entry point (pVirtualChannelWriteEx) by
 *     reading the RAIL PDU header ([MS-RDPERP] TS_RAIL_PDU_HEADER: orderType, orderLength),
 *     so the channel's own ClientHandshake / ClientInformation serializers run; upstream
 *     replaces those callbacks;
 *   - write failures are injected at the first or second write instead of in replaced callbacks;
 *   - stricter than upstream: the answer must be exactly two orders, HANDSHAKE carrying
 *     FreeRDP_ClientBuild and then CLIENTSTATUS, with nothing after them in the same handler
 *     call (upstream counts only the ClientHandshake / ClientInformation callbacks). A FreeRDP
 *     that starts sending a third order there turns this red on purpose -- a review point on a
 *     pin bump, not noise;
 *   - the cases run with FreeRDP_RemoteApplicationMode on, as the App's sessions do;
 *   - the start-command case is kept as a self-check that the capture sees an EXEC when one is
 *     sent, so "no EXEC during the handshake" is not vacuous;
 *   - it counts the handshake cases it actually ran (12 per server handshake variant) and the
 *     self-checks it actually ran, and reports ERROR when either count is not the expected one,
 *     so a loop that silently stopped running cannot leave a smaller green;
 *   - it prints the order sequence of every case and a one-line verdict (a FAIL counts the
 *     failed cases by reason), exits 0 / 1 / 2 -- a fault of the harness itself, such as a
 *     write arriving on a foreign init handle, is ERROR, never FAIL -- and refuses to judge a
 *     libfreerdp-client3 that was not loaded from the prefix named in argv.
 *
 * Why it exists: lane rail-clientstatus (2026-11-10) backported PR #13696 as
 * ThirdParty/patches/0003-rail-client-status-on-default-handshake.patch. Without that behaviour
 * the current Windows host never sends a window order, yet nothing offline could tell: a deleted
 * patch file left Tier 1 and Tier 2 green. This pins the behaviour, not the patch file, so it
 * keeps holding after the patch retires on a pin >= 3.33.0.
 *
 * Usage: rail-handshake-check <freerdp-prefix>   (Scripts/test-rail-handshake.sh runs it)
 * Exit:  0 PASS; 1 FAIL (the behaviour is missing); 2 ERROR (the check could not judge).
 */

#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/stream.h>
#include <winpr/wlog.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/rail.h>
#include <freerdp/freerdp.h>
#include <freerdp/rail.h>
#include <freerdp/settings.h>
#include <freerdp/svc.h>

#define CHECK_PASS 0
#define CHECK_FAIL 1
#define CHECK_ERROR 2

#define MAX_WRITES 32
#define INJECTED_ERROR ERROR_INTERNAL_ERROR
/* Any value other than FreeRDP_ClientBuild: the answer must carry the client's build, not
 * echo the server's. */
#define SERVER_BUILD 0x00004E20u
#define RAIL_LOG_TAG "com.freerdp.channels.rail.client"
/* 2 AutoReconnectionEnabled values x 2 RemoteAppFeatureFlags sets x 3 write outcomes. */
#define EXPECTED_CASES_PER_VARIANT 12u
#define EXPECTED_SELF_CHECKS 2u
#define MAX_REASONS 8

typedef struct
{
	UINT16 orderType;
	UINT16 orderLength;
	UINT32 field; /* first UINT32 of the body: buildNumber (HANDSHAKE), flags (CLIENTSTATUS) */
	BOOL hasHeader;
	BOOL hasField;
	BOOL failed; /* this write was the injected failure */
} SentOrder;

static SentOrder g_sent[MAX_WRITES];
static size_t g_writes = 0;    /* writes attempted, counting any beyond MAX_WRITES */
static size_t g_failWrite = 0; /* 1-based index of the write to fail; 0 = none */
static BOOL g_foreignHandle = FALSE;
/* Counted where the handler / start command is actually called, not where a loop is meant to
 * run: the verdict line prints these, and a short count is an ERROR. */
static size_t g_ranHandshake = 0;
static size_t g_ranHandshakeEx = 0;
static size_t g_ranSelfChecks = 0;

static PCHANNEL_INIT_EVENT_EX_FN g_initEvent = NULL;
static LPVOID g_userParam = NULL;
static RailClientContext* g_rail = NULL;
static int g_initHandle = 0;

static UINT VCAPITYPE fake_init_ex(LPVOID userParam, LPVOID clientContext,
                                   WINPR_ATTR_UNUSED LPVOID initHandle,
                                   WINPR_ATTR_UNUSED PCHANNEL_DEF channel,
                                   WINPR_ATTR_UNUSED INT channelCount,
                                   WINPR_ATTR_UNUSED ULONG version,
                                   PCHANNEL_INIT_EVENT_EX_FN initEvent)
{
	g_userParam = userParam;
	g_rail = clientContext;
	g_initEvent = initEvent;
	return CHANNEL_RC_OK;
}

static UINT16 read_le16(const BYTE* p)
{
	return (UINT16)(p[0] | (p[1] << 8));
}

static UINT32 read_le32(const BYTE* p)
{
	return (UINT32)p[0] | ((UINT32)p[1] << 8) | ((UINT32)p[2] << 16) | ((UINT32)p[3] << 24);
}

/* The channel manager's write, as the RAIL channel calls it (rail_main.c rail_send): the PDU
 * bytes plus the wStream that owns them as pUserData. A real manager queues the data and frees
 * the stream on CHANNEL_EVENT_WRITE_COMPLETE; this one records the PDU and frees it at once. On a
 * failed write the channel frees the stream itself, so an injected failure must not. */
static UINT VCAPITYPE fake_write_ex(LPVOID pInitHandle, WINPR_ATTR_UNUSED DWORD openHandle,
                                    LPVOID pData, ULONG dataLength, LPVOID pUserData)
{
	const BYTE* data = (const BYTE*)pData;
	const size_t index = g_writes++;
	const BOOL fail = (g_failWrite == index + 1);

	if (pInitHandle != (LPVOID)&g_initHandle)
		g_foreignHandle = TRUE;
	if (index < MAX_WRITES)
	{
		SentOrder* o = &g_sent[index];
		memset(o, 0, sizeof(*o));
		if (data && (dataLength >= 4))
		{
			o->orderType = read_le16(data);
			o->orderLength = read_le16(data + 2);
			o->hasHeader = TRUE;
		}
		if (data && (dataLength >= 8))
		{
			o->field = read_le32(data + 4);
			o->hasField = TRUE;
		}
		o->failed = fail;
	}
	if (fail)
		return INJECTED_ERROR;
	if (pUserData)
		Stream_Free((wStream*)pUserData, TRUE);
	return CHANNEL_RC_OK;
}

static void reset_capture(size_t failWrite)
{
	memset(g_sent, 0, sizeof(g_sent));
	g_writes = 0;
	g_failWrite = failWrite;
	g_foreignHandle = FALSE;
}

static size_t captured(void)
{
	return (g_writes < MAX_WRITES) ? g_writes : MAX_WRITES;
}

static size_t count_orders(UINT16 orderType)
{
	size_t n = 0;
	for (size_t i = 0; i < captured(); i++)
	{
		if (g_sent[i].hasHeader && (g_sent[i].orderType == orderType))
			n++;
	}
	return n;
}

static const char* order_name(UINT16 orderType)
{
	switch (orderType)
	{
		case TS_RAIL_ORDER_EXEC:
			return "EXEC";
		case TS_RAIL_ORDER_ACTIVATE:
			return "ACTIVATE";
		case TS_RAIL_ORDER_SYSPARAM:
			return "SYSPARAM";
		case TS_RAIL_ORDER_SYSCOMMAND:
			return "SYSCOMMAND";
		case TS_RAIL_ORDER_HANDSHAKE:
			return "HANDSHAKE";
		case TS_RAIL_ORDER_NOTIFY_EVENT:
			return "NOTIFY_EVENT";
		case TS_RAIL_ORDER_WINDOWMOVE:
			return "WINDOWMOVE";
		case TS_RAIL_ORDER_CLIENTSTATUS:
			return "CLIENTSTATUS";
		case TS_RAIL_ORDER_SYSMENU:
			return "SYSMENU";
		case TS_RAIL_ORDER_LANGBARINFO:
			return "LANGBARINFO";
		case TS_RAIL_ORDER_GET_APPID_REQ:
			return "GET_APPID_REQ";
		case TS_RAIL_ORDER_LANGUAGEIMEINFO:
			return "LANGUAGEIMEINFO";
		case TS_RAIL_ORDER_COMPARTMENTINFO:
			return "COMPARTMENTINFO";
		case TS_RAIL_ORDER_HANDSHAKE_EX:
			return "HANDSHAKE_EX";
		case TS_RAIL_ORDER_CLOAK:
			return "CLOAK";
		case TS_RAIL_ORDER_SNAP_ARRANGE:
			return "SNAP_ARRANGE";
		case TS_RAIL_ORDER_TEXTSCALEINFO:
			return "TEXTSCALEINFO";
		case TS_RAIL_ORDER_CARETBLINKINFO:
			return "CARETBLINKINFO";
		default:
			return "UNKNOWN";
	}
}

/* "[HANDSHAKE(build=0x...) CLIENTSTATUS(flags=0x...)]"; a failed write is marked
 * "!write-failed". */
static void format_orders(char* buf, size_t size)
{
	size_t used = 0;
	int n = snprintf(buf, size, "[");
	used = (n > 0) ? (size_t)n : 0;
	for (size_t i = 0; (i < captured()) && (used < size); i++)
	{
		const SentOrder* o = &g_sent[i];
		const char* sep = (i == 0) ? "" : " ";
		const char* tail = o->failed ? "!write-failed" : "";
		if (!o->hasHeader)
			n = snprintf(buf + used, size - used, "%s<short write>%s", sep, tail);
		else if ((o->orderType == TS_RAIL_ORDER_HANDSHAKE) && o->hasField)
			n = snprintf(buf + used, size - used, "%sHANDSHAKE(build=0x%08" PRIX32 ")%s", sep,
			             o->field, tail);
		else if ((o->orderType == TS_RAIL_ORDER_CLIENTSTATUS) && o->hasField)
			n = snprintf(buf + used, size - used, "%sCLIENTSTATUS(flags=0x%08" PRIX32 ")%s", sep,
			             o->field, tail);
		else
			n = snprintf(buf + used, size - used, "%s%s(0x%04" PRIX16 ")%s", sep,
			             order_name(o->orderType), o->orderType, tail);
		used += (n > 0) ? (size_t)n : 0;
	}
	if ((g_writes > MAX_WRITES) && (used < size))
	{
		n = snprintf(buf + used, size - used, " ...+%zu", g_writes - MAX_WRITES);
		used += (n > 0) ? (size_t)n : 0;
	}
	if (used < size)
		(void)snprintf(buf + used, size - used, "]");
}

static const char* inject_name(size_t failWrite)
{
	switch (failWrite)
	{
		case 0:
			return "none";
		case 1:
			return "write1";
		default:
			return "write2";
	}
}

/* Injected failures make the channel log an ERROR line per failed write; that is the expected
 * path here, so the channel's logger is silenced for exactly those cases. */
static DWORD quiet_rail_log(BOOL quiet, DWORD previous)
{
	wLog* log = WLog_Get(RAIL_LOG_TAG);
	if (!log)
		return previous;
	const DWORD current = WLog_GetLogLevel(log);
	(void)WLog_SetLogLevel(log, quiet ? WLOG_OFF : previous);
	return current;
}

typedef enum
{
	CASE_OK,
	CASE_FAIL, /* the prefix's behaviour differs from the expectation */
	CASE_ERROR /* the harness itself misbehaved: no verdict on the prefix */
} CaseResult;

static const char* result_word(CaseResult r)
{
	switch (r)
	{
		case CASE_OK:
			return "ok";
		case CASE_FAIL:
			return "FAIL: ";
		default:
			return "ERROR: ";
	}
}

/* One default-handshake case. The verdict, in order: the first order is HANDSHAKE carrying
 * FreeRDP_ClientBuild; no EXEC at all; after a failed HANDSHAKE write nothing else is sent;
 * otherwise CLIENTSTATUS follows directly, with FreeRDP_RemoteAppFeatureFlags and the
 * AUTORECONNECT bit following FreeRDP_AutoReconnectionEnabled, and nothing else follows; the
 * handler returns CHANNEL_RC_OK, or the injected error when a write failed. */
static CaseResult handshake_case(rdpSettings* settings, size_t n, BOOL extended, BOOL reconnect,
                                 UINT32 flags, size_t failWrite, const char** whyOut)
{
	*whyOut = NULL;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_RemoteAppFeatureFlags, flags) ||
	    !freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, reconnect))
	{
		*whyOut = "cannot write the settings this case needs";
		(void)printf("case %02zu: ERROR: %s\n", n, *whyOut);
		return CASE_ERROR;
	}
	const UINT32 clientBuild = freerdp_settings_get_uint32(settings, FreeRDP_ClientBuild);
	const UINT32 expectedFlags = reconnect ? (flags | TS_RAIL_CLIENTSTATUS_AUTORECONNECT)
	                                       : (flags & ~TS_RAIL_CLIENTSTATUS_AUTORECONNECT);
	const UINT expectedRc = (failWrite != 0) ? INJECTED_ERROR : CHANNEL_RC_OK;

	DWORD saved = 0;
	if (failWrite != 0)
		saved = quiet_rail_log(TRUE, 0);
	reset_capture(failWrite);
	UINT rc = 0;
	if (extended)
	{
		const RAIL_HANDSHAKE_EX_ORDER handshakeEx = {
			.buildNumber = SERVER_BUILD,
			.railHandshakeFlags = TS_RAIL_ORDER_HANDSHAKEEX_FLAGS_HIDEF |
			                      TS_RAIL_ORDER_HANDSHAKE_EX_FLAGS_EXTENDED_SPI_SUPPORTED
		};
		rc = g_rail->ServerHandshakeEx(g_rail, &handshakeEx);
		g_ranHandshakeEx++;
	}
	else
	{
		const RAIL_HANDSHAKE_ORDER handshake = { .buildNumber = SERVER_BUILD };
		rc = g_rail->ServerHandshake(g_rail, &handshake);
		g_ranHandshake++;
	}
	if (failWrite != 0)
		(void)quiet_rail_log(FALSE, saved);

	CaseResult result = CASE_FAIL;
	const char* why = NULL;
	if (g_foreignHandle)
	{
		result = CASE_ERROR;
		why = "a write carried an init handle that is not the channel's (a harness fault)";
	}
	else if ((captured() == 0) || !g_sent[0].hasHeader ||
	         (g_sent[0].orderType != TS_RAIL_ORDER_HANDSHAKE))
		why = "the first order sent is not HANDSHAKE";
	else if (!g_sent[0].hasField || (g_sent[0].field != clientBuild))
		why = "the HANDSHAKE answer does not carry FreeRDP_ClientBuild";
	else if (count_orders(TS_RAIL_ORDER_EXEC) != 0)
		why = "an EXEC was sent during the handshake";
	else if (failWrite == 1)
	{
		if (g_writes != 1)
			why = "orders were sent after the HANDSHAKE write failed";
	}
	else if ((captured() < 2) || !g_sent[1].hasHeader ||
	         (g_sent[1].orderType != TS_RAIL_ORDER_CLIENTSTATUS))
		why = "no CLIENTSTATUS right after the HANDSHAKE";
	else if (!g_sent[1].hasField || (g_sent[1].field != expectedFlags))
		why = "the CLIENTSTATUS flags are not RemoteAppFeatureFlags with AUTORECONNECT per "
		      "AutoReconnectionEnabled";
	else if (g_writes != 2)
		why = "orders beyond HANDSHAKE and CLIENTSTATUS were sent";
	if (!why && (rc != expectedRc))
		why = (failWrite != 0) ? "the injected write failure was not returned by the handler"
		                       : "the handler did not return CHANNEL_RC_OK";
	if (!why)
		result = CASE_OK;

	char orders[512];
	format_orders(orders, sizeof(orders));
	(void)printf("case %02zu: %-11s reconnect=%d flags=0x%08" PRIX32 " inject=%-6s rc=0x%08X "
	             "orders=%s -> %s%s\n",
	             n, extended ? "HandshakeEx" : "Handshake", reconnect ? 1 : 0, flags,
	             inject_name(failWrite), rc, orders, result_word(result), why ? why : "");
	*whyOut = why;
	return result;
}

/* Self-check: client_rail_server_start_cmd() sends CLIENTSTATUS, the system parameters and the
 * EXEC, in both a patched and an unpatched 3.32.1 and in 3.33.0. Seeing exactly one EXEC, last,
 * proves the capture would see an EXEC the handshake sent; failing the first write proves the
 * injection reaches the CLIENTSTATUS write and that nothing (no EXEC) follows a failed status. */
static BOOL start_cmd_selfcheck(size_t n, size_t failWrite)
{
	DWORD saved = 0;
	if (failWrite != 0)
		saved = quiet_rail_log(TRUE, 0);
	reset_capture(failWrite);
	const UINT rc = client_rail_server_start_cmd(g_rail);
	g_ranSelfChecks++;
	if (failWrite != 0)
		(void)quiet_rail_log(FALSE, saved);

	const char* why = NULL;
	if (g_foreignHandle)
		why = "a write carried an init handle that is not the channel's";
	else if ((captured() == 0) || !g_sent[0].hasHeader ||
	         (g_sent[0].orderType != TS_RAIL_ORDER_CLIENTSTATUS))
		why = "the start command did not begin with CLIENTSTATUS (this self-check assumes "
		      "client_rail_server_start_cmd sends it first, as 3.32.1 and 3.33.0 do; if a newer "
		      "FreeRDP stopped doing that, it is this self-check that needs revisiting, not the "
		      "prefix)";
	else if (failWrite != 0)
	{
		if ((rc != INJECTED_ERROR) || (g_writes != 1))
			why = "a failed CLIENTSTATUS write did not stop the start command with the error";
	}
	else if ((rc != CHANNEL_RC_OK) || (count_orders(TS_RAIL_ORDER_EXEC) != 1) ||
	         (g_writes > MAX_WRITES) ||
	         (g_sent[captured() - 1].orderType != TS_RAIL_ORDER_EXEC))
		why = "the capture did not see exactly one EXEC, last";

	char orders[512];
	format_orders(orders, sizeof(orders));
	(void)printf("self-check %02zu: client_rail_server_start_cmd inject=%-6s rc=0x%08X "
	             "orders=%s -> %s%s\n",
	             n, inject_name(failWrite), rc, orders, why ? "FAIL: " : "ok", why ? why : "");
	return why == NULL;
}

/* The verdict must be about the prefix the caller named: refuse to judge a libfreerdp-client3
 * loaded from anywhere else (DYLD_* overrides, a stale rpath, a system FreeRDP). */
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

typedef struct
{
	const char* why;
	size_t count;
} ReasonCount;

static void tally_reason(ReasonCount* reasons, size_t* used, const char* why)
{
	for (size_t i = 0; i < *used; i++)
	{
		if (strcmp(reasons[i].why, why) == 0)
		{
			reasons[i].count++;
			return;
		}
	}
	if (*used < MAX_REASONS)
	{
		reasons[*used].why = why;
		reasons[*used].count = 1;
		(*used)++;
	}
}

int main(int argc, char* argv[])
{
	if (argc != 2)
	{
		(void)fprintf(stderr, "usage: %s <freerdp-prefix>\n", argv[0]);
		(void)printf("rail-handshake-check: ERROR usage: rail-handshake-check <freerdp-prefix>\n");
		return CHECK_ERROR;
	}
	char loaded[PATH_MAX] = "";
	if (!loaded_from_prefix(argv[1], loaded, sizeof(loaded)))
	{
		(void)printf("rail-handshake-check: ERROR libfreerdp-client3 was loaded from '%s', not "
		             "from %s/lib -- this run cannot judge that prefix\n",
		             loaded, argv[1]);
		return CHECK_ERROR;
	}
	(void)printf("rail-handshake-check: FreeRDP %s, libfreerdp-client3 loaded from %s\n",
	             freerdp_get_version_string(), loaded);

	int result = CHECK_ERROR;
	const char* error = NULL;
	char errorBuf[256] = "";
	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(rdpClientContext);
	rdpContext* context = freerdp_client_context_new(&entry);
	if (!context)
	{
		(void)printf("rail-handshake-check: ERROR freerdp_client_context_new failed\n");
		return CHECK_ERROR;
	}

	PVIRTUALCHANNELENTRYEX entryEx = WINPR_FUNC_PTR_CAST(
	    freerdp_channels_load_static_addin_entry(
	        RAIL_SVC_CHANNEL_NAME, NULL, NULL,
	        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX),
	    PVIRTUALCHANNELENTRYEX);
	if (!entryEx)
	{
		error = "the prefix has no built-in rail channel entry (VirtualChannelEntryEx)";
		goto done;
	}
	CHANNEL_ENTRY_POINTS_FREERDP_EX channelEntry = { 0 };
	channelEntry.cbSize = sizeof(channelEntry);
	channelEntry.protocolVersion = VIRTUAL_CHANNEL_VERSION_WIN2000;
	channelEntry.pVirtualChannelInitEx = fake_init_ex;
	channelEntry.pVirtualChannelWriteEx = fake_write_ex;
	channelEntry.MagicNumber = FREERDP_CHANNEL_MAGIC_NUMBER;
	channelEntry.context = context;
	if (!entryEx((PCHANNEL_ENTRY_POINTS_EX)&channelEntry, &g_initHandle))
	{
		error = "the rail channel's VirtualChannelEntryEx failed";
		goto done;
	}
	if (!g_rail || !g_initEvent || !g_rail->ServerHandshake || !g_rail->ServerHandshakeEx)
	{
		error = "the rail channel did not register a client context with default handshake "
		        "handlers";
		goto terminate;
	}

	rdpSettings* settings = context->settings;
	if (!freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, TRUE) ||
	    !freerdp_settings_set_bool(settings, FreeRDP_RemoteAppLanguageBarSupported, FALSE) ||
	    !freerdp_settings_set_string(settings, FreeRDP_RemoteApplicationProgram,
	                                 "||rail-handshake-check"))
	{
		error = "cannot write the settings the cases need";
		goto terminate;
	}
	size_t selfPassed = 0;
	for (size_t failWrite = 0; failWrite < 2; failWrite++)
	{
		if (start_cmd_selfcheck(failWrite + 1, failWrite))
			selfPassed++;
	}
	if (g_ranSelfChecks != EXPECTED_SELF_CHECKS)
	{
		(void)snprintf(errorBuf, sizeof(errorBuf),
		               "%zu capture self-check(s) ran, expected %u, so the handshake cases would "
		               "not be evidence",
		               g_ranSelfChecks, EXPECTED_SELF_CHECKS);
		error = errorBuf;
		goto terminate;
	}
	if (selfPassed != g_ranSelfChecks)
	{
		error = "the capture self-check failed, so the handshake cases would not be evidence";
		goto terminate;
	}

	const UINT32 flagSets[] = { 0, TS_RAIL_CLIENTSTATUS_ALLOWLOCALMOVESIZE |
		                               TS_RAIL_CLIENTSTATUS_AUTORECONNECT |
		                               TS_RAIL_CLIENTSTATUS_ZORDER_SYNC };
	size_t n = 0;
	size_t failures = 0;
	size_t harnessErrors = 0;
	ReasonCount reasons[MAX_REASONS] = { { 0 } };
	size_t reasonsUsed = 0;
	for (size_t extended = 0; extended < 2; extended++)
	{
		for (size_t reconnect = 0; reconnect < 2; reconnect++)
		{
			for (size_t f = 0; f < ARRAYSIZE(flagSets); f++)
			{
				for (size_t failWrite = 0; failWrite < 3; failWrite++)
				{
					const char* why = NULL;
					const CaseResult r =
					    handshake_case(settings, ++n, extended != 0, reconnect != 0,
					                   flagSets[f], failWrite, &why);
					if (r == CASE_FAIL)
					{
						failures++;
						tally_reason(reasons, &reasonsUsed, why);
					}
					else if (r == CASE_ERROR)
						harnessErrors++;
				}
			}
		}
	}
	const size_t ran = g_ranHandshake + g_ranHandshakeEx;
	if (harnessErrors != 0)
	{
		(void)snprintf(errorBuf, sizeof(errorBuf),
		               "%zu handshake case(s) hit a harness fault (see the case lines)",
		               harnessErrors);
		error = errorBuf;
	}
	else if ((g_ranHandshake != EXPECTED_CASES_PER_VARIANT) ||
	         (g_ranHandshakeEx != EXPECTED_CASES_PER_VARIANT))
	{
		(void)snprintf(errorBuf, sizeof(errorBuf),
		               "ran %zu Handshake + %zu HandshakeEx cases, expected %u + %u",
		               g_ranHandshake, g_ranHandshakeEx, EXPECTED_CASES_PER_VARIANT,
		               EXPECTED_CASES_PER_VARIANT);
		error = errorBuf;
	}
	else if (failures != 0)
	{
		char summary[1024] = "";
		size_t used = 0;
		for (size_t i = 0; (i < reasonsUsed) && (used < sizeof(summary)); i++)
		{
			const int w = snprintf(summary + used, sizeof(summary) - used, "%s%zux %s",
			                       (i == 0) ? "" : "; ", reasons[i].count, reasons[i].why);
			used += (w > 0) ? (size_t)w : 0;
		}
		(void)printf("rail-handshake-check: FAIL %zu/%zu handshake cases [%s] -- the default RAIL "
		             "handshake answer is not the one FreeRDP PR #13696 specifies (HANDSHAKE, then "
		             "CLIENTSTATUS from the settings and nothing else, write failures returned; "
		             "carried as ThirdParty/patches/0003-rail-client-status-on-default-"
		             "handshake.patch until a pin >= 3.33.0); self-checks %zu/%zu ok\n",
		             failures, ran, summary, selfPassed, g_ranSelfChecks);
		result = CHECK_FAIL;
	}
	else
	{
		(void)printf("rail-handshake-check: PASS %zu/%zu handshake cases (%zu Handshake + %zu "
		             "HandshakeEx: HANDSHAKE then CLIENTSTATUS and nothing else, no EXEC; write "
		             "failures returned), self-checks %zu/%zu ok\n",
		             ran - failures, ran, g_ranHandshake, g_ranHandshakeEx, selfPassed,
		             g_ranSelfChecks);
		result = CHECK_PASS;
	}

terminate:
	if (g_initEvent)
		g_initEvent(g_userParam, &g_initHandle, CHANNEL_EVENT_TERMINATED, NULL, 0);
done:
	if (error)
	{
		(void)printf("rail-handshake-check: ERROR %s -- this run cannot judge the prefix\n", error);
		result = CHECK_ERROR;
	}
	freerdp_client_context_free(context);
	return result;
}
