//! virtio-gpu 2D driver (modern PCI transport).
//!
//! Detects a VirtIO GPU device (0x1AF4:0x1050), negotiates modern virtio,
//! creates a 2D resource backed by physical pages, and connects it to
//! scanout 0. After each frame the caller should invoke flush() to copy
//! the backing store to the host display.
//!
//! The backing-store pages are regular physical RAM (CPU-coherent).
//! Map them write-combining into userspace via the framebuffer_map path.
//!
//! All GPU commands are synchronous (we poll the used ring until the
//! response arrives). This is fine because the driver is single-threaded
//! during init, and the only runtime call is flush() which is cheap.

const std = @import("std");
const innigkeit = @import("innigkeit");
const architecture = @import("architecture");
const core = @import("core");

const log = innigkeit.debug.log.scoped(.virtio_gpu);

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const GPU_DEVICE_ID: u16 = 0x1050;

const VCAP_VNDR: u8 = 0x09; // virtio PCI capability vendor id
const VCAP_COMMON: u8 = 1;
const VCAP_NOTIFY: u8 = 2;

const VSTAT_ACKNOWLEDGE: u8 = 0x01;
const VSTAT_DRIVER: u8 = 0x02;
const VSTAT_DRIVER_OK: u8 = 0x04;
const VSTAT_FEATURES_OK: u8 = 0x08;
const VSTAT_FAILED: u8 = 0x80;

const VIRTIO_F_VERSION_1: u64 = 1 << 32;

const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;

const RESP_OK_NODATA: u32 = 0x1100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;

const FMT_B8G8R8X8: u32 = 1;
const RESOURCE_ID: u32 = 1;
const SCANOUT_ID: u32 = 0;

const QSIZE: usize = 16; // must be power of 2

// Byte offsets within the queue page:
const OFF_DESC: usize = 0; // 16*16=256 bytes
const OFF_AVAIL: usize = 256; // avail ring (2-byte aligned)
const OFF_USED: usize = 512; // used ring (4-byte aligned)
const OFF_CMD: usize = 768; // command / request buffer
const OFF_RESP: usize = 1280; // response buffer
// Total used: 1280+256 = 1536 bytes < 4096.

const PAGE_SIZE: usize = 4096;

// Maximum supported framebuffer (enough for 1920x1080).
const MAX_FB_PAGES: usize = (1920 * 1080 * 4 + PAGE_SIZE - 1) / PAGE_SIZE; // 2026

const GpuRect = extern struct { x: u32, y: u32, w: u32, h: u32 };

const GpuCtrlHdr = extern struct {
    type_: u32,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    ring_idx: u8 = 0,
    _pad: [3]u8 = .{0} ** 3,
};
comptime {
    std.debug.assert(@sizeOf(GpuCtrlHdr) == 24);
}

const GpuDisplayOne = extern struct {
    r: GpuRect,
    enabled: u32,
    flags: u32,
};
const GpuRespDisplayInfo = extern struct {
    hdr: GpuCtrlHdr,
    modes: [16]GpuDisplayOne,
};
comptime {
    std.debug.assert(@sizeOf(GpuRespDisplayInfo) == 24 + 16 * 24);
}

const GpuResourceCreate2d = extern struct {
    hdr: GpuCtrlHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};
comptime {
    std.debug.assert(@sizeOf(GpuResourceCreate2d) == 40);
}

const GpuResourceAttachBacking = extern struct {
    hdr: GpuCtrlHdr,
    resource_id: u32,
    nr_entries: u32,
};
comptime {
    std.debug.assert(@sizeOf(GpuResourceAttachBacking) == 32);
}

const GpuMemEntry = extern struct {
    addr: u64,
    length: u32,
    _pad: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(GpuMemEntry) == 16);
}

const GpuSetScanout = extern struct {
    hdr: GpuCtrlHdr,
    r: GpuRect,
    scanout_id: u32,
    resource_id: u32,
};
comptime {
    std.debug.assert(@sizeOf(GpuSetScanout) == 48);
}

const GpuTransferToHost2d = extern struct {
    hdr: GpuCtrlHdr,
    r: GpuRect,
    offset: u64,
    resource_id: u32,
    _pad: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(GpuTransferToHost2d) == 56);
}

const GpuResourceFlush = extern struct {
    hdr: GpuCtrlHdr,
    r: GpuRect,
    resource_id: u32,
    _pad: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(GpuResourceFlush) == 48);
}

pub const GpuState = struct {
    cfg_va: usize, // virtual address of common_cfg MMIO region
    notify_va: usize, // virtual address of notify register
    queue_page: innigkeit.mem.PhysicalPage.Index,
    avail_idx: u16,
    used_last: u16,
    fb_width: u32,
    fb_height: u32,
    fb_pages: []innigkeit.mem.PhysicalPage.Index,
    // Physical pages backing the RESOURCE_ATTACH_BACKING mem-entries array.
    // Heap memory is outside the direct map so we can't derive DMA addresses
    // from heap pointers; physical pages are always in the direct map.
    entry_pages: []innigkeit.mem.PhysicalPage.Index,
};

var state_storage: GpuState = undefined;
pub var state: ?*GpuState = null;

pub fn init() void {
    innigkeit.pci.forEachFunction(tryInit);
}

fn tryInit(addr: innigkeit.pci.Address, func: *innigkeit.pci.Function) void {
    _ = addr;
    if (func.read(u16, 0x00) != VIRTIO_VENDOR_ID) return;
    if (func.read(u16, 0x02) != GPU_DEVICE_ID) return;

    log.debug("virtio-gpu found", .{});

    // Enable memory space and bus-mastering.
    const cmd = func.read(u16, 0x04);
    func.write(u16, 0x04, cmd | 0x06);

    // Walk PCI capability list to find common_cfg and notify.
    var common_bar: u8 = 0xff;
    var common_off: u32 = 0;
    var common_len: u32 = 0;
    var notify_bar: u8 = 0xff;
    var notify_off: u32 = 0;
    var notify_mult: u32 = 0;

    const status = func.read(u16, 0x06);
    if (status & 0x10 == 0) {
        log.err("virtio-gpu: no capability list", .{});
        return;
    }
    var cap: usize = func.read(u8, 0x34);
    while (cap != 0 and cap < 0xFF) {
        const vndr = func.read(u8, cap);
        const next = func.read(u8, cap + 1);
        if (vndr == VCAP_VNDR) {
            const cfg_type = func.read(u8, cap + 3);
            const bar = func.read(u8, cap + 4);
            const off = func.read(u32, cap + 8);
            const len = func.read(u32, cap + 12);
            switch (cfg_type) {
                VCAP_COMMON => {
                    common_bar = bar;
                    common_off = off;
                    common_len = len;
                },
                VCAP_NOTIFY => {
                    notify_bar = bar;
                    notify_off = off;
                    notify_mult = func.read(u32, cap + 16);
                },
                else => {},
            }
        }
        cap = next;
    }

    if (common_bar == 0xff or notify_bar == 0xff) {
        log.err("virtio-gpu: capabilities not found", .{});
        return;
    }

    // Map common_cfg BAR region as uncached MMIO.
    const cfg_phys = barPhysAddr(func, common_bar) orelse {
        log.err("virtio-gpu: could not read common_cfg BAR", .{});
        return;
    };
    const cfg_page_base = common_off & ~@as(u32, PAGE_SIZE - 1);
    const cfg_map_size = core.Size.from(
        std.mem.alignForward(usize, common_off + common_len - cfg_page_base, PAGE_SIZE),
        .byte,
    );
    const cfg_range = innigkeit.mem.heap.allocateSpecial(.{
        .physical_range = .from(innigkeit.PhysicalAddress.from(cfg_phys + cfg_page_base), cfg_map_size),
        .protection = .{ .read = true, .write = true },
        .cache = .uncached,
    }) catch |err| {
        log.err("virtio-gpu: failed to map common_cfg: {t}", .{err});
        return;
    };
    const cfg_va = cfg_range.address.value + (common_off - cfg_page_base);

    // Map notify BAR region.
    const notify_phys = barPhysAddr(func, notify_bar) orelse {
        log.err("virtio-gpu: could not read notify BAR", .{});
        return;
    };
    const notify_page_base = notify_off & ~@as(u32, PAGE_SIZE - 1);
    const notify_range = innigkeit.mem.heap.allocateSpecial(.{
        .physical_range = .from(
            innigkeit.PhysicalAddress.from(notify_phys + notify_page_base),
            core.Size.from(PAGE_SIZE, .byte),
        ),
        .protection = .{ .read = true, .write = true },
        .cache = .uncached,
    }) catch |err| {
        log.err("virtio-gpu: failed to map notify BAR: {t}", .{err});
        return;
    };
    const notify_va = notify_range.address.value + (notify_off - notify_page_base);

    // Allocate the virtqueue page.
    const queue_page = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
        log.err("virtio-gpu: out of memory for queue page", .{});
        return;
    };
    const qp_virt = queue_page.baseAddress().toDirectMap().value;
    const qp_phys = queue_page.baseAddress().value;

    // Zero the queue page.
    @memset(@as([*]u8, @ptrFromInt(qp_virt))[0..PAGE_SIZE], 0);

    // Initialize virtio device.
    if (!virtioInit(cfg_va, qp_phys, notify_va, notify_mult)) {
        log.err("virtio-gpu: virtio init failed", .{});
        return;
    }

    // Compute queue_notify_off for queue 0.
    mmioW16(cfg_va + 22, 0); // queue_select = 0
    const qnotify_off: u32 = mmioR16(cfg_va + 30);
    const queue_notify_addr = notify_va + qnotify_off * notify_mult;

    // Populate driver state skeleton.
    state_storage = .{
        .cfg_va = cfg_va,
        .notify_va = queue_notify_addr,
        .queue_page = queue_page,
        .avail_idx = 0,
        .used_last = 0,
        .fb_width = 0,
        .fb_height = 0,
        .fb_pages = &.{},
        .entry_pages = &.{},
    };

    // GET_DISPLAY_INFO to learn display dimensions.
    var s = &state_storage;
    getDisplayInfo(s) catch |err| {
        log.warn("virtio-gpu: GET_DISPLAY_INFO failed: {t} defaulting to 1024x768", .{err});
        s.fb_width = 1024;
        s.fb_height = 768;
    };
    log.info("virtio-gpu: display {}x{}", .{ s.fb_width, s.fb_height });

    // Allocate backing-store physical pages.
    const fb_bytes: usize = @as(usize, s.fb_width) * @as(usize, s.fb_height) * 4;
    const fb_page_count = (fb_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    const fb_pages = innigkeit.mem.heap.allocator.alloc(
        innigkeit.mem.PhysicalPage.Index,
        fb_page_count,
    ) catch {
        log.err("virtio-gpu: could not alloc fb_pages slice", .{});
        return;
    };

    for (fb_pages, 0..) |*slot, i| {
        slot.* = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
            log.err("virtio-gpu: out of pages at fb page {}", .{i});
            return; // leak earlier pages: init failure is non-recoverable
        };
        // Zero the page.
        const va = slot.*.baseAddress().toDirectMap().value;
        @memset(@as([*]u8, @ptrFromInt(va))[0..PAGE_SIZE], 0);
    }
    s.fb_pages = fb_pages;

    // Allocate physical pages for RESOURCE_ATTACH_BACKING mem entries.
    // Heap memory is outside the HHDM so we can't use fromDirectMap on heap
    // pointers. Physical pages are always in the direct map.
    const entry_bytes = fb_page_count * @sizeOf(GpuMemEntry);
    const ep_count = (entry_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    const entry_page_idxs = innigkeit.mem.heap.allocator.alloc(
        innigkeit.mem.PhysicalPage.Index,
        ep_count,
    ) catch {
        log.err("virtio-gpu: could not alloc entry_page_idxs", .{});
        return;
    };
    for (entry_page_idxs, 0..) |*slot, i| {
        slot.* = innigkeit.mem.PhysicalPage.allocator.allocate() catch {
            log.err("virtio-gpu: out of pages for entry page {}", .{i});
            return;
        };
    }
    s.entry_pages = entry_page_idxs;

    // RESOURCE_CREATE_2D.
    sendResourceCreate2d(s) catch |err| {
        log.err("virtio-gpu: RESOURCE_CREATE_2D failed: {t}", .{err});
        return;
    };

    // RESOURCE_ATTACH_BACKING.
    sendResourceAttachBacking(s) catch |err| {
        log.err("virtio-gpu: RESOURCE_ATTACH_BACKING failed: {t}", .{err});
        return;
    };

    // SET_SCANOUT.
    sendSetScanout(s) catch |err| {
        log.err("virtio-gpu: SET_SCANOUT failed: {t}", .{err});
        return;
    };

    state = s;

    // Initial flush so the display shows black instead of garbage.
    flush(s.fb_width, s.fb_height) catch {};

    log.info("virtio-gpu ready: {}x{} ({} pages)", .{ s.fb_width, s.fb_height, fb_page_count });
}

/// Copy the entire backing store to the host and flush scanout 0.
pub fn flush(w: u32, h: u32) error{NoGpu}!void {
    const s = state orelse return error.NoGpu;

    // Drain write-combining stores from userspace before the device DMA-reads
    // the framebuffer. SYSCALL does not flush WC fill buffers; without this
    // sfence the device may read stale zeroes.
    asm volatile ("sfence" ::: .{ .memory = true });

    const qp_virt = s.queue_page.baseAddress().toDirectMap().value;
    const qp_phys = s.queue_page.baseAddress().value;
    const rect: GpuRect = .{ .x = 0, .y = 0, .w = w, .h = h };

    // TRANSFER_TO_HOST_2D
    const xfer = buildCmd(GpuTransferToHost2d, .{
        .hdr = .{ .type_ = CMD_TRANSFER_TO_HOST_2D },
        .r = rect,
        .offset = 0,
        .resource_id = RESOURCE_ID,
    }, qp_virt);
    const resp_xfer = submitCmd(s, qp_virt, qp_phys, @sizeOf(GpuTransferToHost2d), xfer, @sizeOf(GpuCtrlHdr)) catch return;
    if (resp_xfer != RESP_OK_NODATA)
        log.warn("virtio-gpu: TRANSFER response {x}", .{resp_xfer});

    // RESOURCE_FLUSH
    const flush_cmd = buildCmd(GpuResourceFlush, .{
        .hdr = .{ .type_ = CMD_RESOURCE_FLUSH },
        .r = rect,
        .resource_id = RESOURCE_ID,
    }, qp_virt);
    const resp_flush = submitCmd(s, qp_virt, qp_phys, @sizeOf(GpuResourceFlush), flush_cmd, @sizeOf(GpuCtrlHdr)) catch return;
    if (resp_flush != RESP_OK_NODATA)
        log.warn("virtio-gpu: FLUSH response {x}", .{resp_flush});
}

/// Virtio 1.x device initialisation sequence for the controlq.
fn virtioInit(cfg_va: usize, qp_phys: usize, notify_va: usize, notify_mult: u32) bool {
    _ = notify_mult;
    _ = notify_va;

    // Reset device.
    mmioW8(cfg_va + 20, 0);

    // ACKNOWLEDGE + DRIVER.
    mmioW8(cfg_va + 20, VSTAT_ACKNOWLEDGE | VSTAT_DRIVER);

    // Feature negotiation: accept only VERSION_1.
    mmioW32(cfg_va + 8, 1); // driver_feature_select = 1 (high 32 bits)
    mmioW32(cfg_va + 12, @truncate(VIRTIO_F_VERSION_1 >> 32));
    mmioW32(cfg_va + 8, 0); // driver_feature_select = 0 (low 32 bits)
    mmioW32(cfg_va + 12, @truncate(VIRTIO_F_VERSION_1 & 0xFFFF_FFFF));

    mmioW8(cfg_va + 20, VSTAT_ACKNOWLEDGE | VSTAT_DRIVER | VSTAT_FEATURES_OK);
    const status = mmioR8(cfg_va + 20);
    if (status & VSTAT_FEATURES_OK == 0) {
        log.err("virtio-gpu: FEATURES_OK not set (status={x})", .{status});
        return false;
    }

    // Set up queue 0 (controlq).
    mmioW16(cfg_va + 22, 0); // queue_select = 0
    mmioW16(cfg_va + 24, QSIZE); // queue_size
    mmioW16(cfg_va + 26, 0xFFFF); // queue_msix_vector = NO_VECTOR

    // Physical addresses of desc table, avail ring, used ring.
    mmioW64(cfg_va + 32, qp_phys + OFF_DESC);
    mmioW64(cfg_va + 40, qp_phys + OFF_AVAIL);
    mmioW64(cfg_va + 48, qp_phys + OFF_USED);
    mmioW16(cfg_va + 28, 1); // queue_enable = 1

    // DRIVER_OK.
    mmioW8(cfg_va + 20, VSTAT_ACKNOWLEDGE | VSTAT_DRIVER | VSTAT_FEATURES_OK | VSTAT_DRIVER_OK);

    return true;
}

fn getDisplayInfo(s: *GpuState) !void {
    const qp_virt = s.queue_page.baseAddress().toDirectMap().value;
    const qp_phys = s.queue_page.baseAddress().value;

    _ = buildCmd(GpuCtrlHdr, .{ .type_ = CMD_GET_DISPLAY_INFO }, qp_virt);
    const resp_type = try submitCmd(s, qp_virt, qp_phys, @sizeOf(GpuCtrlHdr), OFF_CMD, @sizeOf(GpuRespDisplayInfo));
    if (resp_type != RESP_OK_DISPLAY_INFO) return error.BadResponse;

    const resp = @as(*align(1) const GpuRespDisplayInfo, @ptrFromInt(qp_virt + OFF_RESP)).*;
    for (&resp.modes) |mode| {
        if (mode.enabled != 0 and mode.r.w > 0 and mode.r.h > 0) {
            s.fb_width = mode.r.w;
            s.fb_height = mode.r.h;
            return;
        }
    }
    // No enabled mode found.
    s.fb_width = 1024;
    s.fb_height = 768;
}

fn sendResourceCreate2d(s: *GpuState) !void {
    const qp_virt = s.queue_page.baseAddress().toDirectMap().value;
    const qp_phys = s.queue_page.baseAddress().value;
    const cmd_off = buildCmd(GpuResourceCreate2d, .{
        .hdr = .{ .type_ = CMD_RESOURCE_CREATE_2D },
        .resource_id = RESOURCE_ID,
        .format = FMT_B8G8R8X8,
        .width = s.fb_width,
        .height = s.fb_height,
    }, qp_virt);
    const r = try submitCmd(s, qp_virt, qp_phys, @sizeOf(GpuResourceCreate2d), cmd_off, @sizeOf(GpuCtrlHdr));
    if (r != RESP_OK_NODATA) return error.BadResponse;
}

fn sendResourceAttachBacking(s: *GpuState) !void {
    const qp_virt = s.queue_page.baseAddress().toDirectMap().value;
    const qp_phys = s.queue_page.baseAddress().value;

    const n = s.fb_pages.len;
    const ep_count = s.entry_pages.len;
    const entries_per_page: usize = PAGE_SIZE / @sizeOf(GpuMemEntry); // 256

    if (ep_count + 2 > QSIZE) return error.TooLarge;

    // Header descriptor (desc 0).
    @as(*align(1) GpuResourceAttachBacking, @ptrFromInt(qp_virt + OFF_CMD)).* = .{
        .hdr = .{ .type_ = CMD_RESOURCE_ATTACH_BACKING },
        .resource_id = RESOURCE_ID,
        .nr_entries = @intCast(n),
    };

    setDesc(qp_virt, 0, qp_phys + OFF_CMD, @sizeOf(GpuResourceAttachBacking), VRING_DESC_F_NEXT, 1);

    // One pass: write mem entries into physical pages AND build their descriptors.
    //
    // j is a monotone fb_page index in [0, n]. next_j = @min(j + entries_per_page, n)
    // guarantees next_j >= j, so count = next_j - j is always >= 0, no subtraction
    // underflow is possible regardless of how ep_count was computed.
    var j: usize = 0;
    for (0..ep_count) |i| {
        const ep = s.entry_pages[i];
        const page_va = ep.baseAddress().toDirectMap().value;
        const next_j = @min(j + entries_per_page, n);
        const count = next_j - j; // always in [0, entries_per_page]
        for (0..count) |k| {
            @as(*align(1) GpuMemEntry, @ptrFromInt(page_va + k * @sizeOf(GpuMemEntry))).* = .{
                .addr = s.fb_pages[j + k].baseAddress().value,
                .length = PAGE_SIZE,
            };
        }
        setDesc(qp_virt, i + 1, ep.baseAddress().value, count * @sizeOf(GpuMemEntry), VRING_DESC_F_NEXT, @intCast(i + 2));
        j = next_j;
    }

    // Response descriptor (desc ep_count+1).
    setDesc(qp_virt, ep_count + 1, qp_phys + OFF_RESP, @sizeOf(GpuCtrlHdr), VRING_DESC_F_WRITE, 0);

    const r = try submitDescChain(s, qp_virt, 0);
    if (r != RESP_OK_NODATA) return error.BadResponse;
}

fn sendSetScanout(s: *GpuState) !void {
    const qp_virt = s.queue_page.baseAddress().toDirectMap().value;
    const qp_phys = s.queue_page.baseAddress().value;
    const cmd_off = buildCmd(GpuSetScanout, .{
        .hdr = .{ .type_ = CMD_SET_SCANOUT },
        .r = .{ .x = 0, .y = 0, .w = s.fb_width, .h = s.fb_height },
        .scanout_id = SCANOUT_ID,
        .resource_id = RESOURCE_ID,
    }, qp_virt);
    const r = try submitCmd(s, qp_virt, qp_phys, @sizeOf(GpuSetScanout), cmd_off, @sizeOf(GpuCtrlHdr));
    if (r != RESP_OK_NODATA) return error.BadResponse;
}

/// Write a command struct into the cmd buffer, return the buffer offset used.
fn buildCmd(comptime T: type, val: T, qp_virt: usize) usize {
    @as(*align(1) T, @ptrFromInt(qp_virt + OFF_CMD)).* = val;
    return OFF_CMD;
}

/// Submit a two-descriptor chain (cmd|response) and return the response type.
/// resp_size must be at least @sizeOf(GpuCtrlHdr); use @sizeOf(GpuRespDisplayInfo)
/// for GET_DISPLAY_INFO which returns a 408-byte payload.
fn submitCmd(s: *GpuState, qp_virt: usize, qp_phys: usize, cmd_size: usize, cmd_off: usize, resp_size: usize) !u32 {
    setDesc(qp_virt, 0, qp_phys + cmd_off, cmd_size, VRING_DESC_F_NEXT, 1);
    setDesc(qp_virt, 1, qp_phys + OFF_RESP, resp_size, VRING_DESC_F_WRITE, 0);
    // Zero response buffer so we can detect non-writes.
    @as(*align(1) GpuCtrlHdr, @ptrFromInt(qp_virt + OFF_RESP)).type_ = 0;
    return submitDescChain(s, qp_virt, 0);
}

/// Place desc_head in the available ring, notify the device, and poll used.
fn submitDescChain(s: *GpuState, qp_virt: usize, desc_head: u16) !u32 {
    // Memory barrier: ensure descriptor writes are visible before avail ring.
    asm volatile ("mfence" ::: .{ .memory = true });

    // Write to available ring: ring[avail_idx % QSIZE] = desc_head.
    const avail_base = qp_virt + OFF_AVAIL;
    const slot: usize = s.avail_idx % QSIZE;
    mmioW16(avail_base + 4 + slot * 2, desc_head);

    // Advance avail_idx and write it back.
    s.avail_idx +%= 1;
    asm volatile ("mfence" ::: .{ .memory = true });
    mmioW16(avail_base + 2, s.avail_idx);
    asm volatile ("mfence" ::: .{ .memory = true });

    // Notify the device (write queue index 0 to the notify register).
    mmioW32(s.notify_va, 0);

    // Poll used ring until device writes a response.
    const used_base = qp_virt + OFF_USED;
    var timeout: usize = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        asm volatile ("mfence" ::: .{ .memory = true });
        const used_idx = mmioR16(used_base + 2);
        if (used_idx != s.used_last) {
            s.used_last = used_idx;
            break;
        }
        architecture.spinLoopHint();
    }
    if (timeout == 0) return error.Timeout;

    // Read response type from the response buffer.
    return @as(*align(1) const GpuCtrlHdr, @ptrFromInt(qp_virt + OFF_RESP)).type_;
}

/// Set a virtqueue descriptor at index i.
fn setDesc(qp_virt: usize, i: usize, phys: usize, len: usize, flags: u16, next: u16) void {
    const base = qp_virt + OFF_DESC + i * 16;
    mmioW64(base + 0, phys);
    mmioW32(base + 8, @intCast(len));
    mmioW16(base + 12, flags);
    mmioW16(base + 14, next);
}

fn barPhysAddr(func: *innigkeit.pci.Function, bar_idx: u8) ?usize {
    const bar_off: usize = 0x10 + @as(usize, bar_idx) * 4;
    const lo = func.read(u32, bar_off);
    if (lo & 1 != 0) return null; // I/O BAR, not memory
    const bar_type = (lo >> 1) & 0x03;
    if (bar_type == 2) { // 64-bit
        const hi = func.read(u32, bar_off + 4);
        return (@as(usize, hi) << 32) | (lo & 0xFFFFFFF0);
    }
    return lo & 0xFFFFFFF0;
}

inline fn mmioR8(addr: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}
inline fn mmioR16(addr: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(addr)).*;
}
inline fn mmioR32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
inline fn mmioW8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}
inline fn mmioW16(addr: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = v;
}
inline fn mmioW32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
inline fn mmioW64(addr: usize, v: usize) void {
    @as(*volatile u64, @ptrFromInt(addr)).* = @intCast(v);
}
