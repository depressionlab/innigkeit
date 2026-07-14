//! Flags hex integer literals with lowercase hex digits (`0xdeadbeef`)
//! instead of uppercase (`0xDEADBEEF`).
//!
//! The `0x` prefix itself stays lowercase either way (matches
//! near-universal Zig style); only the digits after it are checked.
//!
//! **Good:** `0xDEADBEEF`, `0xFEE0_0000`
//!
//! **Bad:** `0xdeadbeef`, `0xFee0_0000` (mixed case)
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
        .rule_id = "hex_literal_case",
        .run = &run,
    };
}

const MESSAGE = "hex literal digits should be uppercase";

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
        if (tree.nodeTag(node) != .number_literal) continue :nodes;

        const token = tree.nodeMainToken(node);
        const slice = tree.tokenSlice(token);
        if (slice.len < 3 or slice[0] != '0' or (slice[1] != 'x' and slice[1] != 'X')) continue :nodes;

        const digits = slice[2..];
        if (std.mem.findAny(u8, digits, "abcdef") == null) continue :nodes;

        const upper_digits = try gpa.alloc(u8, digits.len);
        defer gpa.free(upper_digits);
        _ = std.ascii.upperString(upper_digits, digits);

        const fixed = try std.fmt.allocPrint(gpa, "0x{s}", .{upper_digits});

        const loc_start: zlinter.results.LintProblemLocation = .startOfToken(tree, token);
        const loc_end: zlinter.results.LintProblemLocation = .endOfToken(tree, token);

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = loc_start,
            .end = loc_end,
            .message = try gpa.dupe(u8, MESSAGE),
            .fix = .{
                .start = loc_start.byte_offset,
                .end = loc_end.byte_offset + 1,
                .text = fixed,
            },
        });
    }

    return if (lint_problems.items.len > 0) try .init(
        gpa,
        doc.path,
        try lint_problems.toOwnedSlice(gpa),
    ) else null;
}

test "flags and fixes lowercase hex digits" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const a: u32 = 0xdeadbeef;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "hex_literal_case",
                .severity = .warning,
                .slice = "0xdeadbeef",
                .message = MESSAGE,
            },
        },
    );
}

test "allows uppercase hex digits" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const a: u32 = 0xDEADBEEF;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "allows decimal literals" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const a: u32 = 12345;
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
        \\  const a: u32 = 0xdeadbeef;
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}
