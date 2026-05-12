const AppDescription = @import("../build/AppDescription.zig");

pub const apps: []const AppDescription = &.{
    .{
        .name = "hello_world",
        .dependencies = &.{"innigkeit"},
        .configuration = .simple,
    },
    .{
        .name = "calculator",
        .dependencies = &.{"innigkeit"},
        .configuration = .simple,
    },
};
