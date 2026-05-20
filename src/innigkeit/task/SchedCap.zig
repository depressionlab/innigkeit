//! A task must hold this capability to change its own scheduling class,
//! nice level, or time slice.
//!
//! The capability is checked at the syscall boundary before any scheduler
//! parameter is modified.
//!
//! Rights are a bitmask so they can be narrowed when delegating:
//! A process may hold change_class | change_nice but grant a child only change_nice.
//!
//! TODO: Wire into the capability table once innigkeit.capabilities infrastructure is ready.
//!       For now this file defines the types; enforcement lives in the (future) syscall handlers.
const SchedCap = @This();

const innigkeit = @import("innigkeit");
const SchedClass = @import("SchedClass.zig");

pub const Rights = packed struct(u8) {
    /// May call sched_setclass() to move between fair / RT / idle classes.
    change_class: bool = false,
    /// May call sched_setnice() to adjust the EEVDF weight.
    change_nice: bool = false,
    /// May call sched_setslice() to set a custom time-slice (overrides PELT-lite auto-tune).
    change_slice: bool = false,
    /// May call sched_setdeadline() to influence the virtual deadline directly.
    set_deadline: bool = false,
    _pad: u4 = 0,
};

rights: Rights,

/// Full rights, intended for privileged kernel tasks only.
pub const all: SchedCap = .{ .rights = .{
    .change_class = true,
    .change_nice = true,
    .change_slice = true,
    .set_deadline = true,
} };

/// Normal permissions in userspace
pub const user_default: SchedCap = .{ .rights = .{
    .change_nice = true,
    .change_slice = true,
} };

pub fn canChangeClass(self: SchedCap) bool {
    return self.rights.change_class;
}

pub fn canChangeNice(self: SchedCap) bool {
    return self.rights.change_nice;
}

pub fn canChangeSlice(self: SchedCap) bool {
    return self.rights.change_slice;
}

pub fn canSetDeadline(self: SchedCap) bool {
    return self.rights.set_deadline;
}

/// Change the scheduling class of `task`.
/// Returns error.PermissionDenied if the capability does not include change_class.
pub fn setClass(
    self: SchedCap,
    task: *innigkeit.Task,
    new_class: *const SchedClass,
) error{PermissionDenied}!void {
    if (!self.rights.change_class) return error.PermissionDenied;
    // TODO: dequeue from old class, re-enqueue in new class under scheduler lock.
    task.sched_class = new_class;
}

/// Set the EEVDF nice level [-20, 19].
/// Returns error.PermissionDenied if the capability does not include change_nice.
pub fn setNice(
    self: SchedCap,
    task: *innigkeit.Task,
    nice: i8,
) error{ PermissionDenied, InvalidNice }!void {
    if (!self.rights.change_nice) return error.PermissionDenied;
    if (nice < -20 or nice > 19) return error.InvalidNice;
    const Eevdf = @import("sched/Eevdf.zig");
    // TODO: update weight under scheduler lock and re-place in tree.
    task.sched.weight = Eevdf.SchedEntity.weightForNice(nice);
}

/// Set a custom time slice in nanoseconds.
/// Returns error.PermissionDenied if the capability does not include change_slice.
pub fn setSlice(
    self: SchedCap,
    task: *innigkeit.Task,
    slice_ns: u64,
) error{PermissionDenied}!void {
    if (!self.rights.change_slice) return error.PermissionDenied;
    // TODO: update under scheduler lock.
    task.sched.slice = slice_ns;
    task.sched.custom_slice = true;
}
