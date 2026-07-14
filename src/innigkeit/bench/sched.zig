//! Scheduler benchmark: measures yield latency and fairness across N worker tasks,
//! plus cross-executor wake latency.
//!
//! Each worker yields `yields_per_task` times then exits. The main task waits
//! until all workers have finished, then prints a summary:
//!   - total wall time
//!   - average yield latency (sum of per-worker wall time / total yields)
//!   - per-worker wall time and CPU time (sum_exec_runtime)
//!   - fairness: max deviation from ideal equal wall time across workers
//!
//!
//! The wake-latency benchmark measures unpark -> running for a blocked task
//! while the waker keeps the CPU busy (it never yields voluntarily), so the
//! number reflects how quickly the woken task actually gets a CPU: with idle
//! wake placement + reschedule IPI it lands on an idle executor within
//! microseconds; without them it waits for the waker's executor to be
//! preempted at a timer tick (up to 5 ms).

const innigkeit = @import("innigkeit");
const std = @import("std");
const wallclock = innigkeit.time.wallclock;

const log = innigkeit.debug.log.scoped(.sched_bench);

const task_count: u32 = 2;
const yields_per_task: u32 = 500;

const State = struct {
    done: std.atomic.Value(u32) = .init(0),
    exec_runtime: [task_count]u64 = [_]u64{0} ** task_count,
    // wall time for each worker's full yield loop, measured by the worker itself
    worker_wall_ns: [task_count]u64 = [_]u64{0} ** task_count,
};

var global_state: State = .{};

fn workerFn(index: u32) !void {
    // Measure the full loop wall time rather than per-yield to avoid inflating
    // individual measurements with timer interrupt overhead.
    const loop_start = wallclock.read();
    var i: u32 = 0;
    while (i < yields_per_task) : (i += 1) {
        const h: innigkeit.Task.Scheduler.Handle = .get();
        defer h.unlock();
        h.yield();
    }
    global_state.worker_wall_ns[index] = wallclock.elapsed(loop_start, wallclock.read()).value;

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

    // Allocate all worker tasks before taking the scheduler lock: same pattern
    // as stage4's hello_world creation. createKernelTask triggers heap slab
    // allocations; holding the scheduler lock across those is unnecessary and
    // can interact badly with the memory subsystem.
    var workers: [task_count]*innigkeit.Task = undefined;
    var created: u32 = 0;
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
    // avg_yield: total wall time / total yields. Each worker's loop wall time
    // is summed to exclude time the init task spent spinning between workers.
    var sum_worker_wall: u64 = 0;
    for (global_state.worker_wall_ns) |w| sum_worker_wall += w;
    const avg_yield_ns = if (total_yields > 0) sum_worker_wall / total_yields else 0;

    // Fairness: max deviation from ideal equal wall time across workers.
    // Using wall time (not sum_exec_runtime) so the metric is independent of
    // how the scheduler attributes time spent in timer interrupt handlers.
    const ideal_wall: u64 = sum_worker_wall / task_count;
    var max_dev: u64 = 0;
    for (global_state.worker_wall_ns) |w| {
        const dev = if (w >= ideal_wall) w - ideal_wall else ideal_wall - w;
        if (dev > max_dev) max_dev = dev;
    }
    const fairness_pct: u64 = if (ideal_wall > 0) max_dev * 100 / ideal_wall else 0;

    log.info("sched bench: done  total={} ns  avg_yield={} ns  fairness_err={}%", .{
        total_ns,
        avg_yield_ns,
        fairness_pct,
    });

    for (global_state.worker_wall_ns, global_state.exec_runtime, 0..) |wall, cpu, i| {
        log.info("sched bench:   worker[{}] wall_ns={}  cpu_ns={}", .{ i, wall, cpu });
    }

    try runWakeLatency();
}

const wake_rounds: u32 = 64;
const wake_round_timeout_ns: u64 = 10 * std.time.ns_per_s;

var wake_state: struct {
    parker: innigkeit.sync.Parker = .empty,
    /// Wallclock tick recorded by the sleeper right after park() returned.
    t1: std.atomic.Value(u64) = .init(0),
    rounds_done: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(u32) = .init(0),
} = .{};

fn wakeSleeper() void {
    while (true) {
        wake_state.parker.park();
        if (wake_state.stop.load(.acquire)) break;
        wake_state.t1.store(@intFromEnum(wallclock.read()), .release);
        _ = wake_state.rounds_done.fetchAdd(1, .release);
    }
    _ = wake_state.exited.fetchAdd(1, .release);
}

/// Measure unpark -> running latency for a parked task while the waker stays
/// CPU-bound (preemptible at ticks, but never yielding voluntarily).
fn runWakeLatency() !void {
    wake_state = .{};

    const sleeper = try innigkeit.Task.createKernelTask(.{
        .name = try .fromSlice("bench wake"),
        .entry = .prepare(wakeSleeper, .{}),
    });
    {
        const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
        defer scheduler_handle.unlock();
        scheduler_handle.queueTask(sleeper, .{ .initial = true });
    }

    const current: innigkeit.Task.Current = .get();

    var sum_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // One extra warmup round (the very first unpark also pays for the
    // sleeper's initial scheduling) that is excluded from the stats.
    var round: u32 = 0;
    while (round < wake_rounds + 1) : (round += 1) {
        const expected_done = round + 1;

        const t0 = wallclock.read();
        wake_state.parker.unpark();

        // CPU-bound wait: the interrupt-disable toggle is a preemption point
        // (needs_resched is honoured on the 1 -> 0 transition) but we never
        // yield, so the woken sleeper only runs here if it got its own CPU.
        while (wake_state.rounds_done.load(.acquire) < expected_done) {
            if (wallclock.elapsed(t0, wallclock.read()).value > wake_round_timeout_ns) {
                return error.WakeLatencyTimeout;
            }
            current.incrementInterruptDisable();
            current.decrementInterruptDisable();
        }

        if (round == 0) continue; // warmup

        const t1: wallclock.Tick = @enumFromInt(wake_state.t1.load(.acquire));
        const latency_ns = wallclock.elapsed(t0, t1).value;
        sum_ns += latency_ns;
        min_ns = @min(min_ns, latency_ns);
        max_ns = @max(max_ns, latency_ns);
    }

    wake_state.stop.store(true, .release);
    wake_state.parker.unpark();
    {
        const start = wallclock.read();
        while (wake_state.exited.load(.acquire) == 0) {
            if (wallclock.elapsed(start, wallclock.read()).value > wake_round_timeout_ns) {
                return error.WakeLatencyTimeout;
            }
            const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();
            scheduler_handle.yield();
        }
    }

    log.info("sched bench: wake latency ({} rounds)  avg={} ns  min={} ns  max={} ns", .{
        wake_rounds,
        sum_ns / wake_rounds,
        min_ns,
        max_ns,
    });
}
