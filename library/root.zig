const LibraryDescription = @import("../build/LibraryDescription.zig");

pub const libraries: []const LibraryDescription = &.{
    .{ .name = "bitjuggle", .dependencies = &.{"core"} },
    .{ .name = "innigkeit", .freestanding_only = true },
    .{ .name = "core" },
    .{ .name = "filesystem", .dependencies = &.{ "core", "uuid" } },
    .{ .name = "uuid", .dependencies = &.{"core"} },
};
