# Innigkeit roadmap

Single entry point after a context reset. Read this, then follow the links.
Last updated 2026-09-09.

**Verification gate:** `zig build verify -Darm=true` — runs `zig build check`, host tests (`test_native`), x64, and arm suites. Baseline: x64 158/158, arm 112 (+14 skipped), host `test_native` 89 — up from 157/111/89 after the upstream-review-pass-2 heap/c.zig round-trip test (`docs/upstream-review-plan-2.md`) added the one kernel-side test that surfaced two real bugs in previously-uncalled code. With `-Dtpm=true` also set: x64 175/175 (2 skipped), arm 129/129 (31 skipped). Networking is x64-only in the kernel test suite today — arm's build doesn't reach `network/` at all yet (pre-existing, unrelated to fuzzing). See the full Phase 1-3 + next-epoch history in the Session log below for every earlier increment. Opt-in `-Dtpm=true` gate (build-managed swtpm + QEMU `tpm-crb`). Boot-security progress (SB-1..SB-6) tracked in `docs/secure-boot.md`.

## Companion docs

- `docs/getting-started.md` — first-time walkthrough from a fresh clone to a passing `zig build verify`; bare `zig build`/`zig build help` print a shorter version of the same menu
- `docs/DESIGN.md` — coding ideology, formatting rules, `safe.memcpy` analysis
- `docs/design-goals.md` — long-term pillars and decision records
- `docs/aarch64-port.md` — ARM port log and M3 plan
- `docs/syscall-abi.md` / `docs/syscall-foundation-plan.md` — syscall dispatch contract
- `docs/secure-boot.md` — **(active)** UEFI Secure Boot + TPM 2.0 + disk encryption
- `docs/verification-and-ci.md` — **(active)** canonical map from test layer → build step → CI job → release; records that `main`'s CI was broken for months (missing codesign keygen + rustup target) and the fix, not yet pushed
- `docs/test-harness-plan.md` — **(active)** user-process integration test harness; Stages 0-4 done (TH-1 now passes on x64 *and* aarch64 — real arm SVC dispatch closed the last gap, see arm.md; riscv64 stays skipped, no syscall dispatch of its own yet); TH-2/TH-4/TH-5 remain deferred
- `docs/wm-wayland-plan.md` — **(stashed)** native WM → Wayland compositor; pure cores done and host-tested, parked behind security/test work
- `docs/phase3-review-plan.md` — **(complete)** repo-wide expansion of the Phase 2 review to every remaining subsystem; Tiers 1-3 (Stages 6-18, ~49,700 lines) and Tier 4 (Stages 19-24, ~12,540 lines — directories the original plan missed entirely, discovered via a post-completion cross-check) both fully done — Phase 3's entire currently-planned scope is finished
- `docs/next-epoch-plan.md` — **(active)** the next round of work named by the project owner right after Phase 3 closed: linter adoption (zlint/zwanzig/zlinter researched and compared; zwanzig spiked and dropped, zlinter confirmed), repository reorganization (**done** — itest fixtures + launch.json), a build-system refresh, expanded unit/integration/fuzz testing, and a NixOS-inspired long-range design plan (Zig std → C std → nixpkgs).

## Status

| Workstream | State | Owner doc |
| --- | --- | --- |
| AArch64 M1 (boot + non-driver suite) | **DONE** | `aarch64-port.md` |
| AArch64 M2 (virtio storage, poll mode) | **DONE** (INTx deferred) | `aarch64-port.md` |
| AArch64 M3 (SMP) | **PLANNED** (Limine AP startup; GICv2 SGIs) | `aarch64-port.md` |
| Reliable arm test harness | **DONE** | CLAUDE.md |
| Scheduler Phase A (IPI, work stealing, idle-first wake) | **DONE** | CLAUDE.md |
| Scheduler Phase B (QoS weight/slice + `thread_set_qos`) | **DONE** | `QoS.md` |
| Table-based syscall dispatch + unified `Error` ABI | **DONE** | `syscall-abi.md` |
| `memory.safe.memcpy` fault-fixup | **DONE on x64 and arm** (arm's own routing was already live; its unit tests were just stale-gated to x64-only) | `DESIGN.md` Part 3 |
| WM substrate (geometry / protocol / client / compositor / loop) | **DONE (host-tested), STASHED** | `wm-wayland-plan.md` |
| Build-system integration code review | **DONE** | patches 1-11 |
| Test-harness redesign, Stage 0 (dead test wired in) | **DONE** | `test-harness-plan.md`, patch 14 |
| Test-harness redesign, Stage 1 (`elf_loader.zig` extraction) | **DONE** | `test-harness-plan.md`, patch 16 |
| SYSRET non-canonical-RCX boundary fix (all arches) | **DONE** | patch 19 |
| Per-process fault isolation (`onPageFault`, TH-3 prerequisite) | **DONE** | patch 26 |
| `.?` → `orelse unreachable` sweep (98 sites, 36 files) | **DONE** | patch 29 |
| Independent re-review of patches 14-29 (8-angle `/code-review`) | **DONE** | `test-harness-plan.md` session log |
| Test-harness Stage 2 (`Process.spawnFromInitfs`) | **DONE** | `test-harness-plan.md` |
| Test-harness Stage 3 (`test_only` fixture-app build support) | **DONE** | `test-harness-plan.md` |
| Test-harness Stage 4 / TH-1 (first integration test) | **DONE on x64**; arm skips | `test-harness-plan.md` |
| Unified testing/build/CI/CD system, Phase 1 (fix CI, rename `test`→`build_all`, secboot-verify.yml, canonical doc) | **DONE locally, NOT PUSHED** | `verification-and-ci.md` |
| Phase 2 style guide (`DESIGN.md` Parts 5-7: tradeoff bias, voice/tone, efficiency style) | **DONE** | `DESIGN.md` |
| Phase 2 Stage 1 (codesign/ + elf/ review) | **DONE locally, NOT PUSHED** | `phase2-review-plan.md` |
| Phase 2 Stage 2 (capabilities/ review) | **DONE, no code changes needed** | `phase2-review-plan.md` |
| Phase 2 Stage 3a (user/ dispatch core review) | **DONE locally, NOT PUSHED** | `phase2-review-plan.md` |
| Phase 2 Stage 3b (user/handlers/ review) | **DONE locally, NOT PUSHED** | `phase2-review-plan.md` |
| Phase 2 Stage 4a (memory/address_space core review + `.claude/rules/memory.md`) | **DONE locally, NOT PUSHED** | `phase2-review-plan.md`, `.claude/rules/memory.md` |
| Phase 2 Stage 4b (AnonMap/AnonPage/Object/chunk_map.zig refcount audit) | **DONE, no code changes needed** | `phase2-review-plan.md`, `.claude/rules/memory.md` |
| Phase 2 Stage 5 (memory/ allocator internals: arena/cache/heap/page/compress) | **DONE locally, NOT PUSHED — 1 severe bug found and since fixed** | `phase2-review-plan.md`, `.claude/rules/memory.md` |
| Phase 2 both open findings (heap allocator over-alignment `free()`, address-space page-table lock gap) | **FIXED, verified, NOT PUSHED** | `.claude/rules/memory.md` |
| Phase 3 (repo-wide review expansion: architecture/, acpi/, drivers/, task/, sync/, network/, filesystem/, init/, library/innigkeit/, tools/, debug/, etc.) | **DONE — Tiers 1-3 (Stages 6-18) and Tier 4 (Stages 19-24) both complete** | `phase3-review-plan.md` |
| Next epoch: linter adoption, repo reorg, build-system refresh, test expansion, NixOS-inspired design plan | **IN PROGRESS** — repo reorg DONE (stages 1+2, incl. a fresh structural audit); linter adoption DONE core + ONGOING breadth (zlinter wired in, house style flipped, no_deprecated/require_errdefer_dealloc zeroed, 4 custom rules shipped, import_ordering + hex_literal_case autofixed to 0, clippy/rustfmt cross-reference tracked in `clippy-rustfmt-mapping.md`, 76-finding ptr_from_int follow-up tracked); build-system refresh mostly done; TODO review DONE (full dedicated pass, 5 real fixes); test expansion IN PROGRESS (5 fuzz tests: VolumeHeader, tcp/Segment, udp, icmp, SharedHeader.isValid); NixOS plan not yet started | `next-epoch-plan.md` |

## Durable lessons

Full craft guide in `docs/DESIGN.md`. Headlines:

1. No physical register names in generic code — cross the arch boundary through `architecture.Functions` slots.
2. Fallible user-pointer access must return an error, not panic. The `memory.safe.memcpy` fault-fixup is the engine, wired and verified on both x64 and arm (arm's data-abort path was already routed to `memory.onPageFault` — its tests were just left stale-gated to x64-only, see `DESIGN.md` Part 3).
3. `zig build check` doesn't validate inline assembly. Always run a real kernel build after touching arch `asm`.
4. Make illegal states unrepresentable — tagged-union types over enum+cast patterns.
5. Bootloader memory maps aren't always page-aligned (aarch64 reports sub-page entries; the direct-map builder rounds and clamps).
6. Deliver work as patches in `/tmp/patches/` (numbered, append-only).
7. Address-space boundary constants are security-critical, not just layout details — the SYSRET non-canonical-RCX class (a real historical privilege-escalation bug family) hides in an off-by-one-page arithmetic mistake at the canonical/non-canonical boundary. Diff against a comparable project's equivalent constant, don't just eyeball the math.
8. Zig's `"+{reg}"` inline-asm constraint does not imply that register is in the clobber list — list it explicitly, or risk a silent miscompilation `zig build check` can't catch (it doesn't validate assembly at all).
9. `.?` and `orelse unreachable` are the same operation by language definition — converting between them is always behavior-preserving; the only judgment required is *why* a site is safe, not whether the rewrite itself is safe.
10. `sanitize_c` must be set explicitly on *every* `std.Build.Module` that reaches a freestanding soft-float target, not just the one that might link C — an unset field silently takes Zig's implicit Debug-mode default (`.full`), and any UBSan-instrumented code path touching floats fails to codegen there (`fpext f128` has no encoding without SSE, a Zig 0.16.0 backend limitation). Caught 2026-07-13: `build/App.zig`'s app-vs-C-sources fix (§6 of `verification-and-ci.md`) left the wrapper module's `sanitize_c` unset, breaking every app's x64 build. `zig build check`'s per-app failures with no shared root cause in the diagnostic — bisect via a scratch `git worktree`, don't assume the newest commit is the only suspect.

## What's next

**Explicit 3-phase sequence from the project owner (2026-07-06):** (1) a
long-term, unified, carefully-designed testing/build/CI-CD/verification
system; (2) a comprehensive style/efficiency/security review; (3) big
feature paths (arm support, boot/at-rest security, std integration →
Wayland). The items below are ordered within that sequence.

### Phase 1 — unified testing/build/CI/CD/verification system

**DONE locally, NOT PUSHED.** See `docs/verification-and-ci.md` (new
canonical doc) and "Session log (2026-07-06)" below. Landed: fixed two
confirmed CI-breaking bugs on `main` (missing `zig build codesign --
keygen`, missing `rustup target add x86_64-unknown-none` — `main`'s CI had
been failing on nearly every run for months, confirmed via real GitHub
Actions job logs); renamed the misleadingly-named `test` build step to
`build_all`; added a scheduled `secboot-verify.yml` workflow (the
`-Dsecboot=true` suite had never run in CI before). **`main`'s CI remains
broken until this is actually pushed** — fixing it locally in this session
does not fix `main`.

Independent `/code-review` pass (default model) over the Phase 1 diff found
and fixed 8 real issues: an overclaimed inline-asm/riscv coverage story in
`build_all`'s own comments (verify already covers x64/arm in CI; `verify`
itself never depends on `build_all` either, so that protection is CI-only,
not part of the local gate), 4 stale baseline-number references left behind
in `.claude/skills/`/`.claude/rules/` files, and a broken CLAUDE.md citation.
See `docs/verification-and-ci.md`'s own session log for the full list.

**Explicitly flagged as NOT done this pass (project owner, 2026-07-06):**
developer experience / interface design for the build/test/verification
system — step discoverability (`zig build -l` is a flat ~100-step dump),
actionable error messages at the point of failure (not just in docs), a
real "new contributor" walkthrough. Phase 1 fixed correctness; this is a
distinct, not-yet-scheduled design pass. See
`docs/verification-and-ci.md` §6.

### Phase 2 — comprehensive style/efficiency/security review

Staged in `docs/phase2-review-plan.md` (5 stages, file lists + governing docs
+ checklists specified up front). **Stages 1-3 (codesign/+elf/, capabilities/,
user/ dispatch core, user/handlers/) all DONE** — see their own session logs
above/below. Stages 4-5 (memory/address_space, memory/ allocator internals)
specified but not yet executed. **Environment note from Stage 3a: the
default `.zig-cache` needs a full wipe** (a build-graph cache-key gap
surfaced during verification left it in a bad state — see Stage 3a's
session log) — do this before the next normal `zig build` invocation.

### Phase 3 — big feature paths

Not started. In order: arm support (spawn/SVC dispatch gaps now fixed,
see below; `docs/aarch64-port.md`'s M3 SMP plan remains), boot & at-rest security
(`docs/secure-boot.md`), deeper `std` integration leading into Wayland
(`docs/wm-wayland-plan.md`).

### Carried-over tracked items (from before the 3-phase directive)

**Sibling-thread process termination — IMPLEMENTED and verified end-to-end.** `Process.terminateCallingThread` now marks every sibling thread (`Task.pending_kill`, checked at the same safe point ordinary deferred preemption already uses in `Current.decrementInterruptDisable`) and, on x64, broadcasts a real kill IPI (`kill_request` vector 252, `architecture.interrupts.sendKillIPI`) so one running on another executor notices promptly instead of waiting for the periodic tick; a `Process.terminating` compare-exchange also closes the previously-unsynchronized "whichever `exit_status` write happens last wins" race between concurrent terminators. Deliberately broadcasts rather than targeting a specific executor: reading another task's `state`/`known_executor` from a foreign core without that core's own scheduler lock risks a torn union read, not just staleness, so every other core instead re-checks its OWN current task at its own next safe point — always same-core, never racy. arm/riscv have no kill IPI (both single-executor so far, same as `sendRescheduleIPI`) and rely on the periodic-tick backstop.

**The end-to-end test (`testing/fixtures/itest_sibling_kill`) initially looked blocked by a separate "kernel hangs" bug — that read was wrong, and the real bug (in this feature's own code) is now fixed.** Full writeup in `.claude/rules/x64.md`. Short version: what first looked like `spawn_thread`'s second-thread `enterUserspace` hanging the whole kernel was actually a clean watchdog timeout (confirmed by re-running with a short watchdog and `-Dinterrupts=true` — the suite finished normally reporting one FAILED test, and the "repeating fault" in the `-d int` trace resolved via `addr2line` to the idle loop, not a crash). The real bug: `Process.create()`'s slab-reuse reset (this project already documents "process slots silently carry stale state if you don't [reinitialize]" as a hard invariant in `.claude/rules/capabilities.md`) explicitly resets `entitlements`/`fd_table` but was never updated to also reset the newly-added `Process.terminating` field, so a process reusing a slab slot from a previously-exited process inherited `terminating = true` and silently skipped both `exit_status` and the sibling-kill cascade on its own first exit. Fixed. **Also found and fixed in the same investigation, unrelated to sibling-kill itself**: `CapabilityTable.deinitAll()`'s doc comment says "called when a process exits," but its only real call site was the slab cache's destructor (fires only when a whole slab is reclaimed, not on ordinary process exit) — every process leaked its entire capability table on exit, and a reused Process slab slot handed the next process a capability table still populated with the previous process's live entries (a cross-process capability leak, not just a resource leak). Fixed by calling `cap_table.deinitAll()` from `Process.cleanupProcess`. Verified: the integration test now passes for real on both x64 (160/160) and arm (158/158, 11 skipped), confirmed via `zig build verify -Darm=true -Dtpm=true` with no regressions elsewhere.

**Runtime process spawn on arm — FIXED, no longer a gap.** The former "priority arm bug" (`Process.spawnFromInitfs`'s recursive SP_EL1 exception) and the follow-on "arm has no SVC dispatch at all" gap it exposed are both closed — see `.claude/rules/arm.md`'s "Runtime process spawn on arm" and "EL0 synchronous exceptions" sections. `testing/integration.test.zig`'s two spawn-based tests now run and pass on aarch64 (riscv64 stays skipped, no syscall dispatch of its own yet).

**Three explicitly deferred judgment calls** — `paging`→`mem` rename, hiillos's IPC Sender badge, URI-style service addressing. Project owner said "none of these right now" (2026-07-06) — stay parked, no further unilateral research.

**Test-harness TH-2/TH-4/TH-5** (see `test-harness-plan.md`'s own "Explicitly deferred" section) — IPC + cap transfer, kill/lifecycle beyond the cooperative path, WM client↔server. Each needs its own prerequisite work first.

**Harden the user-memory boundary** — fold remaining streaming `userSlice`+`UserAccess` sites onto `safe.memcpy`; bias new syscalls toward cap-based zero-copy. See `DESIGN.md` Part 3. Folds into Phase 3's arm/security work.
