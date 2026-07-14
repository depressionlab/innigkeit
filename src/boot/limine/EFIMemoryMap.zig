//! EFI Memory Map Feature
//!
//! This feature provides data suitable for use with RT->SetVirtualAddressMap(), provided HHDM offset is subtracted from memmap.

const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x7DF62A431D6872D5, 0xA4FCDFB3E57306C8),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// Address (HHDM, in bootloader reclaimable memory) of the EFI memory map.
    memmap: innigkeit.KernelVirtualAddress,

    /// Size in bytes of the EFI memory map.
    memmap_size: core.Size,

    /// EFI memory map descriptor size in bytes.
    desc_size: core.Size,

    /// Version of EFI memory map descriptors.
    desc_version: u64,

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("EFIMemoryMap{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{self.memmap});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{self.memmap_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("desc_size: {f}\n", .{self.desc_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("desc_version: {}\n", .{self.desc_version});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

test "EFIMemoryMap.Response.format compiles and runs" {
    // format() is never called by anything in the kernel itself; calling it
    // here is what forces Zig to analyze its body and this file had the same
    // self.print(self, ...) double-self-argument bug MP.zig and
    // Framebuffer.zig also had.
    const resp: Response = .{
        .revision = 0,
        .memmap = .{ .value = 0 },
        .memmap_size = .{ .value = 0 },
        .desc_size = .{ .value = 0 },
        .desc_version = 0,
    };

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{resp});
}
