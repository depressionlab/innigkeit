const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// Initialized during `init.initializeCaches`.
pub var slab_cache: innigkeit.memory.cache.Cache(
    innigkeit.memory.cache.RawCache.Slab,
    null,
) = undefined;

/// Initialized during `init.initializeCaches`.
pub var large_item_cache: innigkeit.memory.cache.Cache(
    innigkeit.memory.cache.RawCache.LargeItem,
    null,
) = undefined;

pub const minimum_small_items_per_slab = 8;
pub const maximum_small_item_size = architecture.paging.standard_page_size
    .subtract(.of(innigkeit.memory.cache.RawCache.Slab))
    .divideScalar(minimum_small_items_per_slab);
pub const single_node_alignment: std.mem.Alignment = .of(std.SinglyLinkedList.Node);
