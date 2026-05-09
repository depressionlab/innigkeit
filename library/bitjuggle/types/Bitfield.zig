const std = @import("std");
const builtin = @import("builtin");

/// Defines a bitfield.
pub fn Bitfield(
    /// The type of the underlying integer containing the bitfield.
    comptime FieldType: type,
    /// The starting bit index of the bitfield.
    comptime shift_amount: usize,
    /// The number of bits in the bitfield.
    comptime num_bits: usize,
) type {
    if (shift_amount + num_bits > @bitSizeOf(FieldType))
        @compileError("bitfield doesn't fit!");

    const mask: FieldType = ((1 << num_bits) - 1) << shift_amount;
    const ValueType: type = std.meta.Int(.unsigned, num_bits);

    return extern struct {
        dummy: FieldType,

        const BitfieldT = @This();

        pub fn write(self: *BitfieldT, value: ValueType) void {
            const field_value: FieldType = value;
            self.writeNoShiftFullSize(field_value << shift_amount);
        }

        /// Writes a value to the bitfield without shifting.
        ///
        /// Non-atomic; all bits in `value` not in the bitfield are ignored.
        pub fn writeNoShiftFullSize(self: *BitfieldT, value: FieldType) void {
            self.field().* = (self.field().* & ~mask) | (value & mask);
        }

        pub fn read(self: BitfieldT) ValueType {
            return @truncate(self.readNoShiftFullSize() >> shift_amount);
        }

        /// Reads the full value of the bitfield without shifting and without
        /// truncating the type. All bits not in the bitfield will be zero.
        pub inline fn readNoShiftFullSize(self: BitfieldT) FieldType {
            return (self.field().* & mask);
        }

        /// A function to access the underlying integer as `FieldType`.
        /// Uses `anytype` to support both const and non-const access.
        pub inline fn field(self: anytype) PointerCastPreserveCV(BitfieldT, @TypeOf(self), FieldType) {
            return @ptrCast(self);
        }
    };
}

test Bitfield {
    const S = extern union {
        low: Bitfield(u32, 0, 16),
        high: Bitfield(u32, 16, 16),
        value: u32,
    };

    try std.testing.expect(@sizeOf(S) == 4);
    try std.testing.expect(@bitSizeOf(S) == 32);

    var s: S = .{ .value = 0x13318989 };

    try std.testing.expect(s.low.read() == 0x8989);
    try std.testing.expect(s.high.read() == 0x1331);

    s.low.write(0x1331);
    s.high.write(0x8989);

    try std.testing.expect(s.value == 0x89891331);
}

/// Casts a pointer while preserving `const` or `volatile` qualifiers.
inline fn PointerCastPreserveCV(comptime T: type, comptime PointerToT: type, comptime NewT: type) type {
    return switch (PointerToT) {
        *T => *NewT,
        *const T => *const NewT,
        *volatile T => *volatile NewT,
        *const volatile T => *const volatile NewT,
        else => @compileError("invalid type " ++ @typeName(PointerToT) ++ " given to PointerCastPreserveCV!"),
    };
}

comptime {
    if (builtin.cpu.arch.endian() != .little)
        @compileError("'bitjuggle' assumes little endian!");
}

comptime {
    std.testing.refAllDecls(@This());
}
