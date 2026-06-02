//! virtio-net driver (legacy PCI transport, poll mode).
//!
//! Detects virtio-net (vendor=0x1AF4, device=0x1000), initializes two
//! virtqueues (RX=0, TX=1), reads the device MAC, and exposes
//! `send` / `receive` functions for the network stack.
//!
//! Follows the same legacy PCI pattern as virtio-blk.

const std = @import("std");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const core = @import("core");
const net = @import("../../net/root.zig");

const log = innigkeit.debug.log.scoped(.virtio_net);

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_NET_DEVICE_ID: u16 = 0x1000;

const REG_DEVICE_FEATURES: u16 = 0x00;
const REG_DRIVER_FEATURES: u16 = 0x04;
const REG_QUEUE_PFN: u16 = 0x08;
const REG_QUEUE_SIZE: u16 = 0x0C;
const REG_QUEUE_SEL: u16 = 0x0E;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_DEVICE_STATUS: u16 = 0x12;
const REG_ISR: u16 = 0x13;
// Net-specific config registers (start at 0x14): MAC bytes 0-5 at 0x14-0x19.
const REG_MAC_0: u16 = 0x14;

const STATUS_ACKNOWLEDGE: u8 = 0x01;
const STATUS_DRIVER: u8 = 0x02;
const STATUS_DRIVER_OK: u8 = 0x04;

const VIRTIO_NET_F_MAC: u32 = 1 << 5;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

const QUEUE_SIZE: u16 = 64; // must be <= device-reported max
const PAGE_SIZE: usize = 4096;
const DMA_PAGES: usize = 3;

const VringDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

// Prepended to every TX/RX packet (legacy mode, no GSO).
const NetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
};
const NET_HDR_LEN: usize = @sizeOf(NetHdr);

const QUEUE_RX: u16 = 0;
const QUEUE_TX: u16 = 1;

const Queue = struct {
    io_base: u16,
    queue_num: u16,
    dma_pages: [DMA_PAGES]innigkeit.mem.PhysicalPage.Index,
    avail_idx: u16 = 0,
    used_last_seen: u16 = 0,
    sel: u16,

    inline fn desc(q: *Queue) [*]volatile VringDesc {
        const phys = q.dma_pages[0].baseAddress();
        return @ptrFromInt(phys.toDirectMap().value);
    }
    inline fn avail_ring(q: *Queue) [*]volatile u16 {
        const phys = q.dma_pages[1].baseAddress();
        return @ptrFromInt(phys.toDirectMap().value);
    }
    inline fn used_ring(q: *Queue) [*]volatile u32 {
        const phys = q.dma_pages[2].baseAddress();
        return @ptrFromInt(phys.toDirectMap().value);
    }
    inline fn ior8(q: *Queue, off: u16) u8 {
        const p = architecture.io.Port.from(q.io_base + off) catch unreachable;
        return p.read(u8);
    }
    inline fn iow8(q: *Queue, off: u16, v: u8) void {
        const p = architecture.io.Port.from(q.io_base + off) catch unreachable;
        p.write(u8, v);
    }
    inline fn iow16(q: *Queue, off: u16, v: u16) void {
        const p = architecture.io.Port.from(q.io_base + off) catch unreachable;
        p.write(u16, v);
    }
    inline fn iow32(q: *Queue, off: u16, v: u32) void {
        const p = architecture.io.Port.from(q.io_base + off) catch unreachable;
        p.write(u32, v);
    }
    inline fn ior16(q: *Queue, off: u16) u16 {
        const p = architecture.io.Port.from(q.io_base + off) catch unreachable;
        return p.read(u16);
    }
};

const Device = struct {
    io_base: u16,
    mac: [6]u8,
    rx: Queue,
    tx: Queue,
    ip: [4]u8 = .{ 0, 0, 0, 0 }, // filled by DHCP / static config
    ip_id: u16 = 0,
};

var g_dev: ?Device = null;

pub fn getMac() ?*const [6]u8 {
    if (g_dev) |*d| return &d.mac else return null;
}

pub fn getIp() ?*const [4]u8 {
    if (g_dev) |*d| return &d.ip else return null;
}

pub fn setIp(ip: [4]u8) void {
    if (g_dev) |*d| d.ip = ip;
}

pub fn nextIpId() u16 {
    if (g_dev) |*d| {
        const id = d.ip_id;
        d.ip_id +%= 1;
        return id;
    }
    return 0;
}

pub fn init() void {
    innigkeit.pci.forEachFunction(tryInit);
}

fn tryInit(addr: innigkeit.pci.Address, func: *innigkeit.pci.Function) void {
    _ = addr;
    if (g_dev != null) return; // only one device

    const vendor = func.read(u16, 0x00);
    const device = func.read(u16, 0x02);
    if (vendor != VIRTIO_VENDOR_ID or device != VIRTIO_NET_DEVICE_ID) return;

    // Enable I/O space + bus mastering.
    const cmd = func.read(u16, 0x04);
    func.write(u16, 0x04, cmd | 0x05);

    const bar0_raw = func.read(u32, 0x10);
    if (bar0_raw & 1 == 0) {
        log.warn("virtio-net BAR0 is not I/O space! skipping", .{});
        return;
    }
    const io_base: u16 = @truncate(bar0_raw & 0xFFFC);

    // Device handshake.
    const status_port = architecture.io.Port.from(io_base + REG_DEVICE_STATUS) catch return;
    status_port.write(u8, 0x00);
    status_port.write(u8, STATUS_ACKNOWLEDGE);
    status_port.write(u8, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Negotiate features (accept MAC feature only for now).
    const feat_port = architecture.io.Port.from(io_base + REG_DEVICE_FEATURES) catch return;
    const dev_features = feat_port.read(u32);
    const drv_features = dev_features & VIRTIO_NET_F_MAC;
    (architecture.io.Port.from(io_base + REG_DRIVER_FEATURES) catch return).write(u32, drv_features);

    // Read MAC address.
    var mac: [6]u8 = undefined;
    for (&mac, 0..) |*byte, i| {
        byte.* = (architecture.io.Port.from(io_base + REG_MAC_0 + @as(u16, @intCast(i))) catch return).read(u8);
    }

    log.info("MAC: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });

    var rx_q = setupQueue(io_base, QUEUE_RX) orelse return;
    const tx_q = setupQueue(io_base, QUEUE_TX) orelse return;

    // Pre-populate RX descriptors (one descriptor + 1506-byte buffer each).
    populateRx(&rx_q);

    // Driver OK.
    status_port.write(u8, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

    g_dev = .{
        .io_base = io_base,
        .mac = mac,
        .rx = rx_q,
        .tx = tx_q,
    };

    log.info("virtio-net ready (io_base=0x{x})", .{io_base});
}

fn setupQueue(io_base: u16, sel: u16) ?Queue {
    var q: Queue = .{
        .io_base = io_base,
        .queue_num = 0,
        .dma_pages = undefined,
        .sel = sel,
    };

    (architecture.io.Port.from(io_base + REG_QUEUE_SEL) catch return null).write(u16, sel);
    const qnum_raw = (architecture.io.Port.from(io_base + REG_QUEUE_SIZE) catch return null).read(u16);
    q.queue_num = @min(qnum_raw, QUEUE_SIZE);
    if (q.queue_num == 0) return null;

    // Allocate 3 pages for descriptor, available, and used rings.
    var pages: [DMA_PAGES]innigkeit.mem.PhysicalPage.Index = undefined;
    for (&pages) |*p| {
        p.* = innigkeit.mem.PhysicalPage.allocator.allocate() catch return null;
    }

    // Zero the pages.
    for (pages) |p| {
        const vr = innigkeit.KernelVirtualRange.from(p.baseAddress().toDirectMap(), architecture.paging.standard_page_size);
        @memset(vr.byteSlice(), 0);
    }

    q.dma_pages = pages;

    // Write PFN (page frame number of first descriptor page).
    const pfn: u32 = @intCast(pages[0].baseAddress().value / PAGE_SIZE);
    (architecture.io.Port.from(io_base + REG_QUEUE_PFN) catch return null).write(u32, pfn);

    return q;
}

// RX buffer size: virtio-net header (10) + max Ethernet frame (1514) = 1524,
// rounded up to a safe 1536 bytes. We share one big allocation for simplicity.
const RX_BUF_SIZE: usize = 1536;
var rx_bufs: [QUEUE_SIZE][RX_BUF_SIZE]u8 align(PAGE_SIZE) = undefined;

fn populateRx(q: *Queue) void {
    const descs = q.desc();
    const avail = q.avail_ring();

    // avail[0] = flags, avail[1] = idx
    avail[0] = 0; // no VIRTQ_AVAIL_F_NO_INTERRUPT
    avail[1] = 0;

    var i: u16 = 0;
    while (i < q.queue_num) : (i += 1) {
        const buf_phys = @intFromPtr(&rx_bufs[i]) - architecture.paging.standard_page_size.value; // rough direct-map offset
        _ = buf_phys; // In real impl, translate virt to phys via page table
        descs[i].addr = @intFromPtr(&rx_bufs[i]); // placeholder: VA treated as PA for now
        descs[i].len = RX_BUF_SIZE;
        descs[i].flags = VRING_DESC_F_WRITE;
        descs[i].next = 0;
        avail[2 + i] = i; // ring entry
    }
    avail[1] = q.queue_num; // advance avail idx

    // Notify device of available RX buffers.
    (architecture.io.Port.from(q.io_base + REG_QUEUE_NOTIFY) catch return).write(u16, QUEUE_RX);
}

var tx_bufs: [QUEUE_SIZE][1536]u8 align(PAGE_SIZE) = undefined;
var tx_hdr: [QUEUE_SIZE]NetHdr = .{.{}} ** QUEUE_SIZE;

/// Send a raw Ethernet frame. Returns true on success.
pub fn send(frame: []const u8) bool {
    const dev = if (g_dev != null) &g_dev.? else return false;
    const q = &dev.tx;

    if (frame.len > 1514) return false;

    const slot: u16 = q.avail_idx % q.queue_num;
    const descs = q.desc();
    const avail = q.avail_ring();

    // Descriptor 0: virtio-net header (write-only for device, but TX uses read).
    const hdr = &tx_hdr[slot];
    hdr.* = .{};
    const desc0_idx = slot * 2;
    descs[desc0_idx].addr = @intFromPtr(hdr);
    descs[desc0_idx].len = NET_HDR_LEN;
    descs[desc0_idx].flags = VRING_DESC_F_NEXT;
    descs[desc0_idx].next = slot * 2 + 1;

    // Descriptor 1: packet data.
    @memcpy(tx_bufs[slot][0..frame.len], frame);
    descs[desc0_idx + 1].addr = @intFromPtr(&tx_bufs[slot]);
    descs[desc0_idx + 1].len = @intCast(frame.len);
    descs[desc0_idx + 1].flags = 0;
    descs[desc0_idx + 1].next = 0;

    // Add to available ring (volatile writes, fence for ordering).
    avail[2 + q.avail_idx % q.queue_num] = desc0_idx;
    asm volatile ("" ::: .{ .memory = true });
    avail[1] = q.avail_idx + 1;
    q.avail_idx += 1;

    // Notify device.
    (architecture.io.Port.from(q.io_base + REG_QUEUE_NOTIFY) catch return false).write(u16, QUEUE_TX);

    // Poll for completion (used ring).
    // used[0] = {flags:u16, idx:u16} packed as u32 little-endian; idx in upper half.
    var retries: usize = 0;
    const used = q.used_ring();
    while (@as(u16, @truncate(used[0] >> 16)) == q.used_last_seen) {
        architecture.spinLoopHint();
        retries += 1;
        if (retries > 10_000) return false;
    }
    q.used_last_seen += 1;
    return true;
}

/// Poll for a received frame. Calls `callback` for each frame received.
/// The slice passed to callback is valid only during the call.
pub fn pollRx(callback: fn (frame: []const u8) void) void {
    const dev = if (g_dev != null) &g_dev.? else return;
    const q = &dev.rx;
    const used = q.used_ring();

    while (true) {
        // used[0] = {flags:u16, idx:u16} little-endian; idx in upper half.
        const used_idx: u16 = @truncate(used[0] >> 16);
        if (used_idx == q.used_last_seen) break;

        // Ring entries start at used[1]: {id:u32, len:u32} per slot.
        const ue_offset = 1 + (q.used_last_seen % q.queue_num) * 2;
        const desc_id: u32 = used[ue_offset];
        const len: u32 = used[ue_offset + 1];

        if (len > NET_HDR_LEN and desc_id < q.queue_num) {
            const raw = rx_bufs[desc_id][0..len];
            // Skip the virtio-net header.
            callback(raw[NET_HDR_LEN..]);
        }

        // Recycle the descriptor.
        const avail2 = q.avail_ring();
        avail2[2 + q.avail_idx % q.queue_num] = @intCast(desc_id);
        q.avail_idx += 1;
        asm volatile ("" ::: .{ .memory = true });
        avail2[1] = q.avail_idx;

        q.used_last_seen += 1;
    }

    // Notify device of recycled buffers.
    (architecture.io.Port.from(q.io_base + REG_QUEUE_NOTIFY) catch return).write(u16, QUEUE_RX);
}
