//! virtio-blk driver (legacy PCI transport, poll mode).
//!
//! Supports up to two legacy virtio-blk devices (vendor=0x1AF4, device=0x1001).
//! Device 0 is the boot disk; device 1 is an optional data disk (e.g. WAD).
//! Uses I/O port BAR0 registers (disable-modern=on, disable-legacy=off).

const std = @import("std");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const core = @import("core");
const PortIo = @import("PortIo.zig");

const log = innigkeit.debug.log.scoped(.virtio_blk);

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_BLK_DEVICE_ID: u16 = 0x1001; // legacy device ID

const REG_DEVICE_FEATURES: u16 = 0x00;
const REG_DRIVER_FEATURES: u16 = 0x04;
const REG_QUEUE_PFN: u16 = 0x08;
const REG_QUEUE_SIZE: u16 = 0x0C; // read-only in QEMU legacy: returns device max
const REG_QUEUE_SEL: u16 = 0x0E;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_DEVICE_STATUS: u16 = 0x12;
const REG_ISR: u16 = 0x13;
const REG_CONFIG_CAPACITY_LO: u16 = 0x14;
const REG_CONFIG_CAPACITY_HI: u16 = 0x18;

const STATUS_ACKNOWLEDGE: u8 = 0x01;
const STATUS_DRIVER: u8 = 0x02;
const STATUS_DRIVER_OK: u8 = 0x04;
const STATUS_FAILED: u8 = 0x80;

const BLK_T_IN: u32 = 0; // read request type

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

// Queue size.
//
// QEMU's legacy virtio-pci REG_QUEUE_SIZE is read-only (it always returns the
// device maximum). Writes are silently ignored. We must therefore use the
// device-reported queue size for all ring calculations.
//
// QUEUE_SIZE_MAX is the compile-time upper bound. The runtime value is
// read from the device and stored in `queue_num`.
const QUEUE_SIZE_MAX: u16 = 256;
const PAGE_SIZE: usize = 4096;

// With QUEUE_SIZE_MAX=256 the vring layout spans exactly 3 pages:
//   Page 0 (PFN+0): descriptor table: 256 * 16 = 4096 bytes
//   Page 1 (PFN+1): available ring: starts at offset 4096 from PFN
//   Page 2 (PFN+2): used ring: align(avail_end, PAGE_SIZE) = 8192
const DMA_PAGES: usize = 3;
const MAX_DEVICES: usize = 2;

// Virtqueue data structures (sized for QUEUE_SIZE_MAX)
const VringDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// Block request header.
const BlkReqHeader = extern struct {
    type_: u32,
    ioprio: u32,
    sector: u64,
};

const Device = struct {
    io: PortIo,
    capacity_sectors: u64,
    queue_num: u16,
    dma_pages: [DMA_PAGES]innigkeit.mem.PhysicalPage.Index,
    avail_idx: u16,
    used_last_seen: u16,

    /// Pre-allocated page for the block request header + status byte.
    req_page: innigkeit.mem.PhysicalPage.Index,
    /// Pre-allocated page for the data bounce buffer (up to 8 sectors = 4 KiB).
    scratch_page: innigkeit.mem.PhysicalPage.Index,

    inline fn ior8(d: *const Device, offset: u16) u8 {
        return d.io.r8(offset);
    }
    inline fn ior16(d: *const Device, offset: u16) u16 {
        return d.io.r16(offset);
    }
    inline fn ior32(d: *const Device, offset: u16) u32 {
        return d.io.r32(offset);
    }
    inline fn iow8(d: *const Device, offset: u16, v: u8) void {
        d.io.w8(offset, v);
    }
    inline fn iow16(d: *const Device, offset: u16, v: u16) void {
        d.io.w16(offset, v);
    }
    inline fn iow32(d: *const Device, offset: u16, v: u32) void {
        d.io.w32(offset, v);
    }
};

var devices: [MAX_DEVICES]?Device = .{ null, null };
var device_count: usize = 0;

pub fn init() void {
    innigkeit.pci.forEachFunction(tryInit);
}

fn tryInit(addr: innigkeit.pci.Address, func: *innigkeit.pci.Function) void {
    _ = addr;
    if (device_count >= MAX_DEVICES) return;

    const vendor = func.read(u16, 0x00);
    const device = func.read(u16, 0x02);
    if (vendor != VIRTIO_VENDOR_ID or device != VIRTIO_BLK_DEVICE_ID) return;

    // Enable I/O space and bus-mastering.
    const cmd = func.read(u16, 0x04);
    func.write(u16, 0x04, cmd | 0x05);

    // BAR0: I/O space BAR.
    const bar0 = func.read(u32, 0x10);
    if (bar0 & 1 == 0) {
        log.warn("virtio-blk BAR0 is not an I/O BAR ({x}), skipping", .{bar0});
        return;
    }
    const io_base: u16 = @truncate(bar0 & 0xFFFC);
    log.debug("virtio-blk[{}] found: I/O base=0x{x}", .{ device_count, io_base });

    var dev: Device = .{
        .io = .{ .base = io_base },
        .capacity_sectors = 0,
        .queue_num = 0,
        .dma_pages = undefined,
        .avail_idx = 0,
        .used_last_seen = 0,
        .req_page = undefined,
        .scratch_page = undefined,
    };

    dev.iow8(REG_DEVICE_STATUS, 0);
    dev.iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);
    dev.iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    const dev_features = dev.ior32(REG_DEVICE_FEATURES);
    dev.iow32(REG_DRIVER_FEATURES, dev_features);

    const cap_lo = dev.ior32(REG_CONFIG_CAPACITY_LO);
    const cap_hi = dev.ior32(REG_CONFIG_CAPACITY_HI);
    dev.capacity_sectors = (@as(u64, cap_hi) << 32) | cap_lo;
    log.info("virtio-blk[{}] capacity: {} sectors ({} MiB)", .{
        device_count,
        dev.capacity_sectors,
        dev.capacity_sectors / 2048,
    });

    if (!setupQueue(&dev)) return;

    // Pre-allocate the bounce buffers used on every I/O request. Since the
    // driver is single-threaded (protected by the caller's lock), these pages
    // can be reused across operations, eliminating per-request allocation.
    dev.req_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        log.err("virtio-blk[{}]: OOM allocating req_page", .{device_count});
        return;
    };
    dev.scratch_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        list.prepend(dev.req_page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(list);
        log.err("virtio-blk[{}]: OOM allocating scratch_page", .{device_count});
        return;
    };

    dev.iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);
    devices[device_count] = dev;
    device_count += 1;
    log.info("virtio-blk[{}] ready", .{device_count - 1});
}

fn setupQueue(dev: *Device) bool {
    dev.iow16(REG_QUEUE_SEL, 0);
    dev.queue_num = dev.ior16(REG_QUEUE_SIZE);
    if (dev.queue_num == 0 or dev.queue_num > QUEUE_SIZE_MAX) {
        log.err("virtio-blk queue size {} out of range (max {})", .{ dev.queue_num, QUEUE_SIZE_MAX });
        return false;
    }
    log.debug("virtio-blk device queue_num={}", .{dev.queue_num});

    // Allocate DMA_PAGES contiguous physical pages for the virtqueue.
    // The ring layout (with queue_num=256) spans exactly 3 pages:
    //   Page 0: descriptor table (256*16=4096 bytes)
    //   Page 1: available ring  (starts at offset 4096)
    //   Page 2: used ring       (starts at offset 8192)
    if (!allocContiguousPages(&dev.dma_pages)) {
        log.err("virtio-blk: could not find {} contiguous DMA pages", .{DMA_PAGES});
        return false;
    }

    // Zero all DMA pages.
    for (dev.dma_pages) |pg| {
        const virt = pg.baseAddress().toDirectMap().toPtr([*]u8);
        @memset(virt[0..PAGE_SIZE], 0);
    }

    // The virtqueue base is dma_pages[0] (lowest PFN).
    const queue_phys = dev.dma_pages[0].baseAddress().value;
    dev.iow32(REG_QUEUE_PFN, @intCast(queue_phys / PAGE_SIZE));

    dev.avail_idx = 0;
    dev.used_last_seen = 0;

    log.debug("virtio-blk queue 0 at phys=0x{x} (PFN={})", .{
        queue_phys, queue_phys / PAGE_SIZE,
    });
    return true;
}

/// Allocate DMA_PAGES physically contiguous pages and store them in
/// dma_pages[] in ascending physical order (dma_pages[0] = lowest PFN).
///
/// The free list inserts pages via prepend() in ascending PFN order, so
/// popFirst() returns pages in descending order within a contiguous region.
/// We therefore accept consecutive pages in either direction and sort at the end.
fn allocContiguousPages(dma_pages: *[DMA_PAGES]innigkeit.mem.PhysicalPage.Index) bool {
    var run: [DMA_PAGES]innigkeit.mem.PhysicalPage.Index = undefined;
    var run_len: usize = 0;
    var spares: innigkeit.mem.PhysicalPage.List = .{};

    var attempts: usize = 0;
    while (attempts < 256) : (attempts += 1) {
        const page = innigkeit.mem.PhysicalPage.allocator.allocate() catch break;
        const pfn = @intFromEnum(page);

        if (run_len > 0) {
            const prev_pfn = @intFromEnum(run[run_len - 1]);
            // Accept ascending or descending consecutive (free list prepends
            // in ascending order, so pops come out descending).
            const consecutive = (pfn == prev_pfn +% 1) or (pfn +% 1 == prev_pfn);
            if (consecutive) {
                run[run_len] = page;
                run_len += 1;
                if (run_len == DMA_PAGES) {
                    // Sort ascending so dma_pages[0] has the lowest PFN.
                    dma_pages.* = run;
                    for (0..DMA_PAGES) |i| {
                        for (i + 1..DMA_PAGES) |j| {
                            if (@intFromEnum(dma_pages[j]) < @intFromEnum(dma_pages[i])) {
                                const tmp = dma_pages[i];
                                dma_pages[i] = dma_pages[j];
                                dma_pages[j] = tmp;
                            }
                        }
                    }
                    if (spares.count > 0) innigkeit.mem.PhysicalPage.allocator.deallocate(spares);
                    return true;
                }
                continue;
            }
        }
        // Not consecutive: discard current run into spares, start fresh.
        for (0..run_len) |i| spares.prepend(run[i]);
        run[0] = page;
        run_len = 1;
    }

    // Failed: release everything.
    for (0..run_len) |i| spares.prepend(run[i]);
    if (spares.count > 0) innigkeit.mem.PhysicalPage.allocator.deallocate(spares);
    return false;
}

pub const ReadError = error{ NotInitialized, OutOfRange, DeviceError };
pub const WriteError = error{ NotInitialized, OutOfRange, DeviceError };

const BLK_T_OUT: u32 = 1; // write request type

/// Submit a single virtio-blk request and poll for completion.
///
/// `req_type`: BLK_T_IN (read) or BLK_T_OUT (write).
/// `data_flags`: VRING_DESC_F_WRITE for reads (device writes data), 0 for writes.
/// The caller fills `scratch_virt` with data before calling (writes) or reads it
/// after (reads). Returns error on timeout or non-zero device status.
fn submitRequest(
    dev: *Device,
    dev_idx: usize,
    lba: u64,
    count: u32,
    req_type: u32,
    data_flags: u16,
) ReadError!void {
    const scratch_phys = dev.scratch_page.baseAddress().value;
    const req_phys = dev.req_page.baseAddress().value;
    const req_virt = dev.req_page.baseAddress().toDirectMap().toPtr([*]u8);

    const header: BlkReqHeader = .{ .type_ = req_type, .ioprio = 0, .sector = lba };
    @memcpy(req_virt[0..@sizeOf(BlkReqHeader)], std.mem.asBytes(&header));
    req_virt[@sizeOf(BlkReqHeader)] = 0xFF; // status sentinel

    const pg0 = dev.dma_pages[0].baseAddress().toDirectMap().toPtr([*]u8);
    const pg1 = dev.dma_pages[1].baseAddress().toDirectMap().toPtr([*]u8);
    const pg2 = dev.dma_pages[2].baseAddress().toDirectMap().toPtr([*]u8);
    const descs: *[QUEUE_SIZE_MAX]VringDesc = @ptrCast(@alignCast(pg0));
    const avail_idx_ptr: *u16 = @ptrCast(@alignCast(pg1 + 2));
    const avail_ring_base: [*]u16 = @ptrCast(@alignCast(pg1 + 4));
    const used_idx_ptr: *u16 = @ptrCast(@alignCast(pg2 + 2));

    descs[0] = .{ .addr = req_phys, .len = @sizeOf(BlkReqHeader), .flags = VRING_DESC_F_NEXT, .next = 1 };
    descs[1] = .{ .addr = scratch_phys, .len = @as(u32, count) * 512, .flags = data_flags | VRING_DESC_F_NEXT, .next = 2 };
    descs[2] = .{ .addr = req_phys + @sizeOf(BlkReqHeader), .len = 1, .flags = VRING_DESC_F_WRITE, .next = 0 };

    const avail_ring_idx = dev.avail_idx % dev.queue_num;
    @atomicStore(u16, &avail_ring_base[avail_ring_idx], 0, .monotonic);
    @atomicStore(u16, avail_idx_ptr, avail_idx_ptr.* +% 1, .release);
    dev.avail_idx +%= 1;

    dev.iow16(REG_QUEUE_NOTIFY, 0);

    const expected = dev.used_last_seen +% 1;
    var timeout: u32 = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if (@atomicLoad(u16, used_idx_ptr, .acquire) == expected) break;
        architecture.spinLoopHint();
    }
    if (timeout == 0) {
        log.err("virtio-blk[{}]: timeout waiting for used ring", .{dev_idx});
        return error.DeviceError;
    }
    dev.used_last_seen = expected;

    const status = req_virt[@sizeOf(BlkReqHeader)];
    if (status != 0) {
        log.err("virtio-blk[{}]: I/O error, status={}", .{ dev_idx, status });
        return error.DeviceError;
    }
}

/// Read up to 8 sectors (4 KiB) from `dev_idx` starting at `lba` into `buf`.
/// `buf` must be at least `count * 512` bytes; count must be <= 8.
pub fn readSectors(dev_idx: usize, lba: u64, buf: []u8, count: u32) ReadError!void {
    if (count == 0 or count > 8) return error.OutOfRange;
    const dev: *Device = if (devices[dev_idx]) |*d| d else return error.NotInitialized;
    if (lba + count > dev.capacity_sectors) return error.OutOfRange;
    if (buf.len < @as(usize, count) * 512) return error.OutOfRange;

    try submitRequest(dev, dev_idx, lba, count, BLK_T_IN, VRING_DESC_F_WRITE);
    const scratch_virt = dev.scratch_page.baseAddress().toDirectMap().toPtr([*]u8);
    @memcpy(buf[0 .. @as(usize, count) * 512], scratch_virt[0 .. @as(usize, count) * 512]);
}

/// Read bytes from device `dev_idx` at byte offset `byte_offset` into `buf`.
/// Handles unaligned offsets and chunking (max 8 sectors = 4 KiB per transaction).
pub fn readBytes(dev_idx: usize, byte_offset: u64, buf: []u8) ReadError!void {
    if (buf.len == 0) return;
    var tmp: [8 * 512]u8 = undefined;
    var cur_byte: u64 = byte_offset;
    var out_pos: usize = 0;
    var remaining: usize = buf.len;

    while (remaining > 0) {
        const sector: u64 = cur_byte / 512;
        const off_in_sector: usize = @intCast(cur_byte % 512);
        const sectors_needed: u32 = @intCast(@min(8, (off_in_sector + remaining + 511) / 512));
        const chunk_bytes: usize = @as(usize, sectors_needed) * 512;
        try readSectors(dev_idx, sector, tmp[0..chunk_bytes], sectors_needed);
        const copy_len: usize = @min(remaining, chunk_bytes - off_in_sector);
        @memcpy(buf[out_pos..][0..copy_len], tmp[off_in_sector..][0..copy_len]);
        out_pos += copy_len;
        remaining -= copy_len;
        cur_byte += copy_len;
    }
}

/// Write up to 8 sectors (4 KiB) to `dev_idx` starting at `lba` from `buf`.
/// `buf` must be exactly `count * 512` bytes; count must be <= 8.
pub fn writeSectors(dev_idx: usize, lba: u64, buf: []const u8, count: u32) WriteError!void {
    if (count == 0 or count > 8) return error.OutOfRange;
    const dev: *Device = if (devices[dev_idx]) |*d| d else return error.NotInitialized;
    if (lba + count > dev.capacity_sectors) return error.OutOfRange;
    if (buf.len < @as(usize, count) * 512) return error.OutOfRange;

    const scratch_virt = dev.scratch_page.baseAddress().toDirectMap().toPtr([*]u8);
    @memcpy(scratch_virt[0 .. @as(usize, count) * 512], buf[0 .. @as(usize, count) * 512]);
    // data_flags=0: device reads data (no WRITE flag on data descriptor)
    try submitRequest(dev, dev_idx, lba, count, BLK_T_OUT, 0);
}

/// Write bytes to device `dev_idx` at byte offset `byte_offset` from `buf`.
/// Offset and length must be multiples of 512 (sector size).
pub fn writeBytes(dev_idx: usize, byte_offset: u64, buf: []const u8) WriteError!void {
    if (buf.len == 0) return;
    if (byte_offset % 512 != 0 or buf.len % 512 != 0) return error.OutOfRange;
    var cur_byte: u64 = byte_offset;
    var in_pos: usize = 0;
    var remaining: usize = buf.len;

    while (remaining > 0) {
        const sector: u64 = cur_byte / 512;
        const sectors_now: u32 = @intCast(@min(8, remaining / 512));
        const chunk_bytes: usize = @as(usize, sectors_now) * 512;
        try writeSectors(dev_idx, sector, buf[in_pos..][0..chunk_bytes], sectors_now);
        in_pos += chunk_bytes;
        remaining -= chunk_bytes;
        cur_byte += chunk_bytes;
    }
}

pub fn bootDiskSectorCount() u64 {
    if (devices[0]) |d| return d.capacity_sectors;
    return 0;
}

pub fn dataDiskSectorCount() u64 {
    if (devices[1]) |d| return d.capacity_sectors;
    return 0;
}

/// Return the sector count for the device at dev_idx, or null if no such device.
pub fn diskSectorCount(dev_idx: usize) ?u64 {
    if (dev_idx >= MAX_DEVICES) return null;
    return if (devices[dev_idx]) |d| d.capacity_sectors else null;
}

pub fn isBootReady() bool {
    return devices[0] != null;
}

/// Returns true if a data disk is available (device 1, or device 0 in single-drive setups).
pub fn isDataReady() bool {
    return devices[1] != null or device_count == 1;
}

/// Returns the device index to use for data (WAD) reads.
/// In single-drive setups (e.g. UTM with only the WAD attached), use device 0.
pub fn dataDeviceIndex() usize {
    if (devices[1] != null) return 1;
    return 0;
}
