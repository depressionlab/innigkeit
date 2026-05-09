/// The panic mode the kernel is in.
///
/// The kernel will move through each mode in order as initialization is performed.
///
/// No modes will be skipped and must be in strict increasing order.
pub const PanicMode = enum(u8) {
    /// Panic will disable interrupts and halt the current executor.
    ///
    /// The current task is not guaranteed to be valid.
    no_op,

    /// Panic will print using init output with no locking.
    ///
    /// Does not support multiple executors.
    single_executor_init_panic,

    /// Panic will print using init output, poisons the init output lock.
    ///
    /// Supports multiple executors.
    init_panic,
};
