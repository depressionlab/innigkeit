//! ARM GICv2 (Generic Interrupt Controller v2) driver.
//!
//! QEMU virt machine memory map:
//!   GICD (distributor)   0x08000000
//!   GICC (CPU interface) 0x08010000
//!
//! Supports SGIs (0–15), PPIs (16–31) and SPIs (32–1019).
//! IRQ 27 = virtual timer (PPI, per-CPU).

const architecture = @import("architecture");
const arm = @import("arm.zig");
const innigkeit = @import("innigkeit");

const GICD_BASE: u64 = 0x0800_0000;
const GICC_BASE: u64 = 0x0801_0000;

// Distributor registers (word-wide)

// CPU interface registers

/// The GIC MMIO lives at low physical addresses (below RAM) which are not
/// mapped at their identity address once the kernel runs in the higher half.
/// Limine's HHDM covers at least the first 4 GiB of physical memory, so the
/// GIC (at `0x0800_0000`) is reachable through the direct map. Note that this
/// maps the device as normal cacheable memory; that works under QEMU but a
/// proper device-memory (nGnRE) mapping should be installed once the kernel
/// page tables own this region.
inline fn gicdReg(offset: u64) *volatile u32 {
    const phys: innigkeit.PhysicalAddress = .from(GICD_BASE + offset);
    return phys.toDirectMap().toPtr(*volatile u32);
}

inline fn giccReg(offset: u64) *volatile u32 {
    const phys: innigkeit.PhysicalAddress = .from(GICC_BASE + offset);
    return phys.toDirectMap().toPtr(*volatile u32);
}

/// Initialise the GICv2 distributor. GLOBAL state (one distributor for the
/// whole system): call exactly once, on the bootstrap executor, after the MMU
/// is on and the GIC physical range is direct-mapped.
///
/// The CPU interface is a separate, per-executor concern (see
/// `initCpuInterface`).
pub fn initDistributor() void {
    // Disable distributor while we configure it.
    gicdReg(0x000).* = 0;

    // Read the number of interrupt lines (rounds up to nearest 32).
    const typer = gicdReg(0x004).*;
    const num_irqs: u32 = (32 * ((typer & 0x1F) + 1));

    // Mark all SPIs as Group 1 (non-secure) and disable / clear pending.
    var i: u32 = 1; // skip SGIs (n=0)
    while (i < num_irqs / 32) : (i += 1) {
        gicdReg(0x080 + i * 4).* = 0xFFFF_FFFF; // IGROUPR: group 1
        gicdReg(0x180 + i * 4).* = 0xFFFF_FFFF; // ICENABLER
        gicdReg(0x280 + i * 4).* = 0xFFFF_FFFF; // ICPENDR
    }

    // Set all interrupt priorities to 0xA0 (medium).
    i = 0;
    while (i < num_irqs / 4) : (i += 1) {
        gicdReg(0x400 + i * 4).* = 0xA0A0_A0A0;
    }

    // Target all SPIs to CPU0 (SPI affinity becomes a routing decision
    // once secondary executors run; for now, every SPI lands on the bootstrap).
    i = 8; // ITARGETSR0..7 are read-only (SGIs/PPIs target themselves)
    while (i < num_irqs / 4) : (i += 1) {
        gicdReg(0x800 + i * 4).* = 0x0101_0101;
    }

    // Re-enable distributor.
    gicdReg(0x000).* = 1;
}

/// Initialise THIS executor's GICv2 CPU interface. PER-EXECUTOR state (the
/// GICC registers are banked per CPU): every executor must call this for itself
/// after `initDistributor` has run.
pub fn initCpuInterface() void {
    giccReg(0x000).* = 1; // GICC_CTLR: enable
    giccReg(0x004).* = 0xFF; // GICC_PMR: lowest priority threshold (allow all)
    giccReg(0x008).* = 0; // GICC_BPR: no pre-emption splitting
}

/// Enable interrupt `irq` in the distributor.
pub fn enableIrq(irq: u32) void {
    const word: u32 = irq / 32;
    const bit: u32 = irq % 32;
    gicdReg(0x100 + word * 4).* = @as(u32, 1) << @intCast(bit);
}

/// Disable interrupt `irq` in the distributor.
pub fn disableIrq(irq: u32) void {
    const word: u32 = irq / 32;
    const bit: u32 = irq % 32;
    gicdReg(0x180 + word * 4).* = @as(u32, 1) << @intCast(bit);
}

/// Set the priority of `irq` (0 = highest, 255 = lowest; even values only in
/// most implementations).
pub fn setPriority(irq: u32, priority: u8) void {
    const byte_off: u32 = 0x400 + irq;
    const word_off: u32 = byte_off & ~@as(u32, 3);
    const shift: u5 = @intCast((byte_off & 3) * 8);
    const reg = gicdReg(word_off);
    reg.* = (reg.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, priority) << shift);
}

/// Route SPI `irq` to CPU 0.
pub fn setTarget(irq: u32) void {
    const byte_off: u32 = 0x800 + irq;
    const word_off: u32 = byte_off & ~@as(u32, 3);
    const shift: u5 = @intCast((byte_off & 3) * 8);
    const reg = gicdReg(word_off);
    reg.* = (reg.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, 0x01) << shift);
}

/// Configure the trigger mode of `irq` via GICD_ICFGR (2 bits per interrupt;
/// the low bit is RES0/model-defined, the high bit selects edge (1) vs
/// level (0)). PCI INTx lines are level-sensitive, so pass `level = true`.
///
/// SGIs (0-15) are always edge and PPIs (16-31) are implementation-defined;
/// this is intended for SPIs (>= 32).
pub fn setTrigger(irq: u32, level: bool) void {
    const word: u32 = irq / 16;
    const shift: u5 = @intCast((irq % 16) * 2);
    const reg = gicdReg(0xC00 + word * 4);
    const high_bit: u32 = @as(u32, 0b10) << shift;
    if (level) {
        reg.* = reg.* & ~high_bit; // level-sensitive
    } else {
        reg.* = reg.* | high_bit; // edge-triggered
    }
}

/// Read the interrupt acknowledge register. Returns the pending IRQ id.
/// Call at the START of an IRQ handler (before any other GIC interaction).
pub inline fn ack() u32 {
    return giccReg(0x00C).*; // GICC_IAR
}

/// Signal end-of-interrupt for `irq_id` (the value returned by `ack()`).
/// Call at the END of an IRQ handler.
pub inline fn eoi(irq_id: u32) void {
    giccReg(0x010).* = irq_id; // GICC_EOIR
}

/// Spurious interrupt ID: returned by `ack()` when no real interrupt is pending.
pub const SPURIOUS_ID: u32 = 0x3FF;

/// Maximum number of IRQs tracked by the dispatch table.
pub const MAX_IRQS: usize = 64;

/// Simple flat dispatch table: one no-arg handler per IRQ id (0..MAX_IRQS-1).
/// Used by the generic timer (PPI 27). Handlers are called with IRQs disabled.
pub var handlers: [MAX_IRQS]?*const fn () void = .{null} ** MAX_IRQS;

/// Generic-model dispatch table, parallel to `handlers`: holds the
/// `architecture.interrupts.Interrupt.Handler` for IRQs routed through the
/// generic allocate/route abstraction (e.g. PCI INTx for virtio). A given IRQ
/// id uses at most one of `handlers` / `generic_handlers`.
pub var generic_handlers: [MAX_IRQS]?architecture.interrupts.Interrupt.Handler =
    .{null} ** MAX_IRQS;

/// Register a no-arg handler for `irq` (used by the timer PPI).
pub fn registerHandler(irq: u32, handler: *const fn () void) void {
    if (irq < MAX_IRQS) handlers[irq] = handler;
}

/// Register a generic interrupt handler for `irq` (used by PCI INTx routing).
pub fn registerGenericHandler(
    irq: u32,
    handler: architecture.interrupts.Interrupt.Handler,
) void {
    if (irq < MAX_IRQS) generic_handlers[irq] = handler;
}

/// Called from the exception vector IRQ entry. Acks the GIC, dispatches the
/// no-arg or generic handler registered for the IRQ id, then signals EOI.
///
/// `frame` and `state_before_interrupt` are forwarded to generic handlers
/// (the no-arg `handlers` table ignores them). EOI ordering for generic
/// handlers honours `Handler.eoi`: PCI INTx is level-sensitive and uses
/// `.eoi = .level` (== `.after`), so the device's ISR-clearing handler runs
/// before EOI de-asserts the line at the CPU interface.
pub fn handleIrq(
    frame: *arm.InterruptFrame,
    state_before_interrupt: innigkeit.Task.Current.StateBeforeInterrupt,
) void {
    const id = ack();
    if (id != SPURIOUS_ID and id < MAX_IRQS) {
        if (generic_handlers[id]) |*generic| {
            var handler = generic.*;
            handler.call.setTemplatedArgs(.{
                .{ .arch_specific = frame },
                state_before_interrupt,
            });
            switch (handler.eoi) {
                .none => handler.call.call(),
                .after => {
                    handler.call.call();
                    eoi(id);
                },
                .before => {
                    eoi(id);
                    handler.call.call();
                },
            }
            return;
        }
        if (handlers[id]) |h| h();
    }
    eoi(id);
}
