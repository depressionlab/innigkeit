//! Implementation of the `vmem_map` and `vmem_unmap` syscalls.
//!
//! `vmem_map(handle: u32)` -> addr | error
//!   Maps the physical page(s) backing a Frame capability into the calling
//!   process's address space. Returns the virtual base address of the mapping.
//!   The frame is mapped read+write with max_protection=all.
//!
//! `vmem_unmap(addr: usize, size: usize)` -> 0 | error
//!   Unmaps the region [addr, addr+size) from the calling process's address space.
//!   addr and size must be page-aligned.

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.vmem);

const Context = @import("../Context.zig");
const Error = @import("libinnigkeit").Error;

/// Execute the `vmem_map` syscall.
///
/// arg1 = frame capability handle
/// Returns the virtual base address on success.
pub fn vmemMap(context: Context) Error.Syscall!usize {
    const handle = context.arg32(.one);
    const process = context.process();
    const cap_table = process.cap_table;

    // Look up the Frame capability.
    cap_table.lock.lock();
    const slot_info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return Error.Syscall.BadHandle;
    };
    cap_table.lock.unlock();
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

    if (slot_info.cap_type != .frame) return Error.Syscall.BadHandle;
    if (!slot_info.rights.read) return Error.Syscall.PermissionDenied;

    const frame: *innigkeit.capabilities.Frame = @ptrCast(@alignCast(slot_info.ptr));
    const phys_page = frame.page;

    const page_align = architecture.paging.standard_page_size_alignment;
    const page_size = architecture.paging.standard_page_size;

    const prot: innigkeit.mem.MapType.Protection = .{
        .read = slot_info.rights.read,
        .write = slot_info.rights.write,
        .execute = false, // W^X: explicit execute right required
    };

    // Reserve a virtual address range in the process's address space.
    const virt_range = process.address_space.map(.{
        .size = page_size,
        .protection = prot,
        .max_protection = prot,
        .type = .zero_fill,
    }) catch |err| {
        log.debug("vmem_map: address_space.map failed: {t}", .{err});
        return switch (err) {
            error.OutOfMemory, error.RequestedRangeUnavailable => Error.Syscall.OutOfMemory,
            else => Error.Syscall.InvalidArgument,
        };
    };

    // Now wire the physical page into the page table over the reserved VA.
    const map_type: innigkeit.mem.MapType = .{
        .type = .user,
        .protection = prot,
    };

    _ = page_align; // alignment is guaranteed by address_space.map

    process.address_space.page_table_lock.lock();
    innigkeit.mem.mapSinglePage(
        process.address_space.page_table,
        virt_range.address,
        phys_page,
        map_type,
        innigkeit.mem.PhysicalPage.allocator,
    ) catch |err| {
        process.address_space.page_table_lock.unlock();
        // Unmap the VA we just reserved since we can't back it.
        process.address_space.unmap(virt_range) catch {};
        log.debug("vmem_map: mapSinglePage failed: {t}", .{err});
        return Error.Syscall.OutOfMemory;
    };
    process.address_space.page_table_lock.unlock();

    return virt_range.address.value;
}

/// Execute the `vmem_unmap` syscall.
///
/// arg1 = virtual address (must be page-aligned)
/// arg2 = size in bytes (must be page-aligned)
/// Returns 0 on success.
pub fn vmemUnmap(context: Context) Error.Syscall!usize {
    const addr_raw = context.arg(.one);
    const size_bytes = context.arg(.two);

    if (size_bytes == 0 or addr_raw == 0) return Error.Syscall.InvalidArgument;

    const page_align = architecture.paging.standard_page_size_alignment;
    if (!page_align.check(addr_raw) or !page_align.check(size_bytes)) return Error.Syscall.InvalidArgument;

    const vaddr: innigkeit.VirtualAddress = .from(addr_raw);
    switch (vaddr.tagged()) {
        .user => {},
        else => return Error.Syscall.BadAddress,
    }

    const range: innigkeit.VirtualRange = .{
        .address = vaddr,
        .size = .from(size_bytes, .byte),
    };

    context.process().address_space.unmap(range) catch |err| return switch (err) {
        error.OutOfMemory => Error.Syscall.OutOfMemory,
        error.RangeNotPageAligned => Error.Syscall.InvalidArgument,
    };

    return 0;
}
