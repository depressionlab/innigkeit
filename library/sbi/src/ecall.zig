const base = @import("base.zig");
const ErrorCode = @import("ErrorCode.zig").ErrorCode;
const is_64 = @import("root.zig").is_64;

pub inline fn zeroArgsNoReturnWithError(eid: base.EID, fid: i32, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
        : .{ .x11 = true });

    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn zeroArgsWithReturnWithError(eid: base.EID, fid: i32, comptime ErrorT: type) ErrorT!isize {
    var err: ErrorCode = undefined;
    var value: isize = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
          [value] "={x11}" (value),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
    );
    if (err == .Success) {
        @branchHint(.likely);
        return value;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn zeroArgsWithReturnNoError(eid: base.EID, fid: i32) isize {
    return asm volatile ("ecall"
        : [value] "={x11}" (-> isize),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
        : .{ .x10 = true });
}

pub inline fn oneArgsNoReturnWithError(eid: base.EID, fid: i32, x10: isize, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
        : .{ .x11 = true });
    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn oneArgsWithReturnWithError(eid: base.EID, fid: i32, x10: isize, comptime ErrorT: type) ErrorT!isize {
    var err: ErrorCode = undefined;
    var value: isize = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
          [value] "={x11}" (value),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
    );
    if (err == .Success) {
        @branchHint(.likely);
        return value;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn oneArgsWithReturnNoError(eid: base.EID, fid: i32, x10: isize) isize {
    return asm volatile ("ecall"
        : [value] "={x11}" (-> isize),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
        : .{ .x10 = true });
}

pub inline fn oneArgs64NoReturnNoError(eid: base.EID, fid: i32, x10: u64) void {
    if (is_64) {
        asm volatile ("ecall"
            :
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
            : .{ .x11 = true, .x10 = true });
    } else {
        asm volatile ("ecall"
            :
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0_lo] "{x10}" (@as(u32, @truncate(x10))),
              [arg0_hi] "{x11}" (@as(u32, @truncate(x10 >> 32))),
            : .{ .x11 = true, .x10 = true });
    }
}

pub inline fn oneArgs64NoReturnWithError(eid: base.EID, fid: i32, x10: u64, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    if (is_64) {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
            : .{ .x11 = true });
    } else {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0_lo] "{x10}" (@as(u32, @truncate(x10))),
              [arg0_hi] "{x11}" (@as(u32, @truncate(x10 >> 32))),
            : .{ .x11 = true });
    }

    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn twoArgsNoReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: isize, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
        : .{ .x11 = true });
    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn twoArgsLastArg64NoReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: u64, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;

    if (is_64) {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1] "{x11}" (x11),
            : .{ .x11 = true });
    } else {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1_lo] "{x11}" (@as(u32, @truncate(x11))),
              [arg1_hi] "{x12}" (@as(u32, @truncate(x11 >> 32))),
            : .{ .x11 = true });
    }

    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn fourArgsLastArg64NoReturnWithError(
    eid: base.EID,
    fid: i32,
    x10: isize,
    x11: isize,
    x12: isize,
    x13: u64,
    comptime ErrorT: type,
) ErrorT!void {
    var err: ErrorCode = undefined;

    if (is_64) {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1] "{x11}" (x11),
              [arg2] "{x12}" (x12),
              [arg3] "{x13}" (x13),
            : .{ .x11 = true });
    } else {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1] "{x11}" (x11),
              [arg2] "{x12}" (x12),
              [arg3_lo] "{x13}" (@as(u32, @truncate(x13))),
              [arg3_hi] "{x14}" (@as(u32, @truncate(x13 >> 32))),
            : .{ .x11 = true });
    }

    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn fourArgsNoReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: isize, x12: isize, x13: isize, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
          [arg3] "{x13}" (x13),
        : .{ .x11 = true });
    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn fiveArgsLastArg64WithReturnWithError(
    eid: base.EID,
    fid: i32,
    x10: isize,
    x11: isize,
    x12: isize,
    x13: isize,
    x14: u64,
    comptime ErrorT: type,
) ErrorT!isize {
    var err: ErrorCode = undefined;
    var value: isize = undefined;

    if (is_64) {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
              [value] "={x11}" (value),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1] "{x11}" (x11),
              [arg2] "{x12}" (x12),
              [arg3] "{x13}" (x13),
              [arg4] "{x14}" (x14),
        );
    } else {
        asm volatile ("ecall"
            : [err] "={x10}" (err),
              [value] "={x11}" (value),
            : [eid] "{x17}" (@backingInt(eid)),
              [fid] "{x16}" (fid),
              [arg0] "{x10}" (x10),
              [arg1] "{x11}" (x11),
              [arg2] "{x12}" (x12),
              [arg3] "{x13}" (x13),
              [arg4_lo] "{x14}" (@as(u32, @truncate(x14))),
              [arg4_hi] "{x15}" (@as(u32, @truncate(x14 >> 32))),
        );
    }

    if (err == .Success) {
        @branchHint(.likely);
        return value;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn fiveArgsNoReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: isize, x12: isize, x13: isize, x14: isize, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
          [arg3] "{x13}" (x13),
          [arg4] "{x14}" (x14),
        : .{ .x11 = true });
    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn threeArgsNoReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: isize, x12: isize, comptime ErrorT: type) ErrorT!void {
    var err: ErrorCode = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
        : .{ .x11 = true });
    if (err == .Success) {
        @branchHint(.likely);
        return;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn threeArgsWithReturnWithError(eid: base.EID, fid: i32, x10: isize, x11: isize, x12: isize, comptime ErrorT: type) ErrorT!isize {
    var err: ErrorCode = undefined;
    var value: isize = undefined;
    asm volatile ("ecall"
        : [err] "={x10}" (err),
          [value] "={x11}" (value),
        : [eid] "{x17}" (@backingInt(eid)),
          [fid] "{x16}" (fid),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
    );
    if (err == .Success) {
        @branchHint(.likely);
        return value;
    }
    return ErrorCode.toError(err, ErrorT);
}

pub inline fn legacyZeroArgsNoReturn(eid: base.EID) void {
    asm volatile ("ecall"
        :
        : [eid] "{x17}" (@backingInt(eid)),
        : .{ .x10 = true });
}

pub inline fn legacyZeroArgsWithReturn(eid: base.EID) isize {
    var val: isize = undefined;

    asm volatile ("ecall"
        : [val] "={x10}" (val),
        : [eid] "{x17}" (@backingInt(eid)),
    );

    return val;
}

pub inline fn legacyOneArgsWithReturn(eid: base.EID, x10: isize) isize {
    var val: isize = undefined;

    asm volatile ("ecall"
        : [val] "={x10}" (val),
        : [eid] "{x17}" (@backingInt(eid)),
          [arg0] "{x10}" (x10),
    );

    return val;
}

pub inline fn legacyOneArgs64WithReturn(eid: base.EID, x10: u64) isize {
    var val: isize = undefined;

    if (is_64) {
        asm volatile ("ecall"
            : [val] "={x10}" (val),
            : [eid] "{x17}" (@backingInt(eid)),
              [arg0] "{x10}" (x10),
        );
    } else {
        asm volatile ("ecall"
            : [val] "={x10}" (val),
            : [eid] "{x17}" (@backingInt(eid)),
              [arg0_lo] "{x10}" (@as(u32, @truncate(x10))),
              [arg0_hi] "{x11}" (@as(u32, @truncate(x10 >> 32))),
        );
    }

    return val;
}

pub inline fn legacyThreeArgsWithReturn(eid: base.EID, x10: isize, x11: isize, x12: isize) isize {
    var val: isize = undefined;

    asm volatile ("ecall"
        : [val] "={x10}" (val),
        : [eid] "{x17}" (@backingInt(eid)),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
    );

    return val;
}

pub inline fn legacyFourArgsWithReturn(eid: base.EID, x10: isize, x11: isize, x12: isize, x13: isize) isize {
    var val: isize = undefined;

    asm volatile ("ecall"
        : [val] "={x10}" (val),
        : [eid] "{x17}" (@backingInt(eid)),
          [arg0] "{x10}" (x10),
          [arg1] "{x11}" (x11),
          [arg2] "{x12}" (x12),
          [arg3] "{x13}" (x13),
    );

    return val;
}
