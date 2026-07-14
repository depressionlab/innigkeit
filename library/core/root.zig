const builtin = @import("builtin");
const std = @import("std");

pub const containers = @import("containers/root.zig");
pub const endian_ = @import("endian.zig");
pub const hash = @import("hash.zig");
pub const lock = @import("lock.zig");
pub const masking = @import("masking.zig");
pub const simd = @import("simd.zig");
pub const testing = @import("testing.zig");
pub const Duration = @import("duration.zig").Duration;
pub const Size = @import("size.zig").Size;
pub const TypeErasedCall = @import("containers/TypeErasedCall.zig").TypeErasedCall;
pub const RedBlackTree = @import("containers/RedBlackTree.zig");

const Endian = std.builtin.Endian;
pub const is_debug = builtin.mode == .Debug;

/// A calling convention that is `inline` in non-debug builds and `auto` in debug builds.
///
/// This allows the effect of inlining for release builds but prevents missing
/// debug information during debug builds.
pub const inline_in_non_debug: std.builtin.CallingConvention =
    if (is_debug) .auto else .@"inline";

pub inline fn require(value: anytype, comptime message: []const u8) @TypeOf(value catch unreachable) {
    return value catch |err| {
        std.debug.panic(comptime message ++ ": {t}!", .{err});
    };
}

pub const Direction = enum { forward, backward };
pub const LockState = enum { locked, unlocked };
pub const LockType = enum { read, write };
pub const CleanupDecision = enum { keep, free };

/// Reads up to `sizeOf(T)` bytes of `input` as a `T`, zero-extending any
/// missing high-order bytes, as if `input` were a short/truncated encoding
/// of the full-width value. Where the "missing" bytes land in `buffer`
/// depends on `endian`: for `.little` they're the trailing bytes (already
/// zero); for `.big` the real bytes must be right-aligned instead, or they'd
/// land in the high-order position instead of the low-order one.
pub inline fn readIntPartial(comptime T: type, input: []const u8, endian: Endian) u64 {
    const len: usize = @min(@sizeOf(T), input.len);
    var buffer = [_]u8{0} ** @sizeOf(T);
    switch (endian) {
        .little => @memcpy(buffer[0..len], input[0..len]),
        .big => @memcpy(buffer[@sizeOf(T) - len ..], input[0..len]),
    }
    return std.mem.readInt(T, &buffer, endian);
}

pub inline fn CopyPtrAttrs(comptime source: type, comptime size: std.builtin.Type.Pointer.Size, comptime child: type) type {
    switch (@typeInfo(source)) {
        .optional => |o| return CopyPtrAttrs(o.child, size, child),
        .pointer => |info| return @Pointer(size, info, child, null),
        else => @compileError("invalid source for CopyPtrAttrs!"),
    }
}

test readIntPartial {
    const hello = "hello";
    const hello_zero_padded: [8]u8 = hello.* ++ .{0} ** 3;
    const expected: u64 = @bitCast(hello_zero_padded);

    const endian = builtin.cpu.arch.endian();
    const hello_int = readIntPartial(u64, hello, endian);
    try std.testing.expectEqual(expected, hello_int);
}

test "readIntPartial zero-extends the low-order bytes for both endiannesses" {
    const input = [_]u8{ 0x01, 0x02 };
    try std.testing.expectEqual(@as(u64, 0x0102), readIntPartial(u32, &input, .big));
    try std.testing.expectEqual(@as(u64, 0x0201), readIntPartial(u32, &input, .little));
}

// test trees {
//     inline for ([2]trees.Kind{ .red_black, .avl }) |kind| {
//         const Map = trees.Map(usize, []const u8, null, kind, false);

//         var map = Map.init(std.testing.allocator);
//         defer map.deinit();

//         try map.put(0, "0");
//         try std.testing.expect(map.contains(0));
//         try std.testing.expectEqualSlices(u8, map.get(0).?, "0");

//         var iter = map.iterator(std.testing.allocator);
//         while (try iter.next()) |kv| {
//             // we only put 0 -> "0" in the `map`, so that's all we expect
//             try std.testing.expectEqual(kv.key, 0);
//             try std.testing.expectEqualSlices(u8, kv.value, "0");
//         }
//     }
// }

comptime {
    std.testing.refAllDecls(@This());
}
