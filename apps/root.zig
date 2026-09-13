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
    .{
        .name = "itest_spawn_wait",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_illegal_instruction",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_instruction_abort",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_sibling_kill",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_cap_sender",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_cap_receiver",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_kill_victim",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_killer",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
    .{
        .name = "itest_fuzz_target",
        .root_dir = "testing/fixtures",
        .test_only = true,
    },
};
