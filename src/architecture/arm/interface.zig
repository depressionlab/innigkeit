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

        .init = .{},
    },

    .paging = .{
        .init = .{},
    },

    .user = .{
        .init = .{},
    },

    .scheduling = .{
        .initializeTaskArchSpecific = struct {
            fn initializeTaskArchSpecific(_: *innigkeit.Task) void {}
        }.initializeTaskArchSpecific,

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
    },

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() innigkeit.time.wallclock.Tick {
                return @enumFromInt(arm.instructions.readPhysicalCount()); // TODO: should this be virtual count?
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(memory_system_available: bool) ?architecture.init.InitOutput {
                _ = memory_system_available;
                return null;
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
                _ = executor;
            }
        }.initExecutor,
    },
};

const standard_page_size: core.Size = .from(4, .kib);

const size_of_address_space_half = core.Size.from(256, .tib).subtract(standard_page_size);

pub const decls: architecture.Decls = .{
    .PerExecutor = struct { mpidr: u64 },

    .interrupts = .{
        .Interrupt = enum(u0) { _ },
        .InterruptFrame = extern struct {},
    },

    .paging = .{
        // TODO: most of these values are copied from the x64, so all of them need to be checked
        .standard_page_size = standard_page_size,
        .largest_page_size = .from(1, .gib),
        .kernel_memory_range = .from(
            innigkeit.VirtualAddress.from(0xffff000000000000),
            size_of_address_space_half,
        ),
        .PageTable = extern struct {},
    },

    .scheduling = .{
        .PerTask = struct {},
        .cfi_prevent_unwinding =
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\
        ,
    },

    .user = .{
        .PerThread = struct {},
        .SyscallFrame = struct {},
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
