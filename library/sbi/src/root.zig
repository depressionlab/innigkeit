// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

pub const base = @import("base.zig");
pub const time = @import("time.zig");
pub const ipi = @import("ipi.zig");
pub const rfence = @import("rfence.zig");
pub const hsm = @import("hsm.zig");
pub const reset = @import("reset.zig");
pub const pmu = @import("pmu.zig");
pub const debug_console = @import("debug_console.zig");
pub const system_suspend = @import("system_suspend.zig");
pub const cppc = @import("cppc.zig");
pub const nested_acceleration = @import("nested_acceleration.zig");
pub const steal_time_accounting = @import("steal_time_accounting.zig");
pub const HartMask = @import("HartMask.zig").HartMask;
pub const legacy = @import("legacy.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}

pub const is_64: bool = switch (@import("builtin").target.cpu.arch) {
    .riscv64 => true,
    .riscv32 => false,
    else => |arch| @compileError("only riscv64 and riscv32 targets supported, found target: " ++ @tagName(arch)),
};
