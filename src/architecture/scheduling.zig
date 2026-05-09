const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const architecture = @import("architecture");

/// Architecture specific per-task data.
pub const PerTask = architecture.current_decls.scheduling.PerTask;

/// Perform architecture specific task initialization.
///
/// This function is called very early during init so cannot use any kernel subsystems.
pub fn initializeTaskArchSpecific(task: *innigkeit.Task) callconv(core.inline_in_non_debug) void {
    architecture.current_functions.scheduling.initializeTaskArchSpecific(task);
}

/// Get the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub fn getCurrentTask() callconv(core.inline_in_non_debug) *innigkeit.Task {
    return architecture.getFunction(
        architecture.current_functions.scheduling,
        "getCurrentTask",
    )();
}

/// Set the current task.
///
/// Supports being called with interrupts and preemption enabled.
pub fn setCurrentTask(task: *innigkeit.Task) callconv(core.inline_in_non_debug) void {
    return architecture.getFunction(
        architecture.current_functions.scheduling,
        "setCurrentTask",
    )(task);
}

/// Prepares the given task for being scheduled.
///
/// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
///
/// This function *must* be called before the task is scheduled and can only be called once.
pub fn prepareTaskForScheduling(
    task: *innigkeit.Task,
    type_erased_call: core.TypeErasedCall,
) callconv(core.inline_in_non_debug) void {
    return architecture.getFunction(
        architecture.current_functions.scheduling,
        "prepareTaskForScheduling",
    )(task, type_erased_call);
}

/// Called before `transition.old_task` is switched to `transition.new_task`.
///
/// Page table switching and managing ability to access user memory has already been performed before this function is called.
///
/// Interrupts are disabled when this function is called.
pub fn beforeSwitchTask(transition: innigkeit.Task.Transition) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.scheduling,
        "beforeSwitchTask",
    )(transition);
}

/// Switches to `new_task`.
///
/// The state of `old_task` is saved to allow it to be resumed later.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub fn switchTask(
    old_task: *innigkeit.Task,
    new_task: *innigkeit.Task,
) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.scheduling,
        "switchTask",
    )(old_task, new_task);
}

/// Switches to `new_task`.
///
/// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
pub fn switchTaskNoSave(
    new_task: *innigkeit.Task,
) callconv(core.inline_in_non_debug) noreturn {
    architecture.getFunction(
        architecture.current_functions.scheduling,
        "switchTaskNoSave",
    )(new_task);
}

/// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
///
/// Asserts that the provided `type_erased_call` is noreturn.
pub fn call(
    old_task: *innigkeit.Task,
    new_stack: *innigkeit.Task.Stack,
    type_erased_call: core.TypeErasedCall,
) callconv(core.inline_in_non_debug) void {
    if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

    architecture.getFunction(
        architecture.current_functions.scheduling,
        "call",
    )(
        old_task,
        new_stack,
        type_erased_call,
    );
}

/// Calls `type_erased_call` on `new_stack`.
///
/// Asserts that the provided `type_erased_call` is noreturn.
pub fn callNoSave(
    new_stack: *innigkeit.Task.Stack,
    type_erased_call: core.TypeErasedCall,
) callconv(core.inline_in_non_debug) noreturn {
    if (core.is_debug) std.debug.assert(type_erased_call.return_type.isNoReturn());

    architecture.getFunction(
        architecture.current_functions.scheduling,
        "callNoSave",
    )(
        new_stack,
        type_erased_call,
    );
}

/// A string to be used in inline assembly to prevent unwinding.
///
/// Add `asm volatile (arch.scheduling.cfi_prevent_unwinding);` to the beginning of a function to prevent unwinding past it.
pub const cfi_prevent_unwinding = architecture.current_decls.scheduling.cfi_prevent_unwinding;
