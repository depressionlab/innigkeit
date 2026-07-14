//! Declarative description of a userspace Innigkeit application.
//!
//! Register applications in `apps/root.zig` as a `[]const AppDescription`.
//! The build system reads this slice to produce executables for every
//! supported `Bundle` without requiring per-app build boilerplate.

const Bundle = @import("Bundle.zig");
const std = @import("std");

/// Unique application name.
///
/// Determines the executable name, the root source file
/// (`{root_dir}/{name}/main.zig`), and all derived build step names.
name: []const u8,

/// Directory containing this app's `{name}/main.zig`, relative to the
/// repo root. Defaults to `apps/`, where every real sample/demo app
/// lives; test-fixture apps (`test_only = true`) live under
/// `testing/fixtures/` instead, keeping them out of the user-facing
/// `apps/` listing.
root_dir: []const u8 = "apps",

/// Library names this application depends on.
///
/// Each name must correspond to an entry in `Library.Collection`; the build
/// system panics at configuration time for any unresolvable name.
dependencies: []const []const u8 = &.{"innigkeit"},

/// Extra build configuration applied after the root module is created.
configuration: Configuration = .simple,

/// Whether or not to use the LLVM Zig backend to build this app.
use_llvm: bool = false,

/// If true, this app is only embedded in the test kernel's initfs
/// (`Kernel.buildTestKernel`), never the release kernel's
/// (`Kernel.buildKernel`). For fixture apps that exist purely to be spawned
/// by a kernel-side integration test.
test_only: bool = false,

pub const Configuration = union(enum) {
    /// No additional configuration needed for this app.
    simple,

    /// The same as `.simple` but linking libc with the app.
    link_c,

    /// Fully custom callback, called once per `(app, bundle)` pair.
    ///
    /// Necesitates a function in `apps/{name}/custom.zig` with the type
    /// ```zig
    /// *const fn (b: *std.Build, bundle: Bundle, module: *std.Build.Module) anyerror!void
    /// ```
    custom: *const fn (
        b: *std.Build,
        bundle: Bundle,
        module: *std.Build.Module,
    ) anyerror!void,
};
