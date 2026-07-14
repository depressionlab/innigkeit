//! These functions are provided to allow C code to use the heap allocator and should not be used by Zig code.

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");
const allocator = innigkeit.memory.heap.allocator;

const standard_alignment: std.mem.Alignment = .@"16";

/// Allocate a block of memory of 'size' bytes.
///
/// Freeing the memory must be done with 'sizedFree'.
pub fn mallocWithSizedFree(size: usize) ?[*]u8 {
    if (size == 0) {
        @branchHint(.unlikely);
        return null;
    }

    const mem = allocator.alignedAlloc(
        u8,
        standard_alignment,
        size,
    ) catch {
        @branchHint(.unlikely);
        return null;
    };

    return mem.ptr;
}

/// Free a block of memory allocated with 'mallocWithSizedFree'.
pub fn sizedFree(opt_ptr: ?[*]u8, size: usize) void {
    const ptr = opt_ptr orelse {
        @branchHint(.unlikely);
        return;
    };
    allocator.rawFree(
        ptr[0..size],
        standard_alignment,
        @returnAddress(),
    );
}

/// Allocate a block of memory of 'size' bytes.
///
/// Freeing the memory must be done with 'nonSizedFree'.
pub fn mallocWithNonSizedFree(size: usize) ?[*]u8 {
    comptime std.debug.assert(standard_alignment.compare(.eq, .of(innigkeit.KernelVirtualRange)));

    const full_size = core.Size.from(size, .byte).add(.of(innigkeit.KernelVirtualRange));

    const mem = allocator.alignedAlloc(
        u8,
        standard_alignment,
        full_size,
    ) catch {
        @branchHint(.unlikely);
        return null;
    };

    const result_ptr = mem.ptr + @sizeOf(innigkeit.KernelVirtualRange);

    getAllocationHeader(result_ptr).* = .fromSlice(u8, mem);

    return result_ptr;
}

/// Free a block of memory allocated with 'mallocWithNonSizedFree'.
pub fn nonSizedFree(opt_ptr: ?[*]u8) void {
    const ptr = opt_ptr orelse {
        @branchHint(.unlikely);
        return;
    };
    allocator.rawFree(
        getAllocationHeader(ptr).byteSlice(),
        standard_alignment,
        @returnAddress(),
    );
}

inline fn getAllocationHeader(ptr: [*]align(@alignOf(innigkeit.KernelVirtualRange)) u8) *innigkeit.KernelVirtualRange {
    return @ptrCast(@alignCast(ptr - @sizeOf(innigkeit.KernelVirtualRange)));
}
