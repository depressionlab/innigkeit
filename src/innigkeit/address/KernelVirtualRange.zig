const std = @import("std");
const architecture = @import("architecture");
const core = @import("core");
const root = @import("root.zig");

pub const KernelVirtualRange = struct {
    address: Address,
    size: core.Size,

    /// Creates a range from an address and size.
    ///
    /// **REQUIREMENTS**:
    /// - The range must be fully contained in kernel memory.
    pub inline fn from(address: Address, size: core.Size) KernelVirtualRange {
        const range: KernelVirtualRange = .{ .address = address, .size = size };
        if (core.is_debug) std.debug.assert(architecture.paging.kernel_memory_range.fullyContains(range.toVirtualRange()));
        return range;
    }

    /// Creates a range from a slice.
    ///
    /// **REQUIREMENTS**:
    /// - The slice must be fully contained in kernel memory.
    pub inline fn fromSlice(comptime T: type, slice: []const T) KernelVirtualRange {
        return .from(.{ .value = @intFromPtr(slice.ptr) }, core.Size.of(T).multiplyScalar(slice.len));
    }

    /// Creates a new kernel virtual range from a pointer.
    ///
    /// **REQUIREMENTS**:
    /// - The pointer must be a valid kernel pointer.
    pub inline fn fromPtr(ptr: anytype) KernelVirtualRange {
        const T = comptime blk: {
            const pointer_type_info = @typeInfo(@TypeOf(ptr)).pointer;
            std.debug.assert(pointer_type_info.size == .one);
            break :blk pointer_type_info.child;
        };
        return .from(.{ .value = @intFromPtr(ptr) }, .of(T));
    }

    pub inline fn toVirtualRange(range: KernelVirtualRange) root.VirtualRange {
        return .{
            .address = .{ ._kernel = range.address },
            .size = range.size,
        };
    }

    /// Returns a mutable slice of bytes in this range.
    ///
    /// **REQUIREMENTS**:
    /// - The range must be fully contained in kernel memory.
    pub inline fn byteSlice(range: KernelVirtualRange) []u8 {
        return range.address.toPtr([*]u8)[0..range.size.value];
    }

    pub const pageAligned: fn (range: @This()) callconv(.@"inline") bool = Mixin.pageAligned;
    pub const pageAlign: fn (range: @This()) callconv(.@"inline") @This() = Mixin.pageAlign;
    pub const last: fn (range: @This()) Address = Mixin.last;
    pub const after: fn (range: @This()) callconv(.@"inline") Address = Mixin.after;
    pub const anyOverlap: fn (range: @This(), other: @This()) bool = Mixin.anyOverlap;
    pub const fullyContains: fn (range: @This(), other: @This()) bool = Mixin.fullyContains;
    pub const containsAddress: fn (range: @This(), address: Address) bool = Mixin.containsAddress;
    pub const containsAddressOrder: fn (range: @This(), address: Address) std.math.Order = Mixin.containsAddressOrder;
    pub const format: fn (range: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Address = root.KernelVirtualAddress;
    const Mixin = root.RangeMixin(@This());
};
