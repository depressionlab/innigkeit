//! Deterministic block-device failure injection.

const enabled = @import("kernel_options").fault_inject_block_test;

/// Matches `drivers/virtio/blk.zig`'s own `MAX_DEVICES`.
const max_devices = 2;

var read_budget: [max_devices]?usize = @splat(null);
var write_budget: [max_devices]?usize = @splat(null);

/// Allow `budget` more read requests against `dev_idx` to reach the real
/// device; the next one after that fails with `error.DeviceError` without
/// touching hardware. Call once per scenario, not mid-sequence.
pub fn armRead(dev_idx: usize, budget: usize) void {
    read_budget[dev_idx] = budget;
}

/// Same as `armRead`, for write requests.
pub fn armWrite(dev_idx: usize, budget: usize) void {
    write_budget[dev_idx] = budget;
}

/// Clear any armed budget for `dev_idx`, both directions.
pub fn disarm(dev_idx: usize) void {
    read_budget[dev_idx] = null;
    write_budget[dev_idx] = null;
}

/// Called from `blk.readSectorsRaw`, after its own `NotInitialized`/
/// `OutOfRange` validation but before touching hardware.
pub inline fn maybeFailRead(dev_idx: usize) error{DeviceError}!void {
    if (comptime !enabled) return;
    try maybeFail(&read_budget, dev_idx);
}

/// Called from `blk.writeSectorsRaw`, after its own `NotInitialized`/
/// `OutOfRange` validation but before touching hardware.
pub inline fn maybeFailWrite(dev_idx: usize) error{DeviceError}!void {
    if (comptime !enabled) return;
    try maybeFail(&write_budget, dev_idx);
}

fn maybeFail(budgets: *[max_devices]?usize, dev_idx: usize) error{DeviceError}!void {
    const budget = &budgets[dev_idx];
    const remaining = budget.* orelse return;
    if (remaining == 0) {
        @branchHint(.cold);
        return error.DeviceError;
    }
    budget.* = remaining - 1;
}
