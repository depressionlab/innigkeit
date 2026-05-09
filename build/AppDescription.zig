//! Declarative description of a userspace Innigkeit application.
//!
//! Register applications in `apps/root.zig` as a `[]const AppDescription`.
//! The build system reads this slice to produce executables for every
//! supported `Bundle` without requiring per-app build boilerplate.
const AppDescription = @This();

const std = @import("std");
const Bundle = @import("Bundle.zig");

/// Unique application name.
///
/// Determines the executable name, the root source file (apps/{name}/{name}.zig`),
/// and all derived build step names.
name: []const u8,

/// Library names this application depends on.
///
/// Each name must correspond to an entry in `Library.Collection`; the build
/// system panics at configuration time for any unresolvable name.
dependencies: []const []const u8 = &.{},

/// Extra build configuration applied after the root module is created.
configuration: Configuration = .simple,

pub const Configuration = union(enum) {
    /// No additional configuration needed.
    simple,

    /// Link libc.
    link_c,

    /// Fully custom callback, called once per `(app, bundle)` pair.
    custom: *const fn (
        b: *std.Build,
        bundle: Bundle,
        module: *std.Build.Module,
    ) anyerror!void,
};
