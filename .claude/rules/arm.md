---
paths:
  - "src/architecture/arm/**"
  - "docs/aarch64-port.md"
---

# AArch64-specific constraints

- `zig build check` does NOT validate inline assembly (`-fno-emit-bin`). Always run a real kernel build after touching arm `asm`. Use the raw S-register encoding (`s3_3_c2_c4_0`) + runtime ID-register gates for instructions not supported by the assembler (RNDR pattern).
- Data-abort → `onPageFault` routing is NOT implemented yet. `memory.safe.memcpy` and `memory.safe.atomicLoadU32` fall back to plain copies on arm — a bad user pointer still panics. Do not claim fault-safe user access is complete on arm.
- `testCpus()` returns 1 for aarch64 (M1/M2 are single-core). AP startup is M3 and not started.
- `mapDeviceMmio` in `PageTable.zig` is idempotent (guarded by `device_mmio_mapped`). GIC at `0x0800_0000`, PL011 at `0x0900_0000`.
- bundled EDK2 (zig-pkg, 2026-03) is BROKEN — always use host `/usr/share/AAVMF/AAVMF_CODE.fd`.
- TCG aarch64 boot is slow (~60–120 s for firmware). Budget ≥ 180 s per boot attempt.
- ARM test harness: judge by serial verdict `ALL N TEST(S) PASSED`, never by QEMU exit status: `build/VerdictStep.zig` does this as a real build-graph dependency now, not a manual grep. `zig build verify -Darm=true` (or `zig build test_arm` directly) is the reliable path.
- AP startup is Limine-mediated (not PSCI from kernel). `stage1.bootNonBootstrapExecutors` calls `desc.boot` which writes `goto_address` into the Limine `MPInfo`. The kernel never issues PSCI itself.
- GICv2 SGI IAR detail: `GICC_IAR` for an SGI includes the source CPU in `[12:10]`. Mask `[9:0]` for dispatch but pass the full IAR value to `GICC_EOIR`. A raw comparison against `MAX_IRQS` will drop SGIs from CPU > 0.
- **Runtime process spawn panics on arm.** Spawning a *second* process after boot (`Process.spawnFromInitfs` / the `spawn` syscall, as opposed to the single process `stage4.zig` loads inline before the scheduler is even running) triggers a recursive/looping "current-EL SP_EL1 synchronous" exception inside `arm.vectors.vector_common` itself — confirmed via `testing/integration.test.zig`, the first test to actually exercise this path on arm (skipped there for now). The boot-time path works because it never creates a new kernel thread to do the load; runtime spawn does. Root cause not yet investigated — likely something arm-specific about a freshly created kernel thread's SP_EL1/stack setup, or address-space creation post-boot. Tracked as its own "foundational arm work" item in `docs/roadmap.md`, not folded into test-harness work.

## EL0 synchronous exceptions (syscalls AND user faults) unconditionally panic — bigger gap than the data-abort note above states (Phase 3 Stage 9)

The "data-abort routing is not implemented" bullet above is true but understates
the actual scope: `vectors.zig`'s `arm_handle_exception` dispatches purely on
`vector_idx` (which of the 16 vector-table slots fired), never on
`ESR_EL1`'s Exception Class field. Vector index 8 ("lower-EL AArch64
synchronous") is where the CPU sends *every* EL0 synchronous exception —
`SVC` (syscalls), data aborts, instruction aborts, undefined instructions,
all of it — and the current handler treats index 8 exactly like every other
non-IRQ vector: dump ESR/FAR/ELR via semihosting, then unconditionally
`@panic()`. There is no ESR.EC-based sub-dispatch, no syscall entry path, and
no fault-to-signal isolation (the x64 `exceptionDisposition()` system from
Stage 6a/6b has no arm counterpart at all yet). `interface.zig`'s own comment
already says as much ("its handlers dump faults via semihosting and then
panic"), so this isn't a newly-hidden bug — but its true scope (syscalls too,
not just faults) wasn't stated this explicitly before.

**Why this hasn't shown up as a boot failure**: no currently-passing test
actually reaches EL0 on arm. Both `testing/integration.test.zig` tests that
spawn a real process (`itest_spawn_wait`, `itest_illegal_instruction`) are
unconditionally `SkipZigTest`-gated to x86_64 only. `stage4.zig`'s test-build
path runs the kernel-side test suite directly (`testing.runner.runAll()`) and
never calls `Process.spawnFromInitfs`. So arm's SVC/fault dispatch is
currently exercised by nothing in the passing 102-test baseline — this is a
real gap, not a masked-by-something-else non-issue.

**Not fixed this pass.** Implementing real syscall dispatch + the
x64-equivalent fault-isolation system for arm is comparable in scope to the
Stage 6a/6b x64 exception-isolation redesign (a new ESR.EC decode, a real
`SyscallFrame`-driven dispatch path, `Process.terminateCallingThread`
wiring, and a disposition table mirroring `Interrupt.exceptionDisposition()`)
— a deliberate design effort, not a mechanical fix, and out of scope for a
review pass per this project's delivery model. Flagged here explicitly so
a future arm-userspace milestone doesn't rediscover this from scratch.

## `test` blocks written directly inside `src/architecture/{x64,arm}/*.zig` never run (Phase 3 Stage 9)

Confirmed by direct experiment: a `test` block added to `arm/timer.zig`
never appeared in the `test_arm` serial log, and a pre-existing `test` block
in `x64/registers/Cr4.zig` (`"cr4: SMEP is enforced..."`/`"cr4: SMAP is
enforced..."`) never appeared in the `test_x64` log either — both silently
dead. Root cause (documented at the top of `testing/syscall_frame.test.zig`,
which already works around it): the kernel test binary's root module is
`innigkeit`, and `architecture` is a *separate* Zig module `innigkeit`
imports — Zig's test-block collection only walks the root module's own file
graph, never a dependency module's. The `Cr4.zig` tests were fully redundant
with already-passing tests in `testing/security.test.zig` anyway, so they
were deleted rather than moved. **The fix for any future arch-specific
test**: put it under `src/innigkeit/testing/*.test.zig` (referenced from
`testing/root.zig`'s comptime import list) and reach the arch-specific
behavior through `architecture.current_decls`/`architecture.current_functions`
(the generic interface), exactly like `syscall_frame.test.zig` does — not as
an inline `test` block next to the arch code itself, no matter how natural
that placement looks.
