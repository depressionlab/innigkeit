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
const core = @import("core");

const log = innigkeit.debug.log.scoped(.user_fb);

inline fn errCode(code: i64) usize {
    return @bitCast(code);
}

const e = struct {
    const EPERM: i64 = -1;
    const ENOENT: i64 = -2;
    const EIO: i64 = -5;
    const EBADF: i64 = -9;
    const ENOMEM: i64 = -12;
    const EFAULT: i64 = -14;
    const EINVAL: i64 = -22;
    const ENODEV: i64 = -19;
};

fn validateUserBuffer(ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (ptr +% len < ptr) return false;
    const range: innigkeit.VirtualRange = .from(.from(ptr), .from(len, .byte));
    return architecture.user.user_memory_range.fullyContains(range);
}

/// ABI layout of the FramebufferInfo struct (must match library/innigkeit/display.zig).
const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    _pad: [3]u8 = .{0} ** 3,
};

/// Map the bootloader framebuffer into the calling process's address space.
pub fn syscallFramebufferMap(info_ptr: usize, current_task: innigkeit.Task.Current) usize {
    const info = innigkeit.init.Output.framebuffer.getPhysInfo() orelse {
        log.debug("framebuffer_map: no framebuffer available", .{});
        return errCode(e.ENODEV);
    };

    if (!validateUserBuffer(info_ptr, @sizeOf(FramebufferInfo))) {
        return errCode(e.EFAULT);
    }

    const process = innigkeit.user.Process.from(current_task.task);
    const page_size = architecture.paging.standard_page_size;

    const total_bytes: usize = @as(usize, info.pitch) * @as(usize, info.height);
    const aligned_bytes = std.mem.alignForward(usize, total_bytes, page_size.value);
    const aligned_size = core.Size.from(aligned_bytes, .byte);
    const n_pages = aligned_bytes / page_size.value;

    // Reserve a contiguous VA range.
    const virt_range = process.address_space.map(.{
        .size = aligned_size,
        .protection = .{ .read = true, .write = true },
        .max_protection = .all,
        .type = .zero_fill,
    }) catch |err| {
        log.debug("framebuffer_map: address_space.map failed: {t}", .{err});
        return errCode(e.ENOMEM);
    };

    // Wire each physical page into the page table with write-combining.
    const map_type: innigkeit.mem.MapType = .{
        .type = .user,
        .protection = .{ .read = true, .write = true },
        .cache = .write_combining,
    };

    process.address_space.page_table_lock.lock();
    for (0..n_pages) |i| {
        const phys_addr = innigkeit.PhysicalAddress.from(info.phys_base.value + i * page_size.value);
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
            return errCode(e.ENOMEM);
        };
    }
    process.address_space.page_table_lock.unlock();

    // Write dimensions back to user memory.
    current_task.incrementEnableAccessToUserMemory();
    const user_info: *FramebufferInfo = @ptrFromInt(info_ptr);
    user_info.* = .{
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .bpp = info.bpp,
    };
    current_task.decrementEnableAccessToUserMemory();

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
pub fn syscallInitfsRead(spec_ptr: usize, current_task: innigkeit.Task.Current) usize {
    if (!validateUserBuffer(spec_ptr, @sizeOf(InitfsReadSpec))) return errCode(e.EFAULT);

    current_task.incrementEnableAccessToUserMemory();
    const spec = @as(*const InitfsReadSpec, @ptrFromInt(spec_ptr)).*;
    current_task.decrementEnableAccessToUserMemory();

    const name_len = spec.name_len;
    if (name_len == 0 or name_len > 255) return errCode(e.EINVAL);
    if (!validateUserBuffer(spec.name_ptr, name_len)) return errCode(e.EFAULT);
    if (spec.buf_len > 0 and !validateUserBuffer(spec.buf_ptr, spec.buf_len)) {
        return errCode(e.EFAULT);
    }

    var name_buf: [256]u8 = undefined;
    current_task.incrementEnableAccessToUserMemory();
    @memcpy(name_buf[0..name_len], @as([*]const u8, @ptrFromInt(spec.name_ptr))[0..name_len]);
    current_task.decrementEnableAccessToUserMemory();
    const name = name_buf[0..name_len];

    const file_data = innigkeit.fs.initfs.findFile(name) orelse return errCode(e.ENOENT);

    if (spec.buf_len == 0) return file_data.len;

    const copy_len = @min(file_data.len, spec.buf_len);
    current_task.incrementEnableAccessToUserMemory();
    @memcpy(@as([*]u8, @ptrFromInt(spec.buf_ptr))[0..copy_len], file_data[0..copy_len]);
    current_task.decrementEnableAccessToUserMemory();

    return copy_len;
}

/// Return milliseconds since kernel boot.
pub fn syscallUptimeMs() usize {
    return @intCast(innigkeit.time.init.getUptimeMs());
}

/// Non-blocking drain of raw PS/2 bytes into a user buffer.
///
/// Returns the number of bytes copied (0 if no key events pending).
pub fn syscallKbdRead(buf_ptr: usize, buf_len: usize, current_task: innigkeit.Task.Current) usize {
    if (buf_len == 0) return 0;
    if (!validateUserBuffer(buf_ptr, buf_len)) return errCode(e.EFAULT);

    var tmp: [64]u8 = undefined;
    const to_read = @min(buf_len, tmp.len);
    const n = innigkeit.drivers.input.ps2.raw_kb.drain(tmp[0..to_read]);
    if (n == 0) return 0;

    current_task.incrementEnableAccessToUserMemory();
    @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..n], tmp[0..n]);
    current_task.decrementEnableAccessToUserMemory();

    return n;
}

/// ABI layout for blk_read syscall (spec_ptr points to this struct in user memory).
const BlkReadSpec = extern struct {
    byte_offset: u64,
    buf_ptr: usize,
    buf_len: usize,
};

/// Read bytes from the data disk (device 1) into a user buffer.
///
/// Returns bytes read, or 0 if no data disk is present.
pub fn syscallBlkRead(spec_ptr: usize, current_task: innigkeit.Task.Current) usize {
    if (!validateUserBuffer(spec_ptr, @sizeOf(BlkReadSpec))) return errCode(e.EFAULT);

    current_task.incrementEnableAccessToUserMemory();
    const spec = @as(*const BlkReadSpec, @ptrFromInt(spec_ptr)).*;
    current_task.decrementEnableAccessToUserMemory();

    if (spec.buf_len == 0) return 0;
    if (!validateUserBuffer(spec.buf_ptr, spec.buf_len)) return errCode(e.EFAULT);

    if (!innigkeit.drivers.virtio.blk.isDataReady()) return errCode(e.ENODEV);

    // Read in chunks through a kernel-side bounce buffer.
    const buf: [*]u8 = @ptrFromInt(spec.buf_ptr);
    var out_pos: usize = 0;
    var remaining: usize = spec.buf_len;
    var byte_offset: u64 = spec.byte_offset;
    var tmp: [8 * 512]u8 = undefined;

    while (remaining > 0) {
        const sector: u64 = byte_offset / 512;
        const off_in_sector: usize = @intCast(byte_offset % 512);
        const sectors_needed: u32 = @intCast(@min(8, (off_in_sector + remaining + 511) / 512));
        const chunk_bytes: usize = @as(usize, sectors_needed) * 512;

        const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();
        innigkeit.drivers.virtio.blk.readSectors(dev_idx, sector, tmp[0..chunk_bytes], sectors_needed) catch |err| {
            log.debug("blk_read: readSectors failed: {t}", .{err});
            return errCode(e.EIO);
        };

        const copy_len: usize = @min(remaining, chunk_bytes - off_in_sector);
        current_task.incrementEnableAccessToUserMemory();
        @memcpy(buf[out_pos..][0..copy_len], tmp[off_in_sector..][0..copy_len]);
        current_task.decrementEnableAccessToUserMemory();

        out_pos += copy_len;
        remaining -= copy_len;
        byte_offset += copy_len;
    }

    return out_pos;
}
