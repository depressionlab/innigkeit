//! Bootloader Info Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xF55038D8E2A1202F, 0x279426FCF5F59740),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _name: [*:0]const u8,
    _version: [*:0]const u8,

    pub fn name(self: *const Response) [:0]const u8 {
        return std.mem.sliceTo(self._name, 0);
    }

    pub fn version(self: *const Response) [:0]const u8 {
        return std.mem.sliceTo(self._version, 0);
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("Bootloader({s} {s})", .{
            self.name(),
            self.version(),
        });
    }
};
