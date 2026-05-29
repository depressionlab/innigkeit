//! Represents a userspace process.
const Process = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const log = innigkeit.debug.log.scoped(.user_process);

name: Name,

/// The number of references to this process.
///
/// Each thread within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: innigkeit.mem.AddressSpace,

threads_lock: innigkeit.sync.RwLock = .{},
threads: std.AutoArrayHashMapUnmanaged(*innigkeit.user.Thread, void) = .{},

/// Capability table: maps handle indices to kernel objects.
/// Heap-allocated so that it doesn't inflate the slab cache object size.
cap_table: *innigkeit.capabilities.CapabilityTable,

/// Tracks if this process has been queued for cleanup.
queued_for_cleanup: std.atomic.Value(bool) = .init(false),

/// Used for the process cleanup queue.
cleanup_node: std.SinglyLinkedList.Node = .{},

/// Used for generating thread names.
next_thread_id: std.atomic.Value(usize) = .init(0),

/// Signalled when this process exits (all threads terminate).
/// Created by the spawn syscall and inserted into the spawning process's cap table.
/// May be null for processes created by the kernel (e.g. the initial shell).
exit_notify: ?*innigkeit.capabilities.Notify = null,

/// Exit status set by exit_process syscall; 0 if never set (killed/crashed).
exit_status: u8 = 0,

pub const CreateOptions = struct {
    name: Name,
};

/// Create a process.
pub fn create(options: CreateOptions) !*Process {
    const process = blk: {
        const process = try globals.cache.allocate();
        errdefer globals.cache.deallocate(process);

        if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 0);

        process.name = options.name;
        process.address_space.retarget(process);

        globals.processes_lock.writeLock();
        defer globals.processes_lock.writeUnlock();

        const gop = try globals.processes.getOrPut(innigkeit.mem.heap.allocator, process);
        if (gop.found_existing) @panic("process already in processes list!");

        process.incrementReferenceCount();

        break :blk process;
    };

    log.debug("created process: {f}", .{process});

    return process;
}

pub const CreateThreadOptions = struct {
    name: ?innigkeit.Task.Name = null,
    entry: core.TypeErasedCall,
};

/// Creates a thread in the given process.
///
/// The thread is in the `ready` state and is not scheduled.
pub fn createThread(
    self: *Process,
    options: CreateThreadOptions,
) !*innigkeit.user.Thread {
    const thread = blk: {
        const thread = try innigkeit.user.Thread.internal.create(
            self,
            .{
                .name = if (options.name) |provided_name|
                    provided_name
                else
                    try .initPrint(
                        "{d}",
                        .{self.next_thread_id.fetchAdd(1, .monotonic)},
                    ),
                .type = .user,
                .entry = options.entry,
            },
        );
        errdefer {
            thread.task.state = .{ .terminated = .{} }; // `destroy` will assert this
            thread.task.reference_count.store(0, .monotonic); // `destroy` will assert this
            innigkeit.user.Thread.internal.destroy(thread);
        }

        self.threads_lock.writeLock();
        defer self.threads_lock.writeUnlock();

        const gop = try self.threads.getOrPut(innigkeit.mem.heap.allocator, thread);
        if (gop.found_existing) @panic("thread already in process threads list!");

        self.incrementReferenceCount();

        break :blk thread;
    };

    innigkeit.debug.log.scoped(.user_thread).debug("created thread: {f}", .{thread});

    return thread;
}

pub fn incrementReferenceCount(self: *Process) void {
    _ = self.reference_count.fetchAdd(1, .acq_rel);
}

pub fn decrementReferenceCount(self: *Process) void {
    if (self.reference_count.fetchSub(1, .acq_rel) != 1) {
        @branchHint(.likely);
        return;
    }
    globals.process_cleanup.queueProcessForCleanup(self);
}

/// Returns the process that the given task belongs to.
///
/// Asserts that the task is a user task.
pub inline fn from(task: *innigkeit.Task) *Process {
    if (core.is_debug) std.debug.assert(task.type == .user);
    const thread: *innigkeit.user.Thread = .from(task);
    return thread.process;
}

/// Returns the process that the given task belongs to.
///
/// Asserts that the task is a user task.
pub inline fn fromConst(task: *const innigkeit.Task) *const Process {
    if (core.is_debug) std.debug.assert(task.type == .user);
    const thread: *const innigkeit.user.Thread = .fromConst(task);
    return thread.process;
}

pub fn format(self: *const Process, writer: *std.Io.Writer) !void {
    // TODO: this is a user controlled string
    try writer.print("Process<{s}>", .{self.name.constSlice()});
}

pub const Name = core.containers.BoundedArray(u8, innigkeit.config.user.process_name_length);

const ProcessCleanup = struct {
    task: *innigkeit.Task,
    parker: innigkeit.sync.Parker,
    incoming: core.containers.AtomicSinglyLinkedList,

    pub fn init(self: *ProcessCleanup) !void {
        self.* = .{
            .task = try innigkeit.Task.createKernelTask(.{
                .name = try .fromSlice("process cleanup"),
                .entry = .prepare(ProcessCleanup.execute, .{self}),
            }),
            .parker = undefined, // set below
            .incoming = .{},
        };

        self.parker = .withParkedTask(self.task);
    }

    pub fn queueProcessForCleanup(self: *ProcessCleanup, process: *Process) void {
        if (process.queued_for_cleanup.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) != null) {
            @panic("already queued for cleanup!");
        }

        log.verbose("queueing {f} for cleanup", .{process});

        self.incoming.prepend(&process.cleanup_node);
        self.parker.unpark();
    }

    fn execute(self: *ProcessCleanup) noreturn {
        while (true) {
            while (self.incoming.popFirst()) |node| {
                cleanupProcess(@alignCast(@fieldParentPtr("cleanup_node", node)));
            }

            self.parker.park();
        }
    }

    fn cleanupProcess(process: *Process) void {
        if (core.is_debug) std.debug.assert(process.queued_for_cleanup.load(.monotonic));

        process.queued_for_cleanup.store(false, .release);

        {
            globals.processes_lock.writeLock();
            defer globals.processes_lock.writeUnlock();

            if (process.reference_count.load(.acquire) != 0) {
                @branchHint(.unlikely);
                // someone has acquired a reference to the process after it was queued for cleanup
                log.verbose("{f} still has references", .{process});
                return;
            }

            if (process.queued_for_cleanup.load(.acquire)) {
                @branchHint(.unlikely);
                // someone has requeued this process for cleanup
                log.verbose("{f} has been requeued for cleanup", .{process});
                return;
            }

            if (!globals.processes.swapRemove(process))
                @panic("process not found in processes!");
        }

        log.debug("destroying {f}", .{process});

        // Signal exit watchers before freeing the process.
        if (process.exit_notify) |n| {
            n.signal(@as(u64, 1) | (@as(u64, process.exit_status) << 8));
            n.unref();
            process.exit_notify = null;
        }

        process.threads.clearAndFree(innigkeit.mem.heap.allocator);
        process.address_space.reinitializeAndUnmapAll();

        globals.cache.deallocate(process);
    }
};

const globals = struct {
    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: innigkeit.mem.cache.Cache(
        Process,
        .{
            .constructor = struct {
                fn constructor(process: *Process) innigkeit.mem.cache.ConstructorError!void {
                    const temp_name = Process.Name.initPrint("temp {*}", .{process}) catch unreachable;

                    const cap_table = innigkeit.mem.heap.allocator.create(innigkeit.capabilities.CapabilityTable) catch {
                        log.warn("process constructor: cap_table allocation failed", .{});
                        return error.ItemConstructionFailed;
                    };
                    errdefer innigkeit.mem.heap.allocator.destroy(cap_table);
                    cap_table.init();

                    process.* = .{
                        .name = temp_name,
                        .reference_count = .init(0),
                        .address_space = undefined, // initialized below
                        .cap_table = cap_table,
                    };

                    const page = innigkeit.mem.PhysicalPage.allocator.allocate() catch |err| {
                        log.warn("process constructor failed during page allocation: {t}", .{err});
                        return error.ItemConstructionFailed;
                    };
                    errdefer {
                        var page_list: innigkeit.mem.PhysicalPage.List = .{};
                        page_list.push(page);
                        innigkeit.mem.PhysicalPage.allocator.deallocate(page_list);
                    }

                    const page_table: architecture.paging.PageTable = .create(page);
                    innigkeit.mem.kernelPageTable().copyTopLevelInto(page_table);

                    process.address_space.init(.{
                        .name = innigkeit.mem.AddressSpace.Name.fromSlice(
                            temp_name.constSlice(),
                        ) catch unreachable, // ensured in `innigkeit.config`
                        .range = architecture.user.user_memory_range,
                        .page_table = page_table,
                        .context = .{ .user = process },
                    }) catch |err| {
                        log.warn(
                            "process constructor failed during address space initialization: {t}",
                            .{err},
                        );
                        return error.ItemConstructionFailed;
                    };
                }
            }.constructor,
            .destructor = struct {
                fn destructor(process: *Process) void {
                    process.cap_table.deinitAll();
                    innigkeit.mem.heap.allocator.destroy(process.cap_table);

                    const page_table = process.address_space.page_table;

                    process.address_space.deinit();

                    var page_list: innigkeit.mem.PhysicalPage.List = .{};
                    page_list.prepend(page_table.physical_page);
                    innigkeit.mem.PhysicalPage.allocator.deallocate(page_list);
                }
            }.destructor,
        },
    ) = undefined;

    var processes_lock: innigkeit.sync.RwLock = .{};
    var processes: std.AutoArrayHashMapUnmanaged(*Process, void) = .{};

    /// Initialized during `init.initializeProcesses`.
    var process_cleanup: ProcessCleanup = undefined;
};

pub const init = struct {
    const init_log = innigkeit.debug.log.scoped(.user_init);

    pub fn initializeProcesses() !void {
        init_log.debug("initializing process cache", .{});
        globals.cache.init(.{
            .name = try .fromSlice("process"),
        });

        init_log.debug("initializing process cleanup service", .{});
        try globals.process_cleanup.init();
    }
};
