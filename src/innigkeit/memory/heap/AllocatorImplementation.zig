const core = @import("core");
const globals = @import("globals.zig");
const innigkeit = @import("innigkeit");
const std = @import("std");

const log = innigkeit.debug.log.scoped(.heap);

pub fn alloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    if (core.is_debug) std.debug.assert(len != 0);

    if (alignment.toByteUnits() <= globals.heap_arena_quantum) {
        // no need to overallocate to ensure alignment
        const allocation = globals.heap_arena.allocate(len, .instant_fit) catch {
            @branchHint(.unlikely);
            return null;
        };
        return allocation.toVirtualRange().address.toPtr([*]u8);
    }

    // Over-aligned: the pointer we return may sit anywhere up to
    // `alignment - 1` bytes after the arena's actual allocation base, and
    // that offset is not recoverable at `free()` time from
    // (pointer, len, alignment) alone. The arena only guarantees
    // quantum alignment, not `alignment`-byte alignment, so there is no
    // formula that reconstructs an arbitrary arena-chosen base after the
    // fact. Reserve room for a header holding the arena's true
    // `Allocation` (base+len) immediately before the returned pointer.
    const header_size: core.Size = .of(innigkeit.memory.arena.Allocation);

    const unaligned_allocation = globals.heap_arena.allocate(
        len + alignment.toByteUnits() - 1 + header_size.value,
        .instant_fit,
    ) catch {
        @branchHint(.unlikely);
        return null;
    };

    const data_address = unaligned_allocation
        .toVirtualRange().address
        .moveForward(header_size)
        .alignForward(alignment);

    data_address.moveBackward(header_size)
        .toPtr(*innigkeit.memory.arena.Allocation).* = unaligned_allocation;

    return data_address.toPtr([*]u8);
}

pub fn resize(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    if (core.is_debug) {
        std.debug.assert(memory.len != 0);
        std.debug.assert(new_len != 0);
    }

    const max_allowed_size = std.mem.alignForward(
        usize,
        memory.len,
        globals.heap_arena_quantum,
    );

    return new_len <= max_allowed_size;
}

pub fn remap(
    ptr: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    // TODO: resource arena can support this, find allocation and check if next tag is free
    return if (resize(ptr, memory, alignment, new_len, return_address)) memory.ptr else null;
}

pub fn free(
    _: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    _: usize,
) void {
    if (core.is_debug) std.debug.assert(memory.len != 0);

    if (alignment.toByteUnits() <= globals.heap_arena_quantum) {
        const unaligned_range: innigkeit.KernelVirtualRange = .fromSlice(u8, memory);
        const aligned_range: innigkeit.KernelVirtualRange = .from(unaligned_range.address, unaligned_range.size.alignForward(globals.heap_arena_quantum_size_alignment));
        globals.heap_arena.deallocate(.fromVirtualRange(aligned_range));
        return;
    }

    // Over-aligned: recover the arena's true base+len from the header
    // `alloc()` stashed immediately before this pointer: see the
    // comment there for why this can't be reconstructed by alignment
    // arithmetic alone.
    const header_size: core.Size = .of(innigkeit.memory.arena.Allocation);

    const allocation = innigkeit.KernelVirtualAddress.from(@intFromPtr(memory.ptr))
        .moveBackward(header_size)
        .toPtr(*const innigkeit.memory.arena.Allocation).*;

    globals.heap_arena.deallocate(allocation);
}

pub fn heapPageArenaImport(
    arena_ptr: *anyopaque,
    len: usize,
    policy: innigkeit.memory.arena.Policy,
) innigkeit.memory.arena.AllocateError!innigkeit.memory.arena.Allocation {
    const arena: *globals.Arena = @ptrCast(@alignCast(arena_ptr));

    const allocation = try arena.allocate(
        len,
        policy,
    );
    errdefer arena.deallocate(allocation);

    log.verbose("mapping {f} into heap", .{allocation});

    const virtual_range = allocation.toVirtualRange();

    {
        globals.heap_page_table_mutex.lock();
        defer globals.heap_page_table_mutex.unlock();

        innigkeit.memory.mapRangeAndBackWithPhysicalPages(
            innigkeit.memory.kernelPageTable(),
            virtual_range.toVirtualRange(),
            .{ .type = .kernel, .protection = .{ .read = true, .write = true } },
            .kernel,
            .keep,
            innigkeit.memory.PhysicalPage.allocator,
        ) catch {
            @branchHint(.unlikely);
            return innigkeit.memory.arena.AllocateError.RequestedLengthUnavailable;
        };
    }
    errdefer comptime unreachable;

    if (core.is_debug) @memset(virtual_range.byteSlice(), undefined);

    return allocation;
}

pub fn heapPageArenaRelease(
    arena_ptr: *anyopaque,
    allocation: innigkeit.memory.arena.Allocation,
) void {
    const arena: *globals.Arena = @ptrCast(@alignCast(arena_ptr));

    log.verbose("unmapping {f} from heap", .{allocation});

    {
        var unmap_batch: innigkeit.memory.VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(allocation.toVirtualRange().toVirtualRange());

        globals.heap_page_table_mutex.lock();
        defer globals.heap_page_table_mutex.unlock();

        innigkeit.memory.unmap(
            innigkeit.memory.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .free,
            .keep,
            innigkeit.memory.PhysicalPage.allocator,
        );
    }

    arena.deallocate(allocation);
}

test "heap allocator: over-aligned alloc/free round-trips without corrupting the arena" {
    const allocator = innigkeit.memory.heap.allocator;

    // 64 > heap_arena_quantum (16): exercises the header-based path.
    const alignment: std.mem.Alignment = .@"64";

    const first = try allocator.alignedAlloc(u8, alignment, 128);
    defer allocator.free(first);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(first.ptr), 64));

    const second = try allocator.alignedAlloc(u8, alignment, 128);
    defer allocator.free(second);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(second.ptr), 64));

    // The two allocations must not alias.
    try std.testing.expect(first.ptr != second.ptr);

    @memset(first, 0xAA);
    @memset(second, 0xBB);
    try std.testing.expect(std.mem.allEqual(u8, first, 0xAA));
    try std.testing.expect(std.mem.allEqual(u8, second, 0xBB));

    // A cache-line-aligned struct, as used by `innigkeit.sync.Mutex` /
    // `TicketSpinLock` (the reachable call path found in Phase 2 Stage 5).
    const Aligned = struct {
        _: void align(std.atomic.cache_line) = {},
        value: u32 = 0,
    };
    const boxed = try allocator.create(Aligned);
    defer allocator.destroy(boxed);
    boxed.value = 42;
    try std.testing.expectEqual(@as(u32, 42), boxed.value);

    // The arena must still be usable afterwards (a corrupted boundary tag
    // table would surface as an allocation failure or panic here).
    const after = try allocator.alignedAlloc(u8, alignment, 128);
    allocator.free(after);
}
