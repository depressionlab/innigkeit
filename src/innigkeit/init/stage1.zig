const std = @import("std");
const architecture = @import("architecture");
const boot = @import("boot");
const innigkeit = @import("innigkeit");
const builtin = @import("builtin");

const stage2 = @import("stage2.zig");

pub const Output = @import("output/Output.zig");

const log = innigkeit.debug.log.scoped(.init);

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn bootstrap() !noreturn {
    innigkeit.time.init.captureStartTime();

    // we need basic memory layout information to be able to panic
    const early_memory_layout = innigkeit.mem.init.determineEarlyMemoryLayout();

    try loadBootstrapExecutorAndTask();

    // now that we have an executor and task we can panic in a meaningful way
    innigkeit.debug.setPanicMode(.single_executor_init_panic);

    innigkeit.mem.PhysicalPage.init.initializeBootstrapAllocator();

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    const acpi_tables = try innigkeit.acpi.init.earlyInitialize();

    Output.registerOutputs(.early);

    // no that we have basic output we can log the early memory layout and ACPI tables
    early_memory_layout.log();
    try acpi_tables.log();

    log.debug("initializing early interrupts", .{});
    architecture.interrupts.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    const capture_system_information_options: architecture.init.CaptureSystemInformationOptions = switch (architecture.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        .arm, .riscv => .{},
    };
    try architecture.init.captureSystemInformation(.early, capture_system_information_options);

    log.debug("configuring per-executor system features with early system information", .{});
    architecture.init.configurePerExecutorSystemFeatures();

    log.debug("initializing memory system", .{});
    try innigkeit.mem.init.initializeMemorySystem();

    // now the memory system is initialized we can attempt to register outputs again
    Output.registerOutputs(.full);

    log.debug("capturing system information", .{});
    try architecture.init.captureSystemInformation(.full, capture_system_information_options);

    log.debug("configuring per-executor system features with full system information", .{});
    architecture.init.configurePerExecutorSystemFeatures();

    log.debug("configuring global system features", .{});
    architecture.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try innigkeit.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try architecture.interrupts.init.initializeInterruptRouting();

    log.debug("initializing tasks", .{});
    try innigkeit.Task.init.initializeTasks();

    log.debug("initializing user processes and threads", .{});
    try innigkeit.user.init.initialize();

    log.debug("initializing kernel executors", .{});
    const executors, const new_bootstrap_executor = try createExecutors();
    innigkeit.Executor.init.setExecutors(executors);

    if (executors.len > 1) {
        log.debug("booting non-bootstrap executors", .{});
        try bootNonBootstrapExecutors();
    }

    log.info("zig version: {s}", .{builtin.zig_version_string});

    try stage2.start(new_bootstrap_executor);
    unreachable;
}

fn loadBootstrapExecutorAndTask() !void {
    const static = struct {
        var bootstrap_init_task: innigkeit.Task = undefined;
        var bootstrap_executor: innigkeit.Executor = .{
            .id = .bootstrap,
            ._current_task = undefined, // set by `setCurrentTask`
            .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
            .scheduler = undefined, // not used
        };
    };

    try innigkeit.Task.init.initializeBootstrapInitTask(
        &static.bootstrap_init_task,
        &static.bootstrap_executor,
    );

    architecture.init.prepareBootstrapExecutor(
        &static.bootstrap_executor,
        boot.bootstrapArchitectureProcessorId(),
    );
    architecture.init.initExecutor(&static.bootstrap_executor);
    static.bootstrap_executor.setCurrentTask(&static.bootstrap_init_task);

    innigkeit.Executor.init.setExecutors(@ptrCast(&static.bootstrap_executor));
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors() !struct { []innigkeit.Executor, *innigkeit.Executor } {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > innigkeit.config.executor.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'!",
            .{ descriptors.count(), innigkeit.config.executor.maximum_number_of_executors },
        );
    }

    log.debug("initializing {} executors", .{descriptors.count()});

    const executors = try innigkeit.mem.heap.allocator.alloc(innigkeit.Executor, descriptors.count());

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();
    var opt_bootstrap_executor: ?*innigkeit.Executor = null;

    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &executors[i];

        executor.* = .{
            .id = @enumFromInt(i),
            .arch_specific = undefined, // set by `arch.init.prepareExecutor`
            ._current_task = undefined, // set below by `Task.init.createAndAssignInitTask`
            .scheduler = .{
                .task = undefined, // set below by `Task.init.initializeSchedulerTask`
            },
        };

        try innigkeit.Task.init.createAndAssignInitTask(executor);
        try innigkeit.Task.init.initializeSchedulerTask(&executor.scheduler.task, executor);

        architecture.init.prepareExecutor(
            executor,
            desc.architectureProcessorId(),
        );

        if (desc.architectureProcessorId() == bootstrap_architecture_processor_id) {
            opt_bootstrap_executor = executor;
        }
    }

    return .{ executors, opt_bootstrap_executor.? };
}

fn bootNonBootstrapExecutors() !void {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;
    var i: u32 = 0;

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();

    while (descriptors.next()) |desc| : (i += 1) {
        if (desc.architectureProcessorId() == bootstrap_architecture_processor_id) continue;

        desc.boot(
            &innigkeit.Executor.executors()[i],
            struct {
                fn bootFn(inner_executor: *anyopaque) !noreturn {
                    try stage2.start(@ptrCast(@alignCast(inner_executor)));
                }
            }.bootFn,
        );
    }
}
