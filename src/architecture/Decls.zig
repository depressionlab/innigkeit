//! This contains the declarations that the architecture specific code must export.

const innigkeit = @import("innigkeit");
const core = @import("core");
const architecture = @import("architecture");

/// Architecture specific per-executor data.
PerExecutor: type,

interrupts: struct {
    /// Handle to an interrupt.
    ///
    /// Expected to be an enum.
    Interrupt: type,

    InterruptFrame: type,
},

paging: struct {
    /// The standard page size for the architecture.
    standard_page_size: core.Size,

    /// The largest page size supported by the architecture.
    largest_page_size: core.Size,

    /// The range of the address space that is considered kernel memory.
    ///
    /// Usually the higher half of the address space.
    ///
    /// This must not include either the zero, undefined nor max addresses.
    kernel_memory_range: innigkeit.VirtualRange,

    PageTable: type,
},

scheduling: struct {
    /// Architecture specific per-task data.
    PerTask: type,

    /// A string to be used in inline assembly to prevent unwinding.
    ///
    /// E.g. `asm volatile (arch.scheduling.cfi_prevent_unwinding);`
    cfi_prevent_unwinding: []const u8,
},

user: struct {
    /// Architecture specific per-thread data.
    PerThread: type,

    SyscallFrame: type,

    /// The range of the address space that is considered user memory.
    ///
    /// Usually the lower half of the address space.
    ///
    /// This must not include either the zero, undefined nor max addresses.
    user_memory_range: innigkeit.VirtualRange,
},

io: struct {
    /// Handle to a port.
    ///
    /// Expected to be an enum.
    Port: type,
},

init: struct {
    CaptureSystemInformationOptions: type,
},
