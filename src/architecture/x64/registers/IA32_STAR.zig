const x64 = @import("../x64.zig");
const MSR = @import("root.zig").MSR;

pub const IA32_STAR = extern struct {
    /// The target EIP of syscall in 32-bit compatibility or legacy mode.
    syscall_target_eip_32bit: u32,

    /// This field is used to specify both the CS and SS selectors loaded into CS and SS during SYSCALL.
    ///
    /// This field is copied directly into CS.Sel.
    /// SS.Sel is set to this field + 8.
    ///
    /// Because SYSCALL always switches to CPL 0, the RPL bits 33:32 should be initialized to 00b.
    syscall_cs_ss: x64.Gdt.Selector,

    /// This field is used to specify both the CS and SS selectors loaded into CS and SS during SYSRET.
    ///
    /// If SYSRET is returning to 32-bit mode (either legacy or compatibility), this field is copied directly into the CS selector field.
    /// If SYSRET is returning to 64-bit mode, the CS selector is set to this field + 16.
    /// SS.Sel is set to this field + 8, regardless of the target mode.
    ///
    /// Because SYSRET always returns to CPL 3, the RPL bits 49:48 should be initialized to 11b.
    sysret_cs_ss: x64.Gdt.Selector,

    pub inline fn read() IA32_STAR {
        return @bitCast(msr.read());
    }

    pub inline fn write(star: IA32_STAR) void {
        msr.write(@bitCast(star));
    }

    const msr = MSR(u64, 0xC0000081);
};
