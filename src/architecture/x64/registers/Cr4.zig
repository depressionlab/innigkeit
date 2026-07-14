pub const Cr4 = packed struct(u64) {
    /// Enables hardware-supported performance enhancements for software running in virtual-8086 mode.
    virtual_8086_mode_extensions: bool,

    /// Enables support for protected-mode virtual interrupts.
    protected_mode_virtual_interrupts: bool,

    /// When set, only privilege-level 0 can execute the `RDTSC` or `RDTSCP` instructions.
    time_stamp_disable: bool,

    /// Enables I/O breakpoint capability and enforces treatment of `DR4` and `DR5` registers as reserved.
    debugging_extensions: bool,

    /// Enables 4-MByte pages with 32-bit paging when `true`; restricts 32-bit paging to pages of 4 KBytes when `false`.
    page_size_extension: bool,

    /// Enables physical address extensions and 2MB physical frames.
    ///
    /// Required in long mode.
    physical_address_extension: bool,

    /// Enables the machine-check exception mechanism.
    machine_check_exception: bool,

    /// Enables the global page feature, allowing some page translations to be marked as global.
    page_global: bool,

    /// Allows software running at any privilege level to use the `RDPMC` instruction.
    performance_monitoring_counter: bool,

    /// Enables the use of legacy SSE instructions; allows using `FXSAVE`/`FXRSTOR` for saving processor state of
    /// 128-bit media instructions.
    os_fxsave: bool,

    /// Enables the SIMD floating-point exception (`#XF`) for handling unmasked 256-bit and 128-bit media floating-point
    /// errors.
    unmasked_exception_support: bool,

    /// Prevents the execution of the `SGDT`, `SIDT`, `SLDT`, `SMSW`, and `STR` instructions by user-mode software.
    usermode_instruction_prevention: bool,

    /// Enables 5-level paging on supported CPUs.
    level_5_paging: bool,

    /// Enables VMX instructions.
    ///
    /// Intel only.
    virtual_machine_extensions: bool,

    /// Enables SMX instructions.
    ///
    /// Intel only.
    safer_mode_extensions: bool,

    _reserved15: u1,

    /// Enables software running in 64-bit mode at any privilege level to read and write the FS.base and GS.base hidden
    /// segment register state.
    fsgsbase: bool,

    /// Enables process-context identifiers.
    pcid: bool,

    /// Enables extended processor state management instructions, including `XGETBV` and `XSAVE`.
    osxsave: bool,

    /// Enables the Key Locker feature.
    ///
    /// Intel only.
    key_locker: bool,

    /// Prevents the execution of instructions that reside in pages accessible by user-mode software when the processor
    /// is in supervisor-mode.
    supervisor_mode_execution_prevention: bool,

    /// Enables restrictions for supervisor-mode software when reading data from user-mode pages.
    supervisor_mode_access_prevention: bool,

    /// Enables protection keys for user-mode pages.
    ///
    /// Also enables access to the PKRU register (via the `RDPKRU`/`WRPKRU`
    /// instructions) to set user-mode protection key access controls.
    protection_key_user: bool,

    /// Enables Control-flow Enforcement Technology
    ///
    /// This enables the shadow stack feature, ensuring return addresses read via `RET` and `IRET` have not been
    /// corrupted.
    control_flow_enforcement: bool,

    /// Enables protection keys for supervisor-mode pages.
    ///
    /// Intel only.
    protection_key_supervisor: bool,

    /// Enables user interrupts when `true`, including user-interrupt delivery, user-interrupt notification
    /// identification and the user-interrupt instructions.
    ///
    /// Intel only.
    user_interrupt: bool,

    _reserved26_27: u2,

    /// When set, enables LAM (linear-address masking) for supervisor pointers.
    ///
    /// Intel only.
    supervisor_lam: bool,

    _reserved29_63: u35,

    pub fn read() Cr4 {
        return @bitCast(asm ("mov %%cr4, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(cr4: Cr4) void {
        asm volatile ("mov %[value], %%cr4"
            :
            : [value] "r" (@as(u64, @bitCast(cr4))),
        );
    }
};
