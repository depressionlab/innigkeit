pub const apic = @import("apic/root.zig");
pub const config = @import("config.zig");
pub const Gdt = @import("Gdt.zig").Gdt;
pub const hpet = @import("hpet/root.zig");
pub const info = @import("info/root.zig");
pub const init = @import("init/root.zig");
pub const instructions = @import("instructions.zig");
pub const interrupts = @import("interrupts/root.zig");
pub const ioapic = @import("ioapic/root.zig");
pub const paging = @import("paging/root.zig");
pub const PerExecutor = @import("PerExecutor.zig");
pub const PerTask = @import("PerTask.zig");
pub const registers = @import("registers/root.zig");
pub const scheduling = @import("scheduling.zig");
pub const tsc = @import("tsc/root.zig");
pub const Tss = @import("Tss.zig").Tss;
pub const user = @import("user/root.zig");

pub const PrivilegeLevel = enum(u2) {
    ring0 = 0,
    ring1 = 1,
    ring2 = 2,
    ring3 = 3,
};
