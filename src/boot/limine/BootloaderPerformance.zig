//! Data provided by this feature is purely informational.
//!
//! The ACPI Firmware Performance Data Table may have more correct data and should be preferred if it exists.
//!
//! Bootloaders may implement this feature using the FPDT.

const std = @import("std");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x6b50ad9bf36d13ad, 0xdc4c7e88fc759e17),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    /// Time of system reset in microseconds relative to an arbitrary point in the past.
    ///
    /// The bootloader may assume `reset_usec` is zero if it cannot or does not know the time of system reset, due to implementation or
    /// platform restrictions. `
    ///
    /// `reset_usec` will usually be 0 or a value near zero, but may be any value relative to any point in the past.
    reset_usec: u64,

    /// Time of bootloader initialisation in microseconds relative to an arbitrary point in the past.
    init_usec: u64,

    /// Time of executable handoff in microseconds relative to an arbitrary point in the past.
    exec_usec: u64,

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("BootloaderPerformance{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("reset_usec: {}\n", .{self.reset_usec});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("init_usec: {}\n", .{self.init_usec});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("exec_usec: {}\n", .{self.exec_usec});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};
