#include "crdpq.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ==================================================================================== *
 * DIB -> premultiplied RGBA8888 conversion (adr/0013 §2)
 *
 * Pure C, no allocation, no globals. Every bound is checked before the first pixel is
 * read -- see crdpq_icon_convert's doc comment in crdpq.h for the per-field provenance of
 * each layout fact encoded below (all of them verified against ThirdParty/FreeRDP's own
 * parser/converter, not assumed from the ADR draft).
 * ==================================================================================== */

/** DIB scanline padding: bytes per row rounded up to a 4-byte boundary. */
static uint32_t crdpq_icon_round_up4(uint32_t bytes) {
    return (bytes + 3u) & ~3u;
}

/** 5-bit channel -> 8-bit, bit-identical to FreeRDP's own `(c << 3) + c / 4`
 *  (libfreerdp/codec/color.c's PIXEL_FORMAT_RGB15 branch of FreeRDPSplitColor): both map
 *  0 -> 0 and 31 -> 255 with the top bits replicated into the low ones. */
static uint8_t crdpq_icon_expand5(uint32_t c) {
    return (uint8_t)(((c & 0x1Fu) << 3) | ((c & 0x1Fu) >> 2));
}

/** Straight-alpha channel -> premultiplied, with round-to-nearest. a == 255 is exact
 *  (255*c + 127 < 255*(c+1), so the division floors to c) and a == 0 yields 0, so the two
 *  overwhelmingly common cases are lossless. */
static uint8_t crdpq_icon_premultiply(uint8_t c, uint8_t a) {
    return (uint8_t)(((uint32_t)c * (uint32_t)a + 127u) / 255u);
}

/** Picks the scanline stride actually consistent with `cb` for `height` rows of
 *  `row_bytes` payload each, preferring the DIB-canonical 4-byte-padded stride and falling
 *  back to the unpadded one (see crdpq_icon_convert's doc comment: the vendored source
 *  states both, and for every icon size that exists in practice they are the same number).
 *  Returns 0 -- never a valid stride -- when `cb` is too small for either.
 *
 *  The requirement deliberately mirrors FreeRDP's own mask-size formula
 *  (`stride * (height - 1) + row_bytes`, color.c:487) rather than `stride * height`: the
 *  final row's trailing pad bytes are never read, so demanding them would reject otherwise
 *  well-formed input. Reading row r at `stride * (height - 1 - r)` for `row_bytes` bytes
 *  touches at most byte `stride * (height - 1) + row_bytes - 1`, exactly this bound. */
static uint32_t crdpq_icon_pick_stride(uint32_t row_bytes, uint32_t height, uint32_t cb) {
    const uint32_t padded = crdpq_icon_round_up4(row_bytes);
    /* height <= CRDPQ_ICON_MAX_DIM and row_bytes <= CRDPQ_ICON_MAX_DIM * 4 by the time this
     * is called, so neither product can overflow uint32_t. */
    if (cb >= padded * (height - 1u) + row_bytes) {
        return padded;
    }
    if (cb >= row_bytes * (height - 1u) + row_bytes) {
        return row_bytes;
    }
    return 0;
}

crdpq_icon_convert_result_t crdpq_icon_convert(uint32_t bpp, uint32_t width, uint32_t height,
                                               uint32_t cbColorTable, uint32_t cbBitsMask,
                                               uint32_t cbBitsColor, const uint8_t* bitsColor,
                                               const uint8_t* colorTable, const uint8_t* bitsMask,
                                               uint8_t* dst, size_t dst_capacity) {
    if (!dst) {
        return CRDPQ_ICON_ERR_DEST;
    }
    if (width == 0 || height == 0 || width > CRDPQ_ICON_MAX_DIM || height > CRDPQ_ICON_MAX_DIM) {
        return CRDPQ_ICON_ERR_DIMENSIONS;
    }
    if (dst_capacity < (size_t)width * (size_t)height * 4u) {
        return CRDPQ_ICON_ERR_DEST;
    }

    bool indexed = false;
    switch (bpp) {
        case 1:
        case 4:
        case 8:
            indexed = true;
            break;
        case 16:
        case 24:
        case 32:
            break;
        default:
            /* FreeRDP's parser only guarantees 1..32; every other value in that range
             * (2, 5, 15, ...) lands here. */
            return CRDPQ_ICON_ERR_BPP;
    }

    /* DIB palettes are RGBQUAD arrays (B,G,R,X per entry) and exist only for 1/4/8bpp --
     * update_read_icon_info forces cbColorTable to 0 for every other bpp, so a non-zero
     * value there can't reach us and is simply ignored rather than treated as an error. */
    uint32_t paletteEntries = 0;
    if (indexed) {
        if (!colorTable || cbColorTable == 0 || (cbColorTable % 4u) != 0 || (cbColorTable / 4u) > 256u) {
            return CRDPQ_ICON_ERR_COLOR_TABLE;
        }
        paletteEntries = cbColorTable / 4u;
    }

    /* width <= 48 and bpp <= 32, so this is at most 192 -- no overflow anywhere below. */
    const uint32_t colorRowBytes = (width * bpp + 7u) / 8u;
    if (!bitsColor) {
        return CRDPQ_ICON_ERR_BITS_COLOR;
    }
    const uint32_t colorStride = crdpq_icon_pick_stride(colorRowBytes, height, cbBitsColor);
    if (colorStride == 0) {
        return CRDPQ_ICON_ERR_BITS_COLOR;
    }

    /* The AND mask is optional on the wire (cbBitsMask == 0 means "no mask was sent"), but a
     * declared-non-empty mask with no buffer, or one too short for `height` rows, is a
     * self-inconsistent order -- rejected, never partially read. */
    uint32_t maskStride = 0;
    const uint32_t maskRowBytes = (width + 7u) / 8u;
    if (cbBitsMask > 0) {
        if (!bitsMask) {
            return CRDPQ_ICON_ERR_BITS_MASK;
        }
        maskStride = crdpq_icon_pick_stride(maskRowBytes, height, cbBitsMask);
        if (maskStride == 0) {
            return CRDPQ_ICON_ERR_BITS_MASK;
        }
    }
    const bool useMask = (maskStride != 0);

    /* adr/0013 §2's 32bpp heuristic: a great many real-world 32bpp icons ship an alpha plane
     * that is entirely zero. Trusting it verbatim would render a fully invisible tray item,
     * so an all-zero plane is treated as "this icon has no alpha of its own" and the AND mask
     * (or full opacity) takes over. FreeRDP's own icon converter sidesteps the question by
     * always letting the AND mask win, discarding the source alpha even when it is real --
     * that loses genuine partial transparency, which is why this does not copy it. */
    bool alphaFromSource = false;
    if (bpp == 32) {
        for (uint32_t y = 0; y < height && !alphaFromSource; y++) {
            const uint8_t* row = bitsColor + (size_t)colorStride * (size_t)y;
            for (uint32_t x = 0; x < width; x++) {
                if (row[x * 4u + 3u] != 0) {
                    alphaFromSource = true;
                    break;
                }
            }
        }
    }

    for (uint32_t y = 0; y < height; y++) {
        /* Bottom-up: destination row 0 is the icon's top edge, which is the LAST source row. */
        const uint8_t* srcRow = bitsColor + (size_t)colorStride * (size_t)(height - 1u - y);
        const uint8_t* maskRow = useMask ? (bitsMask + (size_t)maskStride * (size_t)(height - 1u - y)) : NULL;
        uint8_t* dstRow = dst + (size_t)y * (size_t)width * 4u;

        for (uint32_t x = 0; x < width; x++) {
            uint8_t r = 0;
            uint8_t g = 0;
            uint8_t b = 0;
            uint8_t srcAlpha = 0xFF;
            bool unknownIndex = false;

            if (indexed) {
                uint32_t index = 0;
                if (bpp == 1) {
                    index = (srcRow[x >> 3] & (uint8_t)(0x80u >> (x & 7u))) ? 1u : 0u;
                } else if (bpp == 4) {
                    /* High nibble is the LEFT pixel (DIB packs left-to-right, MSB first). */
                    const uint8_t byte = srcRow[x >> 1];
                    index = (x & 1u) ? (uint32_t)(byte & 0x0Fu) : (uint32_t)(byte >> 4);
                } else {
                    index = srcRow[x];
                }
                if (index >= paletteEntries) {
                    unknownIndex = true;
                } else {
                    const uint8_t* entry = colorTable + (size_t)index * 4u;
                    b = entry[0];
                    g = entry[1];
                    r = entry[2];
                }
            } else if (bpp == 16) {
                /* Little-endian UINT16, RGB555 (NOT RGB565 -- color.c:424 says so outright). */
                const uint32_t v = (uint32_t)srcRow[x * 2u] | ((uint32_t)srcRow[x * 2u + 1u] << 8);
                r = crdpq_icon_expand5(v >> 10);
                g = crdpq_icon_expand5(v >> 5);
                b = crdpq_icon_expand5(v);
            } else if (bpp == 24) {
                const uint8_t* p = srcRow + (size_t)x * 3u;
                b = p[0];
                g = p[1];
                r = p[2];
            } else {
                const uint8_t* p = srcRow + (size_t)x * 4u;
                b = p[0];
                g = p[1];
                r = p[2];
                srcAlpha = p[3];
            }

            uint8_t alpha;
            if (bpp == 32 && alphaFromSource) {
                alpha = srcAlpha;
            } else if (useMask) {
                /* Set bit = transparent, matching freerdp_image_copy_from_icon_data's own
                 * `(*maskByte & nextBit) ? 0x00 : 0xFF`. */
                alpha = (maskRow[x >> 3] & (uint8_t)(0x80u >> (x & 7u))) ? 0x00u : 0xFFu;
            } else {
                alpha = 0xFFu;
            }
            if (unknownIndex) {
                alpha = 0x00u;
                r = g = b = 0;
            }

            uint8_t* px = dstRow + (size_t)x * 4u;
            px[0] = crdpq_icon_premultiply(r, alpha);
            px[1] = crdpq_icon_premultiply(g, alpha);
            px[2] = crdpq_icon_premultiply(b, alpha);
            px[3] = alpha;
        }
    }

    return CRDPQ_ICON_OK;
}

/* ==================================================================================== *
 * Icon store (adr/0013 §1)
 * ==================================================================================== */

typedef struct {
    uint32_t windowId;
    uint32_t notifyIconId;
    uint32_t width;
    uint32_t height;
    bool inUse;
    uint8_t rgba[CRDPQ_ICON_RGBA_BUF_SIZE];
} crdpq_icon_slot_t;

struct crdpq_icon_store {
    /* A plain mutex, on purpose -- see crdpq_icon_store_t's doc comment in crdpq.h for why
     * the frames lane's lock-free design is deliberately NOT copied here. */
    pthread_mutex_t lock;
    size_t overflow_count;
    crdpq_icon_slot_t slots[CRDPQ_ICON_SLOTS];
};

/** Must be called with the lock held. Returns CRDPQ_ICON_SLOTS when no live slot matches. */
static size_t crdpq_icon_find_locked(const crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId) {
    for (size_t i = 0; i < CRDPQ_ICON_SLOTS; i++) {
        if (s->slots[i].inUse && s->slots[i].windowId == windowId &&
            s->slots[i].notifyIconId == notifyIconId) {
            return i;
        }
    }
    return CRDPQ_ICON_SLOTS;
}

crdpq_icon_store_t* crdpq_icon_store_create(void) {
    crdpq_icon_store_t* s = calloc(1, sizeof(crdpq_icon_store_t));
    if (!s) return NULL;
    if (pthread_mutex_init(&s->lock, NULL) != 0) {
        free(s);
        return NULL;
    }
    return s;
}

void crdpq_icon_store_destroy(crdpq_icon_store_t* s) {
    if (!s) return;
    pthread_mutex_destroy(&s->lock);
    free(s);
}

void crdpq_icon_store_clear(crdpq_icon_store_t* s) {
    if (!s) return;
    pthread_mutex_lock(&s->lock);
    for (size_t i = 0; i < CRDPQ_ICON_SLOTS; i++) {
        s->slots[i].inUse = false;
        s->slots[i].windowId = 0;
        s->slots[i].notifyIconId = 0;
        s->slots[i].width = 0;
        s->slots[i].height = 0;
    }
    /* overflow_count deliberately survives -- see this function's doc comment. */
    pthread_mutex_unlock(&s->lock);
}

bool crdpq_icon_store_put(crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId,
                          const uint8_t* rgba, uint32_t width, uint32_t height, uint8_t* out_slot) {
    if (!s || !rgba || !out_slot) return false;
    if (width == 0 || height == 0 || width > CRDPQ_ICON_MAX_DIM || height > CRDPQ_ICON_MAX_DIM) {
        /* Defensive: crdpq_icon_convert already rejects these, but this store must be safe
         * on its own terms -- it is the thing holding the fixed-size buffer. */
        return false;
    }

    pthread_mutex_lock(&s->lock);
    size_t idx = crdpq_icon_find_locked(s, windowId, notifyIconId);
    if (idx == CRDPQ_ICON_SLOTS) {
        for (size_t i = 0; i < CRDPQ_ICON_SLOTS; i++) {
            if (!s->slots[i].inUse) {
                idx = i;
                break;
            }
        }
    }
    if (idx == CRDPQ_ICON_SLOTS) {
        s->overflow_count++;
        pthread_mutex_unlock(&s->lock);
        return false;
    }

    crdpq_icon_slot_t* slot = &s->slots[idx];
    slot->windowId = windowId;
    slot->notifyIconId = notifyIconId;
    slot->width = width;
    slot->height = height;
    slot->inUse = true;
    memcpy(slot->rgba, rgba, (size_t)width * (size_t)height * 4u);
    pthread_mutex_unlock(&s->lock);

    *out_slot = (uint8_t)idx;
    return true;
}

bool crdpq_icon_store_lookup(const crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId,
                             uint8_t* out_slot) {
    if (!s || !out_slot) return false;
    /* Same const-cast-to-lock shape crdpq_frame_peek/crdpq_frames_dropped_count already use:
     * the call is logically a read, the mutex is an implementation detail of that read. */
    crdpq_icon_store_t* sw = (crdpq_icon_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const size_t idx = crdpq_icon_find_locked(sw, windowId, notifyIconId);
    pthread_mutex_unlock(&sw->lock);
    if (idx == CRDPQ_ICON_SLOTS) return false;
    *out_slot = (uint8_t)idx;
    return true;
}

bool crdpq_icon_store_remove(crdpq_icon_store_t* s, uint32_t windowId, uint32_t notifyIconId) {
    if (!s) return false;
    pthread_mutex_lock(&s->lock);
    const size_t idx = crdpq_icon_find_locked(s, windowId, notifyIconId);
    if (idx != CRDPQ_ICON_SLOTS) {
        s->slots[idx].inUse = false;
        s->slots[idx].windowId = 0;
        s->slots[idx].notifyIconId = 0;
        s->slots[idx].width = 0;
        s->slots[idx].height = 0;
    }
    pthread_mutex_unlock(&s->lock);
    return idx != CRDPQ_ICON_SLOTS;
}

bool crdpq_icon_store_copy_slot(const crdpq_icon_store_t* s, uint8_t slot, uint32_t windowId,
                                uint32_t notifyIconId, uint8_t* dst, size_t dst_capacity,
                                uint32_t* out_width, uint32_t* out_height, size_t* out_bytes) {
    if (!s || !dst || slot >= CRDPQ_ICON_SLOTS) return false;
    crdpq_icon_store_t* sw = (crdpq_icon_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const crdpq_icon_slot_t* src = &sw->slots[slot];
    /* Key re-check, not redundant -- see this function's doc comment for the
     * delete-then-reclaim race it closes. */
    if (!src->inUse || src->windowId != windowId || src->notifyIconId != notifyIconId) {
        pthread_mutex_unlock(&sw->lock);
        return false;
    }
    const size_t bytes = (size_t)src->width * (size_t)src->height * 4u;
    if (dst_capacity < bytes) {
        pthread_mutex_unlock(&sw->lock);
        return false;
    }
    memcpy(dst, src->rgba, bytes);
    const uint32_t w = src->width;
    const uint32_t h = src->height;
    pthread_mutex_unlock(&sw->lock);

    if (out_width) *out_width = w;
    if (out_height) *out_height = h;
    if (out_bytes) *out_bytes = bytes;
    return true;
}

size_t crdpq_icon_store_overflow_count(const crdpq_icon_store_t* s) {
    if (!s) return 0;
    crdpq_icon_store_t* sw = (crdpq_icon_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    const size_t count = sw->overflow_count;
    pthread_mutex_unlock(&sw->lock);
    return count;
}

size_t crdpq_icon_store_live_count(const crdpq_icon_store_t* s) {
    if (!s) return 0;
    crdpq_icon_store_t* sw = (crdpq_icon_store_t*)s;
    pthread_mutex_lock(&sw->lock);
    size_t count = 0;
    for (size_t i = 0; i < CRDPQ_ICON_SLOTS; i++) {
        if (sw->slots[i].inUse) count++;
    }
    pthread_mutex_unlock(&sw->lock);
    return count;
}
