const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const root = @import("root.zig");

pub const UserVirtualAddress = extern struct {
    value: usize,

    /// Creates a new user virtual address from a raw value.
    ///
    /// **REQUIREMENTS**:
    /// - The address must be within the user memory range.
    pub inline fn from(value: usize) UserVirtualAddress {
        const address: UserVirtualAddress = .{ .value = value };
        if (core.is_debug) std.debug.assert(architecture.user.user_memory_range.containsAddress(address.toVirtualAddress()));
        return address;
    }

    /// Creates a pointer from a user virtual address.
    ///
    /// **REQUIREMENTS**:
    /// - The current task must have enabled access to user memory.
    pub inline fn ptr(address: UserVirtualAddress, comptime PtrT: type) PtrT {
        if (core.is_debug) std.debug.assert(innigkeit.Task.Current.get().task.enable_access_to_user_memory_count.load(.acquire) != 0);
        return @ptrFromInt(address.value);
    }

    pub inline fn toVirtualAddress(address: UserVirtualAddress) root.VirtualAddress {
        return .{ ._user = address };
    }

    pub const aligned: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") bool = Mixin.aligned;
    pub const alignForward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignForward;
    pub const alignForwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignForwardInPlace;
    pub const alignBackward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignBackward;
    pub const alignBackwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignBackwardInPlace;
    pub const moveForward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveForward;
    pub const moveForwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveForwardInPlace;
    pub const moveBackward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveBackward;
    pub const moveBackwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveBackwardInPlace;

    pub const pageAligned: fn (address: @This()) callconv(.@"inline") bool = Mixin.pageAligned;
    pub const pageAlignForward: fn (address: @This()) callconv(.@"inline") @This() = Mixin.pageAlignForward;
    pub const pageAlignForwardInPlace: fn (address: *@This()) callconv(.@"inline") void = Mixin.pageAlignForwardInPlace;
    pub const pageAlignBackward: fn (address: @This()) callconv(.@"inline") @This() = Mixin.pageAlignBackward;
    pub const pageAlignBackwardInPlace: fn (address: *@This()) callconv(.@"inline") void = Mixin.pageAlignBackwardInPlace;
    pub const moveForwardPage: fn (address: @This()) callconv(.@"inline") @This() = Mixin.moveForwardPage;
    pub const moveForwardPageInPlace: fn (address: *@This()) callconv(.@"inline") void = Mixin.moveForwardPageInPlace;
    pub const moveBackwardPage: fn (address: @This()) callconv(.@"inline") @This() = Mixin.moveBackwardPage;
    pub const moveBackwardPageInPlace: fn (address: *@This()) callconv(.@"inline") void = Mixin.moveBackwardPageInPlace;

    pub const equal: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.equal;
    pub const lessThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThan;
    pub const lessThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThanOrEqual;
    pub const greaterThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThan;
    pub const greaterThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThanOrEqual;

    pub const difference: fn (address: @This(), other: @This()) callconv(.@"inline") core.Size = Mixin.difference;
    pub const format: fn (address: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Mixin = root.AddressMixin(@This());

    comptime {
        core.testing.expectSize(UserVirtualAddress, .of(usize));
    }
};
