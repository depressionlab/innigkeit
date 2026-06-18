//! virtio-blk driver (legacy PCI transport).
//!
//! Supports up to two legacy virtio-blk devices (vendor=0x1AF4, device=0x1001).
//! Device 0 is the boot disk; device 1 is an optional data disk (e.g. WAD).
//! Uses I/O port BAR0 registers (disable-modern=on, disable-legacy=off).
//!
//! Completion is interrupt-driven when the device's INTx line can be routed
//! (the requesting task blocks until the IRQ handler wakes it); otherwise the
//! driver falls back to the original bounded-spin poll mode.

const std = @import("std");
const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const core = @import("core");
const PortIo = @import("PortIo.zig");
const legacy = @import("legacy.zig");

const log = innigkeit.debug.log.scoped(.virtio_blk);

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_BLK_DEVICE_ID: u16 = 0x1001; // legacy device ID

// Block-specific config registers (legacy device config starts at 0x14).
const REG_CONFIG_CAPACITY_LO: u16 = legacy.REG_DEVICE_CONFIG + 0x00;
const REG_CONFIG_CAPACITY_HI: u16 = legacy.REG_DEVICE_CONFIG + 0x04;

const STATUS_ACKNOWLEDGE = legacy.STATUS_ACKNOWLEDGE;
const STATUS_DRIVER = legacy.STATUS_DRIVER;
const STATUS_DRIVER_OK = legacy.STATUS_DRIVER_OK;

const BLK_T_IN: u32 = 0; // read request type

const VRING_DESC_F_NEXT = legacy.VRING_DESC_F_NEXT;
const VRING_DESC_F_WRITE = legacy.VRING_DESC_F_WRITE;

const MAX_DEVICES: usize = 2;

/// Block request header.
const BlkReqHeader = extern struct {
    type_: u32,
    ioprio: u32,
    sector: u64,
};

const Device = struct {
    io: PortIo,
    capacity_sectors: u64,
    queue: legacy.LegacyQueue,

    /// Pre-allocated page for the block request header + status byte.
    req_page: innigkeit.mem.PhysicalPage.Index,
    /// Pre-allocated page for the data bounce buffer (up to 8 sectors = 4 KiB).
    scratch_page: innigkeit.mem.PhysicalPage.Index,

    /// Serializes whole requests: the request/scratch bounce pages and the
    /// single descriptor chain are shared, so exactly one request may be in
    /// flight (from descriptor setup through copy-out) at a time.
    request_mutex: innigkeit.sync.Mutex = .{},
    /// Protects `completion_queue`; also taken by the IRQ handler.
    completion_lock: innigkeit.sync.TicketSpinLock = .{},
    /// The requesting task blocks here until the IRQ handler wakes it.
    completion_queue: innigkeit.sync.WaitQueue = .{},
    /// True once INTx is routed; false = bounded-spin poll fallback.
    irq_enabled: bool = false,

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

/// Number of times the INTx handler observed a queue interrupt, per device.
/// Diagnostic: proves the interrupt path is live (see the IRQ test below).
var irq_count: [MAX_DEVICES]std.atomic.Value(u64) = .{ .init(0), .init(0) };

/// Diagnostic: number of queue interrupts handled for `dev_idx`.
pub fn irqFireCount(dev_idx: usize) u64 {
    return irq_count[dev_idx].load(.monotonic);
}

pub fn init() void {
    innigkeit.pci.forEachFunction(tryInit);
}

/// INTx handler (one allocation per device, `dev_idx` bound at setup).
///
/// Services ALL initialized devices, not just `dev_idx`: PCI INTx lines may
/// share a GSI, and routing the second device's vector to a shared GSI
/// overwrites the first device's redirection entry. Whichever handler
/// survives must de-assert and wake every device on the line.
///
/// Must read each ISR register on every invocation: the line is
/// level-triggered and the read is what de-asserts it.
fn onInterrupt(
    _: architecture.interrupts.InterruptFrame,
    _: innigkeit.Task.Current.StateBeforeInterrupt,
    dev_idx: usize,
) void {
    _ = dev_idx;
    for (&devices, 0..) |*slot, i| {
        const dev: *Device = if (slot.*) |*d| d else continue;
        if (!dev.irq_enabled) continue;

        const isr = legacy.readIsr(dev.io);
        if (isr & legacy.ISR_QUEUE == 0) continue;

        _ = irq_count[i].fetchAdd(1, .monotonic);

        dev.completion_lock.lock();
        dev.completion_queue.wakeOne(&dev.completion_lock);
        dev.completion_lock.unlock();
    }
}

/// QEMU `virt` PCI I/O-space aperture CPU physical base, used as a fallback if
/// the device tree cannot be parsed. The `virt` machine maps the host bridge's
/// PCI I/O window here (size 0x10000); the `pcie` node's `ranges` I/O entry
/// describes it (`<0x01000000 0 0  0 0x3eff0000  0 0x10000>`). Derived at
/// runtime from the DTB in `resolveBar0`; this constant is the documented
/// QEMU-virt default for when no device tree is available.
const VIRT_PCI_IO_FALLBACK_BASE: u64 = 0x3eff_0000;

/// Resolve the legacy register window base for `func` into a `PortIo.base`.
///
/// x86-64: BAR0 is an I/O-space BAR; the base is the 16-bit port number.
///
/// aarch64 (QEMU virt): the legacy register block lives behind BAR0, which is a
/// PCI **I/O-space** BAR. There is no CPU port I/O, so the I/O space is exposed
/// as an MMIO aperture (the `pcie` node's `ranges` I/O entry: CPU phys
/// 0x3eff0000, size 0x10000). An I/O BAR holds an OFFSET into that aperture.
/// EDK2 on virt leaves the I/O BAR unprogrammed (reads back 0x1: I/O indicator,
/// zero address), so we assign it ourselves: program BAR0 with an offset, then
/// access the registers at `io_aperture_cpu_base + offset`, mapped Device-nGnRE.
/// (BAR1 is a 4 KiB memory BAR so the MSI-X table, NOT the legacy registers are used;
/// writing it takes a synchronous external abort.)
///
/// Returns null (the device is skipped) on an unexpected BAR layout.
fn resolveBar0(func: *innigkeit.pci.Function) ?u64 {
    if (builtin.cpu.arch == .x86_64) {
        const bar0 = func.read(u32, 0x10);
        if (bar0 & 1 == 0) {
            log.warn("virtio-blk BAR0 is not an I/O BAR ({x}), skipping", .{bar0});
            return null;
        }
        return @as(u64, bar0 & 0xFFFC);
    }

    // BAR0 must be an I/O-space BAR (bit 0 = 1).
    const bar0 = func.read(u32, 0x10);
    if (bar0 & 1 == 0) {
        log.warn("virtio-blk BAR0 is not an I/O BAR ({x}), skipping", .{bar0});
        return null;
    }

    // Find the PCI I/O aperture's CPU physical base from the device tree, with
    // a QEMU-virt fallback. The I/O BAR value is an offset into this aperture.
    const io_window = innigkeit.init.devicetree.pciIoWindow();
    const aperture_base: u64 = if (io_window) |w| w.cpu_base else VIRT_PCI_IO_FALLBACK_BASE;
    const aperture_size: u64 = if (io_window) |w| w.size else 0x1_0000;
    if (io_window == null) {
        log.warn("virtio-blk: no DTB I/O range; using QEMU-virt default 0x{x}", .{aperture_base});
    }

    // The I/O BAR's currently-programmed offset (bits above the type bits).
    // Firmware leaves it 0 on virt, so assign a small offset within the
    // aperture. The legacy register block is tiny (< 0x40 bytes); pick 0.
    var io_offset: u64 = @as(u64, bar0 & 0xFFFF_FFFC);
    if (io_offset == 0) {
        io_offset = 0;
        // Assign the BAR: low two bits are the I/O-space indicator (01). The
        // device decodes I/O accesses at this offset within the aperture once
        // I/O-space decode is enabled (PCI command bit 0, set in tryInit).
        func.write(u32, 0x10, @as(u32, @intCast(io_offset)) | 1);
        log.debug("virtio-blk: assigned I/O BAR0 offset=0x{x}", .{io_offset});
    }

    if (io_offset + 0x1000 > aperture_size) {
        log.warn("virtio-blk: I/O offset 0x{x} outside aperture (size 0x{x}), skipping", .{ io_offset, aperture_size });
        return null;
    }

    const phys_base: u64 = aperture_base + io_offset;

    // Map one page Device-nGnRE (`.uncached` -> Device-nGnRE on aarch64). The
    // legacy register block (offsets 0x00..0x14) plus block config fits well
    // within a page.
    const mapping = innigkeit.mem.heap.allocateSpecial(.{
        .physical_range = .from(.from(phys_base), .from(4096, .byte)),
        .protection = .{ .read = true, .write = true },
        .cache = .uncached,
    }) catch |err| {
        log.err("virtio-blk: failed to map I/O aperture phys=0x{x}: {t}", .{ phys_base, err });
        return null;
    };
    log.debug("virtio-blk: I/O regs phys=0x{x} mapped at 0x{x}", .{ phys_base, mapping.address.value });
    return mapping.address.value;
}

fn tryInit(addr: innigkeit.pci.Address, func: *innigkeit.pci.Function) void {
    if (device_count >= MAX_DEVICES) return;

    const vendor = func.read(u16, 0x00);
    const device = func.read(u16, 0x02);
    if (vendor != VIRTIO_VENDOR_ID or device != VIRTIO_BLK_DEVICE_ID) return;

    // Enable I/O space, memory space, and bus-mastering. Bit 0 (I/O space) and
    // bit 1 (memory space) are both set so the same path works whether BAR0 is
    // an I/O BAR (x86-64) or a memory BAR (aarch64 / QEMU virt); bit 2 is
    // bus-mastering (the device DMAs the vring/buffers).
    const cmd = func.read(u16, 0x04);
    func.write(u16, 0x04, cmd | 0x07);

    const io_base: u64 = resolveBar0(func) orelse return;
    log.debug("virtio-blk[{}] found: register base=0x{x}", .{ device_count, io_base });

    var dev: Device = .{
        .io = .{ .base = io_base },
        .capacity_sectors = 0,
        .queue = undefined,
        .req_page = undefined,
        .scratch_page = undefined,
    };

    dev.iow8(legacy.REG_DEVICE_STATUS, 0);
    dev.iow8(legacy.REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE);
    dev.iow8(legacy.REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    const dev_features = dev.ior32(legacy.REG_DEVICE_FEATURES);
    dev.iow32(legacy.REG_DRIVER_FEATURES, dev_features);

    const cap_lo = dev.ior32(REG_CONFIG_CAPACITY_LO);
    const cap_hi = dev.ior32(REG_CONFIG_CAPACITY_HI);
    dev.capacity_sectors = (@as(u64, cap_hi) << 32) | cap_lo;
    log.info("virtio-blk[{}] capacity: {} sectors ({} MiB)", .{
        device_count,
        dev.capacity_sectors,
        dev.capacity_sectors / 2048,
    });

    dev.queue = legacy.LegacyQueue.setup(dev.io, 0) orelse {
        log.err("virtio-blk[{}]: queue setup failed", .{device_count});
        return;
    };

    // Pre-allocate the bounce buffers used on every I/O request. Requests
    // are serialized by `request_mutex`, so these pages can be reused across
    // operations, eliminating per-request allocation.
    dev.req_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        log.err("virtio-blk[{}]: OOM allocating req_page", .{device_count});
        dev.iow8(legacy.REG_DEVICE_STATUS, 0);
        dev.queue.destroy();
        return;
    };
    dev.scratch_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        list.prepend(dev.req_page);
        innigkeit.mem.PhysicalPage.allocator.deallocate(list);
        log.err("virtio-blk[{}]: OOM allocating scratch_page", .{device_count});
        dev.iow8(legacy.REG_DEVICE_STATUS, 0);
        dev.queue.destroy();
        return;
    };

    dev.iow8(legacy.REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

    // Publish the device slot *before* routing the interrupt so the handler
    // can always reach the ISR register (level-triggered: not reading the
    // ISR would leave the line asserted). No request is in flight yet, so
    // no interrupt can be raised before the first submitRequest.
    const idx = device_count;
    devices[idx] = dev;
    device_count += 1;

    const handler: architecture.interrupts.Interrupt.Handler = .{
        .eoi = .level,
        .call = .prepare(onInterrupt, .{idx}),
    };
    devices[idx].?.irq_enabled = legacy.setupIrq(addr, func, handler, "virtio-blk");

    // aarch64 (M2): the PCI INTx line routes to a GIC SPI (logged by setupIrq),
    // but completions are not yet observed to be delivered. The QEMU-virt PCIe
    // INTx->SPI swizzle must be taken from the DTB `interrupt-map` to pick the
    // exact SPI, which is not yet parsed (we use a computed swizzle + the I/O
    // aperture fallback). Until INTx delivery is verified, use poll mode so a
    // non-firing IRQ cannot hang a disk read forever. virtio-blk completions
    // are fast under QEMU, so the bounded-spin poll path is correct and cheap.
    // The interrupt-driven-completion test (below) skips while this is false.
    // x86-64 keeps interrupt-driven completion. See docs/aarch64-port.md.
    if (builtin.cpu.arch != .x86_64) devices[idx].?.irq_enabled = false;

    log.info("virtio-blk[{}] ready ({s} mode)", .{
        idx,
        if (devices[idx].?.irq_enabled) "irq" else "poll",
    });
}

pub const ReadError = error{ NotInitialized, OutOfRange, DeviceError };
pub const WriteError = error{ NotInitialized, OutOfRange, DeviceError };

const BLK_T_OUT: u32 = 1; // write request type

/// Submit a single virtio-blk request and wait for completion: blocking on
/// the INTx interrupt when it is routed, bounded-spin polling otherwise.
///
/// `req_type`: BLK_T_IN (read) or BLK_T_OUT (write).
/// `data_flags`: VRING_DESC_F_WRITE for reads (device writes data), 0 for writes.
/// The caller fills `scratch_virt` with data before calling (writes) or reads it
/// after (reads), and must hold `dev.request_mutex` across the whole request
/// including those copies. Returns error on timeout or non-zero device status.
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

    const descs = dev.queue.descTable();
    descs[0] = .{ .addr = req_phys, .len = @sizeOf(BlkReqHeader), .flags = VRING_DESC_F_NEXT, .next = 1 };
    descs[1] = .{ .addr = scratch_phys, .len = @as(u32, count) * 512, .flags = data_flags | VRING_DESC_F_NEXT, .next = 2 };
    descs[2] = .{ .addr = req_phys + @sizeOf(BlkReqHeader), .len = 1, .flags = VRING_DESC_F_WRITE, .next = 0 };

    dev.queue.publish(0);
    dev.queue.notify();

    if (dev.irq_enabled) {
        // Block until the IRQ handler signals a used-ring update. The device
        // may have completed before we first take the lock, so the condition
        // is always re-checked under the lock before (re-)waiting; `wait`
        // returns with the lock released.
        dev.completion_lock.lock();
        while (dev.queue.popUsed() == null) {
            dev.completion_queue.wait(&dev.completion_lock);
            dev.completion_lock.lock();
        }
        dev.completion_lock.unlock();
    } else {
        _ = dev.queue.waitUsed(1_000_000) orelse {
            log.err("virtio-blk[{}]: timeout waiting for used ring", .{dev_idx});
            return error.DeviceError;
        };
    }

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

    dev.request_mutex.lock();
    defer dev.request_mutex.unlock();

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

    dev.request_mutex.lock();
    defer dev.request_mutex.unlock();

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

test "virtio-blk: readSectors is stable across repeated reads" {
    if (!isBootReady()) return error.SkipZigTest;

    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    try readSectors(0, 0, &a, 1);
    try readSectors(0, 0, &b, 1);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "virtio-blk: unaligned readBytes matches readSectors" {
    if (!isBootReady()) return error.SkipZigTest;

    var ref: [1024]u8 = undefined;
    try readSectors(0, 0, &ref, 2);

    // Byte range straddling the sector-0/sector-1 boundary, unaligned start.
    var got: [100]u8 = undefined;
    try readBytes(0, 500, &got);
    try std.testing.expectEqualSlices(u8, ref[500..][0..100], &got);
}

test "virtio-blk: completion is interrupt-driven when INTx is routed" {
    if (!isBootReady()) return error.SkipZigTest;
    const dev: *const Device = &devices[0].?;
    if (!dev.irq_enabled) return error.SkipZigTest;

    const before = irqFireCount(0);
    var buf: [512]u8 = undefined;
    try readSectors(0, 0, &buf, 1);
    // The blocking completion path can only have been woken by the handler,
    // and the handler counts every queue interrupt it observes.
    try std.testing.expect(irqFireCount(0) > before);
}
