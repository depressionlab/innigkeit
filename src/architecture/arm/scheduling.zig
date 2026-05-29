//! AArch64 context-switch primitives.
//!
//! Context is stored in PerTask (not on the stack like x64). Memory layout
//! used by the inline assembly (must stay in sync with PerTask.zig):
//!
//! ```
//!   [old/new + 0]  x19   [old/new + 40] x24
//!   [old/new + 8]  x20   [old/new + 48] x25
//!   [old/new + 16] x21   [old/new + 56] x26
//!   [old/new + 24] x22   [old/new + 64] x27
//!   [old/new + 32] x23   [old/new + 72] x28
//!   [old/new + 80] fp(x29)  [old/new + 88] lr/resume-PC
//!   [old/new + 96] kernel SP
//! ```

const std = @import("std");
const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const core = @import("core");
const arm = @import("arm.zig");

/// Prepares a fresh task so that when first scheduled it calls `type_erased_call`.
///
/// Registers stored in PerTask for the trampoline:
///   x19 = typeErased   x20..x24 = args[0..4]   x25 = taskEntry
///   fp  = 0   lr = taskEntryTrampoline   sp = task stack top
pub fn prepareTaskForScheduling(
    task: *innigkeit.Task,
    type_erased_call: core.TypeErasedCall,
) void {
    const impl = struct {
        fn taskEntryTrampoline() callconv(.naked) void {
            asm volatile (
                \\.cfi_sections .debug_frame
                \\.cfi_undefined lr
                \\ mov x0, x19
                \\ mov x1, x20
                \\ mov x2, x21
                \\ mov x3, x22
                \\ mov x4, x23
                \\ mov x5, x24
                \\ br  x25
            );
        }
    };

    const arch = arm.PerTask.from(task);
    arch.x19_x28[0] = @intFromPtr(type_erased_call.typeErased); // x19
    arch.x19_x28[1] = type_erased_call.args[0]; // x20
    arch.x19_x28[2] = type_erased_call.args[1]; // x21
    arch.x19_x28[3] = type_erased_call.args[2]; // x22
    arch.x19_x28[4] = type_erased_call.args[3]; // x23
    arch.x19_x28[5] = type_erased_call.args[4]; // x24
    arch.x19_x28[6] = @intFromPtr(&innigkeit.Task.internal.taskEntry); // x25
    arch.x19_x28[7] = 0;
    arch.x19_x28[8] = 0;
    arch.x19_x28[9] = 0;
    arch.fp = 0;
    arch.lr = @intFromPtr(&impl.taskEntryTrampoline);
    arch.sp = task.stack.stack_pointer.value;
}

/// Stub; extend to save/restore NEON/FP state for user threads.
pub fn beforeSwitchTask(transition: innigkeit.Task.Transition) void {
    _ = transition;
}

/// Saves old_task's callee-saved registers to its PerTask and resumes new_task.
///
/// The resume address is stored in old_task.PerTask.lr via `adr`.
/// old_task continues immediately after the `ret` when next scheduled.
pub inline fn switchTask(
    old_task: *innigkeit.Task,
    new_task: *innigkeit.Task,
) void {
    const old_arch = arm.PerTask.from(old_task);
    const new_arch = arm.PerTask.from(new_task);
    asm volatile (
        \\.cfi_sections .debug_frame
        \\ adr x9, 1f
        \\ stp x19, x20, [%[old], #0]
        \\ stp x21, x22, [%[old], #16]
        \\ stp x23, x24, [%[old], #32]
        \\ stp x25, x26, [%[old], #48]
        \\ stp x27, x28, [%[old], #64]
        \\ stp x29, x9,  [%[old], #80]
        \\ mov x9, sp
        \\ str x9,       [%[old], #96]
        \\.cfi_undefined lr
        \\ ldp x19, x20, [%[new], #0]
        \\ ldp x21, x22, [%[new], #16]
        \\ ldp x23, x24, [%[new], #32]
        \\ ldp x25, x26, [%[new], #48]
        \\ ldp x27, x28, [%[new], #64]
        \\ ldp x29, x30, [%[new], #80]
        \\ ldr x9,       [%[new], #96]
        \\ mov sp, x9
        \\.cfi_restore lr
        \\ ret
        \\ 1:
        :
        : [old] "{x0}" (old_arch),
          [new] "{x1}" (new_arch),
        : .{
          .memory = true,
          .x0 = true,
          .x1 = true,
          .x2 = true,
          .x3 = true,
          .x4 = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .x15 = true,
          .x16 = true,
          .x17 = true,
          .x18 = true,
          .x30 = true,
        });
    comptime {
        std.debug.assert(builtin.omit_frame_pointer == false);
    }
}

pub inline fn switchTaskNoSave(new_task: *innigkeit.Task) noreturn {
    const new_arch = arm.PerTask.from(new_task);
    asm volatile (
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\ ldp x19, x20, [%[new], #0]
        \\ ldp x21, x22, [%[new], #16]
        \\ ldp x23, x24, [%[new], #32]
        \\ ldp x25, x26, [%[new], #48]
        \\ ldp x27, x28, [%[new], #64]
        \\ ldp x29, x30, [%[new], #80]
        \\ ldr x9,       [%[new], #96]
        \\ mov sp, x9
        \\ ret
        :
        : [new] "{x0}" (new_arch),
    );
    unreachable;
}

/// Saves old_task to its PerTask, switches to new_stack, jumps to
/// type_erased_call.typeErased. old_task resumes at label 1 when scheduled back.
pub inline fn call(
    old_task: *innigkeit.Task,
    new_stack: *innigkeit.Task.Stack,
    type_erased_call: core.TypeErasedCall,
) void {
    const old_arch = arm.PerTask.from(old_task);
    asm volatile (
        \\.cfi_sections .debug_frame
        \\ adr x11, 1f
        \\ stp x19, x20, [%[old], #0]
        \\ stp x21, x22, [%[old], #16]
        \\ stp x23, x24, [%[old], #32]
        \\ stp x25, x26, [%[old], #48]
        \\ stp x27, x28, [%[old], #64]
        \\ stp x29, x11, [%[old], #80]
        \\ mov x11, sp
        \\ str x11,      [%[old], #96]
        \\.cfi_undefined lr
        \\ mov sp, %[new_sp]
        \\ mov x29, xzr
        \\ br  %[func]
        \\ 1:
        :
        : [old] "{x8}" (old_arch),
          [new_sp] "{x9}" (new_stack.stack_pointer.value),
          [func] "{x10}" (type_erased_call.typeErased),
          [a0] "{x0}" (type_erased_call.args[0]),
          [a1] "{x1}" (type_erased_call.args[1]),
          [a2] "{x2}" (type_erased_call.args[2]),
          [a3] "{x3}" (type_erased_call.args[3]),
          [a4] "{x4}" (type_erased_call.args[4]),
        : .{
          .memory = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .x15 = true,
          .x16 = true,
          .x17 = true,
          .x18 = true,
          .x30 = true,
        });
    comptime {
        std.debug.assert(builtin.omit_frame_pointer == false);
    }
}

pub inline fn callNoSave(
    new_stack: *innigkeit.Task.Stack,
    type_erased_call: core.TypeErasedCall,
) noreturn {
    asm volatile (
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\ mov sp, %[new_sp]
        \\ mov x29, xzr
        \\ br  %[func]
        :
        : [new_sp] "{x8}" (new_stack.stack_pointer.value),
          [func] "{x9}" (type_erased_call.typeErased),
          [a0] "{x0}" (type_erased_call.args[0]),
          [a1] "{x1}" (type_erased_call.args[1]),
          [a2] "{x2}" (type_erased_call.args[2]),
          [a3] "{x3}" (type_erased_call.args[3]),
          [a4] "{x4}" (type_erased_call.args[4]),
    );
    unreachable;
}
