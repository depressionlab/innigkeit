//! SMP proof and stress tests.
//!
//! These run (like every kernel test) sequentially inside the stage4 task on a
//! single executor, but they spawn additional kernel tasks and explicitly place
//! them on *other* executors' runqueues to exercise cross-executor scheduling,
//! locking, and wakeups.
//!
//! - `Scheduler.Handle.get()` always returns the current executor's scheduler,
//!   so plain `queueTask` only ever enqueues locally.
//! - Cross-executor placement goes through `Scheduler.queueTaskOnRemote`,
//!   which pairs the enqueue with the idle handshake: if the target executor
//!   is halted in its idle loop it is kicked with a reschedule IPI (where the
//!   architecture provides one); the 5 ms tick remains the backstop.
//! - Idle executors also steal one queued fair-class task at a time from the
//!   busiest other executor (never RT tasks, never migration-pinned tasks).
//!
//! Every wait in this file is bounded by a wallclock watchdog so a deadlock
//! fails the test loudly instead of hanging the suite.

const std = @import("std");
const builtin = @import("builtin");
const architecture = @import("architecture");
const boot = @import("boot");
const innigkeit = @import("innigkeit");

const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.smp_test);

/// Generous bound for every blocking wait in this file. The heaviest test
/// (mutex contention) finishes in well under a second on TCG; 60s only ever
/// trips on a genuine deadlock/lost-wakeup, which must fail the test.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

const max_executors = innigkeit.config.executor.maximum_number_of_executors;

/// Yield the current task once.
fn yieldNow() void {
    const handle: innigkeit.Task.Scheduler.Handle = .get();
    defer handle.unlock();
    handle.yield();
}

/// Poll `counter` (yielding between polls) until it reaches `target`.
/// Fails with error.WatchdogTimeout after `watchdog_ns` so a deadlocked or
/// lost worker fails the test instead of hanging the suite.
fn waitForCounter(counter: *const std.atomic.Value(u32), target: u32, what: []const u8) !void {
    const start = wallclock.read();
    while (counter.load(.acquire) < target) {
        if (wallclock.elapsed(start, wallclock.read()).value > watchdog_ns) {
            log.err(
                "watchdog tripped waiting for {s}: {d}/{d} completed",
                .{ what, counter.load(.acquire), target },
            );
            return error.WatchdogTimeout;
        }
        yieldNow();
    }
}

/// Enqueue a freshly created (state == .ready, never run) task onto a
/// specific executor's runqueue, kicking the target out of its idle halt if
/// necessary (same path the kernel uses for cross-executor wakeups).
fn queueTaskOnExecutor(executor: *innigkeit.Executor, task: *innigkeit.Task) void {
    innigkeit.Task.Scheduler.queueTaskOnRemote(executor, task, .{ .initial = true });
}

/// Create a kernel task running `entry` and place it on `executor`.
fn spawnOnExecutor(
    executor: *innigkeit.Executor,
    name: []const u8,
    entry: anytype,
    args: std.meta.ArgsTuple(@TypeOf(entry)),
) !void {
    const task = try innigkeit.Task.createKernelTask(.{
        .name = try .fromSlice(name),
        .entry = .prepare(entry, args),
    });
    queueTaskOnExecutor(executor, task);
}

/// Like `spawnOnExecutor`, but the task starts migration-pinned to `executor`
/// so it cannot be stolen by an idle executor while it waits in the queue.
/// The task body must release the pin with a single
/// `Task.Current.get().decrementMigrationDisable()` once it has recorded
/// whatever needed the stable placement.
fn spawnPinnedOnExecutor(
    executor: *innigkeit.Executor,
    name: []const u8,
    entry: anytype,
    args: std.meta.ArgsTuple(@TypeOf(entry)),
) !void {
    const task = try innigkeit.Task.createKernelTask(.{
        .name = try .fromSlice(name),
        .entry = .prepare(entry, args),
    });
    // The task has never run; we are its only owner. Pinned tasks must have a
    // valid known_executor (see Task.wakeFromBlocked).
    task.migration_disable_count.store(1, .release);
    task.known_executor = executor;
    queueTaskOnExecutor(executor, task);
}

var proof_state: struct {
    done: std.atomic.Value(u32) = .init(0),
    ran_on: [max_executors]std.atomic.Value(usize) = @splat(.init(std.math.maxInt(usize))),
} = .{};

fn proofWorker(index: usize) void {
    const current: innigkeit.Task.Current = .get();
    const id: usize = @intFromEnum(current.knownExecutor().id);
    current.decrementMigrationDisable(); // releaase the spawn-time pin

    proof_state.ran_on[index].store(id, .release);
    _ = proof_state.done.fetchAdd(1, .release);
}

test "smp: every bootloader-reported CPU has a live, scheduling executor" {
    const executors = innigkeit.Executor.executors();
    log.info("smp: {d} executor(s) online", .{executors.len});

    // If Limine SMP did not deliver, fail so we know (rather than silently
    // running every "SMP" test on one core).
    var descriptors = boot.cpuDescriptors() orelse return error.NoSmpInfoFromBootloader;
    try std.testing.expectEqual(descriptors.count(), executors.len);

    // Prove each executor actually runs tasks: pin one worker per executor and
    // record where it ran. The workers are spawned migration-pinned so idle
    // work stealing cannot move them off a dead AP's queue (which would mask
    // exactly the failure this test exists to catch), so ran_on[i] must equal
    // i. If an AP was never booted, its worker never runs and the watchdog
    // fails the test.
    proof_state = .{};
    for (executors, 0..) |*executor, i| {
        try spawnPinnedOnExecutor(executor, "smp proof", proofWorker, .{i});
    }
    try waitForCounter(&proof_state.done, @intCast(executors.len), "smp proof workers");

    for (executors, 0..) |_, i| {
        try std.testing.expectEqual(i, proof_state.ran_on[i].load(.acquire));
    }
}

const spin_workers: u32 = 4;
const spin_iterations: u64 = 5_000;

var spin_state: struct {
    lock: innigkeit.sync.TicketSpinLock = .{},
    counter: u64 = 0,
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn spinWorker() void {
    var i: u64 = 0;
    while (i < spin_iterations) : (i += 1) {
        spin_state.lock.lock();
        spin_state.counter += 1;
        spin_state.lock.unlock();
    }
    _ = spin_state.done.fetchAdd(1, .release);
}

test "smp: TicketSpinLock guards a shared counter under cross-executor contention" {
    spin_state = .{};
    const executors = innigkeit.Executor.executors();

    var w: u32 = 0;
    while (w < spin_workers) : (w += 1) {
        try spawnOnExecutor(&executors[w % executors.len], "smp spin", spinWorker, .{});
    }

    try waitForCounter(&spin_state.done, spin_workers, "spinlock workers");
    try std.testing.expectEqual(
        @as(u64, spin_workers) * spin_iterations,
        spin_state.counter,
    );
}

const mutex_workers: u32 = 4;
const mutex_iterations: u64 = 2_000;

var mutex_state: struct {
    mutex: innigkeit.sync.Mutex = .{},
    counter: u64 = 0,
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn mutexWorker() void {
    var i: u64 = 0;
    while (i < mutex_iterations) : (i += 1) {
        mutex_state.mutex.lock();
        mutex_state.counter += 1;
        mutex_state.mutex.unlock();
    }
    _ = mutex_state.done.fetchAdd(1, .release);
}

test "smp: Mutex guards a shared counter; blocked waiters are woken across executors" {
    mutex_state = .{};
    const executors = innigkeit.Executor.executors();

    var w: u32 = 0;
    while (w < mutex_workers) : (w += 1) {
        try spawnOnExecutor(&executors[w % executors.len], "smp mutex", mutexWorker, .{});
    }

    try waitForCounter(&mutex_state.done, mutex_workers, "mutex workers");
    try std.testing.expectEqual(
        @as(u64, mutex_workers) * mutex_iterations,
        mutex_state.counter,
    );
}

const ring_capacity: usize = 8;
const ring_items: u64 = 500;

var ring_state: struct {
    lock: innigkeit.sync.TicketSpinLock = .{},
    not_empty: innigkeit.sync.WaitQueue = .{},
    not_full: innigkeit.sync.WaitQueue = .{},
    buffer: [ring_capacity]u64 = @splat(0),
    head: usize = 0,
    count: usize = 0,
    received_count: u64 = 0,
    received_sum: u64 = 0,
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn ringProducer() void {
    var next: u64 = 1;
    while (next <= ring_items) {
        ring_state.lock.lock();
        if (ring_state.count == ring_capacity) {
            // Releases the lock and blocks; the consumer wakes us via
            // not_full.wakeOne. Re-check the condition from the top.
            ring_state.not_full.wait(&ring_state.lock);
            continue;
        }
        ring_state.buffer[(ring_state.head + ring_state.count) % ring_capacity] = next;
        ring_state.count += 1;
        next += 1;
        ring_state.not_empty.wakeOne(&ring_state.lock);
        ring_state.lock.unlock();
    }
    _ = ring_state.done.fetchAdd(1, .release);
}

fn ringConsumer() void {
    var received: u64 = 0;
    while (received < ring_items) {
        ring_state.lock.lock();
        if (ring_state.count == 0) {
            ring_state.not_empty.wait(&ring_state.lock);
            continue;
        }
        const value = ring_state.buffer[ring_state.head];
        ring_state.head = (ring_state.head + 1) % ring_capacity;
        ring_state.count -= 1;
        received += 1;
        ring_state.received_sum += value; // still under the lock
        ring_state.not_full.wakeOne(&ring_state.lock);
        ring_state.lock.unlock();
    }
    ring_state.received_count = received;
    _ = ring_state.done.fetchAdd(1, .release);
}

test "smp: WaitQueue producer/consumer ring delivers every item exactly once" {
    ring_state = .{};
    const executors = innigkeit.Executor.executors();

    // Start the producer and consumer on different executors when available.
    try spawnOnExecutor(&executors[0], "smp ring prod", ringProducer, .{});
    try spawnOnExecutor(&executors[executors.len - 1], "smp ring cons", ringConsumer, .{});

    try waitForCounter(&ring_state.done, 2, "ring producer/consumer");

    try std.testing.expectEqual(ring_items, ring_state.received_count);
    // Sum of 1..=ring_items proves no item was dropped or duplicated.
    try std.testing.expectEqual(ring_items * (ring_items + 1) / 2, ring_state.received_sum);
    try std.testing.expectEqual(@as(usize, 0), ring_state.count);
}

const pingpong_rounds: u64 = 300;

var pingpong_state: struct {
    ping_parker: innigkeit.sync.Parker = .empty,
    pong_parker: innigkeit.sync.Parker = .empty,
    ping_rounds: u64 = 0,
    pong_rounds: u64 = 0,
    done: std.atomic.Value(u32) = .init(0),
} = .{};

// Strict alternation: ping's i-th park can only be satisfied by pong's i-th
// unpark, which requires pong's i-th park to have returned, which requires
// ping's i-th unpark. So neither side can run ahead and the final round
// counts are exact.
fn pingTask() void {
    var i: u64 = 0;
    while (i < pingpong_rounds) : (i += 1) {
        pingpong_state.pong_parker.unpark();
        pingpong_state.ping_parker.park();
        pingpong_state.ping_rounds += 1;
    }
    _ = pingpong_state.done.fetchAdd(1, .release);
}

fn pongTask() void {
    var i: u64 = 0;
    while (i < pingpong_rounds) : (i += 1) {
        pingpong_state.pong_parker.park();
        pingpong_state.ping_parker.unpark();
        pingpong_state.pong_rounds += 1;
    }
    _ = pingpong_state.done.fetchAdd(1, .release);
}

test "smp: Parker ping-pong between two tasks completes exact round counts" {
    pingpong_state = .{};
    const executors = innigkeit.Executor.executors();

    try spawnOnExecutor(&executors[0], "smp ping", pingTask, .{});
    try spawnOnExecutor(&executors[executors.len - 1], "smp pong", pongTask, .{});

    try waitForCounter(&pingpong_state.done, 2, "parker ping-pong tasks");

    try std.testing.expectEqual(pingpong_rounds, pingpong_state.ping_rounds);
    try std.testing.expectEqual(pingpong_rounds, pingpong_state.pong_rounds);
}

const blk_reads_per_task: u32 = 4;

var blk_state: struct {
    buffers: [2][512]u8 = @splat(@splat(0)),
    errors: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn blkWorker(slot: usize) void {
    var i: u32 = 0;
    while (i < blk_reads_per_task) : (i += 1) {
        innigkeit.drivers.virtio.blk.readSectors(0, 0, &blk_state.buffers[slot], 1) catch {
            _ = blk_state.errors.fetchAdd(1, .monotonic);
            break;
        };
    }
    _ = blk_state.done.fetchAdd(1, .release);
}

test "smp: concurrent blk reads from two executors return identical data" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    if (!innigkeit.drivers.virtio.blk.isBootReady()) return error.SkipZigTest;

    blk_state = .{};

    var reference: [512]u8 = undefined;
    try innigkeit.drivers.virtio.blk.readSectors(0, 0, &reference, 1);

    const executors = innigkeit.Executor.executors();
    try spawnOnExecutor(&executors[0], "smp blk 0", blkWorker, .{@as(usize, 0)});
    try spawnOnExecutor(&executors[executors.len - 1], "smp blk 1", blkWorker, .{@as(usize, 1)});

    try waitForCounter(&blk_state.done, 2, "blk readers");

    try std.testing.expectEqual(@as(u32, 0), blk_state.errors.load(.acquire));
    try std.testing.expectEqualSlices(u8, &reference, &blk_state.buffers[0]);
    try std.testing.expectEqualSlices(u8, &reference, &blk_state.buffers[1]);
}

var ipi_state: struct {
    run_tick: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn ipiWakeWorker() void {
    ipi_state.run_tick.store(@intFromEnum(wallclock.read()), .release);
    _ = ipi_state.done.fetchAdd(1, .release);
}

test "smp: reschedule IPI wakes an idle executor well before the next tick" {
    // Without a reschedule IPI the idle pickup degrades to the 5 ms tick;
    // nothing to measure.
    if (comptime !architecture.interrupts.reschedule_ipi_available) return error.SkipZigTest;

    const executors = innigkeit.Executor.executors();
    if (executors.len < 2) return error.SkipZigTest;

    // Two probabilistic races can spoil a single measurement without anything
    // being wrong: (a) the target's 5 ms tick can win against our IPI (the
    // task then runs fast but the IPI counter does not move), and (b) the IPI
    // can land in the small window between the idle loop's unlock and its
    // halt (the task then waits for the next tick, ~5 ms). Both are expected
    // and rare, so we retry; a systematic failure exhausts all attempts.
    const max_attempts: u32 = 10;
    const latency_limit_ns: u64 = 4 * std.time.ns_per_ms; // well under the 5 ms tick

    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        ipi_state = .{};

        const current: innigkeit.Task.Current = .get();
        // Pin for the whole attempt: keeps "self" stable for the idle scan
        // and prevents this task from being stolen onto the target executor
        // mid-measurement.
        current.incrementMigrationDisable();
        defer current.decrementMigrationDisable();
        const self_executor = current.knownExecutor();

        // Wait for some remote executor to declare itself idle.
        const target = blk: {
            const start = wallclock.read();
            while (true) {
                for (executors) |*executor| {
                    if (executor == self_executor) continue;
                    if (executor.scheduler.idle.load(.seq_cst)) break :blk executor;
                }
                if (wallclock.elapsed(start, wallclock.read()).value > watchdog_ns) {
                    log.err("watchdog tripped waiting for an idle remote executor", .{});
                    return error.WatchdogTimeout;
                }
                yieldNow();
            }
        };

        const ipis_before = target.scheduler.reschedule_ipi_count.load(.monotonic);

        const task = try innigkeit.Task.createKernelTask(.{
            .name = try .fromSlice("smp ipi wake"),
            .entry = .prepare(ipiWakeWorker, .{}),
        });

        const t0 = wallclock.read();
        innigkeit.Task.Scheduler.queueTaskOnRemote(target, task, .{ .initial = true });

        try waitForCounter(&ipi_state.done, 1, "ipi wake worker");

        const run_tick: wallclock.Tick = @enumFromInt(ipi_state.run_tick.load(.acquire));
        const latency_ns = wallclock.elapsed(t0, run_tick).value;
        const ipi_delta = target.scheduler.reschedule_ipi_count.load(.monotonic) - ipis_before;

        log.info(
            "ipi wake attempt {d}: latency={d} ns, reschedule IPIs={d}",
            .{ attempt, latency_ns, ipi_delta },
        );

        if (ipi_delta > 0 and latency_ns < latency_limit_ns) return; // pass
    }

    log.err("no attempt achieved IPI-driven wake under {d} ns", .{latency_limit_ns});
    return error.RescheduleIpiWakeTooSlow;
}

const steal_worker_count: u32 = 4;

var steal_test_state: struct {
    /// Bit i set <-> some worker has run on executor i.
    executors_seen: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u32) = .init(0),
} = .{};

fn stealWorker() void {
    const current: innigkeit.Task.Current = .get();
    while (!steal_test_state.stop.load(.acquire)) {
        // CPU-bound: never yields voluntarily, so the ONLY way these workers
        // can spread across executors is idle work stealing. The interrupt
        // disable toggle pins known_executor for the read and doubles as a
        // preemption point (needs_resched from the tick is honoured on the
        // 1 -> 0 transition), keeping the host executor live for other tasks.
        current.incrementInterruptDisable();
        const id: u6 = @intCast(@intFromEnum(current.knownExecutor().id));
        current.decrementInterruptDisable();
        _ = steal_test_state.executors_seen.fetchOr(@as(u64, 1) << id, .acq_rel);
    }
    _ = steal_test_state.done.fetchAdd(1, .release);
}

fn totalStealCount() u64 {
    var total: u64 = 0;
    for (innigkeit.Executor.executors()) |*executor| {
        total += executor.scheduler.steal_count.load(.monotonic);
    }
    return total;
}

test "smp: idle executors steal queued fair tasks from a busy executor" {
    const executors = innigkeit.Executor.executors();
    if (executors.len < 2) return error.SkipZigTest;

    steal_test_state = .{};
    const steals_before = totalStealCount();

    // Create all workers first, then enqueue every one of them onto OUR OWN
    // runqueue in a single lock hold: a pile of runnable work on one executor
    // that only stealing can redistribute.
    var workers: [steal_worker_count]*innigkeit.Task = undefined;
    for (&workers) |*slot| {
        slot.* = try innigkeit.Task.createKernelTask(.{
            .name = try .fromSlice("smp steal"),
            .entry = .prepare(stealWorker, .{}),
        });
    }
    {
        const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
        defer scheduler_handle.unlock();
        for (workers) |task| scheduler_handle.queueTask(task, .{ .initial = true });
    }

    // Wait (watchdog-bounded) until the workers have demonstrably run on at
    // least two distinct executors and at least one steal was recorded.
    const start = wallclock.read();
    while (true) {
        const seen = steal_test_state.executors_seen.load(.acquire);
        if (@popCount(seen) >= 2 and totalStealCount() > steals_before) break;

        if (wallclock.elapsed(start, wallclock.read()).value > watchdog_ns) {
            steal_test_state.stop.store(true, .release);
            waitForCounter(&steal_test_state.done, steal_worker_count, "steal workers (cleanup)") catch {};
            log.err(
                "watchdog tripped: executors_seen={b}, steals delta={d}",
                .{ seen, totalStealCount() - steals_before },
            );
            return error.WatchdogTimeout;
        }
        yieldNow();
    }

    steal_test_state.stop.store(true, .release);
    try waitForCounter(&steal_test_state.done, steal_worker_count, "steal workers");

    try std.testing.expect(@popCount(steal_test_state.executors_seen.load(.acquire)) >= 2);
    try std.testing.expect(totalStealCount() > steals_before);
}
