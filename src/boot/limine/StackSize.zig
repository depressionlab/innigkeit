//! Stack Size Feature

const core = @import("core");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x224EF0460A8E8926, 0xE1CB0FC25F46EA3D),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested stack size (also used for MP processors).
    stack_size: core.Size,
};

pub const Response = extern struct {
    revision: u64,
};
