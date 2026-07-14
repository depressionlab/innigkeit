//! Represents a userspace thread.
const Thread = @This();

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");
const log = innigkeit.debug.log.scoped(.user);
const validate = @import("validate.zig");

task: innigkeit.Task,

process: *innigkeit.user.Process,

arch_specific: architecture.user.PerThread,

pub inline fn from(task: *innigkeit.Task) *Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

pub inline fn fromConst(task: *const innigkeit.Task) *const Thread {
    if (core.is_debug) std.debug.assert(task.type == .user);
    return @fieldParentPtr("task", task);
}

/// Enter userspace for the first time.
///
/// Asserts that the current task is the same as the thread's task.
/// `arg` is forwarded in the first argument register (rdi/x0/a0) so
/// thread entry functions of type `fn(usize) callconv(.c) noreturn` receive it.
pub fn start(self: *Thread, entry_point: innigkeit.UserVirtualAddress, arg: usize) !noreturn {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task == &self.task);
    }

    const user_stack = try self.process.address_space.map(.{
        .size = .from(64, .kib),
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });

    log.debug("starting userspace thread: {f}", .{self});

    architecture.user.enterUserspace(.{
        .entry_point = entry_point,
        .stack_pointer = user_stack.toUser().after(),
        .arg = arg,
    });
}

/// Parameters for the ELF-ABI initial stack written by `startProcess`.
pub const InitialStack = struct {
    /// Virtual address of the ELF program header table in the loaded image,
    /// or 0 if unknown.
    phdr_vaddr: usize = 0,
    /// Number of program header entries (e_phnum).
    phnum: usize = 0,
    /// ELF entry point virtual address (e_entry), written as AT_ENTRY.
    entry: usize = 0,
    /// Combined argv+envp buffer, or empty if both argc=0 and envc=0.
    ///
    /// Format when non-empty:
    ///   [argc: usize][envc: usize]
    ///   [arg_len0..arg_len(argc-1): usize each]
    ///   [env_len0..env_len(envc-1): usize each]
    ///   [argv string bytes...][envp string bytes...]
    ///
    /// Freed by startProcess on success (noreturn). Caller frees on error.
    proc_init: []const u8 = &.{},
};

/// Enter userspace for the first time, writing a full ELF-ABI initial stack.
///
/// Writes the SysV x86_64 initial stack layout below the top of a fresh 64 KiB
/// user stack, then jumps to `entry_point` with rsp pointing at argc.
///
/// Stack layout (low -> high, rsp points at argc):
///   [argc][argv[0] ptr]...[argv[N-1] ptr][argv null]
///   [envp[0] ptr]...[envp[M-1] ptr][envp null]
///   [AT_PHDR][AT_PHNUM][AT_ENTRY][AT_NULL]
///   [argv[0] string\0]...[argv[N-1] string\0]
///   [envp[0] string\0]...[envp[M-1] string\0]
///
/// On success: frees `initial.proc_init` before entering userspace.
/// On error: does NOT free `initial.proc_init` (caller responsible).
pub fn startProcess(self: *Thread, entry_point: innigkeit.UserVirtualAddress, initial: InitialStack) !noreturn {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task == &self.task);
    }

    const S = @sizeOf(usize);

    // Parse proc_init header: [argc][envc][arg_lens...][env_lens...]
    const argc: usize = if (initial.proc_init.len >= S)
        std.mem.readInt(usize, initial.proc_init[0..S], .little)
    else
        0;
    const envc: usize = if (initial.proc_init.len >= 2 * S)
        std.mem.readInt(usize, initial.proc_init[S .. 2 * S], .little)
    else
        0;

    // Total bytes needed for null-terminated string data in the user stack.
    // Each string gets one extra byte for the null terminator.
    var total_str_bytes: usize = argc + envc;
    for (0..argc) |i| {
        total_str_bytes += std.mem.readInt(
            usize,
            initial.proc_init[(2 + i) * S ..][0..S],
            .little,
        );
    }
    for (0..envc) |i| {
        total_str_bytes += std.mem.readInt(
            usize,
            initial.proc_init[(2 + argc + i) * S ..][0..S],
            .little,
        );
    }

    // Metadata:
    //   1 (argc) + argc (argv ptrs) + 1 (argv null)
    //   + envc (envp ptrs) + 1 (envp null)
    //   + 4 auxv entries
    const metadata_size = (argc + envc + 3) * S + 4 * @sizeOf(std.elf.Auxv);
    const frame_size = std.mem.alignForward(usize, metadata_size + total_str_bytes, 16);

    const user_stack = try self.process.address_space.map(.{
        .size = .from(64, .kib),
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });

    // proc_init's caller-side validation (handlers/spawn.zig's argc/envc/
    // per-string length caps) is what actually keeps frame_size well under
    // the stack size; assert it explicitly here too, since a future caller
    // violating that contract would otherwise silently write past the
    // mapped stack via moveBackward below.
    if (core.is_debug) std.debug.assert(frame_size <= user_stack.size.value);

    const stack_top = user_stack.toUser().after();
    const stack_ptr = stack_top.moveBackward(core.Size.from(frame_size, .byte));

    {
        const access: validate.UserAccess = .acquire();
        defer access.release();
        // every @ptrFromInt below is derived from `stack_ptr` (this process's
        // own just-mapped stack, not an externally supplied user pointer) and
        // stays within the asserted `frame_size`, inside this `UserAccess`
        // window. the whole block writes the initial user stack layout the
        // kernel is constructing, not a foreign buffer.
        var meta: usize = stack_ptr.value;

        // argc
        @as(*usize, @ptrFromInt(meta)).* = argc;
        meta += S;

        // Reserve space for argv pointers; filled below once string addresses are known.
        const argv_ptrs_base = meta;
        meta += argc * S;

        // argv null
        @as(*usize, @ptrFromInt(meta)).* = 0;
        meta += S;

        // Reserve space for envp pointers; filled below.
        const envp_ptrs_base = meta;
        meta += envc * S;

        // envp null
        @as(*usize, @ptrFromInt(meta)).* = 0;
        meta += S;

        // auxv: AT_PHDR, AT_PHNUM, AT_ENTRY, AT_NULL
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_PHDR, .a_un = .{ .a_val = initial.phdr_vaddr } };
        meta += @sizeOf(std.elf.Auxv);
        // meta, see comment above
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_PHNUM, .a_un = .{ .a_val = initial.phnum } };
        meta += @sizeOf(std.elf.Auxv);
        // meta, see comment above
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_ENTRY, .a_un = .{ .a_val = initial.entry } };
        meta += @sizeOf(std.elf.Auxv);
        // meta, see comment above
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_NULL, .a_un = .{ .a_val = 0 } };
        meta += @sizeOf(std.elf.Auxv);
        // meta == stack_ptr.value + metadata_size; string data follows here.

        // String data starts here; we walk flat_str_offset through proc_init.
        var flat_str_offset: usize = (2 + argc + envc) * S;
        var str_ptr: usize = meta;

        // Copy argv strings into user stack and back-fill pointer table.
        for (0..argc) |i| {
            const str_len = std.mem.readInt(usize, initial.proc_init[(2 + i) * S ..][0..S], .little);
            // `str_ptr/argv_ptrs_base`, see the block comment above.
            @as(*usize, @ptrFromInt(argv_ptrs_base + i * S)).* = str_ptr;
            if (str_len > 0) {
                // str_ptr, see the block comment above.
                @memcpy(
                    @as([*]u8, @ptrFromInt(str_ptr))[0..str_len], // see comment above
                    initial.proc_init[flat_str_offset..][0..str_len],
                );
            }
            // `str_ptr`, see the block comment above.
            @as(*u8, @ptrFromInt(str_ptr + str_len)).* = 0;
            str_ptr += str_len + 1;
            flat_str_offset += str_len;
        }

        // Copy envp strings into user stack and back-fill pointer table.
        for (0..envc) |i| {
            const str_len = std.mem.readInt(usize, initial.proc_init[(2 + argc + i) * S ..][0..S], .little);
            // `str_ptr/envp_ptrs_base`, see the block comment above.
            @as(*usize, @ptrFromInt(envp_ptrs_base + i * S)).* = str_ptr;
            if (str_len > 0) {
                // `str_ptr`, see the block comment above.
                @memcpy(
                    @as([*]u8, @ptrFromInt(str_ptr))[0..str_len], // see comment above
                    initial.proc_init[flat_str_offset..][0..str_len],
                );
            }
            // `str_ptr`, see the block comment above.
            @as(*u8, @ptrFromInt(str_ptr + str_len)).* = 0;
            str_ptr += str_len + 1;
            flat_str_offset += str_len;
        }
    }

    log.debug("starting userspace process: {f}", .{self});

    // Free combined proc_init buffer before entering userspace; defers in the
    // caller won't run on the noreturn success path.
    if (initial.proc_init.len > 0) innigkeit.memory.heap.allocator.free(initial.proc_init);

    architecture.user.enterUserspace(.{
        .entry_point = entry_point,
        .stack_pointer = stack_ptr,
        .arg = 0,
    });
}

pub fn format(self: *const Thread, writer: *std.Io.Writer) !void {
    // TODO: these are user controlled strings...
    // should we make like, an app registry idk?
    // on hold until the userspace api is better developed

    try writer.print("U<{s} - {s}>", .{
        self.process.name.constSlice(),
        self.task.name.constSlice(),
    });
}

pub const internal = struct {
    pub fn create(
        process: *innigkeit.user.Process,
        options: innigkeit.Task.internal.InitOptions,
    ) !*Thread {
        const thread = try globals.cache.allocate();
        errdefer globals.cache.deallocate(thread);

        thread.* = .{
            .task = thread.task, // reinitialized below
            .process = process,
            .arch_specific = thread.arch_specific, // reinitialized below
        };

        try innigkeit.Task.internal.init(&thread.task, options);
        architecture.user.thread.initialize(thread);

        return thread;
    }

    pub fn destroy(thread: *Thread) void {
        if (core.is_debug) {
            const task = &thread.task;
            std.debug.assert(task.type == .user);
            std.debug.assert(task.state == .terminated);
            std.debug.assert(task.reference_count.load(.monotonic) == 0);
        }
        globals.cache.deallocate(thread);
    }
};

const globals = struct {
    /// The source of thread objects.
    ///
    /// Initialized during `init.initializeThreads`.
    var cache: innigkeit.memory.cache.Cache(
        Thread,
        .{
            .constructor = struct {
                fn constructor(thread: *Thread) innigkeit.memory.cache.ConstructorError!void {
                    if (core.is_debug) thread.* = undefined;
                    thread.task.stack = try .createStack();
                    errdefer thread.task.stack.destroyStack();
                    try architecture.user.thread.create(thread);
                }
            }.constructor,
            .destructor = struct {
                fn destructor(thread: *Thread) void {
                    architecture.user.thread.destroy(thread);
                    thread.task.stack.destroyStack();
                }
            }.destructor,
        },
    ) = undefined;
};

pub const init = struct {
    const init_log = innigkeit.debug.log.scoped(.user_init);

    pub fn initializeThreads() !void {
        init_log.debug("initializing thread cache", .{});
        globals.cache.init(
            .{ .name = try .fromSlice("thread") },
        );
    }
};
