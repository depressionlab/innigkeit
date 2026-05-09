const std = @import("std");

const ToolDescription = @import("../../build/ToolDescription.zig");

pub fn config(b: *std.Build, description: *const ToolDescription, module: *std.Build.Module) void {
    _ = description;

    const limine = b.dependency("limine_bin", .{});

    module.link_libc = true;
    module.addIncludePath(limine.path("."));
    module.addCSourceFile(.{
        .file = limine.path("limine.c"),
        .flags = &.{ "-std=c99", "-Dmain=limine_main" },
    });
}
