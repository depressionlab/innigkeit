const innigkeit = @import("innigkeit");

/// Exit the process.
///
/// The kernel will terminate all threads in the process and release all
/// process resources. `status` is reserved for a future wait/waitpid API.
pub fn exit(status: u8) noreturn {
    _ = innigkeit.Syscall.invoke(.exit_process, .{status});
    unreachable;
}

/// ABI layout of the spawn spec passed to the kernel.
///
/// All pointer fields hold integer addresses into the calling process's
/// address space; the kernel validates every byte before reading.
pub const SpawnSpec = extern struct {
    path: usize,
    path_len: u32,
    argv: usize,
    argc: u32,
    cap_grants: usize,
    cap_grant_count: u32,
    _pad: u32 = 0,
};

/// Transfer a capability from the spawning process to the child.
///
/// `src_slot` is the handle in the parent's capability table.
/// `rights_raw` is the `Rights` bitfield as a u16; the kernel enforces
/// that the granted rights are a subset of the parent's own rights.
pub const CapGrant = extern struct {
    src_slot: u32,
    rights_raw: u16,
    _pad: u16 = 0,
};

/// Spawn a new process from the embedded initfs.
///
/// `path` is a null-terminated path string (max 255 chars) naming the ELF
/// binary inside initfs.  `grants` is an optional slice of capabilities to
/// copy into the child's table before the child starts executing.
///
/// Returns a Notify handle in the caller's capability table.  The Notify is
/// signalled (bit 1) when the child process terminates.  Pass the handle to
/// `waitProcess` to block until the child exits, or drop it with
/// `cap_delete` if you do not need to observe the exit.
pub fn spawn(path: [:0]const u8, grants: []const CapGrant) innigkeit.Syscall.Error!u32 {
    const spec = SpawnSpec{
        .path = @intFromPtr(path.ptr),
        .path_len = @intCast(path.len),
        .argv = 0,
        .argc = 0,
        .cap_grants = @intFromPtr(grants.ptr),
        .cap_grant_count = @intCast(grants.len),
    };
    const ret = innigkeit.Syscall.invoke(.spawn, .{@intFromPtr(&spec)});
    const handle = try innigkeit.Syscall.decode(ret);
    return @truncate(handle);
}

/// Block until the process associated with `notify_handle` exits.
///
/// `notify_handle` must be the value returned by `spawn`.  Returns as soon as
/// the child process's exit Notify is signalled.
pub fn waitProcess(notify_handle: u32) innigkeit.Syscall.Error!void {
    const ret = innigkeit.Syscall.invoke(.wait_process, .{@as(usize, notify_handle)});
    _ = try innigkeit.Syscall.decode(ret);
}
