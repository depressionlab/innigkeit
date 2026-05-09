//! Device Tree Blob Feature
//!
//! Note: Information contained in the /chosen node may not reflect the information given by bootloader tags,
//! and as such the /chosen node properties should be ignored.
//!
//! Note: If the DTB contained `memory@...` nodes, they will get removed.
//! Executable may not rely on these nodes and should use the Memory Map feature instead.

const std = @import("std");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xb40ddb48fb54bac7, 0x545081493f81ffb7),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// Virtual (HHDM) pointer to the device tree blob, in bootloader reclaimable memory.
    address: innigkeit.KernelVirtualAddress,

    pub inline fn format(response: *const Response, writer: *std.Io.Writer) !void {
        try writer.print("DeviceTreeBlob({f})", .{response.address});
    }
};
