const Baud = @This();

const core = @import("core");
const std = @import("std");

/// The clock frequency of the UART in Hz.
///
/// Cannot be zero.
clock_frequency: Frequency,

/// The baud rate of the UART in bits per second.
///
/// Cannot be zero.
baud_rate: BaudRate,

pub const BaudRate = enum(u64) {
    @"115200" = 115200,
    @"57600" = 57600,
    @"19200" = 19200,
    @"9600" = 9600,
    _,
};

pub const Frequency = enum(u64) {
    @"1.8432 MHz" = 1843200,
    @"3.6864 MHz" = 3686400,
    @"24 MHz" = 24000000,
    _,
};

pub const DivisorError = error{
    DivisorTooLarge,
};

pub fn integerDivisor(baud: Baud) DivisorError!u16 {
    const baud_rate = @intFromEnum(baud.baud_rate);
    const clock_frequency = @intFromEnum(baud.clock_frequency);

    if (core.is_debug) {
        std.debug.assert(baud_rate != 0);
        std.debug.assert(clock_frequency != 0);
    }

    const divisor = clock_frequency / (baud_rate * 16);
    return std.math.cast(u16, divisor) orelse return error.DivisorTooLarge;
}

pub const Fractional = packed struct(u22) {
    fractional: u6,
    integer: u16,
};

pub fn fractionalDivisor(baud: Baud) DivisorError!Fractional {
    const baud_rate = @intFromEnum(baud.baud_rate);
    const clock_frequency = @intFromEnum(baud.clock_frequency);

    if (core.is_debug) {
        std.debug.assert(baud_rate != 0);
        std.debug.assert(clock_frequency != 0);
    }

    const divisor = (64 * clock_frequency) / (baud_rate * 16);
    return @bitCast(std.math.cast(u22, divisor) orelse return error.DivisorTooLarge);
}
