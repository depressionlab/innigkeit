const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const UserVirtualRange = struct {
    address: Address,
    size: core.Size,

    /// Creates a range from an address and size.
    ///
    /// **REQUIREMENTS**:
    /// - The range must be fully contained in user memory.
    pub inline fn from(address: Address, size: core.Size) UserVirtualRange {
        const range: UserVirtualRange = .{ .address = address, .size = size };
        if (core.is_debug) std.debug.assert(architecture.user.user_memory_range.fullyContains(range.toVirtualRange()));
        return range;
    }

    pub inline fn toVirtualRange(range: UserVirtualRange) root.VirtualRange {
        return .{
            .address = .{ ._user = range.address },
            .size = range.size,
        };
    }

    /// Returns a mutable slice of bytes in this range.
    ///
    /// **REQUIREMENTS**:
    /// - The current task must have enabled access to user memory.
    pub inline fn byteSlice(range: UserVirtualRange) []u8 {
        if (core.is_debug) std.debug.assert(innigkeit.Task.Current.get().task.enable_access_to_user_memory_count.load(.acquire) != 0);
        return range.address.ptr([*]u8)[0..range.size.value];
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

    const Address = root.UserVirtualAddress;
    const Mixin = root.RangeMixin(@This());
};
