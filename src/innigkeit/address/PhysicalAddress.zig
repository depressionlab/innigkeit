const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const PhysicalAddress = extern struct {
    value: usize,

    pub const zero: PhysicalAddress = .from(0);

    pub inline fn from(value: usize) PhysicalAddress {
        return .{ .value = value };
    }

    /// Returns the physical address of this direct map virtual address.
    ///
    /// **REQUIREMENTS**:
    /// - The provided `address` is in the direct map.
    pub inline fn fromDirectMap(direct_map_address: root.KernelVirtualAddress) PhysicalAddress {
        if (core.is_debug) std.debug.assert(innigkeit.memory.globals.direct_map.containsAddress(direct_map_address));
        return .{ .value = direct_map_address.value - innigkeit.memory.globals.direct_map.address.value };
    }

    /// Returns the direct map virtual address corresponding to this physical address.
    ///
    /// **REQUIREMENTS**:
    /// - The provided `address` is covered by the direct map.
    pub inline fn toDirectMap(physical_address: PhysicalAddress) root.KernelVirtualAddress {
        const direct_map_address: root.KernelVirtualAddress = .{ .value = physical_address.value + innigkeit.memory.globals.direct_map.address.value };
        if (core.is_debug) std.debug.assert(innigkeit.memory.globals.direct_map.containsAddress(direct_map_address));
        return direct_map_address;
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
        core.testing.expectSize(PhysicalAddress, .of(usize));
    }
};
