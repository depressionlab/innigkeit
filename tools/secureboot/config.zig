const std = @import("std");
const ToolDescription = @import("../../build/ToolDescription.zig");

/// Link the same vendored `limine.c` (via `-Dmain=limine_main`) that
/// `tools/limine_install` uses, so this tool can call Limine's
/// `enroll-config` in-process instead of shelling out to a runtime-compiled
/// copy of it.
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
