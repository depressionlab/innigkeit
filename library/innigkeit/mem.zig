const std = @import("std");
const innigkeit = @import("innigkeit");

/// Protection flags for mmap.
pub const Prot = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    _pad: u29 = 0,
};

/// Map `size` bytes of anonymous zero-fill memory with the given protection.
///
/// Size is rounded up to the next page boundary by the kernel.
/// Returns a slice pointing to the mapped region.
pub fn mmap(size: usize, prot: Prot) innigkeit.Syscall.Error![]u8 {
    const result = innigkeit.Syscall.invoke(
        .mmap,
        .{ size, @as(u32, @bitCast(prot)) },
    );
    const addr = try innigkeit.Syscall.decode(result);
    return @as([*]u8, @ptrFromInt(addr))[0..size];
}

/// Unmap a region previously returned by `mmap`.
///
/// The slice must match the address and length of an active mapping.
pub fn munmap(region: []u8) innigkeit.Syscall.Error!void {
    const result = innigkeit.Syscall.invoke(
        .munmap,
        .{ @intFromPtr(region.ptr), region.len },
    );
    _ = try innigkeit.Syscall.decode(result);
}

// std.mem.Allocator backed by the mmap/munmap syscalls.
//
// Allocations are page-aligned and rounded up to a whole page. This is
// suitable as a backing allocator for std.heap.ArenaAllocator and
// std.heap.GeneralPurposeAllocator; it is too wasteful for fine-grained
// direct use.

pub const page_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &page_alloc_vtable,
};

const page_size = 4096;

inline fn pageAlignUp(n: usize) usize {
    return (n + page_size - 1) & ~@as(usize, page_size - 1);
}

const page_alloc_vtable: std.mem.Allocator.VTable = .{
    .alloc = pageAlloc,
    .resize = pageResize,
    .remap = pageRemap,
    .free = pageFree,
};

fn pageAlloc(
    _: *anyopaque,
    len: usize,
    _: std.mem.Alignment, // page-alignment satisfies any alignment <= 4096
    _: usize,
) ?[*]u8 {
    const aligned = pageAlignUp(len);
    const result = innigkeit.Syscall.invoke(
        .mmap,
        .{ aligned, @as(u32, 0b11) },
    ); // PROT_READ|WRITE
    const addr = innigkeit.Syscall.decode(result) catch return null;
    if (addr == 0) return null;
    return @ptrFromInt(addr);
}

fn pageResize(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    // True only when new_len fits in the already-mapped pages.
    // We never extend a mapping (no mremap syscall).
    return pageAlignUp(new_len) <= pageAlignUp(memory.len);
}

fn pageRemap(
    _: *anyopaque,
    _: []u8,
    _: std.mem.Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null; // no mremap; caller must alloc+copy
}

fn pageFree(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    const aligned = pageAlignUp(memory.len);
    _ = innigkeit.Syscall.invoke(
        .munmap,
        .{ @intFromPtr(memory.ptr), aligned },
    );
}
