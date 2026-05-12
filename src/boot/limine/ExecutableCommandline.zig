//! Executable Command Line Feature

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x4b161536e598651e, 0xb390ad4a2f1f303a),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// String containing the command line associated with the booted executable.
    ///
    /// This is equivalent to the `string` member of the `executable_file` structure of the Executable File feature.
    _cmdline: ?[*:0]const u8,

    /// String containing the command line associated with the booted executable.
    ///
    /// This is a pointer to the same memory as the `string` member of the `executable_file` structure of the Executable File feature.
    pub fn cmdline(self: *const Response) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            self._cmdline orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn format(self: *const Response, writer: *std.Io.Writer) !void {
        if (self.cmdline()) |c| {
            try writer.print("ExecutableCommandLine(\"{s}\")", .{c});
        } else {
            try writer.writeAll("ExecutableCommandLine(null)");
        }
    }
};
