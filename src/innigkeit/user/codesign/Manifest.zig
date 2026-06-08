//! Entitlements packed struct.
//!
//! Each bit gates a specific syscall or capability type. The kernel checks the
//! calling process's entitlements before allowing the operation. A process
//! inherits the entitlements stored in its `.codesig` blob at spawn time.
//!
//! Default value (all false except allow_spawn) is permissive enough for a
//! shell or init process but restrictive enough to protect hardware resources.

const std = @import("std");

name: []const u8,
version: []const u8 = "0.0.0",
description: []const u8 = "",
entitlements: Entitlements = .{},

pub const Entitlements = packed struct(u64) {
    /// May call `framebuffer_map`
    framebuffer: bool = false, // bit 0
    /// May call `blk_write`
    storage: bool = false, // bit 1
    /// May call any `net_*` syscall
    network: bool = false, // bit 2
    /// May call `kbd_read`
    keyboard: bool = false, // bit 3
    /// May call `mouse_read`
    mouse: bool = false, // bit 4
    /// May call `spawn` to create child processes
    spawn: bool = true, // bit 5

    /// May call `cap_create(.gpu_buffer)`
    gpu: bool = false, // bit 6
    /// May call `cap_create(.secure_vault)`
    secure_vault: bool = false, // bit 7

    /// When true, only the initial process (PID 1) may spawn this binary.
    trusted_spawner_only: bool = false, // bit 8
    /// When true, the kernel grants the process unrestricted cap_grants from init.
    internal_service: bool = false, // bit 9

    _reserved: u54 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Entitlements) == 8);
    std.debug.assert(@bitSizeOf(Entitlements) == 64);
}

test "entitlements: default value fits in u64" {
    const e: Entitlements = .{};
    const raw: u64 = @bitCast(e);
    // Only spawn bit (bit 5) should be set.
    try std.testing.expectEqual(@as(u64, 1 << 5), raw);
}

test "entitlements: all-permissive value" {
    const e: Entitlements = .{
        .framebuffer = true,
        .storage = true,
        .network = true,
        .keyboard = true,
        .mouse = true,
        .spawn = true,
        .gpu = true,
        .secure_vault = true,
        .internal_service = true,
    };
    const raw: u64 = @bitCast(e);
    try std.testing.expect(raw != 0);
    // Reserved bits must remain zero.
    try std.testing.expectEqual(@as(u64, 0), raw >> 10);
}
