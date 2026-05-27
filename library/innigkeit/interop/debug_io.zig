//! Minimal std.Io implementation for Innigkeit userspace processes.
//!
//! Provides `debug_io`, a `std.Io` value that routes std.debug.print and the
//! stdlib panic handler to stderr via the write syscall. Only the subset of
//! VTable functions called by std.debug is implemented; everything else
//! delegates to stubs from std.Io that return errors or panic.
//!
//! Wire it into each app's root file:
//!
//!     pub const std_options_debug_io = innigkeit.interop.debug_io;
const std = @import("std");
const innigkeit = @import("innigkeit");

// Per-thread cancel protection. Must be threadlocal so that each OS thread has its own
// independent protection state.
threadlocal var g_cancel_protection: std.Io.CancelProtection = .unblocked;

/// A File.Writer whose interface drain calls rawWrite(stderr).
var g_stderr_fw: std.Io.File.Writer = .{
    .io = .failing,
    .file = undefined,
    .interface = .{
        .vtable = &innigkeit.io.stderr_vtable,
        .buffer = &.{},
    },
};

/// The std.Io instance for std.debug output.
///
/// Expose via each app's root file:
///   pub const std_options_debug_io = innigkeit.stdlib_config.debug_io;
pub const debug_io: std.Io = .{
    .userdata = null,
    .vtable = &vtable,
};

fn crashHandler(_: ?*anyopaque) void {
    _ = innigkeit.Syscall.invoke(.exit_process, .{@as(usize, 1)});
}

fn swapCancelProtection(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    const old = g_cancel_protection;
    g_cancel_protection = new;
    return old;
}

fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {}

fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    while (@atomicLoad(u32, ptr, .acquire) == expected) {
        _ = innigkeit.Syscall.invoke(.futex_wait, .{ @intFromPtr(ptr), expected });
    }
}

fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    _ = innigkeit.Syscall.invoke(.futex_wake, .{ @intFromPtr(ptr), max_waiters });
}

fn lockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    return .{
        .file_writer = &g_stderr_fw,
        .terminal_mode = .no_color,
    };
}

fn tryLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!?std.Io.LockedStderr {
    return .{
        .file_writer = &g_stderr_fw,
        .terminal_mode = .no_color,
    };
}

fn unlockStderr(_: ?*anyopaque) void {
    g_stderr_fw.interface.flush() catch {};
}

fn ioNow(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    const result = innigkeit.Syscall.invoke(.uptime_ms, .{});
    const ms = innigkeit.Syscall.decode(result) catch return .zero;
    return .fromNanoseconds(@as(i96, @intCast(ms)) * std.time.ns_per_ms);
}

// --- VTable ---
//
// All functions not used by std.debug delegate to the matching pub stubs from
// std.Io so they compile cleanly and return meaningful errors if ever called.
const vtable: std.Io.VTable = .{
    .crashHandler = crashHandler,

    .async = std.Io.noAsync,
    .concurrent = std.Io.failingConcurrent,
    .await = std.Io.unreachableAwait,
    .cancel = std.Io.unreachableCancel,

    .groupAsync = std.Io.noGroupAsync,
    .groupConcurrent = std.Io.failingGroupConcurrent,
    .groupAwait = std.Io.unreachableGroupAwait,
    .groupCancel = std.Io.unreachableGroupCancel,

    .recancel = std.Io.unreachableRecancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,

    .futexWait = std.Io.noFutexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,

    .operate = std.Io.failingOperate,
    .batchAwaitAsync = std.Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = std.Io.unreachableBatchAwaitConcurrent,
    .batchCancel = std.Io.unreachableBatchCancel,

    .dirCreateDir = std.Io.failingDirCreateDir,
    .dirCreateDirPath = std.Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = std.Io.failingDirCreateDirPathOpen,
    .dirOpenDir = std.Io.failingDirOpenDir,
    .dirStat = std.Io.failingDirStat,
    .dirStatFile = std.Io.failingDirStatFile,
    .dirAccess = std.Io.failingDirAccess,
    .dirCreateFile = std.Io.failingDirCreateFile,
    .dirCreateFileAtomic = std.Io.failingDirCreateFileAtomic,
    .dirOpenFile = std.Io.failingDirOpenFile,
    .dirClose = std.Io.unreachableDirClose,
    .dirRead = std.Io.noDirRead,
    .dirRealPath = std.Io.failingDirRealPath,
    .dirRealPathFile = std.Io.failingDirRealPathFile,
    .dirDeleteFile = std.Io.failingDirDeleteFile,
    .dirDeleteDir = std.Io.failingDirDeleteDir,
    .dirRename = std.Io.failingDirRename,
    .dirRenamePreserve = std.Io.failingDirRenamePreserve,
    .dirSymLink = std.Io.failingDirSymLink,
    .dirReadLink = std.Io.failingDirReadLink,
    .dirSetOwner = std.Io.failingDirSetOwner,
    .dirSetFileOwner = std.Io.failingDirSetFileOwner,
    .dirSetPermissions = std.Io.failingDirSetPermissions,
    .dirSetFilePermissions = std.Io.failingDirSetFilePermissions,
    .dirSetTimestamps = std.Io.noDirSetTimestamps,
    .dirHardLink = std.Io.failingDirHardLink,

    .fileStat = std.Io.failingFileStat,
    .fileLength = std.Io.failingFileLength,
    .fileClose = std.Io.unreachableFileClose,
    .fileWritePositional = std.Io.failingFileWritePositional,
    .fileWriteFileStreaming = std.Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = std.Io.noFileWriteFilePositional,
    .fileReadPositional = std.Io.failingFileReadPositional,
    .fileSeekBy = std.Io.failingFileSeekBy,
    .fileSeekTo = std.Io.failingFileSeekTo,
    .fileSync = std.Io.failingFileSync,
    .fileIsTty = std.Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = std.Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = std.Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = std.Io.failingFileSetLength,
    .fileSetOwner = std.Io.failingFileSetOwner,
    .fileSetPermissions = std.Io.failingFileSetPermissions,
    .fileSetTimestamps = std.Io.noFileSetTimestamps,
    .fileLock = std.Io.failingFileLock,
    .fileTryLock = std.Io.failingFileTryLock,
    .fileUnlock = std.Io.unreachableFileUnlock,
    .fileDowngradeLock = std.Io.failingFileDowngradeLock,
    .fileRealPath = std.Io.failingFileRealPath,
    .fileHardLink = std.Io.failingFileHardLink,

    .fileMemoryMapCreate = std.Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = std.Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = std.Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = std.Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = std.Io.unreachableFileMemoryMapWrite,

    .processExecutableOpen = std.Io.failingProcessExecutableOpen,
    .processExecutablePath = std.Io.failingProcessExecutablePath,
    .lockStderr = lockStderr,
    .tryLockStderr = tryLockStderr,
    .unlockStderr = unlockStderr,
    .processCurrentPath = std.Io.failingProcessCurrentPath,
    .processSetCurrentDir = std.Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = std.Io.failingProcessSetCurrentPath,
    .processReplace = std.Io.failingProcessReplace,
    .processReplacePath = std.Io.failingProcessReplacePath,
    .processSpawn = std.Io.failingProcessSpawn,
    .processSpawnPath = std.Io.failingProcessSpawnPath,
    .childWait = std.Io.unreachableChildWait,
    .childKill = std.Io.unreachableChildKill,

    .progressParentFile = std.Io.failingProgressParentFile,

    .random = std.Io.noRandom,
    .randomSecure = std.Io.failingRandomSecure,

    .now = ioNow,
    .clockResolution = std.Io.failingClockResolution,
    .sleep = std.Io.noSleep,

    .netListenIp = std.Io.failingNetListenIp,
    .netAccept = std.Io.failingNetAccept,
    .netBindIp = std.Io.failingNetBindIp,
    .netConnectIp = std.Io.failingNetConnectIp,
    .netListenUnix = std.Io.failingNetListenUnix,
    .netConnectUnix = std.Io.failingNetConnectUnix,
    .netSocketCreatePair = std.Io.failingNetSocketCreatePair,
    .netSend = std.Io.failingNetSend,
    .netRead = std.Io.failingNetRead,
    .netWrite = std.Io.failingNetWrite,
    .netWriteFile = std.Io.failingNetWriteFile,
    .netClose = std.Io.unreachableNetClose,
    .netShutdown = std.Io.failingNetShutdown,
    .netInterfaceNameResolve = std.Io.failingNetInterfaceNameResolve,
    .netInterfaceName = std.Io.unreachableNetInterfaceName,
    .netLookup = std.Io.failingNetLookup,
};
