const architecture = @import("architecture");
const core = @import("core");
const root = @import("root.zig");
const std = @import("std");

pub fn AddressMixin(comptime Address: type) type {
    return struct {
        pub inline fn aligned(address: Address, alignment: std.mem.Alignment) bool {
            return alignment.check(toValue(address));
        }

        pub inline fn pageAligned(address: Address) bool {
            return address.aligned(architecture.paging.standard_page_size_alignment);
        }

        pub inline fn alignForward(address: Address, alignment: std.mem.Alignment) Address {
            return fromValue(alignment.forward(toValue(address)));
        }

        pub inline fn pageAlignForward(address: Address) Address {
            return address.alignForward(architecture.paging.standard_page_size_alignment);
        }

        pub inline fn alignForwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.* = fromValue(alignment.forward(toValue(address.*)));
        }

        pub inline fn pageAlignForwardInPlace(address: *Address) void {
            address.alignForwardInPlace(architecture.paging.standard_page_size_alignment);
        }

        pub inline fn alignBackward(address: Address, alignment: std.mem.Alignment) Address {
            return fromValue(alignment.backward(toValue(address)));
        }

        pub inline fn pageAlignBackward(address: Address) Address {
            return address.alignBackward(architecture.paging.standard_page_size_alignment);
        }

        pub inline fn alignBackwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.* = fromValue(alignment.backward(toValue(address.*)));
        }

        pub inline fn pageAlignBackwardInPlace(address: *Address) void {
            address.alignBackwardInPlace(architecture.paging.standard_page_size_alignment);
        }

        pub inline fn moveForward(address: Address, size: core.Size) Address {
            return fromValue(toValue(address) + @intFromEnum(size));
        }

        pub inline fn moveForwardPage(address: Address) Address {
            return address.moveForward(architecture.paging.standard_page_size);
        }

        pub inline fn moveForwardInPlace(address: *Address, size: core.Size) void {
            address.* = fromValue(toValue(address.*) + @intFromEnum(size));
        }

        pub inline fn moveForwardPageInPlace(address: *Address) void {
            address.moveForwardInPlace(architecture.paging.standard_page_size);
        }

        pub inline fn moveBackward(address: Address, size: core.Size) Address {
            return fromValue(toValue(address) - @intFromEnum(size));
        }

        pub inline fn moveBackwardPage(address: Address) Address {
            return address.moveBackward(architecture.paging.standard_page_size);
        }

        pub inline fn moveBackwardInPlace(address: *Address, size: core.Size) void {
            address.* = fromValue(toValue(address.*) - @intFromEnum(size));
        }

        pub inline fn moveBackwardPageInPlace(address: *Address) void {
            address.moveBackwardInPlace(architecture.paging.standard_page_size);
        }

        pub inline fn equal(address: Address, other: Address) bool {
            return toValue(address) == toValue(other);
        }

        pub inline fn lessThan(address: Address, other: Address) bool {
            return toValue(address) < toValue(other);
        }

        pub inline fn lessThanOrEqual(address: Address, other: Address) bool {
            return toValue(address) <= toValue(other);
        }

        pub inline fn greaterThan(address: Address, other: Address) bool {
            return toValue(address) > toValue(other);
        }

        pub inline fn greaterThanOrEqual(address: Address, other: Address) bool {
            return toValue(address) >= toValue(other);
        }

        /// Returns the size from  `address` to `other`.
        ///
        /// `address + address.difference(other) == other`
        ///
        /// **REQUIREMENTS**:
        /// - `other` must be greater than or equal to `address`
        pub inline fn difference(address: Address, other: Address) core.Size {
            if (core.is_debug) std.debug.assert(greaterThanOrEqual(other, address));
            return .from(toValue(other) - toValue(address), .byte);
        }

        pub fn format(address: Address, writer: *std.Io.Writer) !void {
            const name = comptime switch (Address) {
                root.VirtualAddress => "VirtualAddress",
                root.KernelVirtualAddress => "KernelVirtualAddress",
                root.UserVirtualAddress => "UserVirtualAddress",
                root.PhysicalAddress => "PhysicalAddress",
                else => unreachable,
            };

            try writer.writeAll(comptime name ++ "{ 0x");
            try writer.printInt(
                toValue(address),
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" }");
        }

        /// `VirtualAddress` stays a raw `.value`-carrying union (it needs a
        /// concrete field to tag `._kernel`/`._user` against); the other
        /// three address types are `enum(usize){_}` wrappers. This is the
        /// one place that distinction is visible, so every other function
        /// above can stay written in terms of a plain `usize`.
        pub inline fn fromValue(value: usize) Address {
            return switch (Address) {
                root.VirtualAddress => .{ .value = value },
                root.KernelVirtualAddress, root.UserVirtualAddress, root.PhysicalAddress => @enumFromInt(value),
                else => unreachable,
            };
        }

        pub inline fn toValue(address: Address) usize {
            return switch (Address) {
                root.VirtualAddress => address.value,
                root.KernelVirtualAddress, root.UserVirtualAddress, root.PhysicalAddress => @intFromEnum(address),
                else => unreachable,
            };
        }
    };
}
