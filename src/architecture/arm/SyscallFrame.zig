const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");

/// The syscall frame for AArch64.
///
/// On `svc #0`:
///   - Syscall number is in x8.
///   - Arguments are in x0–x5.
///   - Return value is written to x0.
///   - ELR_EL1 holds the return PC (instruction after the `svc`).
pub const SyscallFrame = extern struct {
    x0: u64, // arg1 / return value
    x1: u64, // arg2
    x2: u64, // arg3
    x3: u64, // arg4
    x4: u64, // arg5
    x5: u64, // arg6
    x8: u64, // syscall number
    pc: u64, // ELR_EL1 / return address after syscall

    pub inline fn syscall(self: *const SyscallFrame) ?libinnigkeit.Syscall {
        return std.enums.fromInt(libinnigkeit.Syscall, self.x8);
    }

    pub inline fn arg(self: *const SyscallFrame, comptime argument: architecture.user.SyscallFrame.Arg) usize {
        return @intCast(switch (argument) {
            .one => self.x0,
            .two => self.x1,
            .three => self.x2,
            .four => self.x3,
            .five => self.x4,
            .six => self.x5,
            // AArch64 SVC only defines 6 args (x0-x5); map extras to zero
            .seven, .eight, .nine, .ten, .eleven, .twelve => 0,
        });
    }

    pub inline fn setReturn(self: *SyscallFrame, value: usize) void {
        self.x0 = value;
    }

    pub fn print(self: *const SyscallFrame, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        if (self.syscall()) |s|
            try writer.print("syscall: {t},\n", .{s})
        else
            try writer.print("invalid syscall: {d},\n", .{self.x8});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x0: 0x{x:0>16}, x1: 0x{x:0>16},\n", .{ self.x0, self.x1 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x2: 0x{x:0>16}, x3: 0x{x:0>16},\n", .{ self.x2, self.x3 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x4: 0x{x:0>16}, x5: 0x{x:0>16},\n", .{ self.x4, self.x5 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x8 (syscall#): 0x{x:0>16}, pc: 0x{x:0>16},\n", .{ self.x8, self.pc });

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const SyscallFrame, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return print(self, writer, 0);
    }
};
