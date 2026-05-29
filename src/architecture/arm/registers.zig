pub const TPIDR_EL1 = MSR(u64, "TPIDR_EL1");

pub const SCTLR_EL1 = MSR(u64, "SCTLR_EL1");
pub const TCR_EL1 = MSR(u64, "TCR_EL1");
pub const MAIR_EL1 = MSR(u64, "MAIR_EL1");
pub const VBAR_EL1 = MSR(u64, "VBAR_EL1");
pub const TTBR0_EL1 = MSR(u64, "TTBR0_EL1");
pub const TTBR1_EL1 = MSR(u64, "TTBR1_EL1");
pub const ESR_EL1 = MSR(u64, "ESR_EL1");
pub const ELR_EL1 = MSR(u64, "ELR_EL1");
pub const SPSR_EL1 = MSR(u64, "SPSR_EL1");
pub const SP_EL0 = MSR(u64, "SP_EL0");
pub const CurrentEL = MSR(u64, "CurrentEL");
pub const CNTP_CTL_EL0 = MSR(u64, "CNTP_CTL_EL0");
pub const CNTFRQ_EL0 = MSR(u64, "CNTFRQ_EL0");
pub const CNTPCT_EL0 = MSR(u64, "CNTPCT_EL0");
pub const CNTVCT_EL0 = MSR(u64, "CNTVCT_EL0");
pub const CNTV_CTL_EL0 = MSR(u64, "CNTV_CTL_EL0");
pub const CNTV_CVAL_EL0 = MSR(u64, "CNTV_CVAL_EL0");
pub const MPIDR_EL1 = MSR(u64, "MPIDR_EL1");

/// Switch to using SP_EL1 as the stack pointer at all ELs.
pub fn spSel1() void {
    asm volatile ("msr SPSel, #1");
}

/// Switch to using SP_EL0 as the stack pointer at all ELs.
pub fn spSel0() void {
    asm volatile ("msr SPSel, #0");
}

pub fn MSR(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub inline fn read() T {
            return asm ("mrs %[out], " ++ name
                : [out] "=r" (-> T),
            );
        }

        pub inline fn write(val: T) void {
            asm volatile ("msr " ++ name ++ ", %[in]"
                :
                : [in] "r" (val),
            );
        }

        pub inline fn writeImm(comptime val: T) void {
            asm volatile ("msr " ++ name ++ ", %[in]"
                :
                : [in] "i" (val),
            );
        }
    };
}
