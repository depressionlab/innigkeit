//! Date at Boot Feature

const std = @import("std");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x502746e184c088aa, 0xfbc5ec83e6327893),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The UNIX timestamp, in seconds, taken from the system RTC, representing the date and time of boot.
    timestamp: i64,

    pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("DateAtBoot({})", .{response.timestamp});
    }
};
