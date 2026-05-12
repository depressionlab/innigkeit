//! A batch of virtual ranges with their current map type.
//!
//! Attempts to merge adjacent ranges if they have the same map type and are reasonably close together see
//! `innigkeit.config.virtual_range_batching_seperation_to_merge_over`.
const ChangeProtectionBatch = @This();

const std = @import("std");

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");

ranges: core.containers.BoundedArray(
    VirtualRangeWithMapType,
    innigkeit.config.mem.virtual_ranges_to_batch,
) = .{},

pub const VirtualRangeWithMapType = struct {
    virtual_range: innigkeit.VirtualRange,
    previous_map_type: innigkeit.mem.MapType,
};

/// Appends a virtual range to the batch.
///
/// **REQUIREMENTS**:
/// - `range.virtual_range.address` must be greater than or equal to the end of the last range in the batch
/// - `range.virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `range.virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn append(self: *ChangeProtectionBatch, range: VirtualRangeWithMapType) bool {
    if (core.is_debug) std.debug.assert(range.virtual_range.pageAligned());

    const len = self.ranges.len;

    if (len == 0) {
        self.ranges.appendAssumeCapacity(range);
        return true;
    }

    const last: *VirtualRangeWithMapType = &self.ranges.slice()[len - 1];

    if (core.is_debug) std.debug.assert(range.virtual_range.address.greaterThanOrEqual(last.virtual_range.after()));

    const seperation_size = last.virtual_range.after().difference(range.virtual_range.address);

    if (seperation_size.lessThanOrEqual(innigkeit.config.mem.virtual_range_batching_merge_distance) and
        last.previous_map_type.equal(range.previous_map_type))
    {
        last.virtual_range.size.addInPlace(seperation_size);
        last.virtual_range.size.addInPlace(range.virtual_range.size);
        return true;
    }

    if (self.full()) {
        @branchHint(.unlikely);
        return false;
    }

    self.ranges.appendAssumeCapacity(range);
    return true;
}

pub fn full(self: *ChangeProtectionBatch) bool {
    return self.ranges.len == innigkeit.config.mem.virtual_ranges_to_batch;
}

pub fn clear(self: *ChangeProtectionBatch) void {
    self.ranges.clear();
}
