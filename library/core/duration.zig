const std = @import("std");
const core = @import("core");

/// Represents a duration.
pub const Duration = extern struct {
    /// The duration, in nanoseconds.
    value: u64,

    pub const zero: Duration = .{ .value = 0 };
    pub const one: Duration = .{ .value = 1 };

    pub const Unit = enum(u64) {
        nanosecond = 1,
        microsecond = 1 * 1000,
        millisecond = 1 * 1000 * 1000,
        second = 1 * 1000 * 1000 * 1000,
        minute = 1 * 1000 * 1000 * 1000 * 60,
        hour = 1 * 1000 * 1000 * 1000 * 60 * 60,
        day = 1 * 1000 * 1000 * 1000 * 60 * 60 * 24,
    };

    pub fn from(amount: u64, unit: Duration.Unit) Duration {
        return .{ .value = amount * @intFromEnum(unit) };
    }

    pub inline fn equal(self: Duration, other: Duration) bool {
        return self.value == other.value;
    }

    pub inline fn lessThan(self: Duration, other: Duration) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: Duration, other: Duration) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: Duration, other: Duration) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: Duration, other: Duration) bool {
        return self.value >= other.value;
    }

    pub fn compare(self: Duration, other: Duration) std.math.Order {
        if (self.lessThan(other)) return .lt;
        if (self.greaterThan(other)) return .gt;
        return .eq;
    }

    pub fn add(self: Duration, other: Duration) Duration {
        return .{ .value = self.value + other.value };
    }

    pub fn addInPlace(self: *Duration, other: Duration) void {
        self.value += other.value;
    }

    pub fn subtract(self: Duration, other: Duration) Duration {
        return .{ .value = self.value - other.value };
    }

    pub fn subtractInPlace(self: *Duration, other: Duration) void {
        self.value -= other.value;
    }

    pub fn multiply(self: Duration, other: Duration) Duration {
        return .{ .value = self.value * other.value };
    }

    pub fn multiplyInPlace(self: *Duration, other: Duration) void {
        self.value *= other.value;
    }

    pub fn multiplyScalar(self: Duration, value: u64) Duration {
        return .{ .value = self.value * value };
    }

    pub fn multiplyScalarInPlace(self: *Duration, value: u64) void {
        self.value *= value;
    }

    pub fn divide(self: Duration, other: Duration) Duration {
        return .{ .value = self.value / other.value };
    }

    pub fn divideInPlace(self: *Duration, other: Duration) void {
        self.value /= other.value;
    }

    pub fn divideScalar(self: Duration, value: u64) Duration {
        return .{ .value = self.value / value };
    }

    pub fn divideScalarInPlace(self: *Duration, value: u64) void {
        self.value /= value;
    }

    pub fn print(self: Duration, writer: *std.Io.Writer, indent: usize) !void {
        _ = indent;

        var any_output = false;
        var value = self.value;

        if (value == 0) {
            try writer.writeAll("0.000000000");
            return;
        }

        const days = value / @intFromEnum(Duration.Unit.day);
        value -= days * @intFromEnum(Duration.Unit.day);

        if (days != 0) {
            try writer.printInt(days, 10, .lower, .{});
            try writer.writeByte('.');
            any_output = true;
        }

        const hours = value / @intFromEnum(Duration.Unit.hour);
        value -= hours * @intFromEnum(Duration.Unit.hour);

        if (hours != 0 or any_output) {
            try writer.printInt(hours, 10, .lower, .{ .fill = '0', .width = 2 });
            try writer.writeByte(':');
            any_output = true;
        }

        const minutes = value / @intFromEnum(Duration.Unit.minute);
        value -= minutes * @intFromEnum(Duration.Unit.minute);

        if (minutes != 0 or any_output) {
            try writer.printInt(minutes, 10, .lower, .{ .fill = '0', .width = 2 });
            try writer.writeByte(':');
            any_output = true;
        }

        const seconds = value / @intFromEnum(Duration.Unit.second);
        value -= seconds * @intFromEnum(Duration.Unit.second);

        try writer.printInt(
            seconds,
            10,
            .lower,
            .{ .fill = '0', .width = 2 },
        );
        try writer.writeByte('.');

        try writer.printInt(
            value,
            10,
            .lower,
            .{ .fill = '0', .width = 9 },
        );
    }

    pub inline fn format(self: Duration, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    comptime {
        core.testing.expectSize(Duration, .of(u64));
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
