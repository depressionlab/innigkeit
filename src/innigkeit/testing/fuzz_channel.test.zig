const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");
const std = @import("std");

const socket = innigkeit.network.socket;
const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.fuzz_channel);

const Syscall = libinnigkeit.Syscall;
const syscall_count = std.meta.tags(Syscall).len;

/// Must match `tools/kernel_fuzz/main.zig`'s destination port and
/// `build/QEMU.zig`'s `-Dfuzz_channel=true` hostfwd wiring.
const port: u16 = 9999;

/// Same bound as `smp.test.zig`'s watchdog.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

test "fuzz channel: a host-sent datagram is echoed back as a byte-sum counter" {
    const sock = socket.openSocket(port) orelse return error.SocketOpenFailed;
    defer socket.closeSocket(sock);

    var buf: [socket.MAX_PAYLOAD]u8 = undefined;
    var from: socket.RecvFrom = undefined;
    const start = wallclock.read();
    const len = while (true) {
        if (socket.recvUdp(sock, &buf, &from)) |n| break n;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > watchdog_ns) {
            log.err("watchdog tripped waiting for the host's corpus datagram", .{});
            return error.WatchdogTimeout;
        }
        // The net-poll task needs to run to deliver the datagram.
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    };

    var counter: u64 = 0;
    for (buf[0..len]) |byte| counter +%= byte;
    log.info("received {d}-byte datagram from {d}.{d}.{d}.{d}:{d}, echoing counter={d}", .{
        len, from.ip[0], from.ip[1], from.ip[2], from.ip[3], from.port, counter,
    });

    var reply: [8]u8 = undefined;
    std.mem.writeInt(u64, &reply, counter, .little);
    try std.testing.expect(socket.sendUdp(sock, from.ip, from.port, &reply));

    // Step 3: send the real per-syscall coverage snapshot back as a second
    // datagram, one little-endian u32 per `std.meta.tags(Syscall)` entry.
    var raw_counts: [syscall_count]u32 = undefined;
    innigkeit.testing.fuzz_coverage.dumpInto(&raw_counts);
    var coverage_dump: [syscall_count * 4]u8 = undefined;
    for (raw_counts, 0..) |count, i| {
        std.mem.writeInt(u32, coverage_dump[i * 4 ..][0..4], count, .little);
    }
    try std.testing.expect(socket.sendUdp(sock, from.ip, from.port, &coverage_dump));
}
