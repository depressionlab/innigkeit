//! HHDM (Higher Half Direct Map) Feature

const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x48DCF1CB8AD2B852, 0x63984E959A98244B),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The virtual address of the beginning of the higher half direct map
    address: innigkeit.KernelVirtualAddress,

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("HHDM({f})", .{self.address});
    }
};
