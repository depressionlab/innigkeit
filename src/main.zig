const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = innigkeit.debug.log.log_level.toStd(),
    .logFn = innigkeit.debug.log.stdLogImpl,

    .page_size_min = @intFromEnum(architecture.paging.standard_page_size),
    .page_size_max = @intFromEnum(architecture.paging.largest_page_size),
    .queryPageSize = struct {
        fn queryPageSize() usize {
            return @intFromEnum(architecture.paging.standard_page_size);
        }
    }.queryPageSize,

    .side_channels_mitigations = .full,
};

pub const std_options_debug_io: std.Io = undefined;
pub const debug = innigkeit.debug.interop;
pub const panic = innigkeit.debug.panic_interface;

comptime {
    @import("boot").exportEntryPoints();
}
