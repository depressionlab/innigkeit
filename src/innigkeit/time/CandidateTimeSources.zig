const CandidateTimeSources = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const CandidateTimeSource = @import("CandidateTimeSource.zig");

const init_log = innigkeit.debug.log.scoped(.time_init);

candidate_time_sources: core.containers.BoundedArray(
    CandidateTimeSource,
    innigkeit.config.time.maximum_number_of_time_sources,
) = .{},

pub fn addTimeSource(
    candidate_time_sources: *CandidateTimeSources,
    time_source: CandidateTimeSource,
) void {
    if (time_source.reference_counter != null) {
        if (time_source.initialization == .calibration_required) {
            std.debug.panic(
                "reference counter cannot require calibration: {s}!",
                .{time_source.name},
            );
        }
    }

    candidate_time_sources.candidate_time_sources.append(time_source) catch {
        @panic("exceeded maximum number of time sources!");
    };

    init_log.debug("adding time source: {s}", .{time_source.name});
    init_log.debug("  priority: {}", .{time_source.priority});
    init_log.debug("  reference counter: {} - wall clock: {} - per-executor periodic: {}", .{
        time_source.reference_counter != null,
        time_source.wallclock != null,
        time_source.per_executor_periodic != null,
    });
}
