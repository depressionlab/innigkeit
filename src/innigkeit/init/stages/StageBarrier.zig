const StageBarrier = @This();

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const std = @import("std");

number_of_executors_ready: std.atomic.Value(usize) = .init(0),
stage_complete: std.atomic.Value(bool) = .init(false),

/// Returns true if the current executor is selected to run the stage.
///
/// All other executors are blocked until the stage executor signals that it has completed.
pub fn start(barrier: *StageBarrier) bool {
    const stage_executor = barrier.number_of_executors_ready.fetchAdd(1, .acq_rel) == 0;

    if (stage_executor) {
        // wait for all executors to signal that they are ready for the stage to occur
        const number_of_executors = innigkeit.Executor.executors().len;
        while (barrier.number_of_executors_ready.load(.acquire) != number_of_executors) {
            architecture.spinLoopHint();
        }
    } else {
        // wait for the stage executor to signal that the stage has completed
        while (!barrier.stage_complete.load(.acquire)) {
            architecture.spinLoopHint();
        }
    }

    return stage_executor;
}

/// Signal that the stage has completed.
///
/// Called by the stage executor only.
pub fn complete(barrier: *StageBarrier) void {
    barrier.stage_complete.store(true, .release);
}
