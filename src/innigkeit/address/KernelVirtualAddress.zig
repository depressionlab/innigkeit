const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const KernelVirtualAddress = extern struct {
    value: usize,

    /// Creates a new kernel virtual address from a raw value.
    ///
    /// **REQUIREMENTS**:
    /// - The address must be within the kernel memory range.
    pub inline fn from(value: usize) KernelVirtualAddress {
        const address: KernelVirtualAddress = .{ .value = value };
        if (core.is_debug) std.debug.assert(architecture.paging.kernel_memory_range.containsAddress(address.toVirtualAddress()));
        return address;
    }

    /// Creates a new kernel virtual address from a pointer.
    ///
    /// **REQUIREMENTS**:
    /// - The pointer must be a valid kernel pointer.
    pub inline fn fromPtr(ptr: anytype) KernelVirtualAddress {
        comptime {
            const pointer_type_info = @typeInfo(@TypeOf(ptr)).pointer;
            std.debug.assert(pointer_type_info.size == .one or pointer_type_info.size == .many);
        }
        return .{ .value = @intFromPtr(ptr) };
    }

    /// Converts the kernel virtual address to a pointer.
    ///
    /// **REQUIREMENTS**:
    /// - The pointer must be a valid kernel pointer.
    pub inline fn toPtr(self: KernelVirtualAddress, comptime PtrT: type) PtrT {
        // this is the sanctioned kernel-address-to-pointer convension.
        return @ptrFromInt(self.value);
    }

    pub inline fn toVirtualAddress(self: KernelVirtualAddress) root.VirtualAddress {
        return .{ ._kernel = self };
    }

    /// Shifts an address to account for any applied virtual offset applied to the kernel (KASLR).
    ///
    /// The resulting address might no longer be a vaild kernel address, use `VirtualAddress.getType` to check.
    pub inline fn applyKernelOffset(self: KernelVirtualAddress) root.VirtualAddress {
        return self.toVirtualAddress().moveBackward(innigkeit.memory.globals.kernel_virtual_offset);
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
        core.testing.expectSize(KernelVirtualAddress, .of(usize));
    }
};
