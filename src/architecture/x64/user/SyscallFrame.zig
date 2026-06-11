const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");
const x64 = @import("../x64.zig");

pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rbx: u64,
    rax: u64,

    rflags: x64.registers.RFlags,
    rip: innigkeit.VirtualAddress,
    rsp: innigkeit.VirtualAddress,

    pub inline fn from(syscall_frame: architecture.user.SyscallFrame) *SyscallFrame {
        return &syscall_frame.arch_specific;
    }

    pub inline fn syscall(self: *const SyscallFrame) ?libinnigkeit.Syscall {
        return std.enums.fromInt(libinnigkeit.Syscall, self.rax);
    }

    pub inline fn arg(self: *const SyscallFrame, comptime argument: architecture.user.SyscallFrame.Arg) usize {
        return switch (argument) {
            .one => self.rdi,
            .two => self.rsi,
            .three => self.rdx,
            // arg4 arrives in r10 (rcx is clobbered by the `syscall`
            // instruction); rbx is callee-saved and never used for arguments.
            .four => self.r10,
            .five => self.r8,
            .six => self.r9,
            .seven => self.rbx,
            .eight => self.r12,
            .nine => self.r13,
            .ten => self.r14,
            .eleven => self.r15,
            .twelve => self.rbp,
        };
    }

    pub fn print(self: *const SyscallFrame, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        if (self.syscall()) |s|
            try writer.print("syscall:   {t},\n", .{s})
        else
            try writer.print("invalid syscall:   {d},\n", .{self.rdi});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg1/rdi:  0x{x:0>16}, arg2/rsi:  0x{x:0>16},\n", .{ self.arg(.one), self.arg(.two) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg3/rdx:  0x{x:0>16}, arg4/r10:   0x{x:0>16},\n", .{ self.arg(.three), self.arg(.four) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg5/r8:   0x{x:0>16}, arg6/r9:  0x{x:0>16},\n", .{ self.arg(.five), self.arg(.six) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg7/rbx:  0x{x:0>16}, arg8/r12:  0x{x:0>16},\n", .{ self.arg(.seven), self.arg(.eight) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg9/r13:  0x{x:0>16}, arg10/r14: 0x{x:0>16},\n", .{ self.arg(.nine), self.arg(.ten) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg11/r15: 0x{x:0>16}, arg12/rbp: 0x{x:0>16},\n", .{ self.arg(.eleven), self.arg(.twelve) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp:       0x{x:0>16}, rip:       0x{x:0>16},\n", .{ self.rsp.value, self.rip.value });

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try self.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const SyscallFrame, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return print(self, writer, 0);
    }
};
