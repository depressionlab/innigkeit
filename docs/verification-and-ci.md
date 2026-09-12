# Verification and CI/CD

Canonical map from test layer → build step → CI job → release. This doc does
not duplicate the command table in `CLAUDE.md` (link there for exact
invocations) or the test taxonomy detail in `docs/test-harness-plan.md` /
Secure Boot rationale in `docs/secure-boot.md` — it ties them together and
owns the build-step hierarchy and CI/release pipeline shape, which no other
doc owns.

---

## 1. Test layer taxonomy

- **Host unit tests** (`zig build test_native`) — pure logic, no kernel. See `CLAUDE.md`'s Testing section for the current count and file list.
- **In-QEMU kernel tests** (`zig build test_x64` / `test_arm`) — judged by the serial verdict (`ALL N TEST(S) PASSED`) via `build/VerdictStep.zig`, not QEMU exit code.
- **SMP stress tests** (`testing/smp.test.zig`) — watchdog-bounded cross-executor tests. See `CLAUDE.md`.
- **User-process integration tests** (`testing/integration.test.zig`) — spawns a real process via `Process.spawnFromInitfs` and observes it end-to-end. See `docs/test-harness-plan.md` for the full taxonomy and staging (Stages 0-4 done; TH-2/4/5 deferred).
- **Boot-security suites** (`-Dtpm=true`, `-Dsecboot=true`) — see `docs/secure-boot.md` for what each test proves and why.

## 2. Build step hierarchy

```
check       -- compile everything, -fno-emit-bin (fastest signal; does NOT validate inline asm)
build_all   -- real link build of kernel/library/app/tool for every architecture
               (incl. riscv, which has no QEMU suite at all) + host-side tests
               (no QEMU boot, no images). Formerly named `test`.
test_native -- the host-only unit test files wired directly in build.zig
test_x64 /
test_arm    -- build test kernel + run its suite in QEMU, judged by VerdictStep
verify      -- check + test_native + test_x64, plus opt-in:
                 -Darm=true      also runs test_arm
                 -Dtpm=true      also runs the TPM suite (swtpm + tpm-crb)
                 -Dsecboot=true  also runs the Secure Boot suite
                 -Dcpus=1        single-core run (any of the above)
image /
image_{arch} -- build a disk image (not part of build_all or verify -- expensive,
                doesn't affect correctness checks)
```

Two gaps this hierarchy makes explicit rather than hides:

- **`check` never validates inline assembly** (`-fno-emit-bin`). `build_all` is a real link, so it's the step to run after touching arch `asm` on any architecture `check` alone won't catch.
- **RISC-V has no QEMU test suite at all** — only x64 and arm do (`build.zig`'s `test_x64`/`test_arm`). `build_all`'s real riscv link build is the only correctness signal riscv gets today. Accepted gap, not silently missing: RISC-V support is early/unfinished (see `docs/aarch64-port.md` for the arm equivalent, which has real QEMU coverage).

## 3. Opt-in suites

- **`-Dtpm=true`** — build-managed `swtpm` + QEMU `tpm-crb` device (`build/TpmHarness.zig`). See `docs/secure-boot.md` SB-1..SB-4 for what's actually being tested.
- **`-Dsecboot=true`** — own PK/KEK/db enrollment, signed/unsigned/tampered-config QEMU boot comparison (`build/Verify.zig`'s `registerSecbootSuite`). Degrades gracefully (skips with a note) if required tools/firmware are missing. See `docs/secure-boot.md` SB-6.
- **`-Darm=true`** — also run the arm QEMU suite as part of `verify`.
- **`-Dcpus=1`** — single-core run of any of the above.

## 4. CI pipeline (`.github/workflows/ci.yml`)

Runs on every push to `main` and every PR. Fixed step order:

1. `checkout`, `get zig` (also handles Zig's own package/build cache internally — no extra `actions/cache` step needed for that)
2. `install QEMU/AAVMF/swtpm`
3. `rust bare-metal target` (`rustup target add x86_64-unknown-none`)
4. `codesign keypair` (`zig build codesign -- keygen`)
5. `lint` (`zig fmt --check --ast-check` scoped to first-party paths — see below)
6. `build_all` — fail-fast link-build pass, cheap relative to a QEMU boot
7. `verify -Darm=true -Dtpm=true`

**Steps 3-4 were missing until this pass, and `main`'s CI had been failing on
nearly every run for months as a result** — every codesigned app failed with
`error: cannot open 'keys/codesign_private.key': FileNotFound`, and all three
Rust apps failed with `error[E0463]: can't find crate for 'core'`
(`rustup target add x86_64-unknown-none` is what was missing). Confirmed via
the real GitHub Actions job logs for `main`, not assumed. **This fix has not
been pushed to `main`** — per this project's working convention, changes stay
local and are delivered as patches; `main`'s CI remains broken until a human
(or a future session with explicit permission) actually pushes it. Do not
assume `main` is green because this doc says the fix exists.

**A second, independent CI-breaking bug was found and fixed this pass, one
step further down the pipeline than steps 3-4's fix reaches.** With the
codesign/rustup fix applied locally, step 5's `zig fmt --check --ast-check .`
still fails — the bare `.` recursively walks the entire repository,
including the gitignored `zig-pkg/` Zig package-fetcher cache, which holds
vendored dependencies' own test fixtures. `zlinter`'s and `zls`'s fixtures
in particular are *deliberately invalid* Zig (duplicate struct members,
duplicate error-set fields, illegal global `asm`) — used to exercise those
projects' own linters/analyzers, never meant to be parsed by anything else.
`--ast-check` chokes on them with real parse/AST errors that have nothing
to do with this repo's own code. Reproduced locally byte-for-byte; fixed by
scoping the lint step to the repo's first-party paths explicitly (`apps
build build.zig build.zig.zon library sdk src testing tools`) instead of
`.` — confirmed to pass with exit 0 against the current tree. Also not yet
pushed to `main`, same convention as above: `main`'s CI would still fail on
step 4 today (steps 3-4's fix hasn't landed there either), so this bug has
never actually been reached on a real `main` run — it was found by running
the full local pipeline past the point `main` currently gets stuck at, not
by observing it fail on GitHub.

**Also hardened this pass, unrelated to correctness**: `timeout-minutes`
added to every workflow's job (bounded-wait safety net, matching this
project's own philosophy of watchdog-bounded waits elsewhere — see
`CLAUDE.md`'s SMP stress-test description) and a `concurrency` group added
to `ci.yml`/`secboot-verify.yml` (cancels a superseded run on the same
ref/branch instead of letting stale runs pile up; deliberately *not* added
to `release.yml`, since canceling an in-flight signed-release build because
another tag pushed would be actively dangerous for a release pipeline, not
a mere efficiency question).

**Secure Boot verify** (`-Dsecboot=true`) runs separately, not in the main
job: `.github/workflows/secboot-verify.yml`, scheduled weekly + on-demand
(`workflow_dispatch`). Kept out of the per-push/PR job because it needs extra
packages (`mtools`, `sbsigntool`, `virt-firmware` via pip) the main job
doesn't install, and is structurally slower (three sequential QEMU boots vs.
one). This suite has never run in CI before this pass either.

**Apt-package caching (QEMU/AAVMF/swtpm) — deliberately not added.** This is
a kernel project where QEMU *boot* time dominates wall-clock, not package
install (seconds vs. minutes); `actions/cache`'s own overhead could rival the
savings. Revisit only if step-duration data from actual CI runs shows
otherwise — a concrete, data-gated trigger, not a blind optimization.

## 5. Release pipeline (`.github/workflows/release.yml`)

Tag-triggered (`v*`) or manual. Builds `image_x64 -Doptimize=ReleaseSafe`,
signs it with a production Secure Boot `db` key from repository secrets,
emits a SLSA build-provenance attestation, attaches the signed image to the
GitHub release. See `docs/secure-boot.md`'s SB-6/`[D]` sections for the
cryptographic rationale (dev vs. production key custody, why signing happens
in CI rather than locally).

**This workflow does not exist on `main` at all** — confirmed via the GitHub
API (`list_workflows` returns only `ci.yml` and Dependabot Updates). It's
local-only work, never pushed, so it has never actually run on a real
runner. It already had a `codesign keypair` step in the right place; this
pass added the same `rustup target add x86_64-unknown-none` step `ci.yml`
needed, since `image_x64` reaches the same Rust `extra_binaries` dependency.

## 6. Known gaps (durable home for scattered build-system TODOs)

- **`build/Kernel.zig`'s `buildTestKernel`/`buildKernel` "duplication" — investigated (next-epoch build-system-refresh pass), not mechanical to fix.** The two can't share `buildRootModule()`: the release kernel roots at `src/main.zig` (importing `architecture`/`boot`/`innigkeit` as named modules), but `zig test`'s test-block discovery only walks the *root* module's own relative-import file tree (`.claude/rules/build.md`) — rooting the test binary at `src/main.zig` the same way would mean none of `innigkeit`'s own test blocks (the 146 kernel-side tests) get collected. Unifying these is blocked on the same kernel-module test-wiring gap below, not a simple copy-paste cleanup — comment corrected in place to say so instead of leaving a bare "TODO: unify this."
- **`build/Kernel.zig`'s optimize-mode tuning for the test kernel and the LLVM-backend-forcing TODO — investigated, left as-is.** Both are genuine design/tuning judgment calls (should release builds strip symbols or keep frame pointers for backtraces; should backend-limitation detection be more precise than a hardcoded arch list) rather than a clear-cut bug — changing either without a concrete goal (binary size target, specific backend capability data) would be an arbitrary guess, not a fix. Left flagged rather than resolved unilaterally.
- ~~`build/App.zig:229`/`:258` — `sanitize_c` should be conditional on whether any C is linked, currently always `.off`.~~ **FIXED** (next-epoch repo-reorg pass): `sanitize_c` is now `.off` unless the app module actually has C source files added (checked via `app_module.link_objects`, not just `.link_c`'s precompiled-libc linking, which UBSan can't instrument anyway) — enabled per-`optimize` (`.full`/.Debug, `.trap`/ReleaseSafe+ReleaseSmall, `.off`/ReleaseFast) the same way `sdk/build.zig`'s tool builder already does. Verified against `doom` (the only app with real C sources, ~70 files): `zig build doom_build_x64` compiles clean with UBSan now active. **Regression found and fixed 2026-07-13**: that same patch removed the *wrapper* module's (`library/innigkeit/prelude.zig`, the actual `-Mroot=` for every app compile) unconditional `sanitize_c = .off` without replacing it, leaving it at Zig's implicit Debug-mode default (`.full`). The wrapper compiles no C itself, so it never needed instrumentation — but left unset it pulled in `ubsan_rt.zig`'s f128 float-reporting path, which the freestanding soft-float x86-64 backend can't codegen (`fpext f128` has no encoding without SSE — a Zig 0.16.0 backend limitation, not a bug in our code). This broke `zig build check`/`build_all`/`verify` for every app on x64 (10/10 failed, confirmed by bisection to the `5933ade` "stash" commit). Fixed by restoring `wrapper.sanitize_c = .off` explicitly. Verified: `zig build check` exits 0, `zig build verify` → x64 157/157.
- RISC-V has no QEMU test suite (§2) — a real, accepted gap, not scheduled work yet.
- Apt-package caching (§4) — explicitly deferred pending step-duration data.
- The exact `virt-firmware` package source for `secboot-verify.yml` (`pip install virt-firmware`) was confirmed by inspecting how this sandbox was provisioned, not from an upstream Ubuntu package guarantee — worth a second check if the workflow's first scheduled run fails on that step specifically.
- **Developer experience / interface — partially addressed (next-epoch build-system-refresh pass); step naming/grouping and a "getting started" walkthrough remain undone.** Phase 1 fixed correctness (broken CI, misleading step names, missing coverage) but didn't redesign the actual day-to-day experience. **Fixed**: `tools/codesign/main.zig`'s (and its `sdk/codesign/main.zig` duplicate's) bare `error.FileNotFound` on a missing `keys/codesign_private.key`/`codesign_public.key` now prints a hint pointing at `zig build codesign -- keygen`; `build/RustApp.zig` now checks once per build invocation whether the `x86_64-unknown-none` target's rustlib directory exists under `rustc --print sysroot`, panicking with an actionable message ("run 'rustup target add x86_64-unknown-none'") instead of letting cargo fail later with its generic `error[E0463]: can't find crate for 'core'`. **Also fixed (this pass)**: the three remaining items. Bare `zig build` (previously a one-line "no build target provided" error, exit 1) and the new `zig build help` step now print the same categorized, curated command overview (Getting started / Run / Test / Build / Codesign, with `zig build -l` pointed to as the exhaustive raw list) — a real "getting started" entry point distinct from `verify`, reached without already knowing a step name. `docs/getting-started.md` is the actual new-contributor walkthrough: prerequisites, the two first-build gotchas (missing codesign keypair, the CONNECT-proxy package-fetch failure), then `check` → `run_{arch}` → `test_{arch}`/`test_native` → `verify` in the order a newcomer should try them.

**Deliberately not done**: renaming or restructuring the ~100+ existing step names (`test_x64`, `library_host_arm`, etc.) to sort into visual groups under plain `zig build -l` — Zig's build runner lists steps alphabetically with no category/header support, so the only way to get real grouping *inside* `-l`'s own output would be a step-naming convention (e.g. prefixing every step `test:x64`, `run:x64`) that breaks every existing invocation, doc reference, and muscle memory for a purely cosmetic gain now that a curated entry point exists. A Justfile was considered as an alternative discoverability layer but not added: it would just re-list the same `zig build ...` invocations under a second command surface with no new information, another file to keep in sync with `build.zig`'s actual step set, and this project has no existing `just` dependency — the native `zig build help` menu already closes the gap without adding a second, parallel entry point to maintain.

## 7. Session log

**2026-07-06 — Phase 1 (unified testing/build/CI/CD/verification system).**
Fixed the two confirmed CI-breaking bugs above; renamed `test` → `build_all`
across `build/Wrapper.zig` and wired it into `ci.yml`; added
`secboot-verify.yml`; wrote this doc. Verified locally: `zig build check`
clean, `zig build build_all` succeeds, `zig build verify -Dtpm=true` (155
passed, 2 skipped) and `zig build verify -Dsecboot=true` both succeed in this
sandbox — confirming the underlying build-graph mechanisms work, though
GitHub Actions itself cannot be triggered from this sandbox, so the new/edited
workflow YAML files are unvalidated against a real runner. **Not pushed to
`main`** — see §4/§5.
