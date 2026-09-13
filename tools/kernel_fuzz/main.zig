//! Host-side driver for the in-kernel corpus feedback channel.
//!
//! At the moment, its used to verify the following:
//! * Step 2: (bytes sent from the host reach a UDP-based debug service inside
//!   a QEMU-booted kernel via `-Dfuzz_channel=true`'s hostfwd wiring, and a
//!   reply comes back with the expected computed value)
//! * Step 3 (a second datagram carrying a per-syscall-selector coverage
//!   snapshot is readable), and
//! * Step 4 (a chosen (selector, args) tuple, sent as a third datagram, is
//!   really dispatched by a minimally-entitled guest process: confirmed by
//!   diffing the coverage snapshot taken before against the one taken after).
//!
//! We still don't handle a corpus/mutation loop: this drives exactly one fixed,
//! known-safe descriptor to prove the mechanism, not a fuzzing campaign.
const std = @import("std");
const net = std.Io.net;

/// Must match `src/innigkeit/testing/fuzz_channel.test.zig`'s listener port
/// and `build/QEMU.zig`'s `-Dfuzz_channel=true` hostfwd wiring.
const port: u16 = 9999;

/// Upper bound on how many little-endian u32 coverage slots the second
/// datagram can carry. We give generous headroom over the current syscall count
/// (`library/innigkeit/syscall.zig`'s `Syscall` enum) so this doesn't need
/// updating every time a syscall is added. The datagram's own length (a
/// multiple of 4) says how many slots it actually holds.
const max_coverage_slots: usize = 512;

/// Sent as the corpus "entry"; the kernel's reply must echo back the
/// wrapping byte-sum of this exact payload.
const payload = "innigkeit-fuzz-channel-poc";

/// The one syscall descriptor step 4 drives through the real dispatch
/// table: `getpid` (selector 27 in `library/innigkeit/syscall.zig`'s
/// `Syscall` enum), chosen because its handler (`syscalls.zig`'s
/// `sysGetpid`) ignores every argument outright, so wild
/// garbage words are guaranteed safe to send.
const fuzz_selector: u64 = 27;
const fuzz_words = [4]u64{ 0xFFFF_FFFF_FFFF_FFFF, 0xDEAD_BEEF_DEAD_BEEF, 0, 0 };

/// Bounds one send-and-wait attempt: short enough that a boot still in
/// progress just costs a quick retry, not a long stall.
const per_attempt_timeout_ms: i64 = 300;

/// Bounds the whole round trip.
const overall_timeout_ns: i96 = 180 * std.time.ns_per_s;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const dest: net.IpAddress = try .parseIp4("127.0.0.1", port);
    const bind_addr: net.IpAddress = .{ .ip4 = .unspecified(0) };
    const sock = try bind_addr.bind(io, .{ .mode = .dgram });
    defer sock.close(io);

    var expected: u64 = 0;
    for (payload) |b| expected +%= b;

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromNanoseconds(overall_timeout_ns));

    var recv_buf: [64]u8 = undefined;
    while (true) {
        sock.send(io, &dest, payload) catch |err| {
            std.debug.print("kernel_fuzz: send failed: {t}\n", .{err});
            std.process.exit(1);
        };

        const attempt_timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(per_attempt_timeout_ms),
            .clock = .awake,
        } };
        if (sock.receiveTimeout(io, &recv_buf, attempt_timeout)) |message| {
            if (message.data.len == 8) {
                const counter = std.mem.readInt(u64, message.data[0..8], .little);
                if (counter == expected) {
                    std.debug.print("kernel_fuzz: PASS (counter={d})\n", .{counter});
                    const before = receiveCoverageDump(io, sock, short_timeout) catch |err| {
                        std.debug.print("kernel_fuzz: no coverage dump received: {t}\n", .{err});
                        std.process.exit(1);
                    };
                    try runFuzzTarget(io, sock, dest, before);
                    return;
                }
                std.debug.print(
                    "kernel_fuzz: reply mismatch: got counter={d}, want {d}\n",
                    .{ counter, expected },
                );
                std.process.exit(1);
            }
            std.debug.print("kernel_fuzz: unexpected reply length {d}\n", .{message.data.len});
            std.process.exit(1);
        } else |err| switch (err) {
            error.Timeout => {}, // per-attempt timeout: the guest isn't ready yet, retry
            else => {
                std.debug.print("kernel_fuzz: receive failed: {t}\n", .{err});
                std.process.exit(1);
            },
        }

        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) {
            std.debug.print("kernel_fuzz: timed out waiting for a reply from the guest\n", .{});
            std.process.exit(1);
        }
    }
}

const CoverageDump = struct {
    counts: [max_coverage_slots]u32 = @splat(0),
    slot_count: usize,
};

/// Staging step 3: read one coverage-snapshot datagram, printing it as it's
/// parsed. Propagates `error.Timeout` normally (the caller decides whether
/// that's fatal or just means "not sent yet, retry") but exits directly on
/// a malformed reply.
fn receiveCoverageDump(io: std.Io, sock: net.Socket, timeout: std.Io.Timeout) net.Socket.ReceiveTimeoutError!CoverageDump {
    var buf: [max_coverage_slots * 4]u8 = undefined;
    const message = try sock.receiveTimeout(io, &buf, timeout);
    if (message.data.len == 0 or message.data.len % 4 != 0 or message.data.len / 4 > max_coverage_slots) {
        std.debug.print("kernel_fuzz: coverage dump has an unexpected length {d}\n", .{message.data.len});
        std.process.exit(1);
    }

    var dump: CoverageDump = .{ .slot_count = message.data.len / 4 };
    var nonzero_slots: usize = 0;
    std.debug.print("kernel_fuzz: coverage dump ({d} slots):\n", .{dump.slot_count});
    for (0..dump.slot_count) |i| {
        const count = std.mem.readInt(u32, message.data[i * 4 ..][0..4], .little);
        dump.counts[i] = count;
        if (count == 0) continue;
        nonzero_slots += 1;
        std.debug.print("  slot {d}: {d} hit(s)\n", .{ i, count });
    }
    std.debug.print("kernel_fuzz: {d}/{d} syscall slots hit at least once\n", .{ nonzero_slots, dump.slot_count });
    return dump;
}

const short_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } };
const retry_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(per_attempt_timeout_ms), .clock = .awake } };

/// Staging step 4: send the one fixed syscall descriptor
/// (`fuzz_selector`/`fuzz_words`) as a third datagram; `testing/
/// fuzz_target.test.zig` forwards it to `itest_fuzz_target`, which issues
/// it as a real syscall, then replies with a fresh coverage dump. A short
/// retry loop (not the long one above) absorbs the brief gap between that
/// test's socket and `fuzz_channel.test.zig`'s closing of the same port.
fn runFuzzTarget(io: std.Io, sock: net.Socket, dest: net.IpAddress, before: CoverageDump) !void {
    var descriptor: [8 + 4 * 8]u8 = undefined;
    std.mem.writeInt(u64, descriptor[0..8], fuzz_selector, .little);
    for (fuzz_words, 0..) |w, i| std.mem.writeInt(u64, descriptor[8 + i * 8 ..][0..8], w, .little);

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(10));
    while (true) {
        sock.send(io, &dest, &descriptor) catch |err| {
            std.debug.print("kernel_fuzz: fuzz-target send failed: {t}\n", .{err});
            std.process.exit(1);
        };

        if (receiveCoverageDump(io, sock, retry_timeout)) |after| {
            if (fuzz_selector >= after.slot_count) {
                std.debug.print("kernel_fuzz: fuzz selector {d} is outside the {d}-slot dump\n", .{ fuzz_selector, after.slot_count });
                std.process.exit(1);
            }
            const before_count = before.counts[fuzz_selector];
            const after_count = after.counts[fuzz_selector];
            if (after_count != before_count + 1) {
                std.debug.print(
                    "kernel_fuzz: fuzz-target FAIL: slot {d} went {d} -> {d}, expected +1\n",
                    .{ fuzz_selector, before_count, after_count },
                );
                std.process.exit(1);
            }
            std.debug.print(
                "kernel_fuzz: fuzz-target PASS: selector {d} dispatched for real (slot {d}: {d} -> {d})\n",
                .{ fuzz_selector, fuzz_selector, before_count, after_count },
            );
            return;
        } else |err| switch (err) {
            error.Timeout => {}, // the guest's socket for this phase isn't reopen yet; retry
            else => {
                std.debug.print("kernel_fuzz: fuzz-target receive failed: {t}\n", .{err});
                std.process.exit(1);
            },
        }

        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) {
            std.debug.print("kernel_fuzz: timed out waiting for the fuzz-target coverage dump\n", .{});
            std.process.exit(1);
        }
    }
}
