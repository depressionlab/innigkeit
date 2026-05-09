const std = @import("std");

pub const DeviceID = enum(u16) {
    _,

    pub inline fn format(id: DeviceID, writer: *std.Io.Writer) !void {
        try writer.print("DeviceID(0x{x:0>4})", .{@intFromEnum(id)});
    }
};
