//! Entry Point Feature

const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x13D86C035A1CD3E1, 0x2B0CAA89D8F3026A),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// The requested entry point.
    entry: *const fn () callconv(.c) noreturn,
};

pub const Response = extern struct {
    revision: u64,
};
