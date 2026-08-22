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

    printf("\n%s (%d failures)\n", fails ? "SLOTS: FAIL" : "SLOTS: PASS", fails);
    return fails ? 1 : 0;
}
