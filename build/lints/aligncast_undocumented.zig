//! Flags `@alignCast(...)` with no comment on the same line or the line
//! immediately above. Asserting a pointer's alignment is a runtime-checked
//! promise (a misaligned pointer traps in safe modes) with no static proof
//! behind it. The reason the alignment actually holds (the source is a
//! `[]align(N)` slice, a page-aligned physical/virtual address, a `*anyopaque`
//! recovered from something the allocator guaranteed was aligned) should be
//! written down next to the cast, not left implicit. Sibling of
//! `ptr_from_int_undocumented`/`ptrcast_undocumented`, same rationale
//! (clippy's `undocumented_unsafe_blocks`).
//!
//! **Good:**
//! ```zig
//! // frame is page-allocated, so 4096-byte alignment always holds.
//! const page: *align(4096) [4096]u8 = @alignCast(frame_ptr);
//! ```
//!
//! **Bad:**
//! ```zig
//! const page: *align(4096) [4096]u8 = @alignCast(frame_ptr);
//! ```
const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return .{
        .rule_id = "aligncast_undocumented",
        .run = &run,
    };
}

const MESSAGE = "`@alignCast` asserts an alignment with no static proof! add a " ++
    "comment explaining why this alignment always holds";

fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;
    var it = try doc.nodeLineageIterator(.root, gpa);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        switch (tree.nodeTag(node)) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => {},
            else => continue :nodes,
        }

        const main_token = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(main_token), "@alignCast")) continue :nodes;
        if (hasNearbyComment(tree, main_token)) continue :nodes;

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try gpa.dupe(u8, MESSAGE),
        });
    }

    return if (lint_problems.items.len > 0) try .init(
        gpa,
        doc.path,
        try lint_problems.toOwnedSlice(gpa),
    ) else null;
}

/// True if there's a `//` comment on the same line as `token`, or on the
/// line immediately before it.
fn hasNearbyComment(tree: Ast, token: Ast.TokenIndex) bool {
    const loc = tree.tokenLocation(0, token);
    const source = tree.source;

    if (std.mem.find(u8, source[loc.line_start..loc.line_end], "//") != null) return true;

    if (loc.line_start == 0) return false;
    const prev_line_end = loc.line_start - 1; // the '\n' itself
    const prev_line_start = if (std.mem.findScalarLast(u8, source[0..prev_line_end], '\n')) |i|
        i + 1
    else
        0;
    return std.mem.find(u8, source[prev_line_start..prev_line_end], "//") != null;
}

test "flags undocumented @alignCast" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const p: *align(4096) u8 = @alignCast(ptr);
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "aligncast_undocumented",
                .severity = .warning,
                .slice = "@alignCast(ptr)",
                .message = MESSAGE,
            },
        },
    );
}

test "allows @alignCast with a preceding comment" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  // ptr came from the page allocator, always 4096-aligned.
        \\  const p: *align(4096) u8 = @alignCast(ptr);
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "allows @alignCast with a trailing comment" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const p: *align(4096) u8 = @alignCast(ptr); // page-aligned
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "off" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const p: *align(4096) u8 = @alignCast(ptr);
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}
