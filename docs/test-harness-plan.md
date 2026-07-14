# User-process integration test harness

Spawn real user processes and exercise multi-process paths end-to-end — IPC round-trips with capability transfer, spawn/wait/kill lifecycle, fault recovery, and eventually the stashed WM client↔server. Currently these paths are compile-checked but not behaviorally verified. Owner doc for roadmap step 1.

This is a rewrite (2026) of the original TH-1..TH-5 draft, which was never implemented. A code-review + research pass over the actual kernel mechanics found the original plan assumed capabilities that don't exist yet (see "TH-3's real prerequisite" below) and glossed over real plumbing gaps (duplicated ELF-load code, no kernel-internal spawn API, no test-only-app build support). This version is grounded in exact file:line findings and is meant to be directly executable, stage by stage.

---

## Current state (unchanged, extended not replaced)

Three test layers exist today and stay as the foundation — this plan adds a fourth category using the *same* judging convention, not a competing one:

- **Host unit tests** (`zig build test_native`, `build.zig:44-67`'s inline `{name, path}` list): pure logic, no kernel. Fast, deterministic; the bulk of coverage.
- **In-QEMU kernel tests**: `src/innigkeit/testing/root.zig` collects `*.test.zig` files via explicit `_ = @import(...)` (not globbing); `src/innigkeit/testing/runner.zig`'s `runAll()` iterates `builtin.test_functions` and prints the serial verdict (`trying`/`pass`/`FAIL`/`skip`, final `ALL {d} TEST(S) PASSED`).
- **SMP stress tests** (`smp.test.zig`): 60s watchdog-bounded waits (`waitForCounter`), migration-pinned worker spawning (`spawnPinnedOnExecutor` via `Scheduler.queueTaskOnRemote`) so idle-stealing can't mask a dead executor.
- **Verification gate**: `zig build verify -Darm=true` (`build/Verify.zig`), judging every suite via `build/VerdictStep.zig` (a generic log-scanning pass/fail step) and, where an external daemon is needed, `build/TpmHarness.zig`'s start/stop lifecycle pattern.

**New integration tests slot into the second bullet, unchanged**: a new `testing/integration.test.zig` is just more `test "..."` blocks collected by `testing/root.zig`, judged by the same `VerdictStep` the gate already scans. No second judging mechanism, no new build-graph verdict step.

The gap this plan fills: every test today runs as kernel code. None spawns a user process. So:
- `Endpoint.transferCaps` is user↔user only (kernel tasks return early) — capability passing over IPC has no end-to-end test.
- The full `spawn` path (codesign verify → ELF load → entitlements → run) is only exercised incidentally (by booting the initial shell/WM at boot, not by an assertion).
- Fault recovery (`safe.memcpy`) is unit-tested at the copy level but not as "a real process faults and the kernel survives."

---

## What's missing (confirmed by direct code inspection, not assumed)

- **No shared kernel-internal spawn helper.** The ELF-load-and-start sequence (map loadable segments → copy segment data under a user-access window → apply protections → compute `AT_PHDR` → `thread.startProcess`) is duplicated in `src/innigkeit/user/handlers/spawn.zig`'s `loadAndStart` (unexported, syscall-only, requires a `.user`-type `Context`) and `src/innigkeit/init/stages/stage4.zig`'s `loadElfFromInitfs` (used to boot the initial shell/WM, no codesign check). A test needs a shared, exported path — not a third duplicate.
- **Cap transfer is user-only.** `CapabilityTable.transferCaps` (`src/innigkeit/capabilities/CapabilityTable.zig:214`) unconditionally returns early unless both sides are `.user` tasks. A kernel test task cannot be one side of a cap-transferring IPC exchange. Workaround: spawn *two* real user fixtures wired by a `CapGrant` at spawn time (`SpawnSpec.cap_grants`), and only observe from the kernel side via wait/notify — never make the kernel test itself an IPC party.
- **wait/kill are straightforward, with one real gap.** A kernel test can hold `Process.exit_notify: ?*Notify` directly and call `.wait`/`.poll`/`.signal`, mirroring `handlers/process.zig`'s `waitProcess` body. But `processKill` only cooperatively signals the exit-`Notify` — there's an explicit `TODO (multi-core): IPI sibling threads and force-terminate` at `handlers/process.zig:27`. No forced termination exists yet.
- **Fault recovery's real blocker — RESOLVED.** `memory/root.zig`'s `onPageFault`, `.user` branch, used to call `AddressSpace.handlePageFault` and panic the entire kernel on error. It now kills only the faulting process (sets `exit_status = 139`, calls `Scheduler.Handle.terminate()` — the same cooperative path `exit_process` already uses) and lets the kernel and every other process continue. x64 only in practice today (arm's data-abort path doesn't route to `onPageFault` yet), but the fix itself is architecture-generic. "A bad pointer passed as a syscall argument" (errno return, process keeps running) was already testable via `safe.memcpy`; "the process's own code touches a bad pointer directly" is now also handled, unblocking a TH-3-equivalent test — see below.
- **No fixture apps, no test-only-app build support.** Zero `itest_*` apps exist. `apps/root.zig`'s app list has no way to mark an app "test image only, exclude from the release image" — every app currently lands in both. Best existing template: `apps/hello_world/main.zig`'s `testSpawnWait()` already demonstrates the TH-1 shape (self-spawn via `innigkeit.process.spawnFull`, a `__child` argv convention, `waitProcess`) — proving the userspace-side primitives work; it's just never been asserted from a kernel-side test, and hello_world is a real demo app, not a minimal fixture.

---

## Staging (Stages 0-4 are concrete and ready to implement; later items are deliberately deferred, not designed further)

**Stage 0 — fix a dead test file (trivial, do first).** `src/innigkeit/testing/security.test.zig` (SMEP/SMAP checks) exists on disk but was never imported into `testing/root.zig` — it has never run. Add the import; it already self-guards non-x86_64 via a `comptime`-evaluated arch check, so it's safe to include unconditionally (Zig prunes the guarded branch entirely on arm).

**Stage 1 — factor the duplicated ELF-load sequence. DONE.** Extracted the shared map/copy/protect/`AT_PHDR`/`startProcess` sequence out of `handlers/spawn.zig::loadAndStart` and `stage4.zig::loadElfFromInitfs` into `src/innigkeit/user/elf_loader.zig`: `pub fn loadAndJump(thread: *Thread, elf_data: []const u8, proc_init: []const u8) !noreturn` (the `proc_init` parameter was missing from this doc's original sketch — spawn.zig needs it; stage4.zig passes `&.{}`). Each call site keeps its own trust decision (codesign-verify vs. stage4's boot-time no-verify — a real, pre-existing asymmetry this extraction did not change) and calls the shared function at the end. Two small hardening deltas were folded in deliberately (reviewed and approved, not accidental): iterator errors during map/copy/protect now propagate via `try` instead of spawn's old `catch null` (fail-closed on a malformed program header instead of silently ending the loop early); the source-range bounds check spawn already had is now shared, so stage4's boot path gains it too (dead code there today, since initfs ELFs are trusted/well-formed). Verified via `zig build check`, `zig build verify` (x64 137/137), and `zig build verify -Darm=true` (97 total/12 skipped, same 85-passed count as before Stage 0+1 combined).

**Stage 2 — kernel-internal spawn API. DONE.** Extracted `spawn()`'s steps 5-8 (exit-`Notify` creation, `Process.create`, cap-grant insertion, thread creation + queue) into `user/Process.zig::spawnFromInitfs(params: SpawnParams) SpawnError!SpawnResult` (`SpawnParams{path, proc_init, cap_grants}`, `SpawnResult{child, exit_notify}`). One delta from this doc's original sketch: `cap_grants` takes already-*resolved* `ResolvedCapGrant{cap_type, ptr, rights}` entries, not raw handles — the syscall handler resolves against the parent's `cap_table` (rights-subset check included) *before* calling `spawnFromInitfs`, which only performs the child-side insert and never touches a parent's cap table. The shared ELF-load thread entry (`loadAndStart`, previously private to `handlers/spawn.zig`) moved into `Process.zig` alongside it, since it's part of the same kernel-internal spawn mechanism. `handlers/spawn.zig::spawn()` is now: decode from user memory (unchanged) → resolve cap grants against the parent's `cap_table` → call `spawnFromInitfs` → insert `exit_notify` into the parent's table (unchanged).

**Stage 3 — fixture-app build support. DONE.** Added `test_only: bool = false` to `build/AppDescription.zig`, carried into `App` (`build/App.zig::resolveApp`), filtered in `build/Kernel.zig::buildInitfs` via a new `include_test_only: bool` param (`buildKernel` passes `false`, `buildTestKernel` passes `true`). Added `apps/itest_spawn_wait/{main.zig,manifest.toml}` (`main.zig` is `innigkeit.process.exit(42)`; `manifest.toml` mirrors `hello_world`'s minimal shape), registered in `apps/root.zig` with `test_only = true`. Verified: the `.codesig` sidecar name (a real initfs-archive-member marker, unlike the app name itself which also appears in Debug-build debug-info source embedding regardless of initfs contents) is present in the test kernel's strings and absent from the release kernel's.

**Stage 4 — TH-1: the first real integration test. DONE (x64; arm skips, see below).** New `src/innigkeit/testing/integration.test.zig`, collected via `testing/root.zig`:
```zig
test "integration: spawn itest_spawn_wait and observe its exit status" {
    const result = try innigkeit.user.Process.spawnFromInitfs(.{ .path = "itest_spawn_wait" });
    defer result.exit_notify.unref();
    const bits = try waitForNotify(result.exit_notify, 0xFF_01); // watchdog-bounded poll loop, mirrors smp.test.zig's waitForCounter
    try std.testing.expectEqual(@as(u8, 42), @as(u8, @truncate(bits >> 8)));
}
```
(`Notify.wait()` has no timeout, so the actual harness polls via `Notify.poll()` in a wallclock-bounded loop rather than calling `.wait()` directly — same watchdog discipline as `smp.test.zig`, applied to a `Notify` instead of an atomic counter.) Verified: `zig build check` clean; x64 137→138 tests; release image confirmed fixture-free.

**Arm gap discovered by Stage 4, not fixed here.** Running the new test on arm panics: a recursive "current-EL SP_EL1 synchronous" exception inside `arm.vectors.vector_common` itself. This is exactly the kind of gap this plan's own "what's missing" section predicted ("The full `spawn` path ... is only exercised incidentally by booting the initial shell/WM, not by an assertion") — spawning a *second* process at runtime, via a freshly created kernel thread, has never been exercised on arm before; the boot-time path (`stage4.zig`) loads the *first* process inline in the stage4 task, never creating a new kernel thread to do it. Gated `x86_64`-only (`if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;`, same idiom as `security.test.zig`) rather than investigated further here — root-causing an arm exception-handling bug is its own task, scoped in `docs/roadmap.md`'s "Foundational arm work" item, not test-harness work. Arm baseline: 97→98 passed, 12→13 skipped.

---

## Explicitly deferred (reasons recorded, not designed further)

- **TH-2 (IPC round-trip + capability transfer).** Two `itest_*` fixtures wired by `SpawnSpec.cap_grants` at spawn time, observed only via wait/notify from the kernel side — **not** kernel-task-as-IPC-party, which `transferCaps`'s `.user`-only check blocks and this plan does not touch.
- **TH-4 (lifecycle: spawn/wait/kill, cleanup, no-leak across repeated spawn/kill).** Must scope around the confirmed gap that `processKill` only cooperatively signals the exit-`Notify` — there is no forced/multi-core termination yet. Test only the cooperative path, or treat forced termination as its own prerequisite kernel task.
- **TH-3's real prerequisite (a process faults, the kernel survives) — DONE.** `memory/root.zig`'s `onPageFault` `.user` branch now terminates only the faulting process instead of panicking the whole kernel. A TH-3-equivalent test can now be written once Stage 3's fixture-app infrastructure exists: an `itest_*` fixture that deliberately dereferences a bad pointer, spawned via `Process.spawnFromInitfs` (Stage 2), asserting the kernel test suite itself keeps running and observing the fixture's `exit_notify` fire with status 139. Not written yet — needs Stage 3's fixture-app build support first, same as TH-1.
- **TH-5 (WM client↔server over real IPC).** Depends on TH-2's cap-grant machinery plus the stashed WM protocol; stays stashed until TH-2 lands.
- **Coverage/fuzzing/flake-tracking infrastructure.** Not needed for what's actually missing; out of scope for this plan.
