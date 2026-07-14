//! LZ4 block-format compressor and decompressor for 4 KiB pages.
//!
//! Implements the raw LZ4 block format (no frame header). The framing layer
//! (magic, content-size, checksums) is intentionally omitted (compressed pages
//! are stored in kernel-internal swap slots, not written to disk).
//!
//! ## Algorithm summary (LZ4 spec §2)
//! A block is a sequence of *sequences*, each consisting of:
//! ```
//!   [token 1B] [literal-length extensions ...] [literals ...]
//!   [match-offset 2B LE] [match-length extensions ...]
//! ```
//!
//! The last sequence contains only the literal part (no match).
//!
//! ```
//! token high nibble = clamped literal length   (>= 15 -> read extra bytes)
//! token low  nibble = clamped match length - 4 (>= 15 -> read extra bytes;
//!                     minimum match length is 4)
//! ```
//!
//! Match offset is 1-based: offset 1 = the byte immediately before dst cursor.
//!
//! ## Hash table
//! 4-byte rolling hash -> last position where that 4-gram appeared.
//! 12-bit table (4096 entries) gives good speed/memory trade-off for 4 KB input.
//!
//! ## Worst-case output
//! Incompressible 4 KiB -> 4096 + ceil(4096/255) ≈ 4112 bytes.
//! `MAX_COMPRESSED_SIZE` accounts for this.

const std = @import("std");

/// Maximum compressed size for a 4 KiB page (incompressible worst case).
pub const PAGE_SIZE: usize = 4096;
pub const MAX_COMPRESSED_SIZE: usize = PAGE_SIZE + (PAGE_SIZE / 255) + 16;

/// Errors returned by compress / decompress.
pub const Error = error{
    /// Output buffer is too small.
    BufferTooSmall,
    /// Compressed data is malformed.
    CorruptInput,
};

const HASH_BITS: u32 = 12;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_SHIFT: u32 = 32 - HASH_BITS;
const MIN_MATCH: usize = 4;
const LAST_LITERALS: usize = 5; // spec: last 5 bytes must be literals

/// Compress `src` into `dst`. Returns the number of bytes written.
///
/// `dst` must be at least `MAX_COMPRESSED_SIZE` bytes.
pub fn compress(src: []const u8, dst: []u8) Error!usize {
    if (dst.len < MAX_COMPRESSED_SIZE) return error.BufferTooSmall;
    if (src.len == 0) return 0;

    var table = [_]u32{0} ** HASH_SIZE;

    var ip: usize = 0; // input position (cursor)
    var anchor: usize = 0; // start of current literal run
    var op: usize = 0; // output position

    // We need at least MIN_MATCH bytes ahead, plus LAST_LITERALS at the end.
    const limit = if (src.len > LAST_LITERALS) src.len - LAST_LITERALS else 0;

    while (ip < limit) {
        // Hash the 4 bytes at ip.
        const v = readU32(src, ip);
        const h = hash4(v);
        const ref_pos = table[h];
        table[h] = @intCast(ip);

        // Try to find a match.
        const offset = ip -% ref_pos;
        const match_found = offset > 0 and
            offset <= 0xFFFF and
            ref_pos < src.len - MIN_MATCH + 1 and
            readU32(src, ref_pos) == v;

        if (!match_found) {
            ip += 1;
            continue;
        }

        // Extend match forward.
        var match_len: usize = MIN_MATCH;
        while (ip + match_len < src.len - LAST_LITERALS + MIN_MATCH and
            src[ref_pos + match_len] == src[ip + match_len])
        {
            match_len += 1;
        }

        // Emit sequence: [token][lit-ext][literals][offset LE][match-ext]
        const lit_len = ip - anchor;
        op = emitSequence(src, anchor, lit_len, match_len - MIN_MATCH, @intCast(offset), dst, op);

        ip += match_len;
        anchor = ip;
    }

    // Emit final literals (mandatory last-literal block).
    const lit_len = src.len - anchor;
    op = emitLastLiterals(src, anchor, lit_len, dst, op);

    return op;
}

inline fn hash4(v: u32) usize {
    return (v *% 0x9E3779B1) >> @intCast(HASH_SHIFT);
}

inline fn readU32(src: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, src[pos..][0..4], .little);
}

fn emitSequence(
    src: []const u8,
    anchor: usize,
    lit_len: usize,
    match_extra: usize, // match_len - MIN_MATCH
    offset: u16,
    dst: []u8,
    op_in: usize,
) usize {
    var op = op_in;
    const tok_lit: u8 = @intCast(@min(15, lit_len));
    const tok_match: u8 = @intCast(@min(15, match_extra));
    dst[op] = (tok_lit << 4) | tok_match;
    op += 1;

    // Literal length extensions.
    if (lit_len >= 15) {
        var rem = lit_len - 15;
        while (rem >= 255) {
            dst[op] = 255;
            op += 1;
            rem -= 255;
        }
        dst[op] = @intCast(rem);
        op += 1;
    }

    // Literals.
    @memcpy(dst[op..][0..lit_len], src[anchor..][0..lit_len]);
    op += lit_len;

    // Match offset (little-endian 16-bit).
    std.mem.writeInt(u16, dst[op..][0..2], offset, .little);
    op += 2;

    // Match length extensions.
    if (match_extra >= 15) {
        var rem = match_extra - 15;
        while (rem >= 255) {
            dst[op] = 255;
            op += 1;
            rem -= 255;
        }
        dst[op] = @intCast(rem);
        op += 1;
    }

    return op;
}

fn emitLastLiterals(
    src: []const u8,
    anchor: usize,
    lit_len: usize,
    dst: []u8,
    op_in: usize,
) usize {
    var op = op_in;
    const tok_lit: u8 = @intCast(@min(15, lit_len));
    dst[op] = tok_lit << 4; // low nibble 0, so no match
    op += 1;

    if (lit_len >= 15) {
        var rem = lit_len - 15;
        while (rem >= 255) {
            dst[op] = 255;
            op += 1;
            rem -= 255;
        }
        dst[op] = @intCast(rem);
        op += 1;
    }

    @memcpy(dst[op..][0..lit_len], src[anchor..][0..lit_len]);
    op += lit_len;
    return op;
}

/// Decompress `src` into `dst`. Returns the number of bytes written.
///
/// `dst` must be large enough for the original data (for pages: `PAGE_SIZE`).
pub fn decompress(src: []const u8, dst: []u8) Error!usize {
    if (src.len == 0) return 0;

    var ip: usize = 0;
    var op: usize = 0;

    while (ip < src.len) {
        if (ip >= src.len) return error.CorruptInput;
        const token = src[ip];
        ip += 1;

        // Literal length.
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (ip < src.len) {
                const extra = src[ip];
                ip += 1;
                lit_len += extra;
                if (extra != 255) break;
            }
        }

        // Copy literals.
        if (op + lit_len > dst.len) return error.BufferTooSmall;
        if (ip + lit_len > src.len) return error.CorruptInput;
        @memcpy(dst[op..][0..lit_len], src[ip..][0..lit_len]);
        ip += lit_len;
        op += lit_len;

        // End-of-block detection: no match follows after the last literal run.
        if (ip >= src.len) break;

        // Match offset.
        if (ip + 2 > src.len) return error.CorruptInput;
        const offset = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or op < offset) return error.CorruptInput;

        // Match length.
        var match_len: usize = (token & 0x0F) + MIN_MATCH;
        if (match_len - MIN_MATCH == 15) {
            while (ip < src.len) {
                const extra = src[ip];
                ip += 1;
                match_len += extra;
                if (extra != 255) break;
            }
        }

        // Copy match (may overlap, must be byte-by-byte for short offsets).
        if (op + match_len > dst.len) return error.BufferTooSmall;
        const match_start = op - offset;
        for (0..match_len) |i| {
            dst[op + i] = dst[match_start + i];
        }
        op += match_len;
    }

    return op;
}

/// Memory pressure level used by the compressed-page pool.
pub const Pressure = enum {
    /// Plenty of free pages; compression disabled.
    low,
    /// Moderate pressure; compress cold pages opportunistically.
    medium,
    /// Critical; compress aggressively and wake swap daemon.
    high,
};

/// A single compressed-page slot in the pool.
pub const CompressedSlot = struct {
    /// The original page index this slot holds.
    page_index: u32,
    /// Compressed data (heap-allocated; length in `compressed_len`).
    data: [*]u8,
    compressed_len: usize,
};

/// Compressed-page pool which manages a bounded set of `CompressedSlot`s.
///
/// Only pages that actually compress are admitted (`len < PAGE_SIZE`).
pub const CompressPool = struct {
    const MAX_SLOTS = 256; // 256 x up-to-4 KiB ≈ 1 MiB of compressed data

    slots: [MAX_SLOTS]?CompressedSlot = [_]?CompressedSlot{null} ** MAX_SLOTS,
    used: usize = 0,
    pressure: Pressure = .low,

    pub fn init() CompressPool {
        return .{};
    }

    /// Attempt to compress and store `page_data`.
    /// Returns `true` if the page was accepted into the pool.
    pub fn store(
        self: *CompressPool,
        page_index: u32,
        page_data: *const [PAGE_SIZE]u8,
        allocator: std.mem.Allocator,
    ) bool {
        if (self.used >= MAX_SLOTS) return false;

        var buf: [MAX_COMPRESSED_SIZE]u8 = undefined;
        const len = compress(page_data, &buf) catch return false;

        // Only keep the page if we actually saved space.
        if (len >= PAGE_SIZE) return false;

        const heap_buf = allocator.alloc(u8, len) catch return false;
        @memcpy(heap_buf, buf[0..len]);

        for (&self.slots) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .page_index = page_index, .data = heap_buf.ptr, .compressed_len = len };
                self.used += 1;
                return true;
            }
        }

        allocator.free(heap_buf);
        return false;
    }

    /// Decompress the stored page for `page_index` into `out`.
    /// Returns `true` and fills `out` if found; `false` if not present.
    pub fn load(
        self: *CompressPool,
        page_index: u32,
        out: *[PAGE_SIZE]u8,
        allocator: std.mem.Allocator,
    ) bool {
        for (&self.slots) |*slot| {
            const s = slot.* orelse continue;
            if (s.page_index != page_index) continue;

            const compressed = s.data[0..s.compressed_len];
            _ = decompress(compressed, out) catch return false;

            allocator.free(s.data[0..s.compressed_len]);
            slot.* = null;
            self.used -= 1;
            return true;
        }
        return false;
    }

    pub fn setPressure(self: *CompressPool, p: Pressure) void {
        self.pressure = p;
    }
};

test "compress: all-zero page compresses and decompresses" {
    const src: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
    var compressed: [MAX_COMPRESSED_SIZE]u8 = undefined;
    const clen = try compress(&src, &compressed);

    // All-zero should compress well below the page size.
    try std.testing.expect(clen < PAGE_SIZE);

    var recovered: [PAGE_SIZE]u8 = undefined;
    const rlen = try decompress(compressed[0..clen], &recovered);
    try std.testing.expectEqual(PAGE_SIZE, rlen);
    try std.testing.expectEqualSlices(u8, &src, &recovered);
}

test "compress: repetitive pattern compresses and round-trips" {
    var src: [PAGE_SIZE]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i % 13); // short repeating period
    var compressed: [MAX_COMPRESSED_SIZE]u8 = undefined;
    const clen = try compress(&src, &compressed);

    try std.testing.expect(clen < PAGE_SIZE);

    var recovered: [PAGE_SIZE]u8 = undefined;
    _ = try decompress(compressed[0..clen], &recovered);
    try std.testing.expectEqualSlices(u8, &src, &recovered);
}

test "compress: incompressible data fits in MAX_COMPRESSED_SIZE" {
    // Pseudo-random data that won't compress.
    var src: [PAGE_SIZE]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    prng.random().bytes(&src);

    var compressed: [MAX_COMPRESSED_SIZE]u8 = undefined;
    const clen = try compress(&src, &compressed);
    try std.testing.expect(clen <= MAX_COMPRESSED_SIZE);

    var recovered: [PAGE_SIZE]u8 = undefined;
    _ = try decompress(compressed[0..clen], &recovered);
    try std.testing.expectEqualSlices(u8, &src, &recovered);
}

test "compress: CompressPool store and load round-trips" {
    var pool = CompressPool.init();
    var page: [PAGE_SIZE]u8 = [_]u8{0xAB} ** PAGE_SIZE;

    const alloc = @import("innigkeit").memory.heap.allocator;
    const stored = pool.store(42, &page, alloc);
    try std.testing.expect(stored);
    try std.testing.expectEqual(@as(usize, 1), pool.used);

    var out: [PAGE_SIZE]u8 = undefined;
    const loaded = pool.load(42, &out, alloc);
    try std.testing.expect(loaded);
    try std.testing.expectEqual(@as(usize, 0), pool.used);
    try std.testing.expectEqualSlices(u8, &page, &out);
}

test "compress: CompressPool load returns false for unknown index" {
    var pool = CompressPool.init();
    var out: [PAGE_SIZE]u8 = undefined;
    const alloc = @import("innigkeit").memory.heap.allocator;
    try std.testing.expect(!pool.load(99, &out, alloc));
}
