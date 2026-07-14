//! virtio-net driver (legacy PCI transport).
//!
//! Detects virtio-net (vendor=0x1AF4, device=0x1000), initializes two
//! virtqueues (RX=0, TX=1) via the shared legacy vring layer, reads the
//! device MAC, and exposes `send` / `pollRx` / `waitRx` for the network
//! stack.
//!
//! When the device's INTx line can be routed, RX is interrupt-driven: the
//! net-poll task blocks in `waitRx` until the IRQ handler wakes it. TX never
//! blocks; `send` reaps prior completions lazily and returns right after the
//! notify. Without a routable interrupt everything degenerates to the
//! original poll mode.
//!
//! Ring layout and indexing always use the DEVICE-reported queue size N
//! (legacy REG_QUEUE_SIZE is read-only; see legacy.zig). The driver itself
//! only manages NUM_BUFS (64) buffers per direction, so descriptor ids stay
//! below NUM_BUFS (RX) / 2*NUM_BUFS (TX) while ring slots wrap modulo N.
//!
//! All DMA buffers live in pages from the physical page allocator so that
//! descriptor `addr` fields can carry real physical addresses; the CPU
//! touches them through the direct map.

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const legacy = @import("legacy.zig");
const PortIo = @import("PortIo.zig");
const std = @import("std");

const log = innigkeit.debug.log.scoped(.virtio_net);

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_NET_DEVICE_ID: u16 = 0x1000;

// Net-specific config registers (legacy device config starts at 0x14):
// MAC bytes 0-5 at 0x14-0x19.
const REG_MAC_0: u16 = legacy.REG_DEVICE_CONFIG;

const VIRTIO_NET_F_MAC: u32 = 1 << 5;

/// Prepended to every TX/RX packet (legacy mode, no GSO, no MRG_RXBUF).
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

const PAGE_SIZE: usize = 4096;

/// Number of buffers the driver manages per direction. May be (and usually
/// is) smaller than the device queue size N; descriptor ids are < NUM_BUFS
/// for RX and < 2*NUM_BUFS for TX, but ring indexing always uses N.
const NUM_BUFS: u16 = 64;

/// Buffer size: virtio-net header (10) + max Ethernet frame (1514) = 1524,
/// rounded up to 1536.
const BUF_SIZE: usize = 1536;
const MAX_FRAME: usize = 1514;

/// Two 1536-byte buffers fit in each 4 KiB page (offsets 0 and 1536); the
/// slack above offset 3072 holds the per-slot 16-byte virtio-net TX headers,
/// so one TX slot's header + payload DMA targets live in a single page.
const BUFS_PER_PAGE: usize = 2;
const BUF_PAGES: usize = NUM_BUFS / BUFS_PER_PAGE;
const TX_HDR_BASE: usize = BUFS_PER_PAGE * BUF_SIZE; // 3072
const TX_HDR_STRIDE: usize = 16;

comptime {
    std.debug.assert(TX_HDR_BASE + BUFS_PER_PAGE * TX_HDR_STRIDE <= PAGE_SIZE);
    std.debug.assert(NET_HDR_LEN <= TX_HDR_STRIDE);
}

const PageIndex = innigkeit.memory.PhysicalPage.Index;

const Device = struct {
    io: PortIo,
    mac: [6]u8,
    rx: legacy.LegacyQueue,
    tx: legacy.LegacyQueue,
    rx_pages: [BUF_PAGES]PageIndex,
    tx_pages: [BUF_PAGES]PageIndex,
    ip: [4]u8 = .{ 0, 0, 0, 0 }, // filled by DHCP / static config
    ip_id: u16 = 0,

    /// Protects `rx_queue`; also taken by the IRQ handler.
    rx_lock: innigkeit.sync.TicketSpinLock = .{},
    /// `waitRx` blocks here until the IRQ handler wakes it.
    rx_queue: innigkeit.sync.WaitQueue = .{},
    /// Serializes `send` (slot allocation, TX reaping, ring publish).
    tx_lock: innigkeit.sync.TicketSpinLock = .{},
    /// Bit i set = TX slot i is in flight (published, not yet reaped).
    tx_busy: u64 = 0,
    /// True once INTx is routed; false = poll fallback (waitRx returns
    /// immediately).
    irq_enabled: bool = false,
};

comptime {
    // `tx_busy` is a u64 bitmap with one bit per TX slot.
    std.debug.assert(NUM_BUFS == 64);
}

var g_dev: ?Device = null;

/// Physical DMA address of buffer `i` (i < NUM_BUFS) within `pages`.
inline fn bufPhys(pages: *const [BUF_PAGES]PageIndex, i: usize) u64 {
    return pages[i / BUFS_PER_PAGE].baseAddress().value + (i % BUFS_PER_PAGE) * BUF_SIZE;
}

/// Kernel (direct-map) pointer to buffer `i` within `pages`.
inline fn bufPtr(pages: *const [BUF_PAGES]PageIndex, i: usize) [*]u8 {
    return pages[i / BUFS_PER_PAGE].baseAddress().toDirectMap().toPtr([*]u8) +
        (i % BUFS_PER_PAGE) * BUF_SIZE;
}

/// Physical DMA address of TX slot `i`'s virtio-net header.
inline fn txHdrPhys(pages: *const [BUF_PAGES]PageIndex, i: usize) u64 {
    return pages[i / BUFS_PER_PAGE].baseAddress().value +
        TX_HDR_BASE + (i % BUFS_PER_PAGE) * TX_HDR_STRIDE;
}

/// Kernel (direct-map) pointer to TX slot `i`'s virtio-net header.
inline fn txHdrPtr(pages: *const [BUF_PAGES]PageIndex, i: usize) [*]u8 {
    return pages[i / BUFS_PER_PAGE].baseAddress().toDirectMap().toPtr([*]u8) +
        TX_HDR_BASE + (i % BUFS_PER_PAGE) * TX_HDR_STRIDE;
}

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

    const io: PortIo = .{ .base = @truncate(bar0_raw & 0xFFFC) };

    // Device handshake.
    io.w8(legacy.REG_DEVICE_STATUS, 0x00);
    io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_ACKNOWLEDGE);
    io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_ACKNOWLEDGE | legacy.STATUS_DRIVER);

    // Negotiate features (accept MAC feature only for now).
    const dev_features = io.r32(legacy.REG_DEVICE_FEATURES);
    io.w32(legacy.REG_DRIVER_FEATURES, dev_features & VIRTIO_NET_F_MAC);

    // Read MAC address.
    var mac: [6]u8 = undefined;
    for (&mac, 0..) |*byte, i| {
        byte.* = io.r8(REG_MAC_0 + @as(u16, @intCast(i)));
    }

    log.info("MAC: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });

    var rx_q = legacy.LegacyQueue.setup(io, QUEUE_RX) orelse {
        log.err("virtio-net: RX queue setup failed", .{});
        io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_FAILED);
        return;
    };
    var tx_q = legacy.LegacyQueue.setup(io, QUEUE_TX) orelse {
        log.err("virtio-net: TX queue setup failed", .{});
        io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_FAILED);
        rx_q.destroy();
        return;
    };

    // RX keeps NUM_BUFS buffers outstanding (ids 0..NUM_BUFS-1); TX uses
    // descriptor ids up to 2*NUM_BUFS-1. Both must fit in the device rings.
    if (rx_q.queue_num < NUM_BUFS or tx_q.queue_num < 2 * NUM_BUFS) {
        log.err("virtio-net: device queues too small (rx N={}, tx N={}, need rx>={}, tx>={})", .{
            rx_q.queue_num, tx_q.queue_num, NUM_BUFS, 2 * NUM_BUFS,
        });
        io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_FAILED);
        tx_q.destroy();
        rx_q.destroy();
        return;
    }

    // Allocate the RX and TX DMA buffer pages (need not be contiguous).
    var rx_pages: [BUF_PAGES]PageIndex = undefined;
    var tx_pages: [BUF_PAGES]PageIndex = undefined;
    if (!allocBufferPages(&rx_pages, &tx_pages)) {
        log.err("virtio-net: OOM allocating packet buffers", .{});
        io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_FAILED);
        tx_q.destroy();
        rx_q.destroy();
        return;
    }

    // Hand all RX buffers to the device.
    populateRx(&rx_q, &rx_pages);

    // TX completions are reaped lazily by send(); only RX needs the
    // interrupt, so ask the device not to interrupt for the TX queue.
    tx_q.suppressInterrupts();

    // Driver OK, then kick the RX queue so it sees the buffers.
    io.w8(legacy.REG_DEVICE_STATUS, legacy.STATUS_ACKNOWLEDGE | legacy.STATUS_DRIVER | legacy.STATUS_DRIVER_OK);
    rx_q.notify();

    g_dev = .{
        .io = io,
        .mac = mac,
        .rx = rx_q,
        .tx = tx_q,
        .rx_pages = rx_pages,
        .tx_pages = tx_pages,
    };

    // Route INTx after g_dev is in place so the handler can always reach the
    // ISR register (level-triggered: not reading it leaves the line asserted).
    const handler: architecture.interrupts.Interrupt.Handler = .{
        .eoi = .level,
        .call = .prepare(onInterrupt, .{}),
    };
    g_dev.?.irq_enabled = legacy.setupIrq(addr, func, handler, "virtio-net");

    log.info("virtio-net ready (io_base=0x{x}, rx N={}, tx N={}, {} bufs/dir, {s} mode)", .{
        io.base,
        rx_q.queue_num,
        tx_q.queue_num,
        NUM_BUFS,
        if (g_dev.?.irq_enabled) "irq" else "poll",
    });
}

/// INTx handler. Must read the ISR register on every invocation: the line is
/// level-triggered and the read is what de-asserts it.
fn onInterrupt(
    _: architecture.interrupts.InterruptFrame,
    _: innigkeit.Task.Current.StateBeforeInterrupt,
) void {
    const dev = if (g_dev != null) &g_dev.? else return;

    const isr = legacy.readIsr(dev.io);
    if (isr & legacy.ISR_QUEUE == 0) return;

    dev.rx_lock.lock();
    dev.rx_queue.wakeOne(&dev.rx_lock);
    dev.rx_lock.unlock();
}

/// Block until the device has published at least one RX frame.
///
/// Returns true if the wait was interrupt-driven. Returns false immediately
/// when no device is present or INTx routing failed (poll fallback): the
/// caller should poll and yield instead.
pub fn waitRx() bool {
    const dev = if (g_dev != null) &g_dev.? else return false;
    if (!dev.irq_enabled) return false;

    // The device may publish (and interrupt) before we take the lock, and a
    // TX completion can wake us spuriously, so the condition is checked
    // under the lock before every wait; `wait` returns with the lock
    // released.
    dev.rx_lock.lock();
    while (!dev.rx.hasUsed()) {
        dev.rx_queue.wait(&dev.rx_lock);
        dev.rx_lock.lock();
    }
    dev.rx_lock.unlock();
    return true;
}

/// Allocate all RX and TX buffer pages, freeing everything on failure.
fn allocBufferPages(rx_pages: *[BUF_PAGES]PageIndex, tx_pages: *[BUF_PAGES]PageIndex) bool {
    var allocated: innigkeit.memory.PhysicalPage.List = .{};
    var ok = true;

    for ([_]*[BUF_PAGES]PageIndex{ rx_pages, tx_pages }) |pages| {
        for (pages) |*p| {
            p.* = innigkeit.memory.PhysicalPage.allocator.allocate() catch {
                ok = false;
                break;
            };
            allocated.prepend(p.*);
        }
        if (!ok) break;
    }
    if (!ok) {
        if (allocated.count > 0) innigkeit.memory.PhysicalPage.allocator.deallocate(allocated);
        return false;
    }

    return true;
}

/// Fill the RX descriptor table with one device-writable buffer per slot and
/// publish all of them to the avail ring. Descriptor ids are 0..NUM_BUFS-1;
/// ring slots advance modulo the device queue size inside publish().
fn populateRx(q: *legacy.LegacyQueue, rx_pages: *const [BUF_PAGES]PageIndex) void {
    const descs = q.descTable();

    var i: u16 = 0;

    while (i < NUM_BUFS) : (i += 1) {
        descs[i] = .{
            .addr = bufPhys(rx_pages, i),
            .len = BUF_SIZE,
            .flags = legacy.VRING_DESC_F_WRITE,
            .next = 0,
        };
        q.publish(i);
    }
}

/// Send a raw Ethernet frame. Returns true on success.
///
/// Asynchronous: returns right after notifying the device. Completions of
/// earlier sends are reaped lazily at entry; only when all NUM_BUFS slots
/// are still in flight (rare) does this spin (bounded) for one completion.
pub fn send(frame: []const u8) bool {
    const dev = if (g_dev != null) &g_dev.? else return false;
    const q = &dev.tx;

    if (frame.len == 0 or frame.len > MAX_FRAME) return false;

    dev.tx_lock.lock();
    defer dev.tx_lock.unlock();

    // Reap completed TX descriptor chains: each frees its slot for reuse.
    // Used ids are chain heads (= slot * 2).
    while (q.popUsed()) |elem| {
        const done_slot = elem.id / 2;
        if (done_slot < NUM_BUFS) dev.tx_busy &= ~(@as(u64, 1) << @intCast(done_slot));
    }

    // All slots in flight: bounded spin-reap for one completion.
    if (dev.tx_busy == std.math.maxInt(u64)) {
        const elem = q.waitUsed(100_000) orelse {
            log.warn("virtio-net: TX ring full and no completion, dropping frame", .{});
            return false;
        };
        const done_slot = elem.id / 2;
        if (done_slot >= NUM_BUFS) {
            log.warn("virtio-net: TX used id {} out of range, dropping frame", .{elem.id});
            return false;
        }
        dev.tx_busy &= ~(@as(u64, 1) << @intCast(done_slot));
    }

    const slot: u16 = @intCast(@ctz(~dev.tx_busy));
    dev.tx_busy |= @as(u64, 1) << @intCast(slot);

    // Zero the virtio-net header (no offloads).
    const hdr_bytes = txHdrPtr(&dev.tx_pages, slot)[0..NET_HDR_LEN];
    @memset(hdr_bytes, 0);

    // Copy the payload into the slot's DMA buffer.
    @memcpy(bufPtr(&dev.tx_pages, slot)[0..frame.len], frame);

    // Two-descriptor chain: header then payload (both device-readable).
    const descs = q.descTable();
    const head: u16 = slot * 2;
    descs[head] = .{
        .addr = txHdrPhys(&dev.tx_pages, slot),
        .len = NET_HDR_LEN,
        .flags = legacy.VRING_DESC_F_NEXT,
        .next = head + 1,
    };
    descs[head + 1] = .{
        .addr = bufPhys(&dev.tx_pages, slot),
        .len = @intCast(frame.len),
        .flags = 0,
        .next = 0,
    };

    q.publish(head);
    q.notify();

    return true;
}

/// Poll for received frames. Calls `callback` for each frame received.
/// The slice passed to callback is valid only during the call.
pub fn pollRx(callback: fn (frame: []const u8) void) void {
    const dev = if (g_dev != null) &g_dev.? else return;
    const q = &dev.rx;

    var recycled = false;
    while (q.popUsed()) |elem| {
        // Validate the device-supplied values before touching memory: the id
        // must name one of our NUM_BUFS descriptors and len must fit in the
        // 1536-byte buffer (and actually contain payload past the header).
        if (elem.id >= NUM_BUFS) {
            log.warn("virtio-net: RX used id {} out of range, dropping", .{elem.id});
            continue; // cannot recycle an id we never owned
        }
        if (elem.len > NET_HDR_LEN and elem.len <= BUF_SIZE) {
            const raw = bufPtr(&dev.rx_pages, elem.id)[0..elem.len];
            // Skip the virtio-net header.
            callback(raw[NET_HDR_LEN..]);
        } else {
            log.warn("virtio-net: RX frame with bad len {}, dropping", .{elem.len});
        }

        // Recycle the descriptor: the addr/len/flags are still intact, just
        // re-publish the same id.
        q.publish(@intCast(elem.id));
        recycled = true;
    }

    // Notify device of recycled buffers.
    if (recycled) q.notify();
}
