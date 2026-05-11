const innigkeit = @import("innigkeit");
const init_log = innigkeit.debug.log.scoped(.cache_init);

const globals = @import("globals.zig");

pub fn initializeCaches() !void {
    init_log.debug("initializing slab cache", .{});
    globals.slab_cache.init(.{
        .name = try .fromSlice("slab"),
        .slab_source = .pmm,
    });

    init_log.debug("initializing large item cache", .{});
    globals.large_item_cache.init(.{
        .name = try .fromSlice("large item"),
        .slab_source = .pmm,
    });
}
