//! `ESR_EL1` (Exception Syndrome Register) decode.
//!
//! See ARM DDI0487 D17.2.37.
//!
//! TODO: Only the fields the kernel currently branches on are named;
//! everything else stays as unnamed reserved padding.

const arm = @import("arm.zig");

// TODO: does this need to be packed?
pub const EsrEl1 = packed struct(u64) {
    iss: u25,
    il: bool,
    ec: ExceptionClass,
    _reserved: u32,

    pub fn read() EsrEl1 {
        return @bitCast(arm.registers.ESR_EL1.read());
    }

    /// Reinterprets [`iss`] as the ISS encoding for a Data Abort exception.
    ///
    /// Only valid when [`ec`] is `.data_abort_lower_el` or `.data_abort_same_el`.
    pub fn dataAbort(self: EsrEl1) DataAbortIss {
        return @bitCast(self.iss);
    }

    pub const ExceptionClass = enum(u6) {
        data_abort_lower_el = 0x24,
        data_abort_same_el = 0x25,
        _,
    };
};

/// ISS encoding for an exception from a Data Abort.
///
/// Only valid when [`EsrEl1.ec`] is `.data_abort_lower_el` or `.data_abort_same_el`.
///
/// See ARM DDI0487 D17.2.37.
pub const DataAbortIss = packed struct(u25) {
    /// Data Fault Status Code. Top four bits [5:2] classify the fault
    /// (`faultClass` below); bottom two bits [1:0] are the translation-table
    /// level, not currently used.
    dfsc: u6,

    /// Write not Read: set for a write access, clear for a read.
    wnr: bool,

    /// S1PTW, CM, EA: not currently branched on.
    _reserved1: u3,

    /// FAR not Valid: when set, `FAR_EL1` does not hold the faulting
    /// address and this fault cannot be routed to `onPageFault`.
    fnv: bool,

    /// VNCR..ISV: not currently branched on.
    _reserved2: u14,

    /// Coarse classification of the fault this kernel knows how to route to
    /// `memory.onPageFault`. Access-flag faults, alignment faults, external
    /// aborts, TLB conflicts, and any other DFSC value return `.other`. the
    /// caller falls back to the diagnostic panic for those rather than guess
    /// at a mapping this kernel's fault handler doesn't actually implement.
    pub fn faultClass(self: DataAbortIss) FaultClass {
        return switch (self.dfsc >> 2) {
            0b0000, 0b0001 => .translation, // address-size or translation fault, any level
            0b0011 => .permission, // permission fault, any level
            else => .other,
        };
    }

    pub const FaultClass = enum { translation, permission, other };
};
