pub const acpi = @import("acpi/root.zig");
pub const config = @import("config.zig");
pub const debug = @import("debug/root.zig");
pub const Executor = @import("Executor.zig");
pub const init = @import("init/root.zig");
pub const mem = @import("mem/root.zig");
pub const pci = @import("pci/root.zig");
pub const sync = @import("sync/root.zig");
pub const Task = @import("task/Task.zig");
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
