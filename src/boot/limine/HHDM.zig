//! HHDM (Higher Half Direct Map) Feature

const root = @import("root.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
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
