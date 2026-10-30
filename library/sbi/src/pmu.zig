//! The RISC-V hardware performance counters such as `mcycle`, `minstret`, and `mhpmcounterX` CSRs are accessible as
//! read-only from supervisor-mode using `cycle`, `instret`, and `hpmcounterX` CSRs.
//!
//! The SBI performance monitoring unit (PMU) extension is an interface for supervisor-mode to configure and use the
//! RISC-V hardware performance counters with assistance from the machine-mode (or hypervisor-mode).
//!
//! These hardware performance counters can only be started, stopped, or configured from machine-mode using
//! `mcountinhibit` and `mhpmeventX` CSRs. Due to this, a machine-mode SBI implementation may choose to disallow SBI PMU
//! extension if `mcountinhibit` CSR is not implemented by the RISC-V platform.
//!
//! A RISC-V platform generally supports monitoring of various hardware events using a limited number of hardware
//! performance counters which are up to 64 bits wide. In addition, a SBI implementation can also provide firmware
//! performance counters which can monitor firmware events such as numberof misaligned load/store instructions, number
//! of RFENCEs, number of IPIs, etc.
//!
//! All firmware counters must have same number of bits and can be up to 64 bits wide.
//!
//! The SBI PMU extension provides:
//!  - An interface for supervisor-mode software to discover and configure per-hart hardware/firmware counters
//!  - A typical perf compatible interface for hardware/firmware performance counters and events
//!  - Full access to microarchitecture’s raw event encodings
const base = @import("base.zig");
const ecall = @import("ecall.zig");
const is_64 = @import("root.zig").is_64;

pub fn available() bool {
    return base.probeExtension(.PMU);
}

/// Returns the number of counters (both hardware and firmware).
///
/// Available from SBI v0.3.
pub fn getNumberOfCounters() usize {
    return @bitCast(ecall.zeroArgsWithReturnNoError(.PMU, @backingInt(PMU_FID.NUM_COUNTERS)));
}

pub const GetCounterInfoError = error{
    /// `counter_index` points to an invalid counter.
    InvalidParameter,
};

/// Get details about the specified counter such as underlying CSR number, width of the counter, type of counter
/// hardware/firmware, etc.
///
/// Available from SBI v0.3.
pub fn getCounterInfo(counter_index: usize) GetCounterInfoError!CounterInfo {
    const raw: CounterInfo.Raw = @bitCast(try ecall.oneArgsWithReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_GET_INFO),
        @bitCast(counter_index),
        GetCounterInfoError,
    ));

    return switch (raw.type) {
        .hardware => .{
            .hardware = .{
                .csr = raw.csr,
                .width = raw.width,
            },
        },
        .firmware => .firmware,
    };
}

pub const ConfigureMatchingCounterError = error{
    /// none of the counters can monitor the specified event.
    NotSupported,

    /// set of counters has at least one invalid counter.
    InvalidParameter,
};

/// Find and configure a counter from a set of counters which is not started (or enabled) and can monitor the
/// specified event.
///
/// The `counter_mask` parameter represent the set of counters whereas `event` represents the event to be monitored.
///
/// Available from SBI v0.3.
pub fn configureMatchingCounter(
    counter_mask: CounterMask,
    event: Event,
    config_flags: ConfigFlags,
) ConfigureMatchingCounterError!usize {
    const raw = event.toRaw();

    return @bitCast(try ecall.fiveArgsLastArg64WithReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_CFG_MATCH),
        @bitCast(counter_mask.base),
        @bitCast(counter_mask.mask),
        @bitCast(config_flags),
        @as(u20, @bitCast(raw.event_index)),
        raw.event_data,
        ConfigureMatchingCounterError,
    ));
}

pub const StartCountersError = error{
    /// set of counters has at least one invalid counter or the given flag parameter has an undefined bit set.
    InvalidParameter,

    /// set of counters includes at least one counter which is already started.
    AlreadyStarted,

    /// the snapshot shared memory is not available and `start_mode` is `.init_snapshot`.
    NoSharedMemory,
};

/// Start or enable a set of counters on the calling hart with the specified initial value.
///
/// The `counter_mask` parameter represents the set of counters.
///
/// Available from SBI v0.3.
pub fn startCounters(
    counter_mask: CounterMask,
    start_mode: StartMode,
) StartCountersError!void {
    return ecall.fourArgsLastArg64NoReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_START),
        @bitCast(counter_mask.base),
        @bitCast(counter_mask.mask),
        @bitCast(start_mode.toRaw()),
        start_mode.initialValue(),
        StartCountersError,
    );
}

pub const StopCountersError = error{
    InvalidParameter,
    AlreadyStopped,
};

/// Stop or disable a set of counters on the calling hart.
///
/// The `counter_mask` parameter represent the set of counters.
///
/// Available from SBI v0.3.
pub fn stopCounters(
    counter_mask: CounterMask,
    stop_flags: StopFlags,
) StopCountersError!void {
    return ecall.threeArgsNoReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_START),
        @bitCast(counter_mask.base),
        @bitCast(counter_mask.mask),
        @bitCast(stop_flags),
        StopCountersError,
    );
}

pub const ReadFirmwareCounterError = error{
    /// `counter_index` points to a hardware counter or an invalid counter.
    InvalidParameter,
};

/// Provide the current value of a firmware counter.
///
/// Available from SBI v0.3.
pub fn readFirmwareCounter(counter_index: usize) ReadFirmwareCounterError!usize {
    return @bitCast(try ecall.oneArgsWithReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_FW_READ),
        @bitCast(counter_index),
        ReadFirmwareCounterError,
    ));
}

/// Provide the upper 32 bits of the current firmware counter value.
///
/// This function always returns zero for RV64 (or higher) systems.
///
/// Available from SBI v2.0.
pub fn readFirmwareCounterHigh(counter_index: usize) ReadFirmwareCounterError!usize {
    return @bitCast(try ecall.oneArgsWithReturnWithError(
        .PMU,
        @backingInt(PMU_FID.COUNTER_FW_READ_HI),
        @bitCast(counter_index),
        ReadFirmwareCounterError,
    ));
}

pub const SetSnapshotSharedMemory = error{
    /// The SBI PMU snapshot functionality is not available in the SBI implementation.
    NotSupported,

    /// The `flags` parameter is not zero or the `shared_memory.set.physical_low` parameter is not 4096 bytes aligned.
    InvalidParameter,

    /// The shared memory is not writable or does not satisfy other requirements.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Set and enable or clear and disable the PMU snapshot shared memory on the calling hart.
///
/// This is an optional function and the SBI implementation may choose not to implement it.
///
/// The layout of the snapshot shared memory is:
///
/// | Name                      | Offset | Size | Description |
/// | ------------------------- | ------ | ---- | ----------- |
/// | `counter_overflow_bitmap` | 0x0000 | 8    | A bitmap of all logical overflown counters relative to the
/// |                           |        |      | `counter_mask.base`. This is valid only if the `Sscofpmf` ISA
/// |                           |        |      | extension is available. Otherwise, it must be zero.
/// | `counter_values`          | 0x0008 | 512  | An array of 64-bit logical counters where each index represents
/// |                           |        |      | the value of each logical counter associated with
/// |                           |        |      | hardware/firmware relative to the `counter_mask.base`.
/// | Reserved                  | 0x0208 | 3576 | Reserved for future use
///
/// Any future revisions to this structure should be made in a backward compatible manner and will be associated
/// with an SBI version.
///
/// The logical counter indicies in the `counter_overflow_bitmap` and `counter_values` array are relative w.r.t to
/// `counter_mask.base` argument present in the `stopCounters` and `startCounters` functions.
/// This allows the users to use snapshot feature for more than `XLEN` counters if required.
///
/// This function should be invoked only once per hart at boot time.
///
/// Once configured, the SBI implementation has read/write access to the shared memory when `stopCounters` is
/// invoked with the `StopFlags.take_snapshot` flag `true`.
///
/// The SBI implementation has read only access when `startCounters` is invoked with the `StartMode.init_snapshot`.
///
/// The SBI implementation must not access this memory any other time.
///
/// Available from SBI v2.0.
pub fn setSnapshotSharedMemory(
    shared_memory: SnapshotSharedMemory,
    flags: SnapshotFlags,
) SetSnapshotSharedMemory!void {
    const physical_address_low, const physical_address_high = shared_memory.toRaw();

    try ecall.threeArgsNoReturnWithError(
        .PMU,
        @backingInt(PMU_FID.SNAPSHOT_SET_SHMEM),
        @bitCast(physical_address_low),
        @bitCast(physical_address_high),
        @bitCast(flags),
        SetSnapshotSharedMemory,
    );
}

pub const GetEventInfoError = error{
    /// The SBI PMU event info retrieval function is not available in the SBI implementation.
    NotSupported,

    /// The `flags` parameter is not zero or the `shared_memory.physical_address_low` parameter is not 16-bytes
    /// aligned or `event_index` value doesn’t conform with the encodings defined in the specification.
    InvalidParameter,

    /// The shared memory is not writable or does not satisfy other requirements.
    InvalidAddress,

    /// The write failed for unspecified or unknown other reasons.
    Failed,
};

/// Get details about any PMU event via shared memory.
///
/// The supervisor software can get event specific information for multiple events in one shot by writing an entry
/// for each event in the shared memory.
///
/// Each entry in the shared memory must be encoded as per the `EventInfo` structure.
///
/// The SBI implementation MUST NOT touch the shared memory once this call returns as supervisor software may free
/// the memory at any time.
///
/// Available from SBI v3.0.
pub fn getEventInfo(shared_memory: EventInfoSharedMemory, flags: EventInfoFlags) GetEventInfoError!void {
    try ecall.fourArgsNoReturnWithError(
        .PMU,
        @backingInt(PMU_FID.EVENT_GET_INFO),
        @bitCast(shared_memory.num_entries),
        @bitCast(shared_memory.physical_address_low),
        @bitCast(shared_memory.physical_address_high),
        @bitCast(flags),
        GetEventInfoError,
    );
}

pub const EventInfo = packed struct(u128) {
    event_index: Event.Index,

    /// Reserved for the future purpose.
    /// Must be zero.
    _reserved1: u12 = 0,

    /// Indicate `event_index` is supported or not.
    ///
    /// The SBI implmenentation MUST update this entire 32-bit word if valid `event_index` and `event_data`
    /// (if applicable) are specified in the entry.
    supported: bool,

    /// Reserved for the future purpose.
    /// Must be zero.
    _reserved2: u31 = 0,

    /// Valid when `event_index.type` is either `hardware_raw`, `hardware_raw_v2` or`firmware`.
    ///
    /// It describes the `event_data` for the specific event specified in `event_index` if applicable.
    event_data: u64,
};

pub const EventInfoSharedMemory = struct {
    /// The size of the share memory must be (`16 * num_entries`) bytes.
    num_entries: usize,

    /// MUST be 16-byte aligned
    physical_address_low: usize,
    physical_address_high: usize,
};

pub const EventInfoFlags = packed struct(usize) {
    _: usize = 0,
};

pub const SnapshotSharedMemory = union(enum) {
    clear,
    /// The size of the snapshot shared memory must be 4096 bytes.
    set: struct {
        /// Specifies the lower XLEN bits of the snapshot shared memory physical base address.
        ///
        /// MUST be 4096 bytes (i.e. page) aligned
        physical_address_low: usize,
        /// Specifies the upper XLEN bits of the snapshot shared memory physical base address.
        physical_address_high: usize,
    },

    fn toRaw(self: SnapshotSharedMemory) struct { usize, usize } {
        return switch (self) {
            .clear => .{ 0, 0 },
            .set => |set| .{ set.physical_address_low, set.physical_address_high },
        };
    }
};

pub const SnapshotFlags = packed struct(usize) {
    _: usize = 0,
};

pub const CounterMask = struct {
    base: usize,
    mask: usize,
};

pub const Event = union(Type) {
    /// Hardware general events
    hardware: Hardware,

    /// Hardware cache events
    hardware_cache: HardwareCache,

    /// Hardware raw events
    ///
    /// On RISC-V platforms with 32 bits wide `mhpmeventX` CSRs, this is the 32-bit value to to be programmed in the
    /// `mhpmeventX` CSR.
    ///
    /// On RISC-V platforms with 64 bits wide `mhpmeventX` CSRs, this is the 48-bit value to be programmed in the
    /// lower 48-bits of `mhpmeventX` CSR and the SBI implementation shall determine the value to be programmed in
    /// the upper 16 bits of `mhpmeventX` CSR.
    ///
    /// **Deprecated in favor of `hardware_raw_v2`**
    hardware_raw: if (is_64) u48 else u32,

    /// Hardware raw events v2
    ///
    /// On RISC-V platforms with 32 bits wide `mhpmeventX` CSRs, this is the 32-bit value to to be programmed in the
    /// `mhpmeventX` CSR.
    ///
    /// On RISC-V platforms with 64 bits wide `mhpmeventX` CSRs, this is the 58-bit value be programmed in the lower
    /// 58-bits of `mhpmeventX` CSR and the SBI implementation shall determine the value to be programmed in the
    /// upper 6 bits of `mhpmeventX` CSR based on privilege specification definition.
    hardware_raw_v2: if (is_64) u58 else u32,

    /// Firmware events
    firmware: Firmware,

    pub const Type = enum(u4) {
        hardware = 0,
        hardware_cache = 1,
        hardware_raw = 2,
        hardware_raw_v2 = 3,
        firmware = 15,
    };

    const Index = packed struct(u20) {
        code: u16,
        type: Type,
    };

    pub const Hardware = enum(u16) {
        /// Event for each CPU cycle
        ///
        /// Counts CPU clock cycles as counted by the `cycle` CSR.
        /// These may be variable frequency cycles, and are not counted when the CPU clock is halted.
        cpu_cycles = 1,

        /// Event for each completed instruction
        instructions = 2,

        /// Event for cache hit
        cache_references = 3,

        /// Event for cache miss
        cache_misses = 4,

        /// Event for a branch instruction
        branch_instructions = 5,

        /// Event for a branch misprediction
        branch_misses = 6,

        /// Event for each BUS cycle
        bus_cycles = 7,

        /// Event for a stalled cycle in microarchitecture frontend
        stalled_cycles_frontend = 8,

        /// Event for a stalled cycle in microarchitecture backend
        stalled_cycles_backend = 9,

        /// Event for each reference CPU cycle
        ///
        /// Counts fixed-frequency clock cycles while the CPU clock is not halted.
        /// The fixed-frequency of counting might, for example, be the same frequency at which the `time` CSR counts.
        ref_cpu_cycles = 10,
    };

    pub const HardwareCache = packed struct(u16) {
        result_id: ResultId,
        op_id: OpId,
        cache_id: CacheId,

        pub const ResultId = enum(u1) {
            /// Cache access
            access = 0,

            /// Cache miss
            miss = 1,
        };

        pub const OpId = enum(u2) {
            /// Read cache line
            read = 0,

            /// Write cache line
            write = 1,

            /// Prefetch cache line
            prefetch = 2,
        };

        pub const CacheId = enum(u13) {
            /// Level1 data cache event
            l1d = 0,

            /// Level1 instruction cache event
            l1i = 1,

            /// Last level cache event
            ll = 2,

            /// Data TLB event
            dtlb = 3,

            /// Instruction TLB event
            itlb = 4,

            /// Branch predictor unit event
            bpu = 5,

            /// NUMA node cache event
            node = 6,
        };
    };

    pub const Firmware = union(FirmwareType) {
        /// Misaligned load trap event
        misaligned_load,

        /// Misaligned store trap event
        misaligned_store,

        /// Load access trap event
        access_load,

        /// Store access trap event
        access_store,

        /// Illegal instruction trap event
        illegal_instruction,

        /// Set timer event
        set_timer,

        /// Sent IPI to other hart event
        ipi_sent,

        /// Received IPI from other hart event
        ipi_received,

        ///  Sent FENCE.I request to other hart event
        fence_i_sent,

        /// Received FENCE.I request from other hart event
        fence_i_received,

        /// Sent SFENCE.VMA request to other hart event
        sfence_vma_sent,

        /// Received SFENCE.VMA request fromother hart event
        sfence_vma_received,

        /// Sent SFENCE.VMA with ASID request to other hart event
        sfence_vma_asid_sent,

        /// Received SFENCE.VMA with ASID request from other hart event
        sfence_vma_asid_received,

        /// Sent HFENCE.GVMA request to other hart event
        hfence_gvma_sent,

        /// Received HFENCE.GVMA request from other hart event
        hfence_gvma_received,

        /// Sent HFENCE.GVMA with VMID request to other hart event
        hfence_gvma_vmid_sent,

        /// Received HFENCE.GVMA with VMID request from other hart event
        hfence_gvma_vmid_received,

        /// Sent HFENCE.VVMA request to other hart event
        hfence_vvma_sent,

        /// Received HFENCE.VVMA request from other hart event
        hfence_vvma_received,

        /// Sent HFENCE.VVMA with ASID request to other hart event
        hfence_vvma_asid_sent,

        /// Received HFENCE.VVMA with ASID request from other hart event
        hfence_vvma_asid_received,

        /// SBI implementation specific firmware events
        ///
        /// Valid values are between 256 and 65534, invalid values will overlap with other events.
        implementation_specific: u16,

        /// RISC-V platform specific firmware events
        platform: u64,

        pub const FirmwareType = enum(u16) {
            misaligned_load = 0,
            misaligned_store = 1,
            access_load = 2,
            access_store = 3,
            illegal_instruction = 4,
            set_timer = 5,
            ipi_sent = 6,
            ipi_received = 7,
            fence_i_sent = 8,
            fence_i_received = 9,
            sfence_vma_sent = 10,
            sfence_vma_received = 11,
            sfence_vma_asid_sent = 12,
            sfence_vma_asid_received = 13,
            hfence_gvma_sent = 14,
            hfence_gvma_received = 15,
            hfence_gvma_vmid_sent = 16,
            hfence_gvma_vmid_received = 17,
            hfence_vvma_sent = 18,
            hfence_vvma_received = 19,
            hfence_vvma_asid_sent = 20,
            hfence_vvma_asid_received = 21,

            implementation_specific = 256,

            platform = 65535,
        };
    };

    fn toRaw(self: Event) Raw {
        return switch (self) {
            .hardware => |hardware| .{
                .event_index = .{
                    .code = @backingInt(hardware),
                    .type = .hardware,
                },
                .event_data = 0,
            },
            .hardware_cache => |hardware_cache| .{
                .event_index = .{
                    .code = @bitCast(hardware_cache),
                    .type = .hardware_cache,
                },
                .event_data = 0,
            },
            .hardware_raw => |hardware_raw| .{
                .event_index = .{
                    .code = 0,
                    .type = .hardware_raw,
                },
                .event_data = hardware_raw,
            },
            .hardware_raw_v2 => |hardware_raw_v2| .{
                .event_index = .{
                    .code = 0,
                    .type = .hardware_raw_v2,
                },
                .event_data = hardware_raw_v2,
            },
            .firmware => |firmware| switch (firmware) {
                .platform => |platform| .{
                    .event_index = .{
                        .code = @backingInt(firmware),
                        .type = .firmware,
                    },
                    .event_data = platform,
                },
                .implementation_specific => |implementation_specific| .{
                    .event_index = .{
                        .code = implementation_specific,
                        .type = .firmware,
                    },
                    .event_data = 0,
                },
                else => .{
                    .event_index = .{
                        .code = @backingInt(firmware),
                        .type = .firmware,
                    },
                    .event_data = 0,
                },
            },
        };
    }

    const Raw = struct {
        event_index: Index,

        _: if (is_64) u44 else u12 = 0,

        event_data: u64,
    };
};

pub const ConfigFlags = packed struct(usize) {
    /// Skip the counter matching
    ///
    /// If `true` the SBI implementation will unconditionally select the first counter from the set of counters
    /// specified by the `counter_base` and `counter_mask` parameters.
    skip_match: bool = false,

    /// Clear (or zero) the counter value in counter configuration
    clear_value: bool = false,

    /// Start the counter after configuring a matching counter
    ///
    /// Has no impact on counter value.
    auto_start: bool = false,

    /// Event counting inhibited in VU-mode
    ///
    /// Event filtering hint and can be ignored or overridden by the SBI implementation for security concerns or due
    /// to lack of event filtering support in the underlying RISC-V platform.
    set_vuinh: bool = false,

    /// Event counting inhibited in VS-mode
    ///
    /// Event filtering hint and can be ignored or overridden by the SBI implementation for security concerns or due
    /// to lack of event filtering support in the underlying RISC-V platform.
    set_vsinh: bool = false,

    /// Event counting inhibited in U-mode
    ///
    /// Event filtering hint and can be ignored or overridden by the SBI implementation for security concerns or due
    /// to lack of event filtering support in the underlying RISC-V platform.
    set_uinh: bool = false,

    /// Event counting inhibited in S-mode
    ///
    /// Event filtering hint and can be ignored or overridden by the SBI implementation for security concerns or due
    /// to lack of event filtering support in the underlying RISC-V platform.
    set_sinh: bool = false,

    /// Event counting inhibited in M-mode
    ///
    /// Event filtering hint and can be ignored or overridden by the SBI implementation for security concerns or due
    /// to lack of event filtering support in the underlying RISC-V platform.
    set_minh: bool = false,

    _: if (is_64) u56 else u24 = 0,
};

pub const StartMode = union(enum) {
    /// The counter value will not be modified and the event counting will start from the current counter value.
    none,

    /// Set the value of the counters to this value.
    init_value: u64,

    /// Initialize the given counters from shared memory if available.
    ///
    /// The shared memory address must be set during boot via sbi_pmu_snapshot_set_shmem before the this may be used.
    ///
    /// The SBI implementation must initialize all the given valid counters (to be started) from the value set in
    /// the shared snapshot memory.
    init_snapshot,

    fn initialValue(self: StartMode) u64 {
        return switch (self) {
            .init_value => |value| value,
            else => 0,
        };
    }

    fn toRaw(self: StartMode) Raw {
        return switch (self) {
            .none => .{
                .init_value = false,
                .init_snapshot = false,
            },
            .init_value => .{
                .init_value = true,
                .init_snapshot = false,
            },
            .init_snapshot => .{
                .init_value = false,
                .init_snapshot = true,
            },
        };
    }

    const Raw = packed struct(usize) {
        init_value: bool,
        init_snapshot: bool,
        _: if (is_64) u62 else u30 = 0,
    };
};

pub const StopFlags = packed struct(usize) {
    /// Reset the counter to event mapping.
    reset: bool = false,

    /// Save a snapshot of the given counter’s values in the shared memory if available.
    ///
    /// The shared memory address must be set during boot via sbi_pmu_snapshot_set_shmem before the this may be used.
    ///
    /// The SBI implementation must save the current value of all the stopped counters in the shared memory if this
    /// is `true`.
    ///
    /// The values corresponding to all other counters must not be modified.
    ///
    /// The SBI implementation must additionally update the overflown counter bitmap in the shared memory.
    take_snapshot: bool = false,

    _: if (is_64) u62 else u30 = 0,
};

pub const CounterInfo = union(Type) {
    hardware: Hardware,
    firmware,

    pub const Hardware = struct {
        csr: u12,

        /// Width (One less than number of bits in CSR)
        width: u6,
    };

    pub const Type = enum(u1) {
        hardware = 0,
        firmware = 1,
    };

    const Raw = packed struct(usize) {
        csr: u12,
        width: u6,
        _: if (is_64) u45 else u13,
        type: Type,
    };
};

const PMU_FID = enum(i32) {
    NUM_COUNTERS = 0x0,
    COUNTER_GET_INFO = 0x1,
    COUNTER_CFG_MATCH = 0x2,
    COUNTER_START = 0x3,
    COUNTER_STOP = 0x4,
    COUNTER_FW_READ = 0x5,
    COUNTER_FW_READ_HI = 0x6,
    SNAPSHOT_SET_SHMEM = 0x7,
    EVENT_GET_INFO = 0x8,
};
