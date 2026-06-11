const architecture = @import("architecture");
const Handler = architecture.interrupts.Interrupt.Handler;
const x64 = @import("../x64.zig");
const interrupt_handlers = @import("handlers.zig");
const globals = @import("globals.zig");

const log = @import("innigkeit").debug.log.scoped(.interrupt);

pub const Interrupt = enum(u8) {
    divide = 0,
    debug = 1,
    non_maskable_interrupt = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_fault = 12,
    general_protection = 13,
    page_fault = 14,
    _reserved1 = 15,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,
    _reserved2 = 22,
    _reserved3 = 23,
    _reserved4 = 24,
    _reserved5 = 25,
    _reserved6 = 26,
    _reserved7 = 27,
    hypervisor_injection = 28,
    vmm_communication = 29,
    security = 30,
    _reserved8 = 31,

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

    flush_request = 254,
    spurious_interrupt = 255,

    _,

    pub const first_available_interrupt = @intFromEnum(Interrupt.per_executor_periodic) + 1;
    pub const last_available_interrupt = @intFromEnum(Interrupt.flush_request) - 1;

    /// Checks if the given interrupt vector pushes an error code.
    pub fn hasErrorCode(vector: Interrupt) bool {
        return switch (@intFromEnum(vector)) {
            // Exceptions
            0x00...0x07 => false,
            0x08 => true,
            0x09 => false,
            0x0A...0x0E => true,
            0x0F...0x10 => false,
            0x11 => true,
            0x12...0x14 => false,
            //0x15 ... 0x1D => unreachable,
            0x1E => true,
            //0x1F          => unreachable,

            // Other interrupts
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

    pub fn allocate(
        interrupt_handler: Handler,
    ) architecture.interrupts.Interrupt.AllocateError!Interrupt {
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
