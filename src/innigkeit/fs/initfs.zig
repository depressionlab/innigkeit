//! Read-only in-kernel filesystem backed by a POSIX ustar archive.
//!
//! The archive is compiled into the kernel image via @embedFile("initfs").
//! File lookup is a linear scan of the 512-byte header blocks, acceptable
//! for a small set of init-time files.

const std = @import("std");

const archive: []const u8 = @embedFile("initfs");

/// Return the raw bytes of the named file, or null if not found.
pub fn findFile(name: []const u8) ?[]const u8 {
    return findFileIn(archive, name);
}

/// Look up `name` in an arbitrary in-memory ustar archive.
/// Split out from findFile() so the parser is testable on synthetic buffers.
pub fn findFileIn(bytes: []const u8, name: []const u8) ?[]const u8 {
    var offset: usize = 0;
    while (offset + 512 <= bytes.len) {
        const hdr = bytes[offset..][0..512];

        // Two consecutive zero blocks mark the end of the archive.
        if (isZeroBlock(hdr)) break;

        // Name is a null-terminated C string in the first 100 bytes.
        const entry_name = std.mem.sliceTo(hdr[0..100], 0);

        // Size field: 11 octal digits at offset 124, terminated by space or NUL.
        const size = parseOctal(hdr[124..136]);

        const data_start = offset + 512;
        // Guard against integer overflow: a malformed archive can encode a huge
        // size that wraps around and passes the bytes.len bound check below.
        if (size > bytes.len - data_start) break;
        const data_end = data_start + size;

        if (std.mem.eql(u8, entry_name, name)) return bytes[data_start..data_end];

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

/// Test helper: build a minimal valid ustar archive containing one file
/// ("hello.txt" -> "hello"): header block, one data block, two zero blocks.
fn buildTestArchive() [2048]u8 {
    var a = [_]u8{0} ** 2048;
    const hdr = a[0..512];
    @memcpy(hdr[0..9], "hello.txt");
    @memcpy(hdr[100..108], "0000644\x00"); // mode
    @memcpy(hdr[124..136], "00000000005\x00"); // size = 5 (octal)
    hdr[156] = '0'; // typeflag: regular file
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");
    // Checksum: sum of the header with the checksum field read as spaces,
    // written as 6 octal digits + NUL + space.
    @memset(hdr[148..156], ' ');
    var sum: u32 = 0;
    for (hdr) |b| sum += b;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        hdr[153 - i] = @intCast('0' + ((sum >> @intCast(3 * i)) & 7));
    }
    hdr[154] = 0;
    hdr[155] = ' ';
    @memcpy(a[512..517], "hello");
    return a;
}

test "initfs: ustar parser finds file in valid archive" {
    const a = buildTestArchive();
    const data = findFileIn(&a, "hello.txt") orelse return error.NotFound;
    try std.testing.expectEqualSlices(u8, "hello", data);
    try std.testing.expect(findFileIn(&a, "missing.txt") == null);
}

test "initfs: ustar parser rejects corrupt size field" {
    // Non-octal garbage in the size field parses as size 0: the entry is
    // still found but exposes no data (and nothing past the buffer).
    var a = buildTestArchive();
    @memcpy(a[124..136], "00Zx!9garbag");
    const data = findFileIn(&a, "hello.txt") orelse return error.NotFound;
    try std.testing.expectEqual(@as(usize, 0), data.len);

    // A huge (saturating) size that overruns the archive terminates the
    // scan gracefully instead of wrapping the bounds check.
    @memcpy(a[124..136], "77777777777\x00");
    try std.testing.expect(findFileIn(&a, "hello.txt") == null);
}
