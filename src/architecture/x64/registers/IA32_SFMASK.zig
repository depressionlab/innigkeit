const MSR = @import("root.zig").MSR;

pub const IA32_SFMASK = packed struct(u64) {
    clear_carry: bool = false,
    _reserved1: u1 = 0,
    clear_parity: bool = false,
    _reserved2: u1 = 0,
    clear_auxiliary_carry: bool = false,
    _reserved3: u1 = 0,
    clear_zero: bool = false,
    clear_sign: bool = false,
    clear_trap: bool = false,
    clear_enable_interrupts: bool = false,
    clear_direction: bool = false,
    clear_overflow: bool = false,
    clear_iopl: enum(u2) {
        false = 0b00,
        true = 0b11,
    } = .false,
    clear_nested: bool = false,
    _reserved4: u1 = 0,
    clear_resume: bool = false,
    clear_virtual_8086: bool = false,
    clear_alignment_check: bool = false,
    clear_virtual_interrupt: bool = false,
    clear_virtual_interrupt_pending: bool = false,
    clear_id: bool = false,
    _reserved5: u42 = 0,

    pub inline fn read() IA32_SFMASK {
        return @bitCast(msr.read());
    }

    pub inline fn write(sfmask: IA32_SFMASK) void {
        msr.write(@bitCast(sfmask));
    }

    const msr = MSR(u64, 0xC0000084);
};
