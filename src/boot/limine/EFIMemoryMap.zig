//! EFI Memory Map Feature
//!
//! This feature provides data suitable for use with RT->SetVirtualAddressMap(), provided HHDM offset is subtracted from memmap.

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x7df62a431d6872d5, 0xa4fcdfb3e57306c8),
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

    pub fn print(response: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("EFIMemoryMap{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{response.memmap});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{response.memmap_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("desc_size: {f}\n", .{response.desc_size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("desc_version: {}\n", .{response.desc_version});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
        return response.print(response, writer, 0);
    }
};
