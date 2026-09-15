#include "crgfx_counters.h"

#include <os/lock.h>
#include <stdlib.h>

typedef struct {
    uint32_t surfaceId;
    bool claimed; /* surfaceId 0 is a legal GFX surface id, so emptiness needs its own flag */
    uint64_t updates;
    uint64_t dirty;
    uint64_t publishes;
    uint64_t stale;
} crgfx_counter_slot_t;

struct crgfx_counters {
    os_unfair_lock lock;
    /* Linear scan, not the open addressing crdpq_frames uses: this table is read once per
     * window per diagnostic sample and written once per frame, and 64 comparisons of a
     * uint32 under an uncontended lock is not a cost this path can notice. A hash would buy
     * nothing measurable and would add the probe-exhaustion case that was crdpq_frames' own
     * H1 heap-overflow bug. */
    crgfx_counter_slot_t slots[CRGFX_COUNTERS_SLOTS];
};

/* Must be called with the lock held. Returns NULL when `surfaceId` has no slot and
 * `claimIfAbsent` is false, or when the table is full. */
static crgfx_counter_slot_t* crgfx_counters_slot_locked(crgfx_counters_t* counters, uint32_t surfaceId,
                                                        bool claimIfAbsent)
{
    crgfx_counter_slot_t* freeSlot = NULL;
    for (size_t i = 0; i < CRGFX_COUNTERS_SLOTS; i++) {
        crgfx_counter_slot_t* slot = &counters->slots[i];
        if (slot->claimed && slot->surfaceId == surfaceId) {
            return slot;
        }
        if (!slot->claimed && !freeSlot) {
            freeSlot = slot;
        }
    }
    if (!claimIfAbsent || !freeSlot) {
        return NULL;
    }
    freeSlot->claimed = true;
    freeSlot->surfaceId = surfaceId;
    return freeSlot;
}

crgfx_counters_t* crgfx_counters_create(void)
{
    crgfx_counters_t* counters = (crgfx_counters_t*)calloc(1, sizeof(crgfx_counters_t));
    if (!counters) return NULL;
    counters->lock = OS_UNFAIR_LOCK_INIT;
    return counters;
}

void crgfx_counters_destroy(crgfx_counters_t* counters)
{
    free(counters);
}

void crgfx_counters_note_update(crgfx_counters_t* counters, uint32_t surfaceId, bool dirty)
{
    if (!counters) return;
    os_unfair_lock_lock(&counters->lock);
    crgfx_counter_slot_t* slot = crgfx_counters_slot_locked(counters, surfaceId, true);
    if (slot) {
        slot->updates++;
        if (dirty) slot->dirty++;
    }
    os_unfair_lock_unlock(&counters->lock);
}

void crgfx_counters_note_publish(crgfx_counters_t* counters, uint32_t surfaceId)
{
    if (!counters) return;
    os_unfair_lock_lock(&counters->lock);
    crgfx_counter_slot_t* slot = crgfx_counters_slot_locked(counters, surfaceId, false);
    if (slot) {
        slot->publishes++;
    }
    os_unfair_lock_unlock(&counters->lock);
}

void crgfx_counters_note_stale(crgfx_counters_t* counters, uint32_t surfaceId)
{
    if (!counters) return;
    os_unfair_lock_lock(&counters->lock);
    crgfx_counter_slot_t* slot = crgfx_counters_slot_locked(counters, surfaceId, false);
    if (slot) {
        slot->stale++;
    }
    os_unfair_lock_unlock(&counters->lock);
}

bool crgfx_counters_read(crgfx_counters_t* counters, uint32_t surfaceId, uint64_t* out_updates,
                         uint64_t* out_dirty, uint64_t* out_publishes, uint64_t* out_stale)
{
    if (!counters) return false;
    os_unfair_lock_lock(&counters->lock);
    crgfx_counter_slot_t* slot = crgfx_counters_slot_locked(counters, surfaceId, false);
    bool tracked = slot != NULL;
    if (tracked) {
        if (out_updates) *out_updates = slot->updates;
        if (out_dirty) *out_dirty = slot->dirty;
        if (out_publishes) *out_publishes = slot->publishes;
        if (out_stale) *out_stale = slot->stale;
    }
    os_unfair_lock_unlock(&counters->lock);
    return tracked;
}
