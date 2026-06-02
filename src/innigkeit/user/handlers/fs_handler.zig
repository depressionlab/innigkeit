//! Kernel-side handlers for the simple flat filesystem syscalls:
//! - fs_open  (id=31): open or create a file
//! - fs_read  (id=32): read from an open fd
//! - fs_write (id=33): write to an open fd
//! - fs_close (id=34): close an fd

const std = @import("std");
const innigkeit = @import("innigkeit");
const validateUserBuffer = @import("../validate.zig").validateUserBuffer;

const simple_fs = innigkeit.fs.simple_fs;

const log = innigkeit.debug.log.scoped(.user_fs);

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

const e = struct {
    const ENOENT: i64 = -2;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EEXIST: i64 = -17;
    const ENODEV: i64 = -19;
    const EINVAL: i64 = -22;
    const ENOSPC: i64 = -28;
    const EPERM: i64 = -1;
};

// FD numbering: userspace FDs 3..14 -> open_files[0..11].
const FD_BASE: u32 = 3;
const FD_MAX: u32 = FD_BASE + 12 - 1; // 14

fn fdToIndex(fd: u32) ?usize {
    if (fd < FD_BASE or fd > FD_MAX) return null;
    return fd - FD_BASE;
}

/// fs_open(name_ptr: usize, name_len: u32, flags: u32) -> fd|error
pub fn syscallFsOpen(
    name_ptr: usize,
    name_len_raw: usize,
    flags_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const name_len: u32 = @truncate(name_len_raw);
    const flags_bits: u32 = @truncate(flags_raw);

    if (name_len == 0 or name_len > 15) return errCode(e.EINVAL);
    if (!validateUserBuffer(name_ptr, name_len)) return errCode(e.EFAULT);

    var name_buf: [16]u8 = undefined;
    current_task.incrementEnableAccessToUserMemory();
    @memcpy(name_buf[0..name_len], @as([*]const u8, @ptrFromInt(name_ptr))[0..name_len]);
    current_task.decrementEnableAccessToUserMemory();
    const name = name_buf[0..name_len];

    const flags: simple_fs.OpenFlags = @bitCast(flags_bits);

    const process = innigkeit.user.Process.from(current_task.task);

    // Find a free slot while holding the lock.
    process.open_files_lock.lock();
    var free_idx: ?usize = null;
    for (0..12) |i| {
        if (process.open_files[i] == null) {
            free_idx = i;
            break;
        }
    }
    process.open_files_lock.unlock();

    const idx = free_idx orelse return errCode(e.ENOMEM); // too many open files

    const file = simple_fs.open(name, flags) catch |err| {
        log.debug("fs_open({s}): {t}", .{ name, err });
        return switch (err) {
            error.NotFound => errCode(e.ENOENT),
            error.NoSpace => errCode(e.ENOSPC),
            error.IoError => errCode(e.EIO),
            error.NoDevice => errCode(e.ENODEV),
            error.InvalidArgument => errCode(e.EINVAL),
        };
    };

    process.open_files_lock.lock();
    // Recheck the slot is still free (another thread might have grabbed it).
    if (process.open_files[idx] != null) {
        process.open_files_lock.unlock();
        // Closing the file we just opened since we can't store it.
        var mutable_file = file;
        simple_fs.close(&mutable_file);
        return errCode(e.ENOMEM);
    }
    process.open_files[idx] = file;
    process.open_files_lock.unlock();

    return @intCast(idx + FD_BASE);
}

/// fs_read(fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
pub fn syscallFsRead(
    fd_raw: usize,
    buf_ptr: usize,
    buf_len: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const fd: u32 = @truncate(fd_raw);
    const idx = fdToIndex(fd) orelse return errCode(e.EBADF);

    if (buf_len == 0) return 0;
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    const process = innigkeit.user.Process.from(current_task.task);

    process.open_files_lock.lock();
    const file_ptr: *simple_fs.OpenFile = if (process.open_files[idx]) |*f| f else {
        process.open_files_lock.unlock();
        return errCode(e.EBADF);
    };

    // Read into a kernel bounce buffer, then copy to user memory.
    var tmp: [4096]u8 = undefined;
    const to_read: usize = @min(buf_len, tmp.len);

    const n = simple_fs.read(file_ptr, tmp[0..to_read]) catch |err| {
        process.open_files_lock.unlock();
        log.debug("fs_read fd={}: {t}", .{ fd, err });
        return switch (err) {
            error.IoError => errCode(e.EIO),
            error.NoDevice => errCode(e.ENODEV),
        };
    };
    process.open_files_lock.unlock();

    if (n > 0) {
        current_task.incrementEnableAccessToUserMemory();
        @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..n], tmp[0..n]);
        current_task.decrementEnableAccessToUserMemory();
    }

    return n;
}

/// fs_write(fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
pub fn syscallFsWrite(
    fd_raw: usize,
    buf_ptr: usize,
    buf_len: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const fd: u32 = @truncate(fd_raw);
    const idx = fdToIndex(fd) orelse return errCode(e.EBADF);

    if (buf_len == 0) return 0;
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    // Copy user data into a kernel bounce buffer before touching the file.
    var tmp: [4096]u8 = undefined;
    const to_write: usize = @min(buf_len, tmp.len);

    current_task.incrementEnableAccessToUserMemory();
    @memcpy(tmp[0..to_write], @as([*]const u8, @ptrFromInt(buf_ptr))[0..to_write]);
    current_task.decrementEnableAccessToUserMemory();

    const process = innigkeit.user.Process.from(current_task.task);

    process.open_files_lock.lock();
    const file_ptr: *simple_fs.OpenFile = if (process.open_files[idx]) |*f| f else {
        process.open_files_lock.unlock();
        return errCode(e.EBADF);
    };

    const n = simple_fs.write(file_ptr, tmp[0..to_write]) catch |err| {
        process.open_files_lock.unlock();
        log.debug("fs_write fd={}: {t}", .{ fd, err });
        return switch (err) {
            error.PermissionDenied => errCode(e.EPERM),
            error.IoError => errCode(e.EIO),
            error.NoDevice => errCode(e.ENODEV),
        };
    };
    process.open_files_lock.unlock();

    return n;
}

/// fs_close(fd: u32) -> 0|error
pub fn syscallFsClose(
    fd_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const fd: u32 = @truncate(fd_raw);
    const idx = fdToIndex(fd) orelse return errCode(e.EBADF);

    const process = innigkeit.user.Process.from(current_task.task);

    process.open_files_lock.lock();
    var file = (process.open_files[idx]) orelse {
        process.open_files_lock.unlock();
        return errCode(e.EBADF);
    };
    process.open_files[idx] = null;
    process.open_files_lock.unlock();

    // close() may do I/O (sync), do it outside the lock.
    simple_fs.close(&file);

    return 0;
}
