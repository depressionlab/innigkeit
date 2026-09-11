const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const std = @import("std");

pub const Index = enum(u32) {
    none = std.math.maxInt(u32),

    _,

    /// Returns the physical page that contains the given physical address.
    pub inline fn fromAddress(physical_address: innigkeit.PhysicalAddress) Index {
        return @enumFromInt(@intFromEnum(physical_address) / @intFromEnum(architecture.paging.standard_page_size));
    }

    /// Returns the base address of the given physical page.
    pub inline fn baseAddress(self: Index) innigkeit.PhysicalAddress {
        return .from(@intFromEnum(self) * @intFromEnum(architecture.paging.standard_page_size));
    }

    pub inline fn range(self: Index) innigkeit.PhysicalRange {
        return .from(self.baseAddress(), architecture.paging.standard_page_size);
    }
};
