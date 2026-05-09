//! Entry Point Feature

const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested entry point.
    entry: *const fn () callconv(.c) noreturn,
};

pub const Response = extern struct {
    revision: u64,
};
