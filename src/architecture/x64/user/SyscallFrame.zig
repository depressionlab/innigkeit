const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const libinnigkeit = @import("libinnigkeit");
const x64 = @import("../x64.zig");

pub const SyscallFrame = extern struct {
    /// arg11
    r15: u64,
    /// arg10
    r14: u64,
    /// arg9
    r13: u64,
    /// arg8
    r12: u64,
    /// arg7
    r10: u64,
    /// arg5
    r9: u64,
    /// arg4
    r8: u64,
    /// syscall number
    rdi: u64,
    /// arg1
    rsi: u64,
    /// arg12
    rbp: u64,
    /// arg2
    rdx: u64,
    /// arg6
    rbx: u64,
    /// arg3
    rax: u64,

    /// r11
    rflags: x64.registers.RFlags,
    /// rcx
    rip: innigkeit.VirtualAddress,
    rsp: innigkeit.VirtualAddress,

    pub inline fn from(syscall_frame: architecture.user.SyscallFrame) *SyscallFrame {
        return &syscall_frame.arch_specific;
    }

    pub inline fn syscall(syscall_frame: *const SyscallFrame) ?libinnigkeit.Syscall {
        return std.enums.fromInt(libinnigkeit.Syscall, syscall_frame.rax);
    }

    pub inline fn arg(syscall_frame: *const SyscallFrame, comptime argument: architecture.user.SyscallFrame.Arg) usize {
        return switch (argument) {
            .one => syscall_frame.rdi,
            .two => syscall_frame.rsi,
            .three => syscall_frame.rdx,
            .four => syscall_frame.rbx,
            .five => syscall_frame.r8,
            .six => syscall_frame.r9,
            .seven => syscall_frame.r10,
            .eight => syscall_frame.r12,
            .nine => syscall_frame.r13,
            .ten => syscall_frame.r14,
            .eleven => syscall_frame.r15,
            .twelve => syscall_frame.rbp,
        };
    }

    pub fn print(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
        indent: usize,
    ) !void {
        const new_indent = indent + 2;

        try writer.writeAll("SyscallFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        if (value.syscall()) |s|
            try writer.print("syscall:   {t},\n", .{s})
        else
            try writer.print("invalid syscall:   {d},\n", .{value.rdi});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg1/rdi:  0x{x:0>16}, arg2/rsi:  0x{x:0>16},\n", .{ value.arg(.one), value.arg(.two) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg3/rdx:  0x{x:0>16}, arg4/rbx:   0x{x:0>16},\n", .{ value.arg(.three), value.arg(.four) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg5/r8:   0x{x:0>16}, arg6/r9:  0x{x:0>16},\n", .{ value.arg(.five), value.arg(.six) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg7/r10:  0x{x:0>16}, arg8/r12:  0x{x:0>16},\n", .{ value.arg(.seven), value.arg(.eight) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg9/r13:  0x{x:0>16}, arg10/r14: 0x{x:0>16},\n", .{ value.arg(.nine), value.arg(.ten) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("arg11/r15: 0x{x:0>16}, arg12/rbp: 0x{x:0>16},\n", .{ value.arg(.eleven), value.arg(.twelve) });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp:       0x{x:0>16}, rip:       0x{x:0>16},\n", .{ value.rsp.value, value.rip.value });

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try value.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        value: *const SyscallFrame,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return print(value, writer, 0);
    }
};
