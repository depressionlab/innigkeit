//! Targeted deterministic checkpoints: named rendezvous points at
//! hand-picked contended sites, so a test can hold one task at a known
//! point while it drives or observes another, forcing one specific
//! interleaving instead of relying on scheduler luck.

const innigkeit = @import("innigkeit");
const std = @import("std");

const Process = innigkeit.user.Process;
const wallclock = innigkeit.time.wallclock;

const enabled = @import("kernel_options").checkpoint_test;

/// Every checkpoint in the kernel.
pub const Point = enum {
    /// `TaskCleanup.cleanupTask`, user-thread branch, before taking the
    /// owning process's `threads_lock`. Subject: the thread's process.
    thread_cleanup,
    /// `ProcessCleanup.cleanupProcess`, on entry, before its reference-count
    /// check or any teardown. Subject: the process being cleaned up.
    process_cleanup,
    /// `elf.loader.loadAndJump`, after the ELF-segment copy loop (its
    /// `UserAccess` window already released) but before the per-segment
    /// `changeProtection` loop runs. The loading process's mapping is
    /// still RW at this point. Subject: the process being loaded.
    /// docs/test-system-plan.md sec4's "remaining first cause" staging.
    loader_before_protect,
    /// `elf.loader.loadAndJump`, immediately after the per-segment
    /// `changeProtection` loop, before `AT_PHDR` computation / jump.
    /// Subject: the process being loaded.
    loader_after_protect,
};

const State = enum(u8) {
    disarmed,
    armed,
    /// A task won the claim and is publishing its subject.
    claiming,
    /// A task is blocked here; `subject` is valid.
    caught,
    released,
};

const Slot = struct {
    state: std.atomic.Value(State) = .init(.disarmed),
    subject: ?*const Process = null,
};

var slots: std.enums.EnumArray(Point, Slot) = .initFill(.{});

/// Block here if `point` is armed and not yet claimed, until the controller
/// releases it. Compiles to nothing without `-Dcheckpoint_test=true`.
///
/// Must not be called with a spinlock held: it yields.
pub inline fn wait(comptime point: Point, subject: *const Process) void {
    if (comptime !enabled) return;
    waitEnabled(point, subject);
}

fn waitEnabled(point: Point, subject: *const Process) void {
    const slot = slots.getPtr(point);
    if (slot.state.load(.monotonic) != .armed) {
        @branchHint(.likely);
        return;
    }
    if (slot.state.cmpxchgStrong(.armed, .claiming, .acquire, .monotonic) != null) return;

    slot.subject = subject;
    slot.state.store(.caught, .release);

    while (slot.state.load(.acquire) != .released) yieldNow();

    slot.subject = null;
    slot.state.store(.disarmed, .release);
}

/// Arm `point`: the next task to reach it blocks there.
pub fn arm(point: Point) void {
    const slot = slots.getPtr(point);
    if (slot.state.cmpxchgStrong(.disarmed, .armed, .acq_rel, .monotonic)) |actual|
        std.debug.panic("checkpoint {t}: armed while {t}", .{ point, actual });
}

/// Disarm `point` if nothing claimed it. Returns false if a task is
/// already claiming or held there (the caller must then decide whether to
/// `release` it).
pub fn disarm(point: Point) bool {
    const slot = slots.getPtr(point);
    return slot.state.cmpxchgStrong(.armed, .disarmed, .acq_rel, .monotonic) == null;
}

/// Wait, yield-polling, until a task is held at `point`, and return the
/// process it reported. Returns null if none arrives within `timeout_ns`.
pub fn awaitCaught(point: Point, timeout_ns: u64) ?*const Process {
    const slot = slots.getPtr(point);
    const start = wallclock.read();
    while (slot.state.load(.acquire) != .caught) {
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > timeout_ns) return null;
        yieldNow();
    }
    return slot.subject;
}

/// Let the task held at `point` continue. `point` must be caught.
pub fn release(point: Point) void {
    const slot = slots.getPtr(point);
    if (slot.state.cmpxchgStrong(.caught, .released, .acq_rel, .monotonic)) |actual|
        std.debug.panic("checkpoint {t}: released while {t}", .{ point, actual });
}

fn yieldNow() void {
    const handle: innigkeit.Task.Scheduler.Handle = .get();
    defer handle.unlock();
    handle.yield();
}
