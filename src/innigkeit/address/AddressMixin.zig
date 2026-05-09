const std = @import("std");
const architecture = @import("architecture");
const core = @import("core");
const root = @import("root.zig");

pub fn AddressMixin(comptime Address: type) type {
    return struct {
        pub inline fn aligned(address: Address, alignment: std.mem.Alignment) bool {
            return alignment.check(address.value);
        }

        pub inline fn pageAligned(address: Address) bool {
            return architecture.paging.standard_page_size_alignment.check(address.value);
        }

        pub inline fn alignForward(address: Address, alignment: std.mem.Alignment) Address {
            return .{ .value = alignment.forward(address.value) };
        }

        pub inline fn pageAlignForward(address: Address) Address {
            return .{ .value = architecture.paging.standard_page_size_alignment.forward(address.value) };
        }

        pub inline fn alignForwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.value = alignment.forward(address.value);
        }

        pub inline fn pageAlignForwardInPlace(address: *Address) void {
            address.value = architecture.paging.standard_page_size_alignment.forward(address.value);
        }

        pub inline fn alignBackward(address: Address, alignment: std.mem.Alignment) Address {
            return .{ .value = alignment.backward(address.value) };
        }

        pub inline fn pageAlignBackward(address: Address) Address {
            return .{ .value = architecture.paging.standard_page_size_alignment.backward(address.value) };
        }

        pub inline fn alignBackwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.value = alignment.backward(address.value);
        }

        pub inline fn pageAlignBackwardInPlace(address: *Address) void {
            address.value = architecture.paging.standard_page_size_alignment.backward(address.value);
        }

        pub inline fn moveForward(address: Address, size: core.Size) Address {
            return .{ .value = address.value + size.value };
        }

        pub inline fn moveForwardPage(address: Address) Address {
            return .{ .value = address.value + architecture.paging.standard_page_size.value };
        }

        pub inline fn moveForwardInPlace(address: *Address, size: core.Size) void {
            address.value += size.value;
        }

        pub inline fn moveForwardPageInPlace(address: *Address) void {
            address.value += architecture.paging.standard_page_size.value;
        }

        pub inline fn moveBackward(address: Address, size: core.Size) Address {
            return .{ .value = address.value - size.value };
        }

        pub inline fn moveBackwardPage(address: Address) Address {
            return .{ .value = address.value - architecture.paging.standard_page_size.value };
        }

        pub inline fn moveBackwardInPlace(address: *Address, size: core.Size) void {
            address.value -= size.value;
        }

        pub inline fn moveBackwardPageInPlace(address: *Address) void {
            address.value -= architecture.paging.standard_page_size.value;
        }

        pub inline fn equal(address: Address, other: Address) bool {
            return address.value == other.value;
        }

        pub inline fn lessThan(address: Address, other: Address) bool {
            return address.value < other.value;
        }

        pub inline fn lessThanOrEqual(address: Address, other: Address) bool {
            return address.value <= other.value;
        }

        pub inline fn greaterThan(address: Address, other: Address) bool {
            return address.value > other.value;
        }

        pub inline fn greaterThanOrEqual(address: Address, other: Address) bool {
            return address.value >= other.value;
        }

        /// Returns the size from  `address` to `other`.
        ///
        /// `address + address.difference(other) == other`
        ///
        /// **REQUIREMENTS**:
        /// - `other` must be greater than or equal to `address`
        pub inline fn difference(address: Address, other: Address) core.Size {
            if (core.is_debug) std.debug.assert(greaterThanOrEqual(other, address));
            return .from(other.value - address.value, .byte);
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
                address.value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" }");
        }
    };
}
