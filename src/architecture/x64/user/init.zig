const innigkeit = @import("innigkeit");
const x64 = @import("../x64.zig");
const globals = @import("globals.zig");

const init_log = innigkeit.debug.log.scoped(.user_init);

/// Perform any per-achitecture initialization needed for userspace processes/threads.
pub fn initialize() !void {
    init_log.debug("initializing xsave area cache", .{});
    globals.xsave_area_cache.init(.{
        .name = try .fromSlice("xsave"),
        .size = x64.info.xsave.xsave_area_size,
        .alignment = .fromByteUnits(64),
    });
}
