//! The kernel's single error type, shared by both the kernel and userspace.
//!
//! Kernel dispatch maps Error.Syscall to Error.Abi once, and userspace maps
//! Error.Abi to Error.Syscall from the same table.
//!
//! **Wire numbers are POSIX-compatible on purpose.** We reuse
//! the codes so the kernel can migrate to Error.Syscall while userspace still
//! decodes the same numbers and so the ranges never straddle.
const Error = @This();

/// Curated kernel syscall error set.
///
/// Add new errors deliberately.
pub const Syscall = error{
    /// The operation was not permitted (missing entitlement or capability right).
    PermissionDenied,
    /// A capability/file handle was invalid, stale, or the wrong type.
    BadHandle,
    /// A user pointer/range was outside user space, unmapped, or misaligned.
    BadAddress,
    /// A non-blocking operation would have blocked, or no data was ready.
    WouldBlock,
    /// Out of memory (kernel allocation failed).
    OutOfMemory,
    /// The named/numbered object does not exist.
    NotFound,
    /// The object already exists.
    AlreadyExists,
    /// An argument was malformed or out of range.
    InvalidArgument,
    /// The required device is absent.
    NoDevice,
    /// No space left (storage/quota).
    NoSpace,
    /// A device/IO operation failed.
    IoError,
    /// The operation is not supported.
    Unsupported,
    /// Decoding the error from the wire code failed.
    Unknown,
};

/// Stable userspace negative wire codes for `Error.Syscall`.
///
/// Note: This is append-only. Never renumber an existing varient.
pub const Abi = enum(i64) {
    permission_denied = -1, // EPERM
    not_found = -2, // ENOENT
    io_error = -5, // EIO
    bad_handle = -9, // EBADF
    would_block = -11, // EAGAIN / EWOULDBLOCK
    out_of_memory = -12, // ENOMEM
    bad_address = -14, // EFAULT
    already_exists = -17, // EEXIST
    no_device = -19, // ENODEV
    invalid_argument = -22, // EINVAL
    no_space = -28, // ENOSPC
    unsupported = -38, // ENOSYS
};

/// Map an `Error.Syscall` to its stable wire code.
pub fn toAbi(err: Error.Syscall) Error.Abi {
    return switch (err) {
        Error.Syscall.PermissionDenied => .permission_denied,
        Error.Syscall.BadHandle => .bad_handle,
        Error.Syscall.BadAddress => .bad_address,
        Error.Syscall.WouldBlock => .would_block,
        Error.Syscall.OutOfMemory => .out_of_memory,
        Error.Syscall.NotFound => .not_found,
        Error.Syscall.AlreadyExists => .already_exists,
        Error.Syscall.InvalidArgument => .invalid_argument,
        Error.Syscall.NoDevice => .no_device,
        Error.Syscall.NoSpace => .no_space,
        Error.Syscall.IoError => .io_error,
        Error.Syscall.Unsupported => .unsupported,
        Error.Syscall.Unknown => unreachable,
    };
}

/// The negated `i64` a handler/dispatch returns for an error (the value placed
/// in the return register).
pub fn code(err: Error.Syscall) i64 {
    return @intFromEnum(toAbi(err));
}

/// Map a wire code back to a `Error.Syscall`. Returns `Error.Unknown` for an
/// unrecognised code (forward/backward ABI compatibility).
pub fn fromCode(raw: i64) Error.Syscall {
    return switch (raw) {
        -1 => Error.Syscall.PermissionDenied,
        -2 => Error.Syscall.NotFound,
        -5 => Error.Syscall.IoError,
        -9 => Error.Syscall.BadHandle,
        -11 => Error.Syscall.WouldBlock,
        -12 => Error.Syscall.OutOfMemory,
        -14 => Error.Syscall.BadAddress,
        -17 => Error.Syscall.AlreadyExists,
        -19 => Error.Syscall.NoDevice,
        -22 => Error.Syscall.InvalidArgument,
        -28 => Error.Syscall.NoSpace,
        -38 => Error.Syscall.Unsupported,
        else => Error.Syscall.Unknown,
    };
}

const std = @import("std");

test "error: Syscall <-> code round-trips and codes are unique/negative" {
    var seen: [64]bool = .{false} ** 64;
    const all = [_]Error.Syscall{
        error.PermissionDenied, error.BadHandle,       error.BadAddress,
        error.WouldBlock,       error.OutOfMemory,     error.NotFound,
        error.AlreadyExists,    error.InvalidArgument, error.NoDevice,
        error.NoSpace,          error.IoError,         error.Unsupported,
    };
    for (all) |err| {
        const c = Error.code(err);
        try std.testing.expect(c < 0);
        const idx: usize = @intCast(-c);
        try std.testing.expect(idx < seen.len);
        try std.testing.expect(!seen[idx]); // unique
        seen[idx] = true;
        try std.testing.expect(fromCode(c) == err); // round-trip
    }
    try std.testing.expect(Error.fromCode(-9999) == Error.Syscall.Unknown);
}
