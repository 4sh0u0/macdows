#include "crdpq.h"

#include <os/lock.h>
#include <stdlib.h>

#define CRDPQ_FRAMES_INITIAL_CAPACITY 64 /* must stay a power of 2 (mask-based probing) */
#define CRDPQ_FRAMES_MAX_LOAD_NUM 7      /* grow when occupied_count * 10 > capacity * 7 */
#define CRDPQ_FRAMES_MAX_LOAD_DEN 10

typedef struct {
    uint32_t surfaceId;
    crdpq_generation_t generation;
    bool occupied; /* this slot has been used at least once (a surfaceId "exists" here) */
    bool dirty;    /* unconsumed publish pending */
} crdpq_frame_slot_t;

struct crdpq_frames {
    os_unfair_lock lock;
    crdpq_frame_slot_t* slots;
    size_t capacity; /* power of 2 */
    size_t occupied_count;
    size_t dropped_count; /* H1: publishes rejected because the table was completely full
                            * and growth failed too — see crdpq_frame_publish */
    bool pending_notification;
    crdpq_frames_schedule_drain_fn schedule_drain;
    void* schedule_drain_ctx;
};

/* Open addressing, linear probing. surfaceId values observed in practice are small and
 * dense (0, 1, 2, ...), so `surfaceId & (capacity - 1)` is already close to a perfect
 * hash for the common case; linear probing handles the general (sparse/adversarial)
 * case correctly regardless. Must be called with the lock held.
 *
 * Returns (size_t)-1 if `capacity` slots were probed and none is empty or a match for
 * `surfaceId` — i.e. the table is completely full of *other* entries. Under normal
 * operation this can't happen: crdpq_frame_publish grows the table well before load
 * factor reaches 1.0. It DOES happen (confirmed via a fault-injection harness that denies
 * every growth allocation past the initial capacity — H1 in the W3 review) if a prior
 * growth attempt already failed under memory pressure and enough distinct new surfaceIds
 * keep arriving to fill out whatever capacity is left. Every caller of this function must
 * check for (size_t)-1 before touching `slots[idx]` — indexing it unconditionally was
 * exactly H1's heap-out-of-bounds bug (ASan-confirmed). */
static size_t crdpq_frames_find_slot_locked(crdpq_frame_slot_t* slots, size_t capacity, uint32_t surfaceId) {
    size_t mask = capacity - 1;
    size_t idx = (size_t)surfaceId & mask;
    for (size_t probes = 0; probes < capacity; probes++) {
        if (!slots[idx].occupied || slots[idx].surfaceId == surfaceId) {
            return idx;
        }
        idx = (idx + 1) & mask;
    }
    return (size_t)-1;
}

/* Must be called with the lock held. */
static bool crdpq_frames_grow_locked(crdpq_frames_t* f) {
    size_t new_capacity = f->capacity * 2;
    crdpq_frame_slot_t* new_slots = calloc(new_capacity, sizeof(crdpq_frame_slot_t));
    if (!new_slots) return false;

    for (size_t i = 0; i < f->capacity; i++) {
        if (!f->slots[i].occupied) continue;
        size_t idx = crdpq_frames_find_slot_locked(new_slots, new_capacity, f->slots[i].surfaceId);
        new_slots[idx] = f->slots[i];
    }

    free(f->slots);
    f->slots = new_slots;
    f->capacity = new_capacity;
    return true;
}

crdpq_frames_t* crdpq_frames_create(crdpq_frames_schedule_drain_fn schedule_drain, void* schedule_drain_ctx) {
    crdpq_frames_t* f = calloc(1, sizeof(crdpq_frames_t));
    if (!f) return NULL;
    f->lock = OS_UNFAIR_LOCK_INIT;
    f->slots = calloc(CRDPQ_FRAMES_INITIAL_CAPACITY, sizeof(crdpq_frame_slot_t));
    if (!f->slots) {
        free(f);
        return NULL;
    }
    f->capacity = CRDPQ_FRAMES_INITIAL_CAPACITY;
    f->schedule_drain = schedule_drain;
    f->schedule_drain_ctx = schedule_drain_ctx;
    return f;
}

void crdpq_frames_destroy(crdpq_frames_t* f) {
    if (!f) return;
    free(f->slots);
    free(f);
}

bool crdpq_frame_publish(crdpq_frames_t* f, uint32_t surfaceId, crdpq_generation_t generation) {
    bool should_schedule = false;
    bool accepted = true;

    os_unfair_lock_lock(&f->lock);

    size_t idx = crdpq_frames_find_slot_locked(f->slots, f->capacity, surfaceId);
    /* idx == (size_t)-1 means the table is completely full of *other* entries — see
     * crdpq_frames_find_slot_locked's doc comment. An already-present surfaceId is never
     * affected by this: linear probing always locates its own existing slot regardless of
     * load factor, so `is_new` is always true whenever idx comes back as -1. */
    bool is_new = (idx == (size_t)-1) || !f->slots[idx].occupied;
    bool must_grow = is_new &&
        (idx == (size_t)-1 ||
         (f->occupied_count + 1) * CRDPQ_FRAMES_MAX_LOAD_DEN > f->capacity * CRDPQ_FRAMES_MAX_LOAD_NUM);

    if (must_grow && crdpq_frames_grow_locked(f)) {
        idx = crdpq_frames_find_slot_locked(f->slots, f->capacity, surfaceId);
        /* A successful grow always leaves capacity > occupied_count, so this can never
         * come back as (size_t)-1. */
    }
    /* If must_grow was true but the grow failed: when idx was already valid going in (the
     * proactive, below-100%-load case — growth was attempted only to keep probe lengths
     * short, not because there was nowhere else to put this entry), fall through and reuse
     * the still-valid, just more crowded existing table — last-writer-wins semantics don't
     * require the grow to succeed for correctness, only for probe-length performance. When
     * idx was (size_t)-1 going in (the table-is-completely-full case), there genuinely is
     * nowhere to place a new surfaceId; that's handled below by checking idx again rather
     * than indexing it blindly (H1's fix). */

    if (idx == (size_t)-1) {
        accepted = false;
        f->dropped_count++;
    } else {
        /* Last-writer-wins: overwrite generation unconditionally, whether or not this slot
         * was already dirty from a not-yet-consumed prior publish. */
        f->slots[idx].surfaceId = surfaceId;
        f->slots[idx].generation = generation;
        f->slots[idx].dirty = true;
        if (is_new) {
            f->slots[idx].occupied = true;
            f->occupied_count++;
        }

        if (!f->pending_notification) {
            f->pending_notification = true;
            should_schedule = true;
        }
    }

    os_unfair_lock_unlock(&f->lock);

    if (should_schedule && f->schedule_drain) {
        f->schedule_drain(f->schedule_drain_ctx);
    }

    return accepted;
}

/* Returns the number of slots actually delivered to `visitor` — NOT the number of slots
 * that were dirty going in. Under the (rare, memory-pressure-only) malloc failure path
 * below, this can be 0 even though real dirty state still exists and was intentionally
 * left untouched (see the comment inline). A 0 return therefore means "nothing was
 * delivered this call", not "nothing is pending" — callers that care about the
 * distinction should treat a 0 alongside `crdpq_frames_dropped_count` staying flat as
 * "genuinely empty" vs. a transient allocation failure showing up some other way (e.g. a
 * future consume call succeeding and delivering the same slots). L1 in the W3 review. */
size_t crdpq_frame_consume(crdpq_frames_t* f, crdpq_frame_visitor_fn visitor, void* vctx) {
    os_unfair_lock_lock(&f->lock);

    /* Upper bound on dirty slots is occupied_count; snapshot into a temp array under
     * lock so the visitor loop (which may run arbitrary, possibly slow, caller code)
     * never runs while holding this lock. */
    size_t cap = f->occupied_count;
    uint32_t* ids = cap ? malloc(cap * sizeof(uint32_t)) : NULL;
    crdpq_generation_t* gens = cap ? malloc(cap * sizeof(crdpq_generation_t)) : NULL;
    size_t n = 0;
    bool snapshot_ok = (cap == 0 || (ids && gens));

    if (snapshot_ok) {
        for (size_t i = 0; i < f->capacity; i++) {
            if (f->slots[i].occupied && f->slots[i].dirty) {
                ids[n] = f->slots[i].surfaceId;
                gens[n] = f->slots[i].generation;
                n++;
                f->slots[i].dirty = false;
            }
        }
        f->pending_notification = false;
    }
    /* L1: on malloc failure (cap != 0 but ids/gens allocation failed), do NOT clear
     * pending_notification. Nothing was actually delivered — every slot is still dirty,
     * exactly as it was before this call — so the flag would be lying if cleared here.
     * Left armed (true), it accurately reflects "there is still real unconsumed dirty
     * data"; a caller that retries crdpq_frame_consume later (its own periodic poll, not
     * necessarily another schedule_drain callback, since a fresh publish() only
     * re-schedules when pending_notification was false) will pick these slots up then. */

    os_unfair_lock_unlock(&f->lock);

    if (visitor) {
        for (size_t i = 0; i < n; i++) {
            visitor(ids[i], gens[i], vctx);
        }
    }

    free(ids);
    free(gens);
    return n;
}

crdpq_generation_t crdpq_frame_peek(const crdpq_frames_t* f, uint32_t surfaceId, bool* out_found) {
    crdpq_frames_t* fw = (crdpq_frames_t*)f;
    os_unfair_lock_lock(&fw->lock);
    size_t idx = crdpq_frames_find_slot_locked(fw->slots, fw->capacity, surfaceId);
    /* idx == (size_t)-1 (table completely full, surfaceId not among the entries already
     * there) is exactly "not found" from a peek's point of view — H1's fix. */
    bool found = (idx != (size_t)-1) && fw->slots[idx].occupied;
    crdpq_generation_t gen = found ? fw->slots[idx].generation : 0;
    os_unfair_lock_unlock(&fw->lock);
    if (out_found) *out_found = found;
    return gen;
}

size_t crdpq_frames_dropped_count(const crdpq_frames_t* f) {
    crdpq_frames_t* fw = (crdpq_frames_t*)f;
    os_unfair_lock_lock(&fw->lock);
    size_t dropped = fw->dropped_count;
    os_unfair_lock_unlock(&fw->lock);
    return dropped;
}
