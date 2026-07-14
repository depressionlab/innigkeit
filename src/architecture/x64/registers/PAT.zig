const std = @import("std");
const MSR = @import("root.zig").MSR;

pub const PAT = packed struct(u64) {
    entry0: MemoryType,

    _reserved3_7: u5,

    entry1: MemoryType,

    _reserved11_15: u5,

    entry2: MemoryType,

    _reserved19_23: u5,

    entry3: MemoryType,

    _reserved27_31: u5,

    entry4: MemoryType,

    _reserved35_39: u5,

    entry5: MemoryType,

    _reserved43_47: u5,

    entry6: MemoryType,

    _reserved51_55: u5,

    entry7: MemoryType,

    _reserved59_63: u5,

    pub const MemoryType = enum(u3) {
        uncacheable = 0x0,
        write_combining = 0x1,
        write_through = 0x4,
        write_protected = 0x5,
        write_back = 0x6,
        uncached = 0x7,
    };

    pub inline fn read() PAT {
        return @bitCast(msr.read());
    }

    pub inline fn write(self: PAT) void {
        msr.write(@bitCast(self));
    }

    pub fn print(self: PAT, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("PAT{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry0: {t},\n", .{self.entry0});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry1: {t},\n", .{self.entry1});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry2: {t},\n", .{self.entry2});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry3: {t},\n", .{self.entry3});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry4: {t},\n", .{self.entry4});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry5: {t},\n", .{self.entry5});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry6: {t},\n", .{self.entry6});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("entry7: {t},\n", .{self.entry7});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: PAT, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    const msr = MSR(u64, 0x277);
};
