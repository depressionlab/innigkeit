const standard_page_size = @import("architecture").paging.standard_page_size;
pub const innigkeit_version = @import("kernel_options").innigkeit_version;

// TODO: should this be generated at build time with a config file? or generated
// from a config file that can be specified in the filesystem?

pub const debug = struct {
    /// The maximum length a log scope can be.
    ///
    /// This is used to align the output of logs.
    pub const max_log_scope_len = 14;
};

pub const executor = struct {
    pub const maximum_number_of_executors = 64;

    pub const interrupt_source_panic_buffer_size = standard_page_size;
};

pub const memory = struct {
    // This must be kept in sync with the linker scripts.
    pub const kernel_base_address: @import("innigkeit")
        .KernelVirtualAddress = .from(0xFFFFFFFF80000000);

    pub const maximum_number_of_memory_map_entries = 128;

    pub const resource_arena_name_length = 64;
    pub const cache_name_length = 64;

    /// The number of virtual ranges to batch together when unmapping/changing protection.
    pub const virtual_ranges_to_batch = 16;

    /// When batching, virtual ranges are merged together if the seperation between them is less than or equal to this value.
    pub const virtual_range_batching_merge_distance = standard_page_size.multiplyScalar(4);
};

pub const scheduler = struct {
    pub const per_executor_interrupt_period: @import("core").Duration = .from(5, .millisecond);
};

pub const task = struct {
    /// Fixed regardless of build mode so that a stack overflow caught in release is
    /// also reproducible in debug (mode-dependent sizes hide release-only bugs).
    ///
    /// Linux x86-64 uses 16 KiB. We use 32 KiB (2x) because Zig stack frames
    /// are deeper than equivalent C frames, and the logging path stack-allocates
    /// a 4 KiB writer buffer.
    ///
    /// TODO: figure out this value...
    pub const kernel_stack_size = standard_page_size.multiplyScalar(128); // 512 KiB

    /// The size of IST stacks (double-fault, NMI) and the per-CPU IRQ stack.
    ///
    /// IST handlers are minimal (panic or halt). The IRQ stack handles full
    /// kernel interrupt dispatch including page-fault handling (~12 frames) and
    /// the logging path (~4 KiB writer buffer), so 16 KiB gives ample headroom.
    pub const interrupt_stack_size = standard_page_size.multiplyScalar(4); // 16 KiB

    pub const task_name_length = 64;
};

pub const time = struct {
    pub const maximum_number_of_time_sources = 8;
};

pub const user = struct {
    pub const process_name_length = 64;
    // the process name is also used as the name of its address space
    pub const address_space_name_length = process_name_length;
};

pub const capabilities = struct {
    /// Number of capability slots per process.
    pub const slots_per_process: u32 = 256;

    /// Sentinel value meaning "no next free slot" in the free list.
    pub const null_slot: u32 = @import("std").math.maxInt(u32);
};

pub const security = struct {
    /// When true, `spawn` refuses the load binaries that have no `.codesig`
    /// sidecar in initfs, or whose signature fails Ed25519 verification.
    /// Off by default in Debug so unsigned development builds still boot.
    pub const enforce_code_signing: bool = !@import("core").is_debug;

    /// When true, syscalls that require an entitlement the process was not
    /// granted return EPERM instead of silently succeeding.
    /// Off by default in Debug for the same reason.
    pub const enforce_entitlements: bool = !@import("core").is_debug;
};
