//! Flags a field of a slab-cached type that nothing resets when its slot is
//! reused.
//!
//! The slab constructor runs once per slot, not once per allocation, so any
//! field the allocating function (`create`) forgets keeps the previous
//! occupant's value: a stale entitlement mask, a still-open file descriptor, a
//! `terminating` flag already set, a half-drained capability free list. Every
//! one of those was a real cross-process bug in this tree
//! (`.claude/rules/slab-reuse.md`).
//!
//! Scope is deliberately narrow and heuristic. For a file whose root type is
//! allocated from a cache (`<...cache...>.allocate()` / `allocateMany()` inside
//! some function of the same file) every container field of the root type must
//! be *mentioned* as `.field` in at least one of:
//!   - a function that calls such an `allocate`,
//!   - a function whose name contains "construct", or
//!   - the argument list of a `Cache(...)` declaration in the same file (an
//!     inline constructor).
//! A field that is intentionally reuse-safe (for example a lock the constructor
//! leaves unlocked, or state only ever written before first use) is accepted
//! with a doc comment containing `slab-reuse-ok:` and the reason. The check
//! cannot prove the mention actually resets the field, only that someone
//! decided about it; it forces that decision for every new field.
//!
//! **Good:**
//! ```zig
//! /// Reset in `create()`.
//! exit_status: i32 = 0,
//! // create(): process.exit_status = 0;
//! ```
//!
//! **Bad:**
//! ```zig
//! next_id: u32 = 0, // never touched by create(): survives slab reuse
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
        .rule_id = "slab_reuse_field",
        .run = &run,
    };
}

const marker = "slab-reuse-ok:";

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
    const tree = doc.tree(session);

    var handled: std.StringHashMapUnmanaged(void) = .empty;
    var allocating = false;
    var whole_object_reset = false;

    // Pass 1: functions that allocate from a cache or construct, and inline
    // `Cache(...)` argument lists.
    var it = try doc.nodeLineageIterator(.root, rule_arena);
    defer it.deinit();
    while (try it.next()) |tuple| {
        const node, _ = tuple;
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto = tree.nodeData(node).node_and_node[0];
        const body = tree.nodeData(node).node_and_node[1];

        var buf: [1]Ast.Node.Index = undefined;
        const fn_proto = tree.fullFnProto(&buf, proto) orelse continue;
        const is_construct = if (fn_proto.name_token) |name_token|
            std.ascii.findIgnoreCase(tree.tokenSlice(name_token), "construct") != null
        else
            false;

        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        const allocs = allocatesFromCache(tree, first, last);
        if (allocs) allocating = true;
        if (allocs or is_construct) try collectMentions(rule_arena, tree, first, last, &handled);
        // `item.* = .{ ... }` in an allocating function rewrites every field,
        // defaults included, on every allocation.
        if (allocs and assignsWholeObject(tree, first, last)) whole_object_reset = true;
    }
    if (!allocating) return null;

    var i: Ast.TokenIndex = 0;
    while (i < tree.tokens.len) : (i += 1) {
        if (tree.tokenTag(i) != .identifier or !std.mem.eql(u8, tree.tokenSlice(i), "Cache")) continue;
        if (i + 1 >= tree.tokens.len or tree.tokenTag(i + 1) != .l_paren) continue;
        const close = matchingParen(tree, i + 1) orelse continue;
        try collectMentions(rule_arena, tree, i, close, &handled);
    }

    if (whole_object_reset or typeIsDocumentedReuseSafe(tree)) return null;

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    var root_buf: [2]Ast.Node.Index = undefined;
    const root = tree.fullContainerDecl(&root_buf, .root) orelse return null;
    for (root.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        const name_token = field.ast.main_token;
        if (handled.contains(tree.tokenSlice(name_token))) continue;
        if (hasMarker(tree, tree.firstToken(member))) continue;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, name_token),
            .end = .endOfToken(tree, name_token),
            .message = try session_arena.print(
                "field '{s}' of a slab-cached type is not mentioned by the allocating function or constructor; " ++
                    "a reused slot keeps the previous occupant's value. Reset it, or document why that is safe " ++
                    "with a `{s}` doc comment",
                .{ tree.tokenSlice(name_token), marker },
            ),
        });
    }

    return if (lint_problems.items.len > 0) try .init(
        doc.file_id,
        lint_problems.items,
    ) else null;
}

/// True if `[first, last]` contains `<...cache...>.allocate(` or
/// `.allocateMany(`.
fn allocatesFromCache(tree: Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    var i = first;
    while (i <= last) : (i += 1) {
        if (tree.tokenTag(i) != .identifier) continue;
        const text = tree.tokenSlice(i);
        if (!std.mem.eql(u8, text, "allocate") and !std.mem.eql(u8, text, "allocateMany")) continue;
        if (i == 0 or tree.tokenTag(i - 1) != .period) continue;
        var back: u32 = 1;
        while (back <= 6 and i >= back + 1) : (back += 1) {
            const t = i - 1 - back;
            if (tree.tokenTag(t) == .identifier and std.ascii.findIgnoreCase(tree.tokenSlice(t), "cache") != null) return true;
        }
    }
    return false;
}

/// True if `[first, last]` contains `<expr>.* = ` (whole-object assignment).
fn assignsWholeObject(tree: Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    var i = first;
    while (i < last) : (i += 1) {
        if (tree.tokenTag(i) == .period_asterisk and tree.tokenTag(i + 1) == .equal) return true;
    }
    return false;
}

/// Records every `.name` in `[first, last]`.
fn collectMentions(
    arena: std.mem.Allocator,
    tree: Ast,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    handled: *std.StringHashMapUnmanaged(void),
) !void {
    var i = first;
    while (i < last) : (i += 1) {
        if (tree.tokenTag(i) != .period) continue;
        switch (tree.tokenTag(i + 1)) {
            .identifier => try handled.put(arena, tree.tokenSlice(i + 1), {}),
            else => {},
        }
    }
}

fn matchingParen(tree: Ast, open: Ast.TokenIndex) ?Ast.TokenIndex {
    var depth: usize = 0;
    var i = open;
    while (i < tree.tokens.len) : (i += 1) {
        switch (tree.tokenTag(i)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// True if the file's `const T = @This();` carries a `slab-reuse-ok:` doc
/// comment: the whole type is reuse-safe for a stated reason (for example every
/// field is required and the only writers assign the whole struct).
fn typeIsDocumentedReuseSafe(tree: Ast) bool {
    var i: Ast.TokenIndex = 0;
    while (i + 3 < tree.tokens.len) : (i += 1) {
        if (tree.tokenTag(i) != .keyword_const) continue;
        if (tree.tokenTag(i + 3) != .builtin or !std.mem.eql(u8, tree.tokenSlice(i + 3), "@This")) continue;
        return hasMarker(tree, if (i > 0 and tree.tokenTag(i - 1) == .keyword_pub) i - 1 else i);
    }
    return false;
}

/// True if a doc comment directly above the token mentions the marker.
fn hasMarker(tree: Ast, first_token: Ast.TokenIndex) bool {
    var i = first_token;
    while (i > 0 and tree.tokenTag(i - 1) == .doc_comment) : (i -= 1) {
        if (std.mem.find(u8, tree.tokenSlice(i - 1), marker) != null) return true;
    }
    return false;
}

test "flags a field the allocating function never mentions" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Thing = @This();
        \\a: u32 = 0,
        \\b: u32 = 0,
        \\pub fn create() !*Thing {
        \\    const t = try globals.cache.allocate();
        \\    t.a = 1;
        \\    return t;
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "slab_reuse_field",
            .severity = .warning,
            .slice = "b",
            .message = "field 'b' of a slab-cached type is not mentioned by the allocating function or constructor; " ++
                "a reused slot keeps the previous occupant's value. Reset it, or document why that is safe " ++
                "with a `" ++ marker ++ "` doc comment",
        }},
    );
}

test "accepts fields reset, constructed, or documented" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Thing = @This();
        \\a: u32 = 0,
        \\lock: u32 = 0,
        \\/// slab-reuse-ok: only written before first use.
        \\c: u32 = 0,
        \\pub fn create() !*Thing {
        \\    const t = try globals.cache.allocate();
        \\    t.a = 1;
        \\    return t;
        \\}
        \\const globals = struct {
        \\    var cache: Cache(Thing, .{ .constructor = struct {
        \\        fn f(t: *Thing) void { t.lock = 0; }
        \\    }.f }) = undefined;
        \\};
    ,
        .{},
        Config{},
        &.{},
    );
}
