//! The `zig build lint` project: a separate build so that zlinter's own
//! `build.zig` (which searches for `kcov` with `findProgram` and would poison
//! the main build's configuration cache on every invocation) never runs as part
//! of the main build. The main `build.zig` runs this as a subprocess; see
//! `build/Lint.zig`. Run from the repository root, e.g.:
//! `zig build --build-file lint/build.zig lint -- --fix`.
//!
//! Custom Innigkeit-specific rules live in `lint/rules`.
const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const lint_step = b.step("lint", "Lint source code with zlinter");

    var builder = zlinter.builder(b, .{});

    // This build root is `lint/`; the code under lint is the repository root.
    builder.addPaths(.{
        .include_dirs = &.{b.path("..")},
        .exclude_dirs = &.{
            b.path("../.tools"),
            b.path("../zig-pkg"),
            b.path("../.zig-cache"),
            b.path("../sdk/zig-pkg"),
            b.path("../sdk/example/zig-pkg"),
            b.path("zig-pkg"),
        },
    });

    builder.addRule(.{ .builtin = .no_unused }, .{});
    builder.addRule(.{ .builtin = .no_deprecated }, .{});
    builder.addRule(.{ .builtin = .no_hidden_allocations }, .{});
    builder.addRule(.{ .builtin = .no_literal_only_bool_expression }, .{});
    builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
    builder.addRule(.{ .builtin = .no_swallow_error }, .{});
    builder.addRule(.{ .builtin = .require_errdefer_dealloc }, .{});
    builder.addRule(.{ .builtin = .require_fmt }, .{});
    builder.addRule(.{ .builtin = .import_ordering }, .{});

    builder.addRule(.{ .custom = .{
        .name = "truncate_unchecked_arithmetic",
        .path = "rules/truncate_unchecked_arithmetic.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "ptr_from_int_undocumented",
        .path = "rules/ptr_from_int_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "ptrcast_undocumented",
        .path = "rules/ptrcast_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "aligncast_undocumented",
        .path = "rules/aligncast_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "hex_literal_case",
        .path = "rules/hex_literal_case.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "unvalidated_arg_slice",
        .path = "rules/unvalidated_arg_slice.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "undocumented_zlinter_disable",
        .path = "rules/undocumented_zlinter_disable.zig",
    } }, .{});

    lint_step.dependOn(builder.build());
}
