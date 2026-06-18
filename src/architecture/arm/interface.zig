const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const arm = @import("arm.zig");

pub const functions: architecture.Functions = .{
    .spinLoopHint = arm.instructions.isb,
    .halt = arm.instructions.halt,
    .earlyDebugWrite = arm.semihost.write,

    .interrupts = .{
        .disableAndHalt = arm.instructions.disableInterruptsAndHalt,
        .areEnabled = arm.instructions.interruptsEnabled,
        .enable = arm.instructions.enableInterrupts,
        .disable = arm.instructions.disableInterrupts,

        .instructionPointer = struct {
            fn instructionPointer(interrupt_frame: *const arm.InterruptFrame) innigkeit.VirtualAddress {
                return interrupt_frame.instructionPointer();
            }
        }.instructionPointer,

        // Single-executor M1: no IPIs are required (a panic on the sole
        // executor simply halts it). Provide a no-op panic IPI so the panic
        // path does not itself panic on a null slot.
        .sendPanicIPI = struct {
            fn sendPanicIPI() void {}
        }.sendPanicIPI,

        // PCI INTx routing for virtio (M2 storage): allocate a generic handler
        // and bind it to a GIC SPI. See `arm/interrupts.zig`.
        .allocateInterrupt = arm.interrupts.allocate,
        .deallocateInterrupt = arm.interrupts.deallocate,
        .routeInterruptPci = arm.interrupts.routeInterruptPci,

        .init = .{
            // The exception vector table is installed in `initExecutor`
            // (VBAR_EL1) and its handlers dump faults via semihosting and then
            // panic.
            .initializeEarlyInterrupts = struct {
                fn initializeEarlyInterrupts() void {}
            }.initializeEarlyInterrupts,

            // GIC-based routing is brought up in `configurePerExecutorSystemFeatures`
            // / the timer path; there is no separate routing table to build for
            // the single-executor M1 bring-up.
            .initializeInterruptRouting = struct {
                fn initializeInterruptRouting() void {}
            }.initializeInterruptRouting,

            .loadStandardInterruptHandlers = struct {
                fn loadStandardInterruptHandlers() void {}
            }.loadStandardInterruptHandlers,
        },
    },

    .paging = .{
        .createPageTable = arm.PageTable.create,
        .loadPageTable = arm.PageTable.loadPageTable,
        .copyTopLevelIntoPageTable = arm.PageTable.copyTopLevelIntoPageTable,
        .mapSinglePage = arm.PageTable.mapSinglePage,
        .unmap = arm.PageTable.unmap,
        .changeProtection = arm.PageTable.changeProtection,
        .flushCache = arm.PageTable.flushCache,
        .enableAccessToUserMemory = arm.pan.enableAccessToUserMemory,
        .disableAccessToUserMemory = arm.pan.disableAccessToUserMemory,

        .init = .{
            .sizeOfTopLevelEntry = arm.PageTable.sizeOfTopLevelEntry,
            .fillTopLevel = arm.PageTable.init.fillTopLevel,
            .mapToPhysicalRangeAllPageSizes = arm.PageTable.init.mapToPhysicalRangeAllPageSizes,
        },
    },

    .user = .{
        .createThread = arm.user.createThread,
        .destroyThread = arm.user.destroyThread,
        .initializeThread = arm.user.initializeThread,
        .enterUserspace = arm.user.enterUserspace,
        .syscallFromSyscallFrame = arm.SyscallFrame.syscall,
        .argFromSyscallFrame = arm.SyscallFrame.arg,
        .setReturnValueOnSyscallFrame = arm.SyscallFrame.setReturnValue,

        .init = .{
            .initialize = arm.user.init.initialize,
        },
    },

    .scheduling = .{
        .initializeTaskArchSpecific = arm.PerTask.initializeTaskArchSpecific,

        .getCurrentTask = struct {
            inline fn getCurrentTask() *innigkeit.Task {
                return @ptrFromInt(arm.registers.TPIDR_EL1.read());
            }
        }.getCurrentTask,
        .setCurrentTask = struct {
            inline fn setCurrentTask(task: *innigkeit.Task) void {
                arm.registers.TPIDR_EL1.write(@intFromPtr(task));
            }
        }.setCurrentTask,

        .prepareTaskForScheduling = arm.scheduling.prepareTaskForScheduling,
        .beforeSwitchTask = arm.scheduling.beforeSwitchTask,
        .switchTask = arm.scheduling.switchTask,
        .switchTaskNoSave = arm.scheduling.switchTaskNoSave,
        .call = arm.scheduling.call,
        .callNoSave = arm.scheduling.callNoSave,
    },

    .io = .{
        // PCI ECAM config-space access: plain MMIO at the ECAM kernel virtual
        // address (mapped Device-nGnRE by `pci/init.zig`). There is no port I/O
        // on the QEMU virt machine, so the `readPort*`/`writePort*` slots stay
        // null (`Port` is `enum(u0)`); the virtio legacy transport reaches its
        // memory BAR through `PortIo`'s MMIO path instead.
        .readPciU8 = struct {
            fn readPciU8(address: innigkeit.KernelVirtualAddress) u8 {
                return arm.instructions.readPciU8(address);
            }
        }.readPciU8,
        .readPciU16 = struct {
            fn readPciU16(address: innigkeit.KernelVirtualAddress) u16 {
                return arm.instructions.readPciU16(address);
            }
        }.readPciU16,
        .readPciU32 = struct {
            fn readPciU32(address: innigkeit.KernelVirtualAddress) u32 {
                return arm.instructions.readPciU32(address);
            }
        }.readPciU32,
        .writePciU8 = struct {
            fn writePciU8(address: innigkeit.KernelVirtualAddress, value: u8) void {
                arm.instructions.writePciU8(address, value);
            }
        }.writePciU8,
        .writePciU16 = struct {
            fn writePciU16(address: innigkeit.KernelVirtualAddress, value: u16) void {
                arm.instructions.writePciU16(address, value);
            }
        }.writePciU16,
        .writePciU32 = struct {
            fn writePciU32(address: innigkeit.KernelVirtualAddress, value: u32) void {
                arm.instructions.writePciU32(address, value);
            }
        }.writePciU32,
    },

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() innigkeit.time.wallclock.Tick {
                return @enumFromInt(arm.instructions.readPhysicalCount());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(memory_system_available: bool) ?architecture.init.InitOutput {
                // Before the memory system is up the device-MMIO hole is not
                // mapped (Limine's HHDM does not cover it), so any PL011 access
                // would translation-fault. Early tracing relies on semihosting
                // (`earlyDebugWrite`) instead; the PL011 is registered at the
                // `.full` stage once `initializeMemorySystem` has mapped its
                // MMIO Device-nGnRE into the direct map.
                if (!memory_system_available) return null;

                // Reach the PL011 through the direct map (its MMIO is mapped by
                // `arm.PageTable.mapDeviceMmio`).
                const phys: innigkeit.PhysicalAddress = .from(arm.pl011.UART_BASE);
                const virtual_base = phys.toDirectMap().toVirtualAddress().value;
                return arm.pl011.getInitOutput(virtual_base);
            }
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                executor: *innigkeit.Executor,
                architecture_processor_id: u64,
            ) void {
                executor.arch_specific = .{
                    .mpidr = architecture_processor_id,
                };
            }
        }.prepareBootstrapExecutor,

        .prepareExecutor = arm.init.prepareExecutor,
        .captureSystemInformation = arm.init.captureSystemInformation,
        .configureGlobalSystemFeatures = arm.init.configureGlobalSystemFeatures,
        .configurePerExecutorSystemFeatures = arm.init.configurePerExecutorSystemFeatures,
        .registerArchitecturalTimeSources = arm.init.registerArchitecturalTimeSources,
        .initLocalInterruptController = arm.init.initLocalInterruptController,

        .initExecutor = struct {
            fn initExecutor(executor: *innigkeit.Executor) void {
                // Install the exception vector table first, so any subsequent
                // fault produces a diagnosable exception (with VBAR_EL1 unset
                // a fault vectors to physical 0 and is unrecoverable).
                arm.registers.VBAR_EL1.write(@intFromPtr(&arm.vectors.vector_table));

                // Use SP_EL1 as the stack pointer while running at EL1.
                arm.registers.spSel1();

                // Record the CPU affinity register for this executor.
                executor.arch_specific.mpidr = arm.registers.MPIDR_EL1.read();

                // Engage PAN (Privileged Access Never, SMAP equivalent) on
                // this executor if FEAT_PAN is implemented.
                arm.pan.init();

                // GIC + generic timer bring-up is deliberately NOT here: it
                // touches device MMIO that is only mapped after
                // initializeMemorySystem, so it lives in
                // `arm.init.configurePerExecutorSystemFeatures` (distributor
                // once, CPU interface + timer per-executor).
            }
        }.initExecutor,
    },
};

const standard_page_size: core.Size = .from(4, .kib);

const size_of_address_space_half = core.Size.from(256, .tib).subtract(standard_page_size);

pub const decls: architecture.Decls = .{
    .PerExecutor = struct { mpidr: u64 },

    .interrupts = .{
        .Interrupt = arm.Interrupt,
        .InterruptFrame = arm.InterruptFrame,
    },

    .paging = .{
        .standard_page_size = standard_page_size,
        .largest_page_size = .from(1, .gib),
        .kernel_memory_range = .from(
            innigkeit.VirtualAddress.from(0xffff000000000000),
            size_of_address_space_half,
        ),
        .PageTable = arm.PageTable,
    },

    .scheduling = .{
        .PerTask = arm.PerTask,
        .cfi_prevent_unwinding =
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\
        ,
    },

    .user = .{
        .PerThread = arm.PerThread,
        .SyscallFrame = arm.SyscallFrame,
        .user_memory_range = .from(
            innigkeit.VirtualAddress.zero.moveForward(standard_page_size),
            size_of_address_space_half,
        ),
    },

    .io = .{
        .Port = enum(u0) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = struct {},
    },
};
