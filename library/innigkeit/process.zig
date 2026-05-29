const innigkeit = @import("innigkeit");

/// Parsed argc from the ELF initial stack. Set by `callMainAndExit` before
/// `main` is called; zero until then.
pub var _argc: usize = 0;

/// Parsed argv pointer from the ELF initial stack. Valid when `_argc > 0`.
pub var _argv: [*][*:0]u8 = undefined;

/// Sentinel-terminated envp pointer. Valid when `_envp_count > 0`.
pub var _envp: [*:null]?[*:0]u8 = undefined;

/// Number of environment variables parsed from the initial stack. Zero until
/// `callMainAndExit` runs.
pub var _envp_count: usize = 0;

/// Returns the process argument vector as set by the kernel on startup.
/// The slice is valid for the lifetime of the process.
pub fn args() []const [*:0]const u8 {
    return @ptrCast(_argv[0.._argc]);
}

/// Returns the environment variable array as set by the kernel on startup.
/// Each entry is a null-terminated "KEY=value" string.
/// The slice is valid for the lifetime of the process.
pub fn environ() []const [*:0]const u8 {
    if (_envp_count == 0) return &.{};
    // All entries in [0.._envp_count] are non-null (we stopped counting at the null sentinel).
    return @ptrCast(_envp[0.._envp_count]);
}

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
    envp: usize = 0,
    envc: u32 = 0,
    _pad2: u32 = 0,
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

/// A single argument passed to the spawned process.
/// Matches the kernel ABI in spawn.zig.
///
/// `ptr` points to the string bytes (not necessarily null-terminated);
/// `len` is the byte count.
pub const Arg = extern struct {
    ptr: usize,
    len: u32,
    _pad: u32 = 0,

    /// Convenience constructor from a Zig slice.
    pub fn fromSlice(s: []const u8) Arg {
        return .{ .ptr = @intFromPtr(s.ptr), .len = @intCast(s.len) };
    }
};

/// A single environment variable passed to the spawned process.
/// Same memory layout as `Arg`; the string should be `KEY=VALUE` formatted.
pub const EnvVar = Arg;

/// Spawn a new process from the embedded initfs with no arguments.
pub fn spawn(path: [:0]const u8, grants: []const CapGrant) innigkeit.Syscall.Error!u32 {
    return spawnFull(path, &.{}, &.{}, grants);
}

/// Spawn a new process from the embedded initfs, passing argument strings.
///
/// `argv` is a slice of `Arg` entries; the kernel copies each string before
/// the child starts. `grants` transfers capabilities into the child.
///
/// Returns a Notify handle in the caller's capability table.  The Notify is
/// signalled (bit 1) when the child process terminates.
pub fn spawnWithArgs(
    path: [:0]const u8,
    argv: []const Arg,
    grants: []const CapGrant,
) innigkeit.Syscall.Error!u32 {
    return spawnFull(path, argv, &.{}, grants);
}

/// Spawn a new process with both argv and envp.
///
/// `argv` is a slice of argument `Arg` entries.
/// `envp` is a slice of `KEY=VALUE` environment `EnvVar` entries.
/// `grants` transfers capabilities into the child.
pub fn spawnFull(
    path: [:0]const u8,
    argv: []const Arg,
    envp: []const EnvVar,
    grants: []const CapGrant,
) innigkeit.Syscall.Error!u32 {
    const spec = SpawnSpec{
        .path = @intFromPtr(path.ptr),
        .path_len = @intCast(path.len),
        .argv = @intFromPtr(argv.ptr),
        .argc = @intCast(argv.len),
        .cap_grants = @intFromPtr(grants.ptr),
        .cap_grant_count = @intCast(grants.len),
        .envp = @intFromPtr(envp.ptr),
        .envc = @intCast(envp.len),
    };
    const ret = innigkeit.Syscall.invoke(.spawn, .{@intFromPtr(&spec)});
    const handle = try innigkeit.Syscall.decode(ret);
    return @truncate(handle);
}

/// Convenience wrapper: spawn with a slice of string slices (no CapGrants or envp).
///
/// Builds the `Arg` array on the stack (max 64 entries).
pub fn spawnArgs(path: [:0]const u8, argv: []const []const u8) innigkeit.Syscall.Error!u32 {
    var args_buf: [64]Arg = undefined;
    const argc = @min(argv.len, args_buf.len);
    for (argv[0..argc], 0..) |a, i| args_buf[i] = Arg.fromSlice(a);
    return spawnFull(path, args_buf[0..argc], &.{}, &.{});
}

/// Block until the process associated with `notify_handle` exits; returns its exit status.
///
/// `notify_handle` must be the value returned by `spawn`. Returns as soon as
/// the child process's exit Notify is signalled.
pub fn waitProcess(notify_handle: u32) innigkeit.Syscall.Error!u8 {
    const ret = innigkeit.Syscall.invoke(.wait_process, .{@as(usize, notify_handle)});
    return @truncate(try innigkeit.Syscall.decode(ret));
}
