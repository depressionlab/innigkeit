const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const x64 = @import("../x64.zig");

const EnterUserspaceFrame = @import("EnterUserspaceFrame.zig").EnterUserspaceFrame;
const globals = @import("globals.zig");

pub const SyscallFrame = @import("SyscallFrame.zig").SyscallFrame;
pub const PerThread = @import("PerThread.zig");
pub const init = @import("init.zig");

// TODO: make this better. look at what linux does for syscalls
// TODO: use @memset and @memcpy instead of `mov`

/// Enter userspace for the first time in the current task.
pub fn enterUserspace(options: architecture.user.EnterUserspaceOptions) noreturn {
    const per_thread: *x64.user.PerThread = .from(.from(innigkeit.Task.Current.get().task));
    if (core.is_debug) std.debug.assert(per_thread.extended_state.state == .memory);

    const frame: EnterUserspaceFrame = .{
        .rip = options.entry_point,
        .rsp = options.stack_pointer,
    };

    x64.instructions.disableInterrupts();

    x64.instructions.enableSSEUsage();
    per_thread.extended_state.load();

    asm volatile (
        \\.cfi_sections .debug_frame
        \\
        \\mov %[frame], %rsp
        \\.cfi_undefined rip
        \\
        \\mov %[arg], %rdi
        \\xor %ebp, %ebp
        \\xor %eax, %eax
        \\xor %ebx, %ebx
        \\xor %ecx, %ecx
        \\xor %edx, %edx
        \\xor %esi, %esi
        // \\xor %edi, %edi
        \\xor %r8, %r8
        \\xor %r9, %r9
        \\xor %r10, %r10
        \\xor %r11, %r11
        \\xor %r12, %r12
        \\xor %r13, %r13
        \\xor %r14, %r14
        \\xor %r15, %r15
        \\swapgs
        \\iretq
        :
        : [frame] "r" (&frame),
          [arg] "r" (options.arg),
    );

    unreachable;
}

export fn syscallDispatch(syscall_frame: *SyscallFrame) callconv(.c) void {
    x64.instructions.disableSSEUsage();
    defer {
        const per_thread: *PerThread = .from(.from(innigkeit.Task.Current.get().task));
        x64.instructions.enableSSEUsage();
        per_thread.extended_state.load();
    }

    innigkeit.user.onSyscall(.{ .arch_specific = syscall_frame });

    x64.instructions.disableInterrupts();
}

pub fn syscallEntry() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\.cfi_sections .debug_frame
            \\
            \\.cfi_undefined %rip
            \\.cfi_undefined %rsp
            \\
            \\swapgs
            \\
            \\mov %rsp, %gs:{[user_rsp_scratch_offset]}      // save the user rsp
            \\mov %gs:{[kernel_stack_pointer_offset]}, %rsp  // load the kernel rsp
            \\.cfi_def_cfa %rsp, 0
            \\
            \\sub $8, %rsp                                   // reserve space for the user rsp
            \\.cfi_adjust_cfa_offset 8
            \\push %rcx                                      // user rip
            \\.cfi_adjust_cfa_offset 8
            \\push %r11                                      // user rflags
            \\.cfi_adjust_cfa_offset 8
            \\
            \\mov %gs:{[user_rsp_scratch_offset]}, %r11
            \\mov %r11, 16(%rsp)                             // store the user rsp in reserved space
            \\
            \\push %rax
            \\.cfi_adjust_cfa_offset 8
            \\push %rbx
            \\.cfi_adjust_cfa_offset 8
            \\push %rdx
            \\.cfi_adjust_cfa_offset 8
            \\push %rbp
            \\.cfi_adjust_cfa_offset 8
            \\push %rsi
            \\.cfi_adjust_cfa_offset 8
            \\push %rdi
            \\.cfi_adjust_cfa_offset 8
            \\push %r8
            \\.cfi_adjust_cfa_offset 8
            \\push %r9
            \\.cfi_adjust_cfa_offset 8
            \\push %r10
            \\.cfi_adjust_cfa_offset 8
            \\push %r12
            \\.cfi_adjust_cfa_offset 8
            \\push %r13
            \\.cfi_adjust_cfa_offset 8
            \\push %r14
            \\.cfi_adjust_cfa_offset 8
            \\push %r15
            \\.cfi_adjust_cfa_offset 8
            \\
            \\xor %ebp, %ebp
            \\mov %rsp, %rdi
            \\call syscallDispatch
            \\
            \\pop %r15
            \\.cfi_adjust_cfa_offset -8
            \\pop %r14
            \\.cfi_adjust_cfa_offset -8
            \\pop %r13
            \\.cfi_adjust_cfa_offset -8
            \\pop %r12
            \\.cfi_adjust_cfa_offset -8
            \\pop %r10
            \\.cfi_adjust_cfa_offset -8
            \\pop %r9
            \\.cfi_adjust_cfa_offset -8
            \\pop %r8
            \\.cfi_adjust_cfa_offset -8
            \\pop %rdi
            \\.cfi_adjust_cfa_offset -8
            \\pop %rsi
            \\.cfi_adjust_cfa_offset -8
            \\pop %rbp
            \\.cfi_adjust_cfa_offset -8
            \\pop %rdx
            \\.cfi_adjust_cfa_offset -8
            \\pop %rbx
            \\.cfi_adjust_cfa_offset -8
            \\pop %rax
            \\.cfi_adjust_cfa_offset -8
            \\
            \\pop %r11 // user rflags
            \\.cfi_adjust_cfa_offset -8
            \\pop %rcx // user rip
            \\.cfi_adjust_cfa_offset -8
            \\pop %rsp // user rsp
            \\.cfi_undefined %rsp
            \\
            \\swapgs
            \\sysretq
        , .{
            .user_rsp_scratch_offset = @offsetOf(innigkeit.Task, "arch_specific") + @offsetOf(x64.PerTask, "user_rsp_scratch"),
            .kernel_stack_pointer_offset = @offsetOf(innigkeit.Task, "stack") + @offsetOf(innigkeit.Task.Stack, "top_stack_pointer"),
        }));
}
