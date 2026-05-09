/// Debug-Status Register (DR6)
///
/// Debug status is loaded into DR6 when an enabled debug condition is encountered that causes a #DB exception.
///
/// `breakpoint_register_access_detected`, `single_step`, and `task_switch` are not cleared by the processor and must be
/// cleared by software after the contents have been read.
pub const DR6 = packed struct(u64) {
    breakpoint_0: bool,
    breakpoint_1: bool,
    breakpoint_2: bool,
    breakpoint_3: bool,

    _reserved4_10: u7,

    /// The processor set this to `false` if #DB was generated due to a bus lock.
    ///
    /// Other sources of #DB do not modify this bit.
    bus_lock_detected: bool,

    _reserved_12: u1,

    /// The processor sets this bit to 1 if software accesses any debug register (DR0–DR7) while the general-detect
    /// condition is enabled (`DR7.general_detect = true`).
    breakpoint_register_access_detected: bool,

    /// The processor sets this bit to 1 if the #DB exception occurs as a result of single-step mode
    /// (`RFlags.trap = true`).
    ///
    /// Single-step mode has the highest-priority among debug exceptions.
    ///
    /// Other status bits within the DR6 register can be set by the processor along with the BS bit.
    single_step: bool,

    /// The processor sets this bit to 1 if the #DB exception occurred as a result of task switch to a task with a
    /// TSS T-bit set to 1.
    task_switch: bool,

    _reserved16_31: u16,

    _reserved32_63: u32,

    pub fn read() DR6 {
        return @bitCast(asm ("mov %%dr6, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(dr6: DR6) void {
        asm volatile ("mov %[value], %%dr6"
            :
            : [value] "r" (@as(u64, @bitCast(dr6))),
        );
    }
};
