const std = @import("std");
const innigkeit = @import("innigkeit");
const x64 = @import("x64.zig");

const PerTask = @This();

/// A self pointer to the task used for GS relative accesses.
self_pointer: *innigkeit.Task,

/// Used to store the user rsp temporarily on syscall entry.
user_rsp_scratch: u64 = undefined,

/// Top of the current executor's dedicated IRQ stack.
///
/// Accessed via GS in the ring0 -> ring0 interrupt entry path to switch execution
/// away from the task stack before calling the Zig interrupt dispatcher.
/// Updated by `initExecutor` (for the initial task) and `beforeSwitchTask`
/// (for every subsequent task switch).
irq_stack_top: u64 = 0,

pub inline fn from(task: *innigkeit.Task) *PerTask {
    return &task.arch_specific;
}

pub fn initializeTaskArchSpecific(task: *innigkeit.Task) void {
    const per_task: *PerTask = .from(task);
    per_task.* = .{
        .self_pointer = task,
        .irq_stack_top = 0,
    };
}

/// Get the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn getCurrentTask() *innigkeit.Task {
    const static = struct {
        const self_pointer_offset_string = std.fmt.comptimePrint(
            "{d}",
            .{@offsetOf(innigkeit.Task, "arch_specific") + @offsetOf(PerTask, "self_pointer")},
        );
    };

    return asm ("mov %%gs:" ++ static.self_pointer_offset_string ++ ", %[current_task]"
        : [current_task] "=r" (-> *innigkeit.Task),
    );
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub inline fn setCurrentTask(task: *innigkeit.Task) void {
    x64.registers.GS_BASE.write(@intFromPtr(task));
}
