//! Deterministic-interleaving tests driven by `testing/checkpoint.zig`.

const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const std = @import("std");

const Process = innigkeit.user.Process;
const checkpoint = innigkeit.testing.checkpoint;
const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.checkpoint);

/// Same bound as `smp.test.zig`'s/`integration.test.zig`'s watchdog: only
/// ever trips on a real lost wakeup.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

/// How long process cleanup gets to (wrongly) start while one of its
/// threads is held awaiting cleanup.
const teardown_window_ns: u64 = 2 * std.time.ns_per_s;

fn returningLoaderThread() void {}

/// Spawns a bare process + one `returningLoaderThread`, mirroring
/// `Process.spawnFromInitfs`'s own reference/notify bookkeeping (steps 5-8)
/// without going through initfs/codesig resolution at all.
fn spawnBroken() !struct { child: *Process, exit_notify: *innigkeit.capabilities.Notify } {
    const exit_notify: *innigkeit.capabilities.Notify = try .create();
    exit_notify.ref(); // process's own ref, signalled on exit
    var exit_notify_caller_owned = true;
    defer if (exit_notify_caller_owned) exit_notify.unref();

    const child = try Process.create(.{ .name = try .fromSlice("chkpt_synth") });
    defer child.decrementReferenceCount(); // create()'s own ref, held until the thread exists

    child.exit_notify = exit_notify;

    const thread = try child.createThread(.{ .entry = .prepare(returningLoaderThread, .{}) });

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&thread.task, .{ .initial = true });

    exit_notify_caller_owned = false;
    return .{ .child = child, .exit_notify = exit_notify };
}

fn waitForNotify(notify: *innigkeit.capabilities.Notify, clear_mask: u64) !u64 {
    const start = wallclock.read();
    while (true) {
        const bits = notify.poll(clear_mask);
        if (bits != 0) return bits;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for exit notify", .{});
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        defer handle.unlock();
        handle.yield();
    }
}

test "checkpoint: a process is not torn down while its failed loader thread still awaits cleanup" {
    // Same arch support as integration.test.zig's spawn tests.
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    checkpoint.arm(.thread_cleanup);
    checkpoint.arm(.process_cleanup);

    const result = spawnBroken() catch |err| {
        _ = checkpoint.disarm(.thread_cleanup);
        _ = checkpoint.disarm(.process_cleanup);
        return err;
    };
    defer result.exit_notify.unref();

    // 1. The loader thread returns without reaching userspace, terminates,
    //    and is held at the entry of its own cleanup.
    const thread_subject = checkpoint.awaitCaught(.thread_cleanup, watchdog_ns) orelse {
        _ = checkpoint.disarm(.thread_cleanup);
        return error.WatchdogTimeout;
    };
    if (thread_subject != result.child) {
        // Unrelated background thread cleanup got there first; letting it
        // continue is ordinary kernel behaviour.
        checkpoint.release(.thread_cleanup);
        log.err("caught an unrelated thread's cleanup", .{});
        return error.CaughtUnrelatedTask;
    }

    // 2. While that thread is held, its process must not reach teardown.
    //    If it does, stop here with both services still held: releasing
    //    either now is exactly the use-after-free this test exists to catch.
    if (checkpoint.awaitCaught(.process_cleanup, teardown_window_ns)) |process_subject| {
        log.err(
            "process cleanup reached for {s} while one of its threads still awaits cleanup; " ++
                "leaving both cleanup services held to avoid the use-after-free",
            .{if (process_subject == result.child) "this test's process" else "an unrelated process"},
        );
        return error.ProcessTornDownBeforeThread;
    }

    // 3. Release the thread: dropping its reference is what queues the
    //    process, which then reaches teardown exactly once.
    checkpoint.release(.thread_cleanup);
    const process_subject = checkpoint.awaitCaught(.process_cleanup, watchdog_ns) orelse {
        _ = checkpoint.disarm(.process_cleanup);
        return error.WatchdogTimeout;
    };
    checkpoint.release(.process_cleanup);
    try std.testing.expectEqual(@as(*const innigkeit.user.Process, result.child), process_subject);

    // `brokenLoaderThread` never calls `terminateCallingThread`, so
    // `exit_status` stays at `create()`'s reset value.
    const bits = try waitForNotify(result.exit_notify, 0x01);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(bits >> 8)));
}

/// Spawns A, holds it at `hold_point` (armed before spawning), then spawns
/// B while A is held and waits for B's *entire* load-and-run to finish
/// before releasing A.
fn spawnOverlapping(hold_point: checkpoint.Point) !struct { a: u8, b: u8 } {
    checkpoint.arm(hold_point);

    const a = innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" }) catch |err| {
        _ = checkpoint.disarm(hold_point);
        return err;
    };
    defer a.exit_notify.unref();

    const a_subject = checkpoint.awaitCaught(hold_point, watchdog_ns) orelse {
        _ = checkpoint.disarm(hold_point);
        return error.WatchdogTimeout;
    };
    if (a_subject != a.child) {
        checkpoint.release(hold_point);
        return error.CaughtUnrelatedTask;
    }

    const b = innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" }) catch |err| {
        checkpoint.release(hold_point); // don't leave A stuck
        return err;
    };
    defer b.exit_notify.unref();

    const b_bits = waitForNotify(b.exit_notify, 0xFF_01) catch |err| {
        checkpoint.release(hold_point); // don't leave A stuck
        return err;
    };

    checkpoint.release(hold_point);
    const a_bits = try waitForNotify(a.exit_notify, 0xFF_01);

    return .{ .a = @as(u8, @truncate(a_bits >> 8)), .b = @as(u8, @truncate(b_bits >> 8)) };
}

// See `spawnOverlapping`'s doc comment. This one holds A before it
// protects its own mapping (still RW).
//
// arm-gated: this reliably reproduces the still-open arm concurrent-spawn
// race.
test "checkpoint: a second process loads while the first is held pre-protect (concurrent-spawn race staging)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const result = try spawnOverlapping(.loader_before_protect);
    if (result.a != 42 or result.b != 42) {
        log.err(
            "pre-protect overlap: A exit={d} B exit={d} (expected 42/42)",
            .{ result.a, result.b },
        );
        return error.UnexpectedExitStatus;
    }
}

// See `spawnOverlapping`'s doc comment. This one holds A *after* it has
// protected its own mapping (r-x, matching the hypothesis's premise).
//
// arm-gated: same reasoning as the pre-protect test above.
test "checkpoint: a second process loads while the first is held post-protect (concurrent-spawn race staging)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const result = try spawnOverlapping(.loader_after_protect);
    if (result.a != 42 or result.b != 42) {
        log.err(
            "post-protect overlap: A exit={d} B exit={d} (expected 42/42)",
            .{ result.a, result.b },
        );
        return error.UnexpectedExitStatus;
    }
}
