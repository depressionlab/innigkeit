const AppDescription = @import("../build/AppDescription.zig");

pub const apps: []const AppDescription = &.{
    .{ .name = "hello_world" },
    .{ .name = "calculator" },
    .{ .name = "shell" },
    .{ .name = "pixels" },
    .{
        .name = "doom",
        .configuration = .{ .custom = @import("doom/custom.zig").custom },
        .use_llvm = true,
    },
};
