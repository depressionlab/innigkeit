const Bitfield = @import("bitjuggle").Bitfield;
const getBit = @import("bitjuggle").getBit;
const setBit = @import("bitjuggle").setBit;

const std = @import("std");
const builtin = @import("builtin");

/// Defines a struct representing a single bit.
fn BitType(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
    /// The type of the bit value, either `u1` or `bool`.
    comptime ValueType: type,
) type {
    return extern struct {
        bits: Bitfield(FieldType, shift_amount, 1),

        const BitTypeT = @This();

        pub fn read(self: BitTypeT) ValueType {
            return @bitCast(getBit(self.bits.field().*, shift_amount));
        }

        pub fn write(self: *BitTypeT, value: ValueType) void {
            setBit(self.bits.field(), shift_amount, @bitCast(value));
        }
    };
}

/// Defines a struct representing a single bit with a `u1` value.
pub fn Bit(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
) type {
    return BitType(FieldType, shift_amount, u1);
}

test Bit {
    const S = extern union {
        low: Bit(u32, 0),
        high: Bit(u32, 1),
        val: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .val = 1 };

    try std.testing.expect(s.low.read() == 1);
    try std.testing.expect(s.high.read() == 0);

    s.low.write(0);
    s.high.write(1);

    try std.testing.expect(s.val == 2);
}

/// Defines a struct representing a single bit with a boolean value.
pub fn Boolean(
    /// The type of the underlying integer containing the bit.
    comptime FieldType: type,
    /// The bit index of the bit.
    comptime shift_amount: usize,
) type {
    return BitType(FieldType, shift_amount, bool);
}

test Boolean {
    const S = extern union {
        low: Boolean(u32, 0),
        high: Boolean(u32, 1),
        val: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .val = 2 };

    try std.testing.expect(s.low.read() == false);
    try std.testing.expect(s.high.read() == true);

    s.low.write(true);
    s.high.write(false);

    try std.testing.expect(s.val == 1);
}

comptime {
    if (builtin.cpu.arch.endian() != .little)
        @compileError("'bitjuggle' assumes little endian!");
}

comptime {
    std.testing.refAllDecls(@This());
}
