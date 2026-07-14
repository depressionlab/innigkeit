const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

pub const InitOptions = struct {
    name: innigkeit.Task.Name,
    type: innigkeit.Context.Type,
    entry: core.TypeErasedCall,
};

pub fn init(task: *innigkeit.Task, options: InitOptions) !void {
    const preconstructed_stack = task.stack;

    task.* = .{
        .name = options.name,
        .state = .ready,
        .stack = preconstructed_stack,
        .type = options.type,
        .known_executor = null,
        .migration_disable_count = .init(0),
        .spinlocks_held = 1, // fresh tasks start with the scheduler locked
        .scheduler_locked = true, // fresh tasks start with the scheduler locked

        .arch_specific = undefined, // initialized by `initializeTaskArchSpecific` below
    };
    architecture.scheduling.initializeTaskArchSpecific(task);

    task.stack.reset();

    architecture.scheduling.prepareTaskForScheduling(task, options.entry);
}

// Called directly by assembly code in `arch.scheduling.prepareTaskForScheduling`, so the signature must match.
pub fn taskEntry(
    target_function: *const core.TypeErasedCall.TypeErasedFn,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
) callconv(.c) noreturn {
    asm volatile (architecture.scheduling.cfi_prevent_unwinding);

    innigkeit.Task.Current.get().knownExecutor().scheduler.unlock();
    target_function(arg0, arg1, arg2, arg3, arg4);

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
    unreachable;
}
