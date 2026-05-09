const KernelModule = @import("../build/KernelModule.zig");

pub const modules: []const KernelModule = &.{
    .{
        .name = "architecture",
        .component_dependencies = &.{"innigkeit"},
        .library_dependencies = &.{
            .{ .name = "innigkeit", .import_name = "libinnigkeit" },
            .{ .name = "core" },
            .{ .name = "bitjuggle" },
        },
        .configuration = @import("architecture/custom.zig").custom,
    },
    .{
        .name = "boot",
        .component_dependencies = &.{ "architecture", "innigkeit" },
        .library_dependencies = &.{
            .{ .name = "core" },
            .{ .name = "uuid" },
        },
    },
    .{
        .name = "innigkeit",
        .component_dependencies = &.{ "architecture", "boot" },
        .library_dependencies = &.{
            .{ .name = "innigkeit", .import_name = "libinnigkeit" },
            .{ .name = "core" },
        },
        .configuration = @import("innigkeit/custom.zig").custom,
        .sourcemaps = true,
    },
};
