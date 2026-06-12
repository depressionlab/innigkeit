//! Demonstrates the `innigkeit.stdio` synchronous `std.Io` backend:
//! * std formatting through a `std.Io.File.Writer` (positional -> streaming
//!   fallback over the write syscall)
//! * monotonic timestamps and `io.sleep`
//! * eager `async` + no-op `await`; `concurrent` correctly unavailable
//! * `std.Io.Mutex` / `std.Io.Event` over the futex syscalls
//! * reading a real file (its own codesig from initfs) and printing it with
//!   std formatting
const std = @import("std");
const innigkeit = @import("innigkeit");

pub fn main() void {
    run() catch |err| {
        innigkeit.io.stdout.print("std_demo: FAILED: {t}\n", .{err}) catch {};
    };
}

fn add(a: u64, b: u64) u64 {
    return a + b;
}

fn run() !void {
    const io = innigkeit.stdio.io();

    // std formatting through std.Io: a std.Io.File.Writer over our backend.
    // The writer starts in positional mode; our backend returns
    // error.Unseekable and std falls back to streaming (operate ->
    // file_write_streaming -> write syscall on fd 1).
    var write_buffer: [256]u8 = undefined;
    var file_writer = innigkeit.stdio.stdoutFile().writer(io, &write_buffer);
    const w = &file_writer.interface;

    try w.print("=== std_demo: std.Io backend ===\n", .{});

    // Clock + sleep. All clocks alias the kernel boot clock (1ms resolution).
    const resolution = try std.Io.Clock.awake.resolution(io);
    const before: std.Io.Clock.Timestamp = .now(io, .awake);
    try io.sleep(.fromMilliseconds(10), .awake);
    const elapsed_ms = before.untilNow(io).raw.toMilliseconds();
    try w.print("std_demo: clock resolution={f}, sleep(10ms) elapsed={d}ms {s}\n", .{
        resolution,
        elapsed_ms,
        if (elapsed_ms >= 10) "ok" else "FAIL",
    });

    // async runs eagerly and returns null; await is a no-op.
    var future = io.async(add, .{ 20, 22 });
    const sum = future.await(io);
    try w.print("std_demo: async/await sum={d} {s}\n", .{
        sum,
        if (sum == 42) "ok" else "FAIL",
    });

    // concurrent must report that no unit of concurrency is available.
    if (io.concurrent(add, .{ 1, 2 })) |_| {
        try w.print("std_demo: concurrent succeeded unexpectedly FAIL\n", .{});
    } else |err| {
        try w.print("std_demo: concurrent -> {t} {s}\n", .{
            err,
            if (err == error.ConcurrencyUnavailable) "ok" else "FAIL",
        });
    }

    // std.Io synchronization primitives over the futex syscalls.
    var mutex: std.Io.Mutex = .init;
    try mutex.lock(io);
    mutex.unlock(io);
    var event: std.Io.Event = .unset;
    event.set(io);
    try event.wait(io); // already set: returns immediately
    try w.print("std_demo: std.Io.Mutex + Event over futex ok\n", .{});

    try w.flush();

    // Real file I/O: read this app's codesig sidecar from initfs and print
    // its header with std formatting. (std.Io.File cannot carry a kernel fd
    // on this target -- Handle is void -- so VFS/initfs files go through
    // innigkeit.fs; see library/innigkeit/stdio.zig.)
    var sig: [144]u8 = undefined;
    const n = innigkeit.fs.initfsRead("std_demo.codesig", &sig) catch |err| blk: {
        try w.print("std_demo: initfs read failed: {t}\n", .{err});
        try w.flush();
        break :blk 0;
    };
    if (n >= 8) {
        const magic_ok = std.mem.eql(u8, sig[0..5], "IKSIG");
        try w.print("std_demo: codesig {d} bytes, magic={x} {s}\n", .{
            n,
            sig[0..8],
            if (magic_ok) "ok" else "FAIL",
        });
        try w.flush();
    }

    try w.print("std_demo: done\n", .{});
    try w.flush();
}

// --- Host-runnable tests (no syscalls: only pure/eager backend paths) ----

test "async executes eagerly and await is a no-op" {
    const io = innigkeit.stdio.io();
    var future = io.async(add, .{ 20, 22 });
    // Eager execution contract: the backend returns a null AnyFuture,
    // meaning the result is already populated.
    try std.testing.expectEqual(@as(?*std.Io.AnyFuture, null), future.any_future);
    try std.testing.expectEqual(@as(u64, 42), future.await(io));
}

test "concurrent reports ConcurrencyUnavailable" {
    const io = innigkeit.stdio.io();
    try std.testing.expectError(error.ConcurrencyUnavailable, io.concurrent(add, .{ 1, 2 }));
}

test "clock resolution is one millisecond" {
    const io = innigkeit.stdio.io();
    const resolution = try std.Io.Clock.awake.resolution(io);
    try std.testing.expectEqual(@as(i64, 1), resolution.toMilliseconds());
}

test "uncontended Mutex and Event complete without blocking" {
    const io = innigkeit.stdio.io();
    var mutex: std.Io.Mutex = .init;
    try std.testing.expect(mutex.tryLock());
    mutex.unlock(io);
    try mutex.lock(io);
    mutex.unlock(io);

    var event: std.Io.Event = .unset;
    try std.testing.expect(!event.isSet());
    event.set(io);
    try event.wait(io); // already set: returns without a futex wait
}

test "fileFromFd wraps a kernel fd in innigkeit.fs.File" {
    const file = innigkeit.stdio.fileFromFd(7);
    try std.testing.expectEqual(@as(u32, 7), file.fd);
}
