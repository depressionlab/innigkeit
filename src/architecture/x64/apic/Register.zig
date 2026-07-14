const core = @import("core");
const std = @import("std");

pub const Register = enum(u32) {
    /// Local APIC ID Register
    ///
    /// Read only
    id = 0x2,

    /// Local APIC Version Register
    ///
    /// Read only
    version = 0x3,

    /// Task Priority Register (TPR)
    ///
    /// Read/Write
    task_priority = 0x8,

    /// Arbitration Priority Register (APR)
    ///
    /// Read Only
    arbitration_priority = 0x9,

    /// Processor Priority Register (PPR)
    ///
    /// Read Only
    processor_priority = 0xA,

    /// EOI Register
    ///
    /// Write Only
    eoi = 0xB,

    /// Remote Read Register (RRD)
    ///
    /// Read Only
    remote_read = 0xC,

    /// Logical Destination Register
    ///
    /// Read/Write
    logical_destination = 0xD,

    /// Destination Format Register
    ///
    /// Read/Write
    destination_format = 0xE,

    /// Spurious Interrupt Vector Register
    ///
    /// Read/Write
    spurious_interrupt = 0xF,

    /// In-Service Register (ISR); bits 31:0
    ///
    /// Read Only
    in_service_31_0 = 0x10,

    /// In-Service Register (ISR); bits 63:32
    ///
    /// Read Only
    in_service_63_32 = 0x11,

    /// In-Service Register (ISR); bits 95:64
    ///
    /// Read Only
    in_service_95_64 = 0x12,

    /// In-Service Register (ISR); bits 127:96
    ///
    /// Read Only
    in_service_127_96 = 0x13,

    /// In-Service Register (ISR); bits 159:128
    ///
    /// Read Only
    in_service_159_128 = 0x14,

    /// In-Service Register (ISR); bits 191:160
    ///
    /// Read Only
    in_service_191_160 = 0x15,

    /// In-Service Register (ISR); bits 223:192
    ///
    /// Read Only
    in_service_223_192 = 0x16,

    /// In-Service Register (ISR); bits 255:224
    ///
    /// Read Only
    in_service_255_224 = 0x17,

    /// Trigger Mode Register (TMR); bits 31:0
    ///
    /// Read Only
    trigger_mode_31_0 = 0x18,

    /// Trigger Mode Register (TMR); bits 63:32
    ///
    /// Read Only
    trigger_mode_63_32 = 0x19,

    /// Trigger Mode Register (TMR); bits 95:64
    ///
    /// Read Only
    trigger_mode_95_64 = 0x1A,

    /// Trigger Mode Register (TMR); bits 127:96
    ///
    /// Read Only
    trigger_mode_127_96 = 0x1B,

    /// Trigger Mode Register (TMR); bits 159:128
    ///
    /// Read Only
    trigger_mode_159_128 = 0x1C,

    /// Trigger Mode Register (TMR); bits 191:160
    ///
    /// Read Only
    trigger_mode_191_160 = 0x1D,

    /// Trigger Mode Register (TMR); bits 223:192
    ///
    /// Read Only
    trigger_mode_223_192 = 0x1E,

    /// Trigger Mode Register (TMR); bits 255:224
    ///
    /// Read Only
    trigger_mode_255_224 = 0x1F,

    /// Interrupt Request Register (IRR); bits 31:0
    ///
    /// Read Only
    interrupt_request_31_0 = 0x20,

    /// Interrupt Request Register (IRR); bits 63:32
    ///
    /// Read Only
    interrupt_request_63_32 = 0x21,

    /// Interrupt Request Register (IRR); bits 95:64
    ///
    /// Read Only
    interrupt_request_95_64 = 0x22,

    /// Interrupt Request Register (IRR); bits 127:96
    ///
    /// Read Only
    interrupt_request_127_96 = 0x23,

    /// Interrupt Request Register (IRR); bits 159:128
    ///
    /// Read Only
    interrupt_request_159_128 = 0x24,

    /// Interrupt Request Register (IRR); bits 191:160
    ///
    /// Read Only
    interrupt_request_191_160 = 0x25,

    /// Interrupt Request Register (IRR); bits 223:192
    ///
    /// Read Only
    interrupt_request_223_192 = 0x26,

    /// Interrupt Request Register (IRR); bits 255:224
    ///
    /// Read Only
    interrupt_request_255_224 = 0x27,

    /// Error Status Register
    ///
    /// Read Only
    error_status = 0x28,

    /// LVT Corrected Machine Check Interrupt (CMCI) Register
    ///
    /// Read/Write
    corrected_machine_check = 0x2F,

    /// Interrupt Command Register (ICR); bits 0-31
    ///
    /// In x2APIC mode this is a single 64-bit register.
    ///
    /// Read/Write
    interrupt_command_0_31 = 0x30,

    /// Interrupt Command Register (ICR); bits 32-63
    ///
    /// Not available in x2APIC mode, `interrupt_command_0_31` is the full 64-bit register.
    ///
    /// Read/Write
    interrupt_command_32_63 = 0x31,

    /// LVT Timer Register
    ///
    /// Read/Write
    lvt_timer = 0x32,

    /// LVT Thermal Sensor Register
    ///
    /// Read/Write
    lvt_thermal_sensor = 0x33,

    /// LVT Performance Monitoring Counters Register
    ///
    /// Read/Write
    lvt_performance_monitoring = 0x34,

    /// LVT LINT0 Register
    ///
    /// Read/Write
    lint0 = 0x35,

    /// LVT LINT1 Register
    ///
    /// Read/Write
    lint1 = 0x36,

    /// LVT Error Register
    ///
    /// Read/Write
    lvt_error = 0x37,

    /// Initial Count Register (for Timer)
    ///
    /// Read/Write
    initial_count = 0x38,

    /// Current Count Register (for Timer)
    ///
    /// Read Only
    current_count = 0x39,

    /// Divide Configuration Register (for Timer)
    ///
    /// Read/Write
    divide_configuration = 0x3E,

    /// Self IPI Register
    ///
    /// Only usable in x2APIC mode
    ///
    /// Write Only
    lapic_ipi = 0x3F,

    /// Acquire the offset of this register from the base address of the APIC.
    ///
    /// Does not support the `self_ipi` register as it is not supported in xAPIC mode.
    pub fn xapicOffset(register: Register) usize {
        if (core.is_debug) std.debug.assert(register != .lapic_ipi); // not supported in xAPIC mode

        return @intFromEnum(register) * 0x10;
    }

    /// Acquire the MSR number of this register.
    ///
    /// Does not support the below registers as they not supported in x2APIC mode:
    ///  - `destination_format`
    ///  - `arbitration_priority`
    ///  - `remote_read`
    ///  - `interrupt_command_32_63`
    pub fn x2apicRegister(register: Register) u32 {
        if (core.is_debug) {
            std.debug.assert(register != .destination_format); // not supported in x2APIC mode
            std.debug.assert(register != .arbitration_priority); // not supported in x2APIC mode
            std.debug.assert(register != .remote_read); // not supported in x2APIC mode
            std.debug.assert(register != .interrupt_command_32_63); // not supported in x2APIC mode
        }

        return 0x800 + @intFromEnum(register);
    }

    pub const register_space_size: core.Size = .from(4, .kib);
};
