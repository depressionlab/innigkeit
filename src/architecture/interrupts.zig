const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const architecture = @import("architecture");

// marked as `inline` unconditionally so that it can be called from a naked function.
pub inline fn disableAndHalt() noreturn {
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "disableAndHalt",
    )();
}

pub fn areEnabled() callconv(core.inline_in_non_debug) bool {
    return architecture.getFunction(
        architecture.current_functions.interrupts,
        "areEnabled",
    )();
}

pub fn enable() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "enable",
    )();
}

pub fn disable() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "disable",
    )();
}

/// Send a panic IPI to all other executors.
///
/// Asserts interrupts are disabled.
pub fn sendPanicIPI() callconv(core.inline_in_non_debug) void {
    if (core.is_debug) std.debug.assert(!areEnabled());
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "sendPanicIPI",
    )();
}

/// Send a flush IPI to the given executor.
pub fn sendFlushIPI(executor: *innigkeit.Executor) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "sendFlushIPI",
    )(executor);
}

/// Whether the current architecture implements `sendRescheduleIPI`.
///
/// Comptime-known: on architectures without it, guarded callers compile to
/// nothing and idle executors are picked up by the periodic tick instead.
pub const reschedule_ipi_available: bool =
    architecture.current_functions.interrupts.sendRescheduleIPI != null;

/// Send a reschedule IPI to the given executor, breaking it out of its idle
/// halt so it re-checks its runqueue immediately.
///
/// Callers must check `reschedule_ipi_available` first.
pub fn sendRescheduleIPI(executor: *innigkeit.Executor) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.interrupts,
        "sendRescheduleIPI",
    )(executor);
}

/// Get the EOI type for the given external interrupt if known.
pub fn eoiType(external_interrupt: u32) callconv(core.inline_in_non_debug) ?Interrupt.Handler.EOI {
    return architecture.getFunction(
        architecture.current_functions.interrupts,
        "eoiType",
    )(external_interrupt);
}

pub const Interrupt = struct {
    arch_specific: architecture.current_decls.interrupts.Interrupt,

    pub const Handler = struct {
        eoi: EOI,
        call: Call,

        pub const EOI = enum {
            none,
            before,
            after,

            pub const edge: EOI = .before;
            pub const level: EOI = .after;
        };

        pub const Call = core.TypeErasedCall.Templated(&.{
            InterruptFrame,
            innigkeit.Task.Current.StateBeforeInterrupt,
        });
    };

    pub const AllocateError = error{InterruptAllocationFailed};

    pub fn allocate(handler: Handler) callconv(core.inline_in_non_debug) AllocateError!Interrupt {
        return .{
            .arch_specific = try architecture.getFunction(
                architecture.current_functions.interrupts,
                "allocateInterrupt",
            )(handler),
        };
    }

    pub fn deallocate(interrupt: Interrupt) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.interrupts,
            "deallocateInterrupt",
        )(interrupt.arch_specific);
    }

    pub const RouteError = error{UnableToRouteExternalInterrupt};

    pub fn route(self: Interrupt, external_interrupt: u32) callconv(core.inline_in_non_debug) RouteError!void {
        return architecture.getFunction(
            architecture.current_functions.interrupts,
            "routeInterrupt",
        )(self.arch_specific, external_interrupt);
    }

    /// Route this interrupt to a PCI INTx GSI (level-triggered, active-low).
    pub fn routePci(self: Interrupt, gsi: u32) callconv(core.inline_in_non_debug) RouteError!void {
        return architecture.getFunction(
            architecture.current_functions.interrupts,
            "routeInterruptPci",
        )(self.arch_specific, gsi);
    }

    pub inline fn toUsize(self: Interrupt) usize {
        return @intFromEnum(self.arch_specific);
    }

    pub inline fn fromUsize(interrupt: usize) Interrupt {
        return .{ .arch_specific = @enumFromInt(interrupt) };
    }
};

pub const InterruptFrame = struct {
    arch_specific: *architecture.current_decls.interrupts.InterruptFrame,

    /// Provides the context this interrupt was triggered from.
    pub fn fillContext(self: InterruptFrame, context: *std.debug.cpu_context.Native) void {
        return architecture.getFunction(
            architecture.current_functions.interrupts,
            "fillContext",
        )(self.arch_specific, context);
    }

    /// Returns the instruction pointer of the context this interrupt was triggered from.
    pub fn instructionPointer(self: InterruptFrame) innigkeit.VirtualAddress {
        // TODO: this is used during panics, so if it is not implemented we will panic during a panic
        return architecture.getFunction(
            architecture.current_functions.interrupts,
            "instructionPointer",
        )(self.arch_specific);
    }

    pub inline fn format(self: InterruptFrame, writer: *std.Io.Writer) !void {
        return self.arch_specific.format(writer);
    }
};

pub const init = struct {
    /// Ensure that any exceptions/faults that occur during early initialization are handled.
    ///
    /// The handler is not expected to do anything other than panic.
    pub fn initializeEarlyInterrupts() callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.interrupts.init,
            "initializeEarlyInterrupts",
        )();
    }

    /// Prepare interrupt allocation and routing.
    pub fn initializeInterruptRouting() callconv(core.inline_in_non_debug) !void {
        return architecture.getFunction(
            architecture.current_functions.interrupts.init,
            "initializeInterruptRouting",
        )();
    }

    /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
    /// system interrupt handlers.
    pub fn loadStandardInterruptHandlers() callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.interrupts.init,
            "loadStandardInterruptHandlers",
        )();
    }
};
