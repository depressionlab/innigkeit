const core = @import("core");
const std = @import("std");

/// Represents a size in bytes.
pub const Size = enum(u64) {
    zero = 0,
    one = 1,

    _,

    pub const Unit = enum(u64) {
        byte = 1,
        kib = 1 * 1024,
        mib = 1 * 1024 * 1024,
        gib = 1 * 1024 * 1024 * 1024,
        tib = 1 * 1024 * 1024 * 1024 * 1024,
    };

    pub inline fn of(comptime T: type) Size {
        return @fromBackingInt(@intCast(@sizeOf(T)));
    }

    pub fn from(amount: u64, unit: Size.Unit) Size {
        return @fromBackingInt(@intCast(amount * @backingInt(unit)));
    }

    pub inline fn toAlignment(self: Size) std.mem.Alignment {
        return .fromByteUnits(@backingInt(self));
    }

    pub inline fn aligned(self: Size, alignment: std.mem.Alignment) bool {
        return alignment.check(@backingInt(self));
    }

    pub inline fn alignForward(self: Size, alignment: std.mem.Alignment) Size {
        return @fromBackingInt(@intCast(alignment.forward(@backingInt(self))));
    }

    pub inline fn alignForwardInPlace(self: *Size, alignment: std.mem.Alignment) void {
        self.* = @fromBackingInt(@intCast(alignment.forward(@backingInt(self.*))));
    }

    pub inline fn alignBackward(self: Size, alignment: std.mem.Alignment) Size {
        return @fromBackingInt(@intCast(alignment.backward(@backingInt(self))));
    }

    pub inline fn alignBackwardInPlace(self: *Size, alignment: std.mem.Alignment) void {
        self.* = @fromBackingInt(@intCast(alignment.backward(@backingInt(self.*))));
    }

    /// Returns the amount of `self` sizes needed to cover `target`.
    ///
    /// Caller must ensure `self` is not zero.
    pub fn amountToCover(self: Size, target: Size) u64 {
        return target.add(self.subtract(.one)).divide(self);
    }

    test amountToCover {
        {
            const size: Size = .from(10, .byte);
            const target: Size = .from(25, .byte);
            const expected: u64 = 3;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size: Size = .one;
            const target: Size = .from(30, .byte);
            const expected: u64 = 30;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size: Size = .from(100, .byte);
            const target: Size = .from(100, .byte);
            const expected: u64 = 1;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size: Size = .from(512, .byte);
            const target = core.Size.from(64, .mib);
            const expected: u64 = 131072;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }
    }

    pub inline fn equal(self: Size, other: Size) bool {
        return @backingInt(self) == @backingInt(other);
    }

    pub inline fn notEqual(self: Size, other: Size) bool {
        return @backingInt(self) != @backingInt(other);
    }

    pub inline fn lessThan(self: Size, other: Size) bool {
        return @backingInt(self) < @backingInt(other);
    }

    pub inline fn lessThanOrEqual(self: Size, other: Size) bool {
        return @backingInt(self) <= @backingInt(other);
    }

    pub inline fn greaterThan(self: Size, other: Size) bool {
        return @backingInt(self) > @backingInt(other);
    }

    pub inline fn greaterThanOrEqual(self: Size, other: Size) bool {
        return @backingInt(self) >= @backingInt(other);
    }

    pub fn compare(self: Size, other: Size) std.math.Order {
        if (self.lessThan(other)) return .lt;
        if (self.greaterThan(other)) return .gt;
        return .eq;
    }

    pub fn add(self: Size, other: Size) Size {
        return @fromBackingInt(@intCast(@backingInt(self) + @backingInt(other)));
    }

    pub fn addInPlace(self: *Size, other: Size) void {
        self.* = self.add(other);
    }

    pub fn subtract(self: Size, other: Size) Size {
        return @fromBackingInt(@intCast(@backingInt(self) - @backingInt(other)));
    }

    pub fn subtractInPlace(self: *Size, other: Size) void {
        self.* = self.subtract(other);
    }

    pub fn multiplyScalar(self: Size, value: u64) Size {
        return @fromBackingInt(@intCast(@backingInt(self) * value));
    }

    pub fn multiplyScalarInPlace(self: *Size, value: u64) void {
        self.* = self.multiplyScalar(value);
    }

    pub fn divide(self: Size, other: Size) usize {
        return @backingInt(self) / @backingInt(other);
    }

    pub fn divideInPlace(self: *Size, other: Size) void {
        self.* = @fromBackingInt(@intCast(@backingInt(self.*) / @backingInt(other)));
    }

    pub fn divideScalar(self: Size, value: u64) Size {
        return @fromBackingInt(@intCast(@backingInt(self) / value));
    }

    pub fn divideScalarInPlace(self: *Size, value: u64) void {
        self.* = self.divideScalar(value);
    }

    // Must be kept in descending size order due to the logic in `print`
    const unit_table = .{
        .{ .value = @backingInt(Unit.tib), .name = "TiB" },
        .{ .value = @backingInt(Unit.gib), .name = "GiB" },
        .{ .value = @backingInt(Unit.mib), .name = "MiB" },
        .{ .value = @backingInt(Unit.kib), .name = "KiB" },
        .{ .value = @backingInt(Unit.byte), .name = "B" },
    };

    pub fn print(self: Size, writer: *std.Io.Writer, _: usize) !void {
        var value = @backingInt(self);

        if (value == 0) {
            try writer.writeAll("0 bytes");
            return;
        }

        var emitted_anything = false;

        inline for (unit_table) |unit| blk: {
            if (value < unit.value) break :blk; // continue loop

            const part = value / unit.value;

            if (emitted_anything) try writer.writeAll(", ");

            try writer.printInt(part, 10, .lower, .{});
            try writer.writeAll(comptime " " ++ unit.name);

            value -= part * unit.value;
            emitted_anything = true;
        }
    }

    pub inline fn format(self: Size, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    comptime {
        core.testing.expectSize(Size, .of(u64));
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
