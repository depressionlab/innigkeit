//! Syscall-dispatch fuzz target.
//!
//! Receives (selector, args) descriptors from the host, runs each in a fresh
//! minimally-entitled process, and replies with the exit status and a
//! coverage snapshot.

const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");
const std = @import("std");

const socket = innigkeit.network.socket;
const wallclock = innigkeit.time.wallclock;
const capabilities = innigkeit.capabilities;
const log = innigkeit.debug.log.scoped(.fuzz_target);

const Syscall = libinnigkeit.Syscall;
const syscall_count = std.meta.tags(Syscall).len;

/// Must match the port in `fuzz_channel.test.zig` and `tools/kernel_fuzz`.
const port: u16 = 9999;

/// Selector plus four words, the same shape as `capabilities.Message`.
const descriptor_len = 8 + 4 * 8;

/// Selector value that ends the loop.
const stop_sentinel: u64 = std.math.maxInt(u64);

const max_iterations: usize = 100;

/// Same bound as the watchdog in `smp.test.zig`.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

/// How long to wait for one target before assuming it is blocked for good.
///
/// Random descriptors will sometimes hit a syscall that blocks with nothing
/// to wake it (`futex_wait`, `net_udp_recv`, ...). That is expected, but it
/// shouldn't stall the loop or trip `watchdog_ns`. Past this limit we signal
/// the target's exit notify ourselves, the same way `process_kill` does.
///
/// The blocked thread keeps running and its Process/Task slots leak until
/// reboot. That's fine for a bounded run; a long campaign would need a real
/// way to kill a stuck thread.
const per_iteration_hang_ns: u64 = 10 * std.time.ns_per_s;

/// Exit status reported when we force-signalled the target. Real statuses
/// are 0 or 128+signal, so this can't collide.
const hang_status: u8 = 0xFF;

/// Waits for `notify`, force-signalling it after `per_iteration_hang_ns`.
/// Returns the exit status, or `hang_status` if we had to force it.
fn waitForExitOrForceUnblock(notify: *capabilities.Notify) !u8 {
    const start = wallclock.read();
    var force_signalled = false;
    while (true) {
        const bits = notify.poll(0xFF_01);
        if (bits != 0) return @truncate(bits >> 8);
        const elapsed_ns = @intFromEnum(wallclock.elapsed(start, wallclock.read()));
        if (!force_signalled and elapsed_ns > per_iteration_hang_ns) {
            log.info("target appears permanently blocked; force-signalling its exit notify", .{});
            notify.signal(@as(u64, 1) | (@as(u64, hang_status) << 8));
            force_signalled = true;
        }
        if (elapsed_ns > watchdog_ns) {
            log.err("watchdog tripped waiting for the fuzz target to exit", .{});
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    }
}

fn recvDescriptor(sock: u8, buf: *[descriptor_len]u8, from: *socket.RecvFrom) !void {
    const start = wallclock.read();
    const len = while (true) {
        if (socket.recvUdp(sock, buf, from)) |n| break n;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for the host's syscall descriptor", .{});
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    };
    if (len != descriptor_len) return error.UnexpectedDescriptorLength;
}

/// Spawns `itest_fuzz_target`, sends it `msg` over a one-shot endpoint, and
/// waits for it to exit. Returns the exit status byte (0 = clean,
/// 128+signal = killed, `hang_status` = force-signalled).
fn runOneDescriptor(msg: capabilities.Message) !u8 {
    const endpoint = try capabilities.Endpoint.create();
    defer endpoint.unref();
    endpoint.ref(); // one ref goes to the target's cap grant

    const target = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_fuzz_target",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .read = true, .write = true } },
        },
    });
    defer target.exit_notify.unref();

    // Doesn't block past the target's own recv().
    endpoint.send(msg);

    return waitForExitOrForceUnblock(target.exit_notify);
}

test "fuzz target: a mutation loop drives host-chosen syscall descriptors through a minimally-entitled process" {
    const sock = socket.openSocket(port) orelse return error.SocketOpenFailed;
    defer socket.closeSocket(sock);

    var iterations: usize = 0;
    while (iterations < max_iterations) : (iterations += 1) {
        var buf: [descriptor_len]u8 = undefined;
        var from: socket.RecvFrom = undefined;
        try recvDescriptor(sock, &buf, &from);

        const selector_raw = std.mem.readInt(u64, buf[0..8], .little);
        if (selector_raw == stop_sentinel) {
            log.info("stop sentinel received after {d} iteration(s)", .{iterations});
            break;
        }

        var words: [4]u64 = undefined;
        for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, buf[8 + i * 8 ..][0..8], .little);
        const exit_status = try runOneDescriptor(.{ .tag = selector_raw, .words = words });

        if (std.enums.fromInt(Syscall, selector_raw)) |selector| {
            log.info("iteration {d}: dispatched {t} (selector={d}), exit_status={d}", .{
                iterations, selector, selector_raw, exit_status,
            });
        } else {
            log.info("iteration {d}: selector {d} does not name a real syscall, exit_status={d}", .{
                iterations, selector_raw, exit_status,
            });
        }

        var raw_coverage: [syscall_count]u32 = undefined;
        innigkeit.testing.fuzz_coverage.dumpInto(&raw_coverage);

        var reply_buf: [4 + syscall_count * 4]u8 = undefined;
        std.mem.writeInt(u32, reply_buf[0..4], exit_status, .little);
        for (raw_coverage, 0..) |count, i| std.mem.writeInt(u32, reply_buf[4 + i * 4 ..][0..4], count, .little);
        try std.testing.expect(socket.sendUdp(sock, from.ip, from.port, &reply_buf));
    } else {
        log.info("max_iterations ({d}) reached without a stop sentinel", .{max_iterations});
    }
}
