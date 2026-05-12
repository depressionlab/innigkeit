const std = @import("std");
const syscall = @import("syscall.zig");

/// Standard file descriptors.
///
/// Stored as `usize` so it can be passed directly to `Syscall.call3` without casting.
pub const Fd = enum(usize) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
};

/// A write-only handle over a file descriptor.
pub const Writer = struct {
    fd: Fd,

    /// Write all bytes in `bytes` to the file descriptor.
    ///
    /// Loops on partial writes, which the kernel may return when the output
    /// buffer is temporarily full.
    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const result = syscall.Syscall.call3(
                .write,
                @intFromEnum(self.fd),
                @intFromPtr(remaining.ptr),
                remaining.len,
            );
            const written = try syscall.Syscall.decode(result);
            if (written == 0) return error.WriteFailed;
            remaining = remaining[written..];
        }
    }

    /// Format `args` with `fmt` and write the result to the file descriptor.
    ///
    /// The formatted output is limited to 4096 bytes. For larger output, write
    /// in chunks or construct the string yourself with an allocating formatter.
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
};

/// A read-only handle over a file descriptor.
pub const Reader = struct {
    fd: Fd,

    /// Read up to `buffer.len` bytes and return the number of bytes read.
    ///
    /// A return of 0 means EOF or the input source has no more data.
    pub fn readAll(self: @This(), buffer: []u8) !usize {
        const result = syscall.Syscall.call3(
            .read,
            @intFromEnum(self.fd),
            @intFromPtr(buffer.ptr),
            buffer.len,
        );
        return syscall.Syscall.decode(result);
    }

    /// Read a line into `buffer`, stripping the trailing newline if present.
    ///
    /// Returns a slice into `buffer` containing the line content.
    pub fn readLine(self: @This(), buffer: []u8) ![]u8 {
        const n = try self.readAll(buffer);
        const line = buffer[0..n];
        if (n > 0 and line[n - 1] == '\n') return line[0 .. n - 1];
        return line;
    }
};

pub const stdin = Reader{ .fd = .stdin };
pub const stdout = Writer{ .fd = .stdout };
pub const stderr = Writer{ .fd = .stderr };
