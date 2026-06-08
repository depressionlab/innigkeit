const std = @import("std");
const ToolDescription = @import("../../build/ToolDescription.zig");

pub fn config(b: *std.Build, _: *const ToolDescription, module: *std.Build.Module) void {
    const toml = b.dependency("toml", .{});
    module.addImport("toml", toml.module("toml"));
}
