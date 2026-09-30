//! User-process integration tests: spawn a real process via
//! `Process.spawnFromInitfs` (the kernel-internal spawn API, no user-memory
//! or cap-table plumbing) and observe it end-to-end.

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

test "integration: spawnFromInitfs rejects a missing path before creating a process" {
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    try std.testing.expectError(
        error.NotFound,
        innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_missing_from_initfs" }),
    );

    // No process slot was ever consumed by the failed spawn above; several
    // follow-up spawns confirm the process slab is still healthy.
    for (0..3) |_| {
        const result = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" });
        defer result.exit_notify.unref();
        const bits = try waitForNotify(result.exit_notify, 0xFF_01);
        try std.testing.expectEqual(@as(u8, 42), @as(u8, @truncate(bits >> 8)));
    }
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

test "integration: a user fault with an exception class the kernel does not name is still isolated" {
    // Regression test for arm's `handleUserFault` formatting its non-
    // exhaustive `ExceptionClass` with `{t}`, which panics the kernel
    // ("invalid enum value") for any EC without a name. (e.g. the EL0
    // instruction abort this fixture triggers. On x64 the same fixture is
    // an ordinary user page fault; both must isolate as sigsegv).
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const result = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_instruction_abort" });
    defer result.exit_notify.unref();

    const bits = try waitForNotify(result.exit_notify, 0xFF_01);
    try std.testing.expectEqual(
        innigkeit.user.Process.ExitStatus.sigsegv,
        @as(u8, @truncate(bits >> 8)),
    );
}

test "integration: a capability transferred over IPC is usable by the receiving process" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const endpoint: *innigkeit.capabilities.Endpoint = try .create();
    endpoint.ref(); // one ref per grant below (sender + receiver)

    const notify: *innigkeit.capabilities.Notify = try .create();
    notify.ref(); // one ref stays with this test to observe the signal below
    defer notify.unref();

    const sender = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_cap_sender",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .write = true } },
            // .grant: this notify is the one itest_cap_sender delegates
            // onward over IPC below. transferCaps drops any handle whose
            // slot lacks it (see CapabilityTable.zig's transferCaps).
            .{ .cap_type = .notify, .ptr = notify, .rights = .{ .write = true, .grant = true } },
        },
    });
    defer sender.exit_notify.unref();

    const receiver = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_cap_receiver",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .read = true } },
        },
    });
    defer receiver.exit_notify.unref();

    const sender_bits = try waitForNotify(sender.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 55), @as(u8, @truncate(sender_bits >> 8)));

    const receiver_bits = try waitForNotify(receiver.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 66), @as(u8, @truncate(receiver_bits >> 8)));

    // The strongest assertion: the receiver signaled the *same* kernel
    // object this test is still holding a reference to, reached only
    // through the handle `transferCaps` copied into its table.
    const signal_bits = try waitForNotify(notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 0xAB), @as(u8, @truncate(signal_bits >> 8)));
}

test "integration: a capability without the grant right is dropped, not transferred, over IPC" {
    if (true) return error.SkipZigTest;

    const endpoint: *innigkeit.capabilities.Endpoint = try .create();
    endpoint.ref();

    const notify: *innigkeit.capabilities.Notify = try .create();
    notify.ref();
    defer notify.unref();

    const sender = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_cap_sender",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .write = true } },
            // No .grant: itest_cap_sender still tries to send this over IPC,
            // but transferCaps must refuse to delegate it.
            .{ .cap_type = .notify, .ptr = notify, .rights = .{ .write = true } },
        },
    });
    defer sender.exit_notify.unref();

    const receiver = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_cap_receiver",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .read = true } },
        },
    });
    defer receiver.exit_notify.unref();

    const sender_bits = try waitForNotify(sender.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 55), @as(u8, @truncate(sender_bits >> 8)));

    // itest_cap_receiver panics on a zeroed handle, which the userspace
    // panic handler turns into a cooperative exit_process(1).
    const receiver_bits = try waitForNotify(receiver.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(receiver_bits >> 8)));
}

test "integration: process_kill force-signals another process's exit status" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const victim = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_kill_victim" });
    defer victim.exit_notify.unref();

    victim.exit_notify.ref(); // one ref transfers to the killer's cap grant below
    const killer = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_killer",
        .cap_grants = &.{
            .{ .cap_type = .notify, .ptr = victim.exit_notify, .rights = .{} },
        },
    });
    defer killer.exit_notify.unref();

    const killer_bits = try waitForNotify(killer.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(killer_bits >> 8)));

    const victim_bits = try waitForNotify(victim.exit_notify, 0xFF_01);
    try std.testing.expectEqual(
        innigkeit.user.Process.ExitStatus.sigint,
        @as(u8, @truncate(victim_bits >> 8)),
    );
}

test "integration: repeated spawn/wait cycles do not leak" {
    const cycles = 20;

    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        const result = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" });
        defer result.exit_notify.unref();
        const bits = try waitForNotify(result.exit_notify, 0xFF_01);
        try std.testing.expectEqual(@as(u8, 42), @as(u8, @truncate(bits >> 8)));
    }
}

test "integration: repeated spawn/kill cycles do not leak" {
    if (true) return error.SkipZigTest;

    const cycles = 20;

    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        const victim = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_kill_victim" });
        defer victim.exit_notify.unref();

        victim.exit_notify.ref();
        const killer = try innigkeit.user.Process.spawnFromInitfs(.{
            .path = "itest_killer",
            .cap_grants = &.{
                .{ .cap_type = .notify, .ptr = victim.exit_notify, .rights = .{} },
            },
        });
        defer killer.exit_notify.unref();

        _ = try waitForNotify(killer.exit_notify, 0xFF_01);
        const victim_bits = try waitForNotify(victim.exit_notify, 0xFF_01);
        try std.testing.expectEqual(
            innigkeit.user.Process.ExitStatus.sigint,
            @as(u8, @truncate(victim_bits >> 8)),
        );
    }
}

test "integration: a busy-looping sibling thread is force-terminated when its process exits" {
    // Same arch support as the tests above: sibling force-termination only
    // needs spawn_thread + exit_process, both already exercised by
    // itest_spawn_wait; riscv64 has no syscall dispatch at all yet.
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const result = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_sibling_kill",
    });
    defer result.exit_notify.unref();

    const bits = try waitForNotify(result.exit_notify, 0xFF_01);
    try std.testing.expectEqual(@as(u8, 77), @as(u8, @truncate(bits >> 8)));
}
