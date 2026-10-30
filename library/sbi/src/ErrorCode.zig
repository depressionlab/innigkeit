const std = @import("std");

const ErrorCode = enum(isize) {
    Success = 0,
    Failed = -1,
    NotSupported = -2,
    InvalidParameter = -3,
    Denied = -4,
    InvalidAddress = -5,
    AlreadyAvailable = -6,
    AlreadyStarted = -7,
    AlreadyStopped = -8,
    NoSharedMemory = -9,
    InvalidState = -10,
    BadRange = -11,
    Timeout = -12,
    IO = -13,

    inline fn toError(self: ErrorCode, comptime ErrorT: type) ErrorT {
        const names = @typeInfo(ErrorT).error_set.error_names.?;
        inline for (names) |name| {
            if (comptime std.mem.eql(u8, name, "Success")) {
                @compileError("Success is not an error");
            }

            if (self == @field(ErrorCode, name)) return @field(ErrorT, name);
        }
        unreachable;
    }
};
