//! Shared support for the legacy virtio-pci transport (disable-modern=on).
//!
//! In legacy virtio the driver does NOT tell the device where each ring part
//! lives. It writes a single page-aligned PFN to `REG_QUEUE_PFN` and the
//! device derives the entire vring layout from that base address and the
//! DEVICE-reported queue size N (`REG_QUEUE_SIZE` is read-only in QEMU's
//! legacy transport; writes to it are silently ignored).
//!
//! Layout the device assumes, for queue size N (virtio 0.9.5 / "legacy
//! interfaces" appendix of virtio 1.x, with VIRTIO_F_EVENT_IDX space always
//! reserved):
//!
//! ```
//! offset 0:                          descriptor table: N * 16 bytes
//! offset N*16:                       avail ring: flags u16, idx u16,
//!                                    ring [N]u16, used_event u16
//!                                    => 6 + 2*N bytes
//! offset alignUp(N*16 + 6 + 2*N,
//!                4096):              used ring: flags u16, idx u16,
//!                                    ring [N]{id u32, len u32}, avail_event u16
//!                                    => 6 + 8*N bytes
//! ```
//!
//! For N = 256 that is: descriptors 0..4096, avail 4096..4614, used at the
//! next page boundary 8192..10246, so there are exactly 3 physically CONTIGUOUS pages.
//! Because the device computes every offset from the single PFN, the pages
//! backing the ring must be physically contiguous; three independent page
//! allocations are not acceptable.
//!
//! All ring indices (`avail.idx % N`, `used.idx % N`) use the device's N as
//! the modulus. A driver must never index the rings with a smaller queue
//! size of its own choosing; after the first wrap the driver and device
//! would disagree about which slot is current.

const std = @import("std");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const PortIo = @import("PortIo.zig");

const log = innigkeit.debug.log.scoped(.virtio_legacy);

// Legacy virtio-pci I/O BAR register map (common to all legacy devices).
// Device-specific configuration space starts at REG_DEVICE_CONFIG.
pub const REG_DEVICE_FEATURES: u16 = 0x00;
pub const REG_DRIVER_FEATURES: u16 = 0x04;
pub const REG_QUEUE_PFN: u16 = 0x08;
pub const REG_QUEUE_SIZE: u16 = 0x0C; // read-only in QEMU legacy: device max
pub const REG_QUEUE_SEL: u16 = 0x0E;
pub const REG_QUEUE_NOTIFY: u16 = 0x10;
pub const REG_DEVICE_STATUS: u16 = 0x12;
pub const REG_ISR: u16 = 0x13;
pub const REG_DEVICE_CONFIG: u16 = 0x14;

pub const STATUS_ACKNOWLEDGE: u8 = 0x01;
pub const STATUS_DRIVER: u8 = 0x02;
pub const STATUS_DRIVER_OK: u8 = 0x04;
pub const STATUS_FAILED: u8 = 0x80;

/// ISR status bit 0: a queue's used ring was updated.
pub const ISR_QUEUE: u8 = 0x01;
/// ISR status bit 1: device configuration changed.
pub const ISR_CONFIG: u8 = 0x02;

pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

pub const VringDesc = extern struct {
    addr: u64, // PHYSICAL address: the device DMAs here.
    len: u32,
    flags: u16,
    next: u16,
};

/// One entry of the used ring: descriptor-chain head id + bytes written.
pub const UsedElem = extern struct {
    id: u32,
    len: u32,
};

/// Compile-time upper bound on the device-reported queue size we accept.
pub const QUEUE_SIZE_MAX: u16 = 256;

const PAGE_SIZE: usize = 4096;

/// Byte offset of the used ring from the ring base, for queue size n.
/// The used ring starts at the first page boundary after the avail ring.
fn usedOffset(n: usize) usize {
    return std.mem.alignForward(usize, n * 16 + 6 + 2 * n, PAGE_SIZE);
}

/// Number of pages needed to back the whole vring for queue size n.
fn ringPageCount(n: usize) usize {
    return std.mem.alignForward(usize, usedOffset(n) + 6 + 8 * n, PAGE_SIZE) / PAGE_SIZE;
}

/// Worst case: N=256 -> exactly 3 pages.
pub const MAX_RING_PAGES: usize = ringPageCount(QUEUE_SIZE_MAX);

/// One legacy virtqueue: owns the contiguous ring pages and the driver-side
/// shadow indices. Completion notification is up to the driver: poll with
/// `popUsed`/`waitUsed`, or route the device's INTx line with `setupIrq` and
/// block until the handler signals a used-ring update.
pub const LegacyQueue = struct {
    io: PortIo,
    /// Queue selector (value written to REG_QUEUE_SEL / REG_QUEUE_NOTIFY).
    sel: u16,
    /// DEVICE-reported queue size N. All ring layout and `% N` indexing uses
    /// this value; the driver may use fewer descriptors but never a smaller
    /// ring modulus.
    queue_num: u16,
    /// Physically contiguous pages backing the vring, ascending PFN order.
    ring_pages: [MAX_RING_PAGES]innigkeit.mem.PhysicalPage.Index,
    ring_page_count: usize,
    /// Driver shadow of avail.idx (free-running, wraps at 65536).
    avail_idx: u16,
    /// Last used.idx value the driver has consumed (free-running).
    used_last_seen: u16,

    /// Select queue `sel`, read the device queue size, allocate and zero the
    /// contiguous ring pages, and program REG_QUEUE_PFN.
    /// Returns null (with everything freed and nothing programmed) on failure.
    pub fn setup(io: PortIo, sel: u16) ?LegacyQueue {
        io.w16(REG_QUEUE_SEL, sel);
        const queue_num = io.r16(REG_QUEUE_SIZE);
        if (queue_num == 0 or queue_num > QUEUE_SIZE_MAX) {
            log.err("queue {} size {} out of range (max {})", .{ sel, queue_num, QUEUE_SIZE_MAX });
            return null;
        }

        var q: LegacyQueue = .{
            .io = io,
            .sel = sel,
            .queue_num = queue_num,
            .ring_pages = undefined,
            .ring_page_count = ringPageCount(queue_num),
            .avail_idx = 0,
            .used_last_seen = 0,
        };

        if (!allocContiguousPages(q.ring_pages[0..q.ring_page_count])) {
            log.err("queue {}: could not find {} contiguous ring pages", .{ sel, q.ring_page_count });
            return null;
        }

        // Zero the whole ring. The pages are physically contiguous, so the
        // direct-map window over them is one contiguous virtual range.
        @memset(q.ringBase()[0 .. q.ring_page_count * PAGE_SIZE], 0);

        const ring_phys = q.ring_pages[0].baseAddress().value;
        io.w32(REG_QUEUE_PFN, @intCast(ring_phys / PAGE_SIZE));
        log.debug("queue {} at phys=0x{x} (PFN={}, N={}, {} pages)", .{
            sel, ring_phys, ring_phys / PAGE_SIZE, queue_num, q.ring_page_count,
        });
        return q;
    }

    /// Release the ring pages. The caller must have reset the device (or at
    /// least cleared REG_QUEUE_PFN) first so the device no longer DMAs here.
    pub fn destroy(q: *LegacyQueue) void {
        var list: innigkeit.mem.PhysicalPage.List = .{};
        for (q.ring_pages[0..q.ring_page_count]) |pg| list.prepend(pg);
        if (list.count > 0) innigkeit.mem.PhysicalPage.allocator.deallocate(list);
        q.ring_page_count = 0;
    }

    /// Kernel (direct-map) pointer to the start of the contiguous ring window.
    inline fn ringBase(q: *const LegacyQueue) [*]u8 {
        return q.ring_pages[0].baseAddress().toDirectMap().toPtr([*]u8);
    }

    /// Descriptor table (offset 0, N entries).
    pub inline fn descTable(q: *const LegacyQueue) [*]VringDesc {
        return @ptrCast(@alignCast(q.ringBase()));
    }

    /// avail.idx (offset N*16 + 2).
    inline fn availIdxPtr(q: *const LegacyQueue) *u16 {
        return @ptrCast(@alignCast(q.ringBase() + @as(usize, q.queue_num) * 16 + 2));
    }

    /// avail.ring[] (offset N*16 + 4, N entries of u16).
    inline fn availRing(q: *const LegacyQueue) [*]u16 {
        return @ptrCast(@alignCast(q.ringBase() + @as(usize, q.queue_num) * 16 + 4));
    }

    /// used.idx (page-aligned used offset + 2).
    inline fn usedIdxPtr(q: *const LegacyQueue) *u16 {
        return @ptrCast(@alignCast(q.ringBase() + usedOffset(q.queue_num) + 2));
    }

    /// used.ring[] (page-aligned used offset + 4, N entries of UsedElem).
    inline fn usedRing(q: *const LegacyQueue) [*]UsedElem {
        return @ptrCast(@alignCast(q.ringBase() + usedOffset(q.queue_num) + 4));
    }

    /// Publish a descriptor-chain head to the device: store it in the avail
    /// ring slot `avail_idx % N`, then release-store the incremented avail
    /// index so the device observes the descriptors and the ring entry
    /// before the new index.
    pub fn publish(q: *LegacyQueue, head: u16) void {
        const slot = q.avail_idx % q.queue_num;
        @atomicStore(u16, &q.availRing()[slot], head, .monotonic);
        @atomicStore(u16, q.availIdxPtr(), q.avail_idx +% 1, .release);
        q.avail_idx +%= 1;
    }

    /// Kick the device for this queue.
    pub fn notify(q: *const LegacyQueue) void {
        q.io.w16(REG_QUEUE_NOTIFY, q.sel);
    }

    /// True if the device has published used-ring elements the driver has
    /// not yet consumed with `popUsed`. Acquire-load pairs with the device's
    /// used-index publish.
    pub fn hasUsed(q: *const LegacyQueue) bool {
        return @atomicLoad(u16, q.usedIdxPtr(), .acquire) != q.used_last_seen;
    }

    /// Set VRING_AVAIL_F_NO_INTERRUPT on this queue's avail ring, asking the
    /// device not to raise an interrupt when it consumes buffers from this
    /// queue (advisory; the device may still interrupt).
    pub fn suppressInterrupts(q: *const LegacyQueue) void {
        const flags_ptr: *u16 = @ptrCast(@alignCast(q.ringBase() + @as(usize, q.queue_num) * 16));
        @atomicStore(u16, flags_ptr, 1, .release);
    }

    /// Consume one used-ring element if the device has published one.
    /// Acquire-loads used.idx so the element contents (and any DMA'd buffer
    /// data) are visible before they are read.
    pub fn popUsed(q: *LegacyQueue) ?UsedElem {
        const used_idx = @atomicLoad(u16, q.usedIdxPtr(), .acquire);
        if (used_idx == q.used_last_seen) return null;
        const slot = q.used_last_seen % q.queue_num;
        const elem = q.usedRing()[slot];
        q.used_last_seen +%= 1;
        return elem;
    }

    /// Bounded-spin variant of `popUsed` for synchronous poll-mode drivers:
    /// retries up to `max_spins` times before giving up with null.
    pub fn waitUsed(q: *LegacyQueue, max_spins: u32) ?UsedElem {
        var spins: u32 = max_spins;
        while (spins > 0) : (spins -= 1) {
            if (q.popUsed()) |elem| return elem;
            architecture.spinLoopHint();
        }
        return null;
    }
};

/// Read (and thereby clear) the legacy ISR status register.
///
/// Reading also de-asserts the level-triggered INTx line; an interrupt
/// handler MUST perform this read on every invocation or the line stays
/// asserted and the interrupt storms.
pub fn readIsr(io: PortIo) u8 {
    return io.r8(REG_ISR);
}

/// Resolve the GSI a function's INTx pin is routed to.
///
/// x86-64 (QEMU q35): firmware programs the PCI config "Interrupt Line"
/// register (offset 0x3c) with the GSI (16-23). Read it directly.
///
/// aarch64 (QEMU virt): there is no meaningful Interrupt Line register; the
/// devicetree `interrupt-map` wires the 4 PCIe INTx pins to GIC SPIs 3..6 via
/// the standard PCI swizzle. With SPI base 3 (GIC interrupt id base 32+3=35):
///   gic_id = 32 + 3 + ((device_slot + (pin - 1)) % 4)
/// where `pin` is 1..4 (INTA#..INTD#).
fn resolveGsi(addr: innigkeit.pci.Address, pin: u8) ?u32 {
    if (@import("builtin").cpu.arch == .x86_64) {
        return null; // caller uses interruptLine() on x86-64
    }
    const swizzle: u32 = (@as(u32, addr.device) + (@as(u32, pin) - 1)) % 4;
    return 32 + 3 + swizzle;
}

/// Set up a legacy virtio INTx interrupt for `func` at PCI `addr`.
///
/// Reads the interrupt pin from PCI config space, makes sure INTx is not
/// masked in the command register, allocates a generic interrupt for `handler`
/// (which must use `.eoi = .level` and must call `readIsr` on every
/// invocation), and routes the GSI level-sensitive/active-low (PCI INTx
/// semantics). The GSI comes from the config "Interrupt Line" register on
/// x86-64 (q35: 16-23) or from the GIC SPI swizzle on aarch64 (virt: 35-38).
///
/// Returns false (with nothing routed) if the device has no INTx pin, the GSI
/// is unusable, or routing fails; the caller should fall back to poll mode.
pub fn setupIrq(
    addr: innigkeit.pci.Address,
    func: *innigkeit.pci.Function,
    handler: architecture.interrupts.Interrupt.Handler,
    what: []const u8,
) bool {
    // Architectures without PCI interrupt routing have a null allocate slot.
    if (comptime architecture.current_functions.interrupts.routeInterruptPci == null) return false;

    const pin = func.interruptPin();
    if (pin == 0) {
        log.info("{s}: no INTx pin, staying in poll mode", .{what});
        return false;
    }

    const gsi: u32 = if (@import("builtin").cpu.arch == .x86_64) blk: {
        const line = func.interruptLine();
        if (line == 0 or line == 0xFF) {
            log.info("{s}: INTx line {} unusable, staying in poll mode", .{ what, line });
            return false;
        }
        break :blk line;
    } else resolveGsi(addr, pin) orelse {
        log.info("{s}: could not resolve INTx GSI, staying in poll mode", .{what});
        return false;
    };

    // PCI command register bit 10 (INTx disable) must be clear.
    const cmd = func.read(u16, 0x04);
    if (cmd & (1 << 10) != 0) func.write(u16, 0x04, cmd & ~@as(u16, 1 << 10));

    const vector = architecture.interrupts.Interrupt.allocate(handler) catch {
        log.warn("{s}: interrupt vector allocation failed, staying in poll mode", .{what});
        return false;
    };
    vector.routePci(gsi) catch {
        vector.deallocate();
        log.warn("{s}: routing INTx GSI {} failed, staying in poll mode", .{ what, gsi });
        return false;
    };

    log.info("{s}: INTx pin {} routed via GSI {} (level/active-low)", .{ what, pin, gsi });
    return true;
}

/// Allocate `pages.len` physically contiguous pages and store them in
/// ascending physical order (pages[0] = lowest PFN).
///
/// The free list inserts pages via prepend() in ascending PFN order, so
/// popFirst() returns pages in descending order within a contiguous region.
/// We therefore accept consecutive pages in either direction and sort at the
/// end. All non-matching pages are returned to the allocator.
fn allocContiguousPages(pages: []innigkeit.mem.PhysicalPage.Index) bool {
    std.debug.assert(pages.len > 0 and pages.len <= MAX_RING_PAGES);

    var run: [MAX_RING_PAGES]innigkeit.mem.PhysicalPage.Index = undefined;
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
                if (run_len == pages.len) {
                    @memcpy(pages, run[0..pages.len]);
                    // Sort ascending so pages[0] has the lowest PFN.
                    for (0..pages.len) |i| {
                        for (i + 1..pages.len) |j| {
                            if (@intFromEnum(pages[j]) < @intFromEnum(pages[i])) {
                                const tmp = pages[i];
                                pages[i] = pages[j];
                                pages[j] = tmp;
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

test "virtio legacy: vring layout for N=256 matches device math" {
    try std.testing.expectEqual(@as(usize, 8192), usedOffset(256));
    try std.testing.expectEqual(@as(usize, 3), ringPageCount(256));
    try std.testing.expectEqual(@as(usize, 3), MAX_RING_PAGES);
}

test "virtio legacy: vring layout for N=128 puts used ring at page boundary" {
    try std.testing.expectEqual(@as(usize, 4096), usedOffset(128));
    try std.testing.expectEqual(@as(usize, 2), ringPageCount(128));
}
