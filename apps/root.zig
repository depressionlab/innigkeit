pub const apps: []const AppDescription = &.{
    .{
        .name = "hello_world",
        .dependencies = &.{"innigkeit"},
        .configuration = .simple,
    },
};

const AppDescription = @import("../build/AppDescription.zig");
