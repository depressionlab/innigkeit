//! A batch of virtual ranges.
//!
//! Attempts to merge adjacent ranges if they are reasonably close together see
//! `innigkeit.config.virtual_range_batching_seperation_to_merge_over`.
const VirtualRangeBatch = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");

ranges: core.containers.BoundedArray(
    innigkeit.VirtualRange,
    innigkeit.config.mem.virtual_ranges_to_batch,
) = .{},

/// Appends a virtual range to the batch.
///
/// If full then always merges with the last range.
///
/// **REQUIREMENTS**:
/// - Each subsequent range must be greater than or equal to the previous range.
/// - `range.address` must be greater than or equal to the end of the last range in the batch
/// - `range.address` must be aligned to `arch.paging.standard_page_size`
/// - `range.size` must be aligned to `arch.paging.standard_page_size`
pub fn appendMergeIfFull(batch: *VirtualRangeBatch, range: innigkeit.VirtualRange) void {
    if (core.is_debug) std.debug.assert(range.pageAligned());

    switch (batch.ranges.len) {
        0 => batch.ranges.appendAssumeCapacity(range),
        innigkeit.config.mem.virtual_ranges_to_batch => {
            @branchHint(.unlikely);

            // we have hit the limit of virtual ranges to batch together so we always merge with the last range
            const last: *innigkeit.VirtualRange = &batch.ranges.slice()[innigkeit.config.mem.virtual_ranges_to_batch - 1];

            if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

            last.size.addInPlace(last.after().difference(range.address));
            last.size.addInPlace(range.size);
        },
        else => |len| {
            const last: *innigkeit.VirtualRange = &batch.ranges.slice()[len - 1];

            if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

            const seperation_size = last.after().difference(range.address);

            if (seperation_size.lessThanOrEqual(innigkeit.config.mem.virtual_range_batching_merge_distance)) {
                last.size.addInPlace(seperation_size);
                last.size.addInPlace(range.size);
            } else {
                batch.ranges.appendAssumeCapacity(range);
            }
        },
    }
}

/// Appends a virtual range to the batch.
///
/// Returns `false` if the batch is full and the range could not be appended.
///
/// **REQUIREMENTS**:
/// - Each subsequent range must be greater than or equal to the previous range.
/// - `range.address` must be greater than or equal to the end of the last range in the batch
/// - `range.address` must be aligned to `arch.paging.standard_page_size`
/// - `range.size` must be aligned to `arch.paging.standard_page_size`
pub fn append(batch: *VirtualRangeBatch, range: innigkeit.VirtualRange) bool {
    if (core.is_debug) std.debug.assert(range.pageAligned());

    const len = batch.ranges.len;

    if (len == 0) {
        batch.ranges.appendAssumeCapacity(range);
        return true;
    }

    const last: *innigkeit.VirtualRange = &batch.ranges.slice()[len - 1];

    if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

    const seperation_size = last.after().difference(range.address);

    if (seperation_size.lessThanOrEqual(innigkeit.config.mem.virtual_range_batching_merge_distance)) {
        last.size.addInPlace(seperation_size);
        last.size.addInPlace(range.size);
        return true;
    }

    if (batch.full()) {
        @branchHint(.unlikely);
        return false;
    }

    batch.ranges.appendAssumeCapacity(range);
    return true;
}

pub fn full(batch: *VirtualRangeBatch) bool {
    return batch.ranges.len == innigkeit.config.mem.virtual_ranges_to_batch;
}

pub fn clear(batch: *VirtualRangeBatch) void {
    batch.ranges.clear();
}
