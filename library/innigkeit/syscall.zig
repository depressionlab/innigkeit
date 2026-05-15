const builtin = @import("builtin");

/// Error codes returned by the kernel as negative isize values.
pub const SyscallError = error{
    PermissionDenied,
    IoError,
    BadFileDescriptor,
    WouldBlock,
    OutOfMemory,
    BadAddress,
    InvalidArgument,
    Unsupported,
    Unknown,
};

/// Kernel-defined syscall numbers.
pub const Syscall = enum(usize) {
    exit_thread = 0,
    write = 1,
    read = 2,
    exit_process = 3,
    yield = 4,
    spawn_thread = 5,
    /// Invoke a capability operation: (handle: u32, op: u64, arg: usize) → usize|error
    cap_invoke = 6,
    /// Copy a capability with optional rights restriction: (handle: u32, rights: u16) → new_handle|error
    cap_copy = 7,
    /// Move a capability to a new slot (copy + delete original): (handle: u32) → new_handle|error
    cap_move = 8,
    /// Delete a capability: (handle: u32) → 0|error
    cap_delete = 9,

    /// Decode a raw syscall return value into a success count or a `SyscallError`.
    ///
    /// The kernel encodes errors as negated errno-style codes (e.g. -9 = EBADF).
    /// Non-negative values are returned as-is.
    pub fn decode(result: isize) SyscallError!usize {
        if (result >= 0) return @intCast(result);
        return switch (result) {
            -1 => error.PermissionDenied,
            -5 => error.IoError,
            -9 => error.BadFileDescriptor,
            -11 => error.WouldBlock,
            -12 => error.OutOfMemory,
            -14 => error.BadAddress,
            -22 => error.InvalidArgument,
            -38 => error.Unsupported,
            else => error.Unknown,
        };
    }

    /// Syscall ABI:
    ///   x86_64  — number in rax, args in rdi/rsi/rdx/r10/r8/r9, return in rax.
    ///             SYSCALL clobbers rcx (saves rip) and r11 (saves rflags).
    ///   aarch64 — number in x8,  args in x0–x5,               return in x0.
    ///             SVC does not clobber any registers; the kernel saves the full frame.
    ///   riscv64 — number in a7,  args in a0–a5,               return in a0.
    ///             ECALL does not clobber any registers; the kernel saves the full frame.
    pub inline fn call0(syscall: Syscall) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call1(syscall: Syscall, arg1: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call2(syscall: Syscall, arg1: usize, arg2: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                  [a2] "{x1}" (arg2),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                  [a2] "{a1}" (arg2),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                  [a2] "{rsi}" (arg2),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call3(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                  [a2] "{x1}" (arg2),
                  [a3] "{x2}" (arg3),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                  [a2] "{a1}" (arg2),
                  [a3] "{a2}" (arg3),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                  [a2] "{rsi}" (arg2),
                  [a3] "{rdx}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call4(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                  [a2] "{x1}" (arg2),
                  [a3] "{x2}" (arg3),
                  [a4] "{x3}" (arg4),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                  [a2] "{a1}" (arg2),
                  [a3] "{a2}" (arg3),
                  [a4] "{a3}" (arg4),
                : .{ .memory = true }),
            // x86_64: arg4 goes in r10, NOT rbx. rbx is callee-saved in the System V ABI
            // and must not be clobbered by a syscall. r10 is the Linux convention too.
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                  [a2] "{rsi}" (arg2),
                  [a3] "{rdx}" (arg3),
                  [a4] "{r10}" (arg4),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call5(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                  [a2] "{x1}" (arg2),
                  [a3] "{x2}" (arg3),
                  [a4] "{x3}" (arg4),
                  [a5] "{x4}" (arg5),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                  [a2] "{a1}" (arg2),
                  [a3] "{a2}" (arg3),
                  [a4] "{a3}" (arg4),
                  [a5] "{a4}" (arg5),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                  [a2] "{rsi}" (arg2),
                  [a3] "{rdx}" (arg3),
                  [a4] "{r10}" (arg4),
                  [a5] "{r8}" (arg5),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }

    pub inline fn call6(
        syscall: Syscall,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        arg6: usize,
    ) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("svc #0"
                : [ret] "={x0}" (-> isize),
                : [num] "{x8}" (@intFromEnum(syscall)),
                  [a1] "{x0}" (arg1),
                  [a2] "{x1}" (arg2),
                  [a3] "{x2}" (arg3),
                  [a4] "{x3}" (arg4),
                  [a5] "{x4}" (arg5),
                  [a6] "{x5}" (arg6),
                : .{ .memory = true }),
            .riscv64 => asm volatile ("ecall"
                : [ret] "={a0}" (-> isize),
                : [num] "{a7}" (@intFromEnum(syscall)),
                  [a1] "{a0}" (arg1),
                  [a2] "{a1}" (arg2),
                  [a3] "{a2}" (arg3),
                  [a4] "{a3}" (arg4),
                  [a5] "{a4}" (arg5),
                  [a6] "{a5}" (arg6),
                : .{ .memory = true }),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [num] "{rax}" (@intFromEnum(syscall)),
                  [a1] "{rdi}" (arg1),
                  [a2] "{rsi}" (arg2),
                  [a3] "{rdx}" (arg3),
                  [a4] "{r10}" (arg4),
                  [a5] "{r8}" (arg5),
                  [a6] "{r9}" (arg6),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture: " ++ @tagName(t)),
        };
    }
};
