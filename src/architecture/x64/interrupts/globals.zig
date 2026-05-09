const Handler = @import("architecture").interrupts.Interrupt.Handler;
const innigkeit = @import("innigkeit");
const Idt = @import("Idt.zig");
const Interrupt = @import("Interrupt.zig").Interrupt;
const interrupt_handlers = @import("handlers.zig");

pub var idt: Idt = .{};
pub var handlers: [Idt.number_of_handlers]Handler = handlers: {
    @setEvalBranchQuota(4 * Idt.number_of_handlers);

    var temp_handlers: [Idt.number_of_handlers]Handler = undefined;

    for (0..Idt.number_of_handlers) |i| {
        const interrupt: Interrupt = @enumFromInt(i);

        if (interrupt == .page_fault) {
            temp_handlers[i] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.earlyPageFaultHandler, .{}),
            };
            continue;
        }

        if (interrupt == .spurious_interrupt) {
            temp_handlers[i] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.spuriousInterruptHandler, .{}),
            };
            continue;
        }

        if (interrupt.isException()) {
            temp_handlers[i] = .{
                .eoi = .none,
                .call = .prepare(interrupt_handlers.unhandledException, .{}),
            };
        } else {
            temp_handlers[i] = .{
                .eoi = .after,
                .call = .prepare(interrupt_handlers.unhandledInterrupt, .{}),
            };
        }
    }

    break :handlers temp_handlers;
};
pub var interrupt_arena: innigkeit.mem.resource_arena.Arena(.none) = undefined; // initialized by `init.initializeInterruptRouting`
