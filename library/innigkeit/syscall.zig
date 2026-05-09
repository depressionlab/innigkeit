const builtin = @import("builtin");

pub const Syscall = enum(usize) {
    exit_current_thread = 0,

    pub inline fn call0(syscall: Syscall) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call1(syscall: Syscall, arg1: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call2(syscall: Syscall, arg1: usize, arg2: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call3(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call4(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize, arg4: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call5(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }

    pub inline fn call6(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) isize {
        return switch (builtin.cpu.arch) {
            .aarch64 => @panic("TODO"),
            .riscv64 => @panic("TODO"),
            .x86_64 => asm volatile ("syscall"
                : [ret] "={rax}" (-> isize),
                : [syscall] "{rax}" (syscall),
                  [arg1] "{rdi}" (arg1),
                  [arg2] "{rsi}" (arg2),
                  [arg3] "{rdx}" (arg3),
                  [arg4] "{rbx}" (arg4),
                  [arg5] "{r8}" (arg5),
                  [arg6] "{r9}" (arg6),
                : .{ .rcx = true, .r11 = true, .memory = true }),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        };
    }
};
