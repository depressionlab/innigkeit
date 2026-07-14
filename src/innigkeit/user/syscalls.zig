//! Declarative syscall table + comptime-generated dispatch.

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");

const Syscall = libinnigkeit.Syscall;
const Error = libinnigkeit.Error;
const handlers = @import("handlers/root.zig");

pub const Context = @import("Context.zig");

/// The entitlement a syscall requires, as a field of the `Entitlements` packed
/// struct. `.none` means the syscall is unprivileged.
pub const Gate = enum {
    none,
    framebuffer,
    storage,
    network,
    keyboard,
    mouse,
    spawn,
    gpu,
    secure_vault,
};

const Handler = fn (Context) Error.Syscall!usize;

/// One row of the declarative syscall table.
const Entry = struct {
    syscall: Syscall,
    handler: *const Handler,
    gate: Gate,
};

/// Compact constructor for a table row (keeps the table itself readable).
fn sys(comptime syscall: Syscall, comptime handler: Handler, comptime gate: Gate) Entry {
    return .{ .syscall = syscall, .handler = handler, .gate = gate };
}

/// The single source of truth for migrated syscalls. Each row: selector,
/// handler, entitlement gate. Order is irrelevant (lookup is by selector).
const table = [_]Entry{
    sys(.yield, sysYield, .none),
    sys(.getpid, sysGetpid, .none),

    // memory
    sys(.mmap, handlers.memory.mmap, .none),
    sys(.munmap, handlers.memory.munmap, .none),
    sys(.vmem_map, handlers.vmem.vmemMap, .none),
    sys(.vmem_unmap, handlers.vmem.vmemUnmap, .none),

    // capabilities (cap_invoke checks rights per-op; cap_create's secure_vault /
    // gpu_buffer entitlement gates are conditional, enforced inside the handler)
    sys(.cap_invoke, handlers.capabilities.capInvoke, .none),
    sys(.cap_copy, handlers.capabilities.capCopy, .none),
    sys(.cap_move, handlers.capabilities.capMove, .none),
    sys(.cap_delete, handlers.capabilities.capDelete, .none),
    sys(.cap_create, handlers.capabilities.capCreate, .none),
    sys(.cap_revoke, handlers.capabilities.capRevoke, .none),

    // framebuffer / input / storage / initfs / time
    sys(.framebuffer_map, handlers.framebuffer.framebufferMap, .framebuffer),
    sys(.initfs_read, handlers.framebuffer.initfsRead, .none),
    sys(.uptime_ms, handlers.framebuffer.uptimeMs, .none),
    sys(.kbd_read, handlers.framebuffer.kbdRead, .keyboard),
    sys(.mouse_read, handlers.framebuffer.mouseRead, .mouse),
    sys(.blk_read, handlers.framebuffer.blkRead, .none),
    sys(.blk_write, handlers.framebuffer.blkWrite, .storage),

    // io / VFS files (open's storage gate is conditional on the write flag, so
    // it is enforced inside the handler, not as a blanket table gate)
    sys(.write, handlers.io.write, .none),
    sys(.read, handlers.io.read, .none),
    sys(.open, handlers.file.open, .none),
    sys(.close, handlers.file.close, .none),
    sys(.lseek, handlers.file.lseek, .none),
    sys(.fstat, handlers.file.fstat, .none),

    // simple flat filesystem
    sys(.fs_open, handlers.filesystem.fsOpen, .none),
    sys(.fs_read, handlers.filesystem.fsRead, .none),
    sys(.fs_write, handlers.filesystem.fsWrite, .none),
    sys(.fs_close, handlers.filesystem.fsClose, .none),

    // process/thread lifecycle
    sys(.spawn, handlers.spawn.spawn, .spawn),
    sys(.exit_thread, handlers.process.exitThread, .none),
    sys(.exit_process, handlers.process.exitProcess, .none),
    sys(.spawn_thread, handlers.process.spawnThread, .none),
    sys(.wait_process, handlers.process.waitProcess, .none),
    sys(.wait_process_nb, handlers.process.waitProcessNb, .none),
    sys(.process_kill, handlers.process.processKill, .none),

    // futex
    sys(.futex_wait, handlers.futex.futexWait, .none),
    sys(.futex_wait_timeout, handlers.futex.futexWaitTimeout, .none),
    sys(.futex_wake, handlers.futex.futexWake, .none),

    // misc / time / scheduling hint / device info
    sys(.nanosleep_ms, handlers.misc.nanosleepMs, .none),
    sys(.thread_set_hint, handlers.misc.threadSetHint, .none),
    sys(.thread_set_qos, handlers.misc.threadSetQos, .none),
    sys(.blk_disk_size, handlers.misc.blkDiskSize, .none),
    sys(.gpu_flush, handlers.misc.gpuFlush, .none),
    sys(.present, handlers.misc.present, .none),
    sys(.efi_var_get, handlers.misc.efiVarStub, .none),
    sys(.efi_var_set, handlers.misc.efiVarStub, .none),

    // UDP networking
    sys(.net_set_ip, handlers.network.netSetIp, .network),
    sys(.net_get_mac, handlers.network.netGetMac, .network),
    sys(.net_udp_open, handlers.network.netUdpOpen, .network),
    sys(.net_udp_send, handlers.network.netUdpSend, .network),
    sys(.net_udp_recv, handlers.network.netUdpRecv, .network),
    sys(.net_udp_recv_nb, handlers.network.netUdpRecvNb, .network),
    sys(.net_udp_close, handlers.network.netUdpClose, .network),
    sys(.net_ping, handlers.network.netPing, .network),

    // TCP networking (net_tcp_close is ungated to match legacy behavior)
    sys(.net_tcp_listen, handlers.network.netTcpListen, .network),
    sys(.net_tcp_accept, handlers.network.netTcpAccept, .network),
    sys(.net_tcp_connect, handlers.network.netTcpConnect, .network),
    sys(.net_tcp_send, handlers.network.netTcpSend, .network),
    sys(.net_tcp_recv, handlers.network.netTcpRecv, .network),
    sys(.net_tcp_close, handlers.network.netTcpClose, .none),
};

comptime {
    @setEvalBranchQuota(20_000); // O(n^2) scan over the (growing) table
    // No selector may appear twice in the table (the dispatch returns the first
    // match, so a duplicate would silently shadow), so we guard it comptime.
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            if (a.syscall == b.syscall) {
                @compileError("duplicate syscall in table: " ++ @tagName(a.syscall));
            }
        }
    }
}

/// The raw value returned for a syscall the table does not cover. The table is
/// exhaustive over the `Syscall` enum, so this is unreachable in practice; it is
/// a graceful degrade (and the answer for any future un-rowed selector).
pub const unsupported_code: usize = @bitCast(Error.code(Error.Syscall.Unsupported));

/// Service `syscall` and return the raw value to place in the return register
/// (a non-negative result, or a negated wire error code).
///
/// `switch (...) { inline else => |tag| }` makes the compiler emit one prong per
/// `Syscall` value (a jump table, O(1)) while the per-tag table lookup is
/// resolved entirely at comptime: each tag inlines its gate+handler. So the
/// declarative table costs nothing at runtime versus a hand-written switch.
pub fn dispatch(syscall: Syscall, frame: architecture.user.SyscallFrame) usize {
    // The generated dispatch is (every Syscall value)*(table scan).
    @setEvalBranchQuota(20_000);
    const context: Context = .{ .frame = frame };
    switch (syscall) {
        inline else => |tag| {
            inline for (table) |entry| {
                if (comptime entry.syscall == tag) {
                    if (comptime entry.gate != .none) {
                        if (!context.entitled(@tagName(entry.gate)))
                            return wire(Error.Syscall.PermissionDenied);
                    }

                    return entry.handler(context) catch |err| wire(err);
                }
            }

            return unsupported_code;
        },
    }
}

/// Map an `Error.Syscall` to the bit pattern delivered in the return register.
inline fn wire(err: Error.Syscall) usize {
    return @bitCast(Error.code(err));
}

/// yield() -> void : voluntarily give up the CPU to another runnable thread.
fn sysYield(_: Context) Error.Syscall!usize {
    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.yield();
    scheduler_handle.unlock();
    return 0;
}

/// getpid() -> pid : stable opaque per-process identifier (a counter, not a ptr).
fn sysGetpid(context: Context) Error.Syscall!usize {
    return context.process().pid;
}
