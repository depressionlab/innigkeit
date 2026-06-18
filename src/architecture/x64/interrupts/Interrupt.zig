const architecture = @import("architecture");
const Handler = architecture.interrupts.Interrupt.Handler;
const x64 = @import("../x64.zig");
const interrupt_handlers = @import("handlers.zig");
const globals = @import("globals.zig");

const log = @import("innigkeit").debug.log.scoped(.interrupt);

pub const Interrupt = enum(u8) {
    // Reserved x64 Interrupts (0-32)

    /// ## Division Error (#DE)
    ///
    /// - Type: Fault
    /// - Vector: `0 (0x0)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Division_Error
    division_error = 0,

    /// ## Debug (#DB)
    ///
    /// - Type: Fault/Trap
    /// - Vector: `1 (0x1)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Debug
    debug = 1,

    /// ## Non-maskable Interrupt (-)
    ///
    /// - Type: Interrupt
    /// - Vector: `2 (0x2)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Non_Maskable_Interrupt
    non_maskable_interrupt = 2,

    /// ## Breakpoint (#BP)
    ///
    /// - Type: Trap
    /// - Vector: `3 (0x3)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Breakpoint
    breakpoint = 3,

    /// ## Ovwerflow (#OF)
    ///
    /// - Type: Trap
    /// - Vector: `4 (0x4)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Overflow
    overflow = 4,

    /// ## Bound Range Exceeded (#BR)
    ///
    /// - Type: Fault
    /// - Vector: `5 (0x5)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Bound_Range_Exceeded
    bound_range_exceeded = 5,

    /// ## Invalid Opcode (#UD)
    ///
    /// - Type: Fault
    /// - Vector: `6 (0x6)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Invalid_Opcode
    invalid_opcode = 6,

    /// ## Device Not Available (#NM)
    ///
    /// - Type: Fault
    /// - Vector: `7 (0x7)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Device_Not_Available
    device_not_available = 7,

    /// ## Double Fault (#DF)
    ///
    /// - Type: Abort
    /// - Vector: `8 (0x8)`
    /// - Error code: Yes (zero)
    ///
    /// https://wiki.osdev.org/Exceptions#Double_Fault
    double_fault = 8,

    /// ## Coprocessor Segment Overrun (-)
    ///
    /// - Type: Fault
    /// - Vector: `9 (0x9)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Coprocessor_Segment_Overrun
    coprocessor_segment_overrun = 9,

    /// ## Invalid TSS (#TS)
    ///
    /// - Type: Fault
    /// - Vector: `10 (0xA)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Invalid_TSS
    invalid_tss = 10,

    /// ## Segment Not Present (#NP)
    ///
    /// - Type: Fault
    /// - Vector: `11 (0xB)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Segment_Not_Present
    segment_not_present = 11,

    /// ## Stack-Segment Fault (#SS)
    ///
    /// - Type: Fault
    /// - Vector: `12 (0xC)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Stack-Segment_Fault
    stack_segment_fault = 12,

    /// ## General Protection Fault (#GP)
    ///
    /// - Type: Fault
    /// - Vector: `13 (0xD)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#General_Protection_Fault
    general_protection_fault = 13,

    /// ## Page Fault (#PF)
    ///
    /// - Type: Fault
    /// - Vector: `14 (0xE)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Page_Fault
    page_fault = 14,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `15 (0xF)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved1 = 15,

    /// ## x87 Floating-Point Exception (#MF)
    ///
    /// - Type: Fault
    /// - Vector: `16 (0x10)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#x87_Floating-Point_Exception
    x87_floating_point = 16,

    /// ## Alignment Check (#AC)
    ///
    /// - Type: Fault
    /// - Vector: `17 (0x11)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Alignment_Check
    alignment_check = 17,

    /// ## Machine Check (#MC)
    ///
    /// - Type: Abort
    /// - Vector: `18 (0x12)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Machine_Check
    machine_check = 18,

    /// ## SIMD Floating-Point Exception (#XM/#XF)
    ///
    /// - Type: Trap
    /// - Vector: `19 (0x13)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#SIMD_Floating-Point_Exception
    simd_floating_point = 19,

    /// ## Virtualization Exception (#VE)
    ///
    /// - Type: Fault
    /// - Vector: `20 (0x14)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Virtualization_Exception
    virtualization = 20,

    /// ## Control Protection Exception (#CP)
    ///
    /// - Type: Fault
    /// - Vector: `21 (0x15)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Control_Protection_Exception
    control_protection = 21,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `22 (0x16)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved2 = 22,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `23 (0x17)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved3 = 23,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `24 (0x18)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved4 = 24,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `25 (0x19)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved5 = 25,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `26 (0x1A)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved6 = 26,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `27 (0x1B)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved7 = 27,

    /// ## Hypervisor Injection Exception (#HV)
    ///
    /// - Type: Fault
    /// - Vector: `28 (0x1C)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions#Hypervisor_Injection_Exception
    hypervisor_injection = 28,

    /// ## VMM Communication Exception (#VC)
    ///
    /// - Type: Fault
    /// - Vector: `29 (0x1D)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#VMM_Communication_Exception
    vmm_communication = 29,

    /// ## Security Exception (#SX)
    ///
    /// - Type: Fault
    /// - Vector: `30 (0x1E)`
    /// - Error code: Yes
    ///
    /// https://wiki.osdev.org/Exceptions#Security_Exception
    security = 30,

    /// ## Reserved (-)
    ///
    /// - Type: -
    /// - Vector: `31 (0x1F)`
    /// - Error code: No
    ///
    /// https://wiki.osdev.org/Exceptions
    _reserved8 = 31,

    // Remapped PIC
    pic_pit = 32,
    pic_keyboard = 33,
    pic_cascade = 34,
    pic_com2 = 35,
    pic_com1 = 36,
    pic_lpt2 = 37,
    pic_floppy = 38,
    pic_lpt1 = 39,
    pic_rtc = 40,
    pic_free1 = 41,
    pic_free2 = 42,
    pic_free3 = 43,
    pic_ps2mouse = 44,
    pic_fpu = 45,
    pic_primary_ata = 46,
    pic_secondary_ata = 47,

    per_executor_periodic = 48,

    // Interrupts (253-255): x64 supports up to 256 interrupt vectors
    reschedule = 253,
    flush_request = 254,
    spurious_interrupt = 255,

    _,

    pub const first_available_interrupt = @intFromEnum(Interrupt.per_executor_periodic) + 1;
    pub const last_available_interrupt = @intFromEnum(Interrupt.reschedule) - 1;

    /// Checks if the given interrupt vector pushes an error code.
    pub fn hasErrorCode(vector: Interrupt) bool {
        return switch (@intFromEnum(vector)) {
            0...7 => false,
            8 => true,
            9 => false,
            10...14 => true,
            15...16 => false,
            17 => true,
            18...20 => false,
            21...29 => unreachable,
            30 => true,
            31 => unreachable,
            else => false,
        };
    }

    /// Checks if the given interrupt vector is an exception.
    pub fn isException(vector: Interrupt) bool {
        if (@intFromEnum(vector) <= @intFromEnum(Interrupt._reserved8)) {
            return vector != Interrupt.non_maskable_interrupt;
        }
        return false;
    }

    pub fn allocate(interrupt_handler: Handler) architecture.interrupts.Interrupt.AllocateError!Interrupt {
        const allocation = globals.interrupt_arena.allocate(1, .instant_fit) catch {
            return error.InterruptAllocationFailed;
        };

        const interrupt_number: u8 = @intCast(allocation.base);

        globals.handlers[interrupt_number] = interrupt_handler;
        x64.instructions.mfence();

        const interrupt: Interrupt = @enumFromInt(interrupt_number);
        log.debug("allocated interrupt {}", .{interrupt});

        return interrupt;
    }

    pub fn deallocate(interrupt: Interrupt) void {
        log.debug("deallocating interrupt {}", .{interrupt});

        const interrupt_number = @intFromEnum(interrupt);

        globals.handlers[interrupt_number] = .{
            .eoi = .after,
            .call = .prepare(interrupt_handlers.unhandledInterrupt, .{}),
        };
        x64.instructions.mfence();

        globals.interrupt_arena.deallocate(.{ .base = interrupt_number, .len = 1 });
    }

    pub fn route(interrupt: Interrupt, external_interrupt: u32) architecture.interrupts.Interrupt.RouteError!void {
        log.debug("routing interrupt {} to {}", .{ interrupt, external_interrupt });

        try x64.ioapic.routeInterrupt(@intCast(external_interrupt), interrupt);
    }

    /// Route this interrupt to a PCI INTx GSI (level-triggered, active-low),
    /// bypassing the ISA source-override defaults.
    pub fn routePci(interrupt: Interrupt, gsi: u32) architecture.interrupts.Interrupt.RouteError!void {
        log.debug("routing interrupt {} to PCI GSI {} (level/active-low)", .{ interrupt, gsi });

        try x64.ioapic.routeInterruptPci(gsi, interrupt);
    }
};
