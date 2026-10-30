//! Flags `@ptrFromInt(...)` with no comment on the same line or the line
//! immediately above. Fabricating a pointer from a raw integer has no
//! type-system provenance at all. The reason the address is valid
//! (memory-mapped device register, a manifest-provided physical address,
//! a value already validated elsewhere) should be written down next to
//! the call, not left implicit. Inspired by clippy's `undocumented_unsafe_blocks`.
//!
//! **Good:**
//! ```zig
//! // APIC base is fixed per the SDM, always page-aligned.
//! const apic: *volatile u32 = @ptrFromInt(0xFEE00000);
//! ```
//!
//! **Bad:**
//! ```zig
//! const apic: *volatile u32 = @ptrFromInt(0xFEE00000);
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
        .rule_id = "ptr_from_int_undocumented",
        .run = &run,
    };
}

const MESSAGE = "`@ptrFromInt` fabricates a pointer with no type-system provenance! add a " ++
    "comment explaining why this address is valid";

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    const tree = doc.tree(session);
    var it = try doc.nodeLineageIterator(.root, rule_arena);
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
        if (!std.mem.eql(u8, tree.tokenSlice(main_token), "@ptrFromInt")) continue :nodes;
        if (hasNearbyComment(tree, main_token)) continue :nodes;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, MESSAGE),
        });
    }

    return if (lint_problems.items.len > 0) try .init(
        doc.file_id,
        lint_problems.items,
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

test "flags undocumented @ptrFromInt" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const p: *volatile u32 = @ptrFromInt(0xFEE00000);
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "ptr_from_int_undocumented",
                .severity = .warning,
                .slice = "@ptrFromInt(0xFEE00000)",
                .message = MESSAGE,
            },
        },
    );
}

test "allows @ptrFromInt with a preceding comment" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  // APIC base is fixed per the SDM.
        \\  const p: *volatile u32 = @ptrFromInt(0xFEE00000);
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "allows @ptrFromInt with a trailing comment" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  const p: *volatile u32 = @ptrFromInt(0xFEE00000); // APIC base
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
        \\  const p: *volatile u32 = @ptrFromInt(0xFEE00000);
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}
