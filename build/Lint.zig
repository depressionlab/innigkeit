//! `zig build lint`: runs the separate lint project in `lint/`.
//!
//! zlinter lives in its own build so that its `build.zig` (which looks for
//! `kcov` with `findProgram` and would poison the configuration cache of every
//! `zig build`) never runs as part of this one. Arguments after `--` are
//! forwarded, e.g. `zig build lint -- --rule import_ordering --fix`.
const std = @import("std");

pub fn register(b: *std.Build) void {
    const lint = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file", "lint/build.zig", "lint", "--" });
    lint.addPassthruArgs();
    lint.has_side_effects = true;
    lint.stdio = .inherit;
    b.step("lint", "Lint source code with zlinter (separate lint/ project)").dependOn(&lint.step);
}
