const builtin = @import("builtin");
const core = @import("core");
const std = @import("std");

pub const Bitfield = @import("types/Bitfield.zig").Bitfield;
pub const Bit = @import("types/root.zig").Bit;
pub const Boolean = @import("types/root.zig").Boolean;

/// Returns `true` if the the bit at index `bit` is set (equals 1).
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// const a: u8 = 0b00000010;
///
/// try std.testing.expect(!isBitSet(a, 0));
/// try std.testing.expect(isBitSet(a, 1));
/// ```
pub inline fn isBitSet(target: anytype, comptime bit: comptime_int) bool {
    const TargetType = @TypeOf(target);

    comptime {
        if (@typeInfo(TargetType) == .int) {
            if (@typeInfo(TargetType).int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
            }
            if (bit >= @bitSizeOf(TargetType)) {
                @compileError("bit index is out of bounds of the bit field!");
            }
        } else if (@typeInfo(TargetType) == .comptime_int) {
            if (target < 0) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
            }
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
        }
    }

    const mask: TargetType = comptime blk: {
        const MaskType = @Int(.unsigned, bit + 1);
        var temp: MaskType = std.math.maxInt(MaskType);
        temp <<= bit;
        break :blk temp;
    };

    return (target & mask) != 0;
}

test isBitSet {
    // comptime
    comptime {
        const a: comptime_int = 0b00000000;
        try std.testing.expect(!isBitSet(a, 0));
        try std.testing.expect(!isBitSet(a, 1));

        const b: comptime_int = 0b11111111;
        try std.testing.expect(isBitSet(b, 0));
        try std.testing.expect(isBitSet(b, 1));

        const c: comptime_int = 0b00000010;
        try std.testing.expect(!isBitSet(c, 0));
        try std.testing.expect(isBitSet(c, 1));
    }

    // runtime
    {
        var value: u8 = 0b00000000;
        try std.testing.expect(!isBitSet(value, 0));
        try std.testing.expect(!isBitSet(value, 1));

        value = 0b11111111;
        try std.testing.expect(isBitSet(value, 0));
        try std.testing.expect(isBitSet(value, 1));

        value = 0b00000010;
        try std.testing.expect(!isBitSet(value, 0));
        try std.testing.expect(isBitSet(value, 1));
    }
}

/// Get the value of the bit at index `bit`.
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// const a: u8 = 0b00000010;
///
/// try std.testing.expect(getBit(a, 0) == 0);
/// try std.testing.expect(getBit(a, 1) == 1);
/// ```
pub inline fn getBit(target: anytype, comptime bit: comptime_int) u1 {
    return @intFromBool(isBitSet(target, bit));
}

test getBit {
    // comptime
    comptime {
        const a: comptime_int = 0b00000000;
        try core.testing.expectEqual(getBit(a, 0), 0);
        try core.testing.expectEqual(getBit(a, 1), 0);

        const b: comptime_int = 0b11111111;
        try core.testing.expectEqual(getBit(b, 0), 1);
        try core.testing.expectEqual(getBit(b, 1), 1);

        const c: comptime_int = 0b00000010;
        try core.testing.expectEqual(getBit(c, 0), 0);
        try core.testing.expectEqual(getBit(c, 1), 1);
    }

    // runtime
    {
        var value: u8 = 0b00000000;
        try core.testing.expectEqual(getBit(value, 0), 0);
        try core.testing.expectEqual(getBit(value, 1), 0);

        value = 0b11111111;
        try core.testing.expectEqual(getBit(value, 0), 1);
        try core.testing.expectEqual(getBit(value, 1), 1);

        value = 0b00000010;
        try core.testing.expectEqual(getBit(value, 0), 0);
        try core.testing.expectEqual(getBit(value, 1), 1);
    }
}

/// Obtains the `number_of_bits` bits starting at `start_bit`.
///
/// Where `start_bit` is the lowest significant bit to fetch.
///
/// ```zig
/// const a: u8 = 0b01101100;
/// const b = getBits(a, 2, 4);
/// try std.testing.expectEqual(@as(u4,0b1011), b);
/// ```
pub inline fn getBits(
    target: anytype,
    comptime start_bit: comptime_int,
    comptime number_of_bits: comptime_int,
) @Int(.unsigned, number_of_bits) {
    const TargetType = @TypeOf(target);

    comptime {
        if (number_of_bits == 0) @compileError("non-zero number_of_bits must be provided!");

        if (@typeInfo(TargetType) == .int) {
            if (@typeInfo(TargetType).int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
            }
            if (start_bit >= @bitSizeOf(TargetType)) {
                @compileError("start_bit index is out of bounds of the bit field!");
            }
            if (start_bit + number_of_bits > @bitSizeOf(TargetType)) {
                @compileError("start_bit + number_of_bits is out of bounds of the bit field!");
            }
        } else if (@typeInfo(TargetType) == .comptime_int) {
            if (target < 0) {
                @compileError("requires a positive integer, found a negative!");
            }
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
        }
    }

    return @truncate(target >> start_bit);
}

test getBits {
    // comptime
    comptime {
        const a: comptime_int = 0b01101100;
        const b = getBits(a, 2, 4);
        try core.testing.expectEqual(b, 0b1011);
    }

    // runtime
    {
        var value: u8 = 0b01101100;
        try core.testing.expectEqual(
            getBits(value, 2, 4),
            0b1011,
        );

        value = 0b01101100;
        try core.testing.expectEqual(
            getBits(value, 0, 3),
            0b100,
        );
    }
}

/// Sets the bit at the index `bit` to the value `value`.
///
/// Note: that index 0 is the least significant bit, while index `length() - 1` is the most significant bit.
///
/// ```zig
/// var val: u8 = 0b00000000;
/// try std.testing.expect(getBit(val, 0) == 0);
/// setBit(&val, 0, 1);
/// try std.testing.expect(getBit(val, 0) == 1);
/// ```
pub inline fn setBit(target: anytype, comptime bit: comptime_int, value: u1) void {
    const ptr_type_info: std.builtin.Type = @typeInfo(@TypeOf(target));
    comptime {
        if (ptr_type_info != .pointer) @compileError("not a pointer!");
    }

    const TargetType = ptr_type_info.pointer.child;

    comptime {
        if (@typeInfo(TargetType) == .int) {
            if (@typeInfo(TargetType).int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
            }
            if (bit >= @bitSizeOf(TargetType)) {
                @compileError("bit index is out of bounds of the bit field!");
            }
        } else if (@typeInfo(TargetType) == .comptime_int) {
            @compileError("comptime_int is unsupported!");
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
        }
    }

    const one: TargetType = 1;
    const mask: TargetType = comptime ~(one << bit);
    const target_value: TargetType = value;

    target.* = (target.* & mask) | (target_value << bit);
}

test setBit {
    var val: u8 = 0b00000000;
    try std.testing.expect(!isBitSet(val, 0));
    setBit(&val, 0, 1);
    try std.testing.expect(isBitSet(val, 0));
    setBit(&val, 0, 0);
    try std.testing.expect(!isBitSet(val, 0));
}

/// Sets the range of bits starting at `start_bit` upto and excluding `start_bit` + `number_of_bits`.
///
/// ```zig
/// var val: u8 = 0b10000000;
/// setBits(&val, 2, 4, 0b00001101);
/// try std.testing.expectEqual(@as(u8, 0b10110100), val);
/// ```
///
/// ## Panic
/// In safe modes this method will panic if the `value` exceeds the bit range of the type of `target`.
pub fn setBits(
    target: anytype,
    comptime start_bit: comptime_int,
    comptime number_of_bits: comptime_int,
    value: anytype,
) void {
    const ptr_type_info: std.builtin.Type = @typeInfo(@TypeOf(target));
    comptime {
        if (ptr_type_info != .pointer) @compileError("not a pointer!");
    }

    const TargetType = ptr_type_info.pointer.child;
    const end_bit = start_bit + number_of_bits;

    comptime {
        if (number_of_bits == 0) @compileError("non-zero number_of_bits must be provided!");

        if (@typeInfo(TargetType) == .int) {
            if (@typeInfo(TargetType).int.signedness != .unsigned) {
                @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
            }
            if (start_bit >= @bitSizeOf(TargetType)) {
                @compileError("start_bit index is out of bounds of the bit field!");
            }
            if (end_bit > @bitSizeOf(TargetType)) {
                @compileError("start_bit + number_of_bits is out of bounds of the bit field!");
            }
        } else if (@typeInfo(TargetType) == .comptime_int) {
            @compileError("comptime_int is unsupported!");
        } else {
            @compileError("requires an unsigned integer, found " ++ @typeName(TargetType) ++ "!");
        }
    }

    const peer_value: TargetType = value;

    // Panic if runtime safety is enabled and value exceeds bit range.
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (getBits(peer_value, 0, (end_bit - start_bit)) != peer_value) {
            @panic("value exceeds bit range!");
        }
    }

    const bitmask: TargetType = comptime blk: {
        const zero: TargetType = 0;
        var bitmask = ~zero;
        bitmask <<= (@bitSizeOf(TargetType) - end_bit);
        bitmask >>= (@bitSizeOf(TargetType) - end_bit);
        bitmask >>= start_bit;
        bitmask <<= start_bit;
        break :blk ~bitmask;
    };

    target.* = (target.* & bitmask) | (peer_value << start_bit);
}

test setBits {
    var val: u8 = 0b10000000;
    setBits(&val, 2, 4, 0b00001101);
    try core.testing.expectEqual(val, 0b10110100);
}

comptime {
    if (builtin.cpu.arch.endian() != .little)
        @compileError("'bitjuggle' assumes little endian!");
}

comptime {
    std.testing.refAllDecls(@This());
}
