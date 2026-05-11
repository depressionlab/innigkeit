const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
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

    /// The path of the file within the volume, with a leading slash
    _path: [*:0]const u8,

    /// A string associated with the file
    _string: ?[*:0]const u8,

    media_type: File.MediaType,

    unused: u32,

    /// If non-0, this is the IP of the TFTP server the file was loaded from.
    tftp_ip: u32,
    /// Likewise, but port.
    tftp_port: u32,

    /// 1-based partition index of the volume from which the file was loaded.
    ///
    /// If 0, it means invalid or unpartitioned.
    partition_index: u32,

    /// If non-0, this is the ID of the disk the file was loaded from as reported in its MBR.
    mbr_disk_id: u32,

    /// If non-0, this is the UUID of the disk the file was loaded from as reported in its GPT.
    gpt_disk_uuid: UUID,

    /// If non-0, this is the UUID of the partition the file was loaded from as reported in the GPT.
    gpt_part_uuid: UUID,

    /// If non-0, this is the UUID of the filesystem of the partition the file was loaded from.
    part_uuid: UUID,

    /// The path of the file within the volume, with a leading slash
    pub fn path(file: *const File) [:0]const u8 {
        return std.mem.sliceTo(file._path, 0);
    }

    /// A string associated with the file
    pub fn string(file: *const File) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            file._string orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn getContents(file: *const File) []const u8 {
        return innigkeit.KernelVirtualRange.from(file.address, file.size).byteSlice();
    }

    pub fn print(file: *const File, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("File{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("path: \"{s}\"\n", .{file.path()});

        if (file.string()) |s| {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("string: \"{s}\"\n", .{s});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{file.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{file.size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("media_type: {t}\n", .{file.media_type});

        if (file.tftp_ip != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("tftp: ");
            try formatIP(file.tftp_ip, file.tftp_port, writer);
            try writer.writeByte('\n');
        }

        if (file.partition_index != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("partition_index: {}\n", .{file.partition_index});
        }

        if (file.mbr_disk_id != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("mbr_disk_id: {}\n", .{file.mbr_disk_id});
        }

        if (!file.gpt_disk_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_disk_uuid: {f}\n", .{file.gpt_disk_uuid});
        }

        if (!file.gpt_part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_part_uuid: {f}\n", .{file.gpt_part_uuid});
        }

        if (!file.part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("part_uuid: {f}\n", .{file.part_uuid});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    fn formatIP(ip: u32, port: u32, writer: *std.Io.Writer) !void {
        const bytes: *const [4]u8 = @ptrCast(&ip);
        try writer.print("{}.{}.{}.{}:{}", .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            port,
        });
    }

    pub inline fn format(file: *const File, writer: *std.Io.Writer) !void {
        return File.print(file, writer, 0);
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
        _,
    };
};

comptime {
    std.testing.refAllDecls(@This());
}
