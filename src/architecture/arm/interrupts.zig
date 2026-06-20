//! Bridge between the generic `architecture.interrupts.Interrupt` model
//! (allocate / route / Handler) and the GICv2 driver.
//!
//! The generic model is what shared drivers use (e.g. `virtio/legacy.zig
//! setupIrq` for PCI INTx). On x86-64 it maps onto IDT vectors + IOAPIC
//! redirection entries; on AArch64 it maps onto GIC SPIs.
//!
//! Allocation here is a thin two-step handshake mirroring x86-64's
//! "allocate a vector, then route a GSI to it":
//!   1. `allocate(handler)` stashes the generic `Handler` in a free pending
//!      slot and returns an opaque `Interrupt` carrying that slot index.
//!   2. `routeInterruptPci(interrupt, gsi)` binds the stashed handler to GIC
//!      interrupt id `gsi`, configures the SPI level-sensitive / targeted at
//!      CPU0 / enabled, so the GIC IRQ dispatch (`gic.handleIrq`) invokes it.
//!
//! On QEMU virt the 4 PCIe INTx pins are wired to GIC SPIs 3..6 (i.e. IRQ
//! 35..38); the PCI config "Interrupt Line" register is not meaningful, so the
//! caller passes the resolved GSI directly.

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const arm = @import("arm.zig");
const gic = @import("gic.zig");

const Handler = architecture.interrupts.Interrupt.Handler;
const ArchInterrupt = arm.Interrupt;

const log = innigkeit.debug.log.scoped(.interrupt);

/// Pending allocations: handlers that have been allocated but not yet routed.
/// Indexed by the `Interrupt` value returned from `allocate`.
const MAX_PENDING: usize = 16;
var pending: [MAX_PENDING]?Handler = .{null} ** MAX_PENDING;
var pending_lock: innigkeit.sync.TicketSpinLock = .{};

/// Allocate an interrupt for `handler`. The handler is held pending until
/// `routeInterruptPci` binds it to a GIC interrupt id.
pub fn allocate(handler: Handler) architecture.interrupts.Interrupt.AllocateError!ArchInterrupt {
    pending_lock.lock();
    defer pending_lock.unlock();

    for (&pending, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = handler;
        log.debug("allocated interrupt (pending slot {})", .{i});
        return @enumFromInt(i);
    }
    return error.InterruptAllocationFailed;
}

pub fn deallocate(interrupt: ArchInterrupt) void {
    const i = @intFromEnum(interrupt);
    if (i >= MAX_PENDING) return;
    pending_lock.lock();
    defer pending_lock.unlock();
    pending[i] = null;
}

/// Route `interrupt` to PCI INTx GIC interrupt id `gsi` (level-sensitive,
/// active-low PCI semantics -> GIC level-sensitive), targeted at CPU0.
pub fn routeInterruptPci(
    interrupt: ArchInterrupt,
    gsi: u32,
) architecture.interrupts.Interrupt.RouteError!void {
    const i = @intFromEnum(interrupt);

    pending_lock.lock();
    const handler = if (i < MAX_PENDING) pending[i] else null;
    pending_lock.unlock();

    const h = handler orelse return error.UnableToRouteExternalInterrupt;
    if (gsi >= gic.MAX_IRQS) {
        log.warn("PCI GSI {} exceeds GIC dispatch table ({} entries)", .{ gsi, gic.MAX_IRQS });
        return error.UnableToRouteExternalInterrupt;
    }

    log.debug("routing interrupt to PCI GIC id {} (level-sensitive)", .{gsi});

    gic.registerGenericHandler(gsi, h);
    gic.setTrigger(gsi, true); // level-sensitive
    gic.setPriority(gsi, 0xA0);
    gic.setTarget(gsi); // CPU0
    gic.enableIrq(gsi);
}
