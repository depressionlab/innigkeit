//! Real syscall-dispatch mutation loop (docs/test-system-plan.md section 5,
//! staging step 5). Repeatedly receives one (selector, args) descriptor from
//! the host, dispatches it through a freshly spawned, minimally-entitled
//! process, and replies with that iteration's exit status plus a fresh
//! coverage snapshot, until the host sends the stop sentinel or
//! `max_iterations` is reached. The one-shot version this replaced only
//! proved the wire format could move a single fixed, known-safe descriptor;
//! this drives however many descriptors the host's real mutation loop
//! (`tools/kernel_fuzz`) generates.
//!
//! Deliberately spawns a fresh `itest_fuzz_target` process every iteration
//! rather than reusing one across many descriptors: a descriptor is
//! expected, by design, to sometimes get the process killed by the kernel's
//! own fault isolation (`.claude/rules/x64.md`/`arm.md`) partway through --
//! exactly the "found a way to crash a process via syscall dispatch" signal
//! a syscall fuzzer wants to surface, not something to avoid. A fresh spawn
//! per iteration means that outcome cleanly ends one iteration rather than
//! leaving a half-dead server the next iteration would have to detect and
//! route around. This is the same sequential spawn/wait shape as
//! `integration.test.zig`'s already-proven 20-cycle no-leak loop -- never
//! two spawns racing (`.claude/rules/arm.md`'s still-open concurrent-spawn
//! race), only ever one process alive between full teardown and the next
//! spawn.
//!
//! Uses `endpoint.send()` (fire-and-forget), not `.call()`: `.call()` parks
//! the caller until the *receiver* explicitly replies, with no mechanism to
//! wake it if the receiver is destroyed first (the "TODO: seL4-style Reply
//! token" at the top of `capabilities/types/Endpoint.zig` is exactly this
//! gap) -- a descriptor that gets the fixture killed after `recv()` but
//! before any reply would hang this test's own kernel thread forever.
//! `send()` only blocks until the fixture's `recv()` picks the message up
//! (near-instant), and this test already needs to wait on the process's
//! `exit_notify` next regardless -- that already reports completion whether
//! the process exited cleanly or was killed, so no reply round-trip is
//! needed at all. `itest_fuzz_target` was updated to match (no more
//! `endpointReply` call). Fixing the underlying `Endpoint` gap for callers
//! that still need `.call()` semantics against a killable receiver is a
//! real, separate IPC-design question, flagged here rather than taken on as
//! part of this test.
//!
//! Only reachable when `stage4.zig` has already brought virtio-net up early
//! for `kernel_options.fuzz_channel_test` -- see that file's comment. Runs
//! after `fuzz_channel.test.zig` in the same suite, reusing the same port
//! (freed by that test's own `closeSocket`).

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

/// Wire shape of the host's syscall descriptor: selector + 4 words (matching
/// `capabilities.Message`'s tag+words shape), then a little-endian `u32`
/// sequence number. The host resends a descriptor whose reply is slow; the
/// sequence number lets this side tell a resend from a new descriptor. A
/// repeated number is answered from `last_reply` without dispatching again
/// (before this, the resend was dispatched as a second iteration, and every
/// later reply was attributed to the wrong descriptor on the host).
const descriptor_len = 8 + 4 * 8 + 4;

/// Reply: `u32` exit status, `u32` sequence number answered, then one `u32`
/// coverage count per `Syscall`.
const reply_len = 4 + 4 + syscall_count * 4;

/// Selector value the host sends to end the loop cleanly. No real `Syscall`
/// tag is anywhere near this value, so it cannot collide with a genuine
/// (if out-of-range) fuzzed descriptor.
const stop_sentinel: u64 = std.math.maxInt(u64);

/// Backstop on guest-side iterations, deliberately far above any run the host
/// would configure (`-Dfuzz_iterations`): the host decides how long a run is
/// and ends it with the stop sentinel. A host that dies mid-run is already
/// bounded by `recvDescriptor`'s own watchdog, so this only exists so the loop
/// can never be unbounded in principle. It used to be 100 and silently capped
/// longer campaigns.
const max_iterations: usize = 1 << 20;

/// Same bound as `smp.test.zig`'s watchdog: a genuinely lost wakeup (not
/// just a slow one -- see `per_iteration_hang_ns` below) fails loudly on
/// its own, not silently absorbed into a much longer overall budget.
const watchdog_ns: u64 = 60 * std.time.ns_per_s;

const descriptor_silence_ns: u64 = 30 * std.time.ns_per_s;

/// A fuzzed descriptor is expected, over enough random (selector, args)
/// tuples, to sometimes land on a syscall that legitimately blocks with
/// nothing that will ever wake it (`net_tcp_connect`'s handshake wait,
/// `net_udp_recv`, `futex_wait[_timeout]`, `nanosleep_ms` with a far
/// deadline, `wait_process` on a handle nothing signals, ...) when called
/// from a process with no real state backing the wait. That is not a
/// kernel bug on its own -- it is what those syscalls are supposed to do --
/// but it must not turn into "the mutation loop stalls for the rest of the
/// 100-iteration budget" or, worse, `watchdog_ns` failing the *whole test*.
/// A per-iteration bound well under `watchdog_ns` catches this: once it
/// trips, `runOneDescriptor` force-signals the process's own exit Notify
/// directly, exactly the mechanism `handlers/process.zig`'s `process_kill`
/// syscall already uses to unblock a waiter (`slot.notify.signal(1 |
/// (status << 8))`) -- just called here from kernel test code instead of
/// through a syscall trap, since this test already holds the same `*Notify`
/// pointer `process_kill` would have looked up from a capability handle.
///
/// This does not stop the target's own thread from actually running (there
/// is no real "force-kill a stuck kernel thread" primitive in this
/// codebase today -- `process_kill`'s own doc comment already describes it
/// as a signal, not a termination), so a genuinely-forever-blocked thread
/// stays parked, leaking its Process/Task slots for the rest of this boot.
/// Acceptable for a single bounded (`max_iterations`) test run; a real
/// fuzzing campaign wanting to run indefinitely would need that missing
/// primitive first -- flagged here rather than built as a side effect of
/// this loop.
const per_iteration_hang_ns: u64 = 10 * std.time.ns_per_s;

/// Exit-status marker for "this iteration's target never signalled its own
/// exit within `per_iteration_hang_ns`, so this test force-signalled it
/// itself." Distinct from every real `Process.ExitStatus` value (0, or
/// 128+signal, topping out at 139 for sigsegv today), so the host can tell
/// a real clean/killed outcome apart from an artificially unblocked one.
const hang_status: u8 = 0xFF;

/// Waits for `target`'s exit notify, but no longer than
/// `per_iteration_hang_ns`: past that, force-signals it directly (mirroring
/// `process_kill`'s own mechanism -- see `per_iteration_hang_ns`'s doc
/// comment) and returns `hang_status` instead of blocking the rest of the
/// mutation loop on one unlucky descriptor. `watchdog_ns` stays as an outer
/// safety net for the case where even the force-signal somehow doesn't
/// unblock the very next poll (it always should: `Notify.poll` reads
/// whatever `Notify.signal` just OR'd in under the same lock).
fn waitForExitOrForceUnblock(notify: *capabilities.Notify) !u8 {
    const start = wallclock.read();
    var force_signalled = false;
    while (true) {
        const bits = notify.poll(0xFF_01);
        if (bits != 0) return @truncate(bits >> 8);
        const elapsed_ns = @backingInt(wallclock.elapsed(start, wallclock.read()));
        if (!force_signalled and elapsed_ns > per_iteration_hang_ns) {
            log.info("target appears permanently blocked; force-signalling its exit notify", .{});
            notify.signal(@as(u64, 1) | (@as(u64, hang_status) << 8));
            force_signalled = true;
        }
        if (elapsed_ns > watchdog_ns) {
            log.err("watchdog tripped waiting for the fuzz target to exit (NIC rx ring holds an unread frame: {})", .{
                innigkeit.drivers.virtio.net.rxPending(),
            });
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    }
}

/// Syscalls whose first argument is a UDP socket id (`handlers/network.zig`:
/// `arg(.one) & 0xFF`). Socket ids are one global table with no owner, so a
/// fuzzed descriptor can name this test's own channel socket and close it,
/// read the host's next descriptor out from under it, or send junk to the
/// host -- three of four real campaigns ended exactly that way
/// (`net_udp_close` on the channel socket, after which the reply could not be
/// sent). That is a real property of the kernel (docs/test-system-plan.md
/// section 5), but the harness's own channel is not what is being fuzzed, so
/// a descriptor that would hit it is redirected to a neighbouring id.
fn avoidChannelSocket(msg: *capabilities.Message, channel_sock: u8) void {
    inline for (.{ Syscall.net_udp_send, Syscall.net_udp_recv, Syscall.net_udp_recv_nb, Syscall.net_udp_close }) |op| {
        if (msg.tag == @backingInt(op) and (msg.words[0] & 0xFF) == channel_sock) msg.words[0] ^= 1;
    }
}

/// Waits for one well-formed descriptor. A datagram of any other length is
/// dropped, not an error: the host's initial handshake resends its 26-byte
/// payload until it hears back, and one still in flight when this test opens
/// the (same) port would otherwise fail the whole run before it started.
fn recvDescriptor(sock: u8, buf: *[descriptor_len]u8, from: *socket.RecvFrom) !void {
    const start = wallclock.read();
    while (true) {
        if (socket.recvUdp(.kernel, sock, buf, from)) |n| {
            if (n == descriptor_len) return;
            continue;
        }
        if (@backingInt(wallclock.elapsed(start, wallclock.read())) > descriptor_silence_ns) {
            log.err("watchdog tripped waiting for the host's syscall descriptor (NIC rx ring holds an unread frame: {})", .{
                innigkeit.drivers.virtio.net.rxPending(),
            });
            return error.WatchdogTimeout;
        }
        const handle: innigkeit.Task.Scheduler.Handle = .get();
        handle.yield();
        handle.unlock();
    }
}

/// Spawns a fresh `itest_fuzz_target`, hands it `msg` over a one-shot
/// Endpoint, and waits for it to exit (cleanly or killed) or to appear
/// permanently blocked (`hang_status`). Returns the raw exit status byte
/// (`Process.ExitStatus` convention: 0 = clean, 128+signal = kernel-
/// initiated kill, or `hang_status` -- see `waitForExitOrForceUnblock`).
fn runOneDescriptor(msg: capabilities.Message) !u8 {
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

    // Fire-and-forget: unblocks as soon as the fixture's own recv() picks
    // the message up, regardless of what that process does with it
    // afterward. See this file's doc comment for why `.call()` is unsafe
    // here.
    endpoint.send(msg);

    return waitForExitOrForceUnblock(target.exit_notify);
}

test "fuzz target: a real mutation loop drives host-chosen syscall descriptors through a minimally-entitled process" {
    const sock = socket.openSocket(.kernel, port) orelse return error.SocketOpenFailed;
    defer socket.closeSocket(.kernel, sock);

    var iterations: usize = 0;
    var last_seq: ?u32 = null;
    var reply_buf: [reply_len]u8 = undefined;
    while (iterations < max_iterations) {
        var buf: [descriptor_len]u8 = undefined;
        var from: socket.RecvFrom = undefined;
        try recvDescriptor(sock, &buf, &from);

        const selector_raw = std.mem.readInt(u64, buf[0..8], .little);
        const seq = std.mem.readInt(u32, buf[40..44], .little);
        if (selector_raw == stop_sentinel) {
            log.info("stop sentinel received after {d} iteration(s)", .{iterations});
            break;
        }

        // A resend of the descriptor already answered: repeat the answer, do
        // not dispatch it again. An older number is a stale copy; drop it.
        if (last_seq) |last| {
            if (seq == last) {
                _ = socket.sendUdp(.kernel, sock, from.ip, from.port, &reply_buf);
                continue;
            }
            if (seq < last) continue;
        }

        var words: [4]u64 = undefined;
        for (&words, 0..) |*w, i| w.* = std.mem.readInt(u64, buf[8 + i * 8 ..][0..8], .little);

        var msg: capabilities.Message = .{ .tag = selector_raw, .words = words };
        avoidChannelSocket(&msg, sock);
        const exit_status = try runOneDescriptor(msg);

        if (std.enums.fromInt(Syscall, selector_raw)) |selector| {
            log.info("iteration {d}: dispatched {t} (selector={d}), exit_status={d}", .{
                seq, selector, selector_raw, exit_status,
            });
        } else {
            log.info("iteration {d}: selector {d} does not name a real syscall, exit_status={d}", .{
                seq, selector_raw, exit_status,
            });
        }

        var raw_coverage: [syscall_count]u32 = undefined;
        innigkeit.testing.fuzz_coverage.dumpInto(&raw_coverage);

        std.mem.writeInt(u32, reply_buf[0..4], exit_status, .little);
        std.mem.writeInt(u32, reply_buf[4..8], seq, .little);
        for (raw_coverage, 0..) |count, i| std.mem.writeInt(u32, reply_buf[8 + i * 4 ..][0..4], count, .little);
        last_seq = seq;
        iterations += 1;
        if (!socket.sendUdp(.kernel, sock, from.ip, from.port, &reply_buf)) {
            log.err("could not send the reply for iteration {d}; the channel socket was probably closed by a fuzzed descriptor", .{seq});
            return error.ReplySendFailed;
        }
    }
    if (iterations >= max_iterations) log.info("max_iterations ({d}) reached without a stop sentinel", .{max_iterations});
}
