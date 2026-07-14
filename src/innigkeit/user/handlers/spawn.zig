//! Implementation of the `spawn` syscall.
//!
//! `spawn(spec_ptr)` -> notify_handle | error
//!   Reads a SpawnSpec from user memory, resolves capability grants against
//!   the parent's cap table, then hands off to
//!   `innigkeit.user.Process.spawnFromInitfs` (the kernel-internal spawn
//!   API, also callable directly by kernel tests) to create the child
//!   process, load the named ELF from initfs, and jump to it. Returns a
//!   `Notify` capability handle that is signalled (bit 0 = exited, bits 8..15
//!   = exit status) when the child process exits.

const innigkeit = @import("innigkeit");
const std = @import("std");
const log = innigkeit.debug.log.scoped(.spawn);

const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");
const validate = @import("../validate.zig");

/// The layout of the SpawnSpec struct as seen in user memory.
pub const SpawnSpec = extern struct {
    /// Pointer to a null-terminated path string
    path: usize,
    /// Byte length excluding the null terminator (max 255)
    path_len: u32,
    /// Pointer to an array of Arg structs (may be 0/null)
    argv: usize,
    /// Number of entries in the `argv` array
    argc: u32,
    /// Pointer to an array of CapGrant structs (may be 0)
    cap_grants: usize,
    /// Number of entries in the `cap_grants` array
    cap_grant_count: u32,
    /// Reserved; must be zero
    _pad: u32,
    /// Pointer to an array of Arg structs for environment variables (may be 0)
    envp: usize,
    /// Number of entries in the `envp` array
    envc: u32,
    /// Reserved; must be zero
    _pad2: u32,
};

/// A single capability grant: copy cap from slot `src_slot` of the parent's
/// cap table into the child with the given rights (which must be ⊆ parent's).
pub const CapGrant = extern struct {
    src_slot: u32,
    rights_raw: u16,
    _pad: u16,
};

/// A single argument passed to the spawned process.
/// `ptr` is a user-space address; `len` is the byte length (no null required).
pub const Arg = extern struct {
    ptr: usize,
    len: u32,
    _pad: u32,
};

/// Maximum length of the process name / initfs path.
const max_path_len: usize = 255;

/// Maximum number of capability grants per spawn.
const max_cap_grants: usize = 64;

/// Maximum number of argv entries.
const max_argc: usize = 64;

/// Maximum byte length of a single argument string.
const max_single_arg_len: usize = 4095;

/// Maximum total byte length of all argument strings combined.
const max_total_arg_len: usize = 8 * 1024;

/// Maximum number of environment variable entries.
const max_envc: usize = 128;

/// Maximum byte length of a single environment variable string.
const max_single_env_len: usize = 4095;

/// Maximum total byte length of all environment strings combined.
const max_total_env_len: usize = 16 * 1024;

/// Execute the `spawn` syscall.
///
/// Returns the raw usize to store in rax (Notify handle on success, negated
/// errno on error).
pub fn spawn(context: Context) Error.Syscall!usize {
    const spec_ptr_raw = context.arg(.one);
    const parent_process = context.process();

    // -- 1. Validate and read SpawnSpec
    const spec = try validate.readUser(SpawnSpec, spec_ptr_raw);
    if (spec._pad != 0 or spec._pad2 != 0) return Error.Syscall.InvalidArgument;

    // -- 2. Validate and copy path
    if (spec.path_len == 0 or spec.path_len > max_path_len) return Error.Syscall.InvalidArgument;
    // +1 for null terminator
    if (!validate.userBuffer(spec.path, spec.path_len + 1)) return Error.Syscall.BadAddress;

    const path_buf = try innigkeit.memory.heap.allocator.alloc(u8, spec.path_len + 1);
    // spawnFromInitfs only borrows `path` (making its own heap copy), so
    // path_buf is always ours to free, unconditionally.
    defer innigkeit.memory.heap.allocator.free(path_buf);

    try validate.copyFromUser(path_buf[0..spec.path_len], spec.path);
    path_buf[spec.path_len] = 0;

    // Reject embedded nulls, they would silently truncate the path passed to the ELF loader.
    if (std.mem.findScalar(u8, path_buf[0..spec.path_len], 0) != null)
        return Error.Syscall.InvalidArgument;

    const path: [:0]const u8 = path_buf[0..spec.path_len :0];

    // -- 3. Validate and copy argv + envp into a combined proc_init buffer.
    //
    // Buffer format when either argc or envc is non-zero:
    //   [argc: usize][envc: usize]
    //   [arg_len0..arg_len(argc-1): usize each]
    //   [env_len0..env_len(envc-1): usize each]
    //   [argv string bytes concatenated]
    //   [envp string bytes concatenated]
    //
    // When both argc=0 and envc=0, proc_init is an empty slice.
    var proc_init: []u8 = &.{};
    var proc_init_owned = false;
    defer if (proc_init_owned) innigkeit.memory.heap.allocator.free(proc_init);

    // Validate argc/argv
    if (spec.argc > max_argc) return Error.Syscall.InvalidArgument;
    var user_args: [max_argc]Arg = undefined;
    var total_arg_str_len: usize = 0;
    if (spec.argc > 0) {
        try validate.copyFromUser(
            std.mem.sliceAsBytes(user_args[0..spec.argc]),
            spec.argv,
        );

        for (user_args[0..spec.argc]) |ua| {
            if (ua._pad != 0 or ua.len > max_single_arg_len) return Error.Syscall.InvalidArgument;
            if (!validate.userBuffer(ua.ptr, ua.len)) return Error.Syscall.BadAddress;
            total_arg_str_len += ua.len;
        }
        if (total_arg_str_len > max_total_arg_len) return Error.Syscall.InvalidArgument;
    }

    // Validate envc/envp
    if (spec.envc > max_envc) return Error.Syscall.InvalidArgument;
    var user_envs: [max_envc]Arg = undefined;
    var total_env_str_len: usize = 0;
    if (spec.envc > 0) {
        try validate.copyFromUser(
            std.mem.sliceAsBytes(user_envs[0..spec.envc]),
            spec.envp,
        );

        for (user_envs[0..spec.envc]) |ue| {
            if (ue._pad != 0 or ue.len > max_single_env_len) return Error.Syscall.InvalidArgument;
            if (!validate.userBuffer(ue.ptr, ue.len)) return Error.Syscall.BadAddress;
            total_env_str_len += ue.len;
        }
        if (total_env_str_len > max_total_env_len) return Error.Syscall.InvalidArgument;
    }

    // Build combined proc_init buffer if either argv or envp is non-empty.
    if (spec.argc > 0 or spec.envc > 0) {
        const header_size = @sizeOf(usize) * (2 + spec.argc + spec.envc);
        const total_size = header_size + total_arg_str_len + total_env_str_len;

        const buf = try innigkeit.memory.heap.allocator.alloc(u8, total_size);
        proc_init = buf;
        proc_init_owned = true;

        const S = @sizeOf(usize);
        std.mem.writeInt(usize, buf[0..S], spec.argc, .little);
        std.mem.writeInt(usize, buf[S .. 2 * S], spec.envc, .little);

        // Write arg length table
        for (user_args[0..spec.argc], 0..) |ua, i| {
            std.mem.writeInt(usize, buf[(2 + i) * S ..][0..S], ua.len, .little);
        }
        // Write env length table
        for (user_envs[0..spec.envc], 0..) |ue, i| {
            std.mem.writeInt(usize, buf[(2 + spec.argc + i) * S ..][0..S], ue.len, .little);
        }

        // Copy argv/envp string bytes via the fault-safe `copyFromUser`, so a
        // concurrently-unmapped argv/envp page (a sibling thread racing the
        // spawn) returns EFAULT instead of panicking the kernel, and no UserAccess
        // window is held. Every range was validated above.
        var str_off: usize = header_size;
        for (user_args[0..spec.argc]) |ua| {
            if (ua.len > 0) try validate.copyFromUser(buf[str_off..][0..ua.len], ua.ptr);
            str_off += ua.len;
        }
        for (user_envs[0..spec.envc]) |ue| {
            if (ue.len > 0) try validate.copyFromUser(buf[str_off..][0..ue.len], ue.ptr);
            str_off += ue.len;
        }
    }

    // -- 4. Validate and copy capability grants, then resolve against
    // the parent's `CapabilityTable` (rights must be a subset of what it holds).
    // `spawnFromInitfs` only performs the child-side insert, so we must handle
    // capability checking.
    if (spec.cap_grant_count > max_cap_grants) return Error.Syscall.InvalidArgument;
    var grants_buf: [max_cap_grants]CapGrant = undefined;

    if (spec.cap_grant_count > 0) try validate.copyFromUser(
        std.mem.sliceAsBytes(grants_buf[0..spec.cap_grant_count]),
        spec.cap_grants,
    );
    const grants = grants_buf[0..spec.cap_grant_count];

    var resolved_grants_buf: [max_cap_grants]innigkeit.user.Process.ResolvedCapGrant = undefined;
    var resolved_grants_count: usize = 0;
    if (grants.len > 0) {
        parent_process.cap_table.lock.lock();
        defer parent_process.cap_table.lock.unlock();

        for (grants) |grant| {
            const requested_rights: innigkeit.capabilities.Rights = @bitCast(grant.rights_raw);
            const info = parent_process.cap_table.getAndRefLocked(grant.src_slot) orelse {
                log.warn("cap grant: slot {} not found in parent", .{grant.src_slot});
                continue;
            };
            // Requested rights must be a subset of what the parent holds.
            const parent_raw: u16 = @bitCast(info.rights);
            const req_raw: u16 = @bitCast(requested_rights);
            if (req_raw & ~parent_raw != 0) {
                innigkeit.capabilities.CapabilityTable.unrefObject(info.cap_type, info.ptr);
                log.warn("cap grant: rights escalation attempt for slot {}", .{grant.src_slot});
                continue;
            }
            resolved_grants_buf[resolved_grants_count] = .{
                .cap_type = info.cap_type,
                .ptr = info.ptr,
                .rights = requested_rights,
            };
            resolved_grants_count += 1;
        }
    }

    // -- 5-8. Create the child process, insert resolved grants, and load the ELF.
    // spawnFromInitfs borrows `path` (making its own coy) but takes proc_init
    // ownership unconditionally; path_buf is still freed by this function's
    // own defer below.
    proc_init_owned = false;

    const result = try innigkeit.user.Process.spawnFromInitfs(.{
        .path = path,
        .proc_init = proc_init,
        .cap_grants = resolved_grants_buf[0..resolved_grants_count],
    });
    const child_process = result.child;
    const exit_notify = result.exit_notify;
    // If we return early from here the caller reference is freed by the defer
    // below; the process reference is freed once the child process is destroyed.
    var exit_notify_caller_owned = true;
    defer if (exit_notify_caller_owned) exit_notify.unref();

    // -- 9. Insert Notify into parent's cap table
    parent_process.cap_table.lock.lock();
    defer parent_process.cap_table.lock.unlock();

    const handle = parent_process.cap_table.insertLocked(
        .notify,
        exit_notify,
        .{ .read = true, .write = false }, // read-only: can wait but not re-signal
    ) catch {
        // Undo: the process already holds its ref and will signal on exit.
        return Error.Syscall.OutOfMemory;
    };
    // Caller's ref is now in the table; don't free it via the defer.
    exit_notify_caller_owned = false;

    // Sanitize path: replace non-printable bytes with '?' to prevent log injection.
    var safe_path_buf: [max_path_len + 1]u8 = undefined;
    for (path, 0..) |c, i| safe_path_buf[i] = if (c >= 0x20 and c < 0x7F) c else '?';
    log.debug("spawned '{s}' pid={d} -> notify handle {}", .{ safe_path_buf[0..path.len], child_process.pid, handle });

    return @intCast(handle);
}

// Tests
test "spawn: validateUserBuffer accepts empty range regardless of pointer" {
    try std.testing.expect(validate.userBuffer(0, 0));
}

test "spawn: validateUserBuffer rejects null pointer" {
    try std.testing.expect(!validate.userBuffer(0, 1));
}

test "spawn: validateUserBuffer rejects pointer+len wrap-around" {
    try std.testing.expect(!validate.userBuffer(std.math.maxInt(usize), 2));
}

test "spawn: validateUserBuffer rejects kernel addresses" {
    var x: u8 = 0;
    try std.testing.expect(!validate.userBuffer(@intFromPtr(&x), 1));
}

test "spawn: SpawnSpec _pad field must be zero (field exists in struct)" {
    // Verify the reserved field can hold a non-zero value so the check is reachable.
    const spec: SpawnSpec = .{
        .path = 0,
        .path_len = 1,
        .argv = 0,
        .argc = 0,
        .cap_grants = 0,
        .cap_grant_count = 0,
        ._pad = 1,
        .envp = 0,
        .envc = 0,
        ._pad2 = 0,
    };
    try std.testing.expectEqual(@as(u32, 1), spec._pad);
}
