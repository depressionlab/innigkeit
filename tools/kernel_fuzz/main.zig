//! Host-side driver for the in-kernel corpus-feedback channel
//! (docs/test-system-plan.md section 5). Verifies staging step 2 (bytes
//! sent from the host reach a UDP-based debug service inside a QEMU-booted
//! kernel via `-Dfuzz_channel=true`'s hostfwd wiring, and a reply comes
//! back with the expected computed value), step 3 (a second datagram
//! carrying a real per-syscall-selector coverage snapshot is readable), and
//! steps 4-5 (a real mutation loop drives many (selector, args) tuples
//! through the real dispatch table by a minimally-entitled process, one per
//! datagram, coverage-guided against the running per-selector-hit-count
//! snapshot and with crash/interesting descriptors saved to disk).
//!
//! Deliberately does not share `library/innigkeit/syscall.zig`'s `Syscall`
//! enum to name each slot: host tools depend only on `library/root.zig`'s
//! `Library.Collection` (`core`, `filesystem`, ...), and `libinnigkeit` --
//! the guest-side syscall wrapper lib, with architecture-specific `asm` in
//! its `invoke`/callN functions -- isn't wired into that collection. The
//! mutation loop only needs the coverage dump's own length (how many
//! selectors exist) to bias its selector generation, which a raw index
//! already gives it -- see `corpus.zig`.
//!
//! Spawned (not waited on) by `build/FuzzChannelHarness.zig` *before* the
//! QEMU test-kernel run step, so it's already retrying against the
//! hostfwd'd port while the guest boots and its net-poll task comes up.
//! Exits 0 on a verified round trip plus a completed mutation loop,
//! non-zero otherwise -- the harness's `stop` step waits for this process
//! and fails the build on a non-zero exit or an unmet deadline. A crashing
//! descriptor found during the loop is *not* itself a non-zero exit: the
//! kernel's own fault isolation containing it is the expected, correct
//! outcome (`.claude/rules/x64.md`/`arm.md`) and gets logged/saved to the
//! corpus, not treated as a fuzz-harness failure. Only a channel that stops
//! responding (a real hang, or a malformed reply) fails the build.
const std = @import("std");
const net = std.Io.net;
const corpus = @import("corpus.zig");

/// Must match `src/innigkeit/testing/fuzz_channel.test.zig`'s listener port
/// and `build/QEMU.zig`'s `-Dfuzz_channel=true` hostfwd wiring.
const port: u16 = 9999;

/// Upper bound on how many little-endian u32 coverage slots a dump can
/// carry -- generous headroom over the current syscall count
/// (`library/innigkeit/syscall.zig`'s `Syscall` enum) so this doesn't need
/// updating every time a syscall is added. Each dump's own length says how
/// many slots it actually holds.
const max_coverage_slots: usize = 512;

/// Sent as the corpus "entry"; the kernel's reply must echo back the
/// wrapping byte-sum of this exact payload.
const payload = "innigkeit-fuzz-channel-poc";

/// How many real (selector, args) descriptors the mutation loop drives
/// through the guest before sending the stop sentinel. Must not exceed
/// `fuzz_target.test.zig`'s own `max_iterations` cap (that cap is the
/// guest's independent defense-in-depth bound, not the normal way the loop
/// ends -- this is). Kept modest: each iteration is a full process
/// spawn+dispatch+teardown under this sandbox's unaccelerated TCG (no KVM),
/// confirmed empirically to cost several real seconds each even without
/// hitting a blocking syscall, and this is a build-time gate, not an
/// unbounded fuzzing campaign.
const default_iterations: usize = 40;

/// Bounds one send-and-wait attempt: short enough that a boot still in
/// progress just costs a quick retry, not a long stall.
const per_attempt_timeout_ms: i64 = 300;

/// Bounds the whole round trip. Generous, not just for boot: the guest's
/// listener isn't opened until `testing/fuzz_channel.test.zig` actually
/// runs, which is near the end of the whole suite under unaccelerated TCG
/// (this sandbox has no KVM) -- every datagram sent before that socket
/// exists is silently dropped (no listener bound to the port yet), so this
/// must outlast the full suite's run time, not just boot. Confirmed
/// empirically: an earlier 20s bound sent 57 datagrams and gave up while
/// the guest was still dozens of tests away from this one. Still finite --
/// a channel that's actually broken must fail the build, not hang it.
const overall_timeout_ns: i96 = 180 * std.time.ns_per_s;

/// Bounds each mutation-loop iteration's send-and-wait: an iteration
/// involves a real process spawn/dispatch/teardown on the guest side, not
/// just an echo, so this is longer than `per_attempt_timeout_ms`. Comfortably
/// exceeds `fuzz_target.test.zig`'s own `per_iteration_hang_ns` (10s) plus
/// round-trip margin, since that file's own force-unblock mechanism is what's
/// actually supposed to bound how long a single descriptor can take -- this
/// timeout firing means the guest didn't even manage that, which is a real
/// build failure, not just an unlucky descriptor. Generous on top of that
/// bound: confirmed empirically that a plain (non-blocking) spawn+dispatch+
/// teardown cycle alone can take several real seconds under this sandbox's
/// unaccelerated TCG, before any blocking syscall or force-unblock is even
/// involved.
const per_iteration_timeout_ms: i64 = 45_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args_slice = try init.minimal.args.toSlice(init.arena.allocator());
    var corpus_dir: ?[]const u8 = null;
    var iterations: usize = default_iterations;
    var seed_override: ?u64 = null;
    var arg_index: usize = 1;
    while (arg_index < args_slice.len) : (arg_index += 1) {
        const arg = args_slice[arg_index];
        if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "--seed")) {
            arg_index += 1;
            if (arg_index >= args_slice.len) usageError("{s} needs a value", .{arg});
            const value = std.fmt.parseInt(u64, args_slice[arg_index], 0) catch
                usageError("{s} needs an integer, got '{s}'", .{ arg, args_slice[arg_index] });
            if (std.mem.eql(u8, arg, "--seed")) {
                seed_override = value;
            } else {
                if (value == 0) usageError("--iterations must be greater than zero", .{});
                iterations = std.math.cast(usize, value) orelse usageError("--iterations is too large", .{});
            }
        } else if (std.mem.startsWith(u8, arg, "--") or corpus_dir != null) {
            usageError("unexpected argument '{s}'", .{arg});
        } else {
            corpus_dir = arg;
        }
    }
    if (corpus_dir == null) {
        std.debug.print("kernel_fuzz: no corpus directory given, crash/interesting descriptors will not be saved\n", .{});
    }

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
                    try runMutationLoop(init.io, init.arena.allocator(), sock, dest, corpus_dir, before, iterations, seed_override);
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

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("kernel_fuzz: " ++ fmt ++ "\nusage: kernel_fuzz [corpus_dir] [--iterations N] [--seed S]\n", args);
    std.process.exit(2);
}

const CoverageDump = struct {
    counts: [max_coverage_slots]u32 = @splat(0),
    slot_count: usize,
};

/// Staging step 3: read one coverage-snapshot datagram, printing it as it's
/// parsed. Propagates `error.Timeout` normally (the caller decides whether
/// that's fatal or just means "not sent yet, retry") but exits directly on
/// a genuinely malformed reply -- that's never something retrying fixes.
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

/// Bytes on the wire for one descriptor: `corpus.Descriptor`'s 40 bytes, then
/// a little-endian `u32` sequence number. The sequence number is what makes a
/// resend safe: the guest answers a repeated number from its cached reply
/// instead of dispatching again, and the host discards any reply whose number
/// isn't the one it is waiting for. Without it, a resend that raced a slow
/// first reply (the spawn+ELF-load of iteration 0 outlasts the short first
/// resend interval) was dispatched as a second, separate iteration, and every
/// later reply was then attributed to the descriptor sent one step after the
/// one that produced it -- found when a real campaign's guest log ran one
/// iteration ahead of the host's, and the saved crash files named the wrong
/// descriptors.
const wire_len = 40 + 4;

fn encodeWire(d: corpus.Descriptor, seq: u32) [wire_len]u8 {
    var wire: [wire_len]u8 = undefined;
    d.encode(wire[0..40]);
    std.mem.writeInt(u32, wire[40..44], seq, .little);
    return wire;
}

/// One mutation-loop iteration's reply: `fuzz_target.test.zig` sends a
/// little-endian `u32` exit status, the `u32` sequence number of the
/// descriptor it answers, then a coverage dump in the same
/// self-describing-by-length shape `receiveCoverageDump` reads for the plain
/// (non-loop) case above.
const IterationReply = struct {
    exit_status: u8,
    seq: u32,
    coverage: CoverageDump,
};

const reply_header_len = 8;

fn receiveIterationReply(io: std.Io, sock: net.Socket, timeout: std.Io.Timeout) net.Socket.ReceiveTimeoutError!IterationReply {
    var buf: [reply_header_len + max_coverage_slots * 4]u8 = undefined;
    const message = try sock.receiveTimeout(io, &buf, timeout);
    if (message.data.len < reply_header_len or
        (message.data.len - reply_header_len) % 4 != 0 or
        (message.data.len - reply_header_len) / 4 > max_coverage_slots)
    {
        std.debug.print("kernel_fuzz: iteration reply has an unexpected length {d}\n", .{message.data.len});
        std.process.exit(1);
    }

    const exit_status: u8 = @truncate(std.mem.readInt(u32, message.data[0..4], .little));
    const seq = std.mem.readInt(u32, message.data[4..8], .little);
    var dump: CoverageDump = .{ .slot_count = (message.data.len - reply_header_len) / 4 };
    for (0..dump.slot_count) |i| {
        dump.counts[i] = std.mem.readInt(u32, message.data[reply_header_len + i * 4 ..][0..4], .little);
    }
    return .{ .exit_status = exit_status, .seq = seq, .coverage = dump };
}

/// Sends the stop sentinel (`corpus.zig`'s callers never generate this
/// value themselves -- see `interesting_selectors`' comment) so
/// `fuzz_target.test.zig` ends its loop and returns normally instead of
/// idling until its own watchdog trips.
fn sendStopSentinel(io: std.Io, sock: net.Socket, dest: net.IpAddress, seq: u32) !void {
    const sentinel: corpus.Descriptor = .{ .selector = std.math.maxInt(u64), .words = @splat(0) };
    const wire = encodeWire(sentinel, seq);
    try sock.send(io, &dest, &wire);
}

/// How long `exchange` waits for the first reply before resending. Separate
/// from `per_attempt_timeout_ms` (the initial handshake's resend interval) so
/// one can be tuned without flooding the guest through the other.
const first_reply_timeout_ms: i64 = 300;

/// How long to wait for a reply before resending, after the first attempt.
/// Matched to how long a real spawn+dispatch+teardown can legitimately take;
/// resending sooner is harmless now (the guest deduplicates by sequence
/// number) but only generates traffic.
const resend_interval_ms: i64 = 3_000;

/// Sends one descriptor and returns the guest's reply to *that* descriptor.
/// The first attempt waits only `first_reply_timeout_ms`, enough to bridge the
/// real gap between `fuzz_channel.test.zig` closing its socket and
/// `fuzz_target.test.zig` opening its own (a datagram sent into it is
/// silently dropped); every resend after that waits `resend_interval_ms`.
/// Replies carrying any other sequence number -- the answer to an earlier
/// resend -- are discarded. Gives up, and exits non-zero, after
/// `per_iteration_timeout_ms`.
fn exchange(io: std.Io, sock: net.Socket, dest: net.IpAddress, wire: *const [wire_len]u8, seq: u32, selector: u64) IterationReply {
    const first_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(first_reply_timeout_ms),
        .clock = .awake,
    } };
    const later_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(resend_interval_ms),
        .clock = .awake,
    } };
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(per_iteration_timeout_ms));

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        sock.send(io, &dest, wire) catch |err| {
            std.debug.print("kernel_fuzz: mutation loop send failed: {t}\n", .{err});
            std.process.exit(1);
        };
        const timeout = if (attempt == 0) first_timeout else later_timeout;
        if (receiveIterationReply(io, sock, timeout)) |reply| {
            if (reply.seq == seq) return reply;
            // The answer to an earlier resend of a previous descriptor; keep
            // waiting for this one.
        } else |err| switch (err) {
            error.Timeout => {}, // socket not open yet, or still processing: resend
            else => {
                std.debug.print("kernel_fuzz: receive failed for sequence {d}: {t}\n", .{ seq, err });
                std.process.exit(1);
            },
        }
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) {
            std.debug.print(
                "kernel_fuzz: no reply for iteration {d} (selector=0x{x}): gave up after {d}ms\n",
                .{ seq, selector, per_iteration_timeout_ms },
            );
            std.process.exit(1);
        }
    }
}

/// Staging step 5: the real corpus/mutation loop. Drives
/// `iterations` (selector, args) descriptors through the
/// guest's `fuzz_target.test.zig`, coverage-guided (a descriptor that moves
/// any coverage slot past its previous running-maximum count is saved to
/// the corpus and becomes eligible to be mutated further) and with a
/// separate crash corpus for any descriptor whose iteration ended with a
/// non-zero exit status (the kernel killed the fixture process -- contained
/// by fault isolation, not a build failure, but worth keeping for replay).
fn runMutationLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    sock: net.Socket,
    dest: net.IpAddress,
    corpus_dir: ?[]const u8,
    baseline: CoverageDump,
    iterations: usize,
    seed_override: ?u64,
) !void {
    var seed: u64 = undefined;
    if (seed_override) |pinned| {
        seed = pinned;
    } else {
        io.random(std.mem.asBytes(&seed));
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    std.debug.print("kernel_fuzz: mutation loop starting, seed=0x{x}, {d} iterations\n", .{ seed, iterations });

    var best_seen = baseline;
    var fuzz_corpus: corpus.Corpus = .{ .max_entries = 64 };
    var crash_count: usize = 0;
    var interesting_count: usize = 0;

    var iteration: usize = 0;
    while (iteration < iterations) : (iteration += 1) {
        // Half the time, mutate something already known to be interesting
        // (once the corpus has anything in it); otherwise generate fresh.
        // Classic explore/exploit split -- always fresh would never dig
        // deeper around a promising find, always-mutate would never
        // discover a new one to dig around.
        const to_send = if (fuzz_corpus.pickRandom(random)) |base|
            (if (random.boolean()) corpus.mutate(random, base, baseline.slot_count) else corpus.randomDescriptor(random, baseline.slot_count))
        else
            corpus.randomDescriptor(random, baseline.slot_count);

        const seq: u32 = @intCast(iteration);
        const wire = encodeWire(to_send, seq);
        const reply = exchange(io, sock, dest, &wire, seq, to_send.selector);

        if (reply.exit_status != 0) {
            crash_count += 1;
            std.debug.print(
                "kernel_fuzz: iteration {d}: killed the target (exit_status={d}) selector=0x{x} words=[0x{x}, 0x{x}, 0x{x}, 0x{x}]\n",
                .{
                    iteration,        reply.exit_status,
                    to_send.selector, to_send.words[0],
                    to_send.words[1], to_send.words[2],
                    to_send.words[3],
                },
            );
            if (corpus_dir) |dir| corpus.save(io, dir, "crashes", seed, iteration, reply.exit_status, to_send);
        }

        // "Interesting" means this descriptor reached a selector nothing
        // before it ever had -- a zero-to-nonzero transition, checked once
        // per slot. Counting every count *increase* instead (the first
        // version of this check did) is wrong: these counters are
        // cumulative for the whole boot, so a repeat dispatch of an
        // already-seen selector always increases its own count, making
        // every re-hit of the same selector look "newly interesting."
        // That bias is what a real run exposed: the corpus kept re-adding
        // and re-mutating variants of the first `nanosleep_ms` descriptor
        // it found (each repeat "increased coverage" by this metric),
        // crowding out exploration of selectors not yet reached at all.
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
            // Bounded to 64 entries of 40 bytes each: a real allocation
            // failure here would mean this host process is already in
            // serious trouble elsewhere, not something worth aborting the
            // whole run over.
            fuzz_corpus.add(allocator, to_send) catch {};
            if (corpus_dir) |dir| corpus.save(io, dir, "interesting", seed, iteration, null, to_send);
        }
    }

    try sendStopSentinel(io, sock, dest, @intCast(iterations));

    var nonzero_slots: usize = 0;
    for (0..best_seen.slot_count) |i| {
        if (best_seen.counts[i] != 0) nonzero_slots += 1;
    }
    std.debug.print(
        "kernel_fuzz: mutation loop PASS: {d} iterations, {d} crash(es), {d} coverage-increasing descriptor(s), {d}/{d} selectors reached, corpus size {d}\n",
        .{ iterations, crash_count, interesting_count, nonzero_slots, best_seen.slot_count, fuzz_corpus.entries.items.len },
    );
}
