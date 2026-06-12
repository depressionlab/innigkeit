const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const arm = @import("arm.zig");

pub const functions: architecture.Functions = .{
    .spinLoopHint = arm.instructions.isb,
    .halt = arm.instructions.halt,

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

        .init = .{},
    },

    .paging = .{
        .createPageTable = arm.PageTable.create,
        .copyTopLevelIntoPageTable = arm.PageTable.copyTopLevelIntoPageTable,
        .enableAccessToUserMemory = arm.pan.enableAccessToUserMemory,
        .disableAccessToUserMemory = arm.pan.disableAccessToUserMemory,

        .init = .{
            .sizeOfTopLevelEntry = arm.PageTable.sizeOfTopLevelEntry,
        },
    },

    .user = .{
        .syscallFromSyscallFrame = arm.SyscallFrame.syscall,
        .argFromSyscallFrame = arm.SyscallFrame.arg,

        .init = .{},
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

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() innigkeit.time.wallclock.Tick {
                return @enumFromInt(arm.instructions.readPhysicalCount());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(memory_system_available: bool) ?architecture.init.InitOutput {
                _ = memory_system_available;
                // Return the PL011 UART at the QEMU virt base address.
                return arm.pl011.getInitOutput(arm.pl011.UART_BASE);
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

        .initExecutor = struct {
            fn initExecutor(
                executor: *innigkeit.Executor,
            ) void {
                // Use SP_EL1 as the stack pointer while running at EL1.
                arm.registers.spSel1();

                // Install the exception vector table.
                arm.registers.VBAR_EL1.write(@intFromPtr(&arm.vectors.vector_table));

                // Record the CPU affinity register for this executor.
                executor.arch_specific.mpidr = arm.registers.MPIDR_EL1.read();

                // Engage PAN (Privileged Access Never, SMAP equivalent) on
                // this executor if FEAT_PAN is implemented.
                arm.pan.init();

                // Initialise the GICv2 and generic timer for this CPU.
                arm.gic.init();
                arm.timer.init();
                arm.gic.registerHandler(arm.timer.IRQ, arm.timer.irqHandler);
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
