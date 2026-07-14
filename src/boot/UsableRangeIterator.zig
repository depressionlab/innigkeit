const UsableRangeIterator = @This();
const boot = @import("boot");
const innigkeit = @import("innigkeit");

memory_map: boot.MemoryMap,

opt_current_range: ?innigkeit.PhysicalRange = null,

pub fn next(self: *UsableRangeIterator) ?innigkeit.PhysicalRange {
    while (true) {
        const opt_entry_range: ?innigkeit.PhysicalRange = while (self.memory_map.next()) |entry| {
            if (entry.type.isUsableForAllocation()) break entry.range;
        } else null;

        const entry_range = (opt_entry_range orelse {
            const current_range = self.opt_current_range;
            self.opt_current_range = null;
            return current_range;
        }).pageAlign();

        const current_range = self.opt_current_range orelse {
            self.opt_current_range = entry_range;
            continue;
        };

        if (current_range.after().equal(entry_range.address)) {
            // Known non-null: `current_range` above was just derived from this
            // same field via `orelse continue`.
            self.opt_current_range.?.size.addInPlace(entry_range.size);
            continue;
        }

        self.opt_current_range = entry_range;

        return current_range;
    }
}
