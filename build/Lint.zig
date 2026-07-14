//! Wires `zlinter` into a `zig build lint` step.
//!
//! Custom Innigkeit-specific rules live in `build/lints`.
const std = @import("std");
const zlinter = @import("zlinter");

pub fn register(b: *std.Build) void {
    const lint_step = b.step("lint", "Lint source code with zlinter");

    var builder = zlinter.builder(b, .{});

    builder.addPaths(.{
        .exclude = &.{
            b.path(".tools"),
            b.path("zig-pkg"),
            b.path("sdk/zig-pkg"),
            b.path("sdk/example/zig-pkg"),
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
        .path = "build/lints/truncate_unchecked_arithmetic.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "ptr_from_int_undocumented",
        .path = "build/lints/ptr_from_int_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "ptrcast_undocumented",
        .path = "build/lints/ptrcast_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "aligncast_undocumented",
        .path = "build/lints/aligncast_undocumented.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "hex_literal_case",
        .path = "build/lints/hex_literal_case.zig",
    } }, .{});
    builder.addRule(.{ .custom = .{
        .name = "undocumented_zlinter_disable",
        .path = "build/lints/undocumented_zlinter_disable.zig",
    } }, .{});

    lint_step.dependOn(builder.build());
}
