//! Represents a userspace process.
const Process = @This();

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");
const log = innigkeit.debug.log.scoped(.user_process);

name: Name,

/// Stable opaque process identifier. Assigned at creation from a global counter.
/// Returned by the getpid syscall.
pid: u64,

/// The number of references to this process.
///
/// Each thread within the process has a reference to the process.
reference_count: std.atomic.Value(usize),

address_space: innigkeit.memory.AddressSpace,

threads_lock: innigkeit.sync.RwLock = .{},
threads: std.array_hash_map.Auto(*innigkeit.user.Thread, void) = .{},

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

/// Set (via compare-exchange) by whichever thread's call to
/// `terminateCallingThread` first decides this process must die, before
/// it touches `exit_status` or any sibling thread.
terminating: std.atomic.Value(bool) = .init(false),

/// Entitlements verified from the binary's .codesig blob at spawn time.
/// The kernel enforces these at syscall boundaries.
/// Processes created directly by the kernel (e.g. init) get all entitlements.
entitlements: innigkeit.user.codesign.Manifest.Entitlements = .{
    .framebuffer = true,
    .storage = true,
    .network = true,
    .keyboard = true,
    .mouse = true,
    .spawn = true,
    .gpu = true,
    .secure_vault = true,
    .internal_service = true,
},

/// Simple flat filesystem open file table.
/// FD 3..14 map to indices 0..11 respectively.
///
/// TODO: refactor file system to the userspace?
open_files: [12]?innigkeit.filesystem.simple_fs.OpenFile = .{null} ** 12,
open_files_lock: innigkeit.sync.TicketSpinLock = .{},

/// Per-process file-descriptor table for the read/write/open/close/lseek/
/// fstat syscalls. Reset explicitly in `create()` (slab reuse invariant).
fd_table: innigkeit.user.FdTable = .{},

pub const CreateOptions = struct {
    name: Name,
};

/// Create a process.
pub fn create(options: CreateOptions) !*Process {
    // TODO: review every single field for slab-reuse issues!!!
    const process = blk: {
        const process = try globals.cache.allocate();
        errdefer globals.cache.deallocate(process);

        // Slab slots are reused without re-running the constructor, so stale
        // entitlements from a previous spawned process persist on reuse.
        // Explicitly reset to full trust here; spawn overwrites with codesig.
        process.entitlements = .{
            .framebuffer = true,
            .storage = true,
            .network = true,
            .keyboard = true,
            .mouse = true,
            .spawn = true,
            .gpu = true,
            .secure_vault = true,
            .internal_service = true,
        };

        // Same slab-reuse invariant: descriptors from a previous process in
        // this slot must not leak into the new one.
        process.fd_table.reset();

        // Same slab-reuse invariant.
        process.open_files = .{null} ** 12;

        // Same slab-reuse invariant: a previous occupant's `terminating`
        // (set true the moment it calls `terminateCallingThread`) must not
        // persist, otherwise this process's own first exit sees the
        // compare-exchange already lost, skipping both `exit_status` and the
        // sibling-kill cascade entirely.
        process.terminating.store(false, .monotonic);

        // Again, you guessed it, same slab-use invariant.
        process.exit_status = 0;
        process.cap_table.init();

        if (core.is_debug) std.debug.assert(process.reference_count.load(.monotonic) == 0);

        process.name = options.name;
        process.pid = globals.next_pid.fetchAdd(1, .monotonic);
        process.next_thread_id.store(0, .monotonic);
        process.address_space.retarget(process);

        globals.processes_lock.writeLock();
        defer globals.processes_lock.writeUnlock();

        const gop = try globals.processes.getOrPut(innigkeit.memory.heap.allocator, process);
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

        const gop = try self.threads.getOrPut(innigkeit.memory.heap.allocator, thread);
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

/// Exit-status convention for a process killed by the kernel rather than
/// exiting on its own: `128 + POSIX signal number`, matching the shell/
/// `wait(2)` "killed by signal" convention. Single source of truth for
/// every kernel-initiated kill path (`process_kill`, the page-fault
/// handler, and per-architecture unhandled-exception isolation) so the
/// mapping only needs deciding once, in one place, and every caller stays
/// consistent as new kill paths are added.
pub const ExitStatus = struct {
    pub const sigill: u8 = 128 + 4; // illegal instruction
    pub const sigtrap: u8 = 128 + 5; // debug/breakpoint trap
    pub const sigbus: u8 = 128 + 7; // alignment/bus error
    pub const sigfpe: u8 = 128 + 8; // arithmetic exception
    pub const sigint: u8 = 128 + 2; // process_kill's force-signal convention
    pub const sigsegv: u8 = 128 + 11; // invalid memory access
};

/// Record `status` as this process's exit status and terminate the calling
/// thread. Does not return.
///
/// Shared by the `exit_process` syscall, the page-fault handler's
/// process-kill path, and per-architecture unhandled-exception isolation
/// (e.g. `architecture/x64/interrupts/handlers.zig`'s `unhandledException`).
///
/// The *first* thread to reach here for a given process (see `terminating`)
/// also marks every sibling thread (`spawn_thread`-created or otherwise) for
/// termination and, where the architecture supports it, sends a kill IPI so
/// one currently running on another executor notices promptly instead of
/// waiting for the next periodic tick (see `forceTerminateSiblings`).
///
/// A second, concurrent call (e.g. a crash racing a sibling's own `exit_process`)
/// skips the cascade and just terminates itself; the first call's cascade already
/// reaches every other sibling, and `exit_status` is no longer written racily since
/// only the winning call touches it.
pub fn terminateCallingThread(self: *Process, status: u8) noreturn {
    if (self.terminating.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        @branchHint(.cold);
        self.exit_status = status;
        self.forceTerminateSiblings();
    }
    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
}

/// Marks every **other** thread of this process for termination (`Task.pending_kill`)
/// and, if the architecture supports it, broadcasts a kill IPI so any of them
/// currently running on another executor notices promptly.
fn forceTerminateSiblings(self: *Process) void {
    self.threads_lock.readLock();
    defer self.threads_lock.readUnlock();

    const current_task = innigkeit.Task.Current.get().task;

    var any_sibling = false;
    var it = self.threads.iterator();
    while (it.next()) |entry| {
        const thread = entry.key_ptr.*;
        if (&thread.task == current_task) continue;
        thread.task.pending_kill.store(true, .release);
        any_sibling = true;
    }

    if (any_sibling and comptime architecture.interrupts.kill_ipi_available)
        architecture.interrupts.sendKillIPI();
}

/// A single already-resolved capability grant, ready to insert into the
/// child's capability table.
///
/// The caller resolves handles against whichever cap table it has access to
/// (e.g. the `spawn` syscall handler resolves against the parent process's
/// table, checking requested rights are a subset of what's held there)
/// *before* calling `spawnFromInitfs`, because `spawnFromInitfs` only
/// performs the child-side insert.
pub const ResolvedCapGrant = struct {
    cap_type: innigkeit.capabilities.ObjectType,
    ptr: *anyopaque,
    rights: innigkeit.capabilities.Rights,
};

pub const SpawnParams = struct {
    /// Initfs path of the ELF to load. Borrowed only for the duration of
    /// `spawnFromInitfs` itself (resolved to an initfs-backed `elf_data`
    /// slice before any process or thread is created); must be no longer
    /// than the `spawn` syscall's own `max_path_len` limit (255 bytes)
    /// enforced there for user input, assumed here for trusted
    /// kernel-internal callers.
    path: []const u8,

    /// Pre-encoded proc_init buffer (argv/envp; see `handlers/spawn.zig`'s
    /// `SpawnSpec` doc comment for the layout). Empty when the child gets no
    /// argv/envp.
    ///
    /// Ownership transfers to `spawnFromInitfs` unconditionally: freed
    /// directly on an early failure, or handed to the spawned thread (which
    /// frees it itself, on every path) once thread creation succeeds.
    proc_init: []u8 = &.{},

    /// Already-resolved capability grants.
    ///
    /// See `ResolvedCapGrant`. Each ref transfers to `spawnFromInitfs`
    /// unconditionally: unref'd directly if it can't be inserted, or
    /// owned by the child's cap table on success.
    cap_grants: []const ResolvedCapGrant = &.{},
};

pub const SpawnResult = struct {
    child: *Process,
    exit_notify: *innigkeit.capabilities.Notify,
};

pub const SpawnError = error{ OutOfMemory, NotFound, PermissionDenied };

/// Kernel-internal spawn: resolve `params.path` against initfs, create a
/// child process, insert already-resolved capability grants, then load the
/// ELF and jump to it in a new thread.
///
/// Mirrors the `spawn` syscall's steps 5-8 (exit-`Notify` creation,
/// `Process.create`, cap-grant insertion, thread creation + queueing);
/// resolution happens before any of those.
///
/// Unlike the syscall, takes no user-memory pointers and never
/// touches a parent's cap table, as the caller is assumed to have
/// already decoded and resolved everything.
///
/// A kernel test can call this directly to spawn a real process without
/// any user-memory/cap-table plumbing.
pub fn spawnFromInitfs(params: SpawnParams) SpawnError!SpawnResult {
    var proc_init_owned = true;
    defer if (proc_init_owned) innigkeit.memory.heap.allocator.free(params.proc_init);
    const resolved = try resolveElfAndEntitlements(params.path);

    // -- 5. Create the exit Notify
    const exit_notify: *innigkeit.capabilities.Notify = try .create();
    // Give an extra ref to the process (so it can signal on exit).
    exit_notify.ref();
    // If we return early the caller ref is freed by the defer below; the
    // process ref is freed once the child process is destroyed.
    var exit_notify_caller_owned = true;
    defer if (exit_notify_caller_owned) exit_notify.unref();

    // -- 6. Create the child process
    const child_process = create(.{
        .name = Name.fromSlice(params.path) catch
            Name.fromSlice(fallback_process_name) catch unreachable,
    }) catch return error.OutOfMemory;
    // create() adds 1 reference; we hold it until we spawn the thread.
    defer child_process.decrementReferenceCount();

    child_process.exit_notify = exit_notify; // process takes ownership of one ref
    child_process.entitlements = resolved.entitlements;

    // -- 7. Insert already-resolved capability grants into the child's table
    if (params.cap_grants.len > 0) {
        child_process.cap_table.lock.lock();
        defer child_process.cap_table.lock.unlock();

        for (params.cap_grants, 0..) |grant, i| {
            _ = child_process.cap_table.insertLocked(grant.cap_type, grant.ptr, grant.rights) catch {
                // This grant and every grant after it are still owned by us;
                // everything before it already transferred to the child's table.
                innigkeit.capabilities.CapabilityTable.unrefObject(grant.cap_type, grant.ptr);
                for (params.cap_grants[i + 1 ..]) |remaining| {
                    innigkeit.capabilities.CapabilityTable.unrefObject(remaining.cap_type, remaining.ptr);
                }
                log.warn("cap grant: child table full", .{});
                return error.OutOfMemory;
            };
        }
    }

    // -- 8. Create the kernel thread that will load the already-resolved ELF.
    // No path is passed through: resolution above already turned it into
    // `resolved.elf_data`, and `child_process.name` was set from it above.
    const proc_init = params.proc_init;

    const load_thread = child_process.createThread(.{
        .entry = .prepare(loadAndStart, .{
            resolved.elf_data.ptr,
            resolved.elf_data.len,
            @as(usize, if (proc_init.len > 0) @intFromPtr(proc_init.ptr) else 0),
            proc_init.len,
        }),
    }) catch return error.OutOfMemory;

    // Transfer proc_init ownership to loadAndStart; disable the defer.
    proc_init_owned = false;

    const scheduler_handle: innigkeit.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&load_thread.task, .{ .initial = true });

    // Caller now owns this ref; don't free it via the defer.
    exit_notify_caller_owned = false;

    return .{ .child = child_process, .exit_notify = exit_notify };
}

/// Fallback process name used when the real name is too long.
const fallback_process_name = "?";

/// Result of resolving an initfs path to an ELF image and its verified
/// entitlements, before any process exists for it.
const ResolvedElf = struct {
    /// Borrowed from the initfs archive, which is static kernel image data
    /// for the life of the kernel. This is safe to hold onto and pass across the
    /// thread that will later parse and map it.
    elf_data: []const u8,
    entitlements: innigkeit.user.codesign.Manifest.Entitlements,
};

/// Look up `path` in initfs and verify its `.codesig` sidecar, without
/// creating a process. Called from `spawnFromInitfs` before `create()` so a
/// spawn that was always going to fail (missing path, missing/invalid
/// signature) never creates a process whose only observable behavior is
/// exiting immediately (see `spawnFromInitfs`'s doc comment).
fn resolveElfAndEntitlements(path: []const u8) SpawnError!ResolvedElf {
    const elf_data = innigkeit.filesystem.initfs.findFile(path) orelse {
        log.err("spawn: '{s}' not found in initfs", .{path});
        return error.NotFound;
    };

    // Build the sidecar name: "<path>.codesig" (255 + 8 bytes: see
    // SpawnParams.path's max-length precondition).
    if (core.is_debug) std.debug.assert(path.len <= 255); // see SpawnParams.path's doc comment
    var sig_name_buf: [255 + 8]u8 = undefined;
    const sig_name = std.fmt.bufPrint(&sig_name_buf, "{s}.codesig", .{path}) catch unreachable;

    const opt_sig_data = innigkeit.filesystem.initfs.findFile(sig_name);

    const entitlements: innigkeit.user.codesign.Manifest.Entitlements = blk: {
        if (opt_sig_data) |sig_data| {
            const result = innigkeit.user.codesign.verify(elf_data, sig_data);
            if (result) |ents| {
                break :blk ents;
            } else |err| {
                log.err("spawn: '{s}' signature verification failed: {s}", .{ path, @errorName(err) });
                // Signature present but invalid: always refuse regardless of mode.
                return error.PermissionDenied;
            }
        } else {
            if (innigkeit.config.security.enforce_code_signing) {
                log.err("spawn: '{s}' has no .codesig and enforcement is on", .{path});
                return error.PermissionDenied;
            }
            log.warn("spawn: '{s}' has no .codesig, proceeding with full entitlements (debug mode)", .{path});
            // In permissive mode grant all entitlements so unsigned dev binaries work.
            break :blk .{
                .framebuffer = true,
                .storage = true,
                .network = true,
                .keyboard = true,
                .mouse = true,
                .spawn = true,
                .gpu = true,
                .secure_vault = true,
            };
        }
    };

    return .{ .elf_data = elf_data, .entitlements = entitlements };
}

/// Kernel thread entry: parse and map an already-resolved ELF, then jump to
/// userspace.
///
/// `elf_data` is borrowed from initfs (static kernel image data, no
/// lifetime concern). Owns proc_init_ptr[0..proc_init_len] when non-zero.
/// On success (noreturn): startProcess frees proc_init. On any return path:
/// defer frees proc_init.
///
/// Owns no reference to `child_process`: returning terminates this thread
/// through the ordinary task-exit path, and `TaskCleanup` drops the
/// thread-membership reference `createThread` took: the same one it
/// drops on a clean exit. Dropping it here as well double-counted it on
/// every load failure.
fn loadAndStart(
    elf_data_ptr: [*]const u8,
    elf_data_len: usize,
    proc_init_ptr: usize,
    proc_init_len: usize,
) void {
    const elf_data = elf_data_ptr[0..elf_data_len];
    // proc_init_ptr is always @intFromPtr of an already kernel heap allocated
    // slice (the one call site above, `params.proc_init`) (not a user pointer)
    // threaded through as a plain usize only because `.prepare`'s thread-entry
    // calling convention takes integer arguments.
    const proc_init: []u8 = if (proc_init_len > 0)
        (@as([*]u8, @ptrFromInt(proc_init_ptr)))[0..proc_init_len] // see comment above
    else
        &.{};

    // proc_init: freed by startProcess on noreturn success; defer handles error returns.
    defer if (proc_init.len > 0) innigkeit.memory.heap.allocator.free(proc_init);

    const current_task: innigkeit.Task.Current = .get();
    const thread: *innigkeit.user.Thread = .from(current_task.task);

    // proc_init ownership transfers to loadAndJump; it frees on noreturn
    // success. The defer above handles it if loadAndJump returns an error.
    innigkeit.user.elf.loader.loadAndJump(thread, elf_data, proc_init) catch |err| {
        log.err("spawn: loadAndJump failed: {t}", .{err});
        return;
    };
    unreachable;
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
        innigkeit.testing.checkpoint.wait(.process_cleanup, process);
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

        // Close any descriptors the process left open (synchronizes writable files;
        // may block on disk I/O, which is fine in this kernel task).
        process.fd_table.closeAll();

        for (&process.open_files) |*maybe_file| {
            if (maybe_file.*) |*file| innigkeit.filesystem.simple_fs.close(file);
            maybe_file.* = null;
        }

        // Release every capability this process ever held before the process
        // goes back to the slab cache.
        process.cap_table.deinitAll();

        process.threads.clearAndFree(innigkeit.memory.heap.allocator);
        process.address_space.reinitializeAndUnmapAll();

        globals.cache.deallocate(process);
    }
};

const globals = struct {
    /// Monotonic counter for stable process IDs.
    var next_pid: std.atomic.Value(u64) = .init(1);

    /// The source of process objects.
    ///
    /// Initialized during `init.initializeCache`.
    var cache: innigkeit.memory.cache.Cache(
        Process,
        .{
            .constructor = struct {
                fn constructor(process: *Process) innigkeit.memory.cache.ConstructorError!void {
                    const temp_name = Process.Name.initPrint("temp {*}", .{process}) catch unreachable;

                    const cap_table = innigkeit.memory.heap.allocator.create(innigkeit.capabilities.CapabilityTable) catch {
                        log.warn("process constructor: cap_table allocation failed", .{});
                        return error.ItemConstructionFailed;
                    };
                    errdefer innigkeit.memory.heap.allocator.destroy(cap_table);
                    cap_table.init();

                    process.* = .{
                        .name = temp_name,
                        .pid = 0, // set in Process.create() via global counter
                        .reference_count = .init(0),
                        .address_space = undefined, // initialized below
                        .cap_table = cap_table,
                    };

                    const page = innigkeit.memory.PhysicalPage.allocator.allocate() catch |err| {
                        log.warn("process constructor failed during page allocation: {t}", .{err});
                        return error.ItemConstructionFailed;
                    };
                    errdefer {
                        var page_list: innigkeit.memory.PhysicalPage.List = .{};
                        page_list.push(page);
                        innigkeit.memory.PhysicalPage.allocator.deallocate(page_list);
                    }

                    const page_table: architecture.paging.PageTable = .create(page);
                    innigkeit.memory.kernelPageTable().copyTopLevelInto(page_table);

                    process.address_space.init(.{
                        .name = innigkeit.memory.AddressSpace.Name.fromSlice(
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
                    innigkeit.memory.heap.allocator.destroy(process.cap_table);

                    const page_table = process.address_space.page_table;

                    process.address_space.deinit();

                    var page_list: innigkeit.memory.PhysicalPage.List = .{};
                    page_list.prepend(page_table.physical_page);
                    innigkeit.memory.PhysicalPage.allocator.deallocate(page_list);
                }
            }.destructor,
        },
    ) = undefined;

    var processes_lock: innigkeit.sync.RwLock = .{};
    var processes: std.array_hash_map.Auto(*Process, void) = .{};

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
