/// ARM64 interrupt/exception types.
pub const Interrupt = enum(u8) {
    /// IRQ from current EL with SP_EL1.
    irq = 0,
    /// FIQ from current EL with SP_EL1.
    fiq = 1,
    /// SError from current EL with SP_EL1.
    serror = 2,
    /// Synchronous exception from EL1 (kernel fault).
    sync_el1 = 3,
    /// Synchronous exception from EL0 (user fault or syscall via SVC).
    sync_el0 = 4,
    /// IRQ from EL0 (user IRQ).
    irq_el0 = 5,
    _,
};
