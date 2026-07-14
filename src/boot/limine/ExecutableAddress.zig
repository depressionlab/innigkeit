//! Executable Address Feature

const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x71BA76863CC55F63, 0xB2644A48C516A487),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The physical base address of the executable.
    physical_base: innigkeit.PhysicalAddress,

    /// The virtual base address of the executable.
    virtual_base: innigkeit.KernelVirtualAddress,

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("ExecutableAddress{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("physical_base: {f}\n", .{self.physical_base});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_base: {f}\n", .{self.virtual_base});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};
