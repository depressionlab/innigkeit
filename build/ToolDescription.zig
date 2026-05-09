//! Declarative description of a host build tool.
//!
//! Tools are host-native executables invoked during the build (e.g. image
//! assemblers, bootloader installers). Register tools in `tools/root.zig`
//! as a `[]const ToolDescription`.
const ToolDescription = @This();

const std = @import("std");

/// Unique tool name.
///
/// Determines the executable name, the root source file (`tool/{name}/{name}.zig`),
/// and derived build step names.
name: []const u8,

/// Library names this tool depends on. Each must have a valid
/// `external_module_for_host`; the build system panics otherwise.
dependencies: []const []const u8 = &.{},

/// Extra build configuration applied after the root module is created.
configuration: Configuration = .simple,

pub const Configuration = union(enum) {
    /// No additional configuration needed.
    simple,

    /// Link libc.
    link_c,

    /// Fully custom callback. Takes a pointer to avoid copying if the struct grows.
    custom: *const fn (
        b: *std.Build,
        description: *const ToolDescription,
        module: *std.Build.Module,
    ) void,
};
