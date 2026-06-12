const AppDescription = @import("../build/AppDescription.zig");

pub const apps: []const AppDescription = &.{
    .{ .name = "hello_world" },
    .{ .name = "std_demo" },
    .{ .name = "calculator" },
    .{ .name = "shell" },
    .{ .name = "pixels" },
    .{ .name = "gfx_demo" },
    .{ .name = "shader_demo" },
    .{ .name = "wm" },
    .{ .name = "installer" },
    .{ .name = "tcp_echo" },
    .{
        .name = "doom",
        .configuration = .{ .custom = @import("doom/custom.zig").custom },
        .use_llvm = true,
    },
};
