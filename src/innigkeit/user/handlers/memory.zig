//! Anonymous memory mapping syscalls: `mmap` and `munmap`.
//!
//! `mmap(size: usize, prot: u32) -> addr | error`
//!   Maps `size` bytes (rounded up to a page) of zero-fill anonymous memory.
//!   prot bits: 1=read, 2=write, 4=execute. At least one bit required; the
//!   write|execute combination is rejected (W^X).
//!
//! `munmap(addr: usize, size: usize) -> 0 | error`
//!   Unmaps [addr, addr+size). Both must be page-aligned and in user space.

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// `mmap(size, prot) -> addr`.
pub fn mmap(context: Context) Error.Syscall!usize {
    const size_bytes = context.arg(.one);
    const prot_raw = context.arg32(.two);

    if (size_bytes == 0) return error.InvalidArgument;

    const page_align = architecture.paging.standard_page_size_alignment;
    const page_size = page_align.toByteUnits();
    // Guard against integer overflow in alignment rounding.
    if (size_bytes > std.math.maxInt(usize) - (page_size - 1)) return error.InvalidArgument;
    const aligned_size = core.Size.from(size_bytes, .byte).alignForward(page_align);

    const protection: innigkeit.mem.MapType.Protection = .{
        .read = (prot_raw & 1) != 0,
        .write = (prot_raw & 2) != 0,
        .execute = (prot_raw & 4) != 0,
    };

    if (protection.equal(.none)) return error.InvalidArgument; // need >=1 permission
    if (protection.write and protection.execute) return error.InvalidArgument; // W^X

    const process = context.process();
    const range = process.address_space.map(.{
        .size = aligned_size,
        .protection = protection,
        .type = .zero_fill,
    }) catch |err| return switch (err) {
        error.OutOfMemory, error.RequestedRangeUnavailable => error.OutOfMemory,
        else => error.InvalidArgument,
    };

    return range.address.value;
}

/// `munmap(addr, size) -> 0`.
pub fn munmap(context: Context) Error.Syscall!usize {
    const addr_raw = context.arg(.one);
    const size_bytes = context.arg(.two);

    if (size_bytes == 0 or addr_raw == 0) return error.InvalidArgument;

    const page_align = architecture.paging.standard_page_size_alignment;
    if (!page_align.check(addr_raw) or !page_align.check(size_bytes)) return error.InvalidArgument;

    const vaddr: innigkeit.VirtualAddress = .from(addr_raw);
    switch (vaddr.tagged()) {
        .user => {},
        else => return error.BadAddress,
    }

    const range: innigkeit.VirtualRange = .{
        .address = vaddr,
        .size = .from(size_bytes, .byte),
    };

    context.process().address_space.unmap(range) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RangeNotPageAligned => error.InvalidArgument,
    };

    return 0;
}
