const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const wallclock = @import("wallclock.zig");
const per_executor_periodic = @import("per_executor_periodic.zig");

const init_log = innigkeit.debug.log.scoped(.time_init);

pub const CandidateTimeSources = @import("CandidateTimeSources.zig");
pub const CandidateTimeSource = @import("CandidateTimeSource.zig");
pub const ReferenceCounter = @import("ReferenceCounter.zig");

/// Attempts to capture the wallclock time at the start of the system using the most likely time source.
///
/// For example on x86_64 this is the TSC.
pub fn captureStartTime() void {
    globals.kernel_start_time = .{
        .kernel_start = architecture.init.getStandardWallclockStartTime(),
    };
}

pub fn initializeTime() !void {
    var candidate_time_sources: CandidateTimeSources = .{};
    architecture.init.registerArchitecturalTimeSources(&candidate_time_sources);

    const time_sources: []CandidateTimeSource = candidate_time_sources.candidate_time_sources.slice();

    const reference_counter = getReferenceCounter(time_sources);

    const wallclock_options = getWallclockTimeSource(time_sources, reference_counter);
    wallclock.globals.readFn = wallclock_options.readFn;
    wallclock.globals.elapsedFn = wallclock_options.elapsedFn;

    const per_executor_periodic_options = getPerExecutorPeriodicTimeSource(
        time_sources,
        reference_counter,
    );
    per_executor_periodic.globals.enableInterruptFn = per_executor_periodic_options.enableInterruptFn;

    switch (globals.kernel_start_time) {
        .kernel_start => |tick| init_log.debug(
            "time initialized {f} after kernel start, spent {f} in firmware and bootloader before kernel start",
            .{
                wallclock.elapsed(tick, wallclock.read()),
                wallclock.elapsed(.zero, tick),
            },
        ),
        .time_system_start => init_log.debug(
            "time initialized {f} after system start (includes early kernel init, firmware and bootloader time)",
            .{
                wallclock.elapsed(.zero, wallclock.read()),
            },
        ),
    }
}

pub fn printInitializationTime() !void {
    innigkeit.init.Output.lock.lock();
    defer innigkeit.init.Output.lock.unlock();

    const t = innigkeit.init.Output.terminal;

    try t.setColor(.green);

    try t.writer.writeAll("initialization complete ");

    try t.setColor(.reset);

    try t.writer.print(
        "- time since kernel start: {f} - time since system start: {f}\n",
        .{
            wallclock.elapsed(
                globals.kernel_start_time.getTick(),
                wallclock.read(),
            ),
            wallclock.elapsed(
                .zero,
                wallclock.read(),
            ),
        },
    );

    try t.setColor(.bright_cyan);

    try t.writer.writeAll("hiiiii :3!\n");

    try t.setColor(.reset);

    try t.writer.flush();
}

fn getReferenceCounter(
    time_sources: []CandidateTimeSource,
) ReferenceCounter {
    const time_source = findAndInitializeTimeSource(time_sources, .{
        .pre_calibrated = true,
        .reference_counter = true,
    }, undefined) orelse
        @panic("no reference counter found!");

    init_log.debug("using reference counter: {s}", .{time_source.name});

    const reference_counter_impl = time_source.reference_counter.?;

    return .{
        ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
        ._waitForFn = reference_counter_impl.waitForFn,
    };
}

fn getWallclockTimeSource(
    time_sources: []CandidateTimeSource,
    reference_counter: ReferenceCounter,
) CandidateTimeSource.WallclockOptions {
    const time_source = findAndInitializeTimeSource(time_sources, .{
        .wallclock = true,
    }, reference_counter) orelse
        @panic("no wallclock found!");

    init_log.debug("using wallclock: {s}", .{time_source.name});

    const wallclock_impl = time_source.wallclock.?;

    if (!wallclock_impl.standard_wallclock_source) {
        init_log.warn(
            "wallclock is not the standard wallclock source - setting kernel start time to now",
            .{},
        );
        globals.kernel_start_time = .{ .time_system_start = wallclock_impl.readFn() };
    }

    return wallclock_impl;
}

fn getPerExecutorPeriodicTimeSource(
    time_sources: []CandidateTimeSource,
    reference_counter: ReferenceCounter,
) CandidateTimeSource.PerExecutorPeriodicOptions {
    const time_source = findAndInitializeTimeSource(time_sources, .{
        .per_executor_periodic = true,
    }, reference_counter) orelse
        @panic("no per-executor periodic found!");

    init_log.debug("using per-executor periodic: {s}", .{time_source.name});

    return time_source.per_executor_periodic.?;
}

const TimeSourceQuery = struct {
    pre_calibrated: bool = false,

    reference_counter: bool = false,

    wallclock: bool = false,

    per_executor_periodic: bool = false,
};

fn findAndInitializeTimeSource(
    time_sources: []CandidateTimeSource,
    query: TimeSourceQuery,
    reference_counter: ReferenceCounter,
) ?*CandidateTimeSource {
    var opt_best_candidate: ?*CandidateTimeSource = null;

    for (time_sources) |*time_source| {
        if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

        if (query.reference_counter and time_source.reference_counter == null) continue;

        if (query.wallclock and time_source.wallclock == null) continue;

        if (query.per_executor_periodic and time_source.per_executor_periodic == null) continue;

        if (opt_best_candidate) |best_candidate| {
            if (time_source.priority > best_candidate.priority) opt_best_candidate = time_source;
        } else {
            opt_best_candidate = time_source;
        }
    }

    if (opt_best_candidate) |best_candidate| best_candidate.initialize(reference_counter);

    return opt_best_candidate;
}

const StartTime = union(enum) {
    /// The wallclock tick at kernel start.
    kernel_start: wallclock.Tick,

    /// The wallclock tick upon initialization of the time system.
    time_system_start: wallclock.Tick,

    inline fn getTick(start_time: StartTime) wallclock.Tick {
        return switch (start_time) {
            .kernel_start => |tick| tick,
            .time_system_start => |tick| tick,
        };
    }
};

const globals = struct {
    /// Upon kernel start this is captured by `init.tryCaptureStandardWallclockStartTime` as variant `.kernel_start`.
    ///
    /// Then upon time system initialization in `initializeTime` if the wallclock source used by
    /// `init.tryCaptureStandardWallclockStartTime` is not the wallclock that is selected by `getWallclockTimeSource` then a
    /// tick is captured from the selected wallclock and is stored as variant `.time_system_start`.
    var kernel_start_time: StartTime = undefined;
};
