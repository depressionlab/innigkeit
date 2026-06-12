//! A synchronous, single-threaded `std.Io` backend for Innigkeit userspace.
//!
//! Obtain the interface with `innigkeit.stdio.io()`. The backend is a
//! stateless singleton: no allocation, `userdata == null`, one shared
//! comptime vtable.
//!
//! ## Execution model
//!
//! Everything runs eagerly and inline on the calling thread:
//!
//! * `async` executes the task immediately and returns `null`, which by the
//!   `std.Io.VTable.async` contract means the result is already populated and
//!   `await` is a no-op. `Group.async` does the same.
//! * `concurrent` / `Group.concurrent` always fail with
//!   `error.ConcurrencyUnavailable` (the documented escape hatch for
//!   implementations without units of concurrency).
//! * `await` / `cancel` / `groupAwait` / `groupCancel` are `unreachable`: the
//!   vtable contract guarantees they are only invoked when `async` returned
//!   non-null (or, for groups, when the implementation published a non-null
//!   group token), which this backend never does.
//! * Cancelation is never delivered, so `checkCancel` always succeeds and
//!   `recancel` (only legal after observing `error.Canceled`) is unreachable.
//! * `Batch.awaitAsync` performs all submitted operations synchronously, in
//!   submission order; `Batch.awaitConcurrent` fails with
//!   `error.ConcurrencyUnavailable`.
//!
//! ## Supported operations
//!
//! * **Futexes** (and therefore `std.Io.Mutex`, `Condition`, `Event`,
//!   `Queue`, ...): wired to the `futex_wait` / `futex_wait_timeout` /
//!   `futex_wake` syscalls.
//! * **Time**: `now` returns milliseconds since kernel boot (`uptime_ms`)
//!   scaled to nanoseconds, for *every* clock — including `.real`, since the
//!   kernel exposes no wall clock; treat all clocks as one monotonic boot
//!   clock. `clockResolution` reports 1 ms. `sleep` rounds the requested
//!   duration/deadline *up* to the next millisecond and uses `nanosleep_ms`.
//! * **Standard streams**: `operate` supports `file_read_streaming` (read
//!   syscall, fd 0) and `file_write_streaming` (write syscall, fd 1). See
//!   "File model" below. `lockStderr` yields a writer over fd 2.
//! * **random**: a non-cryptographic xorshift PRNG seeded from `uptime_ms`
//!   (no entropy syscall exists); `randomSecure` fails with
//!   `error.EntropyUnavailable`.
//!
//! ## File model (important limitation)
//!
//! On the Innigkeit userspace target (`os.tag == .freestanding`),
//! `std.posix.fd_t` is `void`, so `std.Io.File.Handle` and
//! `std.Io.Dir.Handle` cannot carry a kernel file descriptor at all. A
//! `std.Io.File` value is therefore *unaddressable*: this backend cannot
//! know which fd it refers to, and per-file operations cannot be wired to
//! the open/close/read/write/lseek/fstat syscalls through the `std.Io.File`
//! object API.
//!
//! Instead, this backend adopts the convention that any `std.Io.File`
//! denotes the process standard streams: streaming reads come from fd 0
//! (stdin) and streaming writes go to fd 1 (stdout). This makes
//! `std.Io.File.Reader` / `std.Io.File.Writer` (and thus all std formatting)
//! fully usable for console I/O — construct the file with `stdoutFile()` /
//! `stdinFile()`. Positional reads/writes and seeks return
//! `error.Unseekable`, which `std.Io.File.{Reader,Writer}` handle by falling
//! back to streaming mode automatically.
//!
//! For real VFS files use `innigkeit.fs.File` (open/read/write/seek/stat
//! over the kernel fd table); its `reader()` / `writer()` adapters integrate
//! with `std.Io.Reader` / `std.Io.Writer`. `fileFromFd` converts a raw
//! kernel fd into such a handle.
//!
//! ## Unsupported operations
//!
//! TODO: Directory operations, per-file metadata (stat/length/permissions/
//! timestamps/locks), memory maps, process spawning, and all networking
//! return the closest "unsupported" error of their respective error sets,
//! reusing the canonical stubs from `std.Io.failing` (e.g. opens return
//! `error.FileNotFound`, creations return `error.NoSpaceLeft`, net ops
//! return `error.NetworkDown`).
const std = @import("std");
const innigkeit = @import("innigkeit");
const Io = std.Io;
const Syscall = innigkeit.Syscall;

/// The singleton synchronous `std.Io` backend instance.
pub const backend: Io = .{
    .userdata = null,
    .vtable = &vtable,
};

/// Returns the `std.Io` interface for Innigkeit userspace.
///
/// The returned value is a stateless singleton; calling this repeatedly is
/// free and all returned values are interchangeable.
pub fn io() Io {
    return backend;
}

/// Wrap a raw kernel VFS file descriptor (from the open syscall) in an
/// `innigkeit.fs.File`.
///
/// This intentionally does *not* return a `std.Io.File`: on the Innigkeit
/// target `std.Io.File.Handle` is `void` (see the file-model note in the
/// module doc), so a `std.Io.File` cannot carry an fd. The returned
/// `fs.File` provides `reader()` / `writer()` adapters that plug into
/// `std.Io.Reader` / `std.Io.Writer` for use with std formatting APIs.
pub fn fileFromFd(fd: u32) innigkeit.fs.File {
    return .{ .fd = fd };
}

/// A `std.Io.File` denoting the process standard output stream under this
/// backend's file model. Compiles on both the Innigkeit target (where
/// `Handle == void`) and host targets (where it is fd 1).
pub fn stdoutFile() Io.File {
    if (Io.File.Handle == void) {
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    } else {
        return .{ .handle = 1, .flags = .{ .nonblocking = false } };
    }
}

/// A `std.Io.File` denoting the process standard input stream under this
/// backend's file model.
pub fn stdinFile() Io.File {
    if (Io.File.Handle == void) {
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    } else {
        return .{ .handle = 0, .flags = .{ .nonblocking = false } };
    }
}

fn uptimeMs() u64 {
    const result = Syscall.invoke(.uptime_ms, .{});
    return Syscall.decode(result) catch 0;
}

/// Convert a millisecond count since boot into an `std.Io.Timestamp`.
fn msToTimestamp(ms: u64) Io.Timestamp {
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

/// Convert nanoseconds to milliseconds, rounding *up* (so sleeps and
/// timeouts never expire early). Non-positive inputs yield 0.
fn ceilNsToMs(ns: i96) u64 {
    if (ns <= 0) return 0;
    return @intCast(@divFloor(ns + (std.time.ns_per_ms - 1), std.time.ns_per_ms));
}

/// Resolve an `std.Io.Timeout` into an absolute `uptime_ms` deadline.
///
/// Returns `null` for `.none` (wait without timeout). Deadline timestamps
/// are interpreted on the backend's boot clock, which is the same clock
/// `now` reports for every `std.Io.Clock`, so timestamps produced through
/// this `Io` round-trip correctly.
fn timeoutDeadlineMs(timeout: Io.Timeout, current_ms: u64) ?u64 {
    return switch (timeout) {
        .none => null,
        .duration => |d| current_ms + ceilNsToMs(d.raw.nanoseconds),
        .deadline => |ts| ceilNsToMs(ts.raw.nanoseconds),
    };
}

fn ioNow(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    // All clocks alias the kernel boot clock; there is no wall clock or
    // per-task CPU clock syscall. Documented in the module header.
    _ = clock;
    return msToTimestamp(uptimeMs());
}

fn clockResolution(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    _ = clock;
    return .fromMilliseconds(1);
}

fn sleep(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    // `.none` carries no expiry: nothing to wait for, return immediately.
    const deadline_ms = timeoutDeadlineMs(timeout, uptimeMs()) orelse return;
    _ = Syscall.invoke(.nanosleep_ms, .{deadline_ms});
}

// Per-thread cancel protection state. Cancelation is never *delivered* by
// this backend, but std code legitimately saves/restores the protection
// state, so it must be tracked per thread.
threadlocal var cancel_protection: Io.CancelProtection = .unblocked;

fn swapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const old = cancel_protection;
    cancel_protection = new;
    return old;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {
    // No cancelation requests can ever be issued (async runs eagerly and
    // concurrent never starts), so this is always a successful no-op.
}

fn crashHandler(_: ?*anyopaque) void {
    // Route to the interop exit path, matching interop/debug_io.zig. In this
    // ecosystem apps install `innigkeit.interop.panic` as their root panic
    // handler (which prints and exits), so this slot only runs if an app
    // wires this Io up as `std_options_debug_io`.
    _ = Syscall.invoke(.exit_process, .{@as(usize, 1)});
}

fn futexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const deadline_ms = timeoutDeadlineMs(timeout, uptimeMs());
    while (@atomicLoad(u32, ptr, .acquire) == expected) {
        if (deadline_ms) |dl| {
            if (uptimeMs() >= dl) return; // timeout: spurious-wakeup semantics
            _ = Syscall.invoke(.futex_wait_timeout, .{ @intFromPtr(ptr), expected, dl });
        } else {
            _ = Syscall.invoke(.futex_wait, .{ @intFromPtr(ptr), expected });
        }
    }
}

fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    while (@atomicLoad(u32, ptr, .acquire) == expected) {
        _ = Syscall.invoke(.futex_wait, .{ @intFromPtr(ptr), expected });
    }
}

fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    _ = Syscall.invoke(.futex_wake, .{ @intFromPtr(ptr), max_waiters });
}

const stdin_fd: usize = 0;
const stdout_fd: usize = 1;

/// Map a kernel syscall error onto `Operation.FileReadStreaming`'s error set
/// (closest semantic match; anything without a counterpart is
/// `error.Unexpected`).
fn mapReadError(err: Syscall.Error) Io.Operation.FileReadStreaming.UnendingError {
    return switch (err) {
        error.PermissionDenied => error.AccessDenied,
        error.BadFileDescriptor => error.NotOpenForReading,
        error.WouldBlock => error.WouldBlock,
        error.OutOfMemory => error.SystemResources,
        error.IoError => error.InputOutput,
        else => error.Unexpected,
    };
}

/// Map a kernel syscall error onto `Operation.FileWriteStreaming`'s error set.
fn mapWriteError(err: Syscall.Error) Io.Operation.FileWriteStreaming.Error {
    return switch (err) {
        error.PermissionDenied => error.PermissionDenied,
        error.BadFileDescriptor => error.NotOpenForWriting,
        error.WouldBlock => error.WouldBlock,
        error.OutOfMemory => error.SystemResources,
        error.NoSpace => error.NoSpaceLeft,
        error.NoDevice => error.NoDevice,
        error.IoError => error.InputOutput,
        else => error.Unexpected,
    };
}

fn readStreamingConsole(data: []const []u8) Io.Operation.FileReadStreaming.Error!usize {
    // Single-shot scatter read: fill the first non-empty slice; short reads
    // are permitted by the contract.
    const buf = for (data) |d| {
        if (d.len != 0) break d;
    } else return 0;
    const result = Syscall.invoke(.read, .{ stdin_fd, @intFromPtr(buf.ptr), buf.len });
    const n = Syscall.decode(result) catch |err| return mapReadError(err);
    // The kernel console never produces 0 bytes for a live stream; treat 0
    // as end-of-stream so std.Io.Reader does not spin.
    if (n == 0) return error.EndOfStream;
    return n;
}

fn writeAllConsole(bytes: []const u8, total: *usize) Io.Operation.FileWriteStreaming.Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const result = Syscall.invoke(.write, .{
            stdout_fd,
            @intFromPtr(bytes.ptr + off),
            bytes.len - off,
        });
        const n = Syscall.decode(result) catch |err| return mapWriteError(err);
        if (n == 0) return error.InputOutput;
        off += n;
        total.* += n;
    }
}

fn writeStreamingConsole(
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) Io.Operation.FileWriteStreaming.Error!usize {
    // Returns the number of bytes written; on error after a partial write,
    // report the partial count (the caller retries the remainder).
    var total: usize = 0;
    writeAllConsole(header, &total) catch |err| return if (total != 0) total else err;
    if (data.len != 0) {
        for (data[0 .. data.len - 1]) |bytes| {
            writeAllConsole(bytes, &total) catch |err| return if (total != 0) total else err;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            writeAllConsole(pattern, &total) catch |err| return if (total != 0) total else err;
        }
    }
    return total;
}

fn performOperation(operation: Io.Operation) Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |o| .{ .file_read_streaming = readStreamingConsole(o.data) },
        .file_write_streaming => |o| .{
            .file_write_streaming = writeStreamingConsole(o.header, o.data, o.splat),
        },
        // No ioctl-like syscall exists; -38 mirrors -ENOSYS in the
        // "negative errno" result convention of this operation.
        .device_io_control => .{ .device_io_control = -38 },
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

fn operate(_: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return performOperation(operation);
}

/// Performs all submitted operations synchronously, in submission order, and
/// moves them to the completed list. By the time this returns every
/// operation has completed, satisfying the "at least one" requirement.
fn batchAwaitAsync(_: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    var index = batch.submitted.head;
    batch.submitted = .empty;
    while (index != .none) {
        const i = index.toIndex();
        const storage = &batch.storage[i];
        const next = storage.submission.node.next;
        const result = performOperation(storage.submission.operation);
        storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        switch (batch.completed.tail) {
            .none => batch.completed.head = .fromIndex(i),
            else => |tail| batch.storage[tail.toIndex()].completion.node.next = .fromIndex(i),
        }
        batch.completed.tail = .fromIndex(i);
        index = next;
    }
}

fn batchAwaitConcurrent(
    _: ?*anyopaque,
    batch: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    _ = batch;
    _ = timeout;
    return error.ConcurrencyUnavailable;
}

fn batchCancel(_: ?*anyopaque, batch: *Io.Batch) void {
    // Operations never linger: awaitAsync completes everything inline and
    // submissions were already recycled by Batch.cancel, so the pending list
    // is always empty and there is nothing to interrupt or deallocate.
    std.debug.assert(batch.pending.head == .none);
}

fn fileClose(_: ?*anyopaque, files: []const Io.File) void {
    // Files denote the process standard streams in this backend's model;
    // they are not closeable resources.
    _ = files;
}

fn fileSync(_: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    // Console writes complete synchronously in the kernel; nothing to flush.
    _ = file;
}

fn fileReadPositional(
    _: ?*anyopaque,
    file: Io.File,
    data: []const []u8,
    offset: u64,
) Io.File.ReadPositionalError!usize {
    // The standard streams are not seekable. std.Io.File.Reader reacts to
    // `error.Unseekable` by falling back to streaming mode.
    _ = file;
    _ = data;
    _ = offset;
    return error.Unseekable;
}

fn fileWritePositional(
    _: ?*anyopaque,
    file: Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) Io.File.WritePositionalError!usize {
    // See fileReadPositional: triggers std.Io.File.Writer streaming fallback.
    _ = file;
    _ = header;
    _ = data;
    _ = splat;
    _ = offset;
    return error.Unseekable;
}

fn fileIsTty(_: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    _ = file;
    var st: innigkeit.fs.Stat = undefined;
    const result = Syscall.invoke(.fstat, .{ stdout_fd, @intFromPtr(&st) });
    _ = Syscall.decode(result) catch return false;
    return st.getKind() == .tty;
}

fn fileSupportsAnsiEscapeCodes(_: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    // The debug console does not interpret escape sequences.
    _ = file;
    return false;
}

fn fileEnableAnsiEscapeCodes(_: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
    _ = file;
    return error.NotTerminalDevice;
}

// Unbuffered writer over fd 2 reusing the io.zig stderr drain; `io`/`file`
// are never consulted because the interface vtable bypasses File.Writer's
// own drain.
var stderr_file_writer: Io.File.Writer = .{
    .io = backend,
    .file = undefined,
    .interface = .{
        .vtable = &innigkeit.io.stderr_vtable,
        .buffer = &.{},
    },
};

fn lockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    return .{
        .file_writer = &stderr_file_writer,
        .terminal_mode = .no_color,
    };
}

fn tryLockStderr(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    return .{
        .file_writer = &stderr_file_writer,
        .terminal_mode = .no_color,
    };
}

fn unlockStderr(_: ?*anyopaque) void {
    stderr_file_writer.interface.flush() catch {};
}

var prng_state: std.atomic.Value(u64) = .init(0);

/// Non-cryptographic xorshift64 generator seeded from `uptime_ms`. There is
/// no entropy syscall; for anything security-sensitive `randomSecure`
/// correctly reports `error.EntropyUnavailable`.
fn random(_: ?*anyopaque, buffer: []u8) void {
    var s = prng_state.load(.monotonic);
    if (s == 0) s = (uptimeMs() << 16) ^ 0x9e3779b97f4a7c15;
    for (buffer) |*b| {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        b.* = @truncate(s);
    }
    prng_state.store(s, .monotonic);
}

// Slots without Innigkeit support delegate to the canonical pub stubs that
// back `std.Io.failing`:
// * `failing*` — reachable, returns the closest "unsupported" error of the
//   slot's error set.
// * `no*` — reachable, succeeds as a no-op (or, for `noAsync` /
//   `noGroupAsync`, runs the task eagerly inline, which is exactly this
//   backend's execution model).
// * `unreachable*` — only reachable after another slot returned a value
//   this backend never produces (non-null future, group token, ...).
const vtable: Io.VTable = .{
    .crashHandler = crashHandler,

    // Eager execution: task runs inline, returns null => await is a no-op.
    .async = Io.noAsync,
    .concurrent = Io.failingConcurrent,
    // Only called when `async` returns non-null, which never happens here.
    .await = Io.unreachableAwait,
    .cancel = Io.unreachableCancel,

    // Eager execution; the group token is never published, so await/cancel
    // short-circuit in Group.await/Group.cancel and never reach the vtable.
    .groupAsync = Io.noGroupAsync,
    .groupConcurrent = Io.failingGroupConcurrent,
    .groupAwait = Io.unreachableGroupAwait,
    .groupCancel = Io.unreachableGroupCancel,

    // recancel is only legal after observing error.Canceled, which this
    // backend never returns.
    .recancel = Io.unreachableRecancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,

    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,

    .operate = operate,
    .batchAwaitAsync = batchAwaitAsync,
    .batchAwaitConcurrent = batchAwaitConcurrent,
    .batchCancel = batchCancel,

    // Directory API is unsupported: handles cannot carry fds on this target.
    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = Io.failingDirStatFile,
    .dirAccess = Io.failingDirAccess,
    .dirCreateFile = Io.failingDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = Io.failingDirOpenFile,
    .dirClose = Io.unreachableDirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = Io.failingDirRealPathFile,
    .dirDeleteFile = Io.failingDirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = Io.failingDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,

    // Files denote the standard streams; metadata is that of a stream.
    .fileStat = Io.failingFileStat, // error.Streaming
    .fileLength = Io.failingFileLength, // error.Streaming
    .fileClose = fileClose,
    .fileWritePositional = fileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming, // error.Unimplemented => buffered copy fallback
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = fileReadPositional,
    .fileSeekBy = Io.failingFileSeekBy, // error.Unseekable
    .fileSeekTo = Io.failingFileSeekTo, // error.Unseekable
    .fileSync = fileSync,
    .fileIsTty = fileIsTty,
    .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes,
    .fileSetLength = Io.failingFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = Io.noFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = Io.failingFileRealPath,
    .fileHardLink = Io.failingFileHardLink,

    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = lockStderr,
    .tryLockStderr = tryLockStderr,
    .unlockStderr = unlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processReplacePath = Io.failingProcessReplacePath,
    .processSpawn = Io.failingProcessSpawn,
    .processSpawnPath = Io.failingProcessSpawnPath,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,

    .progressParentFile = Io.failingProgressParentFile,

    .now = ioNow,
    .clockResolution = clockResolution,
    .sleep = sleep,

    .random = random,
    .randomSecure = Io.failingRandomSecure, // error.EntropyUnavailable

    .netListenIp = Io.failingNetListenIp,
    .netAccept = Io.failingNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = Io.failingNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = Io.failingNetRead,
    .netWrite = Io.failingNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = Io.unreachableNetClose,
    .netShutdown = Io.failingNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};

test "ceilNsToMs rounds up and clamps non-positive values" {
    try std.testing.expectEqual(@as(u64, 0), ceilNsToMs(0));
    try std.testing.expectEqual(@as(u64, 0), ceilNsToMs(-5));
    try std.testing.expectEqual(@as(u64, 1), ceilNsToMs(1));
    try std.testing.expectEqual(@as(u64, 1), ceilNsToMs(std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u64, 2), ceilNsToMs(std.time.ns_per_ms + 1));
    try std.testing.expectEqual(@as(u64, 10), ceilNsToMs(10 * std.time.ns_per_ms));
}

test "timeoutDeadlineMs resolves none, duration, and deadline" {
    try std.testing.expectEqual(@as(?u64, null), timeoutDeadlineMs(.none, 100));

    const dur: Io.Timeout = .{
        .duration = .{
            .raw = .fromNanoseconds(3 * std.time.ns_per_ms + 1), // 3.000001ms -> 4ms
            .clock = .awake,
        },
    };
    try std.testing.expectEqual(@as(?u64, 104), timeoutDeadlineMs(dur, 100));

    const dl: Io.Timeout = .{ .deadline = .{
        .raw = .fromNanoseconds(2 * std.time.ns_per_ms),
        .clock = .awake,
    } };
    try std.testing.expectEqual(@as(?u64, 2), timeoutDeadlineMs(dl, 100));
}

test "syscall errors map onto std.Io operation error sets" {
    try std.testing.expectEqual(error.NotOpenForReading, mapReadError(error.BadFileDescriptor));
    try std.testing.expectEqual(error.AccessDenied, mapReadError(error.PermissionDenied));
    try std.testing.expectEqual(error.Unexpected, mapReadError(error.NotFound));
    try std.testing.expectEqual(error.NoSpaceLeft, mapWriteError(error.NoSpace));
    try std.testing.expectEqual(error.NotOpenForWriting, mapWriteError(error.BadFileDescriptor));
    try std.testing.expectEqual(error.Unexpected, mapWriteError(error.Unknown));
}

test "msToTimestamp scales milliseconds to nanoseconds" {
    try std.testing.expectEqual(@as(i96, 0), msToTimestamp(0).nanoseconds);
    try std.testing.expectEqual(
        @as(i96, 1234) * std.time.ns_per_ms,
        msToTimestamp(1234).nanoseconds,
    );
    try std.testing.expectEqual(@as(i64, 1234), msToTimestamp(1234).toMilliseconds());
}
