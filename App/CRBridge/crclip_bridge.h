/*
 * crclip_bridge: the cliprdr channel of FreeRDP wired to crdpq (adr/0026, lane L3). Pure C, no
 * AppKit, no Foundation, no Objective-C: CRSession.mm calls it from the three places a channel
 * meets the bridge (the pre-connect step, the channel-connected / -disconnected callbacks on
 * T_rdp, the outbound drain on T_rdp), and Tools/cliprdr-check drives the very same file against
 * FreeRDP's built-in cliprdr channel with no connection at all.
 *
 * The bridge moves things and decides nothing (adr/0026 S0, H-10). Every clipboard decision --
 * announce or not, request or not, answer how, keep or drop what arrived -- is made on T_main by
 * the Swift state machine; this file only turns the channel's server callbacks into the four
 * CRDPQ_EVENT_CLIP_* events and the three CRDPQ_CMD_CLIP_* commands into the channel's Client*
 * sends. What it keeps per channel connection is protocol bookkeeping no other thread reads: the
 * store generation it captured, the response number it hands out as a store key, and what the
 * server's capability PDU said about long format names (which decides how a server Format List is
 * read for the exclusion flag: by name with long names, in crdpq.h's conservative direction
 * without them -- see crdpq.h CRDPQ_CLIP_FLAG_REMOTE_EXCLUDED).
 *
 * Threads (adr/0005 addendum):
 *   - crclip_apply_mode, crclip_bridge_init: T_rdp, in the pre-connect step (the offline tests
 *     call them on a thread of their own, on a settings object of their own).
 *   - crclip_bridge_attach / crclip_bridge_detach: T_rdp, in the PubSub channel-connected /
 *     -disconnected callbacks. FreeRDP creates the channel's message thread T_clip before the
 *     connected callback and joins it before the disconnected one, so neither races T_clip.
 *   - the server callbacks attach installs: T_clip only.
 *   - crclip_outbound_dispatch: T_rdp only, from the outbound drain.
 *   - crclip_store_for_limit and the functions under "T_main" below: T_main (crclip_store_for_limit
 *     only while no thread of any connection exists).
 *   - the counters: any thread (atomic).
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include <freerdp/settings.h>
#include <freerdp/client/cliprdr.h>

#include "crdpq.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The five clipboard modes. The numbers are CRSession.h's CRClipboardMode and MacdowsCore's
 * ClipboardMode raw values; MacdowsAppTests ties the three together. 0 is the default, and the
 * only mode under which the connect path writes nothing and installs nothing. */
typedef enum {
    CRCLIP_MODE_UNMANAGED = 0,
    CRCLIP_MODE_OFF = 1,
    CRCLIP_MODE_BIDIRECTIONAL = 2,
    CRCLIP_MODE_REMOTE_TO_LOCAL_ONLY = 3,
    CRCLIP_MODE_LOCAL_TO_REMOTE_ONLY = 4,
} crclip_mode_t;

/* What the bridge counts. Cumulative for the counter table's lifetime (one CRSession). Values
 * are fixed; new counters go above CRCLIP_COUNTER_COUNT, which stays last. CRSession.h mirrors
 * them as CRClipboardCounter and CRSession.mm asserts the numbers equal. */
typedef enum {
    /* T_clip */
    CRCLIP_COUNTER_CAPABILITIES_SEND_FAILED = 0,
    CRCLIP_COUNTER_FORMAT_LIST_RESPONSE_SEND_FAILED = 1,
    CRCLIP_COUNTER_EVENT_POST_FAILED = 2,
    CRCLIP_COUNTER_REMOTE_DATA_NOT_STORED = 3,
    CRCLIP_COUNTER_REMOTE_DATA_FLAGS_UNEXPECTED = 4,
    /* Server Format Lists that offer CF_UNICODETEXT without long format names negotiated, each
     * judged excluded in crdpq.h's conservative direction (crclip_format_list_flags). */
    CRCLIP_COUNTER_FORMAT_LIST_WITHOUT_LONG_NAMES = 5,
    CRCLIP_COUNTER_CALLBACK_ARGUMENT_MISSING = 6,
    /* T_rdp */
    CRCLIP_COUNTER_COMMAND_DROPPED_NO_CHANNEL = 7,
    CRCLIP_COUNTER_COMMAND_DROPPED_STALE = 8,
    CRCLIP_COUNTER_RESPONSE_WITHHELD_BY_MODE = 9,
    CRCLIP_COUNTER_COMMAND_SEND_FAILED = 10,
    CRCLIP_COUNTER_RESPONSE_BYTES_UNAVAILABLE = 11,
    /* T_main */
    CRCLIP_COUNTER_REMOTE_DATA_UNCONSUMED = 12,
    CRCLIP_COUNTER_RESPOND_STORED_AS_FAILURE = 13,
    CRCLIP_COUNTER_COMMAND_POST_FAILED = 14,
    /* The three drops that stall Windows -> Mac (crdpq.h, "THREE DROPS THAT STALL WINDOWS -> MAC"),
     * each on its own; every one is also in the general counter of its thread above. */
    CRCLIP_COUNTER_STALL_REMOTE_DATA_POST_FAILED = 15, /* T_clip: a REMOTE_DATA event not posted */
    CRCLIP_COUNTER_STALL_REQUEST_POST_FAILED = 16,     /* T_main: a REQUEST command not posted */
    CRCLIP_COUNTER_STALL_REQUEST_DROPPED = 17,         /* T_rdp: a REQUEST command dropped, no channel */
    CRCLIP_COUNTER_COUNT = 18,
} crclip_counter_t;

typedef struct crclip_counters crclip_counters_t;

/* NULL only on allocation failure; every function below accepts a NULL table (counts nothing). */
crclip_counters_t* crclip_counters_create(void);
void crclip_counters_destroy(crclip_counters_t* counters);
/* Adds one and returns the new value (0 for a NULL table or an unknown counter). */
uint64_t crclip_counters_bump(crclip_counters_t* counters, crclip_counter_t counter);
uint64_t crclip_counters_get(const crclip_counters_t* counters, crclip_counter_t counter);

/* The ClipboardFeatureMask value a mode writes: only the two plain direction bits, never a FILES
 * bit (adr/0026 H-7). 0 for Off, for Unmanaged (which writes nothing) and for a value that is
 * not a mode. */
UINT32 crclip_mode_feature_mask(uint32_t mode);
/* Whether the channel is loaded and the bridge installs its callbacks for `mode`: exactly the
 * three modes with a direction. */
bool crclip_mode_installs_callbacks(uint32_t mode);
/* Whether `mode` lets Mac text go to Windows -- the condition in front of the one call to the
 * channel's data-response function (adr/0026 H-2). */
bool crclip_mode_allows_local_to_remote(uint32_t mode);

/* The connect path's clipboard step: a function of the mode and a settings object only, called
 * once from the pre-connect step, before the channel subscriptions. Unmanaged returns TRUE at
 * once and writes nothing. Every other value writes ClipboardFeatureMask (the mode's mask) and
 * RedirectClipboard (TRUE for the three directed modes); Off, and any value that is not a mode
 * (treated as Off, with a WARN), also removes every `cliprdr` entry already in the static
 * channel collection, because FreeRDP loads an entry it finds there whatever RedirectClipboard
 * says. Any write or removal that fails returns FALSE: the connection is refused rather than
 * left with a data flow wider than the mode. */
BOOL crclip_apply_mode(rdpSettings* settings, uint32_t mode);

/* One connection's bridge state. Embedded in the caller's per-connection context; zero-filled is
 * a valid Unmanaged bridge that never attaches. */
typedef struct {
    /* Set by crclip_bridge_init, read-only afterwards. */
    uint32_t mode;
    crdpq_control_t* control;
    crdpq_clip_store_t* store;
    crclip_counters_t* counters;
    /* T_rdp only: the channel the bridge is attached to, or NULL. */
    CliprdrClientContext* channel;
    /* Written by attach (T_rdp) before T_clip sees its first message; read on T_clip and T_rdp. */
    uint32_t storeGeneration;
    /* T_clip only (reset by attach): the response number that keys the next stored response, and
     * what the server's capability PDU said about long format names. */
    uint32_t nextResponseNumber;
    bool serverCapabilitiesSeen;
    bool serverOffersLongNames;
    bool longNamesNegotiated;
} crclip_bridge_t;

/* Fills `bridge` for one connection. For a mode that installs callbacks, returns false (with one
 * ERR of numbers) when the control lane, the store or the counter table is missing: the
 * connection must not go on with a channel nobody can answer. */
bool crclip_bridge_init(crclip_bridge_t* bridge, uint32_t mode, crdpq_control_t* control,
                        crdpq_clip_store_t* store, crclip_counters_t* counters);

/* T_rdp, channel connected. Does nothing but log one ERR line (the mode number only) and returns
 * false without a bridge, without a channel, or unless the mode installs callbacks. Otherwise
 * clears the store -- whatever an earlier channel instance left there can never be
 * taken under the new generation -- captures that generation, resets the T_clip bookkeeping,
 * points the channel's `custom` at the bridge and installs the five server callbacks. */
bool crclip_bridge_attach(crclip_bridge_t* bridge, CliprdrClientContext* channel);

/* T_rdp, channel disconnected (T_clip has been joined). Forgets the channel, clears its
 * `custom` if it is ours, and clears the store so nothing of this instance outlives it. Safe to
 * call twice. */
void crclip_bridge_detach(crclip_bridge_t* bridge, CliprdrClientContext* channel);

/* T_rdp, outbound drain. Returns false, touching nothing, for a command that is not one of the
 * three clipboard kinds -- the caller then goes on to its RAIL path. Returns true for a clipboard
 * command, whatever became of it: sent, or dropped and counted (no channel; an answer for an
 * earlier channel instance; an answer under a mode without Mac -> Windows), in which case an
 * answer's store entry is removed too. With a NULL `bridge` a clipboard command is taken (true)
 * and nothing else happens: nothing sent, counted, logged or removed (CRSession.mm always passes
 * its connection's bridge). Clipboard commands never depend on RAIL (adr/0026 H-3). */
bool crclip_outbound_dispatch(crclip_bridge_t* bridge, const CrdpCommand* command);

/* The two facts T1 takes from a server Format List (crdpq.h CRDPQ_CLIP_FLAG_*). With
 * `longNamesNegotiated` the exclusion flag is set when the list names one of the four exclusion
 * formats, compared by full name with ASCII case folded (Windows compares registered format names
 * without regard to case; same length, nothing folded beyond ASCII); the names never leave this
 * function. Without it no name is
 * compared (short names arrive cut, or whole, so a comparison proves nothing) and crdpq.h's
 * conservative direction applies: a list that names CF_UNICODETEXT gets the exclusion flag too;
 * a list that does not gets neither. */
uint32_t crclip_format_list_flags(const CLIPRDR_FORMAT_LIST* formatList, bool longNamesNegotiated);

/* T_main, while no thread of any connection exists (CRSession's -start): brings `*store` in line
 * with `limit`, the clipboard byte limit, and returns the limit the store now has (0: no store).
 * `storeLimit` is what an earlier call returned. 0, or a limit whose total (twice it) does not
 * fit a size_t, destroys any store and leaves none; an unchanged limit keeps the store; any other
 * limit replaces it with a new one (block limit `limit`, total twice it). A failed creation leaves
 * no store. A directed mode without a store refuses the connection (crclip_bridge_init). */
size_t crclip_store_for_limit(crdpq_clip_store_t** store, size_t storeLimit, size_t limit);

/* ---- T_main: what the session's owner thread does with the lanes and the store. CRSession.mm's
 * clipboard methods and its drain only forward to these; Tools/cliprdr-check drives them as its
 * T_main. None of them decides anything about the clipboard. ---- */

/* Posts one clipboard command; counts a refusal (no lane, sealed, full) -- for a REQUEST also as
 * the stalling drop it is. */
bool crclip_post_command(crdpq_outbound_t* outbound, crclip_counters_t* counters, crdpq_command_type_t type,
                         const crdpq_clip_ref_t* ref);
/* ANNOUNCE: `formatId` CF_UNICODETEXT (a list naming plain text) or CRDPQ_CLIP_NO_FORMAT (an empty
 * list); any other value is refused before anything is posted or counted (T1 is plain text). */
bool crclip_announce(crdpq_outbound_t* outbound, crclip_counters_t* counters, uint32_t formatId);
/* REQUEST: `formatId` must be CF_UNICODETEXT; anything else is refused the same way. */
bool crclip_request(crdpq_outbound_t* outbound, crclip_counters_t* counters, uint32_t formatId);

typedef enum {
    /* One RESPOND carrying the bytes (stored under `key`) was posted. */
    CRCLIP_RESPOND_POSTED = 0,
    /* The bytes could not be stored (over the limit, no room): one failure RESPOND was posted
     * instead, so the server still gets exactly one answer. Counted. */
    CRCLIP_RESPOND_POSTED_AS_FAILURE = 1,
    /* The store refused the request's generation: its channel instance is gone, nobody to answer.
     * Nothing posted. */
    CRCLIP_RESPOND_STALE = 2,
    /* The post was refused (counted); a stored block was discarded again. */
    CRCLIP_RESPOND_NOT_POSTED = 3,
} crclip_respond_result_t;

/* The one answer to a DATA_REQUEST event `request`: `withBytes` false is a failure answer; true
 * stores `bytes[0..length)` (a copy) under `key` -- unique among T_main's live answers -- and
 * posts it. */
crclip_respond_result_t crclip_respond(crdpq_outbound_t* outbound, crdpq_clip_store_t* store,
                                       crclip_counters_t* counters, uint32_t key, const crdpq_clip_ref_t* request,
                                       bool withBytes, const uint8_t* bytes, size_t length);

/* Hands the bytes of an OK REMOTE_DATA event `event` to `reader` (valid during the call only),
 * then wipes and frees the copy. The entry leaves the store whatever happens (a failed take is
 * followed by a discard). False, without calling `reader`, for a non-OK status or a failed take. */
typedef void (*crclip_reader_fn)(const uint8_t* bytes, size_t length, void* context);
bool crclip_take_remote(crdpq_clip_store_t* store, const crdpq_clip_ref_t* event, crclip_reader_fn reader,
                        void* context);
/* Removes the bytes of an OK REMOTE_DATA event without reading them. */
void crclip_discard_remote(crdpq_clip_store_t* store, const crdpq_clip_ref_t* event);
/* The drain's fallback when no consumer settled an OK REMOTE_DATA event: discard and count. */
void crclip_settle_unconsumed(crdpq_clip_store_t* store, crclip_counters_t* counters, const crdpq_clip_ref_t* event);

#ifdef __cplusplus
}
#endif
