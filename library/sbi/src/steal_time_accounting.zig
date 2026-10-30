//! SBI implementations may encounter situations where virtual harts are ready to run, but must be withheld from running.
//! These situations may be, for example, when multiple SBI domains share processors or when an SBI implementation is a
//! hypervisor and guest contexts share processors with other guest contexts or host tasks.
//!
//! When virtual harts are at times withheld from running, observers within the contexts of the virtual harts may need a
//! way to account for less progress than would otherwise be expected. The time a virtual hart was ready, but had to
//! wait, is called "stolen time" and the tracking of it is referred to as steal-time accounting.
//!
//! The Steal-time Accounting (STA) extension defines the mechanism in which an SBI implementation provides steal-time
//! and preemption information, for each virtual hart, to supervisor-mode software.
const base = @import("base.zig");
const ecall = @import("ecall.zig");
const std = @import("std");

pub fn available() bool {
    return base.probeExtension(.STA);
}

pub const SetSharedMemoryError = error{
    /// The `flags` parameter is not zero or `shared_memory.phycial_address_low` is not 64-byte aligned.
    InvalidParameter,

    /// The shared memory is not writable or does not satisfy other requirements.
    InvalidAddress,

    /// The request failed for unspecified or unknown other reasons.
    Failed,
};

/// Set or disable the shared memory physical base address for steal-time accounting of the calling virtual hart and
/// enable the SBI implementation’s steal-time information reporting.
///
///  The SBI implementation MUST zero the first 64 bytes of the shared memory before returning from the SBI call.
///
/// It is not expected for the shared memory to be written by the supervisor-mode software while it is in use for
/// steal-time accounting. However, the SBI implementation MUST not misbehave if a write from supervisor-mode
/// software occurs, however, in that case, it MAY leave the shared memory filled with inconsistent data.
///
/// The SBI implementation MUST stop writing to the shared memory when the supervisor-mode software is not runnable,
/// such as upon system reset or system suspend.
///
/// The layout of shared memory isencoded as per the `StealTimeMemory` structure.
///
/// Available from SBI v2.0.
pub fn setSharedMemory(shared_memory: SharedMemory, flags: SharedMemoryFlags) SetSharedMemoryError!void {
    const physical_address_low, const physical_address_high = shared_memory.toRaw();

    try ecall.threeArgsNoReturnWithError(
        .STA,
        @backingInt(STA_FID.SET_SHMEM),
        @bitCast(physical_address_low),
        @bitCast(physical_address_high),
        @bitCast(flags),
        SetSharedMemoryError,
    );
}

pub const StealTimeMemory = extern struct {
    /// The SBI implementation MUST increment this field to an odd value before writing the steal field, and
    /// increment it again to an even value after writing steal (i.e. an odd sequence number indicates an
    /// in-progress update).
    ///
    /// The SBI implementation SHOULD ensure that the sequence field remains odd for only very short periods of time.
    ///
    /// The supervisor-mode software MUST check this field before and after reading the steal field, and repeat the
    /// read if it is different or odd.
    ///
    /// This sequence field enables the value of the steal field to be read by supervisor-mode software executing
    /// in a 32-bit environment.
    sequence: u32,

    /// Always zero.
    ///
    /// Future extensions of the SBI call might allow the supervisor-mode software to write to some of the fields of
    /// the shared memory. Such extensions will not be enabled as long as a zero value is used for the flags
    /// argument to the SBI call.
    flags: u32,

    /// The amount of time in which this virtual hart was not idle and scheduled out, in nanoseconds.
    ///
    /// The time during which the virtual hart is idle will not be reported as steal-time.
    steal: u64,

    /// An advisory flag indicating whether the virtual hart which registered this structure is running or not.
    ///
    /// A non-zero value MAY be written by the SBI implementation if the virtual hart has been preempted (i.e. while
    /// the steal field is increasing), while a zero value MUST be written before the virtual hart starts to run
    /// again.
    ///
    /// This preempted field can, for example, be used by the supervisor-mode software to check if a lock holder has
    /// been preempted, and, in that case, disable optimistic spinning.
    preempted: u8,

    pad: [47]u8,

    comptime {
        std.debug.assert(@sizeOf(StealTimeMemory) == 64);
    }
};

pub const SharedMemory = union(enum) {
    disable,
    /// The size of the shared memory must be at least 64 bytes.
    enable: struct {
        /// MUST be 64-byte aligned.
        physical_address_low: usize,
        physical_address_high: usize,
    },

    fn toRaw(self: SharedMemory) struct { usize, usize } {
        return switch (self) {
            .disable => .{ 0, 0 },
            .enable => |enable| .{ enable.physical_address_low, enable.physical_address_high },
        };
    }
};

pub const SharedMemoryFlags = packed struct(usize) {
    _: usize = 0,
};

const STA_FID = enum(i32) {
    SET_SHMEM = 0x0,
};
