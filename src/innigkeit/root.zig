pub const acpi = @import("acpi/root.zig");
pub const capabilities = @import("capabilities/root.zig");
pub const config = @import("config.zig");
pub const crypto = @import("crypto/root.zig");
pub const debug = @import("debug/root.zig");
pub const drivers = @import("drivers/root.zig");
pub const Executor = @import("Executor.zig");
pub const filesystem = @import("filesystem/root.zig");
pub const firmware = @import("firmware/root.zig");
pub const init = @import("init/root.zig");
pub const memory = @import("memory/root.zig");
pub const network = @import("network/root.zig");
pub const pci = @import("pci/root.zig");
pub const sync = @import("sync/root.zig");
pub const Task = @import("task/Task.zig");
pub const testing = @import("testing/root.zig");
pub const time = @import("time/root.zig");
pub const user = @import("user/root.zig");

const address = @import("address/root.zig");
pub const VirtualAddress = address.VirtualAddress;
pub const KernelVirtualAddress = address.KernelVirtualAddress;
pub const UserVirtualAddress = address.UserVirtualAddress;
pub const PhysicalAddress = address.PhysicalAddress;
pub const VirtualRange = address.VirtualRange;
pub const KernelVirtualRange = address.KernelVirtualRange;
pub const UserVirtualRange = address.UserVirtualRange;
pub const PhysicalRange = address.PhysicalRange;

pub const Context = union(Type) {
    kernel,
    user: *user.Process,

    pub const Type = enum {
        kernel,
        user,
    };
};

// Boot-time hardware security integration tests.

const builtin = @import("builtin");
const std = @import("std");

test "x64: SMEP is enforced at runtime (CR4 bit 20)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const cr4: u64 = asm ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    try std.testing.expect(cr4 & (1 << 20) != 0);
}

test "x64: SMAP is enforced at runtime (CR4 bit 21)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const cr4: u64 = asm ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    try std.testing.expect(cr4 & (1 << 21) != 0);
}
