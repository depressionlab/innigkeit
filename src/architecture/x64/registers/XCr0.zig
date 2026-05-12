const std = @import("std");
const core = @import("core");

pub const XCr0 = packed struct(u64) {
    /// x87 FPU state
    ///
    /// Must always be `true`
    x87: bool,

    /// 128-bit SSE state
    sse: bool,

    /// 256-bit SSE (AVX) state
    ///
    /// If `true` then `sse` must be `true`
    avx: bool,

    /// Intel Only
    mpx: MPX,

    avx512: AVX512,

    /// Intel Processor Trace
    ///
    /// Intel Only
    pt: bool,

    pkru: bool,

    _reserved0: u7,

    /// Intel Only
    amx: AMX,

    _reserved1: u43,

    /// Lightweight Profiling
    ///
    /// AMD Only
    lwp: bool,

    _reserved2: u1,

    pub const MPX = enum(u2) {
        false = 0b00,
        true = 0b11,
    };

    pub const AVX512 = enum(u3) {
        false = 0b000,
        true = 0b111,
    };

    pub const AMX = enum(u2) {
        false = 0b00,
        true = 0b11,
    };

    pub fn read() XCr0 {
        var lo: u32 = undefined;
        var hi: u32 = undefined;

        asm ("xgetbv"
            : [hi] "={edx}" (hi),
              [lo] "={eax}" (lo),
            : [_] "{ecx}" (0),
        );

        return @bitCast(
            @as(u64, hi) << 32 |
                @as(u64, lo),
        );
    }

    pub fn write(self: XCr0) void {
        const raw: u64 = @bitCast(self);

        asm volatile ("xsetbv"
            :
            : [_] "{ecx}" (0),
              [hi] "{edx}" (@as(u32, @truncate(raw >> 32))),
              [lo] "{eax}" (@as(u32, @truncate(raw))),
        );
    }

    pub fn format(self: XCr0, writer: *std.Io.Writer) !void {
        try writer.writeAll(if (self.x87) "XCr0{ x87: true, " else "XCr0{ x87: false, ");
        try writer.writeAll(if (self.sse) "sse: true, " else "sse: false, ");
        try writer.writeAll(if (self.avx) "avx: true, " else "avx: false, ");
        try writer.writeAll(if (self.mpx == .true) "mpx: true, " else "mpx: false, ");
        try writer.writeAll(if (self.avx512 == .true) "avx512: true, " else "avx512: false, ");
        try writer.writeAll(if (self.pt) "pt: true, " else "pt: false, ");
        try writer.writeAll(if (self.pkru) "pkru: true, " else "pkru: false, ");
        try writer.writeAll(if (self.amx == .true) "amx: true, " else "amx: false, ");
        try writer.writeAll(if (self.lwp) "lwp: true }" else "lwp: false }");
    }

    comptime {
        core.testing.expectSize(XCr0, .of(u64));
    }
};
