const core = @import("core");
const x64 = @import("../x64.zig");
const IOAPIC = @import("IOAPIC.zig");
const SourceOverride = @import("SourceOverride.zig");

pub var io_apics: core.containers.BoundedArray(IOAPIC, x64.config.maximum_number_of_io_apics) = .{};
pub var source_overrides: [x64.paging.PageTable.number_of_entries]?SourceOverride = @splat(null);
