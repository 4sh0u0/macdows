#include "crdpq.h"

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>

#define CRDPQ_OUTBOUND_INITIAL_CAPACITY 64
/* M4 in the W3 review, mirrored from crdpq_control.c — see that file's comment on
 * CRDPQ_CONTROL_DEFAULT_MAX_CAPACITY for the full rationale. */
#define CRDPQ_OUTBOUND_DEFAULT_MAX_CAPACITY 65536u

/* Same double-buffer-with-independent-capacities layout as crdpq_control — see the
 * comment on `struct crdpq_control` in crdpq_control.c for why growth never touches the
 * buffer a concurrent drain's local snapshot might still be iterating. Direction is
 * reversed (T_main posts, T_rdp drains) but the mechanics are identical. */
struct crdpq_outbound {
    os_unfair_lock lock;
    CrdpCommand* buf[2];
    size_t capacity[2];
    size_t count[2];
    int back_idx;
    bool wakeup_pending;
    size_t high_water_mark;
    size_t max_capacity;   /* M4: ceiling on capacity[b]; growth stops here */
    size_t dropped_count;  /* M4: posts rejected for being at-cap-and-full, or OOM */
    _Atomic bool sealed;
    crdpq_wakeup_fn wakeup;
    void* wakeup_ctx;
};

crdpq_outbound_t* crdpq_outbound_create_with_max_capacity(crdpq_wakeup_fn wakeup, void* wakeup_ctx, size_t max_capacity) {
    crdpq_outbound_t* q = calloc(1, sizeof(crdpq_outbound_t));
    if (!q) return NULL;
    q->lock = OS_UNFAIR_LOCK_INIT;
    q->buf[0] = malloc(CRDPQ_OUTBOUND_INITIAL_CAPACITY * sizeof(CrdpCommand));
    q->buf[1] = malloc(CRDPQ_OUTBOUND_INITIAL_CAPACITY * sizeof(CrdpCommand));
    if (!q->buf[0] || !q->buf[1]) {
        free(q->buf[0]);
        free(q->buf[1]);
        free(q);
        return NULL;
    }
    q->capacity[0] = CRDPQ_OUTBOUND_INITIAL_CAPACITY;
    q->capacity[1] = CRDPQ_OUTBOUND_INITIAL_CAPACITY;
    q->back_idx = 0;
    /* Same floor-clamping rationale as crdpq_control_create_with_max_capacity. */
    q->max_capacity = max_capacity > CRDPQ_OUTBOUND_INITIAL_CAPACITY ? max_capacity : CRDPQ_OUTBOUND_INITIAL_CAPACITY;
    atomic_init(&q->sealed, false);
    q->wakeup = wakeup;
    q->wakeup_ctx = wakeup_ctx;
    return q;
}

crdpq_outbound_t* crdpq_outbound_create(crdpq_wakeup_fn wakeup, void* wakeup_ctx) {
    return crdpq_outbound_create_with_max_capacity(wakeup, wakeup_ctx, CRDPQ_OUTBOUND_DEFAULT_MAX_CAPACITY);
}

void crdpq_outbound_destroy(crdpq_outbound_t* q) {
    if (!q) return;
    free(q->buf[0]);
    free(q->buf[1]);
    free(q);
}

bool crdpq_outbound_post(crdpq_outbound_t* q, const CrdpCommand* cmd) {
    bool should_wake = false;
    bool ok = true;

    os_unfair_lock_lock(&q->lock);

    /* M1: same fix as crdpq_post in crdpq_control.c — the seal check moves inside the
     * same critical section as the enqueue, checked as late as possible, immediately
     * before the mutation it gates. See that file's comment for the full rationale;
     * "apply the same isomorphism check to outbound" in the M1 review applies the identical fix here. */
    if (atomic_load_explicit(&q->sealed, memory_order_relaxed)) {
        ok = false;
    } else {
        int b = q->back_idx;
        if (q->count[b] == q->capacity[b]) {
            if (q->capacity[b] >= q->max_capacity) {
                /* M4: already at the configured ceiling and completely full. */
                ok = false;
                q->dropped_count++;
            } else {
                size_t new_cap = q->capacity[b] * 2;
                if (new_cap > q->max_capacity) {
                    new_cap = q->max_capacity;
                }
                CrdpCommand* grown = realloc(q->buf[b], new_cap * sizeof(CrdpCommand));
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
            q->buf[b][q->count[b]] = *cmd;
            q->count[b]++;
            if (q->count[b] > q->high_water_mark) {
                q->high_water_mark = q->count[b];
            }
            if (!q->wakeup_pending) {
                q->wakeup_pending = true;
                should_wake = true;
            }
        }
    }

    os_unfair_lock_unlock(&q->lock);

    if (should_wake && q->wakeup) {
        q->wakeup(q->wakeup_ctx);
    }

    return ok;
}

size_t crdpq_outbound_drain(crdpq_outbound_t* q, crdpq_command_visitor_fn visitor, void* vctx) {
    os_unfair_lock_lock(&q->lock);

    int old_back = q->back_idx;
    int old_front = 1 - old_back;
    q->back_idx = old_front;
    q->wakeup_pending = false;

    CrdpCommand* drain_buf = q->buf[old_back];
    size_t drain_count = q->count[old_back];
    q->count[old_back] = 0;

    os_unfair_lock_unlock(&q->lock);

    if (visitor) {
        for (size_t i = 0; i < drain_count; i++) {
            visitor(&drain_buf[i], vctx);
        }
    }

    return drain_count;
}

void crdpq_outbound_seal(crdpq_outbound_t* q) {
    atomic_store_explicit(&q->sealed, true, memory_order_relaxed);
}

bool crdpq_outbound_is_sealed(const crdpq_outbound_t* q) {
    return atomic_load_explicit(&((crdpq_outbound_t*)q)->sealed, memory_order_relaxed);
}

size_t crdpq_outbound_high_water_mark(const crdpq_outbound_t* q) {
    os_unfair_lock_lock(&((crdpq_outbound_t*)q)->lock);
    size_t hwm = q->high_water_mark;
    os_unfair_lock_unlock(&((crdpq_outbound_t*)q)->lock);
    return hwm;
}

size_t crdpq_outbound_dropped_count(const crdpq_outbound_t* q) {
    os_unfair_lock_lock(&((crdpq_outbound_t*)q)->lock);
    size_t dropped = q->dropped_count;
    os_unfair_lock_unlock(&((crdpq_outbound_t*)q)->lock);
    return dropped;
}
