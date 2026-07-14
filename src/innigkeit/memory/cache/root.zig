// TODO: use `innigkeit.KernelVirtualAddress`, search for `.value`

const core = @import("core");
const innigkeit = @import("innigkeit");

pub const Cache = @import("Cache.zig").Cache;
pub const init = @import("init.zig");
pub const RawCache = @import("RawCache.zig");

pub const RawConstructDestruct = struct {
    constructor: *const fn (item: []u8) ConstructorError!void,
    destructor: *const fn (item: []u8) void,
};

pub fn ConstructDestruct(comptime T: type) type {
    return struct {
        constructor: fn (item: *T) ConstructorError!void,
        destructor: fn (item: *T) void,
    };
}

pub const ConstructorError = error{ItemConstructionFailed};
pub const Name = core.containers.BoundedArray(u8, innigkeit.config.memory.cache_name_length);
pub const isSmallItem = RawCache.isSmallItem;
