const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const globals = @import("globals.zig");

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

    const unaligned_allocation = globals.heap_arena.allocate(
        len + alignment.toByteUnits() - 1,
        .instant_fit,
    ) catch {
        @branchHint(.unlikely);
        return null;
    };
    return unaligned_allocation.toVirtualRange().address.alignForward(alignment).toPtr([*]u8);
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

    const unaligned_range: innigkeit.KernelVirtualRange = .fromSlice(u8, memory);

    const aligned_range: innigkeit.KernelVirtualRange = if (alignment.toByteUnits() <= globals.heap_arena_quantum)
        .from(
            unaligned_range.address,
            unaligned_range.size.alignForward(globals.heap_arena_quantum_size_alignment),
        )
    else
        .from(
            unaligned_range.address
                .moveBackward(.one)
                .alignBackward(alignment),
            unaligned_range.size
                .add(.from(alignment.toByteUnits(), .byte))
                .subtract(.one)
                .alignForward(globals.heap_arena_quantum_size_alignment),
        );

    globals.heap_arena.deallocate(.fromVirtualRange(aligned_range));
}

pub fn heapPageArenaImport(
    arena_ptr: *anyopaque,
    len: usize,
    policy: innigkeit.mem.arena.Policy,
) innigkeit.mem.arena.AllocateError!innigkeit.mem.arena.Allocation {
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

        innigkeit.mem.mapRangeAndBackWithPhysicalPages(
            innigkeit.mem.kernelPageTable(),
            virtual_range.toVirtualRange(),
            .{ .type = .kernel, .protection = .{ .read = true, .write = true } },
            .kernel,
            .keep,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch {
            @branchHint(.unlikely);
            return innigkeit.mem.arena.AllocateError.RequestedLengthUnavailable;
        };
    }
    errdefer comptime unreachable;

    if (core.is_debug) @memset(virtual_range.byteSlice(), undefined);

    return allocation;
}

pub fn heapPageArenaRelease(
    arena_ptr: *anyopaque,
    allocation: innigkeit.mem.arena.Allocation,
) void {
    const arena: *globals.Arena = @ptrCast(@alignCast(arena_ptr));

    log.verbose("unmapping {f} from heap", .{allocation});

    {
        var unmap_batch: innigkeit.mem.VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(allocation.toVirtualRange().toVirtualRange());

        globals.heap_page_table_mutex.lock();
        defer globals.heap_page_table_mutex.unlock();

        innigkeit.mem.unmap(
            innigkeit.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .free,
            .keep,
            innigkeit.mem.PhysicalPage.allocator,
        );
    }

    arena.deallocate(allocation);
}
