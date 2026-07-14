//! Innigkeit userspace I/O: file-descriptor wrappers and std.Io.Writer integration.
//!
//! The simple API (`stdin`, `stdout`, `stderr`) covers the common case.
//! Call `.stdWriter()` on a `Writer` to obtain a `std.Io.Writer` compatible
//! with stdlib formatting functions (std.json.writeStream, etc.).
const innigkeit = @import("innigkeit");
const std = @import("std");

/// Standard file descriptors, encoded as `usize` for direct syscall use.
pub const Fd = enum(usize) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
};

fn rawWrite(fd: Fd, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const result = innigkeit.Syscall.invoke(.write, .{
            @intFromEnum(fd),
            @intFromPtr(remaining.ptr),
            remaining.len,
        });
        const written = try innigkeit.Syscall.decode(result);
        if (written == 0) return error.WriteFailed;
        remaining = remaining[written..];
    }
}

fn rawRead(fd: Fd, buf: []u8) !usize {
    const result = innigkeit.Syscall.invoke(.read, .{
        @intFromEnum(fd),
        @intFromPtr(buf.ptr),
        buf.len,
    });
    return innigkeit.Syscall.decode(result);
}

/// One comptime-specialised vtable per writable fd.
///
/// Each vtable's drain function flushes w.buffer[0..w.end] first (if any),
/// then writes each slice in data[] and repeats the last slice `splat` times.
///
/// We use an unbuffered Writer (buffer = &.{}) so every write goes directly
/// to the syscall. This keeps the implementation simple and safe from IRQ
/// contexts.
fn FdVTable(comptime fd: Fd) std.Io.Writer.VTable {
    return .{
        .drain = &struct {
            fn drain(
                w: *std.Io.Writer,
                data: []const []const u8,
                splat: usize,
            ) std.Io.Writer.Error!usize {
                // Flush anything already buffered (end > 0 only when buffer != &.{}).
                if (w.end > 0) {
                    rawWrite(fd, w.buffer[0..w.end]) catch return error.WriteFailed;
                    w.end = 0;
                }
                // Write all slices except the last.
                const pattern = data[data.len - 1];
                var n: usize = 0;
                for (data[0 .. data.len - 1]) |bytes| {
                    rawWrite(fd, bytes) catch return error.WriteFailed;
                    n += bytes.len;
                }
                // Write the last slice `splat` times.
                for (0..splat) |_| {
                    rawWrite(fd, pattern) catch return error.WriteFailed;
                }
                return n + splat * pattern.len;
            }
        }.drain,
    };
}

pub const stdout_vtable = FdVTable(.stdout);
pub const stderr_vtable = FdVTable(.stderr);

fn vtableFor(fd: Fd) *const std.Io.Writer.VTable {
    return switch (fd) {
        .stdout => &stdout_vtable,
        .stderr => &stderr_vtable,
        .stdin => @compileError("stdin is not a writable fd"),
    };
}

/// A write-only handle over a file descriptor.
pub const Writer = struct {
    fd: Fd,

    /// Write all bytes in `bytes` to the file descriptor.
    ///
    /// Loops on partial writes, which the kernel may return when the output
    /// buffer is temporarily full.
    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try rawWrite(self.fd, bytes);
    }

    /// Format `args` with `fmt` and write the result to the file descriptor.
    ///
    /// The formatted output is limited to 4096 bytes. For larger output, write
    /// in chunks or use `stdWriter().print()` which is unbounded.
    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        var buffer: [4096]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(str);
    }

    /// Write a decimal integer to the file descriptor.
    pub fn writeInt(self: @This(), value: i64) !void {
        var buffer: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try self.writeAll(str);
    }

    /// Return an unbuffered `std.Io.Writer` backed by this file descriptor.
    ///
    /// Use this when passing our output to stdlib functions that accept a
    /// `*std.Io.Writer` (e.g. `std.json.writeStream`, `std.fmt.formatType`).
    pub fn stdWriter(self: @This()) std.Io.Writer {
        return .{
            .vtable = vtableFor(self.fd),
            .buffer = &.{}, // unbuffered: every write goes directly to drain
        };
    }
};

/// A read-only handle over a file descriptor.
pub const Reader = struct {
    fd: Fd,

    /// Read up to `buffer.len` bytes and return the number of bytes read.
    ///
    /// A return of 0 means EOF or the input source has no more data.
    pub fn readAll(self: @This(), buffer: []u8) !usize {
        return rawRead(self.fd, buffer);
    }

    /// Read a canonical line into `buffer`, stripping the trailing newline.
    ///
    /// Blocks until the kernel's line discipline delivers a complete line
    /// (i.e. the user pressed Enter). Returns a slice into `buffer`.
    pub fn readLine(self: @This(), buffer: []u8) ![]u8 {
        const n = try self.readAll(buffer);
        const line = buffer[0..n];
        if (n > 0 and line[n - 1] == '\n') return line[0 .. n - 1];
        return line;
    }
};

pub const stdin: Reader = .{ .fd = .stdin };
pub const stdout: Writer = .{ .fd = .stdout };
pub const stderr: Writer = .{ .fd = .stderr };
