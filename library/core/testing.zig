const core = @import("core");
const std = @import("std");

pub inline fn expectEqual(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

/// Asserts that the size *and* bit size of the given type matches the expected size.
pub inline fn expectSize(comptime T: type, comptime size: core.Size) void {
    const raw_size = @intFromEnum(size);

    if (@sizeOf(T) != raw_size) {
        @compileError(std.fmt.comptimePrint(
            "{s} has size {f} but is expected to have {f}!",
            .{ @typeName(T), core.Size.of(T), size },
        ));
    }

    if (@bitSizeOf(T) != 8 * raw_size) {
        @compileError(std.fmt.comptimePrint(
            "{s} has bit size {} but is expected to have {}!",
            .{ @typeName(T), @bitSizeOf(T), 8 * raw_size },
        ));
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
