const MSR = @import("root.zig").MSR;

/// MTRR Capability Register (MTRRCAP)
pub const IA32_MTRRCAP = packed struct(u64) {
    /// Indicates the number of variable ranges implemented on the processor.
    number_of_variable_range_registers: u8,

    /// Fixed range MTRRs (IA32_MTRR_FIX64K_00000 through IA32_MTRR_FIX4K_0F8000) are supported when `true`; no fixed
    /// range registers are supported when `false`.
    fixed_range_registers_supported: bool,

    _reserved9: u1,

    /// The write-combining (WC) memory type is supported when `true`; the WC type is not supported when `false`.
    write_combining_supported: bool,

    /// The system-management range register (SMRR) interface is supported when `true`; the SMRR interface is not
    /// supported when `false`.
    system_management_range_register_supported: bool,

    _reserved12_63: u52,

    pub inline fn read() IA32_MTRRCAP {
        return @bitCast(msr.read());
    }

    const msr = MSR(u64, 0xFE);
};
