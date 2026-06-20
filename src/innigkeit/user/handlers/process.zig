//! Process / thread lifecycle syscalls:
//!   exit_thread, exit_process  (terminate the caller, never return)
//!   spawn_thread               (create a new thread in the current process)
//!   wait_process, wait_process_nb, process_kill (operate on an exit Notify cap)

const innigkeit = @import("innigkeit");

const Process = @import("../Process.zig");
const Thread = @import("../Thread.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// exit_thread() : terminate the calling thread (does not return).
pub fn exitThread(_: Context) Error.Syscall!usize {
    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
    unreachable;
}

/// exit_process(status) : record the exit status and terminate the calling
/// thread; process state is reclaimed when its refcount hits zero. Does not
/// return.
pub fn exitProcess(context: Context) Error.Syscall!usize {
    const status: u8 = @truncate(context.arg(.one));
    context.process().exit_status = status;

    // TODO (multi-core): IPI sibling threads and force-terminate them before
    // deallocating process state. For now terminate the calling thread; process
    // cleanup runs automatically when the reference count reaches zero.
    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
    unreachable;
}

/// spawn_thread(entry, arg) -> 0 : start a new thread in the current process at
/// the given user entry point.
pub fn spawnThread(context: Context) Error.Syscall!usize {
    const entry_ptr = context.arg(.one);
    const user_arg = context.arg(.two);

    if (entry_ptr == 0) return Error.Syscall.InvalidArgument;

    const vaddr: innigkeit.VirtualAddress = .from(entry_ptr);
    const entry_point = switch (vaddr.tagged()) {
        .user => |user| user,
        else => return Error.Syscall.BadAddress,
    };

    const new_thread = context.process().createThread(.{
        .entry = .prepare(
            spawnThreadEntry,
            .{ entry_point, user_arg },
        ),
    }) catch return Error.Syscall.OutOfMemory;

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&new_thread.task, .{ .initial = true });

    return 0;
}

/// Kernel-side entry for threads spawned via spawn_thread; runs in the new
/// thread's context and jumps to userspace.
fn spawnThreadEntry(entry_point: innigkeit.UserVirtualAddress, arg: usize) !noreturn {
    const thread: *Thread = .from(innigkeit.Task.Current.get().task);
    try thread.start(entry_point, arg);
    unreachable;
}

/// Look up a Notify capability requiring `read` rights (shared by the wait
/// syscalls). Returns the referenced object; caller must unref.
const NotifySlot = struct {
    notify: *innigkeit.capabilities.Notify,
    cap_type: innigkeit.capabilities.ObjectType,
    ptr: *anyopaque,
};

/// wait_process(handle) -> exit_status : block until the exit Notify's bit 0 is
/// set, returning the recorded status byte. Convenience over cap_invoke wait.
pub fn waitProcess(context: Context) Error.Syscall!usize {
    const slot = try lookupNotify(context, .require_read);
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot.cap_type, slot.ptr);
    const bits = slot.notify.wait(0xFF_01); // wait bit 0 (exit), read bits 8..15 (status)
    return @as(u8, @truncate(bits >> 8));
}

/// wait_process_nb(handle) -> exit_status | WouldBlock : non-blocking variant.
pub fn waitProcessNb(context: Context) Error.Syscall!usize {
    const slot = try lookupNotify(context, .require_read);
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot.cap_type, slot.ptr);
    const bits = slot.notify.poll(0xFF_01);
    if (bits == 0) return Error.Syscall.WouldBlock; // still running
    return @as(u8, @truncate(bits >> 8));
}

/// process_kill(handle) -> 0 : force-signal the exit Notify (status 130, the
/// SIGINT convention), unblocking any waiter.
pub fn processKill(context: Context) Error.Syscall!usize {
    const slot = try lookupNotify(context, .no_read_check);
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot.cap_type, slot.ptr);
    // Bit 0 = exited, bits 8..15 = exit status.
    slot.notify.signal(@as(u64, 1) | (@as(u64, 130) << 8));
    return 0;
}

const ReadCheck = enum { require_read, no_read_check };

/// Resolve arg.one as a Notify-typed capability handle, taking a reference.
fn lookupNotify(context: Context, read_check: ReadCheck) Error.Syscall!NotifySlot {
    const handle = context.arg32(.one);
    const cap_table = context.process().cap_table;

    cap_table.lock.lock();
    const slot_info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return Error.Syscall.BadHandle;
    };
    cap_table.lock.unlock();
    errdefer innigkeit.capabilities.CapabilityTable
        .unrefObject(slot_info.cap_type, slot_info.ptr);

    if (slot_info.cap_type != .notify)
        return Error.Syscall.InvalidArgument;
    if (read_check == .require_read and !slot_info.rights.read)
        return Error.Syscall.PermissionDenied;

    return .{
        .notify = @ptrCast(@alignCast(slot_info.ptr)),
        .cap_type = slot_info.cap_type,
        .ptr = slot_info.ptr,
    };
}
