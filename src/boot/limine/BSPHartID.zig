//! RISC-V BSP Hart ID Feature
//!
//! This request contains the same information as `MP.riscv64.bsp_hartid`, but doesn't boot up other APs.

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x1369359f025525f9, 0x2ff2a56178391bb6),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// The Hart ID of the boot processor.
    bsp_hartid: u64,

    pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("BSPHartID({})", .{response.bsp_hartid});
    }
};
