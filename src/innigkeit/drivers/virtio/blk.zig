//! virtio-blk driver (legacy PCI transport, poll mode).
//!
//! Supports the legacy virtio-blk device (vendor=0x1AF4, device=0x1001) as
//! exposed by QEMU with disable-modern=on. Uses I/O port BAR0 registers.
//!
//! Only one device is supported. After `init()`, call `readSectors()` to
//! read 512-byte sectors from the disk.

const std = @import("std");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const core = @import("core");

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

// Driver state (single device)
var initialized: bool = false;
var io_base: u16 = 0;
var capacity_sectors: u64 = 0;
var queue_num: u16 = 0; // actual queue size from device

// Three physically contiguous DMA pages for the virtqueue.
// dma_pages[0] = lowest physical page (PFN, contains descriptor table)
// dma_pages[1] = PFN+1 (available ring)
// dma_pages[2] = PFN+2 (used ring)
var dma_pages: [DMA_PAGES]innigkeit.mem.PhysicalPage.Index = undefined;

var avail_idx: u16 = 0;
var used_last_seen: u16 = 0;

// Convenience: read/write I/O port at (io_base + offset).
inline fn ior8(offset: u16) u8 {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    return port.read(u8);
}
inline fn ior16(offset: u16) u16 {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    return port.read(u16);
}
inline fn ior32(offset: u16) u32 {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    return port.read(u32);
}
inline fn iow8(offset: u16, v: u8) void {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    port.write(u8, v);
}
inline fn iow16(offset: u16, v: u16) void {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    port.write(u16, v);
}
inline fn iow32(offset: u16, v: u32) void {
    const port = architecture.io.Port.from(io_base + offset) catch unreachable;
    port.write(u32, v);
}

pub fn init() void {
    innigkeit.pci.forEachFunction(tryInit);
}

fn tryInit(addr: innigkeit.pci.Address, func: *innigkeit.pci.Function) void {
    _ = addr;
    if (initialized) return;

    const vendor = func.read(u16, 0x00);
    const device = func.read(u16, 0x02);
    if (vendor != VIRTIO_VENDOR_ID or device != VIRTIO_BLK_DEVICE_ID) return;

    // Enable I/O space and bus-mastering.
    const cmd = func.read(u16, 0x04);
    func.write(u16, 0x04, cmd | 0x05);

    // BAR0: I/O space BAR.
    const bar0 = func.read(u32, 0x10);
    if (bar0 & 1 == 0) {
        log.warn("virtio-blk BAR0 is not an I/O BAR ({x}) — skipping", .{bar0});
        return;
    }
    io_base = @truncate(bar0 & 0xFFFC);
    log.debug("virtio-blk found: I/O base=0x{x}", .{io_base});

    // Reset device.
    iow8(REG_DEVICE_STATUS, 0);

    // Acknowledge and claim the device.
    iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);
    iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Feature negotiation — accept all device features.
    const dev_features = ior32(REG_DEVICE_FEATURES);
    iow32(REG_DRIVER_FEATURES, dev_features);

    // Read disk capacity.
    const cap_lo = ior32(REG_CONFIG_CAPACITY_LO);
    const cap_hi = ior32(REG_CONFIG_CAPACITY_HI);
    capacity_sectors = (@as(u64, cap_hi) << 32) | cap_lo;
    log.info("virtio-blk capacity: {} sectors ({} MiB)", .{
        capacity_sectors,
        capacity_sectors / 2048,
    });

    // Set up virtqueue 0.
    if (!setupQueue()) return;

    // Signal driver ready.
    iow8(REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

    initialized = true;
    log.info("virtio-blk ready", .{});
}

fn setupQueue() bool {
    // Select queue 0.
    iow16(REG_QUEUE_SEL, 0);

    // Read the device-reported queue size.  In QEMU's legacy virtio-pci the
    // QUEUE_NUM register is read-only; writes are silently ignored.  We must
    // use the value the device reports for all ring offset calculations.
    queue_num = ior16(REG_QUEUE_SIZE);
    if (queue_num == 0 or queue_num > QUEUE_SIZE_MAX) {
        log.err("virtio-blk queue size {} out of range (max {})", .{ queue_num, QUEUE_SIZE_MAX });
        return false;
    }
    log.debug("virtio-blk device queue_num={}", .{queue_num});

    // Allocate DMA_PAGES contiguous physical pages for the virtqueue.
    // The ring layout (with queue_num=256) spans exactly 3 pages:
    //   Page 0: descriptor table (256*16=4096 bytes)
    //   Page 1: available ring  (starts at offset 4096)
    //   Page 2: used ring       (starts at offset 8192)
    if (!allocContiguousPages()) {
        log.err("virtio-blk: could not find {} contiguous DMA pages", .{DMA_PAGES});
        return false;
    }

    // Zero all DMA pages.
    for (dma_pages) |pg| {
        const virt = pg.baseAddress().toDirectMap().toPtr([*]u8);
        @memset(virt[0..PAGE_SIZE], 0);
    }

    // The virtqueue base is dma_pages[0] (lowest PFN).
    const queue_phys = dma_pages[0].baseAddress().value;
    iow32(REG_QUEUE_PFN, @intCast(queue_phys / PAGE_SIZE));

    avail_idx = 0;
    used_last_seen = 0;

    log.debug("virtio-blk queue 0 at phys=0x{x} (PFN={}), pages={d}", .{
        queue_phys, queue_phys / PAGE_SIZE, DMA_PAGES,
    });
    return true;
}

/// Allocate DMA_PAGES physically contiguous pages and store them in
/// dma_pages[] in ascending physical order (dma_pages[0] = lowest PFN).
///
/// The free list inserts pages via prepend() in ascending PFN order, so
/// popFirst() returns pages in descending order within a contiguous region.
/// We therefore accept consecutive pages in either direction and sort at the end.
fn allocContiguousPages() bool {
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
                    dma_pages = run;
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
        // Not consecutive — discard current run into spares, start fresh.
        for (0..run_len) |i| spares.prepend(run[i]);
        run[0] = page;
        run_len = 1;
    }

    // Failed — release everything.
    for (0..run_len) |i| spares.prepend(run[i]);
    if (spares.count > 0) innigkeit.mem.PhysicalPage.allocator.deallocate(spares);
    return false;
}

pub const ReadError = error{ NotInitialized, OutOfRange, DeviceError };

/// Read `count` 512-byte sectors starting at `lba` into `buf`.
/// `buf` must be at least `count * 512` bytes.
pub fn readSectors(lba: u64, buf: []u8, count: u32) ReadError!void {
    if (!initialized) return error.NotInitialized;
    if (lba + count > capacity_sectors) return error.OutOfRange;
    if (buf.len < @as(usize, count) * 512) return error.OutOfRange;

    // Allocate scratch page (data buffer) and request page (header + status).
    const scratch_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch return error.DeviceError;
    defer {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        list.prepend(scratch_page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(list);
    }
    const scratch_phys = scratch_page.baseAddress().value;
    const scratch_virt = scratch_page.baseAddress().toDirectMap().toPtr([*]u8);

    const req_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch return error.DeviceError;
    defer {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        list.prepend(req_page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(list);
    }
    const req_phys = req_page.baseAddress().value;
    const req_virt = req_page.baseAddress().toDirectMap().toPtr([*]u8);

    // Write the block request header at offset 0 of req_page.
    const header: BlkReqHeader = .{
        .type_ = BLK_T_IN,
        .ioprio = 0,
        .sector = lba,
    };
    @memcpy(req_virt[0..@sizeOf(BlkReqHeader)], std.mem.asBytes(&header));
    req_virt[@sizeOf(BlkReqHeader)] = 0xFF; // status sentinel

    // Virtual addresses of the three DMA pages.
    const pg0 = dma_pages[0].baseAddress().toDirectMap().toPtr([*]u8); // descriptor table
    const pg1 = dma_pages[1].baseAddress().toDirectMap().toPtr([*]u8); // available ring
    const pg2 = dma_pages[2].baseAddress().toDirectMap().toPtr([*]u8); // used ring

    // Descriptor table at pg0.
    const descs: *[QUEUE_SIZE_MAX]VringDesc = @ptrCast(@alignCast(pg0));

    // Available ring at pg1: flags(u16) + idx(u16) + ring[queue_num](u16[]).
    // Use raw byte offsets to avoid struct sizing issues.
    const avail_flags: *u16 = @ptrCast(@alignCast(pg1 + 0));
    const avail_idx_ptr: *u16 = @ptrCast(@alignCast(pg1 + 2));
    const avail_ring_base: [*]u16 = @ptrCast(@alignCast(pg1 + 4));
    _ = avail_flags;

    // Used ring at pg2: flags(u16) + idx(u16) + ring[queue_num]({id:u32, len:u32}[]).
    const used_idx_ptr: *u16 = @ptrCast(@alignCast(pg2 + 2));

    // Use descriptor slots 0, 1, 2.
    const d0: u16 = 0;
    const d1: u16 = 1;
    const d2: u16 = 2;

    descs[d0] = .{
        .addr = req_phys,
        .len = @sizeOf(BlkReqHeader),
        .flags = VRING_DESC_F_NEXT,
        .next = d1,
    };
    descs[d1] = .{
        .addr = scratch_phys,
        .len = @as(u32, count) * 512,
        .flags = VRING_DESC_F_WRITE | VRING_DESC_F_NEXT,
        .next = d2,
    };
    descs[d2] = .{
        .addr = req_phys + @sizeOf(BlkReqHeader),
        .len = 1,
        .flags = VRING_DESC_F_WRITE,
        .next = 0,
    };

    // Post descriptor chain to the available ring.
    const avail_ring_idx = avail_idx % queue_num;
    @atomicStore(u16, &avail_ring_base[avail_ring_idx], d0, .monotonic);
    @atomicStore(u16, avail_idx_ptr, avail_idx_ptr.* +% 1, .release);
    avail_idx +%= 1;

    // Kick queue 0.
    iow16(REG_QUEUE_NOTIFY, 0);

    // Poll used ring until the device completes the request.
    const expected_used_idx = used_last_seen +% 1;
    var timeout: u32 = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        if (@atomicLoad(u16, used_idx_ptr, .acquire) == expected_used_idx) break;
        architecture.spinLoopHint();
    }
    if (timeout == 0) {
        log.err("virtio-blk: timeout (used.idx={}, expected={})", .{ @atomicLoad(u16, used_idx_ptr, .monotonic), expected_used_idx });
        return error.DeviceError;
    }
    used_last_seen = expected_used_idx;

    // Check status byte (0 = success).
    const status = req_virt[@sizeOf(BlkReqHeader)];
    if (status != 0) {
        log.err("virtio-blk: I/O error, status={}", .{status});
        return error.DeviceError;
    }

    // Copy from scratch page to caller's buffer.
    @memcpy(buf[0 .. @as(usize, count) * 512], scratch_virt[0 .. @as(usize, count) * 512]);
}

pub fn sectorCount() u64 {
    return capacity_sectors;
}

pub fn isReady() bool {
    return initialized;
}
