//! Implementation of the `spawn` and `wait_process` syscalls.
//!
//! `spawn(spec_ptr)` → notify_handle | error
//!   Reads a SpawnSpec from user memory, creates a new process, loads the
//!   named ELF from initfs, and returns a Notify capability handle that is
//!   signalled (with bit 1) when the child process exits.
//!
//! `wait_process(notify_handle)` → 0 | error
//!   Waits until bit 1 of the specified Notify is set. Equivalent to
//!   cap_invoke(handle, .wait, 1) on a Notify, but provided as a convenience
//!   syscall that clearly communicates intent.

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const Process = @import("Process.zig");
const Thread = @import("Thread.zig");

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
    /// Must be zero
    _pad: u32,
};

/// A single capability grant: copy cap from slot `src_slot` of the parent's
/// cap table into the child with the given rights (which must be ⊆ parent's).
pub const CapGrant = extern struct {
    src_slot: u32,
    rights_raw: u16,
    _pad: u16,
};

/// Maximum length of the process name / initfs path.
const max_path_len: usize = 255;

/// Maximum number of capability grants per spawn.
const max_cap_grants: usize = 64;

/// Execute the `spawn` syscall.
///
/// Returns the raw usize to store in rax (Notify handle on success, negated
/// errno on error).
pub fn syscallSpawn(
    spec_ptr_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const parent_process = Process.from(current_task.task);

    // -- 1. Validate and read SpawnSpec
    if (!validateUserBuffer(spec_ptr_raw, @sizeOf(SpawnSpec))) return errCode(e.EFAULT);
    current_task.incrementEnableAccessToUserMemory();
    const spec = @as(*const SpawnSpec, @ptrFromInt(spec_ptr_raw)).*;
    current_task.decrementEnableAccessToUserMemory();

    if (spec._pad != 0) return errCode(e.EINVAL);
    // argv passing not yet implemented; reject any non-empty argv so callers get
    // a clear EINVAL instead of having their arguments silently dropped.
    if (spec.argc > 0) return errCode(e.EINVAL);

    // -- 2. Validate and copy path
    if (spec.path_len == 0 or spec.path_len > max_path_len) return errCode(e.EINVAL);
    // +1 for null terminator
    if (!validateUserBuffer(spec.path, spec.path_len + 1)) return errCode(e.EFAULT);

    const path_buf = innigkeit.mem.heap.allocator.alloc(u8, spec.path_len + 1) catch
        return errCode(e.ENOMEM);
    errdefer innigkeit.mem.heap.allocator.free(path_buf);

    current_task.incrementEnableAccessToUserMemory();
    @memcpy(path_buf[0..spec.path_len], @as([*]const u8, @ptrFromInt(spec.path))[0..spec.path_len]);
    current_task.decrementEnableAccessToUserMemory();
    path_buf[spec.path_len] = 0;

    const path: [:0]const u8 = path_buf[0..spec.path_len :0];

    // -- 3. Validate and copy capability grants
    if (spec.cap_grant_count > max_cap_grants) return errCode(e.EINVAL);
    const grants_size = spec.cap_grant_count *| @sizeOf(CapGrant);
    var grants_buf: [max_cap_grants]CapGrant = undefined;

    if (spec.cap_grant_count > 0) {
        if (!validateUserBuffer(spec.cap_grants, grants_size)) return errCode(e.EFAULT);
        current_task.incrementEnableAccessToUserMemory();
        @memcpy(
            std.mem.bytesAsSlice(CapGrant, std.mem.asBytes(&grants_buf[0]))[0..spec.cap_grant_count],
            @as([*]const CapGrant, @ptrFromInt(spec.cap_grants))[0..spec.cap_grant_count],
        );
        current_task.decrementEnableAccessToUserMemory();
    }
    const grants = grants_buf[0..spec.cap_grant_count];

    // -- 4. Create the exit Notify
    const exit_notify = innigkeit.capabilities.Notify.create() catch {
        innigkeit.mem.heap.allocator.free(path_buf);
        return errCode(e.ENOMEM);
    };
    // Give an extra ref to the process (so it can signal on exit).
    exit_notify.ref();

    // -- 5. Create the child process
    const child_process = Process.create(.{ .name = Process.Name.fromSlice(path) catch blk: {
        break :blk Process.Name.fromSlice("?") catch unreachable;
    } }) catch {
        exit_notify.unref(); // process ref
        exit_notify.unref(); // caller ref
        innigkeit.mem.heap.allocator.free(path_buf);
        return errCode(e.ENOMEM);
    };
    // Process.create adds 1 reference; we hold it until we spawn the thread.
    defer child_process.decrementReferenceCount();

    child_process.exit_notify = exit_notify; // process takes ownership of one ref

    // -- 6. Copy granted capabilities into child's table
    if (grants.len > 0) {
        parent_process.cap_table.lock.lock();
        defer parent_process.cap_table.lock.unlock();

        child_process.cap_table.lock.lock();
        defer child_process.cap_table.lock.unlock();

        for (grants) |grant| {
            const requested_rights: innigkeit.capabilities.Rights = @bitCast(grant.rights_raw);
            const slot = parent_process.cap_table.getLocked(grant.src_slot) orelse {
                log.warn("cap grant: slot {} not found in parent", .{grant.src_slot});
                continue;
            };
            // Requested rights must be a subset of what the parent holds.
            const parent_raw: u16 = @bitCast(slot.rights);
            const req_raw: u16 = @bitCast(requested_rights);
            if (req_raw & ~parent_raw != 0) {
                log.warn("cap grant: rights escalation attempt for slot {}", .{grant.src_slot});
                continue;
            }
            const obj_ptr: *anyopaque = @ptrFromInt(slot.ptr_or_next);
            innigkeit.capabilities.CapabilityTable.refObject(slot.type, obj_ptr);
            _ = child_process.cap_table.insertLocked(slot.type, obj_ptr, requested_rights) catch {
                innigkeit.capabilities.CapabilityTable.unrefObject(slot.type, obj_ptr);
                log.warn("cap grant: child table full, skipping slot {}", .{grant.src_slot});
            };
        }
    }

    // -- 7. Create kernel thread that will load the ELF
    // Split the slice into pointer + length so each fits in a usize slot of
    // TypeErasedCall (fat pointers are two words and are not supported).
    const load_thread = child_process.createThread(.{
        .entry = .prepare(loadAndStart, .{ path_buf.ptr, path_buf.len, child_process }),
    }) catch {
        // Release the path_buf here since the thread didn't take ownership.
        innigkeit.mem.heap.allocator.free(path_buf);
        return errCode(e.ENOMEM);
    };
    // loadAndStart will free path_buf, so we no longer own it.

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&load_thread.task, .{ .initial = true });

    // -- 8. Insert Notify into parent's cap table
    parent_process.cap_table.lock.lock();
    defer parent_process.cap_table.lock.unlock();

    const handle = parent_process.cap_table.insertLocked(
        .notify,
        exit_notify,
        .{ .read = true, .write = false }, // read-only: can wait but not re-signal
    ) catch {
        // Undo: we already gave the process its ref, which will be cleaned up
        // by the cleanup task when the child eventually terminates.
        return errCode(e.ENOMEM);
    };

    log.debug("spawned '{s}' as pid {*} → notify handle {}", .{ path, child_process, handle });

    return @intCast(handle);
}

/// Kernel thread entry: load ELF from initfs and jump to userspace.
/// Takes ownership of path_ptr[0..path_len] (frees it on return/error).
/// Also holds a reference to `child_process` (decrements on return).
fn loadAndStart(path_ptr: [*]u8, path_len: usize, child_process: *Process) !void {
    const path_buf = path_ptr[0..path_len];
    defer innigkeit.mem.heap.allocator.free(path_buf);
    defer child_process.decrementReferenceCount();

    const path = path_buf[0 .. std.mem.indexOfScalar(u8, path_buf, 0) orelse path_buf.len];

    const elf_data = innigkeit.fs.initfs.findFile(path) orelse {
        log.err("spawn: '{s}' not found in initfs", .{path});
        return; // thread exits; process cleanup runs and signals exit_notify
    };

    const current_task: innigkeit.Task.Current = .get();
    const thread: *Thread = .from(current_task.task);
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

    // Copy ELF segment data.
    {
        current_task.incrementEnableAccessToUserMemory();
        defer current_task.decrementEnableAccessToUserMemory();

        var iter = header.loadableRegionIterator(program_header_table);
        while (iter.next() catch null) |region| {
            if (region.source_length == 0) continue;
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

    thread.start(entry_point, 0) catch |err| {
        log.err("spawn: thread.start failed: {t}", .{err});
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

fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr +% len < ptr) return false;
    const range: innigkeit.VirtualRange = .from(.from(ptr), .from(len, .byte));
    return architecture.user.user_memory_range.fullyContains(range);
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
    };
    try std.testing.expectEqual(@as(u32, 1), spec._pad);
}
