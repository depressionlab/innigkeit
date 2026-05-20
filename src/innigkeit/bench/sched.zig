//! Scheduler benchmark: measures yield latency and fairness across N worker tasks.
//!
//! Each worker yields `yields_per_task` times then exits.  The main task waits
//! until all workers have finished, then prints a summary:
//!   - total wall time
//!   - average yield round-trip latency (ns)
//!   - per-task CPU time (sum_exec_runtime)
//!   - fairness: max deviation from ideal equal share

const std = @import("std");
const innigkeit = @import("innigkeit");
const wallclock = innigkeit.time.wallclock;

const log = innigkeit.debug.log.scoped(.sched_bench);

const task_count: u32 = 2;
const yields_per_task: u32 = 500;

const State = struct {
    done: std.atomic.Value(u32) = .init(0),
    exec_runtime: [task_count]u64 = [_]u64{0} ** task_count,
    total_yield_ns: std.atomic.Value(u64) = .init(0),
};

var global_state: State = .{};

fn workerFn(index: u32) !void {
    var i: u32 = 0;
    while (i < yields_per_task) : (i += 1) {
        const before = wallclock.read();
        {
            const h: innigkeit.Task.Scheduler.Handle = .get();
            defer h.unlock();
            h.yield();
        }
        const after = wallclock.read();
        _ = global_state.total_yield_ns.fetchAdd(wallclock.elapsed(before, after).value, .monotonic);
    }

    const current_task: innigkeit.Task.Current = .get();
    global_state.exec_runtime[index] = current_task.task.sched.sum_exec_runtime;

    _ = global_state.done.fetchAdd(1, .release);

    {
        const h: innigkeit.Task.Scheduler.Handle = .get();
        h.terminate();
    }
    unreachable;
}

/// Run the scheduler benchmark.
///
/// Creates `task_count` worker tasks, waits for all to complete, then logs results.
pub fn run() !void {
    global_state = .{};

    log.info("sched bench: starting ({} tasks x {} yields)", .{ task_count, yields_per_task });

    const start = wallclock.read();

    // Allocate all worker tasks before taking the scheduler lock — same pattern
    // as stage4's hello_world creation.  createKernelTask triggers heap slab
    // allocations; holding the scheduler lock across those is unnecessary and
    // can interact badly with the memory subsystem.
    var workers: [task_count]*innigkeit.Task = undefined;
    var created: u32 = 0;
    errdefer {
        // Clean up any tasks we created before the error.
        // Acceptable: this is a diagnostic benchmark, not production code.
    }
    while (created < task_count) : (created += 1) {
        workers[created] = try .createKernelTask(.{
            .name = try .fromSlice("bench worker"),
            .entry = .prepare(workerFn, .{created}),
        });
    }

    // Queue all workers under a single scheduler lock acquisition.
    {
        const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
        defer scheduler_handle.unlock();
        for (workers) |t| scheduler_handle.queueTask(t, .{ .initial = true });
    }

    // Yield until all workers are done.
    while (global_state.done.load(.acquire) < task_count) {
        const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
        defer scheduler_handle.unlock();
        scheduler_handle.yield();
    }

    const end = wallclock.read();
    const total_ns = wallclock.elapsed(start, end).value;

    const total_yields: u64 = @as(u64, task_count) * yields_per_task;
    const avg_yield_ns = if (total_yields > 0)
        global_state.total_yield_ns.load(.monotonic) / total_yields
    else
        0;

    // Compute fairness: max deviation from ideal equal share of CPU time.
    var sum_exec: u64 = 0;
    for (global_state.exec_runtime) |rt| sum_exec += rt;
    const ideal: u64 = sum_exec / task_count;
    var max_dev: u64 = 0;
    for (global_state.exec_runtime) |rt| {
        const dev = if (rt >= ideal) rt - ideal else ideal - rt;
        if (dev > max_dev) max_dev = dev;
    }
    const fairness_pct: u64 = if (ideal > 0) max_dev * 100 / ideal else 0;

    log.info("sched bench: done  total={} ns  avg_yield={} ns  fairness_err={}%", .{
        total_ns,
        avg_yield_ns,
        fairness_pct,
    });

    for (global_state.exec_runtime, 0..) |rt, i| {
        log.info("sched bench:   worker[{}] cpu_ns={}", .{ i, rt });
    }
}
