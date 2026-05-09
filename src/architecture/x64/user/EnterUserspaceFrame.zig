const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");

pub const EnterUserspaceFrame = extern struct {
    rip: innigkeit.UserVirtualAddress,
    cs: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    } = .{ .selector = .user_code },
    rflags: x64.registers.RFlags = user_rflags,
    rsp: innigkeit.UserVirtualAddress,
    ss: extern union {
        full: u64,
        selector: x64.Gdt.Selector,
    } = .{ .selector = .user_data },

    const user_rflags: x64.registers.RFlags = .{
        .carry = false,
        ._reserved1 = 0,
        .parity = false,
        ._reserved2 = 0,
        .auxiliary_carry = false,
        ._reserved3 = 0,
        .zero = false,
        .sign = false,
        .trap = false,
        .enable_interrupts = true,
        .direction = .up,
        .overflow = false,
        .iopl = .ring0,
        .nested = false,
        ._reserved4 = 0,
        .@"resume" = false,
        .virtual_8086 = false,
        .alignment_check = false,
        .virtual_interrupt = false,
        .virtual_interrupt_pending = false,
        .id = false,
        ._reserved5 = 0,
    };
};
