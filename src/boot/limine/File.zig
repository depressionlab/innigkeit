const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");
const UUID = @import("uuid").UUID;

pub const File = extern struct {
    revision: u64,

    /// The address of the file. This is always at least 4KiB aligned.
    address: innigkeit.KernelVirtualAddress,

    /// The size of the file.
    ///
    /// Regardless of the file size, all loaded modules are guaranteed to have all 4KiB chunks of memory they cover for
    /// themselves exclusively.
    size: core.Size,

    /// The 0-terminated ASCII path of the file within the volume, with a leading slash.
    _path: [*:0]const u8,

    /// A 0-terminated ASCII string associated with the file.
    _string: ?[*:0]const u8,

    media_type: File.MediaType,

    unused: u32,

    /// If not all zero bytes, this is the IPv4 address of the TFTP server the
    /// file was loaded from, in dotted-decimal octet order.
    tftp_ipv4: [4]u8,
    /// Likewise, but port.
    tftp_port: u32,

    /// 1-based partition index of the volume from which the file was loaded.
    ///
    /// If 0, it means invalid or unpartitioned.
    partition_index: u32,

    /// If non-0, this is the ID of the disk the file was loaded from as reported in its MBR.
    mbr_disk_id: u32,

    /// If not all zero bytes, this is the UUID of the disk the file was loaded from as
    /// reported in its GPT.
    gpt_disk_uuid: UUID,

    /// If not all zero bytes, this is the UUID of the partition the file was loaded from as
    /// reported in the GPT.
    gpt_part_uuid: UUID,

    /// If not all zero bytes, this is the UUID of the filesystem of the partition the
    /// file was loaded from. A UUID with all bytes zero indicates the field is unset.
    part_uuid: UUID,

    /// A 0-terminated ASCII string associated with the file.
    pub fn path(self: *const File) [:0]const u8 {
        return std.mem.sliceTo(self._path, 0);
    }

    /// A 0-terminated ASCII string associated with the file.
    pub fn string(self: *const File) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            self._string orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn getContents(self: *const File) []const u8 {
        return innigkeit.KernelVirtualRange.from(self.address, self.size).byteSlice();
    }

    pub fn print(self: *const File, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("File{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("path: \"{s}\"\n", .{self.path()});

        if (self.string()) |s| {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("string: \"{s}\"\n", .{s});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{self.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{self.size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("media_type: {t}\n", .{self.media_type});

        if (!std.mem.allEqual(u8, &self.tftp_ipv4, 0)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("tftp: ");
            try formatIP(self.tftp_ipv4, self.tftp_port, writer);
            try writer.writeByte('\n');
        }

        if (self.partition_index != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("partition_index: {}\n", .{self.partition_index});
        }

        if (self.mbr_disk_id != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("mbr_disk_id: {}\n", .{self.mbr_disk_id});
        }

        if (!self.gpt_disk_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_disk_uuid: {f}\n", .{self.gpt_disk_uuid});
        }

        if (!self.gpt_part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_part_uuid: {f}\n", .{self.gpt_part_uuid});
        }

        if (!self.part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("part_uuid: {f}\n", .{self.part_uuid});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    fn formatIP(ip: [4]u8, port: u32, writer: *std.Io.Writer) !void {
        try writer.print("{}.{}.{}.{}:{}", .{ ip[0], ip[1], ip[2], ip[3], port });
    }

    pub inline fn format(self: *const File, writer: *std.Io.Writer) !void {
        return File.print(self, writer, 0);
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
        _,
    };
};

test "File.format compiles and runs" {
    // format() is never called by anything in the kernel itself; calling it
    // here is what forces Zig to analyze its body. `print()`'s
    // `self.tftp_ipv4 != 0` (comparing a [4]u8 array against a scalar
    // integer, not valid Zig) was a real compile error hidden this way.
    const file: File = .{
        .revision = 0,
        .address = .{ .value = 0 },
        .size = .{ .value = 0 },
        ._path = "/test",
        ._string = null,
        .media_type = .generic,
        .unused = 0,
        .tftp_ipv4 = .{ 0, 0, 0, 0 },
        .tftp_port = 0,
        .partition_index = 0,
        .mbr_disk_id = 0,
        .gpt_disk_uuid = .nil,
        .gpt_part_uuid = .nil,
        .part_uuid = .nil,
    };

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{file});
}

comptime {
    std.testing.refAllDecls(@This());
}
