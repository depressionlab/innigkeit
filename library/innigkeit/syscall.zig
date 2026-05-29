const builtin = @import("builtin");

/// Kernel-defined syscall numbers.
pub const Syscall = enum(usize) {
    /// Exit an existing thread
    exit_thread = 0,
    /// Spawn a new thread
    spawn_thread = 1,
    /// Write to the standard output: (fd: Fd, ptr: usize, len: usize) -> buf_len|error
    write = 2,
    /// Read from the standard input: (fd: Fd, ptr: usize, len: usize) -> bytes_read|error
    read = 3,
    /// Voluntarily yield the CPU to another runnable thread. () -> void
    yield = 4,
    /// Spawn a new process from initfs: (spec_ptr: usize) -> notify_handle|error
    spawn = 5,
    /// Exit an existing process
    exit_process = 6,
    /// Wait for a spawned process to exit: (notify_handle: u32) -> 0|error
    wait_process = 7,
    /// Invoke a capability operation: (handle: u32, op: u64, arg: usize) -> usize|error
    cap_invoke = 8,
    /// Copy a capability with optional rights restriction: (handle: u32, rights: u16) -> new_handle|error
    cap_copy = 9,
    /// Move a capability to a new slot (copy + delete original): (handle: u32) -> new_handle|error
    cap_move = 10,
    /// Delete a capability: (handle: u32) -> 0|error
    cap_delete = 11,
    /// Create a new kernel capability object: (type: u8) -> handle|error
    cap_create = 12,
    /// Revoke a capability for all holders: (handle: u32) -> 0|error
    /// Requires the slot to carry .revoke rights. Increments the object's generation
    /// counter; every other slot pointing to the same object returns EBADF on next use.
    cap_revoke = 13,
    /// Map anonymous zero-fill memory: (size: usize, prot: u32) -> addr|error
    mmap = 14,
    /// Unmap a previously mapped range: (addr: usize, size: usize) -> 0|error
    munmap = 15,
    /// Block until futex word at addr != expected: (addr: usize, expected: u32) -> 0|error
    futex_wait = 16,
    /// Block until futex word at addr != expected OR uptime_ms >= deadline_ms.
    /// (addr: usize, expected: u32, deadline_ms: u64) -> 0|error
    futex_wait_timeout = 17,
    /// Wake up to max_wake tasks on addr: (addr: usize, max_wake: u32) -> woken_count|error
    futex_wake = 18,
    /// Map a Frame capability into the calling process's address space: (handle: u32) -> addr|error
    vmem_map = 19,
    /// Unmap a virtual address range from the calling process's address space: (addr: usize, size: usize) -> 0|error
    vmem_unmap = 20,
    /// Map the bootloader framebuffer (write-combining) into the calling process's VA.
    /// (info_ptr: usize) -> va|error  Fills FramebufferInfo at info_ptr.
    framebuffer_map = 21,
    /// Read a file from the embedded initfs archive.
    /// (spec_ptr: usize) -> bytes|error  spec_ptr -> InitfsReadSpec
    initfs_read = 22,
    /// Return milliseconds elapsed since kernel boot.
    /// () -> ms:u64
    uptime_ms = 23,
    /// Non-blocking drain of raw PS/2 scancode bytes into a user buffer.
    /// Includes 0xE0 extended prefix and break bit (bit 7 = release).
    /// (buf_ptr: usize, buf_len: usize) -> count
    kbd_read = 24,
    /// Block until uptime_ms >= deadline_ms.
    /// (deadline_ms: u64) -> 0
    nanosleep_ms = 25,
    /// Return a stable u64 identifier for the calling process.
    /// () -> pid:u64  (currently the VA of the kernel Process struct)
    getpid = 26,
    /// Non-blocking check whether the process associated with a Notify handle has exited.
    /// (notify_handle: u32) -> exit_status:u8|error
    /// Returns -EAGAIN if still running.
    wait_process_nb = 27,
    /// Force-signal the exit Notify for a process, unblocking any waitProcess caller.
    /// (notify_handle: u32) -> 0|error
    process_kill = 28,
    /// Read bytes from the data disk (virtio-blk device 1) into a user buffer.
    /// (spec_ptr: usize) -> bytes_read|error  spec_ptr -> BlkReadSpec{byte_offset:u64, buf_ptr:usize, buf_len:usize}
    blk_read = 29,
    /// Write bytes to the data disk (virtio-blk device 1) from a user buffer.
    /// Offset and length must be multiples of 512 (sector size).
    /// (spec_ptr: usize) -> 0|error spec_ptr -> BlkReadSpec{byte_offset:u64, buf_ptr:usize, buf_len:usize}
    blk_write = 30,
    /// Open or create a file on the simple flat filesystem.
    /// (name_ptr: usize, name_len: u32, flags: u32) -> fd|error
    fs_open = 31,
    /// Read bytes from an open file descriptor.
    /// (fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
    fs_read = 32,
    /// Write bytes to an open file descriptor.
    /// (fd: u32, buf_ptr: usize, buf_len: usize) -> nbytes|error
    fs_write = 33,
    /// Close an open file descriptor.
    /// (fd: u32) -> 0|error
    fs_close = 34,
    /// Set P/E-core scheduling hint for the calling thread.
    /// (hint: u8) -> 0  hint: 0=unknown, 1=p_core, 2=e_core
    thread_set_hint = 35,

    /// Decode a raw syscall return value into a success count or a `SyscallError`.
    ///
    /// The kernel encodes errors as negated errno-style codes (e.g. -9 = EBADF).
    /// Non-negative values are returned as-is.
    pub fn decode(result: isize) Syscall.Error!usize {
        if (result >= 0) return @intCast(result);
        return switch (result) {
            -1 => error.PermissionDenied,
            -2 => error.NotFound,
            -5 => error.IoError,
            -9 => error.BadFileDescriptor,
            -11 => error.WouldBlock,
            -12 => error.OutOfMemory,
            -14 => error.BadAddress,
            -17 => error.AlreadyExists,
            -19 => error.NoDevice,
            -22 => error.InvalidArgument,
            -28 => error.NoSpace,
            -38 => error.Unsupported,
            else => error.Unknown,
        };
    }

    /// Syscall ABI:
    ///   x86_64: number in rax, args in rdi/rsi/rdx/r10/r8/r9, return in rax.
    ///             SYSCALL clobbers rcx (saves rip) and r11 (saves rflags).
    ///   aarch64: number in x8,  args in x0–x5,               return in x0.
    ///             SVC does not clobber any registers; the kernel saves the full frame.
    ///   riscv64: number in a7,  args in a0–a5,               return in a0.
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

    /// Invoke a syscall using a comptime-counted anonymous argument tuple.
    ///
    /// The argument count is determined at compile time via struct field
    /// reflection, so the right `callN` is selected with zero runtime overhead.
    /// All argument values must be implicitly coercible to `usize` (integers,
    /// pointers via @intFromPtr, packed structs via @bitCast, etc.).
    ///
    /// ```zig
    /// _ = Syscall.invoke(.write, .{ fd, len });
    /// _ = try Syscall.decode(Syscall.invoke(.mmap, .{ size, prot }));
    /// ```
    pub inline fn invoke(syscall: Syscall, args: anytype) isize {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        return switch (fields.len) {
            0 => call0(syscall),
            1 => call1(syscall, @field(args, fields[0].name)),
            2 => call2(syscall, @field(args, fields[0].name), @field(args, fields[1].name)),
            3 => call3(syscall, @field(args, fields[0].name), @field(args, fields[1].name), @field(args, fields[2].name)),
            4 => call4(syscall, @field(args, fields[0].name), @field(args, fields[1].name), @field(args, fields[2].name), @field(args, fields[3].name)),
            5 => call5(syscall, @field(args, fields[0].name), @field(args, fields[1].name), @field(args, fields[2].name), @field(args, fields[3].name), @field(args, fields[4].name)),
            6 => call6(syscall, @field(args, fields[0].name), @field(args, fields[1].name), @field(args, fields[2].name), @field(args, fields[3].name), @field(args, fields[4].name), @field(args, fields[5].name)),
            else => @compileError("too many syscall arguments (max 6)"),
        };
    }

    /// Error codes returned by the kernel as negative isize values.
    pub const Error = error{
        PermissionDenied,
        NotFound,
        IoError,
        BadFileDescriptor,
        WouldBlock,
        OutOfMemory,
        BadAddress,
        AlreadyExists,
        NoDevice,
        InvalidArgument,
        NoSpace,
        Unsupported,
        Unknown,
    };
};
