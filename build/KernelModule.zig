//! Declarative description of a kernel component.
//!
//! Kernel components form a DAG. Each component is a Zig module whose root
//! file lives at `kernel/{name}/root.zig`. The build system walks this graph
//! starting from a hardcoded entry component, creates one `*std.Build.Module`
//! per component, and wires imports according to the dependency fields below.
//!
//! Register components in `src/root.zig` as a `[]const KernelModule`.
const KernelModule = @This();

const std = @import("std");
const Bundle = @import("Bundle.zig");
const Options = @import("Options.zig");

/// Unique component name.
///
/// Determines the `@import` key and the root source file (`kernel/{name}/root.zig`).
name: []const u8,

/// Names of other kernel components this component may `@import`.
component_dependencies: []const []const u8 = &.{},

/// External libraries (from `Library.Collection`) this component links.
///
/// Use `LibraryDependency.import_name` when the desired `@import` key differs
/// from the library's canonical name.
library_dependencies: []const LibraryDependency = &.{},

/// Inject per-source-file embed modules for stack-trace pretty-printing.
///
/// Enable only for the single component that renders stack traces; enabling
/// it broadly inflates compile times significantly.
sourcemaps: bool = false,

/// Optional callback for configuration that cannot be expressed declaratively.
///
/// Called once per `(component, architecture)` pair after the module is created.
configuration: ?*const fn (
    b: *std.Build,
    architecture: Bundle.Architecture,
    module: *std.Build.Module,
    options: Options,
    is_check: bool,
) anyerror!void = null,

pub const LibraryDependency = struct {
    /// The library's canonical name in `Library.Collection`.
    name: []const u8,
    /// The `@import` key exposed to this component. Defaults to `name` when null.
    import_name: ?[]const u8 = null,
};
