/* Must precede every #include: <string.h> declares memset_s (C11 Annex K) only when this is
 * defined before its first inclusion -- see crdpq_clip_wipe's doc comment in crdpq.h for why
 * the wipe has to be memset_s and not a plain memset. */
#define __STDC_WANT_LIB_EXT1__ 1

#include "crdpq.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ...and the macro alone is not enough. SwiftPM (and Xcode, with modules on) compile this file
 * against PREBUILT Clang modules of the system headers, and a module's content is fixed when
 * the module is built, not by macros defined in the file that imports it -- so under modules
 * the SDK's memset_s declaration stays hidden whatever is defined above (measured: the first
 * build of this file failed with "call to undeclared function 'memset_s'"). Hence this
 * prototype. It is the SDK's own (`errno_t` is `int` and `rsize_t` is `size_t` on Darwin), and
 * in a build without modules both declarations are visible, so the compiler itself checks that
 * the two agree. Darwin's libc has provided the symbol since macOS 10.9. */
int memset_s(void* s, size_t smax, int c, size_t n);

/* ==================================================================================== *
 * Clipboard byte side-store (adr/0026, PROPOSED) -- see crdpq_clip_store_t's doc comment in
 * crdpq.h for the threading contract and for why this is a plain mutex.
 *
 * Shape of every operation below: validate and allocate outside the lock, do only slot
 * bookkeeping under it, then copy, wipe and free outside it. A block that has been detached
 * from its slot under the lock is reachable from exactly one thread, so nothing after the
 * unlock can race; and neither the up-to-4-MiB memcpy nor the wipe ever holds the lock the
 * other side of the store is waiting on.
 * ==================================================================================== */

#define CRDPQ_CLIP_DIRECTIONS 2

typedef struct {
    bool inUse;
    uint32_t key;
    size_t length;
    uint8_t* bytes; /* NULL exactly when length == 0: an empty block owns no memory */
} crdpq_clip_slot_t;

struct crdpq_clip_store {
    pthread_mutex_t lock;
    size_t max_block_bytes; /* immutable after create, so read without the lock */
    size_t max_total_bytes; /* immutable after create */
    size_t live_bytes;
    uint32_t generation;
    /* Per-cause refusal counters, indexed by crdpq_clip_result_t and sized by its LAST member
     * -- see the MAINTENANCE ANCHOR note on CRDPQ_CLIP_ERR_NO_MEMORY in crdpq.h. */
    size_t refusal_counts[CRDPQ_CLIP_ERR_NO_MEMORY + 1];
    crdpq_clip_release_observer_fn observer;
    void* observer_ctx;
    crdpq_clip_slot_t slots[CRDPQ_CLIP_DIRECTIONS][CRDPQ_CLIP_SLOTS_PER_DIRECTION];
};

void crdpq_clip_wipe(void* p, size_t n) {
    if (!p || n == 0) return;
    /* The return value only reports a constraint violation (n > RSIZE_MAX), which a block
     * the store allocated itself cannot reach. */
    (void)memset_s(p, n, 0, n);
}

/** Wipes, shows the (already zeroed) block to the test observer, frees. NULL is a no-op, which
 *  is what makes every "release whatever this path ended up holding" call below unconditional. */
static void crdpq_clip_release(uint8_t* bytes, size_t length, crdpq_clip_release_observer_fn observer,
                               void* observer_ctx) {
    if (!bytes) return;
    crdpq_clip_wipe(bytes, length);
    if (observer) observer(bytes, length, observer_ctx);
    free(bytes);
}

static bool crdpq_clip_direction_valid(crdpq_clip_direction_t direction) {
    return direction == CRDPQ_CLIP_REMOTE_TO_LOCAL || direction == CRDPQ_CLIP_LOCAL_TO_REMOTE;
}

/** Must be called with the lock held. */
static void crdpq_clip_count_locked(crdpq_clip_store_t* s, crdpq_clip_result_t rc) {
    if (rc != CRDPQ_CLIP_OK && (int)rc > 0 && (int)rc <= (int)CRDPQ_CLIP_ERR_NO_MEMORY) {
        s->refusal_counts[rc]++;
    }
}

/** For the refusals decided before the lock is taken (arguments, block limit, allocation). */
static crdpq_clip_result_t crdpq_clip_refuse(crdpq_clip_store_t* s, crdpq_clip_result_t rc) {
    pthread_mutex_lock(&s->lock);
    crdpq_clip_count_locked(s, rc);
    pthread_mutex_unlock(&s->lock);
    return rc;
}

/** Must be called with the lock held. Returns CRDPQ_CLIP_SLOTS_PER_DIRECTION when no live slot
 *  in `direction` holds `key`. */
static size_t crdpq_clip_find_locked(const crdpq_clip_store_t* s, crdpq_clip_direction_t direction,
                                     uint32_t key) {
    for (size_t i = 0; i < CRDPQ_CLIP_SLOTS_PER_DIRECTION; i++) {
        const crdpq_clip_slot_t* slot = &s->slots[direction][i];
        if (slot->inUse && slot->key == key) return i;
    }
    return CRDPQ_CLIP_SLOTS_PER_DIRECTION;
}

/** Must be called with the lock held. Empties the slot and hands its block to the caller,
 *  who now owns the only reference and must release it. */
static uint8_t* crdpq_clip_detach_locked(crdpq_clip_store_t* s, crdpq_clip_slot_t* slot, size_t* out_length) {
    uint8_t* bytes = slot->bytes;
    *out_length = slot->length;
    s->live_bytes -= slot->length;
    slot->inUse = false;
    slot->key = 0;
    slot->length = 0;
    slot->bytes = NULL;
    return bytes;
}

crdpq_clip_store_t* crdpq_clip_store_create(size_t max_block_bytes, size_t max_total_bytes) {
    crdpq_clip_store_t* s = calloc(1, sizeof(crdpq_clip_store_t));
    if (!s) return NULL;
    if (pthread_mutex_init(&s->lock, NULL) != 0) {
        free(s);
        return NULL;
    }
    s->max_block_bytes = max_block_bytes;
    /* Same floor-clamping posture as crdpq_control_create_with_max_capacity: a total limit
     * that could never admit the store's own largest block is not a configuration, it is a
     * mistake, so it is raised rather than honored. */
    s->max_total_bytes = max_total_bytes > max_block_bytes ? max_total_bytes : max_block_bytes;
    return s;
}

/** Detaches every live block under the lock (bumping the generation if asked), then releases
 *  them all outside it. Shared by clear and destroy so both wipe through the same path. */
static uint32_t crdpq_clip_release_all(crdpq_clip_store_t* s, bool bump_generation) {
    uint8_t* detached[CRDPQ_CLIP_DIRECTIONS * CRDPQ_CLIP_SLOTS_PER_DIRECTION];
    size_t lengths[CRDPQ_CLIP_DIRECTIONS * CRDPQ_CLIP_SLOTS_PER_DIRECTION];
    size_t n = 0;

    pthread_mutex_lock(&s->lock);
    for (size_t d = 0; d < CRDPQ_CLIP_DIRECTIONS; d++) {
        for (size_t i = 0; i < CRDPQ_CLIP_SLOTS_PER_DIRECTION; i++) {
            crdpq_clip_slot_t* slot = &s->slots[d][i];
            if (!slot->inUse) continue;
            detached[n] = crdpq_clip_detach_locked(s, slot, &lengths[n]);
            n++;
        }
    }
    if (bump_generation) s->generation++;
    const uint32_t generation = s->generation;
    const crdpq_clip_release_observer_fn observer = s->observer;
    void* const observer_ctx = s->observer_ctx;
    pthread_mutex_unlock(&s->lock);

    for (size_t i = 0; i < n; i++) {
        crdpq_clip_release(detached[i], lengths[i], observer, observer_ctx);
    }
    return generation;
}

void crdpq_clip_store_destroy(crdpq_clip_store_t* s) {
    if (!s) return;
    (void)crdpq_clip_release_all(s, false);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

uint32_t crdpq_clip_store_generation(const crdpq_clip_store_t* s) {
    if (!s) return 0;
    /* Same const-cast-to-lock shape crdpq_icon_store_lookup uses: logically a read. */
    crdpq_clip_store_t* sw = (crdpq_clip_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const uint32_t generation = sw->generation;
    pthread_mutex_unlock(&sw->lock);
    return generation;
}

uint32_t crdpq_clip_store_clear(crdpq_clip_store_t* s) {
    if (!s) return 0;
    return crdpq_clip_release_all(s, true);
}

crdpq_clip_result_t crdpq_clip_store_put(crdpq_clip_store_t* s, uint32_t generation,
                                         crdpq_clip_direction_t direction, uint32_t key,
                                         const uint8_t* bytes, size_t length) {
    if (!s) return CRDPQ_CLIP_ERR_ARGUMENT;
    if (!crdpq_clip_direction_valid(direction) || (!bytes && length > 0)) {
        return crdpq_clip_refuse(s, CRDPQ_CLIP_ERR_ARGUMENT);
    }
    /* Before allocating: an over-limit block (a server announcing an absurd length, say)
     * costs a comparison, not an allocation of that length. */
    if (length > s->max_block_bytes) {
        return crdpq_clip_refuse(s, CRDPQ_CLIP_ERR_BLOCK_TOO_LARGE);
    }
    uint8_t* copy = NULL;
    if (length > 0) {
        copy = malloc(length);
        if (!copy) return crdpq_clip_refuse(s, CRDPQ_CLIP_ERR_NO_MEMORY);
        memcpy(copy, bytes, length);
    }

    crdpq_clip_result_t rc = CRDPQ_CLIP_OK;

    pthread_mutex_lock(&s->lock);
    const crdpq_clip_release_observer_fn observer = s->observer;
    void* const observer_ctx = s->observer_ctx;
    if (generation != s->generation) {
        rc = CRDPQ_CLIP_ERR_STALE_GENERATION;
    } else if (crdpq_clip_find_locked(s, direction, key) < CRDPQ_CLIP_SLOTS_PER_DIRECTION) {
        /* Never an upsert (unlike crdpq_icon_store_put): a one-shot block has no legitimate
         * "newer version", so a key that is still live means two producers collided, and
         * replacing the block would hand the first event the second block's bytes. */
        rc = CRDPQ_CLIP_ERR_KEY_IN_USE;
    } else if (length > s->max_total_bytes - s->live_bytes) {
        /* live_bytes <= max_total_bytes always holds, so the subtraction cannot wrap. */
        rc = CRDPQ_CLIP_ERR_TOTAL_TOO_LARGE;
    } else {
        size_t idx = CRDPQ_CLIP_SLOTS_PER_DIRECTION;
        for (size_t i = 0; i < CRDPQ_CLIP_SLOTS_PER_DIRECTION; i++) {
            if (!s->slots[direction][i].inUse) {
                idx = i;
                break;
            }
        }
        if (idx == CRDPQ_CLIP_SLOTS_PER_DIRECTION) {
            rc = CRDPQ_CLIP_ERR_SLOTS_FULL;
        } else {
            crdpq_clip_slot_t* slot = &s->slots[direction][idx];
            slot->inUse = true;
            slot->key = key;
            slot->length = length;
            slot->bytes = copy;
            s->live_bytes += length;
            copy = NULL; /* the slot owns it now */
        }
    }
    crdpq_clip_count_locked(s, rc);
    pthread_mutex_unlock(&s->lock);

    /* Non-NULL exactly on a refusal after the copy was made: wiped before it goes back to malloc. */
    crdpq_clip_release(copy, length, observer, observer_ctx);
    return rc;
}

/** take and discard are the same operation up to whether the bytes are copied out first. */
static crdpq_clip_result_t crdpq_clip_remove(crdpq_clip_store_t* s, uint32_t generation,
                                             crdpq_clip_direction_t direction, uint32_t key,
                                             bool copy_out, uint8_t* dst, size_t dst_capacity,
                                             size_t* out_length) {
    if (out_length) *out_length = 0;
    if (!s) return CRDPQ_CLIP_ERR_ARGUMENT;
    if (!crdpq_clip_direction_valid(direction) || (copy_out && !dst && dst_capacity > 0)) {
        return crdpq_clip_refuse(s, CRDPQ_CLIP_ERR_ARGUMENT);
    }

    crdpq_clip_result_t rc = CRDPQ_CLIP_OK;
    uint8_t* block = NULL;
    size_t length = 0;

    pthread_mutex_lock(&s->lock);
    const crdpq_clip_release_observer_fn observer = s->observer;
    void* const observer_ctx = s->observer_ctx;
    if (generation != s->generation) {
        rc = CRDPQ_CLIP_ERR_STALE_GENERATION;
    } else {
        const size_t idx = crdpq_clip_find_locked(s, direction, key);
        if (idx == CRDPQ_CLIP_SLOTS_PER_DIRECTION) {
            rc = CRDPQ_CLIP_ERR_NOT_FOUND;
        } else if (copy_out && s->slots[direction][idx].length > dst_capacity) {
            rc = CRDPQ_CLIP_ERR_BUFFER_TOO_SMALL;
            length = s->slots[direction][idx].length;
        } else {
            block = crdpq_clip_detach_locked(s, &s->slots[direction][idx], &length);
        }
    }
    crdpq_clip_count_locked(s, rc);
    pthread_mutex_unlock(&s->lock);

    if (rc == CRDPQ_CLIP_ERR_BUFFER_TOO_SMALL) {
        if (out_length) *out_length = length;
        return rc;
    }
    if (rc != CRDPQ_CLIP_OK) return rc;
    if (copy_out && length > 0) memcpy(dst, block, length);
    if (out_length) *out_length = length;
    crdpq_clip_release(block, length, observer, observer_ctx);
    return rc;
}

crdpq_clip_result_t crdpq_clip_store_take(crdpq_clip_store_t* s, uint32_t generation,
                                          crdpq_clip_direction_t direction, uint32_t key,
                                          uint8_t* dst, size_t dst_capacity, size_t* out_length) {
    return crdpq_clip_remove(s, generation, direction, key, true, dst, dst_capacity, out_length);
}

crdpq_clip_result_t crdpq_clip_store_discard(crdpq_clip_store_t* s, uint32_t generation,
                                             crdpq_clip_direction_t direction, uint32_t key) {
    return crdpq_clip_remove(s, generation, direction, key, false, NULL, 0, NULL);
}

size_t crdpq_clip_store_refusal_count(const crdpq_clip_store_t* s, crdpq_clip_result_t rc) {
    if (!s) return 0;
    if (rc == CRDPQ_CLIP_OK || (int)rc < 0 || (int)rc > (int)CRDPQ_CLIP_ERR_NO_MEMORY) return 0;
    crdpq_clip_store_t* sw = (crdpq_clip_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const size_t count = sw->refusal_counts[rc];
    pthread_mutex_unlock(&sw->lock);
    return count;
}

size_t crdpq_clip_store_live_count(const crdpq_clip_store_t* s, crdpq_clip_direction_t direction) {
    if (!s || !crdpq_clip_direction_valid(direction)) return 0;
    crdpq_clip_store_t* sw = (crdpq_clip_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    size_t count = 0;
    for (size_t i = 0; i < CRDPQ_CLIP_SLOTS_PER_DIRECTION; i++) {
        if (sw->slots[direction][i].inUse) count++;
    }
    pthread_mutex_unlock(&sw->lock);
    return count;
}

size_t crdpq_clip_store_live_bytes(const crdpq_clip_store_t* s) {
    if (!s) return 0;
    crdpq_clip_store_t* sw = (crdpq_clip_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const size_t bytes = sw->live_bytes;
    pthread_mutex_unlock(&sw->lock);
    return bytes;
}

void crdpq_clip_store_set_release_observer(crdpq_clip_store_t* s, crdpq_clip_release_observer_fn observer,
                                           void* ctx) {
    if (!s) return;
    pthread_mutex_lock(&s->lock);
    s->observer = observer;
    s->observer_ctx = ctx;
    pthread_mutex_unlock(&s->lock);
}
