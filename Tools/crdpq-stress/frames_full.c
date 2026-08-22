/* Regression harness for H1 (W3 review): crdpq_frame_publish's internal find_slot could
 * return (size_t)-1 when the table is completely full and every growth attempt has
 * failed, and the pre-fix code indexed slots[(size_t)-1] unconditionally — a heap
 * out-of-bounds read/write, ASan-confirmed. This harness denies every growth allocation
 * past the initial 64-slot table (via a `calloc` macro interposed before #include-ing
 * crdpq_frames.c directly — the only way to fault-inject this specific allocation from
 * outside the library, which is why this coverage point stays a standalone C program
 * instead of a Swift Testing case; see CRDPQueueHardeningTests.swift's header comment)
 * and publishes 80 distinct surfaceIds into it, forcing the table to fill completely and
 * then keep receiving new surfaceIds it categorically cannot place.
 *
 * Post-fix expected behavior: no crash, ever; crdpq_frame_publish returns false and
 * crdpq_frames_dropped_count grows for every surfaceId that arrives once the table is
 * full (the "dropped count grows and zero crash reports" the W3 review's verification bar calls for); every
 * surfaceId that WAS accepted before the table filled up remains correctly stored and
 * peek-able, undisturbed by the later rejections. Exit code 0 = all of the above held;
 * nonzero = a regression (including a crash, which the OS/ASan itself will report). */
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

static int deny_growth = 0;
static void* test_calloc(size_t n, size_t sz) {
    if (deny_growth && n >= 128) {
        return NULL;
    }
    return calloc(n, sz);
}
#define calloc test_calloc
#include "crdpq_frames.c"
#undef calloc

static int fails = 0;
#define CHECK(cond, fmt, ...)                             \
    do {                                                  \
        if (!(cond)) {                                    \
            printf("  FAIL: " fmt "\n", ##__VA_ARGS__);    \
            fails++;                                       \
        }                                                  \
    } while (0)

int main(void) {
    crdpq_frames_t* f = crdpq_frames_create(NULL, NULL);
    CHECK(f != NULL, "crdpq_frames_create failed");
    printf("created, capacity=%zu\n", f->capacity);

    deny_growth = 1; /* every growth allocation (n >= 128) fails from here on */

    int accepted = 0, rejected = 0;
    for (uint32_t s = 0; s < 80; s++) {
        bool ok = crdpq_frame_publish(f, s, s + 1);
        if (ok) {
            accepted++;
        } else {
            rejected++;
        }
    }
    printf("accepted=%d rejected=%d occupied=%zu capacity=%zu dropped_count=%zu\n",
           accepted, rejected, f->occupied_count, f->capacity, crdpq_frames_dropped_count(f));

    /* The first 64 surfaceIds (0..63) map 1:1 onto the 64 initial slots under mask 63 —
     * no collisions among them — so they must all be accepted and the table fills exactly
     * full with no growth ever having actually succeeded (every attempt denied). */
    CHECK(accepted == 64, "expected exactly 64 accepted publishes, got %d", accepted);
    CHECK(rejected == 16, "expected exactly 16 rejected publishes, got %d", rejected);
    CHECK(f->occupied_count == 64, "expected occupied_count == 64, got %zu", f->occupied_count);
    CHECK(f->capacity == 64, "expected capacity to have never grown (every attempt denied), got %zu", f->capacity);
    CHECK(crdpq_frames_dropped_count(f) == 16, "expected dropped_count == 16, got %zu", crdpq_frames_dropped_count(f));

    for (uint32_t s = 0; s < 64; s++) {
        bool found = false;
        crdpq_generation_t gen = crdpq_frame_peek(f, s, &found);
        CHECK(found, "surfaceId %u should have been accepted and stored, but peek reports not-found", s);
        CHECK(gen == s + 1, "surfaceId %u: expected generation %u, got %u", s, s + 1, gen);
    }
    for (uint32_t s = 64; s < 80; s++) {
        bool found = false;
        (void)crdpq_frame_peek(f, s, &found);
        CHECK(!found, "surfaceId %u should have been rejected (table full), but peek reports found", s);
    }

    crdpq_frames_destroy(f);

    printf("%s (%d failures)\n", fails ? "FRAMES_FULL: FAIL" : "FRAMES_FULL: PASS", fails);
    return fails ? 1 : 0;
}
