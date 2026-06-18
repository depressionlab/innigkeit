//! This contains the functions that the architecture specific code must implement.
//!
//! Any optional functions that are not implemented will result in runtime panics when called.

const innigkeit = @import("innigkeit");
const core = @import("core");
const architecture = @import("architecture");

/// Issues an architecture specific hint to the executor that we are spinning in a loop.
spinLoopHint: ?fn () callconv(.@"inline") void = null,

/// Write a string to an architecture debug channel that works prior to
/// ANY kernel initialization (no MMU mappings, no allocators, no output devices).
///
/// - arm: QEMU semihosting
/// - x64: could be port `0xe9` (not currently wired)
///
/// `null` means early boot is silent until the regular output path comes up.
earlyDebugWrite: ?fn (s: []const u8) void = null,

/// Halts the current executor.
halt: ?fn () callconv(.@"inline") void = null,

interrupts: struct {
    /// Disables interrupts and halts the current executor.
    ///
    /// Non-optional because it is used during early initialization.
    disableAndHalt: fn () callconv(.@"inline") noreturn,

    /// Returns whether interrupts are enabled.
    areEnabled: ?fn () callconv(.@"inline") bool = null,

    /// Enables interrupts.
    enable: ?fn () callconv(.@"inline") void = null,

    /// Disables interrupts.
    ///
    /// Non-optional because it is used during early initialization.
    disable: fn () callconv(.@"inline") void,

    /// Send a panic IPI to all other executors.
    sendPanicIPI: ?fn () void = null,

    /// Send a flush IPI to the given executor.
    sendFlushIPI: ?fn (executor: *innigkeit.Executor) void = null,

    /// Send a reschedule IPI to the given executor.
    ///
    /// The IPI's only job is to break the target executor out of its idle
    /// halt so it re-checks its runqueue immediately. Optional: architectures
    /// without it fall back to the periodic tick for idle pickup (callers
    /// must check `architecture.interrupts.reschedule_ipi_available`).
    sendRescheduleIPI: ?fn (executor: *innigkeit.Executor) void = null,

    /// Get the EOI type for the given external interrupt if known.
    eoiType: ?fn (external_interrupt: u32) ?architecture.interrupts.Interrupt.Handler.EOI = null,

    allocateInterrupt: ?fn (
        handler: architecture.interrupts.Interrupt.Handler,
    ) architecture.interrupts.Interrupt.AllocateError!architecture.current_decls.interrupts.Interrupt = null,

    deallocateInterrupt: ?fn (interrupt: architecture.current_decls.interrupts.Interrupt) void = null,

    routeInterrupt: ?fn (
        interrupt: architecture.current_decls.interrupts.Interrupt,
        external_interrupt: u32,
    ) architecture.interrupts.Interrupt.RouteError!void = null,

    /// Route the given interrupt to a PCI INTx GSI (level-triggered, active-low).
    routeInterruptPci: ?fn (
        interrupt: architecture.current_decls.interrupts.Interrupt,
        gsi: u32,
    ) architecture.interrupts.Interrupt.RouteError!void = null,

    /// Provides the context this interrupt was triggered from.
    fillContext: ?fn (
        interrupt_frame: *const architecture.current_decls.interrupts.InterruptFrame,
        context: *@import("std").debug.cpu_context.Native,
    ) void = null,

    /// Returns the instruction pointer of the context this interrupt was triggered from.
    instructionPointer: ?fn (interrupt_frame: *const architecture.current_decls.interrupts.InterruptFrame) innigkeit.VirtualAddress = null,

    init: struct {
        /// Ensure that any exceptions/faults that occur during early initialization are handled.
        ///
        /// The handler is not expected to do anything other than panic.
        initializeEarlyInterrupts: ?fn () void = null,

        /// Prepare interrupt allocation and routing.
        initializeInterruptRouting: ?fn () void = null,

        /// Switch away from the initial interrupt handlers installed by `initInterrupts` to the standard
        /// system interrupt handlers.
        loadStandardInterruptHandlers: ?fn () void = null,
    },
},

paging: struct {
    /// Create a page table in the given physical page.
    ///
    /// **REQUIREMENTS**:
    /// - The provided physical page must be accessible in the direct map.
    createPageTable: ?fn (physical_page: innigkeit.mem.PhysicalPage.Index) *architecture.current_decls.paging.PageTable = null,

    loadPageTable: ?fn (physical_page: innigkeit.mem.PhysicalPage.Index) void = null,

    /// Copies the top level of `page_table` into `target_page_table`.
    copyTopLevelIntoPageTable: ?fn (
        page_table: *architecture.current_decls.paging.PageTable,
        target_page_table: *architecture.current_decls.paging.PageTable,
    ) void = null,

    /// Maps `virtual_address` to `physical_page` with mapping type `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual address is aligned to the standard page size
    ///  - the virtual address is not already mapped
    ///  - `map_type.protection` is not `.none`
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    mapSinglePage: ?fn (
        page_table: *architecture.current_decls.paging.PageTable,
        virtual_address: innigkeit.VirtualAddress,
        physical_page: innigkeit.mem.PhysicalPage.Index,
        map_type: innigkeit.mem.MapType,
        physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
    ) innigkeit.mem.MapError!void = null,

    /// Unmaps the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///
    /// This function:
    ///  - does not flush the TLB
    unmap: ?fn (
        page_table: *architecture.current_decls.paging.PageTable,
        virtual_range: innigkeit.VirtualRange,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        flush_batch: *innigkeit.mem.VirtualRangeBatch,
        deallocate_page_list: *innigkeit.mem.PhysicalPage.List,
    ) void = null,

    /// Changes the protection of the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - `new_map_type` protection is not `.none`
    ///
    /// This function:
    ///  - does not flush the TLB
    changeProtection: ?fn (
        page_table: *architecture.current_decls.paging.PageTable,
        virtual_range: innigkeit.VirtualRange,
        previous_map_type: innigkeit.mem.MapType,
        new_map_type: innigkeit.mem.MapType,
        flush_batch: *innigkeit.mem.VirtualRangeBatch,
    ) void = null,

    /// Flushes the cache for the given virtual range on the current executor.
    ///
    /// Caller must ensure:
    ///   - the `virtual_range` address and size must be aligned to the standard page size
    flushCache: ?fn (virtual_range: innigkeit.VirtualRange) void = null,

    /// Enable the kernel to access user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    enableAccessToUserMemory: ?fn () void = null,

    /// Disable the kernel from accessing user memory.
    ///
    /// This is allowed to be a no-op if the architecture does not support stopping the kernel from accessing user
    /// memory.
    disableAccessToUserMemory: ?fn () void = null,

    init: struct {
        /// The total size of the virtual address space that one entry in the top level of the page table covers.
        sizeOfTopLevelEntry: ?fn () core.Size = null,

        /// This function fills in the top level of the page table for the given range.
        ///
        /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
        ///
        /// This function:
        ///  - does not flush the TLB
        ///  - does not rollback on error
        fillTopLevel: ?fn (
            page_table: *architecture.current_decls.paging.PageTable,
            range: innigkeit.VirtualRange,
            physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
        ) anyerror!void = null,

        /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
        ///
        /// Caller must ensure:
        ///  - the virtual range address and size are aligned to the standard page size
        ///  - the physical range address and size are aligned to the standard page size
        ///  - the virtual range size is equal to the physical range size
        ///  - the virtual range is not already mapped
        ///  - `map_type.protection` is not `.none`
        ///
        /// This function:
        ///  - uses all page sizes available to the architecture
        ///  - does not flush the TLB
        ///  - does not rollback on error
        mapToPhysicalRangeAllPageSizes: ?fn (
            page_table: *architecture.current_decls.paging.PageTable,
            virtual_range: innigkeit.VirtualRange,
            physical_range: innigkeit.PhysicalRange,
            map_type: innigkeit.mem.MapType,
            physical_page_allocator: innigkeit.mem.PhysicalPage.Allocator,
        ) anyerror!void = null,
    },
},

user: struct {
    /// Create the `PerThread` data of a thread.
    ///
    /// Non-architecture specific creation has already been performed but no initialization.
    ///
    /// This function is called in the `Thread` cache constructor.
    createThread: ?fn (
        thread: *innigkeit.user.Thread,
    ) innigkeit.mem.cache.ConstructorError!void = null,

    /// Destroy the `PerThread` data of a thread.
    ///
    /// Non-architecture specific destruction has not already been performed.
    ///
    /// This function is called in the `Thread` cache destructor.
    destroyThread: ?fn (thread: *innigkeit.user.Thread) void = null,

    /// Initialize the `PerThread` data of a thread.
    ///
    /// All non-architecture specific initialization has already been performed.
    ///
    /// This function is called in `Thread.internal.create`.
    initializeThread: ?fn (thread: *innigkeit.user.Thread) void = null,

    /// Enter userspace for the first time in the current task.
    enterUserspace: ?fn (options: architecture.user.EnterUserspaceOptions) noreturn = null,

    /// Get the syscall this frame represents.
    syscallFromSyscallFrame: ?fn (
        syscall_frame: *const architecture.current_decls.user.SyscallFrame,
    ) callconv(.@"inline") ?@import("libinnigkeit").Syscall = null,

    /// Get an argument from this frame.
    argFromSyscallFrame: ?fn (
        syscall_frame: *const architecture.current_decls.user.SyscallFrame,
        comptime argument: architecture.user.SyscallFrame.Arg,
    ) callconv(.@"inline") usize = null,

    /// Write the syscall return value into this frame's return register.
    ///
    /// The arch knows its own ABI (rax on x86-64, x0 on AArch64); the generic
    /// dispatcher must never name a physical register.
    setReturnValueOnSyscallFrame: ?fn (
        syscall_frame: *architecture.current_decls.user.SyscallFrame,
        value: usize,
    ) callconv(.@"inline") void = null,

    init: struct {
        /// Perform any per-achitecture initialization needed for userspace processes/threads.
        initialize: ?fn () anyerror!void = null,
    },
},

scheduling: struct {
    /// Perform architecture specific task initialization.
    ///
    /// This function is called very early during init so cannot use any kernel subsystems.
    initializeTaskArchSpecific: fn (task: *innigkeit.Task) void,

    /// Get the current `Task`.
    ///
    /// Supports being called with interrupts and preemption enabled.
    getCurrentTask: ?fn () callconv(.@"inline") *innigkeit.Task = null,

    /// Set the current task.
    ///
    /// Supports being called with interrupts and preemption enabled.
    setCurrentTask: ?fn (task: *innigkeit.Task) callconv(.@"inline") void = null,

    /// Prepares the given task for being scheduled.
    ///
    /// Ensures that when the task is scheduled it will unlock the scheduler lock then call the `type_erased_call`.
    ///
    /// This function *must* be called before the task is scheduled and can only be called once.
    prepareTaskForScheduling: ?fn (
        task: *innigkeit.Task,
        type_erased_call: core.TypeErasedCall,
    ) void = null,

    /// Called before `transition.old_task` is switched to `transition.new_task`.
    ///
    /// Page table switching and managing ability to access user memory has already been performed before this function is called.
    ///
    /// Interrupts are disabled when this function is called.
    beforeSwitchTask: ?fn (transition: innigkeit.Task.Transition) void = null,

    /// Switches to `new_task`.
    ///
    /// The state of `old_task` is saved to allow it to be resumed later.
    ///
    /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
    switchTask: ?fn (old_task: *innigkeit.Task, new_task: *innigkeit.Task) callconv(.@"inline") void = null,

    /// Switches to `new_task`.
    ///
    /// **Note**: It is the caller's responsibility to call `beforeSwitchTask` before calling this function.
    switchTaskNoSave: ?fn (new_task: *innigkeit.Task) callconv(.@"inline") noreturn = null,

    /// Calls `type_erased_call` on `new_stack` and saves the state of `old_task`.
    call: ?fn (
        old_task: *innigkeit.Task,
        new_stack: *innigkeit.Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(.@"inline") void = null,

    /// Calls `type_erased_call` on `new_stack`.
    callNoSave: ?fn (
        new_stack: *innigkeit.Task.Stack,
        type_erased_call: core.TypeErasedCall,
    ) callconv(.@"inline") noreturn = null,
},

io: struct {
    readPciU8: ?fn (address: innigkeit.KernelVirtualAddress) u8 = null,
    readPciU16: ?fn (address: innigkeit.KernelVirtualAddress) u16 = null,
    readPciU32: ?fn (address: innigkeit.KernelVirtualAddress) u32 = null,

    writePciU8: ?fn (address: innigkeit.KernelVirtualAddress, value: u8) void = null,
    writePciU16: ?fn (address: innigkeit.KernelVirtualAddress, value: u16) void = null,
    writePciU32: ?fn (address: innigkeit.KernelVirtualAddress, value: u32) void = null,

    readPortU8: ?fn (port: architecture.current_decls.io.Port) u8 = null,
    readPortU16: ?fn (port: architecture.current_decls.io.Port) u16 = null,
    readPortU32: ?fn (port: architecture.current_decls.io.Port) u32 = null,

    writePortU8: ?fn (port: architecture.current_decls.io.Port, value: u8) void = null,
    writePortU16: ?fn (port: architecture.current_decls.io.Port, value: u16) void = null,
    writePortU32: ?fn (port: architecture.current_decls.io.Port, value: u32) void = null,
},

init: struct {
    /// Read current wallclock time from the standard wallclock source of the current architecture.
    ///
    /// For example on x86_64 this is the TSC.
    ///
    /// Non-optional because it is used during early initialization.
    getStandardWallclockStartTime: fn () innigkeit.time.wallclock.Tick,

    /// Attempt to get some form of architecture specific init output if it is available.
    ///
    /// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
    /// not available.
    ///
    /// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
    /// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
    /// needing the memory system.
    tryGetSerialOutput: fn (memory_system_available: bool) ?architecture.init.InitOutput,

    /// Prepares the executor as the bootstrap executor.
    prepareBootstrapExecutor: fn (executor: *innigkeit.Executor, u64) void,

    /// Prepares the provided `Executor` for use.
    ///
    /// **WARNING**: This function will panic if the cpu cannot be prepared.
    prepareExecutor: ?fn (
        executor: *innigkeit.Executor,
        architecture_processor_id: u64,
    ) void = null,

    initExecutor: fn (executor: *innigkeit.Executor) void, // non-null as the bootstrap executor needs to call this early

    /// Capture system information.
    captureSystemInformation: ?fn (
        stage: architecture.init.CaptureSystemInformationStage,
        options: architecture.current_decls.init.CaptureSystemInformationOptions,
    ) anyerror!void = null,

    /// Configure any global system features.
    configureGlobalSystemFeatures: ?fn () void = null,

    /// Configure any per-executor system features.
    configurePerExecutorSystemFeatures: ?fn () void = null,

    /// Register any architectural time sources.
    ///
    /// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
    registerArchitecturalTimeSources: ?fn (candidate_time_sources: *innigkeit.time.init.CandidateTimeSources) void = null,

    /// Initialize the local interrupt controller for the current executor.
    ///
    /// For example, on x86_64 this should initialize the APIC.
    initLocalInterruptController: ?fn () void = null,
},
