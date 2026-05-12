const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

pub const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector_number: extern union {
        full: u64,
        interrupt: @import("Interrupt.zig").Interrupt,
    },
    error_code: u64,
    rip: innigkeit.VirtualAddress,
    cs: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    },
    rflags: x64.registers.RFlags,
    rsp: innigkeit.VirtualAddress,
    ss: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    },

    pub inline fn from(self: architecture.interrupts.InterruptFrame) *InterruptFrame {
        return self.arch_specific;
    }

    /// Returns the context that the interrupt was triggered from.
    pub fn context(self: *const InterruptFrame) innigkeit.Context.Type {
        return switch (self.cs.selector) {
            .kernel_code => return .kernel,
            .user_code, .user_code_32bit => .user,
            else => unreachable,
        };
    }

    /// Provides the context this interrupt was triggered from.
    pub fn fillContext(self: *const InterruptFrame, cpu_context: *std.debug.cpu_context.Native) void {
        cpu_context.gprs.set(.rax, self.rax);
        cpu_context.gprs.set(.rdx, self.rdx);
        cpu_context.gprs.set(.rcx, self.rcx);
        cpu_context.gprs.set(.rbx, self.rbx);
        cpu_context.gprs.set(.rsi, self.rsi);
        cpu_context.gprs.set(.rdi, self.rdi);
        cpu_context.gprs.set(.rbp, self.rbp);
        cpu_context.gprs.set(.rsp, self.rsp.value);
        cpu_context.gprs.set(.r8, self.r8);
        cpu_context.gprs.set(.r9, self.r9);
        cpu_context.gprs.set(.r10, self.r10);
        cpu_context.gprs.set(.r11, self.r11);
        cpu_context.gprs.set(.r12, self.r12);
        cpu_context.gprs.set(.r13, self.r13);
        cpu_context.gprs.set(.r14, self.r14);
        cpu_context.gprs.set(.r15, self.r15);
        cpu_context.gprs.set(.rip, self.rip.value);
    }

    pub fn print(self: *const InterruptFrame, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("InterruptFrame{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("interrupt: {t},\n", .{self.vector_number.interrupt});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("error code: {},\n", .{self.error_code});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("cs: {t}, ss: {t},\n", .{ self.cs.selector, self.ss.selector });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rsp: 0x{x:0>16}, rip: 0x{x:0>16},\n", .{ self.rsp.value, self.rip.value });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rax: 0x{x:0>16}, rbx: 0x{x:0>16},\n", .{ self.rax, self.rbx });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rcx: 0x{x:0>16}, rdx: 0x{x:0>16},\n", .{ self.rcx, self.rdx });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rbp: 0x{x:0>16}, rsi: 0x{x:0>16},\n", .{ self.rbp, self.rsi });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("rdi: 0x{x:0>16}, r8:  0x{x:0>16},\n", .{ self.rdi, self.r8 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r9:  0x{x:0>16}, r10: 0x{x:0>16},\n", .{ self.r9, self.r10 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r11: 0x{x:0>16}, r12: 0x{x:0>16},\n", .{ self.r11, self.r12 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r13: 0x{x:0>16}, r14: 0x{x:0>16},\n", .{ self.r13, self.r14 });

        try writer.splatByteAll(' ', new_indent);
        try writer.print("r15: 0x{x:0>16},\n", .{self.r15});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("rflags: ");
        try self.rflags.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const InterruptFrame, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return print(self, writer, 0);
    }
};
