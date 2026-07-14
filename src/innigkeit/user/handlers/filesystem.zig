//! Kernel-side handlers for the simple flat filesystem syscalls:
//! - fs_open  (id=31): open or create a file
//! - fs_read  (id=32): read from an open fd
//! - fs_write (id=33): write to an open fd
//! - fs_close (id=34): close an fd

const innigkeit = @import("innigkeit");
const simple_fs = innigkeit.filesystem.simple_fs;
const log = innigkeit.debug.log.scoped(.user_fs);

const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");
const validate = @import("../validate.zig");

// FD numbering: userspace FDs 3..14 -> open_files[0..11].
const FD_BASE: u32 = 3;
const FD_MAX: u32 = FD_BASE + 12 - 1; // 14

fn fdToIndex(fd: u32) ?usize {
    if (fd < FD_BASE or fd > FD_MAX) return null;
    return fd - FD_BASE;
}

/// fs_open(name_ptr: usize, name_len: u32, flags: u32) -> fd|error
pub fn fsOpen(context: Context) Error.Syscall!usize {
    const name_ptr = context.arg(.one);
    const name_len = context.arg32(.two);
    const flags_bits = context.arg32(.three);

    if (name_len == 0 or name_len > 15) return Error.Syscall.InvalidArgument;

    var name_buf: [16]u8 = undefined;
    try validate.copyFromUser(name_buf[0..name_len], name_ptr);
    const name = name_buf[0..name_len];

    const flags: simple_fs.OpenFlags = @bitCast(flags_bits);

    const process = context.process();
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

    const idx = free_idx orelse return Error.Syscall.OutOfMemory; // too many open files

    const file = simple_fs.open(name, flags) catch |err| {
        log.debug("fs_open({s}): {t}", .{ name, err });
        return switch (err) {
            error.NotFound => Error.Syscall.NotFound,
            error.NoSpace => Error.Syscall.NoSpace,
            error.IoError => Error.Syscall.IoError,
            error.NoDevice => Error.Syscall.NoDevice,
            error.InvalidArgument => Error.Syscall.InvalidArgument,
        };
    };

    process.open_files_lock.lock();
    // Recheck the slot is still free (another thread might have grabbed it).
    if (process.open_files[idx] != null) {
        process.open_files_lock.unlock();
        // Closing the file we just opened since we can't store it.
        var mutable_file = file;
        simple_fs.close(&mutable_file);
        return Error.Syscall.OutOfMemory;
    }
    process.open_files[idx] = file;
    process.open_files_lock.unlock();

    return @intCast(idx + FD_BASE);
}

/// fs_read(fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
pub fn fsRead(context: Context) Error.Syscall!usize {
    const fd = context.arg32(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    const idx = fdToIndex(fd) orelse return Error.Syscall.BadHandle;

    if (buf_len == 0) return 0;
    // Validate up front so a bad buffer faults before the read advances the
    // file offset.
    if (!validate.userBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    const process = context.process();
    process.open_files_lock.lock();
    const file_ptr: *simple_fs.OpenFile = if (process.open_files[idx]) |*f| f else {
        process.open_files_lock.unlock();
        return Error.Syscall.BadHandle;
    };

    // Read into a kernel bounce buffer, then copy to user memory.
    var tmp: [4096]u8 = undefined;
    const to_read: usize = @min(buf_len, tmp.len);

    const n = simple_fs.read(file_ptr, tmp[0..to_read]) catch |err| {
        process.open_files_lock.unlock();
        log.debug("fs_read fd={}: {t}", .{ fd, err });
        return switch (err) {
            error.IoError => Error.Syscall.IoError,
            error.NoDevice => Error.Syscall.NoDevice,
        };
    };
    process.open_files_lock.unlock();

    if (n > 0) try validate.copyToUser(buf_ptr, tmp[0..n]);

    return n;
}

/// fs_write(fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
pub fn fsWrite(context: Context) Error.Syscall!usize {
    const fd = context.arg32(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);
    const idx = fdToIndex(fd) orelse return Error.Syscall.BadHandle;

    if (buf_len == 0) return 0;
    // The whole user range must be valid even though at most tmp.len bytes
    // are consumed per call.
    if (!validate.userBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    // Copy user data into a kernel bounce buffer before touching the file.
    var tmp: [4096]u8 = undefined;
    const to_write: usize = @min(buf_len, tmp.len);

    try validate.copyFromUser(tmp[0..to_write], buf_ptr);

    const process = context.process();
    process.open_files_lock.lock();
    const file_ptr: *simple_fs.OpenFile = if (process.open_files[idx]) |*f| f else {
        process.open_files_lock.unlock();
        return Error.Syscall.BadHandle;
    };

    const n = simple_fs.write(file_ptr, tmp[0..to_write]) catch |err| {
        process.open_files_lock.unlock();
        log.debug("fs_write fd={}: {t}", .{ fd, err });
        return switch (err) {
            error.PermissionDenied => Error.Syscall.PermissionDenied,
            error.IoError => Error.Syscall.IoError,
            error.NoDevice => Error.Syscall.NoDevice,
        };
    };
    process.open_files_lock.unlock();

    return n;
}

/// fs_close(fd: u32) -> 0|error
pub fn fsClose(context: Context) Error.Syscall!usize {
    const fd = context.arg32(.one);
    const idx = fdToIndex(fd) orelse return Error.Syscall.BadHandle;
    const process = context.process();

    process.open_files_lock.lock();
    var file = (process.open_files[idx]) orelse {
        process.open_files_lock.unlock();
        return Error.Syscall.BadHandle;
    };
    process.open_files[idx] = null;
    process.open_files_lock.unlock();

    // close() may do I/O (sync), do it outside the lock.
    simple_fs.close(&file);

    return 0;
}
