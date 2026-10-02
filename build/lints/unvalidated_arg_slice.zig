//! Flags a syscall handler that slices a buffer by a raw `context.arg*()`
//! value before anything has range-checked it. Zig's slice-bounds safety
//! check fires when the slice is formed, and in the kernel that is an
//! unconditional panic, not a contained per-process fault: any process able
//! to reach the syscall can take the whole machine down with one oversized
//! length.
//!
//! Scope is deliberately narrow and heuristic, not a dataflow analysis. Only
//! `user/handlers/` files are checked. Within one function it tracks locals
//! initialised directly from `context.arg(...)`/`arg32(...)`/`arg64(...)`,
//! and reports a `[..]` slice expression that names such a local when no
//! earlier `if (...)` condition or `@min`/`@max` call mentions it. A local
//! derived through `@min` (`const n = @min(len, buf.len);`) is a different
//! name and is never tracked, so the clamp idiom passes untouched. It can
//! miss a guard that does not dominate the slice (an `if` that does not
//! return) and any taint that arrives through a struct field
//! (`spec.name_len`).
//!
//! **Good:**
//! ```zig
//! const len = context.arg(.two);
//! if (len == 0 or len > buf.len) return error.InvalidArgument;
//! try copy(buf[0..len], ptr);
//! ```
//!
//! **Bad:**
//! ```zig
//! const len = context.arg(.two);
//! try copy(buf[0..len], ptr);
//! if (len > buf.len) return error.InvalidArgument;
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
        .rule_id = "unvalidated_arg_slice",
        .run = &run,
    };
}

const MESSAGE = "slice bound comes straight from a syscall argument with no earlier range " ++
    "check; a length past the buffer panics the whole kernel. Validate it first, or clamp " ++
    "it with `@min`";

const handlers_dir = "user/handlers/";

fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;
    if (std.mem.find(u8, doc.path, handlers_dir) == null) return null;

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;
    var it = try doc.nodeLineageIterator(.root, gpa);
    defer it.deinit();

    while (try it.next()) |tuple| {
        const node, _ = tuple;
        if (tree.nodeTag(node) != .fn_decl) continue;

        const body = tree.nodeData(node).node_and_node[1];
        try checkBody(rule, config, tree, body, gpa, &lint_problems);
    }

    return if (lint_problems.items.len > 0) try .init(
        gpa,
        doc.path,
        try lint_problems.toOwnedSlice(gpa),
    ) else null;
}

fn checkBody(
    rule: zlinter.rules.LintRule,
    config: Config,
    tree: Ast,
    body: Ast.Node.Index,
    gpa: std.mem.Allocator,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
) !void {
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);

    var i = first;
    while (i + 5 <= last) : (i += 1) {
        const name = taintedLocalAt(tree, i) orelse continue;
        const guard = firstGuard(tree, name, i, last);

        var j = i;
        while (j <= last) : (j += 1) {
            if (tree.tokenTag(j) != .l_bracket) continue;
            const close = matching(tree, j, .l_bracket, .r_bracket, last) orelse continue;
            if (sliceMentions(tree, j, close, name)) {
                if (guard == null or guard.? > j) {
                    try lint_problems.append(gpa, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfToken(tree, j),
                        .end = .endOfToken(tree, close),
                        .message = try gpa.dupe(u8, MESSAGE),
                    });
                }
            }
        }
    }
}

/// If token `i` starts `const|var NAME = context.arg(...)` (or `arg32` /
/// `arg64`), returns NAME.
fn taintedLocalAt(tree: Ast, i: Ast.TokenIndex) ?[]const u8 {
    switch (tree.tokenTag(i)) {
        .keyword_const, .keyword_var => {},
        else => return null,
    }
    if (tree.tokenTag(i + 1) != .identifier) return null;
    if (tree.tokenTag(i + 2) != .equal) return null;
    if (tree.tokenTag(i + 3) != .identifier) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(i + 3), "context")) return null;
    if (tree.tokenTag(i + 4) != .period) return null;
    if (tree.tokenTag(i + 5) != .identifier) return null;
    const method = tree.tokenSlice(i + 5);
    if (!std.mem.eql(u8, method, "arg") and
        !std.mem.eql(u8, method, "arg32") and
        !std.mem.eql(u8, method, "arg64")) return null;
    return tree.tokenSlice(i + 1);
}

/// Token index of the earliest `if (...)` condition or `@min`/`@max` call
/// after `from` that mentions `name`, or null.
fn firstGuard(tree: Ast, name: []const u8, from: Ast.TokenIndex, last: Ast.TokenIndex) ?Ast.TokenIndex {
    var i = from;
    while (i <= last) : (i += 1) {
        const is_if = tree.tokenTag(i) == .keyword_if;
        const is_clamp = tree.tokenTag(i) == .builtin and
            (std.mem.eql(u8, tree.tokenSlice(i), "@min") or std.mem.eql(u8, tree.tokenSlice(i), "@max"));
        if (!is_if and !is_clamp) continue;
        if (i + 1 > last or tree.tokenTag(i + 1) != .l_paren) continue;
        const close = matching(tree, i + 1, .l_paren, .r_paren, last) orelse continue;
        if (mentions(tree, i + 1, close, name)) return i;
    }
    return null;
}

/// True if `[open, close]` is a slice expression (`..` at bracket depth 0)
/// naming `name` outside any `@min`/`@max` call.
fn sliceMentions(tree: Ast, open: Ast.TokenIndex, close: Ast.TokenIndex, name: []const u8) bool {
    var has_range = false;
    var depth: usize = 0;
    var i = open + 1;
    while (i < close) : (i += 1) {
        switch (tree.tokenTag(i)) {
            .l_bracket, .l_paren, .l_brace => depth += 1,
            .r_bracket, .r_paren, .r_brace => depth -|= 1,
            .ellipsis2 => if (depth == 0) {
                has_range = true;
            },
            .builtin => {
                const text = tree.tokenSlice(i);
                if (std.mem.eql(u8, text, "@min") or std.mem.eql(u8, text, "@max")) return false;
            },
            else => {},
        }
    }
    return has_range and mentions(tree, open, close, name);
}

fn mentions(tree: Ast, from: Ast.TokenIndex, to: Ast.TokenIndex, name: []const u8) bool {
    var i = from;
    while (i <= to) : (i += 1) {
        if (tree.tokenTag(i) == .identifier and std.mem.eql(u8, tree.tokenSlice(i), name)) return true;
    }
    return false;
}

/// Index of the token closing the bracket/paren opened at `open`, or null.
fn matching(
    tree: Ast,
    open: Ast.TokenIndex,
    open_tag: std.zig.Token.Tag,
    close_tag: std.zig.Token.Tag,
    last: Ast.TokenIndex,
) ?Ast.TokenIndex {
    var depth: usize = 0;
    var i = open;
    while (i <= last) : (i += 1) {
        const tag = tree.tokenTag(i);
        if (tag == open_tag) depth += 1;
        if (tag == close_tag) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const handler_file = "src/innigkeit/user/handlers/file.zig";

test "flags a slice taken before the length is checked (the open() bug)" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn open(context: Context) !usize {
        \\    const path_len = context.arg(.two);
        \\    var path_buf: [63]u8 = undefined;
        \\    try copy(path_buf[0..path_len], 0);
        \\    if (path_len > 62) return error.InvalidArgument;
        \\}
    ,
        .{ .filename = handler_file },
        Config{},
        &.{
            .{
                .rule_id = "unvalidated_arg_slice",
                .severity = .warning,
                .slice = "[0..path_len]",
                .message = MESSAGE,
            },
        },
    );
}

test "allows a slice after an explicit range check" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn open(context: Context) !usize {
        \\    const name_len = context.arg32(.two);
        \\    if (name_len == 0 or name_len > 15) return error.InvalidArgument;
        \\    var buf: [16]u8 = undefined;
        \\    try copy(buf[0..name_len], 0);
        \\}
    ,
        .{ .filename = handler_file },
        Config{},
        &.{},
    );
}

test "allows the @min clamp idiom" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn recv(context: Context) !usize {
        \\    const buf_len = context.arg(.four);
        \\    var bounce: [1472]u8 = undefined;
        \\    const recv_len = @min(buf_len, bounce.len);
        \\    return read(bounce[0..recv_len]);
        \\}
    ,
        .{ .filename = handler_file },
        Config{},
        &.{},
    );
}

test "ignores files outside user/handlers" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn open(context: Context) !usize {
        \\    const path_len = context.arg(.two);
        \\    var path_buf: [63]u8 = undefined;
        \\    try copy(path_buf[0..path_len], 0);
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
        \\pub fn open(context: Context) !usize {
        \\    const path_len = context.arg(.two);
        \\    var path_buf: [63]u8 = undefined;
        \\    try copy(path_buf[0..path_len], 0);
        \\}
    ,
        .{ .filename = handler_file },
        Config{ .severity = .off },
        &.{},
    );
}
