//! User-buffer validation and safe user-memory access shared across all
//! syscall handlers.
//!
//! Every transfer between kernel and user memory should go through the
//! helpers in this file: they validate the user range, open the smallest
//! possible SMAP/SUM window around the access, and never leak raw user
//! pointers to the caller.

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

pub const UserAccessError = error{BadAddress};

/// Returns true iff the range `[ptr, ptr+len)` lies entirely within the user
/// virtual address space and does not wrap around zero.
pub fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr +% len < ptr) return false;
    const range: innigkeit.VirtualRange = .from(
        .from(ptr),
        .from(len, .byte),
    );
    return architecture.user.user_memory_range.fullyContains(range);
}

/// Scope guard that enables access to user memory (SMAP/SUM window) for the
/// current task.
///
/// ```zig
/// { // blocked off so defer works
///     const access: UserAccess = .acquire();
///     defer access.release();
///     // ... touch user memory ...
/// }
/// ```
pub const UserAccess = struct {
    task: innigkeit.Task.Current,

    pub fn acquire() UserAccess {
        const task: innigkeit.Task.Current = .get();
        task.incrementEnableAccessToUserMemory();
        return .{ .task = task };
    }

    pub fn release(self: UserAccess) void {
        self.task.decrementEnableAccessToUserMemory();
    }
};

/// Validate that [ptr, ptr+len) is a user range and return it as a read-only
/// slice.
///
/// The returned slice may only be dereferenced while a `UserAccess` window is
/// open; prefer `copyFromUser`/`readUser` unless the data is streamed.
pub fn userSliceConst(ptr: usize, len: usize) UserAccessError![]const u8 {
    if (!validateUserBuffer(ptr, len)) return error.BadAddress;
    return @as([*]const u8, @ptrFromInt(ptr))[0..len];
}

/// Validate that [ptr, ptr+len) is a user range and return it as a mutable
/// slice.
///
/// The returned slice may only be dereferenced while a `UserAccess` window is
/// open; prefer `copyToUser`/`writeUser` unless the data is streamed.
pub fn userSlice(ptr: usize, len: usize) UserAccessError![]u8 {
    if (!validateUserBuffer(ptr, len)) return error.BadAddress;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

/// Copy `dst.len` bytes from user memory at `user_ptr` into `dst`.
pub fn copyFromUser(dst: []u8, user_ptr: usize) UserAccessError!void {
    const src = try userSliceConst(user_ptr, dst.len);
    const access: UserAccess = .acquire();
    defer access.release();
    @memcpy(dst, src);
}

/// Copy `src` into user memory at `user_ptr`.
pub fn copyToUser(user_ptr: usize, src: []const u8) UserAccessError!void {
    const dst = try userSlice(user_ptr, src.len);
    const access: UserAccess = .acquire();
    defer access.release();
    @memcpy(dst, src);
}

/// Read a `T` from user memory at `user_ptr`.
pub fn readUser(comptime T: type, user_ptr: usize) UserAccessError!T {
    var value: T = undefined;
    try copyFromUser(std.mem.asBytes(&value), user_ptr);
    return value;
}

/// Write `value` to user memory at `user_ptr`.
pub fn writeUser(user_ptr: usize, value: anytype) UserAccessError!void {
    try copyToUser(user_ptr, std.mem.asBytes(&value));
}

// The tests below only validate addresses; they never dereference user memory.

test "validate: validateUserBuffer rejects ranges that wrap around zero" {
    try std.testing.expect(!validateUserBuffer(std.math.maxInt(usize) - 1, 4));
    try std.testing.expect(!validateUserBuffer(std.math.maxInt(usize), 1));
}

test "validate: validateUserBuffer rejects kernel-half addresses, accepts len 0" {
    const kernel_addr: usize = 0xffff_8000_0000_0000;
    try std.testing.expect(!validateUserBuffer(kernel_addr, 8));

    // A zero-length buffer is always valid, regardless of address.
    try std.testing.expect(validateUserBuffer(kernel_addr, 0));
    try std.testing.expect(validateUserBuffer(0, 0));

    // Sanity check: a small buffer at the start of user memory is valid.
    const user_base = architecture.user.user_memory_range.address.value;
    try std.testing.expect(validateUserBuffer(user_base, 16));
}

test "validate: userSliceConst returns BadAddress for kernel pointers" {
    try std.testing.expectError(
        error.BadAddress,
        userSliceConst(0xffff_8000_0000_0000, 16),
    );
    try std.testing.expectError(
        error.BadAddress,
        userSliceConst(std.math.maxInt(usize) - 1, 4),
    );
}
