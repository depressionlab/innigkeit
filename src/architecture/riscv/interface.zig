const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

const riscv = @import("riscv.zig");

pub const functions: architecture.Functions = .{
    .spinLoopHint = riscv.instructions.pause,

    .halt = riscv.instructions.halt,

    .interrupts = .{
        .disableAndHalt = riscv.instructions.disableInterruptsAndHalt,
        .areEnabled = riscv.instructions.interruptsEnabled,
        .enable = riscv.instructions.enableInterrupts,
        .disable = riscv.instructions.disableInterrupts,

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
                // safe: setCurrentTask is the only writer, always a real *Task.
                return @ptrFromInt(riscv.registers.SupervisorScratch.read());
            }
        }.getCurrentTask,
        .setCurrentTask = struct {
            inline fn setCurrentTask(task: *innigkeit.Task) void {
                riscv.registers.SupervisorScratch.write(@intFromPtr(task));
            }
        }.setCurrentTask,
    },

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() innigkeit.time.wallclock.Tick {
                return @enumFromInt(riscv.instructions.readTime());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(memory_system_available: bool) ?architecture.init.InitOutput {
                _ = memory_system_available;

                if (riscv.sbi_debug_console.detect()) {
                    return .{
                        .output = riscv.sbi_debug_console.output,
                        .preference = .use,
                    };
                }

                return null;
            }

            const log = innigkeit.debug.log.scoped(.riscv_init);
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                executor: *innigkeit.Executor,
                architecture_processor_id: u64,
            ) void {
                executor.arch_specific = .{
                    .hartid = @intCast(architecture_processor_id),
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
const size_of_address_space_half = core.Size.from(128, .tib).subtract(standard_page_size);
const size_of_user_address_space_half = size_of_address_space_half.subtract(standard_page_size);

pub const decls: architecture.Decls = .{
    .PerExecutor = struct { hartid: u32 },

    .interrupts = .{
        .Interrupt = enum(u0) { _ },
        .InterruptFrame = extern struct {},
    },

    .paging = .{
        // TODO: most of these values are copied from the x64, so all of them need to be checked
        .standard_page_size = standard_page_size,
        .largest_page_size = .from(1, .gib),
        .kernel_memory_range = .from(
            innigkeit.VirtualAddress.from(0xFFFF800000000000),
            size_of_address_space_half,
        ),
        .PageTable = extern struct {},
    },

    .scheduling = .{
        .PerTask = struct {},
        .cfi_prevent_unwinding =
        \\.cfi_sections .debug_frame
        \\.cfi_undefined ra
        \\
        ,
    },

    .user = .{
        .PerThread = struct {},
        .SyscallFrame = struct {},
        .user_memory_range = .from(
            innigkeit.VirtualAddress.zero.moveForward(standard_page_size),
            size_of_user_address_space_half,
        ),
    },

    .io = .{
        .Port = enum(u0) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = struct {},
    },
};
