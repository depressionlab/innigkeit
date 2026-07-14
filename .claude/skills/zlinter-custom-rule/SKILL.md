---
description: Scaffold a zlinter custom rule as either a permanent addition to build/lints/, or a throwaway rule for a one-off AST-based mechanical refactor across the whole tree. Use when asked to write a custom lint rule, or when a refactor is "change every X to Y" / "find every place that does X" across many files. A zlinter rule with --fix is faster and more reliable than grep+sed for anything that needs real AST context (not just text matching).
---

# zlinter custom rules

zlinter (`zig-pkg/zlinter-0.0.1-*`, vendored via `build.zig.zon`) exposes a
small, stable API for writing a rule that walks the AST of every `.zig`
file in the project and reports (or fixes) problems. Two permanent rules
already exist as reference implementations:
`build/lints/truncate_unchecked_arithmetic.zig` and
`build/lints/ptr_from_int_undocumented.zig` — read one before writing
a new rule; this skill is the condensed version of what writing those
taught.

## When this beats grep+sed

Use a zlinter rule instead of a text-based find/replace when the
transform needs to know **what kind of AST node** something is, not just
what it looks like as text — e.g. "every `@truncate` wrapping a plain
arithmetic expression" (not every `@truncate`), "every top-level `pub fn`
missing a doc comment", "every `orelse unreachable` that isn't inside a
test block". If a `grep -P` pattern would need lookahead/lookbehind to
avoid false positives, it's an AST job.

## The shape of a rule

```zig
//! One-line summary of what this rule flags and why.

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return zlinter.rules.LintRule{
        .rule_id = "my_rule_name",
        .run = &run,
    };
}

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
    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple; // second element is {parent, prev_sibling, ...} if you need lineage

        // ... inspect tree.nodeTag(node), tree.nodeMainToken(node), etc. ...
        // append a zlinter.results.LintProblem to lint_problems when found
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(gpa, doc.path, try lint_problems.toOwnedSlice(gpa))
    else
        null;
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
```

## AST navigation cheat sheet (learned from the two real rules)

- **Walk every node**: `doc.nodeLineageIterator(root, gpa)` — yields
  `(node, connections)` tuples; `connections.parent` gives the parent
  node when you need context (e.g. "is this identifier inside a test
  block" — see `doc.isEnclosedInTestBlock(node)`, already provided).
- **Find a builtin call**: match
  `.builtin_call_two/_comma/.builtin_call/_comma` tags, then
  `std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@truncate")`
  (or whatever builtin). Get its arguments via
  `tree.builtinCallParams(&buffer, node)` (`buffer: [2]Ast.Node.Index`
  covers the two-arg forms; check `zlinter`'s own builtin rules for the
  general-arity version if you need more).
- **Inspect a binary expression's operator**: `tree.nodeTag(inner_node)`
  gives `.mul`/`.add`/`.sub`/`.shl` for plain arithmetic vs.
  `.mul_wrap`/`.add_wrap`/`.sub_wrap` for the explicitly-wrapping forms,
  `.mul_sat`/`.add_sat`/`.sub_sat` for saturating — see
  `.tools/zig-0.16.0/lib/std/zig/Ast.zig`'s `Node.Tag` doc comments for
  the full list with the exact source shape each one matches (`Grep -n
  "^\s*[a-z_]+,\s*$"` near the enum for a quick scan). **Warning:**
  structural pattern matching only sees one level — a parenthesized or
  nested expression needs walking `nodeData` yourself if you need to
  look inside operands.
- **Get a node/token's line and source text**: `tree.tokenLocation(0,
  token)` returns `{line, column, line_start, line_end}` (byte offsets);
  slice `tree.source[loc.line_start..loc.line_end]` for the raw line.
  Regular `//` comments are **not** tokens in the Ast (only `///` doc
  comments and `//!` container doc comments are) — if a rule needs to
  check for a nearby `//` comment (e.g. "is this call documented"), do a
  raw text scan of the surrounding line(s) via `tree.source`, the same
  way `ptr_from_int_undocumented.zig`'s `hasNearbyComment` does. Don't
  reach for zlinter's internal `comments.zig` tokenizer for this — it's
  built for the `zlinter-disable` directive parser, not general-purpose
  comment detection, and isn't part of the public API surface either.
- **Problem location**: `.start = .startOfNode(tree, node)`, `.end =
  .endOfNode(tree, node)` (or `.startOfToken`/`.endOfToken` for a single
  token) — these exist on `LintProblemLocation`.

## Autofix: the actual refactor mechanism

Set `.fix` on a `LintProblem` to make `--fix` apply it:

```zig
.fix = .{
    .start = start_byte_offset, // inclusive
    .end = end_byte_offset,     // exclusive
    .text = try gpa.dupe(u8, "replacement source text"), // "" to delete
},
```

This is a plain byte-range replacement — compute `start`/`end` from
`tree.tokenLocation`/`.startOfNode`/`.endOfNode` byte offsets, and
`text` is whatever source text should replace that range. Run:

```sh
zig build lint -- --rule my_rule_name --fix
```

**Back up first (commit or stash) — this rewrites files in place.** It
may take multiple runs to converge (each pass only fixes non-overlapping
problems found in that pass); run with `--fix` until it reports 0 fixes
applied. This is the fast path for exactly the kind of mechanical,
tree-wide rewrite that took hand-written `sed`/manual edits this session
(the `no_deprecated` fixes, the `orelse unreachable` ↔ `.?` convention
flip) — writing a 40-line rule with a `.fix` is very likely faster and
less error-prone than either for anything past a handful of call sites,
*if* the transform needs AST context to avoid false positives. For a
transform that's genuinely just text substitution with no ambiguity
(rename a single well-known symbol, no shadowing possible), plain
find/replace is still simpler — don't reach for this by default.

## Workflow for a one-off refactor (not a permanent rule)

1. Write the rule under `build/lints/_scratch_<name>.zig` (prefix
   makes it obviously temporary and easy to find/delete later).
2. Register it in `build/Lint.zig` temporarily:
   `builder.addRule(.{ .custom = .{ .name = "_scratch_<name>", .path =
   "build/lints/_scratch_<name>.zig" } }, .{});`
3. Run `zig build lint -- --rule _scratch_<name>` first with **no**
   `--fix` to sanity-check the problem count and a few reported
   locations look right before touching any files.
4. Run with `--fix` (repeat until 0 fixes applied).
5. `zig build check` (or the full `zig build verify` gate) to confirm
   nothing broke.
6. **Remove both the rule file and its `build/Lint.zig` registration** —
   it was scaffolding for one refactor, not a standing lint. Only keep a
   rule permanently if it's meant to catch *future* instances of the same
   pattern (in which case, drop the `_scratch_` prefix, give it a real
   name, and write it a doc comment + tests the way the two permanent
   rules have).

## Testing a rule (permanent or scratch)

```zig
test "flags the bad case" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  // bad code here
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "my_rule_name",
                .severity = .warning,
                .slice = "the exact source slice expected to be flagged",
                .message = "expected message",
            },
        },
    );
}
```

Pass `&.{}` as the expected-problems list for a "should NOT flag" case
(the escape-hatch/good-case test). See either permanent rule's test
block for the full pattern, including the `.off` severity test.

## Registering a permanent rule

In `build/Lint.zig`, alongside the builtins:

```zig
builder.addRule(.{ .custom = .{
    .name = "my_rule_name",
    .path = "build/lints/my_rule_name.zig",
} }, .{});
```
