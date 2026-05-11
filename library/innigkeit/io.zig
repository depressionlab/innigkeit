const std = @import("std");
const innigkeit = @import("innigkeit");

pub const Writer = struct {
    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        _ = self;
        const result = innigkeit.Syscall.call2(
            .write,
            @intFromPtr(bytes.ptr),
            bytes.len,
        );
        if (result < 0) return error.WriteFailed;
    }

    pub fn writeInt(self: @This(), value: i64) !void {
        var buffer: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try self.writeAll(str);
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        var buffer: [256]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, fmt, args);
        try self.writeAll(str);
    }
};

pub const Reader = struct {
    pub fn readAll(self: @This(), buffer: []u8) !usize {
        _ = self;
        const result = innigkeit.Syscall.call2(
            .read,
            @intFromPtr(buffer.ptr),
            buffer.len,
        );
        if (result < 0) return error.ReadFailed;
        return @intCast(result);
    }

    pub fn readLine(self: @This(), buffer: []u8) ![]u8 {
        const bytes_read = try self.readAll(buffer);
        // Remove trailing newline if present
        if (bytes_read > 0 and buffer[bytes_read - 1] == '\n') {
            return buffer[0 .. bytes_read - 1];
        }
        return buffer[0..bytes_read];
    }
};

pub const stdout = Writer{};
pub const stdin = Reader{};
