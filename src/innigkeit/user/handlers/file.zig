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

const innigkeit = @import("innigkeit");
const vfs = innigkeit.filesystem.vfs;
const log = innigkeit.debug.log.scoped(.user_file);

const FdTable = @import("../FdTable.zig");
const validate = @import("../validate.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

fn mapFdError(err: FdTable.Error) Error.Syscall {
    return switch (err) {
        // A non-writable descriptor behaves like a bad fd for writes (POSIX).
        FdTable.Error.BadFd, FdTable.Error.NotWritable => Error.Syscall.BadHandle,
        FdTable.Error.InvalidArgument => Error.Syscall.InvalidArgument,
        FdTable.Error.NoDevice => Error.Syscall.NoDevice,
        FdTable.Error.Io => Error.Syscall.IoError,
    };
}

/// Longest accepted path (vfs/ext4 builds a 64-byte absolute path).
const max_path_len = 62;

/// open(path_ptr: usize, path_len: usize, flags: u32) -> fd|error
/// flags bit 0 = open for writing (creates the file if missing). Opening for
/// write requires the `storage` entitlement; read-only opens are unprivileged
/// so the gate is conditional and lives here, not as a blanket table gate.
pub fn open(context: Context) Error.Syscall!usize {
    const path_ptr = context.arg(.one);
    const path_len = context.arg(.two);
    const flags = context.arg32(.three);
    const want_write = flags & 1 != 0;

    if (want_write and !context.entitled("storage")) return Error.Syscall.PermissionDenied;
    var path_buf: [max_path_len + 1]u8 = undefined;
    try validate.copyFromUser(path_buf[0..path_len], path_ptr);

    // The VFS roots everything at "/"; accept and strip a leading slash.
    var path: []const u8 = path_buf[0..path_len];
    while (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len == 0 or path.len > max_path_len) return Error.Syscall.InvalidArgument;

    var node = vfs.open(path, .{ .create = want_write }) catch |err| {
        log.debug("open({s}): {t}", .{ path, err });
        return switch (err) {
            error.NotFound => Error.Syscall.NotFound,
            error.NoSpace => Error.Syscall.NoSpace,
            error.NoDevice => Error.Syscall.NoDevice,
            error.InvalidArgument => Error.Syscall.InvalidArgument,
            else => Error.Syscall.IoError,
        };
    };

    const fd = context.process().fd_table.insertFile(node, want_write) catch {
        vfs.close(&node);
        return Error.Syscall.OutOfMemory; // table full
    };
    return fd;
}

/// close(fd: usize) -> 0|error
pub fn close(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const maybe_file = context.process().fd_table
        .closeFd(fd) catch return Error.Syscall.BadHandle;

    if (maybe_file) |file| {
        // vfs.close may sync metadata to disk: run it outside the table lock.
        var node = file.node;
        vfs.close(&node);
    }
    return 0;
}

/// lseek(fd: usize, offset: i64, whence: u32) -> new_offset|error
/// whence: 0 = SET, 1 = CUR, 2 = END.
pub fn lseek(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const offset: i64 = @bitCast(@as(u64, context.arg(.two)));
    const whence = context.arg32(.three);

    const new_offset = context.process().fd_table
        .lseek(fd, offset, whence) catch |err| return mapFdError(err);
    // lseek results come from i64 arithmetic, so they fit in an isize.
    return @intCast(new_offset);
}

/// fstat(fd: usize, stat_ptr: usize) -> 0|error
/// Fills FdTable.Stat{size: u64, kind: u8} at stat_ptr.
pub fn fstat(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const stat_ptr = context.arg(.two);

    const stat = context.process().fd_table.statFd(fd) catch |err| return mapFdError(err);
    try validate.writeUser(stat_ptr, stat);
    return 0;
}

/// `.file` branch of the read syscall: bounce-buffered positioned read.
/// Returns at most one bounce buffer's worth per call (callers loop).
pub fn readFile(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);

    // The whole user range must be valid even though at most tmp.len bytes
    // are returned per call.
    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;

    var tmp: [4096]u8 = undefined;
    const to_read: usize = @min(buf_len, tmp.len);
    const n = context.process().fd_table.readFile(fd, tmp[0..to_read]) catch |err| return mapFdError(err);
    if (n > 0) try validate.copyToUser(buf_ptr, tmp[0..n]);
    return n;
}

/// `.file` branch of the write syscall: bounce-buffered positioned write.
/// Consumes the entire user buffer (chunked) to match the terminal path.
pub fn writeFile(context: Context) Error.Syscall!usize {
    const fd = context.arg(.one);
    const buf_ptr = context.arg(.two);
    const buf_len = context.arg(.three);

    if (!validate.userBuffer(buf_ptr, buf_len))
        return Error.Syscall.BadAddress;

    var tmp: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < buf_len) {
        const chunk: usize = @min(buf_len - done, tmp.len);
        // Copy from user memory first; the VFS write below may block.
        try validate.copyFromUser(tmp[0..chunk], buf_ptr + done);
        const n = context.process().fd_table.writeFile(fd, tmp[0..chunk]) catch |err| {
            // Report bytes already written rather than an error mid-stream.
            if (done > 0) return done;
            return mapFdError(err);
        };
        if (n == 0) break;
        done += n;
    }
    return done;
}
