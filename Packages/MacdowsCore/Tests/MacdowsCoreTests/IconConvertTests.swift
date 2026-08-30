import CRDPQueue
import Darwin
import Foundation
import Testing

/// adr/0013 §2's offline acceptance surface: `crdpq_icon_convert` is a pure C function with
/// no FreeRDP/AppKit dependency precisely so the whole DIB decode matrix can be fed synthetic
/// bitmaps and asserted byte-for-byte from here, with no Windows host and no display — the
/// same `import CRDPQueue` precedent `CRDPQueueTests`/`CRDPQueueHardeningTests` already set
/// for this package's C target.
///
/// Every expected-byte value in this file is derived from the layout facts recorded on
/// `crdpq_icon_convert`'s own doc comment (crdpq.h), each of which was checked against
/// ThirdParty/FreeRDP's parser (`libfreerdp/core/window.c`) and converter
/// (`libfreerdp/codec/color.c`) rather than taken from the ADR draft.

// MARK: - Synthetic DIB helpers

/// Lays out `rows` — given TOP-DOWN, row 0 being the icon's top edge — as a bottom-up DIB
/// plane with each scanline padded out to `stride` bytes. This is the inverse of what
/// `crdpq_icon_convert` does, so a test can state its bitmap the way a human reads it.
private func dibPlane(rows: [[UInt8]], stride: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(stride * rows.count)
    for row in rows.reversed() {
        precondition(row.count <= stride, "row payload exceeds the requested stride")
        out.append(contentsOf: row)
        out.append(contentsOf: [UInt8](repeating: 0, count: stride - row.count))
    }
    return out
}

/// DIB scanline stride: payload bytes rounded up to a 4-byte boundary.
private func paddedStride(_ rowBytes: Int) -> Int { (rowBytes + 3) & ~3 }

/// One DIB `RGBQUAD` palette entry — B, G, R, X in memory, the order FreeRDP's own
/// `fill_gdi_palette_for_icon` reads via `PIXEL_FORMAT_BGRX32`.
private func rgbquad(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] { [b, g, r, 0] }

/// A byte buffer positioned so its LAST byte sits immediately before a `PROT_NONE` guard
/// page. Any read past `count` faults the process outright, which turns "must never read out
/// of bounds even on malicious field values" from a code-review claim into an executable one:
/// the rejection tests below hand `crdpq_icon_convert` deliberately inconsistent `cb*` values
/// alongside a buffer that really is only `cb` bytes long, so a converter that trusted
/// `width`/`height`/`bpp` over `cb*` would crash here rather than quietly reading someone
/// else's heap.
private final class GuardedBuffer {
    private let region: UnsafeMutableRawPointer
    private let regionSize: Int
    let pointer: UnsafePointer<UInt8>
    let count: Int

    init(_ bytes: [UInt8]) {
        precondition(!bytes.isEmpty, "a zero-length guarded buffer has no meaningful placement")
        let pageSize = Int(getpagesize())
        let dataPages = (bytes.count + pageSize - 1) / pageSize
        regionSize = (dataPages + 1) * pageSize
        let mapped = mmap(nil, regionSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(mapped != MAP_FAILED, "mmap failed")
        let base = mapped!
        let guardPage = base.advanced(by: dataPages * pageSize)
        precondition(mprotect(guardPage, pageSize, PROT_NONE) == 0, "mprotect failed")
        // Right-align the payload against the guard page so byte `count` is the first
        // unreadable address, not merely "somewhere past the data".
        let offset = dataPages * pageSize - bytes.count
        bytes.withUnsafeBytes { src in
            base.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: bytes.count)
        }
        region = base
        pointer = UnsafePointer(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
        count = bytes.count
    }

    deinit { munmap(region, regionSize) }
}

/// Runs `crdpq_icon_convert` against caller-supplied planes and hands back the result code
/// plus the destination bytes (always the full `width * height * 4`, so a failing call's
/// untouched buffer is observable too).
@discardableResult
private func convert(
    bpp: UInt32,
    width: UInt32,
    height: UInt32,
    bitsColor: [UInt8],
    colorTable: [UInt8] = [],
    bitsMask: [UInt8] = [],
    cbBitsColorOverride: UInt32? = nil,
    cbColorTableOverride: UInt32? = nil,
    cbBitsMaskOverride: UInt32? = nil,
    dstCapacityOverride: Int? = nil,
    into out: inout [UInt8]
) -> crdpq_icon_convert_result_t {
    let capacity = dstCapacityOverride ?? Int(width) * Int(height) * 4
    out = [UInt8](repeating: 0xCD, count: max(capacity, 1))
    let colorBuf = GuardedBuffer(bitsColor.isEmpty ? [0] : bitsColor)
    let paletteBuf = colorTable.isEmpty ? nil : GuardedBuffer(colorTable)
    let maskBuf = bitsMask.isEmpty ? nil : GuardedBuffer(bitsMask)
    return out.withUnsafeMutableBufferPointer { dst in
        crdpq_icon_convert(
            bpp, width, height,
            cbColorTableOverride ?? UInt32(colorTable.count),
            cbBitsMaskOverride ?? UInt32(bitsMask.count),
            cbBitsColorOverride ?? UInt32(bitsColor.count),
            bitsColor.isEmpty ? nil : colorBuf.pointer,
            paletteBuf?.pointer,
            maskBuf?.pointer,
            dst.baseAddress, capacity
        )
    }
}

/// The four bytes of output pixel `(x, y)`, in the R,G,B,A address order
/// `crdpq_icon_convert` writes.
private func pixel(_ rgba: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
    let base = (y * width + x) * 4
    return Array(rgba[base..<(base + 4)])
}

// MARK: - Per-bpp conversion matrix

@Suite("crdpq_icon_convert / bit depths")
struct IconConvertBitDepthTests {
    @Test("32bpp: source bytes are B,G,R,A and the source alpha is honored (premultiplied)")
    func bgra32UsesSourceAlpha() {
        // Top row: opaque red, then half-transparent white. Bottom row: opaque green, blue.
        let rows: [[UInt8]] = [
            [/* B,G,R,A */ 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x80],
            [0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF],
        ]
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: 2, height: 2, bitsColor: dibPlane(rows: rows, stride: 8), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0xFF, 0x00, 0x00, 0xFF])
        // 0xFF premultiplied by 0x80: (255 * 128 + 127) / 255 == 128.
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0x80, 0x80, 0x80, 0x80])
        #expect(pixel(out, x: 0, y: 1, width: 2) == [0x00, 0xFF, 0x00, 0xFF])
        #expect(pixel(out, x: 1, y: 1, width: 2) == [0x00, 0x00, 0xFF, 0xFF])
    }

    @Test("32bpp: an all-zero alpha plane falls back to the AND mask (adr/0013 §2 heuristic)")
    func bgra32AllZeroAlphaFallsBackToMask() {
        // Every source alpha byte is 0 — trusting it verbatim would render nothing at all.
        let rows: [[UInt8]] = [
            [0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00],
            [0xFF, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x00],
        ]
        // AND mask, MSB-first: set bit == transparent. Top row masks out pixel 1, bottom
        // row masks out pixel 0. Mask scanlines are 4-byte aligned.
        let mask = dibPlane(rows: [[0b0100_0000], [0b1000_0000]], stride: 4)
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: 2, height: 2, bitsColor: dibPlane(rows: rows, stride: 8), bitsMask: mask, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0xFF, 0x00, 0x00, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0x00, 0x00, 0x00, 0x00])
        #expect(pixel(out, x: 0, y: 1, width: 2) == [0x00, 0x00, 0x00, 0x00])
        #expect(pixel(out, x: 1, y: 1, width: 2) == [0x33, 0x22, 0x11, 0xFF])
    }

    @Test("32bpp: an all-zero alpha plane with no mask at all becomes fully opaque")
    func bgra32AllZeroAlphaNoMaskIsOpaque() {
        let rows: [[UInt8]] = [[0x10, 0x20, 0x30, 0x00]]
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: 1, height: 1, bitsColor: dibPlane(rows: rows, stride: 4), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 1) == [0x30, 0x20, 0x10, 0xFF])
    }

    @Test("24bpp: source bytes are B,G,R (DIB RGBTRIPLE order), opaque without a mask")
    func bgr24ByteOrder() {
        let rows: [[UInt8]] = [
            [/* B,G,R */ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
            [0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C],
        ]
        var out: [UInt8] = []
        let rc = convert(bpp: 24, width: 2, height: 2, bitsColor: dibPlane(rows: rows, stride: 8), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0x03, 0x02, 0x01, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0x06, 0x05, 0x04, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 2) == [0x09, 0x08, 0x07, 0xFF])
        #expect(pixel(out, x: 1, y: 1, width: 2) == [0x0C, 0x0B, 0x0A, 0xFF])
    }

    @Test("16bpp: little-endian RGB555 (not RGB565), 5->8 expansion replicating the high bits")
    func rgb555Unpacking() {
        // 0x7C00 = pure red, 0x03E0 = pure green, 0x001F = pure blue, 0x0000 = black.
        let rows: [[UInt8]] = [
            [0x00, 0x7C, 0xE0, 0x03],
            [0x1F, 0x00, 0x00, 0x00],
        ]
        var out: [UInt8] = []
        let rc = convert(bpp: 16, width: 2, height: 2, bitsColor: dibPlane(rows: rows, stride: 4), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0xFF, 0x00, 0x00, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0x00, 0xFF, 0x00, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 2) == [0x00, 0x00, 0xFF, 0xFF])
        #expect(pixel(out, x: 1, y: 1, width: 2) == [0x00, 0x00, 0x00, 0xFF])
    }

    @Test("16bpp: a mid-range 5-bit channel expands as (c << 3) | (c >> 2), matching FreeRDP")
    func rgb555MidRangeExpansion() {
        // r = 5, g = 17, b = 30  ->  0b0_00101_10001_11110 = 0x163E, stored little-endian.
        let rows: [[UInt8]] = [[0x3E, 0x16]]
        var out: [UInt8] = []
        let rc = convert(bpp: 16, width: 1, height: 1, bitsColor: dibPlane(rows: rows, stride: 4), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        // (5 << 3) | (5 >> 2) = 41; (17 << 3) | (17 >> 2) = 140; (30 << 3) | (30 >> 2) = 247.
        #expect(pixel(out, x: 0, y: 0, width: 1) == [41, 140, 247, 0xFF])
    }

    @Test("8bpp: palette lookup reads RGBQUAD entries as B,G,R,X")
    func palette8bpp() {
        let palette = rgbquad(r: 0x11, g: 0x22, b: 0x33)
            + rgbquad(r: 0xAA, g: 0xBB, b: 0xCC)
            + rgbquad(r: 0x00, g: 0x00, b: 0x00)
        let rows: [[UInt8]] = [[0, 1], [2, 1]]
        var out: [UInt8] = []
        let rc = convert(bpp: 8, width: 2, height: 2, bitsColor: dibPlane(rows: rows, stride: 4), colorTable: palette, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0x11, 0x22, 0x33, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0xAA, 0xBB, 0xCC, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 2) == [0x00, 0x00, 0x00, 0xFF])
        #expect(pixel(out, x: 1, y: 1, width: 2) == [0xAA, 0xBB, 0xCC, 0xFF])
    }

    @Test("4bpp: the HIGH nibble is the left pixel, and scanlines pad to 4 bytes")
    func palette4bpp() {
        let palette = rgbquad(r: 0, g: 0, b: 0)
            + rgbquad(r: 0xFF, g: 0, b: 0)
            + rgbquad(r: 0, g: 0xFF, b: 0)
            + rgbquad(r: 0, g: 0, b: 0xFF)
        // Width 3 -> 2 payload bytes per row, padded to a 4-byte stride. Top row indices
        // 1,2,3; bottom row 3,2,1. The trailing low nibble of byte 1 is unused padding.
        let rows: [[UInt8]] = [[0x12, 0x30], [0x32, 0x10]]
        var out: [UInt8] = []
        let rc = convert(bpp: 4, width: 3, height: 2, bitsColor: dibPlane(rows: rows, stride: paddedStride(2)), colorTable: palette, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 3) == [0xFF, 0x00, 0x00, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 3) == [0x00, 0xFF, 0x00, 0xFF])
        #expect(pixel(out, x: 2, y: 0, width: 3) == [0x00, 0x00, 0xFF, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 3) == [0x00, 0x00, 0xFF, 0xFF])
        #expect(pixel(out, x: 1, y: 1, width: 3) == [0x00, 0xFF, 0x00, 0xFF])
        #expect(pixel(out, x: 2, y: 1, width: 3) == [0xFF, 0x00, 0x00, 0xFF])
    }

    @Test("1bpp: MSB-first bit order against a two-entry palette, 4-byte-padded scanlines")
    func palette1bpp() {
        let palette = rgbquad(r: 0x10, g: 0x20, b: 0x30) + rgbquad(r: 0x40, g: 0x50, b: 0x60)
        // Width 9 -> 2 payload bytes per row, padded to 4. Top row: 1,0,1,0,0,0,0,0, then 1.
        let rows: [[UInt8]] = [[0b1010_0000, 0b1000_0000], [0b0101_0000, 0b0000_0000]]
        var out: [UInt8] = []
        let rc = convert(bpp: 1, width: 9, height: 2, bitsColor: dibPlane(rows: rows, stride: paddedStride(2)), colorTable: palette, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        let one: [UInt8] = [0x40, 0x50, 0x60, 0xFF]
        let zero: [UInt8] = [0x10, 0x20, 0x30, 0xFF]
        #expect(pixel(out, x: 0, y: 0, width: 9) == one)
        #expect(pixel(out, x: 1, y: 0, width: 9) == zero)
        #expect(pixel(out, x: 2, y: 0, width: 9) == one)
        #expect(pixel(out, x: 8, y: 0, width: 9) == one)
        #expect(pixel(out, x: 0, y: 1, width: 9) == zero)
        #expect(pixel(out, x: 1, y: 1, width: 9) == one)
        #expect(pixel(out, x: 8, y: 1, width: 9) == zero)
    }
}

// MARK: - Layout: row order, stride, mask

@Suite("crdpq_icon_convert / DIB layout")
struct IconConvertLayoutTests {
    @Test("rows are bottom-up: output row 0 is the LAST scanline in the source plane")
    func bottomUpRowOrder() {
        // Four distinguishable 8bpp rows, stated top-down; the source plane stores them
        // reversed, and the converter must undo that.
        let palette = (0..<4).flatMap { rgbquad(r: UInt8($0 * 16), g: 0, b: 0) }
        let rows: [[UInt8]] = [[0], [1], [2], [3]]
        var out: [UInt8] = []
        let rc = convert(bpp: 8, width: 1, height: 4, bitsColor: dibPlane(rows: rows, stride: 4), colorTable: palette, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        for y in 0..<4 {
            #expect(pixel(out, x: 0, y: y, width: 1) == [UInt8(y * 16), 0x00, 0x00, 0xFF])
        }
    }

    @Test("scanline padding: a 4-byte-aligned stride is used when cbBitsColor allows it")
    func paddedScanlineStride() {
        // 24bpp, width 6 -> 18 payload bytes per row, padded to a 20-byte stride. Reading
        // this at the unpadded 18 would shift every row after the first by 2 bytes.
        let rows: [[UInt8]] = [
            Array(repeating: 0, count: 15) + [0x01, 0x02, 0x03],
            [0x04, 0x05, 0x06] + Array(repeating: 0, count: 15),
        ]
        var out: [UInt8] = []
        let plane = dibPlane(rows: rows, stride: paddedStride(18))
        #expect(plane.count == 40)
        let rc = convert(bpp: 24, width: 6, height: 2, bitsColor: plane, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 5, y: 0, width: 6) == [0x03, 0x02, 0x01, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 6) == [0x06, 0x05, 0x04, 0xFF])
    }

    @Test("scanline padding: an unpadded plane is decoded at the tight stride instead")
    func unpaddedScanlineStrideFallback() {
        // Same 24bpp/width-6 geometry, but the server sent tightly-packed 18-byte rows.
        // FreeRDP's own icon path assumes exactly this (nSrcStep 0 -> width * bytesPerPixel),
        // so both readings have to work — see crdpq_icon_convert's doc comment.
        let rows: [[UInt8]] = [
            Array(repeating: 0, count: 15) + [0x01, 0x02, 0x03],
            [0x04, 0x05, 0x06] + Array(repeating: 0, count: 15),
        ]
        var out: [UInt8] = []
        let plane = dibPlane(rows: rows, stride: 18)
        #expect(plane.count == 36)
        let rc = convert(bpp: 24, width: 6, height: 2, bitsColor: plane, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 5, y: 0, width: 6) == [0x03, 0x02, 0x01, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 6) == [0x06, 0x05, 0x04, 0xFF])
    }

    @Test("mask-driven alpha for <=24bpp: a set AND-mask bit means transparent")
    func maskDrivenAlpha() {
        let palette = rgbquad(r: 0xFF, g: 0xFF, b: 0xFF) + rgbquad(r: 0x80, g: 0x40, b: 0x20)
        let rows: [[UInt8]] = [[1, 1, 1, 1], [1, 1, 1, 1]]
        // Top row: pixels 1 and 3 masked out. Bottom row: pixel 0 masked out.
        let mask = dibPlane(rows: [[0b0101_0000], [0b1000_0000]], stride: 4)
        var out: [UInt8] = []
        let rc = convert(bpp: 8, width: 4, height: 2, bitsColor: dibPlane(rows: rows, stride: 4), colorTable: palette, bitsMask: mask, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        let opaque: [UInt8] = [0x80, 0x40, 0x20, 0xFF]
        let clear: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        #expect(pixel(out, x: 0, y: 0, width: 4) == opaque)
        #expect(pixel(out, x: 1, y: 0, width: 4) == clear)
        #expect(pixel(out, x: 2, y: 0, width: 4) == opaque)
        #expect(pixel(out, x: 3, y: 0, width: 4) == clear)
        #expect(pixel(out, x: 0, y: 1, width: 4) == clear)
        #expect(pixel(out, x: 1, y: 1, width: 4) == opaque)
    }

    @Test("the AND mask is bottom-up too, on its own 4-byte-aligned stride")
    func maskIsBottomUpAndPadded() {
        let palette = rgbquad(r: 0xFF, g: 0xFF, b: 0xFF) + rgbquad(r: 0x11, g: 0x11, b: 0x11)
        let rows: [[UInt8]] = [[1], [1], [1]]
        // Only the MIDDLE row is masked out; a converter that read the mask top-down would
        // still pass, so the outer rows differ from each other in the color plane too.
        let mask = dibPlane(rows: [[0b0000_0000], [0b1000_0000], [0b0000_0000]], stride: 4)
        #expect(mask.count == 12)
        var out: [UInt8] = []
        let rc = convert(bpp: 8, width: 1, height: 3, bitsColor: dibPlane(rows: rows, stride: 4), colorTable: palette, bitsMask: mask, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 1) == [0x11, 0x11, 0x11, 0xFF])
        #expect(pixel(out, x: 0, y: 1, width: 1) == [0x00, 0x00, 0x00, 0x00])
        #expect(pixel(out, x: 0, y: 2, width: 1) == [0x11, 0x11, 0x11, 0xFF])
    }

    @Test("a 48x48 32bpp icon — the largest shape this contract accepts — converts")
    func maxDimensionAccepted() {
        let dim = Int(CRDPQ_ICON_MAX_DIM)
        let rows = (0..<dim).map { y -> [UInt8] in
            (0..<dim).flatMap { x -> [UInt8] in [UInt8(x * 5 % 256), UInt8(y * 5 % 256), 0x7F, 0xFF] }
        }
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: UInt32(dim), height: UInt32(dim), bitsColor: dibPlane(rows: rows, stride: dim * 4), into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(out.count == dim * dim * 4)
        #expect(pixel(out, x: 0, y: 0, width: dim) == [0x7F, 0x00, 0x00, 0xFF])
        #expect(pixel(out, x: dim - 1, y: dim - 1, width: dim) == [0x7F, UInt8((dim - 1) * 5 % 256), UInt8((dim - 1) * 5 % 256), 0xFF])
    }
}

// MARK: - Rejection matrix (every one of these must also not overread)

@Suite("crdpq_icon_convert / rejections")
struct IconConvertRejectionTests {
    @Test("oversize dimensions are rejected rather than downscaled", arguments: [
        (UInt32(CRDPQ_ICON_MAX_DIM) + 1, UInt32(1)),
        (UInt32(1), UInt32(CRDPQ_ICON_MAX_DIM) + 1),
        (UInt32(1024), UInt32(1024)),
    ])
    func oversizeRejected(width: UInt32, height: UInt32) {
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: width, height: height, bitsColor: [UInt8](repeating: 0, count: 16), into: &out)
        #expect(rc == CRDPQ_ICON_ERR_DIMENSIONS)
    }

    @Test("zero dimensions are rejected", arguments: [(UInt32(0), UInt32(4)), (UInt32(4), UInt32(0))])
    func zeroDimensionsRejected(width: UInt32, height: UInt32) {
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: width, height: height, bitsColor: [UInt8](repeating: 0, count: 16), into: &out)
        #expect(rc == CRDPQ_ICON_ERR_DIMENSIONS)
    }

    @Test("unsupported bpp is rejected — FreeRDP's parser only bounds it to 1...32", arguments: [
        UInt32(0), UInt32(2), UInt32(3), UInt32(15), UInt32(31), UInt32(33), UInt32(0xFFFF_FFFF),
    ])
    func unsupportedBppRejected(bpp: UInt32) {
        var out: [UInt8] = []
        let rc = convert(bpp: bpp, width: 2, height: 2, bitsColor: [UInt8](repeating: 0, count: 64), colorTable: rgbquad(r: 0, g: 0, b: 0), into: &out)
        #expect(rc == CRDPQ_ICON_ERR_BPP)
    }

    @Test("cbBitsColor short of what bpp/width/height require is rejected, without overreading")
    func shortColorPlaneRejected() {
        // A 16x16 32bpp icon needs 1024 bytes; hand over 512 in a guard-page-backed buffer.
        // An implementation trusting width/height over cbBitsColor faults instead of failing.
        var out: [UInt8] = []
        let rc = convert(bpp: 32, width: 16, height: 16, bitsColor: [UInt8](repeating: 0x7F, count: 512), into: &out)
        #expect(rc == CRDPQ_ICON_ERR_BITS_COLOR)
    }

    @Test("cbBitsColor lying ABOUT a buffer smaller than itself still can't push a read past the real bytes")
    func lyingCbBitsColorRejected() {
        // The classic malicious shape: `cb*` claims plenty, the stream held little. FreeRDP's
        // parser guarantees the buffer really is cbBitsColor bytes, so the honest test of
        // this converter is the reverse — a cb that is genuinely too small for the declared
        // geometry, checked before any pixel is touched.
        var out: [UInt8] = []
        let plane = [UInt8](repeating: 0xAB, count: 4)
        let rc = convert(bpp: 24, width: 8, height: 8, bitsColor: plane, cbBitsColorOverride: 4, into: &out)
        #expect(rc == CRDPQ_ICON_ERR_BITS_COLOR)
        // The destination was never written: still the 0xCD fill.
        #expect(out.allSatisfy { $0 == 0xCD })
    }

    @Test("a declared-non-empty mask too short for height rows is rejected, without overreading")
    func shortMaskRejected() {
        let palette = rgbquad(r: 0, g: 0, b: 0) + rgbquad(r: 0xFF, g: 0xFF, b: 0xFF)
        // 16 rows at a 4-byte mask stride need 4 * 15 + 2 = 62 bytes; supply 8.
        var out: [UInt8] = []
        let rc = convert(
            bpp: 8, width: 16, height: 16,
            bitsColor: [UInt8](repeating: 1, count: 16 * 16),
            colorTable: palette,
            bitsMask: [UInt8](repeating: 0, count: 8),
            into: &out
        )
        #expect(rc == CRDPQ_ICON_ERR_BITS_MASK)
    }

    @Test("cbBitsMask non-zero with a NULL mask pointer is rejected")
    func nonZeroMaskLengthWithNoBufferRejected() {
        var out: [UInt8] = []
        let rc = convert(
            bpp: 32, width: 4, height: 4,
            bitsColor: [UInt8](repeating: 0xFF, count: 64),
            cbBitsMaskOverride: 64,
            into: &out
        )
        #expect(rc == CRDPQ_ICON_ERR_BITS_MASK)
    }

    @Test("indexed bpp with a missing or malformed palette is rejected", arguments: [
        // cbColorTable == 0 (no palette at all for an indexed bitmap)
        (UInt32(0), 4),
        // not a multiple of RGBQUAD's 4 bytes
        (UInt32(6), 8),
        // more than 256 entries — the same ceiling FreeRDP's fill_gdi_palette_for_icon uses
        (UInt32(1028), 1028),
    ])
    func malformedPaletteRejected(cbColorTable: UInt32, tableBytes: Int) {
        var out: [UInt8] = []
        let rc = convert(
            bpp: 8, width: 2, height: 2,
            bitsColor: [UInt8](repeating: 0, count: 16),
            colorTable: [UInt8](repeating: 0, count: tableBytes),
            cbColorTableOverride: cbColorTable,
            into: &out
        )
        #expect(rc == CRDPQ_ICON_ERR_COLOR_TABLE)
    }

    @Test("a palette index past the table's end becomes a transparent pixel, not an overread")
    func shortPaletteIndexIsTransparent() {
        // Two-entry palette, but the bitmap references index 7.
        let palette = rgbquad(r: 0x11, g: 0x22, b: 0x33) + rgbquad(r: 0x44, g: 0x55, b: 0x66)
        let rows: [[UInt8]] = [[0, 7]]
        var out: [UInt8] = []
        let rc = convert(bpp: 8, width: 2, height: 1, bitsColor: dibPlane(rows: rows, stride: 4), colorTable: palette, into: &out)
        #expect(rc == CRDPQ_ICON_OK)
        #expect(pixel(out, x: 0, y: 0, width: 2) == [0x11, 0x22, 0x33, 0xFF])
        #expect(pixel(out, x: 1, y: 0, width: 2) == [0x00, 0x00, 0x00, 0x00])
    }

    @Test("a destination smaller than width * height * 4 is rejected")
    func undersizedDestinationRejected() {
        var out: [UInt8] = []
        let rc = convert(
            bpp: 32, width: 4, height: 4,
            bitsColor: [UInt8](repeating: 0xFF, count: 64),
            dstCapacityOverride: 63,
            into: &out
        )
        #expect(rc == CRDPQ_ICON_ERR_DEST)
    }
}

// MARK: - Icon store

@Suite("crdpq_icon_store")
struct IconStoreTests {
    /// Runs `body` against a freshly created store, destroying it afterwards even if an
    /// expectation fails.
    private func withStore(_ body: (OpaquePointer) throws -> Void) rethrows {
        let store = crdpq_icon_store_create()
        #expect(store != nil)
        guard let store else { return }
        defer { crdpq_icon_store_destroy(store) }
        try body(store)
    }

    /// A solid-color 2x2 RGBA block, so a copy-out can be told apart by its first byte.
    private func block(_ marker: UInt8) -> [UInt8] { [UInt8](repeating: marker, count: 2 * 2 * 4) }

    private func put(_ store: OpaquePointer, windowId: UInt32, notifyIconId: UInt32, marker: UInt8) -> (ok: Bool, slot: UInt8) {
        var slot: UInt8 = 0xFF
        let ok = block(marker).withUnsafeBufferPointer {
            crdpq_icon_store_put(store, windowId, notifyIconId, $0.baseAddress, 2, 2, &slot)
        }
        return (ok, slot)
    }

    @Test("upsert by key: a second put for the same key overwrites in place, consuming no second slot")
    func upsertByKey() {
        withStore { store in
            let first = put(store, windowId: 7, notifyIconId: 1, marker: 0xA1)
            #expect(first.ok)
            #expect(crdpq_icon_store_live_count(store) == 1)

            let second = put(store, windowId: 7, notifyIconId: 1, marker: 0xB2)
            #expect(second.ok)
            #expect(second.slot == first.slot)
            #expect(crdpq_icon_store_live_count(store) == 1)

            var dst = [UInt8](repeating: 0, count: 16)
            var w: UInt32 = 0
            var h: UInt32 = 0
            var bytes = 0
            let copied = dst.withUnsafeMutableBufferPointer {
                crdpq_icon_store_copy_slot(store, second.slot, 7, 1, $0.baseAddress, 16, &w, &h, &bytes)
            }
            #expect(copied)
            #expect(w == 2 && h == 2 && bytes == 16)
            #expect(dst.allSatisfy { $0 == 0xB2 })
        }
    }

    @Test("distinct keys take distinct slots, and a delete frees one for reuse")
    func deleteFreesSlotForReuse() {
        withStore { store in
            let a = put(store, windowId: 1, notifyIconId: 1, marker: 0x01)
            let b = put(store, windowId: 1, notifyIconId: 2, marker: 0x02)
            #expect(a.ok && b.ok)
            #expect(a.slot != b.slot)
            #expect(crdpq_icon_store_live_count(store) == 2)

            #expect(crdpq_icon_store_remove(store, 1, 1))
            #expect(crdpq_icon_store_live_count(store) == 1)
            // An unknown delete is tolerated, exactly like TrayModel.delete's own tolerance.
            #expect(!crdpq_icon_store_remove(store, 1, 1))
            #expect(!crdpq_icon_store_remove(store, 99, 99))

            let c = put(store, windowId: 1, notifyIconId: 3, marker: 0x03)
            #expect(c.ok)
            #expect(c.slot == a.slot)
            #expect(crdpq_icon_store_live_count(store) == 2)
        }
    }

    @Test("lookup finds a live key's slot and misses a deleted one")
    func lookupTracksLiveness() {
        withStore { store in
            let a = put(store, windowId: 4, notifyIconId: 9, marker: 0x55)
            #expect(a.ok)
            var slot: UInt8 = 0xFF
            #expect(crdpq_icon_store_lookup(store, 4, 9, &slot))
            #expect(slot == a.slot)
            #expect(!crdpq_icon_store_lookup(store, 4, 10, &slot))
            #expect(crdpq_icon_store_remove(store, 4, 9))
            #expect(!crdpq_icon_store_lookup(store, 4, 9, &slot))
        }
    }

    @Test("slot exhaustion fails open: the put is refused and the overflow counter records it")
    func slotExhaustionIsCountedNotFatal() {
        withStore { store in
            for i in 0..<UInt32(CRDPQ_ICON_SLOTS) {
                #expect(put(store, windowId: 1, notifyIconId: i, marker: UInt8(i)).ok)
            }
            #expect(crdpq_icon_store_live_count(store) == Int(CRDPQ_ICON_SLOTS))
            #expect(crdpq_icon_store_overflow_count(store) == 0)

            let overflowed = put(store, windowId: 1, notifyIconId: 9999, marker: 0xFF)
            #expect(!overflowed.ok)
            #expect(crdpq_icon_store_overflow_count(store) == 1)
            #expect(crdpq_icon_store_live_count(store) == Int(CRDPQ_ICON_SLOTS))

            // An UPDATE for a key already holding a slot still succeeds while full — a live
            // tray icon must not stop updating just because the table is at capacity.
            #expect(put(store, windowId: 1, notifyIconId: 0, marker: 0xEE).ok)
            #expect(crdpq_icon_store_overflow_count(store) == 1)
        }
    }

    @Test("copy_slot refuses a slot whose key was reclaimed by a different icon (drain-time race)")
    func copySlotChecksKey() {
        withStore { store in
            let a = put(store, windowId: 1, notifyIconId: 1, marker: 0xAA)
            #expect(a.ok)
            #expect(crdpq_icon_store_remove(store, 1, 1))
            let b = put(store, windowId: 2, notifyIconId: 2, marker: 0xBB)
            #expect(b.ok)
            #expect(b.slot == a.slot)

            var dst = [UInt8](repeating: 0, count: 16)
            var w: UInt32 = 0
            var h: UInt32 = 0
            var bytes = 0
            // The stale (windowId 1, notifyIconId 1) event's reference must NOT resolve to
            // icon B's pixels.
            let stale = dst.withUnsafeMutableBufferPointer {
                crdpq_icon_store_copy_slot(store, a.slot, 1, 1, $0.baseAddress, 16, &w, &h, &bytes)
            }
            #expect(!stale)
            #expect(dst.allSatisfy { $0 == 0 })

            let live = dst.withUnsafeMutableBufferPointer {
                crdpq_icon_store_copy_slot(store, b.slot, 2, 2, $0.baseAddress, 16, &w, &h, &bytes)
            }
            #expect(live)
            #expect(dst.allSatisfy { $0 == 0xBB })
        }
    }

    @Test("copy_slot refuses an out-of-range slot, a free slot, and an undersized destination")
    func copySlotBounds() {
        withStore { store in
            let a = put(store, windowId: 3, notifyIconId: 3, marker: 0x77)
            #expect(a.ok)
            var dst = [UInt8](repeating: 0, count: 16)
            var w: UInt32 = 0
            var h: UInt32 = 0
            var bytes = 0
            dst.withUnsafeMutableBufferPointer { buf in
                #expect(!crdpq_icon_store_copy_slot(store, UInt8(CRDPQ_ICON_SLOTS), 3, 3, buf.baseAddress, 16, &w, &h, &bytes))
                #expect(!crdpq_icon_store_copy_slot(store, 255, 3, 3, buf.baseAddress, 16, &w, &h, &bytes))
                // Correct slot and key, but the destination is one byte short of the 16 the
                // 2x2 RGBA slot needs.
                #expect(!crdpq_icon_store_copy_slot(store, a.slot, 3, 3, buf.baseAddress, 15, &w, &h, &bytes))
                #expect(crdpq_icon_store_copy_slot(store, a.slot, 3, 3, buf.baseAddress, 16, &w, &h, &bytes))
            }
        }
    }

    @Test("put rejects dimensions the fixed slot buffer can't hold")
    func putRejectsOversizeDimensions() {
        withStore { store in
            var slot: UInt8 = 0xFF
            let pixels = [UInt8](repeating: 0, count: 16)
            pixels.withUnsafeBufferPointer { buf in
                #expect(!crdpq_icon_store_put(store, 1, 1, buf.baseAddress, UInt32(CRDPQ_ICON_MAX_DIM) + 1, 2, &slot))
                #expect(!crdpq_icon_store_put(store, 1, 1, buf.baseAddress, 2, 0, &slot))
                #expect(!crdpq_icon_store_put(store, 1, 1, buf.baseAddress, 0, 2, &slot))
            }
            #expect(crdpq_icon_store_live_count(store) == 0)
        }
    }

    @Test("clear releases every slot but deliberately preserves the cumulative overflow count")
    func clearKeepsOverflowCount() {
        withStore { store in
            for i in 0..<UInt32(CRDPQ_ICON_SLOTS) {
                #expect(put(store, windowId: 1, notifyIconId: i, marker: UInt8(i)).ok)
            }
            #expect(!put(store, windowId: 1, notifyIconId: 500, marker: 0x00).ok)
            #expect(crdpq_icon_store_overflow_count(store) == 1)

            crdpq_icon_store_clear(store)
            #expect(crdpq_icon_store_live_count(store) == 0)
            #expect(crdpq_icon_store_overflow_count(store) == 1)

            // And the table is genuinely reusable afterwards.
            #expect(put(store, windowId: 2, notifyIconId: 1, marker: 0x42).ok)
            #expect(crdpq_icon_store_live_count(store) == 1)
        }
    }
}

// MARK: - POD contract

@Suite("crdpq_notify_icon_t POD contract")
struct NotifyIconPayloadTests {
    @Test("adr/0013 §1: the grown notify-icon payload stays well under the union's largest member")
    func notifyIconStaysSmallerThanWindowOrder() {
        // 276 after the R1-finding-3 iconCached append (was 272; crdpq.h's own assert
        // comment carries the arithmetic).
        #expect(MemoryLayout<crdpq_notify_icon_t>.size == 276)
        #expect(MemoryLayout<crdpq_window_order_t>.size == 572)
        #expect(MemoryLayout<crdpq_event_payload_t>.size == 576)
        #expect(MemoryLayout<CrdpEvent>.size == 584)
    }

    @Test("the appended fields survive a post/drain round trip unmodified")
    func appendedFieldsRoundTrip() {
        let queue = crdpq_control_create(nil, nil)
        #expect(queue != nil)
        guard let queue else { return }
        defer { crdpq_control_destroy(queue) }

        var ev = CrdpEvent()
        ev.type = CRDPQ_EVENT_NOTIFY_ICON_CREATE
        ev.payload.notifyIcon.windowId = 0x1234_5678
        ev.payload.notifyIcon.notifyIconId = 42
        ev.payload.notifyIcon.hasIconSlot = 1
        ev.payload.notifyIcon.iconSlot = 9
        ev.payload.notifyIcon.iconSkipped = 0
        ev.payload.notifyIcon.iconCached = 1
        ev.payload.notifyIcon.toolTipPresent = 1
        let tip = "Remote tray icon"
        tip.withCString { c in
            crdpq_text_set(&ev.payload.notifyIcon.toolTip, c, strlen(c))
        }
        #expect(crdpq_post(queue, &ev))

        final class Sink: @unchecked Sendable {
            var seen: crdpq_notify_icon_t?
        }
        let sink = Sink()
        let delivered = withExtendedLifetime(sink) {
            crdpq_drain(queue, { ev, ctx in
                let sink = Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue()
                sink.seen = ev!.pointee.payload.notifyIcon
            }, Unmanaged.passUnretained(sink).toOpaque())
        }
        #expect(delivered == 1)
        let seen = try! #require(sink.seen)
        #expect(seen.windowId == 0x1234_5678)
        #expect(seen.notifyIconId == 42)
        #expect(seen.hasIconSlot == 1)
        #expect(seen.iconSlot == 9)
        #expect(seen.iconSkipped == 0)
        #expect(seen.iconCached == 1)
        #expect(seen.toolTipPresent == 1)
        var copy = seen.toolTip
        let text = withUnsafeBytes(of: &copy.bytes) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        #expect(text == tip)
        #expect(copy.length == UInt16(tip.utf8.count))
        #expect(!copy.truncated)
    }
}
