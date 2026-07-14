//! Date at Boot Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x502746E184C088AA, 0xFBC5EC83E6327893),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The UNIX timestamp, in seconds, taken from the system RTC, representing the date and time of boot.
    timestamp: i64,

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("DateAtBoot({})", .{self.timestamp});
    }
};
