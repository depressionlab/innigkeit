const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const innigkeit = @import("innigkeit");

// TODO: align this more with zig's standard library: `start.zig`!!!

/// Exports the Innigkeit entry point.
///
/// ```zig
/// pub const _start = void;
/// comptime {
///     innigkeit.exportEntry();
/// }
/// ```
pub fn exportEntry() void {
    comptime if (@import("is_internal").is_internal)
        @export(&_innigkeit_entry, .{ .name = "_start" });
}

fn _innigkeit_entry() callconv(.naked) noreturn {
    if (builtin.unwind_tables != .none or !builtin.strip_debug_info) {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (".cfi_undefined lr"),
            .riscv64 => if (builtin.zig_backend != .stage2_riscv64)
                asm volatile (".cfi_undefined ra"),
            .x86_64 => asm volatile (".cfi_undefined %%rip"),
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
    }

    // Move this to the riscv prong below when this is resolved: https://github.com/ziglang/zig/issues/20918
    if (builtin.cpu.arch.isRISCV() and builtin.zig_backend != .stage2_riscv64) {
        asm volatile (
            \\ .weak __global_pointer$
            \\ .hidden __global_pointer$
            \\ .option push
            \\ .option norelax
            \\ lla gp, __global_pointer$
            \\ .option pop
        );
    }

    asm volatile (switch (builtin.cpu.arch) {
            .aarch64 =>
            \\ mov fp, #0
            \\ mov lr, #0
            \\ mov x0, sp
            \\ and sp, x0, #-16
            \\ b %[callMainAndExit]
            ,
            .riscv64 =>
            \\ li fp, 0
            \\ li ra, 0
            \\ mv a0, sp
            \\ andi sp, sp, -16
            \\ tail %[callMainAndExit]@plt
            ,
            .x86_64 =>
            \\ xor %%ebp, %%ebp
            \\ mov %%rsp, %%rdi
            \\ and $-16, %%rsp
            \\ callq %[callMainAndExit:P]
            ,
            else => |t| @compileError("unsupported architecture " ++ @tagName(t)),
        }
        :
        : [callMainAndExit] "X" (&callMainAndExit),
    );
}

fn callMainAndExit(argc_argv_ptr: [*]usize) callconv(.c) noreturn {
    // We're not ready to panic until thread local storage is initialized.
    @setRuntimeSafety(false);
    // Code coverage instrumentation might try to use thread local variables.
    @disableInstrumentation();

    // Parse the ELF-ABI initial stack written by the kernel:
    //   [argc] [argv[0]..argv[argc-1]] [null] [envp[0]..] [null] [auxv..] [AT_NULL,0]
    // On os=.other, std.process.Args.Vector = void and cannot carry argv, so
    // we stash the parsed values in innigkeit.process globals instead.
    // TODO: make it so we can use std.process.Args somehow
    const argc = argc_argv_ptr[0];
    const argv: [*][*:0]u8 = @ptrCast(argc_argv_ptr + 1);

    // Use a sentinel-typed pointer for envp so the null-terminator is type-checked.
    const envp_optional: [*:null]?[*:0]u8 = @ptrCast(@alignCast(argv + argc + 1));
    var envp_count: usize = 0;
    while (envp_optional[envp_count]) |_| : (envp_count += 1) {}
    const envp = envp_optional[0..envp_count :null];

    // Auxv immediately follows the null envp terminator.
    const auxv: [*]const std.elf.Auxv = @ptrCast(@alignCast(envp.ptr + envp_count + 1));

    // For static PIE binaries: find AT_PHDR/AT_PHNUM in the auxv and apply ELF
    // relocations before touching any global state.  Must be always_inline so the
    // call itself does not go through the (not yet relocated) PLT/GOT.
    if (builtin.link_mode == .static and builtin.position_independent_executable) {
        const phdrs = init: {
            var i: usize = 0;
            var at_phdr: usize = 0;
            var at_phnum: usize = 0;
            while (auxv[i].a_type != std.elf.AT_NULL) : (i += 1) {
                switch (auxv[i].a_type) {
                    std.elf.AT_PHDR => at_phdr = @intCast(auxv[i].a_un.a_val),
                    std.elf.AT_PHNUM => at_phnum = @intCast(auxv[i].a_un.a_val),
                    else => {},
                }
            }
            break :init @as([*]const std.elf.Phdr, @ptrFromInt(at_phdr))[0..at_phnum];
        };
        @call(.always_inline, std.pie.relocate, .{phdrs});
    }

    const opt_init_array_start = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_start",
        .linkage = .weak,
    });
    const opt_init_array_end = @extern([*]const *const fn () callconv(.c) void, .{
        .name = "__init_array_end",
        .linkage = .weak,
    });
    if (opt_init_array_start) |init_array_start| {
        const init_array_end = opt_init_array_end.?;
        const slice = init_array_start[0 .. init_array_end - init_array_start];
        for (slice) |func| func();
    }

    // Store parsed argv and envp in process globals (safe after PIE relocation).
    innigkeit.process._argc = argc;
    innigkeit.process._argv = argv;
    innigkeit.process._envp = envp_optional;
    innigkeit.process._envp_count = envp_count;

    const env_block: std.process.Environ.Block = .empty;
    innigkeit.process.exit(@call(.always_inline, callMain, .{ {}, env_block }));
}

const use_debug_allocator = switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe => !builtin.link_libc,
    .ReleaseFast, .ReleaseSmall => !builtin.link_libc and builtin.single_threaded,
};

// Module-level so that its backing memory is in BSS rather than on the call stack.
var debug_allocator: std.heap.DebugAllocator(.{}) = .{
    .backing_allocator = innigkeit.mem.page_allocator,
};

inline fn callMain(args: std.process.Args.Vector, environ: std.process.Environ.Block) u8 {
    const fn_info = @typeInfo(@TypeOf(root.main)).@"fn";
    if (fn_info.params.len == 0) return wrapMain(root.main());
    if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
        .args = .{ .vector = args },
        .environ = .{ .block = environ },
    }));

    const gpa = if (use_debug_allocator)
        debug_allocator.allocator()
    else if (builtin.link_libc)
        std.heap.c_allocator
    else
        innigkeit.mem.page_allocator;
    // else if (builtin.link_libc)
    //     std.heap.c_allocator
    // else if (!builtin.single_threaded)
    //     std.heap.smp_allocator
    // else
    //     comptime unreachable;

    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit(); // Leaks do not affect return code.
    };

    // var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena_allocator.deinit();

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();

    // var threaded: std.Io.Threaded = .init(gpa, .{
    //     .argv0 = .init(.{ .vector = args }),
    //     .environ = .{ .block = environ },
    // });
    // defer threaded.deinit();

    // var environ_map = std.process.Environ.createMap(.{ .block = environ }, gpa) catch |err|
    //     std.process.fatal("failed to parse environment variables: {t}", .{err});
    // defer environ_map.deinit();

    var environ_map: std.process.Environ.Map = .init(gpa);
    defer environ_map.deinit();

    // Populate environ_map from kernel-provided envp.
    for (innigkeit.process._envp[0..innigkeit.process._envp_count]) |maybe_entry| {
        const env_str: [*:0]const u8 = maybe_entry orelse continue;
        const env_slice = std.mem.span(env_str);
        const eq_pos = std.mem.indexOfScalar(u8, env_slice, '=') orelse continue;
        environ_map.put(env_slice[0..eq_pos], env_slice[eq_pos + 1 ..]) catch {};
    }

    return wrapMain(root.main(.{
        .minimal = .{
            .args = .{ .vector = args },
            .environ = .{ .block = environ },
        },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = innigkeit.interop.debug_io,
        .environ_map = &environ_map,
        .preopens = .empty,
    }));
}

inline fn wrapMain(result: anytype) u8 {
    const ReturnType = @TypeOf(result);
    switch (ReturnType) {
        void => return 0,
        noreturn => unreachable,
        u8 => return result,
        else => {},
    }
    if (@typeInfo(ReturnType) != .error_union) @compileError(bad_main_ret);

    const unwrapped_result = result catch |err| {
        std.log.err("{t}", .{err});
        if (@errorReturnTrace()) |trace| {
            switch (builtin.os.tag) {
                .freestanding, .other => {
                    // No DWARF symbolication yet; print raw instruction addresses.
                    std.log.err("error return trace ({d} frames):", .{trace.index});
                    for (trace.instruction_addresses[0..trace.index]) |addr| {
                        std.log.err("  0x{x}", .{addr});
                    }
                },
                else => std.debug.dumpErrorReturnTrace(trace),
            }
        }

        return 1;
    };

    return switch (@TypeOf(unwrapped_result)) {
        noreturn => unreachable,
        void => 0,
        u8 => unwrapped_result,
        else => @compileError(bad_main_ret),
    };
}

const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'";
