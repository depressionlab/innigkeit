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

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

const log = innigkeit.debug.log.scoped(.vmem);

/// Negated POSIX errno values used as syscall return codes.
const e = struct {
    const EPERM: i64 = -1;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EINVAL: i64 = -22;
};

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

/// Execute the `vmem_map` syscall.
///
/// arg1 = frame capability handle
/// Returns the virtual base address on success, or a negated errno on failure.
pub fn syscallVmemMap(handle: u32, current_task: innigkeit.Task.Current) usize {
    const process = innigkeit.user.Process.from(current_task.task);
    const cap_table = process.cap_table;

    // Look up the Frame capability.
    cap_table.lock.lock();
    const slot_info = cap_table.getAndRefLocked(handle) orelse {
        cap_table.lock.unlock();
        return errCode(e.EBADF);
    };
    cap_table.lock.unlock();
    defer innigkeit.capabilities.CapabilityTable.unrefObject(slot_info.cap_type, slot_info.ptr);

    if (slot_info.cap_type != .frame) {
        return errCode(e.EBADF);
    }
    if (!slot_info.rights.read) {
        return errCode(e.EPERM);
    }

    const frame: *innigkeit.capabilities.Frame = @ptrCast(@alignCast(slot_info.ptr));
    const phys_page = frame.page;

    const page_align = architecture.paging.standard_page_size_alignment;
    const page_size = architecture.paging.standard_page_size;

    // Reserve a virtual address range in the process's address space.
    const virt_range = process.address_space.map(.{
        .size = page_size,
        .protection = .{ .read = true, .write = true },
        .max_protection = .all,
        .type = .zero_fill,
    }) catch |err| {
        log.debug("vmem_map: address_space.map failed: {t}", .{err});
        return switch (err) {
            error.OutOfMemory, error.RequestedRangeUnavailable => errCode(e.ENOMEM),
            else => errCode(e.EINVAL),
        };
    };

    // Now wire the physical page into the page table over the reserved VA.
    const map_type: innigkeit.mem.MapType = .{
        .type = .user,
        .protection = .{ .read = true, .write = true },
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
        return errCode(e.ENOMEM);
    };
    process.address_space.page_table_lock.unlock();

    return virt_range.address.value;
}

/// Execute the `vmem_unmap` syscall.
///
/// arg1 = virtual address (must be page-aligned)
/// arg2 = size in bytes (must be page-aligned)
/// Returns 0 on success or a negated errno on failure.
pub fn syscallVmemUnmap(
    addr_raw: usize,
    size_bytes: usize,
    current_task: innigkeit.Task.Current,
) usize {
    if (size_bytes == 0 or addr_raw == 0) {
        return errCode(e.EINVAL);
    }

    const page_align = architecture.paging.standard_page_size_alignment;
    if (!page_align.check(addr_raw) or !page_align.check(size_bytes)) {
        return errCode(e.EINVAL);
    }

    const vaddr: innigkeit.VirtualAddress = .from(addr_raw);
    if (vaddr.getType() != .user) {
        return errCode(e.EFAULT);
    }

    const range: innigkeit.VirtualRange = .{
        .address = vaddr,
        .size = .from(size_bytes, .byte),
    };

    const process = innigkeit.user.Process.from(current_task.task);
    process.address_space.unmap(range) catch |err| {
        return switch (err) {
            error.OutOfMemory => errCode(e.ENOMEM),
            error.RangeNotPageAligned => errCode(e.EINVAL),
        };
    };

    return 0;
}
