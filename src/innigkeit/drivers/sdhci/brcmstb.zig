//! BCM2712 on-die SDHCI controller for the Raspberry Pi 5's microSD slot.
//!
//! This is not an RP1 device. The board devicetree (`bcm2712.dtsi`,
//! `bcm2712-rpi-5-b.dts`) puts the SD card on `sdio1`, a plain on-die
//! controller (`brcm,bcm2712-sdhci`, `brcm,sdhci-brcmstb`) in the SoC's own
//! MMIO space, with a card-detect GPIO and a fixed 200 MHz base clock. No
//! PCIe/RP1 driver is needed. Linux supports the same controller in
//! `sdhci-brcmstb.c`; its BCM2712 quirks only matter for UHS modes and
//! non-removable cards, which this driver doesn't use. See
//! `docs/rpi5-port-plan.md` (PM4).
//!
//! Scope: one card, PIO only, default speed, 4-bit bus, SDHC/SDXC only (any
//! card that answers CMD8 and sets HCS in ACMD41). CSD is not parsed, so the
//! card's capacity is unknown and callers must not read or write past its
//! end. `readSectors`/`writeSectors` only check that the LBA fits the 32-bit
//! command argument.
//!
//! Unverified: written from the Linux driver, the devicetree and the SD
//! specs. There is no QEMU model of this hardware and it has not run on
//! silicon. `physical_base` in particular needs confirming on hardware, like
//! the GIC-400 address in `arm/gic.zig`.

const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const wallclock = innigkeit.time.wallclock;
const log = innigkeit.debug.log.scoped(.sdhci_brcmstb);

const Sdhci = @This();

regs: *volatile Regs,

/// Relative card address from CMD3; the argument for CMD7, CMD13, etc.
rca: u16,

/// Standard SDHCI 3.0 register block, offsets checked against Linux's
/// `drivers/mmc/host/sdhci.h`. The brcmstb vendor "cfg" block (a separate
/// MMIO range) is not mapped; it only matters for UHS PHY setup and
/// forced-presence quirks.
const Regs = extern struct {
    argument2: u32, // 0x00 (SDMA address; unused, PIO only)
    block_size: u16, // 0x04
    block_count: u16, // 0x06
    argument: u32, // 0x08
    transfer_mode: u16, // 0x0C
    command: u16, // 0x0E
    response: [4]u32, // 0x10..0x1F
    buffer: u32, // 0x20
    present_state: u32, // 0x24
    host_control: u8, // 0x28
    power_control: u8, // 0x29
    block_gap_control: u8, // 0x2A
    wake_up_control: u8, // 0x2B
    clock_control: u16, // 0x2C
    timeout_control: u8, // 0x2E
    software_reset: u8, // 0x2F
    int_status: u32, // 0x30
    int_enable: u32, // 0x34
    signal_enable: u32, // 0x38
    auto_cmd_status: u16, // 0x3C
    host_control2: u16, // 0x3E
    capabilities: u32, // 0x40
    capabilities_1: u32, // 0x44
    _reserved: [0xFE - 0x48]u8,
    host_version: u16, // 0xFE

    comptime {
        core.testing.expectSize(Regs, .from(0x100, .byte));
    }
};

// SDHCI_PRESENT_STATE bits.
const present_cmd_inhibit: u32 = 1 << 0;
const present_data_inhibit: u32 = 1 << 1;
const present_buffer_write_enable: u32 = 1 << 10;
const present_buffer_read_enable: u32 = 1 << 11;

// SDHCI_HOST_CONTROL bits.
const host_control_4bit_bus: u8 = 1 << 1;

// SDHCI_POWER_CONTROL bits/values.
const power_330: u8 = 0x0E; // 3.3 V
const power_on: u8 = 0x01;

// SDHCI_CLOCK_CONTROL bits.
const clock_int_en: u16 = 1 << 0;
const clock_int_stable: u16 = 1 << 1;
const clock_card_en: u16 = 1 << 2;
const clock_divider_shift: u4 = 8;
const clock_divider_hi_shift: u4 = 6;

// SDHCI_SOFTWARE_RESET bits.
const reset_all: u8 = 1 << 0;

// SDHCI_INT_STATUS/ENABLE bits used (PIO only).
const int_response: u32 = 1 << 0;
const int_data_end: u32 = 1 << 1;
const int_error: u32 = 1 << 15;
const int_all_mask: u32 = 0xFFFF_FFFF;

// Response type and check bits, packed into COMMAND next to the command index.
const resp_none: u16 = 0x00;
const resp_long: u16 = 0x01; // R2: 136-bit, CRC checked, no index check
const resp_short: u16 = 0x02; // 48-bit
const resp_short_busy: u16 = 0x03; // R1b
const cmd_crc_check: u16 = 1 << 3;
const cmd_index_check: u16 = 1 << 4;
const cmd_data_present: u16 = 1 << 5;

const resp_r1: u16 = resp_short | cmd_crc_check | cmd_index_check;
const resp_r1b: u16 = resp_short_busy | cmd_crc_check | cmd_index_check;
const resp_r3: u16 = resp_short; // OCR has no CRC
const resp_r6: u16 = resp_short | cmd_crc_check | cmd_index_check;
const resp_r7: u16 = resp_short | cmd_crc_check | cmd_index_check;

/// Physical base of the `sdio1` register block: `0x10_00000000` (the SoC
/// `ranges` offset in `bcm2712.dtsi`) plus `0x00fff000` (`sdio1`'s `reg`).
/// Taken from the devicetree, not yet confirmed on hardware.
pub const physical_base: u64 = 0x10_00FFF000;

/// One page covers the 0x260-byte register block.
const region_size: usize = 0x1000;

/// microSD block size; every command below assumes it.
const sector_size: u32 = 512;

/// Bus clock after init. `setClock` rounds down to a power-of-two divider, so
/// 200 MHz lands at 12.5 MHz, well inside default speed (25 MHz) with margin
/// for first bring-up. No reason to go faster until block I/O works.
const operating_clock_hz: u32 = 20_000_000;
/// Fixed 200 MHz `clk_emmc2` from `bcm2712.dtsi`. Not read from
/// `SDHCI_CAPABILITIES`, which `sdhci-brcmstb.c` doesn't trust on this SoC.
const base_clock_hz: u32 = 200_000_000;
/// The SD spec requires identification at 400 kHz or below.
const identification_clock_hz: u32 = 400_000;

const cmd_timeout_ms: u64 = 250;
/// Cards can take close to 1 s to finish power-up in ACMD41.
const acmd41_timeout_ms: u64 = 1200;

pub const Error = error{
    Timeout,
    NoCard,
    UnusableCard,
    CardError,
    OutOfRange,
};

/// Map the controller and run the SD init sequence (CMD0/CMD8/ACMD41/CMD2/
/// CMD3/CMD7/ACMD6). Leaves the card selected, 4-bit, at `operating_clock_hz`.
/// Returns `error.Timeout` if CMD8 or ACMD41 never completes, and
/// `error.UnusableCard` for anything that isn't SDHC/SDXC.
pub fn init() Error!Sdhci {
    const mapping = innigkeit.memory.heap.allocateSpecial(.{
        .physical_range = .from(innigkeit.PhysicalAddress.from(physical_base), .from(region_size, .byte)),
        .protection = .{ .read = true, .write = true },
        .cache = .uncached,
    }) catch |err| {
        log.warn("failed to map SDHCI MMIO region: {t}", .{err});
        return Error.CardError;
    };
    const regs: *volatile Regs = @ptrFromInt(@intFromEnum(mapping.address));

    var self: Sdhci = .{ .regs = regs, .rca = 0 };
    try self.reset();
    self.setClock(identification_clock_hz);
    self.setPower();

    try self.command(0, 0, resp_none, false); // CMD0: GO_IDLE_STATE

    // CMD8: SEND_IF_COND. Voltage 2.7-3.6V (0001b) plus check pattern 0xAA.
    // No answer means a Ver1.x SD card, MMC, or no card: unsupported.
    self.command(8, 0x1AA, resp_r7, false) catch return Error.UnusableCard;
    if (self.regs.response[0] & 0xFFF != 0x1AA) return Error.UnusableCard;

    // ACMD41: poll until OCR bit 31 (power-up done). HCS (bit 30) asks for
    // high-capacity addressing; a card that doesn't echo it is SDSC.
    const ocr_arg: u32 = 0x00FF_8000 | (1 << 30);
    const start = wallclock.read();
    while (true) {
        try self.appCommand(0);
        try self.command(41, ocr_arg, resp_r3, false);
        const ocr = self.regs.response[0];
        if (ocr & (1 << 31) != 0) {
            if (ocr & (1 << 30) == 0) return Error.UnusableCard; // standard-capacity
            break;
        }
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > acmd41_timeout_ms * std.time.ns_per_ms) {
            return Error.Timeout;
        }
        architecture.spinLoopHint();
    }

    try self.command(2, 0, resp_long, false); // CMD2: ALL_SEND_CID (unused)
    try self.command(3, 0, resp_r6, false); // CMD3: SEND_RELATIVE_ADDR
    self.rca = @intCast(self.regs.response[0] >> 16);

    try self.command(7, @as(u32, self.rca) << 16, resp_r1b, false); // CMD7: SELECT_CARD

    try self.appCommand(self.rca);
    try self.command(6, 2, resp_r1, false); // ACMD6: SET_BUS_WIDTH(4-bit)
    self.regs.host_control |= host_control_4bit_bus;

    self.setClock(operating_clock_hz);

    log.info("sdhci-brcmstb: card ready, RCA=0x{x:0>4}, 4-bit @ {d} MHz", .{ self.rca, operating_clock_hz / 1_000_000 });
    return self;
}

/// Read `count` sectors starting at `lba`. `buf` must be `count * 512` bytes.
pub fn readSectors(self: Sdhci, lba: u64, buf: []u8, count: u32) Error!void {
    if (buf.len != @as(usize, count) * sector_size) return Error.OutOfRange;
    try checkRange(lba, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try self.singleBlock(@intCast(lba + i), buf[i * sector_size ..][0..sector_size], .read);
    }
}

/// Write `count` sectors starting at `lba`. See `readSectors`.
pub fn writeSectors(self: Sdhci, lba: u64, buf: []const u8, count: u32) Error!void {
    if (buf.len != @as(usize, count) * sector_size) return Error.OutOfRange;
    try checkRange(lba, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try self.singleBlockWrite(@intCast(lba + i), buf[i * sector_size ..][0..sector_size]);
    }
}

/// The last block touched must fit the 32-bit command argument. Uses a
/// saturating add so a huge `lba` can't wrap past the check.
fn checkRange(lba: u64, count: u32) Error!void {
    if (count == 0) return;
    const last_lba = lba +| (count - 1);
    if (last_lba > std.math.maxInt(u32)) return Error.OutOfRange;
}

const Direction = enum { read, write };

/// CMD17/CMD24 plus a PIO transfer. Single-block on purpose: multi-block
/// (CMD18/CMD25) needs STOP_TRANSMISSION/AUTO_CMD12 handling, and PIO has no
/// throughput to gain from it.
fn singleBlock(self: Sdhci, block: u32, buf: []u8, comptime dir: Direction) Error!void {
    self.regs.block_size = @intCast(sector_size);
    self.regs.block_count = 1;

    const cmd_index: u8 = if (dir == .read) 17 else 24;
    const resp_flags = resp_r1 | cmd_data_present;
    try self.command(cmd_index, block, resp_flags, true);

    const ready_bit = if (dir == .read) present_buffer_read_enable else present_buffer_write_enable;
    try self.waitPresentState(ready_bit, ready_bit, cmd_timeout_ms);

    var word_index: usize = 0;
    while (word_index < sector_size / 4) : (word_index += 1) {
        const byte_offset = word_index * 4;
        switch (dir) {
            .read => {
                const word = self.regs.buffer;
                std.mem.writeInt(u32, buf[byte_offset..][0..4], word, .little);
            },
            .write => {
                const word = std.mem.readInt(u32, buf[byte_offset..][0..4], .little);
                self.regs.buffer = word;
            },
        }
    }

    try self.waitInterrupt(int_data_end, cmd_timeout_ms);
}

fn singleBlockWrite(self: Sdhci, block: u32, buf: []const u8) Error!void {
    // `singleBlock` takes `[]u8` for its `.read` arm. The write arm never
    // mutates `buf`, so a `@constCast` is simpler than duplicating the loop.
    return self.singleBlock(block, @constCast(buf), .write);
}

fn appCommand(self: Sdhci, rca: u16) Error!void {
    try self.command(55, @as(u32, rca) << 16, resp_r1, false); // CMD55: APP_CMD
}

/// Issue one command and wait for its response. For `has_data` transfers the
/// caller waits for the data phase. Clears stale INT_STATUS first so old flags
/// aren't mistaken for this command's.
fn command(self: Sdhci, index: u8, arg: u32, resp_flags: u16, has_data: bool) Error!void {
    // R1b holds DAT0 low while busy, which DATA_INHIBIT tracks even with no
    // data transfer. Wait it out so the next command isn't rejected.
    const is_busy_response = resp_flags & 0x03 == resp_short_busy;
    const inhibit_mask: u32 = present_cmd_inhibit | (if (has_data or is_busy_response) present_data_inhibit else 0);
    try self.waitPresentState(inhibit_mask, 0, cmd_timeout_ms);

    self.regs.int_status = int_all_mask; // write-1-to-clear
    self.regs.argument = arg;
    if (has_data) self.regs.transfer_mode = 0; // PIO: no block count, auto-CMD12 or DMA
    self.regs.command = (@as(u16, index) << 8) | resp_flags;

    try self.waitInterrupt(int_response, cmd_timeout_ms);
}

fn waitPresentState(self: Sdhci, mask: u32, value: u32, timeout_ms: u64) Error!void {
    const timeout_ns = timeout_ms * std.time.ns_per_ms;
    const start = wallclock.read();
    while (true) {
        if (self.regs.present_state & mask == value) return;
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > timeout_ns) {
            if (self.regs.present_state & mask == value) return;
            return Error.Timeout;
        }
        architecture.spinLoopHint();
    }
}

/// Spin until INT_STATUS reports `want` or an error bit, for at most
/// `timeout_ms`. An error bit returns `Error.CardError` (the controller saw a
/// CRC/index/timeout/end-bit failure); a wallclock timeout returns
/// `Error.Timeout`.
fn waitInterrupt(self: Sdhci, want: u32, timeout_ms: u64) Error!void {
    const timeout_ns = timeout_ms * std.time.ns_per_ms;
    const start = wallclock.read();
    while (true) {
        const status = self.regs.int_status;
        if (status & int_error != 0) {
            self.regs.int_status = int_all_mask;
            return Error.CardError;
        }
        if (status & want == want) {
            self.regs.int_status = want;
            return;
        }
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > timeout_ns) {
            return Error.Timeout;
        }
        architecture.spinLoopHint();
    }
}

fn reset(self: Sdhci) Error!void {
    self.regs.software_reset = reset_all;
    const timeout_ns = cmd_timeout_ms * std.time.ns_per_ms;
    const start = wallclock.read();
    while (self.regs.software_reset & reset_all != 0) {
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > timeout_ns) return Error.Timeout;
        architecture.spinLoopHint();
    }
    self.regs.int_enable = int_all_mask;
    self.regs.signal_enable = 0; // polling only
}

fn setPower(self: Sdhci) void {
    self.regs.power_control = power_330 | power_on;
}

/// Program SDHCI's power-of-two divided clock using the 10-bit divider from
/// spec v3.00: bits [15:8] hold the low 8 bits of the field, bits [7:6] the
/// high 2. The 8-bit form bottoms out at base/256 = 781.25 kHz, above the SD
/// identification limit of 400 kHz, so the extra bits are required.
fn setClock(self: Sdhci, target_hz: u32) void {
    self.regs.clock_control = 0; // stop the card clock while reprogramming

    const max_divisor = 2 * ((1 << 10) - 1); // divisor = 2 * field
    var divisor: u32 = 1;
    while (base_clock_hz / divisor > target_hz and divisor < max_divisor) divisor *= 2;
    const field: u16 = @intCast((divisor / 2) & 0x3FF);
    const field_low: u16 = field & 0xFF;
    const field_high: u16 = (field >> 8) & 0x3;

    self.regs.clock_control = (field_low << clock_divider_shift) | (field_high << clock_divider_hi_shift) | clock_int_en;

    const timeout_ns = cmd_timeout_ms * std.time.ns_per_ms;
    const start = wallclock.read();
    while (self.regs.clock_control & clock_int_stable == 0) {
        if (@intFromEnum(wallclock.elapsed(start, wallclock.read())) > timeout_ns) {
            log.warn("SDHCI clock did not stabilize within {d}ms", .{cmd_timeout_ms});
            break;
        }
        architecture.spinLoopHint();
    }

    self.regs.clock_control |= clock_card_en;
}

// There is no QEMU model of this hardware, so this test runs `setClock`
// against a zeroed `Regs` in place of MMIO. It does two things: it forces
// semantic analysis of this file (uncalled functions aren't type-checked),
// and it pins the divider bit patterns, which
// guards against the 8-bit divider bug described on `setClock`.
//
// It deliberately doesn't cover `reset`, `command` or the sector I/O paths. A
// plain struct doesn't implement write-1-to-clear, so `command()` clearing
// INT_STATUS sets every bit, including `int_error`, and `waitInterrupt`
// returns `CardError` instead of `Timeout`. Modeling that faithfully isn't
// worth it here. A real card (`docs/rpi5-hardware-checklist.md`) is the test
// for the command and PIO paths.
//
// Separately, arm's test runner hangs on a failed assertion (`PANIC IN PANIC
// arm does not implement fillContext`) instead of printing a failure. That
// needs its own fix.

test "sdhci-brcmstb: setClock computes the documented divider fields" {
    var regs: Regs = std.mem.zeroes(Regs);
    var dev: Sdhci = .{ .regs = &regs, .rca = 0 };

    dev.setClock(identification_clock_hz);
    // divisor=512 -> field=0x100 -> low=0x00, high=1; plus clock_int_en (bit0)
    // and clock_card_en (bit2).
    try std.testing.expectEqual(@as(u16, (1 << 6) | (1 << 2) | (1 << 0)), regs.clock_control);

    dev.setClock(operating_clock_hz);
    // divisor=16 -> field=8 -> low=8, high=0.
    try std.testing.expectEqual(@as(u16, (8 << 8) | (1 << 2) | (1 << 0)), regs.clock_control);
}
