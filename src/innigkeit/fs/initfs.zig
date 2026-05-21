//! Read-only in-kernel filesystem backed by a POSIX ustar archive.
//!
//! The archive is compiled into the kernel image via @embedFile("initfs").
//! File lookup is a linear scan of the 512-byte header blocks, acceptable
//! for a small set of init-time files.

const std = @import("std");

const archive: []const u8 = @embedFile("initfs");

/// Return the raw bytes of the named file, or null if not found.
pub fn findFile(name: []const u8) ?[]const u8 {
    var offset: usize = 0;
    while (offset + 512 <= archive.len) {
        const hdr = archive[offset..][0..512];

        // Two consecutive zero blocks mark the end of the archive.
        if (isZeroBlock(hdr)) break;

        // Name is a null-terminated C string in the first 100 bytes.
        const entry_name = std.mem.sliceTo(hdr[0..100], 0);

        // Size field: 11 octal digits at offset 124, terminated by space or NUL.
        const size = parseOctal(hdr[124..136]);

        const data_start = offset + 512;
        // Guard against integer overflow: a malformed archive can encode a huge
        // size that wraps around and passes the archive.len bound check below.
        if (size > archive.len - data_start) break;
        const data_end = data_start + size;

        if (std.mem.eql(u8, entry_name, name)) return archive[data_start..data_end];

        // Advance past this header + data (data is padded to 512-byte boundary).
        offset += 512 + alignUp512(size);
    }
    return null;
}

fn isZeroBlock(block: *const [512]u8) bool {
    for (block) |b| if (b != 0) return false;
    return true;
}

fn parseOctal(field: []const u8) usize {
    var result: usize = 0;
    for (field) |ch| {
        if (ch == 0 or ch == ' ') break;
        // Reject non-octal bytes; a malformed archive could sneak in '8','9',
        // or high bytes and produce garbage sizes via silent wrapping.
        if (ch < '0' or ch > '7') return 0;
        // Saturating arithmetic: a huge encoded value caps at maxInt rather
        // than wrapping to a small number that bypasses bounds checks.
        result = result *| 8 +| (ch - '0');
    }
    return result;
}

fn alignUp512(n: usize) usize {
    return (n + 511) & ~@as(usize, 511);
}
