const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

pub const panic = innigkeit.debug.panic_interface;

pub const std_options: std.Options = .{
    .log_level = innigkeit.debug.log.log_level.toStd(),
    .logFn = innigkeit.debug.log.stdLogImpl,

    .page_size_min = architecture.paging.standard_page_size.value,
    .page_size_max = architecture.paging.largest_page_size.value,
    .queryPageSize = struct {
        fn queryPageSize() usize {
            return architecture.paging.standard_page_size.value;
        }
    }.queryPageSize,

    .side_channels_mitigations = .full,
};

pub const std_options_debug_io: std.Io = undefined;
pub const debug = innigkeit.debug.interop;

comptime {
    @import("boot").exportEntryPoints();
}
