//! Executable File Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    executable_file: *const root.File,

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("ExecutableFile{\n");

        try writer.splatByteAll(' ', new_indent + 2);
        try self.executable_file.print(writer, new_indent + 2);
        try writer.writeByte('\n');

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};
