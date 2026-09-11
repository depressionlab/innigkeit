//! User-process integration tests: spawn a real process via
//! `Process.spawnFromInitfs` (the kernel-internal spawn API, no user-memory
//! or cap-table plumbing) and observe it end-to-end.
//!
//! See `docs/test-harness-plan.md`: this is Stage 4 / TH-1, the harness
//! proving it can launch a signed process and observe its result.

const innigkeit = @import("innigkeit");
const std = @import("std");
const builtin = @import("builtin");

const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.integration);

/// Same bound as `smp.test.zig`'s watchdog: generous, only ever trips on a
/// genuine deadlock/lost-wakeup, which must fail the test.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

fn yieldNow() void {
    const handle: innigkeit.Task.Scheduler.Handle = .get();
    defer handle.unlock();
    handle.yield();
}

/// Poll `notify` for `clear_mask` bits (yielding between polls) until one is
/// set. Fails with error.WatchdogTimeout after `watchdog_ns` instead of
/// hanging the suite if the child never signals.
fn waitForNotify(notify: *innigkeit.capabilities.Notify, clear_mask: u64) !u64 {
    const start = wallclock.read();
    while (true) {
        const bits = notify.poll(clear_mask);
        if (bits != 0) return bits;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for exit notify", .{});
            return error.WatchdogTimeout;
        }
        yieldNow();
    }
}

test "integration: spawn itest_spawn_wait and observe its exit status" {
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const result = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" });
    defer result.exit_notify.unref();

    const bits = try waitForNotify(result.exit_notify, 0xFF_01); // bit 0 = exited, bits 8..15 = status
    try std.testing.expectEqual(@as(u8, 42), @as(u8, @truncate(bits >> 8)));
}

test "integration: unhandled user-mode exception isolates to the calling process, not the kernel" {
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // If either architecture's isolation path regressed back to panicking
    // the kernel, this test would never reach the assertion below.
    const result = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_illegal_instruction",
    });
    defer result.exit_notify.unref();

    const bits = try waitForNotify(result.exit_notify, 0xFF_01);
    try std.testing.expectEqual(
        innigkeit.user.Process.ExitStatus.sigill,
        @as(u8, @truncate(bits >> 8)),
    );
}
