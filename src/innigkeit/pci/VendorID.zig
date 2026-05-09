const std = @import("std");

pub const VendorID = enum(u16) {
    none = 0xFFFF,

    _,

    pub inline fn format(id: VendorID, writer: *std.Io.Writer) !void {
        return try writer.print("VendorID(0x{x:0>4})", .{@intFromEnum(id)});
    }
};
