const std = @import("std");
const Type = std.builtin.Type;

/// Generates a mask to isolate a field of a `packed struct` while keeping it
/// shifted relative to its bit offset in the struct.
///
/// The field's value is effectively left shifted by its bit offset in the
/// struct and bits outside the field are masked out.
pub fn makeTruncationMask(comptime T: type, comptime field: []const u8) @Int(.unsigned, @bitSizeOf(T)) {
    const offset = @bitOffsetOf(T, field);
    const size = @bitSizeOf(@TypeOf(@field(@as(T, undefined), field)));

    const size_mask = (1 << size) - 1;
    return size_mask << offset;
}

test makeTruncationMask {
    const T = packed struct(u16) {
        a: u4,
        b: u3,
        c: u9,
    };

    try std.testing.expectEqual(0x000F, makeTruncationMask(T, "a"));
    try std.testing.expectEqual(0x0070, makeTruncationMask(T, "b"));
    try std.testing.expectEqual(0xFF80, makeTruncationMask(T, "c"));
}
