const architecture = @import("architecture");
const core = @import("core");
const root = @import("root.zig");
const std = @import("std");

pub const VirtualRange = struct {
    address: Address,
    size: core.Size,

    pub inline fn from(address: Address, size: core.Size) VirtualRange {
        return .{ .address = address, .size = size };
    }

    pub const Tagged = union(enum) {
        kernel: root.KernelVirtualRange,
        user: root.UserVirtualRange,
        invalid,
    };

    /// Returns the type of memory this range is in, carrying the typed range
    /// for `kernel`/`user` so callers need not re-project (and re-validate) via
    /// `toKernel`/`toUser`.
    ///
    /// If the range is not fully contained in either kernel or user memory, returns `.invalid`.
    pub fn tagged(range: VirtualRange) Tagged {
        if (architecture.paging.kernel_memory_range.fullyContains(range))
            return .{ .kernel = .{ .address = range.address._kernel, .size = range.size } }
        else if (architecture.user.user_memory_range.fullyContains(range))
            return .{ .user = .{ .address = range.address._user, .size = range.size } }
        else {
            @branchHint(.cold);
            return .invalid;
        }
    }

    /// Converts this range to a kernel range.
    ///
    /// **REQUIREMENTS**:
    /// - The range must be fully contained in kernel memory.
    pub inline fn toKernel(range: VirtualRange) root.KernelVirtualRange {
        if (core.is_debug) std.debug.assert(architecture.paging.kernel_memory_range.fullyContains(range));
        return .{
            .address = range.address._kernel,
            .size = range.size,
        };
    }

    /// Converts this range to a user range.
    ///
    /// **REQUIREMENTS**:
    /// - The range must be fully contained in user memory.
    pub inline fn toUser(range: VirtualRange) root.UserVirtualRange {
        if (core.is_debug) std.debug.assert(architecture.user.user_memory_range.fullyContains(range));
        return .{
            .address = range.address._user,
            .size = range.size,
        };
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

    const Address = root.VirtualAddress;
    const Mixin = root.RangeMixin(@This());
};
