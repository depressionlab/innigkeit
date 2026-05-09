pub const Cr0 = packed struct(u64) {
    /// Enables protected mode.
    protected_mode_enable: bool,

    /// Enables monitoring of the coprocessor.
    monitor_coprocessor: bool,

    /// Force all x87 and MMX instructions to cause an `#NE` exception.
    emulate_coprocessor: bool,

    /// Automatically set to 1 on _hardware_ task switch.
    task_switched: bool,

    /// Indicates support of 387DX math coprocessor instructions.
    extension_type: bool,

    /// Enables the native (internal) error reporting mechanism for x87 FPU errors.
    numeric_error: bool,

    _reserved6_15: u10,

    /// Controls whether supervisor-level writes to read-only pages are inhibited.
    write_protect: bool,

    _reserved17: u1,

    /// Enables automatic usermode alignment checking if `RFlags.alignment_mask` is also set.
    alignment_mask: bool,

    _reserved19_28: u10,

    /// Ignored, should always be unset.
    not_write_through: bool,

    /// Disables some processor caches, specifics are model-dependent.
    cache_disable: bool,

    /// Enables paging.
    paging: bool,

    _reserved32_63: u32,

    pub fn read() Cr0 {
        return @bitCast(asm ("mov %%cr0, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(cr0: Cr0) void {
        asm volatile ("mov %[value], %%cr0"
            :
            : [value] "r" (@as(u64, @bitCast(cr0))),
        );
    }
};
