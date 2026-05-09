const builtin = @import("builtin");
const std = @import("std");

const Endian = std.builtin.Endian;
const native_endian: Endian = builtin.cpu.arch.endian();

/// Converts an integer which has host endianness to the desired endianness.
///
/// Copied from `std.mem`, changed to be inline and `desired_endianness` has been marked as comptime.
pub inline fn nativeTo(comptime T: type, x: T, comptime desired_endianness: std.builtin.Endian) T {
    return switch (desired_endianness) {
        .Little => nativeToLittle(T, x),
        .Big => nativeToBig(T, x),
    };
}

/// Converts an integer which has host endianness to little endian.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn nativeToLittle(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(x),
    };
}

/// Converts an integer which has host endianness to big endian.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn nativeToBig(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(x),
        .Big => x,
    };
}

/// Converts an integer from specified endianness to host endianness.
///
/// Copied from `std.mem`, changed to be inline and `desired_endianness` has been marked as comptime.
pub inline fn toNative(comptime T: type, x: T, comptime endianness_of_x: std.builtin.Endian) T {
    return switch (endianness_of_x) {
        .Little => littleToNative(T, x),
        .Big => bigToNative(T, x),
    };
}

/// Converts a little-endian integer to host endianness.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn littleToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(x),
    };
}

/// Converts a big-endian integer to host endianness.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn bigToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(x),
        .Big => x,
    };
}

comptime {
    std.testing.refAllDecls(@This());
}
