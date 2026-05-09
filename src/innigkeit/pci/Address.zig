const std = @import("std");

pub const Address = extern struct {
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,

    pub inline fn format(
        id: Address,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("Address({x:0>4}:{x:0>2}:{x:0>2}:{x:0>1})", .{
            id.segment,
            id.bus,
            id.device,
            id.function,
        });
    }
};
