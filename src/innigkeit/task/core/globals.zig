const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const TaskCleanup = @import("TaskCleanup.zig");

/// The source of kernel task objects.
///
/// Initialized during `init.initializeTasks`.
pub var kernel_task_cache: innigkeit.mem.cache.Cache(
    innigkeit.Task,
    .{
        .constructor = struct {
            fn constructor(task: *innigkeit.Task) innigkeit.mem.cache.ConstructorError!void {
                if (core.is_debug) task.* = undefined;
                task.stack = try .createStack();
            }
        }.constructor,
        .destructor = struct {
            fn destructor(task: *innigkeit.Task) void {
                task.stack.destroyStack();
            }
        }.destructor,
    },
) = undefined;

/// All currently living kernel tasks.
///
/// This does not include the per-executor scheduler or bootstrap init tasks.
pub var kernel_tasks: std.AutoArrayHashMapUnmanaged(*innigkeit.Task, void) = .{};
pub var kernel_tasks_lock: innigkeit.sync.RwLock = .{};

/// Initialized during `init.initializeTasks`.
pub var task_cleanup: TaskCleanup = undefined;
