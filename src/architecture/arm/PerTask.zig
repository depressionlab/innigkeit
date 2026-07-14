const arm = @import("arm.zig");
const innigkeit = @import("innigkeit");

const PerTask = @This();

/// Callee-saved registers x19–x28.
x19_x28: [10]u64 = .{0} ** 10,
/// Frame pointer (x29).
fp: u64 = 0,
/// Link register (x30).
///
/// The return address when this task is next resumed.
lr: u64 = 0,
/// Kernel stack pointer, saved on context switch.
sp: u64 = 0,

pub inline fn from(task: *innigkeit.Task) *PerTask {
    return &task.arch_specific;
}

pub fn initializeTaskArchSpecific(task: *innigkeit.Task) void {
    const per_task: *PerTask = .from(task);
    per_task.* = .{};
}

/// Get the current task via TPIDR_EL1.
pub inline fn getCurrentTask() *innigkeit.Task {
    // safe: setCurrentTask (below) is the only writer, and always writes
    // a real *innigkeit.Task (same per-CPU thread-pointer pattern as x64's
    // GS_BASE).
    return @ptrFromInt(arm.registers.TPIDR_EL1.read());
}

/// Set the current task via TPIDR_EL1.
pub inline fn setCurrentTask(task: *innigkeit.Task) void {
    arm.registers.TPIDR_EL1.write(@intFromPtr(task));
}
