const std = @import("std");

const architecture = @import("architecture");
const root = @import("root.zig");

pub fn RangeMixin(comptime Range: type) type {
    return struct {
        // We disallow the address `VirtualAddress.max` from being a valid kernel or user address, this allows these range functions to be
        // implemented more efficiently. See `arch/arch.zig`.

        /// Returns whether the range is page aligned.
        ///
        /// Both the address and size must be page aligned for this to return true.
        pub inline fn pageAligned(range: Range) bool {
            return range.address.pageAligned() and range.size.aligned(architecture.paging.standard_page_size_alignment);
        }

        /// Returns the range with the address and size page aligned.
        ///
        /// The address is aligned backward and the size is aligned forward.
        pub inline fn pageAlign(range: Range) Range {
            const new_address = range.address.pageAlignBackward();
            // `after()` (exclusive end), not `last()` (inclusive last byte):
            // `pageAlignForward` is a no-op on an already-aligned value, so
            // aligning the *inclusive* last byte forward silently fails to
            // extend the range whenever that byte already sits exactly on a
            // page boundary (e.g. address=0, size=4097 covers byte 0x1000,
            // which needs a second page, but `last() == 0x1000` is already
            // page-aligned and `pageAlignForward` would leave it there).
            return .{
                .address = new_address,
                .size = new_address.difference(range.after().pageAlignForward()),
            };
        }

        /// Returns the last address in this range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub fn last(range: Range) Address {
            if (range.size.equal(.zero)) {
                @branchHint(.unlikely);
                return range.address;
            }
            return range.address.moveForward(range.size.subtract(.one));
        }

        /// Returns the address of the first byte after the range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub inline fn after(range: Range) Address {
            return range.address.moveForward(range.size);
        }

        pub fn anyOverlap(range: Range, other: Range) bool {
            return range.address.lessThan(after(other)) and after(range).greaterThan(other.address);
        }

        pub fn fullyContains(range: Range, other: Range) bool {
            return range.address.lessThanOrEqual(other.address) and after(range).greaterThanOrEqual(after(other));
        }

        pub fn containsAddress(range: Range, address: Address) bool {
            return range.address.lessThanOrEqual(address) and after(range).greaterThan(address);
        }

        pub fn containsAddressOrder(range: Range, address: Address) std.math.Order {
            if (range.address.greaterThan(address)) return .lt;
            if (after(range).lessThanOrEqual(address)) return .gt;
            return .eq;
        }

        pub fn format(range: Range, writer: *std.Io.Writer) !void {
            const name = comptime switch (Range) {
                root.VirtualRange => "VirtualRange",
                root.KernelVirtualRange => "KernelVirtualRange",
                root.UserVirtualRange => "UserVirtualRange",
                root.PhysicalRange => "PhysicalRange",
                else => unreachable,
            };

            try writer.writeAll(comptime name ++ "{ 0x");
            try writer.printInt(
                range.address.value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" - 0x");
            try writer.printInt(
                range.last().value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" - ");
            try range.size.format(writer);
            try writer.writeAll(" }");
        }

        const Address = switch (Range) {
            root.VirtualRange => root.VirtualAddress,
            root.KernelVirtualRange => root.KernelVirtualAddress,
            root.UserVirtualRange => root.UserVirtualAddress,
            root.PhysicalRange => root.PhysicalAddress,
            else => unreachable,
        };
    };
}
