//! A slab based cache.
//!
//! Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
const RawCache = @This();

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const globals = @import("globals.zig");

const log = innigkeit.debug.log.scoped(.cache);

_name: innigkeit.mem.cache.Name,
lock: innigkeit.sync.Mutex,
size_class: SizeClass,
item_size: core.Size,

/// The size of the item with sufficient padding to ensure alignment.
///
/// If the item is small additional space for the free list node is added.
effective_item_size: core.Size,

items_per_slab: usize,

/// What should happen to the last available slab when it is unused?
last_slab: core.CleanupDecision = .keep,

/// The source of slabs.
///
/// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
///
/// `.pmm` is only valid for small item caches.
slab_source: InitOptions.SlabSource = .heap,

construct_destruct: ?innigkeit.mem.cache.RawConstructDestruct,

available_slabs: std.DoublyLinkedList,
full_slabs: std.DoublyLinkedList,

/// Used to ensure that only one thread allocates a new slab at a time.
allocate_mutex: innigkeit.sync.Mutex,

const SizeClass = union(enum) {
    small,
    large: Large,

    const Large = struct {
        item_lookup: std.AutoHashMap(usize, *LargeItem),
    };
};

pub const InitOptions = struct {
    name: innigkeit.mem.cache.Name,

    size: core.Size,
    alignment: std.mem.Alignment,

    construct_destruct: ?innigkeit.mem.cache.RawConstructDestruct = null,

    /// What should happen to the last available slab when it is unused?
    last_slab: core.CleanupDecision = .keep,

    /// The source of slabs.
    ///
    /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
    ///
    /// `.pmm` is only valid for small item caches.
    slab_source: SlabSource = .heap,

    pub const SlabSource = enum {
        heap,
        pmm,
    };
};

/// Initialize the cache.
pub fn init(self: *RawCache, options: InitOptions) void {
    const item_size: ItemSize = .determine(options.size, options.alignment);

    if (!item_size.is_small and options.slab_source == .pmm) {
        @panic("only small item caches can have `slab_source` set to `.pmm`!");
    }

    if (item_size.is_small) {
        log.debug(
            "{s}: init small item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
            .{
                options.name.constSlice(),
                item_size.effective_item_size,
                options.size,
                options.alignment.toByteUnits(),
                item_size.items_per_slab,
                item_size.effective_item_size.multiplyScalar(item_size.items_per_slab),
            },
        );
    } else {
        log.debug(
            "{s}: init large item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
            .{
                options.name.constSlice(),
                item_size.effective_item_size,
                options.size,
                options.alignment.toByteUnits(),
                item_size.items_per_slab,
                item_size.effective_item_size.multiplyScalar(item_size.items_per_slab),
            },
        );
    }

    self.* = .{
        ._name = options.name,
        .allocate_mutex = .{},
        .lock = .{},
        .item_size = options.size,
        .effective_item_size = item_size.effective_item_size,
        .construct_destruct = options.construct_destruct,
        .available_slabs = .{},
        .full_slabs = .{},
        .items_per_slab = item_size.items_per_slab,
        .last_slab = options.last_slab,
        .slab_source = options.slab_source,
        .size_class = if (item_size.is_small)
            .small
        else
            .{
                .large = .{
                    .item_lookup = .init(innigkeit.mem.heap.allocator),
                },
            },
    };
}

/// Deinitialize the cache.
///
/// All items must have been deallocated before calling this.
pub fn deinit(self: *RawCache) void {
    log.debug("{s}: deinit", .{self.name()});

    if (self.full_slabs.first != null) @panic("full slabs not empty!");

    switch (self.size_class) {
        .small => {},
        .large => |large| {
            if (large.item_lookup.count() != 0) @panic("large item lookup not empty!");
        },
    }

    while (self.available_slabs.pop()) |node| {
        const slab: *Slab = @fieldParentPtr("linkage", node);
        if (slab.allocated_items != 0) @panic("slab not empty!");

        self.deallocateSlab(slab);
    }

    self.* = undefined;
}

pub fn name(self: *const RawCache) []const u8 {
    return self._name.constSlice();
}

pub const AllocateError = error{
    ItemConstructionFailed,

    SlabAllocationFailed,

    /// Failed to allocate a large item.
    ///
    /// Only possible if adding the item to the large item lookup failed.
    LargeItemAllocationFailed,
};

/// Allocate an item from the cache.
pub fn allocate(self: *RawCache) AllocateError![]u8 {
    var item_buffer: [1][]u8 = undefined;
    try self.allocateMany(&item_buffer);
    return item_buffer[0];
}

/// Allocate multiple items from the cache.
pub fn allocateMany(self: *RawCache, items: [][]u8) AllocateError!void {
    if (items.len == 0) return;

    log.verbose("{s}: allocating {} items", .{ self.name(), items.len });

    var allocated_items: std.ArrayList([]u8) = .initBuffer(items);
    errdefer self.deallocateMany(allocated_items.items);

    self.lock.lock();

    var items_left = items.len;

    while (items_left > 0) {
        const slab: *Slab = if (self.available_slabs.first) |slab_node|
            @fieldParentPtr("linkage", slab_node)
        else blk: {
            @branchHint(.unlikely);
            break :blk try self.allocateSlab();
        };

        while (items_left > 0) {
            defer items_left -= 1;

            const item_node = slab.items.popFirst() orelse
                @panic("empty slab on available list!");
            slab.allocated_items += 1;

            switch (self.size_class) {
                .small => {
                    const item_node_ptr: [*]u8 = @ptrCast(item_node);
                    const item_ptr = item_node_ptr - self.item_size.alignForward(globals.single_node_alignment).value;
                    allocated_items.appendAssumeCapacity(item_ptr[0..self.item_size.value]);
                },
                .large => |*large| {
                    const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                    large.item_lookup.putNoClobber(@intFromPtr(large_item.item.ptr), large_item) catch {
                        @branchHint(.cold);

                        slab.items.prepend(item_node);
                        slab.allocated_items -= 1;

                        log.warn("{s}: failed to add large item to lookup table", .{self.name()});

                        // Release the lock before returning so the errdefer
                        // (deallocateMany) can re-acquire it without deadlocking.
                        self.lock.unlock();
                        return error.LargeItemAllocationFailed;
                    };

                    allocated_items.appendAssumeCapacity(large_item.item);
                },
            }

            if (slab.allocated_items == self.items_per_slab) {
                @branchHint(.unlikely);
                self.available_slabs.remove(&slab.linkage);
                self.full_slabs.append(&slab.linkage);

                break;
            }
        }
    }

    self.lock.unlock();
}

/// Allocates a new slab.
///
/// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
fn allocateSlab(self: *RawCache) AllocateError!*Slab {
    errdefer log.warn("{s}: failed to allocate slab", .{self.name()});

    self.lock.unlock();

    self.allocate_mutex.lock();
    defer self.allocate_mutex.unlock();

    // optimistically check for an available slab without locking, if there is one lock and check again
    if (self.available_slabs.first != null) {
        self.lock.lock();

        if (self.available_slabs.first) |slab_node| {
            // there is an available slab now, use it without allocating a new one
            return @fieldParentPtr("linkage", slab_node);
        }

        self.lock.unlock();
    }

    log.debug("{s}: allocating slab", .{self.name()});

    const slab = switch (self.size_class) {
        .small => slab: {
            const slab_base_ptr: [*]u8 = switch (self.slab_source) {
                .heap => slab_base_ptr: {
                    const slab_allocation = innigkeit.mem.heap.heap_page_arena.allocate(
                        architecture.paging.standard_page_size.value,
                        .instant_fit,
                    ) catch return AllocateError.SlabAllocationFailed;
                    break :slab_base_ptr @ptrFromInt(slab_allocation.base);
                },
                .pmm => slab_base_ptr: {
                    const physical_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch
                        return AllocateError.SlabAllocationFailed;

                    const slab_base_ptr = physical_page.baseAddress().toDirectMap().toPtr([*]u8);

                    if (core.is_debug) @memset(slab_base_ptr[0..architecture.paging.standard_page_size.value], undefined);

                    break :slab_base_ptr slab_base_ptr;
                },
            };

            errdefer switch (self.slab_source) {
                .heap => innigkeit.mem.heap.heap_page_arena.deallocate(.{
                    .base = @intFromPtr(slab_base_ptr),
                    .len = architecture.paging.standard_page_size.value,
                }),
                .pmm => {
                    var deallocate_page_list: innigkeit.mem.PhysicalPage.List = .{};
                    deallocate_page_list.prepend(.fromAddress(
                        innigkeit.PhysicalAddress.fromDirectMap(.fromPtr(slab_base_ptr)),
                    ));
                    innigkeit.mem.PhysicalPage.allocator.deallocate(deallocate_page_list);
                },
            };

            const slab: *Slab = @ptrCast(@alignCast(
                slab_base_ptr + architecture.paging.standard_page_size.value - @sizeOf(Slab),
            ));
            slab.* = .{
                .large_item_allocation = undefined,
            };

            if (self.construct_destruct) |con_des| {
                var i: usize = 0;

                errdefer { // call the destructor for any items that the constructor was called on
                    const destructor = con_des.destructor;
                    for (0..i) |y| {
                        const item_ptr = slab_base_ptr + self.effective_item_size.multiplyScalar(y).value;
                        destructor(item_ptr[0..self.item_size.value]);
                    }
                }

                const constructor = con_des.constructor;

                while (i < self.items_per_slab) : (i += 1) {
                    const item_ptr = slab_base_ptr + self.effective_item_size.multiplyScalar(i).value;

                    try constructor(item_ptr[0..self.item_size.value]);

                    slab.items.prepend(@ptrCast(@alignCast(
                        item_ptr + self.item_size.alignForward(globals.single_node_alignment).value,
                    )));
                }
            } else {
                for (0..self.items_per_slab) |i| {
                    const item_ptr = slab_base_ptr + self.effective_item_size.multiplyScalar(i).value;
                    slab.items.prepend(@ptrCast(@alignCast(
                        item_ptr + self.item_size.alignForward(globals.single_node_alignment).value,
                    )));
                }
            }

            break :slab slab;
        },
        .large => slab: {
            const large_item_allocation = innigkeit.mem.heap.heap_page_arena.allocate(
                self.effective_item_size.multiplyScalar(self.items_per_slab).value,
                .instant_fit,
            ) catch return AllocateError.SlabAllocationFailed;
            errdefer innigkeit.mem.heap.heap_page_arena.deallocate(large_item_allocation);

            const slab = try globals.slab_cache.allocate();
            slab.* = .{ .large_item_allocation = large_item_allocation };
            errdefer globals.slab_cache.deallocate(slab);

            if (core.is_debug) {
                const virtual_range: innigkeit.KernelVirtualRange = .{
                    .address = .from(slab.large_item_allocation.base),
                    .size = .from(slab.large_item_allocation.len, .byte),
                };
                @memset(virtual_range.byteSlice(), undefined);
            }

            const items_base: [*]u8 = @ptrFromInt(large_item_allocation.base);

            if (self.construct_destruct) |con_des| {
                errdefer {
                    const destructor = con_des.destructor;
                    while (slab.items.popFirst()) |item_node| {
                        const large_item: *LargeItem = @fieldParentPtr("node", item_node);
                        destructor(large_item.item);
                        globals.large_item_cache.deallocate(large_item);
                    }
                }

                const constructor = con_des.constructor;

                for (0..self.items_per_slab) |i| {
                    const large_item = try globals.large_item_cache.allocate();
                    errdefer globals.large_item_cache.deallocate(large_item);

                    const item_ptr: [*]u8 = items_base + self.effective_item_size.multiplyScalar(i).value;
                    const item: []u8 = item_ptr[0..self.item_size.value];

                    large_item.* = .{
                        .item = item,
                        .slab = slab,
                        .node = .{},
                    };

                    try constructor(item);

                    slab.items.prepend(&large_item.node);
                }
            } else {
                errdefer while (slab.items.popFirst()) |item_node| {
                    globals.large_item_cache.deallocate(@fieldParentPtr("node", item_node));
                };

                for (0..self.items_per_slab) |i| {
                    const large_item = try globals.large_item_cache.allocate();

                    const item_ptr: [*]u8 = items_base + self.effective_item_size.multiplyScalar(i).value;
                    const item: []u8 = item_ptr[0..self.item_size.value];

                    large_item.* = .{
                        .item = item,
                        .slab = slab,
                        .node = .{},
                    };

                    slab.items.prepend(&large_item.node);
                }
            }

            break :slab slab;
        },
    };

    self.lock.lock();

    self.available_slabs.append(&slab.linkage);

    return slab;
}

/// Deallocate an item back to the cache.
pub fn deallocate(self: *RawCache, item: []u8) void {
    self.deallocateMany(&.{item});
}

/// Deallocate many items back to the cache.
pub fn deallocateMany(self: *RawCache, items: []const []u8) void {
    if (items.len == 0) return;

    log.verbose("{s}: deallocating {} items", .{ self.name(), items.len });

    self.lock.lock();
    defer self.lock.unlock();

    for (items) |item| {
        const slab, const item_node = switch (self.size_class) {
            .small => blk: {
                const page_start = std.mem.alignBackward(
                    usize,
                    @intFromPtr(item.ptr),
                    architecture.paging.standard_page_size.value,
                );

                const slab: *Slab = @ptrFromInt(page_start + architecture.paging.standard_page_size.value - @sizeOf(Slab));

                const item_node: *std.SinglyLinkedList.Node = @ptrCast(@alignCast(
                    item.ptr + self.item_size.alignForward(globals.single_node_alignment).value,
                ));

                break :blk .{ slab, item_node };
            },
            .large => |*large| blk: {
                const large_item = large.item_lookup.get(@intFromPtr(item.ptr)) orelse {
                    @panic("large item not found in item lookup!");
                };

                _ = large.item_lookup.remove(@intFromPtr(item.ptr));

                break :blk .{ large_item.slab, &large_item.node };
            },
        };

        if (slab.allocated_items == self.items_per_slab) {
            // slab was previously full, move it to available list
            @branchHint(.unlikely);
            self.full_slabs.remove(&slab.linkage);
            self.available_slabs.append(&slab.linkage);
        }

        slab.items.prepend(item_node);
        slab.allocated_items -= 1;

        if (slab.allocated_items != 0) {
            // slab is still in use
            @branchHint(.likely);
            continue;
        }

        // slab is unused

        switch (self.last_slab) {
            .keep => if (self.available_slabs.first == self.available_slabs.last) {
                @branchHint(.unlikely);

                if (core.is_debug) std.debug.assert(self.available_slabs.first == &slab.linkage);

                // this is the last available slab so we leave it in the available list and don't deallocate it

                continue;
            },
            .free => {},
        }

        // slab is unused remove it from available list and deallocate it
        self.available_slabs.remove(&slab.linkage);

        self.deallocateSlab(slab);
    }
}

/// Deallocate a slab.
///
/// The cache's lock must *not* be held when this is called.
fn deallocateSlab(self: *RawCache, slab: *Slab) void {
    log.debug("{s}: deallocating slab", .{self.name()});

    switch (self.size_class) {
        .small => {
            const slab_info_ptr: [*]u8 = @ptrCast(slab);
            const slab_base_ptr: [*]u8 = slab_info_ptr + @sizeOf(Slab) - architecture.paging.standard_page_size.value;

            if (self.construct_destruct) |con_des| {
                const destructor = con_des.destructor;
                for (0..self.items_per_slab) |i| {
                    const item_ptr = slab_base_ptr + self.effective_item_size.multiplyScalar(i).value;
                    destructor(item_ptr[0..self.item_size.value]);
                }
            }

            switch (self.slab_source) {
                .heap => innigkeit.mem.heap.heap_page_arena.deallocate(
                    .{
                        .base = @intFromPtr(slab_base_ptr),
                        .len = architecture.paging.standard_page_size.value,
                    },
                ),
                .pmm => {
                    var deallocate_page_list: innigkeit.mem.PhysicalPage.List = .{};
                    deallocate_page_list.prepend(.fromAddress(
                        innigkeit.PhysicalAddress.fromDirectMap(.fromPtr(slab_base_ptr)),
                    ));
                    innigkeit.mem.PhysicalPage.allocator.deallocate(deallocate_page_list);
                },
            }

            return;
        },
        .large => {
            if (self.construct_destruct) |con_des| {
                const destructor = con_des.destructor;
                while (slab.items.popFirst()) |item_node| {
                    const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                    destructor(large_item.item);

                    globals.large_item_cache.deallocate(large_item);
                }
            } else {
                while (slab.items.popFirst()) |item_node| {
                    globals.large_item_cache.deallocate(@fieldParentPtr("node", item_node));
                }
            }

            innigkeit.mem.heap.heap_page_arena.deallocate(slab.large_item_allocation);

            globals.slab_cache.deallocate(slab);
        },
    }
}

pub const Slab = struct {
    linkage: std.DoublyLinkedList.Node = .{},
    items: std.SinglyLinkedList = .{},
    allocated_items: usize = 0,

    /// The allocation containing this slabs items.
    ///
    /// Only set for large item slabs.
    large_item_allocation: innigkeit.mem.arena.Allocation,
};

pub const LargeItem = struct {
    item: []u8,
    slab: *Slab,
    node: std.SinglyLinkedList.Node = .{},
};

const default_large_items_per_slab = 16;

const ItemSize = struct {
    is_small: bool,
    effective_item_size: core.Size,
    items_per_slab: usize,

    fn determine(size: core.Size, alignment: std.mem.Alignment) ItemSize {
        const is_small = isSmallItem(size, alignment);

        const effective_item_size = if (is_small)
            sizeOfItemWithNodeAppended(size, alignment)
        else
            size.alignForward(alignment);

        const items_per_slab = if (is_small)
            architecture.paging.standard_page_size.subtract(.of(Slab)).divide(effective_item_size)
        else blk: {
            // TODO: why search when we can calculate?

            var candidate_large_items_per_slab: usize = default_large_items_per_slab;

            const initial_pages_for_allocation = architecture.paging.standard_page_size.amountToCover(
                effective_item_size.multiplyScalar(candidate_large_items_per_slab),
            );

            while (true) {
                const next_pages_for_allocation = architecture.paging.standard_page_size.amountToCover(
                    effective_item_size.multiplyScalar(candidate_large_items_per_slab + 1),
                );

                if (next_pages_for_allocation != initial_pages_for_allocation) break;

                candidate_large_items_per_slab += 1;
            }

            break :blk candidate_large_items_per_slab;
        };

        return .{
            .is_small = is_small,
            .effective_item_size = effective_item_size,
            .items_per_slab = items_per_slab,
        };
    }
};

pub inline fn isSmallItem(size: core.Size, alignment: std.mem.Alignment) bool {
    return sizeOfItemWithNodeAppended(size, alignment).lessThanOrEqual(globals.maximum_small_item_size);
}

fn sizeOfItemWithNodeAppended(size: core.Size, alignment: std.mem.Alignment) core.Size {
    return size.alignForward(globals.single_node_alignment)
        .add(.of(std.SinglyLinkedList.Node))
        .alignForward(alignment);
}
