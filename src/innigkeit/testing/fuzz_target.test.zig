//! First real syscall-dispatch fuzz target.

const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");
const std = @import("std");

const socket = innigkeit.network.socket;
const wallclock = innigkeit.time.wallclock;
const capabilities = innigkeit.capabilities;
const log = innigkeit.debug.log.scoped(.fuzz_target);

const Syscall = libinnigkeit.Syscall;
const syscall_count = std.meta.tags(Syscall).len;

/// Must match `fuzz_channel.test.zig`'s port and `tools/kernel_fuzz`'s
/// destination.
const port: u16 = 9999;

/// Wire shape of the host's syscall descriptor: selector + 4 words, matching
/// `capabilities.Message`'s tag+words shape exactly (no new framing needed).
const descriptor_len = 8 + 4 * 8;

/// Same bound as `smp.test.zig`'s watchdog.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

fn waitForNotify(notify: *capabilities.Notify, clear_mask: u64) !u64 {
    const start = wallclock.read();
    while (true) {
        const bits = notify.poll(clear_mask);
        if (bits != 0) return bits;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for the fuzz target to exit", .{});
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    }
}

test "fuzz target: a host-chosen syscall descriptor is dispatched for real through a minimally-entitled process" {
    const sock = socket.openSocket(port) orelse return error.SocketOpenFailed;
    defer socket.closeSocket(sock);

    var buf: [descriptor_len]u8 = undefined;
    var from: socket.RecvFrom = undefined;
    const start = wallclock.read();
    const len = while (true) {
        if (socket.recvUdp(sock, &buf, &from)) |n| break n;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for the host's syscall descriptor", .{});
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    };
    if (len != descriptor_len) return error.UnexpectedDescriptorLength;

    const selector_raw = std.mem.readInt(u64, buf[0..8], .little);
    var words: [4]u64 = undefined;
    for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, buf[8 + i * 8 ..][0..8], .little);

    const endpoint = try capabilities.Endpoint.create();
    defer endpoint.unref();
    endpoint.ref(); // one ref transfers to the fixture's cap grant below

    const target = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = "itest_fuzz_target",
        .cap_grants = &.{
            .{ .cap_type = .endpoint, .ptr = endpoint, .rights = .{ .read = true, .write = true } },
        },
    });
    defer target.exit_notify.unref();

    var raw_before: [syscall_count]u32 = undefined;
    innigkeit.testing.fuzz_coverage.dumpInto(&raw_before);

    // Blocks until itest_fuzz_target's endpointRecv/endpointReply round
    // trip completes: the reply payload itself carries no information
    // this test needs, only that the fixture ran to completion.
    _ = endpoint.call(.{ .tag = selector_raw, .words = words });

    _ = try waitForNotify(target.exit_notify, 0xFF_01);

    var raw_after: [syscall_count]u32 = undefined;
    innigkeit.testing.fuzz_coverage.dumpInto(&raw_after);

    if (std.enums.fromInt(Syscall, selector_raw)) |selector| {
        const tag_index = std.mem.indexOfScalar(Syscall, std.meta.tags(Syscall), selector).?;
        log.info("dispatched {t} (selector={d}): coverage {d} -> {d}", .{
            selector, selector_raw, raw_before[tag_index], raw_after[tag_index],
        });
    } else {
        log.info("selector {d} does not name a real syscall; no dispatch expected", .{selector_raw});
    }

    var dump: [syscall_count * 4]u8 = undefined;
    for (raw_after, 0..) |count, i| std.mem.writeInt(u32, dump[i * 4 ..][0..4], count, .little);
    try std.testing.expect(socket.sendUdp(sock, from.ip, from.port, &dump));
}
