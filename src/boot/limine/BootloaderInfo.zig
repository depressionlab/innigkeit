//! Bootloader Info Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xf55038d8e2a1202f, 0x279426fcf5f59740),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _name: [*:0]const u8,
    _version: [*:0]const u8,

    pub fn name(response: *const Response) [:0]const u8 {
        return std.mem.sliceTo(response._name, 0);
    }

    pub fn version(response: *const Response) [:0]const u8 {
        return std.mem.sliceTo(response._version, 0);
    }

    pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("Bootloader({s} {s})", .{
            response.name(),
            response.version(),
        });
    }
};
