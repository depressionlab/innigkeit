//! Declarative description of a shared Innigkeit library.
//!
//! Register libraries in `library/root.zig` as a `[]const LibraryDescription`.
//! `Library.getLibraries` resolves this slice topologically, panicking on
//! cycles or missing names.
const LibraryDescription = @This();

const Bundle = @import("Bundle.zig");

/// Unique library name.
///
/// Determines the `@import` key, the root source file (`lib/{name}/{name}.zig`),
/// and derived build step names.
name: []const u8,

/// Library names this library depends on. Listed names must all exist in
/// `Library.Collection`; the build system panics otherwise.
dependencies: []const []const u8 = &.{},

/// Restricts the set of architectures this library is built for.
/// Defaults to `.all`, meaning every architecture the project supports.
architectures: ArchitectureFilter = .all,

/// When true, no host-side (`external`) test runner is registered.
///
/// Use for libraries that depend on bare-metal primitives and have no
/// meaningful semantics outside Innigkeit (e.g. `hal`, `vmm`).
freestanding_only: bool = false,

pub const ArchitectureFilter = union(enum) {
    /// Build for every architecture the project supports.
    all,

    /// Build only for the listed architectures.
    only: []const Bundle.Architecture,

    /// Returns the effective architecture slice, falling back to `supported` for `.all`.
    pub fn resolve(
        self: ArchitectureFilter,
        supported: []const Bundle.Architecture,
    ) []const Bundle.Architecture {
        return switch (self) {
            .all => supported,
            .only => |archs| archs,
        };
    }
};
