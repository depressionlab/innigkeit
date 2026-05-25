//! Zig implementations of C stdlib functions used by doomgeneric.
//! Exported with C calling convention so they link directly with the C sources.
//! Replaces the equivalent definitions in innigkeit_libc.c.
const std = @import("std");

pub export fn snprintf(s: [*c]u8, n: c_ulong, format: [*c]const u8, ...) callconv(.c) c_int {
    var args: std.builtin.VaList = @cVaStart();
    defer @cVaEnd(&args);
    return vsnprintf(s, n, format, &args);
}

export fn vsnprintf(s: [*c]u8, n: c_ulong, format: [*c]const u8, args: *std.builtin.VaList) callconv(.c) c_int {
    if (n == 0) return 0;
    var w: Writer = .{ .buf = s, .cap = n - 1, .len = 0 };
    formatV(&w, format, args);
    s[if (w.len < n) w.len else n - 1] = 0;
    return @intCast(w.len);
}

export fn strncmp(lhs: [*c]const u8, rhs: [*c]const u8, num: c_ulong) callconv(.c) c_int {
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const l = lhs[i];
        const r = rhs[i];
        if (l == 0 and r == 0) return 0;
        if (l != r or l == 0 or r == 0) return @as(c_int, l) - @as(c_int, r);
    }
    return 0;
}

export fn strcmp(lhs: [*c]const u8, rhs: [*c]const u8) callconv(.c) c_int {
    return strncmp(lhs, rhs, std.math.maxInt(c_ulong));
}

export fn strncasecmp(lhs: [*c]const u8, rhs: [*c]const u8, num: c_ulong) callconv(.c) c_int {
    for (0..num) |n| {
        const l = std.ascii.toLower(lhs[n]);
        const r = std.ascii.toLower(rhs[n]);

        if (l == 0 and r == 0) break;
        if (l != r or l == 0 or r == 0) {
            return @as(c_int, l) - @as(c_int, r);
        }
    }

    return 0;
}

export fn strcasecmp(lhs: [*c]const u8, rhs: [*c]const u8) callconv(.c) c_int {
    return strncasecmp(lhs, rhs, std.math.maxInt(c_ulong));
}

const Writer = extern struct {
    buf: [*c]u8,
    cap: usize, // usable bytes (buf[0..cap]); buf[cap] is the NUL slot
    len: usize, // total chars formatted (may exceed cap, used for return value)

    fn putByte(self: *Writer, c: u8) void {
        if (self.len < self.cap) self.buf[self.len] = c;
        self.len += 1;
    }

    fn putStr(self: *Writer, s: []const u8) void {
        for (s) |c| self.putByte(c);
    }
};

fn formatV(w: *Writer, fmt_ptr: [*c]const u8, args: *std.builtin.VaList) callconv(.c) void {
    var i: usize = 0;
    while (fmt_ptr[i] != 0) {
        if (fmt_ptr[i] != '%') {
            w.putByte(fmt_ptr[i]);
            i += 1;
            continue;
        }
        i += 1; // skip '%'

        // flags
        var left: bool = false;
        var zero: bool = false;
        flags: while (true) switch (fmt_ptr[i]) {
            '-' => {
                left = true;
                i += 1;
            },
            '0' => {
                zero = true;
                i += 1;
            },
            '+', ' ', '#' => i += 1,
            else => break :flags,
        };

        // width
        var width: usize = 0;
        while (fmt_ptr[i] >= '0' and fmt_ptr[i] <= '9') {
            width = width * 10 + (fmt_ptr[i] - '0');
            i += 1;
        }
        if (fmt_ptr[i] == '*') {
            const wv = @cVaArg(args, c_int);
            if (wv < 0) {
                left = true;
                width = @intCast(-wv);
            } else width = @intCast(wv);
            i += 1;
        }

        // precision
        var prec: ?usize = null;
        if (fmt_ptr[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (fmt_ptr[i] >= '0' and fmt_ptr[i] <= '9') {
                p = p * 10 + (fmt_ptr[i] - '0');
                i += 1;
            }
            if (fmt_ptr[i] == '*') {
                const pv = @cVaArg(args, c_int);
                if (pv >= 0) prec = @intCast(pv);
                i += 1;
            } else {
                prec = p;
            }
        }

        // length modifier
        var longness: u2 = 0;
        switch (fmt_ptr[i]) {
            'l' => {
                longness = 1;
                i += 1;
                if (fmt_ptr[i] == 'l') {
                    longness = 2;
                    i += 1;
                }
            },
            'h' => {
                i += 1;
                if (fmt_ptr[i] == 'h') i += 1;
            },
            'z', 'j', 't' => {
                longness = 1;
                i += 1;
            },
            else => {},
        }

        // conversion specifier
        switch (fmt_ptr[i]) {
            'd', 'i' => {
                const v: i64 = switch (longness) {
                    2 => @cVaArg(args, c_longlong),
                    1 => @cVaArg(args, c_long),
                    else => @cVaArg(args, c_int),
                };
                const abs_v: u64 = if (v < 0) @bitCast(-v) else @intCast(v);
                fmtUint(w, abs_v, 10, false, v < 0, width, prec, zero, left);
            },
            'u' => {
                const v: u64 = switch (longness) {
                    2 => @cVaArg(args, c_ulonglong),
                    1 => @cVaArg(args, c_ulong),
                    else => @cVaArg(args, c_uint),
                };
                fmtUint(w, v, 10, false, false, width, prec, zero, left);
            },
            'x' => {
                const v: u64 = switch (longness) {
                    2 => @cVaArg(args, c_ulonglong),
                    1 => @cVaArg(args, c_ulong),
                    else => @cVaArg(args, c_uint),
                };
                fmtUint(w, v, 16, false, false, width, prec, zero, left);
            },
            'X' => {
                const v: u64 = switch (longness) {
                    2 => @cVaArg(args, c_ulonglong),
                    1 => @cVaArg(args, c_ulong),
                    else => @cVaArg(args, c_uint),
                };
                fmtUint(w, v, 16, true, false, width, prec, zero, left);
            },
            'o' => {
                const v: u64 = switch (longness) {
                    2 => @cVaArg(args, c_ulonglong),
                    1 => @cVaArg(args, c_ulong),
                    else => @cVaArg(args, c_uint),
                };
                fmtUint(w, v, 8, false, false, width, prec, zero, left);
            },
            'p' => {
                const v = @intFromPtr(@cVaArg(args, ?*anyopaque));
                w.putByte('0');
                w.putByte('x');
                fmtUint(w, v, 16, false, false, 0, 1, false, false);
            },
            's' => {
                const sp = @cVaArg(args, [*c]const u8);
                const full: []const u8 = if (sp != null) std.mem.span(sp) else "(null)";
                const s: []const u8 = if (prec) |pr| full[0..@min(pr, full.len)] else full;
                fmtStr(w, s, width, left);
            },
            'c' => {
                const c: u8 = @truncate(@as(u32, @intCast(@cVaArg(args, c_int))));
                fmtStr(w, &[_]u8{c}, width, left);
            },
            '%' => w.putByte('%'),
            else => {},
        }
        i += 1;
    }
}

fn fmtStr(w: *Writer, s: []const u8, width: usize, left: bool) void {
    if (!left) {
        var j = s.len;
        while (j < width) : (j += 1) w.putByte(' ');
    }
    w.putStr(s);
    if (left) {
        var j = s.len;
        while (j < width) : (j += 1) w.putByte(' ');
    }
}

fn fmtUint(
    w: *Writer,
    v: u64,
    base: u8,
    upper: bool,
    negative: bool,
    width: usize,
    prec: ?usize,
    zero_pad: bool,
    left: bool,
) void {
    // Generate digits into tmp[] in LSB-first (reverse) order.
    var tmp: [64]u8 = undefined;
    var n: usize = 0;

    if (v == 0) {
        // precision=0 with value=0 -> print nothing (C99 §7.19.6.1 p8)
        if (prec == null or prec.? != 0) {
            tmp[0] = '0';
            n = 1;
        }
    } else {
        var val = v;
        while (val != 0) : (val /= base) {
            const d: u8 = @intCast(val % base);
            tmp[n] = if (d < 10) '0' + d else (if (upper) @as(u8, 'A') else 'a') + d - 10;
            n += 1;
        }
    }

    // Precision = minimum digit count; zero-pad the digit string itself.
    const min_d: usize = prec orelse 0;
    while (n < min_d) {
        tmp[n] = '0';
        n += 1;
    }

    // When precision is specified, the zero-fill flag is ignored (C standard).
    const do_zero_pad = zero_pad and prec == null;

    const sign_w: usize = @intFromBool(negative);
    const content_w = n + sign_w;
    const pad_n = if (width > content_w) width - content_w else 0;

    if (!left) {
        if (do_zero_pad) {
            // Sign comes before the zero fill: "-0042"
            if (negative) w.putByte('-');
            var j: usize = 0;
            while (j < pad_n) : (j += 1) w.putByte('0');
        } else {
            var j: usize = 0;
            while (j < pad_n) : (j += 1) w.putByte(' ');
            if (negative) w.putByte('-');
        }
    } else {
        if (negative) w.putByte('-');
    }

    // Digits are in tmp[0..n] LSB-first; emit them in reverse (MSB first).
    var k = n;
    while (k > 0) {
        k -= 1;
        w.putByte(tmp[k]);
    }

    if (left) {
        var j: usize = 0;
        while (j < pad_n) : (j += 1) w.putByte(' ');
    }
}
