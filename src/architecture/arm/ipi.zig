//! Inter-processor interrupts built on GICv2 SGIs.

const architecture = @import("architecture");
const arm = @import("arm.zig");
const gic = @import("gic.zig");
const innigkeit = @import("innigkeit");

// TODO: should this be an enum?
/// SGI ids. 0-15 are available. Only four are in use so far.
const flush_sgi: u4 = 0;
const reschedule_sgi: u4 = 1;
const panic_sgi: u4 = 2;
const kill_sgi: u4 = 3;

// TODO: verify all this on real hardware, upgrade to the latest ARM recommendations
// and APIs instead of blindly mirroring what we do for x86_64.

/// This executor's GICv2 CPU interface number. GICv2 supports at most 8 CPU
/// interfaces, so this fits a target-list bit position directly.
///
/// QEMU virt: CPU interface `i` == `MPIDR_EL1.Aff0` == `i` (GICv2 targets are
/// interface bitmasks, not MPIDR (that's GICv3)).
fn cpuInterface(executor: *const innigkeit.Executor) u3 {
    return @truncate(executor.arch_specific.mpidr);
}

/// Register the four IPI SGI handlers.
///
/// Called once since SGI routing is global dispatch-table state, not per-executor.
pub fn registerHandlers() void {
    gic.registerHandler(flush_sgi, flushHandler);
    gic.registerHandler(reschedule_sgi, rescheduleHandler);
    gic.registerHandler(panic_sgi, panicHandler);
    gic.registerHandler(kill_sgi, killHandler);
}

/// Send a flush IPI to the given executor.
///
/// Mandatory once more than one executor is online. `memory.FlushRequest`
/// calls this unconditionally on every cross-executor TLB/cache maintenance request.
pub fn sendFlushIPI(executor: *innigkeit.Executor) void {
    gic.sendSgi(.list, @as(u8, 1) << cpuInterface(executor), flush_sgi);
}

/// Send a reschedule IPI to the given executor, breaking it out of `wfi` in
/// the idle loop so it re-checks its runqueue immediately.
pub fn sendRescheduleIPI(executor: *innigkeit.Executor) void {
    gic.sendSgi(.list, @as(u8, 1) << cpuInterface(executor), reschedule_sgi);
}

/// Broadcast a panic IPI to every other executor.
pub fn sendPanicIPI() void {
    gic.sendSgi(.all_but_self, 0, panic_sgi);
}

/// Broadcast a kill IPI to every other executor.
pub fn sendKillIPI() void {
    gic.sendSgi(.all_but_self, 0, kill_sgi);
}

fn flushHandler() void {
    innigkeit.memory.FlushRequest.processFlushRequests();
}

fn rescheduleHandler() void {
    _ = innigkeit.Task.Current.get()
        .knownExecutor().scheduler.reschedule_ipi_count.fetchAdd(1, .monotonic);
}

/// The panic IPI's only job is to stop every other executor. Unlike x64's
/// NMI vector, this SGI id carries no other meaning, so the handler halts
/// unconditionally instead of needing `hasAnExecutorPanicked()` to tell a
/// real fault from a broadcast.
fn panicHandler() void {
    arm.instructions.disableInterruptsAndHalt();
}

/// The kill IPI's only job is to force an interrupt return on this executor;
/// `Current.decrementInterruptDisable`'s safe-point check (run as this
/// handler unwinds) re-checks whatever task is now current for
/// `Task.pending_kill`. Count receipts for diagnostics and tests, mirroring
/// x64's `killRequestHandler`.
fn killHandler() void {
    _ = innigkeit.Task.Current.get()
        .knownExecutor().scheduler.kill_ipi_count.fetchAdd(1, .monotonic);
}
