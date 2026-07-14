const std = @import("std");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

const KernelMemoryRegion = @This();

range: innigkeit.KernelVirtualRange,
type: Type,

pub const Type = enum {
    writeable_section,
    readonly_section,
    executable_section,

    direct_map,

    special_heap,

    kernel_heap,
    kernel_stacks,

    pages,

    kernel_address_space,
};

pub inline fn format(self: KernelMemoryRegion, writer: *std.Io.Writer) !void {
    try writer.print("Region{{ {f} - {t} }}", .{
        self.range,
        self.type,
    });
}

pub const List = struct {
    values: core.containers.BoundedArray(
        KernelMemoryRegion,
        std.meta.tags(Type).len,
    ) = .{},

    /// Find the region of the given type.
    pub fn find(self: *const List, region_type: Type) ?KernelMemoryRegion {
        for (self.values.constSlice()) |region| {
            if (region.type == region_type) return region;
        }
        return null;
    }

    /// Find the region containing the given address.
    pub fn containingAddress(self: *const List, address: innigkeit.KernelVirtualAddress) ?KernelMemoryRegion.Type {
        for (self.values.constSlice()) |region| {
            if (region.range.containsAddress(address)) return region.type;
        }
        return null;
    }

    pub fn append(self: *List, region: KernelMemoryRegion) void {
        self.values.appendAssumeCapacity(region);
    }

    pub fn constSlice(self: *const List) []const KernelMemoryRegion {
        return self.values.constSlice();
    }

    pub fn sort(self: *List) void {
        std.mem.sortUnstable(innigkeit.memory.KernelMemoryRegion, self.values.slice(), {}, struct {
            fn lessThanFn(
                context: void,
                region: innigkeit.memory.KernelMemoryRegion,
                other_region: innigkeit.memory.KernelMemoryRegion,
            ) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    pub fn findFreeRange(self: *List, size: core.Size, alignment: std.mem.Alignment) ?innigkeit.KernelVirtualRange {
        // needs the regions to be sorted
        self.sort();

        const regions = self.constSlice();

        var current_address = architecture.paging.kernel_memory_range.address.toKernel();
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    std.math.maxInt(u64) - current_address.value,
                    .byte,
                );

                if (size_of_free_range.lessThan(size)) return null;

                return .from(current_address, size);
            };

            const region_address = region.range.address;

            if (region_address.lessThanOrEqual(current_address)) {
                current_address = region.range.after();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            const size_of_free_range = core.Size.from(
                (region_address.value - 1) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) {
                current_address = region.range.after();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            return .from(current_address, size);
        }
    }
};
