/**
 * rail-probe: single-session RAIL/RDPGFX diagnostic probe built on libfreerdp3 +
 * freerdp-client3.
 *
 * Connects to a Windows RDS host in RemoteApp (RAIL) mode, launches --app, optionally
 * launches a second RemoteApp after a delay to prove multi-app support, and logs every
 * connection/RAIL/RDPGFX event it observes as JSON Lines to --out. Prints a summary JSON
 * object to stdout on exit.
 *
 * Modeled on FreeRDP's client/Sample (tf_freerdp.c / tf_channels.c) minimal client, plus
 * the RAIL channel wiring pattern from client/X11/xf_rail.c.
 */

#include <freerdp/config.h>

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <freerdp/freerdp.h>
#include <freerdp/constants.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/utils/signal.h>
#include <freerdp/client/rail.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/channels.h>

#include <winpr/crt.h>
#include <winpr/assert.h>
#include <winpr/synch.h>
#include <winpr/string.h>

/* ------------------------------------------------------------------------------------ */
/* Types                                                                                 */
/* ------------------------------------------------------------------------------------ */

typedef struct
{
	char* program;
	uint32_t execResult;
	uint32_t rawResult;
} probeExecResult;

typedef struct
{
	char name[64];
	uint64_t count;
} probeEventCount;

typedef struct
{
	char host[256];
	char user[256];
	char pass[256];
	char app[520];
	char second_exec[520];
	int second_delay;
	int duration;
	bool no_hidef;
	bool decode;
	char out_path[1024];
} probeConfig;

typedef struct
{
	uint32_t codecId;
	uint64_t count;
} probeCodecCount;

typedef struct
{
	/* MUST be first member: freerdp_client_context_new()/casts rely on this layout. */
	rdpClientContext common;

	probeConfig cfg;

	FILE* out;
	pthread_mutex_t log_lock;
	struct timespec t0;
	uint64_t connect_ms;
	bool second_exec_sent;

	/* Wired once the "rail" SVC channel connects. */
	RailClientContext* rail;
	pcRailServerHandshake orig_ServerHandshake;
	pcRailServerHandshakeEx orig_ServerHandshakeEx;

	/* Wired once the RDPGFX DVC connects. */
	pcRdpgfxMapSurfaceToWindow orig_MapSurfaceToWindow;
	pcRdpgfxMapSurfaceToScaledWindow orig_MapSurfaceToScaledWindow;
	pcRdpgfxResetGraphics orig_ResetGraphics;
	pcRdpgfxSurfaceCommand orig_SurfaceCommand; /* only wrapped when --decode is given */
	uint64_t surface_command_count;
	probeCodecCount* codec_counts;
	size_t codec_counts_count;
	size_t codec_counts_cap;

	/* Bookkeeping for the final summary line. */
	uint32_t* created_ids;
	size_t created_count;
	size_t created_cap;

	uint32_t* deleted_ids;
	size_t deleted_count;
	size_t deleted_cap;

	probeExecResult* exec_results;
	size_t exec_results_count;
	size_t exec_results_cap;

	probeEventCount* event_counts;
	size_t event_counts_count;
	size_t event_counts_cap;
} probeContext;

/* Only the RDPGFX wrappers need this: gdi_graphics_pipeline_init() claims
 * RdpgfxClientContext::custom for its own rdpGdi* pointer, so we cannot smuggle our
 * context through there. This is a single-session CLI tool, so a global is fine. */
static probeContext* g_probe = NULL;

/* ------------------------------------------------------------------------------------ */
/* Small utilities                                                                      */
/* ------------------------------------------------------------------------------------ */

static void json_escape(const char* in, char* out, size_t outsz)
{
	size_t o = 0;
	if (!in)
		in = "";
	if (outsz == 0)
		return;
	for (size_t i = 0; in[i] != '\0' && o + 2 < outsz; i++)
	{
		unsigned char c = (unsigned char)in[i];
		switch (c)
		{
			case '"':
			case '\\':
				out[o++] = '\\';
				out[o++] = (char)c;
				break;
			case '\n':
				out[o++] = '\\';
				out[o++] = 'n';
				break;
			case '\r':
				out[o++] = '\\';
				out[o++] = 'r';
				break;
			case '\t':
				out[o++] = '\\';
				out[o++] = 't';
				break;
			default:
				if (c < 0x20)
				{
					/* skip other control characters */
				}
				else
					out[o++] = (char)c;
				break;
		}
	}
	out[o] = '\0';
}

static uint64_t get_mono_ms(probeContext* p)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	int64_t sec = (int64_t)ts.tv_sec - (int64_t)p->t0.tv_sec;
	int64_t nsec = (int64_t)ts.tv_nsec - (int64_t)p->t0.tv_nsec;
	return (uint64_t)(sec * 1000 + nsec / 1000000);
}

static void get_tid_hex(char* buf, size_t n)
{
	unsigned long tid = (unsigned long)(uintptr_t)pthread_self();
	snprintf(buf, n, "0x%lx", tid);
}

static void bump_event_count(probeContext* p, const char* ev)
{
	for (size_t i = 0; i < p->event_counts_count; i++)
	{
		if (strcmp(p->event_counts[i].name, ev) == 0)
		{
			p->event_counts[i].count++;
			return;
		}
	}
	if (p->event_counts_count == p->event_counts_cap)
	{
		size_t newcap = p->event_counts_cap ? p->event_counts_cap * 2 : 16;
		probeEventCount* na = realloc(p->event_counts, newcap * sizeof(probeEventCount));
		if (!na)
			return;
		p->event_counts = na;
		p->event_counts_cap = newcap;
	}
	snprintf(p->event_counts[p->event_counts_count].name,
	         sizeof(p->event_counts[p->event_counts_count].name), "%s", ev);
	p->event_counts[p->event_counts_count].count = 1;
	p->event_counts_count++;
}

/* Logs one JSONL event. `fmt` (if non-NULL) is a printf format producing the extra JSON
 * fields (no surrounding braces/commas). Any string values interpolated via %s must
 * already be JSON-escaped by the caller (see json_escape above). */
static void log_event(probeContext* p, const char* ev, const char* fmt, ...)
{
	if (!p)
		return;

	char tidbuf[32];
	get_tid_hex(tidbuf, sizeof(tidbuf));
	uint64_t tms = get_mono_ms(p);

	char extra[4096] = { 0 };
	if (fmt)
	{
		va_list ap;
		va_start(ap, fmt);
		vsnprintf(extra, sizeof(extra), fmt, ap);
		va_end(ap);
	}

	pthread_mutex_lock(&p->log_lock);
	bump_event_count(p, ev);
	if (p->out)
	{
		if (extra[0] != '\0')
			fprintf(p->out, "{\"t_ms\":%llu,\"tid\":\"%s\",\"ev\":\"%s\",%s}\n",
			        (unsigned long long)tms, tidbuf, ev, extra);
		else
			fprintf(p->out, "{\"t_ms\":%llu,\"tid\":\"%s\",\"ev\":\"%s\"}\n",
			        (unsigned long long)tms, tidbuf, ev);
		fflush(p->out);
	}
	pthread_mutex_unlock(&p->log_lock);
}

static void track_window_id(uint32_t** arr, size_t* count, size_t* cap, uint32_t id)
{
	if (*count == *cap)
	{
		size_t newcap = *cap ? *cap * 2 : 16;
		uint32_t* na = realloc(*arr, newcap * sizeof(uint32_t));
		if (!na)
			return;
		*arr = na;
		*cap = newcap;
	}
	(*arr)[(*count)++] = id;
}

static void track_exec_result(probeContext* p, const char* program, uint32_t execResult,
                               uint32_t rawResult)
{
	if (p->exec_results_count == p->exec_results_cap)
	{
		size_t newcap = p->exec_results_cap ? p->exec_results_cap * 2 : 8;
		probeExecResult* na = realloc(p->exec_results, newcap * sizeof(probeExecResult));
		if (!na)
			return;
		p->exec_results = na;
		p->exec_results_cap = newcap;
	}
	p->exec_results[p->exec_results_count].program = strdup(program ? program : "");
	p->exec_results[p->exec_results_count].execResult = execResult;
	p->exec_results[p->exec_results_count].rawResult = rawResult;
	p->exec_results_count++;
}

/* Best-effort name for a WireToSurface1 codecId, from include/freerdp/channels/rdpgfx.h's
 * RDPGFX_CODECID enum. RDPGFX_CODECID_AV1 only exists when this FreeRDP build was
 * configured WITH_GFX_AV1 -- this build (per prefix/include/freerdp3/freerdp/config.h)
 * was not, so that arm is compiled out rather than referencing an undefined enumerator. */
static const char* codec_id_name(uint32_t id)
{
	switch (id)
	{
		case RDPGFX_CODECID_UNCOMPRESSED:
			return "UNCOMPRESSED";
#if defined(WITH_GFX_AV1)
		case RDPGFX_CODECID_AV1:
			return "AV1";
#endif
		case RDPGFX_CODECID_CAVIDEO:
			return "CAVIDEO";
		case RDPGFX_CODECID_CLEARCODEC:
			return "CLEARCODEC";
		case RDPGFX_CODECID_CAPROGRESSIVE:
			return "CAPROGRESSIVE";
		case RDPGFX_CODECID_PLANAR:
			return "PLANAR";
		case RDPGFX_CODECID_AVC420:
			return "AVC420";
		case RDPGFX_CODECID_ALPHA:
			return "ALPHA";
		case RDPGFX_CODECID_CAPROGRESSIVE_V2:
			return "CAPROGRESSIVE_V2";
		case RDPGFX_CODECID_AVC444:
			return "AVC444";
		case RDPGFX_CODECID_AVC444v2:
			return "AVC444v2";
		default:
			return "UNKNOWN";
	}
}

static void bump_codec_count(probeContext* p, uint32_t codecId)
{
	for (size_t i = 0; i < p->codec_counts_count; i++)
	{
		if (p->codec_counts[i].codecId == codecId)
		{
			p->codec_counts[i].count++;
			return;
		}
	}
	if (p->codec_counts_count == p->codec_counts_cap)
	{
		size_t newcap = p->codec_counts_cap ? p->codec_counts_cap * 2 : 8;
		probeCodecCount* na = realloc(p->codec_counts, newcap * sizeof(probeCodecCount));
		if (!na)
			return;
		p->codec_counts = na;
		p->codec_counts_cap = newcap;
	}
	p->codec_counts[p->codec_counts_count].codecId = codecId;
	p->codec_counts[p->codec_counts_count].count = 1;
	p->codec_counts_count++;
}

/* Renders {"<codecId>":<count>,...} into buf for the periodic CodecStats JSONL line. */
static void build_codec_counts_json(probeContext* p, char* buf, size_t bufsz)
{
	size_t o = 0;
	int n = snprintf(buf + o, bufsz - o, "{");
	if (n > 0)
		o += (size_t)n;
	for (size_t i = 0; i < p->codec_counts_count && o < bufsz; i++)
	{
		n = snprintf(buf + o, bufsz - o, "%s\"%u\":%llu", i ? "," : "", p->codec_counts[i].codecId,
		             (unsigned long long)p->codec_counts[i].count);
		if (n > 0)
			o += (size_t)n;
	}
	if (o < bufsz)
		snprintf(buf + o, bufsz - o, "}");
}

/* ------------------------------------------------------------------------------------ */
/* CLI                                                                                   */
/* ------------------------------------------------------------------------------------ */

static void usage(const char* prog)
{
	printf("Usage: %s --host <host> --user <user> --app <exe-path> --out "
	       "<file.jsonl> [options]\n"
	       "\n"
	       "  --host <host>            RDP host (default: $WIN_HOST)\n"
	       "  --user <user>            RDP username (default: $WIN_USER)\n"
	       "                           Password is $WIN_PASS only — deliberately no --pass\n"
	       "                           flag, so it never appears in shell history or a\n"
	       "                           process listing (ps/argv is world-readable).\n"
	       "  --app <exe-path>         RemoteApp program to launch, e.g. 'C:\\\\Windows\\\\"
	       "System32\\\\winver.exe'\n"
	       "  --second-exec <exe-path> Launch a second RemoteApp after --second-delay seconds\n"
	       "  --second-delay <secs>    Delay before launching --second-exec (default: 8)\n"
	       "  --duration <secs>        Total session duration before clean disconnect "
	       "(default: 25)\n"
	       "  --no-hidef               Disable HiDefRemoteApp (FreeRDP_HiDefRemoteApp=FALSE)\n"
	       "  --decode                 Keep FreeRDP_DeactivateClientDecoding=FALSE (full GFX "
	       "decode path) and log per-codecId SurfaceCommand stats (CodecStats event every 50 "
	       "frames, codecCounts in the summary). Without this flag, decoding stays disabled "
	       "as before.\n"
	       "  --out <file.jsonl>       JSON Lines event log output path\n"
	       "  --help                   Show this help and exit\n",
	       prog);
}

static bool parse_args(int argc, char** argv, probeConfig* cfg)
{
	memset(cfg, 0, sizeof(*cfg));
	cfg->second_delay = 8;
	cfg->duration = 25;

	const char* envHost = getenv("WIN_HOST");
	const char* envUser = getenv("WIN_USER");
	const char* envPass = getenv("WIN_PASS");
	if (envHost)
		snprintf(cfg->host, sizeof(cfg->host), "%s", envHost);
	if (envUser)
		snprintf(cfg->user, sizeof(cfg->user), "%s", envUser);
	if (envPass)
		snprintf(cfg->pass, sizeof(cfg->pass), "%s", envPass);

	int i;
	for (i = 1; i < argc; i++)
	{
		const char* a = argv[i];

		if (strcmp(a, "--help") == 0)
		{
			usage(argv[0]);
			exit(0);
		}
		else if (strcmp(a, "--host") == 0)
		{
			if (++i >= argc)
				goto missing;
			snprintf(cfg->host, sizeof(cfg->host), "%s", argv[i]);
		}
		else if (strcmp(a, "--user") == 0)
		{
			if (++i >= argc)
				goto missing;
			snprintf(cfg->user, sizeof(cfg->user), "%s", argv[i]);
		}
		else if (strcmp(a, "--app") == 0)
		{
			if (++i >= argc)
				goto missing;
			snprintf(cfg->app, sizeof(cfg->app), "%s", argv[i]);
		}
		else if (strcmp(a, "--second-exec") == 0)
		{
			if (++i >= argc)
				goto missing;
			snprintf(cfg->second_exec, sizeof(cfg->second_exec), "%s", argv[i]);
		}
		else if (strcmp(a, "--second-delay") == 0)
		{
			if (++i >= argc)
				goto missing;
			cfg->second_delay = atoi(argv[i]);
		}
		else if (strcmp(a, "--duration") == 0)
		{
			if (++i >= argc)
				goto missing;
			cfg->duration = atoi(argv[i]);
		}
		else if (strcmp(a, "--no-hidef") == 0)
		{
			cfg->no_hidef = true;
		}
		else if (strcmp(a, "--decode") == 0)
		{
			cfg->decode = true;
		}
		else if (strcmp(a, "--out") == 0)
		{
			if (++i >= argc)
				goto missing;
			snprintf(cfg->out_path, sizeof(cfg->out_path), "%s", argv[i]);
		}
		else
		{
			fprintf(stderr, "Unknown argument: %s\n", a);
			usage(argv[0]);
			return false;
		}
	}

	if (!cfg->host[0] || !cfg->user[0] || !cfg->pass[0] || !cfg->app[0] || !cfg->out_path[0])
	{
		fprintf(stderr, "Missing required argument(s): --host/--user/--app/--out "
		                "(host/user/pass may come from WIN_HOST/WIN_USER/WIN_PASS env vars; "
		                "pass is env-only, there is no --pass flag)\n");
		usage(argv[0]);
		return false;
	}
	return true;

missing:
	fprintf(stderr, "Missing value for %s\n", argv[i - 1]);
	usage(argv[0]);
	return false;
}

/* ------------------------------------------------------------------------------------ */
/* RAIL window order vtable (context->update->window->*)                                */
/*                                                                                       */
/* Unlike the RAIL channel's Client-side/Server-side callbacks below, FreeRDP installs no */
/* default implementation for these -- only GUI clients (X11/Windows) wire them. So      */
/* there is no "original" to forward to; our logging handler *is* the whole handler.     */
/* ------------------------------------------------------------------------------------ */

static BOOL probe_window_common(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                 const WINDOW_STATE_ORDER* windowState)
{
	probeContext* p = (probeContext*)context;
	char titleEsc[512] = { 0 };

	if (orderInfo->fieldFlags & WINDOW_ORDER_FIELD_TITLE)
	{
		char* title = rail_string_to_utf8_string(&windowState->titleInfo);
		if (title)
		{
			json_escape(title, titleEsc, sizeof(titleEsc));
			free(title);
		}
	}

	const bool isNew = (orderInfo->fieldFlags & WINDOW_ORDER_STATE_NEW) != 0;
	log_event(p, isNew ? "WindowCreate" : "WindowUpdate",
	          "\"windowId\":%u,\"fieldFlags\":%u,\"windowOffsetX\":%d,\"windowOffsetY\":%d,"
	          "\"windowWidth\":%u,\"windowHeight\":%u,\"numVisibilityRects\":%u,"
	          "\"style\":%u,\"styleEx\":%u,\"show\":%u,\"title\":\"%s\"",
	          orderInfo->windowId, orderInfo->fieldFlags, windowState->windowOffsetX,
	          windowState->windowOffsetY, windowState->windowWidth, windowState->windowHeight,
	          windowState->numVisibilityRects, windowState->style, windowState->extendedStyle,
	          windowState->showState, titleEsc);

	if (isNew)
		track_window_id(&p->created_ids, &p->created_count, &p->created_cap, orderInfo->windowId);

	return TRUE;
}

static BOOL probe_window_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	probeContext* p = (probeContext*)context;
	log_event(p, "WindowDelete", "\"windowId\":%u", orderInfo->windowId);
	track_window_id(&p->deleted_ids, &p->deleted_count, &p->deleted_cap, orderInfo->windowId);
	return TRUE;
}

static BOOL probe_window_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                               const WINDOW_ICON_ORDER* windowIcon)
{
	probeContext* p = (probeContext*)context;
	(void)windowIcon;
	log_event(p, "WindowIcon", "\"windowId\":%u", orderInfo->windowId);
	return TRUE;
}

static BOOL probe_window_cached_icon(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                      const WINDOW_CACHED_ICON_ORDER* windowCachedIcon)
{
	probeContext* p = (probeContext*)context;
	(void)windowCachedIcon;
	log_event(p, "WindowCachedIcon", "\"windowId\":%u", orderInfo->windowId);
	return TRUE;
}

static BOOL probe_notify_icon_create(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                      const NOTIFY_ICON_STATE_ORDER* notifyIconState)
{
	probeContext* p = (probeContext*)context;
	(void)notifyIconState;
	log_event(p, "NotifyIconCreate", "\"windowId\":%u,\"notifyIconId\":%u", orderInfo->windowId,
	          orderInfo->notifyIconId);
	return TRUE;
}

static BOOL probe_notify_icon_update(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                      const NOTIFY_ICON_STATE_ORDER* notifyIconState)
{
	probeContext* p = (probeContext*)context;
	(void)notifyIconState;
	log_event(p, "NotifyIconUpdate", "\"windowId\":%u,\"notifyIconId\":%u", orderInfo->windowId,
	          orderInfo->notifyIconId);
	return TRUE;
}

static BOOL probe_notify_icon_delete(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	probeContext* p = (probeContext*)context;
	log_event(p, "NotifyIconDelete", "\"windowId\":%u,\"notifyIconId\":%u", orderInfo->windowId,
	          orderInfo->notifyIconId);
	return TRUE;
}

static BOOL probe_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo,
                                     const MONITORED_DESKTOP_ORDER* monitoredDesktop)
{
	probeContext* p = (probeContext*)context;
	log_event(p, "MonitoredDesktop",
	          "\"fieldFlags\":%u,\"activeWindowId\":%u,\"numWindowIds\":%u",
	          orderInfo->fieldFlags, monitoredDesktop->activeWindowId,
	          monitoredDesktop->numWindowIds);

	/* Mirrors xf_rail_monitored_desktop(): once the remote desktop composition has
	 * finished (ARC_COMPLETED), send ClientInformation/ClientSystemParam/ClientExecute
	 * for the primary --app via the shared helper. */
	if ((orderInfo->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && p->rail)
	{
		UINT rc = client_rail_server_start_cmd(p->rail);
		log_event(p, "ClientRailServerStartCmd", "\"rc\":%u", (unsigned)rc);
	}

	return TRUE;
}

static BOOL probe_non_monitored_desktop(rdpContext* context, const WINDOW_ORDER_INFO* orderInfo)
{
	probeContext* p = (probeContext*)context;
	(void)orderInfo;
	log_event(p, "NonMonitoredDesktop", NULL);
	return TRUE;
}

/* ------------------------------------------------------------------------------------ */
/* RAIL channel Server* handlers.                                                       */
/*                                                                                       */
/* ServerHandshake/ServerHandshakeEx DO have a real default (rail_server_handshake /     */
/* rail_server_handshake_ex, wired by the rail channel plugin itself at load time) that  */
/* we save and forward to. The rest (ServerExecuteResult, ServerSystemParam,             */
/* ServerLocalMoveSize, ServerMinMaxInfo, ServerZOrderSync, ServerGetAppIdResponse) have  */
/* no default at all (NULL until a client sets them) -- for those our logger *is* the    */
/* entire handler.                                                                       */
/* ------------------------------------------------------------------------------------ */

static UINT probe_rail_server_handshake(RailClientContext* context,
                                         const RAIL_HANDSHAKE_ORDER* handshake)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerHandshake", "\"buildNumber\":%u", handshake->buildNumber);
	if (p->orig_ServerHandshake)
		return p->orig_ServerHandshake(context, handshake);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_handshake_ex(RailClientContext* context,
                                            const RAIL_HANDSHAKE_EX_ORDER* handshakeEx)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerHandshakeEx", "\"buildNumber\":%u,\"railHandshakeFlags\":%u",
	          handshakeEx->buildNumber, handshakeEx->railHandshakeFlags);
	if (p->orig_ServerHandshakeEx)
		return p->orig_ServerHandshakeEx(context, handshakeEx);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_execute_result(RailClientContext* context,
                                              const RAIL_EXEC_RESULT_ORDER* execResult)
{
	probeContext* p = (probeContext*)context->custom;
	char exeEsc[512] = { 0 };
	char* exe = rail_string_to_utf8_string(&execResult->exeOrFile);
	if (exe)
	{
		json_escape(exe, exeEsc, sizeof(exeEsc));
		free(exe);
	}
	log_event(p, "ServerExecuteResult",
	          "\"flags\":%u,\"execResult\":%u,\"rawResult\":%u,\"exeOrFile\":\"%s\"",
	          execResult->flags, execResult->execResult, execResult->rawResult, exeEsc);
	track_exec_result(p, exeEsc, execResult->execResult, execResult->rawResult);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_system_param(RailClientContext* context,
                                            const RAIL_SYSPARAM_ORDER* sysparam)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerSystemParam", "\"param\":%u,\"params\":%u", sysparam->param,
	          sysparam->params);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_local_move_size(RailClientContext* context,
                                               const RAIL_LOCALMOVESIZE_ORDER* localMoveSize)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerLocalMoveSize",
	          "\"windowId\":%u,\"isMoveSizeStart\":%s,\"moveSizeType\":%u,\"posX\":%d,"
	          "\"posY\":%d",
	          localMoveSize->windowId, localMoveSize->isMoveSizeStart ? "true" : "false",
	          localMoveSize->moveSizeType, localMoveSize->posX, localMoveSize->posY);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_min_max_info(RailClientContext* context,
                                            const RAIL_MINMAXINFO_ORDER* minMaxInfo)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerMinMaxInfo",
	          "\"windowId\":%u,\"maxWidth\":%d,\"maxHeight\":%d,\"maxPosX\":%d,\"maxPosY\":%d,"
	          "\"minTrackWidth\":%d,\"minTrackHeight\":%d,\"maxTrackWidth\":%d,"
	          "\"maxTrackHeight\":%d",
	          minMaxInfo->windowId, minMaxInfo->maxWidth, minMaxInfo->maxHeight,
	          minMaxInfo->maxPosX, minMaxInfo->maxPosY, minMaxInfo->minTrackWidth,
	          minMaxInfo->minTrackHeight, minMaxInfo->maxTrackWidth, minMaxInfo->maxTrackHeight);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_zorder_sync(RailClientContext* context,
                                           const RAIL_ZORDER_SYNC* zorder)
{
	probeContext* p = (probeContext*)context->custom;
	log_event(p, "ServerZOrderSync", "\"windowIdMarker\":%u", zorder->windowIdMarker);
	return CHANNEL_RC_OK;
}

static UINT probe_rail_server_get_appid_response(RailClientContext* context,
                                                   const RAIL_GET_APPID_RESP_ORDER* getAppIdResp)
{
	probeContext* p = (probeContext*)context->custom;
	size_t wlen = 0;
	while (wlen < ARRAYSIZE(getAppIdResp->applicationId) && getAppIdResp->applicationId[wlen] != 0)
		wlen++;
	size_t utf8sz = 0;
	char* appId = ConvertWCharNToUtf8Alloc(getAppIdResp->applicationId, wlen, &utf8sz);
	char appIdEsc[512] = { 0 };
	if (appId)
	{
		json_escape(appId, appIdEsc, sizeof(appIdEsc));
		free(appId);
	}
	log_event(p, "ServerGetAppIdResponse", "\"windowId\":%u,\"applicationId\":\"%s\"",
	          getAppIdResp->windowId, appIdEsc);
	return CHANNEL_RC_OK;
}

/* ------------------------------------------------------------------------------------ */
/* RDPGFX wrapped callbacks.                                                             */
/*                                                                                       */
/* gdi_graphics_pipeline_init() (invoked via freerdp_client_OnChannelConnectedEventHandler)*/
/* installs real gdi_MapSurfaceToWindow/gdi_MapSurfaceToScaledWindow/gdi_ResetGraphics    */
/* handlers *and* claims RdpgfxClientContext::custom for its own rdpGdi*. We save those   */
/* function pointers, install our logging wrapper, and forward to the saved original --   */
/* we must NOT touch ::custom.                                                            */
/* ------------------------------------------------------------------------------------ */

static UINT probe_gfx_map_surface_to_window(RdpgfxClientContext* context,
                                             const RDPGFX_MAP_SURFACE_TO_WINDOW_PDU* pdu)
{
	probeContext* p = g_probe;
	log_event(p, "GfxMapSurfaceToWindow",
	          "\"surfaceId\":%u,\"windowId\":%llu,\"mappedWidth\":%u,\"mappedHeight\":%u",
	          pdu->surfaceId, (unsigned long long)pdu->windowId, pdu->mappedWidth,
	          pdu->mappedHeight);
	if (p->orig_MapSurfaceToWindow)
		return p->orig_MapSurfaceToWindow(context, pdu);
	return CHANNEL_RC_OK;
}

static UINT
probe_gfx_map_surface_to_scaled_window(RdpgfxClientContext* context,
                                        const RDPGFX_MAP_SURFACE_TO_SCALED_WINDOW_PDU* pdu)
{
	probeContext* p = g_probe;
	log_event(p, "GfxMapSurfaceToScaledWindow",
	          "\"surfaceId\":%u,\"windowId\":%llu,\"mappedWidth\":%u,\"mappedHeight\":%u,"
	          "\"targetWidth\":%u,\"targetHeight\":%u",
	          pdu->surfaceId, (unsigned long long)pdu->windowId, pdu->mappedWidth,
	          pdu->mappedHeight, pdu->targetWidth, pdu->targetHeight);
	if (p->orig_MapSurfaceToScaledWindow)
		return p->orig_MapSurfaceToScaledWindow(context, pdu);
	return CHANNEL_RC_OK;
}

static UINT probe_gfx_reset_graphics(RdpgfxClientContext* context,
                                      const RDPGFX_RESET_GRAPHICS_PDU* pdu)
{
	probeContext* p = g_probe;
	log_event(p, "GfxResetGraphics", "\"width\":%u,\"height\":%u,\"monitorCount\":%u",
	          pdu->width, pdu->height, pdu->monitorCount);
	if (p->orig_ResetGraphics)
		return p->orig_ResetGraphics(context, pdu);
	return CHANNEL_RC_OK;
}

/* Per-codec (WireToSurface1 codecId) frame counters -- only wired when --decode is given.
 * gdi_graphics_pipeline_init_ex() nulls RdpgfxClientContext::SurfaceCommand entirely when
 * FreeRDP_DeactivateClientDecoding is TRUE (the default, kept for a headless/low-risk probe),
 * so this hook only sees real traffic when --decode leaves DeactivateClientDecoding FALSE and
 * the full GFX decode path (gdi_SurfaceCommand) is active. */
static UINT probe_gfx_surface_command(RdpgfxClientContext* context,
                                       const RDPGFX_SURFACE_COMMAND* cmd)
{
	probeContext* p = g_probe;
	bump_codec_count(p, cmd->codecId);
	p->surface_command_count++;

	if (p->surface_command_count % 50 == 0)
	{
		char countsJson[2048];
		build_codec_counts_json(p, countsJson, sizeof(countsJson));
		log_event(p, "CodecStats", "\"counts\":%s", countsJson);
	}

	if (p->orig_SurfaceCommand)
		return p->orig_SurfaceCommand(context, cmd);
	return CHANNEL_RC_OK;
}

/* ------------------------------------------------------------------------------------ */
/* Channel connect/disconnect                                                            */
/* ------------------------------------------------------------------------------------ */

static void probe_on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	probeContext* p = (probeContext*)context;
	log_event(p, "ChannelConnected", "\"name\":\"%s\"", e->name);

	if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
	{
		RailClientContext* rail = (RailClientContext*)e->pInterface;
		p->rail = rail;
		rail->custom = p;

		rdpWindowUpdate* window = p->common.context.update->window;
		window->WindowCreate = probe_window_common;
		window->WindowUpdate = probe_window_common;
		window->WindowDelete = probe_window_delete;
		window->WindowIcon = probe_window_icon;
		window->WindowCachedIcon = probe_window_cached_icon;
		window->NotifyIconCreate = probe_notify_icon_create;
		window->NotifyIconUpdate = probe_notify_icon_update;
		window->NotifyIconDelete = probe_notify_icon_delete;
		window->MonitoredDesktop = probe_monitored_desktop;
		window->NonMonitoredDesktop = probe_non_monitored_desktop;

		p->orig_ServerHandshake = rail->ServerHandshake;
		p->orig_ServerHandshakeEx = rail->ServerHandshakeEx;
		rail->ServerHandshake = probe_rail_server_handshake;
		rail->ServerHandshakeEx = probe_rail_server_handshake_ex;
		rail->ServerExecuteResult = probe_rail_server_execute_result;
		rail->ServerSystemParam = probe_rail_server_system_param;
		rail->ServerLocalMoveSize = probe_rail_server_local_move_size;
		rail->ServerMinMaxInfo = probe_rail_server_min_max_info;
		rail->ServerZOrderSync = probe_rail_server_zorder_sync;
		rail->ServerGetAppIdResponse = probe_rail_server_get_appid_response;
	}
	else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0)
	{
		/* Installs gdi_MapSurfaceToWindow/gdi_MapSurfaceToScaledWindow/gdi_ResetGraphics
		 * (and, unless --decode is given, since DeactivateClientDecoding is then TRUE, nulls
		 * SurfaceCommand/UpdateSurfaces). */
		freerdp_client_OnChannelConnectedEventHandler(&p->common, e);

		RdpgfxClientContext* gfx = (RdpgfxClientContext*)e->pInterface;
		p->orig_MapSurfaceToWindow = gfx->MapSurfaceToWindow;
		p->orig_MapSurfaceToScaledWindow = gfx->MapSurfaceToScaledWindow;
		p->orig_ResetGraphics = gfx->ResetGraphics;
		gfx->MapSurfaceToWindow = probe_gfx_map_surface_to_window;
		gfx->MapSurfaceToScaledWindow = probe_gfx_map_surface_to_scaled_window;
		gfx->ResetGraphics = probe_gfx_reset_graphics;

		if (p->cfg.decode)
		{
			p->orig_SurfaceCommand = gfx->SurfaceCommand;
			gfx->SurfaceCommand = probe_gfx_surface_command;
		}
	}
	else
	{
		freerdp_client_OnChannelConnectedEventHandler(&p->common, e);
	}
}

static void probe_on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	probeContext* p = (probeContext*)context;
	log_event(p, "ChannelDisconnected", "\"name\":\"%s\"", e->name);

	if (strcmp(e->name, RAIL_SVC_CHANNEL_NAME) == 0)
	{
		if (p->rail)
			p->rail->custom = NULL;
		p->rail = NULL;
	}
	else
	{
		freerdp_client_OnChannelDisconnectedEventHandler(&p->common, e);
	}
}

/* ------------------------------------------------------------------------------------ */
/* Certificate / logon callbacks                                                         */
/* ------------------------------------------------------------------------------------ */

static DWORD probe_verify_certificate_ex(freerdp* instance, const char* host, UINT16 port,
                                          const char* common_name, const char* subject,
                                          const char* issuer, const char* fingerprint,
                                          DWORD flags)
{
	probeContext* p = (probeContext*)instance->context;
	char hostEsc[256] = { 0 };
	char cnEsc[512] = { 0 };
	char subjEsc[512] = { 0 };
	char issEsc[512] = { 0 };
	char fpEsc[2048] = { 0 };
	json_escape(host, hostEsc, sizeof(hostEsc));
	json_escape(common_name, cnEsc, sizeof(cnEsc));
	json_escape(subject, subjEsc, sizeof(subjEsc));
	json_escape(issuer, issEsc, sizeof(issEsc));
	json_escape(fingerprint, fpEsc, sizeof(fpEsc));

	log_event(p, "VerifyCertificateEx",
	          "\"host\":\"%s\",\"port\":%u,\"commonName\":\"%s\",\"subject\":\"%s\","
	          "\"issuer\":\"%s\",\"fingerprint\":\"%s\",\"flags\":%lu",
	          hostEsc, (unsigned)port, cnEsc, subjEsc, issEsc, fpEsc, (unsigned long)flags);

	/* Accept unconditionally (probe, not a trust-decision tool) but only for this
	 * session -- never touches the on-disk known-hosts store. */
	return 2;
}

static int probe_logon_error_info(freerdp* instance, UINT32 data, UINT32 type)
{
	probeContext* p = (probeContext*)instance->context;
	const char* sd = freerdp_get_logon_error_info_data(data);
	const char* st = freerdp_get_logon_error_info_type(type);
	log_event(p, "LogonErrorInfo", "\"data\":\"%s\",\"type\":\"%s\"", sd ? sd : "", st ? st : "");
	return 1;
}

/* ------------------------------------------------------------------------------------ */
/* No-op GDI update callbacks (headless: we never blit anywhere)                         */
/* ------------------------------------------------------------------------------------ */

static BOOL probe_begin_paint(rdpContext* context)
{
	(void)context;
	return TRUE;
}

static BOOL probe_end_paint(rdpContext* context)
{
	(void)context;
	return TRUE;
}

static BOOL probe_play_sound(rdpContext* context, const PLAY_SOUND_UPDATE* play_sound)
{
	(void)context;
	(void)play_sound;
	return TRUE;
}

static BOOL probe_desktop_resize(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;
	rdpSettings* settings = context->settings;
	return gdi_resize(gdi, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
	                   freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
}

static BOOL probe_keyboard_set_indicators(rdpContext* context, UINT16 led_flags)
{
	(void)context;
	(void)led_flags;
	return TRUE;
}

static BOOL probe_keyboard_set_ime_status(rdpContext* context, UINT16 imeId, UINT32 imeState,
                                           UINT32 imeConvMode)
{
	(void)context;
	(void)imeId;
	(void)imeState;
	(void)imeConvMode;
	return TRUE;
}

/* ------------------------------------------------------------------------------------ */
/* Connect lifecycle                                                                     */
/* ------------------------------------------------------------------------------------ */

static BOOL probe_pre_connect(freerdp* instance)
{
	probeContext* p = (probeContext*)instance->context;
	rdpSettings* settings = instance->context->settings;

	log_event(p, "PreConnect", NULL);

	if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE))
		return FALSE;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_UNIX))
		return FALSE;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_NATIVE_XSERVER))
		return FALSE;

	if (!freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, TRUE))
		return FALSE;
	if (!freerdp_settings_set_string(settings, FreeRDP_RemoteApplicationProgram, p->cfg.app))
		return FALSE;
	if (!freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE))
		return FALSE;
	if (!freerdp_settings_set_bool(settings, FreeRDP_HiDefRemoteApp, p->cfg.no_hidef ? FALSE : TRUE))
		return FALSE;
	/* NLA allowed; leave TlsSecurity/RdpSecurity at their (also TRUE) defaults so the
	 * client still negotiates a fallback if the server can't do NLA. */
	if (!freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE))
		return FALSE;

	if (PubSub_SubscribeChannelConnected(instance->context->pubSub, probe_on_channel_connected) <
	    0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub,
	                                        probe_on_channel_disconnected) < 0)
		return FALSE;

	return TRUE;
}

static BOOL probe_post_connect(freerdp* instance)
{
	probeContext* p = (probeContext*)instance->context;
	log_event(p, "PostConnect", NULL);

	if (!gdi_init(instance, PIXEL_FORMAT_XRGB32))
		return FALSE;

	rdpContext* context = instance->context;

	/* Headless by default: don't decode/blit anything. gdi_graphics_pipeline_init_ex() still
	 * wires MapSurfaceToWindow/MapSurfaceToScaledWindow/ResetGraphics unconditionally -- only
	 * SurfaceCommand/UpdateSurfaces/UpdateSurfaceArea get nulled -- so our GFX wrappers above
	 * still see real traffic either way. --decode leaves this at its library default (FALSE)
	 * so the real gdi_SurfaceCommand runs and our per-codecId wrapper sees actual frames. */
	if (!p->cfg.decode)
	{
		if (!freerdp_settings_set_bool(context->settings, FreeRDP_DeactivateClientDecoding, TRUE))
			return FALSE;
	}

	context->update->BeginPaint = probe_begin_paint;
	context->update->EndPaint = probe_end_paint;
	context->update->PlaySound = probe_play_sound;
	context->update->DesktopResize = probe_desktop_resize;
	context->update->SetKeyboardIndicators = probe_keyboard_set_indicators;
	context->update->SetKeyboardImeStatus = probe_keyboard_set_ime_status;
	return TRUE;
}

static void probe_post_disconnect(freerdp* instance)
{
	probeContext* p = (probeContext*)instance->context;
	log_event(p, "PostDisconnect", NULL);

	PubSub_UnsubscribeChannelConnected(instance->context->pubSub, probe_on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub,
	                                      probe_on_channel_disconnected);
	gdi_free(instance);
}

static void probe_post_final_disconnect(freerdp* instance)
{
	probeContext* p = (probeContext*)instance->context;
	log_event(p, "PostFinalDisconnect", NULL);
}

/* ------------------------------------------------------------------------------------ */
/* RDP_CLIENT_ENTRY_POINTS callbacks                                                     */
/* ------------------------------------------------------------------------------------ */

static BOOL probe_client_new(freerdp* instance, rdpContext* context)
{
	if (!instance || !context)
		return FALSE;

	instance->PreConnect = probe_pre_connect;
	instance->PostConnect = probe_post_connect;
	instance->PostDisconnect = probe_post_disconnect;
	instance->PostFinalDisconnect = probe_post_final_disconnect;
	instance->LogonErrorInfo = probe_logon_error_info;
	instance->VerifyCertificateEx = probe_verify_certificate_ex;
	return TRUE;
}

static void probe_client_free(freerdp* instance, rdpContext* context)
{
	(void)instance;
	(void)context;
}

static int probe_client_start(rdpContext* context)
{
	(void)context;
	return 0;
}

static int probe_client_stop(rdpContext* context)
{
	(void)context;
	return 0;
}

static BOOL probe_global_init(void)
{
	return freerdp_handle_signals() == 0;
}

static void probe_global_uninit(void)
{
}

/* ------------------------------------------------------------------------------------ */
/* Main loop                                                                             */
/* ------------------------------------------------------------------------------------ */

static UINT probe_run_second_exec(probeContext* p)
{
	char progEsc[512] = { 0 };
	json_escape(p->cfg.second_exec, progEsc, sizeof(progEsc));

	log_event(p, "SecondExecBegin", "\"program\":\"%s\"", progEsc);

	RAIL_EXEC_ORDER exec = { 0 };
	exec.RemoteApplicationProgram = p->cfg.second_exec;

	UINT rc = p->rail->ClientExecute(p->rail, &exec);

	log_event(p, "SecondExecEnd", "\"program\":\"%s\",\"rc\":%u", progEsc, (unsigned)rc);
	return rc;
}

/* Mirrors client/Sample/tf_freerdp.c's tf_client_thread_proc(), plus a bounded wait so we
 * can poll for the --second-exec delay and --duration deadline from this same thread
 * without spinning up a timer thread. */
static DWORD probe_main_loop(freerdp* instance, probeContext* p)
{
	DWORD result = 0;

	BOOL rc = freerdp_connect(instance);
	if (!rc)
	{
		result = freerdp_get_last_error(instance->context);
		log_event(p, "ConnectFailed", "\"error\":%u,\"errorString\":\"%s\"", result,
		          freerdp_get_last_error_string(result));
		goto disconnect;
	}

	log_event(p, "ConnectSucceeded", NULL);
	p->connect_ms = get_mono_ms(p);

	while (!freerdp_shall_disconnect_context(instance->context))
	{
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		DWORD nCount = freerdp_get_event_handles(instance->context, handles, ARRAYSIZE(handles));
		if (nCount == 0)
		{
			log_event(p, "EventHandlesFailed", NULL);
			break;
		}

		DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 200);
		if (status == WAIT_FAILED)
		{
			log_event(p, "WaitFailed", NULL);
			break;
		}

		if (status != WAIT_TIMEOUT)
		{
			if (!freerdp_check_event_handles(instance->context))
			{
				if (freerdp_get_last_error(instance->context) == FREERDP_ERROR_SUCCESS)
					log_event(p, "CheckEventHandlesFailed", NULL);
				break;
			}
		}

		uint64_t now = get_mono_ms(p);
		uint64_t sinceConnect = now - p->connect_ms;

		if (p->cfg.second_exec[0] != '\0' && !p->second_exec_sent && p->rail &&
		    sinceConnect >= (uint64_t)p->cfg.second_delay * 1000)
		{
			probe_run_second_exec(p);
			p->second_exec_sent = true;
		}

		if (sinceConnect >= (uint64_t)p->cfg.duration * 1000)
		{
			log_event(p, "DurationElapsed", "\"sinceConnectMs\":%llu",
			          (unsigned long long)sinceConnect);
			break;
		}
	}

disconnect:
	freerdp_disconnect(instance);
	return result;
}

/* ------------------------------------------------------------------------------------ */
/* Summary                                                                               */
/* ------------------------------------------------------------------------------------ */

static void print_summary(probeContext* p)
{
	printf("{");
	printf("\"hidef\":%s,", p->cfg.no_hidef ? "false" : "true");

	printf("\"eventCounts\":{");
	for (size_t i = 0; i < p->event_counts_count; i++)
		printf("%s\"%s\":%llu", i ? "," : "", p->event_counts[i].name,
		       (unsigned long long)p->event_counts[i].count);
	printf("},");

	printf("\"windowsCreated\":[");
	for (size_t i = 0; i < p->created_count; i++)
		printf("%s%u", i ? "," : "", p->created_ids[i]);
	printf("],");

	printf("\"windowsDeleted\":[");
	for (size_t i = 0; i < p->deleted_count; i++)
		printf("%s%u", i ? "," : "", p->deleted_ids[i]);
	printf("],");

	printf("\"execResults\":[");
	for (size_t i = 0; i < p->exec_results_count; i++)
	{
		printf("%s{\"program\":\"%s\",\"execResult\":%u,\"rawResult\":%u}", i ? "," : "",
		       p->exec_results[i].program ? p->exec_results[i].program : "",
		       p->exec_results[i].execResult, p->exec_results[i].rawResult);
	}
	printf("],");

	printf("\"decode\":%s,", p->cfg.decode ? "true" : "false");
	printf("\"codecCounts\":[");
	for (size_t i = 0; i < p->codec_counts_count; i++)
	{
		printf("%s{\"codecId\":%u,\"name\":\"%s\",\"count\":%llu}", i ? "," : "",
		       p->codec_counts[i].codecId, codec_id_name(p->codec_counts[i].codecId),
		       (unsigned long long)p->codec_counts[i].count);
	}
	printf("]");

	printf("}\n");
	fflush(stdout);
}

/* ------------------------------------------------------------------------------------ */
/* main                                                                                  */
/* ------------------------------------------------------------------------------------ */

int main(int argc, char** argv)
{
	probeConfig cfg;
	if (!parse_args(argc, argv, &cfg))
		return 2;

	RDP_CLIENT_ENTRY_POINTS entryPoints = { 0 };
	entryPoints.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
	entryPoints.GlobalInit = probe_global_init;
	entryPoints.GlobalUninit = probe_global_uninit;
	entryPoints.ContextSize = sizeof(probeContext);
	entryPoints.ClientNew = probe_client_new;
	entryPoints.ClientFree = probe_client_free;
	entryPoints.ClientStart = probe_client_start;
	entryPoints.ClientStop = probe_client_stop;

	rdpContext* context = freerdp_client_context_new(&entryPoints);
	if (!context)
	{
		fprintf(stderr, "freerdp_client_context_new failed\n");
		return 1;
	}

	probeContext* p = (probeContext*)context;
	g_probe = p;
	p->cfg = cfg;
	pthread_mutex_init(&p->log_lock, NULL);
	clock_gettime(CLOCK_MONOTONIC, &p->t0);

	p->out = fopen(p->cfg.out_path, "w");
	if (!p->out)
	{
		fprintf(stderr, "failed to open --out file '%s': %s\n", p->cfg.out_path,
		        strerror(errno));
		freerdp_client_context_free(context);
		return 1;
	}

	rdpSettings* settings = context->settings;
	if (!freerdp_settings_set_string(settings, FreeRDP_ServerHostname, p->cfg.host) ||
	    !freerdp_settings_set_string(settings, FreeRDP_Username, p->cfg.user) ||
	    !freerdp_settings_set_string(settings, FreeRDP_Password, p->cfg.pass))
	{
		fprintf(stderr, "failed to apply host/user/pass settings\n");
		fclose(p->out);
		freerdp_client_context_free(context);
		return 1;
	}

	int rc = 0;
	if (freerdp_client_start(context) != 0)
	{
		fprintf(stderr, "freerdp_client_start failed\n");
		rc = 1;
	}
	else
	{
		DWORD res = probe_main_loop(context->instance, p);
		rc = (int)res;
		if (freerdp_client_stop(context) != 0)
			rc = 1;
	}

	print_summary(p);

	if (p->out)
		fclose(p->out);
	pthread_mutex_destroy(&p->log_lock);
	free(p->created_ids);
	free(p->deleted_ids);
	for (size_t i = 0; i < p->exec_results_count; i++)
		free(p->exec_results[i].program);
	free(p->exec_results);
	free(p->event_counts);
	free(p->codec_counts);

	freerdp_client_context_free(context);
	return rc;
}
