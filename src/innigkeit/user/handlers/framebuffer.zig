//! Kernel-side handlers for the framebuffer_map and initfs_read syscalls.
//!
//! framebuffer_map(info_ptr: usize) -> va | error
//!   Maps the bootloader framebuffer (write-combining) into the calling
//!   process's address space. Fills a FramebufferInfo struct at info_ptr.
//!   Returns the virtual base address on success.
//!
//! initfs_read(name_ptr, name_len, buf_ptr, buf_len) -> bytes | error
//!   Reads a file from the embedded initfs archive into a user buffer.
//!   If buf_len == 0, returns the file size without copying.

const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.user_fb);

const validate = @import("../validate.zig");
const Error = @import("libinnigkeit").Error;
const Context = @import("../Context.zig");

/// ABI layout of the FramebufferInfo struct (must match library/innigkeit/display.zig).
const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    _pad: [3]u8 = .{0} ** 3,
};

/// Map the bootloader framebuffer (or virtio-gpu backing store if present)
/// into the calling process's address space.
pub fn framebufferMap(context: Context) Error.Syscall!usize {
    const info_ptr = context.arg(.one);
    // Prefer virtio-gpu backing store when the driver is up.
    if (innigkeit.drivers.virtio.gpu.state) |gpu| {
        return framebufferMapGpu(context, gpu);
    }

    const info = innigkeit.init.Output.framebuffer.getPhysInfo() orelse {
        log.debug("framebuffer_map: no framebuffer available", .{});
        return Error.Syscall.NoDevice;
    };

    if (!validate.validateUserBuffer(info_ptr, @sizeOf(FramebufferInfo))) {
        return Error.Syscall.BadAddress;
    }

    const process = context.process();
    const page_size = architecture.paging.standard_page_size;

    const total_bytes: usize = @as(usize, info.pitch) * @as(usize, info.height);
    const aligned_bytes = std.mem.alignForward(usize, total_bytes, page_size.value);
    const n_pages = aligned_bytes / page_size.value;

    // Reserve a contiguous VA range.
    const virt_range = process.address_space.map(.{
        .size = .from(aligned_bytes, .byte),
        .protection = .{ .read = true, .write = true },
        .max_protection = .all,
        .type = .zero_fill,
    }) catch |err| {
        log.debug("framebuffer_map: address_space.map failed: {t}", .{err});
        return Error.Syscall.OutOfMemory;
    };

    // Wire each physical page into the page table with write-combining.
    const map_type: innigkeit.mem.MapType = .{
        .type = .user,
        .protection = .{ .read = true, .write = true },
        .cache = .write_combining,
    };

    process.address_space.page_table_lock.lock();
    for (0..n_pages) |i| {
        // Use saturating arithmetic: if the framebuffer PA wraps, refuse to map
        // arbitrary physical memory (kernel pages, MMIO) into userspace.
        const phys_offset = i *| page_size.value;
        if (phys_offset / page_size.value != i) {
            process.address_space.page_table_lock.unlock();
            process.address_space.unmap(virt_range) catch {};
            return Error.Syscall.InvalidArgument;
        }
        const phys_val = info.phys_base.value +| phys_offset;
        if (phys_val < info.phys_base.value) {
            process.address_space.page_table_lock.unlock();
            process.address_space.unmap(virt_range) catch {};
            return Error.Syscall.InvalidArgument;
        }
        const phys_addr = innigkeit.PhysicalAddress.from(phys_val);
        const phys_idx = innigkeit.mem.PhysicalPage.Index.fromAddress(phys_addr);
        const virt_addr = innigkeit.VirtualAddress.from(virt_range.address.value + i * page_size.value);
        innigkeit.mem.mapSinglePage(
            process.address_space.page_table,
            virt_addr,
            phys_idx,
            map_type,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch {
            process.address_space.page_table_lock.unlock();
            process.address_space.unmap(virt_range) catch {};
            log.debug("framebuffer_map: mapSinglePage failed at page {}", .{i});
            return Error.Syscall.OutOfMemory;
        };
    }
    process.address_space.page_table_lock.unlock();

    // Write dimensions back to user memory.
    validate.writeUser(info_ptr, FramebufferInfo{
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .bpp = info.bpp,
    }) catch return Error.Syscall.BadAddress; // unreachable: validated above

    return virt_range.address.value;
}

/// ABI layout of the InitfsReadSpec struct (must match library/innigkeit/fs.zig).
const InitfsReadSpec = extern struct {
    name_ptr: usize,
    name_len: u32,
    _pad: u32 = 0,
    buf_ptr: usize,
    buf_len: usize,
};

/// Read a file from the initfs archive into a user buffer.
///
/// arg1 = pointer to InitfsReadSpec in user memory.
/// Returns bytes copied, or file size if buf_len==0 (stat mode).
pub fn initfsRead(context: Context) Error.Syscall!usize {
    const spec_ptr = context.arg(.one);
    const spec = validate.readUser(InitfsReadSpec, spec_ptr) catch
        return Error.Syscall.BadAddress;

    const name_len = spec.name_len;
    if (name_len == 0 or name_len > 255) return Error.Syscall.InvalidArgument;
    if (!validate.validateUserBuffer(spec.name_ptr, name_len)) return Error.Syscall.BadAddress;
    if (spec.buf_len > 0 and !validate.validateUserBuffer(spec.buf_ptr, spec.buf_len)) return Error.Syscall.BadAddress;

    var name_buf: [256]u8 = undefined;
    validate.copyFromUser(name_buf[0..name_len], spec.name_ptr) catch return Error.Syscall.BadAddress;
    const name = name_buf[0..name_len];

    const file_data = innigkeit.fs.initfs.findFile(name) orelse return Error.Syscall.NotFound;

    if (spec.buf_len == 0) return file_data.len;

    const copy_len = @min(file_data.len, spec.buf_len);
    validate.copyToUser(spec.buf_ptr, file_data[0..copy_len]) catch return Error.Syscall.BadAddress;

    return copy_len;
}

/// Return milliseconds since kernel boot.
pub fn uptimeMs(_: Context) Error.Syscall!usize {
    return @intCast(innigkeit.time.init.getUptimeMs());
}

/// Non-blocking drain of raw PS/2 bytes into a user buffer.
///
/// Returns the number of bytes copied (0 if no key events pending).
pub fn kbdRead(context: Context) Error.Syscall!usize {
    const buf_ptr = context.arg(.one);
    const buf_len = context.arg(.two);
    if (buf_len == 0) return 0;
    // Validate up front so a bad buffer faults before draining (and losing)
    // pending key events.
    if (!validate.validateUserBuffer(buf_ptr, buf_len)) return Error.Syscall.BadAddress;

    var tmp: [64]u8 = undefined;
    const to_read = @min(buf_len, tmp.len);
    const n = innigkeit.drivers.input.ps2.raw_kb.drain(tmp[0..to_read]);
    if (n == 0) return 0;

    validate.copyToUser(buf_ptr, tmp[0..n]) catch return Error.Syscall.BadAddress; // unreachable: validated above

    return n;
}

const MouseEvent = innigkeit.drivers.input.ps2_mouse.MouseEvent;

/// Non-blocking drain of PS/2 mouse events.
/// buf_ptr points to a []MouseEvent; buf_len is the number of events (not bytes).
/// Returns the number of events written.
pub fn mouseRead(context: Context) Error.Syscall!usize {
    const buf_ptr = context.arg(.one);
    const buf_len = context.arg(.two);

    if (buf_len == 0) return 0;
    // Validate up front so a bad buffer faults before draining (and losing)
    // pending mouse events.
    const byte_len = buf_len *| @sizeOf(MouseEvent);
    if (!validate.validateUserBuffer(buf_ptr, byte_len)) return Error.Syscall.BadAddress;

    var tmp: [16]MouseEvent = undefined;
    const to_read = @min(buf_len, tmp.len);
    const n = innigkeit.drivers.input.ps2_mouse.raw_mouse.drain(tmp[0..to_read]);
    if (n == 0) return 0;

    validate.copyToUser(buf_ptr, std.mem.sliceAsBytes(tmp[0..n])) catch
        return Error.Syscall.BadAddress; // unreachable: validated above

    return n;
}

/// Map the virtio-gpu backing-store pages into the calling process's address space.
fn framebufferMapGpu(context: Context, gpu: *innigkeit.drivers.virtio.gpu.GpuState) Error.Syscall!usize {
    const info_ptr = context.arg(.one);
    if (!validate.validateUserBuffer(info_ptr, @sizeOf(FramebufferInfo))) return Error.Syscall.BadAddress;

    const page_size = architecture.paging.standard_page_size;
    const n_pages = gpu.fb_pages.len;
    const total_bytes = n_pages * page_size.value;

    const process = context.process();
    const virt_range = process.address_space.map(.{
        .size = .from(total_bytes, .byte),
        .protection = .{ .read = true, .write = true },
        .max_protection = .all,
        .type = .zero_fill,
    }) catch {
        return Error.Syscall.OutOfMemory;
    };

    const map_type: innigkeit.mem.MapType = .{
        .type = .user,
        .protection = .{ .read = true, .write = true },
        .cache = .write_combining,
    };

    process.address_space.page_table_lock.lock();
    for (gpu.fb_pages, 0..) |pg, i| {
        const virt_addr = innigkeit.VirtualAddress.from(virt_range.address.value + i * page_size.value);
        innigkeit.mem.mapSinglePage(
            process.address_space.page_table,
            virt_addr,
            pg,
            map_type,
            innigkeit.mem.PhysicalPage.allocator,
        ) catch {
            process.address_space.page_table_lock.unlock();
            process.address_space.unmap(virt_range) catch {};
            return Error.Syscall.OutOfMemory;
        };
    }
    process.address_space.page_table_lock.unlock();

    validate.writeUser(info_ptr, FramebufferInfo{
        .width = gpu.fb_width,
        .height = gpu.fb_height,
        .pitch = gpu.fb_width * 4,
        .bpp = 32,
    }) catch return Error.Syscall.BadAddress; // unreachable: validated above

    return virt_range.address.value;
}

/// ABI layout for blk_read / blk_write syscalls (spec_ptr points to this struct in user memory).
pub const BlkReadSpec = extern struct {
    byte_offset: u64,
    buf_ptr: usize,
    buf_len: usize,
};

/// Read bytes from the data disk (device 1) into a user buffer.
///
/// Returns bytes read, or 0 if no data disk is present.
pub fn blkRead(context: Context) Error.Syscall!usize {
    const spec_ptr = context.arg(.one);
    const spec = validate.readUser(BlkReadSpec, spec_ptr) catch return Error.Syscall.BadAddress;

    if (spec.buf_len == 0) return 0;
    if (!validate.validateUserBuffer(spec.buf_ptr, spec.buf_len)) return Error.Syscall.BadAddress;
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return Error.Syscall.NoDevice;

    // Read in chunks through a kernel-side bounce buffer.
    var out_pos: usize = 0;
    var remaining: usize = spec.buf_len;
    var byte_offset: u64 = spec.byte_offset;
    var tmp: [8 * 512]u8 = undefined;

    while (remaining > 0) {
        const sector: u64 = byte_offset / 512;
        const off_in_sector: usize = @intCast(byte_offset % 512);
        // Use saturating add to prevent overflow when computing sectors needed.
        const sectors_needed: u32 = @intCast(@min(8, (off_in_sector +| remaining +| 511) / 512));
        const chunk_bytes: usize = @as(usize, sectors_needed) * 512;

        const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
        innigkeit.drivers.virtio.blk.readSectors(dev_idx, sector, tmp[0..chunk_bytes], sectors_needed) catch |err| {
            log.debug("blk_read: readSectors failed: {t}", .{err});
            return Error.Syscall.IoError;
        };

        const copy_len: usize = @min(remaining, chunk_bytes - off_in_sector);
        validate.copyToUser(spec.buf_ptr + out_pos, tmp[off_in_sector..][0..copy_len]) catch
            return Error.Syscall.BadAddress; // unreachable: whole buffer validated above

        out_pos += copy_len;
        remaining -= copy_len;
        byte_offset += copy_len;
    }

    return out_pos;
}

/// Write bytes from a user buffer to the data disk (device 1).
///
/// Offset and length must be multiples of 512 (sector size).
/// Returns 0 on success.
pub fn blkWrite(context: Context) Error.Syscall!usize {
    const spec_ptr = context.arg(.one);
    const spec = validate.readUser(BlkReadSpec, spec_ptr) catch return Error.Syscall.BadAddress;

    if (spec.buf_len == 0) return 0;
    if (!validate.validateUserBuffer(spec.buf_ptr, spec.buf_len)) return Error.Syscall.BadAddress;
    if (spec.byte_offset % 512 != 0 or spec.buf_len % 512 != 0) return Error.Syscall.InvalidArgument;
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return Error.Syscall.NoDevice;

    // Copy in chunks through a kernel-side bounce buffer.
    var in_pos: usize = 0;
    var remaining: usize = spec.buf_len;
    var byte_offset: u64 = spec.byte_offset;
    var tmp: [8 * 512]u8 = undefined;

    while (remaining > 0) {
        const sectors_now: u32 = @intCast(@min(8, remaining / 512));
        const chunk_bytes: usize = @as(usize, sectors_now) * 512;
        const sector: u64 = byte_offset / 512;

        validate.copyFromUser(tmp[0..chunk_bytes], spec.buf_ptr + in_pos) catch
            return Error.Syscall.BadAddress; // unreachable: whole buffer validated above

        const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
        innigkeit.drivers.virtio.blk.writeSectors(dev_idx, sector, tmp[0..chunk_bytes], sectors_now) catch |err| {
            log.debug("blk_write: writeSectors failed: {t}", .{err});
            return Error.Syscall.IoError;
        };

        in_pos += chunk_bytes;
        remaining -= chunk_bytes;
        byte_offset += chunk_bytes;
    }

    return 0;
}
