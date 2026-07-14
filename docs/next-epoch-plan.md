# Next epoch: tooling, structure, and a long-range design plan

Captured 2026-07-08 right after Phase 3
(the repo-wide style/efficiency/security review, Tiers 1-4) closed out.
Six initiatives, each at a different level of readiness — some have enough
research behind them to stage immediately, others are intentionally left
open pending answers to the open questions listed
under each. This doc is the durable home for all of it; `docs/roadmap.md`
links here and tracks top-level status.

Nothing in this doc has started yet except the linter research in
§1 — everything else is capture + open questions, not a committed plan.

**Standing instruction (interview, 2026-07-08): sweep TODOs opportunistically.**
Whenever any stage of this plan already has a reason to touch a file that
carries a `TODO` comment, resolve it as part of that stage rather than
leaving it for a dedicated pass — don't go looking for TODOs outside a
stage's own file list, but don't skip one that's sitting in code already
being edited either. First instance: `build/App.zig`'s `sanitize_c` TODO,
fixed incidentally during §2's itest reorg (see §3).

---

## 1. Linter selection: zlint vs. zwanzig vs. zlinter

**Ongoing (2026-07-09)**: `docs/clippy-rustfmt-mapping.md` is the
living cross-reference of the existing rustfmt.toml/
Cargo.toml clippy config against zlinter's rule catalog — this is not a
one-shot task, and that doc records both the mapping and a first
empirical test (five clippy-mapped builtins that looked like obvious
wins turned out to be 1,030 combined findings, each realistically its
own future review pass, not a quick config flip). Read it before
starting the next lint-adoption round.

### What each one actually is (researched 2026-07-08)

| | **zlint** (DonIsaac) | **zwanzig** (forketyfork) | **zlinter** (KurtWagner) |
|---|---|---|---|
| Rules | 14 | 13 AST/token + 8 CFG/ZIR-backed = ~21 | 28 |
| Architecture | Custom semantic analyzer, Oxc-inspired, fully separate from the Zig compiler | Fast AST/token rules + **CFG-driven, ZIR-backed** type-aware checkers (path-sensitive) | Zig std-lib AST analysis, build.zig-native |
| Custom rules | Not apparent from docs | Not documented | **Yes** — user-provided `.zig` rule files, plus an AST explorer tool |
| Build integration | Standalone CLI | Standalone CLI (`--do`/`--skip` filtering) | `zig build lint`, dependency-based, per-directory `.zon` overrides, inline disable comments |
| Zig version support | Unspecified (recent) | Unspecified (recent) | **0.14.x through 0.16.x + master** |
| Maturity signal | 291 stars, 437 commits, v0.9.0 (Jul 2026) | 26 stars, 452 commits, v0.14.0 (Jun 2026) | 84 stars, 635 commits |
| Autofix | Not mentioned | Not mentioned | Experimental |

### Rule inventories (for the "port missing rules" ask)

**zlint's 14**: `avoid-as`, `case-convention`, `empty-file`, `homeless-try`,
`line-length`, `must-return-ref`, `no-catch-return`, `no-return-try`,
`no-unresolved`, `returned-stack-reference`, `suppressed-errors`,
`unsafe-undefined`, `unused-decls`, `useless-error-return`.

**zwanzig's ~21**: AST/token — `dupe-import`, `todo`, `file-as-struct`,
`unused-decl`, `unused-parameter`, `unreachable-code`, `empty-defer`,
`empty-errdefer`, `shadowed-variable`, `sentinel-alloc`,
`identifier-style`, `deinit-lifecycle`. CFG/ZIR-backed — `unreachable-code`
(constant-condition), `optional-unwrap` (bare `.?`), `empty-catch`,
`swallowed-error`, **`store-violations`** (double-free / leak /
use-after-free), **`stack-escape`** (stack-backed value escapes via
return/async/thread capture), `divide-by-zero` (path-sensitive),
**`slice-bounds`** (OOB access).

**zlinter's 28**: naming — `declaration_naming`, `field_naming`,
`function_naming`, `file_naming`. Quality — `no_unused`, `no_deprecated`,
`no_todo`, `no_panic`, `no_comment_out_code`. Error handling —
`no_swallow_error`, `no_orelse_unreachable`, `require_errdefer_dealloc`,
`no_inferred_error_unions`. Safety/patterns — `no_unsafe_undefined`,
`no_empty_block`, `no_global_vars`, `no_hidden_allocations`,
`no_literal_args`, `no_redundant_comptime`. Structure — `require_braces`,
`require_exhaustive_enum_switch`, `require_labeled_continue`,
`switch_case_ordering`, `field_ordering`, `import_ordering`,
`max_positional_args`, `require_doc_comment`, `require_fmt`,
`no_literal_only_bool_expression`.

### Gap analysis: what zlinter is missing that zlint has (zwanzig excluded, see below)

Cross-referencing zlinter's 28 against zlint's 14, the following look
like **real gaps worth porting as custom zlinter rules**:

0. **`no_bare_optional_unwrap` (custom, drafted)** — not a gap but an
   active conflict: zlinter's own built-in `no_orelse_unreachable` rule
   prefers `.?` over `orelse unreachable`, the exact opposite of
   `docs/DESIGN.md`'s house rule. Drafted as a custom rule (see below);
   must ship disabling zlinter's built-in rule and enabling this one, not
   as an optional nice-to-have.
1. **`returned-stack-reference` (zlint)** — a stack-backed value escaping
   via return; directly on-target for a kernel (this project has spent
   this entire review hunting exactly this bug class by hand —
   `.claude/rules/*.md` document several near-misses). Highest-value
   single port candidate now that zwanzig's own `stack-escape` (a deeper,
   CFG-based version of the same idea) is off the table for now — see
   below.
2. **`empty-file` (zlint)** — this review found three dead/empty files by
   hand this session alone (`library/core/queue.zig`,
   `build/QEMUProfiler.zig`, and noted-but-not-deleted
   `build/Initfs.zig`/`library/filesystem/ext.zig`). A rule that catches
   this automatically would have saved real review time.
3. **`no-return-try` (zlint)** — flags `return try foo()`, a common Zig
   idiom that adds a redundant error-trace frame. Efficiency-relevant
   per `docs/DESIGN.md` Part 7.
4. **`homeless-try` / `must-return-ref` / `no-catch-return` /
   `useless-error-return` / `avoid-as` / `line-length` / `no-unresolved`
   / `suppressed-errors` (zlint)** — lower-priority; worth a closer read
   of each rule's actual doc before deciding, since several may already
   be covered by zlinter's existing 28 under different names (e.g.
   `suppressed-errors` vs. `no_swallow_error`).

### Recommendation

Adopt **zlinter** as the base (matches the existing stated
preference; best build.zig-native integration story for a project whose
own `build/` is already this bespoke; broadest Zig version support;
genuine custom-rule support to encode Innigkeit's own house style
directly, including the Part 2/Part 4 mechanical recipes in
`docs/DESIGN.md`), starting with the zlint-gap ports above.

### zlinter static compatibility check (2026-07-08) — good sign, actual build still needs a separate go-ahead

Cloned zlinter to a scratch directory and read it statically (did **not**
run `zig build` against it — same reasoning as zwanzig: executing an
unverified external repo's `build.zig` needs its own explicit
per-repo go-ahead, not a blanket one from "keep going" on the broader
plan). Two things checked, both positive, neither conclusive without an
actual build:

- `src/lib/version.zig` explicitly enumerates and branches on
  **Zig 0.14/0.15/0.16/0.17**, `@compileError`ing on anything else — a
  real, maintained multi-version compatibility story, not just a single
  `minimum_zig_version` floor the way zwanzig had. Meaningfully stronger
  signal than zwanzig's static evidence.
- Grepped for every API that broke zwanzig's build (`std.fs.cwd()`,
  `GeneralPurposeAllocator(`, `std.process.argsAlloc(`, `writer.any()`,
  `std.io.getStdOut`/`getStdErr`) — **zero matches anywhere** in
  zlinter's `src/`, `build.zig`, or `build_rules.zig`. Its
  `std.zon.parse.fromSliceAlloc` call sites already match this repo's
  0.16.0 signature exactly (5 args: `T, gpa, source, diag, options`),
  unlike zwanzig's mismatched call shape.

**Next step, needs a separate explicit go-ahead** (same protocol as
zwanzig): actually run `zig build`/`zig build test` against the cloned
zlinter repo to confirm it compiles and its own test suite passes before
committing it as a `build.zig.zon` dependency.

### Critical finding: zlinter's own `no_orelse_unreachable` rule directly contradicts Innigkeit's house style — must be disabled, not just configured

While reading zlinter's built-in rules to refine the gap analysis above,
found that `src/rules/no_orelse_unreachable.zig` is not a gap at all — it's
an **active conflict**. Its own doc comment: "Enforces use of optional
unwrap shorthand `.?` instead of `orelse unreachable`." This is the exact
opposite of `docs/DESIGN.md` Part 1's explicit rule ("Never bare `.?` —
write `orelse unreachable`... Remove language footguns at the source"),
which this review's own Stage 4 recipe (`docs/DESIGN.md` Part 4.A) already
mechanically swept once across 98 sites in 36 files (patch 29, prior
session). If zlinter's default rule set were adopted as-is, it would
actively flag every one of those 98 already-correct sites as a violation.

**Action taken**: drafted a custom Innigkeit rule,
`no_bare_optional_unwrap.zig` (in the scratchpad, not yet committed to the
repo — zlinter isn't wired in as a dependency yet), doing the exact
inverse check: walk the AST for `.unwrap_optional` nodes (the `.?`
operator's tag in `std.zig.Ast.Node.Tag`) and flag every one. The
AST-traversal logic itself — the only genuinely novel/risky part — was
verified standalone against this repo's own Zig 0.16.0 toolchain with a
throwaway `zig run` harness before being wrapped in zlinter's rule API
shape (confirmed via two real example rules,
`no_todo.zig`/`no_orelse_unreachable.zig`, read in full to learn the
`Config`/`buildRule`/`run` pattern and the `zlinter.testing.testRunRule`
test harness): 6 cases (bare `.?`, `orelse unreachable`, `orelse <value>`,
chained `.?.c.?`, `.?` inside an expression, an `if |x| ... else
unreachable` capture) all resolved correctly. The zlinter-API-specific
parts of the drafted rule (exact `.slice` boundaries, whether
`testRunRule`'s contract matches what's written) are **not yet verified**
— that requires the same actual-build go-ahead as above, since zlinter
isn't buildable in this environment without it.

**When zlinter is actually added as a dependency**: this project's config
must explicitly disable zlinter's built-in `no_orelse_unreachable` and
enable this custom rule instead — silently accepting zlinter's defaults
here would be a real, mechanical regression against an already-established
and previously-enforced house rule.

### zwanzig: spiked, found not viable to adopt right now (interview decision + feasibility spike, both 2026-07-08)

zwanzig's rule set (`store-violations` — double-free/leak/UAF via CFG
analysis; `stack-escape`; `slice-bounds` — path-sensitive OOB access;
`optional-unwrap` — bare `.?` detection, which would directly automate an
already-documented `docs/DESIGN.md` house rule; `dupe-import`;
`deinit-lifecycle`) was the most kernel-relevant of the three linters by
far — no other Zig linter does CFG-based double-free/UAF/OOB detection.
The project owner asked to spike feasibility of the three deepest checks
before committing to a port, given they're both the highest security
value and the hardest.

**Static read (no execution)**: zwanzig's `src/` is genuinely modular —
`zir/`, `cfg/`, `engine/`, `checkers/`, `analysis/` are separate
directories, plus a `lib.zig` ("library exports") distinct from
`main.zig`/`cli/`. This meant the realistic integration path was never
"rewrite the checker logic against zlinter's AST-only model" (infeasible
without reimplementing a CFG/ZIR builder inside zlinter) but "depend on
zwanzig as a library for the 3 deep checks, run zlinter for everything
else." `src/zir/bridge.zig`'s `ZirBridge` is built on
**`std.zig.Zir`/`AstGen`/`Ast`** — the compiler **frontend**'s own
std-lib modules (same ones `zls` uses), not deep internals
(`Sema`/`InternPool`/`Air`) — a meaningfully more stable surface, and
this repo's own Zig 0.16.0 toolchain ships both modules.

**Actual build attempt (project owner approved running `zig build`
against the cloned repo)**: does **not** build clean against 0.16.0.

Cloned zwanzig to a scratch directory and ran `zig build` against this
repo's vendored Zig 0.16.0 toolchain. Hit **six consecutive std-library
API-incompatibility errors**, patched one at a time to see how deep the
gap goes, all of them in `build.zig`'s own config-time glue and
`src/main.zig`/`src/cli/run.zig`'s bootstrapping path — **never reached
the actual ZIR/checker analysis code** (`src/zir/`, `src/checkers/`,
`src/engine/`) before stopping:

1. `build.zig`: `std.fs.cwd()` → removed, needs `std.Io.Dir.cwd()` (×2 call sites)
2. `std.zon.parse.fromSlice` → signature/behavior changed (a struct with a
   slice field now requires an allocator-aware parse path)
3. `src/cli/run.zig`: `std.heap.GeneralPurposeAllocator` → renamed to
   `std.heap.DebugAllocator`
4. `src/cli/run.zig`: `std.process.argsAlloc` → removed/replaced (not
   pursued further)

Each fix was mechanical and correct in isolation (confirmed by getting
further on each retry), but they kept surfacing one after another,
strictly in the CLI/build-harness layer — the actual question this spike
was meant to answer (does `std.zig.Zir`/`AstGen`-based analysis work
under 0.16?) is **still unresolved**, because the porting burden in the
outer layers alone is clearly substantial (a real, multi-file port, not
a quick patch) and continuing to push through it would mean doing
zwanzig's entire 0.15.2→0.16.0 CLI port as a side effect of a spike,
which is out of proportion to "check feasibility."

**Verdict: not viable to adopt as-is right now.** Either it needs its own
tracked fork-and-port effort (real work, unscoped, and someone else's
upstream project to diverge from), or this waits until zwanzig itself
ships 0.16.0 support. **Recommendation: drop zwanzig from the immediate
linter plan.** Proceed with zlinter alone for now; revisit zwanzig
specifically if/when it publishes 0.16.0 compatibility, since the
architectural case for it (separate `lib.zig`, ZIR access via the
frontend-stable `std.zig.Zir`/`AstGen` rather than deep compiler
internals) was and remains sound — it's a version-timing problem, not a
design problem.

### Open questions (remaining)

- Should zlint's `case-convention`/`avoid-as`/etc. be read rule-by-rule
  for exact semantics before deciding "gap" vs. "already covered," or is
  the ranking in §1 good enough to start from?
- Revisit zwanzig once it ships 0.16.0 support (check periodically, or
  wait for the project owner to flag it) — the architectural case for it
  remains sound, only the version timing failed.

### Resolved

- **Custom rule location**: `build/lints/` (registered in
  `build/Lint.zig` alongside the builtins, `.custom = .{ .name, .path }`
  per zlinter's own API). Not a separate `tools/lint/` subsystem — these
  are two small, focused rule files, not a reviewed tool binary.
- **`no_bare_optional_unwrap` vs. zlinter's `no_orelse_unreachable`**:
  superseded, not shipped. The existing 2026-07-08 decision was to
  flip `docs/DESIGN.md`'s house convention to match zlinter's default
  (prefer bare `.?`) rather than fight it with a custom counter-rule — see
  the session log below and `docs/DESIGN.md` Part 1.

---

## 2. Repository reorganization

### Current pain points (confirmed by direct inspection 2026-07-08)

- **`apps/`** mixes real, user-facing sample apps (`calculator`, `doom`,
  `shell`, `wm`, `gfx_demo`, ...) with integration-test *fixture* apps
  (`itest_illegal_instruction`, `itest_spawn_wait` — both already flagged
  `test_only` in `build/AppDescription.zig` and never shipped in the
  release kernel's initfs). 17 entries in one flat directory today, and
  every new integration test (`docs/test-harness-plan.md`'s deferred
  TH-2/4/5) adds another fixture app to the same flat list.
- **`docs/`** is already 15 files flat, several of which are
  stage-tracking plans of finite lifespan (`phase2-review-plan.md`,
  `phase3-review-plan.md`) sitting alongside durable reference docs
  (`DESIGN.md`, `syscall-abi.md`) with no structural distinction between
  the two.
- **`.vscode/`** has `extensions.json` + `settings.json` only — no
  `launch.json`, so there's no one-click CodeLLDB attach/launch flow
  despite `.gdbinit`/`.lldbinit` already existing at the repo root for
  the equivalent GDB/LLDB CLI flow (`CLAUDE.md`'s Debugging section).
- **`flake.nix`** already exists (dev shell only: zig/zls/gcc/qemu/pkg-config
  via `zig-overlay` + `nixpkgs-unstable`) — a real starting point for §4's
  NixOS-inspired ambitions, not a green field.

### Draft target shape

- `apps/` keeps real sample/demo apps only.
- **Done (2026-07-08): test-fixture apps moved to `testing/fixtures/`**,
  colocating with the existing
  `src/innigkeit/testing/{smp,integration}.test.zig` kernel-side harness —
  one place for all test infrastructure, kernel-side and userspace,
  rather than a new top-level `itests/` or nesting under `apps/`.
  `apps/{itest_illegal_instruction,itest_spawn_wait}` → `testing/fixtures/`
  via `git mv`. Needed a real build-graph change, not just the move:
  `AppDescription` gained a `root_dir: []const u8 = "apps"` field
  (`build/AppDescription.zig`); `App.zig`'s `resolveApp` uses
  `description.root_dir` instead of a hardcoded `"apps"` for the
  `main.zig` source path, and carries `root_dir` through onto the
  resolved `App` struct; `Kernel.zig::buildInitfs` had its own *second*
  hardcoded `"apps"` for the codesign manifest path (a separate bug this
  reorg would have silently broken had it not been caught by the verify
  gate — `zig build verify` failed with `FileNotFound` on the old
  manifest path on the first attempt) — fixed to read
  `entry.value_ptr.root_dir` too. `apps/root.zig`'s two fixture entries
  now declare `.root_dir = "testing/fixtures"`. Verify gate: x64 146/146,
  arm 103/103 (14 skipped) — unchanged, confirming the fixture apps still
  build/sign/embed correctly from the new location and the
  integration tests that spawn them by name (unaffected — they reference
  `itest_spawn_wait`/`itest_illegal_instruction` as initfs entry names,
  never a filesystem path) still pass.
- **Declined (2026-07-08): no `docs/plans/` subdirectory split.**
  Reconsidered against the actual scale of the problem: `docs/` is 16
  flat files, all reasonably named — genuinely not crowded the way
  `apps/` was (17 entries visibly mixing real demo apps with test-only
  fixtures, a real day-to-day confusion). Moving even just the two
  fully-complete plans (`phase2-review-plan.md`, `phase3-review-plan.md`)
  would touch 35 cross-references across 12 files (`docs/DESIGN.md`,
  `docs/roadmap.md`, 9 `.claude/rules/*.md` files, and the plan docs
  themselves) for a purely cosmetic reorganization with no build-graph
  verification catching a missed/broken link. The
  concretely-stated pain point ("especially now with itests") is already
  fixed; this was this plan's own speculative addition, not something
  asked for beyond general "reorganize" sentiment — declining it here
  rather than doing the churn is the surgical-changes call per
  `docs/DESIGN.md`/karpathy-guidelines. Revisit if `docs/` actually grows
  past this point, or if the project owner asks for it directly.
- **Done (2026-07-08): `.vscode/launch.json` added.** Four CodeLLDB
  `"request": "custom"` configs (x64/arm kernel, x64/arm test kernel),
  each running `target create <path>` + `gdb-remote localhost:1234` —
  the CodeLLDB-idiomatic equivalent of `.gdbinit`/`.lldbinit`'s own two
  commands (`file <path>` + `target remote`/`gdb-remote localhost:1234`),
  so all three debugger entry points (raw gdb, raw lldb, VS Code) target
  the same four kernel/arch combinations without inventing a new
  convention. `vadimcn.vscode-lldb` added to `.vscode/extensions.json`'s
  recommendations.

### Repo reorg stage 1: closed out

The two concretely-scoped pain points (itests crowding `apps/`, no
CodeLLDB `launch.json`) are both done. The `docs/plans/` split was
declined (see above).

### Repo reorg stage 2: fresh full structural audit (2026-07-08)

Surveyed the whole tree (top-level layout, `docs/`, `.claude/`, `sdk/`,
`library/`, `scripts/`, root-level config files) rather than assuming
stage 1's two fixes were the whole story. Two real findings, both fixed:

- **Root `DESIGN.md` was a dead stub** — 24 lines of very early,
  informal project notes ("uhhhh hhh", a stale `- [ ]` checklist:
  "library dependency loops?", "`inline for`"), entirely superseded by
  the real, binding `docs/DESIGN.md` (159 lines, the actual style/
  security guide `CLAUDE.md` and every review stage treats as
  canonical). Confirmed zero real references anywhere in the repo
  (one prose mention in `.claude/rules/memory.md` was ambiguous about
  which `DESIGN.md` it meant — fixed to say `docs/DESIGN.md` explicitly).
  Two files with the same name, one dead, at different tree depths is
  exactly the kind of thing that reads as disorganized to a newcomer.
  Deleted.
- **Root `README.md` was a stale project diary**, not project
  documentation — structured around a single dated "27-05-2026
  reflection" entry, a "goals" checklist wildly out of sync with
  reality (e.g. "arm (next priority)" when arm has been a fully working
  secondary target with its own 104-test QEMU suite for a while;
  zero mention of TPM/Secure Boot/disk encryption, the project's
  *current* stated focus per `CLAUDE.md`), and a "prerequisites" section
  naming QEMU 11.0.0 as if required when the real floor is 8.2+ (11.0.0
  is only `CLAUDE.md`'s documented fallback if host QEMU is too old).
  Rewritten: kept the playful voice and the Q&A section (per
  `docs/DESIGN.md` Part 6 — tone isn't the problem, staleness is),
  fixed the factual content, and made `CLAUDE.md`/`docs/roadmap.md` the
  explicitly-pointed-to living documentation rather than duplicating
  status that goes stale again the moment it's written down twice.

Everything else surveyed came back clean — `apps/`, `library/`
(including `library/innigkeit-rs`, the Rust counterpart to
`library/innigkeit`, correctly separate), `tools/`, `testing/`,
`.claude/skills/`, `sdk/`, and `scripts/` are all already sensibly
organized from stage 1 plus the review passes. `flake.nix` is a real,
working dev-shell (not a stray stub) — unrelated to §5's NixOS-inspired
design-philosophy initiative beyond sharing the name; no action needed
there.

**Re-raising, not re-deciding, the one open structural question**: is a
full top-level restructuring in scope — e.g. rethinking
`src/innigkeit/` vs `library/` vs `sdk/` boundaries, or revisiting the
declined `docs/plans/` split now that this stage added more docs-side
findings? Nothing found this pass suggests either is actually broken
(both boundaries are consistent and consistently used), so not acted on
unilaterally — a boundary rename/move is a hard-to-reverse, high-blast-radius
change (every import path in the repo).

---

## 3. Build system refresh

Two gaps already surfaced by Phase 3 and never acted on.

- **`.claude/rules/build.md`'s kernel-module test-wiring gap** (Stage 22):
  `KernelModule`s (`architecture`, `boot`, `innigkeit`) have no
  per-component host test step the way `LibraryDescription`s
  (`core`, `filesystem`, etc.) do — `test` blocks written under
  `src/boot/` or `src/architecture/` are compiled and run by *nothing*
  today. Two candidate fixes are already documented there (mirror
  `LibraryDescription`'s per-module host-test pattern, or fold those
  tests into `test_x64`/`test_arm`'s existing QEMU-boot discovery).
- **`docs/verification-and-ci.md` §6's dev-experience gap — partially
  fixed (2026-07-08).** The two "unhelpful error message" cases are done:
  `tools/codesign/main.zig` (and its `sdk/codesign/main.zig` duplicate)
  now hints at `zig build codesign -- keygen` on a missing keypair
  instead of a bare `error.FileNotFound`; `build/RustApp.zig` now checks
  once per build invocation whether the `x86_64-unknown-none` target's
  rustlib directory exists (via `rustc --print sysroot`), panicking with
  an actionable `rustup target add x86_64-unknown-none` message instead
  of letting cargo fail later with its generic `error[E0463]`. Verified:
  the hint logic itself with a standalone `zig run` harness pointed at a
  nonexistent file (confirmed the hint prints and exits 1); the Rust
  target check against this environment's already-installed target (a
  true no-op, confirmed by the full verify gate still passing with all
  3 Rust apps building). **Still open**: `zig build -l`'s flat,
  ungrouped ~100+ step dump and the missing "getting started" entry
  point — those are a real redesign, not a bounded error-message fix,
  and weren't attempted this pass.
- **`build/Kernel.zig`'s "duplication" TODO — investigated, not
  mechanical.** Read both `buildKernel`/`buildTestKernel` in full: they
  can't share `buildRootModule()` because the release kernel roots at
  `src/main.zig` while the test kernel must root at the `innigkeit`
  module directly for `zig test`'s file-tree-scoped discovery to pick up
  its test blocks at all (the same constraint `.claude/rules/build.md`
  already documents). Corrected the stale "TODO: unify this" comment to
  explain why, rather than attempting a unification that would either
  break test discovery or misrepresent a fix that isn't actually
  available. The optimize-mode-tuning TODO and the LLVM-backend-forcing
  TODO are genuine tuning/design judgment calls (no concrete goal like a
  binary-size target or backend-capability data to tune against) — left
  as-is rather than guessed at.
- **The kernel-module test-wiring gap itself (`.claude/rules/build.md`)
  — still not attempted**, and still shouldn't be: two candidate fixes
  are documented there, each with real unresolved tradeoffs (can
  freestanding-only `architecture`/`boot` code even build for a host
  target; does folding into `test_x64`/`test_arm`'s discovery require
  restructuring the module graph). This is the one item in this section
  that's a genuine architectural call, not a mechanical fix — still
  flagged for the project owner rather than resolved silently.

### Open questions

- Is the broader `zig build -l` grouping / "getting started" redesign
  wanted as a follow-up, or does the mechanical error-message fix above
  cover what "refresh" meant?
- Does the project owner want the kernel-module test-wiring gap decided
  now (picking one of the two candidate fixes), or does it stay parked?

---

## 4. Test expansion: unit, integration, and fuzzing

- **Unit/integration**: `docs/test-harness-plan.md`'s TH-2 (IPC + cap
  transfer), TH-4 (kill/lifecycle beyond the cooperative path), TH-5 (WM
  client↔server) are already staged and waiting on prerequisite work —
  this is the most concrete, lowest-research part of item 5.
- **Fuzzing is new territory** for this project, but not a green field
  technically: **Zig 0.16 ships built-in fuzz support** —
  `std.testing.fuzz(context, testOne, options)` plus `std.Build.Fuzz`
  wiring it into the build graph (confirmed present in this repo's
  vendored `.tools/zig-0.16.0/lib/std/testing.zig` and
  `lib/std/Build/Fuzz.zig`). This means fuzzing Innigkeit's host-testable
  pure-logic units (TCP parsing, ELF/ACPI/GPT parsers, the codecs already
  covered by `test_native` — `volume_header`/`passphrase_keyslot`/
  `recovery_flow`) is a `zig build --fuzz`-shaped problem already
  supported by the toolchain, not a new external-tool integration
  (AFL/libFuzzer) the way it would be for many other languages.
- The highest-value fuzz targets are exactly the raw-byte parsers this
  session's Phase 3 review spent the most time on: ELF headers, ACPI
  tables, GPT/FAT structures, TCP/UDP/ICMP packet parsing, the volume
  header/passphrase-keyslot codecs. All are pure-logic, host-testable,
  and several already have a `test_native` presence to extend rather than
  invent from scratch. **Correction found while implementing the first
  one**: `src/innigkeit/user/elf/Header.zig`'s `parse()` is *not*
  actually host-testable as-is despite being pure logic — it imports
  `innigkeit`/`architecture` at the top of the file for its return type's
  fields (`innigkeit.user.elf.ObjectType`, `innigkeit.VirtualAddress`,
  etc.), which pulls in the whole freestanding kernel module graph. ELF
  header fuzzing needs that host/freestanding boundary addressed first
  (extracting the pure byte-decode logic, or making the return type
  host-buildable) — not a blocker for fuzzing generally, since the ACPI
  table parsers, GPT/FAT structures, and the volume-header-family codecs
  don't share this problem (confirmed for `VolumeHeader.zig`: `std`-only,
  no kernel-module imports).

### Done (2026-07-08): first fuzz test added — `VolumeHeader.parse`

Added `test "fuzz: VolumeHeader.parse never panics and every slot stays
within bounds"` to `src/innigkeit/filesystem/VolumeHeader.zig`, using
`std.testing.fuzz` + `std.testing.Smith` (learned the API from a real
Zig std-lib example, `lib/init/src/main.zig`, read in full first). Feeds
an arbitrary-length byte buffer (0-511 bytes) into `parse()` and asserts
every returned slot's byte-slice stays strictly within the input buffer
— the exact bug class `.claude/rules/filesystem.md` already documents
this file as getting right; the test exists to keep it that way against
future regressions, not because a bug was found now.

**A real, previously-latent gap surfaced while wiring this in**:
`VolumeHeader.zig` lives under `src/innigkeit/`, so its test blocks are
picked up by *both* `zig build test_native` (a normal `b.addTest` using
Zig's default test runner, which implements `std.testing.fuzz`'s
required `root.fuzz` hook) *and* the in-kernel `kernel_test` binary
(`build/Kernel.zig::buildTestKernel`, which uses a **custom** test
runner, `src/test.zig`, in `.mode = .simple`). `src/test.zig` had no
`fuzz` function, so the very first `zig build check`/`verify` after
adding this test failed with `error: root source file struct 'test' has
no member named 'fuzz'` — a real compile break the verify gate caught
immediately, not something that shipped. Fixed by adding a minimal
`pub fn fuzz(...)` to `src/test.zig`: there's no libFuzzer/coverage-
instrumentation possible inside a QEMU-booted freestanding kernel (no
host process to feed a corpus or read coverage back), so it does exactly
what Zig's own standard runner does when *not* built with `--fuzz` — run
`testOne` once per corpus entry plus one empty-input smoke test. This
means any future fuzz test added to kernel-side code compiles and runs
as an ordinary regression test in both `test_native` and the kernel test
suite; real multi-iteration fuzzing only happens for host-testable code
via `zig build test_native --fuzz`.

Verify gate: baseline moved from 146/103/64 (x64/arm/`test_native`) to
**147/104/65** — a genuine new passing test on all three suites, not a
regression. `CLAUDE.md` and this doc's own baseline references were
already stale by several tests independent of this change (e.g.
`CLAUDE.md` said "138/98/63" going into this pass; the real pre-fuzz-test
count was 146/103/64) — corrected while touching these exact numbers
rather than compounding the drift further.

### Done (2026-07-08): second fuzz test — `tcp/Segment.parse()`

Added `test "fuzz: Segment.parse never panics or hangs, and payload stays
within bounds"` to `src/innigkeit/network/tcp/Segment.zig` — one of
`test_native`'s explicit host-testable file list (`build.zig`'s
`native_test_step` names 9 files by exact path; `Segment.zig`'s own doc
comment says it's "intentionally free of kernel imports so it can be
compiled and tested natively on the host"). Chosen over ACPI/GPT/FAT
specifically because `.claude/rules/network.md` records that this exact
function's TCP-options loop **already had a real bug once** (a
zero-length option that "previously looped forever," fixed with a
regression test already in the file) — the single strongest evidence in
the whole codebase that this specific parser rewards fuzzing over one
without that history. The fuzz test checks the same bounds-safety
property as the `VolumeHeader` one (returned `payload` slice stays
within the input buffer); a real `--fuzz` run's hang detector is what
would catch a reintroduction of the historical infinite-loop class, this
test's job is compiling/running cleanly so that detector has something
to run against.

Verified this generalizes correctly rather than just re-tested the same
file: `zig build check` passed on the first attempt (no repeat of the
`src/test.zig` `fuzz()`-hook gap), confirming that fix isn't
`VolumeHeader`-specific.

**One thing double-checked rather than assumed**: after the verify gate,
x64 moved 147→148 but arm stayed at 104 — worth confirming this wasn't a
new regression before writing it down as expected. Grepped both
architectures' fresh test logs: x64 runs all 52 `network.*`-prefixed
tests (including the new fuzz one); arm runs **zero** — the entire
`network/` subsystem is absent from arm's kernel test build today, a
pre-existing gap (arm's virtio-net port isn't done, consistent with
`docs/aarch64-port.md`'s M2/M3 status) that predates and is unrelated to
this change. Confirmed by checking that *all* of `Segment.zig`'s tests
(not just the new one) are equally absent from arm, not a fuzz-specific
regression.

Verify gate: 147/104/65 → **148/104/66** (x64/arm/`test_native`) — x64 and
`test_native` both gain the one new test; arm is unaffected for the
reason above, not a miss.

### Done (2026-07-09): third and fourth fuzz tests — `udp.parse()` and `icmp.parseEcho()`

Answered the "which parser next" question below by acting on its own
strongest candidate: `udp.zig` (confirmed host-testable, only imports
`ethernet.zig`/`ipv4.zig`/`std`), which `.claude/rules/network.md`
documents as having had a real historical bug in this exact function
(a length field claiming less than `HEADER_LEN` produced `data[8..0]`
and panicked — fixed in Stage 12). `icmp.zig` added alongside it as a
low-effort companion (same host-testable file family, same
bounds-safety property) — a weaker case on its own merits since
`parseEcho()` has no declared-length field of its own to get wrong the
same way `udp`/`tcp` do, but free to add given the infrastructure
already exists. Both wired into `build.zig`'s `native_test_step`.

Verify gate: 148/104/66 → **150/104/84** (x64/`test_native`; arm
unaffected — `network/` is absent from arm's kernel build today, the
same pre-existing gap documented for `tcp/Segment.zig`'s fuzz test,
confirmed not a regression by checking the *whole* `network.*` test
family is equally absent from arm, not just the two new fuzz tests).

### Done (2026-07-09): fifth fuzz test — `SharedHeader.isValid()`

`MADTIterator.next()` was the strongest ACPI candidate by far (a proven
two-bug history — see `.claude/rules/acpi.md`), but every table file
except `SharedHeader.zig` imports `innigkeit` for typed fields
(`innigkeit.PhysicalAddress`), hitting the exact same host-testability
wall found for `elf/Header.zig` above — confirmed empirically this
time (`zig test` against `MADT.zig` bare fails with "no module named
'innigkeit'/'core' available"; every existing `native_test_step` entry
avoids this by importing nothing but `std`). `SharedHeader.isValid()`
only needs `core` (`Size`/`testing`), which — unlike `innigkeit` — is a
genuinely host-buildable library with its own host test step already;
wired as a real module import in `build.zig`
(`libraries.get("core").?.external_module_for_host`), the first
`native_test_step` entry to need one instead of a bare module.

**Caught a real bug in the fuzz test's first draft**: nesting the
`test` block inside the `SharedHeader` struct body means Zig's test
runner silently doesn't collect it at all — found by deliberately
breaking the assertion and confirming the build stayed green when it
should have failed (the same "verify the check actually fires"
discipline as `docs/security-audit.md`'s findings). Moved to file
scope, matching every other test in the codebase; the same
deliberate-break check now correctly reports "0 pass, 1 crash".

Verify gate: 150/104/84 → **153/107/85** (x64/arm/`test_native`) — both
kernel suites gain the test this time (ACPI is core boot infrastructure
on both arches, unlike the network stack `udp`/`icmp` only reached x64).

### Done (2026-07-09): ELF header host-testability gap fixed

Extracted `elf/Header.zig`'s pure byte-decode into a new `RawHeader.zig`
with zero non-`std` imports (`HeaderIdent`, `RawElf64Header`/
`RawElf32Header`, and `parse()` returning a plain-primitive-fields
struct). `Header.parse()` is now a thin wrapper: call `RawHeader.parse()`,
then reinterpret the raw fields as the typed `ObjectType`/`Machine`/
`innigkeit.VirtualAddress`/`core.Size` the rest of the kernel depends on
— public API and behavior unchanged, so `elf_loader.zig`/`SelfInfo.zig`/
`ProgramHeader.zig` needed no changes. Also dropped `HeaderIdent`'s
`osABI()`/`abiVersion()` methods while moving it — confirmed dead (zero
callers anywhere in the tree), and would otherwise have needed their own
`innigkeit.user.elf.OSABI` host-testability decision for no live benefit.

`RawHeader.zig` is wired into `native_test_step` (bare `std`-only module,
matching `tcp/Segment.zig`'s pattern) with 3 unit tests plus a fuzz test.
Since `Header.zig` reaches it via relative import and lives under
`src/innigkeit/` (part of the `innigkeit` kernel module), the same 4
tests also run for free in both the x64 and arm in-kernel suites.

**Assessed `MADTIterator.next()` for the same fix — genuinely bigger
scope, deferred.** The iterator's own walk logic (`entry.length`/
`entry.entry_type`, both `u8`) is already pure. The blocker is
`InterruptControllerEntry`'s `Specific` union: 13 of its ~23 ACPI-variant
structs (`IOSAPIC`, `GIC_CPUInterface`, `GIC_Distributor`, `GIC_MSIFrame`,
`GIC_Redistributor`, `GIC_InterruptTranslationService`,
`LocalAPICAddressOverride`, `MultiprocessorWakeup`, and five LoongArch
PIC variants) reference `innigkeit.PhysicalAddress` — and `extern union`
sizing forces every variant to resolve just from returning `*const
InterruptControllerEntry`, not a single field the way the ELF case was.
`innigkeit.PhysicalAddress` itself also imports `innigkeit` (for
`toDirectMap`/`fromDirectMap`), so there's no already-host-buildable
address type to fall back to the way `core.Size` was for
`SharedHeader.isValid()`. A real fix needs either a host-buildable
minimal address wrapper or narrowing the iterator's return type away
from the rich `Specific` union — touching every ACPI variant plus the
one real caller (`x64/ioapic/init.zig`'s `captureMADTInformation`). Sized
up but not attempted opportunistically alongside the smaller ELF fix;
flagged here as its own future item rather than silently left for a
later session to rediscover from scratch.

Verify gate: 153/107/85 → **157/111/89** (x64/arm/`test_native`) — both
kernel suites and `test_native` gain `RawHeader.zig`'s 4 new tests.

### Open questions

- GPT/FAT structures are the remaining un-fuzzed raw-byte parsers, but
  `.claude/rules/filesystem-library.md` notes they're build-time-only/
  trusted-input tooling, a weaker fuzz case than a runtime
  attacker-facing parser — `MADTIterator`'s bigger-scope fix above is the
  stronger remaining lead if fuzz-target expansion continues.
- Should fuzzing target host-side pure-logic parsers first (cheap, fits
  `zig build --fuzz` directly) or is in-kernel/QEMU fuzzing also wanted
  (much harder — would need a corpus-feeding mechanism across the
  QEMU boundary; the `src/test.zig` fix above makes kernel-side fuzz
  *tests* compile and run as smoke tests, but does not add real
  coverage-guided fuzzing inside QEMU)?

---

## 5. A NixOS-inspired long-range design plan (Zig std → C std → nixpkgs)

### What's already true today

- `flake.nix` already exists — a Nix **dev shell**, not a NixOS module or
  package derivation. It provisions the *host* toolchain (zig/zls/gcc/qemu),
  it does not build or run anything *as* Innigkeit.
- `CLAUDE.md`'s "Current focus" already names "`std`/`std.Io` stubs" as
  active work — i.e., Zig std-library compatibility is already an
  explicit, if not fully scoped, priority before this ask.
- Userspace today is capability-syscall-based (`library/innigkeit/`
  wraps syscalls, IPC, threading) — not POSIX-shaped. Getting real Zig
  std (`std.fs`, `std.process`, `std.net`, etc., not just `std.Io`) to
  work on top of that ABI, then real libc, then real nixpkgs-built
  binaries, is a very large multi-stage undertaking for any capability
  microkernel that isn't POSIX-first by design — worth naming plainly
  rather than understating.

### Why this needs an interview before a plan gets written

"NixOS's philosophy" is a large space — declarative system configuration,
reproducible builds, the nixpkgs package set, atomic upgrades/rollbacks,
service modules — and "Zig std support then C std support then nixpkgs
ports" is a sequencing statement, not yet a scoped one. Before drafting a
staged plan (the way `docs/test-harness-plan.md` or Phase 2/3 got staged),
this needs:

### Decision (interview, 2026-07-08): both, staged

The project owner confirmed the goal is both parts of "NixOS's
philosophy," deliberately staged rather than picking one: reproducible
builds / declarative configuration as a **near-term design influence** on
Innigkeit's own init/service/package model now, with **running real
nixpkgs-built binaries as the explicit long-range goal** the near-term
design work should not foreclose (i.e., don't make init/service design
choices now that would make nixpkgs interop structurally impossible
later, even though that's a multi-year-out goal).

### Open questions (remaining)

- What does "Zig std support" mean as a #1 priority concretely? All of
  `std` (including `std.process`, `std.fs`, threading primitives that
  assume a POSIX-like kernel), or a named, bounded subset (e.g. just
  enough for `std.Io`/allocators/collections to work, which is closer to
  what's already in flight per `CLAUDE.md`)?
- **Is C std support meant to be Innigkeit's own libc, or portability of an
  existing minimal libc (musl, etc.) onto Innigkeit's syscall ABI?** These
  are very different amounts of work and very different design
  commitments (a syscall-ABI-compatibility layer vs. writing libc from
  scratch).
- **What's the actual near-term deliverable**, if any, this epoch — a
  written design doc only (north star + a first concrete milestone), or
  actual code (e.g., getting one more `std` module working end-to-end as
  a proof point)?

---

## Sequencing across all five initiatives (decided, interview 2026-07-08)

The project owner confirmed the draft order below — repo reorg first,
NixOS-inspired plan last:

1. **Repo reorg** (§2) — **done.** Itest fixture apps moved to
   `testing/fixtures/`; `.vscode/launch.json` added for CodeLLDB; the
   `docs/plans/` split was reconsidered and declined (see §2).
2. **Linter adoption** (§1) — **done.** zwanzig dropped (doesn't build
   against 0.16.0 without real, multi-file porting work). zlinter is
   built, wired into a real `zig build lint` step (`build/Lint.zig`)
   with the exact rule selection (`no_deprecated`,
   `no_hidden_allocations`, `no_literal_only_bool_expression`,
   `no_orelse_unreachable`, `require_errdefer_dealloc`, `require_fmt`),
   plus two custom rules ported from the existing clippy config
   (`truncate_unchecked_arithmetic`, `ptr_from_int_undocumented`, in
   `build/lints/`). House style flipped to match zlinter's `no_orelse_unreachable` default
   (bare `.?` over `orelse unreachable`) rather than fighting it with a
   custom counter-rule — the earlier `no_bare_optional_unwrap` draft is
   superseded, not shipped. First real run's findings resolved: 109
   `orelse unreachable` sites reverted to `.?`, 100 `no_deprecated`
   warnings fixed (mechanical std-API modernization). All 76
   `ptr_from_int_undocumented` findings now closed, and `no_swallow_error`
   (195 findings) now enabled and closed too — see the 2026-07-09 session
   log entries below.
3. **Build system refresh** (§3) — **mostly done.** Actionable error
   messages fixed (codesign keypair hint, Rust target check); the
   `Kernel.zig` "duplication" TODO investigated and found not mechanical
   (comment corrected instead); the kernel-module test-wiring gap itself
   remains a flagged architectural call. `zig build -l` grouping / a
   "getting started" entry point remain undone (a real redesign, not a
   bounded fix).
4. **Test expansion** (§4) — **started.** Two fuzz tests added
   (`VolumeHeader.parse`, `tcp/Segment.parse()`), surfacing and fixing a
   real gap along the way (kernel-side custom test runner didn't support
   `std.testing.fuzz` at all — confirmed the fix generalizes, not
   file-specific). TH-2/4/5 (unit/integration) still staged, not started.
   UDP/ICMP and ACPI parsers are the next fuzz targets; `elf/Header.zig`
   needs a host-testability fix first; GPT/FAT are lower-priority
   (build-time-only trust model, not runtime attacker-facing).
5. **NixOS-inspired design plan** (§5) — goal confirmed as "both, staged"
   (design influence now, nixpkgs interop as the explicit long-range
   goal); still needs the remaining open questions answered before real
   staging.

## Session log

**2026-07-08 — Linter adoption stage closed out.** zlinter built for real
against Zig 0.16.0 (the earlier static-compat check's confidence
confirmed by an actual build), wired into `build/Lint.zig` as
`zig build lint`.

1. flipped
   `docs/DESIGN.md`'s `.?`/`orelse unreachable` convention to match
   zlinter's `no_orelse_unreachable` default instead of shipping a
   custom counter-rule — 109 sites across 36 files reverted from
   `orelse unreachable` back to `.?`.
2. Fixed all 100 `no_deprecated` warnings — mechanical std-API
   modernization (`std.fs.path` → `std.Io.Dir.path`, `indexOf`-family →
   `find`-family, `std.meta.Int`/`Tuple` → `@Int`/`@Tuple`,
   `LazyPath.getPath2` → `getPath4`, `std.elf.Elf32_Sym` etc. → the
   namespaced `Elf32.Sym` etc., `SHT_NULL`/`SHT_NOBITS` →
   `@intFromEnum(...)`, `AutoArrayHashMapUnmanaged` →
   `array_hash_map.Auto`, `dupeZ` → `dupeSentinel`,
   `std.debug.runtime_safety` → a local `builtin.mode` check), with two
   call sites correctly left on the old ELF layout (and commented)
   because std's own `SectionHeaderBufferIterator`/`std.pie.relocate`
   haven't migrated their signatures yet.
3. Added two custom rules per the instruction to port
   in clippy-inspired checks, scoped to the highest-signal cast/
   unsafe-pointer translations rather than a blanket port that would've
   drowned the build in noise: `truncate_unchecked_arithmetic` (clippy's
   `cast_possible_truncation`/`cast_sign_loss` cluster — flags
   `@truncate` of a plain, non-wrapping arithmetic expression; one real
   finding in `library/filesystem/gpt.zig`, now documented) and
   `ptr_from_int_undocumented` (clippy's `undocumented_unsafe_blocks` —
   flags `@ptrFromInt` with no nearby comment; 76 real findings left as
   tracked follow-up, since writing an honest comment per site means
   confirming *why* each address is valid, not filling in boilerplate).

`zig build lint`'s state at the end of that session: 76 warnings (all
`ptr_from_int_undocumented`, tracked follow-up), 0 errors. Verified after
each stage: `zig build check` clean, `zig build verify -Darm=true` (x64
148/148, arm 104+14 skipped — unchanged from baseline throughout). Not
pushed to `main` — delivered as patches per this project's standing
convention.

**2026-07-09 — `ptr_from_int_undocumented` backlog closed (76 → 0).**
Worked through all 76 sites in clusters, each with a comment reflecting a
real, verified safety argument (traced the enclosing function/caller/
struct-field-doc, not filler text), matching the commitment made when the
backlog was first opened:

1. arm/riscv arch cluster (13 sites) — per-CPU current-task register
   round-trip, PCI ECAM window, already-typed addresses.
2. capabilities/ cluster (9 sites) — `CapabilityTable`'s `ptr_or_next`
   gated by an already-checked `type != .null`, `Endpoint`/`Reply`'s
   single-producer integer fields, a test fixture never dereferenced.
3. user/ cluster (12 sites) — `Process.zig`/`Thread.zig`'s kernel-owned
   stack/buffer writes inside a `UserAccess` window, `validate.zig`'s own
   sanctioned pointer-construction helpers.
4. memory/ cluster (9 sites) — `Arena`/`RawCache`'s freshly-self-allocated
   bases, `BuddyAllocator`'s already-typed direct-map addresses.
5. drivers/ cluster (12 sites) — `tpm/crb.zig`'s device-MMIO mapping and
   already-bounds-checked buffer translation; `virtio/gpu.zig`'s
   direct-mapped physical pages, its own just-mapped queue page, and its
   private mmio accessors.
6. remaining scattered sites (19 sites, folding in one extra site found
   along the way in `arm/PageTable.zig`) — the callback-arg round-trip
   pattern in `boot/limine/interface.zig` and `sync/{WaitQueue,Parker}.zig`;
   `address/{Kernel,User}VirtualAddress.zig`'s own sanctioned conversion
   primitives; `library/innigkeit/{display,memory}.zig` and
   `apps/doom/syscalls.zig`'s kernel-returned syscall addresses;
   `library/innigkeit/thread.zig`'s thread-entry arg round-trip;
   `library/core/containers/{RedBlackTree,TypeErasedCall}.zig`'s internal
   pointer-packing schemes; `acpi/uacpi_kernel_api.zig`'s I/O port handle
   and dummy event handle (neither ever dereferenced as memory);
   `debug/{Module,SelfInfo}.zig`'s self-reconstructed `.eh_frame` address
   from this same kernel image's own already-parsed headers;
   `tools/image_builder/fat/root.zig`'s fixed on-disk FAT32 layout.

`zig build lint` now reports 0 `ptr_from_int_undocumented` warnings.
Verified after each cluster and again at the end: `zig build check`
clean, `zig build verify -Darm=true` unchanged (x64 153/153, arm 107+14
skipped). Not pushed to `main` — delivered as patches per this project's
standing convention.

**2026-07-09 — `no_swallow_error` enabled and closed (0 → 195 → 0), same
session.** Per the staging order in `docs/clippy-rustfmt-mapping.md`
(§3, item 4), enabled the builtin now that `ptr_from_int_undocumented`
was clear, then worked through all 195 findings in six clusters, same
per-site verification discipline:

1. drivers/ + user/ clusters (27 sites) — `Port.from()` on fixed/computed
   in-range u16 ports; `ProgramHeader`'s reads proven in-bounds by
   `iterateProgramHeaders`'s own checks; `Process.zig`/`AddressSpace.zig`'s
   `Name` conversions proven to fit fixed capacities. Two real gaps found
   and fixed: `gpu.zig`'s initial-flush error silently dropped while every
   sibling call in the same function logs (fixed to log); two
   `vmem.zig`/`framebuffer.zig` cleanup-unmap failures after a mapping
   error, same fix.
2. x64 arch + memory/ clusters (18 sites) — `scheduling.zig`'s task-stack
   pushes proven safe by a fixed, non-data-dependent stack size;
   `memory/core/init.zig`'s bootstrap page allocation converted from
   `unreachable` to an honest `@panic` (a genuine, if rare, early-boot OOM,
   not a provably-impossible condition, matching this file's own sibling
   panics). `Arena.zig`: found a real latent gap while verifying —
   `quantum_caching`'s `count` is a `u8` (max 255) written into a
   `BoundedArray` fixed at 64, with no check before the append loop; the
   one live caller (count=32) doesn't hit it, but a future caller could.
   Added a debug assert closing the gap (Part 1's "assert the
   post-condition"), plus a genuine false positive fix (a comptime
   value-selector `if`/`else` the builtin can't distinguish from an
   error-capturing one).
3. Remaining kernel scattered sites (14) — more fixed-name/fixed-range
   patterns; two more `unreachable`→`@panic` conversions for uACPI's
   non-error-returning C-ABI mutex/spinlock creation; the kernel panic
   handler's own last-resort print (correctly swallowed — no more
   graceful path once already panicking); `ext4.zig`'s `truncateInode`
   freeBlock failure now logs, and `createFile`'s broad lookup-error
   swallow confirmed safe by inspection (the same error resurfaces via
   the very next `lookup(parent_path)` call, which does propagate).
4. library/build/tools/sdk cluster (34) — fixed UUID literals, documented
   best-effort build-tool cleanup/retry patterns (already carrying their
   own "best-effort" doc comments), the ustar 8 GiB file-size limit, and
   a `catch unreachable` living purely inside `@TypeOf(...)` (never
   actually evaluated).
5. apps/ cluster (97) — every finding a demo/smoke-test app's console
   print or a process-exit-time cleanup; whole-file suppressions for the
   uniformly-shaped files (`hello_world`, `shell/*.zig`, `pixels`,
   `tcp_echo`), per-site for `wm/main.zig`/`shader_demo/main.zig` (real
   interactive-loop logic alongside the cleanup calls).

Also discovered empirically (and had to fix twice): `no_swallow_error`'s
`zlinter-disable-next-line` directive targets exactly `comment_line + 1` —
a multi-line reason comment that doesn't put the directive as its own
*last* line before the code silently fails to suppress anything, since
the "next line" ends up being another comment line, not the flagged code.
Every suppression here puts free-form reasoning first and the bare
`zlinter-disable-next-line no_swallow_error` (or an inline `- reason`)
directive last, immediately above the flagged line.

`zig build lint` now reports 0 `no_swallow_error` warnings (and 0
`undocumented_zlinter_disable` warnings across every new suppression).
Verified after each cluster: `zig build check` clean, `zig build verify
-Darm=true` unchanged throughout (x64 153/153, arm 107+14 skipped). Not
pushed to `main` — delivered as patches per this project's standing
convention.
