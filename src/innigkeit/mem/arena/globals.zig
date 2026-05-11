const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const RawCache = innigkeit.mem.cache.RawCache;
const core = @import("core");

const BoundaryTag = @import("Arena.zig").BoundaryTag;

/// Initialized during `init.initializeCaches`.
pub var tag_cache: innigkeit.mem.cache.Cache(BoundaryTag, null) = undefined;

pub const MAX_NUMBER_OF_QUANTUM_CACHES = 64;
pub const QUANTUM_CACHES_PER_PAGE = architecture.paging.standard_page_size.divide(core.Size.of(RawCache));

pub const NUMBER_OF_HASH_BUCKETS = 64;
pub const HashIndex: type = std.math.Log2Int(std.meta.Int(.unsigned, NUMBER_OF_HASH_BUCKETS));

pub const NUMBER_OF_FREELISTS = @bitSizeOf(usize);
pub const UsizeShiftInt: type = std.math.Log2Int(usize);

pub const TAGS_PER_SPAN_CREATE = 2;
pub const TAGS_PER_PARTIAL_ALLOCATION = 1;
pub const MAX_TAGS_PER_ALLOCATION = TAGS_PER_SPAN_CREATE + TAGS_PER_PARTIAL_ALLOCATION;
