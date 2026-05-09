const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const root = @import("root.zig");

pub const PhysicalRange = struct {
    address: Address,
    size: core.Size,

    pub inline fn from(address: Address, size: core.Size) PhysicalRange {
        return .{ .address = address, .size = size };
    }

    /// Returns the physical range corresponding to the given direct map virtual range.
    ///
    /// **REQUIREMENTS**:
    /// - `direct_map_range` must be fully contained within the direct map.
    pub inline fn fromDirectMap(direct_map_range: root.KernelVirtualRange) PhysicalRange {
        if (core.is_debug) std.debug.assert(innigkeit.mem.globals.direct_map.fullyContains(direct_map_range));
        return .{
            .address = .{
                .value = direct_map_range.address.value - innigkeit.mem.globals.direct_map.address.value,
            },
            .size = direct_map_range.size,
        };
    }

    /// Returns the direct map virtual range corresponding to this physical range.
    ///
    /// **REQUIREMENTS**:
    /// - `range` must be fully covered by the direct map.
    pub inline fn toDirectMap(range: PhysicalRange) root.KernelVirtualRange {
        const direct_map_range: root.KernelVirtualRange = .{
            .address = .{ .value = range.address.value + innigkeit.mem.globals.direct_map.address.value },
            .size = range.size,
        };
        if (core.is_debug) std.debug.assert(innigkeit.mem.globals.direct_map.fullyContains(direct_map_range));
        return direct_map_range;
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

    const Address = root.PhysicalAddress;
    const Mixin = root.RangeMixin(@This());
};
