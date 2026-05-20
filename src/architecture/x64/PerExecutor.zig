const innigkeit = @import("innigkeit");
const x64 = @import("x64.zig");

const PerExecutor = @This();

apic_id: u32,

gdt: x64.Gdt = .{},
tss: x64.Tss = .{},

double_fault_stack: innigkeit.Task.Stack,
non_maskable_interrupt_stack: innigkeit.Task.Stack,

/// Dedicated per-CPU stack used for all interrupt dispatch (non-IST).
///
/// Ring3 -> ring0 interrupts land here via TSS.RSP0.
/// Ring0 -> ring0 interrupts switch here explicitly in `_interruptEntry`.
irq_stack: innigkeit.Task.Stack,

pub inline fn from(executor: *innigkeit.Executor) *PerExecutor {
    return &executor.arch_specific;
}
