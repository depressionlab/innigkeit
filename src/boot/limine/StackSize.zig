//! Stack Size Feature

const root = @import("root.zig");
const core = @import("core");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested stack size (also used for MP processors).
    stack_size: core.Size,
};

pub const Response = extern struct {
    revision: u64,
};
