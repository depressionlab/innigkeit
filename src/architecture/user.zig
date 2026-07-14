const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// Architecture specific per-thread data.
pub const PerThread = architecture.current_decls.user.PerThread;

/// The range of the address space that is considered user memory.
///
/// Usually the lower half of the address space.
///
/// This must not include either the zero, undefined nor max addresses.
pub const user_memory_range: innigkeit.VirtualRange = architecture.current_decls.user.user_memory_range;

comptime {
    std.debug.assert(!user_memory_range.containsAddress(.zero));
    std.debug.assert(!user_memory_range.containsAddress(.undefined_address));
    std.debug.assert(!user_memory_range.containsAddress(.max));
}

/// Operations on a thread's `PerThread` arch-specific data. Grouped as a
/// namespace (not a wrapper type like `SyscallFrame`) since `PerThread` lives
/// embedded inside the caller-owned `innigkeit.user.Thread`, not as a
/// separate handle these functions construct.
pub const thread = struct {
    /// Create the `PerThread` data of a thread.
    ///
    /// Non-architecture specific creation has already been performed but no initialization.
    ///
    /// This function is called in the `Thread` cache constructor.
    pub fn create(thread_ptr: *innigkeit.user.Thread) callconv(core.inline_in_non_debug) innigkeit.memory.cache.ConstructorError!void {
        return architecture.getFunction(
            architecture.current_functions.user,
            "createThread",
        )(thread_ptr);
    }

    /// Destroy the `PerThread` data of a thread.
    ///
    /// Non-architecture specific destruction has not already been performed.
    ///
    /// This function is called in the `Thread` cache destructor.
    pub fn destroy(thread_ptr: *innigkeit.user.Thread) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.user,
            "destroyThread",
        )(thread_ptr);
    }

    /// Initialize the `PerThread` data of a thread.
    ///
    /// All non-architecture specific initialization has already been performed.
    ///
    /// This function is called in `Thread.internal.create`.
    pub fn initialize(thread_ptr: *innigkeit.user.Thread) callconv(core.inline_in_non_debug) void {
        architecture.getFunction(
            architecture.current_functions.user,
            "initializeThread",
        )(thread_ptr);
    }
};

pub const SyscallFrame = struct {
    arch_specific: *architecture.current_decls.user.SyscallFrame,

    /// Get the syscall this frame represents.
    pub fn syscall(self: SyscallFrame) callconv(core.inline_in_non_debug) ?@import("libinnigkeit").Syscall {
        return architecture.getFunction(
            architecture.current_functions.user,
            "syscallFromSyscallFrame",
        )(self.arch_specific);
    }

    pub const Arg = enum {
        one,
        two,
        three,
        four,
        five,
        six,
        seven,
        eight,
        nine,
        ten,
        eleven,
        twelve,
    };

    pub fn arg(self: SyscallFrame, comptime argument: Arg) callconv(core.inline_in_non_debug) usize {
        return architecture.getFunction(
            architecture.current_functions.user,
            "argFromSyscallFrame",
        )(self.arch_specific, argument);
    }

    /// Write the syscall return value into the architecture's return register.
    ///
    /// The generic syscall dispatcher returns its result and calls this; the
    /// arch layer places it in the correct register (rax on x86-64, x0 on
    /// AArch64) so generic code never names a physical register.
    pub fn setReturnValue(self: SyscallFrame, value: usize) callconv(core.inline_in_non_debug) void {
        return architecture.getFunction(
            architecture.current_functions.user,
            "setReturnValueOnSyscallFrame",
        )(self.arch_specific, value);
    }

    pub inline fn format(self: SyscallFrame, writer: *std.Io.Writer) !void {
        return self.arch_specific.format(writer);
    }
};

pub const EnterUserspaceOptions = struct {
    entry_point: innigkeit.UserVirtualAddress,
    stack_pointer: innigkeit.UserVirtualAddress,
    /// Value placed in the first argument register (rdi/x0/a0) on entry.
    arg: usize = 0,
};

/// Enter userspace for the first time in the current task.
///
/// Asserts that the current task is a user task.
pub fn enterUserspace(options: EnterUserspaceOptions) callconv(core.inline_in_non_debug) noreturn {
    if (core.is_debug) std.debug.assert(innigkeit.Task.Current.get().task.type == .user);

    architecture.getFunction(
        architecture.current_functions.user,
        "enterUserspace",
    )(options);
}

pub const init = struct {
    /// Perform any per-achitecture initialization needed for userspace processes/threads.
    pub fn initialize() anyerror!void {
        return architecture.getFunction(
            architecture.current_functions.user.init,
            "initialize",
        )();
    }
};
