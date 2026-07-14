const architecture = @import("architecture");
const core = @import("core");
const root = @import("root.zig");
const std = @import("std");

pub const VirtualAddress = extern union {
    _kernel: root.KernelVirtualAddress,
    _user: root.UserVirtualAddress,
    value: usize,

    pub const zero: VirtualAddress = .from(0);
    pub const undefined_address: VirtualAddress = .from(0xAAAAAAAAAAAAAAAA);
    pub const max: VirtualAddress = .from(std.math.maxInt(usize));

    pub inline fn from(value: usize) VirtualAddress {
        return .{ .value = value };
    }

    pub const Tagged = union(enum) {
        kernel: root.KernelVirtualAddress,
        user: root.UserVirtualAddress,
        invalid,
    };

    /// Returns the type of memory this address points to, carrying the typed
    /// address for `kernel`/`user` so callers need not re-project (and
    /// re-validate) via `toKernel`/`toUser`.
    pub fn tagged(address: VirtualAddress) Tagged {
        if (architecture.paging.kernel_memory_range.containsAddress(address))
            return .{ .kernel = .{ .value = address.value } }
        else if (architecture.user.user_memory_range.containsAddress(address))
            return .{ .user = .{ .value = address.value } }
        else {
            @branchHint(.cold);
            return .invalid;
        }
    }

    /// Turn a virtual address into a kernel virtual address.
    ///
    /// **REQUIREMENTS**:
    /// - The address must be in the kernel memory range.
    pub inline fn toKernel(address: VirtualAddress) root.KernelVirtualAddress {
        if (core.is_debug) std.debug.assert(architecture.paging.kernel_memory_range.containsAddress(address));
        return address._kernel;
    }

    /// Turn a virtual address into a user virtual address.
    ///
    /// **REQUIREMENTS**:
    /// - The address must be in the user memory range.
    pub inline fn toUser(address: VirtualAddress) root.UserVirtualAddress {
        if (core.is_debug) std.debug.assert(architecture.user.user_memory_range.containsAddress(address));
        return address._user;
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
        core.testing.expectSize(VirtualAddress, .of(usize));
    }
};
