const innigkeit = @import("innigkeit");

pub const InterruptFrame = extern struct {
    /// General purpose registers x0-x30 (x30 is the link register).
    x: [31]u64,
    /// User stack pointer (SP_EL0), important for EL0 exceptions.
    sp_el0: u64,
    /// Exception Link Register: the address to return to after exception handling.
    elr: u64,
    /// Saved Program Status Register: the interrupted PSTATE.
    spsr: u64,

    pub fn instructionPointer(self: *const InterruptFrame) innigkeit.VirtualAddress {
        return .from(self.elr);
    }
};
