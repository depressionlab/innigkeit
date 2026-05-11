const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.arena);
const globals = @import("globals.zig");

pub fn initializeCaches() !void {
    log.debug("initializing boundary tag cache", .{});
    globals.tag_cache.init(.{
        .name = try .fromSlice("boundary tag"),
        .slab_source = .pmm,
    });
}
