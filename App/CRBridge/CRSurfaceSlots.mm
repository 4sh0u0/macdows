#import "CRSurfaceSlots.h"

#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>

#include <freerdp/codec/region.h>
#include <freerdp/types.h>

#include <cstring>
#include <unordered_map>

namespace
{

/* Mirrors CoreVideo's own `#define kCVPixelFormatType_32BGRA 'BGRA'` (CVPixelBuffer.h) --
 * defined locally rather than linking CoreVideo.framework just for one FourCC constant.
 * Clang packs a multi-character literal from source order into the int's bytes
 * most-significant-first at compile time, independent of host runtime endianness, which is
 * exactly the behavior Apple's own header relies on -- replicating the literal verbatim
 * reproduces the identical value. */
constexpr uint32_t kBGRA32FourCC = 'BGRA';

/* Bound on how many rects a single crsurface_table_write call ever turns into RECTANGLE_16s
 * for region accumulation -- CRSession.mm's own caller-side cap (kMaxStackRects) is already
 * 64, so this is a second, independent, defensive ceiling on this function's own contract,
 * not something expected to ever actually bind given a well-behaved caller. */
constexpr uint32_t kMaxWireRects = 64;

struct CRSurfaceBuffer
{
    IOSurfaceRef surface = nullptr; // nullptr => this ring slot is currently unallocated
    enum class State
    {
        Free,
        Written,
        Leased
    } state = State::Free;
    uint32_t frameGeneration = 0;
    bool neverWritten = true;
    /* H1: the union of every dirty rect posted while this buffer sat out a rotation (i.e.
     * wasn't chosen as the write target), cleared the moment it IS chosen and brought back
     * up to date. See crsurface_table_write's own comment for the full reasoning -- this
     * replaces the old "idx != slot.lastWrittenIndex => full frame" test, which measured
     * out (real instrumentation against a real write->lease->recycle-previous cycle) to be
     * true on nearly every single write, defeating the entire point of a dirty-rect path.
     * region16_init'd/region16_uninit'd via this struct's own constructor/destructor --
     * copy/move are explicitly deleted so an accidental container-driven copy can never
     * shallow-copy the underlying REGION16_DATA* and double-free it; std::unordered_map
     * never actually needs to copy or move a mapped_type instance for insert/erase/rehash
     * (node-based storage, pointer/reference-stable across all three). */
    REGION16 pendingDirty;

    CRSurfaceBuffer() { region16_init(&pendingDirty); }
    ~CRSurfaceBuffer() { region16_uninit(&pendingDirty); }
    CRSurfaceBuffer(const CRSurfaceBuffer &) = delete;
    CRSurfaceBuffer &operator=(const CRSurfaceBuffer &) = delete;
    CRSurfaceBuffer(CRSurfaceBuffer &&) = delete;
    CRSurfaceBuffer &operator=(CRSurfaceBuffer &&) = delete;
};

struct CRSurfaceSlot
{
    uint64_t windowId = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    CRSurfaceBuffer buffers[3];
    int lastWrittenIndex = -1; // index into buffers[], or -1 if nothing ever published
};

struct LeaseRecord
{
    uint32_t surfaceId;
    int index;
};

/* Releases every buffer's ring-owned reference (regardless of state) and resets the slot to
 * "no buffers allocated". A buffer that is currently Leased is NOT left dangling: the
 * caller holding that lease also holds its own separate +1 CFRetain from
 * crsurface_table_lease_published, so this CFRelease only removes the ring's stake --
 * the object stays alive until that caller's own crsurface_table_release_lease call drops
 * the last reference. Also clears each buffer's accumulated pendingDirty (H1) -- once a
 * buffer's surface itself is gone, any accumulated region referred to pixels that no
 * longer exist; a freshly (re)created buffer must start from an empty region, not
 * leftover bookkeeping from a previous surface generation at this index. Must be called
 * with the table lock held. */
void DestroySlotBuffers(CRSurfaceSlot &slot)
{
    for (auto &buf : slot.buffers)
    {
        if (buf.surface)
        {
            CFRelease(buf.surface);
            buf.surface = nullptr;
        }
        buf.state = CRSurfaceBuffer::State::Free;
        buf.neverWritten = true;
        region16_clear(&buf.pendingDirty);
    }
    slot.lastWrittenIndex = -1;
}

/* M4: removes every `leases` entry pointing at `surfaceId`. Called whenever that
 * surfaceId's slot is torn down while still tracked (crsurface_table_map's remap branch,
 * crsurface_table_unmap_window, crsurface_table_clear) -- without this, a lease that's
 * never subsequently released (e.g. a window force-closed without its CATransaction
 * completion ever firing) would sit in `leases` indefinitely, referencing a slot that no
 * longer exists. This is purely `leases` map hygiene: crsurface_table_release_lease's own
 * pointer-identity check already handles a stale/orphaned entry correctly regardless (see
 * that function's own comment) -- this just reclaims the bookkeeping proactively instead
 * of leaving it to whenever (if ever) the caller gets around to releasing it. Must be
 * called with the table lock held. */
void EraseLeasesFor(CRSurfaceSlotTable &table, uint32_t surfaceId);

IOSurfaceRef CreateBGRA32IOSurface(uint32_t width, uint32_t height)
{
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
    if (!props)
        return nullptr;

    auto setNum = [&](CFStringRef key, uint32_t v) {
        CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
        if (n)
        {
            CFDictionarySetValue(props, key, n);
            CFRelease(n);
        }
    };
    setNum(kIOSurfaceWidth, width);
    setNum(kIOSurfaceHeight, height);
    setNum(kIOSurfaceBytesPerElement, 4);
    setNum(kIOSurfacePixelFormat, kBGRA32FourCC);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);
    return surface;
}

} // namespace

struct CRSurfaceSlotTable
{
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    std::unordered_map<uint32_t, CRSurfaceSlot> slots;      // keyed by surfaceId
    std::unordered_map<IOSurfaceRef, LeaseRecord> leases;   // keyed by the leased-out ref's identity
    uint64_t droppedFrameCount = 0;
    uint64_t fullFrameCopies = 0; // diagnostics only (crsurface_table_copy_path_counts)
    uint64_t rectCopies = 0;      // diagnostics only
};

namespace
{
void EraseLeasesFor(CRSurfaceSlotTable &table, uint32_t surfaceId)
{
    for (auto it = table.leases.begin(); it != table.leases.end();)
    {
        if (it->second.surfaceId == surfaceId)
            it = table.leases.erase(it);
        else
            ++it;
    }
}
} // namespace

CRSurfaceSlotTable *crsurface_table_create(void)
{
    return new CRSurfaceSlotTable();
}

void crsurface_table_destroy(CRSurfaceSlotTable *table)
{
    if (!table)
        return;
    crsurface_table_clear(table);
    delete table;
}

void crsurface_table_map(CRSurfaceSlotTable *table, uint32_t surfaceId, uint64_t windowId)
{
    if (!table)
        return;
    os_unfair_lock_lock(&table->lock);

    auto sIt = table->slots.find(surfaceId);
    if (sIt != table->slots.end() && sIt->second.windowId != windowId)
    {
        /* M3: a remap to a DIFFERENT windowId, even at the same surface size (so
         * crsurface_table_write's own size-change detection would never fire on its own).
         * Without this, a buffer still holding the OLD window's last published frame
         * (slot.lastWrittenIndex still pointing at it, state still Written) could be
         * handed out via crsurface_table_lease_published under the NEW window's identity
         * before any fresh write ever occurs for it -- a real cross-window frame leak.
         * Tearing down exactly like a size change does (DestroySlotBuffers) is correct and
         * sufficient: the next write reallocates fresh buffers and is forced onto the
         * full-frame path (neverWritten), and any leases already outstanding against the
         * old buffers are reclaimed from `leases` too (M4) so they resolve as orphaned
         * the moment their caller eventually releases them. */
        DestroySlotBuffers(sIt->second);
        EraseLeasesFor(*table, surfaceId);
    }

    /* operator[] default-constructs a fresh CRSurfaceSlot if surfaceId isn't already
     * tracked. If one already existed with the SAME windowId (a re-map without an
     * intervening unmap -- not expected by the protocol, but handled defensively rather
     * than asserted), its buffers are deliberately left alone: crsurface_table_write
     * already reallocates on any dimension change, so there's nothing here that needs to
     * force a teardown for that case. */
    table->slots[surfaceId].windowId = windowId;
    os_unfair_lock_unlock(&table->lock);
}

void crsurface_table_unmap_window(CRSurfaceSlotTable *table, uint64_t windowId)
{
    if (!table)
        return;
    os_unfair_lock_lock(&table->lock);
    for (auto it = table->slots.begin(); it != table->slots.end();)
    {
        if (it->second.windowId == windowId)
        {
            DestroySlotBuffers(it->second);
            EraseLeasesFor(*table, it->first); // M4
            it = table->slots.erase(it);
        }
        else
        {
            ++it;
        }
    }
    os_unfair_lock_unlock(&table->lock);
}

bool crsurface_table_write(CRSurfaceSlotTable *table, uint32_t surfaceId, const uint8_t *data, uint32_t width,
                            uint32_t height, uint32_t scanline, uint32_t generation, const CRSurfaceRect *rects,
                            uint32_t rectCount)
{
    if (!table || !data || width == 0 || height == 0)
        return false;

    os_unfair_lock_lock(&table->lock);

    auto sIt = table->slots.find(surfaceId);
    if (sIt == table->slots.end())
    {
        /* Not mapped -- e.g. a stray update racing UnmapWindowForSurface. Not counted as a
         * dropped *frame* (droppedFrameCount tracks capacity pressure on a tracked slot,
         * not protocol races), just silently declined. */
        os_unfair_lock_unlock(&table->lock);
        return false;
    }
    CRSurfaceSlot &slot = sIt->second;

    if (slot.width != width || slot.height != height)
    {
        /* adr/0005 §2: buffers are bucketed/rebuilt by surface size. */
        DestroySlotBuffers(slot);
        slot.width = width;
        slot.height = height;
    }

    /* Prefer an unused buffer; otherwise reuse the currently-Written one (last-writer-wins,
     * matching crdpq_frames' own semantics -- an unconsumed previous frame is superseded
     * rather than queued). Only refuse to write if all three are Leased, i.e. legitimately
     * in use by T_main/CoreAnimation at once. */
    int idx = -1;
    for (int i = 0; i < 3; i++)
    {
        if (slot.buffers[i].state == CRSurfaceBuffer::State::Free)
        {
            idx = i;
            break;
        }
    }
    if (idx < 0)
    {
        for (int i = 0; i < 3; i++)
        {
            if (slot.buffers[i].state == CRSurfaceBuffer::State::Written)
            {
                idx = i;
                break;
            }
        }
    }
    if (idx < 0)
    {
        table->droppedFrameCount++;
        os_unfair_lock_unlock(&table->lock);
        return false;
    }

    CRSurfaceBuffer &buf = slot.buffers[idx];
    if (!buf.surface)
    {
        buf.surface = CreateBGRA32IOSurface(width, height);
        if (!buf.surface)
        {
            table->droppedFrameCount++;
            os_unfair_lock_unlock(&table->lock);
            return false;
        }
        buf.neverWritten = true;
    }

    /* H1: convert this frame's rects (or "no rects" / "too many to pass" -- CRSession.mm's
     * own kMaxStackRects fallback, both spelled rectCount==0 -- into "the whole surface is
     * dirty", one rect covering it) into RECTANGLE_16s, then union them into EVERY buffer's
     * own accumulated pendingDirty, including the one we're about to write to (simpler than
     * special-casing it out; its pendingDirty gets read for the copy below and cleared
     * right after, so unioning into it first is harmless and avoids a second code path). A
     * buffer that sits out this rotation is now correctly "further behind" by exactly this
     * frame's contribution; the one we ARE writing has its own accumulated backlog (from
     * however many rotations it itself sat out) plus this frame's contribution, which is
     * exactly everything that's changed since it was last brought up to date. */
    {
        RECTANGLE_16 wireRects[kMaxWireRects];
        UINT32 wireRectCount = 0;
        if (rectCount == 0)
        {
            wireRects[0] =
                RECTANGLE_16{0, 0, static_cast<UINT16>(width), static_cast<UINT16>(height)};
            wireRectCount = 1;
        }
        else
        {
            for (uint32_t r = 0; r < rectCount && wireRectCount < kMaxWireRects; r++)
            {
                const CRSurfaceRect &rc = rects[r];
                UINT16 left = rc.left;
                UINT16 top = rc.top;
                UINT16 right = rc.right > width ? static_cast<UINT16>(width) : rc.right;
                UINT16 bottom = rc.bottom > height ? static_cast<UINT16>(height) : rc.bottom;
                if (left >= right || top >= bottom)
                    continue; // malformed (e.g. left > right) or fully out of bounds -- skip
                wireRects[wireRectCount++] = RECTANGLE_16{left, top, right, bottom};
            }
        }
        for (auto &siblingBuf : slot.buffers)
        {
            for (UINT32 r = 0; r < wireRectCount; r++)
            {
                region16_union_rect(&siblingBuf.pendingDirty, &siblingBuf.pendingDirty, &wireRects[r]);
            }
        }
    }

    /* A buffer only needs a genuine full-frame copy on its very first write -- with H1's
     * accumulated-union tracking above, its pendingDirty (read below) already reflects
     * exactly what's changed since it was last brought up to date on every subsequent
     * write, regardless of how many rotations it sat out. GDI's own surface->data is
     * always the complete, current buffer regardless of what changed (dirty regions are an
     * optimization hint, not the only valid pixels), so a full copy remains correct for
     * this first-write case where there is no prior valid content to patch onto at all. */
    const bool needFull = buf.neverWritten;

    /* L2: IOSurfaceLock can fail (e.g. under real memory pressure). Without a successful
     * lock, IOSurfaceGetBaseAddress below is meaningless -- skip this write entirely rather
     * than copying into (or basing pointer arithmetic on) a buffer this call doesn't
     * actually hold the lock on. Nothing is lost: pendingDirty already picked up this
     * frame's rects above (for every buffer, including this one), so whatever this write
     * would have copied simply stays pending for the next successful write. */
    IOReturn lockStatus = IOSurfaceLock(buf.surface, kIOSurfaceLockAvoidSync, NULL);
    if (lockStatus != kIOReturnSuccess)
    {
        table->droppedFrameCount++;
        os_unfair_lock_unlock(&table->lock);
        return false;
    }
    uint8_t *dst = static_cast<uint8_t *>(IOSurfaceGetBaseAddress(buf.surface));
    const size_t dstStride = IOSurfaceGetBytesPerRow(buf.surface);
    const size_t srcStride = scanline;

    if (needFull)
    {
        table->fullFrameCopies++;
        for (uint32_t y = 0; y < height; y++)
        {
            std::memcpy(dst + y * dstStride, data + static_cast<size_t>(y) * srcStride,
                        static_cast<size_t>(width) * 4);
        }
    }
    else
    {
        table->rectCopies++;
        UINT32 nbRects = 0;
        const RECTANGLE_16 *pending = region16_rects(&buf.pendingDirty, &nbRects);
        for (UINT32 r = 0; r < nbRects; r++)
        {
            const RECTANGLE_16 &rc = pending[r];
            const size_t rowBytes = static_cast<size_t>(rc.right - rc.left) * 4;
            for (uint32_t y = rc.top; y < rc.bottom; y++)
            {
                std::memcpy(dst + y * dstStride + static_cast<size_t>(rc.left) * 4,
                            data + static_cast<size_t>(y) * srcStride + static_cast<size_t>(rc.left) * 4, rowBytes);
            }
        }
    }

    IOSurfaceUnlock(buf.surface, kIOSurfaceLockAvoidSync, NULL);

    region16_clear(&buf.pendingDirty); // fully caught up now
    buf.state = CRSurfaceBuffer::State::Written;
    buf.frameGeneration = generation;
    buf.neverWritten = false;
    slot.lastWrittenIndex = idx;

    os_unfair_lock_unlock(&table->lock);
    return true;
}

IOSurfaceRef crsurface_table_lease_published(CRSurfaceSlotTable *table, uint32_t surfaceId, uint32_t *outGeneration)
{
    if (!table)
        return NULL;

    os_unfair_lock_lock(&table->lock);

    auto sIt = table->slots.find(surfaceId);
    if (sIt == table->slots.end())
    {
        os_unfair_lock_unlock(&table->lock);
        return NULL;
    }
    CRSurfaceSlot &slot = sIt->second;
    if (slot.lastWrittenIndex < 0)
    {
        os_unfair_lock_unlock(&table->lock);
        return NULL;
    }
    CRSurfaceBuffer &buf = slot.buffers[slot.lastWrittenIndex];
    if (buf.state != CRSurfaceBuffer::State::Written)
    {
        /* Already Leased -- the caller already holds this exact frame, nothing newer to
         * hand out. Never re-lease a buffer that's already checked out (that would let two
         * owners believe they exclusively hold the same write target). */
        os_unfair_lock_unlock(&table->lock);
        return NULL;
    }

    CFRetain(buf.surface);
    buf.state = CRSurfaceBuffer::State::Leased;
    if (outGeneration)
        *outGeneration = buf.frameGeneration;
    table->leases[buf.surface] = LeaseRecord{surfaceId, slot.lastWrittenIndex};
    IOSurfaceRef result = buf.surface;

    os_unfair_lock_unlock(&table->lock);
    return result;
}

void crsurface_table_release_lease(CRSurfaceSlotTable *table, IOSurfaceRef surface)
{
    if (!table || !surface)
        return;

    os_unfair_lock_lock(&table->lock);
    auto it = table->leases.find(surface);
    if (it == table->leases.end())
    {
        /* Unknown ref -- not something this table ever leased out (or a double-release).
         * Still honor the "+1 in, callee releases" contract so a caller bug here doesn't
         * additionally leak; there's nothing else safe to do without a known owner. */
        os_unfair_lock_unlock(&table->lock);
        CFRelease(surface);
        return;
    }
    LeaseRecord rec = it->second;
    table->leases.erase(it);

    auto sIt = table->slots.find(rec.surfaceId);
    if (sIt != table->slots.end())
    {
        CRSurfaceBuffer &buf = sIt->second.buffers[rec.index];
        /* Pointer-identity check: if the slot was unmapped and remapped, or resized, since
         * this lease was handed out, buf.surface here is either null or a different
         * IOSurfaceRef -- in that case this lease is orphaned and only the CFRelease below
         * (dropping the caller's own ref) applies; the ring's stake was already released by
         * DestroySlotBuffers at teardown time. */
        if (buf.surface == surface && buf.state == CRSurfaceBuffer::State::Leased)
        {
            buf.state = CRSurfaceBuffer::State::Free;
        }
    }
    os_unfair_lock_unlock(&table->lock);

    CFRelease(surface);
}

void crsurface_table_clear(CRSurfaceSlotTable *table)
{
    if (!table)
        return;
    os_unfair_lock_lock(&table->lock);
    for (auto &kv : table->slots)
    {
        DestroySlotBuffers(kv.second);
        EraseLeasesFor(*table, kv.first); // M4
    }
    table->slots.clear();
    os_unfair_lock_unlock(&table->lock);
}

uint64_t crsurface_table_dropped_frame_count(CRSurfaceSlotTable *table)
{
    if (!table)
        return 0;
    os_unfair_lock_lock(&table->lock);
    uint64_t v = table->droppedFrameCount;
    os_unfair_lock_unlock(&table->lock);
    return v;
}

void crsurface_table_copy_path_counts(CRSurfaceSlotTable *table, uint64_t *outFullFrameCopies,
                                       uint64_t *outRectCopies)
{
    if (!table)
    {
        if (outFullFrameCopies)
            *outFullFrameCopies = 0;
        if (outRectCopies)
            *outRectCopies = 0;
        return;
    }
    os_unfair_lock_lock(&table->lock);
    if (outFullFrameCopies)
        *outFullFrameCopies = table->fullFrameCopies;
    if (outRectCopies)
        *outRectCopies = table->rectCopies;
    os_unfair_lock_unlock(&table->lock);
}
