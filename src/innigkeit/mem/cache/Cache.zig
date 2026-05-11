/// A slab based cache of T.
///
/// Wrapper around `RawCache` that provides a `T`-specifc API.
const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

pub fn Cache(
    comptime T: type,
    comptime construct_destruct: ?innigkeit.mem.cache.ConstructDestruct(T),
) type {
    return struct {
        inner: innigkeit.mem.cache.RawCache,

        const CacheT = @This();

        pub const InitOptions = struct {
            name: innigkeit.mem.cache.Name,

            /// What should happen to the last available slab when it is unused?
            last_slab: core.CleanupDecision = .keep,

            /// The source of slabs.
            ///
            /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
            ///
            /// `.pmm` is only valid for small item caches.
            slab_source: innigkeit.mem.cache.RawCache.InitOptions.SlabSource = .heap,
        };

        /// Initialize the cache.
        pub fn init(self: *CacheT, options: InitOptions) void {
            self.* = .{
                .inner = undefined,
            };

            self.inner.init(.{
                .name = options.name,
                .size = .of(T),
                .alignment = .fromByteUnits(@alignOf(T)),
                .construct_destruct = if (construct_destruct) |con_des| .{
                    .constructor = struct {
                        fn innerConstructor(item: []u8) innigkeit.mem.cache.ConstructorError!void {
                            try con_des.constructor(@ptrCast(@alignCast(item)));
                        }
                    }.innerConstructor,
                    .destructor = struct {
                        fn innerDestructor(item: []u8) void {
                            con_des.destructor(@ptrCast(@alignCast(item)));
                        }
                    }.innerDestructor,
                } else null,
                .last_slab = options.last_slab,
                .slab_source = options.slab_source,
            });
        }

        /// Deinitialize the cache.
        ///
        /// All items must have been deallocated before calling this.
        pub fn deinit(self: *CacheT) void {
            self.inner.deinit();
            self.* = undefined;
        }

        pub fn name(self: *const CacheT) []const u8 {
            return self.inner.name();
        }

        /// Allocate an item from the cache.
        pub fn allocate(self: *CacheT) innigkeit.mem.cache.RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try self.inner.allocate()));
        }

        /// Allocate multiple items from the cache.
        pub fn allocateMany(self: *CacheT, items: []*T) innigkeit.mem.cache.RawCache.AllocateError!void {
            var raw_item_buffer: [16][]u8 = undefined;

            var item_index: usize = 0;
            while (item_index < items.len) {
                const raw_items = raw_item_buffer[0..@min(raw_item_buffer.len, items.len - item_index)];

                try self.inner.allocateMany(raw_items);

                for (items[item_index..][0..raw_items.len], raw_items) |*item, raw_item| {
                    item.* = @ptrCast(@alignCast(raw_item));
                }

                item_index += raw_items.len;
            }
        }

        /// Deallocate an item back to the cache.
        pub fn deallocate(self: *CacheT, item: *T) void {
            self.inner.deallocate(std.mem.asBytes(item));
        }

        /// Deallocate multiple items back to the cache.
        pub fn deallocateMany(self: *CacheT, items: []const *T) void {
            var raw_item_buffer: [16][]u8 = undefined;

            var item_index: usize = 0;
            while (item_index < items.len) {
                const raw_items = raw_item_buffer[0..@min(raw_item_buffer.len, items.len - item_index)];

                for (raw_items, items[item_index..][0..raw_items.len]) |*raw_item, item| {
                    raw_item.* = @ptrCast(@alignCast(item));
                }

                self.inner.deallocateMany(raw_items);

                item_index += raw_items.len;
            }
        }
    };
}
