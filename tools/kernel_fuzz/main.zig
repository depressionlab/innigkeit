//! Host-side driver for the in-kernel fuzz channel.
//!
//! Talks to a QEMU guest booted with `-Dfuzz_channel=true`: checks the UDP
//! handshake, reads a coverage snapshot, then runs a coverage-guided mutation
//! loop over (selector, args) syscall descriptors.

const std = @import("std");
const net = std.Io.net;
const corpus = @import("corpus.zig");

/// Must match the listener port in `src/innigkeit/testing/fuzz_channel.test.zig`
/// and the hostfwd wiring in `build/QEMU.zig`.
const port: u16 = 9999;

/// Max u32 coverage slots in a snapshot datagram. Comfortably above the
/// current syscall count; the datagram length gives the real slot count.
const max_coverage_slots: usize = 512;

/// Handshake payload. The guest replies with its wrapping byte-sum.
const payload = "innigkeit-fuzz-channel-poc";

/// Descriptors sent before the stop sentinel. Must not exceed
/// `max_iterations` in `fuzz_target.test.zig`.
const mutation_loop_iterations: usize = 40;

/// Timeout for one handshake attempt.
const per_attempt_timeout_ms: i64 = 300;

/// Timeout for the whole handshake.
const overall_timeout_ns: i96 = 180 * std.time.ns_per_s;

/// Timeout per mutation-loop iteration (includes guest process spawn/teardown).
const per_iteration_timeout_ms: i64 = 45_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(init.arena.allocator());
    const corpus_dir: ?[]const u8 = if (args_slice.len >= 2) args_slice[1] else null;
    if (corpus_dir == null)
        std.debug.print("kernel_fuzz: no corpus directory given, crash/insteresting descriptors will not be saved\n", .{});

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
                    try runMutationLoop(init.io, init.arena.allocator(), sock, dest, corpus_dir, before);
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
            error.Timeout => {}, // guest not ready yet, retry
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

/// Reads one coverage snapshot datagram. Returns `error.Timeout` to the
/// caller; exits on a malformed reply.
fn receiveCoverageDump(io: std.Io, sock: net.Socket, timeout: std.Io.Timeout) net.Socket.ReceiveTimeoutError!CoverageDump {
    var buf: [max_coverage_slots * 4]u8 = undefined;
    const message = try sock.receiveTimeout(io, &buf, timeout);
    if (message.data.len == 0 or message.data.len % 4 != 0 or message.data.len / 4 > max_coverage_slots) {
        std.debug.print("kernel_fuzz: coverage dump has an unexpected length {d}\n", .{message.data.len});
        std.process.exit(1);
    }

    var dump: CoverageDump = .{ .slot_count = message.data.len / 4 };
    var nonzero_slots: usize = 0;
    for (0..dump.slot_count) |i| {
        const count = std.mem.readInt(u32, message.data[i * 4 ..][0..4], .little);
        dump.counts[i] = count;
        if (count != 0) nonzero_slots += 1;
    }
    std.debug.print("kernel_fuzz: coverage dump ({d} slots, {d} nonzero)\n", .{ dump.slot_count, nonzero_slots });
    return dump;
}

const short_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } };

/// Reply to one descriptor: a little-endian u32 exit status followed by a
/// coverage dump.
const IterationReply = struct {
    exit_status: u8,
    coverage: CoverageDump,
};

fn receiveIterationReply(io: std.Io, sock: net.Socket, timeout: std.Io.Timeout) net.Socket.ReceiveTimeoutError!IterationReply {
    var buf: [4 + max_coverage_slots * 4]u8 = undefined;
    const message = try sock.receiveTimeout(io, &buf, timeout);
    if (message.data.len < 4 or (message.data.len - 4) % 4 != 0 or (message.data.len - 4) / 4 > max_coverage_slots) {
        std.debug.print("kernel_fuzz: iteration reply has an unexpected length {d}\n", .{message.data.len});
        std.process.exit(1);
    }

    const exit_status: u8 = @truncate(std.mem.readInt(u32, message.data[0..4], .little));
    var dump: CoverageDump = .{ .slot_count = (message.data.len - 4) / 4 };
    for (0..dump.slot_count) |i| {
        dump.counts[i] = std.mem.readInt(u32, message.data[4 + i * 4 ..][0..4], .little);
    }
    return .{ .exit_status = exit_status, .coverage = dump };
}

/// Tells the guest to end its loop. `corpus.zig` never generates this value.
fn sendStopSentinel(io: std.Io, sock: net.Socket, dest: net.IpAddress) !void {
    var descriptor: [40]u8 = undefined;
    std.mem.writeInt(u64, descriptor[0..8], std.math.maxInt(u64), .little);
    @memset(descriptor[8..], 0);
    try sock.send(io, &dest, &descriptor);
}

/// Resend interval for iteration 0 after the first (short) attempt. It needs
/// to cover a full spawn/dispatch/teardown. A short interval here made the
/// guest process duplicate copies of the descriptor as separate iterations.
const first_iteration_resend_interval_ms: i64 = 8_000;

/// Sends iteration 0's descriptor, resending until a reply arrives or
/// `per_iteration_timeout_ms` elapses. The guest may not have its socket
/// open yet, so early datagrams can be dropped.
fn sendAndRetryFirstIteration(io: std.Io, sock: net.Socket, dest: net.IpAddress, wire: *const [40]u8, selector: u64) IterationReply {
    const first_attempt_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(per_attempt_timeout_ms),
        .clock = .awake,
    } };
    const later_attempt_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(first_iteration_resend_interval_ms),
        .clock = .awake,
    } };
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(per_iteration_timeout_ms));

    var first_attempt = true;
    while (true) {
        sock.send(io, &dest, wire) catch |err| {
            std.debug.print("kernel_fuzz: mutation loop send failed: {t}\n", .{err});
            std.process.exit(1);
        };

        const attempt_timeout = if (first_attempt) first_attempt_timeout else later_attempt_timeout;
        first_attempt = false;
        if (receiveIterationReply(io, sock, attempt_timeout)) |reply| return reply else |err| switch (err) {
            error.Timeout => {}, // resend
            else => {
                std.debug.print("kernel_fuzz: iteration 0 receive failed: {t}\n", .{err});
                std.process.exit(1);
            },
        }

        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) {
            std.debug.print("kernel_fuzz: no reply for iteration 0 (selector=0x{x}): gave up after {d}ms\n", .{ selector, per_iteration_timeout_ms });
            std.process.exit(1);
        }
    }
}

/// Sends a descriptor once and waits for the reply. No resend: the channel is
/// already open, and a duplicate delivery would desync the iteration counts.
fn sendOnce(io: std.Io, sock: net.Socket, dest: net.IpAddress, wire: *const [40]u8, iteration: usize, selector: u64) IterationReply {
    sock.send(io, &dest, wire) catch |err| {
        std.debug.print("kernel_fuzz: mutation loop send failed: {t}\n", .{err});
        std.process.exit(1);
    };
    const iteration_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(per_iteration_timeout_ms),
        .clock = .awake,
    } };
    return receiveIterationReply(io, sock, iteration_timeout) catch |err| {
        std.debug.print(
            "kernel_fuzz: no reply for iteration {d} (selector=0x{x}): {t}\n",
            .{ iteration, selector, err },
        );
        std.process.exit(1);
    };
}

/// Coverage-guided mutation loop. A descriptor that reaches a selector not
/// seen before goes into the corpus and can be mutated later. A descriptor
/// whose iteration exits non-zero (the kernel killed the target process) is
/// saved to the crash corpus.
fn runMutationLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    sock: net.Socket,
    dest: net.IpAddress,
    corpus_dir: ?[]const u8,
    baseline: CoverageDump,
) !void {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    std.debug.print("kernel_fuzz: mutation loop starting, seed=0x{x}, {d} iterations\n", .{ seed, mutation_loop_iterations });

    var best_seen = baseline;
    var fuzz_corpus: corpus.Corpus = .{ .max_entries = 64 };
    var crash_count: usize = 0;
    var interesting_count: usize = 0;

    var iteration: usize = 0;
    while (iteration < mutation_loop_iterations) : (iteration += 1) {
        // Explore/exploit: half the time mutate a corpus entry (if any),
        // otherwise generate a fresh descriptor.
        const to_send = if (fuzz_corpus.pickRandom(random)) |base|
            (if (random.boolean()) corpus.mutate(random, base, baseline.slot_count) else corpus.randomDescriptor(random, baseline.slot_count))
        else
            corpus.randomDescriptor(random, baseline.slot_count);

        var wire: [40]u8 = undefined;
        to_send.encode(&wire);

        // Only iteration 0 retries: it races the guest reopening its socket
        // between test functions. The wire format has no sequence number, so
        // retrying later iterations could desync host and guest.
        const reply = if (iteration == 0)
            sendAndRetryFirstIteration(io, sock, dest, &wire, to_send.selector)
        else
            sendOnce(io, sock, dest, &wire, iteration, to_send.selector);

        if (reply.exit_status != 0) {
            crash_count += 1;
            std.debug.print(
                "kernel_fuzz: iteration {d}: selector=0x{x} killed the target (exit_status={d})\n",
                .{ iteration, to_send.selector, reply.exit_status },
            );
            if (corpus_dir) |dir| corpus.save(io, dir, "crashes", iteration, reply.exit_status, to_send);
        }

        // "Interesting" = a slot going from zero to nonzero. Counters are
        // cumulative for the whole boot, so counting any increase would flag
        // every repeat hit of an already-seen selector.
        var newly_covered = false;
        for (0..reply.coverage.slot_count) |i| {
            if (best_seen.counts[i] == 0 and reply.coverage.counts[i] != 0) {
                best_seen.counts[i] = reply.coverage.counts[i];
                newly_covered = true;
            } else if (reply.coverage.counts[i] > best_seen.counts[i]) {
                best_seen.counts[i] = reply.coverage.counts[i];
            }
        }
        if (newly_covered) {
            interesting_count += 1;
            // The corpus is capped at 64 small entries; ignore allocation failure.
            fuzz_corpus.add(allocator, to_send) catch {};
            if (corpus_dir) |dir| corpus.save(io, dir, "interesting", iteration, null, to_send);
        }
    }

    try sendStopSentinel(io, sock, dest);

    var nonzero_slots: usize = 0;
    for (0..best_seen.slot_count) |i| {
        if (best_seen.counts[i] != 0) nonzero_slots += 1;
    }
    std.debug.print(
        "kernel_fuzz: mutation loop PASS: {d} iterations, {d} crash(es), {d} coverage-increasing descriptor(s), {d}/{d} selectors reached, corpus size {d}\n",
        .{ mutation_loop_iterations, crash_count, interesting_count, nonzero_slots, best_seen.slot_count, fuzz_corpus.entries.items.len },
    );
}
