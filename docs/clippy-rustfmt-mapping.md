# Clippy/rustfmt → zlinter mapping

Cross-reference of exiting rustfmt.toml settings and Cargo.toml
clippy lint config against zlinter's rule catalog, per their explicit
instruction to "integrate over time" — this is a living reference for
staging future lint-adoption rounds, not a one-shot task. Companion to
`docs/next-epoch-plan.md` §1 (which tracks the linter-adoption initiative's
overall status) and `docs/DESIGN.md` (which the actual style decisions
flow into).

**Key finding up front**: a first empirical test of the five
clippy-mapped zlinter builtins that looked like obvious wins
(`no_panic`, `no_todo`, `no_unused`, `no_swallow_error`, `no_undefined`)
turned up **1,030 combined warnings** — over 13x the size of the
existing `ptr_from_int_undocumented` backlog (76). This is not a "just
turn it on" set. See §3.

---

## 1. rustfmt.toml → zig fmt / zlinter

`zig fmt` is a single opinionated formatter with almost no configuration
surface (unlike rustfmt's many knobs) — most of these settings don't have
a lever to pull in Zig at all; they're either already true by construction
or not applicable to the language:

| rustfmt setting | Zig equivalent |
| --- | --- |
| `max_width = 100` | `zig fmt` doesn't wrap at a column width the same way; no lever. |
| `hard_tabs = true` | `zig fmt` always emits spaces (4-space indent); no lever — Zig has no tabs-vs-spaces setting. |
| `newline_style = "Unix"` | `zig fmt` always emits `\n`; already true by construction. |
| `reorder_imports`, `imports_granularity`, `group_imports = "StdExternalCrate"` | **Real match**: zlinter's `import_ordering` builtin (currently off). Zig's rough equivalent grouping would be `std`/`core`-style shared libs first, then named project modules (`innigkeit`, `architecture`), then relative-path imports — worth enabling and configuring to mirror `StdExternalCrate`'s intent. Not yet tried against this codebase; flagged as the strongest concrete next step from this table. |
| `reorder_modules`, `reorder_impl_items` | No direct Zig equivalent (Zig doesn't have Rust's `impl` blocks or a `mod` declaration order concept the same way) — not applicable. |
| `remove_nested_parens` | `zig fmt` doesn't rewrite redundant parens; no lever, and no zlinter builtin for it either. Possible custom-rule candidate (low priority — cosmetic only). |
| `edition`/`style_edition = "2024"` | Rust-edition-specific; not applicable. |
| `merge_derives` | No Zig equivalent (no `#[derive(...)]`). |
| `use_try_shorthand = false`, `use_field_init_shorthand = false` | Rust-syntax-specific stylistic choices; no Zig equivalent shape. |
| `force_explicit_abi = true` | Zig requires explicit calling convention only where it's ambiguous; not a comparable knob. |
| `unstable_features`, `format_macro_matchers`, `format_macro_bodies` | Rust-macro-specific; Zig has no macro system (comptime is not textual macros) — not applicable. |
| `format_code_in_doc_comments = true` | **Real, valuable idea, no existing rule.** Doc comments (`///`) containing Zig code blocks aren't currently checked for formatting or even for compiling. Good custom-rule candidate: extract fenced code blocks from doc comments and verify they parse (a full "compiles and is formatted" check is much more work — parsing is the cheap first step). |
| `normalize_comments`, `normalize_doc_attributes` | No Zig equivalent (no attribute macros on doc comments). |
| `wrap_comments = true` | zlinter has no comment-rewrapping rule; `zig fmt` doesn't touch comment prose. Custom-rule candidate is possible but low value — Innigkeit's comments are already generally short per `docs/DESIGN.md`'s density guidance ("only when non-obvious"), so wrapping long prose comments isn't a real problem here the way it might be elsewhere. |
| `hex_literal_case = "Upper"` | **Real, easy match.** Zig hex literals (`0xdeadBEEF`-style) have no enforced case; a simple custom rule scanning integer-literal tokens for mixed/lowercase hex digits and requiring uppercase would directly mirror this. Cheap, mechanical, good `--fix` candidate (see the `zlinter-custom-rule` skill). |

**Net takeaway**: rustfmt's settings are almost entirely either
inapplicable (Rust-syntax-specific) or already true by construction
(zig fmt has one style). The two genuinely portable ideas are
`import_ordering` (already exists as a zlinter builtin, just needs
enabling + config) and `hex_literal_case` (doesn't exist yet, a good,
narrow, cheap custom rule).

## 2. Named clippy lints (Cargo.toml) → zlinter

| clippy lint | Verdict |
| --- | --- |
| `unnecessary_cast`, `cast_lossless`, `cast_possible_truncation`, `cast_possible_wrap`, `cast_sign_loss` | Partially covered by `truncate_unchecked_arithmetic` (scoped to the highest-risk shape: `@truncate` of plain arithmetic). `@intCast` itself already has a *runtime* safety check built into the language (traps on truncation in safe modes) — Rust's `as` cast has no such guarantee, which is why clippy needs these lints and Zig needs them less. Not recommending a broader blanket `@intCast`/`@bitCast`/`@floatCast` sweep without a concrete new finding motivating it. |
| `dbg_macro` | **No existing rule — good custom-rule candidate.** Zig's nearest equivalent is a stray `std.debug.print`/scoped-log-at-debug-level call that looks like left-in debugging scaffolding rather than intentional logging (e.g., printing a raw value with no message, right before/after code that clearly isn't a logging call site). Needs careful scoping to avoid flagging Innigkeit's extensive, intentional debug logging — likely needs a heuristic (e.g., flag literal `std.debug.print` specifically, since the project's own logging goes through `innigkeit.debug.log.scoped`, and a stray raw `std.debug.print` is more likely to be scaffolding). |
| `deprecated_cfg_attr`, `separated_literal_suffix` | Rust-syntax-specific (`#[cfg_attr]`, numeric literal suffix spacing) — **not applicable**, no Zig equivalent construct exists. |
| `undocumented_unsafe_blocks` | Covered by `ptr_from_int_undocumented` (the "conjures a pointer from thin air" case) plus, as of 2026-07-09, two siblings covering the other two casts this row used to flag as future work: `ptrcast_undocumented` (`@ptrCast`) and `aligncast_undocumented` (`@alignCast`). Both built, tested, and registered in `build/Lint.zig`. **`aligncast_undocumented` done (82 → 0, same day)**: every site traced to its real alignment provenance (slab-cache configured alignment, page-aligned DMA/mmap buffers, `align(1)` no-op casts, intrusive `@fieldParentPtr` round-trips) rather than filled with generic comments — found and fixed two genuine bugs in the process (`filesystem/simple_fs.zig`'s `dir_buf` and `network/arp.zig`'s `out` buffers were declared with no explicit alignment despite being `@alignCast`ed to a higher-alignment type; fixed by declaring the real alignment and widening the parameter types to carry it structurally). **`ptrcast_undocumented` still open (252 remaining, down from 327 — some sites were shared `@ptrCast(@alignCast(...))` calls the aligncast pass already commented)**: left as its own future pass, same reasoning as before (over-large for one sitting, `.warning` severity, doesn't block CI). Inline `asm` (the third original candidate, ~42 sites) still has no rule — an AST builtin-call match doesn't apply to `asm` blocks, so it would need a different detection shape; not started. |
| `allow_attributes` | **No existing rule — good custom-rule candidate**, and a very direct structural match: Rust's `#[allow(...)]` overuse maps almost exactly onto zlinter's own `zlinter-disable`/`-next-line`/`-current-line` comment mechanism. A rule flagging a disable-comment with no trailing `- reason` (the syntax already supports one) would be cheap to write and enforce the same discipline this project already expects manually (every existing disable comment in the tree has a reason). |
| `ref_patterns` | Rust pattern-matching-specific (`ref x` bindings) — **not applicable**, Zig has no equivalent binding-mode concept. |
| `unwrap_used`, `expect_used` | **Does not translate — would fight this project's own convention.** Clippy discourages `.unwrap()`/`.expect()` because Rust programmers reach for them lazily instead of real error handling. Zig's bare `.?` is the *opposite* case: `docs/DESIGN.md` Part 1 explicitly prefers it for a provably-non-null optional, and this session already flipped house style to match zlinter's own `no_orelse_unreachable` default for exactly this reason. Porting `unwrap_used` would directly contradict a decision already made deliberately. Not recommended. |
| `panic`, `todo`, `unimplemented` | Map to zlinter's `no_panic`/`no_todo` builtins. **Measured, not a quick win** — see §3: `no_panic` alone is 117 findings, ~89% of them genuine kernel-runtime panics (not build-graph noise) needing real "should this be a propagated error instead" judgment, matching the scale of a dedicated review pass like `require_errdefer_dealloc`'s, not a one-line config flip. `no_todo` (163) almost entirely re-surfaces the TODOs just triaged in `docs/todo-review.md` — enabling it now would just be noise duplicating a review that already concluded most of them are legitimate deferred work. |
| `missing_errors_doc`, `future_not_send`, `module_name_repetitions`, `struct_field_names`, `cast_precision_loss`, `missing_panics_doc`, `wildcard_imports`, `too_many_lines` | All explicitly set to `"allow"` (off) — i.e. lints they don't want even in Rust. No corresponding zlinter rule should be enabled for these either; useful signal about actual taste, not just "port everything." |
| `unused_qualifications`, `rust_2018_idioms`, `trivial_casts`, `trivial_numeric_casts`, `unused_import_braces`, `unexpected_cfgs` | Rust-specific (edition idioms, `use` path style, `cfg` attribute system) — Zig has comptime `if`/build options instead of `cfg`, no implicit-prelude-vs-explicit-path distinction the way Rust's module system has, no import-brace syntax. **Not applicable.** |
| `unused_allocation` | Conceptually matches `docs/DESIGN.md` Part 7's own stated philosophy ("don't allocate where a bounded-lifetime stack/arena value works") — but detecting this generically requires real escape analysis (does this heap allocation actually outlive the function/syscall?), which is well beyond what AST-only pattern matching can do reliably. Flagged as *wanted in spirit*, not mechanically detectable with zlinter's current API — would need case-by-case human review, which is effectively what Phase 2/3's manual review already did for allocator call sites. |
| `dead_code` | Maps to `no_unused`. **Done (2026-07-09).** Re-investigated: the earlier "false positive" note below was wrong — every `const std = @import("std");`-shaped finding checked this pass turned out to be a genuinely dead import (confirmed by grepping the full file for the name; the earlier check apparently stopped at a comment/substring match). Enabled and all 78 findings resolved: 72 genuine dead declarations deleted (imports, a stale duplicate `spawnThreadEntry` in `user/root.zig` shadowed by the real one in `handlers/process.zig`, an entirely-unused `gic.zig` register-offset table duplicating info already in inline comments), 6 suppressed with reasoning (`const X = @This();` self-references in `build/`'s Capitalised type-files — real per `docs/DESIGN.md`'s own convention, just never referenced by name within the file itself) plus 3 in `ext4.zig` (`INCOMPAT_JOURNAL_DEV`/`META_BG`/`ENCRYPT` document specific incompat-feature bits that get rejected by *absence* from `SUPPORTED_INCOMPAT`, not by name — keeping the named constant is the point). |
| `unsafe_code` | Zig has no `unsafe` keyword — the closest conceptual match is exactly what `ptr_from_int_undocumented` (and a possible broader unsafe-cast rule, see above) already targets, not a 1:1 syntax mapping. |
| `deprecated`, `deprecated_in_future` | `no_deprecated` already fully adopted and at 0 findings (this session's earlier work). `deprecated_in_future` has no Zig equivalent (no forward-deprecation annotation mechanism). |
| `unused_must_use = "deny"` | Already structurally guaranteed by the Zig compiler itself — an error union can't be silently discarded without an explicit `_ = try foo()`-style acknowledgment. No rule needed; the language already enforces this at compile time, strictly stronger than a lint. |

## 3. Measured: the five "obvious" builtins are each their own review pass

Tested by temporarily enabling `no_panic`, `no_todo`, `no_unused`,
`no_swallow_error`, `no_undefined` against the full tree (not committed —
reverted after measuring):

| rule | findings | note |
| --- | --- | --- |
| `no_undefined` | 399 | `undefined` is pervasive, idiomatic Zig for "will be initialized before use" (buffers, staging arrays). The rule's own defaults already exclude common patterns (names ending in `memory`/`mem`/`buffer`/`buf`/`buff`); 399 remaining suggests this codebase's naming conventions don't fully match those defaults, not that 399 real problems exist. Needs config tuning (broader exclude list) before it's worth enabling, not a blanket "fix all 399." |
| `no_swallow_error` | 195 | `catch {}`/`catch unreachable`/`else \|_\| {}`/`else \|_\| unreachable`. Distinct from the `.?`/`orelse unreachable` question (that's optionals; this is errors) — `docs/DESIGN.md` Part 1's "fallible access must fail, not panic" suggests this rule is philosophically well-aligned, unlike `unwrap_used`. Real backlog, needs per-site review like `ptr_from_int_undocumented`, not a quick fix. |
| `no_todo` | 163 | Almost entirely re-surfaces `docs/todo-review.md`'s just-completed triage. Recommend **not** enabling until/unless the TODO backlog itself needs a standing lint gate (it doesn't right now — most are legitimate deferred work, confirmed this session). |
| `no_panic` | 121 (re-measured 2026-07-09) | **Investigated, declined for now.** The rule's only config knobs are `exclude_tests` and an exact-string `exclude_panic_with_content` allowlist — no name-pattern or call-site exemption. That's a real mismatch with this codebase's own documented style: `docs/DESIGN.md` Part 1 explicitly recommends `orelse @panic("why")` over `orelse unreachable` for a provably-non-null optional needing a message, so a meaningful fraction of the 121 sites are the *correct*, deliberately-chosen idiom this project's own style guide asks for, not a defect. Enabling would require either fighting that convention or suppressing a large fraction of sites one by one for no real gain. Revisit only if zlinter adds a richer exemption model (e.g. skip `@panic` used as the RHS of `orelse`). |
| `no_unused` | 78 (re-measured 2026-07-09) | **Done (2026-07-09) — see §2's `dead_code` row.** The earlier "false positive" claim in this table didn't survive a fresh check; re-verified every finding by grepping the whole file for the declared name, and all 78 were genuine (72 fixed by deletion, 6 suppressed as a real, bounded exception). No config tuning was needed. |
| `no_undefined` | 399 (re-measured 2026-07-09, unchanged) | **Investigated, declined for now.** The rule's `exclude_var_decl_name_ends_with`/`exclude_var_decl_name_equals` config only matches *local* `var` declarations by name — it has no exemption for `= undefined` on a `struct` field, which is the dominant pattern behind this count (IDT/GDT entries built field-by-field, cache/backing arrays sized then filled, `Idt.zig`'s three-field split-address encoding). Those are correct, idiomatic kernel code, not bugs — a scratch buffer or a field about to be immediately overwritten doesn't need a "why" comment any more than `orelse @panic` does. Broadening config to cover field-level exemptions isn't possible with this rule's current option set (checked `no_undefined.zig`'s `run()`: the name-based skip logic only fires when `tree.fullVarDecl` matches, which fields never do). Revisit if zlinter adds a field-level exemption; until then, 399 site-by-site suppressions would be mostly noise, not signal. |
| `require_fmt` | 1 (fixed) | Unrelated to the batch — `AddressSpace.zig` drifted from an earlier comment edit in this session. Fixed with `zig fmt`, already committed. |

**Recommendation**: none of these five are a "just turn it on" addition —
each is realistically its own future review pass, comparable in scope to
`require_errdefer_dealloc`'s or `ptr_from_int_undocumented`'s. Proposed
staging, cheapest/safest first:

1. **Done (2026-07-09).** `import_ordering` (§1) — enabled, 277 findings,
   resolved entirely via `--fix` (two convergence passes, 847+61 fixes).
2. **Done (2026-07-09).** `hex_literal_case` custom rule (§1) — added,
   206 findings, resolved entirely via `--fix` (one pass).
3. **Done (2026-07-09).** `undocumented_zlinter_disable` custom rule
   (the `allow_attributes` match, §2) — added. Caught two real bugs in
   its own first draft (needed to exclude `///`/`//!` doc comments, and
   accept a reason given on the preceding comment line, matching this
   project's own convention at the three real sites that existed) — 0
   findings once corrected, confirming the gap really was small.
4. **Done (2026-07-09).** `no_swallow_error` — enabled, 195 findings,
   worked through in six clusters (drivers/+user/, x64+memory/, remaining
   kernel scattered sites, library/build/tools/sdk/, apps/), each site
   given a real verified justification rather than filler: provably-safe
   patterns documented (fixed-capacity name buffers, port-range casts,
   asserted stack/array bounds), genuine gaps fixed (several silently-
   dropped cleanup/logging paths, two `unreachable`→honest-`@panic`
   conversions for real OOM paths, a debug assert closing a latent
   quantum-cache overflow in `Arena.zig`), and two false positives
   (a comptime type-selector `if`/`else`, a type-level-only `catch` inside
   `@TypeOf`) identified and suppressed with reasoning. See
   `docs/next-epoch-plan.md`'s session log for full per-cluster detail.
5. **Done (2026-07-09).** `no_unused` — investigated (the earlier
   false-positive claim didn't hold up on re-check), enabled, all 78
   findings resolved (72 deleted, 6 suppressed with reasoning). See §2's
   `dead_code` row.
6. `no_panic`, `no_undefined` — investigated and **declined for now**
   (not deferred pending more work — a considered "no", see their rows
   above): both conflict with idioms `docs/DESIGN.md` itself recommends
   (`orelse @panic("why")`; struct-field `= undefined` before
   construction) and neither rule's config can distinguish those from a
   real defect. Revisit only if zlinter's config model grows a matching
   exemption.
7. `no_todo` — hold indefinitely unless the TODO backlog itself starts
   drifting again; a standing lint for something just freshly triaged
   would be pure noise right now.

## 4. Clippy's lint *groups* (`all`/`pedantic`/`correctness`/`perf`/`style`/`suspicious`/`complexity`/`nursery`)

These are broad categories of dozens-to-hundreds of individual lints
each, not enumerable one-by-one here with confidence from memory alone —
doing that credibly needs pulling the actual clippy lint list (e.g. from
`cargo clippy --help` or the published lint index) rather than guessing.
Themes worth naming without the full enumeration:

- **`correctness`/`suspicious`**: these are clippy's highest-confidence
  "this is probably a real bug" lints (self-assignment, always-true
  conditions, etc.). zlinter's `no_literal_only_bool_expression`
  (already enabled) is exactly this category's shape. Worth a future
  pass specifically hunting for zlinter-builtin or custom-rule matches
  to clippy's `correctness` group, since that's the highest-value
  category to port.
- **`perf`**: mostly Rust-ownership/allocation-specific (unnecessary
  `.clone()`, `Vec` vs slice, iterator chain fusion) — much of this
  doesn't have a Zig shape at all (no ownership/borrow checker,
  different allocation model). `unused_allocation` (§2) is the one perf
  idea that translates conceptually.
- **`style`/`complexity`**: mostly Rust-idiom-specific (redundant
  closures, `if let` vs `match`, needless `return`) — low expected
  overlap with Zig's much smaller idiom surface.
- **`pedantic`/`nursery`**: explicitly opt-in, higher-noise clippy tiers
  even within Rust; not a priority to mine before the `all`/`correctness`
  tier is actually cross-referenced.

**Next step for this section specifically**: pull the real clippy lint
list (not from training-data memory, which risks fabricating lint names
that don't exist) before claiming a specific `correctness`/`suspicious`
lint maps to a specific Zig pattern. Flagged as follow-up work, not done
in this pass.
