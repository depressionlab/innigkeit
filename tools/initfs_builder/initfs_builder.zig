//! Build-time tool: packs files into a POSIX ustar archive written to stdout.
//!
//! Usage: initfs_builder [name file]...
//!   name: path stored inside the archive (e.g. "hello_world")
//!   file: filesystem path to read (e.g. /build/hello_world_elf)

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);

    if (args.len > 1 and args.len % 2 != 1) {
        std.debug.print("usage: initfs_builder [name file]...\n", .{});
        std.process.exit(1);
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var sw = Io.File.stdout().writer(init.io, &out_buf);
    const out = &sw.interface;

    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const name = args[i];
        const path = args[i + 1];

        var read_buf: [std.heap.page_size_min]u8 = undefined;
        const file = Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
            std.debug.print("initfs_builder: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close(init.io);

        var reader = file.reader(init.io, &read_buf);
        const data = try reader.interface.allocRemaining(init.gpa, .unlimited);

        try writeEntry(out, name, data);
    }

    // End-of-archive: two consecutive zero 512-byte blocks.
    try out.splatByteAll(0, 1024);
    try out.flush();
}

fn writeEntry(out: *Io.Writer, name: []const u8, data: []const u8) !void {
    var header = std.mem.zeroes([512]u8);

    // name: up to 99 bytes, null-terminated (offset 0, length 100).
    const name_len = @min(name.len, 99);
    @memcpy(header[0..name_len], name[0..name_len]);

    // mode (offset 100, length 8).
    @memcpy(header[100..108], "0000644\x00");

    // uid, gid (offsets 108, 116, each length 8).
    @memcpy(header[108..116], "0000000\x00");
    @memcpy(header[116..124], "0000000\x00");

    // size: 11 octal digits + space (offset 124, length 12).
    _ = std.fmt.bufPrint(header[124..135], "{o:0>11}", .{data.len}) catch unreachable;
    header[135] = ' ';

    // mtime: zero (offset 136, length 12).
    @memcpy(header[136..147], "00000000000");
    header[147] = ' ';

    // checksum placeholder: 8 spaces (offset 148, length 8).
    @memset(header[148..156], ' ');

    // typeflag: '0' = regular file (offset 156).
    header[156] = '0';

    // magic: "ustar\0" (offset 257, length 6).
    @memcpy(header[257..263], "ustar\x00");

    // version: "00" (offset 263, length 2).
    @memcpy(header[263..265], "00");

    // Compute checksum over the full header (checksum field treated as spaces).
    var checksum: u32 = 0;
    for (header) |byte| checksum += byte;

    // Store checksum: 6 octal digits + NUL + space (offset 148, length 8).
    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum}) catch unreachable;
    header[154] = 0;
    header[155] = ' ';

    try out.writeAll(&header);
    try out.writeAll(data);

    // Pad data to the next 512-byte boundary.
    const remainder = data.len % 512;
    if (remainder != 0) try out.splatByteAll(0, 512 - remainder);
}
