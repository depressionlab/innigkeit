const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const stage3 = @import("stage3.zig");
const StageBarrier = @import("StageBarrier.zig");

const log = innigkeit.debug.log.scoped(.init);

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
pub fn start(executor: *innigkeit.Executor) !noreturn {
    const static = struct {
        var stage2_barrier: StageBarrier = .{};
    };

    architecture.interrupts.disable(); // some executors don't have interrupts disabled on load

    innigkeit.memory.kernelPageTable().load();
    architecture.init.initExecutor(executor);
    executor.setCurrentTask(executor._current_task);

    if (static.stage2_barrier.start()) {
        innigkeit.debug.setPanicMode(.init_panic);
        innigkeit.debug.log.setLogMode(.init_log);

        static.stage2_barrier.complete();
    }

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    architecture.init.configurePerExecutorSystemFeatures();

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    architecture.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    innigkeit.time.per_executor_periodic.enableInterrupt(innigkeit.config.scheduler.per_executor_interrupt_period);

    try architecture.scheduling.callNoSave(
        &executor._current_task.stack,
        .prepare(stage3.start, .{}),
    );
    unreachable;
}
