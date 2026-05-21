const ToolDescription = @import("../build/ToolDescription.zig");

pub const tools: []const ToolDescription = &.{
    .{
        .name = "image_builder",
        .dependencies = &.{ "core", "filesystem", "uuid" },
    },
    .{
        .name = "limine_install",
        .configuration = .{
            .custom = @import("limine_install/config.zig").config,
        },
    },
    .{
        .name = "initfs_builder",
    },
};
