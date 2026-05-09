const std = @import("std");
const core = @import("core");
const x64 = @import("../x64.zig");

pub const RFlags = packed struct(u64) {
    /// Set by hardware if last arithmetic operation generated a carry out of the most-significant bit of the result.
    carry: bool,

    _reserved1: u1,

    /// Set by hardware if last result has an even number of 1 bits (only for some operations).
    parity: bool,

    _reserved2: u1,

    /// Set by hardware if last arithmetic operation generated a carry out of bit 3 of the result.
    auxiliary_carry: bool,

    _reserved3: u1,

    /// Set by hardware if last arithmetic operation resulted in a zero value.
    zero: bool,

    /// Set by hardware if last arithmetic operation resulted in a negative value.
    sign: bool,

    /// Enable single-step mode for debugging.
    trap: bool,

    /// Enable interrupts.
    enable_interrupts: bool,

    /// Determines the order in which strings are processed.
    direction: Direction,

    /// Set by hardware to indicate that the sign bit of the result of the last signed integer operation differs from
    /// the source operands.
    overflow: bool,

    /// Specifies the privilege level required for executing I/O address-space instructions.
    iopl: x64.PrivilegeLevel,

    /// Used by `iret` in hardware task switch mode to determine if current task is nested.
    nested: bool,

    _reserved4: u1,

    /// Allows to restart an instruction following an instrucion breakpoint.
    @"resume": bool,

    /// Enable the virtual-8086 mode.
    virtual_8086: bool,

    /// Enable automatic alignment checking if CR0.AM is set.
    ///
    /// Only works if CPL is 3.
    alignment_check: bool,

    /// Virtual image of the INTERRUPT_FLAG bit.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual interrupts (CR4.PVI) are activated.
    virtual_interrupt: bool,

    /// Indicates that an external, maskable interrupt is pending.
    ///
    /// Used when virtual-8086 mode extensions (CR4.VME) or protected-mode virtual interrupts (CR4.PVI) are activated.
    virtual_interrupt_pending: bool,

    /// Processor feature identification flag.
    ///
    /// If this flag is modifiable, the CPU supports CPUID.
    id: bool,

    _reserved5: u42,

    pub const Direction = enum(u1) {
        up = 0,
        down = 1,
    };

    /// Returns the current value of the RFLAGS register.
    pub inline fn read() RFlags {
        return @bitCast(asm ("pushfq; popq %[ret]"
            : [ret] "=r" (-> u64),
        ));
    }

    /// Writes the RFLAGS register.
    ///
    /// Note: does not protect reserved bits, that is left up to the caller
    pub inline fn write(rflags: RFlags) void {
        asm volatile ("pushq %[val]; popfq"
            :
            : [val] "r" (@as(u64, @bitCast(rflags))),
            : .{ .flags = true });
    }

    pub fn print(rflags: RFlags, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("RFlags{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("carry: {},\n", .{rflags.carry});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("parity: {},\n", .{rflags.parity});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("auxiliary_carry: {},\n", .{rflags.auxiliary_carry});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("zero: {},\n", .{rflags.zero});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("sign: {},\n", .{rflags.sign});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("trap: {},\n", .{rflags.trap});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("enable_interrupts: {},\n", .{rflags.enable_interrupts});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("direction: {},\n", .{rflags.direction});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("overflow: {},\n", .{rflags.overflow});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("iopl: {t},\n", .{rflags.iopl});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("nested: {},\n", .{rflags.nested});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("resume: {},\n", .{rflags.@"resume"});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_8086: {},\n", .{rflags.virtual_8086});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("alignment_check: {},\n", .{rflags.alignment_check});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_interrupt: {},\n", .{rflags.virtual_interrupt});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("virtual_interrupt_pending: {},\n", .{rflags.virtual_interrupt_pending});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("id: {},\n", .{rflags.id});

        try writer.splatByteAll(' ', indent);
        try writer.writeAll("}");
    }

    pub inline fn format(
        rflags: RFlags,
        writer: *std.Io.Writer,
    ) !void {
        return print(rflags, writer, 0);
    }

    comptime {
        core.testing.expectSize(RFlags, .of(u64));
    }
};
