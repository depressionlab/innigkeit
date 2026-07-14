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
        .name = "codesign",
        .configuration = .{
            .custom = @import("codesign/config.zig").config,
        },
    },
    .{
        .name = "volume_recovery",
        .configuration = .{
            .custom = @import("volume_recovery/config.zig").config,
        },
    },
    .{
        .name = "secureboot",
        .configuration = .{
            .custom = @import("secureboot/config.zig").config,
        },
    },
    .{ .name = "initfs_builder" },
};
