const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const globals = @import("globals.zig");

const init_log = innigkeit.debug.log.scoped(.task_init);

pub const earlyCreateStack = innigkeit.Task.Stack.createStack;

pub fn initializeTasks() !void {
    try innigkeit.Task.Stack.init.initializeStacks();

    init_log.debug("initializing kernel task cache", .{});
    globals.kernel_task_cache.init(.{ .name = try .fromSlice("kernel task") });

    init_log.debug("initializing task cleanup service", .{});
    try globals.task_cleanup.init();
}

pub fn initializeBootstrapInitTask(
    bootstrap_init_task: *innigkeit.Task,
    bootstrap_executor: *innigkeit.Executor,
) !void {
    bootstrap_init_task.* = .{
        .name = try .fromSlice("bootstrap init"),

        .state = .{ .running = bootstrap_executor },
        .stack = undefined, // never used

        .type = .kernel,

        .migration_disable_count = .init(1), // always on the bootstrap executor
        .known_executor = bootstrap_executor,
        .spinlocks_held = 0, // init tasks don't start with the scheduler locked
        .scheduler_locked = false, // init tasks don't start with the scheduler locked

        .arch_specific = undefined, // initialized by `initializeTaskArchSpecific` below
    };
    architecture.scheduling.initializeTaskArchSpecific(bootstrap_init_task);
}

pub fn createAndAssignInitTask(executor: *innigkeit.Executor) !void {
    const dummyInitEntry = struct {
        fn dummyInitEntry() noreturn {
            @panic("init task should not be scheduled!");
        }
    }.dummyInitEntry;

    const task = try innigkeit.Task.createKernelTask(
        .{
            .name = try .initPrint("init {}", .{@intFromEnum(executor.id)}),
            .entry = .prepare(dummyInitEntry, .{}),
        },
    );
    errdefer comptime unreachable;

    task.state = .{ .running = executor };
    task.known_executor = executor;
    task.migration_disable_count = .init(1); // init tasks are always on their executor
    task.spinlocks_held = 0; // init tasks don't start with the scheduler locked
    task.scheduler_locked = false; // init tasks don't start with the scheduler locked

    task.stack.reset(); // we don't care about the entry function or its arguments

    executor._current_task = task; // can't use `executor.setCurrentTask` as this function is used by the bootstrap executor to prepare other executors
}

pub fn initializeSchedulerTask(
    scheduler_task: *innigkeit.Task,
    executor: *innigkeit.Executor,
) !void {
    scheduler_task.* = .{
        .name = try .initPrint("scheduler {}", .{@intFromEnum(executor.id)}),

        .state = .ready,
        .stack = try .createStack(),
        .type = .kernel,
        .known_executor = executor,
        .migration_disable_count = .init(1), // scheduler tasks are always on their executor
        .spinlocks_held = 1, // scheduler tasks start with the scheduler locked
        .scheduler_locked = true, // scheduler tasks start with the scheduler locked
        .is_scheduler_task = true,

        .arch_specific = undefined, // initialized by `initializeTaskArchSpecific` below
    };
    architecture.scheduling.initializeTaskArchSpecific(scheduler_task);
}
