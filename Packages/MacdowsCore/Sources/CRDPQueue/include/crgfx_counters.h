#ifndef CRGFX_COUNTERS_H
#define CRGFX_COUNTERS_H

/*
 * crgfx_counters: per-surfaceId GFX frame counters for ONE session. MEASUREMENT ONLY --
 * nothing in the render path reads these, no code branches on them, and removing this
 * whole unit would change no pixel.
 *
 * THE QUESTION IT EXISTS TO ANSWER (ADR-0018 §5.2 ②). A RAIL window can be re-mapped onto a
 * NEW GFX surface mid-session (a resize allocates a bigger one). The 2026-09-15 About case
 * showed a window whose later surfaces were mapped but never presented, and the two possible
 * causes are indistinguishable from the client's own render state alone:
 *   4a -- the server DID draw into the new surface and something between the wire and the
 *         NSWindow dropped the frame, or
 *   4b -- the server only mapped the surface and never drew into it.
 * The discriminator is upstream of every client decision: how often the gdi pipeline handed
 * that surface to the bridge at all (`updates`), how often it arrived carrying a non-empty
 * invalid region (`dirty`), how often the bridge published it onward (`publishes`), and how
 * many of those publishes the drain's generation filter then discarded (`stale`).
 * 4b looks like `updates > 0, dirty = 0`; 4a looks like `dirty > 0` with the registry-side
 * counters showing where the frame was lost afterwards.
 *
 * WHY A SEPARATE TABLE AND NOT crdpq_frames. crdpq_frames is last-writer-wins STATE (adr/0005
 * §1): a publish overwrites the previous one, so it cannot say how many times anything
 * happened. These are monotonic event counts with no consumer and nothing to consume -- a
 * different data structure answering a different question, kept out of crdpq.h's own
 * three-primitive contract for that reason.
 *
 * LIFETIME: one table per CRSession instance, created with the session and never reset --
 * not by a reconnect, not by a disconnect. Same "cumulative for this instance's whole
 * lifetime" semantics as the session's other diagnostic counters, and for the same reason: a
 * counter that resets cannot be read after the run that produced it.
 *
 * FIXED CAPACITY, ON PURPOSE (`CRGFX_COUNTERS_SLOTS`). The write side runs on T_dvc inside
 * FreeRDP's mux critical section, on the per-frame path, where adr/0005 §2 forbids allocation;
 * a growing table would allocate there. A session that exceeds the capacity simply stops
 * tracking NEW surface ids -- the ones already holding a slot keep counting correctly, and a
 * read for an untracked id answers "not tracked" rather than 0, so an overflow can never be
 * misread as "the server drew nothing". Observed sessions use a handful of surfaces (the
 * 2026-09-15 About window's whole life: three), so the ceiling is roughly an order of
 * magnitude above anything measured.
 *
 * THREADING: every function below takes the table's own `os_unfair_lock`, so the write side
 * (T_dvc) and the read side (T_main, the diagnostics harness) need no external
 * synchronization. The lock is uncontended in practice -- the same thread that already holds
 * FreeRDP's mux is the only writer -- and taking one more uncontended lock on that path is
 * exactly what `crsurface_table_write` already does one call earlier in the same hook.
 * Allocation-free after `crgfx_counters_create`.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** How many distinct surface ids one table can track (see the file comment's capacity
 *  rationale). Exposed so a test can pin the overflow behaviour against the real bound
 *  rather than a guessed one. */
#define CRGFX_COUNTERS_SLOTS 64

typedef struct crgfx_counters crgfx_counters_t;

/** Creates an empty table, or NULL if the allocation fails (a caller that gets NULL loses
 *  the diagnostic and nothing else -- every function below tolerates a NULL table). */
crgfx_counters_t* crgfx_counters_create(void);

void crgfx_counters_destroy(crgfx_counters_t* counters);

/** Records one entry into the frame hook for `surfaceId`, with `dirty` saying whether the
 *  surface arrived carrying a non-empty invalid region.
 *
 *  The two counters are bumped together, under one lock, so `dirty <= updates` holds by
 *  construction: "the server drew into this surface at least once" is then a property of the
 *  pair, never an artefact of two counters observed a moment apart. Claims a free slot for a
 *  surface id seen for the first time; a call that finds the table full is dropped, leaving
 *  that id untracked (`crgfx_counters_read` returns false for it) rather than being
 *  attributed to somebody else's slot. */
void crgfx_counters_note_update(crgfx_counters_t* counters, uint32_t surfaceId, bool dirty);

/** Records that the bridge published a frame for `surfaceId` onward to the consumer (the
 *  frame lane write plus the readiness doorbell -- see CRSession.mm's GFX hook).
 *
 *  Counted separately from `updates` rather than assumed equal to it: the two are the entry
 *  and the exit of the same hook, and a session where they diverge is a frame the bridge
 *  accepted and never forwarded -- the one client-side loss that would otherwise be invisible
 *  to both the server's own logs and the registry's counters. Does NOT claim a slot for an
 *  unseen surface id: a publish without a preceding update is impossible on the real path, so
 *  a slot claimed here would be a measurement of a bug in this file rather than of the
 *  session. */
void crgfx_counters_note_publish(crgfx_counters_t* counters, uint32_t surfaceId);

/** Records that a published frame-readiness event for `surfaceId` was thrown away by the
 *  drain's generation filter (adr/0005 §4) before any consumer could act on it.
 *
 *  THE GAP THIS CLOSES (gate r1 I-1). Between `publishes` and anything the registry can count
 *  there is one more exit: a reconnect bumps the session generation, and every event still in
 *  the queue from the older connection is discarded at the drain entry point. Without this
 *  counter a run reads `publishes=N` with every later counter at 0 and no way to tell a
 *  discarded frame from one that was never delivered -- so the row's arithmetic
 *  (`publishes = stale + ready + still-in-flight`) would have an unnamed term in it. Same
 *  no-slot-claiming rule as `crgfx_counters_note_publish`: the event this counts was posted by
 *  the same hook that already counted an update for that surface. */
void crgfx_counters_note_stale(crgfx_counters_t* counters, uint32_t surfaceId);

/** Reads the four counters for `surfaceId`. Returns false -- leaving the out-parameters
 *  untouched -- when this table has never seen that surface id, whether because nothing ever
 *  drew into it or because the table was already full when it first appeared. The caller is
 *  expected to report that "not tracked" verdict verbatim; collapsing it into zeros would
 *  turn "no measurement" into the measurement 4b consists of. Every out-parameter is
 *  optional. Safe from any thread. */
bool crgfx_counters_read(crgfx_counters_t* counters, uint32_t surfaceId, uint64_t* out_updates,
                         uint64_t* out_dirty, uint64_t* out_publishes, uint64_t* out_stale);

#ifdef __cplusplus
}
#endif

#endif /* CRGFX_COUNTERS_H */
