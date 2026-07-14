//! Firmware Type Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x8C2F75D90BEF28A8, 0x7045A4688EAC00C3),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    firmware_type: Response.Type,

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("Firmware({t})", .{self.firmware_type});
    }

    pub const Type = enum(u64) {
        x86_bios = 0,
        efi_32 = 1,
        efi_64 = 2,
        sbi = 3,

        _,
    };
};
