const std = @import("std");
const core = @import("core");

/// Represents a size in bytes.
pub const Size = extern struct {
    value: u64,

    pub const zero: Size = .{ .value = 0 };
    pub const one: Size = .{ .value = 1 };

    pub const Unit = enum(u64) {
        byte = 1,
        kib = 1 * 1024,
        mib = 1 * 1024 * 1024,
        gib = 1 * 1024 * 1024 * 1024,
        tib = 1 * 1024 * 1024 * 1024 * 1024,
    };

    pub inline fn of(comptime T: type) Size {
        return .{ .value = @sizeOf(T) };
    }

    pub fn from(amount: u64, unit: Size.Unit) Size {
        return .{ .value = amount * @intFromEnum(unit) };
    }

    pub inline fn toAlignment(self: Size) std.mem.Alignment {
        return .fromByteUnits(self.value);
    }

    pub inline fn aligned(self: Size, alignment: std.mem.Alignment) bool {
        return alignment.check(self.value);
    }

    pub inline fn alignForward(self: Size, alignment: std.mem.Alignment) Size {
        return .{ .value = alignment.forward(self.value) };
    }

    pub inline fn alignForwardInPlace(self: *Size, alignment: std.mem.Alignment) void {
        self.value = alignment.forward(self.value);
    }

    pub inline fn alignBackward(self: Size, alignment: std.mem.Alignment) Size {
        return .{ .value = alignment.backward(self.value) };
    }

    pub inline fn alignBackwardInPlace(self: *Size, alignment: std.mem.Alignment) void {
        self.value = alignment.backward(self.value);
    }

    /// Returns the amount of `self` sizes needed to cover `target`.
    ///
    /// Caller must ensure `self` is not zero.
    pub fn amountToCover(self: Size, target: Size) u64 {
        const one_byte = core.Size{ .value = 1 };
        return target.add(self.subtract(one_byte)).divide(self);
    }

    test amountToCover {
        {
            const size = Size{ .value = 10 };
            const target = Size{ .value = 25 };
            const expected: u64 = 3;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 1 };
            const target = Size{ .value = 30 };
            const expected: u64 = 30;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 100 };
            const target = Size{ .value = 100 };
            const expected: u64 = 1;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 512 };
            const target = core.Size.from(64, .mib);
            const expected: u64 = 131072;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }
    }

    pub inline fn equal(self: Size, other: Size) bool {
        return self.value == other.value;
    }

    pub inline fn notEqual(self: Size, other: Size) bool {
        return self.value != other.value;
    }

    pub inline fn lessThan(self: Size, other: Size) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: Size, other: Size) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: Size, other: Size) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: Size, other: Size) bool {
        return self.value >= other.value;
    }

    pub fn compare(self: Size, other: Size) std.math.Order {
        if (self.lessThan(other)) return .lt;
        if (self.greaterThan(other)) return .gt;
        return .eq;
    }

    pub fn add(self: Size, other: Size) Size {
        return .{ .value = self.value + other.value };
    }

    pub fn addInPlace(self: *Size, other: Size) void {
        self.value += other.value;
    }

    pub fn subtract(self: Size, other: Size) Size {
        return .{ .value = self.value - other.value };
    }

    pub fn subtractInPlace(self: *Size, other: Size) void {
        self.value -= other.value;
    }

    pub fn multiply(self: Size, other: Size) Size {
        return .{ .value = self.value * other.value };
    }

    pub fn multiplyInPlace(self: *Size, other: Size) void {
        self.value *= other.value;
    }

    pub fn multiplyScalar(self: Size, value: u64) Size {
        return .{ .value = self.value * value };
    }

    pub fn multiplyScalarInPlace(self: *Size, value: u64) void {
        self.value *= value;
    }

    pub fn divide(self: Size, other: Size) usize {
        return self.value / other.value;
    }

    pub fn divideInPlace(self: *Size, other: Size) void {
        self.value /= other.value;
    }

    pub fn divideScalar(self: Size, value: u64) Size {
        return .{ .value = self.value / value };
    }

    pub fn divideScalarInPlace(self: *Size, value: u64) void {
        self.value /= value;
    }

    // Must be kept in descending size order due to the logic in `print`
    const unit_table = .{
        .{ .value = @intFromEnum(Unit.tib), .name = "TiB" },
        .{ .value = @intFromEnum(Unit.gib), .name = "GiB" },
        .{ .value = @intFromEnum(Unit.mib), .name = "MiB" },
        .{ .value = @intFromEnum(Unit.kib), .name = "KiB" },
        .{ .value = @intFromEnum(Unit.byte), .name = "B" },
    };

    pub fn print(self: Size, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        var value = self.value;

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
