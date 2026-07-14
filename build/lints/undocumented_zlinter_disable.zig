//! Flags a `zlinter-disable`/`zlinter-disable-next-line`/
//! `zlinter-disable-current-line` comment with no trailing `- reason`.
//!
//! **Good:** `// zlinter-disable-next-line require_fmt - generated file`
//!
//! **Bad:** `// zlinter-disable-next-line require_fmt`
const std = @import("std");
const zlinter = @import("zlinter");

pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return .{
        .rule_id = "undocumented_zlinter_disable",
        .run = &run,
    };
}

const MESSAGE = "`zlinter-disable` with no reason! add \" - why this is safe\" after the rule name(s), or a comment on the line above";

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

    const source = doc.handle.tree.source;

    var prev_line: []const u8 = "";
    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        defer {
            prev_line = line;
            line_start = line_end + 1;
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        // Must be a plain `//` comment, not a doc comment (`///`/`//!`) or a
        // string literal that happens to contain the words.
        if (!std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "///") or
            std.mem.startsWith(u8, trimmed, "//!")) continue;

        const comment_at = std.mem.find(u8, line, "zlinter-disable") orelse continue;
        if (std.mem.findPos(u8, line, comment_at, " - ") != null) continue;

        // Accept a reason given as a plain comment on the preceding line too.
        const prev_trimmed = std.mem.trim(u8, prev_line, " \t");
        if (std.mem.startsWith(u8, prev_trimmed, "//") and
            !std.mem.startsWith(u8, prev_trimmed, "///") and
            !std.mem.startsWith(u8, prev_trimmed, "//!")) continue;

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .{ .byte_offset = line_start + comment_at },
            .end = .{ .byte_offset = line_end - 1 },
            .message = try gpa.dupe(u8, MESSAGE),
        });
    }

    return if (lint_problems.items.len > 0) try .init(
        gpa,
        doc.path,
        try lint_problems.toOwnedSlice(gpa),
    ) else null;
}

test "flags a disable comment with no reason" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  // zlinter-disable-next-line require_fmt
        \\  const a = 1;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "undocumented_zlinter_disable",
                .severity = .warning,
                .slice = "zlinter-disable-next-line require_fmt",
                .message = MESSAGE,
            },
        },
    );
}

test "allows a disable comment with a reason" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  // zlinter-disable-next-line require_fmt - generated file
        \\  const a = 1;
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
        \\  // zlinter-disable-next-line require_fmt
        \\  const a = 1;
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}
