//! SMP proof and stress tests.
//!
//! These run (like every kernel test) sequentially inside the stage4 task on a
//! single executor, but they spawn additional kernel tasks and explicitly place
//! them on *other* executors' runqueues to exercise cross-executor scheduling,
//! locking, and wakeups.
//!
//! - `Scheduler.Handle.get()` always returns the current executor's scheduler,
//!   so plain `queueTask` only ever enqueues locally. There is no public
//!   cross-executor placement API, no load balancing, and no work stealing.
//! - The kernel itself enqueues on a remote executor in exactly one place:
//!   `Task.wakeFromBlocked` (src/innigkeit/task/Task.zig) locks the target
//!   executor's scheduler directly. `queueTaskOnExecutor` below reuses that
//!   pattern for initial placement.
//! - A remote executor that is halted in its idle loop picks the task up at
//!   its next 5 ms timer tick; there is no reschedule IPI.
//!
//! Every wait in this file is bounded by a wallclock watchdog so a deadlock
//! fails the test loudly instead of hanging the suite.

const std = @import("std");
const builtin = @import("builtin");
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
/// specific executor's runqueue.
///
/// There is no public cross-executor placement API; this is the same pattern
/// the kernel itself uses for cross-executor wakeups in `Task.wakeFromBlocked`
/// (src/innigkeit/task/Task.zig): lock the target executor's scheduler and
/// enqueue directly. The target picks the task up at its next timer tick
/// (<= 5 ms) or yield; there is no reschedule IPI.
fn queueTaskOnExecutor(executor: *innigkeit.Executor, task: *innigkeit.Task) void {
    executor.scheduler.lock();
    defer executor.scheduler.unlock();
    executor.scheduler.queueTask(task, .{ .initial = true });
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

var proof_state: struct {
    done: std.atomic.Value(u32) = .init(0),
    ran_on: [max_executors]std.atomic.Value(usize) = @splat(.init(std.math.maxInt(usize))),
} = .{};

fn proofWorker(index: usize) void {
    const current: innigkeit.Task.Current = .get();

    // Pin so known_executor is valid while we read the id.
    current.incrementMigrationDisable();
    const id: usize = @intFromEnum(current.knownExecutor().id);
    current.decrementMigrationDisable();

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
    // record where it ran. Tasks never migrate while runnable (re-enqueue is
    // always local), so ran_on[i] must equal i. If an AP was never booted, its
    // worker never runs and the watchdog fails the test.
    proof_state = .{};
    for (executors, 0..) |*executor, i| {
        try spawnOnExecutor(executor, "smp proof", proofWorker, .{i});
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
