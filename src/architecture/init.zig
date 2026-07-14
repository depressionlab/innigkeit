//! Functionality that is used during kernel init only.

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

/// Read current wallclock time from the standard wallclock source of the current architecture.
///
/// For example on x86_64 this is the TSC.
pub fn getStandardWallclockStartTime() innigkeit.time.wallclock.Tick {
    return architecture.getFunction(
        architecture.current_functions.init,
        "getStandardWallclockStartTime",
    )();
}

pub const InitOutput = struct {
    output: Output,
    preference: Preference,

    pub const Output = innigkeit.init.Output;

    pub const Preference = enum {
        /// Use this output.
        use,

        /// Only use this output if a generic output is not available.
        prefer_generic,
    };
};

/// Attempt to get some form of architecture specific init output if it is available.
///
/// If `memory_system_available` is false, then the memory system has not been initialized so heap allocation and the special heap are
/// not available.
///
/// The first time this function is called `memory_system_available` will be false, this function will be called again after the memory
/// system is initialized with `memory_system_available` set to true, but only if a generic serial output was not available without
/// needing the memory system.
pub fn tryGetSerialOutput(memory_system_available: bool) callconv(core.inline_in_non_debug) ?InitOutput {
    return architecture.getFunction(
        architecture.current_functions.init,
        "tryGetSerialOutput",
    )(memory_system_available);
}

/// Prepares the executor as the bootstrap executor.
pub fn prepareBootstrapExecutor(
    executor: *innigkeit.Executor,
    architecture_processor_id: u64,
) callconv(core.inline_in_non_debug) void {
    architecture.current_functions.init.prepareBootstrapExecutor(executor, architecture_processor_id);
}

/// Prepares the provided `Executor` for use.
///
/// **WARNING**: This function will panic if the cpu cannot be prepared.
pub fn prepareExecutor(
    executor: *innigkeit.Executor,
    architecture_processor_id: u64,
) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.init,
        "prepareExecutor",
    )(executor, architecture_processor_id);
}

/// Initialize the executor.
///
/// ** REQUIREMENTS **:
/// - Must be called by the executor represented by `executor`
pub fn initExecutor(executor: *innigkeit.Executor) callconv(core.inline_in_non_debug) void {
    architecture.current_functions.init.initExecutor(executor);
}

pub const CaptureSystemInformationStage = enum {
    /// Capture any system information that can be without using MMIO.
    ///
    /// For example, on x64 this should capture CPUID but not APIC or ACPI information.
    early,

    /// Capture any system information that needs mmio.
    ///
    /// For example, on x64 this should capture APIC and ACPI information.
    full,
};

pub const CaptureSystemInformationOptions = architecture.current_decls.init.CaptureSystemInformationOptions;

/// Capture any system information that needs mmio.
///
/// For example, on x64 this should capture APIC and ACPI information.
pub fn captureSystemInformation(
    stage: CaptureSystemInformationStage,
    options: CaptureSystemInformationOptions,
) callconv(core.inline_in_non_debug) anyerror!void {
    return architecture.getFunction(
        architecture.current_functions.init,
        "captureSystemInformation",
    )(stage, options);
}

/// Configure any global system features.
pub fn configureGlobalSystemFeatures() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.init,
        "configureGlobalSystemFeatures",
    )();
}

/// Configure any per-executor system features.
///
/// This function is called in a few different contexts and must leave the system in a reasonable state for each of them:
///  - By the bootstrap executor after calling `captureSystemInformation(.early)`
///  - By the bootstrap executor after calling `captureSystemInformation(.full)`
///  - By every executor after `captureSystemInformation(.full)` has been called
pub fn configurePerExecutorSystemFeatures() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.init,
        "configurePerExecutorSystemFeatures",
    )();
}

/// Register any architectural time sources.
///
/// For example, on x86_64 this should register the TSC, HPEC, PIT, etc.
pub fn registerArchitecturalTimeSources(
    candidate_time_sources: *innigkeit.time.init.CandidateTimeSources,
) callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.init,
        "registerArchitecturalTimeSources",
    )(candidate_time_sources);
}

/// Initialize the local interrupt controller for the current executor.
///
/// For example, on x86_64 this should initialize the APIC.
pub fn initLocalInterruptController() callconv(core.inline_in_non_debug) void {
    architecture.getFunction(
        architecture.current_functions.init,
        "initLocalInterruptController",
    )();
}
