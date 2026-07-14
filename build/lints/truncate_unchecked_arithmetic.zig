//! Flags `@truncate(...)` wrapping a plain (non-wrapping) arithmetic
//! expression. `@truncate` silently discards any bits that don't fit the
//! target type. If the value being truncated came from `*`/`+`/`-`
//! (rather than the explicitly-wrapping `*%`/`+%`/`-%` forms), it reads as
//! though the overflow wasn't intentional. Inspired by clippy's
//! `cast_possible_truncation`, scoped to the specific shape that caused a
//! real bug in this codebase (a truncating multiply overflow, see
//! docs/security-audit.md F2) rather than flagging every `@truncate`.
//!
//! **Good** (wrapping op makes truncation-of-overflow explicit):
//! ```zig
//! b.* = @truncate(i *% 3 +% 7);
//! ```
//!
//! **Bad** (plain op; did the author mean to discard the overflow?):
//! ```zig
//! b.* = @truncate(i * 3 + 7);
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
        .rule_id = "truncate_unchecked_arithmetic",
        .run = &run,
    };
}

const MESSAGE = "`@truncate` of a plain (non-wrapping) arithmetic expression discards overflow " ++
    "silently! use a wrapping operator (`*%`/`+%`/`-%`) to make the intent " ++
    "explicit, or add a comment justifying the truncation";

fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
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
        if (!std.mem.eql(u8, tree.tokenSlice(main_token), "@truncate")) continue :nodes;

        var buffer: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, node) orelse continue :nodes;
        if (params.len != 1) continue :nodes;

        switch (tree.nodeTag(params[0])) {
            .mul, .add, .sub => {},
            else => continue :nodes,
        }

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

test "flags @truncate of plain arithmetic" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  var b: u8 = undefined;
        \\  const i: u32 = 300;
        \\  b = @truncate(i * 3 + 7);
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "truncate_unchecked_arithmetic",
                .severity = .warning,
                .slice = "@truncate(i * 3 + 7)",
                .message = MESSAGE,
            },
        },
    );
}

test "allows @truncate of wrapping arithmetic" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  var b: u8 = undefined;
        \\  const i: u32 = 300;
        \\  b = @truncate(i *% 3 +% 7);
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "allows @truncate of plain arithmetic with a justifying comment" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  var b: u8 = undefined;
        \\  const i: u32 = 300;
        \\  // Safe: i is already bounded above by an earlier check.
        \\  b = @truncate(i * 3 + 7);
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "allows @truncate of a plain value" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  var b: u8 = undefined;
        \\  const i: u32 = 300;
        \\  b = @truncate(i);
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
        \\  var b: u8 = undefined;
        \\  const i: u32 = 300;
        \\  b = @truncate(i * 3);
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}
