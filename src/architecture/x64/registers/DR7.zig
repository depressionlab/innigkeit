/// Debug-Control Register (DR7)
///
/// DR7 is used to establish the breakpoint conditions for the address-breakpoint registers (DR0–DR3) and to enable
/// debug exceptions for each address-breakpoint register individually.
///
/// DR7 is also used to enable the general detect breakpoint condition.
pub const DR7 = packed struct(u64) {
    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR0) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_0: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR0) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_0: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR1) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_1: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR1) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_1: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR2) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_2: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR2) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_2: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR3) detects a breakpoint
    /// condition while executing the current task.
    ///
    /// Cleared to `false` by the processor when a hardware task-switch occurs.
    local_exact_breakpoint_3: bool,

    /// When `true` debug exceptions occur when the corresponding address-breakpoint register (DR3) detects a breakpoint
    /// condition while executing any task.
    ///
    /// These bits are never cleared to `false` by the processor.
    global_exact_breakpoint_3: bool,

    /// This bit is ignored by implementations of the AMD64 architecture.
    local_exact_breakpoint: bool,

    /// This bit is ignored by implementations of the AMD64 architecture.
    global_exact_breakpoint: bool,

    _reserved10: u1,

    _reserved11_12: u2,

    /// Software sets this to `true` to cause a debug exception to occur when an attempt is made to execute a MOV DRn
    /// instruction to any debug register (DR0–DR7).
    ///
    /// This bit is set to `false` by the processor when the #DB handler is entered, allowing the handler to read and
    /// write the DRn registers.
    ///
    /// The #DB exception occurs before executing the instruction, and `DR6.breakpoint_register_access_detected` is set
    /// to `true` by the processor.
    ///
    /// Software debuggers can use this bit to prevent the currently-executing program from interfering with the debug
    /// operation.
    general_detect: bool,

    _reserved14_15: u2,

    /// Control the breakpoint conditions used by the DR0 register.
    type_breakpoint_0: BreakpointType,
    length_breakpoint_0: Length,

    /// Control the breakpoint conditions used by the DR1 register.
    type_breakpoint_1: BreakpointType,
    length_breakpoint_1: Length,

    /// Control the breakpoint conditions used by the DR2 register.
    type_breakpoint_2: BreakpointType,
    length_breakpoint_2: Length,

    /// Control the breakpoint conditions used by the DR3 register.
    type_breakpoint_3: BreakpointType,
    length_breakpoint_3: Length,

    _reserved_32_63: u32,

    pub const BreakpointType = enum(u2) {
        /// Only on instruction execution.
        ///
        /// The `length` field for the register using this type must be set to `.byte`.
        /// Setting to any other value produces undefined results.
        instruction_execution = 0b00,

        /// Only on data write.
        data_write = 0b01,

        /// Effect depends on the value of `CR4[DE]` as follows:
        /// - `CR4[DE] = 0` - Condition is undefined.
        /// - `CR4[DE] = 1` - Only on I/O read or I/O write.
        io_read_write = 0b10,

        /// Only on data read or data write.
        read_write = 0b11,
    };

    pub const Length = enum(u2) {
        /// 1 byte.
        byte = 0b00,

        /// 2 bytes, address must be 2 byte aligned.
        word = 0b01,

        /// 4 bytes, address must be 4 byte aligned.
        dword = 0b10,

        /// 8 bytes, address must be 8 byte aligned.
        qword = 0b11,
    };

    pub fn read() DR7 {
        return @bitCast(asm ("mov %%dr7, %[value]"
            : [value] "=r" (-> u64),
        ));
    }

    pub fn write(dr7: DR7) void {
        asm volatile ("mov %[value], %%dr7"
            :
            : [value] "r" (@as(u64, @bitCast(dr7))),
        );
    }
};
