//! TPM 2.0 Command Response Buffer (CRB) transport.
//!
//! Implements the synchronous command/response transport defined by the TCG PC
//! Client Platform TPM Profile (PTP) CRB interface, selected when the ACPI TPM2
//! table reports `start_method == command_response_buffer`. This is QEMU's
//! `tpm-crb` device and the modern hardware default.
//!
//! A `Crb` value owns the memory-mapped control area and exposes a single
//! `transmit(command, response_buf) -> response` primitive; higher-level TPM
//! 2.0 commands are built on top of it in `tpm.zig`. The behaviour follows the
//! PTP CRB state machine (cross-checked against Linux `tpm_crb.c`) but the code
//! is written for Innigkeit's direct-mapped MMIO and wallclock-bounded polling.
//!
//! Layout: per locality the CRB region is `[ locality regs (0x40) | control
//! area (0x30) | command/response buffer ]`. The ACPI `address` field points at
//! the control area (`TPM_CRB_CTRL_REQ`), so the locality registers sit
//! `@sizeOf(RegsHead)` bytes below it.

const builtin = @import("builtin");
const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const acpi = innigkeit.acpi;
const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.tpm_crb);

const Crb = @This();

regs_head: *volatile RegsHead,
regs_ctrl: *volatile RegsCtrl,

/// Physical/virtual base and length of the mapped CRB region (locality head,
/// control area, and (on QEMU's tpm-crb) the command/response buffers, all
/// within one device page). Used to translate the physical buffer addresses the
/// control area reports into the kernel-virtual mapping.
region_phys: usize,
region_virt: usize,
region_size: usize,

/// Locality register block ("head"), immediately before the control area.
const RegsHead = extern struct {
    loc_state: u32, // 0x00
    _reserved0: u32, // 0x04
    loc_ctrl: u32, // 0x08
    loc_sts: u32, // 0x0C
    _reserved1: [32]u8, // 0x10
    intf_id: u64, // 0x30
    ctrl_ext: u64, // 0x38

    comptime {
        core.testing.expectSize(RegsHead, .from(0x40, .byte));
    }
};

/// Control area register block; the ACPI TPM2 `address` points here.
const RegsCtrl = extern struct {
    req: u32, // 0x00 TPM_CRB_CTRL_REQ
    sts: u32, // 0x04 TPM_CRB_CTRL_STS
    cancel: u32, // 0x08 TPM_CRB_CTRL_CANCEL
    start: u32, // 0x0C TPM_CRB_CTRL_START
    int_enable: u32, // 0x10
    int_sts: u32, // 0x14
    cmd_size: u32, // 0x18 TPM_CRB_CTRL_CMD_SIZE
    cmd_laddr: u32, // 0x1C TPM_CRB_CTRL_CMD_LADDR (low 32 bits)
    cmd_haddr: u32, // 0x20 TPM_CRB_CTRL_CMD_HADDR (high 32 bits)
    rsp_size: u32, // 0x24 TPM_CRB_CTRL_RSP_SIZE
    rsp_addr: u64, // 0x28 TPM_CRB_CTRL_RSP_ADDR

    comptime {
        core.testing.expectSize(RegsCtrl, .from(0x30, .byte));
    }
};

// Locality control (write) and state (read) bits.
const loc_ctrl_request_access: u32 = 1 << 0;
const loc_ctrl_relinquish: u32 = 1 << 1;
const loc_state_assigned: u32 = 1 << 1;
const loc_state_reg_valid: u32 = 1 << 7;

// Control-area request / status / start bits.
const ctrl_req_cmd_ready: u32 = 1 << 0;
const ctrl_req_go_idle: u32 = 1 << 1;
const ctrl_sts_error: u32 = 1 << 0;
const ctrl_start_invoke: u32 = 1 << 0;

/// PTP TIMEOUT_C: bound for locality / cmdReady / goIdle handshakes.
const handshake_timeout_ms: u64 = 200;
/// Generous upper bound for command completion. The longest command we issue
/// (TPM2_GetRandom) is specced at 2 s; double it for emulation headroom.
const command_timeout_ms: u64 = 4000;

pub const Error = error{
    Timeout,
    CommandTooLarge,
    DeviceError,
    MalformedResponse,
};

/// Probe the ACPI TPM2 table and, if it describes a usable CRB device, map its
/// control area. Returns `null` when there is no TPM, or it uses an interface
/// this transport does not implement (e.g. FIFO/TIS, or the Arm SMC/FFA CRB
/// variants, those are future work).
pub fn fromAcpi() ?Crb {
    const found = acpi.init.AcpiTable(acpi.tables.TPM2).get(0) orelse return null;
    defer found.deinit();
    const tpm2 = found.table;

    switch (tpm2.start_method) {
        .command_response_buffer,
        .command_response_buffer_with_acpi_start_method,
        => {},
        else => |method| {
            log.warn("TPM present but start method {t} is unsupported", .{method});
            return null;
        },
    }

    const control = tpm2.address;
    if (control.value == 0) {
        log.warn("TPM2 table reports a zero control-area address", .{});
        return null;
    }
    if (control.value < @sizeOf(RegsHead)) {
        log.warn("TPM2 table reports a control-area address too low for the locality head (0x{x})", .{control.value});
        return null;
    }

    // The CRB control area is device MMIO, not RAM, so it is absent from the
    // direct map, so we map it explicitly as uncached device memory (as PCI ECAM
    // does). The locality head sits `@sizeOf(RegsHead)` below the control area;
    // on QEMU's tpm-crb the whole device (head, control, cmd/rsp buffers) fits
    // in a single page.
    const head_phys = control.value - @sizeOf(RegsHead);
    const region_size = core.Size.from(region_bytes, .byte);
    const mapping = innigkeit.memory.heap.allocateSpecial(.{
        .physical_range = .from(innigkeit.PhysicalAddress.from(head_phys), region_size),
        .protection = .{ .read = true, .write = true },
        .cache = .uncached,
    }) catch |err| {
        log.warn("failed to map CRB MMIO region: {t}", .{err});
        return null;
    };

    const base = mapping.address.value;
    return .{
        // `base` is the virtual address that `allocateSpecial()` just mapped
        // for this device-MMIO region (uncached, just established above).
        .regs_head = @ptrFromInt(base),
        // `base + @sizeOf(RegsHead)`, same just-mapped region as `.regs_head`.
        .regs_ctrl = @ptrFromInt(base + @sizeOf(RegsHead)),
        .region_phys = head_phys,
        .region_virt = base,
        .region_size = region_bytes,
    };
}

/// Size of the device MMIO window we map. One page covers QEMU's tpm-crb
/// (locality + control + shared command/response buffer).
const region_bytes: usize = 0x1000;

/// Send `command` and copy the response into `response_buf`, returning the
/// populated prefix. `command` must be a complete TPM 2.0 command (header
/// included); `response_buf` should be large enough for the expected response.
pub fn transmit(self: Crb, command: []const u8, response_buf: []u8) Error![]u8 {
    try self.requestLocality();
    defer self.relinquishLocality() catch |err| log.warn("relinquish locality: {t}", .{err});

    try self.cmdReady();
    defer self.goIdle() catch |err| log.warn("goIdle: {t}", .{err});

    const cmd_size = self.regs_ctrl.cmd_size;
    if (command.len > cmd_size) return Error.CommandTooLarge;

    const cmd_phys = (@as(u64, self.regs_ctrl.cmd_haddr) << 32) | self.regs_ctrl.cmd_laddr;
    const cmd_buf = try self.bufferAt(cmd_phys, command.len);

    // Clear the cancel register so a stale cancel can't abort this command.
    self.regs_ctrl.cancel = 0;
    writeVolatile(cmd_buf, command);

    // Ensure the command bytes are visible to the device before we ring the
    // doorbell. (mfence on x86; dsb on aarch64.)
    deviceBarrier();
    self.regs_ctrl.start = ctrl_start_invoke;

    // The device clears the start bit when the response is ready.
    try waitReg(&self.regs_ctrl.start, ctrl_start_invoke, 0, command_timeout_ms);

    if (self.regs_ctrl.sts & ctrl_sts_error != 0) return Error.DeviceError;

    const rsp_phys = self.regs_ctrl.rsp_addr;

    // The response size lives in the header (bytes 2..6, big-endian). Read the
    // header first so we copy exactly the response and nothing stale.
    const rsp_header = try self.bufferAt(rsp_phys, tpm_header_size);
    var header: [tpm_header_size]u8 = undefined;
    readVolatile(rsp_header, &header);
    const response_size = std.mem.readInt(u32, header[2..6], .big);
    if (response_size < tpm_header_size or response_size > response_buf.len) {
        return Error.MalformedResponse;
    }

    const rsp_buf = try self.bufferAt(rsp_phys, response_size);
    readVolatile(rsp_buf, response_buf[0..response_size]);
    return response_buf[0..response_size];
}

/// Header is tag(2) || size(4) || code(4).
pub const tpm_header_size: usize = 10;

fn requestLocality(self: Crb) Error!void {
    self.regs_head.loc_ctrl = loc_ctrl_request_access;
    const want = loc_state_assigned | loc_state_reg_valid;
    try waitReg(&self.regs_head.loc_state, want, want, handshake_timeout_ms);
}

fn relinquishLocality(self: Crb) Error!void {
    self.regs_head.loc_ctrl = loc_ctrl_relinquish;
    // loc_assigned clears; reg_valid stays set.
    try waitReg(
        &self.regs_head.loc_state,
        loc_state_assigned | loc_state_reg_valid,
        loc_state_reg_valid,
        handshake_timeout_ms,
    );
}

fn cmdReady(self: Crb) Error!void {
    self.regs_ctrl.req = ctrl_req_cmd_ready;
    try waitReg(&self.regs_ctrl.req, ctrl_req_cmd_ready, 0, handshake_timeout_ms);
}

fn goIdle(self: Crb) Error!void {
    self.regs_ctrl.req = ctrl_req_go_idle;
    try waitReg(&self.regs_ctrl.req, ctrl_req_go_idle, 0, handshake_timeout_ms);
}

/// Spin until `reg & mask == value`, bounded by `timeout_ms` of wallclock time.
fn waitReg(reg: *volatile u32, mask: u32, value: u32, timeout_ms: u64) Error!void {
    const timeout_ns = timeout_ms * std.time.ns_per_ms;
    const start = wallclock.read();
    while (true) {
        if (reg.* & mask == value) return;
        if (wallclock.elapsed(start, wallclock.read()).value > timeout_ns) {
            // One last read closes the race where the device flipped the bit
            // just as the deadline expired.
            if (reg.* & mask == value) return;
            return Error.Timeout;
        }
        architecture.spinLoopHint();
    }
}

/// Translate a control-area-reported buffer physical address into the mapped
/// CRB region, validating the whole `len`-byte span lies within it. Buffers
/// outside the mapped device page (relocated on some real hardware) are not yet
/// supported.
fn bufferAt(self: Crb, phys: u64, len: usize) Error![*]volatile u8 {
    const p: usize = @intCast(phys);
    // Saturating add: a device-reported `phys` near usize::max must fail this
    // bounds check, not overflow-panic it.
    if (p < self.region_phys or p +| len > self.region_phys + self.region_size) {
        log.warn("CRB buffer 0x{x}+{d} outside mapped region", .{ p, len });
        return Error.MalformedResponse;
    }
    // bounds already checked above: p falls within [region_phys, region_phys + region_size).
    return @ptrFromInt(self.region_virt + (p - self.region_phys));
}

fn writeVolatile(dst: [*]volatile u8, src: []const u8) void {
    for (src, 0..) |byte, i| dst[i] = byte;
}

fn readVolatile(src: [*]volatile u8, dst: []u8) void {
    for (dst, 0..) |*byte, i| byte.* = src[i];
}

inline fn deviceBarrier() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}
