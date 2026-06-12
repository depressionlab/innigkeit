//! Implementation of the `spawn` and `wait_process` syscalls.
//!
//! `spawn(spec_ptr)` -> notify_handle | error
//!   Reads a SpawnSpec from user memory, creates a new process, loads the
//!   named ELF from initfs, and returns a Notify capability handle that is
//!   signalled (with bit 1) when the child process exits.
//!
//! `wait_process(notify_handle)` -> 0 | error
//!   Waits until bit 1 of the specified Notify is set. Equivalent to
//!   cap_invoke(handle, .wait, 1) on a Notify, but provided as a convenience
//!   syscall that clearly communicates intent.

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const validate = @import("../validate.zig");
const validateUserBuffer = validate.validateUserBuffer;
const codesign = innigkeit.user.codesign;

const log = innigkeit.debug.log.scoped(.spawn);

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

/// Fallback process name used when the real name is too long.
const fallback_process_name = "?";

/// Execute the `spawn` syscall.
///
/// Returns the raw usize to store in rax (Notify handle on success, negated
/// errno on error).
pub fn syscallSpawn(
    spec_ptr_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const parent_process = innigkeit.user.Process.from(current_task.task);

    // -- 1. Validate and read SpawnSpec
    const spec = validate.readUser(SpawnSpec, spec_ptr_raw) catch return errCode(e.EFAULT);
    if (spec._pad != 0 or spec._pad2 != 0) return errCode(e.EINVAL);

    // -- 2. Validate and copy path
    if (spec.path_len == 0 or spec.path_len > max_path_len) return errCode(e.EINVAL);
    // +1 for null terminator
    if (!validateUserBuffer(spec.path, spec.path_len + 1)) return errCode(e.EFAULT);

    const path_buf = innigkeit.mem.heap.allocator.alloc(u8, spec.path_len + 1) catch
        return errCode(e.ENOMEM);
    // Free path_buf on any early return. loadAndStart takes ownership on the
    // happy path (it frees after use), so we track ownership with a sentinel.
    var path_buf_owned = true;
    defer if (path_buf_owned) innigkeit.mem.heap.allocator.free(path_buf);

    validate.copyFromUser(path_buf[0..spec.path_len], spec.path) catch return errCode(e.EFAULT);
    path_buf[spec.path_len] = 0;

    // Reject embedded nulls, they would silently truncate the path passed to the ELF loader.
    if (std.mem.indexOfScalar(u8, path_buf[0..spec.path_len], 0) != null)
        return errCode(e.EINVAL);

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
    defer if (proc_init_owned) innigkeit.mem.heap.allocator.free(proc_init);

    // Validate argc/argv
    if (spec.argc > max_argc) return errCode(e.EINVAL);
    var user_args: [max_argc]Arg = undefined;
    var total_arg_str_len: usize = 0;
    if (spec.argc > 0) {
        validate.copyFromUser(
            std.mem.sliceAsBytes(user_args[0..spec.argc]),
            spec.argv,
        ) catch return errCode(e.EFAULT);

        for (user_args[0..spec.argc]) |ua| {
            if (ua._pad != 0 or ua.len > max_single_arg_len) return errCode(e.EINVAL);
            if (!validateUserBuffer(ua.ptr, ua.len)) return errCode(e.EFAULT);
            total_arg_str_len += ua.len;
        }
        if (total_arg_str_len > max_total_arg_len) return errCode(e.EINVAL);
    }

    // Validate envc/envp
    if (spec.envc > max_envc) return errCode(e.EINVAL);
    var user_envs: [max_envc]Arg = undefined;
    var total_env_str_len: usize = 0;
    if (spec.envc > 0) {
        validate.copyFromUser(
            std.mem.sliceAsBytes(user_envs[0..spec.envc]),
            spec.envp,
        ) catch return errCode(e.EFAULT);

        for (user_envs[0..spec.envc]) |ue| {
            if (ue._pad != 0 or ue.len > max_single_env_len) return errCode(e.EINVAL);
            if (!validateUserBuffer(ue.ptr, ue.len)) return errCode(e.EFAULT);
            total_env_str_len += ue.len;
        }
        if (total_env_str_len > max_total_env_len) return errCode(e.EINVAL);
    }

    // Build combined proc_init buffer if either argv or envp is non-empty.
    if (spec.argc > 0 or spec.envc > 0) {
        const header_size = @sizeOf(usize) * (2 + spec.argc + spec.envc);
        const total_size = header_size + total_arg_str_len + total_env_str_len;

        const buf = innigkeit.mem.heap.allocator.alloc(u8, total_size) catch
            return errCode(e.ENOMEM);
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

        // Copy argv and envp string bytes inside a single access window
        // (every ua.ptr/ue.ptr range was validated above).
        var str_off: usize = header_size;
        const access: validate.UserAccess = .acquire();
        defer access.release();
        for (user_args[0..spec.argc]) |ua| {
            if (ua.len > 0) {
                const src = validate.userSliceConst(ua.ptr, ua.len) catch
                    return errCode(e.EFAULT); // unreachable: validated above
                @memcpy(buf[str_off..][0..ua.len], src);
            }
            str_off += ua.len;
        }
        for (user_envs[0..spec.envc]) |ue| {
            if (ue.len > 0) {
                const src = validate.userSliceConst(ue.ptr, ue.len) catch
                    return errCode(e.EFAULT); // unreachable: validated above
                @memcpy(buf[str_off..][0..ue.len], src);
            }
            str_off += ue.len;
        }
    }

    // -- 4. Validate and copy capability grants
    if (spec.cap_grant_count > max_cap_grants) return errCode(e.EINVAL);
    var grants_buf: [max_cap_grants]CapGrant = undefined;

    if (spec.cap_grant_count > 0) validate.copyFromUser(
        std.mem.sliceAsBytes(grants_buf[0..spec.cap_grant_count]),
        spec.cap_grants,
    ) catch return errCode(e.EFAULT);
    const grants = grants_buf[0..spec.cap_grant_count];

    // -- 5. Create the exit Notify
    const exit_notify = innigkeit.capabilities.Notify.create() catch return errCode(e.ENOMEM);
    // Give an extra ref to the process (so it can signal on exit).
    exit_notify.ref();
    // If we return early the caller ref is freed by the defer below; the process
    // ref will be freed once the child process is destroyed.
    var exit_notify_caller_owned = true;
    defer if (exit_notify_caller_owned) exit_notify.unref();

    // -- 6. Create the child process
    const child_process = innigkeit.user.Process.create(.{
        .name = innigkeit.user.Process.Name.fromSlice(path) catch
            innigkeit.user.Process.Name.fromSlice(fallback_process_name) catch unreachable,
    }) catch return errCode(e.ENOMEM);
    // Process.create adds 1 reference; we hold it until we spawn the thread.
    defer child_process.decrementReferenceCount();

    child_process.exit_notify = exit_notify; // process takes ownership of one ref

    // -- 7. Copy granted capabilities into child's table
    if (grants.len > 0) {
        parent_process.cap_table.lock.lock();
        defer parent_process.cap_table.lock.unlock();

        child_process.cap_table.lock.lock();
        defer child_process.cap_table.lock.unlock();

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
            _ = child_process.cap_table.insertLocked(info.cap_type, info.ptr, requested_rights) catch {
                innigkeit.capabilities.CapabilityTable.unrefObject(info.cap_type, info.ptr);
                log.warn("cap grant: child table full for slot {}", .{grant.src_slot});
                return errCode(e.ENOMEM);
            };
        }
    }

    // -- 8. Create kernel thread that will load the ELF.
    // Ownership of path_buf and proc_init transfers to loadAndStart on success.
    const load_thread = child_process.createThread(.{
        .entry = .prepare(loadAndStart, .{
            path_buf.ptr,
            path_buf.len,
            child_process,
            @as(usize, if (proc_init.len > 0) @intFromPtr(proc_init.ptr) else 0),
            proc_init.len,
        }),
    }) catch return errCode(e.ENOMEM);

    // Transfer buffer ownership to loadAndStart; disable the defers.
    path_buf_owned = false;
    proc_init_owned = false;

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&load_thread.task, .{ .initial = true });

    // -- 9. Insert Notify into parent's cap table
    parent_process.cap_table.lock.lock();
    defer parent_process.cap_table.lock.unlock();

    const handle = parent_process.cap_table.insertLocked(
        .notify,
        exit_notify,
        .{ .read = true, .write = false }, // read-only: can wait but not re-signal
    ) catch {
        // Undo: the process already holds its ref and will signal on exit.
        return errCode(e.ENOMEM);
    };
    // Caller's ref is now in the table; don't free it via the defer.
    exit_notify_caller_owned = false;

    // Sanitize path: replace non-printable bytes with '?' to prevent log injection.
    var safe_path_buf: [max_path_len + 1]u8 = undefined;
    for (path, 0..) |c, i| safe_path_buf[i] = if (c >= 0x20 and c < 0x7F) c else '?';
    log.debug("spawned '{s}' pid={d} -> notify handle {}", .{ safe_path_buf[0..path.len], child_process.pid, handle });

    return @intCast(handle);
}

/// Kernel thread entry: load ELF from initfs and jump to userspace.
///
/// Owns path_ptr[0..path_len] and (when non-zero) proc_init_ptr[0..proc_init_len].
/// On success (noreturn): startProcess frees proc_init; path_buf freed explicitly.
/// On any return path: defers free path_buf and proc_init, decrement child_process ref.
fn loadAndStart(
    path_ptr: [*]u8,
    path_len: usize,
    child_process: *innigkeit.user.Process,
    proc_init_ptr: usize,
    proc_init_len: usize,
) void {
    const path_buf = path_ptr[0..path_len];
    const proc_init: []u8 = if (proc_init_len > 0)
        (@as([*]u8, @ptrFromInt(proc_init_ptr)))[0..proc_init_len]
    else
        &.{};

    defer child_process.decrementReferenceCount();
    // path_buf is freed explicitly before startProcess; defer handles early returns.
    var path_freed = false;
    defer if (!path_freed) innigkeit.mem.heap.allocator.free(path_buf);
    // proc_init: freed by startProcess on noreturn success; defer handles error returns.
    defer if (proc_init.len > 0) innigkeit.mem.heap.allocator.free(proc_init);

    const path = path_buf[0 .. std.mem.indexOfScalar(u8, path_buf, 0) orelse path_buf.len];

    const elf_data = innigkeit.fs.initfs.findFile(path) orelse {
        log.err("spawn: '{s}' not found in initfs", .{path});
        return;
    };

    // Build the sidecar name: "<path>.codesig" (max_path_len + 8 bytes).
    var sig_name_buf: [max_path_len + 8]u8 = undefined;
    const sig_name = std.fmt.bufPrint(&sig_name_buf, "{s}.codesig", .{path}) catch unreachable;

    const opt_sig_data = innigkeit.fs.initfs.findFile(sig_name);

    const entitlements: codesign.Manifest.Entitlements = blk: {
        if (opt_sig_data) |sig_data| {
            const result = codesign.verify(elf_data, sig_data);
            if (result) |ents| {
                break :blk ents;
            } else |err| {
                log.err("spawn: '{s}' signature verification failed: {s}", .{ path, @errorName(err) });
                // Signature present but invalid: always refuse regardless of mode.
                return;
            }
        } else {
            if (innigkeit.config.security.enforce_code_signing) {
                log.err("spawn: '{s}' has no .codesig and enforcement is on", .{path});
                return;
            }
            log.warn("spawn: '{s}' has no .codesig, proceeding with full entitlements (debug mode)", .{path});
            // In permissive mode grant all entitlements so unsigned dev binaries work.
            break :blk .{
                .framebuffer = true,
                .storage = true,
                .network = true,
                .keyboard = true,
                .mouse = true,
                .spawn = true,
                .gpu = true,
                .secure_vault = true,
            };
        }
    };

    child_process.entitlements = entitlements;

    const current_task: innigkeit.Task.Current = .get();
    const thread: *innigkeit.user.Thread = .from(current_task.task);
    const address_space = &thread.process.address_space;

    const header = innigkeit.user.elf.Header.parse(elf_data) catch |err| {
        log.err("spawn: ELF parse error for '{s}': {t}", .{ path, err });
        return;
    };

    const entry_point = blk: {
        const va: innigkeit.VirtualAddress = .from(header.entry);
        if (va.getType() != .user) {
            log.err("spawn: ELF entry point is not in user range", .{});
            return;
        }
        break :blk va.toUser();
    };

    const program_header_table: []const u8 = phdr: {
        const loc = header.programHeaderTableLocation();
        break :phdr elf_data[loc.base..][0..loc.length];
    };

    // Map all loadable segments rw for initial population.
    {
        var iter = header.loadableRegionIterator(program_header_table);
        while (iter.next() catch null) |region| {
            _ = address_space.map(.{
                .base = region.virtual_range.address.toVirtualAddress(),
                .size = region.virtual_range.size,
                .protection = .{ .read = true, .write = true },
                .max_protection = .all,
                .type = .zero_fill,
            }) catch |err| {
                log.err("spawn: map failed: {t}", .{err});
                return;
            };
        }
    }

    // Copy ELF segment data. The destination ranges were just mapped by the
    // kernel into this (child) address space; keep one access window around
    // the whole multi-segment copy loop.
    {
        const access: validate.UserAccess = .acquire();
        defer access.release();

        var iter = header.loadableRegionIterator(program_header_table);
        while (iter.next() catch null) |region| {
            if (region.source_length == 0) continue;
            // Bounds-check the source range against the ELF file before slicing.
            if (region.source_base >= elf_data.len or
                region.source_length > elf_data.len - region.source_base)
            {
                log.err("spawn: ELF segment [{x}, +{x}) out of file bounds ({x})", .{
                    region.source_base, region.source_length, elf_data.len,
                });
                return;
            }
            const dst = region.virtual_range.byteSlice();
            @memcpy(
                dst[region.destination_offset..][0..region.source_length],
                elf_data[region.source_base..][0..region.source_length],
            );
        }
    }

    // Apply per-segment protections.
    {
        var iter = header.loadableRegionIterator(program_header_table);
        while (iter.next() catch null) |region| {
            address_space.changeProtection(
                region.virtual_range.toVirtualRange(),
                .{ .both = .{
                    .protection = region.protection,
                    .max_protection = region.protection,
                } },
            ) catch |err| {
                log.err("spawn: changeProtection failed: {t}", .{err});
                return;
            };
        }
    }

    // Compute AT_PHDR: find the PT_LOAD segment that covers e_phoff, then
    // adjust by the segment's file-to-virtual offset.
    const phdr_vaddr: usize = blk: {
        var iter = header.iterateProgramHeaders(program_header_table);
        while (iter.next()) |phdr| {
            if (phdr.type != .load) continue;
            if (phdr.offset <= header.program_header_offset and
                header.program_header_offset < phdr.offset + phdr.file_size)
            {
                break :blk @intCast(phdr.virtual_address +
                    (header.program_header_offset - phdr.offset));
            }
        }
        break :blk 0; // phdrs not covered by any PT_LOAD; PIE relocation unavailable
    };

    // Free path_buf explicitly (we're done with it and startProcess is noreturn on success).
    innigkeit.mem.heap.allocator.free(path_buf);
    path_freed = true;

    // proc_init ownership transfers to startProcess; it frees on noreturn success.
    // The defer above handles it if startProcess returns an error.
    thread.startProcess(entry_point, .{
        .phdr_vaddr = phdr_vaddr,
        .phnum = header.program_header_entry_count,
        .entry = header.entry,
        .proc_init = proc_init,
    }) catch |err| {
        log.err("spawn: thread.startProcess failed: {t}", .{err});
        return;
    };
    unreachable;
}

/// Negated POSIX errno values used as syscall return codes.
const e = struct {
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EINVAL: i64 = -22;
};

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

// Tests
test "spawn: validateUserBuffer accepts empty range regardless of pointer" {
    try std.testing.expect(validateUserBuffer(0, 0));
}

test "spawn: validateUserBuffer rejects null pointer" {
    try std.testing.expect(!validateUserBuffer(0, 1));
}

test "spawn: validateUserBuffer rejects pointer+len wrap-around" {
    try std.testing.expect(!validateUserBuffer(std.math.maxInt(usize), 2));
}

test "spawn: validateUserBuffer rejects kernel addresses" {
    var x: u8 = 0;
    try std.testing.expect(!validateUserBuffer(@intFromPtr(&x), 1));
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
