/**
 * slots-test: CRSurfaceSlots' own permanent regression suite (adr/0005 §2's frame
 * pathway) — this layer had zero unit tests before the W4b review flagged it. No FreeRDP
 * connection, no CRSession — exercises App/CRBridge/CRSurfaceSlots.h's C API directly,
 * standalone (Scripts/test-slots.sh compiles+links this against CRSurfaceSlots.mm and
 * libfreerdp3 — the latter only for region16's symbols, H1's own dependency).
 *
 * Scenarios A/B/C/D/F originated as the W4b review's own ad hoc verification harness
 * (slots_test.mm/rectpath.mm, kept only in a scratch directory); folded in here as this
 * project's permanent CRSurfaceSlots coverage rather than left as one-off review
 * artifacts. D and F were rewritten to read crsurface_table_copy_path_counts directly
 * (added specifically for this purpose) instead of needing a second, separately
 * instrumented copy of CRSurfaceSlots.mm (slots_instr.mm) linked in as an extern-global
 * hack — one real implementation, always accurate, no drift risk between a "real" and an
 * "instrumented" copy. E is the original review's worst-case benchmark (a full-frame
 * write with no dirty-rect data at all, unaffected by H1 by design — a genuine full copy
 * costs what it costs regardless of the rotation-tracking logic around it); G is new,
 * added for H1's own verification: the actual realistic steady-state pattern (small dirty
 * rect + lease + recycle-previous, RemoteWindow's own real usage) at the same 2560x1440
 * scale, which is what H1 was actually meant to improve.
 */
#include <vector>
#include <algorithm>
#import "CRSurfaceSlots.h"
#import <CoreFoundation/CoreFoundation.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mach/mach_time.h>

static int fails = 0;
#define CHECK(c, ...)                        \
    do                                        \
    {                                         \
        if (!(c))                             \
        {                                     \
            printf("  FAIL: ");               \
            printf(__VA_ARGS__);              \
            printf("\n");                     \
            fails++;                          \
        }                                     \
    } while (0)

static double ms_since(uint64_t t0)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0)
        mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}

int main()
{
    printf("=== A. lease -> unmap -> re-map same surfaceId, while lease is outstanding ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 64, H = 64;
        std::vector<uint8_t> px(W * H * 4, 0xAB);
        crsurface_table_map(t, 5, 100);
        CHECK(crsurface_table_write(t, 5, px.data(), W, H, W * 4, 1, NULL, 0), "first write");
        uint32_t g = 0;
        IOSurfaceRef leased = crsurface_table_lease_published(t, 5, &g);
        CHECK(leased != NULL, "lease succeeded");
        CFIndex rcAfterLease = CFGetRetainCount(leased);
        printf("  leased gen=%u retainCount=%ld (expect 2: ring + caller)\n", g, (long)rcAfterLease);
        CHECK(rcAfterLease == 2, "retainCount after lease should be 2, got %ld", (long)rcAfterLease);

        crsurface_table_unmap_window(t, 100); // T_dvc drops the slot
        CFIndex rcAfterUnmap = CFGetRetainCount(leased);
        printf("  after unmap retainCount=%ld (expect 1: only the caller's)\n", (long)rcAfterUnmap);
        CHECK(rcAfterUnmap == 1, "retainCount after unmap should be 1, got %ld", (long)rcAfterUnmap);

        crsurface_table_map(t, 5, 100); // re-map SAME surfaceId
        CHECK(crsurface_table_write(t, 5, px.data(), W, H, W * 4, 2, NULL, 0), "write after re-map");
        IOSurfaceRef leased2 = crsurface_table_lease_published(t, 5, &g);
        CHECK(leased2 != NULL && leased2 != leased, "re-mapped slot hands out a DIFFERENT buffer");

        crsurface_table_release_lease(t, leased); // late release of the orphaned lease
        printf("  orphaned lease released without crash\n");
        crsurface_table_release_lease(t, leased2);
        crsurface_table_destroy(t);
    }

    printf("=== B. resize while leased (DestroySlotBuffers with slot still in map) ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        std::vector<uint8_t> a(64 * 64 * 4, 1), b(128 * 128 * 4, 2);
        crsurface_table_map(t, 7, 200);
        crsurface_table_write(t, 7, a.data(), 64, 64, 64 * 4, 1, NULL, 0);
        IOSurfaceRef l = crsurface_table_lease_published(t, 7, NULL);
        CHECK(l != NULL, "lease before resize");
        crsurface_table_write(t, 7, b.data(), 128, 128, 128 * 4, 2, NULL, 0); // resize -> DestroySlotBuffers
        CHECK(CFGetRetainCount(l) == 1, "after resize the ring's stake is gone (rc=%ld)", (long)CFGetRetainCount(l));
        crsurface_table_release_lease(t, l);
        printf("  resize-while-leased released cleanly\n");
        crsurface_table_destroy(t);
    }

    printf("=== B2. remap to a different windowId, same size, while leased (M3) ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 64, H = 64;
        std::vector<uint8_t> px(W * H * 4, 9);
        crsurface_table_map(t, 8, 210); // surfaceId 8 -> windowId 210
        crsurface_table_write(t, 8, px.data(), W, H, W * 4, 1, NULL, 0);
        IOSurfaceRef l = crsurface_table_lease_published(t, 8, NULL);
        CHECK(l != NULL, "lease before remap");

        crsurface_table_map(t, 8, 211); // SAME surfaceId, SAME size, DIFFERENT windowId
        CHECK(CFGetRetainCount(l) == 1, "M3: remap to a different windowId drops the ring's stake (rc=%ld)",
              (long)CFGetRetainCount(l));

        uint32_t g = 0;
        IOSurfaceRef stale = crsurface_table_lease_published(t, 8, &g);
        CHECK(stale == NULL, "M3: nothing is published for surfaceId 8 immediately after a remap -- "
                              "the old window's frame must never be handed out under the new windowId");

        std::vector<uint8_t> px2(W * H * 4, 10);
        CHECK(crsurface_table_write(t, 8, px2.data(), W, H, W * 4, 2, NULL, 0), "write after remap");
        IOSurfaceRef fresh = crsurface_table_lease_published(t, 8, &g);
        CHECK(fresh != NULL && fresh != l, "remap's first write publishes a fresh buffer, distinct from the old lease");

        crsurface_table_release_lease(t, l); // late release of the now-orphaned old lease
        printf("  orphaned cross-window lease released without crash\n");
        if (fresh)
            crsurface_table_release_lease(t, fresh);
        crsurface_table_destroy(t);
    }

    printf("=== C. dirty rects exceeding surface bounds ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 32, H = 32;
        std::vector<uint8_t> px(W * H * 4, 0x11);
        crsurface_table_map(t, 9, 300);
        crsurface_table_write(t, 9, px.data(), W, H, W * 4, 1, NULL, 0); // full, buffer0
        crsurface_table_write(t, 9, px.data(), W, H, W * 4, 2, NULL, 0); // buffer1 (full again)
        // force same-index reuse so the RECT path actually runs: lease both free ones
        IOSurfaceRef l1 = crsurface_table_lease_published(t, 9, NULL);
        crsurface_table_write(t, 9, px.data(), W, H, W * 4, 3, NULL, 0);
        IOSurfaceRef l2 = crsurface_table_lease_published(t, 9, NULL);
        CRSurfaceRect bad[4] = {
            {0, 0, (uint16_t)(W + 50), (uint16_t)(H + 50)}, // right/bottom past the edge
            {(uint16_t)(W + 5), 0, (uint16_t)(W + 9), 4},   // entirely past the right edge
            {10, 10, 5, 20},                                // left > right (malformed)
            {0, 0, 8, 8},                                   // valid
        };
        bool ok = crsurface_table_write(t, 9, px.data(), W, H, W * 4, 4, bad, 4);
        printf("  write with out-of-bounds rects returned %d (no crash / no ASan report)\n", (int)ok);
        CHECK(ok, "a write with a mix of malformed/out-of-bounds/valid rects still succeeds overall");
        if (l1)
            crsurface_table_release_lease(t, l1);
        if (l2)
            crsurface_table_release_lease(t, l2);
        crsurface_table_destroy(t);
    }

    printf("=== D. H1: does the rect-union path dominate in the normal rotate-and-lease flow? ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 256, H = 256;
        std::vector<uint8_t> px(W * H * 4, 3);
        crsurface_table_map(t, 11, 400);
        CRSurfaceRect r = {0, 0, 8, 8};
        uint64_t fullBefore = 0, rectBefore = 0;
        crsurface_table_copy_path_counts(t, &fullBefore, &rectBefore);
        // Emulate steady state: write, lease, recycle previous -- exactly RemoteWindow's cycle.
        IOSurfaceRef prev = NULL;
        for (int i = 0; i < 50; i++)
        {
            crsurface_table_write(t, 11, px.data(), W, H, W * 4, (uint32_t)i, &r, 1);
            IOSurfaceRef cur = crsurface_table_lease_published(t, 11, NULL);
            if (prev)
                crsurface_table_release_lease(t, prev);
            prev = cur ? cur : prev;
        }
        if (prev)
            crsurface_table_release_lease(t, prev);
        uint64_t fullAfter = 0, rectAfter = 0;
        crsurface_table_copy_path_counts(t, &fullAfter, &rectAfter);
        uint64_t full = fullAfter - fullBefore, rect = rectAfter - rectBefore;
        printf("  50 frames (write->lease->recycle-previous, RemoteWindow's exact cycle): fullCopies=%llu "
               "rectCopies=%llu\n",
               (unsigned long long)full, (unsigned long long)rect);
        // Pre-H1, this was ~50 full / 0 rect (idx != lastWrittenIndex was true almost every
        // single write in this exact cycle). Post-H1, only each buffer's own first-ever
        // write is full (at most 3, one per ring slot); everything else is rect-union.
        CHECK(rect >= 45, "H1: steady-state rotation should overwhelmingly take the rect-union path "
                          "(got %llu/50 rect, %llu/50 full)",
              (unsigned long long)rect, (unsigned long long)full);
        CHECK(full <= 3, "at most 3 full copies expected (one per ring buffer's first-ever write), got %llu",
              (unsigned long long)full);
        crsurface_table_destroy(t);
    }

    printf("=== F. no consumer at all (nobody leases -- e.g. a filtered-out window's surface) ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 256, H = 256;
        std::vector<uint8_t> px(W * H * 4, 3);
        crsurface_table_map(t, 12, 450);
        CRSurfaceRect r = {0, 0, 8, 8};
        uint64_t fullBefore = 0, rectBefore = 0;
        crsurface_table_copy_path_counts(t, &fullBefore, &rectBefore);
        for (int i = 0; i < 50; i++)
            crsurface_table_write(t, 12, px.data(), W, H, W * 4, (uint32_t)i, &r, 1);
        uint64_t fullAfter = 0, rectAfter = 0;
        crsurface_table_copy_path_counts(t, &fullAfter, &rectAfter);
        uint64_t full = fullAfter - fullBefore, rect = rectAfter - rectBefore;
        printf("  50 frames, no lease ever (last-writer-wins reuse only): fullCopies=%llu rectCopies=%llu\n",
               (unsigned long long)full, (unsigned long long)rect);
        CHECK(full <= 3, "at most 3 full copies expected (one per ring buffer's first-ever write), got %llu",
              (unsigned long long)full);
        crsurface_table_destroy(t);
    }

    printf("=== E. worst case: full-frame copy cost at 2560x1440, no dirty-rect data at all ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 2560, H = 1440;
        std::vector<uint8_t> px((size_t)W * H * 4, 0x7F);
        crsurface_table_map(t, 13, 500);
        crsurface_table_write(t, 13, px.data(), W, H, W * 4, 0, NULL, 0); // warm
        const int N = 60;
        double worst = 0, total = 0;
        std::vector<double> samples;
        for (int i = 0; i < N; i++)
        {
            uint64_t t0 = mach_absolute_time();
            crsurface_table_write(t, 13, px.data(), W, H, W * 4, (uint32_t)i, NULL, 0);
            double d = ms_since(t0);
            samples.push_back(d);
            total += d;
            if (d > worst)
                worst = d;
        }
        std::sort(samples.begin(), samples.end());
        printf("  %d full-frame writes of %ux%u (%.1f MB each), no rects passed every time:\n", N, W, H,
               (double)W * H * 4 / 1e6);
        printf("    mean=%.3f ms  p50=%.3f ms  p95=%.3f ms  max=%.3f ms\n", total / N, samples[N / 2],
               samples[(int)(N * 0.95)], worst);
        crsurface_table_destroy(t);
    }

    printf("=== G. H1's actual payoff: steady-state 2560x1440 with a small dirty rect + lease + recycle ===\n");
    {
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 2560, H = 1440;
        std::vector<uint8_t> px((size_t)W * H * 4, 0x7F);
        crsurface_table_map(t, 14, 550);
        CRSurfaceRect r = {100, 100, 164, 164}; // a modest 64x64 dirty rect

        // Warm up: get all 3 ring buffers past their first-ever (necessarily full) write.
        IOSurfaceRef prevWarm = NULL;
        for (int i = 0; i < 3; i++)
        {
            crsurface_table_write(t, 14, px.data(), W, H, W * 4, (uint32_t)i, NULL, 0);
            IOSurfaceRef cur = crsurface_table_lease_published(t, 14, NULL);
            if (prevWarm)
                crsurface_table_release_lease(t, prevWarm);
            prevWarm = cur;
        }
        if (prevWarm)
            crsurface_table_release_lease(t, prevWarm);

        const int N = 60;
        double worst = 0, total = 0;
        std::vector<double> samples;
        IOSurfaceRef prev = NULL;
        for (int i = 0; i < N; i++)
        {
            uint64_t t0 = mach_absolute_time();
            crsurface_table_write(t, 14, px.data(), W, H, W * 4, (uint32_t)(100 + i), &r, 1);
            IOSurfaceRef cur = crsurface_table_lease_published(t, 14, NULL);
            double d = ms_since(t0);
            if (prev)
                crsurface_table_release_lease(t, prev);
            prev = cur ? cur : prev;
            samples.push_back(d);
            total += d;
            if (d > worst)
                worst = d;
        }
        if (prev)
            crsurface_table_release_lease(t, prev);
        std::sort(samples.begin(), samples.end());
        printf("  %d steady-state writes of a 64x64 dirty rect on a %ux%u surface (write+lease timed together):\n",
               N, W, H);
        printf("    mean=%.3f ms  p50=%.3f ms  p95=%.3f ms  max=%.3f ms\n", total / N, samples[N / 2],
               samples[(int)(N * 0.95)], worst);
        crsurface_table_destroy(t);
    }

    printf("=== H. lease-miss reasons + erase observer (ADR-0018 §5.2 (2)b, measurement only) ===\n");
    {
        /* WHY THIS SCENARIO EXISTS. The 2026-09-15 guard trace could only conclude "the slot was
         * gone" by ELIMINATION, because crsurface_table_lease_published answers all three of its
         * misses with the same NULL, and nothing anywhere recorded a slot teardown. The reason
         * out-parameter and the erase observer are what turn both into direct readings; this
         * scenario drives each of the four outcomes against the real table, in the same process
         * as the rest of the suite. */
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 32, H = 32;
        std::vector<uint8_t> px(W * H * 4, 0x5A);

        /* Every teardown the table performs, recorded in order. */
        static std::vector<uint32_t> erased;
        erased.clear();
        crsurface_table_set_erase_observer(
            t, NULL, [](void *, uint32_t surfaceId) { erased.push_back(surfaceId); });

        /* 1. No slot at all -- the id was never mapped. */
        CRSurfaceLeaseMiss miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 900, NULL, &miss) == NULL, "unmapped id leases nothing");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "unmapped id reports NoSlot, got %d", (int)miss);

        /* 2. Slot present, never written -- mapped and not yet drawn into. */
        crsurface_table_map(t, 900, 77);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 900, NULL, &miss) == NULL, "unwritten slot leases nothing");
        CHECK(miss == CRSurfaceLeaseMissNeverWritten, "unwritten slot reports NeverWritten, got %d", (int)miss);
        CHECK(erased.empty(), "mapping a NEW id is not a teardown (got %zu)", erased.size());

        /* 3. A real lease sets None; the second attempt on the same publish reports AlreadyLeased
         *    -- the ordinary "two doorbells, one frame" case, and the one miss that means nothing
         *    is wrong. */
        CHECK(crsurface_table_write(t, 900, px.data(), W, H, W * 4, 1, NULL, 0), "write into the mapped slot");
        CHECK(erased.empty(), "a FIRST write allocates rather than tears down (got %zu)", erased.size());
        miss = CRSurfaceLeaseMissNoSlot;
        IOSurfaceRef leased = crsurface_table_lease_published_reason(t, 900, NULL, &miss);
        CHECK(leased != NULL, "published frame leases");
        CHECK(miss == CRSurfaceLeaseMissNone, "a successful lease reports None, got %d", (int)miss);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 900, NULL, &miss) == NULL, "no second lease of one frame");
        CHECK(miss == CRSurfaceLeaseMissAlreadyLeased, "re-lease reports AlreadyLeased, got %d", (int)miss);
        crsurface_table_release_lease(t, leased);

        /* 4. A size change that discards a published frame IS a teardown (and the miss it leaves
         *    behind is NeverWritten -- the slot stays), while the surface's first write above was
         *    not: counting that would give every surface that ever drew an erased count of 1. */
        std::vector<uint8_t> px2((W * 2) * (H * 2) * 4, 0x11);
        CHECK(crsurface_table_write(t, 900, px2.data(), W * 2, H * 2, W * 2 * 4, 2, NULL, 0), "write at a new size");
        CHECK(erased.size() == 1 && erased[0] == 900, "a size change over a published frame is one teardown");

        /* 5. The whole-window sweep, which since lane fix/w3-remap-slot-erase is the bridge's
         *    DEFENSIVE path rather than its normal one: it erases every slot of that windowId,
         *    including this one, and every later lease then misses as NoSlot -- with the observer
         *    as the only record that the teardown happened at all. The sweep's own contract is
         *    unchanged and still pinned here because the bridge still takes it when a
         *    UnmapWindowForSurface arrives with no DeleteSurface in flight (CRSession.mm's
         *    crb_gfx_unmap_window_for_surface); what the 2026-09-15 trace turned on -- a delete of
         *    a STALE surface erasing the window's CURRENT one -- is scenario I. */
        crsurface_table_unmap_window(t, 77);
        CHECK(erased.size() == 2 && erased[1] == 900, "the unmap sweep reports each erased surface id");
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 900, NULL, &miss) == NULL, "erased slot leases nothing");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "an erased slot reports NoSlot, got %d", (int)miss);

        /* 6. A remap to a DIFFERENT window tears the buffers down too (the cross-window frame-leak
         *    guard), and the disconnect sweep reports every remaining slot. */
        crsurface_table_map(t, 901, 78);
        CHECK(crsurface_table_write(t, 901, px.data(), W, H, W * 4, 3, NULL, 0), "write for the second window");
        crsurface_table_map(t, 901, 79); // remap to another window
        CHECK(erased.size() == 3 && erased[2] == 901, "a remap to another window is a teardown");
        crsurface_table_clear(t);
        CHECK(erased.size() == 4 && erased[3] == 901, "the clear sweep reports the surviving slot");

        /* 7. A NULL TABLE answers NoSlot -- the out-parameter is written BEFORE the table guard,
         *    so a caller that reads the reason after a torn-down session gets a defined answer
         *    rather than whatever it seeded (gate r1 m-3; CRSession makes the same choice at its
         *    own boundary, and "there is no slot for any id" is literally true of no table). */
        miss = CRSurfaceLeaseMissAlreadyLeased;
        CHECK(crsurface_table_lease_published_reason(NULL, 900, NULL, &miss) == NULL, "a NULL table leases nothing");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "a NULL table reports NoSlot, got %d", (int)miss);

        /* 8. The NULL-reason entry point is unchanged, and observers are removable. */
        crsurface_table_set_erase_observer(t, NULL, NULL);
        crsurface_table_map(t, 902, 80);
        crsurface_table_unmap_window(t, 80);
        CHECK(erased.size() == 4, "a removed observer records nothing further (got %zu)", erased.size());
        CHECK(crsurface_table_lease_published(t, 902, NULL) == NULL, "the reason-less entry point still answers NULL");
        printf("  four lease-miss reasons and four teardown call sites all reported\n");
        crsurface_table_destroy(t);
    }

    printf("=== I. a stale surface's delete leaves the window's CURRENT surface alone "
           "(lane fix/w3-remap-slot-erase) ===\n");
    {
        /* WHY THIS SCENARIO EXISTS -- it is the measured defect, in miniature. In all three pairs
         * of the 2026-09-15 remap batch the About window's surface history was 4 -> 0 -> 4: the
         * server mapped surface 4, created and mapped surface 0, mapped 4 back, and only THEN
         * deleted the now-stale surface 0. FreeRDP's gdi_DeleteSurface still saw windowMapped on
         * surface 0 (a re-map of the window to 4 never clears the old surface's flag) and called
         * UnmapWindowForSurface(window), which the bridge turned into the whole-window sweep
         * below -- erasing surface 4's slot, the one the window was actually showing. No further
         * MapSurfaceToWindow ever arrived, so nothing re-created the slot, every later write was
         * refused and the window kept showing its old frame (last-period row of all three pairs:
         * writes=0 publishes=14 drop-noslot=14 presents=0).
         *
         * The fix is that the bridge erases only the DELETED surface's slot, which is what
         * crsurface_table_erase_surface does; this scenario drives that sequence against the real
         * table. Pointing it back at the sweep (erasing every slot of the window) fails at the
         * first CHECK below. */
        CRSurfaceSlotTable *t = crsurface_table_create();
        const uint32_t W = 32, H = 32;
        std::vector<uint8_t> px(W * H * 4, 0x3C);

        static std::vector<uint32_t> erasedI;
        erasedI.clear();
        crsurface_table_set_erase_observer(
            t, NULL, [](void *, uint32_t surfaceId) { erasedI.push_back(surfaceId); });

        const uint64_t kWindow = 328;
        /* 1. The A -> B -> A history, with no unmap anywhere in it (the server never sent one). */
        crsurface_table_map(t, 4, kWindow);
        crsurface_table_map(t, 0, kWindow);
        crsurface_table_map(t, 4, kWindow);
        CHECK(crsurface_table_write(t, 4, px.data(), W, H, W * 4, 1, NULL, 0),
              "the window's current surface takes a frame");
        CHECK(erasedI.empty(), "mapping and drawing tears nothing down (got %zu)", erasedI.size());

        /* 2. The delete of the STALE surface, the way the bridge's DeleteSurface hook now does it. */
        crsurface_table_erase_surface(t, 0);
        CHECK(erasedI.size() == 1 && erasedI[0] == 0, "exactly one teardown, of surface 0 (got %zu)",
              erasedI.size());

        /* 3. The current surface SURVIVES it, frame and all -- this is the whole fix. */
        CRSurfaceLeaseMiss miss = CRSurfaceLeaseMissNone;
        IOSurfaceRef live = crsurface_table_lease_published_reason(t, 4, NULL, &miss);
        CHECK(live != NULL, "the current surface's slot survives the stale surface's delete");
        CHECK(miss == CRSurfaceLeaseMissNone, "... and still leases its frame, got miss=%d", (int)miss);
        if (live)
            crsurface_table_release_lease(t, live);

        /* 4. ... and the deleted one is gone, which is what the delete was for. */
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 0, NULL, &miss) == NULL,
              "the deleted surface's slot is gone");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "the deleted surface reports NoSlot, got %d", (int)miss);

        /* 5. Erasing an id this table has no slot for is a no-op and is NOT a teardown (a delete
         *    of a surface that was never window-mapped reaches the hook the same way), and a NULL
         *    table is inert like every other entry point here. */
        crsurface_table_erase_surface(t, 0);
        crsurface_table_erase_surface(t, 12345);
        crsurface_table_erase_surface(NULL, 4);
        CHECK(erasedI.size() == 1, "erasing an absent id (or a NULL table) records nothing (got %zu)",
              erasedI.size());

        /* 6. THE ORDINARY CASE, the mirror of the one above (gate r1 I-5): a DeleteSurface for the
         *    surface a window is actually SHOWING -- a normal window close, where the slot being
         *    torn down holds a published frame. It must erase exactly that slot: not the window's
         *    OTHER, freshly-mapped slot (the shape the About window was in), and not another
         *    window's. Fresh ids and a fresh window so this step stands on its own, and the
         *    teardown count is taken RELATIVE to what came before it, so a failure earlier in the
         *    scenario cannot mask or manufacture this one. */
        const uint64_t kCloseWindow = 330;
        const uint64_t kOtherWindow = 329;
        crsurface_table_map(t, 20, kCloseWindow);
        CHECK(crsurface_table_write(t, 20, px.data(), W, H, W * 4, 2, NULL, 0),
              "the closing window's current surface takes a frame");
        crsurface_table_map(t, 21, kCloseWindow);
        crsurface_table_map(t, 9, kOtherWindow);
        CHECK(crsurface_table_write(t, 9, px.data(), W, H, W * 4, 3, NULL, 0), "the other window takes a frame");

        const size_t beforeClose = erasedI.size();
        crsurface_table_erase_surface(t, 20);
        CHECK(erasedI.size() == beforeClose + 1 && erasedI.back() == 20,
              "deleting a window's CURRENT surface is exactly one teardown, of surface 20 (got %zu new)",
              erasedI.size() - beforeClose);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 20, NULL, &miss) == NULL,
              "the current surface's slot is gone after its own delete");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "it reports NoSlot, got %d", (int)miss);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 21, NULL, &miss) == NULL, "surface 21 has no frame yet");
        CHECK(miss == CRSurfaceLeaseMissNeverWritten,
              "the SAME window's other slot survives that delete (NeverWritten, not NoSlot), got %d", (int)miss);
        miss = CRSurfaceLeaseMissNone;
        IOSurfaceRef other = crsurface_table_lease_published_reason(t, 9, NULL, &miss);
        CHECK(other != NULL && miss == CRSurfaceLeaseMissNone,
              "another window's slot is untouched by that delete (miss=%d)", (int)miss);
        if (other)
            crsurface_table_release_lease(t, other);

        /* 7. The DEFENSIVE path is still the whole-window sweep: when the bridge sees an unmap with
         *    no delete in flight it calls crsurface_table_unmap_window, which takes down every slot
         *    of THAT window at once -- here the two left on it -- and nobody else's. */
        const size_t beforeSweep = erasedI.size();
        crsurface_table_map(t, 7, kCloseWindow);
        CHECK(crsurface_table_write(t, 7, px.data(), W, H, W * 4, 4, NULL, 0), "sweep target takes a frame");
        crsurface_table_unmap_window(t, kCloseWindow);
        CHECK(erasedI.size() == beforeSweep + 2, "the sweep reports both remaining slots (got %zu new)",
              erasedI.size() - beforeSweep);
        {
            /* Order is the slot map's iteration order, which is not specified -- assert the SET. */
            std::vector<uint32_t> swept(erasedI.begin() + (long)beforeSweep, erasedI.end());
            std::sort(swept.begin(), swept.end());
            CHECK(swept == std::vector<uint32_t>({7, 21}), "the sweep erased surfaces 7 and 21");
        }
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 7, NULL, &miss) == NULL, "sweep took surface 7");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "surface 7 reports NoSlot after the sweep, got %d", (int)miss);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 21, NULL, &miss) == NULL, "sweep took surface 21");
        CHECK(miss == CRSurfaceLeaseMissNoSlot, "surface 21 reports NoSlot after the sweep, got %d", (int)miss);
        miss = CRSurfaceLeaseMissNone;
        CHECK(crsurface_table_lease_published_reason(t, 9, NULL, &miss) == NULL,
              "the other window's frame was already leased and released, so nothing NEW is on offer");
        CHECK(miss == CRSurfaceLeaseMissAlreadyLeased,
              "the other window's slot still EXISTS after the sweep (miss=%d)", (int)miss);

        printf("  one delete erases one slot (stale or current); the defensive sweep still takes the window's\n");
        crsurface_table_destroy(t);
    }

    printf("\n%s (%d failures)\n", fails ? "SLOTS: FAIL" : "SLOTS: PASS", fails);
    return fails ? 1 : 0;
}
