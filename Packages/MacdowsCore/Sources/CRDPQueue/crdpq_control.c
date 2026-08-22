#include "crdpq.h"

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>

#define CRDPQ_CONTROL_INITIAL_CAPACITY 256
/* M4 in the W3 review: the back buffer used to grow unbounded under realloc. Cap it —
 * default 65536 events, overridable via crdpq_control_create_with_max_capacity — and
 * reject-and-count (crdpq_dropped_count) once a buffer at the cap is also full, matching
 * adr/0005 §7's "dropped-frame count alert" mitigation pattern already used on the frame
 * lane, extended here to this lane. */
#define CRDPQ_CONTROL_DEFAULT_MAX_CAPACITY 65536u

/*
 * Two independently-capacitied buffers, indexed by `back_idx` (0 or 1) — NOT a pair of
 * buffers forced to the same capacity. This is deliberate, not an oversight: growth
 * (realloc) only ever touches whichever buffer is *currently* `back_idx` (the one
 * producers are actively appending to). After a drain() swap, the buffer that was just
 * grown becomes `front`; a subsequent drain()'s visitor loop holds a *local* snapshot of
 * that pointer/count taken under lock, and by the single-consumer contract (see crdpq.h)
 * no second drain() call can run concurrently to swap it back into `back_idx` and
 * potentially realloc/move it out from under that local snapshot while the first drain()
 * is still iterating. Symmetric-capacity buffers would not have this safety property for
 * free — realloc'ing "the other" buffer while a from-before-swap local pointer to it is
 * still in use elsewhere is exactly the bug this layout avoids.
 */
struct crdpq_control {
    os_unfair_lock lock;
    CrdpEvent* buf[2];
    size_t capacity[2];
    size_t count[2];
    int back_idx;
    bool drain_scheduled;
    size_t high_water_mark;
    size_t max_capacity;   /* M4: ceiling on capacity[b]; growth stops here */
    size_t dropped_count;  /* M4: posts rejected for being at-cap-and-full, or OOM */
    _Atomic crdpq_generation_t generation;
    _Atomic bool sealed;
    crdpq_schedule_drain_fn schedule_drain;
    void* schedule_drain_ctx;
};

crdpq_control_t* crdpq_control_create_with_max_capacity(crdpq_schedule_drain_fn schedule_drain, void* schedule_drain_ctx, size_t max_capacity) {
    crdpq_control_t* q = calloc(1, sizeof(crdpq_control_t));
    if (!q) return NULL;
    q->lock = OS_UNFAIR_LOCK_INIT;
    q->buf[0] = malloc(CRDPQ_CONTROL_INITIAL_CAPACITY * sizeof(CrdpEvent));
    q->buf[1] = malloc(CRDPQ_CONTROL_INITIAL_CAPACITY * sizeof(CrdpEvent));
    if (!q->buf[0] || !q->buf[1]) {
        free(q->buf[0]);
        free(q->buf[1]);
        free(q);
        return NULL;
    }
    q->capacity[0] = CRDPQ_CONTROL_INITIAL_CAPACITY;
    q->capacity[1] = CRDPQ_CONTROL_INITIAL_CAPACITY;
    q->back_idx = 0;
    /* A ceiling below the initial capacity would be nonsensical (the buffer is always at
     * least CRDPQ_CONTROL_INITIAL_CAPACITY already, before any growth is even attempted) —
     * clamp up to the floor rather than accept a config that can never actually bind. */
    q->max_capacity = max_capacity > CRDPQ_CONTROL_INITIAL_CAPACITY ? max_capacity : CRDPQ_CONTROL_INITIAL_CAPACITY;
    atomic_init(&q->generation, 0u);
    atomic_init(&q->sealed, false);
    q->schedule_drain = schedule_drain;
    q->schedule_drain_ctx = schedule_drain_ctx;
    return q;
}

crdpq_control_t* crdpq_control_create(crdpq_schedule_drain_fn schedule_drain, void* schedule_drain_ctx) {
    return crdpq_control_create_with_max_capacity(schedule_drain, schedule_drain_ctx, CRDPQ_CONTROL_DEFAULT_MAX_CAPACITY);
}

void crdpq_control_destroy(crdpq_control_t* q) {
    if (!q) return;
    free(q->buf[0]);
    free(q->buf[1]);
    free(q);
}

crdpq_generation_t crdpq_generation_bump(crdpq_control_t* q) {
    /* fetch_add returns the *old* value; the new value (what "bumped" means here) is
     * old + 1, matching adr/0005 §4 step 5's "generation +1" as the value that takes effect.
     * L2: relaxed is sufficient here specifically because adr/0005 §4 step 5 places this
     * call only after both producer threads (T_rdp/T_dvc) have already joined — there is
     * no concurrent producer left that could race a relaxed increment against an in-flight
     * crdpq_post's own relaxed read of `generation`. If a future caller ever needs to bump
     * while a producer thread might still be running, this precondition — and the memory
     * order it justifies — would need to be revisited together. */
    return atomic_fetch_add_explicit(&q->generation, 1u, memory_order_relaxed) + 1u;
}

crdpq_generation_t crdpq_current_generation(const crdpq_control_t* q) {
    return atomic_load_explicit(&((crdpq_control_t*)q)->generation, memory_order_relaxed);
}

bool crdpq_post(crdpq_control_t* q, const CrdpEvent* ev) {
    bool should_schedule = false;
    bool ok = true;

    os_unfair_lock_lock(&q->lock);

    /* M1: the seal check lives HERE, inside the same critical section as the enqueue
     * itself — not before acquiring the lock. crdpq.h's doc comment promises
     * unconditionally that "after crdpq_seal returns, crdpq_post always returns false
     * without enqueueing"; a check taken before the lock leaves a window where a
     * concurrent crdpq_seal() can complete strictly before this post's actual buffer
     * write, yet the write still goes through — confirmed empirically by the review's
     * sealrace harness. Reading `sealed` as late as possible, immediately before the
     * mutation it gates, closes that window. os_unfair_lock_lock is already taken
     * unconditionally below for the actual append, so this costs nothing extra. */
    if (atomic_load_explicit(&q->sealed, memory_order_relaxed)) {
        ok = false;
    } else {
        int b = q->back_idx;
        if (q->count[b] == q->capacity[b]) {
            if (q->capacity[b] >= q->max_capacity) {
                /* M4: already at the configured ceiling and completely full — refuse to
                 * grow further, reject and count this post for alerting. */
                ok = false;
                q->dropped_count++;
            } else {
                size_t new_cap = q->capacity[b] * 2;
                if (new_cap > q->max_capacity) {
                    new_cap = q->max_capacity;
                }
                CrdpEvent* grown = realloc(q->buf[b], new_cap * sizeof(CrdpEvent));
                if (!grown) {
                    ok = false;
                    q->dropped_count++;
                } else {
                    q->buf[b] = grown;
                    q->capacity[b] = new_cap;
                }
            }
        }

        if (ok) {
            CrdpEvent copy = *ev;
            copy.generation = atomic_load_explicit(&q->generation, memory_order_relaxed);
            q->buf[b][q->count[b]] = copy;
            q->count[b]++;
            if (q->count[b] > q->high_water_mark) {
                q->high_water_mark = q->count[b];
            }
            if (!q->drain_scheduled) {
                q->drain_scheduled = true;
                should_schedule = true;
            }
        }
    }

    os_unfair_lock_unlock(&q->lock);

    /* Call outside the lock: os_unfair_lock is a spinlock-class primitive, and
     * schedule_drain is arbitrary caller code (dispatch_async in production) that must
     * never run while it's held. */
    if (should_schedule && q->schedule_drain) {
        q->schedule_drain(q->schedule_drain_ctx);
    }

    return ok;
}

size_t crdpq_drain(crdpq_control_t* q, crdpq_visitor_fn visitor, void* vctx) {
    os_unfair_lock_lock(&q->lock);

    int old_back = q->back_idx;
    int old_front = 1 - old_back;
    q->back_idx = old_front; /* producers now write into what was front */
    q->drain_scheduled = false;

    CrdpEvent* drain_buf = q->buf[old_back];
    size_t drain_count = q->count[old_back];
    q->count[old_back] = 0; /* that buffer is the new (empty) front */

    os_unfair_lock_unlock(&q->lock);

    if (visitor) {
        for (size_t i = 0; i < drain_count; i++) {
            visitor(&drain_buf[i], vctx);
        }
    }

    return drain_count;
}

void crdpq_seal(crdpq_control_t* q) {
    atomic_store_explicit(&q->sealed, true, memory_order_relaxed);
}

bool crdpq_is_sealed(const crdpq_control_t* q) {
    return atomic_load_explicit(&((crdpq_control_t*)q)->sealed, memory_order_relaxed);
}

size_t crdpq_high_water_mark(const crdpq_control_t* q) {
    os_unfair_lock_lock(&((crdpq_control_t*)q)->lock);
    size_t hwm = q->high_water_mark;
    os_unfair_lock_unlock(&((crdpq_control_t*)q)->lock);
    return hwm;
}

size_t crdpq_dropped_count(const crdpq_control_t* q) {
    os_unfair_lock_lock(&((crdpq_control_t*)q)->lock);
    size_t dropped = q->dropped_count;
    os_unfair_lock_unlock(&((crdpq_control_t*)q)->lock);
    return dropped;
}
