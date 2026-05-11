const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const StageBarrier = @import("StageBarrier.zig");
const stage4 = @import("stage4.zig");

const log = innigkeit.debug.log.scoped(.init);

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors.
///
/// All executors are using their init task's stack.
pub fn start() !noreturn {
    const static = struct {
        var stage3_barrier: StageBarrier = .{};
    };

    if (static.stage3_barrier.start()) {
        log.debug("loading standard interrupt handlers", .{});
        architecture.interrupts.init.loadStandardInterruptHandlers();

        log.debug("creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *innigkeit.Task = try .createKernelTask(
                .{
                    .name = try .fromSlice("init stage 4"),
                    .entry = .prepare(stage4.start, .{}),
                },
            );

            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();

            scheduler_handle.queueTask(init_stage4_task);
        }

        static.stage3_barrier.complete();
    }

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
    unreachable;
}
