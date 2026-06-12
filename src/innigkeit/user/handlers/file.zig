//! Kernel-side handlers for the per-process file-descriptor-table syscalls:
//! - open  (id=54): open a VFS file into the fd table
//! - close (id=55): close a descriptor
//! - lseek (id=56): reposition a file descriptor's offset
//! - fstat (id=57): query size/kind of a descriptor
//! plus the `.file` branches of the read (id=3) and write (id=2) syscalls.
//!
//! Disk I/O is interrupt-driven and may block, so user buffers are never
//! touched while a VFS call is in flight: data moves through a kernel
//! bounce buffer, and the user copy happens outside the blocking section
//! (see src/innigkeit/user/validate.zig).

const std = @import("std");
const innigkeit = @import("innigkeit");
const validate = @import("../validate.zig");
const FdTable = @import("../FdTable.zig");

const vfs = innigkeit.fs.vfs;

const log = innigkeit.debug.log.scoped(.user_file);

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

const e = struct {
    const EPERM: i64 = -1;
    const ENOENT: i64 = -2;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const ENODEV: i64 = -19;
    const EINVAL: i64 = -22;
    const ENOSPC: i64 = -28;
};

fn mapFdError(err: FdTable.Error) usize {
    return switch (err) {
        // A non-writable descriptor behaves like a bad fd for writes (POSIX).
        error.BadFd, error.NotWritable => errCode(e.EBADF),
        error.InvalidArgument => errCode(e.EINVAL),
        error.NoDevice => errCode(e.ENODEV),
        error.Io => errCode(e.EIO),
    };
}

/// Longest accepted path (vfs/ext4 builds a 64-byte absolute path).
const max_path_len = 62;

/// open(path_ptr: usize, path_len: usize, flags: u32) -> fd|error
/// flags bit 0 = open for writing (creates the file if missing).
/// The storage entitlement for the write flag is checked in the dispatcher.
pub fn syscallOpen(
    path_ptr: usize,
    path_len: usize,
    flags_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const flags: u32 = @truncate(flags_raw);
    const want_write = flags & 1 != 0;

    if (path_len == 0 or path_len > max_path_len + 1) return errCode(e.EINVAL);
    var path_buf: [max_path_len + 1]u8 = undefined;
    validate.copyFromUser(path_buf[0..path_len], path_ptr) catch return errCode(e.EFAULT);

    // The VFS roots everything at "/"; accept and strip a leading slash.
    var path: []const u8 = path_buf[0..path_len];
    while (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len == 0 or path.len > max_path_len) return errCode(e.EINVAL);

    var node = vfs.open(path, .{ .create = want_write }) catch |err| {
        log.debug("open({s}): {t}", .{ path, err });
        return switch (err) {
            error.NotFound => errCode(e.ENOENT),
            error.NoSpace => errCode(e.ENOSPC),
            error.NoDevice => errCode(e.ENODEV),
            error.InvalidArgument => errCode(e.EINVAL),
            else => errCode(e.EIO),
        };
    };

    const process = innigkeit.user.Process.from(current_task.task);
    const fd = process.fd_table.insertFile(node, want_write) catch {
        vfs.close(&node);
        return errCode(e.ENOMEM); // table full
    };
    return fd;
}

/// close(fd: usize) -> 0|error
pub fn syscallClose(fd: usize, current_task: innigkeit.Task.Current) usize {
    const process = innigkeit.user.Process.from(current_task.task);
    const maybe_file = process.fd_table.closeFd(fd) catch return errCode(e.EBADF);
    if (maybe_file) |file| {
        // vfs.close may sync metadata to disk: run it outside the table lock.
        var node = file.node;
        vfs.close(&node);
    }
    return 0;
}

/// lseek(fd: usize, offset: i64, whence: u32) -> new_offset|error
/// whence: 0 = SET, 1 = CUR, 2 = END.
pub fn syscallLseek(
    fd: usize,
    offset_raw: usize,
    whence_raw: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const offset: i64 = @bitCast(@as(u64, offset_raw));
    const whence: u32 = @truncate(whence_raw);

    const process = innigkeit.user.Process.from(current_task.task);
    const new_offset = process.fd_table.lseek(fd, offset, whence) catch |err|
        return mapFdError(err);
    // lseek results come from i64 arithmetic, so they fit in an isize.
    return @intCast(new_offset);
}

/// fstat(fd: usize, stat_ptr: usize) -> 0|error
/// Fills FdTable.Stat{size: u64, kind: u8} at stat_ptr.
pub fn syscallFstat(
    fd: usize,
    stat_ptr: usize,
    current_task: innigkeit.Task.Current,
) usize {
    const process = innigkeit.user.Process.from(current_task.task);
    const stat = process.fd_table.statFd(fd) catch |err| return mapFdError(err);
    validate.writeUser(stat_ptr, stat) catch return errCode(e.EFAULT);
    return 0;
}

/// `.file` branch of the read syscall: bounce-buffered positioned read.
/// Returns at most one bounce buffer's worth per call (callers loop).
pub fn syscallReadFile(
    table: *FdTable,
    fd: usize,
    buf_ptr: usize,
    buf_len: usize,
) usize {
    // The whole user range must be valid even though at most tmp.len bytes
    // are returned per call.
    if (!validate.validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var tmp: [4096]u8 = undefined;
    const to_read: usize = @min(buf_len, tmp.len);
    const n = table.readFile(fd, tmp[0..to_read]) catch |err| return mapFdError(err);
    if (n > 0) {
        validate.copyToUser(buf_ptr, tmp[0..n]) catch
            return errCode(e.EFAULT); // unreachable: validated above
    }
    return n;
}

/// `.file` branch of the write syscall: bounce-buffered positioned write.
/// Consumes the entire user buffer (chunked) to match the terminal path.
pub fn syscallWriteFile(
    table: *FdTable,
    fd: usize,
    buf_ptr: usize,
    buf_len: usize,
) usize {
    if (!validate.validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var tmp: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < buf_len) {
        const chunk: usize = @min(buf_len - done, tmp.len);
        // Copy from user memory first; the VFS write below may block.
        validate.copyFromUser(tmp[0..chunk], buf_ptr + done) catch return errCode(e.EFAULT);
        const n = table.writeFile(fd, tmp[0..chunk]) catch |err| {
            // Report bytes already written rather than an error mid-stream.
            if (done > 0) return done;
            return mapFdError(err);
        };
        if (n == 0) break;
        done += n;
    }
    return done;
}
