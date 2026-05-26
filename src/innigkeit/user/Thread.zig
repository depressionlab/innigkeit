//! Represents a userspace thread.
const Thread = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const log = innigkeit.debug.log.scoped(.user);

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
    /// Kernel-heap flat argv buffer, or empty slice if argc=0.
    /// - Format: `[argc: usize][len0: usize]...[len(argc-1): usize][str0 bytes][str1 bytes]...`
    /// - Freed by startProcess on success (noreturn). Caller frees on error.
    flat_argv: []const u8 = &.{},
};

/// Enter userspace for the first time, writing a full ELF-ABI initial stack.
///
/// Writes the SysV x86_64 initial stack layout below the top of a fresh 64 KiB
/// user stack, then jumps to `entry_point` with rsp pointing at argc.
///
/// Stack layout (low → high, rsp points at argc):
///   [argc][argv[0] ptr]...[argv[N-1] ptr][argv null][envp null]
///   [AT_PHDR][AT_PHNUM][AT_ENTRY][AT_NULL]
///   [argv[0] string\0]...[argv[N-1] string\0]
///
/// On success: frees `initial.flat_argv` before entering userspace.
/// On error: does NOT free `initial.flat_argv` (caller responsible).
pub fn startProcess(self: *Thread, entry_point: innigkeit.UserVirtualAddress, initial: InitialStack) !noreturn {
    if (core.is_debug) {
        const current_task: innigkeit.Task.Current = .get();
        std.debug.assert(current_task.task == &self.task);
    }

    // Parse flat_argv header: [argc: usize][len0: usize]...[len(argc-1): usize][bytes...]
    const argc: usize = if (initial.flat_argv.len > 0)
        std.mem.readInt(usize, initial.flat_argv[0..@sizeOf(usize)], .little)
    else
        0;

    // Total bytes needed for null-terminated string data in the user stack.
    var total_str_bytes: usize = argc; // one null byte per string
    for (0..argc) |i| {
        total_str_bytes += std.mem.readInt(
            usize,
            initial.flat_argv[@sizeOf(usize) + i * @sizeOf(usize) ..][0..@sizeOf(usize)],
            .little,
        );
    }

    // Metadata: argc + N argv ptrs + argv null + envp null + 4 auxv entries.
    const metadata_size = (argc + 3) * @sizeOf(usize) + 4 * @sizeOf(std.elf.Auxv);
    const frame_size = std.mem.alignForward(usize, metadata_size + total_str_bytes, 16);

    const user_stack = try self.process.address_space.map(.{
        .size = .from(64, .kib),
        .protection = .{ .read = true, .write = true },
        .type = .zero_fill,
    });

    const stack_top = user_stack.toUser().after();
    const stack_ptr = stack_top.moveBackward(core.Size.from(frame_size, .byte));

    {
        const current_task: innigkeit.Task.Current = .get();
        current_task.incrementEnableAccessToUserMemory();
        defer current_task.decrementEnableAccessToUserMemory();

        var meta: usize = stack_ptr.value;

        // argc
        @as(*usize, @ptrFromInt(meta)).* = argc;
        meta += @sizeOf(usize);

        // Reserve space for argv pointers; fill in below once we know string addresses.
        const argv_ptrs_base = meta;
        meta += argc * @sizeOf(usize);

        // argv null + envp null
        @as(*usize, @ptrFromInt(meta)).* = 0;
        meta += @sizeOf(usize);
        @as(*usize, @ptrFromInt(meta)).* = 0;
        meta += @sizeOf(usize);

        // auxv: AT_PHDR, AT_PHNUM, AT_ENTRY, AT_NULL
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_PHDR, .a_un = .{ .a_val = initial.phdr_vaddr } };
        meta += @sizeOf(std.elf.Auxv);
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_PHNUM, .a_un = .{ .a_val = initial.phnum } };
        meta += @sizeOf(std.elf.Auxv);
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_ENTRY, .a_un = .{ .a_val = initial.entry } };
        meta += @sizeOf(std.elf.Auxv);
        @as(*std.elf.Auxv, @ptrFromInt(meta)).* = .{ .a_type = std.elf.AT_NULL, .a_un = .{ .a_val = 0 } };
        meta += @sizeOf(std.elf.Auxv);
        // meta == stack_ptr.value + metadata_size; string data follows here.

        // Copy argv strings into user stack and back-fill the pointer table.
        if (argc > 0) {
            const lens_base = @sizeOf(usize);
            var flat_str_offset: usize = @sizeOf(usize) * (1 + argc);
            var str_ptr: usize = meta;

            for (0..argc) |i| {
                const str_len = std.mem.readInt(
                    usize,
                    initial.flat_argv[lens_base + i * @sizeOf(usize) ..][0..@sizeOf(usize)],
                    .little,
                );
                // Write argv[i] pointer.
                @as(*usize, @ptrFromInt(argv_ptrs_base + i * @sizeOf(usize))).* = str_ptr;
                // Copy string bytes then add null terminator.
                if (str_len > 0) {
                    @memcpy(
                        @as([*]u8, @ptrFromInt(str_ptr))[0..str_len],
                        initial.flat_argv[flat_str_offset..][0..str_len],
                    );
                }
                @as(*u8, @ptrFromInt(str_ptr + str_len)).* = 0;
                str_ptr += str_len + 1;
                flat_str_offset += str_len;
            }
        }
    }

    log.debug("starting userspace process: {f}", .{self});

    // Free kernel argv buffer before entering userspace; defers in the caller
    // won't run on the noreturn success path.
    if (initial.flat_argv.len > 0) innigkeit.mem.heap.allocator.free(initial.flat_argv);

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
        architecture.user.initializeThread(thread);

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
    var cache: innigkeit.mem.cache.Cache(
        Thread,
        .{
            .constructor = struct {
                fn constructor(thread: *Thread) innigkeit.mem.cache.ConstructorError!void {
                    if (core.is_debug) thread.* = undefined;
                    thread.task.stack = try .createStack();
                    errdefer thread.task.stack.destroyStack();
                    try architecture.user.createThread(thread);
                }
            }.constructor,
            .destructor = struct {
                fn destructor(thread: *Thread) void {
                    architecture.user.destroyThread(thread);
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
