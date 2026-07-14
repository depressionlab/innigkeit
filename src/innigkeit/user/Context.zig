//! Handler-facing syscall ABI (the Context handed to syscall handlers).
//!
//! Lightweight handler convention: `fn (Context) Error.Syscall!usize`.
//! Returns a non-negative `usize` (count/handle/address/0) on success,
//! or an `Error.Syscall` value. The dispatcher maps this error to its
//! stable wire code in one place. A handler should never name a physical
//! register.
const Context = @This();

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

const Arg = architecture.user.SyscallFrame.Arg;

const Process = @import("Process.zig");
const Thread = @import("Thread.zig");

/// The internal per-syscall frame being wrapped.
frame: architecture.user.SyscallFrame,

/// Raw positional register argument (pointer width).
pub inline fn arg(self: Context, comptime a: Arg) usize {
    return self.frame.arg(a);
}

/// A positional argument narrowed to `u32` (handles, small flags, ports).
pub inline fn arg32(self: Context, comptime a: Arg) u32 {
    return @truncate(self.frame.arg(a));
}

/// A positional argument cast to `u64` (backwards-compatibility).
pub inline fn arg64(self: Context, comptime a: Arg) u64 {
    return @intCast(self.frame.arg(a));
}

/// The calling task.
pub inline fn currentTask(self: Context) innigkeit.Task.Current {
    _ = self;
    return .get();
}

/// The calling process.
pub inline fn process(self: Context) *Process {
    return .from(self.currentTask().task);
}

/// The calling thread.
pub inline fn thread(self: Context) *Thread {
    return .from(self.currentTask().task);
}

/// True if the calling process holds the named entitlement.
pub inline fn entitled(self: Context, comptime field: []const u8) bool {
    if (!innigkeit.config.security.enforce_entitlements) return true;
    return @field(self.process().entitlements, field);
}
